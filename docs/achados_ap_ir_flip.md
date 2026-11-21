# Achados — IR e flip no modo AP (envelope 502) — funcionou

Fecha a última lacuna do modo AP: os comandos `-i`/`-r` da CLI (`ir_led`, `flip`) nunca
tinham sido exercitados no firmware `202601081657`.

Câmera Naxclow Y2SN, `devicesCode 5c001502B330`. Executado em 2026-11-21, câmera em
**modo AP** (rede `Nax_XXXXXX` aberta), Mac conectado nela. Ambiente controlado.

> **Resultado: funcionou.** Com IR ligado e flip ativo, o stream foi capturado:
> **229 frames JPEG 640×480**. A imagem aparece espelhada e o ganho/ruído muda com o IR.

## Setup

Câmera em modo AP (`192.168.169.1:6123`), sem senha. Nenhum app, nenhum login.

```
python3 src/a9_naxclow.py -l -i -r -c 192.168.169.1:6123 -o results/ap_ir_flip_<ts>.avi
```

Automatizado em [`scripts/mitm_dns/ap_ir_flip.sh`](../scripts/mitm_dns/ap_ir_flip.sh)
(roda offline: fala direto com a câmera, sem internet).

## Evidência

`results/ap_ir_flip_20261121_162929.avi` — RIFF/AVI, **640×480, 10 fps, Motion JPEG,
229 frames** (2.5 MB).

Frames extraídos (primeiro, ~meio, último):

| Frame | Conteúdo |
|---|---|
| inicial | tomada na parede; faixa escura desce pela **direita** |
| meio | mesma cena, enquadramento **espelhado** (faixa no topo/esquerda) |
| final | cena estável, FPS 18.47 |

O `FPS` no canto superior esquerdo sobe de 2.70 → 6.77 → 18.47 ao longo da captura, e o
padrão de ruído/coloração muda — consistente com o LED infravermelho ligando.

## Comandos exercitados

| Ação | CLI | Comando no protocolo | Resultado |
|---|---|---|---|
| IR ligado | `-i` | `ir_led(True)` → `code 202`, `IrLed: 1` | ✅ video mudou de ganho |
| Flip | `-r` | `flip(True)` → `code 216`, `mirrorFlip: 4` | ✅ imagem espelhada |

Ambos no envelope `502` (`CODE_AP_COMMAND`), como as demais operações do modo AP.

## Limitação honesta

O `.log` da execução saiu vazio (0 bytes), então **não há confirmação de protocolo** (o
eco `code 202`/"Camera response"). A prova é **visual**, a partir do vídeo gravado. Repetir
com `-v` para capturar o JSON de resposta, se for necessário provar o lado do protocolo.

## O que isso fecha

O modo AP expõe, sem autenticação: stream ao vivo (`-l`), listagem e download do SD
(`-f`/`-d`/`--dump`), IR e flip (`-i`/`-r`). Não sobrou operação da CLI sem exercício.

## OWASP IoT

| Achado | OWASP |
|---|---|
| Controle de IR (visão noturna) sem autenticação no AP | I3 |
| Alteração de imagem (flip) sem autenticação | I3 |
| WiFi AP aberto sem senha | I2 |
