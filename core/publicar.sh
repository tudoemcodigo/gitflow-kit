#!/bin/sh
# core/publicar.sh TAG: registro depois do PRD publicado e verificado (idempotente; a esteira tenta até 3 vezes).
# main por fast-forward (sem force) para o commit da vX.Y.Z; fecha todo MR cuja última entrega está contida
# nesse commit; MR com entrega mais nova fica aberto com aviso; cria a release da plataforma.
set -eu
KIT_DIR=${KIT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
export KIT_DIR
# shellcheck source=core/lib.sh
. "$KIT_DIR/core/lib.sh"
carregar_config

[ $# -eq 1 ] || { echo "uso: publicar.sh vX.Y.Z" >&2; exit 2; }
TAG=$1

git fetch --quiet --force --tags origin '+refs/heads/*:refs/remotes/origin/*' || para "publicar: não foi possível buscar tags e branches de origin."

echo "$TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || para "publicar: $TAG não é uma versão vX.Y.Z."
tem "$TAG" || para "publicar: a tag $TAG não existe."
SHA=$(git rev-parse "$TAG^{commit}")
VER=${TAG#v}
# só se publica o que está em PRD (a main nunca anda para uma versão que não foi implantada)
ATUAL=$(deploy_ultimo_ok prd) || para "publicar: não foi possível consultar o deployment de PRD."
[ "$ATUAL" = "$TAG" ] || para "publicar: $TAG não é a versão em PRD (${ATUAL:-nenhuma})."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
trap 'exit 1' INT TERM
: > "$TMP/falhas"
falha() { echo "publicar: $*" >&2; echo "$*" >> "$TMP/falhas"; }

# ---------- main por fast-forward ----------
git rev-parse -q --verify refs/remotes/origin/main > /dev/null || para "publicar: a ref origin/main não existe."
if git merge-base --is-ancestor "$SHA" origin/main; then
  echo "main já contém $TAG."
else
  git merge-base --is-ancestor origin/main "$SHA" || para "publicar: a main atual não é ancestral de $TAG; fast-forward impossível (sem force)."
  git push -q origin "$SHA:refs/heads/main" || para "publicar: não foi possível mover a main para $TAG."
  git update-ref refs/remotes/origin/main "$SHA"
  echo "main avançou para $TAG."
fi

# ---------- MRs ----------
LISTA=$(pr_listar_abertos) || para "publicar: não foi possível listar os MRs abertos."
printf '%s\n' "$LISTA" > "$TMP/abertos"
while read -r IID SRC _; do
  [ -n "$IID" ] || continue
  ID=$(id_da_branch "$SRC")
  [ -n "$ID" ] || continue
  RC=$(ultima_rc "$ID")
  [ -n "$RC" ] || continue
  if git merge-base --is-ancestor "$RC^{commit}" "$SHA"; then
    # o MR só fecha se os passos anteriores deram certo (senão a próxima rodada ainda o encontra aberto)
    OK=sim
    pr_rotular "$IID" "Ambiente::PRD" "$LABELS_AMBIENTE" || { falha "rótulo do MR !$IID"; OK=nao; }
    pr_comentar "$IID" "🚀 **$RC** foi publicada em PRD na versão **$TAG**. MR encerrado." || { falha "comentário do MR !$IID"; OK=nao; }
    branch_apagar "$SRC" || { falha "apagar a branch $SRC"; OK=nao; }
    if [ "$OK" = sim ]; then pr_fechar "$IID" || falha "fechar o MR !$IID"; fi
    continue
  fi
  # entrega mais nova que a publicada: o MR segue aberto, com aviso (uma vez só), se uma anterior foi publicada
  PUBLICADA=""
  for T in $(git tag -l "rc/$ID.*"); do
    if git merge-base --is-ancestor "$T^{commit}" "$SHA"; then PUBLICADA=$T; fi
  done
  if [ -n "$PUBLICADA" ]; then
    MARCA="<!-- gitflow:aviso:$TAG:$RC -->"
    COMENTS=$(pr_comentarios "$IID") || { falha "ler os comentários do MR !$IID"; continue; }
    if ! printf '%s
' "$COMENTS" | grep -qF "$MARCA"; then
      pr_comentar "$IID" "⚠️ **$PUBLICADA** foi publicada em PRD na versão **$TAG**, mas existe uma entrega mais nova (**$RC**) que não entrou. O MR continua aberto. $MARCA" || falha "aviso do MR !$IID"
    fi
  fi
done < "$TMP/abertos"

# ---------- release da plataforma ----------
NOTAS="$TAG"
for H in $(git tag --points-at "$SHA" -l 'hom.*' --sort=-creatordate); do
  case "$(assunto "$H")" in "Release $VER"|"Hotfix $VER") NOTAS="$(assunto "$H")
$(manifesto_de "$H")"; break ;; esac
done
release_criar "$TAG" "$NOTAS" || falha "criar a release $TAG"

if [ -s "$TMP/falhas" ]; then
  echo "publicar: terminou com falhas; rode de novo (idempotente)." >&2
  exit 1
fi
echo "Publicado $TAG."
