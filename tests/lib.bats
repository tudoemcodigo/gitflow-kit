#!/usr/bin/env bats
load helper
bats_require_minimum_version 1.5.0

setup() {
  setup_repo
  cd "$WORK"
  export NOTIFICAR=console
  # shellcheck source=/dev/null
  . "$KIT_DIR/core/lib.sh"
  carregar_config
}

tag() { git tag "$@"; }

@test "carregar_config aplica padroes e le .gitflow.env" {
  [ "$LIMITE_QA" = 6 ]
  [ "$MODO_DEMO" = nao ]
  [ "$ID_REGEX" = '[A-Z]+-[0-9]+' ]
  echo "LIMITE_QA=9" > .gitflow.env
  LIMITE_QA= ; unset LIMITE_QA
  carregar_config
  [ "$LIMITE_QA" = 9 ]
}

@test "kit_dir e BOT" {
  [ "$(kit_dir)" = "$KIT_DIR" ]
  case "$BOT" in *"user.name=gitflow-bot"*"gitflow-bot@users.noreply.github.com"*) ;; *) false ;; esac
}

@test "id_da_branch" {
  [ "$(id_da_branch feature/PROJ-101-cadastro-ponto)" = PROJ-101 ]
  [ "$(id_da_branch bugfix/AB-7-x)" = AB-7 ]
  [ "$(id_da_branch hotfix/2.5.1)" = hotfix-2-5-1 ]
  [ -z "$(id_da_branch feature/proj-101-x)" ]
  [ -z "$(id_da_branch feature/PROJ-101)" ]
  ID_REGEX='[0-9]+'
  [ "$(id_da_branch feature/42-x)" = 42 ]
}

@test "ultima_rc ordena numericamente" {
  tag rc/PROJ-1.9; tag rc/PROJ-1.10; tag rc/PROJ-2.1
  [ "$(ultima_rc PROJ-1)" = rc/PROJ-1.10 ]
  [ -z "$(ultima_rc PROJ-9)" ]
}

@test "estado" {
  tag rc/PROJ-1.1
  [ "$(estado rc/PROJ-1.1)" = teste ]
  tag qa-ok/PROJ-1.1
  [ "$(estado rc/PROJ-1.1)" = qa-ok ]
  tag qa-nok/PROJ-1.1
  [ "$(estado rc/PROJ-1.1)" = qa-nok ]
  tag rc/PROJ-2.1; tag hom-ok/PROJ-2.1
  [ "$(estado rc/PROJ-2.1)" = hom-ok ]
  tag retirada/PROJ-2.1
  [ "$(estado rc/PROJ-2.1)" = retirada ]
}

@test "mrs_abertos: pesos" {
  nova_branch feature/PROJ-1-a a.txt; fake_pr 1 feature/PROJ-1-a ana
  nova_branch feature/PROJ-2-b b.txt; fake_pr 2 feature/PROJ-2-b ana
  nova_branch feature/PROJ-3-c c.txt; fake_pr 3 feature/PROJ-3-c ana
  nova_branch feature/PROJ-4-d d.txt; fake_pr 4 feature/PROJ-4-d ana
  pr_rotular 1 "Prioridade::1" ""
  pr_rotular 3 "Suspeita de checagem" ""
  tag rc/PROJ-4.1; tag qa-nok/PROJ-4.1; tag rc/PROJ-4.2
  run mrs_abertos
  assert_line "1 feature/PROJ-1-a 3"
  assert_line "2 feature/PROJ-2-b 6"
  assert_line "3 feature/PROJ-3-c 2"
  assert_line "4 feature/PROJ-4-d 1"
}

@test "mrs_abertos: Prioridade 2 e 3" {
  nova_branch feature/PROJ-1-a a.txt; fake_pr 1 feature/PROJ-1-a ana
  nova_branch feature/PROJ-2-b b.txt; fake_pr 2 feature/PROJ-2-b ana
  pr_rotular 1 "Prioridade::2" ""; pr_rotular 2 "Prioridade::3" ""
  run mrs_abertos
  assert_line "1 feature/PROJ-1-a 4"
  assert_line "2 feature/PROJ-2-b 5"
}

