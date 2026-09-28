# Runbook — Cenário 3: MITM STA + DNS spoof (rede real)

Câmera Naxclow Y2SN (firmware `202601081657`, `devicesCode 5c001502B330`) em uso
normal na WiFi de casa (modo STA). Atacante = **Kali na mesma LAN**, sem ser
gateway, sem tocar na config da câmera. ARP spoof + plugin `dns_spoof` do ettercap
desviam `*.naxclow.com` pro fake server local.

Script: [../scripts/mitm_dns/mitm_dns.sh](../scripts/mitm_dns/mitm_dns.sh)

## Diferença dos vetores anteriores

| Vetor | Posição do atacante | O que faz |
|---|---|---|
| MITM STA ([achados_sta](achados_sta.md)) | mesma LAN | **lê** tudo (passivo) |
| Fake server AP isolado ([achados_fakeserver](achados_fakeserver.md)) | **é o gateway**/DHCP/DNS | **é** o cloud (ativo) |
| **MITM + DNS spoof (este)** | mesma LAN, gateway alheio | **vira** o cloud (ativo) |

É a ponte entre os dois: prova que a falha de confiança em DNS, explorada no AP
isolado por um "atacante remoto que controla DNS", também é explorável por um
adversário fraco (qualquer device na mesma WiFi). Pro TCC: mesmo achado, vetores
de CVSS diferentes (`AV:A` aqui vs `AV:N` no remoto).

## Pré-requisitos (Kali)

```
sudo apt install ettercap-text-only mosquitto mosquitto-clients tcpdump curl
```

(o plugin `dns_spoof` vem no pacote ettercap; se o `up` reclamar, instala
`ettercap-graphical` que puxa tudo.)

Câmera já configurada e funcional na WiFi de casa (app V720 mostrando online).

## Rodando no macOS (sem Kali)

O script detecta o SO automaticamente (`uname`). No Mac:

```
brew install ettercap mosquitto
pip3 install -r requirements.txt        # SEM sudo — deps ficam no site-packages do usuário
```

- **Interface padrão vira `en0`** (override com `IFACE=` se preciso).
- **Firewall do macOS tem que estar DESLIGADO** (Ajustes de Sistema > Rede >
  Firewall) — senão ele bloqueia a câmera chegando no `:80`/`:1883`. O `up` avisa
  se detectar ligado.
- O fake server roda como root mas acha as deps python do teu usuário
  automaticamente via `PYTHONPATH` (`~/Library/Python/3.9/...`).
- O fallback `dnat on` usa **pf rdr** (experimental no Mac; no Kali é iptables).
  `down` desfaz tudo, inclusive desliga o pf se foi o script que ligou.
- `status`, `logs`, `watch` e `cheat` rodam **sem** sudo.

## Fases

### Fase 0 — Preparar o PC

```
# conectar na WiFi de casa e conferir que enxerga a camera
ip -4 addr show wlan0
ping -c 2 192.168.0.36
```

Se a câmera ou o gateway tiverem IPs diferentes de `192.168.0.36` / `192.168.0.1`,
passar por env (`CAM_IP=... GW_IP=...`). Descobrir o IP da câmera: DHCP do
roteador, ou `sudo arp-scan -l -I wlan0 | grep -i 5c:f1:50` (OUI do fabricante).

### Fase 1 — Subir o lab

```
cd ~/sentinela
sudo ./scripts/mitm_dns/mitm_dns.sh up        # digitar SIM
```

O script: detecta teu IP, sobe mosquitto (:1883) e fake server (HTTP :80 +
relay :29940, com `FAKE_SRV_HOST`=<teu IP>), escreve `*.naxclow.com[.cn] -> <teu IP>`
no `etter.dns`, liga IP forwarding, inicia ettercap (`-P dns_spoof -M arp:remote`)
e começa a capturar `docs/mitm_dns_out/cam_dns.pcap`.

Checkpoints imediatos (`sudo ... status`): 5 serviços up, portas :80/:1883/:29940
em LISTEN.

Deixar um terminal acompanhando: `sudo ./scripts/mitm_dns/mitm_dns.sh watch`

### Fase 2 — Câmera (única ação física)

**Power cycle** — tirar da tomada e recolocar. Ela reconecta na WiFi de casa e
re-resolve DNS; as queries passam pelo Kali (ARP poison) e o ettercap responde
com o IP do atacante.

### Fase 3 — Validação (checkpoints em ordem)

**A. DNS spoof mordeu** (esperado em < 60 s após o power cycle):
```
sudo ./scripts/mitm_dns/mitm_dns.sh logs ettercap   # 'dns_spoof: ... naxclow.com ... -> <teu IP>'
sudo ./scripts/mitm_dns/mitm_dns.sh logs server     # HTTP getA9ConfCheck vindo da camera
```

**B. Registro MQTT no broker falso:**
```
sudo ./scripts/mitm_dns/mitm_dns.sh logs mosquitto  # New client ... as 5c001502B330
                                                    # SUBSCRIBE Naxclow/P2P/Users/Device/sub/...
```

**A passou, B não** → a câmera fala com o cloud por **IP fixo**
(`39.108.132.112:1883` / `107.149.143.90:29942`, vistos no pcap STA):
```
sudo ./scripts/mitm_dns/mitm_dns.sh dnat on    # + power cycle de novo
```
(o ARP spoof já faz o tráfego dela passar pelo Kali; o DNAT em PREROUTING
captura até conexão pra IP fixo.)

**Nem A passou** → conferir o poison: `arp -a` deve mostrar o MAC da câmera e do
gateway iguais ao MAC do Kali; ver `logs ettercap` (plugin carregou?).

### Fase 4 — Takeover (prova de controle, sem credencial)

