# 🎼 Orchestra Agents

Um **orquestrador de IA** para o terminal: o **Claude Code** atua como **líder (maestro)** e coordena dois **workers do OpenCode** — um **CODER** (executor) e um **REVISOR** (code review) — cada um rodando na **TUI real do OpenCode**, lado a lado, dentro do **zellij**.

O líder despacha tarefas de forma **assíncrona** (não bloqueia, não fica gastando token esperando) e os workers trabalham em paralelo, com tudo visível ao vivo.

```
┌──────────────────────────────────────────────────────────┐
│  LÍDER (Claude Code)  —  você orquestra daqui             │
│  orchestra send coder "..."   orchestra send reviewer "..."│
├───────────────────────────┬──────────────────────────────┤
│  CODER (OpenCode TUI)      │  REVISOR (OpenCode TUI)       │
│  agente: build            │  agente: reviewer (read-only) │
└───────────────────────────┴──────────────────────────────┘
        zellij  +  servidor OpenCode compartilhado (:4096)
```

---

## ✨ Como funciona

Orchestra usa a arquitetura **cliente/servidor** do OpenCode:

- **`opencode serve`** sobe um servidor headless compartilhado (porta `4096`).
- Cada worker é uma **TUI real** attachada a uma sessão: `opencode attach <url> --session <id>`.
- O líder injeta tarefas via API **assíncrona** (`POST /session/:id/prompt_async`, HTTP 204 instantâneo) — o worker processa em background e renderiza ao vivo na própria TUI.
- Resultados são lidos **sob demanda** (`orchestra result`), nunca em loop — por isso o líder não desperdiça tokens esperando.

---

## ✅ Pré-requisitos

Você precisa ter, **já instalados e configurados**:

| Requisito | Como obter |
|-----------|-----------|
| **Claude Code** | <https://docs.claude.com/claude-code> |
| **OpenCode** (autenticado, com um modelo configurado) | <https://opencode.ai> |
| `git`, `curl`, `python3` | já vêm na maioria das distros |

> O **zellij** é instalado automaticamente pelo instalador se você ainda não tiver.

O OpenCode precisa de um agente **`reviewer`** (read-only). Veja [`config/opencode.reviewer.jsonc`](config/opencode.reviewer.jsonc) — o instalador avisa se ele estiver faltando.

---

## 🚀 Instalação

```bash
curl -fsSL https://raw.githubusercontent.com/orcioly/orchestra-agents/main/install.sh | bash
```

É só isso — **nenhuma configuração manual**. O instalador:
1. confere Claude Code + OpenCode;
2. instala o **zellij** se faltar;
3. coloca os arquivos em `~/.orchestra-agents`;
4. instala o comando **`orchestra`** num diretório que **já está no seu `PATH`** (o mesmo do `claude`/`opencode`), então ele funciona na mesma sessão;
5. configura o `PATH` automaticamente (zsh/bash/fish) caso necessário;
6. avisa se o agente `reviewer` não estiver na config do OpenCode.

Depois de instalar, basta digitar `orchestra`.

---

## 🎬 Uso

São só **dois passos** no dia a dia:

```bash
cd ~/meu-projeto   # qualquer projeto, qualquer pasta
orchestra          # abre o zellij: LÍDER (Claude) em cima, CODER | REVISOR embaixo
```

> `orchestra` sozinho já entra (equivale a `orchestra up` no diretório atual).

### Modo natural (recomendado)

Depois do `orchestra up`, **apenas converse com o Claude** no painel do LÍDER — ele já sobe sabendo orquestrar e delega sozinho:

```
você ▸ cria um endpoint POST /users com validação e depois manda revisar
Claude (LÍDER) ▸ delega ao CODER... (roda no painel ao lado) e depois ao REVISOR
```

Você não precisa decorar comando nenhum. O líder despacha de forma assíncrona e busca os resultados pra você.

### Modo manual (controle fino)

Se quiser comandar na unha:

```bash
orchestra send coder    "crie um endpoint POST /users com validação"
orchestra send reviewer "revise as últimas mudanças e aponte bugs"
orchestra result coder        # vê a resposta quando quiser (sob demanda)
orchestra status              # estado do servidor/sessões
orchestra down                # encerra o servidor
```

