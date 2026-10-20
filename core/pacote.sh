#!/bin/sh
# core/pacote.sh existe|build|publicar|baixar SHA [DESTINO]: um pacote por commit, compilado uma vez (P12).
# build roda scripts/build.sh da aplicação (cwd = clone da app) e zipa dist/ em $GITFLOW_SAIDA/app-<sha>.zip.
set -eu
KIT_DIR=${KIT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
export KIT_DIR
# shellcheck source=core/lib.sh
. "$KIT_DIR/core/lib.sh"
carregar_config

[ $# -ge 2 ] || { echo "uso: pacote.sh existe|build|publicar|baixar SHA [DESTINO]" >&2; exit 2; }
CMD=$1; SHA=$2
SAIDA=${GITFLOW_SAIDA:-.}
command -v artefatos_existe > /dev/null 2>&1 || para "ARTEFATOS não configurado (adapters/artefatos/<nome>.sh)."

case "$CMD" in
  existe)   artefatos_existe "$SHA" ;;
  build)
    [ -f scripts/build.sh ] || para "scripts/build.sh não encontrado na aplicação."
    rm -rf dist
    sh scripts/build.sh
    [ -d dist ] || para "scripts/build.sh não gerou dist/."
    mkdir -p "$SAIDA"
    rm -f "$SAIDA/app-$SHA.zip" "$SAIDA/app-$SHA.zip.sha256"
    zip_criar dist "$SAIDA/app-$SHA.zip"
    (cd "$SAIDA" && sha256sum "app-$SHA.zip" > "app-$SHA.zip.sha256")
    echo "Pacote gerado: $SAIDA/app-$SHA.zip" ;;
  publicar) artefatos_publicar "$SHA" "$SAIDA/app-$SHA.zip" ;;
  baixar)
    DEST=${3:-$SAIDA}; mkdir -p "$DEST"
    artefatos_baixar "$SHA" "$DEST" ;;
  *) echo "comando inválido: $CMD" >&2; exit 2 ;;
esac
