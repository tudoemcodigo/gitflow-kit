#!/usr/bin/env bats
load helper

setup() {
  setup_repo
  export MR_IID=1 AUTOR=qa1 NOTA=""
  fake_membro qa1 qa
  fake_membro neg1 negocio
  fake_membro tl1 tech-leads
  nova_branch feature/PROJ-101-x a.txt
  fake_pr 1 feature/PROJ-101-x dev
  git -C "$WORK" tag -a rc/PROJ-101.1 -m "Entrega" "origin/feature/PROJ-101-x"
  git -C "$WORK" push -q origin refs/tags/rc/PROJ-101.1
}

# montar AMB NOME RC...: build anotada (manifesto no corpo) no commit do primeiro RC; origin/AMB aponta para ela
montar() {
  local amb="$1" nome="$2" sha r
  shift 2
  sha=$(git -C "$WORK" rev-parse "$1^{commit}")
  {
    printf 'Build %s\n\n' "$nome"
    for r in "$@"; do printf '%s !1 %s feature\n' "$r" "$sha"; done
  } > "$BATS_TEST_TMPDIR/m.txt"
  git -C "$WORK" tag -a "$nome" -F "$BATS_TEST_TMPDIR/m.txt" "$sha"
  git -C "$WORK" push -q origin "refs/tags/$nome"
  git -C "$WORK" push -q -f origin "$sha:refs/heads/$amb"
}
# deploy AMB REF STATUS
deploy() {
  local id
  id=$(deploy_iniciar "$1" "$2" "$(git -C "$WORK" rev-parse "$2^{commit}")")
  deploy_concluir "$id" "$3"
}
publicar() { montar "$1" "$2" "${3:-rc/PROJ-101.1}"; deploy "$1" "$2" success; }
refuso() { fake_comentarios 1 | grep -F "⛔ $1 recusado: " | grep -F "$2" || { fake_comentarios 1 >&2; return 1; }; }
tem_tag() { git -C "$ORIGIN" rev-parse -q --verify "refs/tags/$1" > /dev/null; }
# decisao_previa TAG: cria e publica uma tag de decisao sobre rc/PROJ-101.1
decisao_previa() {
  git -C "$WORK" tag -a "$1/PROJ-101.1" -m x rc/PROJ-101.1
  git -C "$WORK" push -q origin "refs/tags/$1/PROJ-101.1"
}
# outra_entrega: rc/PROJ-102.1 em outro commit
outra_entrega() {
  git -C "$WORK" checkout -q -B feature/PROJ-102-y main
  echo b > "$WORK/b.txt"
  git -C "$WORK" add b.txt
  git -C "$WORK" commit -q -m b
  git -C "$WORK" tag -a rc/PROJ-102.1 -m x
  git -C "$WORK" push -q origin refs/tags/rc/PROJ-102.1
}

@test "grupo errado" {
  publicar qa qa.1
  AUTOR=neg1 NOTA="/aprovar" rodar decidir.sh
  assert_failure
  refuso /aprovar "@neg1 não pertence a"
  ! tem_tag qa-ok/PROJ-101.1
}

@test "reprovar sem motivo" {
  publicar qa qa.1
  NOTA="/reprovar" rodar decidir.sh
  assert_failure
  refuso /reprovar "informe o motivo"
}

@test "comando desconhecido e ignorado" {
  NOTA="oi gente" rodar decidir.sh
  assert_success
}

@test "aprovar sucesso: tag anotada, mensagem, label e comentario" {
  publicar qa qa.1
  NOTA="/aprovar" rodar decidir.sh
  assert_success
  tem_tag qa-ok/PROJ-101.1
  [ "$(git -C "$WORK" rev-parse 'qa-ok/PROJ-101.1^{commit}')" = "$(git -C "$WORK" rev-parse 'rc/PROJ-101.1^{commit}')" ]
  [ "$(git -C "$WORK" cat-file -t qa-ok/PROJ-101.1)" = tag ]
  git -C "$WORK" tag -l --format='%(contents:subject)' qa-ok/PROJ-101.1 | grep -Fx "/aprovar por @qa1 na build qa.1"
  [ "$(fake_labels 1)" = "Ambiente::HOM" ]
  fake_comentarios 1 | grep -F "✅ **/aprovar** registrado para **rc/PROJ-101.1**"
}

