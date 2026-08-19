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

# ----- Backend por papel (opencode | codex) -----
# escolhido interativamente no 'orchestra up'; env sobrescreve (útil p/ CI/scripts).
ORCHESTRA_CODER="${ORCHESTRA_CODER:-}"        # opencode|codex (vazio => pergunta/último)
ORCHESTRA_REVIEWER="${ORCHESTRA_REVIEWER:-}"  # opencode|codex (vazio => pergunta/último)
# modelo opcional SÓ para o backend codex (nome do modelo, ex.: gpt-5-codex).
# vazio => usa o default do Codex. Não confundir com ORCHESTRA_MODEL (OpenCode).
ORCHESTRA_CODEX_MODEL="${ORCHESTRA_CODEX_MODEL:-}"

# carrega config do usuário, se existir
[ -f "$HOME/.config/orchestra-agents/config" ] && . "$HOME/.config/orchestra-agents/config"

OC_URL="http://${ORCHESTRA_HOST}:${ORCHESTRA_PORT}"
mkdir -p "$ORCHESTRA_STATE"

# socket Unix do codex app-server compartilhado (análogo ao OC_URL do OpenCode).
# caminho curto de propósito (limite SUN_LEN ~108 do AF_UNIX).
CODEX_SOCK="${ORCHESTRA_CODEX_SOCK:-$ORCHESTRA_STATE/codex.sock}"

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

# localiza o binário do codex
_resolve_codex() {
  if command -v codex >/dev/null 2>&1; then command -v codex; return; fi
  [ -x "$HOME/.local/bin/codex" ] && { echo "$HOME/.local/bin/codex"; return; }
  echo codex
}
CODEX="$(_resolve_codex)"
CODEX_CLIENT="$ORCHESTRA_HOME/lib/codex_client.py"

# backend efetivo de um papel (opencode|codex). default: opencode.
_role_backend() { # $1 role
  local b; b="$(cat "$ORCHESTRA_STATE/$1.backend" 2>/dev/null)"
  case "$b" in codex) echo codex ;; *) echo opencode ;; esac
}
# há algum papel usando codex? (p/ decidir se sobe o app-server)
_any_codex() {
  local r; for r in coder reviewer; do [ "$(_role_backend "$r")" = codex ] && return 0; done; return 1
}
# instruções (system prompt) por papel para o worker codex
_codex_instructions() { # $1 role
  case "$1" in
    coder) echo "Você é o CODER (executor) do Orchestra. Implemente o que for pedido no projeto atual: escreva/edite código, crie testes e faça funcionar. Seja objetivo e conclua a tarefa." ;;
    reviewer) echo "Você é o REVISOR (read-only) do Orchestra. Analise o diff/alterações. Liste bugs, regressões, riscos de segurança/performance e testes faltando. NÃO edite arquivos. Termine SEMPRE com 'VEREDITO: APROVADO' ou 'VEREDITO: REPROVADO' seguido dos itens." ;;
  esac
}
_codex_sandbox() { # $1 role
  # sem user namespaces, o sandbox real do Codex não funciona → roda sem sandbox
  if [ -f "$ORCHESTRA_STATE/codex.nosandbox" ]; then echo danger-full-access; return; fi
  case "$1" in coder) echo workspace-write ;; reviewer) echo read-only ;; esac
}

oc_up() { curl -s --max-time 2 "$OC_URL/api/session" >/dev/null 2>&1; }

# resolve o config do OpenCode respeitando OPENCODE_CONFIG e XDG_CONFIG_HOME
oc_config_path() {
  if [ -n "${OPENCODE_CONFIG:-}" ]; then echo "$OPENCODE_CONFIG"; return; fi
  local dir="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
  [ -f "$dir/opencode.jsonc" ] && { echo "$dir/opencode.jsonc"; return; }
  [ -f "$dir/opencode.json" ]  && { echo "$dir/opencode.json";  return; }
  echo "$dir/opencode.jsonc"
}

# garante o agente 'reviewer' no config do OpenCode — automático e idempotente.
# Roda ANTES de subir o servidor p/ que o OpenCode recém-iniciado já leia o agente.
ensure_reviewer_agent() {
  local script="$ORCHESTRA_HOME/config/merge_reviewer.py"
  local tmpl="$ORCHESTRA_HOME/config/opencode.reviewer.jsonc"
  [ -f "$script" ] && [ -f "$tmpl" ] && command -v python3 >/dev/null 2>&1 || return 0
  python3 "$script" "$(oc_config_path)" "$tmpl" >/dev/null 2>&1 || true
}

