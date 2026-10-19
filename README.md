# Sentinela TCC

Análise de segurança de uma câmera IP **Naxclow Y2SN** (V720).
Investigamos como a câmera, o aplicativo e o servidor se comunicam, e
se um atacante consegue assumir o controle sem a senha da rede.

## Estrutura

```
src/                 Código do cliente e do servidor falso
  a9_naxclow.py      CLI principal (entrada do programa: -l, -s, -f, -d, ...)
  a9_live.py         Exibição/gravação do stream
  v720_ap.py         Cliente que fala com a câmera em modo AP
  v720_sta.py        Servidor falso: canal de dados TCP/UDP (relay)
  v720_http.py       HTTP do servidor falso (provisionamento / bind)
  v720_hls.py        JPEG -> HLS/H.264 (via ffmpeg)
  cmd_udp.py         Códigos de comando do protocolo
  prot_ap.py         Protocolo do modo AP
  prot_udp.py, prot_json_udp.py, prot_xml_udp.py  Pacotes/parsing (header 20 bytes)
  netcl*.py, netsrv*.py  Camada de rede (cliente/servidor TCP/UDP)
  log.py             Logging

scripts/
  fakeserver/        Servidor falso / lab fake (fakesrv_lab.sh, fake_srv_cmd.sh)
  mitm/              Interceptação (mitm_auto.sh, capture_stream.sh) e sondas (p2p_probe.sh)
  mitm_dns/          ARP spoof + DNS spoof/DNAT (mitm_dns.sh) + runbook
  hotspot_ap/        Ataque via hotspot AP da própria câmera (+ README)
  utils/             Extração de vídeo/credenciais (extract_mitm_video*.py, extract_mqtt_*.py)

docs/
  proximos_passos.md     MAPA: estado do lab, pendências e armadilhas (ponto de entrada)
  tcc_resumo.md          Resumo para o TCC (linguagem simples)
  achados_finais.md      Consolidação (OWASP/CVSS + provado vs pendente)
  achados_ap.md          Achados do ataque via hotspot AP
  achados_sta.md         Achados da interceptação na rede (STA)
  achados_mqtt.md        Superfície de comandos do canal MQTT
  achados_fakeserver.md  Achados do servidor falso (técnico)
  achados_fakeserver_relay.md  Relay falso em IP público (VPS) — stream remoto
  protocolo_naxclow.md   Mapeamento detalhado do protocolo
  runbook_fakeserver_ap.md  Passo a passo do lab (AP isolado)
  runbook_mitm_dns.md    Passo a passo do lab (MITM + DNS spoof)
  todo_cenarios.md       Cenários de ataque planejados
```

## Como usar

Dependências e ambiente: veja `requirements.txt`. A CLI principal é
`src/a9_naxclow.py`. O **ponto de entrada** para retomar o trabalho é
`docs/proximos_passos.md` (estado do lab, pendências e armadilhas); o
detalhe de cada vetor e o consolidado estão em `docs/achados_*.md`.

## Aviso

Este projeto é para estudo e uso em ambiente controlado, com equipamento
próprio. Não use contra câmeras ou redes de terceiros.