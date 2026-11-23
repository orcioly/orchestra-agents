#!/usr/bin/env bash
# Smoke test for Orchestra Agents.
#
# Validates syntax, the team model, the complete dispatch/reply cycle and the
# exit codes — all with the multiplexer in 'stub' mode, to run in CI without
# zellij and without spending any backend's tokens.
#
# usage:  ./tests/smoke.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export ORCHESTRA_HOME="$ROOT"
export ORCHESTRA_STATE="$(mktemp -d)"
export ORCHESTRA_PROJECT="$(mktemp -d)"
export ORCHESTRA_MUX=stub
ORCH="$ROOT/bin/orchestra"

# Orchestra project directory. It NO LONGER lives inside the user's project:
# we ask the lib itself where it is, so the test does not duplicate the slug rule.
ODIR="$(. "$ROOT/lib/core.sh" >/dev/null 2>&1; echo "$ORCHESTRA_DIR")"

# FAKE backends on the PATH. 'agent_add' refuses an IA that is not installed, so
# without this the suite only passes on a machine that has claude+opencode+codex — that is what
# broke CI. The stubs are never executed: the tests run with the 'stub'
# multiplexer and no real pane comes up.
FAKEBIN="$ORCHESTRA_STATE/fakebin"; mkdir -p "$FAKEBIN"
for b in claude opencode codex; do
  printf '#!/bin/sh\necho "stub de teste: %s"\n' "$b" >"$FAKEBIN/$b"
  chmod +x "$FAKEBIN/$b"
done
export PATH="$FAKEBIN:$PATH"
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

# loads the core (after the syntax check)
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
# ':role' suffix — a free name must be able to inherit a preset
( ORCHESTRA_TEAM="qa=claude:tester"; _apply_team_env ) >/dev/null 2>&1
[ "$(team_field qa role)" = tester ] || { no "ORCHESTRA_TEAM ignorou o sufixo ':papel'"; e_ok=0; }
# a name without a preset created via env must become custom WITH an editable prompt
( ORCHESTRA_TEAM="seguranca=claude"; _apply_team_env ) >/dev/null 2>&1
[ "$(team_field seguranca role)" = custom ] || { no "agente por env sem preset deveria ser custom"; e_ok=0; }
[ -f "$ODIR/prompts/seguranca.md" ] \
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
[ -f "$ODIR/prompts/seo.md" ] || { no "prompt do agente custom não foi criado"; a_ok=0; }
"$ORCH" add tester >/dev/null 2>&1 && { no "add duplicado deveria falhar"; a_ok=0; }
"$ORCH" add "Nome Inválido" >/dev/null 2>&1 && { no "add com nome inválido deveria falhar"; a_ok=0; }
# the reason must be stated to the user, not just refused.
# (no pipe: 'set -o pipefail' + the command's exit 1 would break the assertion)
msg="$("$ORCH" add "deploy prod" 2>&1 || true)"
case "$msg" in *'não pode ter espaços'*) ;; *) no "erro de nome com espaço deveria explicar a regra"; a_ok=0 ;; esac
msg="$("$ORCH" add leader 2>&1 || true)"
case "$msg" in *reservado*) ;; *) no "erro de nome reservado deveria explicar"; a_ok=0 ;; esac
# aligned columns: a long name is truncated, never touches the next column
"$ORCH" add um-nome-bem-longo-mesmo --backend claude >/dev/null 2>&1
agents_list | sed 's/\x1b\[[0-9;]*m//g' | grep -q 'UM-NOME-B…' \
  || { no "nome longo deveria ser truncado na tabela"; a_ok=0; }
"$ORCH" rm um-nome-bem-longo-mesmo >/dev/null 2>&1
"$ORCH" rm seo >/dev/null 2>&1 || { no "rm seo falhou"; a_ok=0; }
team_exists seo && { no "seo continuou no time após rm"; a_ok=0; }
# --prompt: role defined at creation, without editing a file afterwards
"$ORCH" add gitops --backend claude --prompt "Só faz commit e push." >/dev/null 2>&1 \
  || { no "add --prompt falhou"; a_ok=0; }
[ "$(team_field gitops role)" = custom ] || { no "--prompt deveria criar agente custom"; a_ok=0; }
grep -q 'Só faz commit e push.' "$ODIR/prompts/gitops.md" 2>/dev/null \
  || { no "--prompt não gravou as instruções do usuário"; a_ok=0; }
case "$(team_prompt_for gitops)" in
  *'orchestra done gitops'*) ;;
  *) no "agente custom por --prompt ficou sem o protocolo"; a_ok=0 ;;
esac
"$ORCH" rm gitops >/dev/null 2>&1
"$ORCH" rm leader >/dev/null 2>&1 && { no "remover o líder deveria falhar"; a_ok=0; }
[ "$a_ok" = 1 ] && ok "add/rm, presets, agente custom e validações"

echo "5) Prompt de papel e roster do líder"
# note: we capture into a variable instead of "| grep -q" — with 'pipefail' the producer
# dies of SIGPIPE when grep exits at the first match, and the test would fail for nothing.
p_ok=1
prompt_out="$(team_prompt_for tester)"
leader_out="$(team_leader_prompt)"
case "$prompt_out" in *TESTER*)          ;; *) no "prompt de papel não carregou"; p_ok=0 ;; esac
case "$prompt_out" in *"orchestra done"*) ;; *) no "protocolo não foi anexado ao prompt"; p_ok=0 ;; esac
case "$leader_out" in *coder*)           ;; *) no "roster do líder não lista os agentes"; p_ok=0 ;; esac
case "$leader_out" in *tester*)          ;; *) no "roster do líder não reflete agentes novos"; p_ok=0 ;; esac
[ "$p_ok" = 1 ] && ok "prompts de papel + protocolo + roster dinâmico"

# the leader must not edit files: the coder is the one who implements
grep -q -- '--disallowedTools Edit Write' "$ROOT/agents/run-agent.sh" \
  || no "o líder Claude deveria subir sem as ferramentas de escrita"

# the IA is the user's choice: without --ia and without a terminal, add FAILS instead of assuming 'claude'
msg="$("$ORCH" add semia --prompt "x" </dev/null 2>&1 || true)"
case "$msg" in *'falta dizer qual IA'*) ;; *) no "add sem --ia deveria falhar pedindo a IA" ;; esac
team_exists semia && no "add sem --ia não deveria ter criado o agente"

