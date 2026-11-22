"""Servidor MCP da Sentinela — JSON-RPC 2.0 sobre stdio, sem dependencias.

Implementado a mao (o SDK oficial exige Python 3.10+ e este projeto roda em 3.9).
Especificacao: https://modelcontextprotocol.io

Transporte: uma mensagem JSON por linha no stdin/stdout.

Filosofia de seguranca: as ferramentas sao divididas em camadas.
  - LEITURA   : nao altera nada (info, consulta de docs, referencia de protocolo)
  - PROVA     : fala com a camera, mas so le (baseinfo, lista de SD)
  - ATIVA     : ataca a rede (ARP/DNS/relay) e precisa de confirmacao explicita
Agentes de IA podem ser induzidos por prompt injection; por isso as ferramentas
ativas exigem `confirm: true` e um alvo declarado pelo operador.
"""

import json
import os
import sys
import traceback
from pathlib import Path

# Permite rodar tanto por `python3 mcp_server/server.py` quanto pelo binario da
# raiz: a raiz do projeto entra no sys.path para achar o pacote sentinela_cli.
_ROOT = Path(__file__).resolve().parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

# O servidor roda conduzido por um agente: nao existe terminal para pausas
# fisicas nem para a senha do sudo. O core le esta variavel na importacao.
os.environ.setdefault("SENTINELA_NONINTERACTIVE", "1")

from sentinela_cli import core  # noqa: E402
from sentinela_cli.scenarios import SCENARIOS  # noqa: E402

# Os cenarios da CLI sao interativos (pedem ENTER e confirmacao no terminal).
# Num agente MCP nao existe terminal, entao aqui as ferramentas ativas recebem
# `confirm: true` como contrato e chamam apenas as pecas nao-interativas.

_mitm = SCENARIOS["mitm"][0]
_dns = SCENARIOS["dns"][0]

SERVER_INFO = {
    "name": "sentinela",
    "version": "1.0.0",
}

PROTOCOL_VERSION = "2024-11-05"


# --------------------------------------------------------------------- utils
def _text(s):
    return {"content": [{"type": "text", "text": s}]}


def _json(obj):
    return _text(json.dumps(obj, indent=2, ensure_ascii=False))


def _err(msg):
    return {"isError": True, "content": [{"type": "text", "text": msg}]}


# --------------------------------------------------------------------- tools
def tool_info(args):
    """Diagnostico read-only do ambiente. Camada: LEITURA."""
    ev = core.Evidence("mcp_info")
    out = []
    ip, gw, ssid = core.my_ip(), core.gateway(), core.wifi_ssid()
    out.append(f"interface  {core.IFACE}: {ip or 'sem IPv4'}")
    out.append(f"gateway    {gw or '?'}")
    out.append(f"wifi       {ssid or 'desconectado'}")

    on_ap = bool(ssid and ssid.upper().startswith("NAX_"))
    if on_ap:
        reach = core.tcp_open(core.AP_IP, core.AP_PORT)
        out.append(f"modo       AP da camera (rede {ssid})")
        out.append(f"camera     {core.AP_IP}:{core.AP_PORT} {'acessivel' if reach else 'SEM RESPOSTA'}")
        out.append(f"auth       {'nenhuma (token hardcoded)' if reach else 'n/a'}")
    else:
        cam = core.discover_camera(sweep=False)
        out.append(f"modo       STA (camera na LAN)")
        out.append(f"camera     {cam or 'nao encontrada no ARP'}")
    return _text("\n".join(out))


def tool_kb_search(args):
    """Busca nos achados/protocolo. Camada: LEITURA."""
    q = (args.get("query") or "").lower().strip()
    if not q:
        return _err("informe 'query'")
    docs = core.ROOT / "docs"
    hits = []
    for f in sorted(docs.glob("*.md")):
        try:
            lines = f.read_text(errors="ignore").splitlines()
        except OSError:
            continue
        for i, ln in enumerate(lines, 1):
            if q in ln.lower():
                hits.append(f"{f.name}:{i}: {ln.strip()[:160]}")
    if not hits:
        return _text(f"nada encontrado para {q!r}")
    head = f"{len(hits)} ocorrencia(s) para {q!r}:\n"
    return _text(head + "\n".join(hits[:40]))


def tool_doc_read(args):
    """Le um documento de achados. Camada: LEITURA."""
    name = args.get("name") or ""
    if not name.endswith(".md"):
        name += ".md"
    path = (core.ROOT / "docs" / name).resolve()
    docs = (core.ROOT / "docs").resolve()
    if docs not in path.parents:
        return _err("so documentos em docs/")
    if not path.exists():
        avail = ", ".join(sorted(p.name for p in docs.glob("*.md")))
        return _err(f"{name} nao existe. disponiveis: {avail}")
    return _text(path.read_text(errors="ignore"))


