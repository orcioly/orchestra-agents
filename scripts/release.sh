#!/usr/bin/env bash
# Gera uma nova versão automaticamente: calcula o número (semver), atualiza o
# VERSION em bin/orchestra, faz commit, cria a tag, dá push e publica a release.
#
# uso:
#   ./scripts/release.sh patch     # 0.1.0 -> 0.1.1   (padrão)
#   ./scripts/release.sh minor     # 0.1.0 -> 0.2.0
#   ./scripts/release.sh major     # 0.1.0 -> 1.0.0
#   ./scripts/release.sh 1.2.3     # versão explícita
#   DRY_RUN=1 ./scripts/release.sh minor   # só mostra o que faria
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUMP="${1:-patch}"
CUR="$(grep -oE 'VERSION="[0-9]+\.[0-9]+\.[0-9]+"' bin/orchestra | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)"
[ -n "$CUR" ] || { echo "✖ não encontrei VERSION=\"x.y.z\" em bin/orchestra"; exit 1; }

IFS=. read -r MA MI PA <<<"$CUR"
case "$BUMP" in
  major) MA=$((MA + 1)); MI=0; PA=0; NEW="$MA.$MI.$PA" ;;
  minor) MI=$((MI + 1)); PA=0;       NEW="$MA.$MI.$PA" ;;
  patch) PA=$((PA + 1));             NEW="$MA.$MI.$PA" ;;
  [0-9]*.[0-9]*.[0-9]*)              NEW="$BUMP" ;;
  *) echo "uso: release.sh patch|minor|major|X.Y.Z"; exit 1 ;;
esac
TAG="v$NEW"

echo "🔖 versão: $CUR  ->  $NEW   (tag $TAG)"

if [ "${DRY_RUN:-0}" = 1 ]; then
  echo "[DRY_RUN] faria: bump em bin/orchestra, commit, tag $TAG, push e 'gh release create $TAG --generate-notes'"
  exit 0
fi

# checagens de segurança
git diff --quiet && git diff --cached --quiet || { echo "✖ há mudanças não commitadas — limpe a árvore antes"; exit 1; }
git rev-parse "$TAG" >/dev/null 2>&1 && { echo "✖ a tag $TAG já existe"; exit 1; }
SKIP_DISPATCH=1 ./tests/smoke.sh >/dev/null 2>&1 || { echo "✖ smoke test falhou — corrija antes de lançar"; exit 1; }

# bump da versão
sed -i.bak "s/VERSION=\"$CUR\"/VERSION=\"$NEW\"/" bin/orchestra && rm -f bin/orchestra.bak
git add bin/orchestra
git commit -q -m "🔖 chore: bump version to $TAG"
git tag -a "$TAG" -m "Orchestra Agents $TAG"
git push origin main --follow-tags

# release com notas geradas automaticamente a partir dos commits
if command -v gh >/dev/null 2>&1 && gh release create "$TAG" --verify-tag --title "$TAG" --generate-notes; then
  echo "✅ release $TAG publicada (notas geradas automaticamente)"
else
  echo "ℹ️  tag $TAG publicada. Crie a release manualmente:"
  echo "    gh release create $TAG --verify-tag --title \"$TAG\" --generate-notes"
  echo "    ou pela web: Releases -> Draft a new release -> $TAG"
fi
