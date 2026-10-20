# gitflow-kit

Kit portátil em shell que implementa um processo GitFlow. As regras ficam em `core/*.sh`
(POSIX sh, sem dependência de plataforma); a conversa com GitHub, GitLab etc. passa por
adaptadores em `adapters/`.

## Estrutura

- `core/`: regras do processo (somente funções do provider, nunca `curl` direto).
- `adapters/provider/`: `fake.sh` (testes), `github.sh`, `gitlab.sh`.
- `tests/`: suíte [bats](https://github.com/bats-core/bats-core) (submódulos em `tests/bats/`).

## Testes

```sh
git submodule update --init
tests/bats/bats-core/bin/bats tests/
```

Requisitos: `git`, `jq`, `shellcheck`.

## Licença

MIT.
