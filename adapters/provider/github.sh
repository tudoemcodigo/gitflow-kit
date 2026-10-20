#!/bin/sh
# shellcheck disable=SC2329  # helpers usados pelos adaptadores carregados depois do provider
# shellcheck disable=SC2016  # $var dentro de filtros jq nao e expansao de shell
# Provider GITHUB: implementa o contrato §3.2 via REST v3. Carregado com `.` pelo core.
# Ambiente: GITHUB_TOKEN, GITHUB_REPOSITORY (dono/repo), GITHUB_API_URL (padrao https://api.github.com).
# Grupos de `membro` = slug de Team da organizacao (dono de GITHUB_REPOSITORY). AMB `prd` = environment `production`.
#
# Camada HTTP (unica que fala com a rede; os testes a substituem):
#   gh_api METODO CAMINHO [JSON] : corpo na saida padrao. Retorno: 0 = 2xx; 44 = 404; 42 = 422; 1 = outro erro.
#   gh_paginar CAMINHO            : GET seguindo `Link: rel="next"`; imprime o corpo de cada pagina (uma apos a outra).
# Fixtures dos testes: tests/fixtures/github/<METODO>_<caminho-sanitizado>.json, onde caminho-sanitizado = CAMINHO sem
# a "/" inicial e com cada "/", "?", "&" e "=" trocado por "_". Paginas extras do gh_paginar: <nome>.p2.json, .p3.json...
# Contrato (notas): release_criar e idempotente; "ultimo status" de um deployment = primeiro de /statuses que nao seja
# `inactive` (o GitHub marca assim deployments substituidos por um mais novo); deployment sem status = running;
# deploy_ultimo_ok/deploy_ok_anterior paginam todos os deployments do ambiente.

# shellcheck disable=SC2034  # lido pelo core (mensagens ao usuario)
TERMO_PR=PR

# jq em modo binario: no Windows (Git Bash) o jq emitiria CRLF e quebraria comparacoes.
_gjq() { command jq -b "$@"; }

# URL base da API, sem "/" final
_gh_base() { _gb=${GITHUB_API_URL:-https://api.github.com}; printf '%s' "${_gb%/}"; }

_gh_r() { printf '/repos/%s' "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY nao definido}"; }

# codifica um valor para uso em caminho de URL (preserva "/")
_gh_enc() { printf '%s' "$1" | _gjq -sRr '@uri' | sed 's/%2F/\//g'; }

# ambiente do kit -> environment do GitHub
_gh_amb() { if [ "$1" = prd ]; then printf production; else printf '%s' "$1"; fi; }

gh_api() {
  _ga_m=$1
  _ga_p=$2
  _ga_b=${3:-}
  : "${GITHUB_TOKEN:?GITHUB_TOKEN nao definido}"
  _ga_url="$(_gh_base)$_ga_p"
  _ga_out=$(mktemp) || return 1
  # o token vai em arquivo (modo 600), nunca no argv do curl (visivel em ps//proc)
  _ga_auth=$(mktemp) || { rm -f "$_ga_out"; return 1; }
  ( umask 077; printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN" > "$_ga_auth" )
  set -- -sS -X "$_ga_m" -o "$_ga_out" -w '%{http_code}' \
    -H "@$_ga_auth" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28'
  if [ -n "${GH_HDR_FILE:-}" ]; then set -- "$@" -D "$GH_HDR_FILE"; fi
  if [ -n "$_ga_b" ]; then
    set -- "$@" -H 'Content-Type: application/json' --data-binary @-
    _ga_code=$(printf '%s' "$_ga_b" | curl "$@" "$_ga_url") || true
  else
    _ga_code=$(curl "$@" "$_ga_url" < /dev/null) || true
  fi
  cat "$_ga_out"
  rm -f "$_ga_out" "$_ga_auth"
  case "$_ga_code" in
    2??) return 0 ;;
    404) return 44 ;;
    422) return 42 ;;
    *) printf 'gh_api: HTTP %s em %s %s\n' "${_ga_code:-000}" "$_ga_m" "$_ga_p" >&2; return 1 ;;
  esac
}

# caminho da proxima pagina (sem o prefixo da API) a partir do arquivo de cabecalhos; vazio se nao ha
_gh_proximo() {
  _gx=$(tr -d '\015' < "$1" | grep -i '^link:' | tr ',' '\n' | grep 'rel="next"' \
    | sed -n 's/.*<\([^>]*\)>.*/\1/p' | head -n 1)
  printf '%s' "${_gx#"$(_gh_base)"}"
}

