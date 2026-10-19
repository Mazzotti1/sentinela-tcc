# Protocolo Naxclow Y2SN — Mapeamento completo câmera ↔ app ↔ cloud

> Documentação viva do protocolo em **texto claro** (sem TLS/MQTT auth). Baseado na
> captura real `cam_real.pcap` (2026-09-07, rede NET_2GB, fluxo: reset → parear →
> conectar rede → abrir frame). O objetivo é **replicar exatamente** cada passo no
> fake server (`scripts/fakeserver/fakesrv_lab.sh` + `src/v720_sta.py`/`v720_http.py`).

## Atores e endereços (captura real)

| Ator | IP | MAC | Portas servidas |
|---|---|---|---|
| Câmera Naxclow Y2SN (`devicesCode 5c001502B330`) | 192.168.0.17 | 5c:f1:50:04:af:8a | cliente MQTT/TCP; escuta 29940 (dados) |
| Broker MQTT (cloud) | 39.108.132.112 | — | 1883 |
| HTTP API (cloud) | 47.243.132.88 | — | 80 |
| Relay de dados (cloud) | 107.149.143.96 | — | 29940 (TCP/UDP) |
| Relay secundário (UDP probe) | 191.187.210.110 | — | 18294 (UDP) |

> Nota: o cloud usa múltiplos IPs (balanceamento). Tanto `107.149.143.96` quanto
> `107.149.136.10` e `47.243.132.88` aparecem. A **porta de dados é sempre 29940**.

## Fluxo 1 — Provisionamento / vinculação (HTTP)

**Quem inicia:** o cloud contata a câmera (`47.243.132.88:80 -> camera:52433`, SYN).
A câmera responde e há troca HTTP.

**Resposta do cloud ao request da câmera (JSON, em claro):**
```json
{"code":200,"message":"OK",
 "data":{"userInfo_userId":"7eba2591eaa08c41e2f8de7733983f49",
         "ota_url":null,"ota_version":null,
         "ntpTimer":1788749853,"userInfo_state":1,
         "timeZone":-3,"cloudStorage":0}}
```
- `userInfo_state:1` = usuário/device validado.

**Endpoints (fake server já implementa):**
- `/app/api/ApiSysDevices/a9bindingAppDevice?devicesCode=<dev>&userKey=<user>&...`
- `/app/api/ApiSysDevices/getDevInfo?devicesCode=<dev>&random=<r>&token=<t>`
- `/app/api/ApiServer/getA9ConfCheck?devicesCode=<dev>` → devolve `host`+`tcpPort`+`uid`

## Fluxo 2 — Controle via MQTT (broker 1883)

**Subscrições da câmera:** `Naxclow/P2P/Users/Device/sub/5c001502B330` (QoS 1).
**Publishes da câmera:** `Naxclow/P2P/Users/Device/Info` e `.../Device/Status`.

**Sequência de comandos do CLOUD para a câmera no tópico `sub/<DEV>` (ordem real):**
```json
1) {"code":216,"ntpTimer":<unix>,"timeZone":-3}          // config NTP
2) {"code":249,"cloudStorage":0}                        // config storage
3) {"code":240,"domain":"v720.naxclow.com",
     "host":"<ip>","pwd":"ef830de3",
     "connectId":"<hex>","userId":"<user>"}              // abrir canal de dados
```

**Achado (resolvido):** o fake publicava `216` e `240`, mas **NÃO o `code:249`** entre
eles — era o candidato nº1 da correção (a câmera espera o `249` de config de storage
antes de aceitar o `240`). **Implementado** em `v720_http.py`
(`_pub({"code":249,"cloudStorage":0})`, entre o `216` e o `240`). A ordem real é
`216 → 249 → 240`.

## Fluxo 3 — Canal de dados (relay TCP/UDP 29940)

**Quem conecta:** no real, o **cloud** faz SYN para a câmera (`107.149.143.96.29940 ->
camera:26104`). Na arquitetura do fake, o fake server escuta e a câmera/espelho conecta.

