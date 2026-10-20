#!/bin/sh
# adapters/notificar/teams.sh: notificacao em webhook do Microsoft Teams ({"text": ...}). notificar TIPO TEXTO
# shellcheck disable=SC2016  # $var dentro de filtros jq nao e expansao de shell
# O webhook ($NOTIFICAR_WEBHOOK) e segredo: vai ao curl por arquivo de configuracao (-K), nunca no argv.
_webhook_post() {   # TEXTO
  : "${NOTIFICAR_WEBHOOK:?NOTIFICAR_WEBHOOK não definido}"
  _wh_b=$(jqb -nc --arg text "$1" '{text: $text}') || return 1
  _wh_c=$(mktemp) || return 1
  ( umask 077; printf 'url = "%s"\n' "$NOTIFICAR_WEBHOOK" > "$_wh_c" )
  _wh_rc=0
  printf '%s' "$_wh_b" | curl -sS -f -K "$_wh_c" -X POST -H 'Content-Type: application/json' \
    --data-binary @- > /dev/null || _wh_rc=$?
  rm -f "$_wh_c"
  return "$_wh_rc"
}
notificar() {
  _webhook_post "[$1] $2" || { echo "notificação não enviada (webhook)." >&2; return 1; }
}
