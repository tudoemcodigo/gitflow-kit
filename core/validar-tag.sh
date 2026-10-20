#!/bin/sh
# core/validar-tag.sh TAG AMB: valida a tag de uma build antes de publicar (qa|hom|prd).
# PRD revalida tudo (P9): a verdade de PRD é o último deployment success, não o que a tag diz.
set -eu
KIT_DIR=${KIT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
export KIT_DIR
# shellcheck source=core/lib.sh
. "$KIT_DIR/core/lib.sh"
carregar_config

[ $# -eq 2 ] || { echo "uso: validar-tag.sh TAG qa|hom|prd" >&2; exit 2; }
TAG=$1; AMB=$2
recusa() { echo "⛔ Tag recusada: $*" >&2; exit 1; }

case "$AMB" in qa|hom|prd) ;; *) echo "ambiente inválido: $AMB" >&2; exit 2 ;; esac
tem "$TAG" || recusa "a tag $TAG não existe."
[ "$(git cat-file -t "refs/tags/$TAG")" = tag ] || recusa "$TAG não é uma tag anotada."

case "$AMB" in
  qa|hom)
    case "$TAG" in "$AMB".*) ;; *) recusa "$TAG não é uma tag $AMB.* (ambiente $AMB)." ;; esac
    echo "✅ $TAG válida para $AMB."
    exit 0 ;;
esac

# ---------- PRD ----------
case "$TAG" in v[0-9]*.[0-9]*.[0-9]*) ;; *) recusa "$TAG não é uma versão vX.Y.Z." ;; esac
case "${TAG#v}" in *[!0-9.]*) recusa "$TAG não é uma versão vX.Y.Z." ;; esac
VER=${TAG#v}
SHA=$(git rev-parse "$TAG^{commit}")

# mesmo commit de uma hom.* "Release|Hotfix <versão>" com regressao-ok
HOM=""; ACHOU_TITULO=nao
for H in $(git tag --points-at "$SHA" -l 'hom.*'); do
  [ "$(git cat-file -t "refs/tags/$H")" = tag ] || continue   # a hom.* também precisa ser anotada
  case "$(assunto "$H")" in "Release $VER"|"Hotfix $VER") ;; *) continue ;; esac
  ACHOU_TITULO=sim
  if tem "regressao-ok/$H"; then HOM=$H; break; fi
done
[ "$ACHOU_TITULO" = sim ] || recusa "$TAG não está no mesmo commit de uma hom.* com título \"Release $VER\" ou \"Hotfix $VER\"."
[ -n "$HOM" ] || recusa "a hom.* deste commit não tem regressao-ok."

# contém a main e a versão em PRD (P9)
git rev-parse -q --verify refs/remotes/origin/main > /dev/null || recusa "P9: a ref origin/main não existe; busque (fetch) antes de validar."
git merge-base --is-ancestor origin/main "$SHA" || recusa "P9: o commit de $TAG não contém a main atual."
ATUAL=$(deploy_ultimo_ok prd) || recusa "P9: não foi possível consultar o deployment de PRD."
if [ -n "$ATUAL" ]; then
  git rev-parse -q --verify "refs/tags/$ATUAL^{commit}" > /dev/null || recusa "P9: a versão de PRD $ATUAL não existe como tag."
  git merge-base --is-ancestor "$ATUAL^{commit}" "$SHA" || recusa "P9: $TAG não contém a versão atual de PRD ($ATUAL)."
fi

# todas as entregas do manifesto: última do MR, homologada, sem nok/retirada
MANIF=$(manifesto_de "$HOM") || recusa "não foi possível ler o manifesto de $HOM."
# manifesto sem entregas é uma release vazia legítima
printf '%s\n' "$MANIF" | awk '$1 ~ /^rc\// {print $1}' | while read -r RC; do
  ID=${RC#rc/}; ID=${ID%.*}
  [ "$(ultima_rc "$ID")" = "$RC" ] || recusa "$RC não é a última entrega do $TERMO_PR (existe $(ultima_rc "$ID"))."
  [ "$(estado "$RC")" = hom-ok ] || recusa "$RC não está homologada (estado: $(estado "$RC"))."
done
echo "✅ $TAG válida para prd (hom $HOM)."
