#!/bin/sh
# core/montar.sh <qa|hom|release|hotfix>
# Variáveis: VERSAO, HOTFIX, EXPRESSO, FORCAR, LIMITE_QA, BUILD_USER_ID (vazio ou "timer" = agendada),
#            GRUPO_RM, GITFLOW_SAIDA + as da lib.sh. Roda dentro do checkout da app (com tags e branches).
# Saída: $GITFLOW_SAIDA/montagem.tag com a tag criada (vazio = nada a publicar).
# GITFLOW_LOCAL=sim (resolver-conflito.sh): reproduz a montagem sem tag/push e para no primeiro conflito.
set -eu
KIT_DIR=${KIT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
export KIT_DIR
# shellcheck source=core/lib.sh
. "$KIT_DIR/core/lib.sh"
carregar_config

ALVO=${1:?uso: montar.sh <qa|hom|release|hotfix>}
GRUPO_RM=${GRUPO_RM:-release-managers}
LOCAL=${GITFLOW_LOCAL:-nao}
SAIDA=${GITFLOW_SAIDA:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/gitflow}
mkdir -p "$SAIDA"
: > "$SAIDA/montagem.tag"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
trap 'exit 1' INT TERM

git fetch --quiet --force --tags origin '+refs/heads/*:refs/remotes/origin/*'

# ---------- guardas iniciais ----------
case "$ALVO" in
  qa|hotfix)   AMB=qa;  PREF=qa ;;
  hom|release) AMB=hom; PREF=hom ;;
  *) para "ALVO inválido: $ALVO" ;;
esac
[ "$ALVO" != release ] || echo "${VERSAO:-}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || para "VERSAO inválida: ${VERSAO:-}"
[ "$ALVO" != hotfix ]  || echo "${HOTFIX:-}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || para "HOTFIX inválido: ${HOTFIX:-}"
# release e hotfix: só o Release Manager (a permissão da plataforma é por job, não por parâmetro)
case "$ALVO" in
  release|hotfix) membro "${BUILD_USER_ID:-}" "$GRUPO_RM" || para "ALVO=$ALVO é só para release-managers" ;;
esac
# janela: na montagem agendada, entregas novas criadas nos últimos 30 minutos esperam a próxima
CORTE=$(( $(date +%s) - 1800 ))

# P5: a main precisa ser exatamente o que está em PRD
PRD=$(deploy_ultimo_ok prd)
[ -z "$PRD" ] || [ "$(git rev-parse "$PRD^{commit}")" = "$(git rev-parse origin/main)" ] \
  || para "a main não é igual a PRD ($PRD). Conclua o publicar.sh antes de montar."

# P6/P7: modos release e hotfix
if [ "${FORCAR:-false}" != true ]; then
  PUBHOM=$(publicada hom || true)
  MODO=$(assunto "$PUBHOM")
  case "$ALVO:$MODO" in hom:"Release "*|hom:"Hotfix "*) sai "HOM em modo '$MODO': montagem adiada." ;; esac
  if [ "$ALVO" = qa ]; then
    HF=$(hotfix_aguardando_qa)
    [ -z "$HF" ] || sai "hotfix em teste: QA reservado."
  fi
fi

