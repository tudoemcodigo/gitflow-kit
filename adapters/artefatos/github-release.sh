#!/bin/sh
# adapters/artefatos/github-release.sh: artefatos como assets da Release `pacotes` (prerelease, criada se nao existir).
# shellcheck disable=SC2016  # $var dentro de filtros jq nao e expansao de shell
# Um pacote por commit: app-<sha>.zip + app-<sha>.zip.sha256; nunca sobrescreve. Requer o provider github
# (gh_api, gh_paginar, gh_upload, gh_baixar). Falha de API nunca e lida como "existe"/"sucesso" (fail-closed).

_ghr_tag() { printf '%s' "${ARTEFATOS_RELEASE_TAG:-pacotes}"; }

# _ghr_id : id da release; 44 = nao existe; outro != 0 = erro
_ghr_id() {
  _ghr_d=$(gh_api GET "$(_gh_r)/releases/tags/$(_gh_enc "$(_ghr_tag)")") || return $?
  _ghr_i=$(printf '%s' "$_ghr_d" | _gjq -r '.id // empty') || return 1
  [ -n "$_ghr_i" ] || return 1
  printf '%s\n' "$_ghr_i"
}

# _ghr_garantir : id da release, criando-a como prerelease se nao existir
_ghr_garantir() {
  _ghg_i=$(_ghr_id) && { printf '%s\n' "$_ghg_i"; return 0; }
  [ $? -eq 44 ] || return 1
  _ghg_b=$(_gjq -nc --arg tag "$(_ghr_tag)" '{tag_name: $tag, name: $tag, prerelease: true,
    body: "Pacotes de build (gerenciada pelo gitflow). Nao apagar."}') || return 1
  _ghg_d=$(gh_api POST "$(_gh_r)/releases" "$_ghg_b") || {
    _ghg_rc=$?
    # corrida: outra execucao criou entre a checagem e o POST
    [ "$_ghg_rc" -eq 42 ] && _ghr_id
    return
  }
  _ghg_i=$(printf '%s' "$_ghg_d" | _gjq -r '.id // empty') || return 1
  [ -n "$_ghg_i" ] || return 1
  printf '%s
' "$_ghg_i"
}

# _ghr_asset ID NOME : imprime o id do asset NOME da release ID (vazio = ausente); !=0 = erro
_ghr_asset() {
  _gha_d=$(gh_paginar "$(_gh_r)/releases/$1/assets?per_page=100") || return 1
  printf '%s' "$_gha_d" | _gjq -s -r --arg n "$2" '[.[][] | select(.name == $n)] | first | .id // empty'
}

# 0 = existe (zip e sha256 presentes); 1 = nao existe; 2 = erro ao consultar
artefatos_existe() {   # SHA
  _ghe_i=$(_ghr_id) || { [ $? -eq 44 ] && return 1; return 2; }
  _ghe_z=$(_ghr_asset "$_ghe_i" "app-$1.zip") || return 2
  _ghe_s=$(_ghr_asset "$_ghe_i" "app-$1.zip.sha256") || return 2
  [ -n "$_ghe_z" ] && [ -n "$_ghe_s" ]
}

# _ghr_up ID NOME ARQUIVO TIPO : imprime o id do asset criado
_ghr_up() {
  _ghu_d=$(gh_upload "/repos/${GITHUB_REPOSITORY:?}/releases/$1/assets?name=$(_gh_enc "$2")" "$3" "$4") || return 1
  _ghu_i=$(printf '%s' "$_ghu_d" | _gjq -r '.id // empty') || return 1
  [ -n "$_ghu_i" ] || return 1
  printf '%s\n' "$_ghu_i"
}

artefatos_publicar() {   # SHA ZIP
  [ -f "$2" ] || { echo "zip não encontrado: $2" >&2; return 1; }
  _ghp_h=$(sha256sum "$2" | cut -d' ' -f1)
  if [ -f "$2.sha256" ]; then   # hash local (gerado no build) precisa bater com o zip
    _ghp_l=$(cut -d' ' -f1 < "$2.sha256" | tr -d '\015')
    if [ "$_ghp_l" != "$_ghp_h" ]; then
      echo "SHA-256 de $2 diverge do $2.sha256." >&2; return 1
    fi
  fi
  _ghp_i=$(_ghr_garantir) || { echo "não foi possível obter a release de pacotes." >&2; return 1; }
  _ghp_z=$(_ghr_asset "$_ghp_i" "app-$1.zip") || return 1
  _ghp_s=$(_ghr_asset "$_ghp_i" "app-$1.zip.sha256") || return 1
  if [ -n "$_ghp_z" ] || [ -n "$_ghp_s" ]; then
    echo "pacote app-$1.zip já existe: nunca é sobrescrito." >&2; return 1
  fi
  _ghp_t=$(mktemp -d) || return 1
  printf '%s  app-%s.zip\n' "$_ghp_h" "$1" > "$_ghp_t/sha"
  # o .sha256 sobe antes do zip: o pacote so "existe" com o hash ja registrado
  if ! _ghp_sid=$(_ghr_up "$_ghp_i" "app-$1.zip.sha256" "$_ghp_t/sha" 'text/plain'); then
    rm -rf "$_ghp_t"; echo "pacote app-$1.zip já existe ou o envio falhou." >&2; return 1
  fi
  if ! _ghr_up "$_ghp_i" "app-$1.zip" "$2" 'application/zip' > /dev/null; then
    gh_api DELETE "$(_gh_r)/releases/assets/$_ghp_sid" > /dev/null || true
    rm -rf "$_ghp_t"; echo "pacote app-$1.zip já existe ou o envio falhou." >&2; return 1
  fi
  rm -rf "$_ghp_t"
}

artefatos_baixar() {   # SHA DESTINO (diretório, ou caminho do arquivo)
  _ghd_i=$(_ghr_id) || {
    if [ $? -eq 44 ]; then echo "pacote app-$1.zip não existe." >&2; else echo "erro ao consultar a release de pacotes." >&2; fi
    return 1
  }
  _ghd_z=$(_ghr_asset "$_ghd_i" "app-$1.zip") || return 1
  _ghd_s=$(_ghr_asset "$_ghd_i" "app-$1.zip.sha256") || return 1
  if [ -z "$_ghd_z" ] || [ -z "$_ghd_s" ]; then echo "pacote app-$1.zip não existe." >&2; return 1; fi
  if [ -d "$2" ]; then _ghd_dest="$2/app-$1.zip"; else _ghd_dest=$2; fi
  _ghd_tmp="$_ghd_dest.baixando.$$"
  gh_baixar "$(_gh_r)/releases/assets/$_ghd_s" "$_ghd_tmp.sha" || { rm -f "$_ghd_tmp.sha"; return 1; }
  _ghd_esp=$(cut -d' ' -f1 < "$_ghd_tmp.sha" | tr -d '\015')
  rm -f "$_ghd_tmp.sha"
  [ -n "$_ghd_esp" ] || { echo "SHA-256 registrado de app-$1.zip ilegível." >&2; return 1; }
  gh_baixar "$(_gh_r)/releases/assets/$_ghd_z" "$_ghd_tmp" || { rm -f "$_ghd_tmp"; return 1; }
  if [ "$(sha256sum "$_ghd_tmp" | cut -d' ' -f1)" != "$_ghd_esp" ]; then
    rm -f "$_ghd_tmp"; echo "SHA-256 de app-$1.zip diverge do registrado." >&2; return 1
  fi
  mv -f "$_ghd_tmp" "$_ghd_dest"
}
