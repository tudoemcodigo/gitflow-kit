#!/bin/sh
# core/resolver-conflito.sh <qa|hom|release|hotfix> | --publicar
# ALVO: reproduz a montagem localmente (sem tag nem push) e para no primeiro conflito, para resolver à mão.
#       Depois de 'git add' + 'git commit --no-edit', o rerere guarda a resolução em .git/rr-cache.
# --publicar: envia o conteúdo de .git/rr-cache para a branch meta/rerere (novo commit), que as
#       próximas montagens carregam. Na release a resolução nunca é aplicada (conflito de verdade).
set -eu
KIT_DIR=${KIT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
export KIT_DIR
# shellcheck source=core/lib.sh
. "$KIT_DIR/core/lib.sh"

case "${1:-}" in
  --publicar)
    GD=$(git rev-parse --absolute-git-dir)
    if [ ! -d "$GD/rr-cache" ] || [ -z "$(ls -A "$GD/rr-cache")" ]; then
      para "não há resoluções em .git/rr-cache para publicar."
    fi
    git fetch --quiet origin '+refs/heads/*:refs/remotes/origin/*'   # falha aborta (set -e)
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    trap 'exit 1' INT TERM
    export GIT_INDEX_FILE="$TMP/index"
    PAI=$(git rev-parse -q --verify origin/meta/rerere || true)
    if [ -n "$PAI" ]; then git read-tree "$PAI"; fi   # parte da árvore publicada: não perde resoluções antigas
    git --work-tree="$GD/rr-cache" add --ignore-removal -f .
    TREE=$(git write-tree)
    # shellcheck disable=SC2086  # $BOT são opções -c separadas por espaço
    C=$(git $BOT commit-tree "$TREE" ${PAI:+-p "$PAI"} -m "rerere: resoluções publicadas")
    unset GIT_INDEX_FILE
    git push -q origin "$C:refs/heads/meta/rerere"
    echo "Resoluções publicadas em meta/rerere ($(git rev-parse --short "$C"))."
    ;;
  qa | hom | release | hotfix)
    GITFLOW_LOCAL=sim exec sh "$KIT_DIR/core/montar.sh" "$1" ;;
  *) echo "uso: resolver-conflito.sh <qa|hom|release|hotfix> | --publicar" >&2; exit 2 ;;
esac
