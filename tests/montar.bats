#!/usr/bin/env bats
load helper

setup() {
  setup_repo
  export GITFLOW_SAIDA="$BATS_TEST_TMPDIR/saida" GITFLOW_RUN_ID=1 GITFLOW_LOCK_INTERVALO=1
  export BUILD_USER_ID=tester
  fake_membro rm1 release-managers
  git -C "$WORK" config rerere.enabled false
}

# entrega IID ID [ARQUIVO CONTEUDO]: branch + PR + tag rc/ID.1 (anotada)
entrega() {
  local iid="$1" id="$2" arq="${3:-$2.txt}" conteudo="${4:-$2}"
  git -C "$WORK" checkout -q -B "feature/$id-x" main
  echo "$conteudo" > "$WORK/$arq"
  git -C "$WORK" add "$arq"
  git -C "$WORK" commit -q -m "feat: $id"
  git -C "$WORK" push -q origin "feature/$id-x"
  fake_pr "$iid" "feature/$id-x" dev
  git -C "$WORK" tag -a "rc/$id.1" -m Entrega
  git -C "$WORK" push -q origin "refs/tags/rc/$id.1"
}
# decidir TAGDEC ID: tag de decisao sobre a entrega
decidir() {
  git -C "$WORK" tag -a "$1/$2.1" -m x "rc/$2.1^{commit}"
  git -C "$WORK" push -q origin "refs/tags/$1/$2.1"
}
tem_tag() { git -C "$ORIGIN" rev-parse -q --verify "refs/tags/$1" > /dev/null; }
msg() { git -C "$ORIGIN" tag -l --format='%(contents)' "$1"; }
saida_tag() { cat "$GITFLOW_SAIDA/montagem.tag"; }
# publicar_build TAG: origin/<amb> aponta para o commit da tag
publicar_build() {
  git -C "$WORK" fetch -q --tags origin
  git -C "$WORK" push -q -f origin "$1^{commit}:refs/heads/${1%%.*}"
}
HOJE() { date +%F; }

@test "P5 main diferente de PRD" {
  echo novo >> "$WORK/README.md"
  git -C "$WORK" commit -q -am novo
  git -C "$WORK" push -q origin main
  rodar montar.sh qa
  assert_failure
  assert_output --partial "a main não é igual a PRD"
}

@test "P6 hom em modo release adia; FORCAR monta" {
  git -C "$WORK" tag -a hom.2026-01-01.1 -m "Release 1.1.0"
  git -C "$WORK" push -q origin hom.2026-01-01.1
  publicar_build hom.2026-01-01.1
  rodar montar.sh hom
  assert_success
  assert_output --partial "montagem adiada"
  [ -z "$(saida_tag)" ]
  FORCAR=true rodar montar.sh hom
  assert_success
  [ "$(saida_tag)" = "hom.$(HOJE).1" ]
  tem_tag "hom.$(HOJE).1"
}

@test "P7 hotfix em teste reserva o QA; hotfix so por release manager" {
  git -C "$WORK" checkout -q -B hotfix/2.5.1 main
  echo h > "$WORK/h.txt"; git -C "$WORK" add h.txt; git -C "$WORK" commit -q -m h
  git -C "$WORK" push -q origin hotfix/2.5.1
  fake_pr 9 hotfix/2.5.1 dev
  git -C "$WORK" tag -a rc/hotfix-2-5-1.1 -m x
  git -C "$WORK" push -q origin refs/tags/rc/hotfix-2-5-1.1
  rodar montar.sh qa
  assert_success
  assert_output --partial "QA reservado"
  [ -z "$(saida_tag)" ]
  HOTFIX=2.5.1 rodar montar.sh hotfix
  assert_failure
  assert_output --partial "é só para release-managers"
  BUILD_USER_ID=rm1 HOTFIX=2.5.1 rodar montar.sh hotfix
  assert_success
  tag=$(saida_tag)
  [ "$tag" = "qa.$(HOJE).1" ]
  msg "$tag" | grep -Fx "Hotfix 2.5.1"
  msg "$tag" | grep -F "rc/hotfix-2-5-1.1 !9 "
  FORCAR=true rodar montar.sh qa
  assert_success
  [ "$(saida_tag)" = "qa.$(HOJE).2" ]
}

