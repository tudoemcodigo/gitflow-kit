#!/bin/sh
# reagir.sh COMMENT_ID CONTENT: reacao (eyes, +1, -1...) ao comentario do comando. Falha de reacao nunca derruba o fluxo.
set -eu
KIT_DIR=${KIT_DIR:?KIT_DIR nao definido}
[ $# -eq 2 ] || { echo "uso: reagir.sh COMMENT_ID CONTENT" >&2; exit 2; }
# shellcheck source=adapters/provider/github.sh
. "$KIT_DIR/adapters/provider/github.sh"
CORPO=$(command jq -nc --arg c "$2" '{content: $c}')
gh_api POST "/repos/${GITHUB_REPOSITORY:?}/issues/comments/$1/reactions" "$CORPO" > /dev/null || echo "aviso: reacao $2 nao registrada." >&2
exit 0
