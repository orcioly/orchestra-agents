#!/usr/bin/env bash
# Orchestra Agents — launcher + SUPERVISOR de um agente (worker ou líder).
#
# Roda a TUI LOCAL do backend escolhido para o agente e a mantém viva: se a TUI
# morrer (crash, /exit, Ctrl-D, queda no resize), re-lança automaticamente
# RETOMANDO a sessão anterior — o usuário nunca precisa de "Ctrl-C + Enter".
#
# uso: run-agent.sh <nome-do-agente>
ORCHESTRA_HOME="${ORCHESTRA_HOME:-$HOME/.orchestra-agents}"
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$PATH"
# shellcheck source=/dev/null
. "$ORCHESTRA_HOME/lib/core.sh"

AGENT="${1:-}"
[ -n "$AGENT" ] || { echo "uso: run-agent.sh <agente>"; exec bash; }

mux_remember_session
team_ensure
if ! team_exists "$AGENT"; then
  echo "❌ agente '$AGENT' não existe em $(team_file)"
  echo "   agentes: $(team_all_names | tr '\n' ' ')"
  exec bash
fi

# registra/re-resolve o próprio pane-id (o painel se identifica pelo COMANDO)
mux_pane_id "$AGENT" >/dev/null 2>&1 || true

BACKEND="$(team_field "$AGENT" backend)"
ROLE="$(team_field "$AGENT" role)"
[ -n "$ROLE" ] || ROLE=custom
ICON="$(role_icon "$ROLE")"
PROJ="$ORCHESTRA_PROJECT"
mkdir -p "$ORCHESTRA_RUN_DIR"

if [ "$ROLE" = leader ]; then
  PROMPT="$(team_leader_prompt)"
else
  PROMPT="$(team_prompt_for "$AGENT")"
fi

cd "$PROJ" 2>/dev/null || true

banner() {
  clear
  printf '\033[1;36m%s  %s\033[0m \033[2m(%s · %s)\033[0m\n' \
    "$ICON" "$(echo "$AGENT" | tr '[:lower:]' '[:upper:]')" "$BACKEND" "$(role_desc "$ROLE")"
  printf '\033[2m   projeto: %s\033[0m\n' "$PROJ"
  if [ "$ROLE" = leader ]; then
    printf '\033[2m   delegue com: orchestra send <agente> "<tarefa>"  ·  orchestra agents\033[0m\n'
  else
    printf '\033[2m   tarefas do líder chegam aqui; pode conversar direto também\033[0m\n'
  fi
  echo
}

# ---------------------------------------------------------------------------
# Codex: descobrir e "reivindicar" a sessão deste painel.
#
# 'codex resume --last' filtra por cwd, então com DOIS agentes codex no mesmo
# projeto ele pode retomar a sessão do agente errado. Por isso reivindicamos o
# rollout: após subir, procuramos a sessão nova daquele cwd que ainda não foi
# reivindicada por outro agente e guardamos o id.
# ---------------------------------------------------------------------------
_codex_session_file() { echo "$ORCHESTRA_RUN_DIR/$AGENT.codex.session"; }

