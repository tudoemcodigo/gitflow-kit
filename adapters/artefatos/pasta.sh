#!/bin/sh
# adapters/artefatos/pasta.sh: repositório de artefatos em pasta ($ARTEFATOS_DIR).
# Um pacote por commit: app-<sha>.zip + app-<sha>.zip.sha256; nunca sobrescreve.

_art_dir() { : "${ARTEFATOS_DIR:?ARTEFATOS_DIR não definido}"; printf '%s\n' "$ARTEFATOS_DIR"; }
_art_hash() { sha256sum "$1" | cut -d' ' -f1; }

artefatos_existe() {   # SHA
  _d=$(_art_dir) || return 1
  [ -f "$_d/app-$1.zip" ] && [ -f "$_d/app-$1.zip.sha256" ]
}

artefatos_publicar() {   # SHA ZIP
  _d=$(_art_dir) || return 1
  if [ -e "$_d/app-$1.zip" ] || [ -e "$_d/app-$1.zip.sha256" ]; then
    echo "pacote app-$1.zip já existe: nunca é sobrescrito." >&2; return 1
  fi
  [ -f "$2" ] || { echo "zip não encontrado: $2" >&2; return 1; }
  mkdir -p "$_d"
  cp "$2" "$_d/app-$1.zip"
  printf '%s  app-%s.zip\n' "$(_art_hash "$_d/app-$1.zip")" "$1" > "$_d/app-$1.zip.sha256"
}

artefatos_baixar() {   # SHA DESTINO (diretório, ou caminho do arquivo)
  _d=$(_art_dir) || return 1
  artefatos_existe "$1" || { echo "pacote app-$1.zip não existe." >&2; return 1; }
  _esp=$(cut -d' ' -f1 < "$_d/app-$1.zip.sha256" | tr -d '\015')
  _real=$(_art_hash "$_d/app-$1.zip")
  if [ "$_esp" != "$_real" ]; then
    echo "SHA-256 de app-$1.zip diverge do registrado." >&2; return 1
  fi
  if [ -d "$2" ]; then cp "$_d/app-$1.zip" "$2/app-$1.zip"; else cp "$_d/app-$1.zip" "$2"; fi
}
