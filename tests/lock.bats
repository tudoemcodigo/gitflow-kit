load helper

setup() { setup_repo; export GITFLOW_LOCK_INTERVALO=1; }

L() { # RUN_ID args...
  local id="$1"; shift
  GITFLOW_RUN_ID="$id" GITFLOW_RUN_URL="http://ci/$id" sh -c 'cd "$1" && shift && exec "$@"' _ "$WORK" "$KIT_DIR/core/lock.sh" "$@"
}
tem_ref() { git -C "$ORIGIN" rev-parse -q --verify "refs/gitflow/lock/$1" > /dev/null; }

@test "pegar duas vezes: segunda fica ocupada e mostra o dono" {
  run L 1 pegar deploy
  assert_success
  run L 2 pegar deploy
  assert_equal "$status" 75
  assert_output --partial "run=1"
}

@test "dono imprime a linha do dono; vazio se livre" {
  run L 1 dono deploy
  assert_success
  assert_output ""
  L 1 pegar deploy
  run L 2 dono deploy
  assert_output --regexp '^run=1 url=http://ci/1 desde=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$'
}

@test "corrida: 5 pegar em paralelo, exatamente um vence" {
  pids=""
  for i in 1 2 3 4 5; do
    L "r$i" pegar corrida > "$BATS_TEST_TMPDIR/out$i" 2>&1 &
    pids="$pids $!"
  done
  ok=0; busy=0
  for p in $pids; do
    s=0; wait "$p" || s=$?
    case $s in 0) ok=$((ok+1)) ;; 75) busy=$((busy+1)) ;; esac
  done
  assert_equal "$ok" 1
  assert_equal "$busy" 4
}

@test "soltar de outro dono falha e do dono remove" {
  L 1 pegar deploy
  run L 2 soltar deploy
  assert_equal "$status" 1
  tem_ref deploy
  run L 1 soltar deploy
  assert_success
  ! tem_ref deploy
}

@test "soltar com lock livre e idempotente" {
  run L 1 soltar deploy
  assert_success
  assert_output --partial "livre"
}

@test "espera: B pega depois que A solta" {
  L A pegar deploy
  ( sleep 2; L A soltar deploy ) &
  run L B pegar deploy 20
  assert_success
  wait
  run L C dono deploy
  assert_output --partial "run=B"
}

@test "forcar-soltar remove sem checar dono" {
  L 1 pegar deploy
  run L 2 forcar-soltar deploy
  assert_success
  ! tem_ref deploy
}

@test "sem RUN_ID pegar falha e subcomando invalido sai 2" {
  run env -u GITFLOW_RUN_ID sh -c 'cd "$1" && "$2" pegar x' _ "$WORK" "$KIT_DIR/core/lock.sh"
  assert_failure
  assert_output --partial "GITFLOW_RUN_ID"
  run L 1 bobagem x
  assert_equal "$status" 2
}