```
sudo ./scripts/mitm_dns/mitm_dns.sh takeover
```

Espera a câmera no MQTT, salva baseline do `Device/Info`, manda `ir on` + `reboot`
(via [fake_srv_cmd.sh](../scripts/fakeserver/fake_srv_cmd.sh)), coleta as respostas
e o diff. Prova visual: o IR da câmera acende (visível no escuro / pela câmera do
celular).

Custom: `sudo ./scripts/mitm_dns/mitm_dns.sh takeover --no-stream 'led off'`

### Fase 5 — Stream (só se o relay :29940 registrar)

O `takeover` já tenta: `p2p_watch` no server.log → `/dev/list` → snapshot + `/live`.
Se a câmera **não** abrir o canal de dados, é o mesmo limite documentado no AP
isolado (hipótese do relay em IP público) — nesse caso:
1. garantir que `dnat on` está ativo (redireciona `107.149.143.90:29942`),
2. power cycle + repetir,
3. se persistir, **documentar como limite também neste vetor** — é achado.

Remontagem a partir do pcap principal:
```
python3 scripts/utils/extract_mitm_video.py docs/mitm_dns_out/cam_dns.pcap \
  --out docs/mitm_dns_out/extract --cam-ip 192.168.0.36
```

### Fase 6 — Bônus: stream em STA com viewer aberto (pendência do achados_sta)

Sessão separada, **sem** DNS spoof (lab `down` antes). MITM puro com o `mitm_auto.sh`
original, enquanto o app V720 fica com o viewer aberto — aí o stream real
câmera→cloud atravessa o Kali:

```
sudo ./scripts/mitm/mitm_auto.sh 192.168.0.36 192.168.0.1 wlan0 300 mitm_stream_run
```

### Fase 7 — Encerrar

```
sudo ./scripts/mitm_dns/mitm_dns.sh bundle   # pacote de evidências (anexar ao TCC)
sudo ./scripts/mitm_dns/mitm_dns.sh down     # restaura ARP, ip_forward, etter.dns, DNAT
```

Confirmar no app V720 que a câmera volta a aparecer **online** (cloud real).

## Diagnóstico (árvore de decisão)

| Sintoma | Causa provável | Ação |
|---|---|---|
| ettercap morre no `up` | plugin dns_spoof ausente | `apt install ettercap-graphical` |
| Sem query DNS no log do ettercap | cache de DNS da câmera | power cycle; repetir |
| Query chega, câmera ignora | resposta do roteador ganhou a corrida | poison responde primeiro; conferir `arp -a` e `logs ettercap` |
| HTTP chega, MQTT não | MQTT por IP fixo | `dnat on` + power cycle |
| MQTT registra, :29940 não | relay exige IP público (hipótese do achados_fakeserver) | `dnat on`; se persistir, documentar limite |
| Câmera some da rede | ip_forward off / ettercap caiu | `status`; `down` restaura tudo |

## Vulnerabilidades (OWASP IoT)

| Achado | Evidência | OWASP |
|---|---|---|
| MITM na LAN não detectado | ARP spoof + DNS spoof sem alerta | I2 / I5 |
| Aceita cloud falso vindo de DNS envenenado na LAN | registro no broker/server do atacante | I2 / I7 |
| Canal de controle sem auth | takeover MQTT (`ir`, `reboot`) sem credencial | I1 / I3 |
| Sem criptografia | HTTP/MQTT/relay em claro no pcap | I5 |

## Status final

Executado em 2026-09-27, macOS (Darwin), interface en0. Câmera em 192.168.0.17,
gateway 192.168.0.1, atacante 192.168.0.34.

### O que funcionou

- **DNS spoof via ARP poison**: ettercap desviou `v720.naxclow.com` e
  `v720.p2p.naxclow.com` para o atacante. Câmera fez HTTP `getDevInfo` no fake
  server (:80) e registrou no broker MQTT falso (:1883) como `5c001502B330`, sem
  credencial.
- **Takeover MQTT**: comandos `ir on` (IR LED acendeu, `{"code":202,"IrLed":1}`)
  e `reboot` (`{"code":299,"reboot":1}`) aceitos e executados pela câmera.
  Controle total sem autenticação — mesmo resultado do cenário AP isolado, agora
  reproduzido por adversário na mesma LAN (AV:A no CVSS).
- **DNAT (fallback IP fixo)**: na segunda rodada, câmera conectou pelo IP fixo
  do cloud (`39.108.132.112:1883`); regra pf rdr redirecionou pro broker falso.
  Takeover funcionou igual.

### O que não funcionou

- **Stream via relay (:29940)**: câmera nunca abriu canal de dados no relay
  falso. Mesmo limite documentado no cenário AP isolado — hipótese: relay exige
  IP público específico ou há validação adicional no firmware para o canal de
  vídeo que não existe no canal MQTT de controle.

### Conclusão

O vetor MITM+DNS confirma que a falha de confiança em DNS (explorada no AP
isolado por um "atacante que controla DNS") também é explorável por qualquer
dispositivo na mesma WiFi (ARP spoof). Mesmo achado, vetores de CVSS diferentes
(`AV:A` aqui vs `AV:N` no cenário remoto). O limite de stream é consistente
entre os dois cenários.

| Objetivo | Status |
|---|---|
| DNS spoof desvia a câmera na rede real | ✅ confirmado — ettercap `dns_spoof` desviou queries |
| Takeover MQTT sem credencial (vetor LAN) | ✅ confirmado — `ir on` e `reboot` aceitos sem auth |
| Stream pelo fake server (:29940) | ❌ mesmo limite do AP — câmera não abre canal de dados |
| Bônus: stream STA remontado com viewer aberto | ⏳ não tentado nesta sessão |
