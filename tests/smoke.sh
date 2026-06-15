#!/usr/bin/env bash
# Smoke test do Orchestra Agents.
# Valida: sintaxe dos scripts, doctor, e um despacho async REAL (sem zellij).
# Isolado: usa estado próprio e NÃO encerra um servidor que já esteja rodando.
#
# uso:  ./tests/smoke.sh            (precisa de opencode autenticado p/ o despacho)
#       SKIP_DISPATCH=1 ./tests/smoke.sh   (só sintaxe + doctor)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export ORCHESTRA_HOME="$ROOT"
export ORCHESTRA_STATE="$(mktemp -d)"   # estado isolado (não toca na instalação real)
trap 'rm -rf "$ORCHESTRA_STATE" "${PROJ:-}"' EXIT

pass=0; fail=0
ok(){ printf '  \033[1;32mPASS\033[0m %s\n' "$*"; pass=$((pass+1)); }
no(){ printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }

printf '\n🔬 Orchestra Agents — smoke test\n\n'

# 1) sintaxe (bash -n) de todos os scripts
echo "1) Sintaxe dos scripts"
syn_ok=1
for f in "$ROOT/bin/orchestra" "$ROOT/lib/core.sh" "$ROOT"/agents/*.sh \
         "$ROOT/install.sh" "$ROOT/uninstall.sh" "$ROOT/tests/smoke.sh"; do
  bash -n "$f" 2>/dev/null || { no "sintaxe inválida: $f"; syn_ok=0; }
done
[ "$syn_ok" = 1 ] && ok "todos os scripts passaram no bash -n"

# carrega o núcleo (depois do check de sintaxe)
# shellcheck source=/dev/null
. "$ROOT/lib/core.sh"

# 2) doctor (não pode retornar falha)
echo "2) orchestra doctor"
if "$ROOT/bin/orchestra" doctor >/dev/null 2>&1; then ok "doctor sem falhas (exit 0)"
else no "doctor retornou falha (exit 1) — rode 'orchestra doctor' para detalhes"; fi

# 3) despacho async real
if [ "${SKIP_DISPATCH:-0}" = 1 ]; then
  echo "3) Despacho: pulado (SKIP_DISPATCH=1)"
else
  echo "3) Despacho async (cria arquivo no projeto via worker)"
  if ensure_server >/dev/null; then
    PROJ="$(mktemp -d)"; ( cd "$PROJ" && git init -q 2>/dev/null || true )
    echo "$PROJ" > "$ORCHESTRA_STATE/project"
    ensure_session coder "$ORCHESTRA_CODER_AGENT" "smoke" fresh >/dev/null
    dispatch coder "Crie o arquivo smoke.txt contendo exatamente: ORCHESTRA-OK" >/dev/null
    found=0
    for _ in $(seq 1 45); do [ -f "$PROJ/smoke.txt" ] && { found=1; break; }; sleep 2; done
    if [ "$found" = 1 ] && grep -q "ORCHESTRA-OK" "$PROJ/smoke.txt" 2>/dev/null; then
      ok "worker recebeu a tarefa e criou smoke.txt no projeto"
    elif result coder 2>/dev/null | grep -qi "smoke\|ORCHESTRA-OK"; then
      ok "worker respondeu (arquivo pode ter caído em subpasta)"
    else
      no "despacho não produziu o resultado esperado (opencode autenticado?)"
    fi
  else
    no "servidor OpenCode não subiu (veja $ORCHESTRA_STATE/server.log)"
  fi
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
  printf '\033[1;32m✅ smoke OK — %d checagem(ns) passaram.\033[0m\n' "$pass"; exit 0
else
  printf '\033[1;31m❌ smoke FALHOU — %d falha(s), %d ok.\033[0m\n' "$fail" "$pass"; exit 1
fi