@test "espelhar" {
  fake_pr 1 feature/PROJ-1-a ana
  tag rc/PROJ-1.1; tag qa-ok/PROJ-1.1
  espelhar 1 rc/PROJ-1.1
  [ "$(fake_labels 1)" = "Ambiente::HOM" ]
  fake_pr 2 hotfix/2.5.1 ana
  tag rc/hotfix-2-5-1.1
  espelhar 2 rc/hotfix-2-5-1.1
  [ "$(fake_labels 2)" = "Ambiente::Hotfix" ]
  tag hom-nok/PROJ-1.1
  espelhar 1 rc/PROJ-1.1
  [ "$(fake_labels 1)" = "Ambiente::HOM reprovado" ]
}

@test "aprovadas_vigentes qa-ok" {
  git push -q origin main
  # a: vigente
  nova_branch feature/PROJ-1-a a.txt; tag rc/PROJ-1.1; tag qa-ok/PROJ-1.1
  # b: nao-ultima
  nova_branch feature/PROJ-2-b b.txt; tag rc/PROJ-2.1; tag qa-ok/PROJ-2.1; tag rc/PROJ-2.2
  # c: ja na main
  tag rc/PROJ-3.1 main; tag qa-ok/PROJ-3.1
  # d: hotfix
  nova_branch hotfix/2.5.1 h.txt; tag rc/hotfix-2-5-1.1; tag qa-ok/hotfix-2-5-1.1
  # e: com nok
  nova_branch feature/PROJ-5-e e.txt; tag rc/PROJ-5.1; tag qa-ok/PROJ-5.1; tag qa-nok/PROJ-5.1
  git fetch -q origin
  run aprovadas_vigentes qa-ok
  assert_success
  assert_output "rc/PROJ-1.1"
}

@test "assunto, manifesto, ultima_build, contem, ordenar_por_data" {
  git tag -a -m "assunto x

corpo y" qa/1.0.0-rc.1
  [ "$(assunto qa/1.0.0-rc.1)" = "assunto x" ]
  [ "$(manifesto_de qa/1.0.0-rc.1)" = "corpo y" ]
  [ "$(ultima_build qa/1.0.0-rc)" = qa/1.0.0-rc.1 ]
  printf 'rc/A-1.1 x\n' > m.txt
  contem m.txt rc/A-1.1
  ! contem m.txt rc/A-1.2 || false
  tag rc/A-1.1; tag qa-ok/A-1.1
  run sh -c ". '$KIT_DIR/core/lib.sh'; printf 'rc/A-1.1 1 t\n' | ordenar_por_data qa-ok"
  assert_output "rc/A-1.1 1 t"
}

@test "hotfix_aguardando_qa" {
  nova_branch hotfix/2.5.1 h.txt; fake_pr 1 hotfix/2.5.1 ana
  run hotfix_aguardando_qa
  assert_output ""
  tag rc/hotfix-2-5-1.1
  run hotfix_aguardando_qa
  assert_output "hotfix/2.5.1"
  # aprovado no QA e ainda nao promovido: continua reservando
  tag qa-ok/hotfix-2-5-1.1
  run hotfix_aguardando_qa
  assert_output "hotfix/2.5.1"
  # promovido (hom.* "Hotfix X" com a entrega no manifesto): libera
  printf 'Hotfix 2.5.1

rc/hotfix-2-5-1.1 !1 x
' > "$BATS_TEST_TMPDIR/m"
  git tag -a --cleanup=verbatim hom.2026-01-01.1 -F "$BATS_TEST_TMPDIR/m"
  run hotfix_aguardando_qa
  assert_output ""
}

@test "sai, para, recusa_pr" {
  run sai "ok"
  assert_success; assert_output "ok"
  run para "falhou"
  assert_failure 1
  assert_output --partial "PARADO: falhou"
  fake_pr 1 feature/PROJ-1-a ana
  run recusa_pr 1 "Entrega recusada" 'x $(y)'
  assert_failure 1
  run fake_comentarios 1
  assert_output '⛔ Entrega recusada: x $(y)'
}

