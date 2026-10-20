# Helper dos testes bats do kit (bash; sem restrição de POSIX aqui).
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KIT_DIR
export TZ=America/Sao_Paulo

# jq em modo binario: evita CRLF na saida no Windows (Git Bash).
jq() { command jq -b "$@"; }

load "$KIT_DIR/tests/bats/bats-support/load"
load "$KIT_DIR/tests/bats/bats-assert/load"

# Cria $ORIGIN (bare) e $WORK (clone) com commit inicial na main, tag v1.0.0
# e deployment success de prd em v1.0.0. Exporta a configuração do kit.
setup_repo() {
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  WORK="$BATS_TEST_TMPDIR/work"
  FAKE_DIR="$BATS_TEST_TMPDIR/fake"
  export ORIGIN WORK FAKE_DIR
  mkdir -p "$FAKE_DIR"
  git init -q --bare -b main "$ORIGIN"
  git clone -q "$ORIGIN" "$WORK" 2>/dev/null
  git -C "$WORK" config user.name "Teste"
  git -C "$WORK" config user.email "teste@example.com"
  git -C "$WORK" config core.autocrlf false
  git -C "$WORK" config commit.gpgsign false
  git -C "$WORK" config tag.gpgsign false
  git -C "$WORK" checkout -q -B main
  echo inicial > "$WORK/README.md"
  git -C "$WORK" add README.md
  git -C "$WORK" commit -q -m "chore: commit inicial"
  git -C "$WORK" tag -a v1.0.0 -m "v1.0.0"
  git -C "$WORK" push -q origin main v1.0.0
  export GITFLOW_PROVIDER=fake GRUPO_QA=qa GRUPO_NEGOCIO=negocio \
    GRUPO_TL=tech-leads GRUPO_RM=release-managers
  # shellcheck source=/dev/null
  . "$KIT_DIR/adapters/provider/fake.sh"
  local id
  id=$(deploy_iniciar prd v1.0.0 "$(git -C "$WORK" rev-parse HEAD)")
  deploy_concluir "$id" success
}

# nova_branch NOME ARQUIVO: cria a branch a partir da main, commita ARQUIVO e dá push.
nova_branch() {
  git -C "$WORK" checkout -q -B "$1" main
  echo "$1" > "$WORK/$2"
  git -C "$WORK" add "$2"
  git -C "$WORK" commit -q -m "feat: $1"
  git -C "$WORK" push -q origin "$1"
}

# rodar SCRIPT ARGS: executa core/SCRIPT dentro de $WORK com o kit no PATH.
rodar() {
  local s="$1"
  shift
  run env PATH="$KIT_DIR/core:$PATH" sh -c 'cd "$1" && shift && exec "$@"' _ "$WORK" "$KIT_DIR/core/$s" "$@"
}
