#!/usr/bin/env bash
# Compat shim → the leader is now an agent like the others (swappable backend).
ORCHESTRA_HOME="${ORCHESTRA_HOME:-$HOME/.orchestra-agents}"
exec "$ORCHESTRA_HOME/agents/run-agent.sh" leader
