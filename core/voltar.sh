#!/bin/sh
# core/voltar.sh AMB: volta o ambiente para a última build com deployment success (rodar DENTRO do lock do ambiente).
# Alvo = deploy_ok_anterior ao deployment atual; em hom ignora hom.* "Release"/"Hotfix" que nunca chegaram a PRD.
# Reinstala o pacote, move a branch (qa/hom) e registra um novo deployment success do alvo.
set -eu
KIT_DIR=${KIT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
export KIT_DIR
# shellcheck source=core/lib.sh
. "$KIT_DIR/core/lib.sh"
carregar_config

[ $# -eq 1 ] || { echo "uso: voltar.sh qa|hom|prd" >&2; exit 2; }
AMB=$1
case "$AMB" in qa|hom|prd) ;; *) echo "ambiente inválido: $AMB" >&2; exit 2 ;; esac
command -v artefatos_baixar > /dev/null 2>&1 || { echo "ARTEFATOS não configurado." >&2; exit 1; }
command -v deploy_instalar > /dev/null 2>&1 || { echo "DEPLOY não configurado." >&2; exit 1; }
falha() { echo "voltar $AMB: $*" >&2; exit 1; }

ULT=$(deploy_ultimo "$AMB") || falha "não foi possível consultar o deployment atual."
ATUAL=$(printf '%s
' "$ULT" | awk '{print $1}')
[ -n "$ATUAL" ] || falha "não há deployment em $AMB."

# (o alvo nunca é a própria build que falhou: pula para um sucesso anterior)
# hom.* "Release|Hotfix X" é preview: só vale como destino se chegou a PRD (v* no mesmo commit, já em PRD)
preview_nao_publicada() {
  [ "$AMB" = hom ] || return 1
  case "$1" in hom.*) ;; *) return 1 ;; esac
  case "$(assunto "$1")" in Release*|Hotfix*) ;; *) return 1 ;; esac
  _c=$(git rev-parse -q --verify "refs/tags/$1^{commit}") || return 0
  _prd=$(deploy_ultimo_ok prd) || _prd=""
  if [ -n "$_prd" ]; then
    for _v in $(git tag --points-at "$_c" -l 'v*'); do
      if git merge-base --is-ancestor "$_v^{commit}" "$_prd^{commit}" 2> /dev/null; then return 1; fi
    done
  fi
  return 0
}

ALVO=$(deploy_ok_anterior "$AMB" "$ATUAL") || falha "não foi possível consultar o deployment anterior."
N=0
while [ -n "$ALVO" ] && { [ "$ALVO" = "$ATUAL" ] || preview_nao_publicada "$ALVO"; }; do
  N=$((N + 1))
  [ "$N" -lt 50 ] || { ALVO=""; break; }
  ALVO=$(deploy_ok_anterior "$AMB" "$ALVO") || falha "não foi possível consultar o deployment anterior."
done
[ -n "$ALVO" ] || falha "não há build anterior com sucesso para voltar em $AMB."

git rev-parse -q --verify "refs/tags/$ALVO^{commit}" > /dev/null || falha "a tag $ALVO não existe (busque as tags)."
SHA=$(git rev-parse "$ALVO^{commit}")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
artefatos_baixar "$SHA" "$TMP" || falha "pacote de $ALVO indisponível."
deploy_instalar "$AMB" "$SHA" "${ALVO#v}" "$TMP/app-$SHA.zip" || falha "falha ao reinstalar $ALVO."
if [ "$AMB" != prd ]; then
  git push -q --force origin "$SHA:refs/heads/$AMB" || falha "não foi possível mover a branch $AMB."
fi
ID=$(deploy_iniciar "$AMB" "$ALVO" "$SHA") || falha "não foi possível registrar o deployment."
deploy_concluir "$ID" success || falha "não foi possível concluir o deployment."
echo "↩️ $AMB voltou para $ALVO."
