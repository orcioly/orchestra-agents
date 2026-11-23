#!/usr/bin/env bash
# Orchestra Agents — terminal multiplexer abstraction layer.
#
# ALL access to zellij goes through here. It is what allows swapping the substrate
# (zellij ↔ tmux) by touching ONE file, and it is what the smoke test replaces with the
# 'stub' backend to run in CI without a multiplexer.
#
# Contract (implement all of this when porting to another multiplexer):
#   mux_backend                   → name of the active backend
#   mux_available                 → 0 if the multiplexer is usable
#   mux_session                   → name of the multiplexer session
#   mux_session_name <project>    → stable session name that FITS this mux
#   mux_pane_id <agent>           → echoes the agent's pane-id ("" if it does not exist)
#   mux_pane_alive <pane>         → 0 if the pane exists
#   mux_send_text <pane> <text>   → injects text (multiline, without submitting)
#   mux_enter <pane>              → submits (Enter)
#   mux_capture <pane>            → echoes the pane's visible content + scrollback
#   mux_new_pane <agent> [dir]    → creates the agent's pane and echoes the pane-id
#   mux_kill_pane <pane>          → closes the pane
#
# Do not execute directly; it is sourced by lib/core.sh.

# backend: zellij (default) | stub (tests)
ORCHESTRA_MUX="${ORCHESTRA_MUX:-zellij}"

mux_backend() { echo "$ORCHESTRA_MUX"; }

# ---------------------------------------------------------------------------
# common helpers
# ---------------------------------------------------------------------------

# agents' runtime directory (defined by core.sh; defensive fallback).
# It lives OUTSIDE the project: $ORCHESTRA_STATE/projects/<slug>/run — the root of the
# user's project receives no Orchestra file.
_mux_run_dir() {
  if [ -n "${ORCHESTRA_RUN_DIR:-}" ]; then echo "$ORCHESTRA_RUN_DIR"; return; fi
  local p slug hash
  p="$(cat "$ORCHESTRA_STATE/project" 2>/dev/null)"; [ -n "$p" ] || p="$PWD"
  slug="$(printf '%s' "$(basename "$p")" | tr -c 'a-zA-Z0-9_-' '-')"
  while [ -n "$slug" ] && [ "${slug%-}" != "$slug" ]; do slug="${slug%-}"; done
  hash="$(printf '%s' "$p" | cksum | cut -d' ' -f1)"
  echo "$ORCHESTRA_STATE/projects/${slug:-projeto}-${hash}/run"
}

_mux_pane_file() { echo "$(_mux_run_dir)/${1}.pane"; }

# command that identifies an agent's pane (used to re-resolve the pane-id).
# We match by COMMAND and not by title: the TUIs (opencode/claude/codex) change the
# terminal title via OSC, so the title is not stable — the command is.
_mux_agent_cmd_marker() { echo "run-agent.sh $1"; }

# A shortened name candidate. Cutting the slug at a fixed size can leave it
# ending in a hyphen ('meu-projeto' cut at 4 becomes 'meu-'), which would produce
# 'orchestra-meu--123': we trim the hyphen, and if no slug is left the name keeps only the
# checksum.
_mux_session_cand() { # $1 cut slug  $2 short hash
  local v="$1"
  while [ -n "$v" ] && [ "${v%-}" != "$v" ]; do v="${v%-}"; done
  if [ -n "$v" ]; then printf '%s\n' "orchestra-${v}-${2}"
  else                 printf '%s\n' "orchestra-${2}"; fi
}

# Candidate session names for a project, from the most readable to the shortest, one per
# line. It is PURE (does not touch the multiplexer) — the smoke test exercises this function
# directly, without zellij.
#
# Shortening exists because the name length is NOT free: zellij derives it from what
# is left in 'sockaddr_un.sun_path' (104 bytes on macOS, 108 on Linux) after the
# socket directory, which lives under $TMPDIR. On Linux $TMPDIR is /tmp and the whole name
# fits; on macOS it is /var/folders/<...>/T/ (49 chars) and 24 are left.
#
# The 'orchestra-' prefix goes in ALL candidates: 'kill_all_sessions' (lib/core.sh)
# finds the team's sessions with grep '^orchestra-'. Do NOT remove the prefix when shortening.
_mux_session_candidates() { # $1 project
  local proj="${1:-$PWD}" slug hash short
  # printf (and not piping basename directly): 'tr -c' would convert the trailing \n into '-',
  # leaving the name with a double hyphen before the checksum.
  slug="$(printf '%s' "$(basename "$proj")" | tr -c 'a-zA-Z0-9_-' '-')"
  hash="$(printf '%s' "$proj" | cksum | cut -d' ' -f1)"
  # A project that already starts with 'orchestra-' does not repeat the word in the short name:
  # 'orchestra-agents' would become 'orchestra-orchestr-60767', which besides being ugly loses
  # precisely the part that identifies the project. It becomes 'orchestra-agents-60767'.
  short="${slug#orchestra-}"
  # The 1st is the historical format: as long as it fits (Linux), the name does not change.
  printf '%s\n' "orchestra-${slug}-${hash}"
  _mux_session_cand "${short:0:8}" "${hash: -5}"
  _mux_session_cand "${short:0:4}" "${hash: -5}"
  printf '%s\n' "orchestra-${hash: -5}"
}

