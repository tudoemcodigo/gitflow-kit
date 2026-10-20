#!/bin/sh
# falhou.sh: decide se a falha da esteira desfaz o ambiente (spec §4.1 e §9; P15).
# Env: R_CHEC, R_REG (resultado dos jobs checagem e registrar), AMBIENTE, TAG, GITHUB_RUN_ID, KIT_DIR + as da esteira.
# - registrar falhou: o deployment ja e success; nada volta (publicar.sh e idempotente, rode de novo).
# - checagem falhou: so uma rejeicao explicita (approvals do run) volta o ambiente; expirar nao volta, locks ficam.
# - demais: core/esteira.sh falhou (volta se houve deploy; sempre solta o lock de montagem).
set -eu
KIT_DIR=${KIT_DIR:?KIT_DIR nao definido}
# shellcheck source=core/lib.sh
. "$KIT_DIR/core/lib.sh"
carregar_config
AMB=${AMBIENTE:?}
alerta() { if command -v notificar > /dev/null 2>&1; then notificar alerta "$1" || true; fi; echo "$1" >&2; }

if [ "${R_REG:-}" = failure ]; then
  alerta "O registro de $TAG em $AMB falhou, mas o deploy ja estava concluido: o ambiente nao voltou. Rode o registro de novo."
  exit 1
fi
if [ "${R_CHEC:-}" = failure ]; then
  if ! D=$(gh_api GET "/repos/${GITHUB_REPOSITORY:?}/actions/runs/${GITHUB_RUN_ID:?}/approvals"); then
    alerta "Nao foi possivel consultar as aprovacoes da checagem de $AMB ($TAG): o ambiente nao voltou e segue travado."
    exit 1
  fi
  # shellcheck disable=SC2016  # $n é variável do jq
  if ! printf '%s' "$D" | jqb -e --arg n "checagem-$AMB" 'any(.[]; .state == "rejected" and any(.environments[]?; .name == $n))' > /dev/null; then
    alerta "A checagem de $AMB ($TAG) nao foi rejeitada (expirou ou falhou por outro motivo): o ambiente nao voltou e segue travado. Faca nova checagem ou use o destravar."
    exit 1
  fi
fi
exec sh "$KIT_DIR/core/esteira.sh" falhou
