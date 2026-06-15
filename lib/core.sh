#!/usr/bin/env bash
# Orchestra Agents — núcleo compartilhado (servidor OpenCode, sessões, despacho async)
# Não executar diretamente; é "sourced" pelo CLI e pelos scripts de painel.

# ----- Configuração (sobrescrevível por env ou ~/.config/orchestra-agents/config) -----
ORCHESTRA_HOME="${ORCHESTRA_HOME:-$HOME/.orchestra-agents}"
ORCHESTRA_STATE="${ORCHESTRA_STATE:-$HOME/.local/state/orchestra-agents}"
ORCHESTRA_PORT="${ORCHESTRA_PORT:-4096}"
ORCHESTRA_HOST="${ORCHESTRA_HOST:-127.0.0.1}"
# modelo no formato provider/model (precisa estar configurado/autenticado no OpenCode)
ORCHESTRA_MODEL="${ORCHESTRA_MODEL:-deepseek/deepseek-v4-pro}"
ORCHESTRA_CODER_AGENT="${ORCHESTRA_CODER_AGENT:-build}"
ORCHESTRA_REVIEWER_AGENT="${ORCHESTRA_REVIEWER_AGENT:-reviewer}"

# carrega config do usuário, se existir
[ -f "$HOME/.config/orchestra-agents/config" ] && . "$HOME/.config/orchestra-agents/config"

OC_URL="http://${ORCHESTRA_HOST}:${ORCHESTRA_PORT}"
mkdir -p "$ORCHESTRA_STATE"

_model_provider() { echo "${ORCHESTRA_MODEL%%/*}"; }
_model_id()       { echo "${ORCHESTRA_MODEL#*/}"; }

# localiza o binário do opencode
_resolve_opencode() {
  if command -v opencode >/dev/null 2>&1; then command -v opencode; return; fi
  [ -x "$HOME/.opencode/bin/opencode" ] && { echo "$HOME/.opencode/bin/opencode"; return; }
  echo opencode
}
OPENCODE="$(_resolve_opencode)"

oc_up() { curl -s --max-time 2 "$OC_URL/api/session" >/dev/null 2>&1; }

ensure_server() {
  oc_up && return 0
  setsid "$OPENCODE" serve --port "$ORCHESTRA_PORT" --hostname "$ORCHESTRA_HOST" \
    >"$ORCHESTRA_STATE/server.log" 2>&1 </dev/null &
  for _ in $(seq 1 30); do oc_up && return 0; sleep 1; done
  return 1
}

_create_session() { # $1 agent  $2 title  -> ses id
  # fixa o diretório do projeto na sessão (se definido), p/ o worker operar no repo certo
  local proj loc=""
  proj="$(cat "$ORCHESTRA_STATE/project" 2>/dev/null)"
  [ -n "$proj" ] && loc=",\"location\":{\"directory\":\"$proj\"}"
  curl -s -X POST "$OC_URL/api/session" -H 'Content-Type: application/json' \
    -d "{\"agent\":\"$1\",\"title\":\"$2\"$loc}" \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['id'])"
}

_session_exists() { curl -s "$OC_URL/api/session" 2>/dev/null | grep -q "$1"; }

_session_msgcount() { # $1 sid
  curl -s "$OC_URL/session/$1/message" 2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin); d=d if isinstance(d,list) else d.get('data',[])
    print(len(d))
except Exception:
    print(0)"
}

# garante a sessão de um papel. 4º arg 'fresh' força sessão NOVA e vazia
# (sessão vazia faz a TUI do OpenCode abrir na home com o LOGO).
ensure_session() { # $1 role  $2 agent  $3 title  [fresh]
  local role="$1" agent="$2" title="$3" fresh="${4:-}"
  local f="$ORCHESTRA_STATE/$role.session" sid=""
  [ -s "$f" ] && sid="$(cat "$f")"
  if [ -n "$fresh" ] || [ -z "$sid" ] || ! _session_exists "$sid"; then
    sid="$(_create_session "$agent" "$title")"
    printf '%s' "$sid" >"$f"
  fi
  echo "$sid"
}

# despacho ASSÍNCRONO (não-bloqueante): retorna na hora, o worker roda em background.
# É o que evita o líder gastar token "esperando".
dispatch() { # $1 role  $2.. texto
  local role="$1"; shift; local text="$*"
  local agent f sid
  case "$role" in
    coder)    agent="$ORCHESTRA_CODER_AGENT" ;;
    reviewer) agent="$ORCHESTRA_REVIEWER_AGENT" ;;
    *) echo "papel inválido: '$role' (use coder|reviewer)"; return 1 ;;
  esac
  f="$ORCHESTRA_STATE/$role.session"
  [ -s "$f" ] || { echo "❌ sessão de '$role' não existe — rode 'orchestra up' primeiro"; return 1; }
  sid="$(cat "$f")"
  python3 - "$OC_URL" "$sid" "$text" "$agent" "$(_model_provider)" "$(_model_id)" <<'PY'
import sys, json, urllib.request, urllib.error
url, sid, text, agent, prov, model = sys.argv[1:7]
body = json.dumps({
    "agent": agent,
    "model": {"providerID": prov, "modelID": model},
    "parts": [{"type": "text", "text": text}],
}).encode()
req = urllib.request.Request(f"{url}/session/{sid}/prompt_async", data=body,
                            headers={"Content-Type": "application/json"}, method="POST")
try:
    urllib.request.urlopen(req, timeout=15)
    print(f"📨 enviado ao {agent} (sessão {sid}) — rodando na TUI, sem bloquear o líder")
except urllib.error.HTTPError as e:
    print("❌", e.code, e.read().decode()[:200]); sys.exit(1)
except Exception as e:
    print("❌", e); sys.exit(1)
PY
}

# última resposta do worker (sob demanda — não fica em loop gastando token)
result() { # $1 role
  local role="${1:-}" f sid
  [ -n "$role" ] || { echo "uso: orchestra result coder|reviewer"; return 1; }
  f="$ORCHESTRA_STATE/$role.session"
  [ -s "$f" ] || { echo "sessão de '$role' não existe"; return 1; }
  sid="$(cat "$f")"
  curl -s "$OC_URL/session/$sid/message" | python3 -c "
import sys, json
d = json.load(sys.stdin); d = d if isinstance(d, list) else d.get('data', [])
asst = [m for m in d if (m.get('info', {}) or {}).get('role') == 'assistant']
if not asst:
    print('(sem resposta ainda — o worker pode estar processando)'); raise SystemExit
m = asst[-1]
txt = ' '.join(p.get('text', '') for p in m.get('parts', []) if p.get('type') == 'text').strip()
print(txt or '(processando ou resposta sem texto)')"
}

status() {
  if oc_up; then echo "🟢 servidor: no ar ($OC_URL)"; else echo "🔴 servidor: parado (rode 'orchestra up')"; return; fi
  echo "   modelo: $ORCHESTRA_MODEL"
  local proj; proj="$(cat "$ORCHESTRA_STATE/project" 2>/dev/null)"
  [ -n "$proj" ] && echo "   projeto: $proj"
  local role f sid
  for role in coder reviewer; do
    f="$ORCHESTRA_STATE/$role.session"
    if [ -s "$f" ]; then sid="$(cat "$f")"; echo "   $role → $sid ($(_session_msgcount "$sid") msgs)"
    else echo "   $role → (sem sessão)"; fi
  done
}

teardown() {
  if pkill -f "opencode serve --port $ORCHESTRA_PORT" 2>/dev/null; then echo "🛑 servidor encerrado"
  else echo "servidor já estava parado"; fi
}
