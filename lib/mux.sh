#!/usr/bin/env bash
# Orchestra Agents — camada de abstração do multiplexador de terminal.
#
# TODO acesso ao zellij passa por aqui. É o que permite trocar o substrato
# (zellij ↔ tmux) mexendo em UM arquivo, e é o que o smoke test substitui pelo
# backend 'stub' para rodar em CI sem multiplexador.
#
# Contrato (implementar tudo isto ao portar para outro multiplexador):
#   mux_backend                   → nome do backend ativo
#   mux_available                 → 0 se o multiplexador está utilizável
#   mux_session                   → nome da sessão do multiplexador
#   mux_pane_id <agente>          → ecoa o pane-id do agente ("" se não existe)
#   mux_pane_alive <pane>         → 0 se o pane existe
#   mux_send_text <pane> <texto>  → injeta texto (multilinha, sem submeter)
#   mux_enter <pane>              → submete (Enter)
#   mux_capture <pane>            → ecoa o conteúdo visível+scrollback do pane
#   mux_new_pane <agente> [dir]   → cria o painel do agente e ecoa o pane-id
#   mux_kill_pane <pane>          → fecha o pane
#
# Não executar diretamente; é "sourced" pelo lib/core.sh.

# backend: zellij (padrão) | stub (testes)
ORCHESTRA_MUX="${ORCHESTRA_MUX:-zellij}"

mux_backend() { echo "$ORCHESTRA_MUX"; }

# ---------------------------------------------------------------------------
# helpers comuns
# ---------------------------------------------------------------------------

# diretório de runtime dos agentes (definido por core.sh; fallback defensivo)
_mux_run_dir() {
  if [ -n "${ORCHESTRA_RUN_DIR:-}" ]; then echo "$ORCHESTRA_RUN_DIR"; return; fi
  local p; p="$(cat "$ORCHESTRA_STATE/project" 2>/dev/null)"; [ -n "$p" ] || p="$PWD"
  echo "$p/.orchestra/run"
}

_mux_pane_file() { echo "$(_mux_run_dir)/${1}.pane"; }

# comando que identifica o painel de um agente (usado para re-resolver o pane-id).
# Casamos pelo COMANDO e não pelo título: as TUIs (opencode/claude/codex) trocam o
# título do terminal via OSC, então o título não é estável — o comando é.
_mux_agent_cmd_marker() { echo "run-agent.sh $1"; }

# ---------------------------------------------------------------------------
# backend: zellij
# ---------------------------------------------------------------------------

# nome da sessão zellij: preferimos a do ambiente (estamos dentro de um painel),
# senão a registrada ao subir o time.
_zj_session() {
  if [ -n "${ZELLIJ_SESSION_NAME:-}" ]; then echo "$ZELLIJ_SESSION_NAME"; return 0; fi
  local s; s="$(cat "$ORCHESTRA_STATE/mux.session" 2>/dev/null)"
  [ -n "$s" ] || return 1
  echo "$s"
}

# wrapper de 'zellij action' já mirando a sessão certa
_zj() {
  local s; s="$(_zj_session)" || { echo "❌ sessão do zellij desconhecida (rode 'orchestra')" >&2; return 1; }
  zellij -s "$s" action "$@"
}

# JSON dos painéis não-plugin da sessão
_zj_panes_json() { _zj list-panes -a -j 2>/dev/null; }

_zj_available() {
  command -v zellij >/dev/null 2>&1 || return 1
  _zj_session >/dev/null 2>&1 || return 1
  _zj list-panes -j >/dev/null 2>&1
}

# procura o pane-id de um agente varrendo os painéis pelo comando em execução
_zj_find_pane() { # $1 agente
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

# aba (tab_id) onde vive um painel — usada para ancorar painéis novos na MESMA tela
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

# painel em foco numa aba (para devolver o foco depois de dividir)
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

# maior painel da aba, EXCLUINDO o do líder — é ele que será dividido para abrir
# espaço ao agente novo, para o painel do líder não encolher a cada 'add'.
_zj_biggest_other_pane() { # $1 tab_id  $2 pane-id a excluir
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
    # painel largo divide na horizontal (novo embaixo); painel alto divide na vertical
    print('terminal_%s %s' % (best[1], 'down' if best[2] >= best[3] * 2 else 'right'))
" "$1" "$2" 2>/dev/null
}

# Move o foco até um painel alvo, CICLANDO com 'focus-next-pane'.
# 'focus-pane-id' NÃO funciona quando chamado de fora da sessão (zellij 0.44.3):
# retorna 0 e não move o foco. 'focus-next-pane' funciona — verificado.
_zj_focus_pane() { # $1 tab_id  $2 pane-id alvo
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
# API pública
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

# ecoa o pane-id do agente, revalidando o valor salvo. Se o painel sumiu (usuário
# fechou, matou o supervisor), o cache é descartado e tentamos localizar de novo
# pelo comando — é isto que sobrevive a mover painel, trocar de aba e reiniciar.
mux_pane_id() { # $1 agente
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

mux_send_text() { # $1 pane-id  $2 texto (pode ser multilinha)
  case "$ORCHESTRA_MUX" in
    stub)
      mkdir -p "$(_mux_run_dir)"
      printf '%s' "$2" >>"$(_mux_run_dir)/${1#stub_}.tx" ;;
    zellij)
      # 'paste' usa bracketed paste: a TUI recebe o bloco inteiro como colagem,
      # sem interpretar os \n como submissão. Validado no zellij 0.44.3.
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

mux_capture() { # $1 pane-id  → conteúdo do painel (viewport + scrollback)
  case "$ORCHESTRA_MUX" in
    stub)   cat "$(_mux_run_dir)/${1#stub_}.tx" 2>/dev/null ;;
    zellij) _zj dump-screen -p "$1" --full 2>/dev/null ;;
  esac
}

