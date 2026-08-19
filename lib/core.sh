#!/usr/bin/env bash
# Orchestra Agents — núcleo compartilhado.
#
# Modelo: um TIME de N agentes (líder + workers) rodando como TUIs LOCAIS em
# painéis do zellij. O líder despacha tarefas INJETANDO texto no painel do worker
# (via lib/mux.sh) e recebe a resposta quando o worker executa 'orchestra done'.
#
# Não há servidor headless nem id de sessão guardado: é por isso que /clear, /new,
# resize e mover painel deixaram de quebrar o despacho.
#
# Não executar diretamente; é "sourced" pelo CLI e pelos scripts de painel.

# ----- Configuração (sobrescrevível por env ou ~/.config/orchestra-agents/config) -----
ORCHESTRA_HOME="${ORCHESTRA_HOME:-$HOME/.orchestra-agents}"
ORCHESTRA_STATE="${ORCHESTRA_STATE:-$HOME/.local/state/orchestra-agents}"

# modelos: VAZIOS por padrão => cada CLI usa o modelo que o usuário já configurou.
ORCHESTRA_MODEL="${ORCHESTRA_MODEL:-}"                 # OpenCode (provider/modelo)
ORCHESTRA_CODEX_MODEL="${ORCHESTRA_CODEX_MODEL:-}"     # Codex (nome do modelo)
ORCHESTRA_MODEL_CLAUDE="${ORCHESTRA_MODEL_CLAUDE:-}"   # Claude Code

# composição do time sem TTY (CI/scripts): "leader=claude,coder=opencode,reviewer=codex"
ORCHESTRA_TEAM="${ORCHESTRA_TEAM:-}"
# aliases herdados (continuam funcionando)
ORCHESTRA_CODER="${ORCHESTRA_CODER:-}"
ORCHESTRA_REVIEWER="${ORCHESTRA_REVIEWER:-}"

# timeout padrão do 'await' (segundos)
ORCHESTRA_TIMEOUT="${ORCHESTRA_TIMEOUT:-300}"

# carrega config do usuário, se existir
[ -f "$HOME/.config/orchestra-agents/config" ] && . "$HOME/.config/orchestra-agents/config"

mkdir -p "$ORCHESTRA_STATE"

# ----- Projeto corrente e diretórios de runtime -----
# O runtime mora DENTRO do projeto (.orchestra/run) de propósito: é o que permite
# ao worker codex, rodando com sandbox 'workspace-write', escrever a resposta.
ORCHESTRA_PROJECT="${ORCHESTRA_PROJECT:-}"
if [ -z "$ORCHESTRA_PROJECT" ]; then
  ORCHESTRA_PROJECT="$(cat "$ORCHESTRA_STATE/project" 2>/dev/null)"
fi
[ -n "$ORCHESTRA_PROJECT" ] || ORCHESTRA_PROJECT="$PWD"
ORCHESTRA_DIR="$ORCHESTRA_PROJECT/.orchestra"
ORCHESTRA_RUN_DIR="$ORCHESTRA_DIR/run"

# shellcheck source=/dev/null
. "$ORCHESTRA_HOME/lib/mux.sh"
# shellcheck source=/dev/null
. "$ORCHESTRA_HOME/lib/team.sh"
# shellcheck source=/dev/null
. "$ORCHESTRA_HOME/lib/layout.sh"

# ----- Resolução dos binários dos backends -----
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

backend_url() { # $1 backend  → onde instalar
  case "$1" in
    claude)   echo "https://docs.claude.com/claude-code" ;;
    opencode) echo "https://opencode.ai" ;;
    codex)    echo "https://developers.openai.com/codex/cli" ;;
  esac
}

# Sandbox do Codex. Todos os papéis precisam escrever em .orchestra/run/ para
# fechar o ciclo com 'orchestra done', então usamos workspace-write mesmo no
# reviewer — a disciplina read-only dele é garantida pelo prompt de papel.
codex_sandbox_for() { # $1 role
  echo "${ORCHESTRA_CODEX_SANDBOX:-workspace-write}"
}

