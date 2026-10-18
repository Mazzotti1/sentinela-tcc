# Próximos passos (pendências)

## Concluído

- ✅ **Stream em STA via MITM** — capturado e remontado (`achados_sta.md` + `extract_mitm_video_udp.py`).
- ✅ **Superfície MQTT** — `wifiscan`, `record`, `ledei`, `setwifi`, `format` (`achados_mqtt.md`).
- ✅ **Stream em AP** — capturado (`achados_ap.md`).
- ✅ **RE do APK** — relay antigo + WebRTC do app 3.3.0.

## Pendente (ordem)

1. **Fake server stream (relay)** — o `240` não é o gatilho; a câmera conecta no relay real só com viewer aberto. O `pf rdr` do macOS não entrega no socket local. Falta implementar `getA9VideoConf` e a orquestração do relay (`code 5`).
   - **(a) VPS com IP público** — subir o fake server na VPS e rodar com `FAKE_SRV_HOST=<ip_público>` (a câmera aceita o relay outbound no IP público). É o caminho principal.
   - **(b) Linux (iptables)** — o DNAT no Linux não tem o bug do `pf` do macOS; alternativa local.

2. **Evil twin (cenário 2)** — takeover sem senha do WiFi. Precisa dongle USB (`AR9271`/`RT5370`) + Kali. Testar twin aberto + handshake WPA2.

3. **Modo AP: SD card** — testar `-f` (listar) e `-d` (baixar gravação) via `src/a9_naxclow.py`.

4. **OTA / firmware** — `ota_url` das respostas; verificar update sem assinatura.

5. **Consolidar** — `docs/achados_finais.md` com OWASP/CVSS.
