#!/usr/bin/env bats
load helper

setup() {
  setup_repo
  git -C "$WORK" config rerere.enabled false
  export GITFLOW_SAIDA="$BATS_TEST_TMPDIR/saida"
  export ARTEFATOS=pasta ARTEFATOS_DIR="$BATS_TEST_TMPDIR/artefatos"
  export DEPLOY=pasta DEPLOY_DIR="$BATS_TEST_TMPDIR/sites"
  export GITFLOW_RUN_ID=run-1 GITFLOW_LOCK_INTERVALO=1
  mkdir -p "$GITFLOW_SAIDA" "$WORK/scripts"
  printf '%s\n' '#!/bin/sh' 'mkdir -p dist' 'echo "build $(git rev-parse HEAD)" > dist/index.html' > "$WORK/scripts/build.sh"
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$WORK/scripts/test.sh"
  git -C "$WORK" add scripts
  git -C "$WORK" commit -q -m "chore: scripts"
  git -C "$WORK" push -q origin main
}

# build_qa N: commit novo + tag anotada qa.2026-01-01.N, devolve o sha em $SHA_N
build_qa() {
  echo "$1" > "$WORK/f$1.txt"
  git -C "$WORK" add "f$1.txt"
  git -C "$WORK" commit -q -m "feat: $1"
  git -C "$WORK" tag -a "qa.2026-01-01.$1" -m "Teste $1"
  git -C "$WORK" push -q origin main "qa.2026-01-01.$1"
}
est() {
  local e="$1"
  shift
  run env PATH="$KIT_DIR/core:$PATH" TAG="$TAG" AMBIENTE="${AMB:-qa}" sh -c 'cd "$1" && shift && exec "$@"' _ "$WORK" sh "$KIT_DIR/core/esteira.sh" "$e" "$@"
}
passos() {
  local e
  for e in "$@"; do
    est "$e"
    [ "$status" -eq 0 ] || { echo "etapa $e falhou: $output" >&2; return 1; }
  done
}
lock_dono() { (cd "$WORK" && sh "$KIT_DIR/core/lock.sh" dono "$1"); }
lock_livre() { [ -z "$(lock_dono "$1")" ]; }
branch_em() { git -C "$ORIGIN" rev-parse "refs/heads/$1"; }

@test "fluxo feliz qa: move qa, deployment success e locks livres" {
  build_qa 1
  TAG=qa.2026-01-01.1
  (cd "$WORK" && sh "$KIT_DIR/core/lock.sh" pegar montagem-qa 0 > /dev/null)
  echo montagem-qa > "$GITFLOW_SAIDA/lock-montagem"
  passos preparar construir testar publicar-pacote gates implantar verificar-auto registrar
  grep -q '^CONSTRUIR=sim$' "$GITFLOW_SAIDA/esteira.env"
  [ "$(branch_em qa)" = "$(git -C "$WORK" rev-parse HEAD)" ]
  [ -f "$DEPLOY_DIR/qa/version.json" ]
  [ "$(deploy_ultimo qa)" = "$TAG success" ]
  lock_livre ambiente-qa
  lock_livre montagem-qa
}

@test "pacote existente: CONSTRUIR=nao" {
  build_qa 1
  TAG=qa.2026-01-01.1
  passos preparar construir testar publicar-pacote
  est preparar
  assert_success
  grep -q '^CONSTRUIR=nao$' "$GITFLOW_SAIDA/esteira.env"
  [ "$(grep -c '^CONSTRUIR=' "$GITFLOW_SAIDA/esteira.env")" -eq 1 ]
}

@test "teste falhando: nada publicado e reexecucao roda testes de novo" {
  build_qa 1
  TAG=qa.2026-01-01.1
  printf '%s\n' '#!/bin/sh' 'echo rodou >> "$GITFLOW_SAIDA/testes.log"' 'exit 1' > "$WORK/scripts/test.sh"
  passos preparar construir
  est testar
  assert_failure
  est publicar-pacote
  assert_failure
  [ ! -e "$ARTEFATOS_DIR/app-$(git -C "$WORK" rev-parse HEAD).zip" ]
  passos preparar construir
  grep -q '^CONSTRUIR=sim$' "$GITFLOW_SAIDA/esteira.env"
  est testar
  assert_failure
  [ "$(wc -l < "$GITFLOW_SAIDA/testes.log")" -eq 2 ]
}

