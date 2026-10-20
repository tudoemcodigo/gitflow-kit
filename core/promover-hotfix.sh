#!/bin/sh
# core/promover-hotfix.sh QA_TAG: leva a build do hotfix aprovada no QA para a HOM (hom.* no MESMO commit).
# Imprime só o nome da tag hom.* (stdout); mensagens vão para stderr. Idempotente.
# Variáveis: BUILD_USER_ID, GRUPO_RM.
set -eu
KIT_DIR=${KIT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
export KIT_DIR
# shellcheck source=core/lib.sh
. "$KIT_DIR/core/lib.sh"
carregar_config

[ $# -eq 1 ] || { echo "uso: promover-hotfix.sh QA_TAG" >&2; exit 2; }
QA_TAG=$1
GRUPO_RM=${GRUPO_RM:-release-managers}
QUEM=${BUILD_USER_ID:-}
recusa() { echo "⛔ Promoção recusada: $*" >&2; exit 1; }

[ -n "$QUEM" ] || recusa "quem promove não foi informado."
membro "$QUEM" "$GRUPO_RM" || recusa "@$QUEM não pertence a: $GRUPO_RM."

git fetch --quiet --force --tags origin '+refs/heads/*:refs/remotes/origin/*' || para "não foi possível buscar tags e branches de origin."

case "$QA_TAG" in qa.*) ;; *) recusa "$QA_TAG não é uma tag qa.*." ;; esac
tem "$QA_TAG" || recusa "a tag $QA_TAG não existe."
[ "$(git cat-file -t "refs/tags/$QA_TAG")" = tag ] || recusa "$QA_TAG não é uma tag anotada."
TITULO=$(assunto "$QA_TAG")
case "$TITULO" in
  "Hotfix "[0-9]*.[0-9]*.[0-9]*) ;;
  *) recusa "$QA_TAG não é uma build de hotfix (título \"Hotfix X.Y.Z\"); título atual: \"$TITULO\"." ;;
esac
VER=${TITULO#Hotfix }
echo "$VER" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || recusa "versão inválida no título de $QA_TAG: $VER."
ID="hotfix-$(echo "$VER" | tr . -)"

SHA=$(git rev-parse "$QA_TAG^{commit}")
# idempotência (antes das checagens de estado, que mudam depois): vale a hom.* "Hotfix X" que está na origin;
# uma só local, de uma tentativa que falhou, é apagada e refeita
for H in $(git tag --points-at "$SHA" -l 'hom.*' --sort=creatordate); do
  [ "$(assunto "$H")" = "Hotfix $VER" ] || continue
  NA_ORIGIN=$(git ls-remote --tags origin "refs/tags/$H") || para "não foi possível consultar as tags de origin."
  if [ -n "$NA_ORIGIN" ]; then
    echo "$H já existe para $QA_TAG." >&2
    echo "$H"
    exit 0
  fi
  git tag -d "$H" > /dev/null
done

# a build precisa estar publicada e verificada no QA (mesma regra do decidir)
[ "$(publicada qa || true)" = "$QA_TAG" ] || recusa "$QA_TAG não está publicada no QA."
[ "$(deploy_ultimo qa)" = "$QA_TAG success" ] || recusa "$QA_TAG não está verificada no QA (último deployment: $(deploy_ultimo qa))."

# a entrega do hotfix precisa estar no manifesto, ser a última do MR e ter qa-ok
MANIF=$(manifesto_de "$QA_TAG")
RC=$(printf '%s\n' "$MANIF" | awk -v p="rc/$ID." 'index($1, p) == 1 {print $1; exit}')
[ -n "$RC" ] || recusa "o manifesto de $QA_TAG não tem a entrega rc/$ID.N."
[ "$(ultima_rc "$ID")" = "$RC" ] || recusa "$RC não é a última entrega do MR (existe $(ultima_rc "$ID"))."
[ "$(estado "$RC")" = qa-ok ] || recusa "$RC não tem qa-ok (estado: $(estado "$RC")); use /aprovar antes."

DATA=$(date +%F)
N=$(git tag -l "hom.$DATA.*" | awk -F. '{print $NF}' | sort -n | tail -1)
HOM="hom.$DATA.$(( ${N:-0} + 1 ))"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
trap 'exit 1' INT TERM
{
  printf 'Hotfix %s\n\n' "$VER"
  printf '%s\n' "$MANIF"
  printf 'promovida de %s por @%s\n' "$QA_TAG" "$QUEM"
} > "$TMP/msg"
# shellcheck disable=SC2086  # $BOT são opções -c separadas por espaço
git $BOT tag -a --cleanup=verbatim "$HOM" "$SHA" -F "$TMP/msg"
if ! git push -q origin "refs/tags/$HOM" >&2; then
  git tag -d "$HOM" > /dev/null
  recusa "não foi possível enviar $HOM."
fi
echo "$HOM criada no commit de $QA_TAG." >&2
echo "$HOM"
