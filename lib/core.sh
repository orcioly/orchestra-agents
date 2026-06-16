#!/usr/bin/env bash
# Orchestra Agents — núcleo compartilhado (servidor OpenCode, sessões, despacho async)
# Não executar diretamente; é "sourced" pelo CLI e pelos scripts de painel.

# ----- Configuração (sobrescrevível por env ou ~/.config/orchestra-agents/config) -----
ORCHESTRA_HOME="${ORCHESTRA_HOME:-$HOME/.orchestra-agents}"
ORCHESTRA_STATE="${ORCHESTRA_STATE:-$HOME/.local/state/orchestra-agents}"
ORCHESTRA_PORT="${ORCHESTRA_PORT:-4096}"
ORCHESTRA_HOST="${ORCHESTRA_HOST:-127.0.0.1}"
# modelo: VAZIO por padrão => usa o modelo já configurado/default no OpenCode.
# defina ORCHESTRA_MODEL="provider/modelo" só se quiser FORÇAR um modelo específico.
ORCHESTRA_MODEL="${ORCHESTRA_MODEL:-}"
ORCHESTRA_CODER_AGENT="${ORCHESTRA_CODER_AGENT:-build}"
ORCHESTRA_REVIEWER_AGENT="${ORCHESTRA_REVIEWER_AGENT:-reviewer}"

# carrega config do usuário, se existir
[ -f "$HOME/.config/orchestra-agents/config" ] && . "$HOME/.config/orchestra-agents/config"

OC_URL="http://${ORCHESTRA_HOST}:${ORCHESTRA_PORT}"
mkdir -p "$ORCHESTRA_STATE"

_model_provider() { echo "${ORCHESTRA_MODEL%%/*}"; }
_model_id()       { echo "${ORCHESTRA_MODEL#*/}"; }

# lê o modelo default já configurado no OpenCode (~/.config/opencode/opencode.jsonc)
_detect_model() {
  local cfg
  for cfg in "$HOME/.config/opencode/opencode.jsonc" "$HOME/.config/opencode/opencode.json"; do
    [ -f "$cfg" ] || continue
    python3 - "$cfg" <<'PY'
import sys, re, json
src = open(sys.argv[1]).read()
src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)          # comentários de bloco
src = re.sub(r'(?m)(^|\s)//.*$', '', src)                 # comentários de linha (preserva http://)
try:
    print(json.loads(src).get("model") or "")
except Exception:
    raise SystemExit(1)
PY
    return 0
  done
  return 1
}

# modelo efetivo para exibir/diagnosticar: o forçado, senão o default do OpenCode
_effective_model() {
  if [ -n "$ORCHESTRA_MODEL" ]; then echo "$ORCHESTRA_MODEL"; else _detect_model 2>/dev/null || true; fi
}

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
# (usado pelo 'up' para começar cada subida com contexto limpo).
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
  # salva baseline (contagem de mensagens pré-despacho) para --wait detectar resposta nova
  printf '%s' "$(_session_msgcount "$sid")" >"$ORCHESTRA_STATE/$role.baseline"
  python3 - "$OC_URL" "$sid" "$text" "$agent" "$ORCHESTRA_MODEL" <<'PY'
import sys, json, urllib.request, urllib.error
url, sid, text, agent, model = sys.argv[1:6]
payload = {"agent": agent, "parts": [{"type": "text", "text": text}]}
if model:  # só força o modelo se ORCHESTRA_MODEL estiver definido; senão usa o default do OpenCode
    prov, _, mid = model.partition("/")
    payload["model"] = {"providerID": prov, "modelID": mid}
body = json.dumps(payload).encode()
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
  case "$role" in coder|reviewer) ;; *) echo "papel inválido: '$role' (use coder|reviewer)"; return 1 ;; esac
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

# resultado BLOQUEANTE: faz poll a cada ~3s no endpoint /session/<sid>/message
# até a resposta do worker à ÚLTIMA tarefa despachada estar COMPLETA.
# usa o baseline salvo em dispatch() para detectar mensagem assistant NOVA.
result_wait() { # $1 role  $2 timeout_segundos (padrão 300)  $3 caller (opcional: "await")
  local role="${1:-}" timeout="${2:-300}" caller="${3:-}" f sid baseline
  local usage_msg
  if [ "$caller" = "await" ]; then
    usage_msg="uso: orchestra await <papel> [timeout_segundos]"
  else
    usage_msg="uso: orchestra result <papel> --wait [timeout_segundos]"
  fi
  [ -n "$role" ] || { echo "$usage_msg"; return 1; }
  case "$role" in coder|reviewer) ;; *) echo "papel inválido: '$role' (use coder|reviewer)"; return 1 ;; esac
  # BLOCKER 1: valida timeout no bash com regex de dígitos puros
  if ! [[ "$timeout" =~ ^[0-9]+$ ]]; then
    echo "❌ timeout inválido: '$timeout' (deve ser número inteiro positivo de segundos)" >&2; return 1
  fi
  f="$ORCHESTRA_STATE/$role.session"
  [ -s "$f" ] || { echo "sessão de '$role' não existe"; return 1; }
  sid="$(cat "$f")"
  # BLOCKER 3: baseline ausente → avisa e usa contagem atual como referência,
  # para NÃO retornar resposta antiga/stale como se fosse nova.
  if [ -s "$ORCHESTRA_STATE/$role.baseline" ]; then
    baseline="$(cat "$ORCHESTRA_STATE/$role.baseline")"
  else
    echo "⚠️  baseline ausente (sem dispatch prévio?) — usando contagem atual como referência" >&2
    baseline="$(_session_msgcount "$sid")"
  fi
  # defesa: baseline deve ser dígitos puros
  [[ "$baseline" =~ ^[0-9]+$ ]] || baseline=0
  python3 - "$OC_URL" "$sid" "$baseline" "$timeout" <<'PY'
