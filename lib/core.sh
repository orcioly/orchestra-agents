#!/usr/bin/env bash
# Orchestra Agents — shared core.
#
# Model: a TEAM of N agents (leader + workers) running as LOCAL TUIs in
# zellij panes. The leader dispatches tasks by INJECTING text into the worker's pane
# (via lib/mux.sh) and receives the reply when the worker runs 'orchestra done'.
#
# There is no headless server and no stored session id: that is why /clear, /new,
# resize and moving a pane no longer break dispatching.
#
# Do not execute directly; it is sourced by the CLI and by the pane scripts.

# ----- Configuration (overridable by env or ~/.config/orchestra-agents/config) -----
ORCHESTRA_HOME="${ORCHESTRA_HOME:-$HOME/.orchestra-agents}"
ORCHESTRA_STATE="${ORCHESTRA_STATE:-$HOME/.local/state/orchestra-agents}"

# models: EMPTY by default => each CLI uses the model the user already configured.
ORCHESTRA_MODEL="${ORCHESTRA_MODEL:-}"                 # OpenCode (provider/model)
ORCHESTRA_CODEX_MODEL="${ORCHESTRA_CODEX_MODEL:-}"     # Codex (model name)
ORCHESTRA_MODEL_CLAUDE="${ORCHESTRA_MODEL_CLAUDE:-}"   # Claude Code

# team composition without a TTY (CI/scripts): "leader=claude,coder=opencode,reviewer=codex"
ORCHESTRA_TEAM="${ORCHESTRA_TEAM:-}"
# inherited aliases (they keep working)
ORCHESTRA_CODER="${ORCHESTRA_CODER:-}"
ORCHESTRA_REVIEWER="${ORCHESTRA_REVIEWER:-}"

# default timeout of 'await' (seconds)
ORCHESTRA_TIMEOUT="${ORCHESTRA_TIMEOUT:-300}"

# loads the user's config, if it exists
[ -f "$HOME/.config/orchestra-agents/config" ] && . "$HOME/.config/orchestra-agents/config"

mkdir -p "$ORCHESTRA_STATE"

# ----- Current project and runtime directories -----
# NOTHING from Orchestra is written to the root of the user's project. The team, the prompts and the
# runtime live OUTSIDE, in $ORCHESTRA_STATE/projects/<slug>/ — one directory per project.
#
# Why the state and not the install folder ($ORCHESTRA_HOME): install.sh does
# 'rm -rf "$INSTALL_DIR"' on every install to avoid mixing versions, so keeping
# the team there would erase it on EVERY update, for all projects at once.
#
# The slug carries the checksum of the ABSOLUTE path, and not just the basename: without it
# ~/cliente-a/api and ~/cliente-b/api would share the same team.
ORCHESTRA_PROJECT="${ORCHESTRA_PROJECT:-}"
if [ -z "$ORCHESTRA_PROJECT" ]; then
  ORCHESTRA_PROJECT="$(cat "$ORCHESTRA_STATE/project" 2>/dev/null)"
fi
[ -n "$ORCHESTRA_PROJECT" ] || ORCHESTRA_PROJECT="$PWD"

project_slug() { # $1 project (default: the current one) → <basename>-<path checksum>
  local proj="${1:-$ORCHESTRA_PROJECT}" slug hash
  # printf and not piping basename directly: 'tr -c' would convert the trailing \n into '-'
  slug="$(printf '%s' "$(basename "$proj")" | tr -c 'a-zA-Z0-9_-' '-')"
  while [ -n "$slug" ] && [ "${slug%-}" != "$slug" ]; do slug="${slug%-}"; done
  hash="$(printf '%s' "$proj" | cksum | cut -d' ' -f1)"
  if [ -n "$slug" ]; then printf '%s-%s' "$slug" "$hash"; else printf 'projeto-%s' "$hash"; fi
}

ORCHESTRA_DIR="$ORCHESTRA_STATE/projects/$(project_slug)"
ORCHESTRA_RUN_DIR="$ORCHESTRA_DIR/run"

