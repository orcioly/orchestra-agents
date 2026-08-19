#!/usr/bin/env bash
# Compat shim → delega ao painel genérico (backend-aware) do papel reviewer.
ORCHESTRA_HOME="${ORCHESTRA_HOME:-$HOME/.orchestra-agents}"
exec "$ORCHESTRA_HOME/agents/attach-worker.sh" reviewer
