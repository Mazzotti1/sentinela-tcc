# Cenários de ataque — a fazer depois

Backlog dos vetores de fake server. **Concluídos:** AP isolado, MITM STA + DNS spoof e relay público. **Pendente:** evil twin.

## 1. AP isolado (lab controlado) — Concluido
Monto minha própria rede, ponho a câmera nela via app, provo que ela aceita servidor falso. Mais simples, prova a falha-raiz. Menos "atacante remoto".

## 2. Evil twin (atacante sem senha) — DEPOIS
Crio AP com mesmo SSID da rede real da câmera, sinal mais forte, ela migra sozinha. Prova takeover remoto real sem saber a senha. Mais complexo no macOS.
Ressalva técnica: se a rede real for WPA2, a câmera provavelmente não migra pra twin aberto — testar (a) twin aberto (documenta se migra ou não) e (b) captura do handshake WPA + crack offline, aí o twin com SSID+senha iguais funciona.

## 3. MITM STA + DNS spoof — Concluido
Câmera fica na rede real; eu na mesma LAN faço ARP+DNS spoof pra desviar naxclow.com pro fake server. Realista, exige estar na LAN.
Script pronto: [scripts/mitm_dns/mitm_dns.sh](../scripts/mitm_dns/mitm_dns.sh) — runbook: [runbook_mitm_dns.md](runbook_mitm_dns.md).
Bônus no mesmo dia: sessão de MITM puro com o viewer do app aberto (fecha a pendência do [achados_sta](achados_sta.md)).

## 4. Relay público (fake em VPS) — Concluido
Fake server num **IP público** (VPS) + desvio do relay (`29939`–`29942`, TCP **e** UDP). A câmera registra e entrega **vídeo + áudio** ao atacante, remotamente, sem app e sem estar na LAN. Detalhe: [achados_fakeserver_relay](achados_fakeserver_relay.md).