# OpenCode and Codex receive the role prompt as the FIRST MESSAGE: without an explicit
# instruction, the worker starts working on its own when it opens (the reviewer went off reviewing).
for r in reviewer coder; do
  case "$(team_prompt_for "$r")" in
    *'NÃO comece a trabalhar'*) ;;
    *) no "o prompt de '$r' deveria mandar aguardar em vez de agir ao iniciar" ;;
  esac
  case "$(team_prompt_for "$r")" in
    *'Apresente-se em uma linha e aguarde.') ;;
    *) no "o prompt de '$r' deveria TERMINAR mandando aguardar (recência)" ;;
  esac
done
case "$(team_leader_prompt)" in
  *'não comece a analisar o projeto nem a delegar nada'*) ;;
  *) no "o líder também deveria aguardar em vez de agir ao iniciar" ;;
esac

# no agent may edit the Orchestra installation or leave the project
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

# the leader must be told LIVE when the team changes, without the user typing anything
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

# the leader needs to know WHAT each custom agent is for, otherwise it does not route
"$ORCH" add pr --ia claude --prompt "Abre e atualiza Pull Requests via gh." >/dev/null 2>&1
case "$(team_roster)" in
  *'Abre e atualiza Pull Requests'*) ;;
  *) no "roster do líder deveria descrever o agente custom, não 'agente customizado'" ;;
esac
# no pipe: 'grep -q' closes the pipe at the first match and the producer's SIGPIPE
# becomes a failure because of 'set -o pipefail'
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
TASK="$(cat "$ODIR/run/tester.task" 2>/dev/null)"
[ -n "$TASK" ] || { no "task id não foi gravado"; c_ok=0; }
[ "$(cat "$ODIR/run/tester.status" 2>/dev/null)" = running ] \
  || { no "status deveria ser 'running' após o send"; c_ok=0; }
grep -q "ORCHESTRA task=$TASK" "$ODIR/run/tester.tx" 2>/dev/null \
  || { no "o rodapé com o task id não foi injetado no painel"; c_ok=0; }
grep -q "rode os testes" "$ODIR/run/tester.tx" 2>/dev/null \
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
# regression: with --agent, OpenCode uses ITS OWN prompt (without the Orchestra
# protocol). The role prompt must ALWAYS go, otherwise the worker never
# runs 'orchestra done' and every dispatch dies on timeout.
grep -q -- '--prompt "$PROMPT" "$PROJ"' "$ROOT/agents/run-agent.sh" \
  || { no "launch_opencode deveria enviar sempre o prompt de papel"; p_ok=0; }
if grep -q 'elif \[ "$1" = first \]; then' "$ROOT/agents/run-agent.sh"; then
  no "launch_opencode voltou a tornar o prompt condicional ao --agent"; p_ok=0
fi
# pane label: icon + NAME IN UPPERCASE, the same for layout and runtime
[ "$(pane_label leader)" = "🎼 LÍDER" ] || { no "rótulo do líder fora do padrão"; p_ok=0; }
"$ORCH" add zeta --backend claude >/dev/null 2>&1
case "$(pane_label zeta)" in *ZETA) ;; *) no "nome de agente deveria aparecer em MAIÚSCULAS"; p_ok=0 ;; esac
grep -q 'pane_label' "$ROOT/lib/mux.sh" \
  || { no "painel criado em runtime não usa o rótulo padronizado"; p_ok=0; }
# the new agent must show up on the SAME screen as the others
grep -q -- '--tab-id' "$ROOT/lib/mux.sh" \
  || { no "painel novo deveria ser ancorado na aba do líder (--tab-id)"; p_ok=0; }
if grep -E 'new-pane.*(--floating|[[:space:]]-f[[:space:]])' "$ROOT/lib/mux.sh" >/dev/null 2>&1; then
  no "painel do time nunca pode ser flutuante (cobre os outros em vez de dividir a tela)"; p_ok=0
fi
# 'focus-pane-id' is a no-op when called from outside the session (zellij 0.44.3):
# closing "the focused pane" after it would close the WRONG pane (the leader's).
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

echo "10) Subir o time é a ação padrão (sem 'up')"
s_ok=1
# 'orchestra <dir>' must come up in that project; a nonexistent path is a clear error
msg="$("$ORCH" /nao/existe/mesmo 2>&1 || true)"
case "$msg" in *'diretório não encontrado'*) ;; *) no "caminho inexistente deveria dizer isso, não 'comando desconhecido'"; s_ok=0 ;; esac
# 'up' is still accepted, but warning that it is unnecessary
msg="$(PATH=/usr/bin:/bin "$ORCH" up 2>&1 || true)"
case "$msg" in *"não é mais necessário"*) ;; *) no "'orchestra up' deveria avisar que virou desnecessário"; s_ok=0 ;; esac
# and it must no longer appear in the help
case "$("$ORCH" help 2>&1)" in
  *'orchestra up'*) no "a ajuda não deveria mais documentar 'orchestra up'"; s_ok=0 ;;
esac
[ "$s_ok" = 1 ] && ok "orchestra / orchestra <dir> · 'up' aceito porém não documentado"

echo "11) Lançamento do zellij"
z_ok=1
# regression: with '--session', zellij's '--layout' means "add as a tab to the
# existing session" and fails with "Session not found". Only '-n' creates the session.
grep -q 'exec zellij -s "\$sess" -n "\$layout"' "$ORCH" \
  || { no "o 'up' deveria lançar o zellij com -n (new-session-with-layout)"; z_ok=0; }
if grep -E 'exec zellij .*--layout' "$ORCH" >/dev/null 2>&1; then
  no "o 'up' voltou a usar --layout junto com -s (não cria a sessão)"; z_ok=0
fi
# regression: 'basename | tr -c' converts the trailing \n into '-' and duplicates the hyphen
sess_test="orchestra-$(printf '%s' "$(basename /tmp/proj-x)" | tr -c 'a-zA-Z0-9_-' '-')-1"
case "$sess_test" in *--*) no "nome de sessão com hífen duplo"; z_ok=0 ;; esac
[ "$z_ok" = 1 ] && ok "zellij é lançado com -n e o nome de sessão é limpo"