gh_paginar() {
  _gp_p=$1
  _gp_h=$(mktemp) || return 1
  while [ -n "$_gp_p" ]; do
    GH_HDR_FILE=$_gp_h
    gh_api GET "$_gp_p" || { _gp_rc=$?; unset GH_HDR_FILE; rm -f "$_gp_h"; return "$_gp_rc"; }
    unset GH_HDR_FILE
    printf '\n'
    _gp_p=$(_gh_proximo "$_gp_h")
  done
  rm -f "$_gp_h"
}

# _gh_pipeline SHA -> success|failed|running|none (check-runs, exceto os `gitflow*`, + status combinado)
_gh_pipeline() {
  _gpl_r=$(_gh_r)
  _gpl_c=$(gh_paginar "$_gpl_r/commits/$1/check-runs?per_page=100") || return 1
  _gpl_s=$(gh_api GET "$_gpl_r/commits/$1/status") || return 1
  _gpl_st=$(printf '%s' "$_gpl_s" | _gjq -c '{n: (.statuses | length), s: .state}') || return 1
  printf '%s' "$_gpl_c" | _gjq -s -r --argjson st "$_gpl_st" '
    def ok: . == "success" or . == "skipped" or . == "neutral";
    [.[].check_runs[]? | select(.name | startswith("gitflow") | not)] as $c
    | if ($c | length) == 0 and $st.n == 0 then "none"
      elif any($c[]; .status != "completed") or ($st.n > 0 and $st.s == "pending") then "running"
      elif any($c[]; (.conclusion | ok) | not) or ($st.n > 0 and ($st.s == "failure" or $st.s == "error")) then "failed"
      else "success" end'
}

# ---------- contrato §3.2 ----------

