#!/bin/sh
# shellcheck disable=SC2016  # $var dentro de filtros jq nao e expansao de shell
# Provider FAKE: implementa o contrato §3.2 com estado em arquivos JSON.
# Carregado com `.` pelo core e pelos testes. Requer FAKE_DIR e jq.

# jq em modo binario: no Windows (Git Bash) o jq emitiria CRLF e quebraria comparacoes.
_fjq() { command jq -b "$@"; }

_fake_init() {
  : "${FAKE_DIR:?FAKE_DIR nao definido}"
  mkdir -p "$FAKE_DIR/pr"
  [ -f "$FAKE_DIR/deployments.json" ] || echo '[]' > "$FAKE_DIR/deployments.json"
  [ -f "$FAKE_DIR/membros.json" ] || echo '[]' > "$FAKE_DIR/membros.json"
  [ -f "$FAKE_DIR/releases.json" ] || echo '[]' > "$FAKE_DIR/releases.json"
}

# _fake_jq ARQUIVO ARGS_JQ... FILTRO : reescreve ARQUIVO com o resultado do filtro.
_fake_jq() {
  _fj_arq="$1"
  shift
  _fjq "$@" "$_fj_arq" > "$_fj_arq.tmp" && mv "$_fj_arq.tmp" "$_fj_arq"
}

_fake_prf() { printf '%s/pr/%s.json' "$FAKE_DIR" "$1"; }

# ---------- helpers só de teste ----------

# fake_pr IID BRANCH AUTOR [draft]
fake_pr() {
  _fake_init
  _fp_draft=false
  [ "${4:-}" = "draft" ] && _fp_draft=true
  _fp_sha=$(git -C "${WORK:-.}" rev-parse -q --verify "origin/$2" 2>/dev/null || git -C "${WORK:-.}" rev-parse -q --verify "$2" 2>/dev/null || echo "sha$1")
  _fjq -n --argjson iid "$1" --arg src "$2" --arg autor "$3" \
    --argjson draft "$_fp_draft" --arg sha "$_fp_sha" \
    '{iid:$iid, source_branch:$src, target_branch:"main", draft:$draft, sha:$sha,
      author:$autor, description:"", labels:[], pipeline_sha:"", pipeline_status:"",
      state:"opened", comments:[], reviews:[]}' > "$(_fake_prf "$1")"
}

# fake_pipeline IID SHA STATUS
fake_pipeline() {
  _fake_jq "$(_fake_prf "$1")" --arg sha "$2" --arg st "$3" \
    '.pipeline_sha=$sha | .pipeline_status=$st'
}

# fake_review IID USUARIO SHA
fake_review() {
  _fake_jq "$(_fake_prf "$1")" --arg u "$2" --arg sha "$3" \
    '.reviews += [{user:$u, sha:$sha}]'
}

# fake_membro USUARIO GRUPO
fake_membro() {
  _fake_init
  _fake_jq "$FAKE_DIR/membros.json" --arg u "$1" --arg g "$2" \
    '. += [{user:$u, group:$g}]'
}

# fake_descricao IID TEXTO
fake_descricao() {
  _fake_jq "$(_fake_prf "$1")" --arg t "$2" '.description=$t'
}

# fake_comentarios IID : imprime os comentários, um por linha de saída (separados por quebra)
fake_comentarios() {
  _fjq -r '.comments[]' "$(_fake_prf "$1")"
}

# fake_labels IID : imprime csv
fake_labels() {
  _fjq -r '.labels | join(",")' "$(_fake_prf "$1")"
}

# ---------- contrato §3.2 ----------

# pr_get IID
pr_get() {
  _fjq 'del(.comments, .reviews)' "$(_fake_prf "$1")"
}