# ----- Codex app-server compartilhado (análogo ao 'opencode serve') -----
# vivo se o socket existe e responde ao 'initialize' (via WebSocket, no cliente).
codex_up() {
  [ -S "$CODEX_SOCK" ] || return 1
  python3 "$CODEX_CLIENT" --sock "$CODEX_SOCK" ping >/dev/null 2>&1
}

# o sandbox do Codex no Linux usa bubblewrap + user namespaces. Em máquinas onde
# criar user namespaces é bloqueado (containers/kernels endurecidos), o app-server
# NÃO sobe. Detectamos isso e, se for o caso, rodamos SEM sandbox (como o OpenCode).
_codex_sandbox_available() {
  command -v bwrap >/dev/null 2>&1 || return 1
  bwrap --ro-bind / / --dev /dev true >/dev/null 2>&1
}

ensure_codex_server() {
  codex_up && return 0
  rm -f "$CODEX_SOCK" 2>/dev/null || true
  local extra=()
  if _codex_sandbox_available; then
    rm -f "$ORCHESTRA_STATE/codex.nosandbox" 2>/dev/null || true
  else
    printf '1' >"$ORCHESTRA_STATE/codex.nosandbox"
    extra=(-c sandbox_mode=danger-full-access)
    echo "⚠️  user namespaces indisponíveis — Codex rodará SEM sandbox (como o OpenCode)." >&2
  fi
  setsid "$CODEX" app-server "${extra[@]}" --listen "unix://$CODEX_SOCK" \
    >"$ORCHESTRA_STATE/codex-server.log" 2>&1 </dev/null &
  for _ in $(seq 1 30); do codex_up && return 0; sleep 1; done
  return 1
}

ensure_server() {
  oc_up && return 0
  # destaca o servidor de forma portátil: setsid no Linux (idiomático),
  # nohup+disown no macOS/BSD, onde setsid não existe.
  if command -v setsid >/dev/null 2>&1; then
    setsid "$OPENCODE" serve --port "$ORCHESTRA_PORT" --hostname "$ORCHESTRA_HOST" \
      >"$ORCHESTRA_STATE/server.log" 2>&1 </dev/null &
  else
    nohup "$OPENCODE" serve --port "$ORCHESTRA_PORT" --hostname "$ORCHESTRA_HOST" \
      >"$ORCHESTRA_STATE/server.log" 2>&1 </dev/null &
    disown 2>/dev/null || true
  fi
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

# garante o THREAD do codex para um papel (análogo à sessão do OpenCode).
# 2º arg 'fresh' força thread NOVO (usado pelo 'up' p/ contexto limpo).
ensure_codex_thread() { # $1 role  [fresh]
  local role="$1" fresh="${2:-}" f tid proj model_arg=()
  f="$ORCHESTRA_STATE/$role.codex.thread"
  [ -s "$f" ] && tid="$(cat "$f")"
  if [ -z "$fresh" ] && [ -n "${tid:-}" ]; then echo "$tid"; return 0; fi
  proj="$(cat "$ORCHESTRA_STATE/project" 2>/dev/null)"; [ -n "$proj" ] || proj="$PWD"
  [ -n "$ORCHESTRA_CODEX_MODEL" ] && model_arg=(--model "$ORCHESTRA_CODEX_MODEL")
  local timeout_bin=""; command -v timeout >/dev/null 2>&1 && timeout_bin="timeout 120"
  tid="$($timeout_bin python3 "$CODEX_CLIENT" --sock "$CODEX_SOCK" start-thread \
        --cwd "$proj" \
        --sandbox "$(_codex_sandbox "$role")" \
        --approval never \
        --instructions "$(_codex_instructions "$role")" \
        "${model_arg[@]}" 2>>"$ORCHESTRA_STATE/codex-server.log")"
  [ -n "$tid" ] || return 1
  printf '%s' "$tid" >"$f"
  echo "$tid"
}

# garante o worker de um papel conforme o backend escolhido (opencode|codex).
# usado pelo 'up' e pelos painéis. 4º/2º arg 'fresh' força recomeço limpo.
ensure_worker() { # $1 role  $2 title  [fresh]
  local role="$1" title="$2" fresh="${3:-}" agent
  if [ "$(_role_backend "$role")" = codex ]; then
    ensure_codex_server >/dev/null || { echo "❌ codex app-server não subiu — veja $ORCHESTRA_STATE/codex-server.log" >&2; return 1; }
    ensure_codex_thread "$role" "$fresh"
  else
    case "$role" in coder) agent="$ORCHESTRA_CODER_AGENT" ;; reviewer) agent="$ORCHESTRA_REVIEWER_AGENT" ;; esac
    ensure_session "$role" "$agent" "$title" "$fresh"
  fi
}

