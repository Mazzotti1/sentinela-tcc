#!/usr/bin/env bash
#
# ap_ir_flip.sh — testa IR (-i) e flip (-r) no modo AP, sem precisar de internet.
#
# Roda o cliente AP contra a camera (192.168.169.1:6123), liga o IR, espelha a
# imagem e grava um trecho de video. Tudo offline: a camera E o servidor.
#
# Uso (com o Mac conectado na rede Nax_XXXXXX da camera):
#   ./scripts/mitm_dns/ap_ir_flip.sh [segundos]
#
# Saida: results/ap_ir_flip_<ts>.avi + .log
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

SECS="${1:-25}"
CAM="${CAM:-192.168.169.1:6123}"
TS="$(date +%Y%m%d_%H%M%S)"
OUT="results/ap_ir_flip_${TS}.avi"
LOG="results/ap_ir_flip_${TS}.log"

mkdir -p results

echo "== checando a camera em $CAM =="
if ! ping -c 2 -W 1000 192.168.169.1 >/dev/null 2>&1; then
  echo "[x] camera AP nao respondeu em 192.168.169.1" >&2
  echo "    o Mac esta na rede Nax_XXXXXX da camera?" >&2
  echo "    (a camera ignora ICMP em STA, mas em AP ela responde)" >&2
fi

echo "== rodando ${SECS}s com IR ligado + flip =="
echo "   video: $OUT"
echo "   log:   $LOG"

python3 src/a9_naxclow.py -l -i -r -c "$CAM" -o "$OUT" > "$LOG" 2>&1 &
PID=$!

# sem 'timeout' no macOS: encerra por tempo
( sleep "$SECS"; kill -INT "$PID" 2>/dev/null; sleep 2; kill -9 "$PID" 2>/dev/null ) &
WATCH=$!

wait "$PID" 2>/dev/null
kill "$WATCH" 2>/dev/null || true

echo
echo "== resultado =="
if [[ -f "$OUT" ]]; then
  echo "video: $(ls -lh "$OUT" | awk '{print $5}') -> $OUT"
else
  echo "[!] sem .avi (stream nao gravou)"
fi
echo "--- ultimas linhas do log ---"
tail -20 "$LOG" 2>/dev/null

echo
echo "Pode reconectar na WiFi normal. O agente vai ler os arquivos em results/."
