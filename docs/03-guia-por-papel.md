# 03 · Guia por papel

> O passo a passo de cada papel, com os comandos e botões exatos. As regras por trás de cada passo estão em
> [02 · Portões de aprovação](02-portoes-de-aprovacao.md).

## Sumário

- [Onde ficam os botões](#onde-ficam-os-botões)
- [Dev](#dev)
- [QA](#qa)
- [PO e Negócio](#po-e-negócio)
- [Tech Lead](#tech-lead)
- [Release Manager](#release-manager)
- [DevOps](#devops)
- [O que fazer quando…](#o-que-fazer-quando)

---

## Onde ficam os botões

| Ação | Onde |
|---|---|
| Comandos `/entregar`, `/aprovar`, … | comentário no PR (a primeira palavra é o comando). O bot reage 👀 ao começar, 👍 se aceitou, 👎 se recusou (o motivo vem num comentário "⛔") |
| Montar, regressão, release, promover hotfix, voltar, destravar, esteira manual | **Actions** → workflow **gitflow** → **Run workflow** → escolher `job` e preencher os campos |
| Checagem pós-deploy, aprovação de PRD | **Actions** → o run da esteira → **Review deployments** → marcar o Environment → **Approve and deploy** ou **Reject** |
| Estado de cada PR | label `Ambiente::*` e comentários do bot no PR |
| O que está em cada ambiente | tags `qa.*`/`hom.*` (mensagem = manifesto), branches `qa`/`hom`/`main`, aba **Deployments** |

---

## Dev

### Rotina

```sh
# 1. criar a branch a partir da main (ID da tarefa + descrição em minúsculas)
git fetch origin
git switch -c feature/PROJ-123-tela-de-ferias origin/main

# 2. trabalhar, commitar e abrir o PR para a main no primeiro push
git push -u origin feature/PROJ-123-tela-de-ferias

# 3. todo dia (e depois de cada release ou hotfix): atualizar com a main
git fetch origin && git rebase origin/main
git push --force-with-lease
```

| Passo | O que fazer | O kit responde |
|---|---|---|
| 1 | Abrir o PR para a `main` com o template preenchido (`## Critério de aceite`, `## Como testar`, autoteste marcado) | — |
| 2 | Esperar o CI verde (`app-ci`) e a aprovação de review de outra pessoa **no último commit** | — |
| 3 | Comentar `/entregar` | "📦 Entrega rc/PROJ-123.1 criada"; label `Ambiente::QA` |
| 4 | Acompanhar: label e comentários | "⏳ Na fila do QA (posição N)", "⚠️ … conflitou", "✅ /aprovar registrado", "🚀 … publicada em PRD" |
| 5 | Depois que o PR foi fechado pela release: apagar a branch local | — |

> [!IMPORTANT]
> Commits feitos depois do `/entregar` não vão para nenhum ambiente. Para mandar uma correção: push + `/entregar` de novo
> (vira `rc/PROJ-123.2`).

### Casos especiais

| Caso | Como |
|---|---|
| Reentregar algo já aprovado ou homologado | `/entregar confirmo` (a branch sai da HOM e da release até o QA aprovar a nova entrega) |
| Bug não urgente em PRD | `bugfix/PROJ-130-descricao` a partir da `main`, fluxo normal |
| Hotfix (com autorização do TL) | `git switch -c hotfix/2.5.1 v2.5.0`, correção mínima, PR para a `main`, review, `/entregar` → `rc/hotfix-2-5-1.1` |
| Duas branches que só funcionam juntas | uma branch de épico com PR para a `main`; as partes entram no épico por PR normal; `/entregar` só no PR do épico |
| Não basear a branch em outra tarefa ainda fora de PRD | o `/entregar` recusa (P13): use o épico ou espere a outra ir para PRD |

---

## QA

### Rotina de cada build (10h e 15h)

| # | Passo | Onde |
|---|---|---|
| 1 | Tester de plantão: aguardar o run da esteira chegar em `checagem` | Actions → run `gitflow` (agendado) |
| 2 | Roteiro de 5 minutos: responde, login, telas principais, uma gravação | ambiente QA |
| 3 | **Approve** em `checagem-qa` (ou **Reject** se falhou) | Review deployments |
| 4 | Ler o manifesto: entregas novas, `fora:`, `fila:`, `saiu:` | tag `qa.*` (Releases/Tags ou `git show qa.AAAA-MM-DD.N`) |
| 5 | Testar primeiro os retestes expressos (só a correção), depois as novas pelo critério de aceite | ambiente QA |
| 6 | Em cada PR testado: `/aprovar` ou `/reprovar <o que falhou, como reproduzir, evidência>` | PR |

```text
/reprovar ao fechar o mês o saldo fica negativo
Passos: 1) ... 2) ...
Evidência: print anexado
```

### Outras tarefas

| Tarefa | Como |
|---|---|
| Checagem da preview (HOM), de manhã | **Approve** em `checagem-hom` no run das 17h |
| Montagem expressa (reteste fora da janela) | `job=montar`, `ALVO=qa`, `EXPRESSO=true` |
| Suspeitas depois de uma checagem rejeitada | label `Suspeita de checagem` nos PRs suspeitos (voltam um por montagem) |
| Ajuste na triagem da HOM | `/ajuste <motivo>` |
| Regressão da release ou do hotfix | `job=regressao`, `HOM_TAG=hom.*`, `RESULTADO=ok` (ou `falhou`), `ISSUE=N` |

---

## PO e Negócio

| # | Passo | Como |
|---|---|---|
| 1 | Esperar o QA aprovar a checagem da preview (`checagem-hom`) | o run das 17h fica verde |
| 2 | Validar cada entrega do manifesto da `hom.*` contra o critério de aceite | ambiente HOM |
| 3 | Triagem com o QA: Erro, Ajuste ou Alteração (vale a mais grave) | [G5](02-portoes-de-aprovacao.md#g5--decisão-da-hom-homologar-alteracao-ajuste-reprovar-hom) |
| 4 | Registrar um comando em cada PR | `/homologar` · `/alteracao PROJ-140` · `/ajuste <motivo>` · `/reprovar-hom <motivo>` |
| 5 | Prioridade da fila do QA | labels `Prioridade::1`, `Prioridade::2`, `Prioridade::3` no PR |
| 6 | Desistir de uma branch | `/retirar <motivo>` |
| 7 | Preview fora das 17h | peça a quem roda workflows: `job=montar`, `ALVO=hom` |

Para `/alteracao`, crie a tarefa nova **antes** e informe o ID dela no comando.

---

## Tech Lead

| Tarefa | Como |
|---|---|
| Code review | **Approve** no PR, depois do último commit (o `/entregar` exige review de outra pessoa sobre o último commit) |
| Entregar em nome do autor | `/entregar` (só autor ou `tech-leads`) |
| Conflito de entrega em teste (R2a) | orientar o dev a fazer rebase e reentregar, ou registrar a resolução no rerere (abaixo) |
| Conflito de entrega aprovada (R2b, montagem PARADA por P4) | decidir: rerere, nova entrega, ou `/retirar` uma das duas |
| Autorizar hotfix | combinado fora do kit (o kit não confere essa autorização) |
| Voltar um ambiente | `job=voltar`, `AMBIENTE=qa\|hom\|prd` |
| Destravar um lock | `job=destravar`, `NOME=montagem-qa` (etc.) |

**Registrar uma resolução de conflito (rerere)**, num clone com acesso de escrita e as mesmas variáveis do CI
(`GITFLOW_PROVIDER=github`, `GITHUB_TOKEN`, `GITHUB_REPOSITORY`):

```sh
sh <kit>/core/resolver-conflito.sh qa      # reproduz a montagem localmente, sem tag nem push; para no 1º conflito
# resolva os arquivos, compile e rode os testes
git add -A && git commit --no-edit         # o rerere grava a resolução em .git/rr-cache
sh <kit>/core/resolver-conflito.sh qa      # repita até "Montagem reproduzida sem conflitos"
sh <kit>/core/resolver-conflito.sh --publicar   # envia .git/rr-cache para a branch meta/rerere
```

As próximas montagens `qa`/`hom`/`hotfix` carregam `meta/rerere`; a montagem `release` nunca aplica resoluções.

---

## Release Manager

### Release

| # | Passo | Como |
|---|---|---|
| 1 | Conferir: nenhum hotfix em andamento, issue da release aberta | — |
| 2 | Montar a preview | `job=montar`, `ALVO=release`, `VERSAO=2.5.0` |
| 3 | Conferir o manifesto da `hom.*` "Release 2.5.0": exatamente as homologadas esperadas | tag `hom.*` |
| 4 | Pedir ao QA a checagem (`checagem-hom`) e a regressão | — |
| 5 | Depois de `regressao-ok`: criar a versão | `job=release`, `VERSAO=2.5.0`, `HOM_TAG=hom.2026-10-15.1`, `ISSUE=42` |
| 6 | **Outro** RM aprova `aprovacao-prd` na janela combinada | Review deployments |
| 7 | Conferir: smoke OK, `main` = `v2.5.0`, PRs fechados, Release `v2.5.0` criada, montagens de QA e HOM disparadas | run da esteira |

| Se… | Faça |
|---|---|
| A regressão falhou | QA registra `RESULTADO=falhou`; negócio `/reprovar-hom` na culpada; `job=montar ALVO=release VERSAO=2.5.0` de novo |
| Uma branch foi homologada depois da montagem da release | vai na próxima release, ou monte a release de novo (a regressão recomeça) |
| Um hotfix foi para PRD durante a release | a esteira de PRD recusa (P9): monte a release de novo |
| O smoke falhou | o PRD volta sozinho; `v2.5.0` fica queimada; decida com o TL: hotfix ou nova release com outro número |
| Cancelar a release | `job=montar`, `ALVO=hom`, `FORCAR=true` |

### Hotfix

| # | Quem | Ação |
|---|---|---|
| 1 | TL | autoriza |
| 2 | Dev | `hotfix/2.5.1` a partir de `v2.5.0`, PR, review, `/entregar` (QA fica reservado até o `promover-hotfix`: montagem `qa` normal é adiada) |
| 3 | RM | `job=montar`, `ALVO=hotfix`, `HOTFIX=2.5.1` → `qa.*` "Hotfix 2.5.1" |
| 4 | QA | checagem + `/aprovar` |
| 5 | RM | **logo em seguida**: `job=promover-hotfix`, `QA_TAG=qa.*` → `hom.*` "Hotfix 2.5.1" no mesmo commit |
| 6 | Negócio | `/homologar` |
| 7 | QA | `job=regressao`, `HOM_TAG=<hom.* do hotfix>`, `RESULTADO=ok` |
| 8 | RM | `job=release`, `VERSAO=2.5.1`, `HOM_TAG=<hom.* do hotfix>`; outro RM aprova `aprovacao-prd` |
| 9 | Todos | atualizar as branches com a `main` |

---

## DevOps

| Tarefa | Onde |
|---|---|
| Instalar o kit num repositório | [04 · Instalação no GitHub](04-instalacao-github.md) |
| Republicar a mesma build depois de corrigir ambiente/dado/configuração (R7) | `job=esteira`, `TAG=<build publicada>`, `AMBIENTE=qa\|hom`, opcional `PULAR_CHECAGEM=true` |
| Rodar de novo o registro depois de falha do `publicar.sh` | no run da esteira de PRD: **Re-run failed jobs** (mantém o dono dos locks) |
| Adaptadores de deploy, artefatos e notificação | [05 · Arquitetura](05-arquitetura-e-portabilidade.md) |
| Locks presos, montagens paradas | [07 · Operação e falhas](07-operacao-e-falhas.md) |

---

## O que fazer quando…

| Situação | O que você vê | O que fazer |
|---|---|---|
| **`/entregar` recusado** | 👎 e "⛔ Entrega recusada: motivo" | corrigir o item (rebase, CI, review, template, `confirmo`) e comentar de novo; lista completa em [G1](02-portoes-de-aprovacao.md#g1--portão-de-entrada-entregar) |
| **Decisão recusada** | "⛔ /aprovar recusado: … não está na build publicada e verificada" | esperar a próxima montagem e a checagem; conferir se o dev não reentregou |
| **Conflito na montagem** (entrega em teste) | label `Montagem::Conflito`, "⚠️ … conflitou na montagem" | dev: `git rebase origin/main`, resolver, `/entregar`; ou TL registra rerere |
| **Na fila** | label `Montagem::Fila`, "⏳ Na fila do QA (posição N)" | esperar; PO pode priorizar com `Prioridade::*` |
| **Reteste expresso** | label `Reteste expresso` depois de reentregar uma correção | QA: `job=montar ALVO=qa EXPRESSO=true` ou esperar a janela; testar só a correção |
| **Checagem falhou** | o tester clicou **Reject**; "voltou para a build anterior" | uma entrega nova: `/reprovar` nela; várias: TL + tester analisam ou `Suspeita de checagem` |
| **Checagem esquecida** | montagens agendadas "adiada"; decisões recusadas | o QA aprova ou rejeita `checagem-*` no run pendente |
| **Montagem parou** | run vermelho com "PARADO: …" | ver o motivo (P3, P4, P5) em [07](07-operacao-e-falhas.md#montagem-parada) |
| **Lock preso** | "ocupado: run=… url=…" no log; montagens "adiada" | abrir o run dono (URL no log); se ele morreu ou foi cancelado: `job=destravar NOME=<lock>` ([07](07-operacao-e-falhas.md#locks-presos)) |
| **Voltar um ambiente à mão** | build ruim publicada | `job=voltar AMBIENTE=<amb>` (TL ou RM) |
