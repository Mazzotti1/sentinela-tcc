#!/usr/bin/env bash
#
# mqtt_send_on_connect.sh — espera a câmera conectar no broker MQTT e manda os
# comandos imediatamente (a câmera fica online só ~20-30s e fica reconectando).
#
# Uso:
#   BROKER=192.168.0.38 DEV=5c001502B330 ./mqtt_send_on_connect.sh 'wifiscan;led off;record off'
#   LOG=docs/mitm_dns_out/mosquitto.log ./mqtt_send_on_connect.sh 'led off'
#
set -uo pipefail

BROKER="${BROKER:-192.168.0.38}"
DEV="${DEV:-5c001502B330}"
LOG="${LOG:-docs/mitm_dns_out/mosquitto.log}"
CMDS="${1:-wifiscan;led off;record off;movealert on}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD_SCRIPT="$SCRIPT_DIR/fake_srv_cmd.sh"

echo "[*] aguardando 'New client ... as $DEV' em $LOG ..."
tail -n 0 -F "$LOG" 2>/dev/null | while read -r line; do
  if echo "$line" | grep -qE "New client connected .* as ${DEV}"; then
    echo "[+] camera conectou. enviando comandos: $CMDS"
    IFS=';' read -ra steps <<< "$CMDS"
    for c in "${steps[@]}"; do
      c="${c#"${c%%[![:space:]]*}"}"; c="${c%"${c##*[![:space:]]}"}"
      [[ -n "$c" ]] || continue
      BROKER="$BROKER" DEV="$DEV" "$CMD_SCRIPT" $c
      sleep 1
    done
    echo "[*] pronto."
    break
  fi
done
