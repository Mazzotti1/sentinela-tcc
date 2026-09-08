# Sentinela TCC

Análise de segurança de uma câmera IP **Naxclow Y2SN** (V720).
Investigamos como a câmera, o aplicativo e o servidor se comunicam, e
se um atacante consegue assumir o controle sem a senha da rede.

## Estrutura

```
src/                 Código do cliente e do servidor falso
  v720_ap.py         Cliente que fala com a câmera em modo AP
  v720_sta.py        Servidor falso (modo STA, canal MQTT + TCP)
  v720_http.py       HTTP do servidor falso (provisionamento)
  a9_naxclow.py      CLI principal (entrada do programa)
  a9_live.py         Exibição/gravação do stream

scripts/
  fakeserver/        Scripts do servidor falso / lab fake
  mitm/              Interceptação de rede (MITM) e sondas
  hotspot_ap/        Ataque via hotspot AP da própria câmera
  utils/             Ferramentas auxiliares (extração de vídeo/credenciais)

docs/
  tcc_resumo.md          Resumo para o TCC (linguagem simples)
  achados_ap.md          Achados do ataque via hotspot AP
  achados_sta.md         Achados da interceptação na rede
  achados_fakeserver.md  Achados do servidor falso (técnico)
  protocolo_naxclow.md   Mapeamento detalhado do protocolo
  runbook_fakeserver_ap.md  Passo a passo do laboratório
  todo_cenarios.md       Cenários de ataque planejados
```

## Como usar

Dependências e ambiente: veja `requirements.txt`. A CLI principal é
`src/a9_naxclow.py`. Veja `docs/runbook_fakeserver_ap.md` para o passo a
passo de subir o laboratório do servidor falso.

## Aviso

Este projeto é para estudo e uso em ambiente controlado, com equipamento
próprio. Não use contra câmeras ou redes de terceiros.