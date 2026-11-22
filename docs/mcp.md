# Servidor MCP — Sentinela

Expõe a pesquisa e as ferramentas da Sentinela para agentes de IA (Claude, Cursor,
Zed, Continue, qualquer cliente MCP).

Implementado em JSON-RPC 2.0 sobre stdio, **sem dependências** — o SDK oficial
exige Python 3.10+ e este projeto roda em 3.9.

## O que o agente consegue fazer

As ferramentas são divididas em camadas. A separação é intencional: um agente
pode ser induzido por *prompt injection* a chamar ferramentas, então tudo que
altera ambiente exige consentimento explícito.

### Leitura (não tocam em nada)

| Ferramenta | Para quê |
|---|---|
| `info` | diagnóstico do ambiente: interface, gateway, WiFi, câmera responde? |
| `findings_summary` | o que foi provado e o que falhou, com o modelo de ameaça |
| `kb_search` | busca nos achados/protocolo — evidências, armadilhas, códigos |
| `doc_read` | lê um documento de `docs/` |
| `protocol_ref` | referência do protocolo: framing 20 B, envelopes 301/502, códigos |

### Prova (falam com a câmera, só leitura)

| Ferramenta | Para quê |
|---|---|
| `ap_probe` | em modo AP, conecta sem autenticação e lista o SD |

### Ativas (alteram dispositivo ou rede)

| Ferramenta | Efeito | Exige |
|---|---|---|
| `ap_control` | liga IR + flip (efeito físico visível) | `confirm: true` |
| `relay_ptz` | move a câmera (pan/tilt) | `confirm: true` + `direction` |
| `mitm_capture` | ARP spoof + captura de vídeo | `confirm: true` + `target` |
| `fake_cloud` | fake server + broker + DNS falso | `confirm: true` |
| `lab_down` | derruba tudo e restaura a rede | — |

Sem `confirm: true` as ferramentas ativas retornam erro explicando o efeito, em
vez de executar. `lab_down` é a única ativa que não pede confirmação — ela
**reduz** o estado modificado, então nunca deve ser barrada.

## Registro

### Command Code

O Command Code usa o binário `cmd`. Registre no escopo **project** para que o
`.mcp.json` vá junto com o repositório (quem clonar já tem o servidor):

```bash
cmd mcp add --scope project sentinela -- "$PWD/sentinela-mcp"
```

Use `--scope user` para valer em todos os projetos da máquina (`~/.commandcode/mcp.json`),
ou omitir o `--scope` para o padrão `local` (`~/.commandcode/projects/<slug>/mcp.json`).

Conferir:

```bash
cmd mcp list          # STATUS deve mostrar 'enabled'
cmd mcp get sentinela # detalhes: transporte, escopo, comando
```

O comando acima gera este `.mcp.json` na raiz:

```json
{
  "mcpServers": {
    "sentinela": {
      "transport": "stdio",
      "enabled": true,
      "command": "/caminho/absoluto/sentinela/sentinela-mcp"
    }
  }
}
```

> **`enabled` não é o mesmo que conectado.** O status da configuração só diz que
> o servidor está registrado. Para ver a conexão de verdade e a contagem de
> ferramentas, abra uma sessão e rode `/mcp` — o servidor só é carregado na
> inicialização do `cmd`, então uma sessão já aberta não o enxerga.

Erros de conexão aparecem no `/mcp`. Se o servidor não subir, teste o binário
direto (veja [Teste rápido](#teste-rápido)).

### Claude Desktop

`~/Library/Application Support/Claude/claude_desktop_config.json` (macOS)
ou `%APPDATA%\Claude\claude_desktop_config.json` (Windows):

```json
{
  "mcpServers": {
    "sentinela": {
      "command": "/caminho/para/sentinela/sentinela-mcp"
    }
  }
}
```

### Claude Code

```bash
claude mcp add sentinela -- /caminho/para/sentinela/sentinela-mcp
```

### Cursor / Zed / outros (formato genérico)

```json
{
  "mcpServers": {
    "sentinela": {
      "command": "/caminho/para/sentinela/sentinela-mcp",
      "args": []
    }
  }
}
```

Substitua `/caminho/para/sentinela` pelo caminho absoluto do repositório.

## Exemplo de uso

Com o servidor registrado, o agente já enxerga as ferramentas. Conversa típica:

> **Você:** "Essa câmera Naxclow na minha rede é segura?"
>
> **Agente:** *(chama `info`, depois `findings_summary`)*
> "Não. O canal câmera↔cloud é HTTP em claro e sem autenticação: qualquer um na
> sua LAN pode fazer MITM e reconstruir o vídeo, e quem controla DNS/rota vira o
> cloud da câmera. Só o canal de atualização de firmware usa HTTPS."

### Dentro do Command Code

As ferramentas aparecem com o prefixo `mcp__sentinela__<nome>`. Você não precisa
digitar esse nome: descreva o objetivo e o agente escolhe a ferramenta.

```
/mcp                                    # status + contagem de ferramentas
```

Pedidos que mapeiam direto:

| Você pede | Ferramenta chamada |
|---|---|
| "a câmera está respondendo?" | `info` |
| "o que provamos sobre essa câmera?" | `findings_summary` |
| "acha o que documentamos sobre motorState" | `kb_search` |
| "abre o achado do OTA" | `doc_read` |
| "como é o framing do protocolo?" | `protocol_ref` |
| "lista o SD sem senha" | `ap_probe` (câmera em modo AP) |
| "gira a câmera pra direita 3s" | `relay_ptz` (pede confirmação) |
| "derruba o lab" | `lab_down` |

O servidor só é carregado na inicialização: uma sessão aberta antes do
`cmd mcp add` não enxerga as ferramentas. Abra uma sessão nova.

## Limitações (honestas)

- **Não roda em Android.** ARP spoof, deauth e DNAT exigem capacidades que apps
  não têm. O MCP roda no host (Mac/Linux) que executa o laboratório.
- **Não contorna HTTPS.** O update de firmware é comandado pelo app via HTTPS;
  desviar DNS não basta. Ver `docs/achados_ota.md`.
- **Não extrai o SD remotamente.** Este firmware só atende operações de SD no
  modo AP. Ver `docs/achados_sd_relay.md`.
- **`evil-twin` não está exposto.** Exige Kali + dongle com injeção; não faz
  sentido como ferramenta remota de agente.

## Teste rápido

Sem precisar de agente nenhum — fala direto com o servidor:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | ./sentinela-mcp
echo '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | ./sentinela-mcp
```

Chamar uma ferramenta:

```bash
echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"info","arguments":{}}}' | ./sentinela-mcp
```

Se o `initialize` responder com `"name": "sentinela"`, o servidor está saudável —
qualquer problema depois disso é registro do cliente, não o servidor.

## Aviso

Ambiente controlado, com equipamento próprio. Um agente executando estas
ferramentas contra câmeras de terceiros comete crime — o `confirm: true` existe
para o operador humano decidir, não para o agente decidir sozinho.
