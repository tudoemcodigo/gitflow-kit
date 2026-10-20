#!/bin/sh
# core/lock.sh: travamento atômico guardado como ref git (refs/gitflow/lock/NOME) no remoto origin.
# Uso: lock.sh pegar NOME [ESPERA_S] | soltar NOME | forcar-soltar NOME | dono NOME
# Saídas: pegar 0 ok / 75 ocupado; soltar 1 se outro dono; comando inválido 2.
# Env: GITFLOW_RUN_ID (obrigatório p/ pegar/soltar), GITFLOW_RUN_URL, GITFLOW_LOCK_INTERVALO (s, padrão 10).
BOT="-c user.name=gitflow-bot -c user.email=${BOT_EMAIL:-gitflow-bot@users.noreply.github.com}"
INTERVALO=${GITFLOW_LOCK_INTERVALO:-10}

uso() { echo "uso: lock.sh pegar NOME [ESPERA_S] | soltar NOME | forcar-soltar NOME | dono NOME" >&2; exit 2; }
exige_run() { [ -n "${GITFLOW_RUN_ID:-}" ] || { echo "GITFLOW_RUN_ID não definido" >&2; exit 1; }; }

# sha do commit do lock no remoto (vazio se livre)
sha_remoto() { git ls-remote origin "$REF" | awk '{print $1}'; }

# mensagem (linha do dono) do commit SHA do lock; busca do remoto
msg_dono() {
  git fetch -q origin "$REF" 2> /dev/null || return 1
  git log -1 --format=%s FETCH_HEAD
}

tentar_pegar() {
  tree=$(git hash-object -w -t tree /dev/null) || return 2
  msg="run=$GITFLOW_RUN_ID url=${GITFLOW_RUN_URL:-} desde=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # shellcheck disable=SC2086
  c=$(git $BOT commit-tree "$tree" -m "$msg") || return 2
  git push -q origin "$c:$REF" "--force-with-lease=$REF:" > /dev/null 2>&1
}

cmd=${1:-}
nome=${2:-}
[ -n "$cmd" ] || uso
[ -n "$nome" ] || uso
REF="refs/gitflow/lock/$nome"

case "$cmd" in
  pegar)
    exige_run
    espera=${3:-0}
    inicio=$(date +%s)
    while :; do
      tentar_pegar && { echo "lock $nome obtido por run=$GITFLOW_RUN_ID"; exit 0; }
      sha=$(sha_remoto)
      if [ -z "$sha" ]; then sleep 1; continue; fi   # perdeu corrida de lock de ref, mas já foi solto: tenta de novo
      agora=$(date +%s)
      if [ $((agora - inicio)) -ge "$espera" ]; then
        echo "ocupado: $(msg_dono)"
        exit 75
      fi
      sleep "$INTERVALO"
    done
    ;;
  soltar)
    exige_run
    sha=$(sha_remoto)
    [ -n "$sha" ] || { echo "livre"; exit 0; }
    msg=$(msg_dono) || { echo "falha ao ler o lock $nome" >&2; exit 1; }
    dono=$(printf '%s\n' "$msg" | sed -n 's/^run=\([^ ]*\).*/\1/p')
    if [ "$dono" != "$GITFLOW_RUN_ID" ]; then
      echo "lock $nome pertence a: $msg" >&2
      exit 1
    fi
    # lease no commit exato: um re-pegar concorrente nunca é removido
    git push -q origin ":$REF" "--force-with-lease=$REF:$sha" > /dev/null 2>&1 || { echo "falha ao soltar $nome (mudou?)" >&2; exit 1; }
    echo "lock $nome solto"
    ;;
  forcar-soltar)
    git push -q origin ":$REF" > /dev/null 2>&1 || true
    echo "lock $nome removido"
    ;;
  dono)
    [ -n "$(sha_remoto)" ] || exit 0
    msg_dono || true
    ;;
  *) uso ;;
esac
