# Sentinela — manual da ferramenta

Como rodar cada cenário do começo ao fim. Para o **porquê** de cada teste e as
evidências, veja `docs/achados_*.md`. Para as armadilhas do laboratório, veja
`docs/proximos_passos.md`.

## Antes de começar

Dependências:

```
pip3 install -r requirements.txt
brew install ettercap mosquitto        # macOS
# ou: sudo apt install ettercap-text-only mosquitto mosquitto-clients
```

Regras do jogo:

- **Câmera e rede próprias.** Testar equipamento de terceiros é crime.
- No macOS, o **firewall precisa estar desligado** — senão ele bloqueia a câmera
  chegando nas portas do fake.
- `sudo` é pedido só nos cenários que precisam (`mitm`, `dns`). A ferramenta
  avisa antes.
- Toda execução cria `results/<cenário>_<data>/` com `report.md` + artefatos.

A câmera muda de IP entre sessões (DHCP). A ferramenta descobre pelo MAC
(OUI `5c:f1:50`), então não precisa configurar IP.

---

## `./sentinela info`

Diagnóstico **read-only**: não sobe nada, não muda nada. Diz se o PC está na
rede da câmera, se ela responde, e qual cenário faz sentido rodar agora.

Rode isso primeiro, sempre.

---

## `./sentinela ap`

**Prova:** a câmera aceita controle local sem nenhuma autenticação.

**Pré-requisito:** a câmera em **modo AP** (rede `Nax_XXXXXX`, sem senha) e o PC
conectado nela. Se a câmera estiver pareada na sua WiFi, resete para voltar ao
modo AP.

**Ação física:** conectar o PC na rede da câmera. A ferramenta pausa e espera.

**O que ele faz:** conecta em `192.168.169.1:6123` com o token hardcoded, lista
o cartão SD, e roda stream com IR ligado + flip por 20s.

**O que você vê:** o IR acende, a imagem inverte. A ferramenta pede confirmação.

**Evidência:** `stream.avi`, `sd_list.log`, `report.md`.

---

## `./sentinela mitm`

**Prova:** dentro da mesma WiFi, todo o tráfego câmera↔cloud é legível, e o
vídeo é reconstruível por um terceiro.

**Pré-requisito:** câmera em uso normal (modo STA) na sua WiFi.

**Ação física:** com o app aberto no viewer, a câmera só emite vídeo quando
alguém assiste. A ferramenta avisa o momento de abrir o viewer.

**O que ele faz:** ARP spoof (ettercap) + captura (tcpdump) por 60s
(`DURACAO=120 ./sentinela mitm` para mais tempo), depois remonta o vídeo.

**Evidência:** `mitm/capture.pcap`, `mitm/frames/*.jpg`, `report.md`.

**Atenção:** é ARP spoof ativo na sua rede. Ao terminar, a rede volta ao normal
sozinha (o ARP expira), mas se algo ficar estranho rode `./sentinela info`.

---

## `./sentinela dns`

**Prova:** a câmera aceita um servidor falso como se fosse o cloud do fabricante
— e obedece comandos de hardware sem credencial.

**Pré-requisito:** câmera na sua WiFi.

**O que ele faz:** sobe broker MQTT + fake HTTP + relay, envenena ARP/DNS, espera
a câmera falar com o fake. Se não falar, liga o DNAT (este firmware usa IP fixo
no HTTP) e pede outro power cycle.

**Ações físicas:** power cycle na câmera (uma ou duas vezes). A ferramenta pausa
e explica cada uma.

**O que você vê:** o LED apaga e volta quando os comandos são enviados.

**Evidência:** `server.log`, `report.md`.

**Para derrubar:** `./scripts/mitm_dns/ota_up.sh down`

---

## `./sentinela relay`

**Prova:** controle + vídeo recebidos **fora da LAN**, sem app.

**Pré-requisito:** uma **VPS com IP público**. A câmera só abre o canal de dados
para endpoint público — em IP privado ela registra mas não abre.

```
VPS=203.0.113.10 ./sentinela relay
```

**Ação física:** power cycle na câmera; depois abrir o viewer no app para
disparar o `240`.

**Por que precisa do app:** a câmera só abre o relay quando o cloud manda a
ordem, e o cloud real só faz isso quando alguém assiste. Sem app, esse passo não
acontece.

---

## `./sentinela evil-twin`

**Prova:** a câmera migra sozinha para um AP clonado quando é expulsa do real.

**Pré-requisito:** **Kali Linux** + dongle com injeção (AR9271/RT5370) + os
**SSID e senha da rede real**. Não roda no macOS: precisa de `hostapd` e modo
monitor/injeção.

A ferramenta recusa o cenário fora do Linux e aponta o passo a passo manual em
`docs/achados_evil_twin.md`.

---

## Variáveis de ambiente

| Variável | Default | Para quê |
|---|---|---|
| `IFACE` | `en0` (mac) / `wlan0` | interface de rede |
| `DEV` | `5c001502B330` | `devicesCode` da câmera |
| `DURACAO` | `60` | segundos de captura no `mitm` |
| `VPS` | — | IP público do relay (cenário `relay`) |

## Flags

| Flag | Efeito |
|---|---|
| `--yes` | pula as confirmações de "tem certeza" (**as ações físicas continuam**) |
| `--out DIR` | grava a evidência numa pasta específica |
| `--list` | lista os cenários |

---

## O que a ferramenta NÃO faz

Para não prometer o que não entrega:

- **Não roda em Android.** ARP spoof, deauth e DNAT exigem capacidades que
  apps Android não têm (raw socket). Um APK cobriria só o cenário `ap`.
- **Não contorna HTTPS.** O update de firmware (OTA) é comandado pelo app via
  HTTPS; não é explorável só desviando DNS. Ver `docs/achados_ota.md`.
- **Não extrai o SD remotamente.** Este firmware só atende as operações de SD no
  modo AP. Ver `docs/achados_sd_relay.md`.
