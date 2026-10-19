# Achados finais — consolidação (OWASP / CVSS)

Documento de **fechamento**: consolida, num só lugar, todos os vetores testados, as
evidências de cada um, o mapa **OWASP IoT** e a proposta de **CVSS**. O detalhe de cada
vetor continua nos `achados_*.md` (links na tabela de vetores). É a base para transcrever
no documento formal do TCC e montar a apresentação parcial.

Alvo: câmera **Naxclow Y2SN** (vendida como "V720"), firmware `202601081657`,
`devicesCode 5c001502B330`, app oficial **V720**. Ambiente controlado — câmera e
servidores próprios.

> **Status:** os vetores abaixo estão **provados**. O que foi mapeado mas **ainda não
> testado** está isolado na seção [Pendente](#pendente--mapeado-e-não-testado), pra
> deixar claro o recorte da apresentação parcial.

## Modelo de ameaça — posição do atacante

O mesmo defeito-raiz (a câmera **confia em qualquer servidor que se diga cloud**, sem
autenticar e sem criptografar) é explorável de **posições de ataque diferentes**. Os
vetores se distinguem pelo pré-requisito do atacante, não pela falha.

| Vetor | Posição do atacante | Pré-requisito | O que prova | Doc |
|---|---|---|---|---|
| Hotspot AP da câmera | alcance WiFi, câmera em modo config | rede AP aberta | stream local + token hardcoded | [achados_ap](achados_ap.md) |
| MITM STA (ARP spoof) | mesma LAN | mesma rede da vítima | leitura em claro + stream (UDP) | [achados_sta](achados_sta.md) |
| Canal de controle MQTT | remoto | acesso ao broker | comandos de hardware sem credencial | [achados_mqtt](achados_mqtt.md) |
| Fake server via DNS | controla DNS/rota | desviar `*.naxclow.com` | takeover remoto (controle total) | [achados_fakeserver](achados_fakeserver.md) |
| MITM STA + DNS spoof | mesma LAN, gateway alheio | ARP poison na LAN | vira o cloud a partir da LAN | [runbook_mitm_dns](runbook_mitm_dns.md) |
| Relay público (VPS) | redireciona o relay | VPS com IP público | **vídeo + áudio** no servidor do atacante | [achados_fakeserver_relay](achados_fakeserver_relay.md) |

## Vetores provados

**1. Hotspot AP (acesso local sem auth).** A câmera, em modo de configuração, abre uma
rede WiFi **sem senha** e serve o protocolo na LAN dela (`192.168.169.1:6123`) com token
de autenticação **hardcoded** (`"This is TEST token"`). Conectado na rede, obtém-se o
stream ao vivo sem login. Evidência: `src/v720_ap.py`, `prot_ap.py` (fixes de firmware);
`achados_ap.md`.

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

**4. Fake server via DNS (takeover remoto).** Com o controle de DNS/rota, a câmera
registra num servidor do atacante e obedece comandos de hardware **sem app e sem
credencial**. Evidência: `achados_fakeserver.md`.

**5. MITM STA + DNS spoof (takeover a partir da LAN).** O mesmo takeover do item 4,
reproduzido por um adversário na mesma WiFi (ettercap `dns_spoof` + ARP poison). Mesmo
achado, posição de ataque mais fraca. Evidência: `runbook_mitm_dns.md`.

**6. Relay público (espionagem remota de mídia).** Rodando o fake num **IP público**
(VPS) e desviando o relay (`29939`–`29942`, TCP+UDP), a câmera se registra no relay do
atacante e entrega **vídeo + áudio** — remotamente, sem app e sem estar na LAN. Este é o
vetor de maior impacto. Evidência: `achados_fakeserver_relay.md`.

## Vulnerabilidades (OWASP IoT)

| Achado | Evidência | OWASP |
|---|---|---|
| Sem validação de servidor (aceita qualquer "cloud" via DNS/rota) | câmera registra no fake só por DNS override | **I2 / I7** |
| Relay sem autenticação | câmera conecta num relay em IP público arbitrário | **I2 / I7** |
| Canal de controle sem auth (MQTT e relay) | `mosquitto_pub` / `code 100` aceitos sem token | **I1 / I3** |
| Sem criptografia (HTTP:80, MQTT:1883, relay TCP/UDP) | tudo em claro no pcap | **I5** |
| Token/credencial exposto em claro | `token:530012ec16` interceptado | **I1 / I6** |
| Vazamento de dados sensíveis (`wifiName`, `devicesCode`, versão) | MQTT `Device/Info` em claro | **I6** |
| Takeover remoto de hardware | `reboot` / `format` / `setwifi` / IR via MQTT | **I3** |
| Espionagem remota de mídia (vídeo + áudio) | stream no relay do atacante, sem app | **I3 / I5** |
| Sequestro de rede | `code 204` reconecta a câmera noutra rede | **I2** |
| `wifiscan` vaza SSIDs vizinhas | `scanWifiBase64` no MQTT | **I6** |
| `ledei off` esconde atividade sem parar gravação | LED apagado, gravação mantida | **I3** |
| WiFi AP aberto sem senha | rede `Nax_XXXXXX` sem chave | **I2** |
| Token de autenticação hardcoded | `"This is TEST token"` no código | **I1** |
| MITM na LAN não detectado | ARP spoof sem alerta da câmera | **I2 / I5** |
| Registro P2P sem credencial | `code 100` aceito sem token | **I1 / I3** |

## CVSS 3.1 — proposto (a validar)

Os vetores compartilham o mesmo impacto (confidencialidade + integridade + disponibilidade
totais do dispositivo). O que muda é o **AV** (vetor de ataque), pela posição do atacante.
Proposta inicial — **revisar com a orientação do TCC**.

| Vetor | AV | Justificativa | Base (proposta) |
|---|---|---|---|
| Fake server via DNS / Relay público | `AV:N` | explorável pela rede, sem estar perto nem na LAN | **9.8 (Crítico)** |
| MITM STA + DNS spoof | `AV:A` | exige estar na mesma LAN/segmento | **8.8 (Alto)** |
| Hotspot AP da câmera | `AV:A` | exige alcance do rádio + câmera em modo config | **8.8 (Alto)** |

Componentes comuns: `AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H`. O `AV:N` do relay/DNS é o que
distingue o achado remoto do local — mesma falha, notas diferentes.

## Pendente — mapeado e não testado

Recorte da **apresentação parcial**: o que está documentado/planejado e **ainda não foi
executado**. Ordem do [`proximos_passos.md`](proximos_passos.md).

| Item | O que falta | Onde roda |
|---|---|---|
| Evil twin (cenário 2) | AP clone da rede da vítima; testar twin aberto e handshake WPA2→crack | Kali (dongle AR9271/RT5370) |
| SD card no AP | `python3 src/a9_naxclow.py -f` (listar) e `-d <data-hora>` (baixar) | Mac (rede da câmera `192.168.169.1:6123`) |
| OTA / firmware | servir um `ota_url` pelo fake e ver update sem assinatura | VPS (Mac orquestra via `ssh`) |
| Stream local no AP / MITM+DNS | a câmera não abre o canal em IP local — reproduzir só com relay público | Linux/relay |
| Comandos MQTT inconclusivos | PTZ `212`, flip `216`, `speedGrade` `201`, `movealert` `205`, `apmode` `208`, `led` `210` | LAN/relay |

> O vetor do **relay público** já resolveu o antigo bloqueio "stream não fecha" que
> atingia os cenários locais — o que faltava era um endpoint **público**. Ver a nota de
> desdobramento em [achados_fakeserver](achados_fakeserver.md) e o achado em
> [achados_fakeserver_relay](achados_fakeserver_relay.md).

## Índice de evidências

| Evidência | Onde |
|---|---|
| Achados por vetor | `docs/achados_ap.md`, `achados_sta.md`, `achados_mqtt.md`, `achados_fakeserver.md`, `achados_fakeserver_relay.md` |
| Protocolo (payloads, portas, handshake) | `docs/protocolo_naxclow.md` |
| Runbooks de execução | `docs/runbook_fakeserver_ap.md`, `runbook_mitm_dns.md` |
| Remontagem de mídia | `scripts/utils/extract_mitm_video.py`, `extract_mitm_video_udp.py` |
| Ferramentas | `src/a9_naxclow.py`, `scripts/mitm_dns/mitm_dns.sh`, `scripts/fakeserver/`, `src/v720_hls.py` |
| Capturas/artefatos (fora do repo, por tamanho/dados sensíveis) | `apk/`, `results/`, `docs/mitm_dns_out/`, `*.pcap` |

## Conclusão

A câmera **não autentica o servidor e não criptografa nada**, o que permite (a) **assumir
o controle** do hardware sem credencial e (b) **espionar** o stream de vídeo/áudio —
tanto remotamente (DNS/relay) quanto de dentro da LAN (MITM/DNS) ou por proximidade (AP
aberto). O ponto de virada do trabalho foi o vetor do **relay em IP público**: provou a
espionagem remota de ponta a ponta, que era o único passo em aberto nos cenários
anteriores. Os itens da seção [Pendente](#pendente--mapeado-e-não-testado) ficam para a
próxima etapa (evil twin, SD card, OTA e a varredura de comandos MQTT) e estão fora do
recorte da apresentação parcial.
