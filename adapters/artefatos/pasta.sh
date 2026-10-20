#!/bin/sh
# adapters/artefatos/pasta.sh: repositório de artefatos em pasta ($ARTEFATOS_DIR).
# Um pacote por commit: app-<sha>.zip + app-<sha>.zip.sha256; nunca sobrescreve.

_art_dir() { : "${ARTEFATOS_DIR:?ARTEFATOS_DIR não definido}"; printf '%s\n' "$ARTEFATOS_DIR"; }
_art_hash() { sha256sum "$1" | cut -d' ' -f1; }

artefatos_existe() {   # SHA
  _d=$(_art_dir) || return 1
  [ -f "$_d/app-$1.zip" ] && [ -f "$_d/app-$1.zip.sha256" ]
}

# escreve em nomes temporários e renomeia sem sobrescrever (ln falha se o destino existe);
# o .sha256 é renomeado antes do zip: o zip só aparece com o hash já registrado
artefatos_publicar() {   # SHA ZIP
  _d=$(_art_dir) || return 1
  if [ -e "$_d/app-$1.zip" ] || [ -e "$_d/app-$1.zip.sha256" ]; then
    echo "pacote app-$1.zip já existe: nunca é sobrescrito." >&2; return 1
  fi
  [ -f "$2" ] || { echo "zip não encontrado: $2" >&2; return 1; }
  _h=$(_art_hash "$2")
  if [ -f "$2.sha256" ]; then   # hash local (gerado no build) precisa bater com o zip
    _loc=$(cut -d' ' -f1 < "$2.sha256" | tr -d '\015')
    if [ "$_loc" != "$_h" ]; then
      echo "SHA-256 de $2 diverge do $2.sha256." >&2; return 1
    fi
  fi
  mkdir -p "$_d"
  _t=$(mktemp -d "$_d/.pub.XXXXXX") || return 1
  cp "$2" "$_t/zip" && printf '%s  app-%s.zip\n' "$_h" "$1" > "$_t/sha"
  if [ "$(_art_hash "$_t/zip")" != "$_h" ]; then
    rm -rf "$_t"; echo "falha ao copiar o pacote." >&2; return 1
  fi
  if ! ln "$_t/sha" "$_d/app-$1.zip.sha256" 2> /dev/null; then
    rm -rf "$_t"; echo "pacote app-$1.zip já existe: nunca é sobrescrito." >&2; return 1
  fi
  if ! ln "$_t/zip" "$_d/app-$1.zip" 2> /dev/null; then
    rm -f "$_d/app-$1.zip.sha256"; rm -rf "$_t"
    echo "pacote app-$1.zip já existe: nunca é sobrescrito." >&2; return 1
  fi
  rm -rf "$_t"
}

artefatos_baixar() {   # SHA DESTINO (diretório, ou caminho do arquivo)
  _d=$(_art_dir) || return 1
  artefatos_existe "$1" || { echo "pacote app-$1.zip não existe." >&2; return 1; }
  _esp=$(cut -d' ' -f1 < "$_d/app-$1.zip.sha256" | tr -d '\015')
  if [ -d "$2" ]; then _dest="$2/app-$1.zip"; else _dest=$2; fi
  _tmp="$_dest.baixando.$$"
  cp "$_d/app-$1.zip" "$_tmp" || { rm -f "$_tmp"; return 1; }
  if [ "$(_art_hash "$_tmp")" != "$_esp" ]; then
    rm -f "$_tmp"; echo "SHA-256 de app-$1.zip diverge do registrado." >&2; return 1
  fi
  mv -f "$_tmp" "$_dest"
}
