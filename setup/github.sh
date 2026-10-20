#!/bin/sh
# shellcheck disable=SC2016  # $var dentro de filtros jq nao e expansao de shell
# Configura um repositorio GitHub (e as Teams da organizacao) para o GitFlow Kit. Idempotente.
#
# Uso: setup/github.sh --repo ORG/REPO --app-id ID [--dry-run] [--modo-demo]
#   --app-id     id da integracao (GitHub App) do bot; vira ator de bypass dos rulesets (Integration, always)
#   --dry-run    imprime "METODO caminho" de cada chamada, em ordem fixa, sem executar nada
#   --modo-demo  prevent_self_review=false no Environment aprovacao-prd (revisor pode ser o autor)
#
# Requer `gh` autenticado como admin do repositorio e da organizacao. Todas as chamadas: `gh api`.
#
# Environments:
#   qa, hom, production  sem revisores: so recebem os deployments criados pela API do kit. Nenhum job declara
#                        `environment:` com esses nomes (o Actions criaria um deployment extra e poluiria a "verdade"
#                        de PRD = ultimo deployment success em production).
#   checagem-qa/-hom     revisores: Team qa, sem espera.
#   aprovacao-prd        revisores: Team release-managers; prevent_self_review = nao --modo-demo.
#
# GERENCIAMENTO TOTAL: os Environments (qa, hom, production, checagem-*, aprovacao-prd) e os rulesets gitflow-ambientes,
# gitflow-tags e gitflow-versoes sao totalmente gerenciados por este script: cada execucao sobrescreve (PUT) o que
# foi alterado a mao. Personalizacoes devem usar outros nomes.
# Falhas diferentes de HTTP 404 em leituras interrompem o script (nunca tratadas como "nao existe").
#
# LIMITACAO: rulesets so protegem branches e tags. Os locks do kit (refs/gitflow/lock/*) NAO podem ser protegidos
# por ruleset: quem tem permissao de escrita pode apaga-los. Aceitavel: o workflow "destravar" existe para isso.
set -eu

export TZ=America/Sao_Paulo
KIT_SETUP=$(cd "$(dirname "$0")" && pwd)
ZERO=0000000000000000000000000000000000000000

jq() { command jq -b "$@"; }
info() { printf '%s\n' "$*" >&2; }
die() { printf 'erro: %s\n' "$*" >&2; exit 2; }

REPO="" APP_ID="" DRY=nao DEMO=nao
while [ $# -gt 0 ]; do
  case $1 in
    --repo) [ $# -ge 2 ] || die "--repo exige valor"; REPO=$2; shift ;;
    --app-id) [ $# -ge 2 ] || die "--app-id exige valor"; APP_ID=$2; shift ;;
    --dry-run) DRY=sim ;;
    --modo-demo) DEMO=sim ;;
    *) die "argumento desconhecido: $1" ;;
  esac
  shift
