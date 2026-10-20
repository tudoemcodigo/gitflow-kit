load helper

# setup/github.sh: golden do --dry-run e idempotencia com um `gh` falso no PATH.

SH() { sh "$KIT_DIR/setup/github.sh" "$@"; }

@test "dry-run imprime so METODO caminho, igual ao golden" {
  SH --repo acme/app --app-id 12345 --dry-run 2>/dev/null > "$BATS_TEST_TMPDIR/saida"
  diff "$BATS_TEST_TMPDIR/saida" "$KIT_DIR/tests/fixtures/setup_github.golden"
}

@test "dry-run nao chama gh" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho CHAMOU >> "%s/chamou"\nexit 1\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" SH --repo acme/app --app-id 1 --dry-run > /dev/null 2>&1
  [ ! -e "$BATS_TEST_TMPDIR/chamou" ]
}

@test "exige --repo no formato ORG/REPO e --app-id" {
  run SH --app-id 1 --dry-run
  [ "$status" -ne 0 ]
  run SH --repo semorg --app-id 1 --dry-run
  [ "$status" -ne 0 ]
  run SH --repo acme/app --dry-run
  [ "$status" -ne 0 ]
}

@test "template de PR tem os tres titulos e labels.tsv tem 15 linhas de 3 colunas" {
  t="$KIT_DIR/setup/modelos/pull_request_template.md"
  grep -qx '## Critério de aceite' "$t"
  grep -qx '## Como testar' "$t"
  grep -qx '## Autoteste do dev' "$t"
  [ "$(wc -l < "$KIT_DIR/setup/modelos/labels.tsv" | tr -d ' ')" = 15 ]
  [ "$(awk -F'\t' 'NF==3' "$KIT_DIR/setup/modelos/labels.tsv" | wc -l | tr -d ' ')" = 15 ]
}

# --- gh falso: grava "METODO caminho" e responde GET a partir de $FAKE/state/<caminho com / -> _> ---
fake_gh() {
  FAKE="$BATS_TEST_TMPDIR/fake"
  mkdir -p "$FAKE/bin" "$FAKE/state" "$FAKE/falha"
  cat > "$FAKE/bin/gh" <<'GH'
#!/bin/sh
[ "$1" = api ] || exit 2
shift
M=GET P=
while [ $# -gt 0 ]; do
  case $1 in
    -X) M=$2; shift ;;
    --input) B=1 ;;
    --paginate|--silent) : ;;
    --jq) shift ;;
    -*) : ;;
    *) P=$1 ;;
  esac
  shift
