#!/bin/sh
# adapters/deploy/pasta.sh: "deploy" em pasta ($DEPLOY_DIR/<amb>/) com version.json.

deploy_instalar() {   # AMB SHA VERSAO ZIP
  : "${DEPLOY_DIR:?DEPLOY_DIR não definido}"
  [ -f "$4" ] || { echo "zip não encontrado: $4" >&2; return 1; }
  mkdir -p "$DEPLOY_DIR"
  _novo=$(mktemp -d "$DEPLOY_DIR/.novo.XXXXXX") || return 1
  if ! zip_extrair "$4" "$_novo"; then rm -rf "$_novo"; return 1; fi
  # shellcheck disable=SC2016  # $versao etc. são variáveis do jq
  jqb -n --arg versao "$3" --arg sha "$2" --arg data "$(date +%FT%T%z)" \
    '{versao: $versao, sha: $sha, data: $data}' > "$_novo/version.json"
  rm -rf "${DEPLOY_DIR:?}/$1"
  mv "$_novo" "$DEPLOY_DIR/$1"
}

deploy_saude() {   # AMB
  : "${DEPLOY_DIR:?DEPLOY_DIR não definido}"
  [ -f "$DEPLOY_DIR/$1/version.json" ]
}
