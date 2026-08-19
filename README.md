# 🎼 Orchestra Agents

[![smoke](https://github.com/orcioly/orchestra-agents/actions/workflows/smoke.yml/badge.svg)](https://github.com/orcioly/orchestra-agents/actions/workflows/smoke.yml)
[![version](https://img.shields.io/github/v/release/orcioly/orchestra-agents?sort=semver&label=version&color=blue)](https://github.com/orcioly/orchestra-agents/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/orcioly/orchestra-agents/pulls)

Um **orquestrador de IA** para o terminal: o **Claude Code** atua como **líder (maestro)** e coordena dois **workers** — um **CODER** (executor) e um **REVISOR** (code review) — cada um rodando como **TUI real**, lado a lado, dentro do **zellij**. Para cada papel você escolhe o backend: **OpenCode** ou **Codex**.

O líder despacha tarefas de forma **assíncrona** (não bloqueia, não fica gastando token esperando) e os workers trabalham em paralelo, com tudo visível ao vivo. Trocar o backend não muda nada no seu fluxo — os comandos são idênticos.

```
┌─────────────────────────────────────────────────────────────┐
│             LÍDER (Claude Code) — você orquestra            │
├──────────────────────────────┬──────────────────────────────┤
│  CODER                       │  REVISOR                     │
│  backend: opencode | codex   │  backend: opencode | codex   │
└──────────────────────────────┴──────────────────────────────┘
   zellij + servidor OpenCode (:4096) e/ou Codex app-server
```

Ao rodar `orchestra up`, o Orchestra **pergunta** qual backend usar em cada papel (a última escolha vira o padrão). Dá para pré-definir via env `ORCHESTRA_CODER` / `ORCHESTRA_REVIEWER` (útil em CI).

---

## ✨ Como funciona

Cada papel roda como **TUI real** attachada a um **servidor compartilhado**, e o líder injeta tarefas de forma **assíncrona** — igual para os dois backends:

- **OpenCode:** `opencode serve` sobe um servidor headless (porta `4096`); o worker é `opencode attach <url> --session <id>`; o líder despacha via `POST /session/:id/prompt_async`.
- **Codex:** `codex app-server --listen unix://<sock>` sobe o servidor; o worker é `codex --remote unix://<sock> resume <thread>` (mesmo thread → as tarefas do líder aparecem ao vivo na TUI); o líder despacha via JSON-RPC (`thread/start`/`turn/start`).
- Resultados são lidos via `orchestra result <papel> --wait` (bloqueante, eficiente — o líder encadeia automaticamente) ou `orchestra result <papel>` (sob demanda, não-bloqueante).

---

## ✅ Pré-requisitos

Você precisa ter, **já instalados e configurados**:

| Requisito | Como obter |
|-----------|-----------|
| **Claude Code** | <https://docs.claude.com/claude-code> |
| **OpenCode** (autenticado, com um modelo configurado) | <https://opencode.ai> |
| `git`, `curl`, `python3` | já vêm na maioria das distros |
| **Codex CLI** (autenticado) — *opcional* | <https://developers.openai.com/codex/cli> |

> O **zellij** é instalado automaticamente pelo instalador se você ainda não tiver.
> O **Codex** só é necessário se você escolher `codex` como coder/reviewer; caso contrário, ignore-o.

O OpenCode precisa de um agente **`reviewer`** (read-only). Veja [`config/opencode.reviewer.jsonc`](config/opencode.reviewer.jsonc) — o instalador avisa se ele estiver faltando. (No backend Codex, o papel de revisor read-only é aplicado automaticamente via sandbox `read-only`.)

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
orchestra          # pergunta o backend de cada papel e abre o zellij:
                   # LÍDER (Claude) em cima, CODER | REVISOR embaixo
```

Ao subir, o Orchestra pergunta o backend de cada papel (Enter aceita o padrão / última escolha):

```
🎛️  Escolha os workers deste time:
  coder     [1] opencode  [2] codex  (padrão: opencode) > 2
  reviewer  [1] opencode  [2] codex  (padrão: opencode) > 
    coder=codex · reviewer=opencode
```

> `orchestra` sozinho já entra (equivale a `orchestra up` no diretório atual).
> Para pular a pergunta (CI/scripts): `ORCHESTRA_CODER=codex ORCHESTRA_REVIEWER=opencode orchestra up`.

### Modo natural (recomendado)

Depois do `orchestra up`, **apenas converse com o Claude** no painel do LÍDER — ele já sobe sabendo orquestrar e delega sozinho:

```
você ▸ cria um endpoint POST /users com validação e depois manda revisar
Claude (LÍDER) ▸ delega ao CODER... (roda no painel ao lado) e depois ao REVISOR
```

Você não precisa decorar comando nenhum. O líder despacha de forma assíncrona, busca os resultados automaticamente com `--wait` e reporta.

### Modo manual (controle fino)

Se quiser comandar na unha:

```bash
orchestra send coder    "crie um endpoint POST /users com validação"
orchestra send reviewer "revise as últimas mudanças e aponte bugs"
orchestra result coder --wait   # espera a resposta completa (bloqueante)
orchestra result coder          # vê a resposta quando quiser (não-bloqueante)
orchestra await coder           # alias de result --wait
orchestra status        # estado do servidor/sessões
orchestra down          # encerra o servidor
```

### Comandos

| Comando | Descrição |
|---------|-----------|
| `orchestra` | Atalho para `orchestra up` no diretório atual |
| `orchestra up [dir]` | Sobe o time no zellij no projeto `dir` (padrão: diretório atual) |
| `orchestra send <papel> "<tarefa>"` | Despacha tarefa **assíncrona** (`papel` = `coder` \| `reviewer`) |
| `orchestra result <papel>` | Mostra a última resposta do worker (não-bloqueante) |
| `orchestra result <papel> --wait [s]` | Bloqueia até resposta completa (padrão: 300s) |
| `orchestra await <papel> [s]` | Alias de `result --wait` |
| `orchestra status` | Estado dos servidores, backend e sessões/threads de cada papel |
| `orchestra down` | Encerra os servidores (OpenCode e/ou Codex app-server) |
| `orchestra uninstall` | Remove o Orchestra Agents por completo |
| `orchestra version` | Versão |

---

## 🩺 Diagnóstico (`orchestra doctor`)

Antes de subir o time — ou quando algo não funciona — rode:

```bash
orchestra doctor
```

Ele verifica, em três blocos, tudo que o Orchestra precisa:

**Pré-requisitos** (binários no `PATH`):
- `claude`, `opencode`, `zellij`, `git`, `python3`, `curl` — mostra o caminho de cada um ou aponta o que falta (com o link de instalação).

**OpenCode** (relativo ao **modelo efetivo** — o forçado em `ORCHESTRA_MODEL`, ou o default da sua config do OpenCode):
- **provider autenticado** — confere se o provider do modelo está em `~/.local/share/opencode/auth.json`; senão sugere `opencode auth login`.
- **modelo disponível** — confere se o modelo efetivo aparece em `opencode models`.
- **agente revisor** — confere se o agente `reviewer` existe em `~/.config/opencode/opencode.jsonc`.

**Orchestra**:
- instalação presente em `~/.orchestra-agents`;
- comando `orchestra` acessível no `PATH`;
- estado do **servidor** OpenCode (no ar ou parado — ele sobe sozinho no `orchestra`).

### Exemplo de saída

```text
🩺 Orchestra Agents — diagnóstico

Pré-requisitos:
  ✔ claude — /home/voce/.local/bin/claude
  ✔ opencode — /home/voce/.opencode/bin/opencode
  ✔ zellij — /home/voce/.local/bin/zellij
  ✔ git — /usr/bin/git
  ✔ python3 — /usr/bin/python3
  ✔ curl — /usr/bin/curl

OpenCode (modelo: deepseek/deepseek-v4-pro — default do OpenCode):
  ✔ provider 'deepseek' autenticado
  ✔ modelo 'deepseek/deepseek-v4-pro' disponível
  ✔ agente revisor 'reviewer' configurado

Orchestra:
  ✔ instalado em /home/voce/.orchestra-agents
  ✔ CLI no PATH — /home/voce/.local/bin/orchestra
  ! servidor parado (sobe ao rodar 'orchestra')

Resumo: o essencial está ok, com 1 aviso(s).
```

### Legenda e código de saída

| Símbolo | Significado |
|---------|-------------|
| ✔ | OK |
| ! | aviso — funciona, mas vale ajustar (ex.: servidor parado, modelo diferente) |
| ✖ | falha — algo essencial está faltando |

- **Exit code `0`** quando não há falhas (mesmo com avisos).
- **Exit code `1`** quando há ao menos uma falha ✖ — útil em scripts de CI/checagem.

---

## ⚙️ Configuração

### Modelos (importante)

O Orchestra **usa os modelos que você já tem configurados** — não força nenhum:

- **Workers (OpenCode):** por padrão **nenhum modelo é enviado**, então o OpenCode usa o **modelo default da sua config** (`~/.config/opencode/opencode.jsonc`) ou o do próprio agente. Quer forçar um modelo específico? Defina `ORCHESTRA_MODEL="provider/modelo"`.
- **Workers (Codex):** por padrão usa o **modelo default do Codex**. Para forçar, defina `ORCHESTRA_CODEX_MODEL="nome-do-modelo"`.
- **Líder (Claude Code):** sobe com `claude` **sem `--model`**, então usa o **modelo que você configurou no Claude Code**.

Resumo: configurou no OpenCode/Codex/Claude → é o que o Orchestra usa.

### Variáveis

Por ambiente ou em `~/.config/orchestra-agents/config` (formato shell):

| Variável | Padrão | Descrição |
|----------|--------|-----------|
| `ORCHESTRA_CODER` | *(pergunta)* | Backend do CODER: `opencode` \| `codex`. Definido = pula a pergunta no `up` |
| `ORCHESTRA_REVIEWER` | *(pergunta)* | Backend do REVISOR: `opencode` \| `codex`. Definido = pula a pergunta no `up` |
| `ORCHESTRA_MODEL` | *(vazio)* | **Override opcional** do modelo dos workers **OpenCode** (`provider/modelo`). Vazio = default do OpenCode |
| `ORCHESTRA_CODEX_MODEL` | *(vazio)* | **Override opcional** do modelo dos workers **Codex** (nome do modelo). Vazio = default do Codex |
| `ORCHESTRA_CODER_AGENT` | `build` | Agente do CODER (só backend OpenCode) |
| `ORCHESTRA_REVIEWER_AGENT` | `reviewer` | Agente do REVISOR (só backend OpenCode) |
| `ORCHESTRA_PORT` | `4096` | Porta do servidor OpenCode |
| `ORCHESTRA_HOST` | `127.0.0.1` | Host do servidor OpenCode |
| `ORCHESTRA_CODEX_SOCK` | `$ORCHESTRA_STATE/codex.sock` | Socket Unix do Codex app-server |
| `ORCHESTRA_HOME` | `~/.orchestra-agents` | Diretório de instalação |
| `ORCHESTRA_STATE` | `~/.local/state/orchestra-agents` | Estado de runtime (sessões/threads, backend, logs) |

Exemplo `~/.config/orchestra-agents/config` (só se quiser forçar algo):

```sh
ORCHESTRA_CODER="codex"                         # opcional — fixa o backend do coder
ORCHESTRA_REVIEWER="opencode"                   # opcional — fixa o backend do reviewer
ORCHESTRA_MODEL="anthropic/claude-sonnet-4-6"   # opcional — força este modelo nos workers OpenCode
ORCHESTRA_REVIEWER_AGENT="reviewer"
```

---

## 🖼️ Sobre o logo do OpenCode

Os painéis CODER/REVISOR abrem **direto na visão de sessão** do OpenCode (via `opencode attach --session`), e não na tela "home" — por isso o **logo/splash grande não aparece**. Isso é **esperado**, não é bug: o `--session` é justamente o que permite o líder mirar a sessão pela API e você ver o trabalho **ao vivo** na própria TUI. O logo do OpenCode só é exibido na home (ao abrir **sem** sessão), o que é incompatível com esse modelo de orquestração. Mesmo assim os painéis ficam claramente identificados como OpenCode (modelo, sidebar e o rodapé `OpenCode x.y.z`).

> O `orchestra up` cria **sessões frescas** a cada subida — não pelo logo, mas para começar com um **contexto limpo**.

---

## 🗑️ Desinstalação

Remove tudo (CLI, PATH configurado, layout, estado, config e o diretório de instalação):

```bash
orchestra uninstall
# ou, se preferir via curl:
curl -fsSL https://raw.githubusercontent.com/orcioly/orchestra-agents/main/uninstall.sh | bash
```

> zellij, Claude Code, OpenCode e Codex **não** são removidos — são ferramentas gerais que você pode usar fora do Orchestra.

---

## 🧩 Estrutura

```
orchestra-agents/
├── install.sh                   # instalador (curl | bash)
├── uninstall.sh                 # desinstalador
├── bin/orchestra                # CLI
├── lib/core.sh                  # núcleo: servidores, sessões/threads, despacho async, backends
├── lib/codex_client.py          # cliente JSON-RPC do Codex app-server (thread/turn)
├── agents/
│   ├── leader.sh                # painel do LÍDER (Claude)
│   ├── leader-prompt.md         # instruções de orquestração (modo natural)
│   ├── attach-worker.sh         # painel CODER/REVISOR (backend-aware: OpenCode | Codex)
│   ├── attach-coder.sh          # compat shim → attach-worker.sh coder
│   └── attach-reviewer.sh       # compat shim → attach-worker.sh reviewer
├── layouts/
│   ├── team.kdl                 # zellij: LÍDER + CODER + REVISOR
│   └── solo.kdl                 # zellij: só o LÍDER
└── config/opencode.reviewer.jsonc  # agente reviewer de referência
```

---

## 🧪 Testes

Um smoke test valida sintaxe dos scripts, `orchestra doctor` e um despacho async real:

```bash
./tests/smoke.sh                 # completo (precisa de OpenCode autenticado)
SKIP_DISPATCH=1 ./tests/smoke.sh # só sintaxe + doctor (sem chamar modelo)
```

É isolado: usa estado próprio e roda num projeto temporário em `/tmp`, **sem** encerrar um Orchestra que já esteja rodando. Sai com código `0` (ok) ou `1` (falha).

**CI (GitHub Actions):** o workflow [`.github/workflows/smoke.yml`](.github/workflows/smoke.yml) roda o smoke test a cada push/PR na `main`. Como o runner não tem `claude`/`opencode`/`zellij`, os passos de `doctor` e despacho são **pulados automaticamente** — o CI valida a **sintaxe** de todos os scripts (e roda `shellcheck` de forma informativa).

---

## 🚢 Processo de release

**Forma automática (recomendada).** O script [`scripts/release.sh`](scripts/release.sh) **calcula o próximo número** (semver), atualiza o `VERSION` em `bin/orchestra`, faz o commit, cria a tag, dá push e publica a release com **notas geradas automaticamente**:

```bash
./scripts/release.sh patch   # 0.1.0 -> 0.1.1
./scripts/release.sh minor   # 0.1.0 -> 0.2.0
./scripts/release.sh major   # 0.1.0 -> 1.0.0
./scripts/release.sh 1.2.3   # versão explícita
DRY_RUN=1 ./scripts/release.sh minor   # só mostra o que faria
```

> Você não precisa digitar o número — o script incrementa sozinho a partir do `VERSION` atual. A publicação da release precisa do `gh` autenticado como dono do repo; sem isso, ele cria a tag e mostra o comando para finalizar.

<details>
<summary>Passo a passo manual (equivalente)</summary>

1. Atualize `VERSION="X.Y.Z"` em `bin/orchestra`.
2. `git commit -am "🔖 chore: bump version to vX.Y.Z"`
3. `git tag -a vX.Y.Z -m "Orchestra Agents vX.Y.Z" && git push origin main --follow-tags`
4. `gh release create vX.Y.Z --verify-tag --title "vX.Y.Z" --generate-notes` (ou pela web: Releases → Draft a new release → escolha a tag → Publish)

O badge de versão (`github/v/release`) e o link "latest" atualizam sozinhos.
</details>

---

## 🩺 Troubleshooting

- **`orchestra: command not found`** → adicione `~/.local/bin` ao `PATH`.
- **Servidor não sobe** → veja `~/.local/state/orchestra-agents/server.log`; confirme que o OpenCode está autenticado (`opencode auth`).
- **Worker não executa a tarefa** → confirme que `ORCHESTRA_MODEL` é um modelo válido/autenticado e que o agente (`build`/`reviewer`) existe no OpenCode.
- **Sem logo** → é esperado depois que a sessão tem mensagens; suba de novo com `orchestra up` para sessões frescas.

---

## 🤝 Contribuindo

Contribuições são bem-vindas! Veja o **[CONTRIBUTING.md](CONTRIBUTING.md)** para setup, testes e o fluxo de PR.

As mensagens de commit são em inglês e adotam, **como referência de convenção**, o guia **[Padrões de Commits (iuricode)](https://github.com/iuricode/padroes-de-commits)** (emoji + tipo).

---

## 📄 Licença

MIT © 2026 orcioly