done
case $P in /*) echo "$M $P" >> "$FAKE/barra"; P=${P#/} ;; esac
P=/$P
echo "$M $P" >> "$FAKE/log"
[ -z "${B:-}" ] || cat > "$FAKE/body.$(printf "%s" "$M$P" | tr "/?=&" "____")"
if [ "$M" = GET ]; then
  f="$FAKE/state/$(printf '%s' "$P" | tr '/?=&' '____')"
  if [ -f "$f" ] && grep -q '^HTTP500' "$f"; then echo "gh: Server Error (HTTP 500)" >&2; exit 1; fi
  if [ -f "$f" ]; then cat "$f"; exit 0; fi
  echo "gh: Not Found (HTTP 404)" >&2
  exit 1
fi
f="$FAKE/falha/$(printf '%s' "$M$P" | tr '/?=&' '____')"
if [ -f "$f" ]; then cat "$f" >&2; exit 1; fi
echo '{"id":7,"sha":"abc","object":{"sha":"abc"}}'
GH
  chmod +x "$FAKE/bin/gh"
  export FAKE
  PATH="$FAKE/bin:$PATH"
}

# estado "tudo ja existe", derivado do golden: cada GET responde com o objeto que o script espera
estado_existente() {
  S="$FAKE/state"
  put() { printf '%s' "$2" > "$S/$(printf '%s' "$1" | tr '/?=&' '____')"; }
  put /repos/acme/app '{"default_branch":"main"}'
  put '/orgs/acme/installations?per_page=100' '{"total_count":1,"installations":[{"id":5,"app_id":12345,"app_slug":"meu-bot","repository_selection":"all"}]}'
  put /orgs/acme/teams/tech-leads/repos/acme/app '{"role_name":"push"}'
  for t in qa negocio tech-leads release-managers; do put "/orgs/acme/teams/$t" '{"id":9}'; done
  for b in main qa hom meta/rerere gh-pages; do put "/repos/acme/app/git/ref/heads/$b" '{"object":{"sha":"abc"}}'; done
  put /repos/acme/app/git/matching-refs/tags/v '[{"ref":"refs/tags/v0.1.0"}]'
  put '/repos/acme/app/deployments?environment=production&per_page=1' '[{"id":3}]'
  put /orgs/acme/teams/qa/repos/acme/app '{"role_name":"maintain"}'
  put /orgs/acme/teams/release-managers/repos/acme/app '{"role_name":"admin"}'
  put /repos/acme/app/pages '{"url":"x"}'
  put /repos/acme/app/contents/.github/pull_request_template.md '{"sha":"s"}'
  put '/repos/acme/app/labels?per_page=100' "$(cut -f1 "$KIT_DIR/setup/modelos/labels.tsv" | jq -R '{name:.}' | jq -cs .)"
  put '/repos/acme/app/rulesets?per_page=100&includes_parents=false' '[{"id":1,"name":"gitflow-ambientes"},{"id":2,"name":"gitflow-tags"},{"id":3,"name":"gitflow-versoes"}]'
  put '/repos/acme/app/actions/secrets?per_page=100' '{"secrets":[{"name":"GITFLOW_APP_ID"},{"name":"GITFLOW_APP_KEY"}]}'
}

@test "primeira execucao (nada existe) cria teams, branches, tag, labels e rulesets" {
  fake_gh
  put() { printf '%s' "$2" > "$FAKE/state/$(printf '%s' "$1" | tr '/?=&' '____')"; }
  put /repos/acme/app '{"default_branch":"main"}'
  put '/orgs/acme/installations?per_page=100' '{"installations":[{"app_id":12345,"app_slug":"meu-bot","repository_selection":"all"}]}'
  put /repos/acme/app/git/ref/heads/main '{"object":{"sha":"abc"}}'
  run SH --repo acme/app --app-id 12345
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q '^POST /orgs/acme/teams$' "$FAKE/log"
  grep -q '^POST /repos/acme/app/git/refs$' "$FAKE/log"
  grep -q '^POST /repos/acme/app/labels$' "$FAKE/log"
  grep -q '^POST /repos/acme/app/rulesets$' "$FAKE/log"
  grep -q '^POST /repos/acme/app/deployments$' "$FAKE/log"
}

@test "segunda execucao (tudo existe) nao faz nenhum POST de criacao" {
  fake_gh
  estado_existente
  run SH --repo acme/app --app-id 12345
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  if grep -q '^POST ' "$FAKE/log"; then cat "$FAKE/log"; false; fi
  grep -q '^PUT /repos/acme/app/rulesets/1$' "$FAKE/log"
  grep -q '^PUT /repos/acme/app/environments/aprovacao-prd$' "$FAKE/log"
  grep -q '^PATCH /repos/acme/app$' "$FAKE/log"
}

@test "avisa quando faltam os secrets do App e documenta a limitacao de refs/gitflow" {
  fake_gh
  estado_existente
  printf '{"secrets":[]}' > "$FAKE/state/_repos_acme_app_actions_secrets_per_page_100"

  run SH --repo acme/app --app-id 12345
  [ "$status" -eq 0 ]
  [[ "$output" == *"GITFLOW_APP_ID"* ]]
  [[ "$output" == *"refs/gitflow"* ]]
}

@test "--modo-demo desliga prevent_self_review e avisa" {
  fake_gh
  estado_existente
  run SH --repo acme/app --app-id 12345 --modo-demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"MODO_DEMO"* ]]
  [ "$(jq -r .prevent_self_review "$FAKE/body.PUT_repos_acme_app_environments_aprovacao-prd")" = false ]
  [ "$(jq -r '.reviewers[0].type' "$FAKE/body.PUT_repos_acme_app_environments_aprovacao-prd")" = Team ]
}

@test "padrao: aprovacao-prd com prevent_self_review, production sem revisores, bypass do App e da Team em v*" {
  fake_gh
  estado_existente
  run SH --repo acme/app --app-id 12345
  [ "$status" -eq 0 ]
  [ "$(jq -r .prevent_self_review "$FAKE/body.PUT_repos_acme_app_environments_aprovacao-prd")" = true ]
  [ "$(jq -r '.reviewers | length' "$FAKE/body.PUT_repos_acme_app_environments_production")" = 0 ]
  [ "$(jq -r '.bypass_actors[0].actor_type' "$FAKE/body.PUT_repos_acme_app_rulesets_3")" = Integration ]
  [ "$(jq -r '.bypass_actors[1].actor_type' "$FAKE/body.PUT_repos_acme_app_rulesets_3")" = Team ]
}

@test "GET com erro 500 em matching-refs: aborta sem criar tag v0.1.0 nem deployment" {
  fake_gh
  estado_existente
  printf 'HTTP500' > "$FAKE/state/_repos_acme_app_git_matching-refs_tags_v"
  run SH --repo acme/app --app-id 12345
  [ "$status" -ne 0 ]
  if grep -q '^POST /repos/acme/app/git/tags' "$FAKE/log"; then false; fi
  if grep -q '^POST /repos/acme/app/deployments' "$FAKE/log"; then false; fi
}

@test "GET com erro 500 em deployments: aborta sem criar deployment" {
  fake_gh
  estado_existente
  printf 'HTTP500' > "$FAKE/state/_repos_acme_app_deployments_environment_production_per_page_1"
  run SH --repo acme/app --app-id 12345
  [ "$status" -ne 0 ]
  if grep -q '^POST /repos/acme/app/deployments' "$FAKE/log"; then false; fi
}

@test "Teams: qa, tech-leads e release-managers recebem push; negocio nao; nunca rebaixa acesso existente" {
  fake_gh
  estado_existente
  run SH --repo acme/app --app-id 12345
  [ "$status" -eq 0 ]
  if grep -q '^PUT /orgs/acme/teams/.*/repos/' "$FAKE/log"; then cat "$FAKE/log"; false; fi
  rm "$FAKE/state/_orgs_acme_teams_qa_repos_acme_app" "$FAKE/state/_orgs_acme_teams_tech-leads_repos_acme_app" "$FAKE/log"
  run SH --repo acme/app --app-id 12345
  grep -q '^PUT /orgs/acme/teams/qa/repos/acme/app$' "$FAKE/log"
  grep -q '^PUT /orgs/acme/teams/tech-leads/repos/acme/app$' "$FAKE/log"
  [ "$(jq -r .permission "$FAKE/body.PUT_orgs_acme_teams_tech-leads_repos_acme_app")" = push ]
  if grep -q 'teams/negocio/repos' "$FAKE/log"; then false; fi
}

