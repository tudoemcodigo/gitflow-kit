load helper
load github_stub

# Adaptadores GitHub: artefatos (Release `pacotes`), deploy (Pages) e notificadores. Sem rede.

setup() {
  export GITHUB_REPOSITORY=acme/app GITHUB_TOKEN=tok-secreto GITHUB_API_URL=https://api.test
  # shellcheck source=/dev/null
  . "$KIT_DIR/core/lib.sh"
  # shellcheck source=/dev/null
  . "$KIT_DIR/adapters/provider/github.sh"
  gh_stub_instalar
  GH_FIX="$BATS_TEST_TMPDIR/fix"
  ASSETS="$BATS_TEST_TMPDIR/assets"
  mkdir -p "$GH_FIX" "$ASSETS"
  export GH_FIX ASSETS
  # transferencia de arquivos simulada: assets em $ASSETS/<id>
  gh_upload() {
    printf 'UP %s %s\n' "$1" "$3" >> "$GH_LOG"
    [ ! -f "$BATS_TEST_TMPDIR/up_falha_zip" ] || case "$1" in *.sha256*) ;; *) return 1 ;; esac
    UPN=$(($(cat "$BATS_TEST_TMPDIR/upn" 2> /dev/null || echo 100) + 1))
    echo "$UPN" > "$BATS_TEST_TMPDIR/upn"
    cp "$2" "$ASSETS/$UPN"
    printf '{"id":%s}' "$UPN"
  }
  gh_baixar() {
    printf 'DL %s\n' "$1" >> "$GH_LOG"
    local id=${1##*/}
    [ -f "$ASSETS/$id" ] || return 44
    cp "$ASSETS/$id" "$2"
  }
  # shellcheck source=/dev/null
  . "$KIT_DIR/adapters/artefatos/github-release.sh"
  ZIP="$BATS_TEST_TMPDIR/app.zip"
  mkdir "$BATS_TEST_TMPDIR/conteudo"
  echo "<html>v1</html>" > "$BATS_TEST_TMPDIR/conteudo/index.html"
  zip_criar "$BATS_TEST_TMPDIR/conteudo" "$ZIP"
}

release_com_assets() {   # lista JSON de assets
  echo '{"id":7}' > "$GH_FIX/GET_repos_acme_app_releases_tags_pacotes.json"
  echo "$1" > "$GH_FIX/GET_repos_acme_app_releases_7_assets_per_page_100.json"
}

# ---------- artefatos ----------

@test "existe: zip e sha256 presentes" {
  release_com_assets '[{"id":1,"name":"app-abc.zip"},{"id":2,"name":"app-abc.zip.sha256"}]'
  run artefatos_existe abc
  [ "$status" -eq 0 ]
}

@test "existe: so o zip, sem sha256, nao conta" {
  release_com_assets '[{"id":1,"name":"app-abc.zip"}]'
  run artefatos_existe abc
  [ "$status" -eq 1 ]
}

@test "existe: release inexistente e nao existe" {
  run artefatos_existe abc
  [ "$status" -eq 1 ]
}

@test "existe: erro de API nunca vira existe nem nao-existe" {
  gh_api() { return 1; }
  run artefatos_existe abc
  [ "$status" -eq 2 ]
}

@test "publicar cria a release prerelease, sobe sha256 antes do zip" {
  echo '{"id":7}' > "$GH_FIX/POST_repos_acme_app_releases.json"
  echo '[]' > "$GH_FIX/GET_repos_acme_app_releases_7_assets_per_page_100.json"
  run artefatos_publicar abc "$ZIP"
  [ "$status" -eq 0 ]
  grep -q '^POST /repos/acme/app/releases ' "$GH_LOG"
  [ "$(grep '^POST /repos/acme/app/releases ' "$GH_LOG" | sed 's/^POST [^ ]* //' | jq -r '.prerelease, .tag_name' | tr '\n' ' ')" = "true pacotes " ]
}

