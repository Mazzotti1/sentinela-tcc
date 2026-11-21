# Achados finais — consolidação (OWASP / CVSS)

Documento de **fechamento**: consolida, num só lugar, todos os vetores testados, as
evidências de cada um, o mapa **OWASP IoT** e a proposta de **CVSS**. O detalhe de cada
vetor continua nos `achados_*.md` (links na tabela de vetores). É a base para transcrever
no documento formal do TCC e montar a apresentação parcial.

Alvo: câmera **Naxclow Y2SN** (vendida como "V720"), firmware `202601081657`,
`devicesCode 5c001502B330`, app oficial **V720**. Ambiente controlado — câmera e
servidores próprios.

> **Status:** todos os vetores planejados foram **executados**. Os resultados dos três
> últimos testes (2026-11-21) estão no fim do documento; os vetores que não se aplicam
> estão em [Testado e descartado](#testado-e-descartado).

## Modelo de ameaça — posição do atacante

O mesmo defeito-raiz (a câmera **confia em qualquer servidor que se diga cloud**, sem
autenticar e sem criptografar) é explorável de **posições de ataque diferentes**. Os
vetores se distinguem pelo pré-requisito do atacante, não pela falha.

| Vetor | Posição do atacante | Pré-requisito | O que prova | Doc |
|---|---|---|---|---|
| Hotspot AP da câmera | alcance WiFi, câmera em modo config | rede AP aberta | stream local + token hardcoded | [achados_ap](achados_ap.md) |
| MITM STA (ARP spoof) | mesma LAN | mesma rede da vítima | leitura em claro + stream (UDP) | [achados_sta](achados_sta.md) |
| Canal de controle MQTT | mesma LAN ou posição de cloud falso | broker aceitando o cliente (o broker real **recusa anônimo**, `CONNACK 5`) | comandos de hardware sem credencial | [achados_mqtt](achados_mqtt.md) |
| Fake server via DNS | controla DNS/rota | desviar `*.naxclow.com` | takeover do cloud (controle total); no lab, atacante = gateway | [achados_fakeserver](achados_fakeserver.md) |
| MITM STA + DNS spoof | mesma LAN, gateway alheio | ARP poison na LAN | vira o cloud a partir da LAN | [runbook_mitm_dns](runbook_mitm_dns.md) |
| Relay público (VPS) | redireciona o relay | VPS com IP público + desviar rota/DNS (no lab: ARP+DNAT na LAN) | **vídeo + áudio** no servidor do atacante | [achados_fakeserver_relay](achados_fakeserver_relay.md) |
| Evil twin (deauth + clone) | AP clone da rede da vítima, no alcance | proximidade + deauth + **credenciais da rede** (ou handshake quebrado) | câmera migra sozinha pro AP do atacante → controle (LED/`setwifi`) + **vídeo** (relay na VPS) | [achados_evil_twin](achados_evil_twin.md) |

## Vetores provados

**1. Hotspot AP (acesso local sem auth).** A câmera, em modo de configuração, abre uma
rede WiFi **sem senha** e serve o protocolo na LAN dela (`192.168.169.1:6123`) com token
de autenticação **hardcoded** (`"This is TEST token"`). Conectado na rede, obtém-se o
stream ao vivo sem login. Além do stream, **lista e baixa as gravações do cartão SD** sem
login (`-f`/`-d`/`--dump`, codes `400`–`407`). Evidência: `src/v720_ap.py`, `prot_ap.py`
(fixes de firmware); `achados_ap.md`.

**2. MITM STA (escuta em claro).** Outro device na mesma LAN (ARP spoof com ettercap)
intercepta todo o tráfego câmera↔cloud. Vazam em claro: **token MQTT**, **SSID** da
vítima, **devicesCode**, versão, e os comandos. O stream de vídeo trafega sem
criptografia e é **reconstruível** por um terceiro. Evidência: `cam_mitm.pcap` (control
channel) + remontagem (`extract_mitm_video.py` / `extract_mitm_video_udp.py`) em
`mitm_out/`; `achados_sta.md`.

**3. Canal de controle MQTT (sem credencial).** O tópico
`Naxclow/P2P/Users/Device/sub/<devicesCode>` aceita **qualquer JSON** publicado sem
autenticação. Comandos obedecem: `wifiscan` (211), `record` (209), `ledei` (220),
`setwifi` (204), `format` (207), `reboot` (299). Evidência: `achados_mqtt.md`.

**4. Fake server via DNS (takeover do cloud).** Com o controle de DNS/rota, a câmera
registra num servidor do atacante e obedece comandos de hardware **sem app e sem
credencial**. No lab, o atacante foi o **gateway** da câmera (AP isolado); o caso remoto
depende de desviar o DNS da vítima de fora. Evidência: `achados_fakeserver.md`.

**5. MITM STA + DNS spoof (takeover a partir da LAN).** O mesmo takeover do item 4,
reproduzido por um adversário na mesma WiFi (ettercap `dns_spoof` + ARP poison). Mesmo
achado, posição de ataque mais fraca. Evidência: `runbook_mitm_dns.md`.

**6. Relay público (espionagem de mídia).** Rodando o fake num **IP público**
(VPS) e desviando o relay (`29939`–`29942`, TCP+UDP), a câmera se registra no relay do
atacante e entrega **vídeo + áudio**, sem app e sem credencial. No lab o desvio foi feito
por **ARP spoof + DNAT na LAN**; o caso remoto exige controlar a rota/DNS do relay. Este é o
vetor de maior impacto. Evidência: `achados_fakeserver_relay.md`.

**7. Modo combinado — controle + stream na mesma sessão.** Subindo broker, HTTP e relay na
**VPS** e redirecionando a câmera pra ela, a mesma sessão entrega **controle** (`ledei`,
`setwifi`) e **vídeo** (640×480 JPEG). Foi o que fechou o antigo bloqueio "a câmera não abre
o canal": o `240` do fake omitia **`tcpPort`** e **`uid`**, e a captura do `240` real revelou
os campos (`errStatus 2` → `errStatus 0`). Evidência: `runbook_mitm_dns.md` (seção *Modo
combinado*) e o fix em `src/v720_http.py`.

**8. Evil twin com vídeo (deauth + clone + relay na VPS).** O clone do AP (mesmo SSID/senha)
mais **deauth** faz a câmera migrar sozinha pro AP do atacante; com o fake local pro
controle/DNS e o relay anunciado na **VPS**, o `/live` rende **vídeo (JPEG 640×480)** e o
controle responde (`ledEI`). Evidência: `achados_evil_twin.md`.

## Vulnerabilidades (OWASP IoT)

| Achado | Evidência | OWASP |
|---|---|---|
| Sem validação de servidor (aceita qualquer "cloud" via DNS/rota) | câmera registra no fake só por DNS override | **I2 / I7** |
| Relay sem autenticação | câmera conecta num relay em IP público arbitrário | **I2 / I7** |
| Canal de controle sem auth (MQTT e relay) | `mosquitto_pub` / `code 100` aceitos sem token | **I1 / I3** |
| Sem criptografia (HTTP:80, MQTT:1883, relay TCP/UDP) | tudo em claro no pcap | **I5** |
| Token/credencial exposto em claro | `token:530012ec16` interceptado | **I1 / I6** |
| Vazamento de dados sensíveis (`wifiName`, `devicesCode`, versão) | MQTT `Device/Info` em claro | **I6** |
| Gravações do SD listáveis/baixáveis sem auth | `-f`/`-d`/`--dump` no AP | **I3 / I6** |
| Takeover remoto de hardware | `reboot` / `format` / `setwifi` / IR via MQTT | **I3** |
| Espionagem remota de mídia (vídeo + áudio) | stream no relay do atacante, sem app | **I3 / I5** |
| Sequestro de rede | `code 204` reconecta a câmera noutra rede | **I2** |
| `wifiscan` vaza SSIDs vizinhas | `scanWifiBase64` no MQTT | **I6** |
| `ledei off` esconde atividade sem parar gravação | LED apagado, gravação mantida | **I3** |
| WiFi AP aberto sem senha | rede `Nax_XXXXXX` sem chave | **I2** |
| Câmera associa a clone do AP da vítima | `Station 5c:f1:50:04:af:8a` no clone; `wifiName` inalterado | **I2** |
| Token de autenticação hardcoded | `"This is TEST token"` no código | **I1** |
| MITM na LAN não detectado | ARP spoof sem alerta da câmera | **I2 / I5** |
| Registro P2P sem credencial | `code 100` aceito sem token | **I1 / I3** |

## CVSS 3.1 — proposto (a validar)

Os vetores compartilham o mesmo impacto (confidencialidade + integridade + disponibilidade
totais do dispositivo). O que muda é o **AV** (vetor de ataque), pela posição do atacante.
Proposta inicial — **revisar com a orientação do TCC**.

| Vetor | AV | Justificativa | Base (proposta) |
|---|---|---|---|
| Fake server via DNS / Relay público | `AV:N` | **hipótese** de pré-requisito: se o atacante já controla o DNS/rota, não precisa estar perto. **No lab foi executado como `AV:A`** (atacante = gateway do AP isolado, ou ARP+DNAT na LAN) | **9.8 (Crítico)** — a revalidar com o AV real |
| MITM STA + DNS spoof | `AV:A` | exige estar na mesma LAN/segmento | **8.8 (Alto)** |
| Hotspot AP da câmera | `AV:A` | exige alcance do rádio + câmera em modo config | **8.8 (Alto)** |
| Evil twin (deauth + clone) | `AV:A` / `AC:H` | exige proximidade + deauth e timing; a rede clonada usa SSID/senha reais (ou handshake quebrado) | **7.5 (Alto)** |

Componentes comuns: `PR:N/UI:N/S:U/C:H/I:H/A:H` (o evil twin sobe o `AC` para `H`, por
depender de deauth/timing).

> **Ressalva de honestidade do CVSS:** todos os vetores foram executados com o atacante
> **na LAN ou ao alcance do rádio**. O `AV:N` do fake server/relay é a **nota do cenário
> remoto hipotético** (atacante que controla DNS/rota de fora), não uma medição de
> laboratório. Separar os dois na escrita do TCC: o que foi provado (`AV:A`) e o que o
> pré-requisito permite inferir (`AV:N`).

> **Comandos MQTT (`setwifi`, `format`, `reboot`, IR, LED) — não é vetor remoto autônomo.**
> O broker real **recusa acesso anônimo** (`CONNACK 5`, testado 2026-11-02) — ver
> [achados_mqtt](achados_mqtt.md). O controle de hardware é exercido **na posição** já
> conquistada pelo fake server (DNS → `AV:N`) ou pelo MITM STA (credenciais vazam em claro
> → `AV:A`). O impacto (controle total + **sequestro de rede/persistência** via `setwifi`)
> já está contemplado nas notas acima; o `setwifi` **não** sobe a nota por si — ele
> **pressupõe** uma dessas posições.

## Últimos testes (2026-11-21) — nada em aberto

Todos os vetores planejados foram executados. Resultados dos três últimos:

| Item | Resultado | Onde |
|---|---|---|
| OTA / firmware | ❌ **negativo** — a câmera ignora `ota_url`/`ota_version`; o update é do cloud via HTTPS | [achados_ota](achados_ota.md) |
| Controle pelo canal relay | ✅ **positivo** — PTZ `212` e LED `220` funcionam (pulsos a 80 ms); `201`/`205`/`208`/`210` ecoados sem efeito | [achados_relay_controle](achados_relay_controle.md) |
| IR/flip no modo AP | ✅ **positivo** — `-i`/`-r` no envelope `502` | [achados_ap_ir_flip](achados_ap_ir_flip.md) |

> **Descartado por escopo:** SD via app/cloud (exigiria CA no iPhone) e hardware drop
> (apenas modelo de ameaça, em [conceito_hardware_drop](conceito_hardware_drop.md)).

> O antigo bloqueio "stream não fecha em IP local" **não é mais pendência**: era só a falta
> de um endpoint **público** e do `tcpPort`/`uid` no `240`. Resolvido no modo combinado e no
> evil twin — ver [achados_fakeserver](achados_fakeserver.md),
> [achados_fakeserver_relay](achados_fakeserver_relay.md) e
> [achados_evil_twin](achados_evil_twin.md). Esse limite continua valendo apenas para o fake
> em **IP local/AP isolado** (a câmera só abre o canal pra endpoint público).

### Testado e descartado

| Item | Resultado | Evidência |
|---|---|---|
| SD pelo relay (sem modo AP) | **Negativo** — a câmera ignora as ops de SD (`400/402/404/406`) no envelope `301`; só responde no `502` (AP) | [achados_sd_relay](achados_sd_relay.md) |
| OTA / firmware por DNS/rota | **Negativo** — a câmera recebe `ota_url`/`ota_version` do fake e ignora; o update é orquestrado pelo cloud via HTTPS | [achados_ota](achados_ota.md) |

## Índice de evidências

| Evidência | Onde |
|---|---|
| Achados por vetor | `docs/achados_ap.md`, `achados_ap_ir_flip.md`, `achados_sta.md`, `achados_mqtt.md`, `achados_fakeserver.md`, `achados_fakeserver_relay.md`, `achados_relay_controle.md`, `achados_evil_twin.md`, `achados_sd_relay.md`, `achados_ota.md` |
| Protocolo (payloads, portas, handshake) | `docs/protocolo_naxclow.md` |
| Runbooks de execução | `docs/runbook_fakeserver_ap.md`, `runbook_mitm_dns.md` |
| Remontagem de mídia | `scripts/utils/extract_mitm_video.py`, `extract_mitm_video_udp.py` |
| Ferramentas | `src/a9_naxclow.py`, `scripts/mitm_dns/mitm_dns.sh`, `scripts/fakeserver/`, `src/v720_hls.py` |
| Capturas/artefatos (fora do repo, por tamanho/dados sensíveis) | `apk/`, `results/`, `docs/mitm_dns_out/`, `*.pcap` |

## Conclusão

A câmera **não autentica o servidor e não criptografa nada**, o que permite (a) **assumir
o controle** do hardware sem credencial e (b) **espionar** o stream de vídeo/áudio — a partir
da LAN (MITM/DNS), por proximidade (AP aberto, evil twin) ou desviando o cloud/relay (fake
server) — e (c) **extrair as gravações** do cartão SD por proximidade (AP aberto).

O ponto de virada do trabalho foi o vetor do **relay em IP público**: destravou a mídia
remota de ponta a ponta. Depois dele, o **modo combinado** (controle + stream) e o
**evil twin com vídeo** fecharam o antigo bloqueio do canal de dados. Os últimos testes
fecharam o controle de hardware: **PTZ e LED pelo canal relay** e **IR/flip no AP** —
todos sem autenticação.

> **Assimetria final:** os canais câmera↔cloud (HTTP/MQTT/relay) são abertos e por isso
> totalmente controláveis por um atacante que desvie DNS/rota. O único caminho que resiste
> é o **app↔cloud do OTA**, que usa HTTPS — e por isso o firmware falso não cai com o mesmo
> ataque. Ver [achados_ota](achados_ota.md).
