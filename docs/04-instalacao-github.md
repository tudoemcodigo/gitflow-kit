# 04 · Instalação no GitHub

> Do zero até a primeira entrega publicada no QA. Siga na ordem.

## Sumário

1. [Pré-requisitos](#1-pré-requisitos)
2. [Criar o GitHub App](#2-criar-o-github-app)
3. [Secrets da organização](#3-secrets-da-organização)
4. [Copiar os arquivos para a aplicação: `instalar.sh`](#4-copiar-os-arquivos-para-a-aplicação-instalarsh)
5. [Configurar o repositório: `setup/github.sh`](#5-configurar-o-repositório-setupgithubsh)
6. [Contrato com a aplicação](#6-contrato-com-a-aplicação)
7. [`.gitflow.env`](#7-gitflowenv)
8. [Acesso das Teams](#8-acesso-das-teams)
9. [Checklist da primeira execução](#9-checklist-da-primeira-execução)

---

## 1. Pré-requisitos

| Item | Por quê |
|---|---|
| Organização no GitHub (não conta pessoal) | Teams, secrets da org, GitHub App da org |
| Repositório público, ou plano Team/Enterprise | Environments com revisores obrigatórios em repositório privado exigem plano pago |
| Admin da organização e do repositório | criar o App, Teams, rulesets, Environments |
| `gh` CLI autenticado (`gh auth login` com escopos `repo` e `admin:org`) | `setup/github.sh` usa só `gh api` |
| `git`, `jq`, `sh` (Git Bash no Windows) | `instalar.sh` e `setup/github.sh` |
| Um clone do kit (ou um fork na sua organização) | os workflows reutilizáveis são consumidos por `ORG/REPO@ref` |
| A aplicação com CI de PR | o `/entregar` exige CI verde no último commit (`app-ci.yml` é instalado como modelo) |

---

## 2. Criar o GitHub App

O bot do kit é um GitHub App: cria tags e deployments, escreve labels e comentários, dispara a montagem e é o único
ator de bypass dos rulesets. O token é gerado por job (`actions/create-github-app-token`), restrito ao repositório.

### Permissões

| Escopo | Permissão | Para quê |
|---|---|---|
| Repository › Contents | Read and write | branches, tags, refs `refs/gitflow/*`, assets de release |
| Repository › Pull requests | Read and write | ler PRs e reviews, fechar PRs |
| Repository › Issues | Read and write | labels e comentários (PRs usam a API de issues) |
| Repository › Deployments | Read and write | a verdade de QA, HOM e PRD |
| Repository › Actions | Read and write | disparar a remontagem depois do PRD; ler `GET /actions/runs/{id}/approvals` |
| Repository › Metadata | Read-only | obrigatório |
| Organization › Members | Read-only | conferir pertencimento às Teams |

### Opção A · Manual

1. `Settings › Developer settings › GitHub Apps › New GitHub App` **da organização**.
2. Nome (ex.: `minha-org-release-bot`), Homepage URL = URL do repositório do kit.
3. **Webhook**: desmarque `Active`.
4. Permissões da tabela acima. `Where can this GitHub App be installed`: `Only on this account`.
5. **Create GitHub App**. Anote o **App ID** (número no topo da página).
6. **Generate a private key**: baixa um `.pem`. Guarde só no cofre/secrets.
7. **Install App** › a organização › `Only select repositories` › os repositórios que usam o kit.

### Opção B · Manifesto (um clique)

O GitHub cria o App a partir de um JSON enviado por formulário. O kit não traz esta página pronta; salve o HTML abaixo
num arquivo local, troque `minha-org`, abra no navegador e clique no botão.

```html
<form action="https://github.com/organizations/minha-org/settings/apps/new" method="post">
  <input type="hidden" name="manifest" id="manifest">
  <button type="submit">Criar o GitHub App do GitFlow Kit</button>
</form>
<script>
  document.getElementById("manifest").value = JSON.stringify({
    name: "minha-org-release-bot",
    url: "https://github.com/minha-org/gitflow-kit",
    redirect_url: "https://github.com/minha-org",
    public: false,
    hook_attributes: { url: "https://example.invalid", active: false },
    default_permissions: {
      contents: "write", pull_requests: "write", issues: "write",
      deployments: "write", actions: "write", metadata: "read", members: "read"
    }
  });
</script>
```

Depois de confirmar, o GitHub redireciona para `redirect_url?code=XXXX`. Troque o código (válido por 1 hora) pelo id
e pela chave:

```sh
gh api -X POST /app-manifests/XXXX/conversions > app.json
jq -r .id app.json                       # App ID
jq -r .pem app.json > release-bot.pem    # chave privada
rm app.json
```

Em seguida, instale o App nos repositórios (passo 7 da opção A).

---

## 3. Secrets da organização

```sh
gh secret set GITFLOW_APP_ID  --org minha-org --visibility selected --repos minha-app --body "<App ID>"
gh secret set GITFLOW_APP_KEY --org minha-org --visibility selected --repos minha-app < release-bot.pem
rm release-bot.pem
```

Restrinja sempre aos repositórios que usam o kit (`selected`). Os workflows recebem os secrets com `secrets: inherit`.

---

## 4. Copiar os arquivos para a aplicação: `instalar.sh`

```sh
sh instalar.sh --plataforma github --destino ../minha-app \
  [--kit-repo minha-org/gitflow-kit] [--kit-ref v1] [--org minha-org] [--modo-demo]
```

| Opção | Padrão | Efeito |
|---|---|---|
| `--plataforma` | — (obrigatória) | só `github`; `gitlab` e `jenkins` respondem "ainda não disponível" |
| `--destino DIR` | — (obrigatória) | diretório da aplicação; o nome do diretório vira `@APP@` nas URLs do `.gitflow.env` |
| `--kit-repo ORG/REPO` | `tudoemcodigo/gitflow-kit` | de onde os workflows reutilizáveis são chamados (use o seu fork) |
| `--kit-ref REF` | `v1` | tag ou SHA do kit; vai no `@ref` do `uses:` e em `kit-ref:` de cada job |
| `--org ORG` | dono do `--kit-repo` | `@ORG@` nas URLs do `.gitflow.env` |
| `--modo-demo` | desligado | grava `MODO_DEMO=sim` no `.gitflow.env` |

Arquivos criados (nunca sobrescreve: o que já existe é listado como "pulado"):

| Arquivo | Origem no kit | Ajuste |
|---|---|---|
| `.github/workflows/gitflow.yml` | `ci/github-actions/chamadores/gitflow.yml` | horários do `schedule` (UTC) |
| `.github/workflows/app-ci.yml` | `ci/github-actions/chamadores/app-ci.yml` | o CI de PR da aplicação |
| `.github/pull_request_template.md` | `setup/modelos/pull_request_template.md` | mantenha as seções `## Critério de aceite` e `## Como testar` |
| `.gitflow.env` | `modelos/app/.gitflow.env.github` | ver [seção 7](#7-gitflowenv) |
| `scripts/build.sh` | `modelos/app/scripts/build.sh` | o build real |
| `scripts/test.sh` | `modelos/app/scripts/test.sh` | os testes reais |

> [!IMPORTANT]
> O nome `gitflow.yml` é o valor padrão de `montar-workflow`: a esteira de PRD dispara esse arquivo para remontar QA e
> HOM. Se renomear, passe `montar-workflow: <arquivo>` nos jobs `montar`, `esteira`, `release` e `promover-hotfix`.

Publique esses arquivos na `main` da aplicação **antes** do passo 5 (depois dos rulesets, só o App escreve na `main`).

---

## 5. Configurar o repositório: `setup/github.sh`

```sh
sh setup/github.sh --repo minha-org/minha-app --app-id 123456 [--dry-run] [--modo-demo]
```

| Opção | Efeito |
|---|---|
| `--repo ORG/REPO` | repositório da aplicação (obrigatório) |
| `--app-id ID` | id numérico do App; vira ator de bypass dos rulesets (obrigatório) |
| `--dry-run` | imprime `METODO caminho` de cada chamada, sem executar |
| `--modo-demo` | `prevent_self_review=false` em `aprovacao-prd` (quem dispara pode aprovar PRD) |

O que ele faz, em ordem (idempotente; leituras com erro diferente de 404 abortam):

| # | Item | Detalhe |
|---|---|---|
| 1 | Teams | cria `qa`, `negocio`, `tech-leads`, `release-managers` se faltarem; dá `push` no repositório a `qa` e `release-managers` (só se não tiverem acesso) |
| 2 | Repositório | squash e rebase merge desligados; merge commit ligado; issues ligadas |
| 3 | Branches | cria `qa`, `hom`, `meta/rerere` a partir da `main` |
| 4 | Pages | cria `gh-pages` órfã e habilita o Pages (deploy `pages`) |
| 5 | Environments | `qa`, `hom`, `production` sem revisores; `checagem-qa` e `checagem-hom` com a Team `qa`; `aprovacao-prd` com `release-managers` e `prevent_self_review` |
| 6 | Template de PR | cria `.github/pull_request_template.md` na `main` se faltar |
| 7 | Estado inicial de PRD | se não há tag `v*`, cria `v0.1.0` anotada na `main`; se não há deployment em `production`, cria um `success` na versão mais nova |
| 8 | Labels | sincroniza `setup/modelos/labels.tsv` |
| 9 | Rulesets | `gitflow-ambientes`, `gitflow-tags`, `gitflow-versoes` (ver [G13](02-portoes-de-aprovacao.md#g13--proteções-da-plataforma-rulesets)) |
| 10 | Secrets | avisa se `GITFLOW_APP_ID`/`GITFLOW_APP_KEY` não existem no repositório nem na org |

> [!WARNING]
> Os Environments listados e os três rulesets são **totalmente gerenciados** pelo script: cada execução sobrescreve
> alterações manuais. Personalizações devem usar outros nomes. Os nomes das Teams estão fixos no script: se o
> `.gitflow.env` usar outros slugs, crie as Teams e ajuste os revisores dos Environments à mão.

---

## 6. Contrato com a aplicação

A aplicação fornece scripts; o kit nunca roda código da aplicação em job com o token do App
(`construir`, `testar`, `gates` e `verificar` rodam sem token).

| Arquivo | Obrigatório | Chamado como | Contrato |
|---|---|---|---|
| `scripts/build.sh` | sim | `sh scripts/build.sh` (cwd = raiz do repositório) | termina com `exit 0` e deixa o resultado em `dist/` (o kit apaga `dist/` antes e zipa o conteúdo) |
| `scripts/test.sh` | sim | `sh scripts/test.sh` | `exit 0` = aprovado; roda depois do build, com `dist/` presente |
| `scripts/gates.sh` | não | `sh scripts/gates.sh AMB SHA` | gates de qualidade/segurança; `exit` ≠ 0 barra a publicação |
| `scripts/checar.sh` | não | `sh scripts/checar.sh qa\|hom` | checagem automática pós-deploy; se existir, substitui o Environment `checagem-*` |
| `scripts/smoke.sh` | não | `sh scripts/smoke.sh prd` | smoke de PRD; sem ele, o kit usa `deploy_saude prd SHA` do adaptador de deploy |

- O pacote é `app-<sha>.zip` + `app-<sha>.zip.sha256`, um por commit, nunca sobrescrito.
- O deploy `pages` grava `version.json` (`versao`, `sha`, `data`) em cada ambiente; `deploy_saude` confere o `sha`.
- Equivalentes `.ps1` (Windows) ainda não são detectados: os scripts precisam ser `sh`.

---

## 7. `.gitflow.env`

Lido **literalmente** (sem `eval`, sem expansão de `$VAR`), linha a linha `CHAVE=VALOR`, aspas externas removidas.
Uma variável já definida no ambiente vence o arquivo.

| Chave | Padrão | Uso |
|---|---|---|
| `GITFLOW_PROVIDER` | — (obrigatória) | `github` (o workflow já define) |
| `ARTEFATOS` | — | `github-release` ou `pasta` |
| `DEPLOY` | — | `pages` ou `pasta` |
| `NOTIFICAR` | `console` | `console`, `pr-comment`, `slack`, `teams` |
| `MODO_DEMO` | `nao` | `sim` só em demonstração |
| `GRUPO_QA`, `GRUPO_NEGOCIO`, `GRUPO_TL`, `GRUPO_RM` | `qa`, `negocio`, `tech-leads`, `release-managers` | slugs das Teams |
| `LIMITE_QA` | `6` | entregas em teste por build do QA |
| `ID_REGEX` | `[A-Z]+-[0-9]+` | ID da tarefa no nome da branch |
| `URL_QA`, `URL_HOM`, `URL_PRD` | — | usadas por `deploy_saude` (adaptador `pages`) |
| `PAGES_*`, `ARTEFATOS_*`, `DEPLOY_*`, `NOTIFICAR_*` | — | ajustes de adaptador (ex.: `PAGES_TENTATIVAS`, `ARTEFATOS_RELEASE_TAG`, `NOTIFICAR_ISSUE`) |
| `TERMO_PR`, `TZ` | `PR` (GitHub), `America/Sao_Paulo` | aceitas, mas hoje sem efeito: o provider `github` redefine `TERMO_PR` e `core/lib.sh` fixa `TZ` |

**Recusadas no arquivo** (só pelo ambiente/secrets do CI): `PAGES_REMOTE`, `ARTEFATOS_URL`, `ARTEFATOS_DIR`,
`DEPLOY_DIR`, qualquer `*_REMOTE`, `*_TOKEN`, `*_SENHA`, `*_PASSWORD`, `*_WEBHOOK`. Qualquer chave fora da lista
também é recusada (`PATH`, `GIT_*`, `BASH_ENV`… nunca vêm do arquivo). Nomes de adaptador aceitam só `[a-z0-9-]`.

---

## 8. Acesso das Teams

| Team | Precisa de | Para |
|---|---|---|
| `qa` | `push` (o setup concede) | rodar `job=regressao`/`montar`; ser revisora de `checagem-*` |
| `release-managers` | `push` (o setup concede) | rodar `release`/`montar`/`promover-hotfix`; revisora de `aprovacao-prd`; bypass em `v*` |
| `tech-leads` | `push` (conceder à mão) | rodar `voltar`/`destravar`; review |
| `negocio` | acesso de leitura ou triagem (conceder à mão em repositório privado) | comentar comandos no PR |

Comandos de PR só são processados para autores com associação `OWNER`, `MEMBER` ou `COLLABORATOR`.

---

## 9. Checklist da primeira execução

- [ ] App criado, instalado no repositório; `GITFLOW_APP_ID` e `GITFLOW_APP_KEY` na org (visibilidade `selected`)
- [ ] `instalar.sh` rodado; `gitflow.yml`, `app-ci.yml`, template, `.gitflow.env`, `scripts/` na `main`
- [ ] `setup/github.sh --dry-run` revisado e depois rodado sem `--dry-run`
- [ ] Pessoas nas Teams `qa`, `negocio`, `tech-leads`, `release-managers` (pelo menos dois RMs: `prevent_self_review`)
- [ ] `scripts/build.sh` gera `dist/`; `scripts/test.sh` sai com 0 (rode localmente)

**Verificação**

| # | Faça | Espere |
|---|---|---|
| 1 | `git ls-remote origin qa hom meta/rerere` | as três branches |
| 2 | `git ls-remote --tags origin v0.1.0` | a tag do estado inicial |
| 3 | `gh api repos/minha-org/minha-app/deployments?environment=production` | um deployment com status `success` |
| 4 | `gh api repos/minha-org/minha-app/rulesets` | `gitflow-ambientes`, `gitflow-tags`, `gitflow-versoes` |
| 5 | Criar `feature/DEMO-1-teste`, abrir PR, CI verde, review de outra pessoa, `/entregar` | 👀 → 👍, tag `rc/DEMO-1.1`, label `Ambiente::QA` |
| 6 | Actions → `gitflow` → Run workflow: `job=montar`, `ALVO=qa` | tag `qa.AAAA-MM-DD.1`, esteira até `checagem` |
| 7 | Approve em `checagem-qa` | `registrar` verde; branch `qa` no commit da build; locks livres (`git ls-remote origin 'refs/gitflow/lock/*'` vazio) |
| 8 | `/aprovar` no PR (alguém da Team `qa`) | tag `qa-ok/DEMO-1.1`, label `Ambiente::HOM` |

---

<p align="center"><a href="03-guia-por-papel.md">⬅ 03 · Guia por papel</a> · <a href="../README.md">Índice</a> · <a href="05-arquitetura-e-portabilidade.md">05 · Arquitetura ➜</a></p>