@test "P7 reserva do QA vale ate o promover-hotfix: qa-ok sem promocao adia; depois da promocao monta" {
  git -C "$WORK" checkout -q -B hotfix/2.5.1 main
  echo h > "$WORK/h.txt"; git -C "$WORK" add h.txt; git -C "$WORK" commit -q -m h
  git -C "$WORK" push -q origin hotfix/2.5.1
  fake_pr 9 hotfix/2.5.1 dev
  git -C "$WORK" tag -a rc/hotfix-2-5-1.1 -m x
  git -C "$WORK" push -q origin refs/tags/rc/hotfix-2-5-1.1
  BUILD_USER_ID=rm1 HOTFIX=2.5.1 rodar montar.sh hotfix
  assert_success
  tagqa=$(saida_tag)
  publicar_build "$tagqa"
  id=$(deploy_iniciar qa "$tagqa" "$(git -C "$WORK" rev-parse "$tagqa^{commit}")")
  deploy_concluir "$id" success
  # aprovado no QA, ainda sem promocao: a montagem agendada nao pode trocar o QA
  decidir qa-ok hotfix-2-5-1
  BUILD_USER_ID=timer rodar montar.sh qa
  assert_success
  assert_output --partial "hotfix em teste: QA reservado."
  [ "$(git -C "$ORIGIN" rev-parse refs/heads/qa)" = "$(git -C "$WORK" rev-parse "$tagqa^{commit}")" ]
  # promocao: a reserva termina
  BUILD_USER_ID=rm1 rodar promover-hotfix.sh "$tagqa"
  assert_success
  BUILD_USER_ID=timer rodar montar.sh qa
  assert_success
  refute_output --partial "QA reservado"
}

@test "release por nao release manager e recusado; versao invalida" {
  VERSAO=1.1.0 rodar montar.sh release
  assert_failure
  assert_output --partial "é só para release-managers"
  BUILD_USER_ID=rm1 VERSAO=1.1 rodar montar.sh release
  assert_failure
  assert_output --partial "VERSAO inválida"
}

@test "selecao: QA = homologadas+aprovadas+teste; HOM sem teste; release so homologadas" {
  entrega 1 PROJ-1; decidir qa-ok PROJ-1; decidir hom-ok PROJ-1
  entrega 2 PROJ-2; decidir qa-ok PROJ-2
  entrega 3 PROJ-3
  rodar montar.sh qa
  assert_success
  m=$(msg "$(saida_tag)")
  echo "$m" | grep -Fx "Build qa"
  echo "$m" | grep -E '^base main [0-9a-f]+ \(v1\.0\.0\)$'
  echo "$m" | grep -E '^rerere nenhum$'
  echo "$m" | grep -E '^rc/PROJ-1\.1 !1 [0-9a-f]+ homologada$'
  echo "$m" | grep -E '^rc/PROJ-2\.1 !2 [0-9a-f]+ aprovada QA$'
  echo "$m" | grep -E '^rc/PROJ-3\.1 !3 [0-9a-f]+ em teste$'
  [ "$(fake_labels 3)" = "Ambiente::QA" ]
  rodar montar.sh hom
  assert_success
  m=$(msg "$(saida_tag)")
  echo "$m" | grep -F "rc/PROJ-1.1 !1"
  echo "$m" | grep -F "rc/PROJ-2.1 !2"
  ! echo "$m" | grep -F "rc/PROJ-3.1" || false
  BUILD_USER_ID=rm1 VERSAO=1.1.0 rodar montar.sh release
  assert_success
  m=$(msg "$(saida_tag)")
  echo "$m" | grep -Fx "Release 1.1.0"
  echo "$m" | grep -F "rc/PROJ-1.1 !1"
  ! echo "$m" | grep -F "rc/PROJ-2.1" || false
  ! echo "$m" | grep -F "rc/PROJ-3.1" || false
}

