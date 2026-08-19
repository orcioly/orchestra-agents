#!/usr/bin/env bash
# Compat shim → o painel de qualquer agente agora é o run-agent.sh (supervisionado).
ORCHESTRA_HOME="${ORCHESTRA_HOME:-$HOME/.orchestra-agents}"
exec "$ORCHESTRA_HOME/agents/run-agent.sh" reviewer
