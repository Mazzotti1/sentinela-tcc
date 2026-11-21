# Achados — OTA / firmware — testado, não explorável por DNS/rota

Teste do vetor mapeado em [proximos_passos](proximos_passos.md): se um atacante que
controla o DNS/rota da câmera consegue entregar **firmware falso** e ter o update
aceito sem verificação de assinatura.

Câmera Naxclow Y2SN, firmware `202601081657`, `devicesCode 5c001502B330`. Ambiente
controlado — câmera e servidores próprios. Executado em 2026-11-21 no macOS (`en0`).

> **Resultado: negativo para o atacante de DNS/rota.** A câmera **recebe** `ota_url` e
> `ota_version` do servidor falso e **ignora os dois** — não tenta baixar nada. O update
> é orquestrado pelo **cloud via HTTPS autenticado**, não pela câmera. Explorar o OTA
> exigiria comprometer o cloud do fabricante ou a CA do celular, não apenas desviar o DNS.

## Setup

`mitm_dns.sh up` com o OTA ligado (`OTA_URL`/`OTA_VERSION`), ARP spoof + `dns_spoof`
na câmera, e o fake anunciando:

```
ota_url:     http://192.168.0.47/fw_test.bin    (1 MiB aleatório, não é firmware)
ota_version: 999999999                          (muito acima de 202601081657)
```

## Sequência observada (câmera → fake)

```
DNS   v720.naxclow.com       -> 192.168.0.47        (spoof OK)
DNS   v720.p2p.naxclow.com   -> 192.168.0.47        (spoof OK)
HTTP  POST getDevInfo        -> 192.168.0.47:80     (takeover OK)
       resposta: {"ota_url":"http://.../fw_test.bin","ota_version":"999999999", ...}
MQTT  216 -> 249 -> 240 publicados; câmera conecta no broker e publica Device/Info
```

A câmera **aceitou** o cloud falso (como nos outros vetores), mas:

```
GET /fw_test.bin            -> NENHUM (0 requisições)
GET getA9ConfCheck          -> NENHUM (0 chamadas)
version no Device/Info      -> 202601081657 (inalterada)
```

## Por que não baixou: o update é do app, via HTTPS

Análise do app oficial **V720 3.3.0** (decompilado):

| Endpoint | Método | Papel |
|---|---|---|
| `app/api/SysDevicesVersion/getNewVersion?devicesCode=` | GET | checa se há update (`DeviceVersionBean`: `versionId`, `update`, `isOpen`) |
| `app/api/SysDevicesVersion/mdfDevVersion?devicesCode=&versionId=` | POST | **ordena** o update |
| `app/api/SysDevicesVersion/cancelUpdate?devicesCode=` | POST | cancela |

Fluxo: `DeviceInfoActivity` → `getNewVersion` → se `data.update == true` abre
`DeviceUpdateMdfActivity` → `mdfDevVersion` → **o cloud** serve o firmware para a câmera.

Dois pontos que fecham o vetor:

1. **O app usa HTTPS.** O host principal é `https://v720.naxclow.com/` (`OkHttp3Manager`,
   `IHttpService.HOST_URL`). Desviar o DNS do celular não basta: o TLS falha contra um
   fake HTTP, e só um atacante que controle certificado/CA (ou o cloud) passaria.
2. **Não existe comando MQTT de update.** Nada relacionado a OTA apareceu no `mqtt.log`,
   e o APK não tem caminho MQTT para firmware — a orquestração é toda HTTP no cloud.

## Contraste relevante para o TCC

O mesmo trabalho provou que o canal **câmera↔cloud** é HTTP em claro, sem autenticação,
e por isso totalmente falsificável. O canal **app↔cloud**, que protege o OTA, é HTTPS.
É uma assimetria de projeto: a superfície de mídia/controle é aberta, mas a de firmware
não cai com o mesmo ataque.

## O que isso significa

| Vetor | Resultado |
|---|---|
| Firmware falso via DNS/rota | ❌ não explorável (câmera ignora `ota_url`; update vem do cloud por HTTPS) |
| Firmware falso com comprometimento do cloud | fora do escopo (exigiria a chave do fabricante) |
| Firmware falso com CA instalada no celular | fora do escopo (interceptação TLS, não este vetor) |

## Correção de documentação

Uma versão anterior deste plano dizia "servir um `ota_url` pelo fake e ver se a câmera
aceita update sem assinatura". O teste mostrou que **o `ota_url` é campo morto neste
firmware**: a câmera não é quem inicia o update. A hipótese correta (update orquestrado
pelo app/cloud via HTTPS) está registrada aqui.

## Ferramentas usadas

- `scripts/mitm_dns/mitm_dns.sh` com `OTA_URL`/`OTA_VERSION` (repassadas ao fake).
- `docs/runbook_ota.md` — passo a passo do teste.
- `apk_v720/V720_3.3.0_APKPure.xapk` — decompilado com `jadx` para mapear o fluxo.
