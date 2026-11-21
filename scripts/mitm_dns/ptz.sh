#!/usr/bin/env bash
#
# ptz.sh — move a camera pelo canal de relay do fake server.
#
# O app oficial NAO manda um comando por toque: enquanto o botao fica
# pressionado ele repete o "motorState" a cada 80 ms e manda 0 ao soltar.
# Um comando avulso produz so um passo curtinho. Este script reproduz o fluxo
# continuo (pulsos) e sempre encerra com a parada.
#
# Uso:
#   ./ptz.sh <dir> [segundos] [host]
#     dir: 1=direita 2=esquerda 3=cima 4=baixo 0=parar
#     segundos: default 4
#     host: default 127.0.0.1:8080 (rode na VPS, onde esta o relay)
#
# Ex. (na VPS):  ./ptz.sh 1 6
#     (do Mac):  ./ptz.sh 1 6 137.131.132.251:8080
#
# Requer o relay aberto: /dev/list mostrando a camera.
set -uo pipefail

DIR="${1:-}"
SECS="${2:-4}"
HOST="${3:-127.0.0.1:8080}"
DEV="${DEV:-5c001502B330}"
PULSE="${PULSE:-0.08}"     # mesmo intervalo do app (80 ms)

case "$DIR" in
  ''|*[!0-9]*) echo "uso: $0 <1|2|3|4|0> [segundos] [host:porta]" >&2; exit 1 ;;
esac

fwd() { curl -s -m 2 "http://$HOST/dev/$DEV/fwd?v=212&motorState=$1" >/dev/null; }

if [[ "$DIR" == "0" ]]; then
  fwd 0; echo "parada enviada"; exit 0
fi

N=$(awk -v s="$SECS" -v p="$PULSE" 'BEGIN{printf "%d", s/p}')
echo "movendo: direcao=$DIR por ${SECS}s ($N pulsos)"
for ((i = 0; i < N; i++)); do
  fwd "$DIR"
  sleep "$PULSE"
done
fwd 0
echo "fim (parada enviada)"
