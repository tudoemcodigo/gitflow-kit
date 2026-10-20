#!/bin/sh
# disparar-montar.sh: depois do PRD, remonta QA e HOM (FORCAR=true) disparando o workflow da aplicacao.
# Env: MONTAR_WORKFLOW (arquivo na app, ex.: gitflow.yml), MONTAR_REF (padrao main). Requer permissao actions:write do App.
# Falha ao disparar so alerta: o PRD ja foi publicado.
set -eu
KIT_DIR=${KIT_DIR:?KIT_DIR nao definido}
# shellcheck source=core/lib.sh
. "$KIT_DIR/core/lib.sh"
carregar_config
ARQ=${MONTAR_WORKFLOW:-gitflow.yml}
REF=${MONTAR_REF:-main}
for ALVO in qa hom; do
# shellcheck disable=SC2016  # $ref/$alvo são variáveis do jq
  CORPO=$(jqb -nc --arg ref "$REF" --arg alvo "$ALVO" '{ref: $ref, inputs: {ALVO: $alvo, FORCAR: "true"}}')
  if gh_api POST "/repos/${GITHUB_REPOSITORY:?}/actions/workflows/$ARQ/dispatches" "$CORPO" > /dev/null; then
    echo "montagem de $ALVO disparada."
  else
    msg="Nao foi possivel disparar a montagem de $ALVO apos o PRD: rode-a manualmente (FORCAR)."
    echo "$msg" >&2
    if command -v notificar > /dev/null 2>&1; then notificar alerta "$msg" || true; fi
  fi
done
