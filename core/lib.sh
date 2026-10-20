#!/bin/sh
# core/lib.sh: funções comuns do kit, agnósticas de plataforma (uso: . core/lib.sh).
# Toda chamada à plataforma passa pelas funções do provider (adapters/provider/*.sh).
# shellcheck disable=SC2034  # variáveis de configuração são usadas pelos scripts que carregam a lib

export TZ=America/Sao_Paulo   # datas das tags no fuso local, em qualquer agente
BOT="-c user.name=gitflow-bot -c user.email=${BOT_EMAIL:-gitflow-bot@users.noreply.github.com}"

# jq em modo binário: no Windows (Git Bash) o jq emitiria CRLF. Único ponto de chamada do jq.
jqb() { command jq -b "$@"; }

# diretório do kit: KIT_DIR se definido, senão o pai do diretório do script em execução
kit_dir() {
  if [ -n "${KIT_DIR:-}" ]; then printf '%s\n' "$KIT_DIR"; else (cd "$(dirname "$0")/.." && pwd); fi
}

carregar_config() {
  # o ambiente vence o .gitflow.env: valor do arquivo só vale se a variável ainda não existe
  if [ -f .gitflow.env ]; then
    while IFS= read -r _l || [ -n "$_l" ]; do
      _l=$(printf '%s' "$_l" | tr -d '\015')
      case "$_l" in [A-Za-z_]*=*) ;; *) continue ;; esac
      _k=${_l%%=*}
      case "$_k" in *[!A-Za-z0-9_]*) continue ;; esac
      if eval "[ -z \"\${$_k+x}\" ]"; then
        eval "$_l"
        export "${_k?}"
      fi
    done < .gitflow.env
  fi
  : "${LIMITE_QA:=6}"
  : "${ID_REGEX:=[A-Z]+-[0-9]+}"
  : "${MODO_DEMO:=nao}"
  : "${NOTIFICAR:=console}"
  : "${GITFLOW_PROVIDER:?GITFLOW_PROVIDER não definido}"
  export LIMITE_QA ID_REGEX MODO_DEMO NOTIFICAR GITFLOW_PROVIDER
  _kd=$(kit_dir)
  # shellcheck source=/dev/null
  . "$_kd/adapters/provider/$GITFLOW_PROVIDER.sh"
  if [ -f "$_kd/adapters/notificar/$NOTIFICAR.sh" ]; then
    # shellcheck source=/dev/null
    . "$_kd/adapters/notificar/$NOTIFICAR.sh"
  fi
}

sai()  { echo "$*"; exit 0; }
para() {
  echo "PARADO: $*" >&2
  if command -v notificar > /dev/null 2>&1; then notificar alerta "$*" || true; fi
  exit 1
}
recusa_pr() {   # iid prefixo msg
  pr_comentar "$1" "⛔ $2: $3" || true
  echo "⛔ $2: $3" >&2
  exit 1
}

