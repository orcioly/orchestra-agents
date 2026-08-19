#!/usr/bin/env bash
# Smoke test do Orchestra Agents.
#
# Valida sintaxe, o modelo do time, o ciclo completo de despacho/resposta e os
# exit codes — tudo com o multiplexador em modo 'stub', para rodar em CI sem
# zellij e sem gastar token de nenhum backend.
#
# uso:  ./tests/smoke.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export ORCHESTRA_HOME="$ROOT"
export ORCHESTRA_STATE="$(mktemp -d)"
export ORCHESTRA_PROJECT="$(mktemp -d)"
export ORCHESTRA_MUX=stub
ORCH="$ROOT/bin/orchestra"
trap 'rm -rf "$ORCHESTRA_STATE" "$ORCHESTRA_PROJECT"' EXIT

pass=0; fail=0; skip=0
ok(){   printf '  \033[1;32mPASS\033[0m %s\n' "$*"; pass=$((pass+1)); }
no(){   printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
skipt(){ printf '  \033[1;33mSKIP\033[0m %s\n' "$*"; skip=$((skip+1)); }

printf '\n🔬 Orchestra Agents — smoke test\n\n'

# ---------------------------------------------------------------------------
echo "1) Sintaxe dos scripts"
syn_ok=1
for f in "$ROOT/bin/orchestra" "$ROOT"/lib/*.sh "$ROOT"/agents/*.sh \
         "$ROOT"/scripts/*.sh "$ROOT/install.sh" "$ROOT/uninstall.sh" "$ROOT/tests/smoke.sh"; do
  bash -n "$f" 2>/dev/null || { no "sintaxe inválida: $f"; syn_ok=0; }
done
[ "$syn_ok" = 1 ] && ok "todos os scripts passaram no bash -n"

if python3 -m py_compile "$ROOT/config/merge_reviewer.py" 2>/dev/null; then
  ok "config/merge_reviewer.py compila (py_compile)"
else
  no "config/merge_reviewer.py falhou no py_compile"
fi

# carrega o núcleo (depois do check de sintaxe)
# shellcheck source=/dev/null
. "$ROOT/lib/core.sh"

# ---------------------------------------------------------------------------
echo "2) Modelo do time (team.json)"
team_ensure
t_ok=1
[ -f "$(team_file)" ] || { no "team.json não foi criado"; t_ok=0; }
[ "$(team_field leader backend)" = claude ] || { no "líder default deveria ser claude"; t_ok=0; }
[ "$(team_names | tr '\n' ' ')" = "coder reviewer " ] || { no "time default deveria ser 'coder reviewer'"; t_ok=0; }
team_exists coder     || { no "team_exists coder falhou"; t_ok=0; }
team_exists leader    || { no "team_exists leader falhou"; t_ok=0; }
team_exists fantasma  && { no "team_exists aceitou agente inexistente"; t_ok=0; }
team_valid_name "tester"  || { no "nome válido rejeitado"; t_ok=0; }
team_valid_name "leader"  && { no "'leader' deveria ser reservado"; t_ok=0; }
team_valid_name "Tester"  && { no "nome com maiúscula deveria ser rejeitado"; t_ok=0; }
team_valid_name "a b"     && { no "nome com espaço deveria ser rejeitado"; t_ok=0; }
[ "$t_ok" = 1 ] && ok "team.json: criação, campos, validação de nome"

echo "3) Composição por env (CI, sem TTY)"
e_ok=1
( ORCHESTRA_CODER=codex ORCHESTRA_REVIEWER=claude; _apply_team_env ) >/dev/null 2>&1
[ "$(team_field coder backend)" = codex ]     || { no "alias ORCHESTRA_CODER não aplicou"; e_ok=0; }
[ "$(team_field reviewer backend)" = claude ] || { no "alias ORCHESTRA_REVIEWER não aplicou"; e_ok=0; }
( ORCHESTRA_TEAM="leader=codex,coder=opencode"; _apply_team_env ) >/dev/null 2>&1
[ "$(team_field leader backend)" = codex ]    || { no "ORCHESTRA_TEAM não trocou o líder"; e_ok=0; }
[ "$(team_field coder backend)" = opencode ]  || { no "ORCHESTRA_TEAM não trocou o coder"; e_ok=0; }
# sufixo ':papel' — um nome livre deve poder herdar um preset
( ORCHESTRA_TEAM="qa=claude:tester"; _apply_team_env ) >/dev/null 2>&1
[ "$(team_field qa role)" = tester ] || { no "ORCHESTRA_TEAM ignorou o sufixo ':papel'"; e_ok=0; }
# nome sem preset criado por env deve virar custom COM prompt editável
( ORCHESTRA_TEAM="seguranca=claude"; _apply_team_env ) >/dev/null 2>&1
[ "$(team_field seguranca role)" = custom ] || { no "agente por env sem preset deveria ser custom"; e_ok=0; }
[ -f "$ORCHESTRA_PROJECT/.orchestra/prompts/seguranca.md" ] \
  || { no "agente custom por env ficou sem arquivo de prompt"; e_ok=0; }
"$ORCH" rm qa >/dev/null 2>&1; "$ORCH" rm seguranca >/dev/null 2>&1
team_set leader backend claude >/dev/null 2>&1
[ "$e_ok" = 1 ] && ok "ORCHESTRA_TEAM e aliases herdados aplicam sem TTY"

echo "4) Agentes dinâmicos (add/rm)"
a_ok=1
"$ORCH" add tester --backend claude --role tester >/dev/null 2>&1 || { no "add tester falhou"; a_ok=0; }
team_exists tester || { no "tester não entrou no time"; a_ok=0; }
[ "$(team_field tester role)" = tester ] || { no "papel do tester incorreto"; a_ok=0; }
"$ORCH" add seo --backend claude >/dev/null 2>&1 || { no "add custom falhou"; a_ok=0; }
[ "$(team_field seo role)" = custom ] || { no "agente sem preset deveria virar custom"; a_ok=0; }
[ -f "$ORCHESTRA_PROJECT/.orchestra/prompts/seo.md" ] || { no "prompt do agente custom não foi criado"; a_ok=0; }
"$ORCH" add tester >/dev/null 2>&1 && { no "add duplicado deveria falhar"; a_ok=0; }
"$ORCH" add "Nome Inválido" >/dev/null 2>&1 && { no "add com nome inválido deveria falhar"; a_ok=0; }
# o motivo precisa ser dito ao usuário, não só recusado.
# (sem pipe: 'set -o pipefail' + exit 1 do comando derrubaria a asserção)
msg="$("$ORCH" add "deploy prod" 2>&1 || true)"
case "$msg" in *'não pode ter espaços'*) ;; *) no "erro de nome com espaço deveria explicar a regra"; a_ok=0 ;; esac
msg="$("$ORCH" add leader 2>&1 || true)"
case "$msg" in *reservado*) ;; *) no "erro de nome reservado deveria explicar"; a_ok=0 ;; esac
# colunas alinhadas: nome longo é truncado, nunca encosta na coluna seguinte
"$ORCH" add um-nome-bem-longo-mesmo --backend claude >/dev/null 2>&1
agents_list | sed 's/\x1b\[[0-9;]*m//g' | grep -q 'UM-NOME-B…' \
  || { no "nome longo deveria ser truncado na tabela"; a_ok=0; }
"$ORCH" rm um-nome-bem-longo-mesmo >/dev/null 2>&1
"$ORCH" rm seo >/dev/null 2>&1 || { no "rm seo falhou"; a_ok=0; }
team_exists seo && { no "seo continuou no time após rm"; a_ok=0; }
# --prompt: função definida na criação, sem editar arquivo depois
"$ORCH" add gitops --backend claude --prompt "Só faz commit e push." >/dev/null 2>&1 \
  || { no "add --prompt falhou"; a_ok=0; }
[ "$(team_field gitops role)" = custom ] || { no "--prompt deveria criar agente custom"; a_ok=0; }
grep -q 'Só faz commit e push.' "$ORCHESTRA_PROJECT/.orchestra/prompts/gitops.md" 2>/dev/null \
  || { no "--prompt não gravou as instruções do usuário"; a_ok=0; }
case "$(team_prompt_for gitops)" in
  *'orchestra done gitops'*) ;;
  *) no "agente custom por --prompt ficou sem o protocolo"; a_ok=0 ;;
esac
"$ORCH" rm gitops >/dev/null 2>&1
"$ORCH" rm leader >/dev/null 2>&1 && { no "remover o líder deveria falhar"; a_ok=0; }
[ "$a_ok" = 1 ] && ok "add/rm, presets, agente custom e validações"

echo "5) Prompt de papel e roster do líder"
# nota: capturamos em variável em vez de "| grep -q" — com 'pipefail' o produtor
# morre de SIGPIPE quando o grep sai no primeiro match, e o teste falharia à toa.
p_ok=1
prompt_out="$(team_prompt_for tester)"
leader_out="$(team_leader_prompt)"
case "$prompt_out" in *TESTER*)          ;; *) no "prompt de papel não carregou"; p_ok=0 ;; esac
case "$prompt_out" in *"orchestra done"*) ;; *) no "protocolo não foi anexado ao prompt"; p_ok=0 ;; esac
case "$leader_out" in *coder*)           ;; *) no "roster do líder não lista os agentes"; p_ok=0 ;; esac
case "$leader_out" in *tester*)          ;; *) no "roster do líder não reflete agentes novos"; p_ok=0 ;; esac
[ "$p_ok" = 1 ] && ok "prompts de papel + protocolo + roster dinâmico"

# o líder não pode editar arquivos: quem implementa é o coder
grep -q -- '--disallowedTools Edit Write' "$ROOT/agents/run-agent.sh" \
  || no "o líder Claude deveria subir sem as ferramentas de escrita"

# a IA é escolha do usuário: sem --ia e sem terminal, o add FALHA em vez de assumir 'claude'
msg="$("$ORCH" add semia --prompt "x" </dev/null 2>&1 || true)"
case "$msg" in *'falta dizer qual IA'*) ;; *) no "add sem --ia deveria falhar pedindo a IA" ;; esac
team_exists semia && no "add sem --ia não deveria ter criado o agente"

# nenhum agente pode editar a instalação do Orchestra nem sair do projeto
case "$(team_prompt_for coder)" in
  *'NUNCA edite a instalação do Orchestra'*) ;;
  *) no "o prompt de todo worker deveria proibir editar a instalação do Orchestra" ;;
esac
case "$(team_leader_prompt)" in
  *'Criar agente NÃO é programar'*) ;;
  *) no "o líder deveria ser instruído a criar agentes por comando, não por código" ;;
esac
case "$(team_leader_prompt)" in
  *'PERGUNTE ao usuário qual IA'*) ;;
  *) no "o líder deveria perguntar a IA antes de criar um agente" ;;
esac

# o líder tem de ser avisado AO VIVO quando o time muda, sem o usuário digitar nada
mux_new_pane leader "$ORCHESTRA_PROJECT" >/dev/null 2>&1
: > "$ORCHESTRA_RUN_DIR/leader.tx" 2>/dev/null
"$ORCH" add avisado --ia claude --prompt "Cuida de deploys." >/dev/null 2>&1
case "$(cat "$ORCHESTRA_RUN_DIR/leader.tx" 2>/dev/null)" in
  *"o agente 'avisado' entrou"*) ;;
  *) no "o líder deveria ser avisado ao vivo quando um agente entra" ;;
esac
case "$(cat "$ORCHESTRA_RUN_DIR/leader.tx" 2>/dev/null)" in
  *'Cuida de deploys.'*) ;;
  *) no "o aviso ao líder deveria conter a função do agente novo" ;;
esac
: > "$ORCHESTRA_RUN_DIR/leader.tx"
"$ORCH" rm avisado >/dev/null 2>&1
case "$(cat "$ORCHESTRA_RUN_DIR/leader.tx" 2>/dev/null)" in
  *"o agente 'avisado' saiu"*) ;;
  *) no "o líder deveria ser avisado quando um agente sai" ;;
esac

# o líder precisa saber PARA QUE serve cada agente custom, senão não roteia
"$ORCH" add pr --ia claude --prompt "Abre e atualiza Pull Requests via gh." >/dev/null 2>&1
case "$(team_roster)" in
  *'Abre e atualiza Pull Requests'*) ;;
  *) no "roster do líder deveria descrever o agente custom, não 'agente customizado'" ;;
esac
# sem pipe: 'grep -q' fecha o pipe no primeiro casamento e o SIGPIPE do produtor
# vira falha por causa do 'set -o pipefail'
case "$(team_prompt_for pr)" in
  *'Abre e atualiza Pull Requests'*) ;;
  *) no "o agente custom deveria receber a própria descrição no prompt" ;;
esac
msg="$("$ORCH" add semdesc --ia claude 2>&1 || true)"
case "$msg" in *'ainda não tem especialidade'*) ;; *) no "criar custom sem descrição deveria avisar" ;; esac
"$ORCH" rm pr >/dev/null 2>&1; "$ORCH" rm semdesc >/dev/null 2>&1

echo "6) Ciclo completo: send → done → await"
c_ok=1
"$ORCH" send tester "rode os testes" >/dev/null 2>&1 || { no "send falhou"; c_ok=0; }
TASK="$(cat "$ORCHESTRA_PROJECT/.orchestra/run/tester.task" 2>/dev/null)"
[ -n "$TASK" ] || { no "task id não foi gravado"; c_ok=0; }
[ "$(cat "$ORCHESTRA_PROJECT/.orchestra/run/tester.status" 2>/dev/null)" = running ] \
  || { no "status deveria ser 'running' após o send"; c_ok=0; }
grep -q "ORCHESTRA task=$TASK" "$ORCHESTRA_PROJECT/.orchestra/run/tester.tx" 2>/dev/null \
  || { no "o rodapé com o task id não foi injetado no painel"; c_ok=0; }
grep -q "rode os testes" "$ORCHESTRA_PROJECT/.orchestra/run/tester.tx" 2>/dev/null \
  || { no "a tarefa não foi injetada no painel"; c_ok=0; }
echo "resposta errada" | "$ORCH" done tester TASK-ERRADA >/dev/null 2>&1 \
  && { no "done com task divergente deveria ser recusado"; c_ok=0; }
printf 'tudo verde\n' | "$ORCH" done tester "$TASK" >/dev/null 2>&1 || { no "done falhou"; c_ok=0; }
out="$("$ORCH" await tester 10 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] || { no "await deveria sair 0 após o done (saiu $rc)"; c_ok=0; }
[ "$out" = "tudo verde" ] || { no "await devolveu '$out' em vez da resposta"; c_ok=0; }
res_out="$("$ORCH" result tester 2>/dev/null)"
case "$res_out" in *"tudo verde"*) ;; *) no "result não-bloqueante falhou"; c_ok=0 ;; esac
[ "$c_ok" = 1 ] && ok "send → done → await devolve a resposta com exit 0"

echo "7) Exit codes"
x_ok=1
"$ORCH" send fantasma "oi" >/dev/null 2>&1; [ "$?" = 1 ] || { no "send p/ agente inexistente deveria ser exit 1"; x_ok=0; }
"$ORCH" await tester abc  >/dev/null 2>&1; [ "$?" = 1 ] || { no "timeout não-numérico deveria ser exit 1"; x_ok=0; }
"$ORCH" await             >/dev/null 2>&1; [ "$?" = 1 ] || { no "await sem agente deveria ser exit 1"; x_ok=0; }
"$ORCH" send tester "outra tarefa" >/dev/null 2>&1
out="$("$ORCH" await tester 4 2>/dev/null)"; rc=$?
[ "$rc" = 2 ] || { no "await sem resposta deveria ser exit 2 (saiu $rc)"; x_ok=0; }
case "$out" in "[TIMEOUT/PARCIAL]"*) ;; *) no "timeout deveria prefixar com [TIMEOUT/PARCIAL]"; x_ok=0 ;; esac
[ "$x_ok" = 1 ] && ok "exit codes: 1 validação · 2 timeout com [TIMEOUT/PARCIAL]"

echo "8) Layout gerado"
l_ok=1
lay="$(generate_layout)"
[ -f "$lay" ] || { no "layout não foi gerado"; l_ok=0; }
grep -q 'run-agent.sh leader' "$lay" || { no "layout não abre o painel do líder"; l_ok=0; }
grep -q 'run-agent.sh coder'  "$lay" || { no "layout não abre o painel do coder"; l_ok=0; }
grep -q 'run-agent.sh tester' "$lay" || { no "layout não reflete agentes adicionados"; l_ok=0; }
for extra in a1 a2 a3 a4; do "$ORCH" add "$extra" --backend claude >/dev/null 2>&1; done
lay="$(generate_layout)"
grep -q 'run-agent.sh a4' "$lay" || { no "layout de time grande perdeu agentes"; l_ok=0; }
[ "$(grep -c 'split_direction="vertical"' "$lay")" -ge 2 ] || { no "time grande deveria virar 2 fileiras"; l_ok=0; }
for extra in a1 a2 a3 a4; do "$ORCH" rm "$extra" >/dev/null 2>&1; done
[ "$l_ok" = 1 ] && ok "layout KDL gerado para times pequenos e grandes"

echo "9) Protocolo e rótulos padronizados"
p_ok=1
# regressão: com --agent, o OpenCode usa o prompt DELE (sem o protocolo do
# Orchestra). O prompt de papel precisa ir SEMPRE, senão o worker nunca
# executa 'orchestra done' e todo despacho morre em timeout.
grep -q -- '--prompt "$PROMPT" "$PROJ"' "$ROOT/agents/run-agent.sh" \
  || { no "launch_opencode deveria enviar sempre o prompt de papel"; p_ok=0; }
if grep -q 'elif \[ "$1" = first \]; then' "$ROOT/agents/run-agent.sh"; then
  no "launch_opencode voltou a tornar o prompt condicional ao --agent"; p_ok=0
fi
# rótulo de painel: ícone + NOME EM MAIÚSCULAS, igual para layout e runtime
[ "$(pane_label leader)" = "🎼 LÍDER" ] || { no "rótulo do líder fora do padrão"; p_ok=0; }
"$ORCH" add zeta --backend claude >/dev/null 2>&1
case "$(pane_label zeta)" in *ZETA) ;; *) no "nome de agente deveria aparecer em MAIÚSCULAS"; p_ok=0 ;; esac
grep -q 'pane_label' "$ROOT/lib/mux.sh" \
  || { no "painel criado em runtime não usa o rótulo padronizado"; p_ok=0; }
# o agente novo tem de aparecer na MESMA tela dos outros
grep -q -- '--tab-id' "$ROOT/lib/mux.sh" \
  || { no "painel novo deveria ser ancorado na aba do líder (--tab-id)"; p_ok=0; }
if grep -E 'new-pane.*(--floating|[[:space:]]-f[[:space:]])' "$ROOT/lib/mux.sh" >/dev/null 2>&1; then
  no "painel do time nunca pode ser flutuante (cobre os outros em vez de dividir a tela)"; p_ok=0
fi
# 'focus-pane-id' é no-op quando chamado de fora da sessão (zellij 0.44.3):
# fechar "o painel em foco" depois dele fecharia o painel ERRADO (o do líder).
grep -q 'close-pane -p' "$ROOT/lib/mux.sh" \
  || { no "fechar painel deve mirar o id (close-pane -p), nunca o painel em foco"; p_ok=0; }
if grep -E 'focus-pane-id.*\|\| return|focus-pane-id "\$1"' "$ROOT/lib/mux.sh" >/dev/null 2>&1; then
  no "focus-pane-id não move o foco remotamente — não usar para mirar painel"; p_ok=0
fi
grep -q 'focus-next-pane' "$ROOT/lib/mux.sh" \
  || { no "mirar painel precisa ciclar com focus-next-pane"; p_ok=0; }
lay2="$(generate_layout)"
grep -q 'pane name="✨ ZETA"' "$lay2" || { no "layout não usou o rótulo padronizado"; p_ok=0; }
"$ORCH" rm zeta >/dev/null 2>&1
[ "$p_ok" = 1 ] && ok "prompt de papel sempre enviado + rótulos ícone/MAIÚSCULAS"

echo "10) Lançamento do zellij"
z_ok=1
# regressão: com '--session', o '--layout' do zellij significa "adicione como aba à
# sessão existente" e falha com "Session not found". Só o '-n' cria a sessão.
grep -q 'exec zellij -s "\$sess" -n "\$layout"' "$ORCH" \
  || { no "o 'up' deveria lançar o zellij com -n (new-session-with-layout)"; z_ok=0; }
if grep -E 'exec zellij .*--layout' "$ORCH" >/dev/null 2>&1; then
  no "o 'up' voltou a usar --layout junto com -s (não cria a sessão)"; z_ok=0
fi
# regressão: 'basename | tr -c' converte o \n final em '-' e duplica o hífen
sess_test="orchestra-$(printf '%s' "$(basename /tmp/proj-x)" | tr -c 'a-zA-Z0-9_-' '-')-1"
case "$sess_test" in *--*) no "nome de sessão com hífen duplo"; z_ok=0 ;; esac
[ "$z_ok" = 1 ] && ok "zellij é lançado com -n e o nome de sessão é limpo"

echo "11) orchestra doctor"
if "$ORCH" doctor >/dev/null 2>&1; then ok "doctor sem falhas (exit 0)"
else skipt "doctor com falhas — esperado se claude/opencode/codex não estão neste host"; fi

# ---------------------------------------------------------------------------
printf '\nResultado: \033[1;32m%d passou\033[0m · \033[1;31m%d falhou\033[0m · \033[1;33m%d pulado\033[0m\n\n' \
  "$pass" "$fail" "$skip"
[ "$fail" = 0 ] || exit 1