_codex_claim_session() { # $1 epoch mínimo
  local since="$1" claimed=() f id
  for f in "$ORCHESTRA_RUN_DIR"/*.codex.session; do
    [ -f "$f" ] || continue
    case "$f" in *"/$AGENT.codex.session") continue ;; esac
    id="$(cat "$f" 2>/dev/null)"; [ -n "$id" ] && claimed+=("$id")
  done
  python3 - "$PROJ" "$since" "$(_codex_session_file)" "${claimed[@]}" <<'PY'
import sys, os, json, glob, time
proj, since, out = sys.argv[1], float(sys.argv[2]), sys.argv[3]
claimed = set(sys.argv[4:])
root = os.path.expanduser("~/.codex/sessions")
best = None
for path in glob.glob(os.path.join(root, "**", "rollout-*.jsonl"), recursive=True):
    try:
        if os.path.getmtime(path) < since - 5:
            continue
        with open(path) as f:
            meta = json.loads(f.readline()).get("payload", {})
    except Exception:
        continue
    sid = meta.get("session_id")
    if not sid or sid in claimed or meta.get("cwd") != proj:
        continue
    ts = os.path.getmtime(path)
    if best is None or ts > best[0]:
        best = (ts, sid)
if best:
    with open(out, "w") as f:
        f.write(best[1])
PY
}

# roda em background: espera o rollout aparecer (o codex só grava após o 1º turno)
_codex_claim_bg() {
  local since="$1" i
  ( for i in $(seq 1 40); do
      sleep 3
      _codex_claim_session "$since" 2>/dev/null
      [ -s "$(_codex_session_file)" ] && break
    done ) >/dev/null 2>&1 &
}

# ---------------------------------------------------------------------------
# Lançamento por backend. $1 = "first" na primeira subida, "resume" nas demais.
# ---------------------------------------------------------------------------
launch() { # $1 first|resume
  local mode="$1"
  case "$BACKEND" in
    claude)   launch_claude   "$mode" ;;
    opencode) launch_opencode "$mode" ;;
    codex)    launch_codex    "$mode" ;;
    *) echo "❌ backend desconhecido: '$BACKEND'"; return 127 ;;
  esac
}

launch_claude() {
  local args=(--append-system-prompt "$PROMPT")
  if [ "$ROLE" = leader ]; then
    # O líder ORQUESTRA: quem edita código é o coder. Bloquear as ferramentas de
    # escrita é o que impede, de fato, o líder de sair alterando o projeto do
    # usuário (ou a instalação do Orchestra) em vez de delegar — regra em prompt
    # é orientação, isto é impedimento.
    args+=(--disallowedTools Edit Write NotebookEdit)
  else
    # permite ao worker fechar o ciclo sem prompt de permissão
    args+=(--allowedTools "Bash(orchestra done:*)")
  fi
  [ -n "$ORCHESTRA_MODEL_CLAUDE" ] && args+=(--model "$ORCHESTRA_MODEL_CLAUDE")
  [ "$1" = resume ] && args=(--continue "${args[@]}")
  claude "${args[@]}"
}

launch_opencode() {
  local args=()
  [ -n "$ORCHESTRA_MODEL" ] && args+=(-m "$ORCHESTRA_MODEL")
  # Quando existe um agente homônimo na config do OpenCode, usamos ele — traz as
  # restrições de ferramenta do papel (ex.: reviewer sem write/edit).
  _opencode_has_agent "$ROLE" && args+=(--agent "$ROLE")
  # O prompt de papel é enviado SEMPRE: o agente da config do OpenCode tem prompt
  # próprio, que NÃO inclui o protocolo do Orchestra. Sem isto o worker responde
  # na TUI mas nunca executa 'orchestra done', e todo despacho morre em timeout.
  if [ "$1" = resume ]; then args+=(--continue); else args+=(--prompt "$PROMPT" "$PROJ"); fi
  "$OPENCODE" "${args[@]}"
}

launch_codex() {
  local sid args=(-C "$PROJ" -a never -s "$(codex_sandbox_for "$ROLE")" --no-alt-screen)
  # o runtime do Orchestra mora fora do projeto: sem abri-lo no sandbox o worker
  # não consegue gravar a resposta do 'orchestra done'
  local wr; wr="$(codex_writable_roots_arg)"
  [ -n "$wr" ] && args+=(-c "$wr")
  [ -n "$ORCHESTRA_CODEX_MODEL" ] && args+=(-m "$ORCHESTRA_CODEX_MODEL")
  if [ "$1" = resume ]; then
    sid="$(cat "$(_codex_session_file)" 2>/dev/null)"
    if [ -n "$sid" ]; then "$CODEX" resume "$sid" "${args[@]}"; else "$CODEX" resume --last "${args[@]}"; fi
  else
    _codex_claim_bg "$(date +%s)"
    "$CODEX" "${args[@]}" "$PROMPT"
  fi
}

# ---------------------------------------------------------------------------
# Supervisor: mantém a TUI viva.
# ---------------------------------------------------------------------------
mode=first
fast_failures=0
while true; do
  banner
  start=$(date +%s)
  launch "$mode"
  rc=$?
  elapsed=$(( $(date +%s) - start ))

  # crash-loop (binário ausente, flag inválida): não fica reiniciando em vão
  if [ "$elapsed" -lt 3 ]; then
    fast_failures=$((fast_failures+1))
  else
    fast_failures=0
  fi
  if [ "$fast_failures" -ge 3 ]; then
    echo
    printf '\033[1;31m✖ %s saiu %d vezes seguidas em menos de 3s (exit %d).\033[0m\n' "$BACKEND" "$fast_failures" "$rc"
    printf '   Rode \033[1morchestra doctor\033[0m para diagnosticar. Shell liberado abaixo.\n'
    printf '   Para tentar de novo: \033[1mexec %s %s\033[0m\n\n' "$ORCHESTRA_HOME/agents/run-agent.sh" "$AGENT"
    exec bash
  fi

  # janela para o usuário sair de verdade (Ctrl-C durante a contagem)
  stop=0
  trap 'stop=1' INT
  echo
  for i in 3 2 1; do
    printf '\r  \033[1;33m⟳\033[0m %s encerrou (exit %d) — reiniciando em %ss…  \033[2m(Ctrl-C cancela)\033[0m' "$AGENT" "$rc" "$i"
    sleep 1
    [ "$stop" = 1 ] && break
  done
  trap - INT
  echo
  if [ "$stop" = 1 ]; then
    printf '  reinício cancelado. Shell liberado — \033[1mexec %s %s\033[0m para voltar.\n\n' \
      "$ORCHESTRA_HOME/agents/run-agent.sh" "$AGENT"
    exec bash
  fi
  mode=resume
done