# ----- OpenCode: config e agentes -----
# resolve o config do OpenCode respeitando OPENCODE_CONFIG e XDG_CONFIG_HOME
oc_config_path() {
  if [ -n "${OPENCODE_CONFIG:-}" ]; then echo "$OPENCODE_CONFIG"; return; fi
  local dir="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
  [ -f "$dir/opencode.jsonc" ] && { echo "$dir/opencode.jsonc"; return; }
  [ -f "$dir/opencode.json" ]  && { echo "$dir/opencode.json";  return; }
  echo "$dir/opencode.jsonc"
}

# garante o agente 'reviewer' no config do OpenCode — automático e idempotente.
ensure_reviewer_agent() {
  local script="$ORCHESTRA_HOME/config/merge_reviewer.py"
  local tmpl="$ORCHESTRA_HOME/config/opencode.reviewer.jsonc"
  [ -f "$script" ] && [ -f "$tmpl" ] && command -v python3 >/dev/null 2>&1 || return 0
  python3 "$script" "$(oc_config_path)" "$tmpl" >/dev/null 2>&1 || true
}

# existe um agente com esse nome no config do OpenCode?
_opencode_has_agent() { # $1 nome
  local cfg; cfg="$(oc_config_path)"
  [ -f "$cfg" ] || return 1
  grep -q "\"$1\"" "$cfg" 2>/dev/null
}

# lê o modelo default já configurado no OpenCode
_detect_model() {
  local cfg
  for cfg in "$(oc_config_path)"; do
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

_effective_model() {
  if [ -n "$ORCHESTRA_MODEL" ]; then echo "$ORCHESTRA_MODEL"; else _detect_model 2>/dev/null || true; fi
}

# ---------------------------------------------------------------------------
# Runtime dos agentes
# ---------------------------------------------------------------------------
# printf '%-Ns' do bash conta BYTES: um acento (LÍDER) encolhe a coluna em 1 e
# desalinha a tabela inteira. Este padding conta CARACTERES.
_pad() { # $1 texto  $2 largura
  local t="$1" n="${2:-0}" i=${#1}
  printf '%s' "$t"
  while [ "$i" -lt "$n" ]; do printf ' '; i=$((i+1)); done
}

# "a b c" -> "a, b, c" — toda lista mostrada ao usuário passa por aqui
_human_list() { printf '%s' "$1" | tr -s ' ' '\n' | sed '/^$/d' | paste -sd',' - | sed 's/,/, /g'; }

# corta preservando a largura visual (conta caracteres, não bytes)
_ellipsis() { # $1 texto  $2 largura
  local t="$1" n="${2:-0}"
  if [ "${#t}" -gt "$n" ]; then printf '%s…' "${t:0:$((n-1))}"; else printf '%s' "$t"; fi
}

_run_file() { echo "$ORCHESTRA_RUN_DIR/$1.$2"; }   # $1 agente  $2 sufixo

_new_task_id() { printf 'T%s%04d' "$(date +%s)" "$((RANDOM % 10000))"; }

# garante que o agente existe, com mensagem útil quando não existe
_require_agent() { # $1 nome
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

# resolve o painel do agente, RECRIANDO-O se tiver morrido (auto-cura).
_pane_for() { # $1 agente  → ecoa pane-id
  local agent="$1" pane
  pane="$(mux_pane_id "$agent" 2>/dev/null)"
  if [ -n "$pane" ]; then echo "$pane"; return 0; fi
  mux_available || { echo "❌ multiplexador indisponível — rode 'orchestra up'" >&2; return 1; }
  echo "⚠️  painel de '$agent' não está aberto — recriando…" >&2
  pane="$(mux_new_pane "$agent" "$ORCHESTRA_PROJECT")" || {
    echo "❌ não consegui recriar o painel de '$agent'" >&2; return 1; }
  # dá um instante para a TUI subir antes de injetar texto
  sleep 3
  echo "$pane"
}

# ---------------------------------------------------------------------------
# Despacho (ASSÍNCRONO): injeta a tarefa no painel do agente.
# ---------------------------------------------------------------------------
dispatch() { # $1 agente  $2.. texto
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
# 'orchestra done' — chamado PELO WORKER para devolver a resposta (lê stdin).
# ---------------------------------------------------------------------------
done_reply() { # $1 agente  $2 task_id
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
# Leitura de resultado
# ---------------------------------------------------------------------------
result() { # $1 agente  (não-bloqueante)
  local agent="${1:-}" st
  _require_agent "$agent" || return 1
  st="$(cat "$(_run_file "$agent" status)" 2>/dev/null)"
  if [ -s "$(_run_file "$agent" out)" ]; then cat "$(_run_file "$agent" out)"; return 0; fi
  case "$st" in
    running) echo "(sem resposta ainda — '$agent' está processando)" ;;
    *)       echo "(sem resposta ainda — nenhuma tarefa despachada para '$agent')" ;;
  esac
}

# BLOQUEANTE: espera a resposta da ÚLTIMA tarefa despachada.
# exit 0 ok · 1 validação · 2 timeout ([TIMEOUT/PARCIAL]) · 3 erro de ambiente
result_wait() { # $1 agente  $2 timeout  $3 caller
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

  # timeout: devolve o que der, SEMPRE marcado como não confiável.
  echo "⚠️  timeout (${timeout}s) esperando '$agent'." >&2
  if [ -s "$(_run_file "$agent" out)" ]; then
    printf '[TIMEOUT/PARCIAL] '; cat "$(_run_file "$agent" out)"
  else
    # fallback: cauda da tela do painel — o worker pode ter respondido sem
    # executar 'orchestra done'.
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
# Gestão do time
# ---------------------------------------------------------------------------
# estado legível da última tarefa do agente
_agent_state() { # $1 agente
  case "$(cat "$(_run_file "$1" status)" 2>/dev/null)" in
    running) printf 'trabalhando…' ;;
    done)    printf 'respondeu' ;;
    error)   printf 'erro' ;;
    *)       printf '—' ;;
  esac
}

