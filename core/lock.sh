#!/bin/sh
# core/lock.sh: travamento atômico guardado como ref git (refs/gitflow/lock/NOME) no remoto origin.
# Uso: lock.sh pegar NOME [ESPERA_S] | soltar NOME | forcar-soltar NOME | dono NOME
# Saídas: 0 ok; 75 ocupado (pegar); 1 outro dono (soltar); 2 uso/argumento inválido;
#         3 erro de acesso ao remoto (nunca confundir com "livre" ou "ocupado").
# Env: GITFLOW_RUN_ID (obrigatório p/ pegar/soltar), GITFLOW_RUN_URL, GITFLOW_LOCK_INTERVALO (s, padrão 10).
# As datas ficam em UTC de propósito (este script não usa o fuso local do kit).
set -eu

BOT="-c user.name=gitflow-bot -c user.email=${BOT_EMAIL:-gitflow-bot@users.noreply.github.com}"
INTERVALO=${GITFLOW_LOCK_INTERVALO:-10}

uso() { echo "uso: lock.sh pegar NOME [ESPERA_S] | soltar NOME | forcar-soltar NOME | dono NOME" >&2; exit 2; }
exige_run() { [ -n "${GITFLOW_RUN_ID:-}" ] || { echo "GITFLOW_RUN_ID não definido" >&2; exit 1; }; }
numero() { case "$1" in '' | *[!0-9]*) echo "valor não numérico: '$1'" >&2; exit 2 ;; esac; }
acesso() { echo "erro de acesso ao remoto: $*" >&2; exit 3; }

# sha do commit do lock no remoto (vazio se livre); falha se o remoto não responde
sha_remoto() {
  out=$(git ls-remote origin "$REF") || return 1
  printf '%s\n' "$out" | awk '{print $1}'
}

# baixa o lock para um ref de cache; define SHA e MSG a partir desse único fetch
ler_lock() {
  git fetch -q origin "+$REF:$CACHE" 2> /dev/null || return 1
  SHA=$(git rev-parse "$CACHE") || return 1
  MSG=$(git log -1 --format=%s "$CACHE") || return 1
}

tentar_pegar() {
  tree=$(git hash-object -w -t tree /dev/null) || acesso "não foi possível criar a árvore vazia"
  msg="run=$GITFLOW_RUN_ID url=${GITFLOW_RUN_URL:-} desde=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # shellcheck disable=SC2086
  c=$(git $BOT commit-tree "$tree" -m "$msg") || acesso "não foi possível criar o commit do lock"
  PUSH_ERR=
  if PUSH_ERR=$(git push -q origin "$c:$REF" "--force-with-lease=$REF:" 2>&1); then return 0; fi
  return 1
}

cmd=${1:-}
nome=${2:-}
[ -n "$cmd" ] || uso
[ -n "$nome" ] || uso
REF="refs/gitflow/lock/$nome"
CACHE="refs/gitflow/lock-cache/$nome"
git check-ref-format "$REF" || { echo "nome de lock inválido: '$nome'" >&2; exit 2; }
numero "$INTERVALO"

case "$cmd" in
  pegar)
    exige_run
    espera=${3:-0}
    numero "$espera"
    inicio=$(date +%s)
    ausentes=0
    while :; do
      tentar_pegar && { echo "lock $nome obtido por run=$GITFLOW_RUN_ID"; exit 0; }
      sha=$(sha_remoto) || acesso "$PUSH_ERR"
      if [ -z "$sha" ]; then
        # push falhou mas o lock não existe: disputa de ref-lock ou erro de push; poucas novas tentativas
        ausentes=$((ausentes + 1))
        [ "$ausentes" -lt 3 ] || acesso "$PUSH_ERR"
        sleep 1
        continue
      fi
      ausentes=0
      restante=$((espera - ($(date +%s) - inicio)))
      if [ "$restante" -le 0 ]; then
        ler_lock || acesso "não foi possível ler o dono do lock"
        echo "ocupado: $MSG"
        exit 75
      fi
      if [ "$restante" -lt "$INTERVALO" ]; then sleep "$restante"; else sleep "$INTERVALO"; fi
    done
    ;;
  soltar)
    exige_run
    sha=$(sha_remoto) || acesso "ls-remote falhou"
    [ -n "$sha" ] || { echo "livre"; exit 0; }
    ler_lock || acesso "não foi possível ler o lock $nome"
    dono=$(printf '%s\n' "$MSG" | sed -n 's/^run=\([^ ]*\).*/\1/p')
    if [ "$dono" != "$GITFLOW_RUN_ID" ]; then
      echo "lock $nome pertence a: $MSG" >&2
      exit 1
    fi
    # lease no commit exato: um re-pegar concorrente nunca é removido
    if ! err=$(git push -q origin ":$REF" "--force-with-lease=$REF:$SHA" 2>&1); then
      echo "falha ao soltar $nome: $err" >&2
      exit 1
    fi
    echo "lock $nome solto"
    ;;
  forcar-soltar)
    sha=$(sha_remoto) || acesso "ls-remote falhou"
    [ -n "$sha" ] || { echo "livre"; exit 0; }
    if ! err=$(git push -q origin ":$REF" 2>&1); then acesso "$err"; fi
    echo "lock $nome removido"
    ;;
  dono)
    sha=$(sha_remoto) || acesso "ls-remote falhou"
    [ -n "$sha" ] || exit 0
    ler_lock || acesso "não foi possível ler o lock $nome"
    printf '%s\n' "$MSG"
    ;;
  *) uso ;;
esac