@test "P2 entrega fora da build publicada recusa aprovar" {
  outra_entrega
  publicar qa qa.1 rc/PROJ-102.1
  NOTA="/aprovar" rodar decidir.sh
  assert_failure
  refuso /aprovar "a entrega rc/PROJ-101.1 não está na build publicada e verificada em qa"
  ! tem_tag qa-ok/PROJ-101.1
}

@test "P2 deployment running (nao verificado) recusa aprovar" {
  montar qa qa.1 rc/PROJ-101.1
  deploy qa qa.1 running
  NOTA="/aprovar" rodar decidir.sh
  assert_failure
  refuso /aprovar "não está na build publicada e verificada"
}

@test "P2 deployment failed recusa aprovar" {
  montar qa qa.1 rc/PROJ-101.1
  deploy qa qa.1 failed
  NOTA="/aprovar" rodar decidir.sh
  assert_failure
  refuso /aprovar "não está na build publicada e verificada"
  ! tem_tag qa-ok/PROJ-101.1
}

@test "P2 deployment de outra build recusa aprovar" {
  montar qa qa.1 rc/PROJ-101.1
  deploy qa qa.0 success
  NOTA="/aprovar" rodar decidir.sh
  assert_failure
  refuso /aprovar "não está na build publicada e verificada"
}

@test "reprovar vale para a ultima build montada mesmo sem deploy" {
  montar qa qa.1 rc/PROJ-101.1
  NOTA="/reprovar falhou nos gates" rodar decidir.sh
  assert_success
  tem_tag qa-nok/PROJ-101.1
  git -C "$WORK" tag -l --format='%(contents:body)' qa-nok/PROJ-101.1 | grep -F "falhou nos gates"
}

@test "reprovar recusa se a entrega nao esta em nenhuma build" {
  montar qa qa.1 rc/PROJ-101.1
  outra_entrega
  montar qa qa.2 rc/PROJ-102.1
  NOTA="/reprovar motivo" rodar decidir.sh
  assert_failure
  refuso /reprovar "não está na build publicada nem na última montada de qa"
}

@test "aprovar apos nova entrega nao publicada e recusado" {
  publicar qa qa.1
  git -C "$WORK" checkout -q feature/PROJ-101-x
  echo mais >> "$WORK/a.txt"
  git -C "$WORK" commit -q -am mais
  git -C "$WORK" push -q origin feature/PROJ-101-x
  git -C "$WORK" tag -a rc/PROJ-101.2 -m x
  git -C "$WORK" push -q origin refs/tags/rc/PROJ-101.2
  NOTA="/aprovar" rodar decidir.sh
  assert_failure
  refuso /aprovar "a entrega rc/PROJ-101.2 não está na build publicada e verificada em qa"
  ! tem_tag qa-ok/PROJ-101.2
}

@test "transicao: qa-nok sobre qa-ok permitido" {
  publicar qa qa.1
  NOTA="/aprovar" rodar decidir.sh
  assert_success
  NOTA="/reprovar errei" rodar decidir.sh
  assert_success
  tem_tag qa-nok/PROJ-101.1
}

@test "transicao: qa-ok sobre qa-nok recusado" {
  publicar qa qa.1
  NOTA="/reprovar ruim" rodar decidir.sh
  assert_success
  NOTA="/aprovar" rodar decidir.sh
  assert_failure
  refuso /aprovar "a entrega rc/PROJ-101.1 está em 'qa-nok'; /aprovar não se aplica"
  ! tem_tag qa-ok/PROJ-101.1
}

@test "transicao: hom-ok sobre teste recusado" {
  publicar hom hom.1
  AUTOR=neg1 NOTA="/homologar" rodar decidir.sh
  assert_failure
  refuso /homologar "está em 'teste'"
}