import sys, json, time, urllib.request, urllib.error
url, sid, baseline_str, timeout_str = sys.argv[1:5]

# BLOCKER 1: try/except ValueError para conversões, com erro amigável em stderr
try:
    baseline = int(baseline_str)
except ValueError:
    print(f"\u274c baseline inv\u00e1lido: '{baseline_str}' (deve ser n\u00famero inteiro)", file=sys.stderr)
    sys.exit(1)
try:
    timeout = int(timeout_str)
except ValueError:
    print(f"\u274c timeout inv\u00e1lido: '{timeout_str}' (deve ser n\u00famero inteiro de segundos)", file=sys.stderr)
    sys.exit(1)

elapsed = 0
interval = 3
messages = []

while elapsed < timeout:
    try:
        resp = urllib.request.urlopen(f"{url}/session/{sid}/message", timeout=10)
        data = json.load(resp)
        messages = data if isinstance(data, list) else data.get('data', [])
    except (urllib.error.URLError, TimeoutError, OSError):
        # ALTA (a): retry apenas em erros transientes de rede
        time.sleep(interval)
        elapsed += interval
        continue
    except urllib.error.HTTPError as e:
        # erro HTTP permanente (4xx, 5xx) → loga e sai
        body = ""
        try:
            body = e.read().decode()[:200]
        except Exception:
            pass
        print(f"\u274c erro HTTP {e.code} ao consultar sess\u00e3o: {body}", file=sys.stderr)
        sys.exit(3)
    except json.JSONDecodeError as e:
        # JSON inv\u00e1lido → loga e sai
        print(f"\u274c resposta inv\u00e1lida do servidor (JSON): {e}", file=sys.stderr)
        sys.exit(3)

    # busca mensagens assistant NOVAS (\u00edndice >= baseline, ap\u00f3s as pr\u00e9-despacho)
    new_asst = []
    for i, m in enumerate(messages):
        info = m.get('info', {}) or {}
        if info.get('role') == 'assistant' and i >= baseline:
            new_asst.append(m)

    if new_asst:
        m = new_asst[-1]
        info = m.get('info', {}) or {}
        tinfo = info.get('time', {}) or {}
        completed = tinfo.get('completed')
        txt = ' '.join(p.get('text', '') for p in m.get('parts', []) if p.get('type') == 'text').strip()

        if completed and txt:
            print(txt)
            sys.exit(0)

    time.sleep(interval)
    elapsed += interval

# timeout: mostra o que houver com aviso em stderr e marca parcial no stdout (exit 2)
# ALTA (b): prefixo [TIMEOUT/PARCIAL] deixa claro que o texto não é confiável
print(f"\u26a0\ufe0f  timeout ({timeout}s) — mostrando resposta parcial, se houver:", file=sys.stderr)
asst = [m for m in messages if (m.get('info', {}) or {}).get('role') == 'assistant']
if asst:
    m = asst[-1]
    txt = ' '.join(p.get('text', '') for p in m.get('parts', []) if p.get('type') == 'text').strip()
    print(f"[TIMEOUT/PARCIAL] {txt}" if txt else "[TIMEOUT/PARCIAL] (processando ou resposta sem texto)")
else:
    print("[TIMEOUT/PARCIAL] (sem resposta ainda)")
sys.exit(2)
PY
}

