# Análise de Segurança da Câmera IP — Resumo para TCC

## Do que se trata

Este trabalho analisa a segurança de uma câmera de vigilância IP
**Naxclow Y2SN** (modelo vendido como "V720") usando o aplicativo de
controle oficial. O objetivo foi verificar, na prática, se é possível que
um atacante assuma o controle da câmera sem ter a senha da rede dela.

## Como é a câmera

A câmera se comunica com um servidor na internet (o "cloud" do fabricante).
O aplicativo no celular e a câmera falam com esse servidor para parear,
controlar (ligar/desligar, girar) e ver as imagens ao vivo. Toda essa
comunicação acontece **sem criptografia** e **sem exigir senha** entre os
aparelhos e o servidor.

## A ideia do ataque

Se um atacante conseguir fazer a câmera pensar que o servidor dele é o
"servidor oficial" (por exemplo, controlando o DNS ou criando uma réplica
da rede da câmera), ela passa a conversar com ele como se fosse o cloud
de verdade. Criamos um **servidor falso** e testamos se a câmera o aceita.

## O que testamos e o que descobrimos

Testamos três caminhos diferentes:

1. **Hotspot da própria câmera** — a câmera, em modo de configuração, abre
   uma rede sem senha. Dá para se conectar nela e falar o protocolo dela
   diretamente, sem login. Isso já mostrou que o controle local não exige
   autenticação.

2. **Interceptação na rede (MITM)** — ficando entre a câmera e a internet
   dentro da mesma rede Wi-Fi, conseguimos capturar todo o tráfego em claro:
   os comandos de controle e o envio do vídeo compactado, tudo sem
   criptografia.

3. **Servidor falso (fake server)** — criamos um servidor que imita o cloud
   da Naxclow. Com ele, a câmera **aceitou** o servidor falso, se conectou ao
   nosso serviço de controle e **obedeceu comandos** (acender infravermelho,
   reiniciar) **sem pedir nenhuma senha**.

## O que conseguimos provar

- A câmera **aceita um servidor falso** se o DNS apontar para ele — não
  verifica se o servidor é mesmo o oficial.
- O **canal de controle não tem senha**: qualquer pessoa que consiga falar
  com esse canal pode dar comandos à câmera.
- Toda a comunicação (controle e vídeo) trafega **em texto claro**, sem TLS.

## O que ainda não conseguimos

- **Abrir o vídeo ao vivo pelo servidor falso.** A câmera faz o pareamento
  e aceita os comandos de controle, mas não completa o envio da imagem ao
  vivo quando o servidor é o falso. O motivo provável: o cloud real usa um
  servidor de vídeo com **endereço público**, e a câmera só envia a imagem
  para esse tipo de endereço. Em um laboratório com servidor em IP privado
  e rede isolada, não conseguimos replicar essa parte.

## Conclusão em poucas palavras

A câmera apresenta **falhas reais de segurança**: aceita servidor falso,
tem canal de controle sem senha e tudo sem criptografia. Isso permite
**assumir o controle dessas câmeras** (ligar/desligar, reiniciar, mudar a
rede de destino). O único passo que não fechamos foi o envio de vídeo em
tempo real pelo servidor falso, por depender de um endereço público de
relay que não reproduzimos em laboratório.