def tool_protocol_ref(args):
    """Devolve a referencia do protocolo (framing, envelopes, codigos)."""
    p = core.ROOT / "docs" / "protocolo_naxclow.md"
    if p.exists():
        return _text(p.read_text(errors="ignore"))
    return _err("protocolo_naxclow.md ausente")


def tool_ap_probe(args):
    """Le baseinfo e o catalogo do SD em modo AP. Camada: PROVA (so leitura)."""
    if not core.tcp_open(core.AP_IP, core.AP_PORT):
        return _err(f"camera nao responde em {core.AP_IP}:{core.AP_PORT}. "
                    "O PC esta na rede Nax_XXXXXX?")
    rc, out = core.run([sys.executable, "src/a9_naxclow.py",
                        "-c", f"{core.AP_IP}:{core.AP_PORT}", "-f"], check=False)
    return _text(f"camera acessivel sem autenticacao em {core.AP_IP}:{core.AP_PORT}\n\n{out}")


def tool_ap_control(args):
    """Liga IR e aplica flip. Camada: ATIVA (efeito fisico visivel)."""
    if not args.get("confirm"):
        return _err("ferramenta ativa: repita com confirm=true. "
                    "Isto liga o IR e inverte a imagem da camera.")
    if not core.tcp_open(core.AP_IP, core.AP_PORT):
        return _err("camera nao responde em modo AP")
    secs = int(args.get("seconds", 15))
    rc, out = core.run([str(core.SCRIPTS / "mitm_dns" / "ap_ir_flip.sh"), str(secs)],
                       check=False, capture=True)
    if rc != 0:
        return _err(f"falhou (exit {rc}): {(out or '').strip()[-300:]}")
    return _text(f"IR + flip aplicados por {secs}s. Verifique o efeito fisico.")


def tool_relay_ptz(args):
    """Move a camera pelo canal relay. Camada: ATIVA (efeito fisico)."""
    if not args.get("confirm"):
        return _err("ferramenta ativa: repita com confirm=true. "
                    "Isto move a camera fisicamente.")
    direction = args.get("direction")
    if direction not in ("right", "left", "up", "down", "stop"):
        return _err("direction: right|left|up|down|stop")
    code = {"right": 1, "left": 2, "up": 3, "down": 4, "stop": 0}[direction]
    secs = float(args.get("seconds", 3))
    host = args.get("host", "127.0.0.1:8080")

    # Confere se o relay esta aberto ANTES de mandar pulsos: o ptz.sh fala com
    # /dev/<uid>/fwd, que so responde quando a camera abriu o canal.
    ok, devs = core.http_get_json(f"http://{host}/dev/list", timeout=5)
    if not ok:
        return _err(f"relay inacessivel em {host} — o fake server esta no ar?")
    if not devs:
        return _err(f"relay no ar em {host}, mas nenhuma camera registrada. "
                    "Abra o viewer no app para disparar o 240, ou reenvie o getDevInfo.")

    rc, out = core.run([str(core.SCRIPTS / "mitm_dns" / "ptz.sh"),
                        str(code), str(secs), host], check=False, capture=True)
    if rc != 0:
        return _err(f"PTZ falhou (exit {rc})\n{(out or '').strip()[-300:]}")
    return _text(out or f"PTZ {direction} enviado")


def tool_mitm(args):
    """ARP spoof + captura na LAN. Camada: ATIVA (altera a rede)."""
    if not args.get("confirm"):
        return _err("ferramenta ativa: repita com confirm=true e com o alvo declarado. "
                    "Isto faz ARP spoof na rede local.")
    cam = args.get("target") or core.discover_camera(sweep=False)
    if not cam:
        return _err("camera nao encontrada; informe 'target' (IP da camera)")
    dur = int(args.get("seconds", 60))
    ev = core.Evidence("mcp_mitm")
    try:
        _mitm(ev)
    except core.Abort as e:
        return _err(f"abortado: {e}")
    return _json({"target": cam, "evidence": str(ev.dir),
                  "checks": [list(c) for c in ev.checks]})


def tool_dns(args):
    """Fake server + DNS/DNAT. Camada: ATIVA (altera a rede)."""
    if not args.get("confirm"):
        return _err("ferramenta ativa: repita com confirm=true. "
                    "Isto envenena ARP/DNS e sobe broker MQTT falso.")
    ev = core.Evidence("mcp_dns")
    try:
        _dns(ev)
    except core.Abort as e:
        return _err(f"abortado: {e}")
    return _json({"evidence": str(ev.dir), "checks": [list(c) for c in ev.checks]})


