#!/bin/sh
# adapters/notificar/console.sh: notificação no console. notificar TIPO TEXTO
notificar() {
  printf '[%s] %s\n' "$1" "$2"
}
