#!/usr/bin/env bats
load helper

DESC_OK='## Critério de aceite
Ponto registrado

## Como testar
Abrir a tela e registrar

## Autoteste
- [x] rodei local'

# preparar IID BRANCH: PR valido (autor dev), pipeline verde, review de outra pessoa, descricao ok
preparar() {
  fake_pr "$1" "$2" dev
  local sha
  sha=$(git -C "$WORK" rev-parse "origin/$2")
  fake_pipeline "$1" "$sha" success
  fake_review "$1" rev "$sha"
  fake_descricao "$1" "$DESC_OK"
}

setup() {
  setup_repo
  export NOTA="" AUTOR=dev MR_IID=1
  nova_branch feature/PROJ-101-x a.txt
  preparar 1 feature/PROJ-101-x
}

sha_de() { git -C "$WORK" rev-parse "origin/$1"; }
refuso() { fake_comentarios "${1:-1}" | grep -F "⛔ Entrega recusada: "; }
pr_editar() { jq "$2" "$FAKE_DIR/pr/$1.json" > "$FAKE_DIR/t" && mv "$FAKE_DIR/t" "$FAKE_DIR/pr/$1.json"; }

@test "sucesso: tag anotada no sha do PR, label e comentario" {
  rodar criar-rc.sh
  assert_success
  [ "$(git -C "$WORK" rev-parse 'rc/PROJ-101.1^{commit}')" = "$(sha_de feature/PROJ-101-x)" ]
  [ "$(git -C "$WORK" cat-file -t rc/PROJ-101.1)" = tag ]
  git -C "$ORIGIN" rev-parse -q --verify refs/tags/rc/PROJ-101.1
  [ "$(fake_labels 1)" = "Ambiente::QA" ]
  fake_comentarios 1 | grep -F "📦 Entrega **rc/PROJ-101.1** criada ($(sha_de feature/PROJ-101-x | cut -c1-8)). Entra na próxima montagem do QA."
}

@test "branch fora do padrao" {
  nova_branch feature/proj-1-x b.txt
  preparar 2 feature/proj-1-x
  MR_IID=2 rodar criar-rc.sh
  assert_failure
  fake_comentarios 2 | grep -F "nome de branch fora do padrão"
}

@test "hotfix sem X.Y.Z ou vazio e recusado" {
  nova_branch hotfix/2.5 b.txt
  preparar 2 hotfix/2.5
  MR_IID=2 rodar criar-rc.sh
  assert_failure
  fake_comentarios 2 | grep -F "use hotfix/X.Y.Z"
  fake_pr 3 hotfix/ dev
  MR_IID=3 rodar criar-rc.sh
  assert_failure
  fake_comentarios 3 | grep -F "use hotfix/X.Y.Z"
}

@test "hotfix valido cria rc/hotfix-2-5-1.1" {
  nova_branch hotfix/2.5.1 b.txt
  preparar 2 hotfix/2.5.1
  MR_IID=2 rodar criar-rc.sh
  assert_success
  git -C "$WORK" rev-parse -q --verify refs/tags/rc/hotfix-2-5-1.1
  [ "$(fake_labels 2)" = "Ambiente::Hotfix" ]
}

@test "target diferente de main" {
  pr_editar 1 '.target_branch="epic/x"'
  rodar criar-rc.sh
  assert_failure
  refuso | grep -F "precisa apontar para a main"
}

@test "draft" {
  pr_editar 1 '.draft=true'
  rodar criar-rc.sh
  assert_failure
  refuso | grep -F "rascunho"
}

@test "autor diferente do dono e nao TL" {
  AUTOR=outro rodar criar-rc.sh
  assert_failure
  refuso | grep -F "só o autor do MR ou um Tech Lead"
}

@test "autor diferente do dono mas TL passa" {
  fake_membro tl tech-leads
  AUTOR=tl rodar criar-rc.sh
  assert_success
}

@test "mesmo ID em outro PR aberto" {
  nova_branch bugfix/PROJ-101-y b.txt
  fake_pr 2 bugfix/PROJ-101-y dev
  rodar criar-rc.sh
  assert_failure
  refuso | grep -F "!2 usa o mesmo ID PROJ-101"
}

