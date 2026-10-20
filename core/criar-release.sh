#!/bin/sh
# core/criar-release.sh VERSAO HOM_TAG ISSUE: o Release Manager cria vVERSAO no commit da preview com regressao-ok.
# Variáveis: BUILD_USER_ID, GRUPO_RM. As regras de PRD são as do validar-tag.sh (rodado antes do push).
set -eu
KIT_DIR=${KIT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
export KIT_DIR
# shellcheck source=core/lib.sh
. "$KIT_DIR/core/lib.sh"
carregar_config

[ $# -eq 3 ] || { echo "uso: criar-release.sh VERSAO HOM_TAG ISSUE" >&2; exit 2; }
VERSAO=$1; HOM_TAG=$2; ISSUE=$3
GRUPO_RM=${GRUPO_RM:-release-managers}
QUEM=${BUILD_USER_ID:-}
TAG="v$VERSAO"
recusa() { echo "⛔ Release recusada: $*" >&2; exit 1; }

echo "$VERSAO" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || recusa "versão inválida: $VERSAO (use X.Y.Z)."
[ -n "$QUEM" ] || recusa "quem cria não foi informado."
membro "$QUEM" "$GRUPO_RM" || recusa "@$QUEM não pertence a: $GRUPO_RM."

git fetch --quiet --force --tags origin '+refs/heads/*:refs/remotes/origin/*' || para "não foi possível buscar tags e branches de origin."

if tem "$TAG"; then recusa "a versão $TAG já existe."; fi
case "$HOM_TAG" in hom.*) ;; *) recusa "$HOM_TAG não é uma tag hom.*." ;; esac
tem "$HOM_TAG" || recusa "a tag $HOM_TAG não existe."
[ "$(git cat-file -t "refs/tags/$HOM_TAG")" = tag ] || recusa "$HOM_TAG não é uma tag anotada."
[ "$(publicada hom || true)" = "$HOM_TAG" ] || recusa "$HOM_TAG não está publicada agora na HOM."
[ "$(deploy_ultimo hom)" = "$HOM_TAG success" ] || recusa "$HOM_TAG não está verificada na HOM (último deployment: $(deploy_ultimo hom))."
tem "regressao-ok/$HOM_TAG" || recusa "$HOM_TAG não tem regressao-ok."
case "$(assunto "$HOM_TAG")" in
  "Release $VERSAO"|"Hotfix $VERSAO") ;;
  *) recusa "o título de $HOM_TAG não é \"Release $VERSAO\" nem \"Hotfix $VERSAO\"." ;;
esac

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
trap 'exit 1' INT TERM
{
  printf '%s\n\n' "$TAG"
  printf 'preview %s\nissue %s\npor @%s\n' "$HOM_TAG" "$ISSUE" "$QUEM"
} > "$TMP/msg"
# shellcheck disable=SC2086  # $BOT são opções -c separadas por espaço
git $BOT tag -a --cleanup=verbatim "$TAG" "$HOM_TAG^{commit}" -F "$TMP/msg"
# as verificações de PRD são as do validar-tag.sh; se recusar, a tag local some e nada é enviado
if ! sh "$KIT_DIR/core/validar-tag.sh" "$TAG" prd; then
  git tag -d "$TAG" > /dev/null
  exit 1
fi
if ! git push -q origin "refs/tags/$TAG"; then
  git tag -d "$TAG" > /dev/null
  echo "⛔ Release recusada: não foi possível enviar $TAG (já existe no remoto?)." >&2
  exit 1
fi
echo "$TAG criada no commit de $HOM_TAG."
