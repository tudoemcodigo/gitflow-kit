#!/usr/bin/env bats
# As 10 provocacoes da Fase 1 (doc 09 secao 2): cada linha da tabela e um @test, com a reacao esperada.
# Tudo pelos scripts reais; montagens manuais (BUILD_USER_ID=qa1) salvo onde a agendada e o ponto.
load helper
load e2e

setup() { e2e_setup; }

@test "P2 /aprovar depois de uma nova entrega e recusado" {
  tarefa PROJ-101 11
  entregar 11
  montar_publicar qa
  igual "$(manifesto_amb qa)" "rc/PROJ-101.1" "build do QA"
  tarefa PROJ-101 11 2 # o dev empurra um commit novo e entrega de novo
  entregar 11
  AUTOR=qa1 MR_IID=11 NOTA="/aprovar" rodar decidir.sh
  assert_failure
  assert_output --partial "decida depois da próxima montagem"
  fake_comentarios 11 | grep -F "⛔ /aprovar recusado: "
  ! tem_tag qa-ok/PROJ-101.2 || false
  ! tem_tag qa-ok/PROJ-101.1 || false
}

@test "P1 label mexido a mao nao muda nada e e reescrito" {
  tarefa PROJ-101 11
  tarefa PROJ-102 12
  entregar 11
  entregar 12
  montar_publicar qa
  dec qa1 11 "/aprovar"
  # alguem mexe nos labels: a 02 (em teste) "vira" homologada e a 01 (aprovada no QA) "volta" para o QA
  pr_rotular 12 "Ambiente::Homologado" "Ambiente::QA"
  pr_rotular 11 "Ambiente::QA" "Ambiente::HOM"
  # o estado vem das tags: a 02 nao tem hom-ok
  ! tem_tag hom-ok/PROJ-102.1 || false
  tarefa PROJ-103 13
  entregar 13
  montar_publicar qa # nova build: a montagem espelha os labels de volta
  igual "$(fake_labels 12)" "Ambiente::QA" "label da 02 reescrito"
  igual "$(fake_labels 11)" "Ambiente::HOM" "label da 01 reescrito"
  igual "$(n_tags 'hom-ok/*')" 0 "nenhuma homologacao criada"
}

@test "P3 fechar o MR de uma branch aprovada para a montagem e avisa" {
  tarefa PROJ-101 11
  entregar 11
  montar_publicar qa
  dec qa1 11 "/aprovar"
  pr_fechar 11
  BUILD_USER_ID=qa1 rodar fluxo-montar.sh qa
  assert_failure
  assert_output --partial "entregas aprovadas fora da build sem motivo: rc/PROJ-101.1"
  assert_output --partial "[alerta]"
  igual "$(n_tags 'qa.*')" 1 "nenhuma build nova"
  lock_livre montagem-qa
  lock_livre comandos
}

# Substituicao aceita: duas branches aprovadas nunca conflitam pelo fluxo normal (a segunda sempre cai "fora" como
# entrega em teste), entao o conflito vem da main que anda (hotfix em PRD). O que se afirma e a reacao da linha
# do doc 09: a montagem para e avisa.
@test "P4 conflito entre branch aprovada e a main para a montagem e avisa" {
  # a 02 (aprovada no QA) e um hotfix mexem na mesma linha; o hotfix chega a PRD e a main anda
  ramo feature/PROJ-102-tarefa 12 README.md "linha da 102"
  entregar 12
  montar_publicar qa
  dec qa1 12 "/aprovar"
  hotfix_ate_prd 1.0.1 21 README.md "linha do hotfix"
  igual "$(prd_atual)" v1.0.1 "hotfix em PRD"
  BUILD_USER_ID=qa1 rodar fluxo-montar.sh qa
  assert_failure
  assert_output --partial "conflito em entrega aprovada: rc/PROJ-102.1"
  assert_output --partial "[alerta]"
  lock_livre montagem-qa
}