# uma linha da tabela do time (mesma ordem de colunas do menu)
_agent_row() { # $1 agente
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

# Resolve o papel de um agente NOVO: preset conhecido, ou 'custom' com um prompt
# editável no projeto. Ecoa "role<TAB>prompt_file". Usado pelo 'add' e pelo
# ORCHESTRA_TEAM, para os dois caminhos criarem agentes idênticos.
_resolve_role() { # $1 nome  [$2 role desejado]  [$3 texto do prompt]
  local name="$1" role="${2:-}" text="${3:-}" pf=""
  [ -n "$role" ] || role="$name"
  # instruções dadas na criação => agente custom, com o texto do usuário
  if [ -n "$text" ]; then
    mkdir -p "$(team_prompts)"
    pf=".orchestra/prompts/$name.md"
    { printf 'Você é o agente **%s** do Orchestra Agents.\n\n' "$name"
      printf '%s\n' "$text"
      printf '\nTrabalhe no projeto onde este painel foi aberto.\n'
    } >"$ORCHESTRA_PROJECT/$pf"
    printf '%s\t%s' custom "$pf"
    return 0
  fi
  case " $ORCHESTRA_ROLES " in
    *" $role "*) ;;
    *) role=custom
       mkdir -p "$(team_prompts)"
       pf=".orchestra/prompts/$name.md"
       [ -f "$ORCHESTRA_PROJECT/$pf" ] || {
         cp "$ORCHESTRA_HOME/agents/roles/custom.md" "$ORCHESTRA_PROJECT/$pf" 2>/dev/null || \
           printf 'Você é o agente %s do Orchestra.\n' "$name" >"$ORCHESTRA_PROJECT/$pf"
       } ;;
  esac
  printf '%s\t%s' "$role" "$pf"
}

# Avisa o LÍDER, AO VIVO, que o time mudou — injetando a nota no painel dele.
# Sem isto o líder só conhece o time montado quando o painel dele subiu, e um agente
# criado depois seria ignorado até o próximo 'orchestra up'.
notify_leader() { # $1 texto
  local pane self
  mux_available || return 0
  pane="$(mux_pane_id leader 2>/dev/null)"
  [ -n "$pane" ] || return 0
  # se o comando partiu do próprio painel do líder, ele já sabe: não injetar nele mesmo
  self="${ZELLIJ_PANE_ID:-}"
  [ -n "$self" ] && [ "$pane" = "terminal_$self" ] && return 0
  mux_send_text "$pane" "$1" && mux_enter "$pane"
}

