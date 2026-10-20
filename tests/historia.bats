#!/usr/bin/env bats
# A historia BRANCH 01/02/03 (doc 01 secao 3.3), dia a dia, com os scripts reais e o provider fake.
# Decisao: UM @test longo com checkpoints por dia (a historia e uma cadeia; refazer os dias anteriores
# em 4 testes custaria 4x no Windows). Cada checkpoint falha dizendo o dia.
# PRD atual = v1.0.0 (o setup_repo) no lugar de v2.4.0; a release da historia sai como v1.1.0.
# Todos os dias usam a data real: as asserções olham o CONTEUDO (manifesto/arvore) das builds
# publicadas em qa/hom/main, nunca as datas das tags. Montagens manuais (BUILD_USER_ID=qa1) ignoram o corte de 30 min.
load helper
load e2e

setup() { e2e_setup; }

R1="rc/PROJ-101.1"
R2="rc/PROJ-102.1"
R3="rc/PROJ-103.1"

dia1() {
  tarefa PROJ-101 11
  tarefa PROJ-102 12
  entregar 11
  entregar 12
  montar_publicar qa                      # 10h
  igual "$(manifesto_amb qa)" "$R1 $R2" "dia 1: QA 01+02"
  dec qa1 11 "/aprovar"                   # o QA aprova a 01; a 02 segue em teste
  montar_publicar hom                     # 17h: preview so com a 01
  igual "$(manifesto_amb hom)" "$R1" "dia 1: HOM 01"
  igual "$(prd_atual)" v1.0.0 "dia 1: PRD"
  arvore_tem hom PROJ-101.txt
  ! arvore_tem hom PROJ-102.txt || falha "dia 1: a 02 nao podia estar na HOM"
}

dia2() {
  local qa hom
  qa=$(git -C "$ORIGIN" rev-parse refs/heads/qa)
  hom=$(git -C "$ORIGIN" rev-parse refs/heads/hom)
  montar qa
  igual "$MTAG" "" "dia 2: QA nada republicado"
  assert_output --partial "nada mudou"
  montar hom
  igual "$MTAG" "" "dia 2: HOM nada republicado"
  assert_output --partial "nada mudou"
  igual "$(git -C "$ORIGIN" rev-parse refs/heads/qa)" "$qa" "dia 2: branch qa"
  igual "$(git -C "$ORIGIN" rev-parse refs/heads/hom)" "$hom" "dia 2: branch hom"
  igual "$(manifesto_amb qa)" "$R1 $R2" "dia 2: QA 01+02"
  igual "$(manifesto_amb hom)" "$R1" "dia 2: HOM 01"
  lock_livre montagem-qa
  lock_livre montagem-hom
}

dia3() {
  tarefa PROJ-103 13
  entregar 13
  montar_publicar qa                      # 10h: 01 + 02 + 03
  igual "$(manifesto_amb qa)" "$R1 $R2 $R3" "dia 3 (10h): QA 01+02+03"
  dec qa1 13 "/reprovar erro no banco de horas"
  dec qa1 12 "/aprovar"
  dec neg1 11 "/homologar"
  montar_publicar qa                      # 15h: a 03 sai
  igual "$(manifesto_amb qa)" "$R1 $R2" "dia 3 (15h): QA 01+02 (03 fora)"
  ! arvore_tem qa PROJ-103.txt || falha "dia 3: o codigo da 03 ficou no QA"
  arvore_tem qa PROJ-101.txt
  arvore_tem qa PROJ-102.txt
  montar_publicar hom                     # 17h
  igual "$(manifesto_amb hom)" "$R1 $R2" "dia 3: HOM 01+02"
  igual "$(prd_atual)" v1.0.0 "dia 3: PRD"
  fake_labels 13 | grep -F "Ambiente::QA reprovado"
}

dia4() {
  release_ate_tag 1.1.0 5
  igual "$(manifesto_amb hom)" "$R1" "dia 4: preview da release so com a 01"
  ! arvore_tem hom PROJ-102.txt || falha "dia 4: a 02 entrou na release"
  esteira prd v1.1.0
  igual "$(prd_atual)" v1.1.0 "dia 4: PRD v1.1.0"
  igual "$(git -C "$ORIGIN" rev-parse refs/heads/main)" "$(git -C "$ORIGIN" rev-parse 'v1.1.0^{commit}')" "dia 4: main = v1.1.0"
  igual "$(jq -r .state "$FAKE_DIR/pr/11.json")" closed "dia 4: MR da 01 encerrado"
  igual "$(jq -r .state "$FAKE_DIR/pr/12.json")" opened "dia 4: MR da 02 aberto"
  # a 03 corrigida volta ao QA (rebase na nova main); QA e HOM saem do modo release (FORCAR)
  tarefa PROJ-103 13 2
  entregar 13
  FORCAR=true montar_publicar qa
  igual "$(manifesto_amb qa)" "$R2 rc/PROJ-103.2" "dia 4: QA 02+03 corrigida"
  FORCAR=true montar_publicar hom
  igual "$(manifesto_amb hom)" "$R2" "dia 4: HOM 02"
  arvore_tem hom PROJ-102.txt
  lock_livre ambiente-qa
  lock_livre ambiente-hom
  lock_livre montagem-qa
  lock_livre montagem-hom
}

@test "historia BRANCH 01 02 03 dias 1 a 4" {
  dia1
  dia2
  dia3
  dia4
}
