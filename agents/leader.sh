#!/usr/bin/env bash
# Painel LÍDER — Claude Code orquestrando os workers.
ORCHESTRA_HOME="${ORCHESTRA_HOME:-$HOME/.orchestra-agents}"
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$PATH"
# shellcheck source=/dev/null
. "$ORCHESTRA_HOME/lib/core.sh" 2>/dev/null || true
# entra no diretório do projeto (definido pelo 'orchestra up') — funciona em qualquer pasta
PROJ="$(cat "$ORCHESTRA_STATE/project" 2>/dev/null)"
[ -n "$PROJ" ] && cd "$PROJ" 2>/dev/null
clear
cat <<EOF
🎼  ORCHESTRA AGENTS — você é o LÍDER (maestro)
    projeto: ${PROJ:-$(pwd)}

  Despache tarefas de forma ASSÍNCRONA (não bloqueia, não gasta token esperando):
      orchestra send coder    "implemente X"
      orchestra send reviewer "revise as mudanças"

  Modo natural: só converse comigo (o Claude) que eu delego pros workers.
  Manual:       orchestra send coder|reviewer "..."  ·  orchestra result  ·  status

EOF
# Sobe o Claude já instruído a orquestrar (modo natural).
# NÃO passamos --model: o Claude Code usa o modelo que VOCÊ já configurou.
PROMPT_FILE="$ORCHESTRA_HOME/agents/leader-prompt.md"
if [ -f "$PROMPT_FILE" ]; then
  exec claude --append-system-prompt "$(cat "$PROMPT_FILE")"
else
  exec claude
fi
