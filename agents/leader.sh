#!/usr/bin/env bash
# Compat shim → o líder agora é um agente como os outros (backend trocável).
ORCHESTRA_HOME="${ORCHESTRA_HOME:-$HOME/.orchestra-agents}"
exec "$ORCHESTRA_HOME/agents/run-agent.sh" leader