def tool_lab_down(args):
    """Derruba o laboratorio. Camada: ATIVA."""
    core.hdr("DERRUBAR")
    rc, out = core.run([str(core.SCRIPTS / "mitm_dns" / "ota_up.sh"), "down"],
                       sudo=True, check=False, timeout=180, capture=True)
    if rc != 0:
        # Sem sudo sem senha o comando nao roda. Nunca reportar sucesso nesse
        # caso: um agente precisa saber que a rede continua modificada.
        return _err(
            f"nao foi possivel derrubar o lab (exit {rc}).\n"
            "Se aparecer 'a password is required', rode manualmente num "
            "terminal com sudo:\n"
            f"  sudo {core.SCRIPTS / 'mitm_dns' / 'ota_up.sh'} down\n"
            f"saida: {(out or '').strip()[-300:] or '(vazia)'}"
        )
    return _text("lab derrubado (ARP/DNS/DNAT restaurados)")


def tool_findings_summary(args):
    """Resumo dos achados: o que foi provado, o que falhou."""
    p = core.ROOT / "docs" / "achados_finais.md"
    if not p.exists():
        return _err("achados_finais.md ausente")
    txt = p.read_text(errors="ignore")
    # devolve a conclusao + a tabela de ultimos testes
    idx = txt.find("## Conclusão")
    tail = txt[idx:] if idx > 0 else txt[-2500:]
    return _text(tail)


# --------------------------------------------------------------------- spec
TOOLS = [
    {
        "name": "info",
        "description": "Diagnostico read-only do ambiente: interface, gateway, WiFi, "
                       "e se a camera responde (modo AP ou STA). Nao altera nada. "
                       "Comece sempre por aqui.",
        "inputSchema": {"type": "object", "properties": {}},
        "annotations": {"readOnlyHint": True},
        "fn": tool_info,
    },
    {
        "name": "findings_summary",
        "description": "Resumo consolidado da pesquisa: quais ataques foram provados e "
                       "quais falharam, com o modelo de ameaca. Use para responder "
                       "'a camera X e segura?'. Nao toca em nenhum dispositivo.",
        "inputSchema": {"type": "object", "properties": {}},
        "annotations": {"readOnlyHint": True},
        "fn": tool_findings_summary,
    },
    {
        "name": "kb_search",
        "description": "Busca textual nos documentos de achados/protocolo do projeto. "
                       "Util para achar evidencias, armadilhas e codigos de comando.",
        "inputSchema": {
            "type": "object",
            "properties": {"query": {"type": "string", "description": "termo de busca"}},
            "required": ["query"],
        },
        "annotations": {"readOnlyHint": True},
        "fn": tool_kb_search,
    },
    {
        "name": "doc_read",
        "description": "Le um documento de docs/ (ex.: achados_relay_controle.md).",
        "inputSchema": {
            "type": "object",
            "properties": {"name": {"type": "string", "description": "nome do .md"}},
            "required": ["name"],
        },
        "annotations": {"readOnlyHint": True},
        "fn": tool_doc_read,
    },
    {
        "name": "protocol_ref",
        "description": "Referencia do protocolo Naxclow/V720: framing de 20 bytes, "
                       "envelopes 301/502, codigos de comando, portas.",
        "inputSchema": {"type": "object", "properties": {}},
        "annotations": {"readOnlyHint": True},
        "fn": tool_protocol_ref,
    },
    {
        "name": "ap_probe",
        "description": "Com a camera em modo AP (rede Nax_XXXXXX), conecta sem "
                       "autenticacao e lista o cartao SD. Prova de exposicao local. "
                       "So leitura.",
        "inputSchema": {"type": "object", "properties": {}},
        "annotations": {"readOnlyHint": True},
        "fn": tool_ap_probe,
    },
    {
        "name": "ap_control",
        "description": "ATIVA. Com a camera em modo AP, liga o IR e aplica flip. "
                       "Tem efeito fisico visivel. Exige confirm=true.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "confirm": {"type": "boolean"},
                "seconds": {"type": "integer", "default": 15},
            },
            "required": ["confirm"],
        },
        "annotations": {"readOnlyHint": False, "destructiveHint": False},
        "fn": tool_ap_control,
    },
    {
        "name": "relay_ptz",
        "description": "ATIVA. Move a camera (pan/tilt) pelo canal de relay do fake "
                       "server. Tem efeito fisico. Exige confirm=true.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "confirm": {"type": "boolean"},
                "direction": {"type": "string", "enum": ["right", "left", "up", "down", "stop"]},
                "seconds": {"type": "number", "default": 3},
                "host": {"type": "string", "default": "127.0.0.1:8080"},
            },
            "required": ["confirm", "direction"],
        },
        "annotations": {"readOnlyHint": False, "destructiveHint": False},
        "fn": tool_relay_ptz,
    },
    {
        "name": "mitm_capture",
        "description": "ATIVA. ARP spoof na LAN + captura de trafego e remontagem de "
                       "video. Altera a rede. Exige confirm=true e o alvo.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "confirm": {"type": "boolean"},
                "target": {"type": "string", "description": "IP da camera"},
                "seconds": {"type": "integer", "default": 60},
            },
            "required": ["confirm"],
        },
        "annotations": {"readOnlyHint": False, "destructiveHint": True},
        "fn": tool_mitm,
    },
    {
        "name": "fake_cloud",
        "description": "ATIVA. Sobe fake server + broker MQTT e envenena ARP/DNS para "
                       "a camera aceitar um cloud falso. Exige confirm=true.",
        "inputSchema": {
            "type": "object",
            "properties": {"confirm": {"type": "boolean"}},
            "required": ["confirm"],
        },
        "annotations": {"readOnlyHint": False, "destructiveHint": True},
        "fn": tool_dns,
    },
    {
        "name": "lab_down",
        "description": "Derruba o laboratorio e restaura ARP/DNS/DNAT. Use sempre que "
                       "terminar um teste ativo.",
        "inputSchema": {"type": "object", "properties": {}},
        "annotations": {"readOnlyHint": False, "destructiveHint": False},
        "fn": tool_lab_down,
    },
]