# ---------------------------------------------------------------------------
# backend: zellij
# ---------------------------------------------------------------------------

# zellij session name: we prefer the one from the environment (we are inside a pane),
# otherwise the one registered when the team came up.
_zj_session() {
  if [ -n "${ZELLIJ_SESSION_NAME:-}" ]; then echo "$ZELLIJ_SESSION_NAME"; return 0; fi
  local s; s="$(cat "$ORCHESTRA_STATE/mux.session" 2>/dev/null)"
  [ -n "$s" ] || return 1
  echo "$s"
}

# Does zellij accept this session name? Cheap probe (~25ms, measured): 'list-panes'
# on a nonexistent session answers "There is no active session!", whereas a name that is
# too long does not even reach the server — the parser refuses with "error: invalid value".
# Any other failure counts as "fits": that is today's behavior, and zellij's real error
# shows up when starting, instead of the name being shortened for nothing.
#
# The output is captured in a variable instead of going through 'grep': 'up' runs under
# 'set -o pipefail', and in a pipe zellij's exit (2, when it refuses the name) WINS over that of the
# grep that just matched — the test answered "fits" precisely for the name that is too big,
# which is the case it exists to catch. Do NOT reintroduce the pipe here.
_zj_session_name_fits() { # $1 name
  local out
  out="$(zellij -s "$1" action list-panes -j 2>&1)"
  case "$out" in *'invalid value'*) return 1 ;; esac
  return 0
}

# wrapper for 'zellij action' already targeting the right session
_zj() {
  local s; s="$(_zj_session)" || { echo "❌ sessão do zellij desconhecida (rode 'orchestra')" >&2; return 1; }
  zellij -s "$s" action "$@"
}

# JSON of the session's non-plugin panes
_zj_panes_json() { _zj list-panes -a -j 2>/dev/null; }

_zj_available() {
  command -v zellij >/dev/null 2>&1 || return 1
  _zj_session >/dev/null 2>&1 || return 1
  _zj list-panes -j >/dev/null 2>&1
}

# finds an agent's pane-id by scanning the panes for the running command
_zj_find_pane() { # $1 agent
  local marker; marker="$(_mux_agent_cmd_marker "$1")"
  _zj_panes_json | python3 -c "
import sys, json, re
marker = sys.argv[1]
try:
    panes = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
pat = re.compile(r'run-agent\.sh\s+' + re.escape(marker.split()[-1]) + r'(\s|\$)')
for p in panes:
    if p.get('is_plugin'):
        continue
    cmd = p.get('terminal_command') or ''
    if pat.search(cmd + ' '):
        print('terminal_%s' % p['id'])
        break
" "$marker" 2>/dev/null
}

# tab (tab_id) where a pane lives — used to anchor new panes on the SAME screen
_zj_tab_of() { # $1 pane-id
  local want="${1#terminal_}"
  _zj_panes_json | python3 -c "
import sys, json
want = sys.argv[1]
try:
    panes = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
for p in panes:
    if not p.get('is_plugin') and str(p.get('id')) == want:
        t = p.get('tab_id')
        if t is not None:
            print(t)
        break
" "$want" 2>/dev/null
}

# focused pane in a tab (to give focus back after splitting)
_zj_focused_pane() { # $1 tab_id
  _zj_panes_json | python3 -c "
import sys, json
tab = int(sys.argv[1])
try:
    panes = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
for p in panes:
    if not p.get('is_plugin') and p.get('tab_id') == tab and p.get('is_focused'):
        print('terminal_%s' % p['id']); break
" "$1" 2>/dev/null
}

