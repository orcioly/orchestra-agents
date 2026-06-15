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
BIN_DIR="${ORCHESTRA_BIN:-$HOME/.local/bin}"

c_say(){ printf '\033[1;36m▶ %s\033[0m\n' "$*"; }
c_ok(){  printf '\033[1;32m✔ %s\033[0m\n' "$*"; }
c_warn(){ printf '\033[1;33m! %s\033[0m\n' "$*"; }
c_err(){ printf '\033[1;31m✖ %s\033[0m\n' "$*" >&2; }
have(){ command -v "$1" >/dev/null 2>&1; }

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

# 4) symlink do CLI
mkdir -p "$BIN_DIR"
ln -sf "$INSTALL_DIR/bin/orchestra" "$BIN_DIR/orchestra"
c_ok "CLI disponível: $BIN_DIR/orchestra"

# 5) PATH
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) c_warn "Adicione ao seu ~/.zshrc (ou ~/.bashrc):  export PATH=\"$BIN_DIR:\$PATH\"";;
esac

# 6) layout extra no diretório padrão do zellij (conveniência)
mkdir -p "$HOME/.config/zellij/layouts"
cp -f "$INSTALL_DIR/layouts/team.kdl" "$HOME/.config/zellij/layouts/orchestra.kdl" 2>/dev/null || true

# 7) checagem do agente reviewer no OpenCode
OC_CFG="$HOME/.config/opencode/opencode.jsonc"
if [ -f "$OC_CFG" ] && grep -q '"reviewer"' "$OC_CFG"; then
  c_ok "Agente 'reviewer' encontrado na config do OpenCode."
else
  c_warn "Agente 'reviewer' NÃO encontrado no OpenCode."
  c_warn "Adicione o bloco de:  $INSTALL_DIR/config/opencode.reviewer.jsonc"
  c_warn "ao seu $OC_CFG (e ajuste o modelo)."
fi

printf '\n'
c_ok "Instalação concluída! 🎼"
cat <<EOF

  Para começar:
    1) Entre no seu projeto:        cd ~/meu-projeto
    2) Suba o time:                 orchestra up
    3) No painel do LÍDER (Claude): orchestra send coder "implemente X"
                                    orchestra send reviewer "revise as mudanças"
    Status / resultado:             orchestra status   |   orchestra result coder

  Docs:  $INSTALL_DIR/README.md
EOF
