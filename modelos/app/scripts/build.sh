#!/bin/sh
# Modelo de build do contrato com o kit: gera dist/ a partir de src/.
# Troque o corpo pelo build real da aplicacao; o contrato e: terminar com exit 0 e deixar o resultado em dist/.
set -eu
cd "$(dirname "$0")/.."

[ -d src ] || { echo "src/ nao existe: nada para construir" >&2; exit 1; }
rm -rf dist
mkdir -p dist
cp -R src/. dist/
echo "build ok: dist/ gerado a partir de src/"