@test "P8 checagem com Abort devolve o ambiente a build anterior dentro do travamento" {
  tarefa PROJ-101 11
  tarefa PROJ-102 12
  entregar 11
  montar_publicar qa
  B1="$MTAG"
  SHA1=$(git -C "$ORIGIN" rev-parse refs/heads/qa)
  entregar 12
  montar qa
  B2="$MTAG"
  esteira qa "$B2" preparar construir testar publicar-pacote gates implantar verificar-auto # checagem manual pendente
  [ "$(git -C "$ORIGIN" rev-parse refs/heads/qa)" != "$SHA1" ]
  [ -n "$(lock_dono ambiente-qa)" ] # dentro do travamento
  TAG="$B2" AMBIENTE=qa rodar esteira.sh falhou # o QA clica Abort
  assert_success
  igual "$(git -C "$ORIGIN" rev-parse refs/heads/qa)" "$SHA1" "qa voltou"
  igual "$(manifesto_amb qa)" "rc/PROJ-101.1" "manifesto de volta"
  igual "$(cd "$WORK" && deploy_ultimo qa)" "$B1 success" "deployment"
  igual "$(jq -r --arg t "$B2" '[.[] | select(.ref == $t)] | last | .status' "$FAKE_DIR/deployments.json")" failed "a build abortada"
  lock_livre ambiente-qa
  lock_livre montagem-qa
}

@test "P11 montagem das 15h com a checagem das 10h pendente espera" {
  tarefa PROJ-101 11
  tarefa PROJ-102 12
  entregar 11
  montar qa # 10h
  B1="$MTAG"
  esteira qa "$B1" preparar construir testar publicar-pacote gates implantar verificar-auto # sem registrar: pendente
  entregar 12
  # 15h agendada: outra execucao do CI, com a sua propria pasta de saida
  BUILD_USER_ID=timer GITFLOW_RUN_ID=run-15h GITFLOW_SAIDA="$BATS_TEST_TMPDIR/saida-15h" rodar fluxo-montar.sh qa
  assert_success
  assert_output --partial "adiada: qa aguardando run=run-1"
  igual "$(cat "$BATS_TEST_TMPDIR/saida-15h/montagem.tag")" "" "sem tag"
  igual "$(n_tags 'qa.*')" 1 "nenhuma build nova"
  TAG="$B1" AMBIENTE=qa rodar esteira.sh registrar # a checagem das 10h termina
  assert_success
  lock_livre montagem-qa
  montar_publicar qa # a proxima montagem encontra tudo livre
  igual "$(manifesto_amb qa)" "rc/PROJ-101.1 rc/PROJ-102.1" "a 02 entrou depois"
}

@test "P12 republicar a esteira de uma build com teste falhando roda os testes de novo" {
  tarefa PROJ-101 11
  entregar 11
  printf '%s\n' '#!/bin/sh' 'echo rodou >> "$GITFLOW_SAIDA/testes.log"' 'exit 1' > "$WORK/scripts/test.sh"
  git -C "$WORK" add scripts
  git -C "$WORK" commit -q -m "chore: teste falhando"
  git -C "$WORK" push -q origin HEAD:main
  fixture_retag_prd
  montar qa
  B1="$MTAG"
  SHA=$(git -C "$ORIGIN" rev-parse "$B1^{commit}")
  TAG="$B1" AMBIENTE=qa rodar esteira.sh preparar
  assert_success
  TAG="$B1" AMBIENTE=qa rodar esteira.sh construir
  assert_success
  TAG="$B1" AMBIENTE=qa rodar esteira.sh testar
  assert_failure
  TAG="$B1" AMBIENTE=qa rodar esteira.sh publicar-pacote
  assert_failure
  assert_output --partial "P12"
  [ ! -e "$ARTEFATOS_DIR/app-$SHA.zip" ]
  # republicar: o pacote nao foi publicado, entao os testes rodam de novo (e continuam barrando)
  TAG="$B1" AMBIENTE=qa rodar esteira.sh preparar
  assert_success
  grep -q '^CONSTRUIR=sim$' "$GITFLOW_SAIDA/esteira.env"
  TAG="$B1" AMBIENTE=qa rodar esteira.sh construir
  assert_success
  TAG="$B1" AMBIENTE=qa rodar esteira.sh testar
  assert_failure
  igual "$(wc -l < "$GITFLOW_SAIDA/testes.log" | tr -d ' ')" 2 "testes rodaram duas vezes"
  ! git -C "$ORIGIN" rev-parse -q --verify refs/heads/qa || false
}