@test "falhou apos implantar: qa volta a build anterior, failed e locks soltos" {
  build_qa 1
  TAG=qa.2026-01-01.1
  passos preparar construir testar publicar-pacote implantar verificar-auto registrar
  SHA1=$(git -C "$WORK" rev-parse HEAD)
  rm -f "$GITFLOW_SAIDA/esteira.env"
  build_qa 2
  TAG=qa.2026-01-01.2
  passos preparar construir testar publicar-pacote implantar
  [ "$(branch_em qa)" = "$(git -C "$WORK" rev-parse HEAD)" ]
  est falhou
  assert_success
  [ "$(branch_em qa)" = "$SHA1" ]
  [ "$(deploy_ultimo qa)" = "qa.2026-01-01.1 success" ]
  grep -q "$SHA1" "$DEPLOY_DIR/qa/version.json"
  lock_livre ambiente-qa
  run jq -r '[.[] | select(.ref == "qa.2026-01-01.2")] | last | .status' "$FAKE_DIR/deployments.json"
  assert_output failed
}

@test "voltar falhando (sem build anterior): locks continuam e alerta" {
  build_qa 1
  TAG=qa.2026-01-01.1
  passos preparar construir testar publicar-pacote implantar
  est falhou
  assert_failure
  assert_output --partial "[alerta]"
  [ -n "$(lock_dono ambiente-qa)" ]
  run jq -r 'last | .status' "$FAKE_DIR/deployments.json"
  assert_output failed
}

@test "implantar em prd com hotfix publicado depois da preview: recusa P9" {
  AMB=prd
  git -C "$WORK" checkout -q --detach main
  git -C "$WORK" tag -a --cleanup=verbatim hom.2026-01-01.1 -m "Release 1.1.0"
  git -C "$WORK" tag -a regressao-ok/hom.2026-01-01.1 -m ok
  git -C "$WORK" tag -a v1.1.0 -m v1.1.0
  git -C "$WORK" push -q origin main v1.1.0 hom.2026-01-01.1
  # hotfix chega a PRD depois da preview, so no origin (outro clone): o WORK nao sabe
  git clone -q "$ORIGIN" "$BATS_TEST_TMPDIR/outro" 2> /dev/null
  git -C "$BATS_TEST_TMPDIR/outro" config user.name T
  git -C "$BATS_TEST_TMPDIR/outro" config user.email t@example.com
  git -C "$BATS_TEST_TMPDIR/outro" checkout -q main
  echo hf > "$BATS_TEST_TMPDIR/outro/hf.txt"
  git -C "$BATS_TEST_TMPDIR/outro" add hf.txt
  git -C "$BATS_TEST_TMPDIR/outro" commit -q -m "fix: hf"
  git -C "$BATS_TEST_TMPDIR/outro" tag -a v1.0.1 -m v1.0.1
  git -C "$BATS_TEST_TMPDIR/outro" push -q origin main v1.0.1
  id=$(deploy_iniciar prd v1.0.1 "$(git -C "$BATS_TEST_TMPDIR/outro" rev-parse HEAD)")
  deploy_concluir "$id" success
  TAG=v1.1.0
  SHA=$(git -C "$WORK" rev-parse "v1.1.0^{commit}")
  # pacote ja existe (preview)
  git -C "$WORK" checkout -q "$SHA"
  sh -c 'cd "$1" && sh "$2/core/pacote.sh" build "$3" && sh "$2/core/pacote.sh" publicar "$3"' _ "$WORK" "$KIT_DIR" "$SHA" > /dev/null
  git -C "$WORK" checkout -q main
  printf 'SHA=%s\nCONSTRUIR=nao\n' "$SHA" > "$GITFLOW_SAIDA/esteira.env"
  est implantar
  assert_failure
  assert_output --partial "P9: o commit de v1.1.0 não contém a main atual"
  [ ! -e "$DEPLOY_DIR/prd" ]
}

@test "preparar em prd sem pacote: PRD nunca compila" {
  AMB=prd
  git -C "$WORK" checkout -q --detach main
  git -C "$WORK" tag -a --cleanup=verbatim hom.2026-01-01.1 -m "Release 1.1.0"
  git -C "$WORK" tag -a regressao-ok/hom.2026-01-01.1 -m ok
  git -C "$WORK" tag -a v1.1.0 -m v1.1.0
  git -C "$WORK" push -q origin main v1.1.0 hom.2026-01-01.1
  TAG=v1.1.0
  est preparar
  assert_failure
  assert_output --partial "PRD nunca compila"
}

