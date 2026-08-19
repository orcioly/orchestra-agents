# 🎼 Orchestra Agents

[![smoke](https://github.com/orcioly/orchestra-agents/actions/workflows/smoke.yml/badge.svg)](https://github.com/orcioly/orchestra-agents/actions/workflows/smoke.yml)
[![version](https://img.shields.io/github/v/release/orcioly/orchestra-agents?sort=semver&label=version&color=blue)](https://github.com/orcioly/orchestra-agents/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/orcioly/orchestra-agents/pulls)

Um **orquestrador de IA** para o terminal: você monta um **time de agentes** — um **líder
(maestro)** e quantos workers quiser — e cada um roda como **TUI real**, lado a lado, dentro
do **zellij**.

O time é **inteiramente seu**: você escolhe quantos agentes, o nome de cada um, o que cada um
faz (um papel pronto ou uma função que você escreve) e qual IA o roda — **Claude Code**,
**OpenCode** ou **Codex**, inclusive para o líder. Os três abaixo são só um exemplo.

O líder despacha tarefas de forma **assíncrona** (não bloqueia, não queima token esperando)
e os workers trabalham em paralelo, com tudo visível ao vivo. Trocar a IA de um agente
não muda nada no seu fluxo — os comandos são idênticos.

```
┌───────────────────────────────────────────────────────────┐
│ 🎼 LÍDER                    a IA é sua escolha            │
├──────────────┬──────────────┬──────────────┬──────────────┤
│ 🔧 CODER     │ 🔍 REVIEWER  │ ✨ PR        │    +         │
│ papel pronto │ papel pronto │ função sua   │ quantos você │
│ IA à escolha │ IA à escolha │ IA à escolha │ quiser       │
└──────────────┴──────────────┴──────────────┴──────────────┘
   nada aqui é fixo: você define quantos agentes, o nome, a função
   e a IA (claude, opencode ou codex) de cada um — no menu, ao subir
```

Ao rodar `orchestra`, um **menu com setas** deixa você montar o time do projeto: trocar a IA
de cada agente, adicionar e remover agentes. A composição fica salva em
`.orchestra/team.json`, **dentro do projeto** — e pode ser versionada com ele.

---

## ✨ Como funciona

Não há servidor, porta nem daemon. Cada agente é uma **TUI local** num painel do zellij, e o
líder conversa com ela pelo próprio multiplexador:

1. `orchestra send coder "…"` **injeta a tarefa no painel** do coder (como uma colagem) e
   submete. Retorna na hora — o líder não fica parado.
2. O worker trabalha **ao vivo**, na TUI, e você vê tudo acontecendo.
3. Ao concluir, o worker executa `orchestra done coder <id>` devolvendo a resposta final.
4. O líder pega o resultado com `orchestra await coder` (bloqueante e barato) ou
   `orchestra result coder` (não-bloqueante).

Como não existe id de sessão guardado, dar `/clear`, `/new`, mover o painel ou redimensionar
**não quebra** o despacho. E se um painel morrer, ele é **recriado automaticamente** — cada
painel roda sob um supervisor que reinicia a TUI retomando a conversa anterior.

---

## ✅ Pré-requisitos

| Requisito | Como obter |
|-----------|-----------|
| **Ao menos uma IA de agente** — Claude Code, OpenCode ou Codex | <https://docs.claude.com/claude-code> · <https://opencode.ai> · <https://developers.openai.com/codex/cli> |
| `git`, `python3` (e `curl`, só para o instalador) | já vêm na maioria das distros |
| **zellij** | instalado automaticamente pelo instalador |

> Você só precisa das IAs que for **usar**. Um time inteiro de Claude Code funciona sem
> OpenCode nem Codex instalados — e vice-versa. O `orchestra doctor` mostra o que falta.
>
> Se usar OpenCode, o instalador configura sozinho o agente **`reviewer`** (read-only) na sua
> config — veja [`config/opencode.reviewer.jsonc`](config/opencode.reviewer.jsonc).

---

## 🚀 Instalação

```bash
curl -fsSL https://raw.githubusercontent.com/orcioly/orchestra-agents/main/install.sh | bash
```

É só isso — **nenhuma configuração manual**. O instalador:
1. confere quais IAs você tem instaladas;
2. instala o **zellij** se faltar;
3. coloca os arquivos em `~/.orchestra-agents`;
4. instala o comando **`orchestra`** num diretório que **já está no seu `PATH`** (o mesmo do
   `claude`/`opencode`), então ele funciona na mesma sessão;
5. configura o `PATH` automaticamente (zsh/bash/fish) caso necessário;
6. registra o agente `reviewer` na config do OpenCode, se ele estiver instalado.

Depois de instalar, confira e suba:

```bash
orchestra doctor   # mostra o que está ok e o que falta (sai 0 se o essencial está certo)
cd ~/meu-projeto
orchestra          # precisa ser fora de uma sessão zellij
```

> **Rode `orchestra` a partir de um terminal normal**, não de dentro do zellij — ele recusa
> aninhar sessões e avisa.

### Atualizar

Rode o mesmo comando de instalação de novo. A instalação é substituída por completo, então
arquivos de versões antigas são removidos junto:

```bash
curl -fsSL https://raw.githubusercontent.com/orcioly/orchestra-agents/main/install.sh | bash
```

Um detalhe que economiza confusão: **painéis já abertos continuam rodando o código antigo**.
Depois de atualizar, encerre e suba de novo:

```bash
orchestra down
orchestra
```

Seu time (`.orchestra/team.json`) e seus prompts continuam onde estão — a atualização não
mexe neles.

---

## 🎬 Uso

```bash
cd ~/meu-projeto
orchestra                 # monta o time e abre o zellij

orchestra ~/outro-app     # ou aponte o projeto direto, sem trocar de pasta
```

### O menu do time

```
🎛️  Monte o time deste projeto
   /home/voce/meu-projeto

   AGENTE         O QUE FAZ                      IA QUE RODA
 ▸ 🎼 LÍDER       orquestra o time               claude, opencode, codex
   🔧 CODER       implementa código              claude, opencode, codex
   🔍 REVIEWER    code review (read-only)        claude, opencode, codex
   ✨ COMMIT      Faz commit e push.             claude, opencode, codex

   + adicionar agente
   ✖ sair sem abrir

   ↑/↓ navegar · ←/→ trocar a IA · a adicionar · d remover
   Enter abre o time no zellij · q sai sem abrir
```

**"IA" é qual CLI roda o agente** (Claude Code, OpenCode ou Codex) — não tem relação com
backend/frontend de software. O que o agente *faz* é a coluna **O QUE FAZ**, definida pelo
papel ou pelo texto que você escreve.

Para desistir: `q`, `Esc` ou a linha **sair** — nada é aberto e as trocas feitas na tela são
descartadas.

O time começa com **líder + coder + reviewer** e você ajusta à vontade. A escolha vale para
**aquele projeto** e fica em `.orchestra/team.json`.

> **Time inteiro num comando** (útil em projeto novo, e para pular o menu em CI):
>
> ```bash
> ORCHESTRA_TEAM="leader=claude,coder=codex,reviewer=opencode,tester=claude,docs=opencode,architect=claude,devops=codex" orchestra
> ```
>
> Sintaxe: `nome=ia` ou `nome=ia:papel` — o sufixo deixa um nome livre herdar um
> preset (`qa=claude:tester`). Nome sem preset e sem sufixo vira `custom`, com prompt
> editável em `.orchestra/prompts/<nome>.md`.

### Papéis prontos

Cada agente tem um **papel**, que define seu prompt de sistema:

| Papel | | O que faz |
|-------|---|-----------|
| `coder` | 🔧 | implementa código |
| `reviewer` | 🔍 | code review (read-only, por disciplina de prompt) |
| `tester` | 🧪 | escreve e roda testes |
| `docs` | 📚 | documentação e READMEs |
| `architect` | 📐 | arquitetura e decisões de design |
| `devops` | 🚀 | build, CI/CD e infraestrutura |

Qualquer outro nome vira um agente **`custom`**: você define o que ele faz, na hora.

```bash
# papel pronto
orchestra add tester --ia claude --role tester

# função sua, escrita na criação
orchestra add gitops --ia claude \
  --prompt "Cuida só de git: commit e push no padrão do repo. NUNCA edita código."

orchestra rm gitops
```

Sem `--prompt`, o agente custom nasce com um arquivo em `.orchestra/prompts/<nome>.md`
para você escrever depois. No menu, o `a` pergunta a mesma coisa: **nome → função → IA →
o que ele faz**. A IA nunca é adivinhada pelo nome — é sempre escolha sua.

O nome vira argumento de comando (`orchestra send deploy-prod "…"`), então segue uma regra
estrita: **minúsculas, sem espaços e sem acentos**, começando por letra, aceitando `-` e `_`
(ex.: `tester`, `deploy-prod`). O menu explica a regra e deixa você tentar de novo; o CLI diz
exatamente o que está errado.

O nome fica em minúsculas nos comandos (`orchestra send gitops "…"`) e aparece em
**MAIÚSCULAS** no painel, com o ícone do papel — igual aos demais: `✨ GITOPS`.

Todo agente, de qualquer IA, recebe automaticamente o mesmo **protocolo**: obedecer o líder e
devolver a resposta com `orchestra done`. Não há agente que fique de fora.

### O nome não define a função

Criar um agente chamado `pr` não o torna responsável por Pull Requests — o nome é só o
endereço do comando (`orchestra send pr "…"`). Quem ensina a função é a descrição:

```bash
orchestra add pr --ia claude \
  --prompt "Abre e atualiza Pull Requests no GitHub via gh. Não implementa features."
```

Isso alimenta **os dois lados**:

- o agente recebe a descrição como prompt de sistema, então sabe do que cuida;
- o líder recebe a mesma linha no roster do time, então sabe **quando** acionar aquele agente:

```
- ✨ PR (claude) — Abre e atualiza Pull Requests no GitHub via gh. Não implementa features.
```

Sem descrição, o agente nasce genérico e o líder o vê apenas como "agente customizado" — não
vai saber rotear nada para ele. Por isso o `add` avisa quando isso acontece, e o menu explica
antes de perguntar.

### O líder é avisado sozinho

Criar um agente com o time já no ar **não** exige que você conte nada a ele: a nota chega no
painel do líder na hora.

```
📣 líder avisado
```

O que ele recebe:

```
[ORCHESTRA] O time mudou: o agente 'pr' entrou agora (claude).
Função: Abre e atualiza Pull Requests no GitHub via gh.
Delegue com: orchestra send pr "<tarefa>"   ·   resultado: orchestra await pr
```

Vale também para o `orchestra rm` — o líder é avisado de que aquele agente saiu e para de
delegar para ele. Se o comando partiu do próprio painel do líder, nada é injetado (ele já
sabe: foi ele quem rodou).

O painel do agente novo abre **na mesma tela dos outros**, dividindo o espaço — nunca numa
janela flutuante por cima, nunca em outra aba. Mesmo que você esteja com o foco em outra aba
do zellij na hora, ele nasce junto do time.

### Modo natural (recomendado)

Depois de subir, **apenas converse com o líder** — ele já sobe conhecendo o time deste
projeto e delega sozinho:

```
você ▸ cria um endpoint POST /users com validação e depois manda revisar
líder ▸ delega ao CODER… (roda no painel ao lado) e depois ao REVIEWER
```

Você não precisa decorar comando nenhum. O líder despacha, busca os resultados com `await` e
reporta.

### Modo manual (controle fino)

```bash
orchestra send coder    "crie um endpoint POST /users com validação"
orchestra send reviewer "revise as últimas mudanças e aponte bugs"
orchestra await coder           # espera a resposta completa (bloqueante)
orchestra result coder          # vê a resposta quando quiser (não-bloqueante)
orchestra agents                # quem é quem e o estado de cada painel
orchestra down                  # encerra a sessão
```

### Comandos

| Comando | Descrição |
|---------|-----------|
| `orchestra` | Monta o time e abre o zellij no diretório atual |
| `orchestra <dir>` | O mesmo, para outro projeto: `orchestra ~/meu-app` |
| `orchestra send <agente> "<tarefa>"` | Despacha tarefa **assíncrona** |
| `orchestra result <agente>` | Última resposta do agente (não-bloqueante) |
| `orchestra result <agente> --wait [s]` | Bloqueia até a resposta completa (padrão: 300s) |
| `orchestra await <agente> [s]` | Alias de `result --wait` |
| `orchestra done <agente> <task>` | *(usado pelo agente)* devolve a resposta, lendo stdin |
| `orchestra agents` | Lista o time e o estado de cada painel |
| `orchestra add <nome> --ia <ia> [--role r] [--prompt "…"]` | Cria um agente e abre o painel |
| `orchestra rm <nome>` | Remove o agente e fecha o painel |
| `orchestra leader <ia>` | Troca a IA do líder |
| `orchestra heal` | Recria painéis que morreram ou foram fechados |
| `orchestra status` | Estado da sessão e dos agentes |
| `orchestra doctor` | Diagnostica pré-requisitos, IAs e painéis |
| `orchestra down` | Encerra a sessão do time |
| `orchestra uninstall` | Remove o Orchestra Agents por completo |
| `orchestra version` | Versão |

**Exit codes do `await` / `result --wait`** (o líder checa automaticamente):
`0` resposta completa · `1` erro de validação · `2` **timeout** (saída prefixada com
`[TIMEOUT/PARCIAL]`, **não confiável**) · `3` o agente reportou erro.

---

## 🩺 Diagnóstico (`orchestra doctor`)

```text
🩺 Orchestra Agents — diagnóstico

Base:
  ✔ zellij — /home/voce/.local/bin/zellij
  ✔ git — /usr/bin/git
  ✔ python3 — /usr/bin/python3

Backends de agente:
  ✔ claude disponível
  ✔ opencode disponível
  ! codex ausente — https://developers.openai.com/codex/cli

Time deste projeto (/home/voce/meu-projeto):
  ✔ líder → claude
  ✔ coder → opencode (coder)
  ✔ reviewer → opencode (reviewer)

Sessão ativa:
  ✔ multiplexador zellij no ar (sessão orchestra-meu-projeto-284…)
  ✔ painel de leader aberto
  ✔ painel de coder aberto
  ! painel de reviewer ausente — 'orchestra heal' recria

Orchestra:
  ✔ instalado em /home/voce/.orchestra-agents
  ✔ CLI no PATH — /home/voce/.local/bin/orchestra

Resumo: o essencial está ok, com 2 aviso(s).
```

| Símbolo | Significado |
|---------|-------------|
| ✔ | OK |
| ! | aviso — funciona, mas vale ajustar |
| ✖ | falha — algo essencial está faltando |

Sai com **`0`** quando não há falhas (mesmo com avisos) e **`1`** quando há ao menos um ✖.

---

## ⚙️ Configuração

### Modelos (importante)

O Orchestra **usa os modelos que você já tem configurados** — não força nenhum. Configurou no
Claude Code / OpenCode / Codex → é o que o Orchestra usa. Os overrides abaixo existem só se
você quiser fixar algo.

### Variáveis

Por ambiente ou em `~/.config/orchestra-agents/config` (formato shell):

| Variável | Padrão | Descrição |
|----------|--------|-----------|
| `ORCHESTRA_TEAM` | *(menu)* | Compõe o time sem TTY: `"leader=claude,coder=codex,tester=opencode"`. Definido = pula o menu |
| `ORCHESTRA_CODER` / `ORCHESTRA_REVIEWER` | *(vazio)* | Aliases herdados: fixam só a IA desses dois agentes |
| `ORCHESTRA_MODEL` | *(vazio)* | Override do modelo dos agentes **OpenCode** (`provider/modelo`) |
| `ORCHESTRA_CODEX_MODEL` | *(vazio)* | Override do modelo dos agentes **Codex** |
| `ORCHESTRA_MODEL_CLAUDE` | *(vazio)* | Override do modelo dos agentes **Claude Code** |
| `ORCHESTRA_TIMEOUT` | `300` | Timeout padrão (segundos) do `await` |
| `ORCHESTRA_CODEX_SANDBOX` | `workspace-write` | Sandbox dos agentes Codex |
| `ORCHESTRA_MUX` | `zellij` | Multiplexador (`stub` é usado pelos testes) |
| `ORCHESTRA_HOME` | `~/.orchestra-agents` | Diretório de instalação |
| `ORCHESTRA_STATE` | `~/.local/state/orchestra-agents` | Estado global (projeto, sessão do mux) |

Exemplo de `~/.config/orchestra-agents/config`:

```sh
ORCHESTRA_MODEL="anthropic/claude-sonnet-4-6"   # opcional — fixa o modelo dos agentes OpenCode
ORCHESTRA_TIMEOUT=600                           # opcional — tarefas longas
```

### O que fica dentro do projeto

```
meu-projeto/.orchestra/
├── team.json         # composição do time (VERSIONÁVEL)
├── prompts/<nome>.md # prompts dos agentes custom (VERSIONÁVEL)
└── run/              # runtime descartável (gitignorado automaticamente)
```

---

## 🗑️ Desinstalação

**Um comando só.** Ele faz tudo: encerra as sessões abertas (de todos os projetos), remove o
comando `orchestra`, as linhas de `PATH` que tiver criado, o estado, o diretório de instalação
e até o zellij — se tiver sido o instalador do Orchestra que o colocou aí.

```bash
orchestra uninstall
```

Ou, se o comando já não existir (ou você preferir):

```bash
curl -fsSL https://raw.githubusercontent.com/orcioly/orchestra-agents/main/uninstall.sh | bash
```

Você **não** precisa dar `orchestra down` antes, nem fechar painel nenhum.

O que ele **preserva**, de propósito:

| Preservado | Por quê |
|------------|---------|
| `.orchestra/` dos seus projetos | é a composição do seu time, sua — não do Orchestra |
| Claude Code, OpenCode, Codex | ferramentas suas, usadas fora do Orchestra |
| zellij que **você** já tinha | só é removido o que o instalador do Orchestra baixou |
| agente `reviewer` na config do OpenCode | é uma entrada na sua config; o caminho é mostrado no fim |

> Se for **reinstalar na mesma janela** do terminal, limpe o cache de comandos do shell —
> `hash -r` no bash, `rehash` no zsh. Sem isso ele ainda aponta para o binário removido e você
> vê um erro confuso. O próprio desinstalador lembra disso no fim.

### Reinstalar do zero

```bash
orchestra uninstall
hash -r 2>/dev/null || rehash 2>/dev/null || true
curl -fsSL https://raw.githubusercontent.com/orcioly/orchestra-agents/main/install.sh | bash
orchestra doctor
```

---

## 🧩 Estrutura

```
orchestra-agents/
├── install.sh                   # instalador (curl | bash)
├── uninstall.sh                 # desinstalador
├── bin/orchestra                # CLI
├── lib/
│   ├── core.sh                  # núcleo: despacho, resultados, gestão do time, doctor
│   ├── team.sh                  # modelo do time (.orchestra/team.json) e prompts
│   ├── mux.sh                   # abstração do multiplexador (zellij | stub)
│   └── layout.sh                # gera o layout KDL do time
├── agents/
│   ├── run-agent.sh             # launcher + supervisor de um agente (qualquer IA)
│   ├── leader-prompt.md         # instruções de orquestração do líder
│   ├── roles/*.md               # prompts dos papéis prontos
│   └── leader.sh, attach-*.sh   # compat shims → run-agent.sh
└── config/
    ├── opencode.reviewer.jsonc  # agente reviewer de referência
    └── merge_reviewer.py        # mescla esse agente na sua config do OpenCode
```

---

## 🧪 Testes

```bash
./tests/smoke.sh
```

Cobre sintaxe de todos os scripts, o modelo do time, composição por env, `add`/`rm`, prompts
de papel e roster, o ciclo completo `send → done → await`, exit codes, o layout gerado e o
`doctor`. Roda com `ORCHESTRA_MUX=stub` num projeto temporário — **não** encosta numa sessão
real nem chama modelo, então serve tanto local quanto no CI.

**CI (GitHub Actions):** [`.github/workflows/smoke.yml`](.github/workflows/smoke.yml) roda o
smoke test a cada push/PR na `main`, mais `shellcheck` de forma informativa.

---

## 🚢 Processo de release

O script [`scripts/release.sh`](scripts/release.sh) **calcula o próximo número** (semver),
atualiza o `VERSION` em `bin/orchestra`, faz o commit, cria a tag, dá push e publica a release
com notas automáticas:

```bash
./scripts/release.sh patch   # 0.2.0 -> 0.2.1
./scripts/release.sh minor   # 0.2.0 -> 0.3.0
./scripts/release.sh major   # 0.2.0 -> 1.0.0
./scripts/release.sh 1.2.3   # versão explícita
DRY_RUN=1 ./scripts/release.sh minor   # só mostra o que faria
```

> A publicação precisa do `gh` autenticado como dono do repo; sem isso, o script cria a tag e
> mostra o comando para finalizar.

---

## 🩺 Troubleshooting

- **`orchestra: command not found`** → adicione `~/.local/bin` ao `PATH`.
- **Painel sumiu / foi fechado** → `orchestra heal` recria. O próprio `send` também recria o
  painel do agente se ele estiver faltando.
- **O painel reinicia sozinho em loop** → a IA daquele painel está falhando ao subir (binário ausente ou
  flag inválida). Depois de 3 falhas rápidas o supervisor para e libera um shell; rode
  `orchestra doctor`.
- **`[TIMEOUT/PARCIAL]` na resposta** → o worker não chamou `orchestra done`. Aumente o
  timeout (`orchestra await coder 600`) ou reenvie a tarefa. **Nunca** trate esse texto como
  resposta final.
- **`⚠️ você já está dentro de uma sessão zellij`** → saia para um terminal normal antes de
  rodar `orchestra` (evita aninhar sessões).

---

## 🤝 Contribuindo

Contribuições são bem-vindas! Veja o **[CONTRIBUTING.md](CONTRIBUTING.md)** para setup, testes
e o fluxo de PR.

As mensagens de commit são em inglês e adotam, **como referência de convenção**, o guia
**[Padrões de Commits (iuricode)](https://github.com/iuricode/padroes-de-commits)** (emoji + tipo).

---

## 📄 Licença

MIT © 2026 orcioly
