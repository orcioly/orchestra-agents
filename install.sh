#!/usr/bin/env bash
# Orchestra Agents — instalador
# Uso:
#   curl -fsSL https://raw.githubusercontent.com/orcioly/orchestra-agents/main/install.sh | bash
#
# Pré-requisitos do desenvolvedor: Claude Code e OpenCode já instalados e configurados.
# O zellij é instalado automaticamente se faltar.
set -euo pipefail

# ----- parâmetros (sobrescrevíveis por env) -----
REPO_USER="${ORCHESTRA_REPO_USER:-orcioly}"
REPO_NAME="${ORCHESTRA_REPO_NAME:-orchestra-agents}"
REPO_BRANCH="${ORCHESTRA_REPO_BRANCH:-main}"
REPO_URL="${ORCHESTRA_REPO_URL:-https://github.com/${REPO_USER}/${REPO_NAME}.git}"
INSTALL_DIR="${ORCHESTRA_HOME:-$HOME/.orchestra-agents}"
STATE_DIR="${ORCHESTRA_STATE:-$HOME/.local/state/orchestra-agents}"
BIN_DIR="${ORCHESTRA_BIN:-}"   # resolvido automaticamente após checar pré-requisitos

c_say(){ printf '\033[1;36m▶ %s\033[0m\n' "$*"; }
c_ok(){  printf '\033[1;32m✔ %s\033[0m\n' "$*"; }
c_warn(){ printf '\033[1;33m! %s\033[0m\n' "$*"; }
c_err(){ printf '\033[1;31m✖ %s\033[0m\n' "$*" >&2; }
have(){ command -v "$1" >/dev/null 2>&1; }
in_path(){ case ":$PATH:" in *":$1:"*) return 0;; *) return 1;; esac; }

# Resolve o caminho do config do OpenCode respeitando overrides do próprio OpenCode,
# para escrever na pasta CERTA (não quebrar quem usa XDG_CONFIG_HOME ou OPENCODE_CONFIG).
oc_config_path() {
  if [ -n "${OPENCODE_CONFIG:-}" ]; then echo "$OPENCODE_CONFIG"; return; fi
  local dir="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
  [ -f "$dir/opencode.jsonc" ] && { echo "$dir/opencode.jsonc"; return; }
  [ -f "$dir/opencode.json" ]  && { echo "$dir/opencode.json";  return; }
  echo "$dir/opencode.jsonc"   # default a criar
}

