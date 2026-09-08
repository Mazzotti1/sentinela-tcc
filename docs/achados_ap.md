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

Ainda não testados: `-f` (lista SD), `-d` (baixa gravação), `-i`/`-r` (IR/flip), `-s` (fake server, ataque remoto — cenário diferente).

## Vulnerabilidades (mapa OWASP IoT)

- **WiFi AP aberto sem senha** → I2
- **Token de autenticação hardcoded** (`"This is TEST token"`) → I1
- **Stream acessível sem autenticação** → I3

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

O acesso local sem auth é real e grave, mas exige **proximidade física** (alcance WiFi) e a câmera **em modo AP**. Numa câmera já em uso normal (modo STA, na WiFi de casa), esse vetor não se aplica direto — aí o alvo é o fake server (`-s`), que é ataque remoto e cenário separado.
