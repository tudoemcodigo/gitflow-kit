#!/bin/sh
# shellcheck disable=SC2016  # $text e variavel do jq
# adapters/notificar/_webhook.sh: POST {"text": ...} em $NOTIFICAR_WEBHOOK, compartilhado por teams.sh e slack.sh.
# O webhook e segredo: vai ao curl por arquivo de configuracao (-K, modo 600, removido mesmo em INT/TERM), nunca no argv.
_webhook_post() {   # TEXTO
  : "${NOTIFICAR_WEBHOOK:?NOTIFICAR_WEBHOOK não definido}"
  _wh_b=$(jqb -nc --arg text "$1" '{text: $text}') || return 1
  (
    _wh_c=$(mktemp) || exit 1
    trap 'rm -f "$_wh_c"' EXIT INT TERM
    _wh_u=$(printf '%s' "$NOTIFICAR_WEBHOOK" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')   # escapa \ e " no formato do curl -K
    ( umask 077; printf 'url = "%s"\n' "$_wh_u" > "$_wh_c" )
    printf '%s' "$_wh_b" | curl -sS -f --max-time 30 -K "$_wh_c" -X POST -H 'Content-Type: application/json' \
      --data-binary @- > /dev/null
  )
}
notificar() {
  _webhook_post "[$1] $2" || { echo "notificação não enviada (webhook)." >&2; return 1; }
}