# pr_get IID
pr_get() {
  _pg_r=$(_gh_r)
  _pg_pr=$(gh_api GET "$_pg_r/pulls/$1") || return 1
  _pg_sha=$(printf '%s' "$_pg_pr" | _gjq -r .head.sha) || return 1
  _pg_st=$(_gh_pipeline "$_pg_sha") || return 1
  printf '%s' "$_pg_pr" | _gjq --arg ps "$_pg_st" '
    {iid: .number, source_branch: .head.ref, target_branch: .base.ref, draft: (.draft // false),
     sha: .head.sha, author: .user.login, description: (.body // ""), labels: [.labels[].name],
     pipeline_sha: (if $ps == "none" then "" else .head.sha end), pipeline_status: $ps,
     state: (if .merged_at != null or .merged == true then "merged"
             elif .state == "closed" then "closed" else "opened" end)}'
}

# pr_listar_abertos : linhas "iid branch labels_csv" (PRs abertos para a main, todas as paginas, ordem numerica)
pr_listar_abertos() {
  _pl_r=$(_gh_r)
  _pl_d=$(gh_paginar "$_pl_r/pulls?state=open&base=main&per_page=100") || return 1
  printf '%s' "$_pl_d" | _gjq -s -r '[.[][]] | sort_by(.number)[]
    | "\(.number) \(.head.ref) \([.labels[].name] | join(","))"'
}

# pr_comentarios IID : texto puro dos comentarios do PR
pr_comentarios() {
  _pc_r=$(_gh_r)
  _pc_d=$(gh_paginar "$_pc_r/issues/$1/comments?per_page=100") || return 1
  printf '%s' "$_pc_d" | _gjq -s -r '.[][] | .body'
}

# _gh_comentar NUM TEXTO (PR e issue compartilham /issues/{n}/comments)
_gh_comentar() {
  _gc_b=$(_gjq -nc --arg t "$2" '{body: $t}') || return 1
  gh_api POST "$(_gh_r)/issues/$1/comments" "$_gc_b" > /dev/null
}

# pr_comentar IID TEXTO
pr_comentar() { _gh_comentar "$1" "$2"; }

# issue_comentar NUM TEXTO
issue_comentar() { _gh_comentar "$1" "$2"; }

# pr_rotular IID ADD REMOVE (listas csv; remover rotulo ausente nao e erro)
pr_rotular() {
  _pr_r=$(_gh_r)
  _pr_rem=$(printf '%s\n' "$3" | _gjq -R -r 'split(",") | map(select(. != "")) | .[] | @uri') || return 1
  _pr_add=$(printf '%s\n' "$2" | _gjq -R -c 'split(",") | map(select(. != ""))') || return 1
  while IFS= read -r _pr_l; do
    [ -n "$_pr_l" ] || continue
    gh_api DELETE "$_pr_r/issues/$1/labels/$_pr_l" > /dev/null || [ $? -eq 44 ] || return 1
  done << EOF
$_pr_rem
EOF
  if [ "$_pr_add" != '[]' ]; then
    _pr_b=$(_gjq -nc --argjson l "$_pr_add" '{labels: $l}') || return 1
    gh_api POST "$_pr_r/issues/$1/labels" "$_pr_b" > /dev/null || return 1
  fi
}

# pr_fechar IID
pr_fechar() {
  gh_api PATCH "$(_gh_r)/pulls/$1" '{"state":"closed"}' > /dev/null
}

# branch_apagar NOME : branch inexistente = sucesso (404, ou 422 "Reference does not exist")
branch_apagar() {
  _ba_o=$(gh_api DELETE "$(_gh_r)/git/refs/heads/$(_gh_enc "$1")") && return 0
  _ba_rc=$?
  [ "$_ba_rc" -ne 44 ] || return 0
  [ "$_ba_rc" -eq 42 ] && printf '%s' "$_ba_o" | grep -qi 'reference does not exist'
}

# aprovado_por_outro IID SHA AUTOR : vale a ultima revisao decisiva de cada pessoa (APPROVED/CHANGES_REQUESTED/DISMISSED)
aprovado_por_outro() {
  _ap_d=$(gh_paginar "$(_gh_r)/pulls/$1/reviews?per_page=100") || return 2
  printf '%s' "$_ap_d" | _gjq -s -e --arg sha "$2" --arg autor "$3" '
    [.[][] | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED")]
    | group_by(.user.login) | map(last)
    | any(.[]; .state == "APPROVED" and .commit_id == $sha and .user.login != $autor)' > /dev/null
}

# membro USUARIO GRUPO... : 0 = membro ativo de algum Team; 1 = nao e; 2 = erro (nem 404 nem resposta valida)
membro() {
  _m_user=$1
  shift
  _m_org=${GITHUB_REPOSITORY%%/*}
  _m_erro=0
  for _m_g in "$@"; do
    if _m_d=$(gh_api GET "/orgs/$_m_org/teams/$(_gh_enc "$_m_g")/memberships/$(_gh_enc "$_m_user")"); then
      if printf '%s' "$_m_d" | _gjq -e '.state == "active"' > /dev/null; then return 0; fi
    else
      [ $? -eq 44 ] || _m_erro=1
    fi
  done
  if [ "$_m_erro" -eq 1 ]; then return 2; fi
  return 1
}

# _gh_status_dep ID -> running|success|failed (primeiro status que nao seja inactive; sem status = running)
_gh_status_dep() {
  _gs_d=$(gh_api GET "$(_gh_r)/deployments/$1/statuses?per_page=10") || return 1
  printf '%s' "$_gs_d" | _gjq -r '[.[] | select(.state != "inactive")] | (.[0].state // "pending")
    | if . == "success" then "success" elif . == "failure" or . == "error" then "failed" else "running" end'
}

# deploy_iniciar AMB REF SHA -> id (REF = nome da tag)
deploy_iniciar() {
  _di_env=$(_gh_amb "$1")
  _di_b=$(_gjq -nc --arg ref "$2" --arg env "$_di_env" --arg sha "$3" '
    {ref: $ref, environment: $env, auto_merge: false, required_contexts: [], transient_environment: false,
     production_environment: ($env == "production"), description: ("gitflow " + $sha)}') || return 1
  _di_d=$(gh_api POST "$(_gh_r)/deployments" "$_di_b") || return 1
  printf '%s' "$_di_d" | _gjq -r '.id'
}

# deploy_concluir ID STATUS (running|success|failed)
deploy_concluir() {
  case "$2" in
    running) _dc_st=in_progress ;;
    success) _dc_st=success ;;
    failed) _dc_st=failure ;;
    *) printf 'deploy_concluir: status invalido: %s\n' "$2" >&2; return 1 ;;
  esac
  _dc_b=$(_gjq -nc --arg s "$_dc_st" '{state: $s}') || return 1
  gh_api POST "$(_gh_r)/deployments/$1/statuses" "$_dc_b" > /dev/null
}

# deploy_ultimo AMB -> "ref status"
deploy_ultimo() {
  _du_d=$(gh_api GET "$(_gh_r)/deployments?environment=$(_gh_amb "$1")&per_page=1") || return 1
  _du_id=$(printf '%s' "$_du_d" | _gjq -r '.[0].id // empty') || return 1
  [ -n "$_du_id" ] || return 0
  _du_ref=$(printf '%s' "$_du_d" | _gjq -r '.[0].ref') || return 1
  _du_st=$(_gh_status_dep "$_du_id") || return 1
  printf '%s %s\n' "$_du_ref" "$_du_st"
}

# _gh_deploys AMB : deployments do ambiente (mais novo primeiro; todas as paginas, um array JSON)
_gh_deploys() {
  _gd_d=$(gh_paginar "$(_gh_r)/deployments?environment=$(_gh_amb "$1")&per_page=100") || return 1
  printf '%s' "$_gd_d" | _gjq -s -c '[.[][]]'
}

# _gh_primeiro_ok : le linhas "id ref" (mais novo primeiro) e imprime o ref do primeiro cujo status e success
_gh_primeiro_ok() {
  while read -r _po_id _po_ref; do
    [ -n "$_po_id" ] || continue
    _po_st=$(_gh_status_dep "$_po_id") || return 1
    if [ "$_po_st" = success ]; then
      printf '%s\n' "$_po_ref"
      return 0
    fi
  done
}

# deploy_ultimo_ok AMB -> ref do deployment mais recente cujo ultimo status e success
deploy_ultimo_ok() {
  _uo_d=$(_gh_deploys "$1") || return 1
  _uo_l=$(printf '%s' "$_uo_d" | _gjq -r '.[] | "\(.id) \(.ref)"') || return 1
  _gh_primeiro_ok << EOF
$_uo_l
EOF
}

# deploy_ok_anterior AMB REF -> ref do ultimo success de AMB criado antes do deploy de REF
deploy_ok_anterior() {
  _oa_d=$(_gh_deploys "$1") || return 1
  _oa_l=$(printf '%s' "$_oa_d" | _gjq -r --arg ref "$2" '
    ([.[] | select(.ref == $ref)] | first | .id) as $id
    | if $id == null then empty else .[] | select(.id < $id) | "\(.id) \(.ref)" end') || return 1
  _gh_primeiro_ok << EOF
$_oa_l
EOF
}

# release_criar TAG TEXTO : idempotente (release ja existente para a TAG = sucesso)
release_criar() {
  _rc_r=$(_gh_r)
  _rc_t=$(_gh_enc "$1")
  gh_api GET "$_rc_r/releases/tags/$_rc_t" > /dev/null && return 0
  [ $? -eq 44 ] || return 1
  _rc_b=$(_gjq -nc --arg tag "$1" --arg t "$2" '{tag_name: $tag, name: $tag, body: $t}') || return 1
  gh_api POST "$_rc_r/releases" "$_rc_b" > /dev/null || {
    _rc_rc=$?
    # corrida: outra execucao criou entre a checagem e o POST
    [ "$_rc_rc" -eq 42 ] && gh_api GET "$_rc_r/releases/tags/$_rc_t" > /dev/null
  }
}

# ---------- transferencia de arquivos (assets de release) ----------

# URL base de uploads, derivada de GITHUB_API_URL: api.github.com -> uploads.github.com; GHES <host>/api/v3 -> <host>/api/uploads
_gh_uploads_base() {
  _gu_b=$(_gh_base)
  case "$_gu_b" in
    https://api.github.com) printf 'https://uploads.github.com' ;;
    */api/v3) printf '%s/api/uploads' "${_gu_b%/api/v3}" ;;
    *) printf '%s' "$_gu_b" ;;
  esac
}

# _gh_curl_arq METODO URL SAIDA ARQ_CORPO_OU_VAZIO CONTENT_TYPE ACCEPT : curl com o token em arquivo (nunca no argv);
# imprime o codigo HTTP; o corpo da resposta vai para SAIDA
_gh_curl_arq() {
  : "${GITHUB_TOKEN:?GITHUB_TOKEN nao definido}"
  _gc_auth=$(mktemp) || return 1
  ( umask 077; printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN" > "$_gc_auth" )
  set -- -sS -L -X "$1" -o "$3" -w '%{http_code}' -H "@$_gc_auth" -H "Accept: $6" \
    -H 'X-GitHub-Api-Version: 2022-11-28' ${4:+-H "Content-Type: $5" --data-binary "@$4"} "$2"
  curl "$@" < /dev/null || true
  rm -f "$_gc_auth"
}

_gh_codigo() {   # CODIGO METODO CAMINHO -> mesmo mapeamento do gh_api
  case "$1" in
    2??) return 0 ;;
    404) return 44 ;;
    422) return 42 ;;
    *) printf 'gh_api: HTTP %s em %s %s\n' "${1:-000}" "$2" "$3" >&2; return 1 ;;
  esac
}

