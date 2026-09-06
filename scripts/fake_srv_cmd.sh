#!/usr/bin/env bash
# fake_srv_cmd.sh - Envia comandos de controle pra camera via MQTT no fake server.
#
# Pre-requisito: mosquitto broker rodando no host do fake server (mesma maquina
# que resolve v720.p2p.naxclow.com). A camera assina o topico
#   Naxclow/P2P/Users/Device/sub/<devicesCode>
# e obedece qualquer JSON publicado ali. SEM autenticacao.
#
# Uso:
#   BROKER=10.42.0.1 DEV=5c001502B330 ./fake_srv_cmd.sh ir on
#   BROKER=10.42.0.1 DEV=5c001502B330 ./fake_srv_cmd.sh reboot
#
# Ambiente controlado / camera propria. Nao usar contra dispositivos de terceiros.

set -euo pipefail

BROKER="${BROKER:-10.42.0.1}"
DEV="${DEV:-5c001502B330}"
TOPIC="Naxclow/P2P/Users/Device/sub/${DEV}"

pub() {
    echo "[pub] ${TOPIC} <- $1"
    mosquitto_pub -h "$BROKER" -t "$TOPIC" -m "$1"
}

case "${1:-help}" in
    ir)        [ "${2:-on}" = on ] && pub '{"code":202,"IrLed":1}' || pub '{"code":202,"IrLed":0}' ;;
    led)       [ "${2:-on}" = on ] && pub '{"code":210,"instLed":1}' || pub '{"code":210,"instLed":0}' ;;
    record)    [ "${2:-on}" = on ] && pub '{"code":209,"sdCardReco":1}' || pub '{"code":209,"sdCardReco":0}' ;;
    movealert) [ "${2:-on}" = on ] && pub '{"code":205,"moveAlert":1}' || pub '{"code":205,"moveAlert":0}' ;;
    wifiscan)  pub '{"code":211}' ;;
    setwifi)   pub "{\"code\":204,\"s\":\"${2:?SSID}\",\"p\":\"${3:?PWD}\"}" ;;
    apmode)    pub '{"code":208}' ;;
    format)    pub '{"code":207}' ;;
    reboot)    pub '{"code":299,"reboot":1}' ;;
    listen)    mosquitto_sub -h "$BROKER" -t '#' -v ;;
    *)
        cat <<EOF
comandos:
  ir on|off         infravermelho (visao noturna)
  led on|off        led de status (desliga sem parar gravacao)
  record on|off     gravacao no SD
  movealert on|off  alerta de movimento
  wifiscan          escaneia wifi (resultado em scanWifiBase64)
  setwifi SSID PWD  reconecta camera noutra rede
  apmode            forca camera pro modo AP
  format            formata SD (destrutivo)
  reboot            reinicia camera
  listen            escuta todos os topicos (status/info/respostas)

env: BROKER=<ip do broker> DEV=<devicesCode>
EOF
        ;;
esac