# seletor VISUAL (setas) dos backends de coder e reviewer numa única tela.
# desenha em /dev/tty; ecoa "coder_backend reviewer_backend" no stdout.
# respeita env (ORCHESTRA_CODER/REVIEWER) — se AMBOS setados, não abre UI (CI).
# sem /dev/tty (ex.: pipe/CI), cai no default (env > última escolha > opencode).
select_backends() {
  local ce re c0 r0
  case "$ORCHESTRA_CODER"    in opencode|codex) ce="$ORCHESTRA_CODER" ;; *) ce="" ;; esac
  case "$ORCHESTRA_REVIEWER" in opencode|codex) re="$ORCHESTRA_REVIEWER" ;; *) re="" ;; esac
  if [ -n "$ce" ] && [ -n "$re" ]; then echo "$ce $re"; return 0; fi
  c0="${ce:-$(_role_backend coder)}"; r0="${re:-$(_role_backend reviewer)}"
  # sem terminal controlador (pipe/CI/subprocesso): não dá pra abrir /dev/tty → default.
  if ! ( : >/dev/tty ) 2>/dev/null; then echo "$c0 $r0"; return 0; fi

  local labels=("CODER  " "REVISOR") vals=("$c0" "$r0")
  local row=0 nrows=2 key k2
  _sb_t()  { printf "$@" >/dev/tty; }
  _sb_toggle() { [ "${vals[$row]}" = opencode ] && vals[$row]=codex || vals[$row]=opencode; }
  _sb_render() {
    local i arrow oc cx
    for i in 0 1; do
      [ "$i" = "$row" ] && arrow='\033[1;36m▸\033[0m' || arrow=' '
      if [ "${vals[$i]}" = opencode ]; then oc='\033[1;7;36m opencode \033[0m'; cx=' codex ';
      else oc=' opencode '; cx='\033[1;7;35m codex \033[0m'; fi
      _sb_t ' %b  \033[1m%s\033[0m   %b  %b\n' "$arrow" "${labels[$i]}" "$oc" "$cx"
    done
  }
  _sb_t '\n\033[1m🎛️  Escolha os workers deste time\033[0m  \033[2m(↑/↓ move · ←/→ ou espaço troca · Enter confirma)\033[0m\n\n'
  _sb_t '\033[?25l'
  trap 'printf "\033[?25h" >/dev/tty' RETURN INT
  _sb_render
  while true; do
    IFS= read -rsn1 key </dev/tty || break
    case "$key" in
      $'\e')
        read -rsn2 -t 0.02 k2 </dev/tty
        case "$k2" in
          '[A') row=$(( (row+nrows-1)%nrows )) ;;
          '[B') row=$(( (row+1)%nrows )) ;;
          '[C'|'[D') _sb_toggle ;;
        esac ;;
      ' ') _sb_toggle ;;
      k|K) row=$(( (row+nrows-1)%nrows )) ;;
      j|J) row=$(( (row+1)%nrows )) ;;
      h|H|l|L) _sb_toggle ;;
      '') break ;;                 # Enter
      q|Q) break ;;
    esac
    _sb_t '\033[%dA' "$nrows"; _sb_render
  done
  _sb_t '\033[?25h\n'
  trap - RETURN INT
  unset -f _sb_t _sb_toggle _sb_render
  echo "${vals[0]} ${vals[1]}"
}

# escolhe o backend de um papel: env > pergunta interativa (com último como default).
# lê/escreve em /dev/tty para não poluir stdout (que carrega o valor escolhido).
choose_backend() { # $1 role  -> ecoa opencode|codex
  local role="$1" envval="" cur def ans
  case "$role" in coder) envval="$ORCHESTRA_CODER" ;; reviewer) envval="$ORCHESTRA_REVIEWER" ;; esac
  cur="$(_role_backend "$role")"; def="${cur:-opencode}"
  if [ -n "$envval" ]; then
    case "$envval" in
      opencode|codex) echo "$envval"; return 0 ;;
      *) printf "⚠️  valor inválido em ORCHESTRA_%s: '%s' — usando '%s'\n" "$(echo "$role" | tr a-z A-Z)" "$envval" "$def" >&2; echo "$def"; return 0 ;;
    esac
  fi
  # sem terminal interativo => usa o default (não trava CI/scripts)
  if [ ! -r /dev/tty ]; then echo "$def"; return 0; fi
  printf '  %-9s [1] opencode  [2] codex  (padrão: %s) > ' "$role" "$def" >/dev/tty
  read -r ans </dev/tty || ans=""
  case "$ans" in
    1|opencode|oc|o) echo opencode ;;
    2|codex|cx|c)    echo codex ;;
    "")              echo "$def" ;;
    *)               printf "   resposta '%s' não reconhecida — usando '%s'\n" "$ans" "$def" >/dev/tty; echo "$def" ;;
  esac
}

