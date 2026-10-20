#!/bin/sh
# adapters/deploy/pages.sh: deploy no GitHub Pages (branch gh-pages): qa/, hom/ e a raiz (prd).
# shellcheck disable=SC2015  # A && B || C intencional: C e o tratamento de falha de A e B
# Ambiente: GITHUB_TOKEN, GITHUB_REPOSITORY, GITHUB_SERVER_URL (padrao https://github.com), PAGES_REMOTE (substitui a URL
# do remoto; usado nos testes), URL_QA/URL_HOM/URL_PRD (URL publica de cada ambiente), PAGES_TENTATIVAS (10), PAGES_INTERVALO (15 s).
# O token vai por variaveis de ambiente do git (http.extraHeader), nunca no argv nem na URL do remoto gravada em disco.

_pages_amb() {   # so ambientes conhecidos
  case "$1" in qa|hom|prd) ;; *) echo "ambiente inválido: '$1'" >&2; return 1 ;; esac
}

_pages_remoto() {
  if [ -n "${PAGES_REMOTE:-}" ]; then printf '%s\n' "$PAGES_REMOTE"; return 0; fi
  printf '%s/%s.git\n' "${GITHUB_SERVER_URL:-https://github.com}" "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY não definido}"
}

# _pages_git ARGS... : git com o token so no ambiente do processo filho
_pages_git() {
  (
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      _pg_b=$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\n\r')
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $_pg_b"
      export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
    fi
    GIT_TERMINAL_PROMPT=0
    export GIT_TERMINAL_PROMPT
    exec git -c credential.helper= "$@"
  )
}

deploy_instalar() {   # AMB SHA VERSAO ZIP
  _pages_amb "$1" || return 1
  [ -f "$4" ] || { echo "zip não encontrado: $4" >&2; return 1; }
  _pi_rem=$(_pages_remoto) || return 1
  _pi_t=$(mktemp -d) || return 1
  _pi_w="$_pi_t/w"
  _pi_n="$_pi_t/novo"
  mkdir -p "$_pi_n"
  if ! zip_extrair "$4" "$_pi_n"; then rm -rf "$_pi_t"; return 1; fi
  if [ -e "$_pi_n/.git" ] || { [ "$1" = prd ] && { [ -e "$_pi_n/qa" ] || [ -e "$_pi_n/hom" ]; }; }; then
    rm -rf "$_pi_t"; echo "pacote inválido: contém .git, qa/ ou hom/ na raiz." >&2; return 1
  fi
  # distingue "gh-pages nao existe" (cria orfa) de erro de rede/permissao (falha)
  _pi_rc=0
  _pages_git ls-remote --exit-code --heads "$_pi_rem" gh-pages > /dev/null 2>&1 || _pi_rc=$?
  if [ "$_pi_rc" -eq 0 ]; then
    _pages_git clone -q --branch gh-pages --single-branch "$_pi_rem" "$_pi_w" 2> /dev/null \
      || { rm -rf "$_pi_t"; echo "falha ao clonar gh-pages." >&2; return 1; }
  elif [ "$_pi_rc" -eq 2 ]; then
    git init -q "$_pi_w" && git -C "$_pi_w" checkout -q --orphan gh-pages \
      && git -C "$_pi_w" remote add origin "$_pi_rem" || { rm -rf "$_pi_t"; return 1; }
  else
    rm -rf "$_pi_t"; echo "falha ao consultar o remoto do Pages." >&2; return 1
  fi
  if [ "$1" = prd ]; then   # raiz: apaga tudo menos .git, qa/ e hom/
    for _pi_e in "$_pi_w"/* "$_pi_w"/.[!.]* "$_pi_w"/..?*; do
      [ -e "$_pi_e" ] || continue
      case "${_pi_e##*/}" in .git|qa|hom) continue ;; esac
      rm -rf "$_pi_e"
    done
    cp -R "$_pi_n"/. "$_pi_w"/ || { rm -rf "$_pi_t"; return 1; }
    _pi_v="$_pi_w/version.json"
  else
    rm -rf "${_pi_w:?}/$1"
    mkdir -p "$_pi_w/$1" && cp -R "$_pi_n"/. "$_pi_w/$1"/ || { rm -rf "$_pi_t"; return 1; }
    _pi_v="$_pi_w/$1/version.json"
  fi
  # shellcheck disable=SC2016  # $versao etc. sao variaveis do jq
  jqb -n --arg versao "$3" --arg sha "$2" --arg data "$(date +%FT%T%z)" \
    '{versao: $versao, sha: $sha, data: $data}' > "$_pi_v" || { rm -rf "$_pi_t"; return 1; }
  : > "$_pi_w/.nojekyll"
  if git -C "$_pi_w" add -A \
    && git -C "$_pi_w" -c user.name=gitflow-bot -c "user.email=${BOT_EMAIL:-gitflow-bot@users.noreply.github.com}" \
      -c commit.gpgsign=false commit -q -m "deploy($1): $3 ($2)" \
    && _pages_git -C "$_pi_w" push -q origin gh-pages 2> /dev/null; then
    rm -rf "$_pi_t"
    PAGES_ULTIMO_SHA=$2   # deploy_saude sem SHA explicito confere este
    return 0
  fi
  rm -rf "$_pi_t"
  echo "falha ao publicar em gh-pages." >&2
  return 1
}

# deploy_saude AMB [SHA] : SHA esperado = 2o argumento, senao $SAUDE_SHA, senao o do ultimo deploy_instalar do processo.
# Consulta <URL_AMB>/version.json ate o .sha bater (PAGES_TENTATIVAS x PAGES_INTERVALO s: o Pages demora a publicar).
deploy_saude() {
  _pages_amb "$1" || return 1
  _ps_k="URL_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  _ps_u=$(eval "printf '%s' \"\${$_ps_k:-}\"")
  [ -n "$_ps_u" ] || { echo "URL do ambiente $1 não configurada ($_ps_k)." >&2; return 1; }
  _ps_e=${2:-${SAUDE_SHA:-${PAGES_ULTIMO_SHA:-}}}
  [ -n "$_ps_e" ] || { echo "SHA esperado não informado (2º argumento ou SAUDE_SHA)." >&2; return 1; }
  _ps_n=${PAGES_TENTATIVAS:-10}
  _ps_i=1
  while [ "$_ps_i" -le "$_ps_n" ]; do
    if _ps_v=$(curl -sf "${_ps_u%/}/version.json") \
      && [ "$(printf '%s' "$_ps_v" | jqb -r '.sha // empty' 2> /dev/null)" = "$_ps_e" ]; then
      return 0
    fi
    if [ "$_ps_i" -lt "$_ps_n" ]; then sleep "${PAGES_INTERVALO:-15}"; fi
    _ps_i=$((_ps_i + 1))
  done
  echo "saúde de $1 não confirmada: version.json sem o sha $_ps_e." >&2
  return 1
}
