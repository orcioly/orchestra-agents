#!/usr/bin/env bash
# Painel LÍDER — Claude Code orquestrando os workers.
ORCHESTRA_HOME="${ORCHESTRA_HOME:-$HOME/.orchestra-agents}"
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$PATH"
# shellcheck source=/dev/null
. "$ORCHESTRA_HOME/lib/core.sh" 2>/dev/null || true
clear
cat <<'EOF'
🎼  ORCHESTRA AGENTS — você é o LÍDER (maestro)

  Despache tarefas de forma ASSÍNCRONA (não bloqueia, não gasta token esperando):
      orchestra send coder    "implemente X"
      orchestra send reviewer "revise as mudanças"

  Resultado sob demanda:   orchestra result coder
  Estado do time:          orchestra status

EOF
exec claude