# pr_listar_abertos : linhas "iid branch labels_csv"
pr_listar_abertos() {
  _fake_init
  for _pl_f in "$FAKE_DIR"/pr/*.json; do
    [ -f "$_pl_f" ] || continue
    _fjq -r 'select(.state=="opened" and .target_branch=="main")
           | "\(.iid) \(.source_branch) \(.labels | join(","))"' "$_pl_f"
  done | sort -n
}

# pr_comentar IID TEXTO
pr_comentar() {
  _fake_jq "$(_fake_prf "$1")" --arg t "$2" '.comments += [$t]'
}

# pr_rotular IID ADD REMOVE (listas csv)
pr_rotular() {
  _fake_jq "$(_fake_prf "$1")" --arg add "$2" --arg rem "$3" '
    ($add | split(",") | map(select(. != ""))) as $a
    | ($rem | split(",") | map(select(. != ""))) as $r
    | .labels = ((.labels - $r) + $a | unique)'
}

# pr_fechar IID
pr_fechar() {
  _fake_jq "$(_fake_prf "$1")" '.state="closed"'
}

# branch_apagar NOME
branch_apagar() {
  _fake_init
  printf '%s\n' "$1" >> "$FAKE_DIR/branches_apagadas.txt"
  if [ -n "${ORIGIN:-}" ] && [ -d "$ORIGIN" ]; then
    git --git-dir="$ORIGIN" update-ref -d "refs/heads/$1" 2>/dev/null || true
  fi
}

# aprovado_por_outro IID SHA AUTOR
aprovado_por_outro() {
  _fjq -e --arg sha "$2" --arg autor "$3" \
    '[.reviews[] | select(.sha == $sha and .user != $autor)] | length > 0' \
    "$(_fake_prf "$1")" > /dev/null
}

# membro USUARIO GRUPO...
membro() {
  _fake_init
  _m_user="$1"
  shift
  _m_grupos=$(printf '%s\n' "$@" | _fjq -R . | _fjq -s .)
  _fjq -e --arg u "$_m_user" --argjson g "$_m_grupos" \
    'any(.[]; .user == $u and (.group as $x | $g | index($x) != null))' \
    "$FAKE_DIR/membros.json" > /dev/null
}

# deploy_iniciar AMB REF SHA -> id
deploy_iniciar() {
  _fake_init
  _di_id=$(_fjq 'map(.id) | (max // 0) + 1' "$FAKE_DIR/deployments.json")
  _fake_jq "$FAKE_DIR/deployments.json" --argjson id "$_di_id" \
    --arg amb "$1" --arg ref "$2" --arg sha "$3" \
    '. += [{id:$id, env:$amb, ref:$ref, sha:$sha, status:"running"}]'
  printf '%s\n' "$_di_id"
}

# deploy_concluir ID STATUS (running|success|failed)
deploy_concluir() {
  _fake_jq "$FAKE_DIR/deployments.json" --argjson id "$1" --arg st "$2" \
    'map(if .id == $id then .status = $st else . end)'
}

# deploy_ultimo AMB -> "ref status"
deploy_ultimo() {
  _fake_init
  _fjq -r --arg amb "$1" \
    '[.[] | select(.env == $amb)] | last // empty | "\(.ref) \(.status)"' \
    "$FAKE_DIR/deployments.json"
}

# deploy_ultimo_ok AMB -> ref
deploy_ultimo_ok() {
  _fake_init
  _fjq -r --arg amb "$1" \
    '[.[] | select(.env == $amb and .status == "success")] | last // empty | .ref' \
    "$FAKE_DIR/deployments.json"
}

# deploy_ok_anterior AMB REF -> ref do último success de AMB criado antes do deploy de REF
deploy_ok_anterior() {
  _fake_init
  _fjq -r --arg amb "$1" --arg ref "$2" '
    ([.[] | select(.env == $amb and .ref == $ref)] | last // empty | .id) as $id
    | [.[] | select(.env == $amb and .status == "success" and .id < $id)]
    | last // empty | .ref' "$FAKE_DIR/deployments.json"
}

# release_criar TAG TEXTO : idempotente (release já existente para a TAG = sucesso, sem duplicar)
release_criar() {
  _fake_init
  if _fjq -e --arg tag "$1" 'any(.[]; .tag == $tag)' "$FAKE_DIR/releases.json" > /dev/null; then
    return 0
  fi
  _fake_jq "$FAKE_DIR/releases.json" --arg tag "$1" --arg t "$2" \
    '. += [{tag:$tag, texto:$t}]'
}
