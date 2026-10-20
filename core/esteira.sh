#!/bin/sh
# core/esteira.sh ETAPA: a esteira de publicação, uma etapa por job de CI.
# Etapas: preparar construir testar publicar-pacote gates implantar verificar-auto registrar falhou
# Env: TAG AMBIENTE (qa|hom|prd) PULAR_CHECAGEM GITFLOW_SAIDA GITFLOW_RUN_ID (o mesmo em todas as etapas).
# O estado passa entre jobs por $GITFLOW_SAIDA/esteira.env (SHA CONSTRUIR TESTADO DEPLOY_ID; VERIFICAR só é escrito).
set -eu
KIT_DIR=${KIT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
export KIT_DIR
# shellcheck source=core/lib.sh
. "$KIT_DIR/core/lib.sh"
carregar_config

ETAPA=${1:-}
TAG=${TAG:?TAG não definida}
AMB=${AMBIENTE:?AMBIENTE não definido}
case "$AMB" in qa|hom|prd) ;; *) echo "ambiente inválido: $AMB" >&2; exit 2 ;; esac
SAIDA=${GITFLOW_SAIDA:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/gitflow}
export GITFLOW_SAIDA="$SAIDA"
mkdir -p "$SAIDA"
ENV="$SAIDA/esteira.env"
lock() { sh "$KIT_DIR/core/lock.sh" "$@"; }
pacote() { sh "$KIT_DIR/core/pacote.sh" "$@"; }

# lê só as chaves conhecidas (nunca "source" no arquivo de estado)
SHA=""; CONSTRUIR=""; TESTADO=""; DEPLOY_ID=""
if [ -f "$ENV" ]; then
  while IFS='=' read -r _k _v || [ -n "$_k" ]; do
    _v=$(printf '%s' "$_v" | tr -d '\015')
    case "$_k" in
      SHA) SHA=$_v ;; CONSTRUIR) CONSTRUIR=$_v ;; TESTADO) TESTADO=$_v ;;
      DEPLOY_ID) DEPLOY_ID=$_v ;;
    esac
  done < "$ENV"
fi
salvar() {   # CHAVE VALOR: substitui a chave no arquivo de estado
  _t=$(mktemp "$SAIDA/.env.XXXXXX")
  { grep -v "^$1=" "$ENV" 2> /dev/null || true; printf '%s=%s\n' "$1" "$2"; } > "$_t"
  mv -f "$_t" "$ENV"
}
exige_sha() { [ -n "$SHA" ] || para "esteira.env sem SHA: rode a etapa preparar antes."; }

MONT=${GITFLOW_LOCK_MONTAGEM:-}
if [ -z "$MONT" ] && [ -s "$SAIDA/lock-montagem" ]; then MONT=$(tr -d '\015\n' < "$SAIDA/lock-montagem"); fi

# main + tags sempre (falha aborta); qa/hom só se existem no remoto
buscar() {
  git fetch --quiet --force --tags origin main || para "não foi possível buscar main e tags de origin."
  for _b in qa hom; do
    if git ls-remote --exit-code --heads origin "$_b" > /dev/null 2>&1; then
      git fetch --quiet --force origin "+refs/heads/$_b:refs/remotes/origin/$_b" || para "não foi possível buscar $_b de origin."
    fi
  done
}

soltar_locks() {
  _rc=0
  lock soltar "ambiente-$AMB" || _rc=1
  if [ -n "$MONT" ]; then lock soltar "$MONT" || echo "aviso: $MONT não é desta execução; mantido." >&2; fi
  return "$_rc"
}

