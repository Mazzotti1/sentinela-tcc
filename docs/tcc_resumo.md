# Análise de Segurança da Câmera IP — Resumo para TCC

## Do que se trata

Este trabalho analisa a segurança de uma câmera de vigilância IP
**Naxclow Y2SN** (modelo vendido como "V720") usando o aplicativo de
controle oficial. O objetivo foi verificar, na prática, se é possível que
um atacante assuma o controle da câmera e espie o vídeo **sem ter a senha
da rede dela**.

## Como é a câmera

A câmera se comunica com um servidor na internet (o "cloud" do fabricante).
O aplicativo no celular e a câmera falam com esse servidor para parear,
controlar (ligar/desligar, girar) e ver as imagens ao vivo. Toda essa
comunicação acontece **sem criptografia** e **sem exigir senha** entre os
aparelhos e o servidor.

## A ideia do ataque

Se um atacante conseguir fazer a câmera pensar que o servidor dele é o
"servidor oficial" (por exemplo, controlando o DNS, criando uma réplica da
rede da câmera ou desviando o servidor de vídeo), ela passa a conversar
com ele como se fosse o cloud de verdade. Criamos um **servidor falso** e
testamos se a câmera o aceita.

## O que testamos e o que descobrimos

Testamos vários caminhos, do mais simples ao mais grave:

1. **Hotspot da própria câmera** — em modo de configuração ela abre uma
   rede **sem senha**. Dá para se conectar nela e falar o protocolo
   diretamente, sem login: stream ao vivo **e** listagem/download das
   gravações do cartão SD. Já mostra que o controle local não exige
   autenticação.

2. **Interceptação na rede (MITM)** — ficando entre a câmera e a internet
   dentro da mesma Wi-Fi, capturamos todo o tráfego **em claro**: os
   comandos de controle e o vídeo, que é **reconstruível** por um terceiro.

3. **Servidor falso (fake server)** — criamos um servidor que imita o cloud
   da Naxclow. A câmera **aceitou** o servidor falso, se conectou ao nosso
   serviço de controle e **obedeceu comandos** (infravermelho, reiniciar,
   trocar de rede) **sem pedir senha**.

4. **Servidor falso com vídeo (relay em IP público)** — colocando o
   servidor falso numa máquina com **IP público** (VPS) e desviando o canal
   de vídeo, a câmera entregou **vídeo + áudio ao atacante, remotamente**,
   sem app e sem estar na rede do alvo. Este é o resultado de maior impacto.

5. **Evil twin (réplica da rede + expulsão)** — criamos um **clone da rede
   da vítima** (mesmo nome e senha) e **expulsamos** a câmera da rede real.
   Ela migrou **sozinha** para o clone, pegou IP/DNS do atacante e obedeceu
   comandos. Com o servidor falso na VPS, também veio **vídeo** (JPEG
   640×480). Prova que um atacante **com as credenciais da rede** (SSID +
   senha, ou o handshake WPA2 quebrado) assume a câmera só com proximidade e
   um computador — sem app e sem credencial da câmera.

Caminhos testados que **não** funcionaram:

- **Baixar o cartão SD pelo servidor falso/relay** — a câmera ignora os
  comandos de SD fora do modo AP. As gravações só saem pelo hotspot local.

## O que conseguimos provar

- A câmera **aceita um servidor falso** se o DNS/rota apontar para ele —
  não verifica se o servidor é mesmo o oficial.
- O **canal de controle não tem senha**: qualquer um que fale com ele pode
  dar comandos à câmera.
- Toda a comunicação (controle e vídeo) trafega **em texto claro**, sem TLS.
- O **vídeo e o áudio** podem ser recebidos **remotamente** pelo atacante,
  sem app e sem estar na mesma rede.
- Um atacante **com as credenciais da rede** (ou o handshake WPA2 quebrado)
  consegue a câmera com um **clone do Wi-Fi + expulsão (deauth)** — por
  proximidade.
- Um atacante que **controla DNS/rota não precisa da senha do Wi-Fi** para
  assumir a câmera remotamente (fake server/relay).
- As **gravações do cartão SD** podem ser listadas e baixadas sem login pelo
  hotspot aberto da câmera.

## O que ainda falta

- **Atualização de firmware (OTA)** — servir uma atualização pelo servidor
  falso e ver se a câmera aceita **sem verificar assinatura**. É o próximo
  teste.
- **SD pelo app/cloud** (opcional) — capturar o fluxo real do app na tela
  de gravações para tentar outro caminho além do hotspot local.
- **Comandos MQTT secundários** — confirmar os comandos menos usados
  (girar/mover, espelhar, sensibilidade de movimento, modo AP).

## Conclusão em poucas palavras

A câmera apresenta **falhas reais e graves de segurança**: aceita servidor
falso, tem canal de controle sem senha e não criptografa nada. Isso permite
**(a) assumir o controle** (ligar/desligar, reiniciar, trocar a rede),
**(b) espionar** o vídeo/áudio — tanto remotamente quanto de dentro da rede
ou por proximidade — e **(c) extrair as gravações** do cartão SD. O caminho
que **dispensa a senha do Wi-Fi** é o servidor falso/relay via DNS/rota; o
evil twin exige as credenciais da rede (ou o handshake WPA2 quebrado). Todos
os principais vetores foram **provados em laboratório**; resta o teste de
atualização de firmware (OTA).

## Onde está cada detalhe

- `achados_finais.md` — consolidação (OWASP IoT / CVSS).
- `achados_ap.md`, `achados_sta.md`, `achados_mqtt.md` — hotspot, MITM e comandos.
- `achados_fakeserver.md`, `achados_fakeserver_relay.md` — servidor falso e vídeo remoto.
- `achados_evil_twin.md` — clone da rede + deauth.
- `achados_sd_relay.md` — o teste de SD pelo relay (negativo).
- `proximos_passos.md` — estado do laboratório e próximos passos.
