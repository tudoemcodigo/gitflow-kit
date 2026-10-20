#!/bin/sh
# core/regressao.sh HOM_TAG ok|falhou ISSUE: o QA registra o resultado da regressão da preview publicada na HOM.
# Variáveis: BUILD_USER_ID, GRUPO_QA. "ok" cria regressao-ok/HOM_TAG; "falhou" só avisa a issue.
set -eu
KIT_DIR=${KIT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
export KIT_DIR
# shellcheck source=core/lib.sh
. "$KIT_DIR/core/lib.sh"
carregar_config

[ $# -eq 3 ] || { echo "uso: regressao.sh HOM_TAG ok|falhou ISSUE" >&2; exit 2; }
HOM_TAG=$1; RESULTADO=$2; ISSUE=$3
GRUPO_QA=${GRUPO_QA:-qa}
QUEM=${BUILD_USER_ID:-}
recusa() { echo "⛔ Regressão recusada: $*" >&2; exit 1; }

case "$RESULTADO" in ok|falhou) ;; *) recusa "resultado inválido: $RESULTADO (use ok ou falhou)." ;; esac
[ -n "$QUEM" ] || recusa "quem registra não foi informado."
membro "$QUEM" "$GRUPO_QA" || recusa "@$QUEM não pertence a: $GRUPO_QA."

git fetch --quiet --force --tags origin '+refs/heads/*:refs/remotes/origin/*' || para "não foi possível buscar tags e branches de origin."

case "$HOM_TAG" in hom.*) ;; *) recusa "$HOM_TAG não é uma tag hom.*." ;; esac
tem "$HOM_TAG" || recusa "a tag $HOM_TAG não existe."
[ "$(git cat-file -t "refs/tags/$HOM_TAG")" = tag ] || recusa "$HOM_TAG não é uma tag anotada."
# a regressão vale para a preview publicada e verificada na HOM (mesma regra do decidir)
[ "$(publicada hom || true)" = "$HOM_TAG" ] || recusa "$HOM_TAG não está publicada na HOM."
[ "$(deploy_ultimo hom)" = "$HOM_TAG success" ] || recusa "$HOM_TAG não está verificada na HOM (último deployment: $(deploy_ultimo hom))."

if [ "$RESULTADO" = falhou ]; then
  issue_comentar "$ISSUE" "❌ Regressão de \`$HOM_TAG\` **falhou** (registrada por @$QUEM). Reprove a entrega culpada com /reprovar-hom e monte a release de novo." || true
  echo "Regressão de $HOM_TAG registrada como falhou (nenhuma tag criada)."
  exit 0
fi

# idempotência: vale o que está na origin (uma tag só local, de uma tentativa que falhou, é refeita)
NA_ORIGIN=$(git ls-remote --tags origin "refs/tags/regressao-ok/$HOM_TAG") || para "não foi possível consultar as tags de origin."
if [ -n "$NA_ORIGIN" ]; then
  echo "regressao-ok/$HOM_TAG já registrada."
  exit 0
fi
if tem "regressao-ok/$HOM_TAG"; then git tag -d "regressao-ok/$HOM_TAG" > /dev/null; fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
trap 'exit 1' INT TERM
{
  printf 'Regressão OK de %s\n\n' "$HOM_TAG"
  printf 'por @%s\nissue %s\n' "$QUEM" "$ISSUE"
} > "$TMP/msg"
# shellcheck disable=SC2086  # $BOT são opções -c separadas por espaço
git $BOT tag -a --cleanup=verbatim "regressao-ok/$HOM_TAG" "$HOM_TAG^{commit}" -F "$TMP/msg"
if ! git push -q origin "refs/tags/regressao-ok/$HOM_TAG"; then
  git tag -d "regressao-ok/$HOM_TAG" > /dev/null
  echo "⛔ Regressão recusada: não foi possível enviar regressao-ok/$HOM_TAG." >&2
  exit 1
fi
issue_comentar "$ISSUE" "✅ Regressão de \`$HOM_TAG\` **OK** (registrada por @$QUEM). O Release Manager já pode criar a versão." || true
echo "regressao-ok/$HOM_TAG registrada."