echo "12) Desinstalação em um comando"
u_ok=1
# the user has no way of knowing they need to end sessions beforehand: the uninstall does
case "$(sed -n '/^uninstall()/,/^}/p' "$ROOT/lib/core.sh")" in
  *kill_all_sessions*) ;;
  *) no "uninstall deveria encerrar as sessões sozinho"; u_ok=0 ;;
esac
grep -q "grep '\^orchestra-'" "$ROOT/lib/core.sh" \
  || { no "só sessões 'orchestra-*' podem ser encerradas"; u_ok=0; }
grep -q "grep '\^orchestra-'" "$ROOT/uninstall.sh" \
  || { no "o uninstall standalone também deveria encerrar as sessões"; u_ok=0; }
case "$(sed -n '/^uninstall()/,/^}/p' "$ROOT/lib/core.sh")" in
  *'hash -r'*) ;;
  *) no "uninstall deveria avisar sobre o cache de comandos do shell"; u_ok=0 ;;
esac
# only the zellij that the installer downloaded may be removed
grep -q 'zellij.ours' "$ROOT/install.sh" \
  || { no "o instalador deveria marcar quando ele mesmo instala o zellij"; u_ok=0; }
grep -q 'zellij.ours' "$ROOT/lib/core.sh" \
  || { no "uninstall deveria remover o zellij que o Orchestra instalou"; u_ok=0; }
grep -q 'zellij.ours' "$ROOT/uninstall.sh" \
  || { no "o uninstall standalone também deveria remover esse zellij"; u_ok=0; }
# the uninstall must be documented for the user
grep -q '^## 🗑️ Uninstallation' "$ROOT/README.md" \
  || { no "o README precisa de uma seção de desinstalação"; u_ok=0; }
[ "$u_ok" = 1 ] && ok "uninstall em um comando: sessões, zellij próprio e documentação"

echo "13) orchestra doctor"
if "$ORCH" doctor >/dev/null 2>&1; then ok "doctor sem falhas (exit 0)"
else skipt "doctor com falhas — esperado se claude/opencode/codex não estão neste host"; fi

echo "14) Nome de sessão que cabe no multiplexador"
n_ok=1
# zellij derives the maximum name length from what is left in 'sockaddr_un.sun_path'
# (104 bytes on macOS, 108 on Linux) after the socket dir, which lives under $TMPDIR.
# On Linux ($TMPDIR=/tmp) the whole name fits; on macOS (/var/folders/<...>/T/,
# 49 chars) 24 are left — and 'up' died with "session name must be less than 0".
( source "$ROOT/lib/mux.sh" 2>/dev/null

  hist="orchestra-$(printf '%s' "$(basename /a/b/meu-projeto)" | tr -c 'a-zA-Z0-9_-' '-')-$(printf '%s' /a/b/meu-projeto | cksum | cut -d' ' -f1)"
  cands="$(_mux_session_candidates /a/b/meu-projeto)"

  # the 1st candidate is the historical format: as long as it fits, Linux does not change its name
  [ "$(printf '%s\n' "$cands" | head -1)" = "$hist" ] \
    || { echo "FAIL1"; exit 1; }

  short_ok=0
  while IFS= read -r c; do
    # 'kill_all_sessions' finds the team's sessions with grep '^orchestra-'
    case "$c" in orchestra-*) ;; *) echo "FAIL2"; exit 1 ;; esac
    case "$c" in *--*) echo "FAIL3"; exit 1 ;; esac
    [ "${#c}" -le 24 ] && short_ok=1
  done <<EOF2
$cands
EOF2
  # there must be at least one candidate that fits the macOS limit
  [ "$short_ok" = 1 ] || { echo "FAIL4"; exit 1; }

  # a project already named 'orchestra-*' does not repeat the word in the short name
  printf '%s\n' "$(_mux_session_candidates /a/b/orchestra-agents)" | grep -q '^orchestra-agents-' \
    || { echo "FAIL5"; exit 1; }

  # same basename in different paths → different sessions even after shortening
  a="$(_mux_session_candidates /cliente-a/api | sed -n 2p)"
  b="$(_mux_session_candidates /cliente-b/api | sed -n 2p)"
  [ "$a" != "$b" ] || { echo "FAIL6"; exit 1; }
  echo OK
) >"$ORCHESTRA_STATE/sess.out" 2>&1
case "$(cat "$ORCHESTRA_STATE/sess.out")" in
  *OK*) ;;
  *FAIL1*) no "o 1º candidato mudou — nome de sessão regride no Linux"; n_ok=0 ;;
  *FAIL2*) no "candidato sem o prefixo 'orchestra-' — 'orchestra kill' deixa de achar"; n_ok=0 ;;
  *FAIL3*) no "nome de sessão com hífen duplo"; n_ok=0 ;;
  *FAIL4*) no "nenhum candidato cabe em 24 chars — o 'up' quebra no macOS"; n_ok=0 ;;
  *FAIL5*) no "projeto 'orchestra-*' repete a palavra no nome curto"; n_ok=0 ;;
  *FAIL6*) no "dois projetos com o mesmo nome colidiriam na mesma sessão"; n_ok=0 ;;
  *) no "_mux_session_candidates não pôde ser exercitada"; n_ok=0 ;;
esac
# the assembly must live in lib/mux.sh, not inline in 'up'
grep -q 'sess="$(mux_session_name "$ORCHESTRA_PROJECT")"' "$ORCH" \
  || { no "o 'up' deveria pedir o nome de sessão ao mux (mux_session_name)"; n_ok=0; }
# The probe must work under 'set -o pipefail' (that is how 'up' runs). With a
# 'zellij | grep' pipe, zellij's exit 2 when refusing the name WINS over grep's that matched, and the
# probe answered "fits" precisely for the name that is too big — the team did not come up on
# macOS even with the shortening in place. Fake zellij with macOS's 24-char ceiling.
ZJFAKE="$ORCHESTRA_STATE/zjfake"; mkdir -p "$ZJFAKE"
cat >"$ZJFAKE/zellij" <<'ZJ'
#!/bin/sh
name=""
while [ $# -gt 0 ]; do
  case "$1" in -s) name="$2"; shift 2 ;; *) shift ;; esac
done
if [ "${#name}" -gt 24 ]; then
  echo "error: invalid value '$name' for '--session <SESSION>': session name must be less than 0 characters" >&2
  exit 2
