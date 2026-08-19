#!/usr/bin/env bash
# Orchestra Agents — desinstalador
# Uso:
#   orchestra uninstall            (recomendado)
#   ou:  curl -fsSL https://raw.githubusercontent.com/orcioly/orchestra-agents/main/uninstall.sh | bash
set -uo pipefail
INSTALL_DIR="${ORCHESTRA_HOME:-$HOME/.orchestra-agents}"

if [ -f "$INSTALL_DIR/lib/core.sh" ]; then
  # usa a função oficial de uninstall
  # shellcheck source=/dev/null
  . "$INSTALL_DIR/lib/core.sh"
  uninstall
  exit 0
fi

# fallback self-contained (se o diretório de instalação já sumiu)
echo "🧹 Desinstalando Orchestra Agents (modo standalone)..."
STATE_DIR="${ORCHESTRA_STATE:-$HOME/.local/state/orchestra-agents}"
# encerra as sessões do Orchestra de TODOS os projetos (mesmo comportamento do
# 'orchestra uninstall'); sessões do usuário com outros nomes ficam intactas
if command -v zellij >/dev/null 2>&1; then
  zellij list-sessions --no-formatting 2>/dev/null | awk '{print $1}' | grep '^orchestra-' \
    | while IFS= read -r s; do
        [ -n "$s" ] && zellij delete-session --force "$s" >/dev/null 2>&1 && echo "  🛑 sessão '$s' encerrada"
      done
fi
bindir="$(cat "$STATE_DIR/bindir" 2>/dev/null || true)"
[ -n "$bindir" ] && rm -f "$bindir/orchestra"
IFSorig="$IFS"; IFS=:
for d in $PATH; do
  if [ -L "$d/orchestra" ]; then
    case "$(readlink "$d/orchestra" 2>/dev/null || true)" in
      *orchestra-agents/bin/orchestra) rm -f "$d/orchestra";;
    esac
  fi
done
IFS="$IFSorig"
for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
  { [ -f "$rc" ] && grep -q 'orchestra-agents (PATH)' "$rc" 2>/dev/null; } || continue
  tmp="$(mktemp)"
  awk '/# orchestra-agents \(PATH\)/{skip=2} skip>0{skip--; next} {print}' "$rc" >"$tmp" && mv "$tmp" "$rc"
done
zj="$(cat "$STATE_DIR/zellij.ours" 2>/dev/null || true)"
[ -n "$zj" ] && [ -f "$zj" ] && rm -f "$zj" && echo "  removido $zj (tinha sido instalado pelo Orchestra)"
rm -f "$HOME/.config/fish/conf.d/orchestra.fish" "$HOME/.config/zellij/layouts/orchestra.kdl"
rm -rf "$HOME/.config/orchestra-agents" "$STATE_DIR" "$INSTALL_DIR"
echo "✅ Orchestra Agents removido por completo."
