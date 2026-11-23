#!/usr/bin/env bash
# Compat shim → the pane of any agent is now run-agent.sh (supervised).
ORCHESTRA_HOME="${ORCHESTRA_HOME:-$HOME/.orchestra-agents}"
exec "$ORCHESTRA_HOME/agents/run-agent.sh" reviewer