@test "para chama notificar se existir" {
  notificar() { echo "NOTIF $*" >> "$BATS_TEST_TMPDIR/n"; }
  ( para "boom" ) || true
  [ "$(cat "$BATS_TEST_TMPDIR/n")" = "NOTIF alerta boom" ]
}

@test "carregar_config: ambiente vence o arquivo e CR e removido" {
  printf 'LIMITE_QA=9\r\nNOTIFICAR=console\r\n# comentario\r\nMODO_DEMO=sim\r\n' > .gitflow.env
  unset LIMITE_QA MODO_DEMO
  export NOTIFICAR=nenhum
  carregar_config
  [ "$LIMITE_QA" = 9 ]
  [ "$MODO_DEMO" = sim ]
  [ "$NOTIFICAR" = nenhum ]
}

@test "publicada ignora tags de decisao no mesmo commit" {
  git tag -a qa.1 -m b HEAD
  git push -q origin main qa.1
  git push -q origin HEAD:refs/heads/qa
  git fetch -q origin
  git tag -a qa-ok/X-1.1 -m ok HEAD
  [ "$(publicada qa)" = qa.1 ]
  [ -z "$(publicada hom)" ]
}

@test "ultima_build e publicada ordenam .10 acima de .9" {
  git tag -a qa.2026-10-14.9 -m b HEAD
  git tag -a qa.2026-10-14.10 -m b HEAD
  git push -q origin main qa.2026-10-14.9 qa.2026-10-14.10
  git push -q origin HEAD:refs/heads/qa
  git fetch -q origin
  [ "$(ultima_build qa)" = qa.2026-10-14.10 ]
  [ "$(publicada qa)" = qa.2026-10-14.10 ]
}

@test "carregar_config: .gitflow.env e lido literalmente (sem eval, sem expansao)" {
  rm -f "$BATS_TEST_TMPDIR/marker" "$BATS_TEST_TMPDIR/marker2"
  {
    printf 'URL_A=$(touch %s/marker)\n' "$BATS_TEST_TMPDIR"
    printf 'URL_B=`touch %s/marker2`\n' "$BATS_TEST_TMPDIR"
    printf 'URL_C="com aspas $HOME"\n'
    printf "URL_D='simples'\n"
    printf 'url_minuscula=1\n'
    printf 'URL_E; touch %s/marker=1\n' "$BATS_TEST_TMPDIR"
  } > .gitflow.env
  unset URL_A URL_B URL_C URL_D url_minuscula
  carregar_config
  [ ! -e "$BATS_TEST_TMPDIR/marker" ]
  [ ! -e "$BATS_TEST_TMPDIR/marker2" ]
  [ "$URL_A" = "\$(touch $BATS_TEST_TMPDIR/marker)" ]
  [ "$URL_B" = "\`touch $BATS_TEST_TMPDIR/marker2\`" ]
  [ "$URL_C" = 'com aspas $HOME' ]
  [ "$URL_D" = simples ]
  [ -z "${url_minuscula:-}" ]
}

@test "carregar_config: nome de adaptador com / ou . e recusado" {
  echo "ARTEFATOS=../../x" > .gitflow.env
  unset ARTEFATOS
  run carregar_config
  [ "$status" -ne 0 ]
  [[ "$output" == *"ARTEFATOS inválido"* ]]
  printf 'DEPLOY=a.b\n' > .gitflow.env
  unset ARTEFATOS DEPLOY
  run carregar_config
  [ "$status" -ne 0 ]
  echo "NOTIFICAR=x/y" > .gitflow.env
  unset DEPLOY NOTIFICAR
  run carregar_config
  [ "$status" -ne 0 ]
}