# ---------- seleção pelo estado da última entrega de cada MR ----------
PUB=$(publicada "$AMB" || true)
manifesto_de "$PUB" > "$TMP/publicado"
: > "$TMP/homologadas"; : > "$TMP/aprovadas"; : > "$TMP/teste"
ABERTOS=$(mrs_abertos)   # fail-closed: falha da plataforma aborta aqui
printf '%s\n' "$ABERTOS" | while read -r IID SRC PESO; do
  [ -n "$IID" ] || continue
  RC=$(ultima_rc "$(id_da_branch "$SRC")"); [ -n "$RC" ] || continue
  case "$SRC" in
    hotfix/*)
      if [ "$ALVO" = hotfix ] && [ "$SRC" = "hotfix/$HOTFIX" ]; then echo "$RC $IID hotfix" >> "$TMP/homologadas"; fi
      continue ;;
  esac
  [ "$ALVO" != hotfix ] || continue
  case "$ALVO:$(estado "$RC")" in
    *:hom-ok)              echo "$RC $IID homologada" >> "$TMP/homologadas" ;;
    qa:qa-ok | hom:qa-ok)  echo "$RC $IID aprovada"   >> "$TMP/aprovadas" ;;
    qa:teste)
      if contem "$TMP/publicado" "$RC"; then PESO=0; fi            # já em teste: mantém o lugar
      if [ "${EXPRESSO:-false}" = true ] && [ "$PESO" -gt 1 ]; then continue; fi
      if [ "$PESO" -gt 1 ] && [ "${BUILD_USER_ID:-timer}" = timer ] && [ "$(data_tag "$RC")" -gt "$CORTE" ]; then continue; fi
      echo "$PESO $(data_tag "$RC") $RC $IID" >> "$TMP/teste" ;;
  esac
done

# fila do QA: quem já está em teste sempre fica; uma suspeita de checagem volta SOZINHA
# (na montagem em que ela volta, nenhuma outra entrega nova entra); depois prioridade e antiguidade
sort -n -k1,1 -k2,2 "$TMP/teste" | awk -v lim="${LIMITE_QA:-6}" '
  $1 == 0                  { n++; print "entra", $3, $4, $1; next }
  $1 == 2 && !s && !novas  { s = 1; n++; print "entra", $3, $4, $1; next }
  $1 != 2 && !s && n < lim { novas = 1; n++; print "entra", $3, $4, $1; next }
                           { print "fila", $3, $4 }' > "$TMP/fila"

# ---------- montagem: commit novo a partir da main ----------
git checkout -q --detach origin/main
git config rerere.enabled true; git config rerere.autoUpdate true
if git rev-parse -q --verify origin/meta/rerere > /dev/null; then   # cache rerere compartilhado
  D="$(git rev-parse --git-dir)/rr-cache"; mkdir -p "$D"
  git archive -o "$TMP/rerere.tar" origin/meta/rerere
  tar -x -C "$D" -f "$TMP/rerere.tar"
fi
echo "base main $(git rev-parse --short HEAD) ($(git describe --tags --exact-match origin/main 2> /dev/null || echo sem-versao))" > "$TMP/manifesto"
echo "rerere $(git rev-parse --short origin/meta/rerere 2> /dev/null || echo nenhum)" >> "$TMP/manifesto"
: > "$TMP/fora"; : > "$TMP/bloqueio"
mesclar() {   # rc iid -> 0 se entrou (sem conflito, ou resolvido pelo rerere fora da release e sem marcadores)
  # shellcheck disable=SC2086  # $BOT são opções -c separadas por espaço
  git $BOT merge --no-ff -q -m "montagem $ALVO: $1 (!$2)" "$1" > /dev/null 2>&1 && return 0
  if [ "$ALVO" != release ] && [ -z "$(git diff --name-only --diff-filter=U)" ] && git diff --cached --check > /dev/null; then
    # shellcheck disable=SC2086
    git $BOT commit -q --no-edit; echo "rerere: $1" >> "$TMP/fora"; return 0
  fi
  if [ "$LOCAL" = sim ]; then   # deixa o conflito no working tree para o usuário resolver
    echo "Conflito ao mesclar $1 (!$2) na montagem $ALVO."
    echo "Resolva os arquivos, 'git add' e 'git commit --no-edit' (o rerere grava a resolução),"
    echo "depois rode: resolver-conflito.sh --publicar"
    exit 0
  fi
  git merge --abort; return 1
}
incluir() {   # rc iid tipo [peso]
  if mesclar "$1" "$2"; then
    case "$3" in aprovada) T="aprovada QA" ;; teste) T="em teste" ;; *) T="$3" ;; esac
    if [ "$3" = teste ] && [ "${4:-}" = 1 ]; then T="$T (reteste expresso)"; fi
    echo "$1 !$2 $(git rev-parse --short "$1^{commit}") $T" >> "$TMP/manifesto"
  elif [ "$3" = teste ]; then echo "fora: $1 !$2 conflito" >> "$TMP/fora"
  else echo "$1 !$2 ($3)" >> "$TMP/bloqueio"; fi
}
ordenar_por_data hom-ok < "$TMP/homologadas" > "$TMP/l1"
while read -r RC IID T; do incluir "$RC" "$IID" "$T"; done < "$TMP/l1"
if [ "$ALVO" = qa ] || [ "$ALVO" = hom ]; then
  ordenar_por_data qa-ok < "$TMP/aprovadas" > "$TMP/l2"
  while read -r RC IID T; do incluir "$RC" "$IID" "$T"; done < "$TMP/l2"
fi
if [ "$ALVO" = qa ]; then
  awk '$1 == "entra" {print $2, $3, $4}' "$TMP/fila" > "$TMP/l3"
  while read -r RC IID PS; do incluir "$RC" "$IID" teste "$PS"; done < "$TMP/l3"
fi

# P4: conflito de entrega aprovada para a montagem
[ ! -s "$TMP/bloqueio" ] || para "conflito em entrega aprovada: $(tr '\n' ' ' < "$TMP/bloqueio")"

# P3: toda entrega aprovada vigente precisa estar na build (pega MR fechado, label mexido, etc.)
case "$ALVO" in qa|hom) DEC=qa-ok ;; release) DEC=hom-ok ;; hotfix) DEC= ;; esac
if [ -n "$DEC" ]; then
  VIG=$(aprovadas_vigentes "$DEC")
  printf '%s\n' "$VIG" | while read -r RC; do
    [ -n "$RC" ] || continue
    contem "$TMP/manifesto" "$RC" || echo "$RC"
  done > "$TMP/sumiu"
  [ ! -s "$TMP/sumiu" ] || para "entregas aprovadas fora da build sem motivo: $(tr '\n' ' ' < "$TMP/sumiu"). Reabra o MR ou use /retirar."
fi

# manifesto: o que saiu em relação à build publicada (informativo)
{ grep '^rc/' "$TMP/publicado" || true; } | while read -r RC _; do
  contem "$TMP/manifesto" "$RC" && continue
  ID=${RC%.*}
  NOVA=$(awk -v p="$ID." 'index($1, p) == 1 {print $1; exit}' "$TMP/manifesto")
  if [ -n "$NOVA" ]; then echo "saiu: $RC substituída por $NOVA"; else echo "saiu: $RC ($(estado "$RC"))"; fi
done >> "$TMP/fora"
awk '$1 == "fila" {print "fila: " $2 " !" $3 " posição " ++p}' "$TMP/fila" >> "$TMP/fora"
cat "$TMP/fora" >> "$TMP/manifesto"

if [ "$LOCAL" = sim ]; then sai "Montagem reproduzida sem conflitos (nada foi publicado)."; fi

# nada mudou? (mesma base e mesmas entregas da build publicada)
if [ "$ALVO" = qa ] || [ "$ALVO" = hom ]; then
  NOVO=$(grep -E '^(base|rerere|rc/)' "$TMP/manifesto" || true)
  ANTES=$(grep -E '^(base|rerere|rc/)' "$TMP/publicado" || true)
  [ "$NOVO" != "$ANTES" ] || sai "nada mudou desde $PUB."
fi

# ---------- tag da build ----------
case "$ALVO" in
  qa)      TIT="Build qa"; [ "${EXPRESSO:-false}" != true ] || TIT="Build qa (expressa)" ;;
  hom)     TIT="Build hom" ;;
  release) TIT="Release $VERSAO" ;;
  hotfix)  TIT="Hotfix $HOTFIX" ;;
esac
DATA=$(date +%F)
N=$(git tag -l "$PREF.$DATA.*" | awk -F. '{print $NF}' | sort -n | tail -1)
TAG="$PREF.$DATA.$(( ${N:-0} + 1 ))"
{ echo "$TIT"; echo; cat "$TMP/manifesto"; } > "$TMP/msg"
# shellcheck disable=SC2086
git $BOT tag -a --cleanup=verbatim "$TAG" -F "$TMP/msg"
git push -q origin "refs/tags/$TAG"
echo "$TAG" > "$SAIDA/montagem.tag"

# ---------- avisos nos MRs (melhor esforço: a tag já existe e a esteira precisa rodar) ----------
av() { "$@" || echo "AVISO: falha em $1 ($2) após criar $TAG; ignorada." >&2; }
awk '$1 == "fila" {print $3, ++p}' "$TMP/fila" | while read -r IID P; do
  av pr_rotular "$IID" "Montagem::Fila" ""; av pr_comentar "$IID" "⏳ Na fila do QA (posição $P) na montagem $TAG."
done
{ grep '^fora: ' "$TMP/fora" || true; } | while read -r _ RC IID _; do
  av pr_rotular "${IID#!}" "Montagem::Conflito" ""
  av pr_comentar "${IID#!}" "⚠️ $RC conflitou na montagem $TAG e ficou fora. Atualize com a main e entregue de novo."
done
{ grep '^rc/' "$TMP/manifesto" || true; } | while read -r RC IID _; do
  av espelhar "${IID#!}" "$RC"; av pr_rotular "${IID#!}" "" "Montagem::Fila,Montagem::Conflito"
done
echo "Criada $TAG:"; cat "$TMP/msg"