# despacho ASSÍNCRONO (não-bloqueante): retorna na hora, o worker roda em background.
# É o que evita o líder gastar token "esperando".
dispatch() { # $1 role  $2.. texto
  local role="$1"; shift; local text="$*"
  local agent f sid
  case "$role" in coder|reviewer) ;; *) echo "papel inválido: '$role' (use coder|reviewer)"; return 1 ;; esac
  if [ "$(_role_backend "$role")" = codex ]; then dispatch_codex "$role" "$text"; return; fi
  case "$role" in
    coder)    agent="$ORCHESTRA_CODER_AGENT" ;;
    reviewer) agent="$ORCHESTRA_REVIEWER_AGENT" ;;
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

# despacho ASSÍNCRONO para o backend CODEX: dispara o turno em background (setsid),
# que roda até completar escrevendo a resposta em <role>.codex.last e o estado em
# <role>.codex.status. O painel (codex --remote) enxerga o mesmo thread ao vivo.
dispatch_codex() { # $1 role  $2 text
  local role="$1" text="$2" tid last statf log tfile
  tfile="$ORCHESTRA_STATE/$role.codex.thread"
  [ -s "$tfile" ] || { echo "❌ thread codex de '$role' não existe — rode 'orchestra up' primeiro"; return 1; }
  ensure_codex_server >/dev/null || { echo "❌ codex app-server indisponível — veja $ORCHESTRA_STATE/codex-server.log"; return 1; }
  tid="$(cat "$tfile")"
  last="$ORCHESTRA_STATE/$role.codex.last"
  statf="$ORCHESTRA_STATE/$role.codex.status"
  log="$ORCHESTRA_STATE/$role.codex.log"
  rm -f "$last" 2>/dev/null || true
  printf 'running' >"$statf"
  setsid python3 "$CODEX_CLIENT" --sock "$CODEX_SOCK" dispatch \
    --thread "$tid" --text "$text" --last "$last" --status "$statf" --timeout 600 \
    >"$log" 2>&1 </dev/null &
  echo "📨 enviado ao codex ($role, thread $tid) — rodando no app-server, sem bloquear o líder"
}

# lê o resultado do backend codex (sob demanda). usado por result() quando o papel é codex.
result_codex() { # $1 role
  local role="$1" last statf st
  last="$ORCHESTRA_STATE/$role.codex.last"
  statf="$ORCHESTRA_STATE/$role.codex.status"
  st="$(cat "$statf" 2>/dev/null)"
  if [ -s "$last" ]; then cat "$last"; echo
  elif [ "$st" = running ]; then echo "(sem resposta ainda — o worker codex pode estar processando)"
  else echo "(sem resposta ainda)"; fi
}

