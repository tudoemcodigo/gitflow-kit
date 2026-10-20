# GitHub App `tudoemcodigo-release-bot`

O bot do kit é um GitHub App: cria tags e deployments, escreve labels e comentários, dispara a montagem e é o único ator de bypass dos rulesets criados por `setup/github.sh`.

## 1. Criar o App

Em `Settings > Developer settings > GitHub Apps > New GitHub App` (da organização):

| Campo | Valor |
|---|---|
| GitHub App name | `tudoemcodigo-release-bot` |
| Homepage URL | a URL do repositório do kit |
| Webhook | **desmarcar** `Active` (sem webhook) |
| Where can this app be installed | `Only on this account` |

### Permissões

| Escopo | Permissão | Para quê |
|---|---|---|
| Repository > Contents | Read and write | branches, tags, refs `refs/gitflow/*` |
| Repository > Pull requests | Read and write | ler PRs, aprovar/comentar, labels |
| Repository > Issues | Read and write | labels e comentários (PRs usam a API de issues) |
| Repository > Deployments | Read and write | verdade de PRD/QA/HOM (deployments e statuses) |
| Repository > Actions | Read and write | disparar `montar` (dispatch) e ler `GET /actions/runs/{id}/approvals` |
| Repository > Metadata | Read-only | obrigatório |
| Organization > Members | Read-only | `membro`: verificar pertencimento às Teams |

Environments: não é preciso a permissão `Environments`; as aprovações são lidas pela API de Actions (`approvals`), coberta por `Actions: Read`.

## 2. Gerar a chave e anotar o id

1. Na página do App, `Generate a private key` baixa um `.pem`. Guarde-o só no cofre/secrets.
2. Anote o **App ID** (número, no topo da página). Ele é o valor de `--app-id` no `setup/github.sh`.

## 3. Instalar nos repositórios

`Install App` > a organização > `Only select repositories` > escolha os repositórios que usam o kit.

## 4. Secrets da organização

```sh
gh secret set GITFLOW_APP_ID  --org ORG --visibility selected --repos app1,app2 --body "<App ID>"
gh secret set GITFLOW_APP_KEY --org ORG --visibility selected --repos app1,app2 < tudoemcodigo-release-bot.private-key.pem
```

Restrinja sempre aos repositórios que usam o kit (`selected`). Depois de gravar, apague o `.pem` local.

## 5. Configurar o repositório

```sh
setup/github.sh --repo ORG/REPO --app-id <App ID>            # --dry-run mostra as chamadas sem executar
setup/github.sh --repo ORG/REPO --app-id <App ID> --modo-demo  # só em demonstração: o autor pode aprovar o próprio PRD
```

Quem roda precisa ser admin do repositório e da organização (`gh auth login` com escopos `repo`, `admin:org`).
O script confere os secrets `GITFLOW_APP_ID`/`GITFLOW_APP_KEY` e avisa se faltarem.

## Limitações

- Rulesets só protegem branches e tags: os locks `refs/gitflow/lock/*` podem ser apagados por quem tem escrita. O workflow `destravar` existe para recuperar o estado.
- Environments com revisores obrigatórios em repositórios privados exigem plano GitHub Team/Enterprise.
- Os Environments `qa`, `hom` e `production` não têm revisores e nenhum job os declara: só recebem os deployments criados pelo kit.
