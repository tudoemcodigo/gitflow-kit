#!/bin/sh
# core/fluxo-montar.sh <qa|hom|release|hotfix>: montagem sob lock (K6, P11).
# montagem-<amb> (agendada: não espera; manual: até 30 min) -> comandos (até 10 min) -> montar.sh.
# Com tag criada, montagem-<amb> continua presa para a esteira soltar no fim (nome em $GITFLOW_SAIDA/lock-montagem).
# Env: GITFLOW_RUN_ID (obrigatório), BUILD_USER_ID (vazio ou "timer" = agendada), GITFLOW_SAIDA.
set -eu
KIT_DIR=${KIT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
export KIT_DIR
ALVO=${1:?uso: fluxo-montar.sh <qa|hom|release|hotfix>}
SAIDA=${GITFLOW_SAIDA:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/gitflow}
export GITFLOW_SAIDA="$SAIDA"
mkdir -p "$SAIDA"
: > "$SAIDA/montagem.tag"
: > "$SAIDA/lock-montagem"
case "$ALVO" in
  qa|hotfix)   AMB=qa ;;
  hom|release) AMB=hom ;;
  *) echo "PARADO: ALVO inválido: $ALVO" >&2; exit 1 ;;
esac
LOCK="montagem-$AMB"
lock() { sh "$KIT_DIR/core/lock.sh" "$@"; }

case "${BUILD_USER_ID:-timer}" in timer) ESPERA=0 ;; *) ESPERA=1800 ;; esac
RC=0
OUT=$(lock pegar "$LOCK" "$ESPERA") || RC=$?
if [ "$RC" -eq 75 ]; then
  if [ "$ESPERA" -eq 0 ]; then
    echo "adiada: $AMB aguardando ${OUT#ocupado: }"
    exit 0
  fi
  echo "PARADO: $LOCK ocupado após ${ESPERA}s: ${OUT#ocupado: }" >&2
  exit 1
fi
[ "$RC" -eq 0 ] || { echo "$OUT" >&2; exit "$RC"; }

if ! lock pegar comandos 600; then
  lock soltar "$LOCK" > /dev/null || true
  exit 1
fi
RC=0
sh "$KIT_DIR/core/montar.sh" "$ALVO" || RC=$?
TAG=$(cat "$SAIDA/montagem.tag")
if [ -n "$TAG" ]; then
  echo "$LOCK" > "$SAIDA/lock-montagem"   # a esteira solta no fim
fi
RS=0
lock soltar comandos || RS=$?
if [ -z "$TAG" ]; then lock soltar "$LOCK" || RS=$?; fi
[ "$RC" -eq 0 ] || exit "$RC"
[ "$RS" -eq 0 ] || { echo "PARADO: falha ao soltar lock (código $RS)" >&2; exit 1; }