fi
echo "There is no active session!"
exit 1
ZJ
chmod +x "$ZJFAKE/zellij"
probe="$(
  set -uo pipefail
  PATH="$ZJFAKE:$PATH"; export PATH
  ORCHESTRA_MUX=zellij; export ORCHESTRA_MUX
  source "$ROOT/lib/mux.sh" 2>/dev/null
  _zj_session_name_fits "orchestra-nome-longo-demais-1234" && echo "TOO_LONG_FITS"
  _zj_session_name_fits "orchestra-curto-1234" || echo "SHORT_DOES_NOT_FIT"
  mux_session_name /a/b/tsoft-rep-hub
)"
case "$probe" in
  *TOO_LONG_FITS*)      no "sob pipefail a sondagem aceita nome longo demais (o 'up' quebra no macOS)"; n_ok=0 ;;
  *SHORT_DOES_NOT_FIT*) no "sob pipefail a sondagem recusa um nome que cabe"; n_ok=0 ;;
esac
chosen="$(printf '%s\n' "$probe" | tail -1)"
[ -n "$chosen" ] && [ "${#chosen}" -le 24 ] \
  || { no "mux_session_name devolveu '$chosen' (${#chosen} chars) onde o teto é 24"; n_ok=0; }
[ "$n_ok" = 1 ] && ok "nome de sessão encurta sozinho e segue estável por projeto"

# ---------------------------------------------------------------------------
echo "15) Menu de composição: setas e redesenho"
# The menu only fails in a real terminal, so this case drives it through a pty
# (tests/menu_pty.py explains each trap). It covers the arrow that closed the menu in
# macOS's bash 3.2 and the absolute anchor that duplicated the block when the screen scrolled.
m_ok=1
if command -v python3 >/dev/null 2>&1 && [ -r /bin/bash ]; then
  MENUPROJ="$(mktemp -d)"
  menu_out="$(python3 "$ROOT/tests/menu_pty.py" "$ROOT" "$MENUPROJ" 2>/dev/null)"
  rm -rf "$MENUPROJ"
  case "$menu_out" in
    *MENU_DIED*)         no "a seta ↓ fecha o menu (timeout fracionário em 'read -t')"; m_ok=0 ;;
  esac
  case "$menu_out" in
    *INVALID_TIMEOUT*)  no "'read -t' recusou o timeout — a detecção de fração não pegou"; m_ok=0 ;;
  esac
  case "$menu_out" in
    *ABSOLUTE_ANCHOR*)  no "o menu voltou a usar âncora absoluta de cursor — com scroll ele se duplica na tela"; m_ok=0 ;;
  esac
  case "$menu_out" in
    *RELATIVE_REDRAW*) ;;
    *) no "o redesenho não é relativo: falta o movimento de subir N linhas"; m_ok=0 ;;
  esac
  case "$menu_out" in
    *REACHED_ADD*) ;;
    *) no "a seta ↓ não chega em '+ adicionar agente'"; m_ok=0 ;;
  esac
  # each arrow proves an EFFECT on screen, not just "some byte came out" (finding from the
  # OAV2-26 review: with 'up)'/'left|right)' turning into a no-op in lib/core.sh,
  # the previous version of this case kept passing).
  case "$menu_out" in
    *MOVES_DOWN_TO_CODER*) ;;
    *) no "a seta ↓ não move o cursor do líder para o coder"; m_ok=0 ;;
  esac
  case "$menu_out" in
    *MOVES_DOWN_TO_REVIEWER*) ;;
    *) no "a seta ↓ não move o cursor do coder para o reviewer"; m_ok=0 ;;
  esac
  case "$menu_out" in
    *MOVES_UP_TO_CODER*) ;;
    *) no "a seta ↑ não move o cursor de volta para o coder"; m_ok=0 ;;
  esac
  case "$menu_out" in
    *RIGHT_SWITCHES_TO_CODEX*) ;;
    *) no "a seta → não troca a IA da linha corrente (opencode -> codex)"; m_ok=0 ;;
  esac
  case "$menu_out" in
    *LEFT_SWITCHES_TO_CLAUDE*) ;;
    *) no "a seta ← não troca a IA da linha corrente (codex -> claude)"; m_ok=0 ;;
  esac
  case "$menu_out" in
    *FOUR_ARROWS_ALIVE*) ;;
    *) no "↑/↓/←/→ não navegam de verdade (o menu morreu no meio da sequência)"; m_ok=0 ;;
  esac
  case "$menu_out" in
    *ESC_CANCELS*) ;;
    *) no "Esc sozinho não cancelou com rc 2"; m_ok=0 ;;
  esac
  [ "$m_ok" = 1 ] && ok "setas navegam até o fim do menu e o redesenho não deixa sobra"
else
  skipt "python3 ou /bin/bash ausente — menu de composição não exercitado"
fi