id_da_branch() {
  case "$1" in
    hotfix/*) echo "hotfix-$(echo "${1#hotfix/}" | tr . -)" ;;
    *)        echo "$1" | sed -nE "s#^(feature|bugfix)/(${ID_REGEX})-[a-z0-9-]+\$#\2#p" ;;
  esac
}
ultima_rc() { git tag -l "rc/$1.*" | awk -F. '{print $NF, $0}' | sort -n | tail -1 | cut -d' ' -f2; }
tem()       { git rev-parse -q --verify "refs/tags/$1" > /dev/null; }
data_tag()  { git for-each-ref --format='%(creatordate:unix)' "refs/tags/$1"; }

# estado de uma entrega pelas tags de decisão ("nok" vence "ok")
estado() {
  e=${1#rc/}
  if   tem "retirada/$e"; then echo retirada
  elif tem "hom-nok/$e";  then echo hom-nok
  elif tem "qa-nok/$e";   then echo qa-nok
  elif tem "hom-ok/$e";   then echo hom-ok
  elif tem "qa-ok/$e";    then echo qa-ok
  else echo teste; fi
}

espelhar() {   # iid rc: reescreve o label Ambiente::* (o label é só espelho)
  L=""
  case "$(estado "$2")" in
    teste)    L="Ambiente::QA" ;;         qa-nok)  L="Ambiente::QA reprovado" ;;
    qa-ok)    L="Ambiente::HOM" ;;        hom-nok) L="Ambiente::HOM reprovado" ;;
    hom-ok)   L="Ambiente::Homologado" ;; retirada) L="Ambiente::Retirada" ;;
  esac
  case "$2:$L" in rc/hotfix-*:Ambiente::QA) L="Ambiente::Hotfix" ;; esac
  REM=""
  for A in "Ambiente::QA" "Ambiente::QA reprovado" "Ambiente::HOM" "Ambiente::HOM reprovado" \
           "Ambiente::Homologado" "Ambiente::Retirada" "Ambiente::Hotfix"; do
    [ "$A" = "$L" ] || REM="${REM:+$REM,}$A"
  done
  pr_rotular "$1" "$L" "$REM"
}

# PRs abertos para a main: "iid branch peso"; peso = ordem na fila do QA.
# Pesos vêm dos labels (coluna labels_csv de pr_listar_abertos); reteste expresso vem das TAGS.
mrs_abertos() {
  LISTA=$(pr_listar_abertos) || return 1
  printf "%s\n" "$LISTA" | while read -r I B LB; do
    [ -n "$I" ] || continue
    case ",$LB," in
      *,Suspeita\ de\ checagem,*) P=2 ;;
      *,Prioridade::1,*)          P=3 ;;
      *,Prioridade::2,*)          P=4 ;;
      *,Prioridade::3,*)          P=5 ;;
      *)                          P=6 ;;
    esac
    ID=$(id_da_branch "$B"); RC=$(ultima_rc "$ID"); N=${RC##*.}
    if [ -n "$RC" ] && [ "$N" -gt 1 ]; then
      ANT="rc/$ID.$(( N - 1 ))"
      if case "$(estado "$ANT")" in qa-nok|hom-nok) true ;; *) tem "hom-ajuste/${ANT#rc/}" ;; esac; then
        P=1
      fi
    fi
    echo "$I $B $P"
  done
}

publicada()        { git tag --points-at "origin/$1" -l "$1.*" --sort=-refname --sort=-creatordate 2> /dev/null | head -1; }   # build publicada = tag do ambiente no commit de origin/AMB
ultima_build()     { git tag -l "$1.*" --sort=-refname --sort=-creatordate | head -1; }        # última montada (qa ou hom)
assunto()          { [ -z "$1" ] || git tag -l --format='%(contents:subject)' "$1"; }
manifesto_de()     { [ -z "$1" ] || git tag -l --format='%(contents:body)' "$1"; }
contem()           { awk -v r="$2" '$1 == r {f = 1} END {exit !f}' "$1"; }
ordenar_por_data() { while read -r RC IID T; do echo "$(data_tag "$1/${RC#rc/}") $RC $IID $T"; done | sort -n | cut -d' ' -f2-; }

# entregas aprovadas vigentes: última entrega do ID, com a decisão, sem "nok"/retirada, fora da main
aprovadas_vigentes() {
  git tag -l "$1/*" | while read -r T; do
    RC="rc/${T#*/}"; ID=${RC#rc/}; ID=${ID%.*}
    case "$ID" in hotfix-*) continue ;; esac
    [ "$(ultima_rc "$ID")" = "$RC" ] || continue
    git merge-base --is-ancestor "$RC" origin/main && continue
    case "$(estado "$RC")" in retirada|qa-nok|hom-nok) continue ;; esac
    echo "$RC"
  done
}

hotfix_aguardando_qa() {
  LISTA=$(mrs_abertos) || return 1
  printf "%s\n" "$LISTA" | while read -r _ SRC _; do
    [ -n "$SRC" ] || continue
    case "$SRC" in hotfix/*)
      RC=$(ultima_rc "$(id_da_branch "$SRC")")
      if [ -n "$RC" ] && [ "$(estado "$RC")" = teste ]; then echo "$SRC"; fi ;;
    esac
  done
}
