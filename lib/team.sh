#!/usr/bin/env bash
# Orchestra Agents — modelo do TIME (líder + N agentes), por projeto.
#
# O time vive em <projeto>/.orchestra/team.json. Cada agente tem:
#   name    — identificador usado em 'orchestra send <name>'
#   backend — claude | opencode | codex
#   role    — preset (coder, reviewer, tester, docs, architect, devops) ou 'custom'
#   prompt_file — só p/ role=custom: caminho relativo ao projeto
#
# Não executar diretamente; é "sourced" pelo lib/core.sh.

ORCHESTRA_BACKENDS="claude opencode codex"
ORCHESTRA_ROLES="coder reviewer tester docs architect devops"

# ícone + descrição curta de cada papel (usados no menu, no layout e no roster do líder)
role_icon() {
  case "$1" in
    leader)    echo "🎼" ;; coder)  echo "🔧" ;; reviewer)  echo "🔍" ;;
    tester)    echo "🧪" ;; docs)   echo "📚" ;; architect) echo "📐" ;;
    devops)    echo "🚀" ;; *)      echo "✨" ;;
  esac
}
role_desc() {
  case "$1" in
    leader)    echo "orquestra o time" ;;
    coder)     echo "implementa código" ;;
    reviewer)  echo "code review (read-only)" ;;
    tester)    echo "escreve e roda testes" ;;
    docs)      echo "documentação e READMEs" ;;
    architect) echo "arquitetura e decisões de design" ;;
    devops)    echo "build, CI/CD e infraestrutura" ;;
    *)         echo "agente customizado" ;;
  esac
}

# Rótulo PADRONIZADO do painel de um agente: ícone do papel + NOME EM MAIÚSCULAS.
# Fonte única — usada pelo layout gerado, pelos painéis criados em runtime e pelo
# menu, para que um agente criado na hora fique igual aos que vieram do layout.
pane_label() { # $1 agente
  local r
  if [ "$1" = leader ]; then printf '%s LÍDER' "$(role_icon leader)"; return 0; fi
  r="$(team_field "$1" role)"
  printf '%s %s' "$(role_icon "$r")" "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
}

