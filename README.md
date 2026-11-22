# Sentinela

Ferramenta de verificação de segurança de câmeras IP **Naxclow Y2SN** (V720).

Roda como um CLI único: sem argumentos mostra o banner e um menu navegável por
setas; com um cenário roda direto. Cada cenário sobe o que precisa, indica o que
fazer fisicamente na câmera, espera, valida e grava as evidências.

```
./sentinela                  menu interativo (banner + setas)
./sentinela --list           lista os cenários
./sentinela info             diagnóstico read-only
./sentinela ap               câmera em modo AP
./sentinela mitm             interceptação na LAN
./sentinela dns              fake server + takeover
./sentinela relay            controle + vídeo remoto (VPS)
./sentinela evil-twin        AP clone + deauth (Kali)
./sentinela down             derruba o laboratório
```
<img width="587" height="657" alt="Captura de Tela 2026-11-21 às 18 12 32" src="https://github.com/user-attachments/assets/f2a1ad75-6abd-4d5e-88a3-cb4a7189882e" />

## Servidor MCP (para agentes de IA)

Expõe as mesmas capacidades como ferramentas MCP, para agentes (Claude, Cursor,
Zed) executarem e consultarem a pesquisa.

```bash
./sentinela-mcp              # servidor JSON-RPC sobre stdio
```

Registro e catálogo de ferramentas: **[docs/mcp.md](docs/mcp.md)**. As
ferramentas ativas exigem `confirm: true` — o consentimento é do operador, não
do agente.

## Cenários

| Cenário | O que prova | Precisa |
|---|---|---|
| `info` | diagnostica o ambiente (não altera nada) | — |
| `ap` | acesso local sem autenticação: stream, SD, IR, flip | câmera em modo AP |
| `mitm` | tráfego em claro na LAN + vídeo reconstruível | mesma LAN |
| `dns` | a câmera aceita um cloud falso (takeover) | mesma LAN, `sudo` |
| `relay` | controle e vídeo remotos, fora da LAN | VPS com IP público |
| `evil-twin` | migra para AP clonado após deauth | Kali + dongle |

Cada execução grava `results/<cenário>_<data>/` com `report.md` e os artefatos
(pcap, vídeo, logs). O código de saída é 0 quando provado, 1 quando falhou.

## Instalação

```
pip3 install -r requirements.txt
brew install ettercap mosquitto        # macOS
```

Nas opções que precisam de root (`mitm`, `dns`, `relay`, `down`), a ferramenta
pede `sudo` no momento certo.

## Estrutura

```
sentinela                entry point da CLI
sentinela-mcp            entry point do servidor MCP

mcp_server/
  server.py              JSON-RPC 2.0 sobre stdio, sem dependencias

sentinela_cli/           a ferramenta
  main.py                CLI, banner, menu e dispatch
  menu.py                menu de setas (sem dependências externas)
  ui.py                  banner ASCII e tema
  core.py                execução, rede, evidência, pausas físicas
  scenarios/             os cenários (um módulo)

src/                     protocolo e fake server (Python)
  a9_naxclow.py          CLI do protocolo (-l, -s, -f, -d, -i, -r, --dump)
  v720_ap.py             cliente do modo AP
  v720_sta.py            servidor falso: canal relay TCP/UDP
  v720_http.py           HTTP do servidor falso
  prot_*.py              framing (header de 20 bytes) e envelopes
  cmd_udp.py             códigos de comando
  netcl*.py, netsrv*.py  camada de rede
  v720_hls.py            JPEG -> HLS (ffmpeg)

scripts/                 os laboratórios (bash), usados pelos cenários
  mitm_dns/              ARP/DNS spoof, DNAT, ota_up.sh, ptz.sh, ap_ir_flip.sh
  mitm/                  mitm_auto.sh, capture_stream.sh, p2p_probe.sh
  fakeserver/            fakesrv_lab.sh, fake_srv_cmd.sh
  ap_atacante/           AP do atacante no dongle (Kali)
  take3/                 relay na VPS
  utils/                 extração de vídeo/credenciais

docs/                    achados_*.md (evidências por vetor)
                         ferramenta.md (manual da CLI)
                         mcp.md (integração com agentes de IA)
                         protocolo_naxclow.md (referência)
                         runbook_*.md (passo a passo manual)

assets/                  logo (png e arte ASCII)
```

## Documentação

- `docs/ferramenta.md` — manual de uso, cenário por cenário
- `docs/achados_finais.md` — consolidação (OWASP/CVSS, provado vs. descartado)
- `docs/tcc_resumo.md` — resumo em linguagem simples
- `docs/proximos_passos.md` — estado do laboratório e armadilhas
- `docs/protocolo_naxclow.md` — referência do protocolo

## Aviso

Ambiente controlado, com equipamento próprio. Testar câmeras ou redes de
terceiros é crime.
