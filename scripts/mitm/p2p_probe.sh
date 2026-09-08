#!/usr/bin/env bash
#
# p2p_probe.sh — sonda passiva pra descobrir o comando que faz a camera abrir o
# canal de dados P2P (:6123) com o fake server.
#
# Contexto: no firmware novo (202601081657) a camera pareia e obedece comando
# via MQTT SEM nunca registrar no TCP :6123 do fake server. O registro P2P so
# acontece quando o app real "chama" a camera (abre o viewer). Este script
# observa o MQTT e o :6123 durante essa chamada e registra o que a camera faz,
# pra gente aprender o comando exato em vez de chutar.
#
# Uso (depois do 'up'; o broker e o fake server precisam estar no ar):
#   sudo ./scripts/p2p_probe.sh            # sobe a sonda (MQTT + tcpdump do 6123)
#   # ... no celular: abrir o app V720, abrir o viewer da camera ...
#   sudo ./scripts/p2p_probe.sh stop       # derruba e mostra o que capturou
#
# Overrides por env:
#   BROKER=192.168.50.1 DEV=5c001502B330 IFACE=wlan0 OUT=docs/mitm_out/p2p_probe
#
set -uo pipefail

BROKER="${BROKER:-192.168.50.1}"
DEV="${DEV:-5c001502B330}"
IFACE="${IFACE:-wlan0}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$REPO_ROOT/docs/mitm_out/p2p_probe}"
RUN_DIR="$OUT/run"
LOG_DIR="$OUT"

need_root() { [[ $EUID -eq 0 ]] || { echo "precisa de root: sudo $0 $*" >&2; exit 1; }; }
have() { command -v "$1" >/dev/null 2>&1; }

start() {
  need_root start
  mkdir -p "$RUN_DIR"
  local pid
  for b in mosquitto_sub tcpdump; do have "$b" || { echo "falta '$b' no PATH" >&2; exit 1; }; done

  # subscriber MQTT: tudo que nao for o topico de comandos (sub/<DEV>) e o
  # "ruido" normal (Status/Info) e candidato a ser o comando de call/invite.
  # %I (ISO) %t (topico) %p (payload) — mesmo formato do takeover.
  echo "[*] sub MQTT (Naxclow/#) -> $LOG_DIR/mqtt.log"
  : > "$LOG_DIR/mqtt.log"
  mosquitto_sub -h "$BROKER" -t 'Naxclow/#' -v -F '%I  %t  %p' > "$LOG_DIR/mqtt.log" 2>&1 &
  echo $! > "$RUN_DIR/sub.pid"

  # captura do trafego pro :6123 (registro P2P + possivel stream)
  echo "[*] tcpdump (:6123) -> $LOG_DIR/6123.pcap"
  tcpdump -i "$IFACE" -n -w "$LOG_DIR/6123.pcap" 'port 6123' >/dev/null 2>&1 &
  echo $! > "$RUN_DIR/tcpdump.pid"

  echo
  echo "  Sonda no ar. Agora no celular:"
  echo "    app V720 -> abrir o viewer da camera $DEV (deixar uns 15s)"
  echo "  Depois: sudo $0 stop"
}

stop() {
  need_root stop
  local p
  for n in sub tcpdump; do
    p=$(cat "$RUN_DIR/$n.pid" 2>/dev/null) || continue
    kill "$p" 2>/dev/null && echo "[*] parei $n (pid $p)"
    rm -f "$RUN_DIR/$n.pid"
  done
  sleep 1
  echo
  echo "================  o que a sonda viu  ================"
  echo "--- topicos MQTT (alem do sub/<DEV> e do vai-e-vem Status/Info): ---"
  grep -avE "Device/(sub/${DEV}|Status|Info)" "$LOG_DIR/mqtt.log" 2>/dev/null \
    | sed 's/^/  /' || echo "  (nenhum topico novo — a camera nao foi chamada, ou o app usa outro caminho)"
  echo "--- ultimas linhas do MQTT (qualquer coisa): ---"
  tail -5 "$LOG_DIR/mqtt.log" 2>/dev/null | sed 's/^/  /'
  echo "--- pcap do :6123: $LOG_DIR/6123.pcap ($(du -h "$LOG_DIR/6123.pcap" 2>/dev/null | cut -f1)) ---"
  if have tcpdump && [[ -s "$LOG_DIR/6123.pcap" ]]; then
    echo "  (abrir no Wireshark, ou: tcpdump -r $LOG_DIR/6123.pcap -A)"
  else
    echo "  (vazio — a camera NAO falou com o :6123 durante a janela)"
  fi
  echo "======================================================="
  echo "Se apareceu topico novo tipo 'Device/req'/'call'/'invite', o payload dele"
  echo "e o que precisamos reproduzir no fake server pra destravar o P2P."
}

status() {
  for n in sub tcpdump; do
    p=$(cat "$RUN_DIR/$n.pid" 2>/dev/null) || { echo "$n: parado"; continue; }
    if kill -0 "$p" 2>/dev/null; then echo "$n: rodando (pid $p)"; else echo "$n: morto (pid $p)"; fi
  done
}

case "${1:-start}" in
  start)  start ;;
  stop)   stop ;;
  status) status ;;
  *) echo "uso: sudo $0 [start|stop|status]"; exit 1 ;;
esac
