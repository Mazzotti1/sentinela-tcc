#!/usr/bin/env bash
#
# ota_up.sh — atalho para o lab MITM+DNS, sem depender de variaveis passando
# pelo sudo (o sudo limpa o ambiente).
#
# Uso (SEM sudo — o wrapper chama o sudo com as vars ja resolvidas):
#   ./scripts/mitm_dns/ota_up.sh up
#   ./scripts/mitm_dns/ota_up.sh dnat on
#   ./scripts/mitm_dns/ota_up.sh status
#   ./scripts/mitm_dns/ota_up.sh down
#
# Overrides:
#   CAM_IP=...            (default: descoberto pelo OUI 5c:f1:50)
#   RELAY_IP=...          (default: 137.131.132.251 — anunciado no "240")
#   OTA_URL / OTA_VERSION (opcional; so para o teste de OTA)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

# camera pelo OUI do fabricante (o IP muda entre sessoes por DHCP)
CAM_IP="${CAM_IP:-$(arp -a -n 2>/dev/null | awk '/5c:f1:50/ {gsub(/[()]/,"",$2); print $2; exit}')}"
# relay anunciado no "240". A camera so abre o canal para IP PUBLICO — nao adianta
# apontar pro Mac. A VPS (fake) escuta o relay.
RELAY_IP="${RELAY_IP:-137.131.132.251}"
OTA_URL="${OTA_URL:-}"
OTA_VERSION="${OTA_VERSION:-}"

if [[ -z "$CAM_IP" ]]; then
  echo "[x] camera nao encontrada no ARP (OUI 5c:f1:50). Ligada e na mesma WiFi?" >&2
  exit 1
fi

echo "camera=$CAM_IP  relay=$RELAY_IP"
[[ -n "$OTA_URL" ]] && echo "ota_url=$OTA_URL  versao=$OTA_VERSION"

exec sudo CAM_IP="$CAM_IP" FAKE_SRV_RELAY_HOST="$RELAY_IP" \
  OTA_URL="$OTA_URL" OTA_VERSION="$OTA_VERSION" \
  ./scripts/mitm_dns/mitm_dns.sh "$@"
