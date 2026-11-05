# Conceito — Hardware drop + evil twin (ataque a distância)

> **Escopo:** documento de **modelo de ameaça** para o TCC — análise conceitual, ambiente
> controlado. **Não é tutorial operacional.** Descreve a classe de ataque, os **termos
> técnicos corretos** e, principalmente, **como detectar e prevenir**. Usar contra
> equipamentos/rede de terceiros é crime (interceptação/ataque não autorizado).

## 1. A ideia

Todos os vetores de "cloud falso" exigem que o atacante esteja **perto** (rádio) ou **na LAN**
da câmera (ver [proximos_passos](proximos_passos.md)). O **hardware drop** quebra essa
limitação: em vez de o atacante estar lá, ele **deixa um dispositivo** que faz o trabalho local
e responde por um canal próprio. Na literatura de segurança isso é um **implant** (ou
**drop device**, **covert AP**, **foothold físico**).

**Termos corretos:**
- **Hardware implant / drop device / drop box** — o dispositivo deixado no local.
- **Rogue access point (AP)** / **evil twin** — o AP falso que imita a rede da vítima.
- **Deauthentication attack (deauth)** — frame 802.11 forjado que expulsa a câmera do AP
  legítimo.
- **Out-of-band (OOB) uplink** — link de internet **próprio** do implante (ex.: 4G/LTE),
  separado da rede alvo.
- **Command and control (C2)** — canal pelo qual o operador controla o implante à distância
  (túnel VPN/SSH reverso; broker de C2).
- **Pivot / foothold** — o implante como "pé" no ambiente, de onde se pivota.
- **Covert placement** — posicionamento discreto (alimentação, camuflagem, alcance).
- **Public relay** — relay em IP público (a VPS) por onde passam vídeo/dados.
- **CGNAT** — NAT de operadora: o 4G costuma **não** ter IP público (impacta o relay).

## 2. Modelo de ameaça (posições)

| Cenário | Atacante presente | Precisa de rádio durante o ataque? |
|---|---|---|
| Evil twin local (provado) | sim (ao lado) | sim, o tempo todo |
| **Hardware drop + evil twin** | **não** (opera de qualquer lugar) | só no **ato de implantação** |

Ou seja: troca-se **presença contínua** por **um único ato físico de implantação**. Depois
disso, o operador ataca/observa **remotamente** (de casa), quando quiser.

## 3. Arquitetura

```
[câmera] --WiFi--> [implante: evil twin + deauth + fake cloud] --4G--> internet
                              |                                        |
                              |--NAT--> [VPS pública: relay/vídeo] <---+
                              |                                        ^
                              +--C2 reverso (VPN/SSH)--> [operador, de casa]
```

- **Implante (perto da câmera, oculto):** cria o **evil twin**, faz o **deauth**, hospeda o
  **fake cloud** (HTTP/MQTT) e o **broker**, e faz **NAT** pra câmera alcançar a **VPS**.
- **VPS (IP público):** o **relay** (vídeo/áudio). Por que a VPS: a câmera **só abre o relay
  pra endpoint público** e o 4G é **CGNAT** — então o relay público fica na VPS (ver
  [achados_evil_twin](achados_evil_twin.md)).
- **Operador (de casa):** entra no **C2** do implante e assiste o vídeo pela VPS.

## 4. Componentes (classe de hardware — não é guia de montagem)

- **SBC com Linux** (ex.: Raspberry Pi Zero 2 W / Pi 4) — roda `hostapd`, `dnsmasq`,
  `mosquitto`, `aireplay-ng` e o **nosso fake** (`src/a9_naxclow.py`).
- **Rádio WiFi com injeção/monitor** (ex.: AR9271/RT5370) — AP + deauth (o mesmo tipo do
  dongle que usamos).