case "$ETAPA" in
  preparar)
    buscar
    sh "$KIT_DIR/core/validar-tag.sh" "$TAG" "$AMB"
    # R7: PULAR_CHECAGEM só vale para a build que JÁ está publicada no ambiente
    if [ "${PULAR_CHECAGEM:-false}" = true ] && [ "$(publicada "$AMB")" != "$TAG" ]; then
      para "PULAR_CHECAGEM só vale para a build publicada em $AMB."
    fi
    SHA=$(git rev-parse "$TAG^{commit}")
    if pacote existe "$SHA"; then CONSTRUIR=nao; else CONSTRUIR=sim; fi
    if [ "$AMB" = prd ] && [ "$CONSTRUIR" = sim ]; then
      echo "PRD nunca compila: o pacote da preview precisa existir ($SHA)." >&2
      exit 1
    fi
    : > "$ENV"
    salvar SHA "$SHA"
    salvar CONSTRUIR "$CONSTRUIR"
    echo "SHA=$SHA CONSTRUIR=$CONSTRUIR" ;;

  construir)
    exige_sha
    [ "$CONSTRUIR" = sim ] || { echo "pacote já existe: sem build."; exit 0; }
    pacote build "$SHA" ;;

  testar)
    exige_sha
    [ "$CONSTRUIR" = sim ] || { echo "pacote já testado: sem testes."; exit 0; }
    [ -f scripts/test.sh ] || para "scripts/test.sh não encontrado na aplicação."
    sh scripts/test.sh
    salvar TESTADO sim ;;

  publicar-pacote)
    exige_sha
    [ "$CONSTRUIR" = sim ] || { echo "pacote já publicado."; exit 0; }
    [ "$TESTADO" = sim ] || para "P12: o pacote só é publicado depois de passar nos testes."
    pacote publicar "$SHA" ;;

  gates)
    exige_sha
    if [ -f scripts/gates.sh ]; then
      sh scripts/gates.sh "$AMB" "$SHA"
    else
      echo "scripts/gates.sh ausente: sem gates adicionais."
    fi ;;

  implantar)
    exige_sha
    command -v deploy_iniciar > /dev/null 2>&1 || para "provider sem deploy_iniciar."
    lock pegar "ambiente-$AMB" 1800
    buscar   # depois da espera: origin/main e as tags podem ter mudado (P9)
    [ "$SHA" = "$(git rev-parse "$TAG^{commit}")" ] || para "o SHA do esteira.env não é o de $TAG."
    sh "$KIT_DIR/core/validar-tag.sh" "$TAG" "$AMB"   # P9: revalida dentro do travamento
    ID=$(deploy_iniciar "$AMB" "$TAG" "$SHA")
    salvar DEPLOY_ID "$ID"
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    pacote baixar "$SHA" "$TMP"
    deploy_instalar "$AMB" "$SHA" "${TAG#v}" "$TMP/app-$SHA.zip"
    if [ "$AMB" != prd ]; then git push -q --force origin "$SHA:refs/heads/$AMB"; fi
    echo "Implantado $TAG em $AMB (deployment $ID)." ;;

  verificar-auto)
    exige_sha
    if [ "${PULAR_CHECAGEM:-false}" = true ]; then
      salvar VERIFICAR PULADA; echo "checagem pulada (R7)"; exit 0
    fi
    if [ "$AMB" = prd ]; then
      if [ -f scripts/smoke.sh ]; then sh scripts/smoke.sh prd; else deploy_saude prd; fi
    elif [ -f scripts/checar.sh ]; then
      sh scripts/checar.sh "$AMB"
    else
      salvar VERIFICAR MANUAL
      echo "MANUAL"
      exit 0
    fi
    salvar VERIFICAR OK
    echo "verificação OK" ;;

  registrar)
    exige_sha
    [ -n "$DEPLOY_ID" ] || para "esteira.env sem DEPLOY_ID."
    deploy_concluir "$DEPLOY_ID" success
    RC=0
    if [ "$AMB" = prd ] && [ -f "$KIT_DIR/core/publicar.sh" ]; then
      _ok=nao
      for _i in 1 2 3; do
        if sh "$KIT_DIR/core/publicar.sh" "$TAG"; then _ok=sim; break; fi
        echo "publicar.sh: tentativa $_i falhou." >&2
      done
      if [ "$_ok" != sim ]; then
        echo "PRD publicado, mas publicar.sh falhou: rode-o de novo (idempotente)." >&2
        notificar alerta "PRD $TAG publicado, mas publicar.sh falhou: rode-o de novo." || true
        RC=1
      fi
    fi
    if [ "$RC" -eq 0 ]; then notificar publicado "$TAG em $AMB" || true; fi
    soltar_locks || RC=1
    exit "$RC" ;;

  falhou)
    DONO=$(lock dono "ambiente-$AMB") || DONO=""
    case "$DONO" in
      "run=${GITFLOW_RUN_ID:-}"\ *) ;;
      *)
        echo "o lock ambiente-$AMB não é desta execução: nada a desfazer."
        if [ -n "$MONT" ]; then lock soltar "$MONT" || echo "aviso: $MONT não é desta execução; mantido." >&2; fi
        exit 1 ;;
    esac
    if [ -z "$DEPLOY_ID" ]; then
      echo "nada foi implantado: só soltando o travamento."
      soltar_locks
      exit 0
    fi
    deploy_concluir "$DEPLOY_ID" failed
    if ! sh "$KIT_DIR/core/voltar.sh" "$AMB"; then
      notificar alerta "A volta de $AMB falhou depois de $TAG: o ambiente segue travado. Intervenção humana necessária." || true
      exit 1
    fi
    notificar alerta "$AMB voltou para a build anterior (falha em $TAG)." || true
    soltar_locks ;;

  *) echo "uso: esteira.sh preparar|construir|testar|publicar-pacote|gates|implantar|verificar-auto|registrar|falhou" >&2; exit 2 ;;
esac
