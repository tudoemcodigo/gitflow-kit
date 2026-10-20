#!/usr/bin/env bats
load helper

setup() {
  setup_repo
  export GITFLOW_SAIDA="$BATS_TEST_TMPDIR/saida"
  export ARTEFATOS=pasta ARTEFATOS_DIR="$BATS_TEST_TMPDIR/artefatos"
  export DEPLOY=pasta DEPLOY_DIR="$BATS_TEST_TMPDIR/sites"
  SHA=abc1234
  export SHA
  # app minima com scripts/build.sh que gera dist/
  APP="$BATS_TEST_TMPDIR/app"
  mkdir -p "$APP/scripts"
  printf '%s\n' '#!/bin/sh' 'mkdir -p dist/sub' 'echo ola > dist/index.html' 'echo dado > dist/sub/a.txt' > "$APP/scripts/build.sh"
}

pacote() {
  run env PATH="$KIT_DIR/core:$PATH" sh -c 'cd "$1" && shift && exec sh "$@"' _ "$APP" "$KIT_DIR/core/pacote.sh" "$@"
}

@test "build gera zip e sha256 a partir de dist" {
  pacote build "$SHA"
  assert_success
  [ -f "$GITFLOW_SAIDA/app-$SHA.zip" ]
  [ -f "$GITFLOW_SAIDA/app-$SHA.zip.sha256" ]
  (cd "$GITFLOW_SAIDA" && sha256sum -c "app-$SHA.zip.sha256")
}

@test "existe falha antes e passa depois de publicar" {
  pacote existe "$SHA"
  assert_failure
  pacote build "$SHA"
  pacote publicar "$SHA"
  assert_success
  pacote existe "$SHA"
  assert_success
  [ -f "$ARTEFATOS_DIR/app-$SHA.zip.sha256" ]
}

@test "publicar duas vezes: a segunda recusa e nao sobrescreve" {
  pacote build "$SHA"
  pacote publicar "$SHA"
  assert_success
  antes=$(sha256sum "$ARTEFATOS_DIR/app-$SHA.zip")
  pacote publicar "$SHA"
  assert_failure
  assert_output --partial "nunca é sobrescrito"
  [ "$antes" = "$(sha256sum "$ARTEFATOS_DIR/app-$SHA.zip")" ]
}

@test "baixar entrega o mesmo arquivo" {
  pacote build "$SHA"
  pacote publicar "$SHA"
  pacote baixar "$SHA" "$BATS_TEST_TMPDIR/dl"
  assert_success
  cmp "$GITFLOW_SAIDA/app-$SHA.zip" "$BATS_TEST_TMPDIR/dl/app-$SHA.zip"
}

@test "baixar com sha256 adulterado: exit 1 e nada entregue" {
  pacote build "$SHA"
  pacote publicar "$SHA"
  echo "0000000000000000000000000000000000000000000000000000000000000000  app-$SHA.zip" > "$ARTEFATOS_DIR/app-$SHA.zip.sha256"
  pacote baixar "$SHA" "$BATS_TEST_TMPDIR/dl"
  assert_failure
  assert_output --partial "diverge"
  [ ! -e "$BATS_TEST_TMPDIR/dl/app-$SHA.zip" ]
}

@test "build sem scripts/build.sh para" {
  rm "$APP/scripts/build.sh"
  pacote build "$SHA"
  assert_failure
}

@test "deploy instala o pacote, grava version.json e saude passa" {
  pacote build "$SHA"
  pacote publicar "$SHA"
  . "$KIT_DIR/core/lib.sh"
  carregar_config
  ! deploy_saude qa || false
  deploy_instalar qa "$SHA" qa.2026-10-15.1 "$GITFLOW_SAIDA/app-$SHA.zip"
  deploy_saude qa
  [ "$(cat "$DEPLOY_DIR/qa/index.html")" = ola ]
  [ "$(cat "$DEPLOY_DIR/qa/sub/a.txt")" = dado ]
  [ "$(jq -r .versao "$DEPLOY_DIR/qa/version.json")" = qa.2026-10-15.1 ]
  [ "$(jq -r .sha "$DEPLOY_DIR/qa/version.json")" = "$SHA" ]
  [ -n "$(jq -r .data "$DEPLOY_DIR/qa/version.json")" ]
}

@test "reinstalar substitui o conteudo anterior" {
  pacote build "$SHA"
  . "$KIT_DIR/core/lib.sh"
  carregar_config
  mkdir -p "$DEPLOY_DIR/qa"
  echo velho > "$DEPLOY_DIR/qa/velho.txt"
  deploy_instalar qa "$SHA" v1 "$GITFLOW_SAIDA/app-$SHA.zip"
  [ ! -e "$DEPLOY_DIR/qa/velho.txt" ]
  [ -f "$DEPLOY_DIR/qa/index.html" ]
}

@test "notificar console imprime tipo e texto" {
  . "$KIT_DIR/core/lib.sh"
  carregar_config
  run notificar alerta 'texto $(x) "q"'
  assert_success
  assert_output '[alerta] texto $(x) "q"'
}
