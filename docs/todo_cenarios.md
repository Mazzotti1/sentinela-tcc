# Cenários de ataque — a fazer depois

Backlog dos vetores de fake server. Em andamento: **AP isolado**. Os outros dois ficam pra depois.

## 1. AP isolado (lab controlado) — EM ANDAMENTO
Monto minha própria rede, ponho a câmera nela via app, provo que ela aceita servidor falso. Mais simples, prova a falha-raiz. Menos "atacante remoto".

## 2. Evil twin (atacante sem senha) — DEPOIS
Crio AP com mesmo SSID da rede real da câmera, sinal mais forte, ela migra sozinha. Prova takeover remoto real sem saber a senha. Mais complexo no macOS.

## 3. MITM STA + DNS spoof — DEPOIS
Câmera fica na rede real; eu na mesma LAN faço ARP+DNS spoof pra desviar naxclow.com pro fake server. Realista, exige estar na LAN.