@test "segundo hotfix ativo" {
  nova_branch hotfix/1.0.1 h1.txt
  preparar 2 hotfix/1.0.1
  git -C "$WORK" tag -a rc/hotfix-1-0-1.1 -m x "origin/hotfix/1.0.1"
  nova_branch hotfix/1.0.2 h2.txt
  preparar 3 hotfix/1.0.2
  MR_IID=3 rodar criar-rc.sh
  assert_failure
  fake_comentarios 3 | grep -F "hotfix !2 ainda ativo"
}

@test "nao contem origin/main" {
  git -C "$WORK" checkout -q main
  echo novo > "$WORK/n.txt"; git -C "$WORK" add n.txt; git -C "$WORK" commit -q -m n
  git -C "$WORK" push -q origin main
  rodar criar-rc.sh
  assert_failure
  refuso | grep -F "git rebase origin/main"
}

@test "nao contem a versao de PRD" {
  git -C "$WORK" checkout -q -B outra main
  echo p > "$WORK/p.txt"; git -C "$WORK" add p.txt; git -C "$WORK" commit -q -m p
  git -C "$WORK" tag -a v2.0.0 -m v2
  id=$(deploy_iniciar prd v2.0.0 "$(git -C "$WORK" rev-parse HEAD)")
  deploy_concluir "$id" success
  rodar criar-rc.sh
  assert_failure
  refuso | grep -F "não contém a versão em PRD (v2.0.0)"
}

@test "P13 contem entrega de outro MR nao mergeada" {
  nova_branch feature/PROJ-2-z z.txt
  git -C "$WORK" tag -a rc/PROJ-2.1 -m x HEAD
  git -C "$WORK" checkout -q -B feature/PROJ-101-x feature/PROJ-2-z
  echo m > "$WORK/m.txt"; git -C "$WORK" add m.txt; git -C "$WORK" commit -q -m m
  git -C "$WORK" push -q -f origin feature/PROJ-101-x
  preparar 1 feature/PROJ-101-x
  rodar criar-rc.sh
  assert_failure
  refuso | grep -F "contém a entrega rc/PROJ-2.1"
}

@test "pipeline nao verde" {
  fake_pipeline 1 "$(sha_de feature/PROJ-101-x)" failed
  rodar criar-rc.sh
  assert_failure
  refuso | grep -F "pipeline do último commit não está verde"
}

@test "pipeline de outro sha" {
  fake_pipeline 1 0000000 success
  rodar criar-rc.sh
  assert_failure
  refuso | grep -F "pipeline do último commit não está verde"
}

@test "sem review de outra pessoa" {
  pr_editar 1 '.reviews=[{user:"dev",sha:.sha}]'
  rodar criar-rc.sh
  assert_failure
  refuso | grep -F "falta aprovação de code review"
}

@test "review de commit antigo nao vale" {
  pr_editar 1 '.reviews=[{user:"rev",sha:"abc123"}]'
  rodar criar-rc.sh
  assert_failure
  refuso | grep -F "falta aprovação de code review"
}

@test "MODO_DEMO sem review cria a tag e avisa" {
  pr_editar 1 '.reviews=[]'
  MODO_DEMO=sim rodar criar-rc.sh
  assert_success
  git -C "$WORK" rev-parse -q --verify refs/tags/rc/PROJ-101.1
  fake_comentarios 1 | grep -F "⚠️ MODO_DEMO:"
}

@test "criterio de aceite vazio so com texto-guia" {
  fake_descricao 1 '## Critério de aceite
(o que precisa funcionar)

## Como testar
Abrir a tela'
  rodar criar-rc.sh
  assert_failure
  refuso | grep -F 'seção "Critério de aceite" do MR está vazia'
}

@test "como testar vazio" {
  fake_descricao 1 '## Critério de aceite
Ok

## Como testar
'
  rodar criar-rc.sh
  assert_failure
  refuso | grep -F 'seção "Como testar" do MR está vazia'
}