@test "publicar: corrida na criacao da release (422) recupera a existente" {
  echo '[]' > "$GH_FIX/GET_repos_acme_app_releases_7_assets_per_page_100.json"
  gh_api() {
    printf '%s %s %s
' "$1" "$2" "${3:-}" >> "$GH_LOG"
    case "$1 $2" in
      "GET /repos/acme/app/releases/tags/pacotes")
        if [ -f "$BATS_TEST_TMPDIR/criada" ]; then echo '{"id":7}'; else return 44; fi ;;
      "POST /repos/acme/app/releases") : > "$BATS_TEST_TMPDIR/criada"; return 42 ;;
      *) echo '{}' ;;
    esac
  }
  run artefatos_publicar abc "$ZIP"
  [ "$status" -eq 0 ]
  grep -q '^UP /repos/acme/app/releases/7/assets' "$GH_LOG"
}

@test "publicar com release existente envia os dois assets na ordem" {
  release_com_assets '[]'
  run artefatos_publicar abc "$ZIP"
  [ "$status" -eq 0 ]
  ! grep -q '^POST /repos/acme/app/releases ' "$GH_LOG" || false
  [ "$(grep '^UP ' "$GH_LOG" | sed 's/^UP [^ ]*name=//;s/ .*//')" = "$(printf 'app-abc.zip.sha256\napp-abc.zip')" ]
  [ "$(cut -d' ' -f1 < "$ASSETS/101")" = "$(sha256sum "$ZIP" | cut -d' ' -f1)" ]
}

@test "publicar recusa asset duplicado e nao envia nada" {
  release_com_assets '[{"id":1,"name":"app-abc.zip"},{"id":2,"name":"app-abc.zip.sha256"}]'
  run artefatos_publicar abc "$ZIP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"nunca é sobrescrito"* ]]
  ! grep -q '^UP ' "$GH_LOG" || false
}

@test "publicar recusa quando so um dos assets ja existe" {
  release_com_assets '[{"id":2,"name":"app-abc.zip.sha256"}]'
  run artefatos_publicar abc "$ZIP"
  [ "$status" -eq 1 ]
  ! grep -q '^UP ' "$GH_LOG" || false
}

@test "publicar recusa sha256 local divergente do zip" {
  release_com_assets '[]'
  echo "0000  app.zip" > "$ZIP.sha256"
  run artefatos_publicar abc "$ZIP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"diverge"* ]]
  ! grep -q '^UP ' "$GH_LOG" || false
}

@test "publicar: falha no envio do zip remove o sha256 orfao" {
  release_com_assets '[]'
  : > "$BATS_TEST_TMPDIR/up_falha_zip"
  run artefatos_publicar abc "$ZIP"
  [ "$status" -eq 1 ]
  grep -q '^DELETE /repos/acme/app/releases/assets/101 ' "$GH_LOG"
}

@test "publicar: erro ao listar assets nao e lido como ausente" {
  release_com_assets '[]'
  gh_paginar() { return 1; }
  run artefatos_publicar abc "$ZIP"
  [ "$status" -eq 1 ]
  ! grep -q '^UP ' "$GH_LOG" || false
}

@test "baixar confere o SHA-256 e entrega o arquivo" {
  release_com_assets '[{"id":11,"name":"app-abc.zip"},{"id":12,"name":"app-abc.zip.sha256"}]'
  cp "$ZIP" "$ASSETS/11"
  printf '%s  app-abc.zip\n' "$(sha256sum "$ZIP" | cut -d' ' -f1)" > "$ASSETS/12"
  mkdir "$BATS_TEST_TMPDIR/dest"
  run artefatos_baixar abc "$BATS_TEST_TMPDIR/dest"
  [ "$status" -eq 0 ]
  cmp "$ZIP" "$BATS_TEST_TMPDIR/dest/app-abc.zip"
}

@test "baixar recusa zip adulterado e nao deixa arquivo" {
  release_com_assets '[{"id":11,"name":"app-abc.zip"},{"id":12,"name":"app-abc.zip.sha256"}]'
  echo adulterado > "$ASSETS/11"
  printf '%s  app-abc.zip\n' "$(sha256sum "$ZIP" | cut -d' ' -f1)" > "$ASSETS/12"
  mkdir "$BATS_TEST_TMPDIR/dest"
  run artefatos_baixar abc "$BATS_TEST_TMPDIR/dest"
  [ "$status" -eq 1 ]
  [[ "$output" == *"diverge"* ]]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/dest")" ]
}

@test "baixar de pacote inexistente falha" {
  release_com_assets '[]'
  run artefatos_baixar abc "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
}