agent_add() { # $1 nome  [$2 backend]  [$3 role]  [$4 texto do prompt]
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
  # A IA é ESCOLHA DO USUÁRIO — nunca um default silencioso. Sem ela: pergunta (se um
  # humano estiver digitando) ou falha explicando. É isto que impede um agente líder de
  # criar tudo em 'claude' só por ter esquecido a flag.
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
    echo "  prompt em: $pf (edite à vontade)"
    # sem descrição o agente é genérico E o líder não sabe quando usá-lo
    if [ -z "$text" ]; then
      echo "  ⚠️  ele ainda não tem especialidade: o líder vai vê-lo como 'agente customizado'."
      echo "     Descreva a função no arquivo acima, ou recrie com:"
      echo "     orchestra add $name --ia $backend --prompt \"<o que ele faz>\""
    fi
  fi
  if mux_available; then
    mux_new_pane "$name" "$ORCHESTRA_PROJECT" >/dev/null && echo "  🎬 painel aberto"
  else
    echo "  (sem multiplexador ativo — o painel abre no próximo 'orchestra up')"
  fi
  notify_leader "$(cat <<EOF
[ORCHESTRA] O time mudou: o agente '$name' entrou agora ($backend).
Função: $(role_summary "$name")
Delegue com: orchestra send $name "<tarefa>"   ·   resultado: orchestra await $name
Passe a considerá-lo nas próximas tarefas que forem da função dele. Responda só "ok".
EOF
)" && echo "  📣 líder avisado"
}

