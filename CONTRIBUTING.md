# Contributing to Orchestra Agents

Thanks for your interest in contributing! 🎼 Issues and pull requests are welcome.

## 🧰 Prerequisites

- At least one agent backend — **Claude Code**, **OpenCode** or **Codex** (see the
  [prerequisites](README.md#-prerequisites)). To run the tests, none is required.
- **zellij**, `git`, `python3` (and `curl` to run the installer)
- `bash` (the scripts use `#!/usr/bin/env bash`)

## 🛠️ Development setup

```bash
# 1) fork and clone your fork
git clone git@github.com:YOUR_USERNAME/orchestra-agents.git
cd orchestra-agents

# 2) install from the local copy (without downloading from GitHub)
ORCHESTRA_LOCAL_SRC="$PWD" bash install.sh
```

To iterate, edit the files in the repository and run `ORCHESTRA_LOCAL_SRC="$PWD" bash install.sh` again to sync the installation in `~/.orchestra-agents`. Dev mode copies the whole working tree (except `.git`, `.orchestra` and caches) and **recreates** the installation directory, so files removed from the repository disappear from the installation too.

After syncing, remember that **panes that are already open keep running the old code**: shut down with `orchestra down` and bring the team up again to test your changes.

## ✅ Running the tests

Always run the smoke test before opening a PR:

```bash
./tests/smoke.sh
```

It covers syntax (`bash -n`), the team model, composition via env, `add`/`rm`, role prompts, the full `send → done → await` cycle, exit codes, the generated layout and `doctor`. It runs with `ORCHESTRA_MUX=stub` in a temporary project — it needs neither zellij nor an authenticated backend, and it never touches a real session. CI (GitHub Actions) runs automatically on every push/PR to `main`.

## 🎨 Code style

- Every script starts with `#!/usr/bin/env bash`.
- Make sure it passes `bash -n` and, preferably, `shellcheck -S warning`.
- Quote variables (`"$var"`), prefer `[ ... ]`/`case`, and keep functions small and well named.
- Keep the same comment density and language as the existing messages (user-facing messages in PT-BR).
- Do not introduce dependencies beyond `bash`, `python3`, `git` and the tools already in use (`zellij`, `claude`, `opencode`, `codex`).
- All multiplexer access goes through `lib/mux.sh` — do not call `zellij` directly from any other file.
- Every menu uses the engine in `lib/menu.sh` (`menu_read_key`, `menu_draw_begin`/`menu_draw_end`, `menu_begin`/`menu_end`) — do not write key reading or screen redrawing in any other file. The smoke test fails the build if you duplicate it; the two bugs this rule prevents are invisible in bash 5 and outside a real terminal.

## 📝 Commit messages

Messages are **in English** and adopt, **as a convention reference**, the **[Padrões de Commits (iuricode)](https://github.com/iuricode/padroes-de-commits)** guide: `<emoji> <type>: <description in the imperative>`. (It is just an external reference for standardization — there is no tie to the project.)

Examples:

| Type | When | Example |
|------|------|---------|
| ✨ `feat` | new feature | `✨ feat: add 'orchestra logs' command` |
| 🐛 `fix` | bug fix | `🐛 fix: handle empty project directory` |
| 📝 `docs` | documentation | `📝 docs: clarify model configuration` |
| ✅ `test` | tests | `✅ test: cover dispatch error path` |
| ♻️ `refactor` | refactoring | `♻️ refactor: extract session helpers` |
| 🔧 `chore` | tasks/config | `🔧 chore: tidy install paths` |
| 👷 `ci` | CI/CD | `👷 ci: cache shellcheck install` |
| 🔖 `chore` | version bump | `🔖 chore: bump version to v0.2.0` |

## 🔀 Opening a Pull Request

1. Create a branch from `main`: `git checkout -b my-feature`
2. Make your changes and run `./tests/smoke.sh` (it must pass).
3. Commit following the convention above.
4. Open the PR against `main`, describing **what** and **why**.
5. Make sure CI is green.

## 🚢 Releasing a version

Maintainers: the release process is documented in the [README](README.md#-release-process).

---

Questions? Open an [issue](https://github.com/orcioly/orchestra-agents/issues). 🙌