# ---------------------------------------------------------------------------
echo "16) Nada é escrito na raiz do projeto"
r_ok=1
# the user's project does not receive a SINGLE Orchestra file
leftovers="$(ls -A "$ORCHESTRA_PROJECT" 2>/dev/null)"
[ -z "$leftovers" ] || { no "o Orchestra deixou arquivos na raiz do projeto: $leftovers"; r_ok=0; }
case "$ODIR" in
  "$ORCHESTRA_STATE"/projects/*) ;;
  *) no "ORCHESTRA_DIR devia ficar em \$ORCHESTRA_STATE/projects/<slug>, veio '$ODIR'"; r_ok=0 ;;
esac
[ -f "$ODIR/project.path" ] && [ "$(cat "$ODIR/project.path")" = "$ORCHESTRA_PROJECT" ] \
  || { no "project.path não aponta para o projeto (o uninstall depende dele)"; r_ok=0; }
# two projects with the same name in different folders do not share the same team
sl_a="$(ORCHESTRA_PROJECT=/tmp/cliente-a/api bash -c '. "'"$ROOT"'/lib/core.sh" >/dev/null 2>&1; basename "$ORCHESTRA_DIR"')"
sl_b="$(ORCHESTRA_PROJECT=/tmp/cliente-b/api bash -c '. "'"$ROOT"'/lib/core.sh" >/dev/null 2>&1; basename "$ORCHESTRA_DIR"')"
[ -n "$sl_a" ] && [ "$sl_a" != "$sl_b" ] \
  || { no "projetos homônimos em pastas diferentes colidiram no mesmo slug ($sl_a)"; r_ok=0; }
# migration: whoever already had <project>/.orchestra loses neither team nor prompt
MIGPROJ="$(mktemp -d)"; MIGSTATE="$(mktemp -d)"
mkdir -p "$MIGPROJ/.orchestra/prompts"
printf 'run/\n' >"$MIGPROJ/.orchestra/.gitignore"
printf 'linha 1\nfaz deploy de produção\n' >"$MIGPROJ/.orchestra/prompts/velho.md"
cat >"$MIGPROJ/.orchestra/team.json" <<'JSON'
{"version":1,"leader":{"name":"leader","backend":"codex","role":"leader"},
 "agents":[{"name":"velho","backend":"claude","role":"custom","prompt_file":".orchestra/prompts/velho.md"}]}
JSON
mig="$(ORCHESTRA_STATE="$MIGSTATE" ORCHESTRA_PROJECT="$MIGPROJ" bash -c '
  . "'"$ROOT"'/lib/core.sh" >/dev/null 2>&1
  printf "%s|%s|%s\n" "$(team_names | tr "\n" " ")" "$(team_field leader backend)" "$(role_summary velho)"')"
case "$mig" in
  "velho |codex|faz deploy de produção") ;;
  *) no "migração do .orchestra legado perdeu dados (veio '$mig')"; r_ok=0 ;;
esac
[ -e "$MIGPROJ/.orchestra" ] && { no "a migração deixou o .orchestra antigo no projeto"; r_ok=0; }
rm -rf "$MIGPROJ" "$MIGSTATE"
[ "$r_ok" = 1 ] && ok "time/prompts/runtime fora do projeto, sem colisão e com migração do legado"

# ---------------------------------------------------------------------------
echo "17) Sandbox do Codex alcança o runtime"
c_ok=1
# the runtime left the project and 'workspace-write' only frees the workspace: without opening the
# Orchestra directory, a codex worker's 'orchestra done' dies with
# "Operation not permitted" and every dispatch to it becomes a timeout.
wr="$(. "$ROOT/lib/core.sh" >/dev/null 2>&1; codex_writable_roots_arg)"
case "$wr" in
  'sandbox_workspace_write.writable_roots=["'"$ODIR"'"]') ;;
  *) no "codex_writable_roots_arg não aponta para \$ORCHESTRA_DIR (veio '$wr')"; c_ok=0 ;;
esac
grep -q 'codex_writable_roots_arg' "$ROOT/agents/run-agent.sh" \
  || { no "run-agent.sh não passa writable_roots ao codex"; c_ok=0; }
[ "$c_ok" = 1 ] && ok "codex recebe o runtime como writable_root"

# ---------------------------------------------------------------------------
echo "18) Uninstall devolve a máquina ao estado anterior"
u_ok=1
# What the installer put there must leave by the METHOD it came in with. The bug that
# motivated this: 'cargo install zellij' puts the binary in ~/.cargo/bin, but the marker
# recorded $BIN_DIR/zellij — a path where nothing existed. The uninstall did not find the
# file, said "zellij preservado" and zellij stayed on the machine forever.
UNHOME="$(mktemp -d)"; UNBIN="$UNHOME/fakebin"; mkdir -p "$UNBIN" "$UNHOME/bin"
for t in brew cargo; do
  printf '#!/bin/sh\necho "$@" >>"%s/%s.log"\nexit 0\n' "$UNHOME" "$t" >"$UNBIN/$t"
  chmod +x "$UNBIN/$t"
done
printf '#!/bin/sh\nexit 0\n' >"$UNHOME/bin/zellij"; chmod +x "$UNHOME/bin/zellij"
UNSTATE="$UNHOME/state"; mkdir -p "$UNSTATE"
printf 'os\tmacos\nfile\t%s\nbrew\tzellij\ncargo\tzellij\n' "$UNHOME/bin/zellij" >"$UNSTATE/installed.manifest"
un_out="$(HOME="$UNHOME" PATH="$UNBIN:$PATH" ORCHESTRA_STATE="$UNSTATE" ORCHESTRA_HOME="$ROOT" \
  bash -c '. "'"$ROOT"'/lib/core.sh" >/dev/null 2>&1; _uninstall_manifest' 2>&1)"
[ -e "$UNHOME/bin/zellij" ] && { no "uninstall não removeu o binário registrado como 'file'"; u_ok=0; }
grep -q '^uninstall zellij$' "$UNHOME/brew.log" 2>/dev/null \
  || { no "uninstall não chamou 'brew uninstall zellij' para o item do brew"; u_ok=0; }
grep -q '^uninstall zellij$' "$UNHOME/cargo.log" 2>/dev/null \
  || { no "uninstall não chamou 'cargo uninstall zellij' para o item do cargo"; u_ok=0; }
case "$un_out" in *preservado*) no "disse 'preservado' tendo removido itens do manifesto"; u_ok=0 ;; esac
# and the opposite: without a manifest, a zellij that already belonged to the user must NOT vanish
UNHOME2="$(mktemp -d)"; UNBIN2="$UNHOME2/fakebin"; mkdir -p "$UNBIN2" "$UNHOME2/.config/zellij"
printf '#!/bin/sh\nexit 0\n' >"$UNBIN2/zellij"; chmod +x "$UNBIN2/zellij"
: >"$UNHOME2/.config/zellij/config.kdl"
UNSTATE2="$UNHOME2/state"; mkdir -p "$UNSTATE2"; printf 'os\tlinux\n' >"$UNSTATE2/installed.manifest"
un_out2="$(HOME="$UNHOME2" PATH="$UNBIN2:$PATH" ORCHESTRA_STATE="$UNSTATE2" ORCHESTRA_HOME="$ROOT" \
  bash -c '. "'"$ROOT"'/lib/core.sh" >/dev/null 2>&1; _uninstall_manifest' 2>&1)"
[ -x "$UNBIN2/zellij" ] || { no "uninstall removeu um zellij que não foi ele que instalou"; u_ok=0; }
[ -f "$UNHOME2/.config/zellij/config.kdl" ] || { no "uninstall apagou a config de um zellij alheio"; u_ok=0; }
# and even when zellij LEAVES, ~/.config/zellij belongs to the user and must stay
mkdir -p "$UNHOME/.config/zellij"; : >"$UNHOME/.config/zellij/config.kdl"
printf '#!/bin/sh\nexit 0\n' >"$UNHOME/bin/zellij"; chmod +x "$UNHOME/bin/zellij"
HOME="$UNHOME" PATH="$UNBIN:$PATH" ORCHESTRA_STATE="$UNSTATE" ORCHESTRA_HOME="$ROOT" \
  bash -c '. "'"$ROOT"'/lib/core.sh" >/dev/null 2>&1; _uninstall_manifest' >/dev/null 2>&1
[ -f "$UNHOME/.config/zellij/config.kdl" ] \
  || { no "uninstall apagou ~/.config/zellij, que é do usuário e não do Orchestra"; u_ok=0; }
case "$un_out2" in *preservado*) ;; *) no "não avisou que o zellij alheio foi preservado"; u_ok=0 ;; esac
# the installer must record each method, otherwise none of this is actionable
for m in 'record_installed brew zellij' 'record_installed file' 'record_installed cargo zellij'; do
  grep -q "$m" "$ROOT/install.sh" || { no "install.sh não registra: $m"; u_ok=0; }
done
grep -q 'os_detect' "$ROOT/install.sh" || { no "install.sh não detecta o sistema operacional"; u_ok=0; }
rm -rf "$UNHOME" "$UNHOME2"
[ "$u_ok" = 1 ] && ok "cada item sai pelo método com que entrou; o que era do usuário fica"

# ---------------------------------------------------------------------------
echo "19) O motor do menu vive num arquivo só"
me_ok=1

# Architecture lint, not style lint. The menu engine — hide the cursor, erase the
# previous drawing, read a key — carries two bugs that do NOT show up in bash 5 or
# outside a pty: macOS's bash 3.2 rejects 'read -t 0.05' (that is what made every
# arrow close the menu, and zellij did not even open) and the absolute anchor reprints the menu
# when the terminal scrolls. Whoever duplicates the engine will not see the bug come back on their own
# machine — that is why the rule is a test that fails the build, and not documentation.
#
# The regexes below are written to NOT match themselves ('read -rs[nt]' does not
# contain 'read -rsn'), and that is what allows sweeping the WHOLE repository, this test
# file included, without opening the convenient exception of "tests do not count".
MENU_OWNER="lib/menu.sh"

# TEMPORARY exemption, with a mechanical deadline: it existed while select_team() hosted
# the old engine in lib/core.sh (OAV2-2 migrated it to lib/menu.sh). Empty now that the
# exempt file no longer has any engine pattern — it is the deadline expiring on its own,
# instead of a "remove later" that nobody reads.
MENU_EXEMPT=""

_menu_engine_patterns() { # regex TAB what-it-is TAB where-allowed TAB what-to-use TAB why-it-hurts
  printf '%s\t%s\t%s\t%s\t%s\n' \
    'read -rs[nt]' \
    'leitura de tecla crua' \
    "só pode existir em $MENU_OWNER" \
    'menu_read_key' \
    'o bash 3.2 do macOS recusa timeout fracionário e devolve a variável VAZIA, que é exatamente como se reconhece "Esc sozinho": toda seta fecha o menu'
  printf '%s\t%s\t%s\t%s\t%s\n' \
    '\\033\[\?25[lh]' \
    'esconder ou mostrar o cursor' \
    "só pode existir em $MENU_OWNER" \
    'menu_begin e menu_end' \
    'quem esconde o cursor tem de garantir a devolução dele em INT/TERM/EXIT, e essa proteção mora no motor'
  printf '%s\t%s\t%s\t%s\t%s\n' \
    '\\033\[(%d|[0-9]+|\$\{?[A-Za-z_][A-Za-z_0-9]*\}?)A' \
    'redesenho relativo' \
    "só pode existir em $MENU_OWNER" \
    'menu_draw_begin e menu_draw_end' \
    'um segundo contador de linhas sai de sincronia com o primeiro e o menu volta a se reimprimir'
  printf '%s\t%s\t%s\t%s\t%s\n' \
    '[Dd][Rr][Aa][Ww][Nn]=' \
    'contador de linhas do desenho' \
    "só pode existir em $MENU_OWNER" \
    'menu_draw_end' \
    'o estado do desenho é do motor; conteúdo que conta linhas por fora duplica o menu quando erra a conta'
}

_menu_engine_hits() { # $1 file  $2 'motor+ancora'|'so-ancora' — echoes line TAB … per violation
  local f="$1" scope="$2" rx what where use why matches n
  {
    # Rule 2: the absolute anchor has no legitimate use ANYWHERE, not even in the owner of
    # the engine. That is why it is checked separately, in all files and without exemption.
    printf '%s\t%s\t%s\t%s\t%s\n' \
      '\\033\[[su]([^A-Za-z0-9_]|$)' \
      'âncora absoluta de cursor' \
      "não pode existir em arquivo nenhum, nem em $MENU_OWNER" \
      'menu_draw_begin, que sobe N linhas a partir de onde o cursor está' \
      'a âncora guarda a LINHA ABSOLUTA da tela: quando o menu não cabe na janela o terminal rola, ela passa a apontar para o meio do bloco e o menu aparece duas vezes'
    [ "$scope" = 'motor+ancora' ] && _menu_engine_patterns
  } | while IFS="$(printf '\t')" read -r rx what where use why; do
    [ -n "$rx" ] || continue
    # Rule 3: a comment is not code. lib/core.sh DOCUMENTS this trap and cites the
    # anchor in the text — without the filter, the guard would fail precisely the documentation
    # that exists to avoid the error.
    matches="$(grep -nE "$rx" "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#')"
    [ -n "$matches" ] || continue
    printf '%s\n' "$matches" | while IFS=: read -r n _; do
      printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$what" "$where" "$use" "$why"
    done
  done
}

_menu_engine_report() { # $1 relative path  $2 output of _menu_engine_hits
  # The message must TEACH: whoever bumps into it may not know the history.
  printf '%s\n' "$2" | while IFS="$(printf '\t')" read -r n what where use why; do
    [ -n "$n" ] || continue
    printf '  \033[1;31m✖\033[0m %s em %s:%s\n' "$what" "$1" "$n"
    printf '     %s.\n' "$where"
    printf '     %s.\n' "$why"
    printf '     Use %s.\n' "$use"
  done
}

menu_scan_files=("$ROOT/bin/orchestra" "$ROOT"/lib/*.sh "$ROOT"/agents/*.sh \
                 "$ROOT"/scripts/*.sh "$ROOT/install.sh" "$ROOT/uninstall.sh" \
                 "$ROOT/tests/smoke.sh")
for f in "${menu_scan_files[@]}"; do
  [ -f "$f" ] || continue
  rel="${f#"$ROOT"/}"
  scope='motor+ancora'
  case "$rel" in "$MENU_OWNER"|"$MENU_EXEMPT") scope='so-ancora' ;; esac
  hits="$(_menu_engine_hits "$f" "$scope")"
  [ -n "$hits" ] || continue
  no "regra do motor de menu violada em $rel"
  _menu_engine_report "$rel" "$hits"
  me_ok=0
done

# The deadline of the exemption, enforced by machine.
if [ -n "$MENU_EXEMPT" ] && [ -z "$(_menu_engine_hits "$ROOT/$MENU_EXEMPT" 'motor+ancora')" ]; then
  no "a isenção de $MENU_EXEMPT venceu: o motor antigo já saiu de lá — apague MENU_EXEMPT para a Regra 1 passar a valer nele também"
  me_ok=0
fi

# Rule 4 — a test that never failed is not a test. Without this case, an error in the grep
# would leave the guard passing forever without verifying anything. We fabricate the real case,
# a new menu written from scratch in ANOTHER file, and require that it be failed. The
# patterns go in through markers (@L@, @A@…) swapped in on the fly, precisely so that
# THESE lines here do not trigger the guard they test.
MENUBAD="$ORCHESTRA_STATE/duplicated-menu.sh"
sed 's/@L@/l/; s/@A@/A/; s/@W@/w/; s/@N@/n/; s/@S@/s/' >"$MENUBAD" <<'FAKE'
#!/usr/bin/env bash
my_new_menu() {
  printf '\033[?25@L@' >/dev/tty
  printf '\033[3@A@\r\033[J' >/dev/tty
  dra@W@n=0
  read -rs@N@1 key </dev/tty
  printf '\033[@S@' >/dev/tty
}
FAKE
menu_bad="$(_menu_engine_hits "$MENUBAD" 'motor+ancora')"
for expected in 'leitura de tecla crua' 'esconder ou mostrar o cursor' 'redesenho relativo' \
                'contador de linhas do desenho' 'âncora absoluta de cursor'; do
  case "$menu_bad" in
    *"$expected"*) ;;
    *) no "a guarda deixou passar um menu duplicado: não reprovou '$expected'"; me_ok=0 ;;
  esac
done

# And the opposite, also by machine: the SAME patterns, commented, must not fail.
# That is what keeps the trap's documentation alive inside the code.
sed 's/^/# /' "$MENUBAD" >"$MENUBAD.commented"
[ -z "$(_menu_engine_hits "$MENUBAD.commented" 'motor+ancora')" ] \
  || { no "a guarda reprovou linhas de comentário: a documentação da armadilha não pode derrubar o build"; me_ok=0; }
rm -f "$MENUBAD" "$MENUBAD.commented"

# The guard prevents; the documentation guides. Whoever bumps into the test will look for the why.
grep -q 'menu_read_key' "$ROOT/CONTRIBUTING.md" \
  || { no "CONTRIBUTING.md não registra que o motor do menu mora em $MENU_OWNER"; me_ok=0; }
# CLAUDE.md is not versioned (it is in .gitignore), so in CI it does not even exist:
# requiring it there would fail the build over a missing file. It is charged where it exists.
if [ -f "$ROOT/CLAUDE.md" ] && ! grep -q 'menu_read_key' "$ROOT/CLAUDE.md"; then
  no "CLAUDE.md não registra a armadilha do motor de menu duplicado"; me_ok=0
fi
grep -q 'WHY THIS FILE EXISTS' "$ROOT/lib/menu.sh" \
  || { no "lib/menu.sh perdeu o comentário que explica por que ele é único"; me_ok=0; }

[ "$me_ok" = 1 ] && ok "motor do menu não duplicado, com a guarda provada em arquivo forjado"

# ---------------------------------------------------------------------------
echo "20) Sequência CSI mais longa que 2 bytes não vaza tecla fantasma (OAV2-25)"
# The target is not a specific terminal: Shift/Ctrl/Alt+arrow arrive with MORE than 2
# bytes after the ESC on every platform Orchestra runs on (macOS, Linux,
# WSL), only each terminal picks an encoding. menu_read_key only read 2 and
# left the leftover in the buffer — the NEXT turn of the loop read it as a LONE
# key, and a letter bound to a shortcut (the 'D' of any Left-with-
# modifier, the 'A' of any Up-with-modifier) fired on its own: 'd'
# falls into the branch that deletes the agent under the cursor — today it stops at the
# OAV2-27 confirmation (before it, it deleted directly) —, 'a' opens the add prompt.
# tests/menu_ghost_pty.py covers both encoding families — CSI with
# parameter ('\e[1;3D', common on Linux/WSL) and ESC-prefixed ('\e\e[D', tmux/
# screen/xterm/macOS) — plus Delete/PageUp/F5 ('~' terminator), the kitty
# keyboard protocol (CSI 'u') and SS3 in application mode. The bytes go straight to the
# pty, so the test runs the same on any terminal, including CI ubuntu.
# Two extra cases (space_in_csi, long_params) came from the OAV2-25 REVIEW:
# a space inside the CSI without 'IFS=' became an empty variable, and the 16-byte
# parameter cap was only just covering the longest real producer (SGR mouse,
# 15 bytes) — no keyboard key emits those forms today, but the failure mode
# is the same, so they stay as a known regression.
gk_ok=1
if command -v python3 >/dev/null 2>&1 && [ -r /bin/bash ]; then
  gk_out="$(python3 "$ROOT/tests/menu_ghost_pty.py" "$ROOT" 2>/dev/null)"
  case "$gk_out" in
    *=FAIL*)
      no "tecla-fantasma vazou no motor atual:"
      printf '%s\n' "$gk_out" | grep '=FAIL' | while IFS= read -r line; do
        printf '       %s\n' "$line" >&2
      done
      gk_ok=0 ;;
  esac
  [ -n "$gk_out" ] || { no "o teste-fantasma não devolveu nada — pty morreu cedo demais"; gk_ok=0; }

  # Rule 4 again (case 19): a test that never failed is not a test. We prove
  # that THIS matrix catches it by replaying the whole script against a copy with the
  # engine from BEFORE OAV2-25 ('read -rsn2', no draining of the rest of the sequence)
  # — it must fail the same way it would in production. shift_up and
  # ctrl_left (OAV2-26) go in this list for the same reason as shift_left/
  # ctrl_up: the leftover is a real 'A'/'D'. alt_space (OAV2-26) also goes in —
  # it already fails on its own WITHOUT needing this whole engine (just remove the
  # 'IFS=' from lib/menu.sh:129/:146; measured), but failing here too confirms
  # that the engine from BEFORE OAV2-25 had the same defect. dead_key_batch does NOT
  # go in: by inspection, none of the 13 sequences there leaves a leftover bound to a
  # shortcut, not even in the old engine — it is not a regressor, it is coverage. The SS3 case
  # (ss3_up) of PROBE_CASES is the same story: an arrow in application mode has
  # exactly 2 bytes after the ESC, the same fixed size the old engine
  # already read. The pattern goes in through a marker (@N@), for the same reason as case 19:
  # so as not to trigger its own guard when scanning THIS file.
  GKOLD="$ORCHESTRA_STATE/menu_read_key.old.sh"
  sed 's/@N@/n/g' >"$GKOLD" <<'FAKE_OLD'
menu_read_key() {
  local __mrk_var="$1" __mrk_key __mrk_rest
  IFS= read -rs@N@1 __mrk_key </dev/tty || return 1
  case "$__mrk_key" in
    $'\e')
      _menu_esc_detect
      __mrk_rest=""
      read -rs@N@2 -t "$_MENU_ESC_WAIT" __mrk_rest </dev/tty
      case "$__mrk_rest" in
        '[A') __mrk_key=up ;;
        '[B') __mrk_key=down ;;
        '[C') __mrk_key=right ;;
        '[D') __mrk_key=left ;;
        '')   __mrk_key=esc ;;
        *)    __mrk_key=unknown ;;
      esac ;;
    '')  __mrk_key=enter ;;
    ' ') __mrk_key=space ;;
  esac
  printf -v "$__mrk_var" '%s' "$__mrk_key"
}
FAKE_OLD
  GKHOME="$ORCHESTRA_STATE/old-menu-home"
  mkdir -p "$GKHOME"
  cp -R "$ROOT/lib" "$GKHOME/lib"
  python3 - "$GKHOME/lib/menu.sh" "$GKOLD" <<'PY'
import sys
target, oldfile = sys.argv[1], sys.argv[2]
with open(target) as f:
    lines = f.readlines()
with open(oldfile) as f:
    old = f.read()
out, skip = [], False
for line in lines:
    if line.startswith('menu_read_key() {'):
        skip = True
        out.append(old)
        continue
    if skip:
        if line.rstrip('\n') == '}':
            skip = False
        continue
    out.append(line)
with open(target, 'w') as f:
    f.writelines(out)
PY
  # only the names that MUST fail on the old engine — dead_key_batch and ss3_up
  # stay out (see the 'somente' comment in menu_ghost_pty.py:main):
  # running them again against the old copy proves nothing and only wastes time.
  GK_EXPECTED="shift_left ctrl_up alt_left_csi alt_up_csi alt_left_escpfx alt_up_escpfx
                shift_up ctrl_left
                delete pageup f5 kitty_u space_in_csi long_params alt_space"
  gk_bad="$(python3 "$ROOT/tests/menu_ghost_pty.py" "$GKHOME" \
    "$(printf '%s' "$GK_EXPECTED" | tr -s ' \n' ',')" 2>/dev/null)"
  missing_regressions=""
  for expected in $GK_EXPECTED; do
    case "$gk_bad" in
      # '=FAIL' right after the NAME, not anywhere in the whole blob —
      # otherwise another case's FAIL would be enough to give a false positive here.
      *"$expected=FAIL"*) ;;
      *) missing_regressions="$missing_regressions $expected" ;;
    esac
  done
  [ -z "$missing_regressions" ] \
    || { no "o teste-fantasma não pega: o motor de ANTES da OAV2-25 passou sem reprovar$missing_regressions"; gk_ok=0; }
  rm -rf "$GKHOME" "$GKOLD"

  [ "$gk_ok" = 1 ] && ok "matriz de teclas-fantasma (CSI c/ parâmetro, ESC-prefixado, '~', kitty CSI-u, SS3, Alt+Espaço) drenada sem sobra"
else
  skipt "python3 ou /bin/bash ausente — tecla fantasma não exercitada"
fi

# ---------------------------------------------------------------------------
echo "21) Menu de composição: adicionar, remover, trocar IA e persistir (OAV2-26)"
# The blind spot that tests/menu_pty.py (case 15) always left: it never pressed 'a'
# (add, writes to team.json right away), 'd' (remove, same), Space (IA
# switch) nor Enter on an agent row — only the ↓ arrow down to '+ adicionar agente' and
# 'q'. tests/menu_compose_pty.py drives these four flows through a real pty and
# checks the EFFECT on team.json (and on the generated prompt, in the case of 'a'), not the screen.
cp_ok=1
if command -v python3 >/dev/null 2>&1 && [ -r /bin/bash ]; then
  cp_out="$(python3 "$ROOT/tests/menu_compose_pty.py" "$ROOT" 2>/dev/null)"
  case "$cp_out" in
    *=FAIL*)
      no "fluxo de composição falhou:"
      printf '%s\n' "$cp_out" | grep '=FAIL' | while IFS= read -r line; do
        printf '       %s\n' "$line" >&2
      done
      cp_ok=0 ;;
  esac
  [ -n "$cp_out" ] || { no "o teste de composição não devolveu nada — pty morreu cedo demais"; cp_ok=0; }
  case "$cp_out" in *SESSION_ALIVE*) ;; *) no "o teste de composição não chegou ao fim"; cp_ok=0 ;; esac
  [ "$cp_ok" = 1 ] && ok "'a' até o fim (com prompt gerado), 'a' cancelado, 'd' com confirmação (s/n/Enter), Espaço e Enter persistindo certo"
else
  skipt "python3 ou /bin/bash ausente — menu de composição (add/del/espaço/enter) não exercitado"
fi

# ---------------------------------------------------------------------------
printf '\nResultado: \033[1;32m%d passou\033[0m · \033[1;31m%d falhou\033[0m · \033[1;33m%d pulado\033[0m\n\n' \
  "$pass" "$fail" "$skip"
[ "$fail" = 0 ] || exit 1