agent_rm() { # $1 nome
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

# recria os painéis de agentes cujo painel morreu/foi fechado
heal() {
  team_ensure
  mux_available || { echo "❌ multiplexador indisponível — rode 'orchestra up'" >&2; return 1; }
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

# troca o backend do líder
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
    echo "     Feche-o (Ctrl-C durante a contagem) ou rode 'orchestra up' de novo para aplicar."
  fi
}

status() {
  team_ensure
  local s; s="$(mux_session 2>/dev/null)"
  if mux_available; then echo "🟢 multiplexador: $(mux_backend) (sessão ${s:-?})"
  else echo "⚪ multiplexador: fora do ar (rode 'orchestra up')"; fi
  echo "   projeto: $ORCHESTRA_PROJECT"
  echo "   time:    $(team_file)"
  agents_list
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
# Menu VISUAL de composição do time (setas). Desenha em /dev/tty.
# Sem TTY (CI/pipe) usa ORCHESTRA_TEAM / o time salvo, sem travar.
# ---------------------------------------------------------------------------

# aplica ORCHESTRA_TEAM e os aliases herdados por cima do time salvo
# Aplica ORCHESTRA_TEAM ("nome=backend" ou "nome=backend:papel", separados por
# vírgula) e os aliases herdados por cima do time salvo.
_apply_team_env() {
  local spec pair name rest backend role pf
  [ -n "$ORCHESTRA_CODER" ]    && team_set coder    backend "$ORCHESTRA_CODER"    2>/dev/null
  [ -n "$ORCHESTRA_REVIEWER" ] && team_set reviewer backend "$ORCHESTRA_REVIEWER" 2>/dev/null
  [ -n "$ORCHESTRA_TEAM" ] || return 0
  spec="${ORCHESTRA_TEAM//,/ }"
  for pair in $spec; do
    name="${pair%%=*}"; rest="${pair#*=}"
    backend="${rest%%:*}"
    # papel explícito só quando existe o sufixo ':papel'
    if [ "$rest" = "$backend" ]; then role=""; else role="${rest#*:}"; fi
    [ -n "$name" ] && [ -n "$backend" ] || continue
    case " $ORCHESTRA_BACKENDS " in *" $backend "*) ;; *) continue ;; esac
    if [ "$name" = leader ]; then team_set leader backend "$backend"; continue; fi
    team_valid_name "$name" || continue
    if team_exists "$name"; then
      team_set "$name" backend "$backend"
      # trocar o papel de um agente existente também refaz o prompt quando custom
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
  # sem terminal controlador (pipe/CI) ou com o time já fixado por env: não abre UI
  if [ -n "$ORCHESTRA_TEAM" ] || ! ( : >/dev/tty ) 2>/dev/null; then return 0; fi

  local names=() backends=() roles=() row=0 nrows key k2 i
  _st_load() {
    names=(leader); backends=("$(team_field leader backend)"); roles=(leader)
    local n
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      names+=("$n"); backends+=("$(team_field "$n" backend)"); roles+=("$(team_field "$n" role)")
    done < <(team_names)
    # +2 linhas especiais no fim: "adicionar agente" e "sair"
    nrows=$(( ${#names[@]} + 2 ))
  }
  _st_row_add()  { echo "${#names[@]}"; }
  _st_row_quit() { echo "$(( ${#names[@]} + 1 ))"; }
  _st_t() { printf "$@" >/dev/tty; }
  _st_cycle() { # troca o backend da linha corrente
    [ "$row" -lt "${#names[@]}" ] || return 0
    local cur="${backends[$row]}" list=($ORCHESTRA_BACKENDS) j=0 k
    for k in "${!list[@]}"; do [ "${list[$k]}" = "$cur" ] && j=$k; done
    backends[$row]="${list[$(( (j+1) % ${#list[@]} ))]}"
  }
  _st_render() {
    local i arrow lbl b cell line sep desc
    _st_t '\033[u\033[J'          # volta à âncora e limpa daqui para baixo
    _st_t '   \033[2m%s %s %s\033[0m\n' \
      "$(_pad AGENTE 14)" "$(_pad "O QUE FAZ" 30)" "IA QUE RODA"
    for i in "${!names[@]}"; do
      [ "$i" = "$row" ] && arrow='\033[1;36m▸\033[0m' || arrow=' '
      [ "${roles[$i]}" = leader ] && lbl="LÍDER" \
        || lbl="$(printf '%s' "${names[$i]}" | tr '[:lower:]' '[:upper:]')"
      desc="$(_ellipsis "$(role_summary "${names[$i]}")" 29)"
      line=""; sep=""
      for b in $ORCHESTRA_BACKENDS; do
        # sem espaços dentro da célula: qualquer padding só no destaque desalinharia
        # a coluna inteira, porque cada linha destaca uma IA diferente.
        if [ "$b" = "${backends[$i]}" ]; then cell="\033[1;7;36m$b\033[0m"; else cell="\033[2m$b\033[0m"; fi
        line="$line$sep$cell"; sep="\033[2m,\033[0m "
      done
      _st_t ' %b %s %s %s %b\033[K\n' "$arrow" "$(role_icon "${roles[$i]}")" \
        "$(_pad "$(_ellipsis "$lbl" 10)" 11)" "$(_pad "$desc" 30)" "$line"
    done
    _st_t '\033[K\n'
    [ "$row" = "$(_st_row_add)" ] && arrow='\033[1;36m▸\033[0m' || arrow=' '
    _st_t ' %b \033[1m+\033[0m adicionar agente\033[K\n' "$arrow"
    [ "$row" = "$(_st_row_quit)" ] && arrow='\033[1;36m▸\033[0m' || arrow=' '
    _st_t ' %b \033[1m✖\033[0m sair sem abrir\033[K\n' "$arrow"
    _st_t '\033[K\n'
    _st_t '   \033[2m↑/↓ navegar · ←/→ trocar a IA · a adicionar · d remover\033[0m\033[K\n'
    _st_t '   \033[2mEnter abre o time no zellij · q sai sem abrir\033[0m\033[K\n'
  }
  _st_add() {
    local name backend role
    _st_t '\033[?25h\n'
    # o nome vira argumento de comando ('orchestra send <nome>'), por isso a regra
    # é estrita. Explicamos ANTES e deixamos tentar de novo, em vez de só recusar.
    while true; do
      printf '  nome do agente \033[2m— minúsculas, sem espaços e sem acentos (ex.: tester, deploy-prod)\033[0m\n  ▸ ' >/dev/tty
      read -r name </dev/tty || name=""
      case "$name" in
        '') printf '  \033[2mcancelado\033[0m\n' >/dev/tty; sleep 1; _st_t '\033[?25l'; return ;;
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
    # papel sem preset => o usuário descreve a função aqui mesmo
    local text=""
    case " $ORCHESTRA_ROLES " in
      *" $role "*) ;;
      *) printf '  o que ele faz? \033[2m— é isto que ensina a função a ele E diz ao líder\n' >/dev/tty
         printf '                  quando usá-lo (ex.: "Abre e atualiza Pull Requests via gh")\033[0m\n  ▸ ' >/dev/tty
         read -r text </dev/tty || text=""
         if [ -z "$text" ]; then
           printf '  \033[2m⚠️  sem descrição ele fica genérico; edite depois em .orchestra/prompts/%s.md\033[0m\n' "$name" >/dev/tty
           sleep 2
         fi ;;
    esac
    agent_add "$name" "$backend" "$role" "$text" >/dev/null 2>&1
    _st_load; _st_t '\033[?25l'
  }
  _st_del() {
    [ "$row" -lt "${#names[@]}" ] || return 0
    [ "${roles[$row]}" = leader ] && return 0
    agent_rm "${names[$row]}" >/dev/null 2>&1
    _st_load; [ "$row" -ge "$nrows" ] && row=$((nrows-1))
  }

  _st_load
  _st_t '\n\033[1m🎛️  Monte o time deste projeto\033[0m\n'
  _st_t '   \033[2m%s\033[0m\n\n' "$ORCHESTRA_PROJECT"
  _st_t '\033[?25l'
  trap 'printf "\033[?25h" >/dev/tty' RETURN INT
  # âncora do bloco: cada redesenho volta AQUI e apaga o que houver abaixo. Sem isto,
  # subir um número fixo de linhas erra a posição depois que o 'a'/'d' imprime perguntas,
  # e o menu aparece duplicado na tela.
  _st_t '\033[s'
  _st_render
  local quit=0
  while true; do
    IFS= read -rsn1 key </dev/tty || break
    case "$key" in
      $'\e')
        # Esc sozinho (sem sequência de seta depois) = sair
        k2=""
        read -rsn2 -t 0.05 k2 </dev/tty
        case "$k2" in
          '[A') row=$(( (row+nrows-1)%nrows )) ;;
          '[B') row=$(( (row+1)%nrows )) ;;
          '[C'|'[D') _st_cycle ;;
          '')   quit=1; break ;;
        esac ;;
      ' ')
        if   [ "$row" = "$(_st_row_add)" ];  then _st_add
        elif [ "$row" = "$(_st_row_quit)" ]; then quit=1; break
        else _st_cycle; fi ;;
      k|K) row=$(( (row+nrows-1)%nrows )) ;;
      j|J) row=$(( (row+1)%nrows )) ;;
      h|H|l|L) _st_cycle ;;
      a|A) _st_add ;;
      d|D) _st_del ;;
      q|Q) quit=1; break ;;
      '')
        if   [ "$row" = "$(_st_row_add)" ];  then _st_add
        elif [ "$row" = "$(_st_row_quit)" ]; then quit=1; break
        else break; fi ;;
    esac
    _st_render
  done
  _st_t '\033[?25h\n'
  trap - RETURN INT

  # saiu pelo "sair": descarta as trocas de backend feitas na tela e sinaliza
  # cancelamento a quem chamou (o 'up' não abre o zellij).
  if [ "$quit" = 1 ]; then
    unset -f _st_t _st_cycle _st_render _st_load _st_add _st_del _st_row_add _st_row_quit
    return 2
  fi

  # persiste as escolhas
  local specs=()
  for i in "${!names[@]}"; do specs+=("${names[$i]}=${backends[$i]}:${roles[$i]}"); done
  team_replace "${specs[@]}"
  unset -f _st_t _st_cycle _st_render _st_load _st_add _st_del _st_row_add _st_row_quit
}

# ---------------------------------------------------------------------------
# Diagnóstico
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
    _dwarn "nenhuma sessão ativa (sobe ao rodar 'orchestra up')"
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
  echo "   (o .orchestra/ dos seus projetos foi preservado — é a composição do time.)"
  echo "   (zellij, Claude Code, OpenCode e Codex foram preservados.)"
}