status() {
  if oc_up; then echo "🟢 servidor: no ar ($OC_URL)"; else echo "🔴 servidor: parado (rode 'orchestra up')"; return; fi
  local em; em="$(_effective_model)"
  if [ -n "$ORCHESTRA_MODEL" ]; then echo "   modelo: $em (forçado)"
  elif [ -n "$em" ]; then echo "   modelo: $em (default do OpenCode)"
  else echo "   modelo: default do OpenCode"; fi
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

# diagnóstico de pré-requisitos, modelo/agente do OpenCode, servidor e PATH
doctor() {
  local ok=0 warn=0 fail=0 b p
  _dok(){   printf '  \033[1;32m✔\033[0m %s\n' "$*"; ok=$((ok+1)); }
  _dwarn(){ printf '  \033[1;33m!\033[0m %s\n' "$*"; warn=$((warn+1)); }
  _dfail(){ printf '  \033[1;31m✖\033[0m %s\n' "$*"; fail=$((fail+1)); }

  printf '\n🩺 Orchestra Agents — diagnóstico\n\n'

  echo "Pré-requisitos:"
  for b in claude opencode zellij git python3 curl; do
    if p="$(command -v "$b" 2>/dev/null)"; then _dok "$b — $p"
    elif [ "$b" = opencode ] && [ -x "$HOME/.opencode/bin/opencode" ]; then _dok "opencode — $HOME/.opencode/bin/opencode"
    else
      case "$b" in
        claude)   _dfail "claude ausente — https://docs.claude.com/claude-code" ;;
        opencode) _dfail "opencode ausente — https://opencode.ai" ;;
        zellij)   _dfail "zellij ausente — reinstale (install.sh) ou https://zellij.dev" ;;
        *)        _dfail "$b ausente" ;;
      esac
    fi
  done

  local em provider auth_file oc_cfg origin
  em="$(_effective_model)"
  [ -n "$ORCHESTRA_MODEL" ] && origin="forçado (ORCHESTRA_MODEL)" || origin="default do OpenCode"
  echo; echo "OpenCode (modelo: ${em:-?} — $origin):"
  if [ -z "$em" ]; then
    _dwarn "não consegui detectar o modelo default do OpenCode — confira ~/.config/opencode/opencode.jsonc"
  else
    provider="${em%%/*}"
    auth_file="$HOME/.local/share/opencode/auth.json"
    if [ -f "$auth_file" ] && python3 -c "import json,sys;d=json.load(open('$auth_file'));sys.exit(0 if '$provider' in d else 1)" 2>/dev/null; then
      _dok "provider '$provider' autenticado"
    else
      _dwarn "provider '$provider' não autenticado — rode: opencode auth login"
    fi
    if "$OPENCODE" models 2>/dev/null | grep -qx "$em"; then
      _dok "modelo '$em' disponível"
    else
      _dwarn "modelo '$em' não listado em 'opencode models'"
    fi
  fi
  oc_cfg="$HOME/.config/opencode/opencode.jsonc"
  if [ -f "$oc_cfg" ] && grep -q "\"$ORCHESTRA_REVIEWER_AGENT\"" "$oc_cfg"; then
    _dok "agente revisor '$ORCHESTRA_REVIEWER_AGENT' configurado"
  else
    _dwarn "agente '$ORCHESTRA_REVIEWER_AGENT' não encontrado — veja $ORCHESTRA_HOME/config/opencode.reviewer.jsonc"
  fi

  echo; echo "Orchestra:"
  [ -d "$ORCHESTRA_HOME" ] && _dok "instalado em $ORCHESTRA_HOME" || _dfail "instalação não encontrada em $ORCHESTRA_HOME"
  local oself; oself="$(command -v orchestra 2>/dev/null || true)"
  [ -n "$oself" ] && _dok "CLI no PATH — $oself" || _dwarn "comando 'orchestra' não está no PATH"
  oc_up && _dok "servidor: no ar ($OC_URL)" || _dwarn "servidor parado (sobe ao rodar 'orchestra')"

  echo
  if [ "$fail" -gt 0 ]; then
    printf '\033[1;31mResumo: %d falha(s) e %d aviso(s). Resolva as falhas acima.\033[0m\n' "$fail" "$warn"; return 1
  elif [ "$warn" -gt 0 ]; then
    printf '\033[1;33mResumo: o essencial está ok, com %d aviso(s).\033[0m\n' "$warn"; return 0
  else
    printf '\033[1;32mResumo: tudo certo! Pode rodar "orchestra". 🎼\033[0m\n'; return 0
  fi
}

# remove COMPLETAMENTE o Orchestra Agents (preserva zellij/claude/opencode)
uninstall() {
  echo "🧹 Desinstalando Orchestra Agents..."
  teardown >/dev/null 2>&1 || true
  # 1) symlink(s) do CLI no PATH (+ o local registrado na instalação)
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
  # 2) linhas de PATH nos rc + fish
  for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
    { [ -f "$rc" ] && grep -q 'orchestra-agents (PATH)' "$rc" 2>/dev/null; } || continue
    tmp="$(mktemp)"
    awk '/# orchestra-agents \(PATH\)/{skip=2} skip>0{skip--; next} {print}' "$rc" >"$tmp" \
      && mv "$tmp" "$rc" && echo "  PATH removido de $rc"
  done
  rm -f "$HOME/.config/fish/conf.d/orchestra.fish"
  # 3) layout do zellij
  rm -f "$HOME/.config/zellij/layouts/orchestra.kdl"
  # 4) diretórios de config, estado e instalação
  rm -rf "$HOME/.config/orchestra-agents" "$ORCHESTRA_STATE" "$ORCHESTRA_HOME"
  echo "✅ Orchestra Agents removido por completo."
  echo "   (zellij, Claude Code e OpenCode foram preservados — são ferramentas gerais.)"
}
