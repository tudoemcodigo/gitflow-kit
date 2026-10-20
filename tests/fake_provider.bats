load helper

setup() { setup_repo; }

@test "pr_get devolve JSON normalizado" {
  fake_pr 11 feature/PROJ-101-x dev1
  [ "$(pr_get 11 | jq -r .source_branch)" = "feature/PROJ-101-x" ]
  [ "$(pr_get 11 | jq -r .target_branch)" = "main" ]
  [ "$(pr_get 11 | jq -r .draft)" = "false" ]
}

@test "deploy_ultimo_ok ignora failed" {
  id=$(deploy_iniciar qa qa.2026-10-12.1 aaa); deploy_concluir "$id" success
  id=$(deploy_iniciar qa qa.2026-10-12.2 bbb); deploy_concluir "$id" failed
  [ "$(deploy_ultimo_ok qa)" = "qa.2026-10-12.1" ]
  [ "$(deploy_ultimo qa)" = "qa.2026-10-12.2 failed" ]
}

@test "deploy_ok_anterior devolve o success anterior ao deploy de REF" {
  id=$(deploy_iniciar prd v1.1.0 aaa); deploy_concluir "$id" success
  id=$(deploy_iniciar prd v1.2.0 bbb); deploy_concluir "$id" failed
  id=$(deploy_iniciar prd v1.3.0 ccc); deploy_concluir "$id" success
  [ "$(deploy_ok_anterior prd v1.3.0)" = "v1.1.0" ]
  [ "$(deploy_ok_anterior prd v1.1.0)" = "v1.0.0" ]
}

@test "membro aceita qualquer grupo da lista" {
  fake_membro qa1 qa
  membro qa1 negocio qa
  run membro dev1 qa
  [ "$status" -eq 1 ]
}

@test "pr_rotular troca labels" {
  fake_pr 11 feature/PROJ-101-x dev1
  pr_rotular 11 "Ambiente::QA" ""
  pr_rotular 11 "Ambiente::HOM" "Ambiente::QA"
  [ "$(fake_labels 11)" = "Ambiente::HOM" ]
}

@test "pr_listar_abertos, comentar e fechar" {
  fake_pr 11 feature/PROJ-101-x dev1
  fake_pr 12 feature/PROJ-102-y dev2
  pr_rotular 12 "a,b" ""
  pr_comentar 11 'texto "hostil" $(x) `y`'
  [ "$(fake_comentarios 11)" = 'texto "hostil" $(x) `y`' ]
  pr_fechar 11
  [ "$(pr_listar_abertos)" = "12 feature/PROJ-102-y a,b" ]
}

@test "aprovado_por_outro exige outra pessoa no sha atual" {
  fake_pr 11 feature/PROJ-101-x dev1
  fake_review 11 dev1 sha1
  run aprovado_por_outro 11 sha1 dev1
  [ "$status" -ne 0 ]
  fake_review 11 rev1 sha0
  run aprovado_por_outro 11 sha1 dev1
  [ "$status" -ne 0 ]
  fake_review 11 rev1 sha1
  aprovado_por_outro 11 sha1 dev1
}

@test "pipeline, descricao, release e branch_apagar" {
  fake_pr 11 feature/PROJ-101-x dev1 draft
  fake_pipeline 11 abc success
  fake_descricao 11 "Descricao"
  [ "$(pr_get 11 | jq -r '.draft,.pipeline_sha,.pipeline_status,.description' | paste -sd,)" = "true,abc,success,Descricao" ]
  release_criar v1.1.0 "notas"
  [ "$(jq -r '.[0].tag' "$FAKE_DIR/releases.json")" = "v1.1.0" ]
  nova_branch feature/PROJ-5-z f.txt
  branch_apagar feature/PROJ-5-z
  run git -C "$ORIGIN" rev-parse --verify -q refs/heads/feature/PROJ-5-z
  [ "$status" -ne 0 ]
}

@test "issue_comentar, pr_comentarios e release_criar idempotente" {
  issue_comentar 7 "primeiro"
  issue_comentar 7 "segundo"
  [ "$(fake_issue_comentarios 7 | paste -sd,)" = "primeiro,segundo" ]
  fake_pr 12 feature/PROJ-102-x dev1
  pr_comentar 12 "um"
  [ "$(pr_comentarios 12)" = "um" ]
  release_criar v1.2.0 "a"
  release_criar v1.2.0 "b"
  [ "$(jq length "$FAKE_DIR/releases.json")" -eq 1 ]
}