@test "fila: limite, lugar mantido, suspeita volta sozinha, rotulos" {
  export LIMITE_QA=1
  entrega 1 PROJ-1; sleep 1
  entrega 2 PROJ-2; sleep 1
  entrega 3 PROJ-3
  rodar montar.sh qa
  assert_success
  tag=$(saida_tag)
  msg "$tag" | grep -F "rc/PROJ-1.1 !1"
  ! msg "$tag" | grep -E "^rc/PROJ-[23]" || false
  msg "$tag" | grep -F "fila: rc/PROJ-2.1 !2 posição 1"
  msg "$tag" | grep -F "fila: rc/PROJ-3.1 !3 posição 2"
  fake_labels 2 | grep -F "Montagem::Fila"
  fake_comentarios 3 | grep -F "⏳ Na fila do QA (posição 2) na montagem $tag."
  # quem ja esta publicado mantem o lugar
  publicar_build "$tag"
  rodar montar.sh qa
  assert_success
  assert_output --partial "nada mudou"
  # suspeita de checagem volta sozinha
  fake_pr 3 feature/PROJ-3-x dev
  pr_rotular 3 "Suspeita de checagem" ""
  LIMITE_QA=3 rodar montar.sh qa
  assert_success
  tag2=$(saida_tag)
  [ "$tag2" = "qa.$(HOJE).2" ]
  msg "$tag2" | grep -F "rc/PROJ-1.1 !1"
  msg "$tag2" | grep -F "rc/PROJ-3.1 !3"
  ! msg "$tag2" | grep -E "^rc/PROJ-2" || false
  msg "$tag2" | grep -F "fila: rc/PROJ-2.1 !2 posição 1"   # havia vaga (limite 3), mas a suspeita volta sozinha
  fake_labels 3 | grep -v "Montagem::Fila" > /dev/null
}

@test "corte de 30 min so na agendada" {
  entrega 1 PROJ-1
  BUILD_USER_ID=timer rodar montar.sh qa
  assert_success
  ! msg "$(saida_tag)" | grep -F "rc/PROJ-1.1" || false
  BUILD_USER_ID=tester rodar montar.sh qa
  assert_success
  msg "$(saida_tag)" | grep -F "rc/PROJ-1.1 !1"
  # entrega antiga entra mesmo na agendada
  git -C "$WORK" checkout -q -B feature/PROJ-2-x main
  echo 2 > "$WORK/2.txt"; git -C "$WORK" add 2.txt; git -C "$WORK" commit -q -m 2
  git -C "$WORK" push -q origin feature/PROJ-2-x
  fake_pr 2 feature/PROJ-2-x dev
  GIT_COMMITTER_DATE="2020-01-01T00:00:00" git -C "$WORK" tag -a rc/PROJ-2.1 -m x
  git -C "$WORK" push -q origin refs/tags/rc/PROJ-2.1
  BUILD_USER_ID= rodar montar.sh qa
  assert_success
  msg "$(saida_tag)" | grep -F "rc/PROJ-2.1 !2"
}

@test "conflito em teste fica fora com label; em aprovada para (P4)" {
  entrega 1 PROJ-1 README.md um
  entrega 2 PROJ-2 README.md dois
  decidir qa-ok PROJ-1
  rodar montar.sh qa
  assert_success
  tag=$(saida_tag)
  msg "$tag" | grep -F "rc/PROJ-1.1 !1"
  msg "$tag" | grep -Fx "fora: rc/PROJ-2.1 !2 conflito"
  ! msg "$tag" | grep -E "^rc/PROJ-2" || false
  fake_labels 2 | grep -F "Montagem::Conflito"
  fake_comentarios 2 | grep -F "⚠️ rc/PROJ-2.1 conflitou na montagem $tag e ficou fora."
  decidir qa-ok PROJ-2
  rodar montar.sh qa
  assert_failure
  assert_output --partial "conflito em entrega aprovada"
}

