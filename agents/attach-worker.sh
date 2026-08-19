#!/usr/bin/env bash
# Painel de WORKER — abre a TUI real do backend escolhido para o papel ($1: coder|reviewer).
#   - opencode: TUI attachada ao servidor headless (opencode attach --session)
#   - codex:    TUI attachada ao app-server compartilhado (codex --remote), no MESMO thread
#               que o líder despacha — então tarefas do 'orchestra send' aparecem aqui ao vivo.
ORCHESTRA_HOME="${ORCHESTRA_HOME:-$HOME/.orchestra-agents}"
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$PATH"
# shellcheck source=/dev/null
. "$ORCHESTRA_HOME/lib/core.sh"

ROLE="${1:-coder}"
case "$ROLE" in
  coder)    ICON="🛠️"; LABEL="CODER (executor)" ;;
  reviewer) ICON="🔍"; LABEL="REVISOR (code review)" ;;
  *) echo "papel inválido: '$ROLE'"; exec bash ;;
esac
BACKEND="$(_role_backend "$ROLE")"
DIR="$(cat "$ORCHESTRA_STATE/project" 2>/dev/null)"; [ -n "$DIR" ] || DIR="$HOME"
clear

if [ "$BACKEND" = codex ]; then
  echo "$ICON  $LABEL — Codex TUI (sandbox: $(_codex_sandbox "$ROLE"))"
  echo "    conectando ao codex app-server compartilhado..."
  ensure_codex_server >/dev/null || { echo "❌ codex app-server indisponível — veja $ORCHESTRA_STATE/codex-server.log"; exec bash; }
  TID="$(ensure_codex_thread "$ROLE")" || { echo "❌ não consegui obter o thread do codex"; exec bash; }
  # attach interativo ao MESMO thread que o líder usa (via --remote no socket compartilhado).
  # opções no subcomando 'resume' (evita ambiguidade global vs. subcomando).
  CODEX_EXTRA=()
  [ -n "$ORCHESTRA_CODEX_MODEL" ] && CODEX_EXTRA+=(-m "$ORCHESTRA_CODEX_MODEL")
  # sem user namespaces, desliga o sandbox também no cliente da TUI (senão falha no preflight)
  [ -f "$ORCHESTRA_STATE/codex.nosandbox" ] && CODEX_EXTRA+=(-c sandbox_mode=danger-full-access)
  exec "$CODEX" resume "$TID" --remote "unix://$CODEX_SOCK" --cd "$DIR" "${CODEX_EXTRA[@]}"
else
  MDL="$(_effective_model 2>/dev/null)"; [ -n "$ORCHESTRA_MODEL" ] || MDL="${MDL:-default} (OpenCode)"
  case "$ROLE" in coder) AGENT="$ORCHESTRA_CODER_AGENT" ;; reviewer) AGENT="$ORCHESTRA_REVIEWER_AGENT" ;; esac
  echo "$ICON  $LABEL — OpenCode TUI (agente $AGENT · modelo: $MDL)"
  echo "    conectando ao servidor do time..."
  ensure_server >/dev/null || { echo "❌ servidor OpenCode indisponível — veja $ORCHESTRA_STATE/server.log"; exec bash; }
  SID="$(ensure_session "$ROLE" "$AGENT" "$LABEL")"
  exec "$OPENCODE" attach "$OC_URL" --session "$SID" --dir "$DIR"
fi
