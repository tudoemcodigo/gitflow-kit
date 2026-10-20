#!/bin/sh
# Instala no repositorio da aplicacao os arquivos do GitFlow Kit, sem sobrescrever nada.
# Uso: instalar.sh --plataforma github --destino DIR [--kit-ref v1] [--kit-repo ORG/REPO] [--org ORG] [--modo-demo]
set -eu
export TZ=America/Sao_Paulo

KIT=$(cd "$(dirname "$0")" && pwd)
PLAT=; DEST=; KIT_REF=v1; KIT_REPO=tudoemcodigo/gitflow-kit; ORG=; DEMO=nao

uso() {
  echo "uso: instalar.sh --plataforma github|gitlab|jenkins --destino DIR [--kit-ref v1] [--kit-repo ORG/REPO] [--org ORG] [--modo-demo]" >&2
  exit 2
}
valida() { # valida NOME VALOR: so caracteres seguros (vao para sed/awk e para arquivos)
  case "$2" in
    '' | *[!A-Za-z0-9._/-]*) echo "valor invalido para $1: $2" >&2; exit 2 ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --plataforma) [ $# -ge 2 ] || uso; PLAT=$2; shift 2 ;;
    --destino) [ $# -ge 2 ] || uso; DEST=$2; shift 2 ;;
    --kit-ref) [ $# -ge 2 ] || uso; KIT_REF=$2; shift 2 ;;
    --kit-repo) [ $# -ge 2 ] || uso; KIT_REPO=$2; shift 2 ;;
    --org) [ $# -ge 2 ] || uso; ORG=$2; shift 2 ;;
    --modo-demo) DEMO=sim; shift ;;
    *) uso ;;
  esac
done
[ -n "$PLAT" ] && [ -n "$DEST" ] || uso

case "$PLAT" in
  github) ;;
  gitlab | jenkins) echo "plataforma $PLAT: ainda não disponível nesta versão do kit" >&2; exit 2 ;;
  *) uso ;;
esac

valida --kit-ref "$KIT_REF"
valida --kit-repo "$KIT_REPO"
case "$KIT_REPO" in */*/* | /* | */) echo "--kit-repo deve ser ORG/REPO" >&2; exit 2 ;; */*) ;; *) echo "--kit-repo deve ser ORG/REPO" >&2; exit 2 ;; esac
[ -n "$ORG" ] || ORG=${KIT_REPO%%/*}
valida --org "$ORG"

mkdir -p "$DEST"
DEST=$(cd "$DEST" && pwd)
APP=$(basename "$DEST")
valida "nome do diretorio de destino" "$APP"

INSTALADOS=; PULADOS=
# colocar ORIGEM DESTINO_RELATIVO [exec]: copia so se o destino nao existe
colocar() {
  if [ -e "$DEST/$2" ]; then
    PULADOS="$PULADOS $2"
    return 0
  fi
  mkdir -p "$(dirname "$DEST/$2")"
  cp "$1" "$DEST/$2"
  [ "${3:-}" = exec ] && chmod +x "$DEST/$2"
  INSTALADOS="$INSTALADOS $2"
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

# chamador: troca o @ref e passa kit-repo/kit-ref em cada job (with:)
awk -v repo="$KIT_REPO" -v ref="$KIT_REF" '
  /^    uses: tudoemcodigo\/gitflow-kit\// {
    sub(/^    uses: tudoemcodigo\/gitflow-kit\//, "    uses: " repo "/")
    sub(/@[A-Za-z0-9._-]+$/, "@" ref)
    print
    if ((getline prox) > 0) {
      if (prox == "    with:") { print prox; pend = "" } else { print "    with:"; pend = prox }
    }
    print "      kit-repo: " repo
    print "      kit-ref: " ref
    if (pend != "") print pend
    next
  }
  { print }
' "$KIT/ci/github-actions/chamadores/gitflow.yml" > "$TMP/gitflow.yml"

sed -e "s/@MODO_DEMO@/$DEMO/" -e "s/@ORG@/$ORG/g" -e "s/@APP@/$APP/g" \
  "$KIT/modelos/app/.gitflow.env.github" > "$TMP/env"

colocar "$TMP/gitflow.yml" .github/workflows/gitflow.yml
colocar "$KIT/ci/github-actions/chamadores/app-ci.yml" .github/workflows/app-ci.yml
colocar "$KIT/setup/modelos/pull_request_template.md" .github/pull_request_template.md
colocar "$TMP/env" .gitflow.env
colocar "$KIT/modelos/app/scripts/build.sh" scripts/build.sh exec
colocar "$KIT/modelos/app/scripts/test.sh" scripts/test.sh exec

echo "Instalado em $DEST (plataforma $PLAT, kit $KIT_REPO@$KIT_REF):"
for f in $INSTALADOS; do echo "  criado:  $f"; done
if [ -z "$INSTALADOS" ]; then echo "  (nada novo)"; fi
for f in $PULADOS; do echo "  pulado (ja existe): $f"; done
cat <<FIM

Proximos passos:
  1. Crie o repositorio no GitHub, publique estes arquivos e configure o app e os segredos conforme $KIT/setup/github-app.md
  2. Configure labels, Environments, protecao de branch e Teams:
       sh $KIT/setup/github.sh --repo $ORG/$APP --app-id ID$( [ "$DEMO" = sim ] && printf ' --modo-demo' )
  3. Ajuste scripts/build.sh e scripts/test.sh ao seu projeto (contrato: build gera dist/, test sai com 0).
FIM
