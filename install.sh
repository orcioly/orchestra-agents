#!/usr/bin/env bash
# Orchestra Agents — installer
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/orcioly/orchestra-agents/main/install.sh | bash
#
# Developer prerequisites: Claude Code and OpenCode already installed and configured.
# zellij is installed automatically if missing.
set -euo pipefail

# ----- parameters (overridable by env) -----
REPO_USER="${ORCHESTRA_REPO_USER:-orcioly}"
REPO_NAME="${ORCHESTRA_REPO_NAME:-orchestra-agents}"
REPO_BRANCH="${ORCHESTRA_REPO_BRANCH:-main}"
REPO_URL="${ORCHESTRA_REPO_URL:-https://github.com/${REPO_USER}/${REPO_NAME}.git}"
INSTALL_DIR="${ORCHESTRA_HOME:-$HOME/.orchestra-agents}"
STATE_DIR="${ORCHESTRA_STATE:-$HOME/.local/state/orchestra-agents}"
BIN_DIR="${ORCHESTRA_BIN:-}"   # resolved automatically after checking prerequisites

c_say(){ printf '\033[1;36m▶ %s\033[0m\n' "$*"; }
c_ok(){  printf '\033[1;32m✔ %s\033[0m\n' "$*"; }
c_warn(){ printf '\033[1;33m! %s\033[0m\n' "$*"; }
c_err(){ printf '\033[1;31m✖ %s\033[0m\n' "$*" >&2; }
have(){ command -v "$1" >/dev/null 2>&1; }
in_path(){ case ":$PATH:" in *":$1:"*) return 0;; *) return 1;; esac; }

# Resolves the OpenCode config path honoring OpenCode's own overrides,
# to write to the RIGHT folder (not break anyone using XDG_CONFIG_HOME or OPENCODE_CONFIG).
oc_config_path() {
  if [ -n "${OPENCODE_CONFIG:-}" ]; then echo "$OPENCODE_CONFIG"; return; fi
  local dir="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
  [ -f "$dir/opencode.jsonc" ] && { echo "$dir/opencode.jsonc"; return; }
  [ -f "$dir/opencode.json" ]  && { echo "$dir/opencode.json";  return; }
  echo "$dir/opencode.jsonc"   # default to create
}

