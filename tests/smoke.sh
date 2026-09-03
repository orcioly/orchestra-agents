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

# Diretório do projeto no Orchestra. NÃO fica mais dentro do projeto do usuário:
# perguntamos à própria lib onde ele é, para o teste não duplicar a regra do slug.
ODIR="$(. "$ROOT/lib/core.sh" >/dev/null 2>&1; echo "$ORCHESTRA_DIR")"

# Backends FALSOS no PATH. 'agent_add' recusa uma IA que não esteja instalada, então
# sem isto a suíte só passa em máquina que tenha claude+opencode+codex — foi o que
# derrubou o CI. Os stubs nunca são executados: os testes rodam com o multiplexador
# 'stub' e nenhum painel real sobe.
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

# OpenCode e Codex recebem o prompt de papel como PRIMEIRA MENSAGEM: sem instrução
# explícita, o worker começa a trabalhar sozinho ao abrir (o reviewer saía revisando).
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

echo "10) Subir o time é a ação padrão (sem 'up')"
s_ok=1
# 'orchestra <dir>' precisa subir naquele projeto; caminho inexistente é erro claro
msg="$("$ORCH" /nao/existe/mesmo 2>&1 || true)"
case "$msg" in *'diretório não encontrado'*) ;; *) no "caminho inexistente deveria dizer isso, não 'comando desconhecido'"; s_ok=0 ;; esac
# 'up' continua aceito, mas avisando que é desnecessário
msg="$(PATH=/usr/bin:/bin "$ORCH" up 2>&1 || true)"
case "$msg" in *"não é mais necessário"*) ;; *) no "'orchestra up' deveria avisar que virou desnecessário"; s_ok=0 ;; esac
# e não pode mais aparecer na ajuda
case "$("$ORCH" help 2>&1)" in
  *'orchestra up'*) no "a ajuda não deveria mais documentar 'orchestra up'"; s_ok=0 ;;
esac
[ "$s_ok" = 1 ] && ok "orchestra / orchestra <dir> · 'up' aceito porém não documentado"

echo "11) Lançamento do zellij"
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

echo "12) Desinstalação em um comando"
u_ok=1
# o usuário não tem como saber que precisa encerrar sessões antes: o uninstall faz
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
# só o zellij que o instalador baixou pode ser removido
grep -q 'zellij.ours' "$ROOT/install.sh" \
  || { no "o instalador deveria marcar quando ele mesmo instala o zellij"; u_ok=0; }
grep -q 'zellij.ours' "$ROOT/lib/core.sh" \
  || { no "uninstall deveria remover o zellij que o Orchestra instalou"; u_ok=0; }
grep -q 'zellij.ours' "$ROOT/uninstall.sh" \
  || { no "o uninstall standalone também deveria remover esse zellij"; u_ok=0; }
# a desinstalação precisa estar documentada para o usuário
grep -q '^## 🗑️ Desinstalação' "$ROOT/README.md" \
  || { no "o README precisa de uma seção de desinstalação"; u_ok=0; }
[ "$u_ok" = 1 ] && ok "uninstall em um comando: sessões, zellij próprio e documentação"

echo "13) orchestra doctor"
if "$ORCH" doctor >/dev/null 2>&1; then ok "doctor sem falhas (exit 0)"
else skipt "doctor com falhas — esperado se claude/opencode/codex não estão neste host"; fi

echo "14) Nome de sessão que cabe no multiplexador"
n_ok=1
# O zellij deriva o tamanho máximo do nome do que sobra em 'sockaddr_un.sun_path'
# (104 bytes no macOS, 108 no Linux) depois do socket dir, que fica sob $TMPDIR.
# No Linux ($TMPDIR=/tmp) o nome inteiro cabe; no macOS (/var/folders/<...>/T/,
# 49 chars) sobram 24 — e o 'up' morria com "session name must be less than 0".
( source "$ROOT/lib/mux.sh" 2>/dev/null

  hist="orchestra-$(printf '%s' "$(basename /a/b/meu-projeto)" | tr -c 'a-zA-Z0-9_-' '-')-$(printf '%s' /a/b/meu-projeto | cksum | cut -d' ' -f1)"
  cands="$(_mux_session_candidates /a/b/meu-projeto)"

  # o 1º candidato é o formato histórico: enquanto ele couber, o Linux não muda de nome
  [ "$(printf '%s\n' "$cands" | head -1)" = "$hist" ] \
    || { echo "FAIL1"; exit 1; }

  short_ok=0
  while IFS= read -r c; do
    # 'kill_all_sessions' acha as sessões do time com grep '^orchestra-'
    case "$c" in orchestra-*) ;; *) echo "FAIL2"; exit 1 ;; esac
    case "$c" in *--*) echo "FAIL3"; exit 1 ;; esac
    [ "${#c}" -le 24 ] && short_ok=1
  done <<EOF2
