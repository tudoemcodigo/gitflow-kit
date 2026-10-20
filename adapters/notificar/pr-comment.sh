#!/bin/sh
# adapters/notificar/pr-comment.sh: comenta no PR corrente ($MR_IID) ou, sem ele, na issue $NOTIFICAR_ISSUE;
# sem nenhum dos dois (ou sem a funcao do provider), cai no console. notificar TIPO TEXTO
notificar() {
  _n_t="[$1] $2"
  if [ -n "${MR_IID:-}" ] && command -v pr_comentar > /dev/null 2>&1; then
    pr_comentar "$MR_IID" "$_n_t"
  elif [ -n "${NOTIFICAR_ISSUE:-}" ] && command -v issue_comentar > /dev/null 2>&1; then
    issue_comentar "$NOTIFICAR_ISSUE" "$_n_t"
  else
    printf '%s\n' "$_n_t"
  fi
}