# Escolhe um diretório de instalação do CLI que JÁ esteja no PATH e seja gravável,
# para que 'orchestra' funcione na mesma sessão, sem configuração manual.
# (o instalador roda via 'curl | bash' herdando o PATH real do usuário)
pick_bindir() {
  local d c p dd
  # 1) preferidos, se já no PATH e graváveis
  for d in "$HOME/.local/bin" "$HOME/bin"; do
    [ -d "$d" ] && [ -w "$d" ] && in_path "$d" && { echo "$d"; return; }
  done
  # 2) diretório de um pré-requisito (garantidamente no PATH) e gravável
  for c in opencode claude zellij; do
    p="$(command -v "$c" 2>/dev/null)" || continue
    dd="$(cd "$(dirname "$p")" 2>/dev/null && pwd)" || continue
    in_path "$dd" && [ -w "$dd" ] && { echo "$dd"; return; }
  done
  # 3) qualquer diretório do PATH gravável dentro do HOME
  local IFSorig="$IFS"; IFS=:
  for d in $PATH; do
    case "$d" in "$HOME"/*) if [ -w "$d" ]; then echo "$d"; IFS="$IFSorig"; return; fi;; esac
  done
  IFS="$IFSorig"
  # 4) fallback: ~/.local/bin (será adicionado ao PATH via rc)
  echo "$HOME/.local/bin"
}

printf '\n\033[1;35m🎼 Orchestra Agents — instalador\033[0m\n\n'

# 1) pré-requisitos obrigatórios
c_say "Verificando pré-requisitos..."
miss=0
have git    || { c_err "git é necessário"; miss=1; }
have curl   || { c_err "curl é necessário"; miss=1; }
have python3|| { c_err "python3 é necessário"; miss=1; }
if ! have claude; then
  c_err "Claude Code não encontrado. Instale e configure antes:  https://docs.claude.com/claude-code"; miss=1
fi
if ! have opencode && [ ! -x "$HOME/.opencode/bin/opencode" ]; then
  c_err "OpenCode não encontrado. Instale e configure antes:  https://opencode.ai"; miss=1
fi
[ "$miss" = 1 ] && { c_err "Resolva os itens acima e rode novamente."; exit 1; }
c_ok "Claude Code e OpenCode presentes."

# resolve onde instalar o CLI (diretório já no PATH, sempre que possível)
[ -n "$BIN_DIR" ] || BIN_DIR="$(pick_bindir)"
mkdir -p "$BIN_DIR"

# 2) zellij (instala por padrão se faltar)
install_zellij(){
  c_say "Instalando zellij..."
  if have cargo; then cargo install zellij && return 0; fi
  local arch target tmp url
  arch="$(uname -m)"
  case "$arch" in x86_64|amd64) arch=x86_64;; aarch64|arm64) arch=aarch64;; esac
  case "$(uname -s)" in
    Linux)  target="${arch}-unknown-linux-musl";;
    Darwin) target="${arch}-apple-darwin";;
    *) c_err "SO não suportado para auto-instalar zellij. Instale manualmente: https://zellij.dev"; return 1;;
  esac
  url="https://github.com/zellij-org/zellij/releases/latest/download/zellij-${target}.tar.gz"
  tmp="$(mktemp -d)"
  curl -fsSL "$url" -o "$tmp/zellij.tar.gz" || { c_err "download do zellij falhou: $url"; return 1; }
  tar -xzf "$tmp/zellij.tar.gz" -C "$tmp"
  mkdir -p "$BIN_DIR"; install -m 0755 "$tmp/zellij" "$BIN_DIR/zellij"
  rm -rf "$tmp"
}
if have zellij; then c_ok "zellij já instalado ($(zellij --version 2>/dev/null))"
else install_zellij && c_ok "zellij instalado em $BIN_DIR"; fi

# 3) baixa/atualiza o repositório
c_say "Instalando Orchestra Agents em $INSTALL_DIR ..."
if [ -n "${ORCHESTRA_LOCAL_SRC:-}" ]; then
  # modo dev: instala a partir de uma cópia local
  mkdir -p "$INSTALL_DIR"; cp -r "$ORCHESTRA_LOCAL_SRC/." "$INSTALL_DIR/"
elif [ -d "$INSTALL_DIR/.git" ]; then
  git -C "$INSTALL_DIR" fetch --depth 1 origin "$REPO_BRANCH" && git -C "$INSTALL_DIR" reset --hard "origin/$REPO_BRANCH"
else
  rm -rf "$INSTALL_DIR"
  git clone --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$INSTALL_DIR"
fi
chmod +x "$INSTALL_DIR/bin/orchestra" "$INSTALL_DIR/agents/"*.sh 2>/dev/null || true
c_ok "Arquivos instalados."

# 4) symlink do CLI + registra o local (para o uninstall saber)
ln -sf "$INSTALL_DIR/bin/orchestra" "$BIN_DIR/orchestra"
mkdir -p "$STATE_DIR"; printf '%s' "$BIN_DIR" >"$STATE_DIR/bindir"
c_ok "CLI instalado: $BIN_DIR/orchestra"

# 5) PATH — só precisa configurar algo se o diretório escolhido NÃO estiver no PATH
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

# 6) layout extra no diretório padrão do zellij (conveniência)
mkdir -p "$HOME/.config/zellij/layouts"
cp -f "$INSTALL_DIR/layouts/team.kdl" "$HOME/.config/zellij/layouts/orchestra.kdl" 2>/dev/null || true

# 7) agente reviewer no OpenCode — configuração AUTOMÁTICA (sem passo manual)
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

  Depois, no painel do LÍDER (Claude), apenas converse: ele delega ao
  CODER (implementar) e ao REVISOR (revisar) automaticamente.

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
