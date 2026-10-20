load helper

# Camada GitHub Actions: workflows reutilizaveis e chamadores. Sem rede.

WF=""
setup() {
  WF="$KIT_DIR/.github/workflows"
  CH="$KIT_DIR/ci/github-actions/chamadores"
}

# bloco de um job: das linhas "  <job>:" ate o proximo job (2 espacos de indentacao)
job_bloco() { # arquivo job
  awk -v j="  $2:" '
    $0 == j { dentro = 1; print; next }
    dentro && /^  [A-Za-z0-9_-]+:/ { exit }
    dentro { print }' "$1"
}

# "! cmd" nao falha o teste sob set -e: helpers explicitos
nao_tem() { # texto regex(grep -E)
  if printf '%s
' "$1" | grep -Eq -- "$2"; then echo "inesperado: $2"; return 1; fi
}
nao_tem_arq() { # arquivo regex
  if grep -Eq -- "$2" "$1"; then echo "inesperado em $1: $2"; return 1; fi
}

reutilizaveis() { ls "$WF"/gitflow-*.yml; }

@test "actionlint limpo em todos os workflows, na acao e nos chamadores" {
  command -v actionlint > /dev/null || skip "actionlint ausente"
  # (no CI do kit o binario com checksum fixado entra no PATH pelo passo "instalar actionlint")
  run actionlint "$WF"/*.yml "$CH"/*.yml
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "existem os oito workflows reutilizaveis e a acao preparar" {
  for n in comandos montar esteira regressao release promover-hotfix voltar destravar; do
    [ -f "$WF/gitflow-$n.yml" ]
  done
  [ -f "$KIT_DIR/.github/actions/preparar/action.yml" ]
  [ -f "$CH/gitflow.yml" ]
  [ -f "$CH/app-ci.yml" ]
}

@test "todos os reutilizaveis: workflow_call com kit-repo/kit-ref e os secrets do App" {
  for f in $(reutilizaveis); do
    grep -q 'workflow_call:' "$f"
    grep -q 'kit-repo:' "$f"
    grep -q 'kit-ref:' "$f"
    grep -q 'GITFLOW_APP_ID:' "$f"
    grep -q 'GITFLOW_APP_KEY:' "$f"
    grep -q 'repository: ${{ inputs.kit-repo }}' "$f"
    grep -q 'ref: ${{ inputs.kit-ref }}' "$f"
    grep -q 'path: .gitflow' "$f"
    nao_tem_arq "$f" 'job_workflow_sha'
  done
}

@test "nenhum run: usa github.event.comment.body (texto hostil so por env:)" {
  for f in $(reutilizaveis) "$CH"/*.yml; do
    run awk '
      /^[[:space:]]*run:/ { r = 1; ind = match($0, /[^ ]/); next }
      r && NF && match($0, /[^ ]/) <= ind && !/^[[:space:]]*#/ { r = 0 }
      r && /github\.event\.comment\.body/ { print FILENAME ": " $0; bad = 1 }
      END { exit bad }' "$f"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
  done
  grep -q 'NOTA: ${{ github.event.comment.body }}' "$WF/gitflow-comandos.yml"
}

@test "nenhum run: interpola github.event.* ou inputs.* (so env:)" {
  for f in $(reutilizaveis) "$KIT_DIR/.github/actions/preparar/action.yml" "$CH"/*.yml; do
    run awk '
      /^[[:space:]]*run:/ { r = 1; ind = match($0, /[^ ]/) }
      r && /\$\{\{[^}]*(github\.event\.|inputs\.)/ { print FILENAME ": " $0; bad = 1 }
      r && NF && !/^[[:space:]]*run:/ && match($0, /[^ ]/) <= ind { r = 0 }
      END { exit bad }' "$f"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
  done
}

@test "gitflow-comandos nao tem concurrency (a serializacao e o lock em ref)" {
  nao_tem_arq "$WF/gitflow-comandos.yml" 'concurrency'
  grep -q 'lock.sh" pegar comandos' "$WF/gitflow-comandos.yml"
  grep -q "github.event.issue.pull_request" "$WF/gitflow-comandos.yml"
}

@test "construir e testar: contents read, sem secrets, sem token do App" {
  for j in construir testar; do
    b=$(job_bloco "$WF/gitflow-esteira.yml" $j)
    [ -n "$b" ]
    printf '%s\n' "$b" | grep -q 'contents: read'
    nao_tem "$b" 'secrets[.]'
    nao_tem "$b" 'app-id|app-key|create-github-app-token|GITFLOW_APP'
    nao_tem "$b" "token: 'true'"
  done
}

@test "jobs com token do App nao sao construir/testar/gates" {
  f="$WF/gitflow-esteira.yml"
  for j in preparar publicar-pacote implantar registrar falhou; do
    job_bloco "$f" $j | grep -q "token: 'true'"
  done
  for j in construir testar gates; do
    nao_tem "$(job_bloco "$f" $j)" "token: 'true'"
  done
  # so a acao composta cria o token
  run grep -l 'create-github-app-token' -r "$KIT_DIR/.github"
  [ "$output" = "$KIT_DIR/.github/actions/preparar/action.yml" ]
  grep -q 'create-github-app-token@v1' "$KIT_DIR/.github/actions/preparar/action.yml"
  grep -q 'owner: ${{ github.repository_owner }}' "$KIT_DIR/.github/actions/preparar/action.yml"
}

@test "esteira: jobs, environments e falhou" {
  f="$WF/gitflow-esteira.yml"
  for j in preparar construir testar publicar-pacote gates aprovacao implantar checagem registrar falhou; do
    [ -n "$(job_bloco "$f" $j)" ]
  done
  job_bloco "$f" aprovacao | grep -q 'environment: aprovacao-prd'
  job_bloco "$f" checagem | grep -q 'environment: checagem-${{ inputs.AMBIENTE }}'
  job_bloco "$f" checagem | grep -q "needs.verificar.outputs.verificar == 'MANUAL'"
  job_bloco "$f" falhou | grep -q 'failure()'
  grep -q 'GITFLOW_RUN_ID' "$KIT_DIR/.github/actions/preparar/action.yml"
  grep -q 'upload-artifact@v4' "$f"
  grep -q 'download-artifact@v4' "$f"
}

@test "agendas em UTC e chamador com secrets inherit" {
  grep -q "0 13,18 \* \* 1-5" "$CH/gitflow.yml"
  grep -q "0 20 \* \* 1-5" "$CH/gitflow.yml"
  grep -q 'secrets: inherit' "$CH/gitflow.yml"
  grep -q 'gitflow-kit/.github/workflows/gitflow-comandos.yml@v1' "$CH/gitflow.yml"
  nao_tem_arq "$CH/app-ci.yml" 'secrets'
}

@test "nada da empresa nos arquivos do kit" {
  # termos vem do ambiente (virgula ou espaco), nunca literais no repo
  if [ -z "${GITFLOW_TERMOS_PROIBIDOS:-}" ]; then
    skip "GITFLOW_TERMOS_PROIBIDOS não definido"
  fi
  dirs=()
  for d in .github ci core adapters setup modelos docs; do
    [ -d "$KIT_DIR/$d" ] && dirs+=("$KIT_DIR/$d")
  done
  [ "${#dirs[@]}" -gt 0 ]
  termos=$(printf '%s' "$GITFLOW_TERMOS_PROIBIDOS" | tr ',' ' ')
  for t in $termos; do
    run grep -rliF -- "$t" "${dirs[@]}"
    [ "$status" -ne 0 ] || { echo "termo proibido encontrado: $t"; echo "$output"; false; }
  done
}

@test "token do App restrito ao repositorio e sem credencial persistida" {
  a="$KIT_DIR/.github/actions/preparar/action.yml"
  grep -q 'repositories: ${{ steps.repo.outputs.nome }}' "$a"
  for f in $(reutilizaveis) "$a"; do
    # todo checkout declara persist-credentials: false
    n=$(grep -c 'uses: actions/checkout@v4' "$f")
    m=$(grep -c 'persist-credentials: false' "$f")
    [ "$n" -eq "$m" ] || { echo "$f: $n checkouts, $m persist-credentials"; false; }
  done
}

@test "verificar-auto roda em job proprio sem token do App" {
  f="$WF/gitflow-esteira.yml"
  b=$(job_bloco "$f" verificar)
  [ -n "$b" ]
  printf '%s
' "$b" | grep -q 'verificar-auto'
  nao_tem "$b" "token: 'true'|secrets[.]"
  nao_tem "$(job_bloco "$f" implantar)" 'verificar-auto'
}

@test "GITFLOW_RUN_ID e so o run_id (re-run mantem o dono dos locks)" {
  a="$KIT_DIR/.github/actions/preparar/action.yml"
  grep -q 'GITFLOW_RUN_ID=${RUN_ID}"' "$a"
  nao_tem_arq "$a" 'run_attempt}[^/]|RUN_ATTEMPT'
}

@test "comandos so aceita OWNER/MEMBER/COLLABORATOR" {
  grep -q 'author_association' "$WF/gitflow-comandos.yml"
}

@test "::add-mask:: nunca fica dentro do grupo redirecionado para GITHUB_ENV" {
  a="$KIT_DIR/.github/actions/preparar/action.yml"
  grep -q '::add-mask::' "$a"
  run awk '
    /^[[:space:]]*\{[[:space:]]*$/ { g = 1; next }
    g && /\}[[:space:]]*>>[[:space:]]*"\$GITHUB_ENV"/ { g = 0; next }
    g && /::add-mask::/ { print NR ": " $0; bad = 1 }
    END { exit bad }' "$a"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "nenhum job declara environment production, qa ou hom (so deployments da API do kit)" {
  for f in $(reutilizaveis) "$CH"/*.yml; do
    nao_tem_arq "$f" '^[[:space:]]*environment:[[:space:]]*(production|qa|hom)[[:space:]]*$'
  done
}