@test "--grupo-*: Teams, revisores e bypass usam os slugs informados" {
  fake_gh
  estado_existente
  S="$FAKE/state"
  for t in meu-qa meu-neg meus-tls meus-rms; do printf '{"id":9}' > "$S/_orgs_acme_teams_$t"; done
  printf '{"role_name":"push"}' > "$S/_orgs_acme_teams_meu-qa_repos_acme_app"
  printf '{"role_name":"push"}' > "$S/_orgs_acme_teams_meus-tls_repos_acme_app"
  printf '{"role_name":"push"}' > "$S/_orgs_acme_teams_meus-rms_repos_acme_app"
  run SH --repo acme/app --app-id 12345 --grupo-qa meu-qa --grupo-negocio meu-neg --grupo-tl meus-tls --grupo-rm meus-rms
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q '^GET /orgs/acme/teams/meus-rms$' "$FAKE/log"
  grep -q '^GET /orgs/acme/teams/meus-tls/repos/acme/app$' "$FAKE/log"
  if grep -q 'teams/tech-leads$\|teams/release-managers$' "$FAKE/log"; then cat "$FAKE/log"; false; fi
  run SH --repo acme/app --app-id 12345 --grupo-tl 'Tech Leads'
  [ "$status" -ne 0 ]
}

