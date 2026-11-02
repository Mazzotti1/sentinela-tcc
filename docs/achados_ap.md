# Achados — Modo AP (câmera Naxclow Y2SN)

Notas de organização. Firmware `202601081657`, app V720, ferramenta a9-v720.

## O que é o AP hotspot

A câmera cria a própria rede WiFi (`Nax_XXXXXX`, **sem senha**). Vira um roteador: quem conecta cai na LAN dela (`192.168.169.x`, câmera em `192.168.169.1:6123`). É o modo de configuração inicial — o app se conecta assim antes de jogar a câmera na WiFi de casa.

Problema: enquanto está em AP, qualquer um no alcance do WiFi entra sem senha e já fala o protocolo da câmera direto.

## O que conseguimos

| Teste | Comando | Resultado |
|---|---|---|
| Stream ao vivo | `python3 src/a9_naxclow.py -l -o stream.avi` | ✅ intercepta o vídeo que a câmera grava **agora**, só por estar na WiFi dela. Sem login. |
| Conexão TCP | — | Aceita token literal `"This is TEST token"`, hardcoded. Sem auth real. |

Testados: `-l` (stream), `-f` (lista SD), `-d` (baixa gravação) e `--dump` (baixa todas as gravações). Não testados aqui: `-i`/`-r` (IR/flip) e `-s` (fake server, cenário diferente).

## Extração do cartão SD — gravações sem autenticação

Conectado na rede AP aberta, além do stream ao vivo, dá para **listar e baixar as gravações do cartão SD** sem nenhum login. Testado em 2026-11-01 (firmware `202601081657`).

**O que a câmera expõe** (resposta ao `baseinfo`, code 4): `sdDevStatus: 1`, `sdCapacity: 94` (cartão presente). Sem cartão vinha `0`/`0`.

**Execução** (Mac conectado na rede `Nax_XXXXXX`, câmera em `192.168.169.1:6123`):

- `python3 src/a9_naxclow.py -f` — lista datas/horas/minutos e o tamanho de cada segmento.
- `python3 src/a9_naxclow.py -d <data-hora> -o <arquivo>.avi` — baixa um segmento.
- `python3 src/a9_naxclow.py --dump -o results/sdcard_dump` — baixa **todas** as gravações (varre datas → horas → minutos, pulando segmentos vazios).

**Amostra capturada** (data `20261101`):

| Segmento | fileName | Tamanho |
|---|---|---|
| 20:00 | `202611012000` | 10.519.764 B (~10,5 MB) |
| 20:01 | `202611012001` | 1 B (vazio — pulado) |
| 20:02 | `202611012002` | 9.526.968 B (~9,5 MB) |

O download sai como `.avi` (MJPG) válido, **sem credencial**.

**Protocolo usado (o mesmo P2P da câmera).** Frames com header de **20 bytes** (little-endian): `len(4) cmd(2) msg_flag(1) deal_flag(1) forward_id(8) pkg_id(4)` + payload. No modo AP o comando vai no envelope JSON `{"code":502,"content":{...}}` (`CODE_AP_COMMAND`); as operações de SD são códigos dentro do `content`:

| Op | code | Resposta | Conteúdo |
|---|---|---|---|
| Lista de datas | `400` | `401` | `dates: [...]`, `dateNum` |
| Catálogo do dia | `402` | `403` + XML `cmd=8` | `<video><catalogue hours minBin>` (bitmap de minutos) |
| Info do segmento | `404` | `405` | `fileSize`, `fileName` |
| Iniciar stream | `406` | `407` | payload `cmd=7` (AVI) no canal |
| Parar stream | `408` | `409` | — |

**Limite:** o protocolo só expõe o **catálogo de vídeo** — não há comando de listar/baixar arquivos arbitrários do SD (fotos, config, etc.). É dump de gravações, não do sistema de arquivos.

**Fixes de firmware necessários** (este caminho nunca tinha sido testado no `202601081657`):
1. `_json_req` / `filename_list` passaram a **drenar frames de mídia** até a resposta JSON/XML (o firmware manda vídeo/áudio intercalado desde a conexão).
2. `sdcard_status` não estoura mais `KeyError` se faltar `sdDevStatus`.
3. `download` / `get_file` param pelo **tamanho esperado** (`fileSize`), filtram JSON/XML do stream e truncam ao tamanho exato (evita loop por heartbeat e arquivo contaminado).
4. `_json_req` casa o **código de resposta** esperado (400→401, 402→403, 404→405, 406→407) — sem isso, o frame de fim-de-stream de um arquivo dessincronizava o próximo no `--dump`.

**OWASP IoT:** gravações acessíveis sem autenticação → **I3** (Insecure Ecosystem Interfaces) + **I6** (privacidade — exposição de mídia gravada).

> **Desdobramento possível (não testado):** as mesmas operações de SD (códigos `400`–`407`) também podem trafegar no **canal relay/fake server** (envelope de forward `code:301` em vez de `502`), o que permitiria exfiltrar gravações **remotamente, sem modo AP** — reusando a infra do relay público. Mapeado, ainda não executado.

## Vulnerabilidades (mapa OWASP IoT)

- **WiFi AP aberto sem senha** → I2
- **Token de autenticação hardcoded** (`"This is TEST token"`) → I1
- **Stream acessível sem autenticação** → I3
- **Gravações do SD listáveis e baixáveis sem auth** → I3 / I6

## Quão fácil foi

Fácil, mas não out-of-the-box. Precisou de:

1. Estar na WiFi da câmera (trivial — rede aberta).
2. Rodar a ferramenta pública (a9-v720).
3. **Corrigir 3 bugs** porque o firmware é mais novo que o testado pelo repo (ver abaixo).

Sem os fixes, o script quebra antes de gravar. Com eles: stream contínuo até CTRL-C.

## Problemas encontrados (firmware novo quebrou o script)

1. **`baseinfo()` retorna None** — firmware novo responde comando com `{code,target,status}`, sem os campos `content`/`version` que o código antigo esperava. Crashava com `KeyError`.
   - Fix: null-checks em [v720_ap.py](../src/v720_ap.py) e [prot_ap.py](../src/prot_ap.py).

2. **Respostas dessincronizadas com o stream** — o firmware começa a mandar áudio/vídeo (cmd 6, PCM) assim que conecta. Os comandos JSON recebiam de volta frames de mídia em vez da resposta. Crashava `flip()`.
   - Fix: `_ap_req` agora drena frames de mídia até achar a resposta JSON de comando.

3. **Stream fechava sozinho após alguns segundos** — o loop mandava `ping()` manual a cada 5s, mas o `recv()` já responde heartbeat inline. Os pings extras floodavam a câmera → ela derrubava a conexão (viam-se 5 heartbeats seguidos no log antes do `Connection closed`).
   - Fix: removido o `ping()` manual do loop de vídeo.

4. Menor: `setDaemon()` (removido no Python 3.10+) em [a9_live.py](../src/a9_live.py) → trocado por `.daemon = True`.

## Conclusão rápida

O acesso local sem auth é real e grave, mas exige **proximidade física** (alcance WiFi) e a câmera **em modo AP**. Numa câmera já em uso normal (modo STA, na WiFi de casa), esse vetor não se aplica direto — aí o alvo é o fake server (`-s`), que é ataque remoto e cenário separado. Além do stream ao vivo, o acesso local sem auth também **extrai as gravações do SD** (`-f`/`-d`/`--dump`), sem login.