# ---------- helpers HTTP de arquivo (curl falso) ----------

curl_arq_stub() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'STUB'
#!/bin/sh
out=; args=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift ;;
    -H) case "$2" in @*) printf 'AUTH %s\n' "$(cat "${2#@}")" >> "$CURL_LOG" ;; esac ;;
  esac
  args="$args $1"
  shift
done
printf 'ARGS%s\n' "$args" >> "$CURL_LOG"
printf '{"id":9}' > "$out"
printf '201'
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  : > "$CURL_LOG"
  export CURL_LOG
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "gh_upload usa uploads.github.com, token fora do argv" {
  . "$KIT_DIR/adapters/provider/github.sh"
  curl_arq_stub
  GITHUB_API_URL=https://api.github.com
  run gh_upload "/repos/acme/app/releases/7/assets?name=a.zip" "$ZIP" application/zip
  [ "$status" -eq 0 ]
  [ "$output" = '{"id":9}' ]
  grep -q 'https://uploads.github.com/repos/acme/app/releases/7/assets?name=a.zip' "$CURL_LOG"
  grep -q 'Content-Type: application/zip' "$CURL_LOG"
  grep -q '^AUTH Authorization: Bearer tok-secreto' "$CURL_LOG"
  ! grep '^ARGS' "$CURL_LOG" | grep -q tok-secreto || false
}

@test "gh_upload em GHES deriva /api/uploads" {
  . "$KIT_DIR/adapters/provider/github.sh"
  curl_arq_stub
  GITHUB_API_URL=https://ghe.example/api/v3
  run gh_upload "/repos/acme/app/releases/7/assets?name=a.zip" "$ZIP" application/zip
  [ "$status" -eq 0 ]
  grep -q 'https://ghe.example/api/uploads/repos/acme/app/releases/7/assets' "$CURL_LOG"
}

@test "gh_baixar pede octet-stream e grava o corpo" {
  . "$KIT_DIR/adapters/provider/github.sh"
  curl_arq_stub
  run gh_baixar /repos/acme/app/releases/assets/5 "$BATS_TEST_TMPDIR/saida"
  [ "$status" -eq 0 ]
  grep -q 'Accept: application/octet-stream' "$CURL_LOG"
  [ -f "$BATS_TEST_TMPDIR/saida" ]
}

# ---------- deploy Pages ----------

pages_setup() {
  # shellcheck source=/dev/null
  . "$KIT_DIR/adapters/deploy/pages.sh"
  PAGES_BARE="$BATS_TEST_TMPDIR/pages.git"
  git init -q --bare -b main "$PAGES_BARE"
  export PAGES_REMOTE="$PAGES_BARE"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  mkdir -p "$BATS_TEST_TMPDIR/c2"
  echo "<html>v2</html>" > "$BATS_TEST_TMPDIR/c2/novo.html"
  ZIP2="$BATS_TEST_TMPDIR/app2.zip"
  zip_criar "$BATS_TEST_TMPDIR/c2" "$ZIP2"
}

pages_ver() {   # CAMINHO -> conteudo do arquivo em gh-pages
  git --git-dir="$PAGES_BARE" show "gh-pages:$1"
}

@test "pages: cria gh-pages orfa e instala qa com version.json" {
  pages_setup
  run deploy_instalar qa sha1 1.0.0-rc.1 "$ZIP"
  [ "$status" -eq 0 ]
  [ "$(pages_ver qa/index.html)" = "<html>v1</html>" ]
  [ "$(pages_ver qa/version.json | jq -r '.versao + " " + .sha')" = "1.0.0-rc.1 sha1" ]
  [ "$(pages_ver qa/version.json | jq -r 'keys | join(",")')" = "data,sha,versao" ]
}

@test "pages: prd preserva qa/ e hom/ e troca so a raiz" {
  pages_setup
  deploy_instalar qa shaq 1.0.0-rc.1 "$ZIP"
  deploy_instalar hom shah 1.0.0-rc.1 "$ZIP"
  deploy_instalar prd sha1 1.0.0 "$ZIP"
  deploy_instalar prd sha2 1.1.0 "$ZIP2"
  [ "$(pages_ver qa/version.json | jq -r .sha)" = shaq ]
  [ "$(pages_ver hom/version.json | jq -r .sha)" = shah ]
  [ "$(pages_ver qa/index.html)" = "<html>v1</html>" ]
  [ "$(pages_ver version.json | jq -r .sha)" = sha2 ]
  [ "$(pages_ver novo.html)" = "<html>v2</html>" ]
  run git --git-dir="$PAGES_BARE" cat-file -e gh-pages:index.html
  [ "$status" -ne 0 ]
}

@test "pages: push recusado refaz a partir de clone novo (corrida entre ambientes)" {
  pages_setup
  deploy_instalar prd sha1 1.0.0 "$ZIP"
  # outro ambiente publica entre o clone e o push: o primeiro push e recusado e o outro commit entra no gh-pages
  mkdir -p "$PAGES_BARE/hooks"
  cat > "$PAGES_BARE/hooks/pre-receive" <<EOS
#!/bin/sh
n=\$(cat "$BATS_TEST_TMPDIR/pr" 2> /dev/null || echo 0)
echo \$((n + 1)) > "$BATS_TEST_TMPDIR/pr"
[ "\$n" -ge 1 ]
EOS
  chmod +x "$PAGES_BARE/hooks/pre-receive"
  run deploy_instalar hom shah 1.0.0-rc.1 "$ZIP2"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/pr")" -eq 2 ]
  [ "$(pages_ver hom/version.json | jq -r .sha)" = shah ]
  [ "$(pages_ver version.json | jq -r .sha)" = sha1 ]
}

