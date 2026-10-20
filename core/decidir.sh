#!/bin/sh
# core/decidir.sh: /aprovar /reprovar /homologar /alteracao /ajuste /reprovar-hom /retirar
# A decisão vale para a última entrega do MR e só se ela estiver na build publicada (e verificada) no ambiente.
# Variáveis: MR_IID, NOTA, AUTOR, GRUPO_QA, GRUPO_NEGOCIO, GRUPO_TL + as do .gitflow.env.
# O texto da NOTA nunca passa por avaliação do shell: vai para a tag com -F e para o PR via provider.
set -eu
KIT_DIR=${KIT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
export KIT_DIR
# shellcheck source=core/lib.sh
. "$KIT_DIR/core/lib.sh"
carregar_config

: "${MR_IID:?MR_IID não definido}"
: "${AUTOR:?AUTOR não definido}"
NOTA=$(printf '%s\n' "${NOTA:-}" | tr -d '\015')
GRUPO_QA=${GRUPO_QA:-qa}
GRUPO_NEGOCIO=${GRUPO_NEGOCIO:-negocio}
GRUPO_TL=${GRUPO_TL:-tech-leads}

CMD=$(printf '%s\n' "$NOTA" | awk 'NR==1 {print $1; exit}')
MOTIVO=$(printf '%s\n' "$NOTA" | sed '1s#^/[a-z-]*[[:space:]]*##')
# tira linhas vazias do fim
MOTIVO=$(printf '%s' "$MOTIVO" | awk '{l[NR]=$0} END {n=NR; while (n>0 && l[n]=="") n--; for (i=1;i<=n;i++) print l[i]}')

recusa() { recusa_pr "$MR_IID" "$CMD recusado" "$1"; }

case "$CMD" in
  /aprovar)      AMB=qa;  DEC=qa-ok;      GRUPOS="$GRUPO_QA" ;;
  /reprovar)     AMB=qa;  DEC=qa-nok;     GRUPOS="$GRUPO_QA" ;;
  /homologar)    AMB=hom; DEC=hom-ok;     GRUPOS="$GRUPO_NEGOCIO" ;;
  /alteracao)    AMB=hom; DEC=hom-ok;     GRUPOS="$GRUPO_NEGOCIO" ;;
  /ajuste)       AMB=hom; DEC=hom-ajuste; GRUPOS="$GRUPO_NEGOCIO $GRUPO_QA" ;;
  /reprovar-hom) AMB=hom; DEC=hom-nok;    GRUPOS="$GRUPO_NEGOCIO" ;;
  /retirar)      AMB=;    DEC=retirada;   GRUPOS="$GRUPO_NEGOCIO $GRUPO_TL" ;;
  *) exit 0 ;;
esac
# shellcheck disable=SC2086  # $GRUPOS é uma lista separada por espaço
membro "$AUTOR" $GRUPOS || recusa "@$AUTOR não pertence a: $GRUPOS"
case "$CMD" in
  /aprovar | /homologar) ;;
  *) [ -n "$MOTIVO" ] || recusa "informe o motivo (no /alteracao, a tarefa nova)" ;;
esac

git fetch --quiet --force --tags origin '+refs/heads/*:refs/remotes/origin/*'
MR=$(pr_get "$MR_IID")
SRC=$(printf '%s' "$MR" | jqb -r .source_branch)
RC=$(ultima_rc "$(id_da_branch "$SRC")")
[ -n "$RC" ] || recusa "o MR não tem entrega"
E=$(estado "$RC")
BUILD="-"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
trap 'exit 1' INT TERM

# P2: aprovação vale para a entrega publicada e verificada no ambiente.
# Reprovação também vale para a última build montada do ambiente (ex.: falhou nos testes ou gates antes do deploy).
if [ -n "$AMB" ]; then
  BUILD=$(publicada "$AMB" || true)
  manifesto_de "$BUILD" > "$TMP/m"
  if [ -n "$BUILD" ] && contem "$TMP/m" "$RC" && [ "$(deploy_ultimo "$AMB")" = "$BUILD success" ]; then
    :
  else
    case "$DEC" in
      qa-nok | hom-nok)
        BUILD=$(ultima_build "$AMB")
        manifesto_de "$BUILD" > "$TMP/m"
        { [ -n "$BUILD" ] && contem "$TMP/m" "$RC"; } \
          || recusa "a entrega $RC não está na build publicada nem na última montada de $AMB" ;;
      *) recusa "a entrega $RC não está na build publicada e verificada em $AMB; decida depois da próxima montagem" ;;
    esac
  fi
fi

# a mesma decisão não se repete
if tem "$DEC/${RC#rc/}"; then recusa "$CMD já foi registrado para $RC"; fi
# transições permitidas ("nok" pode corrigir um "ok" dado por engano; o contrário não)
case "$DEC:$E" in
  qa-ok:teste | qa-nok:teste | qa-nok:qa-ok) ;;
  hom-ok:qa-ok | hom-nok:qa-ok | hom-nok:hom-ok | hom-ajuste:qa-ok) ;;
  retirada:qa-ok | retirada:hom-ok | retirada:teste) ;;
  *) recusa "a entrega $RC está em '$E'; $CMD não se aplica" ;;
esac

{
  printf '%s por @%s na build %s\n\n' "$CMD" "$AUTOR" "$BUILD"
  printf '%s\n' "$MOTIVO"
} > "$TMP/msg"
# shellcheck disable=SC2086  # $BOT são opções -c separadas por espaço
git $BOT tag -a --cleanup=verbatim "$DEC/${RC#rc/}" "$RC^{commit}" -F "$TMP/msg"
git push -q origin "refs/tags/$DEC/${RC#rc/}"
espelhar "$MR_IID" "$RC"
case "$DEC" in qa-ok | qa-nok) pr_rotular "$MR_IID" "" "Reteste expresso,Suspeita de checagem" ;; esac
pr_comentar "$MR_IID" "✅ **$CMD** registrado para **$RC** (build \`$BUILD\`) por @$AUTOR. $MOTIVO"