# cria o painel de um agente e ecoa o pane-id. Usado pelo 'add' e pela auto-cura.
mux_new_pane() { # $1 agente  [$2 dir]
  local agent="$1" dir="${2:-}" id
  case "$ORCHESTRA_MUX" in
    stub) mkdir -p "$(_mux_run_dir)"
          printf 'stub_%s' "$agent" >"$(_mux_pane_file "$agent")"; printf 'stub_%s' "$agent"; return 0 ;;
  esac
  # mesmo rótulo do layout gerado — um agente criado na hora não pode destoar
  local label; label="$(pane_label "$agent" 2>/dev/null)"; [ -n "$label" ] || label="$agent"
  local args=(new-pane -n "$label")
  # O painel do time SEMPRE nasce na mesma tela dos outros:
  #  - '--tab-id' da aba do líder: sem isto o zellij usa a aba em FOCO, e o agente
  #    apareceria numa aba diferente (fora da vista) se o usuário tivesse trocado.
  #  - NUNCA '-f/--floating': painel flutuante cobre os outros em vez de dividir a tela.
  #  - sem '-d/--direction': o zellij escolhe o maior espaço livre, o que evita
  #    espremer o painel de quem estiver em foco (tipicamente o líder).
  local anchor tab=""
  if [ "$agent" != leader ]; then
    anchor="$(mux_pane_id leader 2>/dev/null)"
    [ -n "$anchor" ] && tab="$(_zj_tab_of "$anchor")"
  fi
  [ -n "$tab" ] && args+=(--tab-id "$tab")
  # Sem direção o zellij divide o MAIOR painel — que costuma ser o do líder, que
  # então encolhe a cada agente novo. Focamos o maior painel de worker e dividimos
  # ELE, devolvendo o foco em seguida.
  local prev="" split="" target="" sdir=""
  if [ -n "$tab" ] && [ -n "$anchor" ]; then
    split="$(_zj_biggest_other_pane "$tab" "$anchor")"
    target="${split%% *}"; sdir="${split##* }"
    if [ -n "$target" ] && [ "$target" != "$sdir" ]; then
      prev="$(_zj_focused_pane "$tab")"
      if [ "$prev" = "$target" ] || _zj_focus_pane "$tab" "$target"; then
        args+=(-d "$sdir")
      else
        prev=""   # não conseguiu mirar: deixa o zellij escolher o espaço
      fi
    fi
  fi
  [ -n "$dir" ] && args+=(--cwd "$dir")
  args+=(-- bash -lc "exec '$ORCHESTRA_HOME/agents/run-agent.sh' '$agent'")
  id="$(_zj "${args[@]}" 2>/dev/null | tr -d '[:space:]')"
  # devolve o foco para onde estava (o painel novo nasce focado)
  [ -n "$prev" ] && [ -n "$tab" ] && _zj_focus_pane "$tab" "$prev" >/dev/null 2>&1
  [ -n "$id" ] || return 1
  mkdir -p "$(_mux_run_dir)"; printf '%s' "$id" >"$(_mux_pane_file "$agent")"
  echo "$id"
}

mux_kill_pane() { # $1 pane-id
  case "$ORCHESTRA_MUX" in
    stub)   return 0 ;;
    zellij)
      # 'close-pane -p <id>' fecha o painel ALVO sem mexer no foco. NÃO usar
      # 'focus-pane-id + close-pane': se o focus falhar, fecha o painel em foco —
      # que pode ser o do líder. Ao fechar, o zellij redistribui o espaço entre os
      # painéis restantes sozinho.
      _zj close-pane -p "$1" >/dev/null 2>&1 ;;
  esac
}

# registra a sessão do multiplexador (chamado no 'up' e pelo run-agent.sh)
mux_remember_session() {
  [ "$ORCHESTRA_MUX" = zellij ] || return 0
  [ -n "${ZELLIJ_SESSION_NAME:-}" ] || return 0
  mkdir -p "$ORCHESTRA_STATE"
  printf '%s' "$ZELLIJ_SESSION_NAME" >"$ORCHESTRA_STATE/mux.session"
}