done
case $REPO in */*/* | /* | */ | '') die "use --repo ORG/REPO" ;; */*) ;; *) die "use --repo ORG/REPO" ;; esac
case $APP_ID in '' | *[!0-9]*) die "use --app-id <id numerico da integracao>" ;; esac
ORG=${REPO%%/*}
R="/repos/$REPO"

exec 4>&1

# chamar METODO CAMINHO [CORPO JSON] -> corpo na saida; GET que falha (404 etc.) retorna 1.
# Em --dry-run: imprime "METODO caminho" (stdout original) e nada executa; GET "nao acha" e o resto devolve placeholders.
chamar() {
  _m=$1
  _p=$2
  _b=${3:-}
  if [ "$DRY" = sim ]; then
    printf '%s %s\n' "$_m" "$_p" >&4
    if [ "$_m" = GET ]; then return 1; fi
    printf '{"id":1,"sha":"%s","object":{"sha":"%s"}}\n' "$ZERO" "$ZERO"
    return 0
  fi
  if [ -n "$_b" ]; then
    printf '%s' "$_b" | gh api -X "$_m" "$_p" --input -
  elif [ "$_m" = GET ]; then
    _pg=
    case $_p in *per_page=100*) _pg=--paginate ;; esac
    # shellcheck disable=SC2086  # _pg vazio ou uma unica opcao
    if gh api $_pg "$_p" 2> "$ERRF"; then return 0; fi
    # fail closed: so HTTP 404 e "nao existe"; qualquer outro erro (5xx, 401, 403, rede) interrompe
    if grep -q 'HTTP 404' "$ERRF"; then return 1; fi
    cat "$ERRF" >&2
    return 3
  else
    gh api -X "$_m" "$_p"
  fi
}

ERRF=$(mktemp)
trap 'rm -f "$ERRF"' EXIT

# obter CAMINHO: GET fail-closed. 0 = existe (corpo em $out); 1 = 404 (nao existe); outro erro: aborta o script.
obter() {
  out=$(chamar GET "$1") && return 0
  _rc=$?
  [ "$_rc" -eq 1 ] && return 1
  die "GET $1 falhou (nao e 404); abortando sem alterar nada alem do que ja foi feito"
}

enc() { printf '%s' "$1" | jq -sRr '@uri'; }

if [ "$DRY" = nao ]; then
  command -v gh > /dev/null || die "gh nao encontrado no PATH"
  gh api "$R" > /dev/null || die "nao consegui ler $REPO (login do gh e permissao de admin?)"
fi

# ---------- Teams ----------
TEAM_QA="" TEAM_RM=""
for t in qa negocio tech-leads release-managers; do
  if obter "/orgs/$ORG/teams/$t"; then
    info "team $t: ja existe"
  else
    out=$(chamar POST "/orgs/$ORG/teams" "$(jq -n --arg n "$t" '{name: $n, privacy: "closed"}')")
    info "team $t: criada"
  fi
  id=$(printf '%s' "$out" | jq -r '.id // empty' | head -n 1)
  if [ -z "$id" ]; then
    [ "$DRY" = sim ] || die "nao consegui o id da Team $t"
    id=1
  fi
  [ "$t" = qa ] && TEAM_QA=$id
  [ "$t" = release-managers ] && TEAM_RM=$id
  # So as Teams revisoras (qa, release-managers) precisam de acesso ao repo para aprovar Environments.
  # Nunca rebaixa: so concede `push` se a Team ainda nao tem nenhum acesso ao repositorio.
  case $t in
    qa | release-managers)
      if obter "/orgs/$ORG/teams/$t/repos/$REPO" > /dev/null; then
        info "team $t: ja tem acesso ao repo (mantido)"
      else
        chamar PUT "/orgs/$ORG/teams/$t/repos/$REPO" '{"permission":"push"}' > /dev/null
        info "team $t: acesso push concedido ao repo"
      fi ;;
  esac
done

# ---------- Configuracao do repositorio ----------
chamar PATCH "$R" "$(jq -n '{allow_squash_merge: false, allow_rebase_merge: false, allow_merge_commit: true,
  delete_branch_on_merge: false, has_issues: true}')" > /dev/null
info "repo: squash/rebase desligados, merge commit ligado (o ruleset bloqueia a main para quem nao e o bot)"

# ---------- Branches ----------
if obter "$R/git/ref/heads/main"; then
  MAIN_SHA=$(printf '%s' "$out" | jq -r '.object.sha' | head -n 1)
else
  [ "$DRY" = sim ] || die "branch main nao existe em $REPO"
  MAIN_SHA=$ZERO
fi
for b in qa hom meta/rerere; do
  if obter "$R/git/ref/heads/$b" > /dev/null; then
    info "branch $b: ja existe"
  else
    chamar POST "$R/git/refs" "$(jq -n --arg r "refs/heads/$b" --arg s "$MAIN_SHA" '{ref: $r, sha: $s}')" > /dev/null
    info "branch $b: criada a partir da main"
  fi
done

# ---------- gh-pages + Pages ----------
if obter "$R/git/ref/heads/gh-pages" > /dev/null; then
  info "branch gh-pages: ja existe"
else
  blob=$(chamar POST "$R/git/blobs" "$(jq -n '{content: "GitFlow Kit\n", encoding: "utf-8"}')" | jq -r .sha)
  tree=$(chamar POST "$R/git/trees" "$(jq -n --arg b "$blob" '{tree: [{path: "index.html", mode: "100644", type: "blob", sha: $b}]}')" | jq -r .sha)
  com=$(chamar POST "$R/git/commits" "$(jq -n --arg t "$tree" '{message: "chore: gh-pages inicial", tree: $t, parents: []}')" | jq -r .sha)
  chamar POST "$R/git/refs" "$(jq -n --arg s "$com" '{ref: "refs/heads/gh-pages", sha: $s}')" > /dev/null
  info "branch gh-pages: criada (orfa)"
fi
PAGES=$(jq -n '{source: {branch: "gh-pages", path: "/"}}')
if obter "$R/pages" > /dev/null; then
  chamar PUT "$R/pages" "$PAGES" > /dev/null || info "AVISO: nao consegui atualizar o Pages"
else
  chamar POST "$R/pages" "$PAGES" > /dev/null || info "AVISO: nao consegui habilitar o Pages (plano do repositorio?)"
fi

# ---------- Environments ----------
# amb NOME TEAM_ID|"" PREVENT_SELF_REVIEW
amb() {
  if [ -n "$2" ]; then
    _rev=$(jq -n --argjson i "$2" '[{type: "Team", id: $i}]')
  else
    _rev='[]'
  fi
  chamar PUT "$R/environments/$1" "$(jq -n --argjson r "$_rev" --argjson p "$3" \
    '{wait_timer: 0, prevent_self_review: $p, reviewers: $r, deployment_branch_policy: null}')" > /dev/null
  info "environment $1: ok"
}
PREVENT=true
[ "$DEMO" = sim ] && PREVENT=false
amb qa "" false
amb hom "" false
amb production "" false
amb checagem-qa "$TEAM_QA" false
amb checagem-hom "$TEAM_QA" false
amb aprovacao-prd "$TEAM_RM" "$PREVENT"
if [ "$DEMO" = sim ]; then
  info "⚠️ MODO_DEMO: prevent_self_review=false em aprovacao-prd (quem abriu pode aprovar o proprio PRD)"
fi

# ---------- Rulesets existentes (lidos antes das escritas na main/tags) ----------
RULESETS=""
if obter "$R/rulesets?per_page=100&includes_parents=false"; then RULESETS=$out; fi
if printf '%s' "$RULESETS" | jq -e 'any(.[]?; .name | startswith("gitflow-"))' > /dev/null 2>&1; then
  info "AVISO: rulesets gitflow-* ja existem. O template de PR e a tag v0.1.0 so podem ser escritos antes deles; se faltarem, a escrita sera barrada (quem roda precisa estar no bypass)."
fi

# ---------- Template do PR ----------
TPL=.github/pull_request_template.md
if obter "$R/contents/$TPL" > /dev/null; then
  info "template de PR: ja existe"
else
  chamar PUT "$R/contents/$TPL" "$(jq -n --arg c "$(base64 < "$KIT_SETUP/modelos/pull_request_template.md" | tr -d '\r\n')" \
    '{message: "chore: template de pull request do GitFlow", content: $c, branch: "main"}')" > /dev/null
  info "template de PR: criado na main"
fi

# ---------- Estado inicial de PRD: tag v0.1.0 + deployment success ----------
VTAG=
if obter "$R/git/matching-refs/tags/v" && [ "$(printf '%s' "$out" | jq 'length')" -gt 0 ]; then
  VTAG=$(printf '%s' "$out" | jq -r '[.[].ref | sub("^refs/tags/"; "")] | sort_by(sub("^v"; "") | split(".") | map(tonumber? // 0)) | last' | sed 's|^refs/tags/||')
  info "tag $VTAG: ja existe"
else
  VTAG=v0.1.0
  tg=$(chamar POST "$R/git/tags" "$(jq -n --arg s "$MAIN_SHA" '{tag: "v0.1.0", message: "Estado inicial de PRD", object: $s, type: "commit"}')" | jq -r .sha)
  chamar POST "$R/git/refs" "$(jq -n --arg s "$tg" '{ref: "refs/tags/v0.1.0", sha: $s}')" > /dev/null
  info "tag v0.1.0: criada (anotada) na main"
fi
if obter "$R/deployments?environment=production&per_page=1" && [ "$(printf '%s' "$out" | jq 'length')" -gt 0 ]; then
  info "deployment de production: ja existe"
else
  dep=$(chamar POST "$R/deployments" "$(jq -n --arg r "$VTAG" \
    '{ref: $r, environment: "production", auto_merge: false, required_contexts: [], production_environment: true, description: "estado inicial"}')" | jq -r .id)
  chamar POST "$R/deployments/$dep/statuses" '{"state":"success","environment":"production"}' > /dev/null
  info "deployment inicial de production: criado em $VTAG (success)"
fi

# ---------- Labels ----------
existentes=
if obter "$R/labels?per_page=100"; then
  existentes=$(printf '%s' "$out" | jq -r '.[].name')
fi
TAB=$(printf '\t')
while IFS="$TAB" read -r nome cor desc; do
  [ -n "$nome" ] || continue
  corpo=$(jq -n --arg n "$nome" --arg c "$cor" --arg d "$desc" '{name: $n, color: $c, description: $d}')
  if printf '%s\n' "$existentes" | grep -Fxq -- "$nome"; then
    chamar PATCH "$R/labels/$(enc "$nome")" "$corpo" > /dev/null
  else
    chamar POST "$R/labels" "$corpo" > /dev/null
  fi
done < "$KIT_SETUP/modelos/labels.tsv"
info "labels: sincronizadas"

# ---------- Rulesets ----------
BYPASS_APP=$(jq -n --argjson i "$APP_ID" '[{actor_id: $i, actor_type: "Integration", bypass_mode: "always"}]')
BYPASS_APP_RM=$(jq -n --argjson i "$APP_ID" --argjson t "$TEAM_RM" \
  '[{actor_id: $i, actor_type: "Integration", bypass_mode: "always"}, {actor_id: $t, actor_type: "Team", bypass_mode: "always"}]')

# ruleset NOME TARGET REFS_JSON RULES_JSON BYPASS_JSON
ruleset() {
  _corpo=$(jq -n --arg n "$1" --arg t "$2" --argjson refs "$3" --argjson rules "$4" --argjson by "$5" \
    '{name: $n, target: $t, enforcement: "active", bypass_actors: $by,
      conditions: {ref_name: {include: $refs, exclude: []}}, rules: $rules}')
  _id=
  if [ -n "$RULESETS" ]; then
    _id=$(printf '%s' "$RULESETS" | jq -r --arg n "$1" '[.[] | select(.name == $n) | .id][0] // empty' | head -n 1)
  fi
  if [ -n "$_id" ]; then
    chamar PUT "$R/rulesets/$_id" "$_corpo" > /dev/null
    info "ruleset $1: atualizado"
  else
    chamar POST "$R/rulesets" "$_corpo" > /dev/null
    info "ruleset $1: criado"
  fi
}
# main/qa/hom: `update` ja barra push e merge de quem nao e bypass (inclui force push); non_fast_forward e deletion reforcam.
ruleset gitflow-ambientes branch '["refs/heads/main","refs/heads/qa","refs/heads/hom"]' \
  '[{"type":"update"},{"type":"deletion"},{"type":"non_fast_forward"}]' "$BYPASS_APP"
ruleset gitflow-tags tag \
  '["refs/tags/rc/*","refs/tags/qa.*","refs/tags/hom.*","refs/tags/qa-ok/*","refs/tags/qa-nok/*","refs/tags/hom-ok/*","refs/tags/hom-nok/*","refs/tags/hom-ajuste/*","refs/tags/retirada/*","refs/tags/regressao-ok/*"]' \
  '[{"type":"creation"},{"type":"update"},{"type":"deletion"}]' "$BYPASS_APP"
ruleset gitflow-versoes tag '["refs/tags/v*"]' \
  '[{"type":"creation"},{"type":"update"},{"type":"deletion"}]' "$BYPASS_APP_RM"

# ---------- Secrets do App ----------
nomes=
for p in "$R/actions/secrets?per_page=100" "$R/actions/organization-secrets?per_page=100"; do
  if out=$(chamar GET "$p"); then
    nomes="$nomes
$(printf '%s' "$out" | jq -r '.secrets[]?.name')"
  fi
done
for s in GITFLOW_APP_ID GITFLOW_APP_KEY; do
  if ! printf '%s\n' "$nomes" | grep -Fxq "$s"; then
    info "AVISO: secret $s nao encontrado (repo/organizacao). Veja setup/github-app.md."
  fi
done

info "NOTA: os locks refs/gitflow/lock/* nao podem ser protegidos por ruleset (so branches/tags); quem tem escrita pode apagar um lock. O workflow destravar cobre esse caso."
info "pronto: $REPO configurado."