# gh_upload CAMINHO_UPLOAD ARQUIVO CONTENT_TYPE : POST do arquivo em <uploads>CAMINHO_UPLOAD; resposta na saida padrao
gh_upload() {
  _gup_out=$(mktemp) || return 1
  _gup_code=$(_gh_curl_arq POST "$(_gh_uploads_base)$1" "$_gup_out" "$2" "$3" 'application/vnd.github+json') || true
  cat "$_gup_out"
  rm -f "$_gup_out"
  _gh_codigo "$_gup_code" POST "$1"
}

# gh_baixar CAMINHO DESTINO : GET binario (Accept: application/octet-stream) gravado em DESTINO
gh_baixar() {
  _gb_code=$(_gh_curl_arq GET "$(_gh_base)$1" "$2" '' '' 'application/octet-stream') || true
  _gh_codigo "$_gb_code" GET "$1" || { _gb_rc=$?; rm -f "$2"; return "$_gb_rc"; }
}

# ---------- transferencia de arquivos (assets de release) ----------

# URL base de uploads, derivada de GITHUB_API_URL: api.github.com -> uploads.github.com; GHES <host>/api/v3 -> <host>/api/uploads
_gh_uploads_base() {
  _gu_b=$(_gh_base)
  case "$_gu_b" in
    https://api.github.com) printf 'https://uploads.github.com' ;;
    */api/v3) printf '%s/api/uploads' "${_gu_b%/api/v3}" ;;
    *) printf '%s' "$_gu_b" ;;
  esac
}

