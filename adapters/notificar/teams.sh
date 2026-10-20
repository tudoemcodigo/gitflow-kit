#!/bin/sh
# adapters/notificar/teams.sh: notificacao em webhook do Teams ({"text": ...}). notificar TIPO TEXTO
# Implementacao compartilhada em _webhook.sh (webhook em $NOTIFICAR_WEBHOOK, secreto).
# shellcheck source=/dev/null
. "${KIT_DIR:-$(kit_dir)}/adapters/notificar/_webhook.sh"
