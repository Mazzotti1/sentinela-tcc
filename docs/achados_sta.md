# Achados — Modo STA (câmera em uso normal na rede)

Cenário: câmera já configurada, pareada com o app, funcionando na WiFi de casa. Atacante = outro device na **mesma rede**, sem tocar na config da câmera.

## Recon: o que NÃO funcionou (e por quê — já é achado)

- **Port scan direto na câmera:** em STA a câmera é **cliente do cloud**, não servidor. Não abre porta local. `nmap -p-` → tudo `filtered`/reset. O vetor local direto do modo AP (`-l -c IP:6123`) **não se aplica**.
- **Sniff passivo:** rede WiFi é switchada → teu device não vê o tráfego câmera↔cloud. `tcpdump` sem MITM = 0 pacotes úteis.
- **Ping sweep (`nmap -sn`):** câmera ignora ICMP, não aparece. Só identificada pelo MAC (OUI `5C:F1:50`, fabricante) e por gerar tráfego.

Conclusão: **recon ativo tradicional tem valor limitado** contra esse device em STA. Precisa de MITM ativo.

## O ataque que funcionou: MITM via ARP spoofing

Teu device se põe entre a câmera e o roteador, intercepta todo o tráfego câmera↔cloud.

```
sudo sysctl -w net.inet.ip.forwarding=1
sudo ettercap -T -i en0 -M arp:remote /192.168.0.36// /192.168.0.1//
```

(`192.168.0.36` = câmera, `192.168.0.1` = roteador. Sair com `q`.)

Sem fake server, sem DNS spoof. ARP spoof puro na LAN.

## O que foi interceptado (TUDO EM TEXTO CLARO)

### Info do dispositivo — MQTT porta 1883, sem TLS
```json
Naxclow/P2P/Users/Device/Info
{"token":"530012ec16", "devPower":-1, "sdCapacity":0, "IrLed":0,
 "cameraState":0, "wifiName":"NET_2GB966E4",
 "devicesCode":"5c001502B330", "version":"202601081657"}
```
Vazou em claro: **token MQTT**, **SSID da vítima** (`wifiName` = dado de localização), **ID único** (`devicesCode`), versão de firmware.

### Comandos de controle — porta 29942, protocolo AP em claro
```json
{"code":301, "target":"7eba2591eaa08c41e2f8de7733983f49",
 "content":{"code":218, "sdDevStatus":0}}
```

## Servidores cloud (Alibaba Cloud, China)

| IP | Porta | Função |
|---|---|---|
| `107.149.143.90` | 29942 | servidor TCP de comandos/relay |
| `39.108.132.112` | 1883 | broker MQTT (control channel), **sem criptografia** |

## Vulnerabilidades STA (OWASP IoT) — com prova capturada

| Achado | Evidência | OWASP |
|---|---|---|
| Comunicação sem criptografia | MQTT 1883 + comandos em claro no pcap | **I5** |
| Token/credencial exposto | `token:530012ec16` interceptado | **I1/I6** |
| Vazamento de dados sensíveis | `wifiName`, `devicesCode`, versão | **I6** (privacidade) |
| MITM na LAN não detectado | ARP spoof funcionou, câmera não notou | **I2/I5** |
| Control channel exposto | comando `code:301` capturado; mesmo canal aceita `mosquitto_pub` | **I3** |

## Quão fácil / problemas

- **Mais fácil que o fake server.** Não precisou DNS spoof nem servidor falso. ARP spoof (ettercap) + tcpdump já expôs tudo.
- **Problema no macOS:** ettercap pegou interface errada por padrão (`ap1`, interface interna). Fix: forçar `-i en0`. Versões novas do macOS quebram ettercap com frequência (`libnet_write`, malloc abort) — bettercap é alternativa mais estável.
- **Cenário realista e grave:** qualquer device na WiFi (convidado, IoT comprometido, WiFi pública/empresa) faz MITM. Não exige modo AP nem proximidade especial além de estar na mesma rede.

## Remontagem do vídeo/áudio interceptado — FEITO

**Cenário desta captura:** a remontagem foi feita a partir de `live-tcp.pcapng` (captura arquivada fora do repo por tamanho), uma captura do **stream em modo AP** (rede `192.168.169.x`, câmera em `192.168.169.1:6123`), em WiFi *monitor mode*. O resultado remontado está em [mitm_out/](mitm_out/). **Não** é o stream do MITM STA — no MITM STA a câmera só emite vídeo pro cloud quando o app abre o viewer, e a captura `cam_mitm.pcap` apanhou apenas o control channel (29942) + MQTT (1883), sem frames de mídia. A remontagem prova que **o stream de vídeo trafega em claro e é reconstruível por um terceiro**; o vetor (AP vs MITM) é a única diferença de posicionamento do atacante.

**Protocolo do stream** (little-endian, header de 20 bytes por chunk TCP):
```
len(4) cmd(2) msg_flag(1) deal_flag(1) forward_id(8) pkg_id(4) | payload
cmd: 1 = JPEG (vídeo)   4 = G711 u-law (áudio)   0 = JSON   100 = heartbeat
```
Cada frame JPEG chega fragmentado em ~20 chunks de até 1400 bytes. Neste firmware (`202601081657`) o marcador SOI `FF D8 FF` só aparece no primeiro chunk de cada frame — usámos o SOI como fronteira de frame (fecha o anterior, começa o novo). Áudio G711 vem em chunks `cmd=4` intercalados.

**Ferramenta:** [extract_mitm_video.py](extract_mitm_video.py) — remonta o byte-stream TCP câmera→cliente (scapy), parseia os chunks e escreve os frames + áudio.
```
python3 extract_mitm_video.py live-tcp.pcapng --out mitm_out
```

**Resultado (em `mitm_out/`):**

| Saída | Conteúdo |
|---|---|
| `frames/*.jpg` | 456 frames JPEG 640×480, ~99% decodificáveis |
| `video_final.avi` | vídeo remontado (MJPG, ~12 fps) |
| `audio.wav` | 56 s de áudio G711 u-law (8 kHz mono) reconstruído |
| `preview_final.png` | grid de amostra dos frames |

Conteúdo visível: imagem real da câmera (estrutura metálica com parafusos sobre fundo claro). Prova de **espionagem completa (vídeo + áudio) sem autenticação**.

**Qualidade / limitação honesta:** a captura foi feita em *monitor mode* com sinal ~-39 dBm e teve **~4% de perda de pacotes no ar** (664 buracos de sequência TCP em 16412 segmentos). Pacotes perdidos no rádio não são recuperáveis offline, por isso alguns frames saem degradados. Isto é limite da captura, não do protocolo: um atacante em MITM ativo (com retransmissão TCP intacta) reconstrói o stream sem perdas.

**OWASP IoT:** stream de mídia sem criptografia nem autenticação → **I3 (Insecure Ecosystem Interfaces) + I5 (Lack of Encryption)**.

## Próximo passo (não feito ainda)

- **Injeção de comando via MQTT:** o control channel está exposto. Testar `mosquitto_pub` no tópico `Naxclow/P2P/Users/Device/sub/<devicesCode>` pra controlar hardware (IR, gravação, reboot) sem auth.
- **Capturar o stream de vídeo *no MITM STA*:** repetir a remontagem acima com um pcap tirado durante MITM ativo enquanto o app está com o viewer aberto (aí o vídeo passa pelo atacante em STA, não só em AP).
- **Fake server (`-s`):** cenário do atacante remoto (controla DNS), ainda separado.
