# Hotspot AP (ataque inicial)

O vetor de ataque por hotspot AP não usa scripts próprios nesta execução.
O fluxo inicial foi feito com os módulos de `src/`:

- `src/v720_ap.py` — cliente que fala com a câmera em modo AP
  (rede `Nax_XXXXXX`, sem senha, câmera em `192.168.169.1:6123`).
- `src/a9_live.py` — exibição/gravação do stream (`show_live`).
- CLI: `python3 src/a9_naxclow.py -l -o stream.avi` (modo live via `-l` / auto).

A documentação do achado está em `docs/achados_ap.md`.

Como a câmera, em modo AP, é um servidor TCP/HTTP aberto (porta 6123, token
`"This is TEST token"` hardcoded), o ataque é direto: conecta na rede da câmera,
descobre o IP dela e fala o protocolo sem autenticação.