@test "P3 entrega aprovada com PR fechado para a montagem" {
  entrega 1 PROJ-1; decidir qa-ok PROJ-1
  pr_fechar 1
  rodar montar.sh qa
  assert_failure
  assert_output --partial "entregas aprovadas fora da build sem motivo: rc/PROJ-1.1"
  [ -z "$(saida_tag)" ]
}

@test "nada mudou mesmo quando a entrega publicada passou de em teste para aprovada" {
  entrega 1 PROJ-1
  rodar montar.sh qa
  assert_success
  t1=$(saida_tag)
  publicar_build "$t1"
  decidir qa-ok PROJ-1
  rodar montar.sh qa
  assert_success
  assert_output --partial "nada mudou desde $t1"
  [ -z "$(saida_tag)" ]
}

@test "nada mudou sai sem tag; segunda montagem do dia vira .2" {
  entrega 1 PROJ-1
  rodar montar.sh qa
  assert_success
  t1=$(saida_tag)
  [ "$t1" = "qa.$(HOJE).1" ]
  publicar_build "$t1"
  rodar montar.sh qa
  assert_success
  assert_output --partial "nada mudou desde $t1"
  [ -z "$(saida_tag)" ]
  ! tem_tag "qa.$(HOJE).2" || false
  entrega 2 PROJ-2
  rodar montar.sh qa
  assert_success
  [ "$(saida_tag)" = "qa.$(HOJE).2" ]
  [ "$(git -C "$ORIGIN" cat-file -t "qa.$(HOJE).2")" = tag ]
}

@test "fluxo agendado com montagem-qa ocupado adia sem tag" {
  GITFLOW_RUN_ID=outro sh -c 'cd "$1" && "$2" pegar montagem-qa' _ "$WORK" "$KIT_DIR/core/lock.sh"
  entrega 1 PROJ-1
  BUILD_USER_ID=timer GITFLOW_RUN_ID=2 rodar fluxo-montar.sh qa
  assert_success
  assert_output --partial "adiada: qa aguardando run=outro"
  [ -z "$(saida_tag)" ]
  ! tem_tag "qa.$(HOJE).1" || false
}

@test "fluxo: com tag mantem montagem-qa e solta comandos; sem tag solta tudo" {
  entrega 1 PROJ-1
  rodar fluxo-montar.sh qa
  assert_success
  tag=$(saida_tag)
  [ "$tag" = "qa.$(HOJE).1" ]
  [ "$(cat "$GITFLOW_SAIDA/lock-montagem")" = montagem-qa ]
  git -C "$ORIGIN" rev-parse -q --verify refs/gitflow/lock/montagem-qa
  ! git -C "$ORIGIN" rev-parse -q --verify refs/gitflow/lock/comandos || false
  GITFLOW_RUN_ID=1 sh -c 'cd "$1" && "$2" soltar montagem-qa' _ "$WORK" "$KIT_DIR/core/lock.sh"
  publicar_build "$tag"
  rodar fluxo-montar.sh qa
  assert_success
  assert_output --partial "nada mudou"
  [ -z "$(saida_tag)" ]
  ! git -C "$ORIGIN" rev-parse -q --verify refs/gitflow/lock/montagem-qa || false
  ! git -C "$ORIGIN" rev-parse -q --verify refs/gitflow/lock/comandos || false
}

