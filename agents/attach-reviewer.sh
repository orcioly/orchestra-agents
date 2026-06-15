#!/usr/bin/env bash
# Painel REVISOR — TUI REAL do OpenCode (agente reviewer, read-only) attachada ao servidor.
ORCHESTRA_HOME="${ORCHESTRA_HOME:-$HOME/.orchestra-agents}"
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$PATH"
# shellcheck source=/dev/null
. "$ORCHESTRA_HOME/lib/core.sh"
clear
echo "🔍 REVISOR — OpenCode TUI (agente $ORCHESTRA_REVIEWER_AGENT · $ORCHESTRA_MODEL)"
echo "    conectando ao servidor do time..."
ensure_server >/dev/null || { echo "❌ servidor OpenCode indisponível — veja $ORCHESTRA_STATE/server.log"; exec bash; }
SID="$(ensure_session reviewer "$ORCHESTRA_REVIEWER_AGENT" "REVISOR (code review)")"
DIR="$(cat "$ORCHESTRA_STATE/project" 2>/dev/null)"; [ -n "$DIR" ] || DIR="$HOME"
exec "$OPENCODE" attach "$OC_URL" --session "$SID" --dir "$DIR"
