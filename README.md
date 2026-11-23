# 🎼 Orchestra Agents

[![smoke](https://github.com/orcioly/orchestra-agents/actions/workflows/smoke.yml/badge.svg)](https://github.com/orcioly/orchestra-agents/actions/workflows/smoke.yml)
[![version](https://img.shields.io/github/v/release/orcioly/orchestra-agents?sort=semver&label=version&color=blue)](https://github.com/orcioly/orchestra-agents/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/orcioly/orchestra-agents/pulls)

An **AI orchestrator** for the terminal: you build a **team of agents**, with a **leader
(the conductor)** and as many workers as you like, and each one runs as a **real TUI**, side
by side, inside **zellij**.

The team is **entirely yours**: you choose how many agents, the name of each one, what each
one does (a ready-made role or a function you write) and which AI runs it: **Claude Code**,
**OpenCode** or **Codex**, the leader included. The three below are just an example.

The leader dispatches tasks **asynchronously** (it doesn't block, and it doesn't burn tokens
waiting) and the workers run in parallel, with everything visible live. Swapping the AI of an
agent changes nothing in your workflow: the commands are identical.

```
┌───────────────────────────────────────────────────────────┐
│ 🎼 LEADER                   your AI of choice             │
├──────────────┬──────────────┬──────────────┬──────────────┤
│ 🔧 CODER     │ 🔍 REVIEWER  │ ✨ PR        │    +         │
│ preset role  │ preset role  │ your role    │ as many as   │
│ any AI       │ any AI       │ any AI       │ you want     │
└──────────────┴──────────────┴──────────────┴──────────────┘
   nothing here is fixed: you set how many agents, the name, the role
   and the AI (claude, opencode or codex) of each one, in the menu, at startup
```

When you run `orchestra`, an **arrow-key menu** lets you build the project's team: switch the
AI of each agent, add and remove agents. The composition is saved **outside the project**,
in `~/.local/state/orchestra-agents/projects/<project>/team.json`: Orchestra writes no file
into your code folder.

---

## ✨ How it works

There is no server, port or daemon. Each agent is a **local TUI** in a zellij pane, and the
leader talks to it through the multiplexer itself:

1. `orchestra send coder "…"` **injects the task into the coder's pane** (as a paste) and
   submits it. It returns immediately, so the leader is never stuck waiting.
2. The worker works **live**, in the TUI, and you see everything happening.
3. When finished, the worker runs `orchestra done coder <id>`, handing back the final answer.
4. The leader picks up the result with `orchestra await coder` (blocking and cheap) or
   `orchestra result coder` (non-blocking).

Since no session id is stored, running `/clear`, `/new`, moving the pane or resizing it
**does not break** dispatching. And if a pane dies, it is **recreated automatically**: each
pane runs under a supervisor that restarts the TUI, resuming the previous conversation.

---

## ✅ Prerequisites

| Requirement | How to get it |
|-------------|---------------|
| **System**: Linux or macOS natively; Windows via WSL2 | see [Windows (via WSL)](#windows-via-wsl) |
| **At least one agent AI**: Claude Code, OpenCode or Codex | <https://docs.claude.com/claude-code> · <https://opencode.ai> · <https://developers.openai.com/codex/cli> |
| `git`, `python3` (and `curl`, for the installer only) | already shipped with most distros |
| **zellij** | installed automatically by the installer |

> You only need the AIs you are going to **use**. A whole team of Claude Code works without
> OpenCode or Codex installed, and vice versa. `orchestra doctor` shows what is missing.
>
> If you use OpenCode, the installer configures the **`reviewer`** agent (read-only) in your
> config for you. See [`config/opencode.reviewer.jsonc`](config/opencode.reviewer.jsonc).

---

## 🚀 Installation

### Linux and macOS

```bash
curl -fsSL https://raw.githubusercontent.com/orcioly/orchestra-agents/main/install.sh | bash
```

That's it, with **no manual configuration**. The installer:
1. checks which AIs you have installed;
2. installs **zellij** if it is missing;
3. puts the files in `~/.orchestra-agents`;
4. installs the **`orchestra`** command in a directory that is **already on your `PATH`**
   (the same one as `claude`/`opencode`), so it works in the same session;
5. configures the `PATH` automatically (zsh/bash/fish) when needed;
6. registers the `reviewer` agent in the OpenCode config, if OpenCode is installed.

After installing, check and launch:

```bash
orchestra doctor   # shows what is ok and what is missing (exits 0 if the essentials are fine)
cd ~/my-project
orchestra          # must be run outside a zellij session
```

> **Run `orchestra` from a regular terminal**, not from inside zellij: it refuses to nest
> sessions and says so.

### Windows (via WSL)

Orchestra is written in bash and uses Unix tools that Command Prompt and PowerShell do not
have. That is why, on Windows, it runs inside **WSL**, which is real Linux. In practice:
you install WSL once and, from then on, everything works the same as on Linux.

**1. Install WSL first.** In PowerShell, **as administrator**:

```powershell
wsl --install
```

Restart the computer and open Ubuntu once, to create your user.

**2. Install the AIs inside WSL.** In Ubuntu, install and authenticate `claude`, `opencode`
or `codex`. The versions installed on Windows **will not work**, because the panes are Linux processes.

**3. Follow the same steps as on Linux**, now inside Ubuntu: [installation above](#linux-and-macos).

If you would rather not enter WSL, you can install straight from PowerShell or Command Prompt:

```powershell
wsl bash -lc "curl -fsSL https://raw.githubusercontent.com/orcioly/orchestra-agents/main/install.sh | bash"
```

**To use it afterwards:** `orchestra` inside WSL, or `wsl orchestra` from PowerShell/cmd,
without having to enter Linux.

> Use **Windows Terminal** (the default on Windows 11, and in the Microsoft Store on
> Windows 10). It draws the pane borders and icons correctly; the old black Command Prompt
> window does not.
>
> Keep the project **inside** WSL (`~/my-app`). Under `/mnt/c` it works, but I/O is much
> slower.

### Updating

Run the same install command again. The installation is replaced entirely, so files from
old versions are removed along with it:

```bash
curl -fsSL https://raw.githubusercontent.com/orcioly/orchestra-agents/main/install.sh | bash
```

One detail that saves confusion: **panes that are already open keep running the old code**.
After updating, shut down and start again:

```bash
orchestra down
orchestra
```

Your team and your prompts stay where they are: they live in
`~/.local/state/orchestra-agents/projects/`, outside the installation folder, and the update
does not touch them.

---

## 🗑️ Uninstallation

**A single command.** It does everything: it ends the open sessions (of all projects) and
removes the `orchestra` command, the `PATH` lines it created, the state, the installation
directory and even zellij, if it was the Orchestra installer that put it there.

```bash
orchestra uninstall
```

Or, if the command no longer exists (or you prefer):

```bash
curl -fsSL https://raw.githubusercontent.com/orcioly/orchestra-agents/main/uninstall.sh | bash
```

You do **not** need to run `orchestra down` first, nor close any pane.

On **Windows**, it is the same command inside WSL, or `wsl orchestra uninstall` straight from
PowerShell. WSL itself is not removed: it is yours, not Orchestra's.

What it **preserves**, on purpose:

| Preserved | Why |
|-----------|-----|
| Claude Code, OpenCode, Codex | your own tools, used outside Orchestra |
| zellij that **you** already had | only what the Orchestra installer downloaded is removed |

Apart from that, `orchestra uninstall` removes **everything** Orchestra put on the machine:
the installation, the teams and prompts of every project, the command symlink, the PATH lines
in your `rc` files, the zellij layout, the `reviewer` agent it added to the OpenCode config
and **zellij itself, if it was the one that installed it**. Your projects keep nothing from
Orchestra, so nothing is left behind in them.

The installer records each thing it installs and by which means (`brew`, official binary or
`cargo`), and the uninstall undoes each one by the same means, on the operating system you
are on. What already existed on the machine beforehand is not recorded, and therefore is
never removed. Your personal zellij configuration (`~/.config/zellij`) also stays.
| `reviewer` agent in the OpenCode config | it is an entry in your config; the path is shown at the end |

> If you are going to **reinstall in the same terminal window**, clear the shell's command
> cache: `hash -r` in bash, `rehash` in zsh. Without it the shell still points to the removed
> binary and you see a confusing error. The uninstaller itself reminds you of this at the end.

### Reinstalling from scratch

```bash
orchestra uninstall
hash -r 2>/dev/null || rehash 2>/dev/null || true
curl -fsSL https://raw.githubusercontent.com/orcioly/orchestra-agents/main/install.sh | bash
orchestra doctor
```

---

## 🎬 Usage

```bash
cd ~/my-project
orchestra                 # builds the team and opens zellij

orchestra ~/other-app     # or point at the project directly, without changing folder
```

### The team menu

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

**"IA" (AI) is which CLI runs the agent** (Claude Code, OpenCode or Codex). It has nothing to
do with software backend/frontend. What the agent *does* is the **O QUE FAZ** (what it does)
column, defined by the role or by the text you write.

To back out: `q`, `Esc` or the **sair** (quit) line. Nothing is opened and the changes made
on screen are discarded.

The team starts with **leader + coder + reviewer** and you adjust it freely. The choice
applies to **that project** and is kept in `~/.local/state/orchestra-agents/projects/<project>/team.json`.

> **The whole team in one command** (useful in a new project, and to skip the menu in CI):
>
> ```bash
> ORCHESTRA_TEAM="leader=claude,coder=codex,reviewer=opencode,tester=claude,docs=opencode,architect=claude,devops=codex" orchestra
> ```
>
> Syntax: `name=ai` or `name=ai:role`. The suffix lets a free-form name inherit a
> preset (`qa=claude:tester`). A name with no preset and no suffix becomes `custom`, with a
> prompt you can edit at `~/.local/state/orchestra-agents/projects/<project>/prompts/<name>.md`.

### Ready-made roles

Each agent has a **role**, which defines its system prompt:

| Role | | What it does |
|------|---|--------------|
| `coder` | 🔧 | implements code |
| `reviewer` | 🔍 | code review (read-only, by prompt discipline) |
| `tester` | 🧪 | writes and runs tests |
| `docs` | 📚 | documentation and READMEs |
| `architect` | 📐 | architecture and design decisions |
| `devops` | 🚀 | build, CI/CD and infrastructure |

Any other name becomes a **`custom`** agent: you define what it does, on the spot.

```bash
# ready-made role
orchestra add tester --ia claude --role tester

# your own function, written at creation
orchestra add gitops --ia claude \
  --prompt "Cuida só de git: commit e push no padrão do repo. NUNCA edita código."

orchestra rm gitops
```

Without `--prompt`, the custom agent is born with a file at `prompts/<name>.md` (inside the
project's directory in Orchestra; `add` shows the full path) for you to write in later. In
the menu, `a` asks the same thing: **name → role → AI →
what it does**. The AI is never guessed from the name: it is always your choice.

The name becomes a command argument (`orchestra send deploy-prod "…"`), so it follows a
strict rule: **lowercase, no spaces and no accents**, starting with a letter, allowing `-`
and `_` (e.g. `tester`, `deploy-prod`). The menu explains the rule and lets you try again;
the CLI says exactly what is wrong.

The name stays lowercase in commands (`orchestra send gitops "…"`) and shows up in
**UPPERCASE** in the pane, with the role icon, like the others: `✨ GITOPS`.

Every agent, of any AI, automatically receives the same **protocol**: obey the leader and
hand back the answer with `orchestra done`. No agent is left out.

### The name does not define the function

Creating an agent called `pr` does not make it responsible for Pull Requests. The name is
just the command's address (`orchestra send pr "…"`). What teaches the function is the
description:

```bash
orchestra add pr --ia claude \
  --prompt "Abre e atualiza Pull Requests no GitHub via gh. Não implementa features."
```

This feeds **both sides**:

- the agent receives the description as its system prompt, so it knows what it handles;
- the leader receives the same line in the team roster, so it knows **when** to call that agent:

```
- ✨ PR (claude): Abre e atualiza Pull Requests no GitHub via gh. Não implementa features.
```

Without a description, the agent is born generic and the leader sees it only as a "custom
agent", so it will not know how to route anything to it. That is why `add` warns when this
happens, and the menu explains before asking.

### The leader is notified automatically

Creating an agent while the team is already running does **not** require you to tell the
leader anything: the note reaches the leader's pane right away.

```
📣 líder avisado
```

What it receives:

```
[ORCHESTRA] O time mudou: o agente 'pr' entrou agora (claude).
Função: Abre e atualiza Pull Requests no GitHub via gh.
Delegue com: orchestra send pr "<tarefa>"   ·   resultado: orchestra await pr
```

The same applies to `orchestra rm`: the leader is told that the agent left and stops
delegating to it. If the command came from the leader's own pane, nothing is injected (it
already knows: it was the one that ran it).

The new agent's pane opens **on the same screen as the others**, splitting the space, never
in a floating window on top, never in another tab. Even if you have focus on another zellij
tab at that moment, it is born next to the team.

### Natural mode (recommended)

After launching, **just talk to the leader**. It already starts out knowing this project's
team and delegates on its own:

```
você ▸ cria um endpoint POST /users com validação e depois manda revisar
líder ▸ delega ao CODER… (roda no painel ao lado) e depois ao REVIEWER
```

You do not need to memorize any command. The leader dispatches, fetches the results with
`await` and reports back.

### Manual mode (fine control)

```bash
orchestra send coder    "create a POST /users endpoint with validation"
orchestra send reviewer "review the latest changes and point out bugs"
orchestra await coder           # waits for the full answer (blocking)
orchestra result coder          # see the answer whenever you like (non-blocking)
orchestra agents                # who is who and the state of each pane
orchestra down                  # ends the session
```

### Commands

| Command | Description |
|---------|-------------|
| `orchestra` | Builds the team and opens zellij in the current directory |
| `orchestra <dir>` | The same, for another project: `orchestra ~/my-app` |
| `orchestra send <agent> "<task>"` | Dispatches an **asynchronous** task |
| `orchestra result <agent>` | The agent's last answer (non-blocking) |
| `orchestra result <agent> --wait [s]` | Blocks until the full answer (default: 300s) |
| `orchestra await <agent> [s]` | Alias of `result --wait` |
| `orchestra done <agent> <task>` | *(used by the agent)* hands back the answer, reading stdin |
| `orchestra agents` | Lists the team and the state of each pane |
| `orchestra add <name> --ia <ai> [--role r] [--prompt "…"]` | Creates an agent and opens its pane |
| `orchestra rm <name>` | Removes the agent and closes its pane |
| `orchestra leader <ai>` | Switches the leader's AI |
| `orchestra heal` | Recreates panes that died or were closed |
| `orchestra status` | State of the session and the agents |
| `orchestra doctor` | Diagnoses prerequisites, AIs and panes |
| `orchestra down` | Ends the team's session |
| `orchestra uninstall` | Removes Orchestra Agents completely |
| `orchestra version` | Version |

**Exit codes of `await` / `result --wait`** (the leader checks them automatically):
`0` complete answer · `1` validation error · `2` **timeout** (output prefixed with
`[TIMEOUT/PARCIAL]`, **not reliable**) · `3` the agent reported an error.

---

## 🩺 Diagnostics (`orchestra doctor`)

```text
🩺 Orchestra Agents: diagnóstico

Base:
  ✔ zellij: /home/voce/.local/bin/zellij
  ✔ git: /usr/bin/git
  ✔ python3: /usr/bin/python3

Backends de agente:
  ✔ claude disponível
  ✔ opencode disponível
  ! codex ausente, instale em: https://developers.openai.com/codex/cli

Time deste projeto (/home/voce/meu-projeto):
  ✔ líder → claude
  ✔ coder → opencode (coder)
  ✔ reviewer → opencode (reviewer)

Sessão ativa:
  ✔ multiplexador zellij no ar (sessão orchestra-meu-projeto-284…)
  ✔ painel de leader aberto
  ✔ painel de coder aberto
  ! painel de reviewer ausente, 'orchestra heal' recria

Orchestra:
  ✔ instalado em /home/voce/.orchestra-agents
  ✔ CLI no PATH: /home/voce/.local/bin/orchestra

Resumo: o essencial está ok, com 2 aviso(s).
```

| Symbol | Meaning |
|--------|---------|
| ✔ | OK |
| ! | warning: it works, but is worth adjusting |
| ✖ | failure: something essential is missing |

Exits with **`0`** when there are no failures (even with warnings) and **`1`** when there is
at least one ✖.

---

## ⚙️ Configuration

### Models (important)

Orchestra **uses the models you already have configured** and forces none. Whatever you
configured in Claude Code / OpenCode / Codex is what Orchestra uses. The overrides below
exist only if you want to pin something.

### Variables

Through the environment or in `~/.config/orchestra-agents/config` (shell format):

| Variable | Default | Description |
|----------|---------|-------------|
| `ORCHESTRA_TEAM` | *(menu)* | Composes the team without a TTY: `"leader=claude,coder=codex,tester=opencode"`. Set = skips the menu |
| `ORCHESTRA_CODER` / `ORCHESTRA_REVIEWER` | *(empty)* | Legacy aliases: pin the AI of just those two agents |
| `ORCHESTRA_MODEL` | *(empty)* | Model override for **OpenCode** agents (`provider/model`) |
| `ORCHESTRA_CODEX_MODEL` | *(empty)* | Model override for **Codex** agents |
| `ORCHESTRA_MODEL_CLAUDE` | *(empty)* | Model override for **Claude Code** agents |
| `ORCHESTRA_TIMEOUT` | `300` | Default timeout (seconds) of `await` |
| `ORCHESTRA_CODEX_SANDBOX` | `workspace-write` | Sandbox of the Codex agents |
| `ORCHESTRA_MUX` | `zellij` | Multiplexer (`stub` is used by the tests) |
| `ORCHESTRA_HOME` | `~/.orchestra-agents` | Installation directory |
| `ORCHESTRA_STATE` | `~/.local/state/orchestra-agents` | Global state (project, mux session) |

Example `~/.config/orchestra-agents/config`:

```sh
ORCHESTRA_MODEL="anthropic/claude-sonnet-4-6"   # optional: pins the model of OpenCode agents
ORCHESTRA_TIMEOUT=600                           # optional: long tasks
```

### Where Orchestra keeps things

**Nothing** goes into your project folder. Each project gets its own directory in
Orchestra's state, identified by the folder name + a checksum of the path (so
`~/client-a/api` and `~/client-b/api` do not get mixed up):

```
~/.local/state/orchestra-agents/projects/my-project-1234567/
├── team.json         # team composition
├── project.path      # which project this directory belongs to
├── prompts/<name>.md # prompts of the custom agents
└── run/              # disposable runtime
```

> Anyone who used earlier versions had this in `<project>/.orchestra/`. The first time you
> open the project, Orchestra moves the team and the prompts to the new location on its own
> and cleans up the project folder — you lose nothing.

---

## 🧩 Structure

```
orchestra-agents/
├── install.sh                   # installer (curl | bash)
├── uninstall.sh                 # uninstaller
├── bin/orchestra                # CLI
├── lib/
│   ├── core.sh                  # core: dispatch, results, team management, doctor
│   ├── team.sh                  # team model (team.json) and prompts
│   ├── mux.sh                   # multiplexer abstraction (zellij | stub)
│   └── layout.sh                # generates the team's KDL layout
├── agents/
│   ├── run-agent.sh             # launcher + supervisor of an agent (any AI)
│   ├── leader-prompt.md         # the leader's orchestration instructions
│   ├── roles/*.md               # prompts of the ready-made roles
│   └── leader.sh, attach-*.sh   # compat shims → run-agent.sh
└── config/
    ├── opencode.reviewer.jsonc  # reference reviewer agent
    └── merge_reviewer.py        # merges that agent into your OpenCode config
```

---

## 🧪 Tests

```bash
./tests/smoke.sh
```

It covers the syntax of all scripts, the team model, composition by env, `add`/`rm`, role
prompts and roster, the full `send → done → await` cycle, exit codes, the generated layout
and `doctor`. It runs with `ORCHESTRA_MUX=stub` in a temporary project, and does **not**
touch a real session or call a model, so it works both locally and in CI.

**CI (GitHub Actions):** [`.github/workflows/smoke.yml`](.github/workflows/smoke.yml) runs
the smoke test on every push/PR to `main`, plus `shellcheck` on an informational basis.

---

## 🚢 Release process

The [`scripts/release.sh`](scripts/release.sh) script **computes the next number** (semver),
updates `VERSION` in `bin/orchestra`, makes the commit, creates the tag, pushes and publishes
the release with automatic notes:

```bash
./scripts/release.sh patch   # 0.2.0 -> 0.2.1
./scripts/release.sh minor   # 0.2.0 -> 0.3.0
./scripts/release.sh major   # 0.2.0 -> 1.0.0
./scripts/release.sh 1.2.3   # explicit version
DRY_RUN=1 ./scripts/release.sh minor   # only shows what it would do
```

> Publishing requires `gh` authenticated as the repo owner; without it, the script creates
> the tag and shows the command to finish.

---

## 🩺 Troubleshooting

- **`orchestra: command not found`** → add `~/.local/bin` to your `PATH`.
- **Pane vanished / was closed** → `orchestra heal` recreates it. `send` itself also
  recreates the agent's pane if it is missing.
- **The pane keeps restarting in a loop** → the AI in that pane is failing to start (missing
  binary or invalid flag). After 3 quick failures the supervisor stops and drops you into a
  shell; run `orchestra doctor`.
- **`[TIMEOUT/PARCIAL]` in the answer** → the worker did not call `orchestra done`. Raise
  the timeout (`orchestra await coder 600`) or resend the task. **Never** treat that text as
  the final answer.
- **`⚠️ você já está dentro de uma sessão zellij`** → leave to a regular terminal before
  running `orchestra` (this avoids nesting sessions).

---

## 🤝 Contributing

Contributions are welcome! See **[CONTRIBUTING.md](CONTRIBUTING.md)** for setup, tests
and the PR flow.

Commit messages are in English and adopt, **as a convention reference**, the guide
**[Padrões de Commits (iuricode)](https://github.com/iuricode/padroes-de-commits)** (emoji + type).

---

## 📄 License

MIT © 2026 orcioly