@test "pages: push sempre recusado falha apos as tentativas" {
  pages_setup
  mkdir -p "$PAGES_BARE/hooks"
  printf '#!/bin/sh
exit 1
' > "$PAGES_BARE/hooks/pre-receive"
  chmod +x "$PAGES_BARE/hooks/pre-receive"
  run deploy_instalar qa sha1 1.0.0 "$ZIP"
  [ "$status" -eq 1 ]
}

@test "pages: qa nao toca hom/ nem a raiz" {
  pages_setup
  deploy_instalar prd sha1 1.0.0 "$ZIP"
  deploy_instalar qa shaq 1.1.0-rc.1 "$ZIP2"
  [ "$(pages_ver version.json | jq -r .sha)" = sha1 ]
  [ "$(pages_ver index.html)" = "<html>v1</html>" ]
  [ "$(pages_ver qa/novo.html)" = "<html>v2</html>" ]
}

@test "pages: ambiente invalido recusado antes de qualquer operacao" {
  pages_setup
  run deploy_instalar "" sha1 1.0.0 "$ZIP"
  [ "$status" -eq 1 ]
  run deploy_instalar ../x sha1 1.0.0 "$ZIP"
  [ "$status" -eq 1 ]
  run git --git-dir="$PAGES_BARE" rev-parse --verify gh-pages
  [ "$status" -ne 0 ]
}

@test "pages: pacote prd com qa/ na raiz e recusado" {
  pages_setup
  mkdir -p "$BATS_TEST_TMPDIR/c3/qa"
  echo x > "$BATS_TEST_TMPDIR/c3/qa/a.txt"
  zip_criar "$BATS_TEST_TMPDIR/c3" "$BATS_TEST_TMPDIR/c3.zip"
  run deploy_instalar prd sha1 1.0.0 "$BATS_TEST_TMPDIR/c3.zip"
  [ "$status" -eq 1 ]
  run git --git-dir="$PAGES_BARE" rev-parse --verify gh-pages
  [ "$status" -ne 0 ]
}

@test "pages: remoto inalcancavel falha e nao e lido como gh-pages ausente" {
  pages_setup
  export PAGES_REMOTE="$BATS_TEST_TMPDIR/nao-existe.git"
  run deploy_instalar qa sha1 1.0.0 "$ZIP"
  [ "$status" -eq 1 ]
}