@test "rerere: resolucao publicada em meta/rerere faz a entrega em teste entrar" {
  entrega 1 PROJ-1 README.md um; sleep 1
  entrega 2 PROJ-2 README.md dois
  rodar montar.sh qa
  assert_success
  msg "$(saida_tag)" | grep -Fx "fora: rc/PROJ-2.1 !2 conflito"
  # reproduz localmente, resolve e publica
  rodar resolver-conflito.sh qa
  assert_success
  assert_output --partial "Conflito ao mesclar rc/PROJ-2.1"
  echo resolvido > "$WORK/README.md"
  git -C "$WORK" add README.md
  git -C "$WORK" -c user.name=t -c user.email=t@e commit -q --no-edit
  rodar resolver-conflito.sh --publicar
  assert_success
  git -C "$ORIGIN" rev-parse -q --verify refs/heads/meta/rerere
  rm -rf "$WORK/.git/rr-cache"
  rodar montar.sh qa
  assert_success
  tag=$(saida_tag)
  msg "$tag" | grep -E '^rc/PROJ-2\.1 !2 [0-9a-f]+ em teste$'
  msg "$tag" | grep -Fx "rerere: rc/PROJ-2.1"
  msg "$tag" | grep -E '^rerere [0-9a-f]+$'
  [ "$(git -C "$ORIGIN" tag -l | grep -c '^qa\.')" -eq 2 ]
}

@test "manifesto: reteste expresso e substituida por" {
  entrega 1 PROJ-1
  rodar montar.sh qa
  assert_success
  t1=$(saida_tag)
  publicar_build "$t1"
  decidir qa-nok PROJ-1
  git -C "$WORK" checkout -q feature/PROJ-1-x
  echo mais >> "$WORK/PROJ-1.txt"
  git -C "$WORK" commit -q -am mais
  git -C "$WORK" push -q origin feature/PROJ-1-x
  git -C "$WORK" tag -a rc/PROJ-1.2 -m x
  git -C "$WORK" push -q origin refs/tags/rc/PROJ-1.2
  rodar montar.sh qa
  assert_success
  m=$(msg "$(saida_tag)")
  echo "$m" | grep -E '^rc/PROJ-1\.2 !1 [0-9a-f]+ em teste \(reteste expresso\)$'
  echo "$m" | grep -Fx "saiu: rc/PROJ-1.1 substituída por rc/PROJ-1.2"
}

@test "falha do provider apos a tag nao derruba a montagem" {
  entrega 1 PROJ-1
  K="$BATS_TEST_TMPDIR/kit"
  mkdir -p "$K"
  cp -r "$KIT_DIR/core" "$KIT_DIR/adapters" "$K/"
  echo 'pr_rotular() { return 1; }' >> "$K/adapters/provider/fake.sh"
  KIT_DIR="$K" rodar montar.sh qa
  assert_success
  [ "$(saida_tag)" = "qa.$(HOJE).1" ]
  tem_tag "qa.$(HOJE).1"
  assert_output --partial "AVISO"
}

@test "rerere: publicar nao descarta resolucoes ja publicadas" {
  entrega 1 PROJ-1 README.md um; sleep 1
  entrega 2 PROJ-2 README.md dois
  rodar resolver-conflito.sh qa
  assert_success
  echo resolvido > "$WORK/README.md"
  git -C "$WORK" add README.md
  git -C "$WORK" -c user.name=t -c user.email=t@e commit -q --no-edit
  rodar resolver-conflito.sh --publicar
  assert_success
  A=$(ls "$WORK/.git/rr-cache" | head -1)
  [ -n "$A" ]
  # clone sem A: so a resolucao B local
  rm -rf "$WORK/.git/rr-cache"
  mkdir -p "$WORK/.git/rr-cache/bbbb0000"
  echo pre > "$WORK/.git/rr-cache/bbbb0000/preimage"
  echo pos > "$WORK/.git/rr-cache/bbbb0000/postimage"
  rodar resolver-conflito.sh --publicar
  assert_success
  git -C "$ORIGIN" ls-tree --name-only refs/heads/meta/rerere | grep -Fx "$A"
  git -C "$ORIGIN" ls-tree --name-only refs/heads/meta/rerere | grep -Fx bbbb0000
}
