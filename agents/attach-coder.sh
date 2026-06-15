#!/usr/bin/env bash
# Painel CODER — TUI REAL do OpenCode (agente executor) attachada ao servidor do time.
ORCHESTRA_HOME="${ORCHESTRA_HOME:-$HOME/.orchestra-agents}"
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$PATH"
# shellcheck source=/dev/null
. "$ORCHESTRA_HOME/lib/core.sh"
clear
echo "🛠️  CODER — OpenCode TUI (agente $ORCHESTRA_CODER_AGENT · $ORCHESTRA_MODEL)"
echo "    conectando ao servidor do time..."
ensure_server >/dev/null || { echo "❌ servidor OpenCode indisponível — veja $ORCHESTRA_STATE/server.log"; exec bash; }
SID="$(ensure_session coder "$ORCHESTRA_CODER_AGENT" "CODER (executor)")"
DIR="$(cat "$ORCHESTRA_STATE/project" 2>/dev/null)"; [ -n "$DIR" ] || DIR="$HOME"
exec "$OPENCODE" attach "$OC_URL" --session "$SID" --dir "$DIR"