@test "pages: token vai por header de ambiente, nunca no argv do git" {
  pages_setup
  mkdir -p "$BATS_TEST_TMPDIR/gbin"
  real=$(command -v git)
  cat > "$BATS_TEST_TMPDIR/gbin/git" <<EOS
#!/bin/sh
printf 'ARGV %s\n' "\$*" >> "$BATS_TEST_TMPDIR/git.log"
printf 'ENV %s\n' "\$GIT_CONFIG_VALUE_0" >> "$BATS_TEST_TMPDIR/git.log"
exec "$real" "\$@"
EOS
  chmod +x "$BATS_TEST_TMPDIR/gbin/git"
  PATH="$BATS_TEST_TMPDIR/gbin:$PATH"
  run deploy_instalar qa sha1 1.0.0 "$ZIP"
  [ "$status" -eq 0 ]
  b64=$(printf 'x-access-token:tok-secreto' | base64 | tr -d '\n')
  grep -q "^ENV AUTHORIZATION: basic $b64" "$BATS_TEST_TMPDIR/git.log"
  ! grep '^ARGV' "$BATS_TEST_TMPDIR/git.log" | grep -q "tok-secreto\|$b64" || false
}

curl_saude_stub() {   # SHA_RESPONDIDO APOS_N_FALHAS
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'STUB'
#!/bin/sh
n=$(cat "$BATS_TEST_TMPDIR/n" 2> /dev/null || echo 0)
n=$((n + 1)); echo "$n" > "$BATS_TEST_TMPDIR/n"
for a; do u=$a; done
echo "$u" >> "$BATS_TEST_TMPDIR/urls"
[ "$n" -gt "$FALHAS" ] || exit 22
printf '{"sha":"%s"}' "$RESP_SHA"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export BATS_TEST_TMPDIR
}

@test "saude: tenta de novo ate o version.json ter o sha" {
  pages_setup
  export URL_QA=https://acme.github.io/app/qa PAGES_TENTATIVAS=5 PAGES_INTERVALO=0 FALHAS=2 RESP_SHA=sha1
  curl_saude_stub
  run deploy_saude qa sha1
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/n")" -eq 3 ]
  grep -qx 'https://acme.github.io/app/qa/version.json' "$BATS_TEST_TMPDIR/urls"
}

@test "saude: sha diferente esgota as tentativas e falha" {
  pages_setup
  export URL_HOM=https://acme.github.io/app/hom PAGES_TENTATIVAS=3 PAGES_INTERVALO=0 FALHAS=0 RESP_SHA=velho
  curl_saude_stub
  run deploy_saude hom novo
  [ "$status" -eq 1 ]
  [ "$(cat "$BATS_TEST_TMPDIR/n")" -eq 3 ]
}

@test "saude: sha esperado vem de SAUDE_SHA ou do ultimo deploy; sem nenhum, falha" {
  pages_setup
  export URL_PRD=https://acme.github.io/app PAGES_TENTATIVAS=2 PAGES_INTERVALO=0 FALHAS=0 RESP_SHA=sha9
  curl_saude_stub
  run deploy_saude prd
  [ "$status" -eq 1 ]
  SAUDE_SHA=sha9 run deploy_saude prd
  [ "$status" -eq 0 ]
  unset SAUDE_SHA
  deploy_instalar prd sha9 1.0.0 "$ZIP"
  deploy_saude prd
}

@test "saude: curl com --max-time" {
  pages_setup
  export URL_QA=https://acme.github.io/app/qa PAGES_TENTATIVAS=1 PAGES_INTERVALO=0 FALHAS=0 RESP_SHA=sha1
  curl_saude_stub
  sed -i 's/^for a; do u=\$a; done/printf "%s\n" "$*" >> "$BATS_TEST_TMPDIR\/cargs"; for a; do u=$a; done/' "$BATS_TEST_TMPDIR/bin/curl"
  run deploy_saude qa sha1
  [ "$status" -eq 0 ]
  grep -q -- '--max-time' "$BATS_TEST_TMPDIR/cargs"
}

@test "webhook com aspas e barra e escapado no config do curl" {
  curl_webhook_stub
  export NOTIFICAR_WEBHOOK='https://h.example/a"b\c'
  # shellcheck source=/dev/null
  . "$KIT_DIR/adapters/notificar/slack.sh"
  run notificar info oi
  [ "$status" -eq 0 ]
  grep -qF 'url = "https://h.example/a\"b\\c"' "$BATS_TEST_TMPDIR/wh.cfg"
}

@test "saude: ambiente invalido ou sem URL falha" {
  pages_setup
  run deploy_saude xyz sha1
  [ "$status" -eq 1 ]
  unset URL_QA
  run deploy_saude qa sha1
  [ "$status" -eq 1 ]
}

# ---------- notificadores ----------