# Migration for those who already used Orchestra: up to v0.2 the team lived in
# <project>/.orchestra. We move it ONCE, without overwriting anything that already exists at the
# destination, and leave the project clean. Silent on purpose: it runs on every
# 'source' of the core, including inside the panes.
_orchestra_migrate_legacy_dir() {
  local legacy="$ORCHESTRA_PROJECT/.orchestra" f base
  [ -d "$legacy" ] || return 0
  [ -e "$ORCHESTRA_DIR/team.json" ] && { rm -rf "$legacy" 2>/dev/null; return 0; }
  mkdir -p "$ORCHESTRA_DIR" 2>/dev/null || return 0
  for f in "$legacy"/* "$legacy"/.gitignore; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    [ "$base" = .gitignore ] && continue          # makes no sense in the new place
    [ -e "$ORCHESTRA_DIR/$base" ] || mv "$f" "$ORCHESTRA_DIR/$base" 2>/dev/null
  done
  rm -rf "$legacy" 2>/dev/null
}
_orchestra_migrate_legacy_dir

# Records which project this directory belongs to. The slug has a checksum and is not
# reversible, so without this the uninstall would have no way to find an orphan .orchestra/
# from an old version, and whoever opened ~/.local/state/orchestra-agents/projects/ would not
# know what each folder is.
_orchestra_stamp_project() {
  [ -d "$ORCHESTRA_DIR" ] || return 0
  [ "$(cat "$ORCHESTRA_DIR/project.path" 2>/dev/null)" = "$ORCHESTRA_PROJECT" ] && return 0
  printf '%s' "$ORCHESTRA_PROJECT" >"$ORCHESTRA_DIR/project.path" 2>/dev/null || true
}

# shellcheck source=/dev/null
. "$ORCHESTRA_HOME/lib/mux.sh"
# shellcheck source=/dev/null
. "$ORCHESTRA_HOME/lib/team.sh"
# shellcheck source=/dev/null
. "$ORCHESTRA_HOME/lib/layout.sh"
# shellcheck source=/dev/null
. "$ORCHESTRA_HOME/lib/menu.sh"

# ----- Resolving the backend binaries -----
_resolve_opencode() {
  if command -v opencode >/dev/null 2>&1; then command -v opencode; return; fi
  [ -x "$HOME/.opencode/bin/opencode" ] && { echo "$HOME/.opencode/bin/opencode"; return; }
  echo opencode
}
_resolve_codex() {
  if command -v codex >/dev/null 2>&1; then command -v codex; return; fi
  [ -x "$HOME/.local/bin/codex" ] && { echo "$HOME/.local/bin/codex"; return; }
  echo codex
}
OPENCODE="$(_resolve_opencode)"
CODEX="$(_resolve_codex)"

backend_available() { # $1 backend
  case "$1" in
    claude)   command -v claude >/dev/null 2>&1 ;;
    opencode) command -v opencode >/dev/null 2>&1 || [ -x "$HOME/.opencode/bin/opencode" ] ;;
    codex)    command -v codex   >/dev/null 2>&1 || [ -x "$HOME/.local/bin/codex" ] ;;
    *) return 1 ;;
  esac
}

backend_url() { # $1 backend  → where to install
  case "$1" in
    claude)   echo "https://docs.claude.com/claude-code" ;;
    opencode) echo "https://opencode.ai" ;;
    codex)    echo "https://developers.openai.com/codex/cli" ;;
  esac
}

# Codex sandbox. All roles need to write to the runtime to close the cycle
# with 'orchestra done', so we use workspace-write even for the reviewer — its
# read-only discipline is guaranteed by the role prompt, not by the sandbox.
codex_sandbox_for() { # $1 role
  echo "${ORCHESTRA_CODEX_SANDBOX:-workspace-write}"
}

# The runtime left the project, and 'workspace-write' only allows writing to the
# workspace: without this the 'orchestra done' of a codex worker dies with "Operation not
# permitted" and EVERY dispatch to it ends in timeout. 'writable_roots' opens
# exactly that project's Orchestra directory and nothing else — the sandbox
# still applies to the rest of the disk. Verified on codex-cli 0.149.1.
codex_writable_roots_arg() { # → echoes the '-c key=value' pair (nothing if there is no dir)
  [ -n "${ORCHESTRA_DIR:-}" ] || return 0
  printf 'sandbox_workspace_write.writable_roots=["%s"]' "$ORCHESTRA_DIR"
}

# ----- OpenCode: config and agents -----
# resolves the OpenCode config honoring OPENCODE_CONFIG and XDG_CONFIG_HOME
oc_config_path() {
  if [ -n "${OPENCODE_CONFIG:-}" ]; then echo "$OPENCODE_CONFIG"; return; fi
  local dir="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
  [ -f "$dir/opencode.jsonc" ] && { echo "$dir/opencode.jsonc"; return; }
  [ -f "$dir/opencode.json" ]  && { echo "$dir/opencode.json";  return; }
  echo "$dir/opencode.jsonc"
}

# ensures the 'reviewer' agent in the OpenCode config — automatic and idempotent.
# When the merge returns 0 it was IT that inserted the agent; we record that so the
# uninstall can undo it. Without the mark, a 'reviewer' that already belonged to the user would be
# deleted on uninstall — the same care that already exists with zellij.
ensure_reviewer_agent() {
  local script="$ORCHESTRA_HOME/config/merge_reviewer.py"
  local tmpl="$ORCHESTRA_HOME/config/opencode.reviewer.jsonc"
  [ -f "$script" ] && [ -f "$tmpl" ] && command -v python3 >/dev/null 2>&1 || return 0
  if python3 "$script" "$(oc_config_path)" "$tmpl" >/dev/null 2>&1; then
    printf '%s' "$(oc_config_path)" >"$ORCHESTRA_STATE/opencode.reviewer.ours" 2>/dev/null || true
  fi
  return 0
}

# Undoes ensure_reviewer_agent. Only acts if the mark exists.
remove_reviewer_agent() {
  local mark="$ORCHESTRA_STATE/opencode.reviewer.ours" script cfg rc
  [ -f "$mark" ] || return 0
  cfg="$(cat "$mark" 2>/dev/null)"; [ -n "$cfg" ] || return 0
  script="$ORCHESTRA_HOME/config/remove_reviewer.py"
  [ -f "$script" ] && command -v python3 >/dev/null 2>&1 || return 0
  python3 "$script" "$cfg" >/dev/null 2>&1; rc=$?
  case "$rc" in
    0)  echo "  removido o agente 'reviewer' de $cfg (tinha sido posto pelo Orchestra)" ;;
    3)  echo "  ⚠️  o agente 'reviewer' ficou em $cfg — o arquivo tem comentários seus e"
        echo "     não quis reformatá-lo; apague o bloco \"reviewer\" à mão se quiser" ;;
  esac
  return 0
}

# is there an agent with that name in the OpenCode config?
_opencode_has_agent() { # $1 name
  local cfg; cfg="$(oc_config_path)"
  [ -f "$cfg" ] || return 1
  grep -q "\"$1\"" "$cfg" 2>/dev/null
}

# reads the default model already configured in OpenCode
_detect_model() {
  local cfg
  for cfg in "$(oc_config_path)"; do
    [ -f "$cfg" ] || continue
    python3 - "$cfg" <<'PY'
import sys, re, json
src = open(sys.argv[1]).read()
src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)          # block comments
src = re.sub(r'(?m)(^|\s)//.*$', '', src)                 # line comments (preserves http://)
try:
    print(json.loads(src).get("model") or "")
except Exception:
    raise SystemExit(1)
PY
    return 0
  done
  return 1
}

_effective_model() {
  if [ -n "$ORCHESTRA_MODEL" ]; then echo "$ORCHESTRA_MODEL"; else _detect_model 2>/dev/null || true; fi
}

# ---------------------------------------------------------------------------
# Agent runtime
# ---------------------------------------------------------------------------
# bash's printf '%-Ns' counts BYTES: an accent (LÍDER) shrinks the column by 1 and
# misaligns the whole table. This padding counts CHARACTERS.
_pad() { # $1 text  $2 width
  local t="$1" n="${2:-0}" i=${#1}
  printf '%s' "$t"
  while [ "$i" -lt "$n" ]; do printf ' '; i=$((i+1)); done
}

# "a b c" -> "a, b, c" — every list shown to the user goes through here
_human_list() { printf '%s' "$1" | tr -s ' ' '\n' | sed '/^$/d' | paste -sd',' - | sed 's/,/, /g'; }

# truncates preserving the visual width (counts characters, not bytes)
_ellipsis() { # $1 text  $2 width
  local t="$1" n="${2:-0}"
  if [ "${#t}" -gt "$n" ]; then printf '%s…' "${t:0:$((n-1))}"; else printf '%s' "$t"; fi
}

_run_file() { echo "$ORCHESTRA_RUN_DIR/$1.$2"; }   # $1 agent  $2 suffix

_new_task_id() { printf 'T%s%04d' "$(date +%s)" "$((RANDOM % 10000))"; }

# ensures the agent exists, with a useful message when it does not
_require_agent() { # $1 name
  team_ensure
  if [ -z "${1:-}" ]; then
    echo "❌ falta o nome do agente. Agentes: $(team_names | tr '\n' ' ')" >&2; return 1
  fi
  if ! team_exists "$1"; then
    echo "❌ agente '$1' não existe. Agentes: $(team_names | tr '\n' ' ')" >&2
    echo "   crie com: orchestra add $1" >&2
    return 1
  fi
}

# resolves the agent's pane, RECREATING it if it died (self-healing).
_pane_for() { # $1 agent  → echoes pane-id
  local agent="$1" pane
  pane="$(mux_pane_id "$agent" 2>/dev/null)"
  if [ -n "$pane" ]; then echo "$pane"; return 0; fi
  mux_available || { echo "❌ multiplexador indisponível — rode 'orchestra'" >&2; return 1; }
  echo "⚠️  painel de '$agent' não está aberto — recriando…" >&2
  pane="$(mux_new_pane "$agent" "$ORCHESTRA_PROJECT")" || {
    echo "❌ não consegui recriar o painel de '$agent'" >&2; return 1; }
  # gives the TUI a moment to come up before injecting text
  sleep 3
  echo "$pane"
}

# ---------------------------------------------------------------------------
# Dispatch (ASYNCHRONOUS): injects the task into the agent's pane.
# ---------------------------------------------------------------------------
dispatch() { # $1 agent  $2.. text
  local agent="${1:-}"; shift 2>/dev/null || true
  local text="$*" pane task payload
  _require_agent "$agent" || return 1
  [ -n "$text" ] || { echo "❌ tarefa vazia. uso: orchestra send $agent \"<tarefa>\"" >&2; return 1; }

  pane="$(_pane_for "$agent")" || return 1
  mkdir -p "$ORCHESTRA_RUN_DIR"

  task="$(_new_task_id)"
  printf '%s' "$task" >"$(_run_file "$agent" task)"
  printf 'running'    >"$(_run_file "$agent" status)"
  rm -f "$(_run_file "$agent" out)" 2>/dev/null || true

  payload="$(cat <<EOF
$text

─────
[ORCHESTRA task=$task] Ao concluir ESTA tarefa, execute no shell:

    orchestra done $agent $task <<'ORCHESTRA_EOF'
    <sua resposta final>
    ORCHESTRA_EOF
EOF
)"

  mux_send_text "$pane" "$payload" || { echo "❌ falha ao injetar a tarefa no painel de '$agent'" >&2; return 1; }
  mux_enter "$pane" || { echo "❌ falha ao submeter a tarefa em '$agent'" >&2; return 1; }
  echo "📨 tarefa $task enviada a '$agent' (painel $pane) — rodando ao vivo, sem bloquear o líder"
}

# ---------------------------------------------------------------------------
# 'orchestra done' — called BY THE WORKER to hand back the reply (reads stdin).
# ---------------------------------------------------------------------------
done_reply() { # $1 agent  $2 task_id
  local agent="${1:-}" task="${2:-}" cur body
  _require_agent "$agent" || return 1
  mkdir -p "$ORCHESTRA_RUN_DIR"
  cur="$(cat "$(_run_file "$agent" task)" 2>/dev/null)"
  body="$(cat)"
  if [ -n "$task" ] && [ -n "$cur" ] && [ "$task" != "$cur" ]; then
    echo "⚠️  task '$task' não é a tarefa corrente de '$agent' ('$cur') — resposta ignorada." >&2
    return 1
  fi
  printf '%s\n' "$body" >"$(_run_file "$agent" out)"
  printf 'done'          >"$(_run_file "$agent" status)"
  echo "✅ resposta de '$agent' registrada (task ${task:-$cur})"
}

# ---------------------------------------------------------------------------
# Reading the result
# ---------------------------------------------------------------------------
result() { # $1 agent  (non-blocking)
  local agent="${1:-}" st
  _require_agent "$agent" || return 1
  st="$(cat "$(_run_file "$agent" status)" 2>/dev/null)"
  if [ -s "$(_run_file "$agent" out)" ]; then cat "$(_run_file "$agent" out)"; return 0; fi
  case "$st" in
    running) echo "(sem resposta ainda — '$agent' está processando)" ;;
    *)       echo "(sem resposta ainda — nenhuma tarefa despachada para '$agent')" ;;
  esac
}

# BLOCKING: waits for the reply of the LAST dispatched task.
# exit 0 ok · 1 validation · 2 timeout ([TIMEOUT/PARCIAL]) · 3 environment error
result_wait() { # $1 agent  $2 timeout  $3 caller
  local agent="${1:-}" timeout="${2:-$ORCHESTRA_TIMEOUT}" caller="${3:-}"
  local elapsed=0 interval=2 st pane usage_msg

  if [ "$caller" = await ]; then usage_msg="uso: orchestra await <agente> [timeout_segundos]"
  else usage_msg="uso: orchestra result <agente> --wait [timeout_segundos]"; fi
  [ -n "$agent" ] || { echo "$usage_msg" >&2; return 1; }
  _require_agent "$agent" || return 1
  if ! [[ "$timeout" =~ ^[0-9]+$ ]]; then
    echo "❌ timeout inválido: '$timeout' (inteiro positivo de segundos)" >&2; return 1
  fi
  if [ ! -s "$(_run_file "$agent" task)" ]; then
    echo "❌ nenhuma tarefa despachada para '$agent' — rode 'orchestra send $agent \"…\"' antes" >&2
    return 1
  fi

  while [ "$elapsed" -lt "$timeout" ]; do
    st="$(cat "$(_run_file "$agent" status)" 2>/dev/null)"
    case "$st" in
      done)  cat "$(_run_file "$agent" out)"; return 0 ;;
      error) echo "❌ '$agent' reportou erro:" >&2; cat "$(_run_file "$agent" out)" 2>/dev/null; return 3 ;;
    esac
    sleep "$interval"; elapsed=$((elapsed+interval))
  done

  # timeout: returns whatever it can, ALWAYS marked as unreliable.
  echo "⚠️  timeout (${timeout}s) esperando '$agent'." >&2
  if [ -s "$(_run_file "$agent" out)" ]; then
    printf '[TIMEOUT/PARCIAL] '; cat "$(_run_file "$agent" out)"
  else
    # fallback: tail of the pane's screen — the worker may have answered without
    # running 'orchestra done'.
    pane="$(mux_pane_id "$agent" 2>/dev/null)"
    if [ -n "$pane" ]; then
      echo "⚠️  sem 'orchestra done' — mostrando a cauda do painel (NÃO confiável):" >&2
      printf '[TIMEOUT/PARCIAL] '; mux_capture "$pane" | tail -n 40
    else
      echo "[TIMEOUT/PARCIAL] (sem resposta e sem painel)"
    fi
  fi
  return 2
}

# ---------------------------------------------------------------------------
# Team management
# ---------------------------------------------------------------------------
# readable state of the agent's last task
_agent_state() { # $1 agent
  case "$(cat "$(_run_file "$1" status)" 2>/dev/null)" in
    running) printf 'trabalhando…' ;;
    done)    printf 'respondeu' ;;
    error)   printf 'erro' ;;
    *)       printf '—' ;;
  esac
}

# one row of the team table (same column order as the menu)
_agent_row() { # $1 agent
  local n="$1" icon lbl desc b pane
  if [ "$n" = leader ]; then icon="$(role_icon leader)"; lbl=LÍDER
  else icon="$(role_icon "$(team_field "$n" role)")"
       lbl="$(printf '%s' "$n" | tr '[:lower:]' '[:upper:]')"; fi
  desc="$(_ellipsis "$(role_summary "$n")" 29)"
  b="$(team_field "$n" backend)"
  pane="$(mux_pane_id "$n" 2>/dev/null)"
  printf '   %s %s %s %s %s %s\n' "$icon" "$(_pad "$(_ellipsis "$lbl" 10)" 11)" "$(_pad "$desc" 30)" \
    "$(_pad "$b" 9)" "$(_pad "$([ -n "$pane" ] && echo aberto || echo '⚠ ausente')" 9)" \
    "$([ "$n" = leader ] && echo '—' || _agent_state "$n")"
}

agents_list() {
  team_ensure
  local n
  printf '\n🎼 \033[1mTime em %s\033[0m\n\n' "$ORCHESTRA_PROJECT"
  printf '   \033[2m%s %s %s %s %s\033[0m\n' "$(_pad AGENTE 14)" "$(_pad "O QUE FAZ" 30)" \
    "$(_pad IA 9)" "$(_pad PAINEL 9)" "ÚLTIMA TAREFA"
  _agent_row leader
  while IFS= read -r n; do [ -n "$n" ] && _agent_row "$n"; done < <(team_names)
  printf '\n  \033[2mdespache com: orchestra send <agente> "<tarefa>"  ·  orchestra await <agente>\033[0m\n\n'
}

# Resolves the role of a NEW agent: a known preset, or 'custom' with an
# editable prompt in the project. Echoes "role<TAB>prompt_file". Used by 'add' and by
# ORCHESTRA_TEAM, so both paths create identical agents.
_resolve_role() { # $1 name  [$2 desired role]  [$3 prompt text]
  local name="$1" role="${2:-}" text="${3:-}" pf=""
  [ -n "$role" ] || role="$name"
  # instructions given at creation => custom agent, with the user's text
  if [ -n "$text" ]; then
    mkdir -p "$(team_prompts)"
    pf="prompts/$name.md"
    { printf 'Você é o agente **%s** do Orchestra Agents.\n\n' "$name"
      printf '%s\n' "$text"
      printf '\nTrabalhe no projeto onde este painel foi aberto.\n'
    } >"$ORCHESTRA_DIR/$pf"
    printf '%s\t%s' custom "$pf"
    return 0
  fi
  case " $ORCHESTRA_ROLES " in
    *" $role "*) ;;
    *) role=custom
       mkdir -p "$(team_prompts)"
       pf="prompts/$name.md"
       [ -f "$ORCHESTRA_DIR/$pf" ] || {
         cp "$ORCHESTRA_HOME/agents/roles/custom.md" "$ORCHESTRA_DIR/$pf" 2>/dev/null || \
           printf 'Você é o agente %s do Orchestra.\n' "$name" >"$ORCHESTRA_DIR/$pf"
       } ;;
  esac
  printf '%s\t%s' "$role" "$pf"
}

# Tells the LEADER, LIVE, that the team changed — injecting the note into its pane.
# Without this the leader only knows the team assembled when its pane came up, and an agent
# created later would be ignored until the next 'orchestra'.
notify_leader() { # $1 text
  local pane self
  mux_available || return 0
  pane="$(mux_pane_id leader 2>/dev/null)"
  [ -n "$pane" ] || return 0
  # if the command came from the leader's own pane, it already knows: do not inject into itself
  self="${ZELLIJ_PANE_ID:-}"
  [ -n "$self" ] && [ "$pane" = "terminal_$self" ] && return 0
  mux_send_text "$pane" "$1" && mux_enter "$pane"
}

agent_add() { # $1 name  [$2 backend]  [$3 role]  [$4 prompt text]
  local name="${1:-}" backend="${2:-}" role="${3:-}" text="${4:-}" pf="" rc
  team_ensure
  team_valid_name "$name" || {
    case "$name" in
      *' '*) echo "❌ o nome não pode ter espaços: '$name' — use - ou _ (ex.: deploy-prod)" >&2 ;;
      leader) echo "❌ 'leader' é reservado — use 'orchestra leader <ia>' para trocar o líder" >&2
              return 1 ;;
      *) echo "❌ nome inválido: '$name' — comece por letra e use só minúsculas, dígitos, - ou _" >&2 ;;
    esac
    echo "   (o nome vira comando: orchestra send <nome> \"<tarefa>\")" >&2
    return 1; }
  team_exists "$name" && { echo "❌ agente '$name' já existe" >&2; return 1; }
  # The IA is the USER'S CHOICE — never a silent default. Without it: ask (if a
  # human is typing) or fail explaining. This is what stops a leader agent from
  # creating everything in 'claude' just for having forgotten the flag.
  if [ -z "$backend" ]; then
    if [ -t 0 ]; then
      printf 'qual IA roda o agente "%s"? [%s]: ' "$name" "$(_human_list "$ORCHESTRA_BACKENDS")"
      read -r backend || backend=""
    fi
    if [ -z "$backend" ]; then
      echo "❌ falta dizer qual IA roda o agente '$name'." >&2
      echo "   use: orchestra add $name --ia $(printf '%s' "$ORCHESTRA_BACKENDS" | tr ' ' '|') --prompt \"<o que ele faz>\"" >&2
      echo "   (a escolha da IA é do usuário — pergunte a ele antes de criar)" >&2
      return 1
    fi
  fi
  case " $ORCHESTRA_BACKENDS " in *" $backend "*) ;; *) echo "❌ IA inválida: '$backend' (use: $(_human_list "$ORCHESTRA_BACKENDS"))" >&2; return 1 ;; esac
  backend_available "$backend" || { echo "❌ '$backend' não está instalado — $(backend_url "$backend")" >&2; return 1; }
  IFS=$'\t' read -r role pf <<<"$(_resolve_role "$name" "$role" "$text")"
  team_add "$name" "$backend" "$role" "$pf"; rc=$?
  [ "$rc" = 0 ] || { echo "❌ falha ao registrar '$name'" >&2; return 1; }
  echo "✔ agente '$name' criado ($backend · $role)"
  if [ -n "$pf" ]; then
    echo "  prompt em: $(team_prompt_path "$pf") (edite à vontade)"
    # without a description the agent is generic AND the leader does not know when to use it
    if [ -z "$text" ]; then
      echo "  ⚠️  ele ainda não tem especialidade: o líder vai vê-lo como 'agente customizado'."
      echo "     Descreva a função no arquivo acima, ou recrie com:"
      echo "     orchestra add $name --ia $backend --prompt \"<o que ele faz>\""
    fi
  fi
  if mux_available; then
    mux_new_pane "$name" "$ORCHESTRA_PROJECT" >/dev/null && echo "  🎬 painel aberto"
  else
    echo "  (sem multiplexador ativo — o painel abre no próximo 'orchestra')"
  fi
  notify_leader "$(cat <<EOF
[ORCHESTRA] O time mudou: o agente '$name' entrou agora ($backend).
Função: $(role_summary "$name")
Delegue com: orchestra send $name "<tarefa>"   ·   resultado: orchestra await $name
Passe a considerá-lo nas próximas tarefas que forem da função dele. Responda só "ok".
EOF
)" && echo "  📣 líder avisado"
}

agent_rm() { # $1 name
  local name="${1:-}" pane
  team_ensure
  [ -n "$name" ] || { echo "❌ falta o nome. uso: orchestra rm <agente>" >&2; return 1; }
  [ "$name" = leader ] && { echo "❌ o líder não pode ser removido — troque com 'orchestra leader <backend>'" >&2; return 1; }
  team_exists "$name" || { echo "❌ agente '$name' não existe" >&2; return 1; }
  pane="$(mux_pane_id "$name" 2>/dev/null)"
  team_rm "$name" || { echo "❌ falha ao remover '$name'" >&2; return 1; }
  [ -n "$pane" ] && mux_kill_pane "$pane" >/dev/null 2>&1
  rm -f "$ORCHESTRA_RUN_DIR/$name."* 2>/dev/null || true
  echo "✔ agente '$name' removido"
  notify_leader "[ORCHESTRA] O time mudou: o agente '$name' saiu. NÃO delegue mais para ele. Responda só \"ok\"." \
    && echo "  📣 líder avisado"
}

# recreates the panes of agents whose pane died/was closed
heal() {
  team_ensure
  mux_available || { echo "❌ multiplexador indisponível — rode 'orchestra'" >&2; return 1; }
  local n missing=0
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if [ -z "$(mux_pane_id "$n" 2>/dev/null)" ]; then
      printf '  ⟳ recriando painel de %s…' "$n"
      if mux_new_pane "$n" "$ORCHESTRA_PROJECT" >/dev/null; then echo ' ok'; else echo ' falhou'; fi
      missing=$((missing+1))
    fi
  done < <(team_all_names)
  [ "$missing" = 0 ] && echo "✔ todos os painéis estão no ar" || echo "✔ $missing painel(is) recriado(s)"
}

# switches the leader's backend
leader_set() { # $1 backend
  local b="${1:-}" pane
  team_ensure
  case " $ORCHESTRA_BACKENDS " in *" $b "*) ;; *) echo "❌ IA inválida: '$b' (use: $(_human_list "$ORCHESTRA_BACKENDS"))" >&2; return 1 ;; esac
  backend_available "$b" || { echo "❌ '$b' não está instalado — $(backend_url "$b")" >&2; return 1; }
  team_set leader backend "$b" || { echo "❌ falha ao trocar o líder" >&2; return 1; }
  echo "✔ líder agora é $b"
  pane="$(mux_pane_id leader 2>/dev/null)"
  if [ -n "$pane" ]; then
    echo "  ⚠️  o painel do líder ainda roda o backend anterior."
    echo "     Feche-o (Ctrl-C durante a contagem) ou rode 'orchestra' de novo para aplicar."
  fi
}

status() {
  team_ensure
  local s; s="$(mux_session 2>/dev/null)"
  if mux_available; then echo "🟢 multiplexador: $(mux_backend) (sessão ${s:-?})"
  else echo "⚪ multiplexador: fora do ar (rode 'orchestra')"; fi
  echo "   projeto: $ORCHESTRA_PROJECT"
  echo "   time:    $(team_file)"
  agents_list
}

# Ends ALL Orchestra sessions, of all projects. 'teardown' only takes care of
# the session registered in the state; whoever has several projects open would leave the
# others behind — and the user has no way to know that when uninstalling.
kill_all_sessions() {
  command -v zellij >/dev/null 2>&1 || return 0
  local s n=0
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    zellij delete-session --force "$s" >/dev/null 2>&1 && { echo "  🛑 sessão '$s' encerrada"; n=$((n+1)); }
  done < <(zellij list-sessions --no-formatting 2>/dev/null | awk '{print $1}' | grep '^orchestra-' || true)
  [ "$n" = 0 ] && echo "  (nenhuma sessão do Orchestra estava aberta)"
  return 0
}

teardown() {
  local s; s="$(mux_session 2>/dev/null)"
  if [ -n "$s" ] && [ "$(mux_backend)" = zellij ]; then
    if zellij delete-session --force "$s" >/dev/null 2>&1; then
      echo "🛑 sessão '$s' encerrada"; return 0
    fi
  fi
  echo "nada para encerrar (nenhuma sessão ativa registrada)"
}

# ---------------------------------------------------------------------------
# VISUAL team composition menu (arrows). Draws on /dev/tty.
# Without a TTY (CI/pipe) it uses ORCHESTRA_TEAM / the saved team, without hanging.
# ---------------------------------------------------------------------------

# applies ORCHESTRA_TEAM and the inherited aliases on top of the saved team
# Applies ORCHESTRA_TEAM ("name=backend" or "name=backend:role", separated by
# commas) and the inherited aliases on top of the saved team.
_apply_team_env() {
  local spec pair name rest backend role pf
  [ -n "$ORCHESTRA_CODER" ]    && team_set coder    backend "$ORCHESTRA_CODER"    2>/dev/null
  [ -n "$ORCHESTRA_REVIEWER" ] && team_set reviewer backend "$ORCHESTRA_REVIEWER" 2>/dev/null
  [ -n "$ORCHESTRA_TEAM" ] || return 0
  spec="${ORCHESTRA_TEAM//,/ }"
  for pair in $spec; do
    name="${pair%%=*}"; rest="${pair#*=}"
    backend="${rest%%:*}"
    # explicit role only when the ':role' suffix exists
    if [ "$rest" = "$backend" ]; then role=""; else role="${rest#*:}"; fi
    [ -n "$name" ] && [ -n "$backend" ] || continue
    case " $ORCHESTRA_BACKENDS " in *" $backend "*) ;; *) continue ;; esac
    if [ "$name" = leader ]; then team_set leader backend "$backend"; continue; fi
    team_valid_name "$name" || continue
    if team_exists "$name"; then
      team_set "$name" backend "$backend"
      # changing an existing agent's role also redoes the prompt when custom
      if [ -n "$role" ] && [ "$role" != "$(team_field "$name" role)" ]; then
        IFS=$'\t' read -r role pf <<<"$(_resolve_role "$name" "$role")"
        team_set "$name" role "$role"
        [ -n "$pf" ] && team_set "$name" prompt_file "$pf"
      fi
    else
      IFS=$'\t' read -r role pf <<<"$(_resolve_role "$name" "$role")"
      team_add "$name" "$backend" "$role" "$pf" 2>/dev/null || true
    fi
  done
}

select_team() {
  team_ensure
  _apply_team_env
  # without a controlling terminal (pipe/CI) or with the team already pinned by env: does not open the UI
  if [ -n "$ORCHESTRA_TEAM" ] || ! ( : >/dev/tty ) 2>/dev/null; then return 0; fi

  # The engine (read key, hide/restore cursor, relative redraw) lives in
  # lib/menu.sh — see that file's header for the two traps it
  # carries (bash 3.2's 'read -t' and the absolute cursor anchor). Here only the
  # CONTENT of this menu: which lines exist and what each key does on them.
  local names=() backends=() roles=() row=0 nrows key i
  _st_load() {
    names=(leader); backends=("$(team_field leader backend)"); roles=(leader)
    local n
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      names+=("$n"); backends+=("$(team_field "$n" backend)"); roles+=("$(team_field "$n" role)")
    done < <(team_names)
    # +2 special lines at the end: "adicionar agente" (add agent) and "sair" (quit)
    nrows=$(( ${#names[@]} + 2 ))
  }
  _st_row_add()  { echo "${#names[@]}"; }
  _st_row_quit() { echo "$(( ${#names[@]} + 1 ))"; }
  _st_cycle() { # switches the current line's backend
    [ "$row" -lt "${#names[@]}" ] || return 0
    local cur="${backends[$row]}" list=($ORCHESTRA_BACKENDS) j=0 k
    for k in "${!list[@]}"; do [ "${list[$k]}" = "$cur" ] && j=$k; done
    backends[$row]="${list[$(( (j+1) % ${#list[@]} ))]}"
  }
  _st_render() {
    local i arrow lbl b cell line sep desc
    menu_draw_begin
    menu_tty '   \033[2m%s %s %s\033[0m\n' \
      "$(_pad AGENTE 14)" "$(_pad "O QUE FAZ" 30)" "IA QUE RODA"
    for i in "${!names[@]}"; do
      [ "$i" = "$row" ] && arrow='\033[1;36m▸\033[0m' || arrow=' '
      [ "${roles[$i]}" = leader ] && lbl="LÍDER" \
        || lbl="$(printf '%s' "${names[$i]}" | tr '[:lower:]' '[:upper:]')"
      desc="$(_ellipsis "$(role_summary "${names[$i]}")" 29)"
      line=""; sep=""
      for b in $ORCHESTRA_BACKENDS; do
        # no spaces inside the cell: any padding only on the highlight would misalign
        # the whole column, because each row highlights a different IA.
        if [ "$b" = "${backends[$i]}" ]; then cell="\033[1;7;36m$b\033[0m"; else cell="\033[2m$b\033[0m"; fi
        line="$line$sep$cell"; sep="\033[2m,\033[0m "
      done
      menu_tty ' %b %s %s %s %b\033[K\n' "$arrow" "$(role_icon "${roles[$i]}")" \
        "$(_pad "$(_ellipsis "$lbl" 10)" 11)" "$(_pad "$desc" 30)" "$line"
    done
    menu_tty '\033[K\n'
    [ "$row" = "$(_st_row_add)" ] && arrow='\033[1;36m▸\033[0m' || arrow=' '
    menu_tty ' %b \033[1m+\033[0m adicionar agente\033[K\n' "$arrow"
    [ "$row" = "$(_st_row_quit)" ] && arrow='\033[1;36m▸\033[0m' || arrow=' '
    menu_tty ' %b \033[1m✖\033[0m sair sem abrir\033[K\n' "$arrow"
    menu_tty '\033[K\n'
    menu_tty '   \033[2m↑/↓ navegar · ←/→ trocar a IA · a adicionar · d remover\033[0m\033[K\n'
    menu_tty '   \033[2mEnter abre o time no zellij · q sai sem abrir\033[0m\033[K\n'
    # header + agents + blank + add + quit + blank + 2 of help
    menu_draw_end "$(( ${#names[@]} + 7 ))"
  }
  _st_add() {
    local name backend role
    menu_erase
    menu_end; menu_tty '\n'
    # the name becomes a command argument ('orchestra send <name>'), hence the rule
    # is strict. We explain BEFORE and let them try again, instead of just refusing.
    while true; do
      printf '  nome do agente \033[2m— minúsculas, sem espaços e sem acentos (ex.: tester, deploy-prod)\033[0m\n  ▸ ' >/dev/tty
      read -r name </dev/tty || name=""
      case "$name" in
        '') printf '  \033[2mcancelado\033[0m\n' >/dev/tty; sleep 1; menu_begin; return ;;
      esac
      if [ "$name" = leader ]; then
        printf '  ✖ "leader" é reservado — troque a IA do líder com ←/→ na linha dele\n' >/dev/tty; continue
      fi
      if team_exists "$name"; then
        printf '  ✖ já existe um agente chamado "%s" — escolha outro nome\n' "$name" >/dev/tty; continue
      fi
      case "$name" in
        *' '*) printf '  ✖ o nome não pode ter espaços — use - ou _ (ex.: deploy-prod)\n' >/dev/tty; continue ;;
      esac
      if ! team_valid_name "$name"; then
        printf '  ✖ nome inválido: comece por letra e use só minúsculas, números, - ou _\n' >/dev/tty
        printf '    \033[2m(o nome vira comando: orchestra send <nome> "<tarefa>")\033[0m\n' >/dev/tty
        continue
      fi
      break
    done
    printf '  função — pronta [%s]\n' "$(_human_list "$ORCHESTRA_ROLES")" >/dev/tty
    printf '           ou escreva a sua (ex.: frontend, deploy) [Enter = %s]: ' "$name" >/dev/tty
    read -r role </dev/tty || role=""
    [ -n "$role" ] || role="$name"
    printf '  qual IA roda esse agente [%s] (Enter = claude): ' "$(_human_list "$ORCHESTRA_BACKENDS")" >/dev/tty
    read -r backend </dev/tty || backend=""
    [ -n "$backend" ] || backend=claude
    case " $ORCHESTRA_BACKENDS " in *" $backend "*) ;; *) backend=claude ;; esac
    # role without a preset => the user describes the function right here
    local text=""
    case " $ORCHESTRA_ROLES " in
      *" $role "*) ;;
      *) printf '  o que ele faz? \033[2m— é isto que ensina a função a ele E diz ao líder\n' >/dev/tty
         printf '                  quando usá-lo (ex.: "Abre e atualiza Pull Requests via gh")\033[0m\n  ▸ ' >/dev/tty
         read -r text </dev/tty || text=""
         if [ -z "$text" ]; then
           printf '  \033[2m⚠️  sem descrição ele fica genérico; edite depois em %s/%s.md\033[0m\n' \
             "$(team_prompts)" "$name" >/dev/tty
           sleep 2
         fi ;;
    esac
    agent_add "$name" "$backend" "$role" "$text" >/dev/null 2>&1
    _st_load; menu_begin
  }
  _st_del() {
    [ "$row" -lt "${#names[@]}" ] || return 0
    [ "${roles[$row]}" = leader ] && return 0
    menu_erase
    # menu_confirm() already takes care of showing/hiding the cursor (the menu's trap
    # stays armed) — it is not 'menu_end'/'menu_begin' as in '_st_add', which
    # needs the screen free for several full-line prompts. Default NO
    # (the second argument is the warning shown with ⚠): a lone Enter does not remove.
    if menu_confirm "Remover \"${names[$row]}\" do time?" \
        "A remoção é permanente. O painel e o histórico dele somem."; then
      agent_rm "${names[$row]}" >/dev/null 2>&1
      _st_load; [ "$row" -ge "$nrows" ] && row=$((nrows-1))
    fi
  }

  _st_load
  menu_tty '\n\033[1m🎛️  Monte o time deste projeto\033[0m\n'
  menu_tty '   \033[2m%s\033[0m\n\n' "$ORCHESTRA_PROJECT"
  menu_begin
  _st_render
  local quit=0
  while true; do
    menu_read_key key || break
    case "$key" in
      up)         row=$(( (row+nrows-1)%nrows )) ;;
      down)       row=$(( (row+1)%nrows )) ;;
      left|right) _st_cycle ;;
      esc)        quit=1; break ;;
      # Escape sequence recognized (by lib/menu.sh) but not an arrow — Delete,
      # Home/End, PageUp/PageDown, F1-F12, arrow in application mode. NOT "esc": the
      # screen bytes are the same as pressing Esc, but canceling the whole session
      # because the user looked for the Delete key (the menu help says "d remover")
      # would be the worst possible no-op. Ignore and keep going in the loop, as HEAD did
      # before an "unknown" branch existed (there, the whole sequence was ignored
      # for lack of any *) branch in this case).
      unknown)    : ;;
      space)
        if   [ "$row" = "$(_st_row_add)" ];  then _st_add
        elif [ "$row" = "$(_st_row_quit)" ]; then quit=1; break
        else _st_cycle; fi ;;
      k|K) row=$(( (row+nrows-1)%nrows )) ;;
      j|J) row=$(( (row+1)%nrows )) ;;
      h|H|l|L) _st_cycle ;;
      a|A) _st_add ;;
      d|D) _st_del ;;
      q|Q) quit=1; break ;;
      enter)
        if   [ "$row" = "$(_st_row_add)" ];  then _st_add
        elif [ "$row" = "$(_st_row_quit)" ]; then quit=1; break
        else break; fi ;;
    esac
    _st_render
  done
  menu_end
  menu_tty '\n'

  # left through "sair": discards the backend changes made on screen and signals
  # cancellation to the caller (the 'up' does not open zellij).
  if [ "$quit" = 1 ]; then
    unset -f _st_cycle _st_render _st_load _st_add _st_del _st_row_add _st_row_quit
    return 2
  fi

  # persists the choices
  local specs=()
  for i in "${!names[@]}"; do specs+=("${names[$i]}=${backends[$i]}:${roles[$i]}"); done
  team_replace "${specs[@]}"
  unset -f _st_cycle _st_render _st_load _st_add _st_del _st_row_add _st_row_quit
}

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------
doctor() {
  local ok=0 warn=0 fail=0 b p n
  _dok(){   printf '  \033[1;32m✔\033[0m %s\n' "$*"; ok=$((ok+1)); }
  _dwarn(){ printf '  \033[1;33m!\033[0m %s\n' "$*"; warn=$((warn+1)); }
  _dfail(){ printf '  \033[1;31m✖\033[0m %s\n' "$*"; fail=$((fail+1)); }

  printf '\n🩺 Orchestra Agents — diagnóstico\n\n'
  team_ensure

  echo "Base:"
  for b in zellij git python3; do
    if p="$(command -v "$b" 2>/dev/null)"; then _dok "$b — $p"
    else _dfail "$b ausente"; fi
  done

  echo; echo "Backends de agente:"
  for b in $ORCHESTRA_BACKENDS; do
    if backend_available "$b"; then _dok "$b disponível"
    else _dwarn "$b ausente — $(backend_url "$b")"; fi
  done

  echo; echo "Time deste projeto ($ORCHESTRA_PROJECT):"
  b="$(team_field leader backend)"
  if backend_available "$b"; then _dok "líder → $b"; else _dfail "líder → $b (não instalado)"; fi
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    b="$(team_field "$n" backend)"
    if backend_available "$b"; then _dok "$n → $b ($(team_field "$n" role))"
    else _dfail "$n → $b (não instalado)"; fi
  done < <(team_names)

  echo; echo "Sessão ativa:"
  if mux_available; then
    _dok "multiplexador $(mux_backend) no ar (sessão $(mux_session))"
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      if [ -n "$(mux_pane_id "$n" 2>/dev/null)" ]; then _dok "painel de $n aberto"
      else _dwarn "painel de $n ausente — 'orchestra heal' recria"; fi
    done < <(team_all_names)
  else
    _dwarn "nenhuma sessão ativa (sobe ao rodar 'orchestra')"
  fi

  echo; echo "Orchestra:"
  [ -d "$ORCHESTRA_HOME" ] && _dok "instalado em $ORCHESTRA_HOME" || _dfail "instalação não encontrada em $ORCHESTRA_HOME"
  p="$(command -v orchestra 2>/dev/null || true)"
  [ -n "$p" ] && _dok "CLI no PATH — $p" || _dwarn "comando 'orchestra' não está no PATH"

  echo
  if [ "$fail" -gt 0 ]; then
    printf '\033[1;31mResumo: %d falha(s) e %d aviso(s). Resolva as falhas acima.\033[0m\n' "$fail" "$warn"; return 1
  elif [ "$warn" -gt 0 ]; then
    printf '\033[1;33mResumo: o essencial está ok, com %d aviso(s).\033[0m\n' "$warn"; return 0
  else
    printf '\033[1;32mResumo: tudo certo! Pode rodar "orchestra". 🎼\033[0m\n'; return 0
  fi
}

# remove COMPLETAMENTE o Orchestra Agents (preserva zellij/claude/opencode/codex)
# Current operating system. The installer records its own in the manifest; if the
# user uninstalls on another machine/OS, we warn instead of running a 'brew
# uninstall' that does not exist there.
orchestra_os() {
  case "$(uname -s 2>/dev/null)" in
    Darwin) echo macos ;;
    Linux)  if grep -qi microsoft /proc/version 2>/dev/null; then echo wsl; else echo linux; fi ;;
    FreeBSD|OpenBSD|NetBSD) echo bsd ;;
    CYGWIN*|MINGW*|MSYS*) echo windows ;;
    *) echo desconhecido ;;
  esac
}

# Undoes what the installer recorded in installed.manifest. Each line is
# "<method><TAB><target>" and leaves by the method it came in with: 'brew uninstall' for
# what came from brew, 'cargo uninstall' for what came from cargo, 'rm' for a downloaded
# binary. The manifest is the ONLY source: what is not there was not installed by us
# and must not be removed — it is what protects the zellij of someone who already used zellij before.
_uninstall_manifest() {
  local mf="$ORCHESTRA_STATE/installed.manifest" method target zj
  local os_now os_inst="" removeu=0
  os_now="$(orchestra_os)"
  if [ -f "$mf" ]; then
    os_inst="$(awk -F'\t' '$1=="os"{print $2; exit}' "$mf" 2>/dev/null)"
    if [ -n "$os_inst" ] && [ "$os_inst" != "$os_now" ]; then
      echo "  ⚠️  instalado em '$os_inst', desinstalando em '$os_now' — o que não existir aqui é pulado"
    fi
    while IFS="$(printf '\t')" read -r method target || [ -n "$method" ]; do
      [ -n "${method:-}" ] && [ -n "${target:-}" ] || continue
      case "$method" in
        os) ;;
        file)
          [ -e "$target" ] && rm -f "$target" \
            && { echo "  removido $target (instalado pelo Orchestra)"; removeu=1; } ;;
        brew)
          if command -v brew >/dev/null 2>&1; then
            brew uninstall "$target" >/dev/null 2>&1 \
              && { echo "  removido $target via brew (instalado pelo Orchestra)"; removeu=1; } \
              || echo "  ⚠️  'brew uninstall $target' falhou — remova à mão se quiser"
          else
            echo "  ⚠️  $target veio do brew, que não existe nesta máquina — remova à mão"
          fi ;;
        cargo)
          if command -v cargo >/dev/null 2>&1; then
            cargo uninstall "$target" >/dev/null 2>&1 \
              && { echo "  removido $target via cargo (instalado pelo Orchestra)"; removeu=1; } \
              || echo "  ⚠️  'cargo uninstall $target' falhou — remova à mão se quiser"
          else
            echo "  ⚠️  $target veio do cargo, que não existe nesta máquina — remova à mão"
          fi ;;
      esac
    done <"$mf"
  fi
  # old marker (installs prior to the manifest), still honored
  zj="$(cat "$ORCHESTRA_STATE/zellij.ours" 2>/dev/null || true)"
  if [ -n "$zj" ] && [ -e "$zj" ]; then
    rm -f "$zj" && { echo "  removido $zj (tinha sido instalado pelo Orchestra)"; removeu=1; }
  fi
  # ~/.config/zellij is NOT ours: whoever writes there is the zellij in use and the
  # user themself (config.kdl, their layouts). We remove only the layout Orchestra generates
  # — done above — and warn about the rest, instead of deleting adjustments we did not make.
  if [ "$removeu" = 1 ] && [ -d "$HOME/.config/zellij" ] \
     && [ -n "$(ls -A "$HOME/.config/zellij" 2>/dev/null)" ]; then
    echo "  ⚠️  ~/.config/zellij ficou (é sua configuração do zellij, não do Orchestra)"
  fi
  if [ "$removeu" = 0 ] && command -v zellij >/dev/null 2>&1; then
    echo "  zellij preservado (já existia antes do Orchestra)"
  fi
  return 0
}

uninstall() {
  echo "🧹 Desinstalando Orchestra Agents..."
  echo "   sistema: $(orchestra_os)"
  kill_all_sessions
  # 1) CLI symlink(s) on the PATH (+ the location recorded at install)
  local d tgt bindir rc tmp IFSorig
  bindir="$(cat "$ORCHESTRA_STATE/bindir" 2>/dev/null || true)"
  [ -n "$bindir" ] && [ -L "$bindir/orchestra" ] && rm -f "$bindir/orchestra" && echo "  removido $bindir/orchestra"
  IFSorig="$IFS"; IFS=:
  for d in $PATH; do
    if [ -L "$d/orchestra" ]; then
      tgt="$(readlink "$d/orchestra" 2>/dev/null || true)"
      case "$tgt" in *orchestra-agents/bin/orchestra) rm -f "$d/orchestra" && echo "  removido $d/orchestra";; esac
    fi
  done
  IFS="$IFSorig"
  # 2) PATH lines in the rc files + fish
  for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
    { [ -f "$rc" ] && grep -q 'orchestra-agents (PATH)' "$rc" 2>/dev/null; } || continue
    tmp="$(mktemp)"
    awk '/# orchestra-agents \(PATH\)/{skip=2} skip>0{skip--; next} {print}' "$rc" >"$tmp" \
      && mv "$tmp" "$rc" && echo "  PATH removido de $rc"
  done
  rm -f "$HOME/.config/fish/conf.d/orchestra.fish"
  # 3) everything the INSTALLER put on the machine, each item by the method it came in with
  _uninstall_manifest

  # 4) zellij layout
  rm -f "$HOME/.config/zellij/layouts/orchestra.kdl"
  # 5) the agent Orchestra put in the OpenCode config
  remove_reviewer_agent
  # 6) leftovers from the versions where the team lived inside the project. We know where the
  #    projects are because each one leaves 'project.path' in its state directory
  #    — it is what avoids abandoning an orphan .orchestra/ on the user's machine.
  local pp proj
  for pp in "$ORCHESTRA_STATE"/projects/*/project.path; do
    [ -f "$pp" ] || continue
    proj="$(cat "$pp" 2>/dev/null)"
    [ -n "$proj" ] && [ -d "$proj/.orchestra" ] \
      && rm -rf "$proj/.orchestra" && echo "  removido $proj/.orchestra (resíduo de versão antiga)"
  done
  # 7) config, state and install directories
  rm -rf "$HOME/.config/orchestra-agents" "$ORCHESTRA_STATE" "$ORCHESTRA_HOME"
  echo "✅ Orchestra Agents removido por completo."
  echo
  echo "   Removido junto: os times e prompts de TODOS os seus projetos — eles ficavam"
  echo "   em $ORCHESTRA_STATE/projects/, fora dos projetos, e não sobrou nada na"
  echo "   pasta de nenhum deles."
  echo
  echo "   Preservado de propósito:"
  echo "     · Claude Code, OpenCode e Codex (ferramentas suas, não do Orchestra)"
  # the shell caches the removed command's path; without this, an 'orchestra'
  # right after fails with a confusing message instead of 'command not found'.
  echo
  echo "   Se for reinstalar nesta mesma janela, limpe o cache de comandos antes:"
  echo "     hash -r    (bash)     ·     rehash    (zsh)"
}
