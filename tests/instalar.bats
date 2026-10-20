load helper

# instalar.sh: copia os arquivos do kit para o repo da aplicacao sem sobrescrever nada.

INST() { sh "$KIT_DIR/instalar.sh" "$@"; }

@test "github em diretorio vazio instala todos os arquivos" {
  D="$BATS_TEST_TMPDIR/app"
  run INST --plataforma github --destino "$D"
  [ "$status" -eq 0 ]
  for f in .github/workflows/gitflow.yml .github/workflows/app-ci.yml \
    .github/pull_request_template.md .gitflow.env scripts/build.sh scripts/test.sh; do
    [ -f "$D/$f" ]
  done
  [ -x "$D/scripts/build.sh" ]
  [ -x "$D/scripts/test.sh" ]
}

@test "segunda execucao nao altera nada e lista o que pulou" {
  D="$BATS_TEST_TMPDIR/app"
  INST --plataforma github --destino "$D" > /dev/null
  echo "# meu" >> "$D/scripts/build.sh"
  ( cd "$D" && find . -type f -exec cksum {} + | sort ) > "$BATS_TEST_TMPDIR/antes"
  run INST --plataforma github --destino "$D"
  [ "$status" -eq 0 ]
  ( cd "$D" && find . -type f -exec cksum {} + | sort ) > "$BATS_TEST_TMPDIR/depois"
  diff "$BATS_TEST_TMPDIR/antes" "$BATS_TEST_TMPDIR/depois"
  assert_output --partial "pulado"
  assert_output --partial "scripts/build.sh"
}

@test "kit-ref e kit-repo entram no uses e nos inputs dos chamadores" {
  D="$BATS_TEST_TMPDIR/app"
  INST --plataforma github --destino "$D" --kit-ref v2.1 --kit-repo acme/kit > /dev/null
  g="$D/.github/workflows/gitflow.yml"
  grep -q 'uses: acme/gitflow-kit' "$g" && return 1
  grep -q 'uses: acme/kit/.github/workflows/gitflow-montar.yml@v2.1' "$g"
  grep -q 'kit-ref: v2.1' "$g"
  grep -q 'kit-repo: acme/kit' "$g"
  grep -q '@v1' "$g" && return 1
  return 0
}

@test "padrao usa tudoemcodigo/gitflow-kit@v1" {
  D="$BATS_TEST_TMPDIR/app"
  INST --plataforma github --destino "$D" > /dev/null
  grep -q 'uses: tudoemcodigo/gitflow-kit/.github/workflows/gitflow-comandos.yml@v1' "$D/.github/workflows/gitflow.yml"
}

@test "workflow instalado continua YAML valido com um with por job" {
  D="$BATS_TEST_TMPDIR/app"
  INST --plataforma github --destino "$D" --kit-ref v3 > /dev/null
  g="$D/.github/workflows/gitflow.yml"
  [ "$(grep -c '^    uses: ' "$g")" = "$(grep -c '^    with:' "$g")" ]
  [ "$(grep -c 'kit-ref: v3' "$g")" = "$(grep -c '^    uses: ' "$g")" ]
}

@test "gitflow.env gerado so tem chaves permitidas e usa --org nas URLs" {
  D="$BATS_TEST_TMPDIR/app"
  INST --plataforma github --destino "$D" --org acme --modo-demo > /dev/null
  e="$D/.gitflow.env"
  grep -q '^MODO_DEMO=sim' "$e"
  grep -q '^GITFLOW_PROVIDER=github' "$e"
  grep -q 'https://acme.github.io/' "$e"
  run env -i PATH="$PATH" KIT_DIR="$KIT_DIR" sh -c "cd '$D' && . '$KIT_DIR/core/lib.sh' && carregar_config && echo ok"
  assert_output "ok"
}

@test "sem modo-demo o env nao liga MODO_DEMO" {
  D="$BATS_TEST_TMPDIR/app"
  INST --plataforma github --destino "$D" > /dev/null
  grep -q '^MODO_DEMO=sim' "$D/.gitflow.env" && return 1
  return 0
}

@test "modelo de app: build copia src para dist e test valida" {
  D="$BATS_TEST_TMPDIR/app"
  INST --plataforma github --destino "$D" > /dev/null
  mkdir -p "$D/src"
  printf '<!doctype html><html><body>oi</body></html>\n' > "$D/src/index.html"
  ( cd "$D" && sh scripts/build.sh && sh scripts/test.sh )
  [ -f "$D/dist/index.html" ]
  rm "$D/dist/index.html"
  run sh -c "cd '$D' && sh scripts/test.sh"
  [ "$status" -ne 0 ]
}

@test "gitlab e jenkins ainda nao estao disponiveis (exit 2, nada criado)" {
  for p in gitlab jenkins; do
    D="$BATS_TEST_TMPDIR/app-$p"
    run INST --plataforma "$p" --destino "$D"
    [ "$status" -eq 2 ]
    assert_output --partial "ainda não disponível nesta versão do kit"
    [ ! -e "$D" ]
  done
}

@test "argumentos invalidos recusam com exit 2" {
  run INST --plataforma github
  [ "$status" -eq 2 ]
  run INST --destino "$BATS_TEST_TMPDIR/x"
  [ "$status" -eq 2 ]
  run INST --plataforma azure --destino "$BATS_TEST_TMPDIR/x"
  [ "$status" -eq 2 ]
}

@test "imprime proximos passos" {
  run INST --plataforma github --destino "$BATS_TEST_TMPDIR/app" --org acme
  assert_output --partial "setup/github.sh --repo"
  assert_output --partial "github-app.md"
}