- **Uplink OOB** — modem 4G/LTE (USB/HAT) com SIM, ou outro enlace.
- **Energia + invólucro** — bateria/power bank, case discreto.
- **C2** — túnel reverso (WireGuard/SSH) pra um VPS do atacante.

Comercial: o **WiFi Pineapple** (Hak5) é o produto pronto dessa classe (rogue AP + C2);
roteadores **OpenWrt** pequenos com 4G são alternativa mais barata.

## 5. Cadeia de ataque (fases, em alto nível)

1. **Implantação** (única presença física): deixar o dispositivo no alcance da câmera.
2. **Estabelecer C2**: o implante "liga pra casa" pelo uplink (VPN/SSH reverso).
3. **Recon**: scanear SSIDs/BSSIDs locais, achar a rede da câmera.
4. **Rogue AP (evil twin)**: subir o clone (mesmo SSID/senha), no canal do AP real.
5. **Deauth**: expulsar a câmera do AP legítimo → ela migra pro clone.
6. **Fake cloud**: a câmera recebe DHCP/DNS do implante e fala com o fake (controle); o `240`
   aponta o **relay** pra VPS (vídeo).
7. **Operação remota**: o operador controla (LED/IR/`setwifi`/`format`) e assiste o vídeo.

## 6. Limitações (por que é difícil na prática)

- **Alcance de rádio**: o implante tem que ficar perto (dezenas de metros, com obstáculos).
- **Energia/ocultação**: bateria e discrição limitam o tempo.
- **Injeção**: deauth exige rádio compatível (monitor/injection).
- **CGNAT no 4G**: sem IP público → precisa da VPS como relay.
- **Validação do relay**: o relay público tem que ser alcançável e aceito (resolvido com o fix
  do `240`: `tcpPort`+`uid`).
- **Deauth detectável**: WIDS/WIPS e 802.11w (PMF) quebram o deauth.

## 7. Defesa / detecção (o ponto pro TCC)

- **802.11w (Protected Management Frames / PMF)** — bloqueia deauth forjado (WPA3, ou WPA2+PMF).
- **WIDS/WIPS** — detecta **rogue AP/evil twin** (BSSID desconhecido com SSID conhecido, mesmo
  canal, sinal anômalo) e **deauth floods**.
- **Monitoramento de ARP/DNS** — detecta "cloud" fora do pool oficial.
- **Inspeção física** — buscar dispositivos ocultos (SBC, dongle, battery) no perímetro.
- **Hardening do WiFi** — WPA3, senha forte, desligar WPS, inventário de APs.
- **No dispositivo (câmera)** — TLS + validação/pinning de certificado do servidor e
  autenticação do relay/broker. (Hoje não existe — é a falha-raiz.)

## 8. OWASP IoT

| Achado | OWASP |
|---|---|
| Câmera aceita AP/cloud não autenticados (evil twin + fake) | I2 / I7 |
| Sem criptografia (HTTP/MQTT/relay em claro) | I5 |
| Deauth/MITM não detectado pela câmera | I2 / I5 |

**CVSS (proposto):** o **vetor** exige **implantação física** (`AV:P`/`AV:A`), mas a
**operação** é remota; o impacto é o mesmo dos outros vetores (controle + mídia). A nota deve
refletir o **pré-requisito de implantação física**.

## 9. Relação com os achados do TCC

- **Não é um novo achado de vulnerabilidade da câmera** — é um **vetor de entrega** que amplia
  o alcance de um achado já provado (evil twin + fake cloud).
- Peças já provadas: **evil twin** ([achados_evil_twin](achados_evil_twin.md)), **fake
  cloud/relay** ([achados_fakeserver](achados_fakeserver.md),
  [achados_fakeserver_relay](achados_fakeserver_relay.md)) e **controle**
  ([achados_mqtt](achados_mqtt.md)).
- O que este documento acrescenta é o **modelo de ameaça remoto** (implantação física única +
  operação à distância) e a **discussão de detecção/prevenção**.
