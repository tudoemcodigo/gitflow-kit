#!/bin/sh
# adapters/deploy/pasta.sh: "deploy" em pasta ($DEPLOY_DIR/<amb>/) com version.json.

_deploy_amb() {   # só ambientes conhecidos: AMB vazio apagaria o DEPLOY_DIR inteiro
  case "$1" in qa|hom|prd) ;; *) echo "ambiente inválido: '$1'" >&2; return 1 ;; esac
}

deploy_instalar() {   # AMB SHA VERSAO ZIP
  : "${DEPLOY_DIR:?DEPLOY_DIR não definido}"
  _deploy_amb "$1" || return 1
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

deploy_saude() {   # AMB [SHA]: com SHA, o version.json também precisa tê-lo
  : "${DEPLOY_DIR:?DEPLOY_DIR não definido}"
  _deploy_amb "$1" || return 1
  [ -f "$DEPLOY_DIR/$1/version.json" ] || return 1
  [ -z "${2:-}" ] || [ "$(jqb -r '.sha // empty' "$DEPLOY_DIR/$1/version.json" 2> /dev/null)" = "$2" ]
}
