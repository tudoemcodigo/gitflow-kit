#!/usr/bin/env bats
load helper

setup() {
  setup_repo
  git -C "$WORK" config rerere.enabled false
  fake_membro qa1 qa
  fake_membro rm1 release-managers
  fake_membro dev1 devs
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
  fake_pr 7 feature/ISSUE-x dev
}

# entrega ID [DEC...]: branch, rc/ID.1 anotada, tags de decisao; tudo no origin
entrega() {
  local id="$1" d
  shift
  git -C "$WORK" checkout -q -B "feature/$id-x" main
  echo "$id" > "$WORK/$id.txt"
  git -C "$WORK" add "$id.txt"
  git -C "$WORK" commit -q -m "feat: $id"
  git -C "$WORK" tag -a "rc/$id.1" -m Entrega
  for d in "$@"; do git -C "$WORK" tag -a "$d/$id.1" -m x "rc/$id.1^{commit}"; done
  git -C "$WORK" push -q origin "feature/$id-x"
  git -C "$WORK" push -q origin --tags
}
# montar_amb AMB TITULO TAG RC...: commit de montagem a partir da main com manifesto (tag local)
montar_amb() {
  local amb="$1" tit="$2" tag="$3" rc msg nl
  nl=$'\n'
  shift 3
  git -C "$WORK" checkout -q --detach origin/main
  msg="$tit$nl${nl}base main x (v1.0.0)${nl}rerere nenhum"
  for rc in "$@"; do
    git -C "$WORK" merge -q --no-ff -m "m $rc" "$rc" > /dev/null
    msg="$msg$nl$rc !1 abc1234 homologada"
  done
  if [ $# -eq 0 ]; then git -C "$WORK" commit -q --allow-empty -m montagem; fi
  git -C "$WORK" tag -a --cleanup=verbatim "$tag" -m "$msg"
}
# publica_amb AMB TAG [STATUS]: tag e branch no origin e deployment (padrao success)
publica_amb() {
  local id
  git -C "$WORK" push -q origin "refs/tags/$2"
  git -C "$WORK" push -q -f origin "$2^{commit}:refs/heads/$1"
  id=$(deploy_iniciar "$1" "$2" "$(git -C "$WORK" rev-parse "$2^{commit}")")
  deploy_concluir "$id" "${3:-success}"
}
tem_tag() { git -C "$ORIGIN" rev-parse -q --verify "refs/tags/$1" > /dev/null; }
msg_tag() { git -C "$ORIGIN" tag -l --format='%(contents)' "$1"; }
reg() { BUILD_USER_ID="${USUARIO:-qa1}" rodar regressao.sh "$@"; }
rel() { BUILD_USER_ID="${USUARIO:-rm1}" rodar criar-release.sh "$@"; }
hotp() { BUILD_USER_ID="${USUARIO:-rm1}" rodar promover-hotfix.sh "$@"; }
pub() { rodar publicar.sh "$@"; }
# hook_recusa_tag PADRAO: o origin recusa o push de refs que casam com o padrao
hook_recusa_tag() {
  printf '%s
' '#!/bin/sh' 'while read -r _o _n ref; do' "  case \"\$ref\" in $1) echo recusado >&2; exit 1 ;; esac" 'done' > "$ORIGIN/hooks/pre-receive"
  chmod +x "$ORIGIN/hooks/pre-receive"
}
# hotp_so QA_TAG: so o stdout do promover-hotfix.sh (a tag impressa), em $saida
hotp_so() {
  saida=$(BUILD_USER_ID="${USUARIO:-rm1}" PATH="$KIT_DIR/core:$PATH" sh -c 'cd "$1" && shift && exec "$@" 2> /dev/null' _ "$WORK" sh "$KIT_DIR/core/promover-hotfix.sh" "$@")
}
# regressao_ok TAG: registra regressao-ok direto (sem passar pelo script)
regressao_ok() {
  git -C "$WORK" tag -a "regressao-ok/$1" -m ok
  git -C "$WORK" push -q origin --tags
}
# release_pronta: hom.1 "Release 1.1.0" com ABC-1, publicada, regressao-ok
release_pronta() {
  entrega ABC-1 qa-ok hom-ok
  montar_amb hom "Release 1.1.0" hom.2026-01-01.1 rc/ABC-1.1
  publica_amb hom hom.2026-01-01.1
  regressao_ok hom.2026-01-01.1
}
# em_prd TAG: deployment success de PRD para a tag
em_prd() {
  local id
  id=$(deploy_iniciar prd "$1" "$(git -C "$WORK" rev-parse "$1^{commit}")")
  deploy_concluir "$id" success
}
# prd_v110: release v1.1.0 (ABC-1, MR 1 aberto) criada e em PRD, main ainda na v1.0.0
prd_v110() {
  fake_pr 1 feature/ABC-1-x dev
  release_pronta
  rel 1.1.0 hom.2026-01-01.1 7
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  em_prd v1.1.0
}

# ---------- regressao ----------

@test "regressao de hom nao publicada recusa" {
  entrega ABC-1 qa-ok hom-ok
  montar_amb hom "Release 1.1.0" hom.2026-01-01.1 rc/ABC-1.1
  git -C "$WORK" push -q origin refs/tags/hom.2026-01-01.1
  reg hom.2026-01-01.1 ok 7
  assert_failure
  assert_output --partial "não está publicada"
  ! tem_tag regressao-ok/hom.2026-01-01.1 || false
}

@test "regressao com deployment ainda em execucao recusa" {
  entrega ABC-1 qa-ok hom-ok
  montar_amb hom "Release 1.1.0" hom.2026-01-01.1 rc/ABC-1.1
  publica_amb hom hom.2026-01-01.1 running
  reg hom.2026-01-01.1 ok 7
  assert_failure
  assert_output --partial "não está verificada"
  ! tem_tag regressao-ok/hom.2026-01-01.1 || false
}

@test "regressao ok registra a tag com quem e a issue e comenta" {
  entrega ABC-1 qa-ok hom-ok
  montar_amb hom "Release 1.1.0" hom.2026-01-01.1 rc/ABC-1.1
  publica_amb hom hom.2026-01-01.1
  reg hom.2026-01-01.1 ok 7
  assert_success
  tem_tag regressao-ok/hom.2026-01-01.1
  msg_tag regressao-ok/hom.2026-01-01.1 | grep -F 'qa1'
  msg_tag regressao-ok/hom.2026-01-01.1 | grep -F '7'
  fake_issue_comentarios 7 | grep -F 'hom.2026-01-01.1'
}

@test "regressao so para o grupo QA" {
  entrega ABC-1 qa-ok hom-ok
  montar_amb hom "Release 1.1.0" hom.2026-01-01.1 rc/ABC-1.1
  publica_amb hom hom.2026-01-01.1
  USUARIO=dev1 reg hom.2026-01-01.1 ok 7
  assert_failure
  assert_output --partial "não pertence a"
  ! tem_tag regressao-ok/hom.2026-01-01.1 || false
}

@test "regressao falhou nao cria tag e avisa a issue" {
  entrega ABC-1 qa-ok hom-ok
  montar_amb hom "Release 1.1.0" hom.2026-01-01.1 rc/ABC-1.1
  publica_amb hom hom.2026-01-01.1
  reg hom.2026-01-01.1 falhou 7
  assert_success
  ! tem_tag regressao-ok/hom.2026-01-01.1 || false
  fake_issue_comentarios 7 | grep -F 'falhou'
}

@test "regressao repetida nao cria outra tag nem falha" {
  entrega ABC-1 qa-ok hom-ok
  montar_amb hom "Release 1.1.0" hom.2026-01-01.1 rc/ABC-1.1
  publica_amb hom hom.2026-01-01.1
  reg hom.2026-01-01.1 ok 7
  assert_success
  reg hom.2026-01-01.1 ok 7
  assert_success
  assert_output --partial "já registrada"
  [ "$(git -C "$ORIGIN" tag -l 'regressao-ok/*' | wc -l)" -eq 1 ]
  [ "$(fake_issue_comentarios 7 | wc -l)" -eq 1 ]
}

@test "regressao com push de tag recusado nao deixa tag local e a repeticao refaz" {
  entrega ABC-1 qa-ok hom-ok
  montar_amb hom "Release 1.1.0" hom.2026-01-01.1 rc/ABC-1.1
  publica_amb hom hom.2026-01-01.1
  hook_recusa_tag 'refs/tags/regressao-ok/*'
  reg hom.2026-01-01.1 ok 7
  assert_failure
  assert_output --partial "não foi possível enviar"
  ! git -C "$WORK" rev-parse -q --verify refs/tags/regressao-ok/hom.2026-01-01.1 || false
  ! tem_tag regressao-ok/hom.2026-01-01.1 || false
  rm -f "$ORIGIN/hooks/pre-receive"
  reg hom.2026-01-01.1 ok 7
  assert_success
  tem_tag regressao-ok/hom.2026-01-01.1
}

@test "regressao com tag so local (sobra antiga) e reenviada" {
  entrega ABC-1 qa-ok hom-ok
  montar_amb hom "Release 1.1.0" hom.2026-01-01.1 rc/ABC-1.1
  publica_amb hom hom.2026-01-01.1
  git -C "$WORK" tag -a regressao-ok/hom.2026-01-01.1 -m sobra
  ! tem_tag regressao-ok/hom.2026-01-01.1 || false
  reg hom.2026-01-01.1 ok 7
  assert_success
  tem_tag regressao-ok/hom.2026-01-01.1
}

@test "regressao com resultado invalido recusa" {
  reg hom.2026-01-01.1 talvez 7
  assert_failure
  assert_output --partial "resultado inválido"
}

# ---------- criar-release ----------

@test "release sem regressao-ok recusa" {
  entrega ABC-1 qa-ok hom-ok
  montar_amb hom "Release 1.1.0" hom.2026-01-01.1 rc/ABC-1.1
  publica_amb hom hom.2026-01-01.1
  rel 1.1.0 hom.2026-01-01.1 7
  assert_failure
  assert_output --partial "regressao-ok"
  ! tem_tag v1.1.0 || false
}

@test "release com versao existente recusa" {
  release_pronta
  rel 1.0.0 hom.2026-01-01.1 7
  assert_failure
  assert_output --partial "já existe"
}

@test "release so para release manager" {
  release_pronta
  USUARIO=qa1 rel 1.1.0 hom.2026-01-01.1 7
  assert_failure
  assert_output --partial "não pertence a"
  ! tem_tag v1.1.0 || false
}

@test "release com versao invalida recusa" {
  release_pronta
  rel 1.1 hom.2026-01-01.1 7
  assert_failure
  assert_output --partial "versão inválida"
  rel v1.1.0 hom.2026-01-01.1 7
  assert_failure
  assert_output --partial "versão inválida"
}

@test "release com hom nao publicada agora recusa" {
  release_pronta
  git -C "$WORK" checkout -q --detach origin/main
  git -C "$WORK" commit -q --allow-empty -m outra
  git -C "$WORK" tag -a --cleanup=verbatim hom.2026-01-01.2 -m "Build hom"
  publica_amb hom hom.2026-01-01.2
  rel 1.1.0 hom.2026-01-01.1 7
  assert_failure
  assert_output --partial "não está publicada"
  ! tem_tag v1.1.0 || false
}

@test "release ok cria vX.Y.Z anotada no commit da hom e registra quem" {
  release_pronta
  rel 1.1.0 hom.2026-01-01.1 7
  assert_success
  tem_tag v1.1.0
  [ "$(git -C "$ORIGIN" cat-file -t refs/tags/v1.1.0)" = tag ]
  [ "$(git -C "$ORIGIN" rev-parse 'v1.1.0^{commit}')" = "$(git -C "$ORIGIN" rev-parse 'hom.2026-01-01.1^{commit}')" ]
  msg_tag v1.1.0 | grep -F 'hom.2026-01-01.1'
  msg_tag v1.1.0 | grep -F 'rm1'
  msg_tag v1.1.0 | grep -F '7'
}

@test "release que o validar-tag prd recusa nao deixa tag local nem remota" {
  entrega ABC-1 qa-ok
  montar_amb hom "Release 1.1.0" hom.2026-01-01.1 rc/ABC-1.1
  publica_amb hom hom.2026-01-01.1
  regressao_ok hom.2026-01-01.1
  rel 1.1.0 hom.2026-01-01.1 7
  assert_failure
  assert_output --partial "não está homologada"
  ! tem_tag v1.1.0 || false
  ! git -C "$WORK" rev-parse -q --verify refs/tags/v1.1.0 || false
}

@test "release de hotfix com titulo Hotfix cria a versao" {
  entrega hotfix-1-0-1 qa-ok hom-ok
  montar_amb hom "Hotfix 1.0.1" hom.2026-01-01.1 rc/hotfix-1-0-1.1
  publica_amb hom hom.2026-01-01.1
  regressao_ok hom.2026-01-01.1
  rel 1.0.1 hom.2026-01-01.1 7
  assert_success
  tem_tag v1.0.1
}

# ---------- promover-hotfix ----------

# hotfix_qa [DEC...]: qa.1 "Hotfix 1.0.1" publicada e verificada no QA
hotfix_qa() {
  entrega hotfix-1-0-1 "$@"
  montar_amb qa "Hotfix 1.0.1" qa.2026-01-01.1 rc/hotfix-1-0-1.1
  publica_amb qa qa.2026-01-01.1
}

@test "promover hotfix sem qa-ok recusa" {
  hotfix_qa
  hotp qa.2026-01-01.1
  assert_failure
  assert_output --partial "qa-ok"
}

@test "promover hotfix cria hom no mesmo commit e imprime so a tag" {
  hotfix_qa qa-ok
  hotp_so qa.2026-01-01.1
  [[ "$saida" =~ ^hom\.[0-9-]+\.1$ ]]
  tem_tag "$saida"
  [ "$(git -C "$ORIGIN" rev-parse "$saida^{commit}")" = "$(git -C "$ORIGIN" rev-parse 'qa.2026-01-01.1^{commit}')" ]
  [ "$(git -C "$ORIGIN" tag -l --format='%(contents:subject)' "$saida")" = "Hotfix 1.0.1" ]
  git -C "$ORIGIN" tag -l --format='%(contents:body)' "$saida" | grep -F 'rc/hotfix-1-0-1.1'
}

@test "promover hotfix de build que nao e Hotfix recusa" {
  entrega ABC-1 qa-ok
  montar_amb qa "Build qa" qa.2026-01-01.1 rc/ABC-1.1
  publica_amb qa qa.2026-01-01.1
  hotp qa.2026-01-01.1
  assert_failure
  assert_output --partial "Hotfix"
}

@test "promover hotfix de build nao publicada no QA recusa" {
  hotfix_qa qa-ok
  git -C "$WORK" checkout -q --detach origin/main
  git -C "$WORK" commit -q --allow-empty -m outra
  git -C "$WORK" tag -a --cleanup=verbatim qa.2026-01-01.2 -m "Build qa"
  publica_amb qa qa.2026-01-01.2
  hotp qa.2026-01-01.1
  assert_failure
  assert_output --partial "não está publicada"
}

@test "promover hotfix com entrega que nao e a ultima do MR recusa" {
  hotfix_qa qa-ok
  git -C "$WORK" tag -a rc/hotfix-1-0-1.2 -m Entrega "rc/hotfix-1-0-1.1^{commit}"
  git -C "$WORK" push -q origin --tags
  hotp qa.2026-01-01.1
  assert_failure
  assert_output --partial "não é a última entrega"
}

@test "promover hotfix so para release manager" {
  hotfix_qa qa-ok
  USUARIO=qa1 hotp qa.2026-01-01.1
  assert_failure
  assert_output --partial "não pertence a"
}

@test "promover hotfix duas vezes devolve a mesma hom" {
  hotfix_qa qa-ok
  hotp_so qa.2026-01-01.1
  primeira="$saida"
  hotp_so qa.2026-01-01.1
  [ -n "$primeira" ]
  [ "$saida" = "$primeira" ]
  [ "$(git -C "$ORIGIN" tag -l 'hom.*' | wc -l)" -eq 1 ]
}

@test "promover hotfix repetido depois do hom-ok e do QA remontado devolve a mesma hom" {
  hotfix_qa qa-ok
  hotp_so qa.2026-01-01.1
  primeira="$saida"
  git -C "$WORK" tag -a hom-ok/hotfix-1-0-1.1 -m x "rc/hotfix-1-0-1.1^{commit}"
  git -C "$WORK" push -q origin --tags
  git -C "$WORK" checkout -q --detach origin/main
  git -C "$WORK" commit -q --allow-empty -m outra
  git -C "$WORK" tag -a --cleanup=verbatim qa.2026-01-01.2 -m "Build qa"
  publica_amb qa qa.2026-01-01.2
  hotp_so qa.2026-01-01.1
  [ "$saida" = "$primeira" ]
}

@test "promover hotfix com push recusado nao deixa tag local e a repeticao funciona" {
  hotfix_qa qa-ok
  hook_recusa_tag 'refs/tags/hom.*'
  hotp qa.2026-01-01.1
  assert_failure
  assert_output --partial "não foi possível enviar"
  [ -z "$(git -C "$WORK" tag -l 'hom.*')" ]
  rm -f "$ORIGIN/hooks/pre-receive"
  hotp_so qa.2026-01-01.1
  tem_tag "$saida"
}

@test "promover hotfix com hom so local (sobra antiga) e refeita na origin" {
  hotfix_qa qa-ok
  git -C "$WORK" tag -a --cleanup=verbatim hom.2026-01-01.9 -m "Hotfix 1.0.1" qa.2026-01-01.1
  hotp_so qa.2026-01-01.1
  tem_tag "$saida"
  [ -z "$(git -C "$WORK" tag -l 'hom.2026-01-01.9')" ]
}

# ---------- publicar ----------

estado_pub() {
  git -C "$ORIGIN" rev-parse refs/heads/main
  fake_labels 1
  jq -r 'map(.tag) | join(",")' "$FAKE_DIR/releases.json"
  jq -r '.state' "$FAKE_DIR/pr/1.json"
  jq -r '.comments | length' "$FAKE_DIR/pr/1.json"
}

@test "publicar move a main, fecha o MR, apaga a branch e cria a release" {
  prd_v110
  pub v1.1.0
  assert_success
  [ "$(git -C "$ORIGIN" rev-parse refs/heads/main)" = "$(git -C "$ORIGIN" rev-parse 'v1.1.0^{commit}')" ]
  [ "$(jq -r .state "$FAKE_DIR/pr/1.json")" = closed ]
  fake_labels 1 | grep -F 'Ambiente::PRD'
  fake_comentarios 1 | grep -F 'v1.1.0'
  grep -Fx 'feature/ABC-1-x' "$FAKE_DIR/branches_apagadas.txt"
  [ "$(jq -r 'map(.tag) | join(",")' "$FAKE_DIR/releases.json")" = v1.1.0 ]
  jq -r '.[0].texto' "$FAKE_DIR/releases.json" | grep -F 'rc/ABC-1.1'
}

@test "publicar troca o label de ambiente por Ambiente::PRD" {
  fake_pr 1 feature/ABC-1-x dev
  pr_rotular 1 "Ambiente::Homologado,Ambiente::HOM" ""
  release_pronta
  rel 1.1.0 hom.2026-01-01.1 7
  em_prd v1.1.0
  pub v1.1.0
  assert_success
  [ "$(fake_labels 1)" = "Ambiente::PRD" ]
}

@test "publicar duas vezes: mesmo estado, sem erro e uma so release" {
  prd_v110
  pub v1.1.0
  assert_success
  antes=$(estado_pub)
  pub v1.1.0
  assert_success
  [ "$(estado_pub)" = "$antes" ]
  [ "$(jq length "$FAKE_DIR/releases.json")" -eq 1 ]
}

@test "publicar com MR de entrega mais nova nao publicada avisa e deixa aberto" {
  prd_v110
  # depois da release, o autor entrega de novo (rc .2 fora da versao)
  git -C "$WORK" checkout -q "feature/ABC-1-x"
  echo mais > "$WORK/mais.txt"
  git -C "$WORK" add mais.txt
  git -C "$WORK" commit -q -m "feat: mais"
  git -C "$WORK" tag -a rc/ABC-1.2 -m Entrega
  git -C "$WORK" push -q origin "feature/ABC-1-x" --tags
  pub v1.1.0
  assert_success
  [ "$(jq -r .state "$FAKE_DIR/pr/1.json")" = opened ]
  fake_comentarios 1 | grep -F 'rc/ABC-1.2'
  pub v1.1.0
  assert_success
  [ "$(fake_comentarios 1 | grep -cF 'rc/ABC-1.2')" -eq 1 ]
  ! grep -Fx 'feature/ABC-1-x' "$FAKE_DIR/branches_apagadas.txt" || false
  [ "$(git -C "$ORIGIN" rev-parse refs/heads/main)" = "$(git -C "$ORIGIN" rev-parse 'v1.1.0^{commit}')" ]
}

@test "publicar nao fecha MR sem entrega" {
  prd_v110
  pub v1.1.0
  assert_success
  [ "$(jq -r .state "$FAKE_DIR/pr/7.json")" = opened ]
}

@test "publicar tag que nao e a versao de PRD recusa" {
  fake_pr 1 feature/ABC-1-x dev
  release_pronta
  rel 1.1.0 hom.2026-01-01.1 7
  pub v1.1.0
  assert_failure
  assert_output --partial "não é a versão em PRD"
  [ "$(git -C "$ORIGIN" rev-parse refs/heads/main)" != "$(git -C "$ORIGIN" rev-parse 'v1.1.0^{commit}')" ]
}

@test "publicar com main divergente nao usa force" {
  prd_v110
  git clone -q "$ORIGIN" "$BATS_TEST_TMPDIR/outro" 2> /dev/null
  git -C "$BATS_TEST_TMPDIR/outro" config user.name T
  git -C "$BATS_TEST_TMPDIR/outro" config user.email t@example.com
  git -C "$BATS_TEST_TMPDIR/outro" checkout -q main
  echo x > "$BATS_TEST_TMPDIR/outro/x.txt"
  git -C "$BATS_TEST_TMPDIR/outro" add x.txt
  git -C "$BATS_TEST_TMPDIR/outro" commit -q -m x
  git -C "$BATS_TEST_TMPDIR/outro" push -q origin main
  antes=$(git -C "$ORIGIN" rev-parse refs/heads/main)
  pub v1.1.0
  assert_failure
  assert_output --partial "fast-forward impossível"
  [ "$(git -C "$ORIGIN" rev-parse refs/heads/main)" = "$antes" ]
}

@test "hotfix publicado depois da preview: a release esperando e recusada em PRD" {
  # release 1.1.0 pronta (v1.1.0 criada) e o hotfix 1.0.1 chega antes a PRD
  release_pronta
  rel 1.1.0 hom.2026-01-01.1 7
  entrega hotfix-1-0-1 qa-ok hom-ok
  montar_amb hom "Hotfix 1.0.1" hom.2026-01-01.2 rc/hotfix-1-0-1.1
  regressao_ok hom.2026-01-01.2
  git -C "$WORK" tag -a v1.0.1 -m v1.0.1
  git -C "$WORK" push -q origin --tags
  em_prd v1.0.1
  pub v1.0.1
  assert_success
  rodar validar-tag.sh v1.1.0 prd
  assert_failure
  assert_output --partial "P9"
}

# ---------- esteira registrar em prd ----------

# est_prd ETAPA: roda esteira.sh para v1.1.0 em prd
est_prd() {
  local e="$1"
  shift
  run env PATH="$KIT_DIR/core:$PATH" TAG=v1.1.0 AMBIENTE=prd sh -c 'cd "$1" && shift && exec "$@"' _ "$WORK" sh "$KIT_DIR/core/esteira.sh" "$e" "$@"
}
# prd_antes_do_registrar: release v1.1.0 com pacote, implantada em PRD, antes da etapa registrar
prd_antes_do_registrar() {
  fake_pr 1 feature/ABC-1-x dev
  release_pronta
  rel 1.1.0 hom.2026-01-01.1 7
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  SHA=$(git -C "$WORK" rev-parse 'v1.1.0^{commit}')
  git -C "$WORK" checkout -q "$SHA"
  sh -c 'cd "$1" && sh "$2/core/pacote.sh" build "$3" && sh "$2/core/pacote.sh" publicar "$3"' _ "$WORK" "$KIT_DIR" "$SHA" > /dev/null
  git -C "$WORK" checkout -q main
  est_prd preparar
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  est_prd implantar
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "registrar em prd: deployment success, main move, MR fecha e lock livre" {
  prd_antes_do_registrar
  est_prd registrar
  assert_success
  [ "$(deploy_ultimo prd)" = "v1.1.0 success" ]
  [ "$(git -C "$ORIGIN" rev-parse refs/heads/main)" = "$(git -C "$ORIGIN" rev-parse 'v1.1.0^{commit}')" ]
  [ "$(jq -r .state "$FAKE_DIR/pr/1.json")" = closed ]
  [ "$(jq length "$FAKE_DIR/releases.json")" -eq 1 ]
  [ -z "$(cd "$WORK" && sh "$KIT_DIR/core/lock.sh" dono ambiente-prd)" ]
}

@test "registrar em prd com publicar falhando 3 vezes: alerta, exit 1 e PRD nao e desfeito" {
  prd_antes_do_registrar
  printf '%s\n' '#!/bin/sh' 'while read -r _o _n ref; do' '  if [ "$ref" = refs/heads/main ]; then echo recusado >&2; exit 1; fi' 'done' > "$ORIGIN/hooks/pre-receive"
  chmod +x "$ORIGIN/hooks/pre-receive"
  est_prd registrar
  assert_failure
  assert_output --partial "publicar.sh: tentativa 3 falhou"
  assert_output --partial "[alerta]"
  [ "$(deploy_ultimo prd)" = "v1.1.0 success" ]
  [ "$(git -C "$ORIGIN" rev-parse refs/heads/main)" != "$(git -C "$ORIGIN" rev-parse 'v1.1.0^{commit}')" ]
  [ -z "$(cd "$WORK" && sh "$KIT_DIR/core/lock.sh" dono ambiente-prd)" ]
}

@test "publicar com a main ja contendo a versao segue e conclui o resto" {
  prd_v110
  git -C "$WORK" push -q origin "v1.1.0^{commit}:refs/heads/main"
  pub v1.1.0
  assert_success
  assert_output --partial "main já contém"
  [ "$(jq -r .state "$FAKE_DIR/pr/1.json")" = closed ]
  [ "$(jq length "$FAKE_DIR/releases.json")" -eq 1 ]
}

@test "publicar com versao fora do padrao estrito recusa" {
  prd_v110
  pub v1.1.0x
  assert_failure
  assert_output --partial "não é uma versão vX.Y.Z"
}

@test "publicar nao fecha o MR se o passo anterior falhou" {
  prd_v110
  mkdir "$FAKE_DIR/branches_apagadas.txt"   # branch_apagar do fake passa a falhar
  pub v1.1.0
  assert_failure
  [ "$(jq -r .state "$FAKE_DIR/pr/1.json")" = opened ]
}
