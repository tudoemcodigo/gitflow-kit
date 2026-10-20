# 06 · Referência

> Consulta rápida. Tudo aqui existe no código do kit.

## Sumário

- [Comandos de PR](#comandos-de-pr)
- [Workflow `gitflow` da aplicação (`workflow_dispatch`)](#workflow-gitflow-da-aplicação-workflow_dispatch)
- [Workflows reutilizáveis](#workflows-reutilizáveis)
- [Environments](#environments)
- [Labels](#labels)
- [Tags e refs](#tags-e-refs)
- [Scripts do core](#scripts-do-core)
- [Variáveis de ambiente](#variáveis-de-ambiente)
- [Arquivos em `$GITFLOW_SAIDA`](#arquivos-em-gitflow_saida)
- [Códigos de saída de `core/lock.sh`](#códigos-de-saída-de-corelocksh)
- [Proteções P1–P15](#proteções-p1p15)

---

## Comandos de PR

Primeira palavra do comentário; o resto da primeira linha e as linhas seguintes são o motivo/nota.

| Comando | Quem (`.gitflow.env`) | Motivo | Registra | Script |
|---|---|---|---|---|
| `/entregar` | autor do PR ou `GRUPO_TL` | — (`confirmo` para reentregar algo aprovado) | `rc/<ID>.N` | `core/criar-rc.sh` |
| `/aprovar` | `GRUPO_QA` | opcional | `qa-ok/<ID>.N` | `core/decidir.sh` |
| `/reprovar` | `GRUPO_QA` | obrigatório | `qa-nok/<ID>.N` | `core/decidir.sh` |
| `/homologar` | `GRUPO_NEGOCIO` | opcional | `hom-ok/<ID>.N` | `core/decidir.sh` |
| `/alteracao` | `GRUPO_NEGOCIO` | obrigatório (tarefa nova) | `hom-ok/<ID>.N` | `core/decidir.sh` |
| `/ajuste` | `GRUPO_NEGOCIO` ou `GRUPO_QA` | obrigatório | `hom-ajuste/<ID>.N` | `core/decidir.sh` |
| `/reprovar-hom` | `GRUPO_NEGOCIO` | obrigatório | `hom-nok/<ID>.N` | `core/decidir.sh` |
| `/retirar` | `GRUPO_NEGOCIO` ou `GRUPO_TL` | obrigatório | `retirada/<ID>.N` | `core/decidir.sh` |

Transições aceitas por `decidir.sh` (estado da última entrega → decisão):

| Decisão | A partir de |
|---|---|
| `qa-ok` | em teste |
| `qa-nok` | em teste, `qa-ok` |
| `hom-ok` | `qa-ok` |
| `hom-nok` | `qa-ok`, `hom-ok` |
| `hom-ajuste` | `qa-ok` |
| `retirada` | em teste, `qa-ok`, `hom-ok` |

---

## Workflow `gitflow` da aplicação (`workflow_dispatch`)

Arquivo `.github/workflows/gitflow.yml` (modelo em `ci/github-actions/chamadores/gitflow.yml`). Gatilhos:
`issue_comment` (comandos), `schedule` (`0 13,18 * * 1-5` → `qa`; `0 20 * * 1-5` → `hom`, em UTC) e
`workflow_dispatch` com o input `job`:

| `job` | Inputs usados | Chama | Quem (conferido pelo script) |
|---|---|---|---|
| `montar` | `ALVO` (`qa`, `hom`, `release`, `hotfix`), `VERSAO`, `HOTFIX`, `EXPRESSO`, `FORCAR` | `gitflow-montar` | `release`/`hotfix`: `GRUPO_RM` |
| `esteira` | `TAG`, `AMBIENTE` (`qa`, `hom`, `prd`), `PULAR_CHECAGEM` | `gitflow-esteira` | — (PRD passa por `aprovacao-prd`) |
| `regressao` | `HOM_TAG`, `RESULTADO` (`ok`, `falhou`), `ISSUE` | `gitflow-regressao` | `GRUPO_QA` |
| `release` | `VERSAO`, `HOM_TAG`, `ISSUE` | `gitflow-release` | `GRUPO_RM` |
| `promover-hotfix` | `QA_TAG` | `gitflow-promover-hotfix` | `GRUPO_RM` |
| `voltar` | `AMBIENTE` | `gitflow-voltar` | `GRUPO_TL` ou `GRUPO_RM` |
| `destravar` | `NOME` | `gitflow-destravar` | `GRUPO_TL` ou `GRUPO_RM` |

| Input | Tipo | Observação |
|---|---|---|
| `EXPRESSO` | boolean | só entram (além das já em teste) entregas de peso 1 (reteste expresso) |
| `FORCAR` | boolean | desliga as guardas P6 (modo release) e P7 (modo hotfix); **não** ignora "nada mudou" |
| `PULAR_CHECAGEM` | boolean | só existe em `job=esteira`: aceito quando `TAG` é a build já publicada no ambiente (R7); em PRD é sempre recusado. Montagem, release e promover-hotfix não têm o input (sempre criam tag nova) |

---

## Workflows reutilizáveis

Todos em `.github/workflows/`, `on: workflow_call`, com inputs `kit-repo` (padrão `tudoemcodigo/gitflow-kit`) e
`kit-ref` (padrão `v1`) e secrets `GITFLOW_APP_ID`, `GITFLOW_APP_KEY`.

| Workflow | Inputs próprios | Jobs |
|---|---|---|
| `gitflow-comandos` | — | `comandos` |
| `gitflow-montar` | `ALVO`, `VERSAO`, `HOTFIX`, `EXPRESSO`, `FORCAR`, `montar-workflow` | `montar` → `esteira` (se criou tag) |
| `gitflow-esteira` | `TAG`, `AMBIENTE`, `PULAR_CHECAGEM`, `GITFLOW_LOCK_MONTAGEM`, `montar-workflow` | `preparar`, `construir`, `testar`, `publicar-pacote`, `gates`, `aprovacao`, `implantar`, `verificar`, `checagem`, `registrar`, `falhou` |
| `gitflow-regressao` | `HOM_TAG`, `RESULTADO`, `ISSUE` | `regressao` |
| `gitflow-release` | `VERSAO`, `HOM_TAG`, `ISSUE`, `montar-workflow` | `release` → `esteira` (`AMBIENTE=prd`) |
| `gitflow-promover-hotfix` | `QA_TAG`, `montar-workflow` | `promover` → `esteira` (`AMBIENTE=hom`) |
| `gitflow-voltar` | `AMBIENTE` | `voltar` |
| `gitflow-destravar` | `NOME` | `destravar` |

`montar-workflow` (padrão `gitflow.yml`) é o arquivo da aplicação que a esteira de PRD dispara para remontar QA e HOM.
A ação composta `.github/actions/preparar` (inputs `token`, `app-id`, `app-key`, `ref`) gera o token do App
(opcional), faz o checkout da aplicação em `app/` e exporta as variáveis do kit.

---

## Environments

| Environment | Revisores | Usado por |
|---|---|---|
| `qa`, `hom`, `production` | nenhum | só deployments criados pela API do kit (`deploy_iniciar`); nenhum job declara esses nomes |
| `checagem-qa`, `checagem-hom` | Team `qa` | job `checagem` (P15: sem prazo; só Reject explícito volta) |
| `aprovacao-prd` | Team `release-managers`, `prevent_self_review=true` (exceto `--modo-demo`) | job `aprovacao` |

---

## Labels

Sincronizadas de `setup/modelos/labels.tsv`.

| Label | Quem escreve | Significa |
|---|---|---|
| `Ambiente::QA` | kit | última entrega em teste |
| `Ambiente::QA reprovado` | kit | `qa-nok` |
| `Ambiente::HOM` | kit | `qa-ok` |
| `Ambiente::HOM reprovado` | kit | `hom-nok` |
| `Ambiente::Homologado` | kit | `hom-ok`, aguardando PRD |
| `Ambiente::PRD` | kit (`publicar.sh`) | entrega publicada em PRD; PR fechado |
| `Ambiente::Hotfix` | kit | entrega de hotfix em teste |
| `Ambiente::Retirada` | kit | `retirada` |
| `Montagem::Conflito` | kit | ficou fora da montagem por conflito |
| `Montagem::Fila` | kit | na fila do QA |
| `Reteste expresso` | kit | correção de algo reprovado ou ajuste (o peso vem das tags, não do label) |
| `Suspeita de checagem` | QA (à mão) | peso 2: volta sozinha, uma por montagem |
| `Prioridade::1`, `::2`, `::3` | PO (à mão) | pesos 3, 4, 5 na fila |

---

## Tags e refs

| Nome | Formato | Criada por |
|---|---|---|
| Entrega | `rc/<ID>.N` (hotfix: `rc/hotfix-X-Y-Z.N`) | `criar-rc.sh` |
| Build do QA | `qa.AAAA-MM-DD.N`; título `Build qa`, `Build qa (expressa)` ou `Hotfix X.Y.Z` | `montar.sh` |
| Build da HOM | `hom.AAAA-MM-DD.N`; título `Build hom`, `Release X.Y.Z` ou `Hotfix X.Y.Z` | `montar.sh`, `promover-hotfix.sh` |
| Versão | `vX.Y.Z` | `criar-release.sh` |
| Decisões | `qa-ok/`, `qa-nok/`, `hom-ok/`, `hom-nok/`, `hom-ajuste/`, `retirada/` + `<ID>.N` | `decidir.sh` |
| Regressão | `regressao-ok/<hom.*>` | `regressao.sh` |
| Estado inicial | `v0.1.0` | `setup/github.sh` |
| Release de pacotes | Release/tag `pacotes` (prerelease; `ARTEFATOS_RELEASE_TAG`) | adaptador `github-release` |
| Locks | `refs/gitflow/lock/<nome>` (cache local `refs/gitflow/lock-cache/<nome>`) | `lock.sh` |
| Cache rerere | branch `meta/rerere` | `resolver-conflito.sh --publicar` |

Nomes de lock: `comandos`, `montagem-qa`, `montagem-hom`, `ambiente-qa`, `ambiente-hom`, `ambiente-prd`.

---

## Scripts do core

| Script | Uso |
|---|---|
| `core/criar-rc.sh` | env `MR_IID`, `AUTOR`, `NOTA` |
| `core/decidir.sh` | env `MR_IID`, `AUTOR`, `NOTA` |
| `core/fluxo-montar.sh ALVO` | locks + `montar.sh` |
| `core/montar.sh ALVO` | `qa`, `hom`, `release`, `hotfix`; env `VERSAO`, `HOTFIX`, `EXPRESSO`, `FORCAR`, `BUILD_USER_ID` |
| `core/esteira.sh ETAPA` | `preparar`, `construir`, `testar`, `publicar-pacote`, `gates`, `implantar`, `verificar-auto`, `registrar`, `falhou`; env `TAG`, `AMBIENTE` |
| `core/pacote.sh CMD SHA [DESTINO]` | `existe`, `build`, `publicar`, `baixar` |
| `core/validar-tag.sh TAG AMB` | `qa`, `hom`, `prd` |
| `core/regressao.sh HOM_TAG ok\|falhou ISSUE` | |
| `core/criar-release.sh VERSAO HOM_TAG ISSUE` | |
| `core/promover-hotfix.sh QA_TAG` | imprime a `hom.*` criada |
| `core/publicar.sh vX.Y.Z` | idempotente |
| `core/voltar.sh AMB` | rodar dentro do lock `ambiente-AMB` |
| `core/resolver-conflito.sh ALVO \| --publicar` | reprodução local da montagem; publicação do rerere |
| `core/lock.sh pegar\|soltar\|forcar-soltar\|dono NOME [ESPERA_S]` | ver abaixo |

---

## Variáveis de ambiente

| Variável | Quem lê | Origem / padrão |
|---|---|---|
| `GITFLOW_PROVIDER`, `ARTEFATOS`, `DEPLOY`, `NOTIFICAR` | `lib.sh` | `.gitflow.env` / ação `preparar` (`GITFLOW_PROVIDER=github`) |
| `GRUPO_QA`, `GRUPO_NEGOCIO`, `GRUPO_TL`, `GRUPO_RM` | core | `.gitflow.env`; padrões `qa`, `negocio`, `tech-leads`, `release-managers` |
| `LIMITE_QA`, `ID_REGEX`, `MODO_DEMO` | core | `6`, `[A-Z]+-[0-9]+`, `nao` |
| `URL_QA`, `URL_HOM`, `URL_PRD` | `deploy/pages.sh` | `.gitflow.env` |
| `KIT_DIR` | todos | ação `preparar` (`.gitflow` do workspace) |
| `GITFLOW_RUN_ID`, `GITFLOW_RUN_URL` | `lock.sh` | ação `preparar` (id do run; URL com a tentativa) |
| `GITFLOW_SAIDA` | esteira, montagem | ação `preparar` (`$RUNNER_TEMP/gitflow`) |
| `GITFLOW_LOCK_INTERVALO` | `lock.sh` | `10` s |
| `GITFLOW_LOCK_MONTAGEM` | esteira | input do workflow (lock de montagem a soltar no fim) |
| `GITFLOW_LOCAL` | `montar.sh` | `sim` só via `resolver-conflito.sh` |
| `BUILD_USER_ID` | montagem, release, regressão, promoção, `exige-membro.sh` | `github.triggering_actor`; `timer` no `schedule` |
| `BOT_NAME`, `BOT_EMAIL` | tags e commits do kit | `<slug>[bot]` do App |
| `MR_IID`, `AUTOR`, `NOTA`, `COMMENT_ID` | comandos | evento `issue_comment` |
| `TAG`, `AMBIENTE`, `PULAR_CHECAGEM` | esteira | inputs |
| `VERSAO`, `HOTFIX`, `EXPRESSO`, `FORCAR`, `ALVO` | montagem | inputs |
| `GITHUB_TOKEN`, `GITHUB_REPOSITORY`, `GITHUB_API_URL`, `GITHUB_SERVER_URL` | `provider/github.sh`, `deploy/pages.sh` | token do App; Actions |
| `PAGES_REMOTE`, `PAGES_TENTATIVAS` (10), `PAGES_INTERVALO` (15), `PAGES_PUSH_TENTATIVAS` (3), `PAGES_CURL_TIMEOUT` (20), `SAUDE_SHA` | `deploy/pages.sh` | `PAGES_REMOTE` só pelo ambiente |
| `ARTEFATOS_RELEASE_TAG` (`pacotes`), `ARTEFATOS_DIR` | adaptadores de artefatos | `ARTEFATOS_DIR` só pelo ambiente |
| `DEPLOY_DIR` | `deploy/pasta.sh` | só pelo ambiente |
| `NOTIFICAR_WEBHOOK`, `NOTIFICAR_ISSUE` | notificação | webhook só pelo ambiente: secret opcional `NOTIFICAR_WEBHOOK` (`required: false` nos workflows; o chamador usa `secrets: inherit`), repassado só aos passos do core que notificam, nunca aos que rodam código da aplicação |
| `MONTAR_WORKFLOW`, `MONTAR_REF` | `disparar-montar.sh` | input `montar-workflow`; branch padrão |
| `R_CHEC`, `R_REG` | `falhou.sh` | resultado dos jobs `checagem` e `registrar` |
| `GITFLOW_ZIP_FORCAR` | `lib.sh` | `powershell` força o zip via PowerShell (testes) |

---

## Arquivos em `$GITFLOW_SAIDA`

| Arquivo | Escrito por | Conteúdo |
|---|---|---|
| `esteira.env` | `esteira.sh` (`preparar` recria) | `SHA` (commit da tag), `CONSTRUIR` (`sim`\|`nao`), `TESTADO` (`sim`), `DEPLOY_ID` (id do deployment), `VERIFICAR` (`OK`\|`MANUAL`\|`PULADA`, só escrito) |
| `montagem.tag` | `montar.sh` | a tag criada (vazio = nada a publicar) |
| `lock-montagem` | `fluxo-montar.sh` | `montagem-qa` ou `montagem-hom` quando a esteira precisa soltá-lo no fim |
| `app-<sha>.zip`, `app-<sha>.zip.sha256` | `pacote.sh build` | o pacote |

Entre jobs, `esteira.env` viaja nos artefatos `gitflow-estado-1` (depois de `preparar`), `gitflow-estado-2` (depois de
`testar`) e `gitflow-estado-3` (depois de `implantar`); o pacote, em `gitflow-pacote`.

---

## Códigos de saída de `core/lock.sh`

| Código | Significado |
|---|---|
| 0 | ok (obtido, solto, livre, removido) |
| 75 | `pegar`: ocupado depois da espera (imprime `ocupado: run=… url=… desde=…`) |
| 1 | `soltar`: o lock é de outro run, ou o push de remoção falhou; `GITFLOW_RUN_ID` ausente |
| 2 | uso inválido (subcomando, nome de lock, número) |
| 3 | erro de acesso ao remoto (nunca confundido com "livre" ou "ocupado") |

---

## Proteções P1–P15

| # | Proteção | Onde no kit |
|---|---|---|
| P1 | Decisões presas à entrega | tags `qa-ok/<ID>.N`…; `estado()` em `lib.sh` |
| P2 | Decisão só para a entrega publicada e verificada | `decidir.sh` (`publicada`, `deploy_ultimo`) |
| P3 | Guarda do manifesto | `montar.sh` (`aprovadas_vigentes`) |
| P4 | Conflito de aprovada para a montagem | `montar.sh` |
| P5 | `main` = PRD | `montar.sh` |
| P6 | Modo release | `montar.sh` (título `Release` da `hom.*` publicada) |
| P7 | Modo hotfix | `montar.sh`, `hotfix_aguardando_qa` |
| P8 | Um ambiente, uma publicação por vez | lock `ambiente-AMB` (`esteira.sh implantar`) |
| P9 | PRD revalida tudo dentro do lock | `validar-tag.sh` no `implantar` |
| P10 | Montagem reproduzível | base, rerere e lista no manifesto; ordem por data da decisão |
| P11 | Montagem e publicação são uma unidade | lock `montagem-AMB` até o fim da esteira |
| P12 | Pacote só depois dos testes | `esteira.sh publicar-pacote` (`TESTADO=sim`) |
| P13 | Entrega não carrega código de outra | `criar-rc.sh` |
| P14 | Um ID, um PR; um hotfix por vez | `criar-rc.sh` |
| P15 | Checagem sem prazo; só rejeição explícita volta | job `checagem` + `falhou.sh` |

---

<p align="center"><a href="05-arquitetura-e-portabilidade.md">⬅ 05 · Arquitetura</a> · <a href="../README.md">Índice</a> · <a href="07-operacao-e-falhas.md">07 · Operação e falhas ➜</a></p>