# Picks a CLI install directory that is ALREADY on the PATH and writable,
# so that 'orchestra' works in the same session, with no manual setup.
# (the installer runs via 'curl | bash', inheriting the user's real PATH)
pick_bindir() {
  local d c p dd
  # 1) preferred ones, if already on the PATH and writable
  for d in "$HOME/.local/bin" "$HOME/bin"; do
    [ -d "$d" ] && [ -w "$d" ] && in_path "$d" && { echo "$d"; return; }
  done
  # 2) a prerequisite's directory (guaranteed to be on the PATH) and writable
  for c in opencode claude zellij; do
    p="$(command -v "$c" 2>/dev/null)" || continue
    dd="$(cd "$(dirname "$p")" 2>/dev/null && pwd)" || continue
    in_path "$dd" && [ -w "$dd" ] && { echo "$dd"; return; }
  done
  # 3) any writable PATH directory inside HOME
  local IFSorig="$IFS"; IFS=:
  for d in $PATH; do
    case "$d" in "$HOME"/*) if [ -w "$d" ]; then echo "$d"; IFS="$IFSorig"; return; fi;; esac
  done
  IFS="$IFSorig"
  # 4) fallback: ~/.local/bin (will be added to the PATH via rc)
  echo "$HOME/.local/bin"
}

printf '\n\033[1;35m🎼 Orchestra Agents — instalador\033[0m\n\n'

# 1) mandatory prerequisites
c_say "Verificando pré-requisitos..."
miss=0
have git    || { c_err "git é necessário"; miss=1; }
have curl   || { c_err "curl é necessário"; miss=1; }
have python3|| { c_err "python3 é necessário"; miss=1; }
[ "$miss" = 1 ] && { c_err "Resolva os itens acima e rode novamente."; exit 1; }

# Agent backends: just ONE is enough. Each team agent picks its own in 'orchestra up',
# so a whole team of Claude Code (or of Codex) is perfectly valid.
backends=0
if have claude; then
  c_ok "Claude Code presente — disponível para qualquer agente."; backends=$((backends+1))
else
  c_warn "Claude Code ausente. Instale se quiser usá-lo: https://docs.claude.com/claude-code"
fi
if have opencode || [ -x "$HOME/.opencode/bin/opencode" ]; then
  c_ok "OpenCode presente — disponível para qualquer agente."; backends=$((backends+1))
else
  c_warn "OpenCode ausente. Instale se quiser usá-lo: https://opencode.ai"
fi
if have codex || [ -x "$HOME/.local/bin/codex" ]; then
  c_ok "Codex presente — disponível para qualquer agente."; backends=$((backends+1))
else
  c_warn "Codex ausente. Instale se quiser usá-lo: https://developers.openai.com/codex/cli"
fi
if [ "$backends" = 0 ]; then
  c_err "Nenhum backend de agente encontrado — instale ao menos um dos acima e rode novamente."
  exit 1
fi

# resolves where to install the CLI (a directory already on the PATH, whenever possible)
[ -n "$BIN_DIR" ] || BIN_DIR="$(pick_bindir)"
mkdir -p "$BIN_DIR"

# ----- manifest of what the INSTALLER put on the machine -----
# One line per item: "<method><TAB><target>", method in file|brew|cargo. The uninstall
# reads this and undoes each item WITH THE RIGHT METHOD — a zellij that came from brew leaves
# with 'brew uninstall', a downloaded binary leaves with 'rm'.
#
# Only what WE installed goes in here. What already existed on the machine is never recorded
# and therefore never removed: uninstalling Orchestra must not take along the zellij
# of someone who already used zellij before.
# Operating system: decides HOW to install (and, recorded in the manifest, helps the
# uninstall know what machine the installer ran on). 'wsl' is Linux for the purposes
# of the binary, but it is useful to tell apart in diagnostics.
os_detect(){
  case "$(uname -s 2>/dev/null)" in
    Darwin) echo macos ;;
    Linux)  if grep -qi microsoft /proc/version 2>/dev/null; then echo wsl; else echo linux; fi ;;
    FreeBSD|OpenBSD|NetBSD) echo bsd ;;
    CYGWIN*|MINGW*|MSYS*) echo windows ;;
    *) echo desconhecido ;;
  esac
}
ORCHESTRA_OS="$(os_detect)"

MANIFEST="$STATE_DIR/installed.manifest"
record_installed(){ # $1 method  $2 target
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  local line; line="$(printf '%s\t%s' "$1" "$2")"
  grep -qxF "$line" "$MANIFEST" 2>/dev/null && return 0
  printf '%s\n' "$line" >>"$MANIFEST"
}

# 2) zellij (installed by default if missing)
_zellij_from_brew(){
  have brew || return 1
  brew install zellij || { c_warn "'brew install zellij' falhou — tentando o binário oficial"; return 1; }
  record_installed brew zellij
}

install_zellij(){
  c_say "Instalando zellij ($ORCHESTRA_OS)..."
  local arch target tmp url
  # On macOS brew is the native manager and comes first. On Linux the default path
  # is the release's musl binary: brew normally does NOT exist there, and requiring it
  # would leave the installer with no way out on the most common machine.
  if [ "$ORCHESTRA_OS" = macos ] && _zellij_from_brew; then return 0; fi
  arch="$(uname -m)"
  case "$arch" in x86_64|amd64) arch=x86_64;; aarch64|arm64) arch=aarch64;; esac
  case "$ORCHESTRA_OS" in
    linux|wsl) target="${arch}-unknown-linux-musl";;
    macos)     target="${arch}-apple-darwin";;
    *)         target="";;
  esac
  if [ -n "$target" ]; then
    url="https://github.com/zellij-org/zellij/releases/latest/download/zellij-${target}.tar.gz"
    tmp="$(mktemp -d)"
    if curl -fsSL "$url" -o "$tmp/zellij.tar.gz" && tar -xzf "$tmp/zellij.tar.gz" -C "$tmp"; then
      mkdir -p "$BIN_DIR"
      install -m 0755 "$tmp/zellij" "$BIN_DIR/zellij"
      record_installed file "$BIN_DIR/zellij"
      # old marker, kept for anyone uninstalling with an earlier uninstall.sh
      printf '%s' "$BIN_DIR/zellij" >"$STATE_DIR/zellij.ours" 2>/dev/null || true
      rm -rf "$tmp"
      return 0
    fi
    rm -rf "$tmp"
    c_warn "download do binário do zellij falhou — tentando compilar com cargo"
  fi
  # brew outside macOS (linuxbrew), only after the binary
  if [ "$ORCHESTRA_OS" != macos ] && _zellij_from_brew; then return 0; fi
  # cargo last: compiles from scratch (slow), but covers architectures without a release
  if have cargo; then
    if cargo install zellij; then record_installed cargo zellij; return 0; fi
  fi
  c_err "não consegui instalar o zellij automaticamente neste sistema ($ORCHESTRA_OS)."
  c_err "Instale manualmente: https://zellij.dev"
  return 1
}
record_installed os "$ORCHESTRA_OS"
if have zellij; then
  c_ok "zellij já instalado ($(zellij --version 2>/dev/null))"
else
  if install_zellij; then
    c_ok "zellij instalado ($(command -v zellij 2>/dev/null || echo "$BIN_DIR/zellij"))"
  fi
fi

# 3) downloads/updates the repository
c_say "Instalando Orchestra Agents em $INSTALL_DIR ..."
if [ -n "${ORCHESTRA_LOCAL_SRC:-}" ]; then
  # dev mode: installs from a local copy.
  # excludes .git (read-only objects break the re-copy and are not needed at runtime)
  # and caches; recreates the destination from scratch to avoid overwrite conflicts.
  rm -rf "$INSTALL_DIR"; mkdir -p "$INSTALL_DIR"
  # '.orchestra' is PROJECT STATE (team, prompts, runtime) of whoever is
  # developing — it must not travel into the installation.
  ( cd "$ORCHESTRA_LOCAL_SRC" && tar --exclude='./.git' --exclude='./.orchestra' \
      --exclude='*/__pycache__' --exclude='*.pyc' -cf - . ) \
    | ( cd "$INSTALL_DIR" && tar -xf - )
elif [ -d "$INSTALL_DIR/.git" ]; then
  git -C "$INSTALL_DIR" fetch --depth 1 origin "$REPO_BRANCH" && git -C "$INSTALL_DIR" reset --hard "origin/$REPO_BRANCH"
else
  rm -rf "$INSTALL_DIR"
  git clone --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$INSTALL_DIR"
fi
chmod +x "$INSTALL_DIR/bin/orchestra" "$INSTALL_DIR/agents/"*.sh 2>/dev/null || true
c_ok "Arquivos instalados."

# 4) CLI symlink + records the location (so the uninstall knows)
ln -sf "$INSTALL_DIR/bin/orchestra" "$BIN_DIR/orchestra"
mkdir -p "$STATE_DIR"; printf '%s' "$BIN_DIR" >"$STATE_DIR/bindir"
c_ok "CLI instalado: $BIN_DIR/orchestra"

# 5) PATH — only needs to configure something if the chosen directory is NOT on the PATH
READY_NOW=1
if in_path "$BIN_DIR"; then
  c_ok "'orchestra' já disponível nesta sessão (sem configuração manual)."
else
  READY_NOW=0
  c_say "Configurando o PATH automaticamente (zsh/bash/fish)..."
  shname="$(basename "${SHELL:-}" 2>/dev/null)"
  rcs=()
  [ "$shname" = zsh ]  && rcs+=("$HOME/.zshrc")
  [ "$shname" = bash ] && rcs+=("$HOME/.bashrc")
  [ -f "$HOME/.zshrc" ]  && rcs+=("$HOME/.zshrc")
  [ -f "$HOME/.bashrc" ] && rcs+=("$HOME/.bashrc")
  [ ${#rcs[@]} -eq 0 ] && rcs+=("$HOME/.profile")
  for rc in $(printf '%s\n' "${rcs[@]}" | sort -u); do
    if ! grep -qs 'orchestra-agents (PATH)' "$rc" 2>/dev/null; then
      printf '\n# orchestra-agents (PATH)\nexport PATH="%s:$PATH"\n' "$BIN_DIR" >>"$rc"
      c_ok "PATH adicionado em $rc"
    fi
  done
  if command -v fish >/dev/null 2>&1 || [ -d "$HOME/.config/fish" ]; then
    mkdir -p "$HOME/.config/fish/conf.d"
    printf 'fish_add_path %s\n' "$BIN_DIR" >"$HOME/.config/fish/conf.d/orchestra.fish"
    c_ok "PATH (fish) configurado."
  fi
fi

# 6) (the zellij layout is GENERATED per project on every "orchestra up" — nothing to copy)

# 7) reviewer agent in OpenCode — AUTOMATIC configuration (no manual step)
OC_CFG="$(oc_config_path)"
set +e
python3 "$INSTALL_DIR/config/merge_reviewer.py" "$OC_CFG" "$INSTALL_DIR/config/opencode.reviewer.jsonc"
rc=$?
set -e
case "$rc" in
  0)  c_ok "Agente 'reviewer' configurado automaticamente em $OC_CFG." ;;
  10) c_ok "Agente 'reviewer' já estava configurado no OpenCode." ;;
  *)  c_warn "Não consegui mesclar o 'reviewer' em $OC_CFG com segurança."
      c_warn "Bloco de referência: $INSTALL_DIR/config/opencode.reviewer.jsonc" ;;
esac

printf '\n'
c_ok "Instalação concluída! 🎼"
if [ "$READY_NOW" = 1 ]; then
  cat <<EOF

  Pronto! É só ir ao seu projeto e digitar:

      cd ~/meu-projeto
      orchestra

  Um menu deixa você montar o time do projeto (líder + agentes, cada um em
  claude, opencode ou codex). Depois é só conversar no painel do LÍDER: ele
  delega aos agentes e busca os resultados automaticamente.

  Desinstalar tudo:  orchestra uninstall
  Docs:              $INSTALL_DIR/README.md
EOF
else
  cat <<EOF

  Quase lá! Abra um novo terminal (o PATH foi configurado automaticamente),
  então vá ao seu projeto e digite:

      cd ~/meu-projeto
      orchestra

  Desinstalar tudo:  orchestra uninstall
  Docs:              $INSTALL_DIR/README.md
EOF
fi