@test "verificar-auto sem checar.sh em qa imprime MANUAL" {
  build_qa 1
  TAG=qa.2026-01-01.1
  passos preparar construir testar publicar-pacote implantar
  est verificar-auto
  assert_success
  assert_output --partial "MANUAL"
  grep -q '^VERIFICAR=MANUAL$' "$GITFLOW_SAIDA/esteira.env"
}

@test "verificar-auto com checar.sh falhando: etapa falha" {
  build_qa 1
  TAG=qa.2026-01-01.1
  printf '%s\n' '#!/bin/sh' 'exit 3' > "$WORK/scripts/checar.sh"
  passos preparar construir testar publicar-pacote implantar
  est verificar-auto
  assert_failure
}

@test "gates da app falhando barra" {
  build_qa 1
  TAG=qa.2026-01-01.1
  printf '%s\n' '#!/bin/sh' 'exit 1' > "$WORK/scripts/gates.sh"
  passos preparar
  est gates
  assert_failure
}

# hom_build N SUBJECT: commit + tag anotada hom.2026-01-01.N
hom_build() {
  echo "h$1" > "$WORK/h$1.txt"
  git -C "$WORK" add "h$1.txt"
  git -C "$WORK" commit -q -m "feat: h$1"
  git -C "$WORK" tag -a --cleanup=verbatim "hom.2026-01-01.$1" -m "$2"
  git -C "$WORK" push -q origin main "hom.2026-01-01.$1"
}

@test "voltar em hom ignora preview Release nunca publicada" {
  AMB=hom
  hom_build 1 "Ajustes de hom"
  TAG=hom.2026-01-01.1
  passos preparar construir testar publicar-pacote implantar registrar
  SHA1=$(git -C "$WORK" rev-parse HEAD)
  rm -f "$GITFLOW_SAIDA/esteira.env"
  hom_build 2 "Release 1.1.0"
  TAG=hom.2026-01-01.2
  passos preparar construir testar publicar-pacote implantar registrar
  rm -f "$GITFLOW_SAIDA/esteira.env"
  hom_build 3 "Ajustes de hom"
  TAG=hom.2026-01-01.3
  passos preparar construir testar publicar-pacote implantar
  est falhou
  assert_success
  # a anterior (hom.2) e preview de release nao publicada: volta para hom.1
  [ "$(branch_em hom)" = "$SHA1" ]
  [ "$(deploy_ultimo hom)" = "hom.2026-01-01.1 success" ]
}

@test "falhou com a esteira abortada antes de implantar solta a montagem" {
  build_qa 1
  TAG=qa.2026-01-01.1
  (cd "$WORK" && sh "$KIT_DIR/core/lock.sh" pegar montagem-qa 0 > /dev/null)
  echo montagem-qa > "$GITFLOW_SAIDA/lock-montagem"
  printf '%s
' '#!/bin/sh' 'exit 1' > "$WORK/scripts/test.sh"
  passos preparar construir
  est testar
  assert_failure
  est falhou
  lock_livre montagem-qa
}

@test "falhou sem DEPLOY_ID (lock nosso): so solta os locks, sem voltar" {
  build_qa 1
  TAG=qa.2026-01-01.1
  passos preparar
  (cd "$WORK" && sh "$KIT_DIR/core/lock.sh" pegar ambiente-qa 0 > /dev/null)
  est falhou
  assert_success
  lock_livre ambiente-qa
  [ "$(deploy_ultimo qa)" = "" ]
}

@test "verificar-auto prd sem smoke.sh usa deploy_saude" {
  AMB=prd
  TAG=v1.0.0
  printf 'SHA=x
CONSTRUIR=nao
' > "$GITFLOW_SAIDA/esteira.env"
  est verificar-auto
  assert_failure
  mkdir -p "$DEPLOY_DIR/prd"
  echo '{}' > "$DEPLOY_DIR/prd/version.json"
  est verificar-auto
  assert_success
  grep -q '^VERIFICAR=OK$' "$GITFLOW_SAIDA/esteira.env"
}