# biggest pane of the tab, EXCLUDING the leader's — it is the one that will be split to open
# room for the new agent, so the leader's pane does not shrink on every 'add'.
_zj_biggest_other_pane() { # $1 tab_id  $2 pane-id to exclude
  _zj_panes_json | python3 -c "
import sys, json
tab, skip = int(sys.argv[1]), sys.argv[2].replace('terminal_', '')
try:
    panes = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
best = None
for p in panes:
    if p.get('is_plugin') or p.get('tab_id') != tab or p.get('is_floating'):
        continue
    if str(p.get('id')) == skip:
        continue
    area = (p.get('pane_columns') or 0) * (p.get('pane_rows') or 0)
    if best is None or area > best[0]:
        best = (area, p['id'], p.get('pane_columns') or 0, p.get('pane_rows') or 0)
if best:
    # a wide pane splits horizontally (new one below); a tall pane splits vertically
    print('terminal_%s %s' % (best[1], 'down' if best[2] >= best[3] * 2 else 'right'))
" "$1" "$2" 2>/dev/null
}

# Moves focus to a target pane, CYCLING with 'focus-next-pane'.
# 'focus-pane-id' does NOT work when called from outside the session (zellij 0.44.3):
# it returns 0 and does not move focus. 'focus-next-pane' works — verified.
_zj_focus_pane() { # $1 tab_id  $2 target pane-id
  local i cur
  for i in $(seq 1 12); do
    cur="$(_zj_focused_pane "$1")"
    [ -n "$cur" ] || return 1
    [ "$cur" = "$2" ] && return 0
    _zj focus-next-pane >/dev/null 2>&1 || return 1
  done
  return 1
}

_zj_pane_alive() { # $1 pane-id
  local want="${1#terminal_}"
  _zj_panes_json | python3 -c "
import sys, json
want = sys.argv[1]
try:
    panes = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
for p in panes:
    if not p.get('is_plugin') and str(p.get('id')) == want and not p.get('exited'):
        raise SystemExit(0)
raise SystemExit(1)
" "$want" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

mux_available() {
  case "$ORCHESTRA_MUX" in
    stub)   return 0 ;;
    zellij) _zj_available ;;
    *)      return 1 ;;
  esac
}

mux_session() {
  case "$ORCHESTRA_MUX" in
    stub)   echo "stub" ;;
    zellij) _zj_session ;;
  esac
}

# Stable session name per project, already guaranteed to fit this multiplexer. Tries the
# candidates from the most readable to the shortest and returns the first accepted — on Linux the
# first one passes and the name is exactly the usual one.
mux_session_name() { # $1 project
  local proj="${1:-$PWD}" cand last=""
  case "$ORCHESTRA_MUX" in
    stub) echo "stub"; return 0 ;;
  esac
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    last="$cand"
    if _zj_session_name_fits "$cand"; then echo "$cand"; return 0; fi
  done < <(_mux_session_candidates "$proj")
  # None fit: returns the shortest and explains, instead of dying with zellij's raw
  # error ("session name must be less than 0 characters", which says nothing).
  echo "⚠️  o zellij recusou até o nome curto de sessão: o socket sob" >&2
  echo "   \$TMPDIR (${TMPDIR:-/tmp}) não deixa espaço. Tente 'TMPDIR=/tmp orchestra'." >&2
  echo "$last"
}

# echoes the agent's pane-id, revalidating the saved value. If the pane is gone (user
# closed it, killed the supervisor), the cache is discarded and we try to locate it again
# by command — this is what survives moving a pane, switching tabs and restarting.
mux_pane_id() { # $1 agent
  local agent="$1" f cached found
  f="$(_mux_pane_file "$agent")"
  case "$ORCHESTRA_MUX" in
    stub)
      mkdir -p "$(_mux_run_dir)"
      printf 'stub_%s' "$agent" >"$f"; printf 'stub_%s' "$agent"; return 0 ;;
  esac
  [ -s "$f" ] && cached="$(cat "$f")"
  if [ -n "${cached:-}" ] && _zj_pane_alive "$cached"; then echo "$cached"; return 0; fi
  found="$(_zj_find_pane "$agent")"
  if [ -n "$found" ]; then
    mkdir -p "$(_mux_run_dir)"; printf '%s' "$found" >"$f"; echo "$found"; return 0
  fi
  rm -f "$f" 2>/dev/null || true
  return 1
}

mux_pane_alive() { # $1 pane-id
  case "$ORCHESTRA_MUX" in
    stub)   [ -n "$1" ] ;;
    zellij) _zj_pane_alive "$1" ;;
  esac
}

mux_send_text() { # $1 pane-id  $2 text (may be multiline)
  case "$ORCHESTRA_MUX" in
    stub)
      mkdir -p "$(_mux_run_dir)"
      printf '%s' "$2" >>"$(_mux_run_dir)/${1#stub_}.tx" ;;
    zellij)
      # 'paste' uses bracketed paste: the TUI receives the whole block as a paste,
      # without interpreting the \n as submission. Validated on zellij 0.44.3.
      _zj paste -p "$1" "$2" ;;
  esac
}

