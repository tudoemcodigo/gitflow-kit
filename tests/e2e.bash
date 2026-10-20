# Helpers dos cenarios ponta a ponta (historia.bats e provocacoes.bats). Carregado depois do helper.bash.
# Tudo passa pelos scripts reais do core (rodar/esteira); so o provider e o fake e os adaptadores sao pasta.

DESC_OK='## Critério de aceite
Ponto registrado

## Como testar
Abrir a tela e registrar

## Autoteste
- [x] rodei local'

e2e_setup() {
  setup_repo
  fake_membro qa1 qa
  fake_membro neg1 negocio
  fake_membro rm1 release-managers
  fake_membro tl1 tech-leads
  git -C "$WORK" config rerere.enabled false
  export GITFLOW_SAIDA="$BATS_TEST_TMPDIR/saida"
  export ARTEFATOS=pasta ARTEFATOS_DIR="$BATS_TEST_TMPDIR/artefatos"
  export DEPLOY=pasta DEPLOY_DIR="$BATS_TEST_TMPDIR/sites"
  export GITFLOW_RUN_ID=run-1 GITFLOW_LOCK_INTERVALO=1
  mkdir -p "$GITFLOW_SAIDA" "$WORK/scripts"
  printf '%s\n' '#!/bin/sh' 'mkdir -p dist' 'echo "build $(git rev-parse HEAD)" > dist/index.html' > "$WORK/scripts/build.sh"
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$WORK/scripts/test.sh"
  git -C "$WORK" add scripts
  git -C "$WORK" commit -q -m "chore: scripts"
  git -C "$WORK" push -q origin main
  # PRD atual = v1.0.0 (o setup_repo); a release da historia sai como v1.1.0
  fixture_retag_prd
}
# fixture_retag_prd: reposiciona a v1.0.0 (so em fixture de teste) no HEAD da main, para a main ser igual a PRD
fixture_retag_prd() {
  git -C "$WORK" tag -f -a v1.0.0 -m v1.0.0 > /dev/null || return 1
  git -C "$WORK" push -q -f origin refs/tags/v1.0.0
}
# rodar_out SCRIPT ARGS: como rodar, mas devolve so o stdout em $saida; o stderr aparece no teste
rodar_out() {
  local s="$1"
  shift
  saida=$(env PATH="$KIT_DIR/core:$PATH" sh -c 'cd "$1" && shift && exec "$@"' _ "$WORK" sh "$KIT_DIR/core/$s" "$@")
}

# ---------- util ----------
falha() { echo "$*" >&2; return 1; }
igual() { [ "$1" = "$2" ] || falha "esperado [$2] obtido [$1] ($3)"; }
tem_tag() { git -C "$ORIGIN" rev-parse -q --verify "refs/tags/$1" > /dev/null; }
lock_dono() { (cd "$WORK" && sh "$KIT_DIR/core/lock.sh" dono "$1"); }
lock_livre() { [ -z "$(lock_dono "$1")" ]; }
n_tags() { git -C "$ORIGIN" tag -l "$1" | wc -l | tr -d ' '; }

# ---------- dev ----------
# ramo BRANCH IID ARQUIVO CONTEUDO [BASE]: branch a partir de BASE (origin/main), PR aberto com tudo verde
ramo() {
  local br="$1" iid="$2" arq="$3" cont="$4" base="${5:-origin/main}" sha
  git -C "$WORK" fetch -q origin || return 1
  git -C "$WORK" checkout -q -B "$br" "$base" || return 1
  echo "$cont" > "$WORK/$arq" || return 1
  git -C "$WORK" add "$arq" || return 1
  git -C "$WORK" commit -q -m "feat: $br $cont" || return 1
  git -C "$WORK" push -q -f origin "$br" || return 1
  sha=$(git -C "$WORK" rev-parse HEAD) || return 1
  fake_pr "$iid" "$br" dev || return 1
  fake_pipeline "$iid" "$sha" success || return 1
  fake_review "$iid" rev "$sha" || return 1
  fake_descricao "$iid" "$DESC_OK" || return 1
}
# tarefa ID IID [VERSAO_DO_CONTEUDO [BASE]]: feature/ID-tarefa com o arquivo ID.txt
tarefa() { ramo "feature/$1-tarefa" "$2" "$1.txt" "$1 v${3:-1}" "${4:-origin/main}"; }
# entregar IID [NOTA]: /entregar (criar-rc) pelo dev
entregar() {
  AUTOR=dev MR_IID="$1" NOTA="${2:-}" rodar criar-rc.sh
  [ "$status" -eq 0 ] || { falha "entregar !$1: $output"; return 1; }
}
# dec USUARIO IID "/comando motivo"
dec() {
  AUTOR="$1" MR_IID="$2" NOTA="$3" rodar decidir.sh
  [ "$status" -eq 0 ] || { falha "$3 (!$2) por $1: $output"; return 1; }
}

