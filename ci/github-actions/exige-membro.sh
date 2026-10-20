#!/bin/sh
# exige-membro.sh GRUPO...: BUILD_USER_ID precisa ser membro de algum dos grupos (Teams). Roda com cwd = clone da aplicacao.
set -eu
KIT_DIR=${KIT_DIR:?KIT_DIR nao definido}
# shellcheck source=core/lib.sh
. "$KIT_DIR/core/lib.sh"
carregar_config
QUEM=${BUILD_USER_ID:-}
[ -n "$QUEM" ] || { echo "⛔ Recusado: quem executa nao foi informado." >&2; exit 1; }
RC=0
membro "$QUEM" "$@" || RC=$?
if [ "$RC" -ne 0 ]; then
  echo "⛔ Recusado: @$QUEM nao pertence a: $*" >&2
  exit 1
fi
