load helper
load github_stub

setup() {
  export GITHUB_REPOSITORY=acme/app GITHUB_TOKEN=tok GITHUB_API_URL=https://api.test
  # shellcheck source=/dev/null
  . "$KIT_DIR/adapters/provider/github.sh"
  gh_stub_instalar
}

log_tem() { grep -qxF -- "$1" "$GH_LOG"; }

@test "TERMO_PR e PR" {
  [ "$TERMO_PR" = "PR" ]
}

@test "pr_get normaliza PR aberto com pipeline success (gitflow ignorado)" {
  run pr_get 11
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .iid)" = 11 ]
  [ "$(echo "$output" | jq -r .source_branch)" = "feature/PROJ-101-x" ]
  [ "$(echo "$output" | jq -r .target_branch)" = "main" ]
  [ "$(echo "$output" | jq -r .draft)" = "false" ]
  [ "$(echo "$output" | jq -r .sha)" = "sha11" ]
  [ "$(echo "$output" | jq -r .author)" = "dev1" ]
  [ "$(echo "$output" | jq -r '.labels | join(",")')" = "Ambiente::QA,Reteste expresso" ]
  [ "$(echo "$output" | jq -r .pipeline_sha)" = "sha11" ]
  [ "$(echo "$output" | jq -r .pipeline_status)" = "success" ]
  [ "$(echo "$output" | jq -r .state)" = "opened" ]
  [ "$(echo "$output" | jq -r .description)" = "$(printf '## Criterio de aceite\nfeito')" ]
}

@test "pr_get de PR mergeado e rascunho sem checks" {
  run pr_get 12
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .state)" = "merged" ]
  [ "$(echo "$output" | jq -r .draft)" = "true" ]
  [ "$(echo "$output" | jq -r .pipeline_status)" = "none" ]
  [ "$(echo "$output" | jq -r .pipeline_sha)" = "" ]
  [ "$(echo "$output" | jq -r .description)" = "" ]
}

@test "pr_get com um check-run failure e pipeline failed e PR fechado" {
  run pr_get 13
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .pipeline_status)" = "failed" ]
  [ "$(echo "$output" | jq -r .state)" = "closed" ]
}

@test "pr_get de PR inexistente falha" {
  run pr_get 999
  [ "$status" -ne 0 ]
}

@test "pipeline: check-run em andamento e running" {
  [ "$(_gh_pipeline run1)" = "running" ]
}

@test "pipeline: status combinado em erro e failed mesmo com checks ok" {
  [ "$(_gh_pipeline st1)" = "failed" ]
}

@test "pipeline: so status combinado success e success" {
  [ "$(_gh_pipeline st2)" = "success" ]
}

@test "pr_listar_abertos junta 2 paginas: 150 linhas em ordem numerica" {
  run pr_listar_abertos
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 150 ]
  [ "${lines[0]}" = "1 feature/PROJ-1-x " ]
  [ "${lines[6]}" = "7 feature/PROJ-7-x a,b" ]
  [ "${lines[99]}" = "100 feature/PROJ-100-x " ]
  [ "${lines[149]}" = "150 feature/PROJ-150-x " ]
}

@test "pr_comentarios imprime o texto puro de cada comentario" {
  run pr_comentarios 11
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "primeiro" ]
  [ "${lines[1]}" = 'texto "hostil" $(x) `y`' ]
  [ "${lines[2]}" = "linha 2 🚀" ]
}

