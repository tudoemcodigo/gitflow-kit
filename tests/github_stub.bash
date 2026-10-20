# shellcheck disable=SC2329  # funcoes substitutas, chamadas indiretamente pelo provider
# Helper dos testes do provider GitHub (bash). Substitui gh_api/gh_paginar por leitura de fixtures.
# Convencao do nome da fixture (a mesma documentada em adapters/provider/github.sh):
#   <METODO>_<caminho>.json, caminho = CAMINHO sem a "/" inicial, com "/", "?", "&" e "=" trocados por "_".
#   gh_paginar: pagina 1 em <nome>.json; paginas seguintes em <nome>.p2.json, <nome>.p3.json...
# Toda chamada de gh_api vai para $GH_LOG ("METODO CAMINHO CORPO"); POST/PATCH/DELETE sem fixture respondem {}.

GH_FIX="$KIT_DIR/tests/fixtures/github"

gh_fixture_nome() {
  local c=${2#/}
  c=${c//[\/?&=]/_}
  printf '%s_%s' "$1" "$c"
}

gh_stub_instalar() {
  GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  : > "$GH_LOG"
  export GH_LOG
  gh_api() {
    printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$GH_LOG"
    local f
    f="$GH_FIX/$(gh_fixture_nome "$1" "$2").json"
    if [ -f "$f" ]; then
      cat "$f"
    elif [ "$1" = GET ]; then
      return 44
    else
      echo '{}'
    fi
  }
  gh_paginar() {
    local n p=1 f
    n=$(gh_fixture_nome GET "$1")
    f="$GH_FIX/$n.json"
    [ -f "$f" ] || return 44
    printf 'GET %s\n' "$1" >> "$GH_LOG"
    while [ -f "$f" ]; do
      cat "$f"
      echo
      p=$((p + 1))
      f="$GH_FIX/$n.p$p.json"
    done
  }
}

# curl falso (para testar gh_api/gh_paginar de verdade). Respostas em $STUB_DIR, mesmos nomes de fixture;
# <nome>.code = codigo HTTP (padrao 200 com fixture, 404 sem), <nome>.link = valor do cabecalho Link.
curl_stub_instalar() {
  STUB_DIR="$BATS_TEST_TMPDIR/stub"
  CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  mkdir -p "$STUB_DIR" "$BATS_TEST_TMPDIR/bin"
  : > "$CURL_LOG"
  export STUB_DIR CURL_LOG
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'STUB'
#!/bin/sh
m=GET; out=; hdr=; url=; corpo=
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m=$2; shift ;;
    -o) out=$2; shift ;;
    -D) hdr=$2; shift ;;
    -w) shift ;;
    -H) printf 'H %s\n' "$2" >> "$CURL_LOG"; shift ;;
    --data-binary) corpo=$(cat); shift ;;
    -sS | --fail-with-body) ;;
    *) url=$1 ;;
  esac
  shift
done
caminho=${url#"$GITHUB_API_URL"}
nome=$(printf '%s' "${caminho#/}" | tr '/?&=' '____')
printf 'R %s %s %s\n' "$m" "$caminho" "$corpo" >> "$CURL_LOG"
base="$STUB_DIR/${m}_$nome"
if [ -f "$base.json" ]; then cp "$base.json" "$out"; code=200; else echo '{"message":"Not Found"}' > "$out"; code=404; fi
[ ! -f "$base.code" ] || code=$(cat "$base.code")
if [ -n "$hdr" ]; then
  { printf 'HTTP/2 %s\r\n' "$code"; [ ! -f "$base.link" ] || printf 'Link: %s\r\n' "$(cat "$base.link")"; printf '\r\n'; } > "$hdr"
fi
printf '%s' "$code"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}