$cands
EOF2
  # precisa existir ao menos um candidato que caiba no limite do macOS
  [ "$short_ok" = 1 ] || { echo "FAIL4"; exit 1; }

  # projeto que já se chama 'orchestra-*' não repete a palavra no nome curto
  printf '%s\n' "$(_mux_session_candidates /a/b/orchestra-agents)" | grep -q '^orchestra-agents-' \
    || { echo "FAIL5"; exit 1; }

  # mesmo basename em caminhos diferentes → sessões diferentes mesmo depois de encurtar
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
# a montagem tem de viver em lib/mux.sh, não inline no 'up'
grep -q 'sess="$(mux_session_name "$ORCHESTRA_PROJECT")"' "$ORCH" \
  || { no "o 'up' deveria pedir o nome de sessão ao mux (mux_session_name)"; n_ok=0; }
# A sondagem tem de funcionar sob 'set -o pipefail' (o 'up' roda assim). Com um pipe
# 'zellij | grep', o exit 2 do zellij ao recusar o nome VENCE o do grep que casou, e a
# sondagem respondia "cabe" justamente para o nome grande demais — o time não subia no
# macOS mesmo com o encurtamento no lugar. Fake zellij com o teto de 24 chars do macOS.
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
# O menu só falha num terminal de verdade, então este caso o dirige por um pty
# (tests/menu_pty.py explica cada armadilha). Cobre a seta que fechava o menu no
# bash 3.2 do macOS e a âncora absoluta que duplicava o bloco quando a tela rolava.
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
  # cada seta prova um EFEITO na tela, não só "saiu algum byte" (achado da
  # revisão da OAV2-26: com 'up)'/'left|right)' virando no-op em lib/core.sh,
  # a versão anterior deste caso continuava passando).
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
# o projeto do usuário não recebe UM arquivo sequer do Orchestra
leftovers="$(ls -A "$ORCHESTRA_PROJECT" 2>/dev/null)"
[ -z "$leftovers" ] || { no "o Orchestra deixou arquivos na raiz do projeto: $leftovers"; r_ok=0; }
case "$ODIR" in
  "$ORCHESTRA_STATE"/projects/*) ;;
  *) no "ORCHESTRA_DIR devia ficar em \$ORCHESTRA_STATE/projects/<slug>, veio '$ODIR'"; r_ok=0 ;;
esac
[ -f "$ODIR/project.path" ] && [ "$(cat "$ODIR/project.path")" = "$ORCHESTRA_PROJECT" ] \
  || { no "project.path não aponta para o projeto (o uninstall depende dele)"; r_ok=0; }
# dois projetos de mesmo nome em pastas diferentes não dividem o mesmo time
sl_a="$(ORCHESTRA_PROJECT=/tmp/cliente-a/api bash -c '. "'"$ROOT"'/lib/core.sh" >/dev/null 2>&1; basename "$ORCHESTRA_DIR"')"
sl_b="$(ORCHESTRA_PROJECT=/tmp/cliente-b/api bash -c '. "'"$ROOT"'/lib/core.sh" >/dev/null 2>&1; basename "$ORCHESTRA_DIR"')"
[ -n "$sl_a" ] && [ "$sl_a" != "$sl_b" ] \
  || { no "projetos homônimos em pastas diferentes colidiram no mesmo slug ($sl_a)"; r_ok=0; }
# migração: quem já tinha <projeto>/.orchestra não perde time nem prompt
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
# o runtime saiu do projeto e 'workspace-write' só libera o workspace: sem abrir o
# diretório do Orchestra, o 'orchestra done' de um worker codex morre em
# "Operation not permitted" e todo despacho para ele vira timeout.
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
# O que o instalador colocou tem de sair pelo MÉTODO com que entrou. O bug que
# motivou isto: 'cargo install zellij' põe o binário em ~/.cargo/bin, mas o marcador
# gravava $BIN_DIR/zellij — um caminho onde nada existia. O uninstall não achava o
# arquivo, dizia "zellij preservado" e o zellij ficava na máquina para sempre.
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
# e o oposto: sem manifesto, um zellij que já era do usuário NÃO pode sumir
UNHOME2="$(mktemp -d)"; UNBIN2="$UNHOME2/fakebin"; mkdir -p "$UNBIN2" "$UNHOME2/.config/zellij"
printf '#!/bin/sh\nexit 0\n' >"$UNBIN2/zellij"; chmod +x "$UNBIN2/zellij"
: >"$UNHOME2/.config/zellij/config.kdl"
UNSTATE2="$UNHOME2/state"; mkdir -p "$UNSTATE2"; printf 'os\tlinux\n' >"$UNSTATE2/installed.manifest"
un_out2="$(HOME="$UNHOME2" PATH="$UNBIN2:$PATH" ORCHESTRA_STATE="$UNSTATE2" ORCHESTRA_HOME="$ROOT" \
  bash -c '. "'"$ROOT"'/lib/core.sh" >/dev/null 2>&1; _uninstall_manifest' 2>&1)"
[ -x "$UNBIN2/zellij" ] || { no "uninstall removeu um zellij que não foi ele que instalou"; u_ok=0; }
[ -f "$UNHOME2/.config/zellij/config.kdl" ] || { no "uninstall apagou a config de um zellij alheio"; u_ok=0; }
# e mesmo quando o zellij SAI, ~/.config/zellij é do usuário e tem de ficar
mkdir -p "$UNHOME/.config/zellij"; : >"$UNHOME/.config/zellij/config.kdl"
printf '#!/bin/sh\nexit 0\n' >"$UNHOME/bin/zellij"; chmod +x "$UNHOME/bin/zellij"
HOME="$UNHOME" PATH="$UNBIN:$PATH" ORCHESTRA_STATE="$UNSTATE" ORCHESTRA_HOME="$ROOT" \
  bash -c '. "'"$ROOT"'/lib/core.sh" >/dev/null 2>&1; _uninstall_manifest' >/dev/null 2>&1
[ -f "$UNHOME/.config/zellij/config.kdl" ] \
  || { no "uninstall apagou ~/.config/zellij, que é do usuário e não do Orchestra"; u_ok=0; }
case "$un_out2" in *preservado*) ;; *) no "não avisou que o zellij alheio foi preservado"; u_ok=0 ;; esac
# o instalador precisa registrar cada método, senão nada disso é acionável
for m in 'record_installed brew zellij' 'record_installed file' 'record_installed cargo zellij'; do
  grep -q "$m" "$ROOT/install.sh" || { no "install.sh não registra: $m"; u_ok=0; }
done
grep -q 'os_detect' "$ROOT/install.sh" || { no "install.sh não detecta o sistema operacional"; u_ok=0; }
rm -rf "$UNHOME" "$UNHOME2"
[ "$u_ok" = 1 ] && ok "cada item sai pelo método com que entrou; o que era do usuário fica"

# ---------------------------------------------------------------------------
echo "19) O motor do menu vive num arquivo só"
me_ok=1

# Lint de arquitetura, não de estilo. O motor do menu — esconder o cursor, apagar o
# desenho anterior, ler uma tecla — carrega dois bugs que NÃO aparecem em bash 5 nem
# fora de um pty: o bash 3.2 do macOS recusa 'read -t 0.05' (era isso que fazia toda
# seta fechar o menu, e o zellij nem abria) e a âncora absoluta reimprime o menu
# quando o terminal rola. Quem duplicar o motor não vai ver o bug voltar na própria
# máquina — por isso a regra é teste que reprova o build, e não documentação.
#
# Os regex abaixo são escritos para NÃO casarem consigo mesmos ('read -rs[nt]' não
# contém 'read -rsn'), e é isso que permite varrer o repositório INTEIRO, este arquivo
# de teste incluído, sem abrir a exceção conveniente de "testes não contam".
MENU_OWNER="lib/menu.sh"

# Isenção TEMPORÁRIA, com prazo mecânico: existiu enquanto select_team() hospedava
# o motor antigo em lib/core.sh (OAV2-2 migrou para lib/menu.sh). Vazia agora que o
# arquivo isento não tem mais nenhum padrão do motor — é o prazo vencendo por conta
# própria, em vez de um "remover depois" que ninguém lê.
MENU_EXEMPT=""

_menu_engine_patterns() { # regex TAB o-que-é TAB onde-pode TAB o-que-usar TAB por-que-dói
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

_menu_engine_hits() { # $1 arquivo  $2 'motor+ancora'|'so-ancora' — ecoa linha TAB … por violação
  local f="$1" scope="$2" rx what where use why matches n
  {
    # Regra 2: a âncora absoluta não tem uso legítimo em lugar NENHUM, nem no dono do
    # motor. Por isso ela é checada à parte, em todos os arquivos e sem isenção.
    printf '%s\t%s\t%s\t%s\t%s\n' \
      '\\033\[[su]([^A-Za-z0-9_]|$)' \
      'âncora absoluta de cursor' \
      "não pode existir em arquivo nenhum, nem em $MENU_OWNER" \
      'menu_draw_begin, que sobe N linhas a partir de onde o cursor está' \
      'a âncora guarda a LINHA ABSOLUTA da tela: quando o menu não cabe na janela o terminal rola, ela passa a apontar para o meio do bloco e o menu aparece duas vezes'
    [ "$scope" = 'motor+ancora' ] && _menu_engine_patterns
  } | while IFS="$(printf '\t')" read -r rx what where use why; do
    [ -n "$rx" ] || continue
    # Regra 3: comentário não é código. lib/core.sh DOCUMENTA esta armadilha e cita a
    # âncora no texto — sem o filtro, a guarda reprovaria justamente a documentação
    # que existe para evitar o erro.
    matches="$(grep -nE "$rx" "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#')"
    [ -n "$matches" ] || continue
    printf '%s\n' "$matches" | while IFS=: read -r n _; do
      printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$what" "$where" "$use" "$why"
    done
  done
}

_menu_engine_report() { # $1 caminho relativo  $2 saída de _menu_engine_hits
  # A mensagem tem de ENSINAR: quem esbarrar nela pode não conhecer a história.
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

# O prazo da isenção, cobrado por máquina.
if [ -n "$MENU_EXEMPT" ] && [ -z "$(_menu_engine_hits "$ROOT/$MENU_EXEMPT" 'motor+ancora')" ]; then
  no "a isenção de $MENU_EXEMPT venceu: o motor antigo já saiu de lá — apague MENU_EXEMPT para a Regra 1 passar a valer nele também"
  me_ok=0
fi

# Regra 4 — um teste que nunca falhou não é um teste. Sem este caso, um erro no grep
# deixaria a guarda passando para sempre sem verificar nada. Fabricamos o caso real,
# um menu novo escrito do zero em OUTRO arquivo, e exigimos que seja reprovado. Os
# padrões entram por marcadores (@L@, @A@…) trocados na hora, justamente para que
# ESTAS linhas aqui não disparem a guarda que elas testam.
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

# E o oposto, também por máquina: os MESMOS padrões, comentados, não podem reprovar.
# É isso que mantém a documentação da armadilha viva dentro do código.
sed 's/^/# /' "$MENUBAD" >"$MENUBAD.commented"
[ -z "$(_menu_engine_hits "$MENUBAD.commented" 'motor+ancora')" ] \
  || { no "a guarda reprovou linhas de comentário: a documentação da armadilha não pode derrubar o build"; me_ok=0; }
rm -f "$MENUBAD" "$MENUBAD.commented"

# A guarda impede; a documentação orienta. Quem esbarra no teste vai procurar o porquê.
grep -q 'menu_read_key' "$ROOT/CONTRIBUTING.md" \
  || { no "CONTRIBUTING.md não registra que o motor do menu mora em $MENU_OWNER"; me_ok=0; }
# CLAUDE.md não é versionado (está no .gitignore), então no CI ele nem existe:
# exigi-lo lá reprovaria o build por um arquivo ausente. Cobra-se onde ele existe.
if [ -f "$ROOT/CLAUDE.md" ] && ! grep -q 'menu_read_key' "$ROOT/CLAUDE.md"; then
  no "CLAUDE.md não registra a armadilha do motor de menu duplicado"; me_ok=0
fi
grep -q 'POR QUE ESTE ARQUIVO EXISTE' "$ROOT/lib/menu.sh" \
  || { no "lib/menu.sh perdeu o comentário que explica por que ele é único"; me_ok=0; }

[ "$me_ok" = 1 ] && ok "motor do menu não duplicado, com a guarda provada em arquivo forjado"

# ---------------------------------------------------------------------------
echo "20) Sequência CSI mais longa que 2 bytes não vaza tecla fantasma (OAV2-25)"
# O alvo não é um terminal específico: Shift/Ctrl/Alt+seta chegam com MAIS de 2
# bytes depois do ESC em toda plataforma que o Orchestra roda (macOS, Linux,
# WSL), só que cada terminal escolhe uma codificação. menu_read_key só lia 2 e
# deixava a sobra no buffer — o giro SEGUINTE do laço lia aquilo como tecla
# SOLTA, e uma letra vinculada a atalho (o 'D' de qualquer Esquerda-com-
# modificador, o 'A' de qualquer Cima-com-modificador) disparava sozinha: 'd'
# cai no ramo de apagar o agente sob o cursor — hoje para na confirmação da
# OAV2-27 (antes dela, apagava direto) —, 'a' abre o prompt de adicionar.
# tests/menu_ghost_pty.py cobre as duas famílias de codificação — CSI com
# parâmetro ('\e[1;3D', comum em Linux/WSL) e ESC-prefixado ('\e\e[D', tmux/
# screen/xterm/macOS) — mais Delete/PageUp/F5 (terminador '~'), o protocolo de
# teclado do kitty (CSI 'u') e SS3 em modo aplicação. Os bytes vão direto pro
# pty, então o teste roda igual em qualquer terminal, inclusive no CI ubuntu.
# Dois casos a mais (space_in_csi, long_params) vieram da REVISÃO da OAV2-25:
# um espaço dentro da CSI sem 'IFS=' virava variável vazia, e o teto de 16
# bytes de parâmetro ficava raspando o produtor real mais longo (mouse SGR,
# 15 bytes) — nenhuma tecla de teclado emite essas formas hoje, mas o modo de
# falha é o mesmo, então ficam como regressão conhecida.
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

  # Regra 4 de novo (caso 19): um teste que nunca falhou não é um teste. Provamos
  # que ESTA matriz pega reproduzindo o roteiro inteiro contra uma cópia com o
  # motor de ANTES da OAV2-25 ('read -rsn2', sem drenagem do resto da sequência)
  # — tem de reprovar do mesmo jeito que reprovaria em produção. shift_up e
  # ctrl_left (OAV2-26) entram nesta lista pelo mesmo motivo de shift_left/
  # ctrl_up: a sobra é 'A'/'D' de verdade. alt_space (OAV2-26) também entra —
  # ele já reprova sozinho SEM precisar deste motor inteiro (basta tirar o
  # 'IFS=' de lib/menu.sh:129/:146; medido), mas reprovar aqui também confirma
  # que o motor de ANTES da OAV2-25 tinha o mesmo defeito. dead_key_batch NÃO
  # entra: por inspeção, nenhuma das 13 sequências ali deixa sobra vinculada a
  # atalho, nem no motor antigo — não é regressor, é cobertura. O caso SS3
  # (ss3_up) do PROBE_CASES é a mesma história: uma seta em modo aplicação tem
  # exatamente 2 bytes depois do ESC, o mesmo tamanho fixo que o motor antigo
  # já lia. O padrão entra por marcador (@N@), pelo mesmo motivo do caso 19:
  # para não disparar a própria guarda dele ao escanear ESTE arquivo.
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
  # só os nomes que TÊM de reprovar no motor antigo — dead_key_batch e ss3_up
  # ficam de fora (ver o comentário de 'somente' em menu_ghost_pty.py:main):
  # rodá-los de novo contra a cópia antiga não prova nada e só gasta tempo.
  GK_EXPECTED="shift_left ctrl_up alt_left_csi alt_up_csi alt_left_escpfx alt_up_escpfx
                shift_up ctrl_left
                delete pageup f5 kitty_u space_in_csi long_params alt_space"
  gk_bad="$(python3 "$ROOT/tests/menu_ghost_pty.py" "$GKHOME" \
    "$(printf '%s' "$GK_EXPECTED" | tr -s ' \n' ',')" 2>/dev/null)"
  missing_regressions=""
  for expected in $GK_EXPECTED; do
    case "$gk_bad" in
      # '=FAIL' logo depois do NOME, não em qualquer lugar do blob inteiro —
      # senão o FAIL de outro caso bastaria para dar falso positivo aqui.
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
# O ponto cego que tests/menu_pty.py (caso 15) sempre deixou: nunca apertava 'a'
# (adicionar, grava no team.json na hora), 'd' (remover, idem), Espaço (troca de
# IA) nem Enter numa linha de agente — só a seta ↓ até '+ adicionar agente' e
# 'q'. tests/menu_compose_pty.py dirige esses quatro fluxos por pty de verdade e
# confere o EFEITO no team.json (e no prompt gerado, no caso do 'a'), não a tela.
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