@test "gh api sempre sem barra inicial (Git Bash converteria o caminho)" {
  fake_gh
  estado_existente
  run SH --repo acme/app --app-id 12345
  [ "$status" -eq 0 ]
  [ -s "$FAKE/log" ]
  [ ! -e "$FAKE/barra" ] || { cat "$FAKE/barra"; false; }
}

@test "App nao instalado na organizacao: para antes de qualquer escrita, com a mensagem de instalacao" {
  fake_gh
  estado_existente
  printf '{"installations":[{"app_id":999,"app_slug":"outro","repository_selection":"all"}]}' > "$FAKE/state/_orgs_acme_installations_per_page_100"
  run SH --repo acme/app --app-id 12345 --app-slug meu-bot
  [ "$status" -ne 0 ]
  [[ "$output" == *"o GitHub App (id 12345) não está instalado em acme/app: instale em https://github.com/apps/meu-bot/installations/new e rode o setup de novo"* ]]
  if grep -Eq '^(POST|PUT|PATCH|DELETE) ' "$FAKE/log"; then cat "$FAKE/log"; false; fi
}

@test "ruleset 422 'must be part of the ruleset source' vira a mensagem de instalacao (slug da API)" {
  fake_gh
  estado_existente
  printf '[]' > "$FAKE/state/_repos_acme_app_rulesets_per_page_100_includes_parents_false"
  printf 'gh: Validation Failed (HTTP 422)
Actor must be part of the ruleset source or owner organization
' > "$FAKE/falha/POST_repos_acme_app_rulesets"
  run SH --repo acme/app --app-id 12345
  [ "$status" -ne 0 ]
  [[ "$output" == *"o GitHub App (id 12345) não está instalado em acme/app: instale em https://github.com/apps/meu-bot/installations/new"* ]]
}

@test "Pages: HTTP 409 no POST e sucesso (ja habilitado)" {
  fake_gh
  estado_existente
  rm "$FAKE/state/_repos_acme_app_pages"
  printf 'gh: Conflict (HTTP 409)
A GitHub Pages site already exists.
' > "$FAKE/falha/POST_repos_acme_app_pages"
  run SH --repo acme/app --app-id 12345
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"Pages: já habilitado"* ]]
  [[ "$output" != *"AVISO: nao consegui habilitar o Pages"* ]]
  printf 'gh: Server Error (HTTP 500)
' > "$FAKE/falha/POST_repos_acme_app_pages"
  run SH --repo acme/app --app-id 12345
  [[ "$output" == *"AVISO: nao consegui habilitar o Pages"* ]]
}

@test "tag mais nova por ordem de versao, nao de texto (v0.10.0 > v0.9.0)" {
  fake_gh
  estado_existente
  printf '[{"ref":"refs/tags/v0.9.0"},{"ref":"refs/tags/v0.10.0"}]' > "$FAKE/state/_repos_acme_app_git_matching-refs_tags_v"
  printf '[]' > "$FAKE/state/_repos_acme_app_deployments_environment_production_per_page_1"
  run SH --repo acme/app --app-id 12345
  [ "$status" -eq 0 ]
  [ "$(jq -r .ref "$FAKE/body.POST_repos_acme_app_deployments")" = v0.10.0 ]
}