**Sequência de payloads (JSON, texto claro) enviados pelo cloud no 29940:**
```json
1) {"code":101,"status":200}                 // registro OK (primeiro envio)
2) {"code":11,"cliTarget":..,"cliToken":..,  // NAT probe (chama UDP de dados)
    "cliIp":"191.187.210.110","cliPort":18294,
    "cliNatIp":"192.168.0.21","cliNatPort":53462}
3) {"code":53,"status":1,"target":"<user>"}  // device online
4) {"code":301,"target":"<user>","content":{"code":298}}   // retransmissão
5) {"code":301,"target":"<user>","content":{"unixTimer":<t>,"code":4}}  // baseinfo
6) {"code":301,"target":"<user>","content":{"code":3}}     // ABRIR STREAM (vídeo+áudio)
7) {"code":301,"target":"<user>","content":{"code":218}}   // SD status
```

**Achado:** o fake server tem handlers para quase todos (`101` em `__reg_req_hnd`,
`11` em `__send_nat_probe`, `53`+`298`+`4` em `__initial_sequence`, `3` em
`__start_live`), mas **só os disparava após a câmera completar o probe** — que não
acontecia porque a conexão caía. A correção fez o `__tcp_hnd` disparar a sequência
completa **proativamente** na conexão.

## Canal de dados — valores de sessão (CRÍTICOS)

Os seguintes valores aparecem fixos na captura `viewer_real.pcap` e **a câmera
valida** (usar errado = conexão fechada):

| Campo | Valor real (cloud) | Fake ANTES (errado) | Fake AGORA (correto) |
|---|---|---|---|
| `cliTarget` (code 11) | `7eba2591eaa08c41e2f8de7733983f49` | `00112233445566778899aabbccddeeff` | `7eba...` (env `CLI_TG`) |
| `cliToken`  (code 11) | `2a5dc181` | `deadc0de` | `2a5dc181` (env `CLI_TKN`) |
| `cliIp`     (code 11) | `191.187.210.110` | `255.255.255.255` | env `FAKE_SRV_CLIIP` |
| `cliPort`   (code 11) | `47006` / `30147` | `0` | env `FAKE_SRV_CLIPORT` |
| `cliNatIp`  (code 11) | `192.168.0.21` | `get_ip()` auto | env `FAKE_SRV_NATIP` |
| `cliNatPort`(code 11) | `53929` / `53932` | `UDP_PORT` (29940) | env `FAKE_SRV_NATPORT` |

**Achado-chave:** a câmera rejeita o NAT probe se o `cliTarget`/`cliToken` não
corresponderem à sua sessão (userId `7eba...` / token `2a5dc181`). O fake usava
tokens genéricos e por isso a conexão caía logo após o `code 11`.

## Fluxo 4 — Stream (vídeo/áudio)

Depois do `code 3` (abrir stream), o vídeo (MJPG, `cmd=1`, msg_flag 250/251/252/255)
e o áudio (G711, `cmd=4`) vêm pelo data-channel UDP. Headers de 20 bytes (prot_udp).
Remontagem: `scripts/utils/extract_mitm_video_udp.py`.

## Resumo dos gaps atuais do fake server

| Passo | Cloud real | Fake server | Status |
|---|---|---|---|
| Provisionamento HTTP | binds, retorna userInfo_state:1 | ✅ implementado | OK |
| MQTT subscribe/pub | tópicos `Info`/`Status`/`sub` | ✅ | OK |
| Comando 216 (NTP) | ✅ | ✅ | OK |
| **Comando 249 (storage)** | ✅ | ✅ (`v720_http.py`) | OK |
| Comando 240 (abrir canal) | ✅ | ✅ | OK |
| Canal 29940 handshake 101/11/53/298/4/3 | ✅ | ✅ (proativo) | OK no relay público |
| Stream MJPG/G711 | ✅ | ✅ (relay público) | OK |

> O canal `29940` **não abre com o fake em IP local** (AP isolado). Destravado quando o
> fake roda num **IP público** (relay) — ver [achados_fakeserver_relay](achados_fakeserver_relay.md).

## Pendências

1. **Comando 249** — ✅ implementado (`v720_http.py`, entre `216` e `240`).
2. **Abrir o canal 29940** — ✅ no relay público; ❌ em IP local (fake em AP isolado).
3. **Se ainda não manter** (em IP local), capturar o fluxo REAL no momento exato do viewer (arpspoof na NET_2GB + abrir frame) e comparar byte a byte o handshake.