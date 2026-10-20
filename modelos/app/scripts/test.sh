#!/bin/sh
# Modelo de testes do contrato com o kit: verificacao minima do resultado do build.
# Troque pelos testes reais da aplicacao; o contrato e: exit 0 = aprovado.
set -eu
cd "$(dirname "$0")/.."

[ -f dist/index.html ] || { echo "dist/index.html ausente: rode scripts/build.sh antes" >&2; exit 1; }
grep -qi '<html' dist/index.html || { echo "dist/index.html nao parece HTML" >&2; exit 1; }
echo "testes ok"