# _gh_curl_arq METODO URL SAIDA ARQ_CORPO_OU_VAZIO CONTENT_TYPE ACCEPT : curl com o token em arquivo (nunca no argv);
# imprime o codigo HTTP; o corpo da resposta vai para SAIDA
_gh_curl_arq() {
  : "${GITHUB_TOKEN:?GITHUB_TOKEN nao definido}"
  _gc_auth=$(mktemp) || return 1
  ( umask 077; printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN" > "$_gc_auth" )
  set -- -sS -L -X "$1" -o "$3" -w '%{http_code}' -H "@$_gc_auth" -H "Accept: $6" \
    -H 'X-GitHub-Api-Version: 2022-11-28' ${4:+-H "Content-Type: $5" --data-binary "@$4"} "$2"
  curl "$@" < /dev/null || true
  rm -f "$_gc_auth"
}

_gh_codigo() {   # CODIGO METODO CAMINHO -> mesmo mapeamento do gh_api
  case "$1" in
    2??) return 0 ;;
    404) return 44 ;;
    422) return 42 ;;
    *) printf 'gh_api: HTTP %s em %s %s\n' "${1:-000}" "$2" "$3" >&2; return 1 ;;
  esac
}

# gh_upload CAMINHO_UPLOAD ARQUIVO CONTENT_TYPE : POST do arquivo em <uploads>CAMINHO_UPLOAD; resposta na saida padrao
gh_upload() {
  _gup_out=$(mktemp) || return 1
  _gup_code=$(_gh_curl_arq POST "$(_gh_uploads_base)$1" "$_gup_out" "$2" "$3" 'application/vnd.github+json') || true
  cat "$_gup_out"
  rm -f "$_gup_out"
  _gh_codigo "$_gup_code" POST "$1"
}

# gh_baixar CAMINHO DESTINO : GET binario (Accept: application/octet-stream) gravado em DESTINO
gh_baixar() {
  _gb_code=$(_gh_curl_arq GET "$(_gh_base)$1" "$2" '' '' 'application/octet-stream') || true
  _gh_codigo "$_gb_code" GET "$1" || { _gb_rc=$?; rm -f "$2"; return "$_gb_rc"; }
}
