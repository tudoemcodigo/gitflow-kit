#!/usr/bin/env bats
load helper

setup() {
  setup_repo
  git -C "$WORK" config rerere.enabled false
}

# entrega ID [DEC...]: branch, rc/ID.1 anotada e tags de decisao listadas
entrega() {
  local id="$1"
  shift
  git -C "$WORK" checkout -q -B "feature/$id-x" main
  echo "$id" > "$WORK/$id.txt"
  git -C "$WORK" add "$id.txt"
  git -C "$WORK" commit -q -m "feat: $id"
  git -C "$WORK" tag -a "rc/$id.1" -m Entrega
  local d
  for d in "$@"; do git -C "$WORK" tag -a "$d/$id.1" -m x "rc/$id.1^{commit}"; done
}
# montar_hom TITULO TAG RC...: commit de montagem a partir da main com manifesto
montar_hom() {
  local tit="$1" tag="$2" rc msg nl
  nl=$'\n'
  shift 2
  git -C "$WORK" checkout -q --detach origin/main
  msg="$tit$nl${nl}base main x (v1.0.0)${nl}rerere nenhum"
  for rc in "$@"; do
    git -C "$WORK" merge -q --no-ff -m "m $rc" "$rc" > /dev/null
    msg="$msg$nl$rc !1 abc1234 homologada"
  done
  if [ $# -eq 0 ]; then git -C "$WORK" commit -q --allow-empty -m montagem; fi
  git -C "$WORK" tag -a --cleanup=verbatim "$tag" -m "$msg"
}
valida() { rodar validar-tag.sh "$@"; }

@test "caso feliz prd: 0" {
  entrega ABC-1 qa-ok hom-ok
  montar_hom "Release 1.1.0" hom.2026-01-01.1 rc/ABC-1.1
  git -C "$WORK" tag -a regressao-ok/hom.2026-01-01.1 -m ok
  git -C "$WORK" tag -a v1.1.0 -m v1.1.0
  valida v1.1.0 prd
  assert_success
}

@test "prd sem regressao-ok recusa" {
  entrega ABC-1 qa-ok hom-ok
  montar_hom "Release 1.1.0" hom.2026-01-01.1 rc/ABC-1.1
  git -C "$WORK" tag -a v1.1.0 -m v1.1.0
  valida v1.1.0 prd
  assert_failure
  assert_output --partial "regressao-ok"
}

@test "prd com titulo da hom diferente da versao recusa" {
  entrega ABC-1 qa-ok hom-ok
  montar_hom "Release 1.2.0" hom.2026-01-01.1 rc/ABC-1.1
  git -C "$WORK" tag -a regressao-ok/hom.2026-01-01.1 -m ok
  git -C "$WORK" tag -a v1.1.0 -m v1.1.0
  valida v1.1.0 prd
  assert_failure
  assert_output --partial "Release 1.1.0"
}

@test "prd com hotfix usa titulo Hotfix" {
  entrega hotfix-1.0.1 qa-ok hom-ok
  montar_hom "Hotfix 1.0.1" hom.2026-01-01.1 rc/hotfix-1.0.1.1
  git -C "$WORK" tag -a regressao-ok/hom.2026-01-01.1 -m ok
  git -C "$WORK" tag -a v1.0.1 -m v1.0.1
  valida v1.0.1 prd
  assert_success
}

@test "prd com entrega que nao e a ultima do MR recusa" {
  entrega ABC-1 qa-ok hom-ok
  montar_hom "Release 1.1.0" hom.2026-01-01.1 rc/ABC-1.1
  git -C "$WORK" tag -a regressao-ok/hom.2026-01-01.1 -m ok
  git -C "$WORK" tag -a v1.1.0 -m v1.1.0
  git -C "$WORK" tag -a rc/ABC-1.2 -m Entrega "rc/ABC-1.1^{commit}"
  valida v1.1.0 prd
  assert_failure
  assert_output --partial "rc/ABC-1.1 não é a última"
}

@test "prd com entrega sem hom-ok recusa" {
  entrega ABC-1 qa-ok
  montar_hom "Release 1.1.0" hom.2026-01-01.1 rc/ABC-1.1
  git -C "$WORK" tag -a regressao-ok/hom.2026-01-01.1 -m ok
  git -C "$WORK" tag -a v1.1.0 -m v1.1.0
  valida v1.1.0 prd
  assert_failure
  assert_output --partial "não está homologada"
}

@test "prd com entrega retirada depois recusa" {
  entrega ABC-1 qa-ok hom-ok
  montar_hom "Release 1.1.0" hom.2026-01-01.1 rc/ABC-1.1
  git -C "$WORK" tag -a regressao-ok/hom.2026-01-01.1 -m ok
  git -C "$WORK" tag -a v1.1.0 -m v1.1.0
  git -C "$WORK" tag -a retirada/ABC-1.1 -m x "rc/ABC-1.1^{commit}"
  valida v1.1.0 prd
  assert_failure
  assert_output --partial "retirada"
}

@test "P9: hotfix publicado depois em PRD que a tag nao contem recusa" {
  entrega ABC-1 qa-ok hom-ok
  montar_hom "Release 1.1.0" hom.2026-01-01.1 rc/ABC-1.1
  git -C "$WORK" tag -a regressao-ok/hom.2026-01-01.1 -m ok
  git -C "$WORK" tag -a v1.1.0 -m v1.1.0
  git -C "$WORK" checkout -q --detach main
  echo hf > "$WORK/hf.txt"
  git -C "$WORK" add hf.txt
  git -C "$WORK" commit -q -m hf
  git -C "$WORK" tag -a v1.0.1 -m v1.0.1
  id=$(deploy_iniciar prd v1.0.1 "$(git -C "$WORK" rev-parse HEAD)")
  deploy_concluir "$id" success
  valida v1.1.0 prd
  assert_failure
  assert_output --partial "P9"
}

@test "prd: tag leve ou nome fora do padrao recusa" {
  git -C "$WORK" tag v9.9.9
  valida v9.9.9 prd
  assert_failure
  assert_output --partial "anotada"
  git -C "$WORK" tag -a versao-x -m x
  valida versao-x prd
  assert_failure
}

@test "qa.* anotada: ok em qa, recusada em hom" {
  git -C "$WORK" tag -a qa.2026-01-01.1 -m "Build qa"
  valida qa.2026-01-01.1 qa
  assert_success
  valida qa.2026-01-01.1 hom
  assert_failure
  assert_output --partial "hom"
}

@test "hom.* anotada ok em hom; qa.* leve recusada em qa" {
  git -C "$WORK" tag -a hom.2026-01-01.1 -m "Build hom"
  valida hom.2026-01-01.1 hom
  assert_success
  git -C "$WORK" tag qa.2026-01-01.2
  valida qa.2026-01-01.2 qa
  assert_failure
}

@test "tag inexistente e ambiente invalido" {
  valida qa.nada qa
  assert_failure
  valida qa.nada xyz
  assert_failure
}

@test "prd sem a ref origin/main recusa com mensagem propria" {
  entrega ABC-1 qa-ok hom-ok
  montar_hom "Release 1.1.0" hom.2026-01-01.1 rc/ABC-1.1
  git -C "$WORK" tag -a regressao-ok/hom.2026-01-01.1 -m ok
  git -C "$WORK" tag -a v1.1.0 -m v1.1.0
  git -C "$WORK" update-ref -d refs/remotes/origin/main
  valida v1.1.0 prd
  assert_failure
  assert_output --partial "origin/main não existe"
}

@test "prd com hom.* leve no commit recusa" {
  entrega ABC-1 qa-ok hom-ok
  montar_hom "Release 1.1.0" hom.2026-01-01.1 rc/ABC-1.1
  git -C "$WORK" tag -a regressao-ok/hom.2026-01-01.1 -m ok
  git -C "$WORK" tag -a v1.1.0 -m v1.1.0
  git -C "$WORK" tag -d hom.2026-01-01.1 > /dev/null
  git -C "$WORK" tag hom.2026-01-01.1 v1.1.0^{commit}
  valida v1.1.0 prd
  assert_failure
}

@test "prd com release vazia (manifesto sem entregas) passa" {
  montar_hom "Release 1.1.0" hom.2026-01-01.1
  git -C "$WORK" tag -a regressao-ok/hom.2026-01-01.1 -m ok
  git -C "$WORK" tag -a v1.1.0 -m v1.1.0
  valida v1.1.0 prd
  assert_success
}
