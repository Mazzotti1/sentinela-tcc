# Achados — Controle de hardware pelo canal relay (sem MQTT, sem auth)

Teste do vetor pendente em [proximos_passos](proximos_passos.md): comandos que **não
obedecem por MQTT** (`212`, `216`, `201`, `205`, `208`, `210`) — a hipótese era que
trafegassem pelo **canal de relay** (`code 301`), não pelo tópico MQTT.

Câmera Naxclow Y2SN, firmware `202601081657`, `devicesCode 5c001502B330`.
Executado em 2026-11-21. Ambiente controlado.

> **Resultado: confirmado.** No canal relay a câmera **obedece** PTZ e LED, sem
> autenticação. Por MQTT esses comandos não têm efeito.

## Setup (sem app, sem celular)

O fake local (Mac) faz o papel do cloud: `getDevInfo` responde, e ele publica
`216 → 249 → 240` no MQTT. O `240` anuncia o relay na **VPS** (IP público), porque a
câmera só abre o canal de dados para endpoint público.

Topologia:

```
câmera → (ARP spoof) Mac   : getDevInfo + broker MQTT (controle)
câmera → VPS (137.131.132.251:29940) : canal de dados (relay)
```

Nada de app, celular ou 4G — o fake comandou o `240` sozinho.

## Armadilha encontrada: race no MQTT

Na primeira tentativa a câmera **não** abriu o canal. O fake publicava o `240` no mesmo
instante em que ela terminava o `getDevInfo` — antes de a câmera concluir o `SUBSCRIBE`.
Como o publish é **QoS 0**, a mensagem se perdeu.

**Fix operacional:** re-disparar o `getDevInfo` depois que a câmera já está conectada ao
broker:

```
curl -s -X POST "http://<mac>/app/api/ApiSysDevices/getDevInfo?devicesCode=5c001502B330"
```

Com isso o relay abriu na hora. (Corrigir no código: publicar com QoS 1, ou esperar o
`SUBSCRIBE` antes de publicar.)

## Como os comandos foram enviados

Endpoint do fake na VPS — `content.code` + campos do comando:

```
curl -s "http://127.0.0.1:8080/dev/5c001502B330/fwd?v=212&motorState=1"
```

O fake monta `{"code":301,"content":{"code":212,"motorState":1,"devTarget":"<uid>"}}`.

## Resultado

| Comando | Código | Payload | Efeito observado |
|---|---|---|---|
| PTZ (direita/esquerda/cima/baixo) | `212` | `motorState` `1`/`2`/`3`/`4`, `0` = parar | ✅ **a câmera gira** (confirmado visualmente) |
| LED EI | `220` | `ledEI` `0`/`1` | ✅ **LED apaga e acende** (confirmado visualmente) |
| Flip | `216` | `mirrorFlip` `2`/`3`/`0` | ecoado; efeito visual a confirmar |
| `speedGrade` | `201` | `speedGrade` | ecoado, sem efeito visível |
| `instLed` | `210` | `instLed` | sem eco, sem efeito (o correto é `220`/`ledEI`) |
| `apmode` | `208` | — | sem eco (AP real é via canal próprio, não comando) |
| `moveAlert` | `205` | `moveAlert` | sem eco (provável notificação push) |

## Como o PTZ realmente funciona: fluxo de pulsos, não um comando

Um `212` avulso move a câmera **um passo curtíssimo** (~poucos graus). O app oficial não
manda um comando por toque: enquanto o botão fica pressionado, ele **repete o
`motorState` a cada 80 ms** e, ao soltar, manda `motorState: 0` (parada).

Confirmado no APK (`UdpDeviceActivity.runMicTime`, `timer.schedule(..., 0L, 80L)`) e na
prática: para girar de verdade, é preciso emitir a sequência de pulsos e encerrar com a
parada. Um comando isolado parece "não funcionar" — mas funciona, só anda um passo.

Reprodução: [`scripts/mitm_dns/ptz.sh`](../scripts/mitm_dns/ptz.sh)

```bash
./scripts/mitm_dns/ptz.sh 1 6              # direita por 6s (na VPS)
./scripts/mitm_dns/ptz.sh 1 6 137.131.132.251:8080   # a partir do Mac
```

Isso tem implicação prática para o ataque: o atacante consegue **varrer o ambiente**
girando a câmera continuamente, não apenas dar toques.

## Detalhe importante: o `Device/Info` não reflete o motor

Após mover a câmera, o `Device/Info` continua com `motorStatus: 1`, `mirrorFlip: 0`,
`speedGrade: 0`. **Não usar o `Device/Info` como prova para PTZ/flip** — a prova é visual
(a câmera se move / o LED muda). Isso contraria o que se fazia para `ledEI` por MQTT, onde
o campo aparecia no `Info`.

## Por que isso importa

Os comandos de hardware que "não funcionavam" não estavam bloqueados — estavam no
**outro canal**. Isso fecha a lacuna: quem já conquistou a posição de cloud falso (DNS/
relay) controla **movimento, LED e imagem**, não só os comandos básicos do MQTT.

Como o canal relay é aberto (`code 100` aceito sem token), o conjunto todo continua sem
autenticação.

## OWASP IoT

| Achado | OWASP |
|---|---|
| Canal de controle (relay) sem autenticação | I1 / I3 |
| Movimento/PTZ controlável remotamente sem credencial | I3 |
| LED do status apagável (esconde atividade) | I3 |

## Reprodução

1. `./scripts/mitm_dns/ota_up.sh up` (fake local anunciando o relay da VPS).
2. `./scripts/mitm_dns/ota_up.sh dnat on` + power cycle na câmera.
3. Esperar o `getDevInfo`; depois re-disparar o `getDevInfo` (race do `240`).
4. Confirmar `curl -s http://<vps>:8080/dev/list`.
5. Enviar movimento contínuo: `./scripts/mitm_dns/ptz.sh 1 6` (na VPS).
6. LED: `curl -s "http://<vps>:8080/dev/<uid>/fwd?v=220&ledEI=0"`.