@test "pr_comentar envia o texto hostil literal no JSON" {
  t=$(printf 'texto "hostil" $(x) `y`\nlinha 2 \360\237\232\200')
  pr_comentar 11 "$t"
  linha=$(grep '^POST /repos/acme/app/issues/11/comments ' "$GH_LOG")
  corpo=${linha#POST /repos/acme/app/issues/11/comments }
  [ "$(echo "$corpo" | jq -r .body)" = "$t" ]
}

@test "issue_comentar usa o caminho da issue" {
  issue_comentar 42 "oi"
  log_tem 'POST /repos/acme/app/issues/42/comments {"body":"oi"}'
}

@test "pr_rotular remove (url-encoded) e depois adiciona" {
  pr_rotular 11 "Ambiente::HOM,Reteste expresso" "Ambiente::QA"
  log_tem 'DELETE /repos/acme/app/issues/11/labels/Ambiente%3A%3AQA '
  log_tem 'POST /repos/acme/app/issues/11/labels {"labels":["Ambiente::HOM","Reteste expresso"]}'
}

@test "pr_rotular remover rotulo ausente (404) nao e erro" {
  gh_api() { printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$GH_LOG"; [ "$1" != DELETE ] || return 44; echo '{}'; }
  pr_rotular 11 "x" "nao-existe"
  log_tem 'POST /repos/acme/app/issues/11/labels {"labels":["x"]}'
}

@test "pr_rotular falha se o DELETE der erro diferente de 404" {
  gh_api() { return 1; }
  run pr_rotular 11 "" "x"
  [ "$status" -ne 0 ]
}

@test "pr_rotular com listas vazias nao chama a API" {
  pr_rotular 11 "" ""
  [ ! -s "$GH_LOG" ]
}

@test "pr_fechar faz PATCH state=closed" {
  pr_fechar 11
  log_tem 'PATCH /repos/acme/app/pulls/11 {"state":"closed"}'
}

@test "branch_apagar apaga a ref e branch inexistente e sucesso" {
  branch_apagar feature/PROJ-1-x
  log_tem 'DELETE /repos/acme/app/git/refs/heads/feature/PROJ-1-x '
  gh_api() { return 44; }
  branch_apagar sumiu
  gh_api() { return 42; }
  branch_apagar sumiu
}

@test "branch_apagar propaga erro real" {
  gh_api() { return 1; }
  run branch_apagar x
  [ "$status" -ne 0 ]
}

@test "aprovado_por_outro: aprovacao do autor ou em commit antigo nao conta" {
  run aprovado_por_outro 11 sha11 dev1
  [ "$status" -ne 0 ]
}

@test "aprovado_por_outro: aprovacao de outra pessoa no sha atual conta" {
  aprovado_por_outro 12 sha12 dev2
}

@test "aprovado_por_outro: vale a ultima revisao de cada pessoa" {
  run aprovado_por_outro 13 sha13 dev1
  [ "$status" -ne 0 ]
}

@test "membro: membro ativo de algum dos grupos" {
  membro qa1 negocio qa
}

@test "membro: 404 e nao-membro (1) e pending tambem" {
  run membro qa1 negocio
  [ "$status" -eq 1 ]
  run membro pend1 negocio
  [ "$status" -eq 1 ]
}

@test "membro: erro diferente de 404 devolve 2" {
  gh_api() { return 1; }
  run membro qa1 qa
  [ "$status" -eq 2 ]
}

@test "membro: erro em um grupo e 404 no outro devolve 2, mas membro de outro grupo vence" {
  gh_api() { case "$2" in */teams/ruim/*) return 1 ;; */teams/qa/*) echo '{"state":"active"}' ;; *) return 44 ;; esac; }
  run membro u1 ruim negocio
  [ "$status" -eq 2 ]
  run membro u1 ruim qa
  [ "$status" -eq 0 ]
}

@test "deploy_iniciar prd cria deployment em production e devolve o id" {
  run deploy_iniciar prd v1.4.0 abc123
  [ "$status" -eq 0 ]
  [ "$output" = "77" ]
  linha=$(grep '^POST /repos/acme/app/deployments ' "$GH_LOG")
  corpo=${linha#POST /repos/acme/app/deployments }
  [ "$(echo "$corpo" | jq -c '[.ref,.environment,.auto_merge,.required_contexts,.transient_environment,.production_environment]')" = '["v1.4.0","production",false,[],false,true]' ]
}

@test "deploy_iniciar qa mantem o ambiente e nao marca production_environment" {
  deploy_iniciar qa qa.2026-10-12.2 abc > /dev/null
  linha=$(grep '^POST /repos/acme/app/deployments ' "$GH_LOG")
  corpo=${linha#POST /repos/acme/app/deployments }
  [ "$(echo "$corpo" | jq -c '[.environment,.production_environment]')" = '["qa",false]' ]
}

@test "deploy_concluir mapeia running success failed" {
  deploy_concluir 77 running
  deploy_concluir 77 success
  deploy_concluir 77 failed
  log_tem 'POST /repos/acme/app/deployments/77/statuses {"state":"in_progress"}'
  log_tem 'POST /repos/acme/app/deployments/77/statuses {"state":"success"}'
  log_tem 'POST /repos/acme/app/deployments/77/statuses {"state":"failure"}'
  run deploy_concluir 77 qualquer
  [ "$status" -ne 0 ]
}

@test "deploy_ultimo: ref e status normalizado" {
  [ "$(deploy_ultimo prd)" = "v1.3.0 failed" ]
}

@test "deploy_ultimo: deployment sem status e running; ambiente vazio nao imprime nada" {
  [ "$(deploy_ultimo qa)" = "qa.2026-10-12.1 running" ]
  run deploy_ultimo hom
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "deploy_ultimo_ok pula failed e enxerga success mesmo se ficou inactive" {
  [ "$(deploy_ultimo_ok prd)" = "v1.2.0" ]
  run deploy_ultimo_ok hom
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "deploy_ok_anterior devolve o success anterior ao deploy de REF" {
  [ "$(deploy_ok_anterior prd v1.3.0)" = "v1.2.0" ]
  [ "$(deploy_ok_anterior prd v1.2.0)" = "v1.1.0" ]
  [ -z "$(deploy_ok_anterior prd v1.1.0)" ]
  [ -z "$(deploy_ok_anterior prd v9.9.9)" ]
}

@test "release_criar de tag que ja tem release e sucesso sem POST" {
  release_criar v1.0.0 "texto"
  run grep -c '^POST' "$GH_LOG"
  [ "$output" = "0" ]
}

@test "release_criar cria a release com o texto literal" {
  t=$(printf 'Notas "x" $(y)\nlinha 2')
  release_criar v1.1.0 "$t"
  linha=$(grep '^POST /repos/acme/app/releases ' "$GH_LOG")
  corpo=${linha#POST /repos/acme/app/releases }
  [ "$(echo "$corpo" | jq -r '[.tag_name,.name]|join(" ")')" = "v1.1.0 v1.1.0" ]
  [ "$(echo "$corpo" | jq -r .body)" = "$t" ]
}

@test "release_criar: corrida (422 no POST mas a release ja existe) e sucesso" {
  gh_api() {
    printf '%s %s\n' "$1" "$2" >> "$GH_LOG"
    case "$1" in
      GET) if [ -f "$BATS_TEST_TMPDIR/criada" ]; then echo '{}'; else return 44; fi ;;
      POST) : > "$BATS_TEST_TMPDIR/criada"; return 42 ;;
    esac
  }
  release_criar v2.0.0 x
}

@test "release_criar: 422 persistente falha" {
  gh_api() { case "$1" in GET) return 44 ;; *) return 42 ;; esac; }
  run release_criar v2.0.0 x
  [ "$status" -ne 0 ]
}

# ---------- camada HTTP de verdade, com curl falso ----------

curl_setup() {
  unset -f gh_api gh_paginar
  # shellcheck source=/dev/null
  . "$KIT_DIR/adapters/provider/github.sh"
  curl_stub_instalar
}

@test "gh_api envia cabecalhos e corpo e devolve o corpo" {
  curl_setup
  echo '{"id":5}' > "$STUB_DIR/POST_repos_acme_app_releases.json"
  run gh_api POST /repos/acme/app/releases '{"a":"b c"}'
  [ "$status" -eq 0 ]
  [ "$output" = '{"id":5}' ]
  grep -qxF 'H Authorization: Bearer tok' "$CURL_LOG"
  grep -qxF 'H Accept: application/vnd.github+json' "$CURL_LOG"
  grep -qxF 'H X-GitHub-Api-Version: 2022-11-28' "$CURL_LOG"
  grep -qxF 'R POST /repos/acme/app/releases {"a":"b c"}' "$CURL_LOG"
}

@test "gh_api mapeia 404 em 44, 422 em 42 e outros erros em 1" {
  curl_setup
  run gh_api GET /repos/acme/app/nada
  [ "$status" -eq 44 ]
  echo '{}' > "$STUB_DIR/GET_repos_acme_app_a.json"
  echo 422 > "$STUB_DIR/GET_repos_acme_app_a.code"
  run gh_api GET /repos/acme/app/a
  [ "$status" -eq 42 ]
  echo 500 > "$STUB_DIR/GET_repos_acme_app_a.code"
  run gh_api GET /repos/acme/app/a
  [ "$status" -eq 1 ]
}

@test "gh_paginar segue o Link rel=next ate acabar" {
  curl_setup
  echo '[{"n":1}]' > "$STUB_DIR/GET_repos_acme_app_x_per_page_1.json"
  printf '<https://api.test/repos/acme/app/x?per_page=1&page=2>; rel="next", <https://api.test/repos/acme/app/x?per_page=1&page=3>; rel="last"' \
    > "$STUB_DIR/GET_repos_acme_app_x_per_page_1.link"
  echo '[{"n":2}]' > "$STUB_DIR/GET_repos_acme_app_x_per_page_1_page_2.json"
  printf '<https://api.test/repos/acme/app/x?per_page=1&page=1>; rel="prev"' > "$STUB_DIR/GET_repos_acme_app_x_per_page_1_page_2.link"
  run gh_paginar "/repos/acme/app/x?per_page=1"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -s -c '[.[][].n]')" = "[1,2]" ]
}
