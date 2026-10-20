#!/bin/sh
# core/criar-rc.sh: /entregar. Confere o portão de entrada e cria rc/<ID>.N no último commit do PR.
# Variáveis: MR_IID, AUTOR, NOTA (opcional) + as do .gitflow.env. Roda com cwd = clone da aplicação.
set -eu
KIT_DIR=${KIT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
export KIT_DIR
# shellcheck source=core/lib.sh
. "$KIT_DIR/core/lib.sh"
carregar_config

: "${MR_IID:?MR_IID não definido}"
: "${AUTOR:?AUTOR não definido}"
NOTA=${NOTA:-}

recusa() { recusa_pr "$MR_IID" "Entrega recusada" "$1"; }

MR=$(pr_get "$MR_IID")
SRC=$(printf '%s' "$MR" | jqb -r .source_branch)
SHA=$(printf '%s' "$MR" | jqb -r .sha)

# nome da branch: hotfix só como hotfix/X.Y.Z; demais pelo padrão do ID
case "$SRC" in
  hotfix/*) printf '%s\n' "$SRC" | grep -Eq '^hotfix/[0-9]+\.[0-9]+\.[0-9]+$' || recusa "use hotfix/X.Y.Z" ;;
esac
ID=$(id_da_branch "$SRC")
[ -n "$ID" ] || recusa "nome de branch fora do padrão (feature/ABC-123-descricao)"

[ "$(printf '%s' "$MR" | jqb -r .target_branch)" = main ] \
  || recusa "o MR precisa apontar para a main (sub-branch de épico entrega pelo MR do épico)"
[ "$(printf '%s' "$MR" | jqb -r .draft)" = false ] || recusa "o MR está em rascunho (draft)"
DONO=$(printf '%s' "$MR" | jqb -r .author)
if [ "$AUTOR" != "$DONO" ]; then
  membro "$AUTOR" "${GRUPO_TL:-tech-leads}" || recusa "só o autor do MR ou um Tech Lead pode entregar"
fi
git fetch --quiet --force --tags origin main "$SRC"

# 0. um ID, um MR; um hotfix por vez
LISTA=$(mrs_abertos)
CONFLITO=$(printf "%s\n" "$LISTA" | while read -r I B _; do
  [ -n "$I" ] || continue
  [ "$I" != "$MR_IID" ] || continue
  [ "$(id_da_branch "$B")" != "$ID" ] || echo "!$I usa o mesmo ID $ID"
  case "$SRC:$B" in
    hotfix/*:hotfix/*)
      R=$(ultima_rc "$(id_da_branch "$B")")
      if [ -n "$R" ] && [ "$(estado "$R")" != retirada ]; then echo "hotfix !$I ainda ativo"; fi ;;
  esac
done | tr '\n' ' ')
[ -z "$CONFLITO" ] || recusa "$CONFLITO"

# 1. contém tudo o que está em PRD (verdade de PRD = último deployment com sucesso)
PRD=$(deploy_ultimo_ok prd)
git merge-base --is-ancestor origin/main "$SHA" || recusa "a branch não contém a main. Rode git rebase origin/main"
[ -z "$PRD" ] || git merge-base --is-ancestor "$PRD" "$SHA" || recusa "a branch não contém a versão em PRD ($PRD)"
# 1b. não carrega código de outra entrega que ainda não está na main
for T in $(git tag -l 'rc/*' --no-merged origin/main --merged "$SHA"); do
  case "$T" in
    rc/"$ID".*) ;;
    *) recusa "a branch contém a entrega $T, de outro MR, que ainda não está em PRD. Use entrega única (épico) ou espere ela ir para PRD" ;;
  esac
done

# 2. pipeline verde no último commit
[ "$(printf '%s' "$MR" | jqb -r '.pipeline_sha // ""')" = "$SHA" ] \
  && [ "$(printf '%s' "$MR" | jqb -r '.pipeline_status // ""')" = success ] \
  || recusa "o pipeline do último commit não está verde"

# 3. code review: alguém que não é o autor, sobre o último commit
DEMO_SEM_REVIEW=nao
if ! aprovado_por_outro "$MR_IID" "$SHA" "$DONO"; then
  if [ "$MODO_DEMO" = sim ]; then
    DEMO_SEM_REVIEW=sim
  else
    recusa "falta aprovação de code review (de outra pessoa, depois do último commit)"
  fi
fi

# 4. template preenchido
DESC=$(printf '%s' "$MR" | jqb -r '.description // ""' | tr -d '\015')
for S in "Critério de aceite" "Como testar"; do
  printf '%s\n' "$DESC" | awk -v s="## $S" '$0==s {f=1; next} /^## / {f=0} f && NF && !/^\(/' | grep -q . \
    || recusa "a seção \"$S\" do MR está vazia"
done
if printf '%s\n' "$DESC" | grep -q -- '- \[ \]'; then recusa "há itens do autoteste sem marcar"; fi

# 5. a entrega anterior: nova entrega de algo aprovado exige confirmação
ANT=$(ultima_rc "$ID")
if [ -n "$ANT" ]; then
  if [ "$(git rev-parse "$ANT^{commit}")" = "$SHA" ]; then recusa "este commit já é a entrega $ANT"; fi
  case "$(estado "$ANT")" in
    qa-ok|hom-ok)
      tem "hom-ajuste/${ANT#rc/}" || printf '%s\n' "$NOTA" | grep -qw confirmo || recusa \
        "a entrega $ANT está aprovada ($(estado "$ANT")). Uma nova entrega tira a branch da HOM e da release até o QA aprovar de novo. Para seguir, comente: /entregar confirmo" ;;
  esac
fi

# 6. cria a entrega
N=${ANT##*.}
TAG="rc/$ID.$(( ${N:-0} + 1 ))"
# shellcheck disable=SC2086  # $BOT são opções -c separadas por espaço
git $BOT tag -a --cleanup=verbatim "$TAG" "$SHA" -m "Entrega de $ID (MR !$MR_IID) por @$AUTOR"
git push -q origin "refs/tags/$TAG"
if [ "$DEMO_SEM_REVIEW" = sim ]; then
  pr_comentar "$MR_IID" "⚠️ MODO_DEMO: code review de outra pessoa dispensado nesta entrega (só na demonstração)." || true
fi

# 7. espelho no PR: correção de algo reprovado (ou ajuste) ganha reteste expresso
espelhar "$MR_IID" "$TAG"
pr_rotular "$MR_IID" "" "Montagem::Conflito,Montagem::Fila,Suspeita de checagem,Reteste expresso"
if [ -n "$ANT" ]; then
  case "$(estado "$ANT")" in qa-nok|hom-nok) pr_rotular "$MR_IID" "Reteste expresso" "" ;; esac
  if tem "hom-ajuste/${ANT#rc/}"; then pr_rotular "$MR_IID" "Reteste expresso" ""; fi
fi
pr_comentar "$MR_IID" "📦 Entrega **$TAG** criada ($(printf '%s' "$SHA" | cut -c1-8)). Entra na próxima montagem do QA."