mux_enter() { # $1 pane-id
  case "$ORCHESTRA_MUX" in
    stub)
      mkdir -p "$(_mux_run_dir)"
      printf '\n' >>"$(_mux_run_dir)/${1#stub_}.tx" ;;
    zellij) _zj write -p "$1" 13 ;;
  esac
}

mux_capture() { # $1 pane-id  → pane content (viewport + scrollback)
  case "$ORCHESTRA_MUX" in
    stub)   cat "$(_mux_run_dir)/${1#stub_}.tx" 2>/dev/null ;;
    zellij) _zj dump-screen -p "$1" --full 2>/dev/null ;;
  esac
}

# creates an agent's pane and echoes the pane-id. Used by 'add' and by self-healing.
mux_new_pane() { # $1 agent  [$2 dir]
  local agent="$1" dir="${2:-}" id
  case "$ORCHESTRA_MUX" in
    stub) mkdir -p "$(_mux_run_dir)"
          printf 'stub_%s' "$agent" >"$(_mux_pane_file "$agent")"; printf 'stub_%s' "$agent"; return 0 ;;
  esac
  # same label as the generated layout — an agent created on the spot must not clash
  local label; label="$(pane_label "$agent" 2>/dev/null)"; [ -n "$label" ] || label="$agent"
  local args=(new-pane -n "$label")
  # A team pane ALWAYS comes up on the same screen as the others:
  #  - '--tab-id' of the leader's tab: without it zellij uses the FOCUSED tab, and the agent
  #    would appear in a different tab (out of view) if the user had switched.
  #  - NEVER '-f/--floating': a floating pane covers the others instead of splitting the screen.
  #  - without '-d/--direction': zellij picks the biggest free space, which avoids
  #    squeezing the pane of whoever is focused (typically the leader).
  local anchor tab=""
  if [ "$agent" != leader ]; then
    anchor="$(mux_pane_id leader 2>/dev/null)"
    [ -n "$anchor" ] && tab="$(_zj_tab_of "$anchor")"
  fi
  [ -n "$tab" ] && args+=(--tab-id "$tab")
  # Without a direction zellij splits the BIGGEST pane — which tends to be the leader's, which
  # then shrinks with every new agent. We focus the biggest worker pane and split
  # IT, giving focus back afterwards.
  local prev="" split="" target="" sdir=""
  if [ -n "$tab" ] && [ -n "$anchor" ]; then
    split="$(_zj_biggest_other_pane "$tab" "$anchor")"
    target="${split%% *}"; sdir="${split##* }"
    if [ -n "$target" ] && [ "$target" != "$sdir" ]; then
      prev="$(_zj_focused_pane "$tab")"
      if [ "$prev" = "$target" ] || _zj_focus_pane "$tab" "$target"; then
        args+=(-d "$sdir")
      else
        prev=""   # could not target: let zellij pick the space
      fi
    fi
  fi
  [ -n "$dir" ] && args+=(--cwd "$dir")
  args+=(-- bash -lc "exec '$ORCHESTRA_HOME/agents/run-agent.sh' '$agent'")
  id="$(_zj "${args[@]}" 2>/dev/null | tr -d '[:space:]')"
  # gives focus back to where it was (the new pane comes up focused)
  [ -n "$prev" ] && [ -n "$tab" ] && _zj_focus_pane "$tab" "$prev" >/dev/null 2>&1
  [ -n "$id" ] || return 1
  mkdir -p "$(_mux_run_dir)"; printf '%s' "$id" >"$(_mux_pane_file "$agent")"
  echo "$id"
}

mux_kill_pane() { # $1 pane-id
  case "$ORCHESTRA_MUX" in
    stub)   return 0 ;;
    zellij)
      # 'close-pane -p <id>' closes the TARGET pane without touching focus. Do NOT use
      # 'focus-pane-id + close-pane': if the focus fails, it closes the focused pane —
      # which may be the leader's. On closing, zellij redistributes the space among the
      # remaining panes on its own.
      _zj close-pane -p "$1" >/dev/null 2>&1 ;;
  esac
}

# registers the multiplexer session (called in 'up' and by run-agent.sh)
mux_remember_session() {
  [ "$ORCHESTRA_MUX" = zellij ] || return 0
  [ -n "${ZELLIJ_SESSION_NAME:-}" ] || return 0
  mkdir -p "$ORCHESTRA_STATE"
  printf '%s' "$ZELLIJ_SESSION_NAME" >"$ORCHESTRA_STATE/mux.session"
}