@test "checkbox nao marcado" {
  fake_descricao 1 "$DESC_OK
- [ ] falta isto"
  rodar criar-rc.sh
  assert_failure
  refuso | grep -F "itens do autoteste sem marcar"
}

@test "mesmo commit da entrega anterior" {
  rodar criar-rc.sh
  assert_success
  rodar criar-rc.sh
  assert_failure
  refuso | grep -F "este commit já é a entrega rc/PROJ-101.1"
}

# avancar: novo commit na branch + PR atualizado
avancar() {
  git -C "$WORK" checkout -q feature/PROJ-101-x
  echo mais >> "$WORK/a.txt"; git -C "$WORK" commit -q -am mais
  git -C "$WORK" push -q origin feature/PROJ-101-x
  preparar 1 feature/PROJ-101-x
}

@test "anterior qa-ok sem confirmo pede confirmacao" {
  rodar criar-rc.sh
  git -C "$WORK" tag -a qa-ok/PROJ-101.1 -m ok rc/PROJ-101.1
  avancar
  rodar criar-rc.sh
  assert_failure
  refuso | grep -F "/entregar confirmo"
  ! git -C "$WORK" rev-parse -q --verify refs/tags/rc/PROJ-101.2
}

@test "anterior qa-ok com confirmo cria .2" {
  rodar criar-rc.sh
  git -C "$WORK" tag -a qa-ok/PROJ-101.1 -m ok rc/PROJ-101.1
  avancar
  NOTA="/entregar confirmo" rodar criar-rc.sh
  assert_success
  git -C "$WORK" rev-parse -q --verify refs/tags/rc/PROJ-101.2
}

@test "anterior hom-ajuste cria sem confirmo e com reteste expresso" {
  rodar criar-rc.sh
  git -C "$WORK" tag -a qa-ok/PROJ-101.1 -m ok rc/PROJ-101.1
  git -C "$WORK" tag -a hom-ajuste/PROJ-101.1 -m aj rc/PROJ-101.1
  avancar
  rodar criar-rc.sh
  assert_success
  fake_labels 1 | grep -F "Reteste expresso"
}

@test "anterior qa-nok cria .2 com reteste expresso" {
  rodar criar-rc.sh
  git -C "$WORK" tag -a qa-nok/PROJ-101.1 -m nok rc/PROJ-101.1
  avancar
  rodar criar-rc.sh
  assert_success
  git -C "$WORK" rev-parse -q --verify refs/tags/rc/PROJ-101.2
  fake_labels 1 | grep -F "Reteste expresso"
  fake_labels 1 | grep -F "Ambiente::QA"
}

@test "MODO_DEMO recusado depois do review nao comenta aviso" {
  pr_editar 1 '.reviews=[]'
  fake_descricao 1 "## Critério de aceite

## Como testar
x"
  MODO_DEMO=sim rodar criar-rc.sh
  assert_failure
  ! git -C "$WORK" rev-parse -q --verify refs/tags/rc/PROJ-101.1
  ! fake_comentarios 1 | grep -F "MODO_DEMO"
}

@test "falha ao listar PRs abertos aborta sem criar tag" {
  mkdir -p "$BATS_TEST_TMPDIR/kit/adapters/provider" "$BATS_TEST_TMPDIR/kit/core"
  cp "$KIT_DIR/core/"*.sh "$BATS_TEST_TMPDIR/kit/core/"
  cat "$KIT_DIR/adapters/provider/fake.sh" > "$BATS_TEST_TMPDIR/kit/adapters/provider/fake.sh"
  echo 'pr_listar_abertos() { echo "provider fora do ar" >&2; return 1; }' >> "$BATS_TEST_TMPDIR/kit/adapters/provider/fake.sh"
  KIT_DIR="$BATS_TEST_TMPDIR/kit" rodar criar-rc.sh
  assert_failure
  ! git -C "$WORK" rev-parse -q --verify refs/tags/rc/PROJ-101.1
}

@test "MODO_DEMO sem review: aviso so apos a tag" {
  pr_editar 1 '.reviews=[]'
  MODO_DEMO=sim rodar criar-rc.sh
  assert_success
  fake_comentarios 1 | grep -F "⚠️ MODO_DEMO:"
}