# ---------- montagem + esteira ----------
# esteira AMB TAG [ETAPAS...]: as etapas da esteira (padrao: todas), parando na primeira que falhar
esteira() {
  local amb="$1" tag="$2" e etapas
  shift 2
  etapas="${*:-preparar construir testar publicar-pacote gates implantar verificar-auto registrar}"
  for e in $etapas; do
    TAG="$tag" AMBIENTE="$amb" rodar esteira.sh "$e"
    [ "$status" -eq 0 ] || { falha "esteira $amb $tag etapa $e: $output"; return 1; }
  done
}
# montar ALVO: fluxo-montar.sh (manual por padrao: QUEM=qa1; QUEM=timer = agendada). Define MTAG ("" = nada)
montar() {
  BUILD_USER_ID="${QUEM:-qa1}" rodar fluxo-montar.sh "$1"
  [ "$status" -eq 0 ] || { falha "montar $1: $output"; return 1; }
  MTAG=$(cat "$GITFLOW_SAIDA/montagem.tag")
}
amb_de() { case "$1" in qa | hotfix) echo qa ;; *) echo hom ;; esac; }
# montar_publicar ALVO: monta e, se houve build, passa pela esteira ate registrar
montar_publicar() {
  montar "$1" || return 1
  if [ -n "$MTAG" ]; then esteira "$(amb_de "$1")" "$MTAG"; fi
}

# ---------- o que esta publicado ----------
# manifesto_amb AMB: entregas (rc/...) da build publicada em origin/AMB, ordenadas, numa linha
manifesto_amb() {
  local sha tag
  sha=$(git -C "$ORIGIN" rev-parse "refs/heads/$1")
  tag=$(git -C "$ORIGIN" tag --points-at "$sha" -l "$1.*" | head -1)
  git -C "$ORIGIN" tag -l --format='%(contents:body)' "$tag" | awk '$1 ~ /^rc\// {print $1}' | sort | tr '\n' ' ' | sed 's/ $//'
}
# arvore_tem AMB ARQUIVO: o arquivo existe na branch publicada (o codigo realmente entrou)
arvore_tem() { git -C "$ORIGIN" cat-file -e "refs/heads/$1:$2" 2> /dev/null; }
prd_atual() { (cd "$WORK" && deploy_ultimo_ok prd); }

# ---------- caminhos longos reutilizados ----------
# aprovar_ate_hom ID IID: tarefa, entrega, QA monta, QA aprova, HOM monta, negocio homologa
aprovar_ate_hom() {
  tarefa "$1" "$2" || return 1
  entregar "$2" || return 1
  montar_publicar qa || return 1
  dec qa1 "$2" "/aprovar" || return 1
  montar_publicar hom || return 1
  dec neg1 "$2" "/homologar" || return 1
}
# release_ate_tag VERSAO ISSUE: RM monta a release, QA registra a regressao, RM cria a vX.Y.Z. Define RHOM.
release_ate_tag() {
  VERSAO="$1" QUEM=rm1 montar_publicar release || return 1
  [ -n "$MTAG" ] || { falha "a montagem da release nao gerou build"; return 1; }
  RHOM="$MTAG"
  BUILD_USER_ID=qa1 rodar regressao.sh "$RHOM" ok "$2"
  [ "$status" -eq 0 ] || { falha "regressao: $output"; return 1; }
  BUILD_USER_ID=rm1 rodar criar-release.sh "$1" "$RHOM" "$2"
  [ "$status" -eq 0 ] || { falha "criar-release: $output"; return 1; }
}
# hotfix_ate_prd X.Y.Z IID ARQUIVO CONTEUDO: hotfix completo ate PRD (QA, aprovacao, HOM, homologacao, regressao, release)
hotfix_ate_prd() {
  local ver="$1" iid="$2" id
  id="hotfix-$(echo "$ver" | tr . -)"
  ramo "hotfix/$ver" "$iid" "$3" "$4" || return 1
  entregar "$iid" || return 1
  HOTFIX="$ver" QUEM=rm1 montar_publicar hotfix || return 1
  dec qa1 "$iid" "/aprovar" || return 1
  [ -n "$MTAG" ] || { falha "a montagem do hotfix nao gerou build"; return 1; }
  BUILD_USER_ID=rm1 rodar_out promover-hotfix.sh "$MTAG" || { falha "promover-hotfix falhou"; return 1; }
  RHOM="$saida"
  esteira hom "$RHOM" || return 1
  dec neg1 "$iid" "/homologar" || return 1
  BUILD_USER_ID=qa1 rodar regressao.sh "$RHOM" ok 1
  [ "$status" -eq 0 ] || { falha "regressao: $output"; return 1; }
  BUILD_USER_ID=rm1 rodar criar-release.sh "$ver" "$RHOM" 1
  [ "$status" -eq 0 ] || { falha "criar-release: $output"; return 1; }
  esteira prd "v$ver" || return 1
}
# hook_recusa_ref PADRAO: o origin recusa o push de refs que casam com o padrao
hook_recusa_ref() {
  printf '%s\n' '#!/bin/sh' 'while read -r _o _n ref; do' "  case \"\$ref\" in $1) echo recusado >&2; exit 1 ;; esac" 'done' > "$ORIGIN/hooks/pre-receive"
  chmod +x "$ORIGIN/hooks/pre-receive"
}