@test "P13 entrega a partir da branch de outra tarefa e recusada" {
  tarefa PROJ-101 11
  entregar 11
  tarefa PROJ-102 12 1 origin/feature/PROJ-101-tarefa # a 02 nasce em cima da 01 (que ainda nao esta em PRD)
  AUTOR=dev MR_IID=12 NOTA="" rodar criar-rc.sh
  assert_failure
  fake_comentarios 12 | grep -F "⛔ Entrega recusada: a branch contém a entrega rc/PROJ-101.1, de outro MR"
  ! tem_tag rc/PROJ-102.1 || false
}

@test "P9 hotfix publicado enquanto a release espera aprovacao recusa a release" {
  aprovar_ate_hom PROJ-101 11
  release_ate_tag 1.1.0 5 # v1.1.0 criada, esperando a aprovacao de PRD
  hotfix_ate_prd 1.0.1 21 hotfix.txt "correcao"
  igual "$(prd_atual)" v1.0.1 "hotfix em PRD"
  TAG=v1.1.0 AMBIENTE=prd rodar esteira.sh preparar
  assert_failure
  assert_output --partial "P9"
  igual "$(prd_atual)" v1.0.1 "PRD segue no hotfix"
}

@test "P5 publicar.sh falhando bloqueia as montagens ate concluir" {
  aprovar_ate_hom PROJ-101 11
  release_ate_tag 1.1.0 5
  hook_recusa_ref 'refs/heads/main'
  esteira prd v1.1.0 preparar construir testar publicar-pacote gates implantar verificar-auto
  TAG=v1.1.0 AMBIENTE=prd rodar esteira.sh registrar
  assert_failure
  assert_output --partial "publicar.sh falhou"
  igual "$(prd_atual)" v1.1.0 "PRD publicado"
  BUILD_USER_ID=qa1 rodar fluxo-montar.sh qa
  assert_failure
  assert_output --partial "a main não é igual a PRD (v1.1.0). Conclua o publicar.sh antes de montar."
  BUILD_USER_ID=qa1 rodar fluxo-montar.sh hom
  assert_failure
  assert_output --partial "a main não é igual a PRD"
  rm -f "$ORIGIN/hooks/pre-receive"
  rodar publicar.sh v1.1.0 # conclui o publicar.sh
  assert_success
  igual "$(git -C "$ORIGIN" rev-parse refs/heads/main)" "$(git -C "$ORIGIN" rev-parse 'v1.1.0^{commit}')" "main = v1.1.0"
  FORCAR=true montar qa # as montagens voltam
}

@test "helpers: etapa da esteira que falha faz montar_publicar retornar nao zero mesmo sob ||" {
  tarefa PROJ-101 11
  entregar 11
  printf '%s
' '#!/bin/sh' 'exit 1' > "$WORK/scripts/test.sh"
  git -C "$WORK" add scripts
  git -C "$WORK" commit -q -m "chore: teste falhando"
  git -C "$WORK" push -q origin HEAD:main
  fixture_retag_prd
  r=0
  montar_publicar qa 2> /dev/null || r=$?
  [ "$r" -ne 0 ]
  r=0
  esteira qa "$(git -C "$ORIGIN" tag -l 'qa.*' | head -1)" preparar construir testar publicar-pacote 2> /dev/null || r=$?
  [ "$r" -ne 0 ]
  ! git -C "$ORIGIN" rev-parse -q --verify refs/heads/qa || false
}