# última resposta do worker (sob demanda — não fica em loop gastando token)
result() { # $1 role
  local role="${1:-}" f sid
  [ -n "$role" ] || { echo "uso: orchestra result coder|reviewer"; return 1; }
  case "$role" in coder|reviewer) ;; *) echo "papel inválido: '$role' (use coder|reviewer)"; return 1 ;; esac
  if [ "$(_role_backend "$role")" = codex ]; then result_codex "$role"; return; fi
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
# espera BLOQUEANTE para o backend codex: faz poll no arquivo de status escrito
# pelo dispatch em background. Mesmos exit codes do result_wait do OpenCode:
# 0 ok · 2 timeout ([TIMEOUT/PARCIAL]) · 3 erro.
result_wait_codex() { # $1 role  $2 timeout
  local role="$1" timeout="$2" statf last st elapsed=0 interval=3
  statf="$ORCHESTRA_STATE/$role.codex.status"
  last="$ORCHESTRA_STATE/$role.codex.last"
  while [ "$elapsed" -lt "$timeout" ]; do
    st="$(cat "$statf" 2>/dev/null)"
    case "$st" in
      done)  [ -s "$last" ] && cat "$last" && echo; return 0 ;;
      error) echo "❌ erro no worker codex:" >&2; [ -s "$last" ] && cat "$last" && echo; return 3 ;;
      timeout)
        echo "⚠️  o worker codex atingiu o timeout interno" >&2
        printf '[TIMEOUT/PARCIAL] '; [ -s "$last" ] && cat "$last" || printf '(sem resposta)'; echo; return 2 ;;
    esac
    sleep "$interval"; elapsed=$((elapsed+interval))
  done
  echo "⚠️  timeout (${timeout}s) aguardando o worker coder/reviewer" >&2
  printf '[TIMEOUT/PARCIAL] '; [ -s "$last" ] && cat "$last" || printf '(sem resposta ainda)'; echo
  return 2
}

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
  if [ "$(_role_backend "$role")" = codex ]; then result_wait_codex "$role" "$timeout"; return; fi
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
    except urllib.error.HTTPError as e:
        # erro HTTP permanente (4xx, 5xx) → loga e sai
        # (HTTPError é subclasse de URLError — DEVE vir ANTES do handler de rede)
        body = ""
        try:
            body = e.read().decode()[:200]
        except Exception:
            pass
        print(f"\u274c erro HTTP {e.code} ao consultar sess\u00e3o: {body}", file=sys.stderr)
        sys.exit(3)
    except (urllib.error.URLError, TimeoutError, OSError):
        # ALTA (a): retry apenas em erros transientes de rede
        time.sleep(interval)
        elapsed += interval
        continue
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
  local any=0
  if oc_up; then echo "🟢 OpenCode: no ar ($OC_URL)"; any=1; else echo "⚪ OpenCode: parado"; fi
  if codex_up; then echo "🟢 Codex app-server: no ar ($CODEX_SOCK)"; any=1; else echo "⚪ Codex app-server: parado"; fi
  if [ "$any" = 0 ]; then echo "🔴 nenhum servidor no ar (rode 'orchestra up')"; return; fi
  local em; em="$(_effective_model)"
  if [ -n "$ORCHESTRA_MODEL" ]; then echo "   modelo OpenCode: $em (forçado)"
  elif [ -n "$em" ]; then echo "   modelo OpenCode: $em (default)"; fi
  [ -n "$ORCHESTRA_CODEX_MODEL" ] && echo "   modelo Codex: $ORCHESTRA_CODEX_MODEL"
  local proj; proj="$(cat "$ORCHESTRA_STATE/project" 2>/dev/null)"
  [ -n "$proj" ] && echo "   projeto: $proj"
  local role backend sid tid st
  for role in coder reviewer; do
    backend="$(_role_backend "$role")"
    if [ "$backend" = codex ]; then
      tid="$(cat "$ORCHESTRA_STATE/$role.codex.thread" 2>/dev/null)"
      st="$(cat "$ORCHESTRA_STATE/$role.codex.status" 2>/dev/null)"
      if [ -n "$tid" ]; then echo "   $role → codex thread $tid${st:+ [$st]}"
      else echo "   $role → codex (sem thread)"; fi
    else
      sid="$(cat "$ORCHESTRA_STATE/$role.session" 2>/dev/null)"
      if [ -n "$sid" ]; then echo "   $role → opencode $sid ($(_session_msgcount "$sid") msgs)"
      else echo "   $role → opencode (sem sessão)"; fi
    fi
  done
}

teardown() {
  local stopped=0
  if pkill -f "opencode serve --port $ORCHESTRA_PORT" 2>/dev/null; then echo "🛑 OpenCode encerrado"; stopped=1; fi
  if pkill -f "app-server --listen unix://$CODEX_SOCK" 2>/dev/null; then echo "🛑 Codex app-server encerrado"; stopped=1; fi
  rm -f "$CODEX_SOCK" 2>/dev/null || true
  [ "$stopped" = 1 ] || echo "servidores já estavam parados"
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

  echo; echo "Codex (opcional — só se escolher como coder/reviewer):"
  if command -v codex >/dev/null 2>&1 || [ -x "$HOME/.local/bin/codex" ]; then
    _dok "codex — $("$CODEX" --version 2>/dev/null || echo "$CODEX")"
    if [ -f "$HOME/.codex/auth.json" ]; then _dok "codex autenticado (~/.codex/auth.json)"
    else _dwarn "codex sem auth — rode: codex login"; fi
    [ -f "$CODEX_CLIENT" ] && _dok "cliente app-server presente" || _dwarn "lib/codex_client.py ausente — reinstale (install.sh)"
    if [ -S "$CODEX_SOCK" ] && codex_up; then _dok "app-server: no ar ($CODEX_SOCK)"
    else _dwarn "app-server parado (sobe ao escolher codex em 'orchestra up')"; fi
  else
    _dwarn "codex ausente — necessário só se for usar como coder/reviewer (https://developers.openai.com/codex/cli)"
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
