# Cenários de ataque — a fazer depois

Backlog dos vetores de fake server. **Concluídos:** AP isolado, MITM STA + DNS spoof, relay público, **evil twin** (deauth + clone, inclusive vídeo) e **OTA** (testado, não explorável — ver [`achados_ota.md`](achados_ota.md)). **Pendente:** comandos de controle pelo canal relay, SD via app/cloud e IR/flip no AP. O twin aberto e o crack do handshake WPA2 são variações do pré-requisito do evil twin, não vetores em aberto.

## 1. AP isolado (lab controlado) — Concluido
Monto minha própria rede, ponho a câmera nela via app, provo que ela aceita servidor falso. Mais simples, prova a falha-raiz. Menos "atacante remoto".

## 2. Evil twin (com as credenciais da rede) — Concluido
**Resultou (2026-11-04):** o twin sozinho não convence — a câmera mantém o AP real. Com **deauth** (expulsar do AP real) ela migra pro clone; aí pegou IP/DNS do atacante, conectou no broker e obedeceu comandos; com fake em IP público (VPS) veio **vídeo** (~170 frames JPEG 640×480). Detalhe: [`achados_evil_twin.md`](achados_evil_twin.md).
Crio AP com mesmo SSID **e senha** da rede real da câmera, sinal mais forte, ela migra sozinha. Prova takeover por proximidade quando as credenciais da rede são conhecidas (ou o handshake WPA2 é quebrado). Mais complexo no macOS.
Opcional (fecha o pré-requisito, não o vetor): testar (a) twin **aberto** — documenta se migra ou não — e (b) captura do handshake WPA + crack offline, para não depender de conhecer a senha.

## 3. MITM STA + DNS spoof — Concluido
Câmera fica na rede real; eu na mesma LAN faço ARP+DNS spoof pra desviar naxclow.com pro fake server. Realista, exige estar na LAN.
Script pronto: [scripts/mitm_dns/mitm_dns.sh](../scripts/mitm_dns/mitm_dns.sh) — runbook: [runbook_mitm_dns.md](runbook_mitm_dns.md).
Bônus no mesmo dia: sessão de MITM puro com o viewer do app aberto (fecha a pendência do [achados_sta](achados_sta.md)).

## 4. Relay público (fake em VPS) — Concluido
Fake server num **IP público** (VPS) + desvio do relay (`29939`–`29942`, TCP **e** UDP). A câmera registra e entrega **vídeo + áudio** ao atacante, sem app e sem credencial (no lab o desvio foi por ARP spoof + DNAT na LAN). Detalhe: [achados_fakeserver_relay](achados_fakeserver_relay.md).

## 5. OTA / firmware — Concluido (negativo)
**Resultou (2026-11-21):** a câmera recebe `ota_url`/`ota_version` do servidor falso e **ignora** — não baixa nada. O update é orquestrado pelo **cloud via HTTPS** (`getNewVersion` → `mdfDevVersion`), não pela câmera. Explorar exigiria comprometer o cloud ou a CA do celular. Detalhe: [`achados_ota.md`](achados_ota.md).
