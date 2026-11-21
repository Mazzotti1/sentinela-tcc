# Runbook — OTA / firmware (testado: negativo)

> **Resultado (2026-11-21): não explorável por DNS/rota.** A câmera recebe `ota_url` +
> `ota_version` do fake e **ignora** — não baixa nada. O update é orquestrado pelo app/cloud
> via **HTTPS** (`getNewVersion` → `mdfDevVersion`). Achado completo em
> [`achados_ota.md`](achados_ota.md). Este runbook fica como reprodução do teste.

Cenário: câmera Naxclow Y2SN em uso normal (STA) na WiFi de casa. O fake server
anuncia uma URL de firmware (`ota_url`/`ota_version`) na resposta HTTP
`getDevInfo`. A pergunta do teste: ela verifica assinatura? Aceita binário arbitrário?

Firmware `202601081657`, `devicesCode 5c001502B330`.

## O que já está pronto (validado)

| Peça | Estado |
|---|---|
| `getDevInfo` devolve `ota_url` e `ota_version` | ✅ via env `OTA_URL` / `OTA_VERSION` |
| `getA9ConfCheck` devolve `updateUrl` e `version` | ✅ via as mesmas env |
| Fake serve arquivos de `static/` (`SimpleHTTPRequestHandler`) | ✅ validado (`GET /fw.bin` → 200) |
| `mitm_dns.sh` repassa as env de OTA ao fake | ✅ (só quando definidas) |
| Framing HTTP (`Content-Length` / CRLF extra) | ✅ corrigido — antes o JSON vinha truncado |

**O que falta descobrir (é o objetivo do teste):** o gatilho. Este firmware **não
chama `getA9ConfCheck`** (confirmado nos pcaps: só `getDevInfo`). Então o update
depende de um dos dois: (a) a câmera comparar `ota_version` com a sua própria no
`getDevInfo`, ou (b) o **app** mandar o comando de update pelo canal de controle.

## Ação sua (física)

1. Deixar a câmera **ligada** na WiFi de casa.
2. **Power cycle** (tirar da tomada e recolocar) quando eu pedir — é o que força
   ela a refazer o HTTP/MQTT contra o fake.

## Comandos (Mac — você roda o `sudo`)

Tudo em **uma linha** por comando, pra não quebrar na colagem.

**Firmware de teste:** já criado em `static/fw_test.bin` (1 MiB aleatório, não é
firmware real; está no `.gitignore`). SHA-256: `035a70d02183605d…1bbe9`.

**1. Subir o lab com OTA ligado** (repassa a URL e a versão pro fake):

```
cd ~/Documents/dev/git/sentinela && sudo OTA_URL="http://192.168.0.47/fw_test.bin" OTA_VERSION="999999999" CAM_IP=192.168.0.17 ./scripts/mitm_dns/mitm_dns.sh up
```

(o fake já escuta na `:80`, então a URL não precisa de porta)

**2. Power cycle na câmera** (você).

**3. Ver se ela pediu o firmware:**

```
cd ~/Documents/dev/git/sentinela && sudo ./scripts/mitm_dns/mitm_dns.sh logs server 0 | grep -iE "fw_test|getDevInfo|ota"
```

## O que aconteceu no teste (2026-11-21)

| Evidência | Resultado |
|---|---|
| `GET /fw_test.bin` no `server.log` | ❌ **nenhum** — não houve tentativa de download |
| `ota_url` na resposta do `getDevInfo` | ✅ entregue ao fake, campo devolvido |
| `getA9ConfCheck` chamado | ❌ 0 chamadas (este firmware só usa `getDevInfo`) |
| App V720 | "já está na versão mais recente" |

Conclusão: o `ota_url` é **campo morto** neste firmware. O app decide pelo endpoint
`SysDevicesVersion/getNewVersion`, que ele consulta por **HTTPS** direto no cloud.

## Caminho que NÃO funciona: spoofar o celular

Testado em análise: o app usa `https://v720.naxclow.com/`. Desviar o DNS do iPhone só
leva a um handshake TLS falho contra o fake HTTP. Precisaria de CA instalada no aparelho
(interceptação TLS), o que é outro vetor — não "servidor falso".

## Observações

- O `static/fw_test.bin` é **artefato de teste** (já no `.gitignore`), não
  firmware real. Não substituir por firmware de terceiros.
- O fake escuta em `0.0.0.0`, então a câmera alcança o Mac pelo IP da LAN.
- Se o firewall do macOS estiver ligado, ele bloqueia a câmera no `:80`.
- **Sem `dnat on` a câmera vai por IP fixo** (`43.242.130.61:80`) e o DNS spoof não a pega.