@test "homologar apos qa-ok" {
  decisao_previa qa-ok
  publicar hom hom.1
  AUTOR=neg1 NOTA="/homologar" rodar decidir.sh
  assert_success
  tem_tag hom-ok/PROJ-101.1
  [ "$(fake_labels 1)" = "Ambiente::Homologado" ]
}

@test "alteracao exige motivo e registra hom-ok" {
  decisao_previa qa-ok
  publicar hom hom.1
  AUTOR=neg1 NOTA="/alteracao" rodar decidir.sh
  assert_failure
  fake_comentarios 1 | grep -F "informe o motivo (no /alteracao, a tarefa nova)"
  AUTOR=neg1 NOTA="/alteracao trocar o texto" rodar decidir.sh
  assert_success
  tem_tag hom-ok/PROJ-101.1
}

@test "ajuste por QA apos qa-ok" {
  decisao_previa qa-ok
  publicar hom hom.1
  NOTA="/ajuste cor do botao" rodar decidir.sh
  assert_success
  tem_tag hom-ajuste/PROJ-101.1
}

@test "repetido: ja foi registrado" {
  decisao_previa qa-ok
  publicar hom hom.1
  NOTA="/ajuste a" rodar decidir.sh
  assert_success
  NOTA="/ajuste b" rodar decidir.sh
  assert_failure
  refuso /ajuste "/ajuste já foi registrado para rc/PROJ-101.1"
}

@test "reprovar repetido tambem diz ja foi registrado" {
  publicar qa qa.1
  NOTA="/reprovar a" rodar decidir.sh
  assert_success
  NOTA="/reprovar b" rodar decidir.sh
  assert_failure
  refuso /reprovar "já foi registrado"
}

@test "motivo hostil vira texto literal na tag e no comentario" {
  publicar qa qa.1
  local marca="$BATS_TEST_TMPDIR/pwn" nota corpo
  nota=$(printf '/reprovar "x" $(touch %s) `touch %s`\nlinha2 🚀' "$marca" "$marca")
  NOTA="$nota" rodar decidir.sh
  assert_success
  [ ! -e "$marca" ]
  corpo=$(git -C "$WORK" tag -l --format='%(contents:body)' qa-nok/PROJ-101.1)
  case "$corpo" in *'"x" $(touch '*'`touch '*) ;; *) false ;; esac
  printf '%s' "$corpo" | grep -F 'linha2 🚀'
  fake_comentarios 1 | grep -F '"x" $(touch '
  fake_comentarios 1 | grep -F 'linha2 🚀'
}

@test "retirar por negocio em entrega qa-ok" {
  decisao_previa qa-ok
  AUTOR=neg1 NOTA="/retirar nao vai mais" rodar decidir.sh
  assert_success
  tem_tag retirada/PROJ-101.1
  [ "$(fake_labels 1)" = "Ambiente::Retirada" ]
  git -C "$WORK" tag -l --format='%(contents:subject)' retirada/PROJ-101.1 | grep -F "/retirar por @neg1 na build -"
}

@test "retirar sem entrega" {
  fake_pr 5 feature/PROJ-999-nada dev
  MR_IID=5 AUTOR=tl1 NOTA="/retirar x" rodar decidir.sh
  assert_failure
  fake_comentarios 5 | grep -F "o MR não tem entrega"
}

@test "motivo com linha iniciada por # e espacos fica literal" {
  publicar qa qa.1
  NOTA=$(printf '/reprovar #42 quebrou\n# segunda\n  indentada  ') rodar decidir.sh
  assert_success
  local corpo
  corpo=$(git -C "$WORK" tag -l --format='%(contents:body)' qa-nok/PROJ-101.1)
  printf '%s\n' "$corpo" | grep -Fx '#42 quebrou'
  printf '%s\n' "$corpo" | grep -Fx '# segunda'
  printf '%s\n' "$corpo" | grep -Fx '  indentada  '
}

@test "reprovar-hom registra hom-nok" {
  decisao_previa qa-ok
  publicar hom hom.1
  AUTOR=neg1 NOTA="/reprovar-hom nao atende" rodar decidir.sh
  assert_success
  tem_tag hom-nok/PROJ-101.1
  [ "$(fake_labels 1)" = "Ambiente::HOM reprovado" ]
}
