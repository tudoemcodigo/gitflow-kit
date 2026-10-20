#!/bin/sh
# exige-membro.sh GRUPO...: BUILD_USER_ID precisa ser membro de algum dos grupos (Teams). Roda com cwd = clone da aplicacao.
# Um grupo pode ser dado como @GRUPO_QA, @GRUPO_NEGOCIO, @GRUPO_TL ou @GRUPO_RM: vale o do ambiente/.gitflow.env
# (padroes qa, negocio, tech-leads, release-managers).
set -eu
KIT_DIR=${KIT_DIR:?KIT_DIR nao definido}
# shellcheck source=core/lib.sh
. "$KIT_DIR/core/lib.sh"
carregar_config
QUEM=${BUILD_USER_ID:-}
[ -n "$QUEM" ] || { echo "⛔ Recusado: quem executa nao foi informado." >&2; exit 1; }
GRUPOS=
for _g in "$@"; do
  case "$_g" in
    @GRUPO_QA)      _g=${GRUPO_QA:-qa} ;;
    @GRUPO_NEGOCIO) _g=${GRUPO_NEGOCIO:-negocio} ;;
    @GRUPO_TL)      _g=${GRUPO_TL:-tech-leads} ;;
    @GRUPO_RM)      _g=${GRUPO_RM:-release-managers} ;;
  esac
  GRUPOS="${GRUPOS:+$GRUPOS }$_g"
done
RC=0
# shellcheck disable=SC2086  # GRUPOS: nomes de Team separados por espaco (slugs, sem espacos nem curingas)
membro "$QUEM" $GRUPOS || RC=$?
if [ "$RC" -ne 0 ]; then
  echo "⛔ Recusado: @$QUEM nao pertence a: $GRUPOS" >&2
  exit 1
fi