### Comandos

| Comando | Descrição |
|---------|-----------|
| `orchestra` | Atalho para `orchestra up` no diretório atual |
| `orchestra up [dir]` | Sobe o time no zellij no projeto `dir` (padrão: diretório atual) |
| `orchestra send <papel> "<tarefa>"` | Despacha tarefa **assíncrona** (`papel` = `coder` \| `reviewer`) |
| `orchestra result <papel>` | Mostra a última resposta do worker |
| `orchestra status` | Estado do servidor e das sessões |
| `orchestra down` | Encerra o servidor OpenCode |
| `orchestra uninstall` | Remove o Orchestra Agents por completo |
| `orchestra version` | Versão |

---

## ⚙️ Configuração

Variáveis de ambiente ou `~/.config/orchestra-agents/config` (formato shell):

| Variável | Padrão | Descrição |
|----------|--------|-----------|
| `ORCHESTRA_MODEL` | `deepseek/deepseek-v4-pro` | Modelo `provider/model` (precisa estar configurado no OpenCode) |
| `ORCHESTRA_CODER_AGENT` | `build` | Agente do CODER |
| `ORCHESTRA_REVIEWER_AGENT` | `reviewer` | Agente do REVISOR |
| `ORCHESTRA_PORT` | `4096` | Porta do servidor OpenCode |
| `ORCHESTRA_HOST` | `127.0.0.1` | Host do servidor |
| `ORCHESTRA_HOME` | `~/.orchestra-agents` | Diretório de instalação |
| `ORCHESTRA_STATE` | `~/.local/state/orchestra-agents` | Estado de runtime (ids de sessão, logs) |

Exemplo `~/.config/orchestra-agents/config`:

```sh
ORCHESTRA_MODEL="anthropic/claude-sonnet-4-6"
ORCHESTRA_REVIEWER_AGENT="reviewer"
```

---

## 🖼️ Sobre o logo do OpenCode

A logo do OpenCode aparece na **tela inicial (home)**, que é mostrada quando a sessão está **vazia**. O `orchestra up` cria **sessões frescas** a cada subida, então você vê o logo até despachar a primeira tarefa — depois a TUI entra na visão de conversa (comportamento padrão do OpenCode).

---

## 🗑️ Desinstalação

Remove tudo (CLI, PATH configurado, layout, estado, config e o diretório de instalação):

```bash
orchestra uninstall
# ou, se preferir via curl:
curl -fsSL https://raw.githubusercontent.com/orcioly/orchestra-agents/main/uninstall.sh | bash
```

> zellij, Claude Code e OpenCode **não** são removidos — são ferramentas gerais que você pode usar fora do Orchestra.

---

## 🧩 Estrutura

```
orchestra-agents/
├── install.sh                   # instalador (curl | bash)
├── uninstall.sh                 # desinstalador
├── bin/orchestra                # CLI
├── lib/core.sh                  # núcleo: servidor, sessões, despacho async, uninstall
├── agents/
│   ├── leader.sh                # painel do LÍDER (Claude)
│   ├── leader-prompt.md         # instruções de orquestração (modo natural)
│   ├── attach-coder.sh          # painel CODER (OpenCode TUI)
│   └── attach-reviewer.sh       # painel REVISOR (OpenCode TUI)
├── layouts/
│   ├── team.kdl                 # zellij: LÍDER + CODER + REVISOR
│   └── solo.kdl                 # zellij: só o LÍDER
└── config/opencode.reviewer.jsonc  # agente reviewer de referência
```

---

## 🩺 Troubleshooting

- **`orchestra: command not found`** → adicione `~/.local/bin` ao `PATH`.
- **Servidor não sobe** → veja `~/.local/state/orchestra-agents/server.log`; confirme que o OpenCode está autenticado (`opencode auth`).
- **Worker não executa a tarefa** → confirme que `ORCHESTRA_MODEL` é um modelo válido/autenticado e que o agente (`build`/`reviewer`) existe no OpenCode.
- **Sem logo** → é esperado depois que a sessão tem mensagens; suba de novo com `orchestra up` para sessões frescas.

---

## 📄 Licença

MIT © 2026 orcioly