TOOL_MAP = {t["name"]: t for t in TOOLS}


# --------------------------------------------------------------------- MCP
def handle(msg):
    method = msg.get("method")
    mid = msg.get("id")
    params = msg.get("params") or {}

    def reply(result):
        return {"jsonrpc": "2.0", "id": mid, "result": result}

    def error(code, message):
        return {"jsonrpc": "2.0", "id": mid, "error": {"code": code, "message": message}}

    if method == "initialize":
        return reply({
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {"listChanged": False},
                             "resources": {"listChanged": False}},
            "serverInfo": SERVER_INFO,
        })

    if method == "notifications/initialized":
        return None   # notificacao: sem resposta

    if method == "ping":
        return reply({})

    if method == "tools/list":
        return reply({"tools": [{k: v for k, v in t.items() if k != "fn"} for t in TOOLS]})

    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        tool = TOOL_MAP.get(name)
        if not tool:
            return error(-32602, f"ferramenta desconhecida: {name}")
        try:
            # As funcoes usam print() para narrar o progresso. Em stdio o stdout
            # e o canal do protocolo: qualquer print corromperia o JSON-RPC.
            # Redireciona tudo para stderr durante a execucao da ferramenta.
            real_stdout = sys.stdout
            sys.stdout = sys.stderr
            try:
                result = tool["fn"](args)
            finally:
                sys.stdout = real_stdout
            return reply(result)
        except Exception as e:
            return reply(_err(f"erro em {name}: {e}\n{traceback.format_exc()[-600:]}"))

    if method == "resources/list":
        docs = core.ROOT / "docs"
        res = [{
            "uri": f"sentinela://docs/{p.name}",
            "name": p.name,
            "description": "Documento de achados do projeto",
            "mimeType": "text/markdown",
        } for p in sorted(docs.glob("*.md"))]
        return reply({"resources": res})

    if method == "resources/read":
        uri = params.get("uri", "")
        name = uri.rsplit("/", 1)[-1]
        path = (core.ROOT / "docs" / name).resolve()
        docs = (core.ROOT / "docs").resolve()
        if docs not in path.parents or not path.exists():
            return error(-32602, f"recurso invalido: {uri}")
        return reply({"contents": [{"uri": uri, "mimeType": "text/markdown",
                                    "text": path.read_text(errors="ignore")}]})

    return error(-32601, f"metodo nao suportado: {method}")


def main():
    # stdout e reservado para o protocolo; logs vao para stderr.
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError as e:
            out = {"jsonrpc": "2.0", "id": None,
                   "error": {"code": -32700, "message": f"parse error: {e}"}}
            sys.stdout.write(json.dumps(out) + "\n")
            sys.stdout.flush()
            continue

        try:
            out = handle(msg)
        except Exception as e:
            print(f"[sentinela-mcp] erro: {e}", file=sys.stderr)
            out = {"jsonrpc": "2.0", "id": msg.get("id"),
                   "error": {"code": -32603, "message": str(e)}}

        if out is not None:
            sys.stdout.write(json.dumps(out) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