@test "carregar_config: chaves fora da lista permitida sao ignoradas com aviso" {
  rm -f "$BATS_TEST_TMPDIR/pwn"
  {
    printf 'BASH_ENV=%s/pwn\n' "$BATS_TEST_TMPDIR"
    printf 'GIT_SSH_COMMAND=touch %s/pwn\n' "$BATS_TEST_TMPDIR"
    printf 'PATH=/nada\n'
    printf 'LD_PRELOAD=/x.so\n'
    printf 'GRUPO_QA=meu-qa\n'
    printf 'URL_QA=http://x\n'
    printf 'MODO_DEMO=sim\n'
  } > .gitflow.env
  unset BASH_ENV GIT_SSH_COMMAND LD_PRELOAD GRUPO_QA URL_QA MODO_DEMO
  PATH_ANTES=$PATH
  run --separate-stderr carregar_config
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"chave não permitida em .gitflow.env: BASH_ENV"* ]]
  [[ "$stderr" == *"chave não permitida em .gitflow.env: GIT_SSH_COMMAND"* ]]
  [[ "$stderr" == *"chave não permitida em .gitflow.env: PATH"* ]]
  carregar_config 2> /dev/null
  [ -z "${BASH_ENV:-}" ]
  [ -z "${GIT_SSH_COMMAND:-}" ]
  [ -z "${LD_PRELOAD:-}" ]
  [ "$PATH" = "$PATH_ANTES" ]
  [ "$GRUPO_QA" = meu-qa ]
  [ "$URL_QA" = http://x ]
  [ "$MODO_DEMO" = sim ]
}

@test "carregar_config: destinos de credencial e segredos so pelo ambiente" {
  {
    printf 'PAGES_REMOTE=https://evil.example/x.git\n'
    printf 'NOTIFICAR_WEBHOOK=https://hooks.example/s\n'
    printf 'DEPLOY_DIR=/tmp/d\n'
    printf 'ARTEFATOS_URL=https://evil.example\n'
    printf 'GRUPO_X_TOKEN=abc\n'
    printf 'URL_QA=http://qa.example\n'
  } > .gitflow.env
  unset PAGES_REMOTE NOTIFICAR_WEBHOOK DEPLOY_DIR ARTEFATOS_URL GRUPO_X_TOKEN URL_QA
  run --separate-stderr carregar_config
  [ "$status" -eq 0 ]
  for k in PAGES_REMOTE NOTIFICAR_WEBHOOK DEPLOY_DIR ARTEFATOS_URL GRUPO_X_TOKEN; do
    [[ "$stderr" == *"chave não permitida em .gitflow.env: $k"* ]]
  done
  carregar_config 2> /dev/null
  [ -z "${PAGES_REMOTE:-}" ]
  [ -z "${NOTIFICAR_WEBHOOK:-}" ]
  [ -z "${DEPLOY_DIR:-}" ]
  [ -z "${GRUPO_X_TOKEN:-}" ]
  [ "$URL_QA" = http://qa.example ]
  # o ambiente continua valendo
  export NOTIFICAR_WEBHOOK=https://hooks.example/env
  carregar_config 2> /dev/null
  [ "$NOTIFICAR_WEBHOOK" = https://hooks.example/env ]
}

@test "carregar_config: TZ e TERMO_PR nao sao chaves do .gitflow.env (sem efeito)" {
  printf 'TZ=UTC\nTERMO_PR=XX\n' > .gitflow.env
  run --separate-stderr carregar_config
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"chave não permitida em .gitflow.env: TZ"* ]]
  [[ "$stderr" == *"chave não permitida em .gitflow.env: TERMO_PR"* ]]
  carregar_config 2> /dev/null
  [ "$TZ" = America/Sao_Paulo ]
  [ "$TERMO_PR" = MR ]   # padrao do core (o provider github define PR por conta propria)
}

@test "exige-membro: @GRUPO_TL e @GRUPO_RM valem os grupos do .gitflow.env" {
  printf 'GRUPO_TL=meus-tls\nGRUPO_RM=meus-rms\n' > .gitflow.env
  unset GRUPO_TL GRUPO_RM
  fake_membro ana meus-tls
  fake_membro bia tech-leads
  EM="$KIT_DIR/ci/github-actions/exige-membro.sh"
  BUILD_USER_ID=ana run sh "$EM" @GRUPO_TL @GRUPO_RM
  assert_success
  BUILD_USER_ID=bia run sh "$EM" @GRUPO_TL @GRUPO_RM
  assert_failure
  assert_output --partial "meus-tls meus-rms"
}