HOSTIL=$'Falhou "aspas" $(touch /tmp/pwn) `id` \\ barra\nsegunda linha \xf0\x9f\x9a\xa8'

curl_webhook_stub() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'STUB'
#!/bin/sh
printf 'ARGS %s\n' "$*" >> "$BATS_TEST_TMPDIR/wh.log"
while [ $# -gt 0 ]; do
  case "$1" in -K) cat "$2" >> "$BATS_TEST_TMPDIR/wh.cfg" ;; esac
  shift
done
cat > "$BATS_TEST_TMPDIR/wh.body"
[ ! -f "$BATS_TEST_TMPDIR/wh.falha" ] || exit 22
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export BATS_TEST_TMPDIR NOTIFICAR_WEBHOOK=https://hooks.example/secreto-xyz
}

@test "teams e slack: texto hostil vira JSON valido e literal; webhook fora do argv" {
  curl_webhook_stub
  for s in teams slack; do
    : > "$BATS_TEST_TMPDIR/wh.log"
    # shellcheck source=/dev/null
    . "$KIT_DIR/adapters/notificar/$s.sh"
    run notificar alerta "$HOSTIL"
    [ "$status" -eq 0 ]
    jq -e . "$BATS_TEST_TMPDIR/wh.body" > /dev/null
    [ "$(jq -r .text "$BATS_TEST_TMPDIR/wh.body")" = "[alerta] $HOSTIL" ]
    ! grep -q secreto-xyz "$BATS_TEST_TMPDIR/wh.log" || false
    grep -q 'url = "https://hooks.example/secreto-xyz"' "$BATS_TEST_TMPDIR/wh.cfg"
  done
  [ ! -e /tmp/pwn ]
}

@test "teams: falha do webhook propaga erro sem vazar a URL" {
  curl_webhook_stub
  : > "$BATS_TEST_TMPDIR/wh.falha"
  # shellcheck source=/dev/null
  . "$KIT_DIR/adapters/notificar/teams.sh"
  run notificar alerta oi
  [ "$status" -eq 1 ]
  [[ "$output" != *secreto-xyz* ]]
}

@test "teams: sem NOTIFICAR_WEBHOOK falha" {
  curl_webhook_stub
  unset NOTIFICAR_WEBHOOK
  # shellcheck source=/dev/null
  . "$KIT_DIR/adapters/notificar/teams.sh"
  run notificar alerta oi
  [ "$status" -ne 0 ]
}

@test "pr-comment: comenta no MR_IID corrente com texto literal" {
  # shellcheck source=/dev/null
  . "$KIT_DIR/adapters/notificar/pr-comment.sh"
  MR_IID=42 NOTIFICAR_ISSUE=5 notificar alerta "$HOSTIL"
  [ "$(grep -c '^POST /repos/acme/app/issues/42/comments ' "$GH_LOG")" -eq 1 ]
  [ "$(grep '^POST ' "$GH_LOG" | sed 's/^POST [^ ]* //' | jq -r .body)" = "[alerta] $HOSTIL" ]
}

@test "pr-comment: sem MR_IID usa a issue NOTIFICAR_ISSUE" {
  # shellcheck source=/dev/null
  . "$KIT_DIR/adapters/notificar/pr-comment.sh"
  unset MR_IID
  NOTIFICAR_ISSUE=5 notificar info oi
  grep -q '^POST /repos/acme/app/issues/5/comments ' "$GH_LOG"
}

@test "pr-comment: sem MR_IID nem issue cai no console" {
  # shellcheck source=/dev/null
  . "$KIT_DIR/adapters/notificar/pr-comment.sh"
  unset MR_IID NOTIFICAR_ISSUE
  run notificar info oi
  [ "$status" -eq 0 ]
  [ "$output" = "[info] oi" ]
  ! grep -q '^POST ' "$GH_LOG" || false
}

@test "adaptadores novos sao executaveis, LF e sem nome de empresa" {
  emp=di
  for f in artefatos/github-release deploy/pages notificar/teams notificar/slack notificar/pr-comment; do
    [ -x "$KIT_DIR/adapters/$f.sh" ]
    ! grep -q $'\r' "$KIT_DIR/adapters/$f.sh" || false
    ! grep -qi "${emp}mep" "$KIT_DIR/adapters/$f.sh" || false
  done
}