# Descrição curta da FUNÇÃO de um agente, para o usuário entender o time de relance.
# Papéis prontos usam role_desc; agentes custom mostram a 1ª linha do prompt que o
# usuário escreveu — é o que ele reconhece, muito melhor que "agente customizado".
role_summary() { # $1 agente
  local r pf f line=""
  if [ "$1" = leader ]; then role_desc leader; return 0; fi
  r="$(team_field "$1" role)"
  if [ "$r" != custom ]; then role_desc "$r"; return 0; fi
  pf="$(team_field "$1" prompt_file)"
  if [ -n "$pf" ]; then
    f="$pf"; case "$f" in /*) ;; *) f="$ORCHESTRA_PROJECT/$f" ;; esac
    line="$(sed -n '2,$p' "$f" 2>/dev/null | sed '/^$/d' | head -1)"
  fi
  [ -n "$line" ] || line="$(role_desc custom)"
  printf '%s' "$line"
}

team_file()    { echo "$ORCHESTRA_DIR/team.json"; }
team_prompts() { echo "$ORCHESTRA_DIR/prompts"; }

# roda um trecho python com o team.json no stdin e o caminho no argv[1]
_team_py() { # $1 script python  $@ args extras
  local script="$1"; shift
  python3 -c "$script" "$(team_file)" "$@" 2>/dev/null
}

_TEAM_LOAD='
import sys, json, os
path = sys.argv[1]
try:
    team = json.load(open(path))
except Exception:
    team = {"version": 1, "leader": {"name": "leader", "backend": "claude", "role": "leader"}, "agents": []}
team.setdefault("version", 1)
team.setdefault("leader", {"name": "leader", "backend": "claude", "role": "leader"})
team.setdefault("agents", [])
def save():
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(team, f, indent=2, ensure_ascii=False)
        f.write("\n")
def find(name):
    if name == team["leader"]["name"] or name == "leader":
        return team["leader"]
    for a in team["agents"]:
        if a.get("name") == name:
            return a
    return None
'

# cria o time padrão se ainda não existir (líder claude + coder + reviewer)
team_ensure() {
  [ -f "$(team_file)" ] && return 0
  mkdir -p "$ORCHESTRA_DIR"
  cat >"$(team_file)" <<'JSON'
{
  "version": 1,
  "leader": { "name": "leader", "backend": "claude", "role": "leader" },
  "agents": [
    { "name": "coder", "backend": "opencode", "role": "coder" },
    { "name": "reviewer", "backend": "opencode", "role": "reviewer" }
  ]
}
JSON
}

# nomes dos agentes (workers), um por linha, na ordem do arquivo
team_names() {
  _team_py "$_TEAM_LOAD"'
for a in team["agents"]:
    print(a.get("name",""))
'
}

# nomes incluindo o líder (primeiro)
team_all_names() {
  _team_py "$_TEAM_LOAD"'
print(team["leader"].get("name","leader"))
for a in team["agents"]:
    print(a.get("name",""))
'
}

team_exists() { # $1 nome
  [ -n "${1:-}" ] || return 1
  team_all_names | grep -qx -- "$1"
}

# lê um campo de um agente (backend|role|prompt_file|name)
team_field() { # $1 nome  $2 campo
  _team_py "$_TEAM_LOAD"'
a = find(sys.argv[2])
print((a or {}).get(sys.argv[3], "") or "")
' "$1" "$2"
}

team_set() { # $1 nome  $2 campo  $3 valor
  _team_py "$_TEAM_LOAD"'
a = find(sys.argv[2])
if a is None:
    raise SystemExit(1)
a[sys.argv[3]] = sys.argv[4]
save()
' "$1" "$2" "$3"
}

team_add() { # $1 nome  $2 backend  $3 role  [$4 prompt_file]
  _team_py "$_TEAM_LOAD"'
name, backend, role = sys.argv[2], sys.argv[3], sys.argv[4]
pf = sys.argv[5] if len(sys.argv) > 5 else ""
if find(name) is not None:
    raise SystemExit(2)
entry = {"name": name, "backend": backend, "role": role}
if pf:
    entry["prompt_file"] = pf
team["agents"].append(entry)
save()
' "$1" "$2" "$3" "${4:-}"
}

team_rm() { # $1 nome
  _team_py "$_TEAM_LOAD"'
name = sys.argv[2]
before = len(team["agents"])
team["agents"] = [a for a in team["agents"] if a.get("name") != name]
if len(team["agents"]) == before:
    raise SystemExit(1)
save()
' "$1"
}

# substitui a lista inteira a partir de "nome=backend:role" separados por espaço
team_replace() { # $@ specs
  _team_py "$_TEAM_LOAD"'
specs = sys.argv[2:]
agents = []
for s in specs:
    name, _, rest = s.partition("=")
    backend, _, role = rest.partition(":")
    if name == "leader":
        team["leader"] = {"name": "leader", "backend": backend, "role": "leader"}
        continue
    old = find(name) or {}
    entry = {"name": name, "backend": backend, "role": role or old.get("role") or "custom"}
    if old.get("prompt_file"):
        entry["prompt_file"] = old["prompt_file"]
    agents.append(entry)
team["agents"] = agents
save()
' "$@"
}

# valida um nome de agente (slug seguro p/ nome de arquivo e argumento de shell)
team_valid_name() { # $1 nome
  [[ "${1:-}" =~ ^[a-z][a-z0-9_-]{0,23}$ ]] || return 1
  case "$1" in leader) return 1 ;; esac   # reservado
}

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------

# protocolo de resposta — comum a TODOS os workers, qualquer backend.
# É o que fecha o ciclo: o líder despacha injetando texto no painel e recebe a
# resposta quando o worker executa 'orchestra done'.
team_worker_protocol() { # $1 nome
  cat <<EOF

## Limites (obrigatório)

- Trabalhe SOMENTE dentro do diretório do projeto onde este painel foi aberto:
  \`$ORCHESTRA_PROJECT\`
- NUNCA edite a instalação do Orchestra (\`$ORCHESTRA_HOME\`, \`~/.orchestra-agents\`)
  nem arquivos de outros projetos. Você usa o Orchestra; não o modifica.
- A ÚNICA exceção é quando o projeto acima FOR o próprio código do Orchestra e a tarefa
  pedir isso explicitamente — ainda assim, mexa apenas nos arquivos do projeto, nunca na
  cópia instalada.

## Ao iniciar — NÃO comece a trabalhar

Estas instruções podem ter chegado como a PRIMEIRA MENSAGEM deste painel (é assim que
OpenCode e Codex recebem). Elas descrevem quem você é; **não são uma tarefa**.

Agora, ao lê-las: não analise o repositório, não rode comandos, não edite nada.
Responda apenas UMA linha curta se apresentando — por exemplo: \`pronto, aguardando o líder\`.

Você só age quando:
- chegar uma mensagem com o bloco \`[ORCHESTRA task=<id>]\` (tarefa do líder); ou
- o usuário falar diretamente com você neste painel.

## Protocolo do Orchestra (obrigatório)

Você recebe tarefas do LÍDER como mensagens que terminam com um bloco
\`[ORCHESTRA task=<id>]\`. Ao CONCLUIR cada uma dessas tarefas, execute no shell:

    orchestra done $1 <id> <<'ORCHESTRA_EOF'
    <sua resposta final, completa>
    ORCHESTRA_EOF

Use o \`<id>\` exato que veio na tarefa. Sem esse comando o líder fica esperando e
a tarefa expira por timeout. Mensagens digitadas pelo usuário direto no seu painel
(sem o bloco \`[ORCHESTRA task=...]\`) NÃO precisam do \`orchestra done\`.

---

**Agora**: nenhuma tarefa foi pedida ainda. Apresente-se em uma linha e aguarde.
EOF
}

# texto de instruções de um agente: preset em agents/roles/<role>.md, ou o
# prompt_file do projeto quando role=custom. Sempre acrescido do protocolo.
team_prompt_for() { # $1 nome
  local name="$1" role pf f
  role="$(team_field "$name" role)"
  pf="$(team_field "$name" prompt_file)"
  if [ -n "$pf" ]; then
    f="$pf"; case "$f" in /*) ;; *) f="$ORCHESTRA_PROJECT/$f" ;; esac
  else
    f="$ORCHESTRA_HOME/agents/roles/${role}.md"
  fi
  if [ -f "$f" ]; then cat "$f"
  else echo "Você é o agente '$name' do Orchestra ($(role_desc "$role"))."; fi
  team_worker_protocol "$name"
}

# roster legível do time — anexado ao prompt do líder para que ele conheça os
# agentes que existem DE VERDADE (e não uma lista hardcoded).
team_roster() {
  local n b r
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    b="$(team_field "$n" backend)"; r="$(team_field "$n" role)"
    # role_summary (e NÃO role_desc): para agentes custom, role_desc devolve só
    # "agente customizado" e o líder fica sem saber quando usar aquele agente.
    printf -- '- %s %s (%s) — %s\n' "$(role_icon "$r")" \
      "$(printf '%s' "$n" | tr '[:lower:]' '[:upper:]')" "$b" "$(role_summary "$n")"
  done < <(team_names)
}

# prompt completo do líder = base + roster real do time
team_leader_prompt() {
  local base="$ORCHESTRA_HOME/agents/leader-prompt.md"
  [ -f "$base" ] && cat "$base"
  printf '\n\n## Seu time NESTE projeto\n\n'
  team_roster
  printf '\nDelegue com `orchestra send <nome> "<tarefa>"` e busque o resultado com\n'
  printf '`orchestra await <nome>`. Use SOMENTE os nomes listados acima.\n'
  printf 'Consulte o time a qualquer momento com `orchestra agents`.\n'
}
