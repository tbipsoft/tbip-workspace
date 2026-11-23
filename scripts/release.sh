#!/usr/bin/env bash
#
# Gera o pacote de release de um app do workspace.
#
#   ./scripts/release.sh <app>            ex.: ./scripts/release.sh controller-test
#   PLATFORM=linux-arm64 ./scripts/release.sh <app>   sobrescreve a plataforma detectada
#
# Saida em <app>/dist:
#   <app>-<versao>-<plataforma>           binario principal
#   <app>-<versao>-<plataforma>.tar.gz    binarios + launcher de <app>/scripts
#   <app>-<versao>-<plataforma>.tar.gz.sha256
#
#   <app>.tar.gz + <app>.tar.gz.sha256    copia para a GitHub Release (so em linux-arm64);
#                                         sao estes nomes que o instalador e o Manager baixam
#
# O tbip-manager e so shell: nao compila e gera apenas tbip-manager.tar.gz + .sha256.
#
# Dentro do .tar.gz os binarios mantem o nome original, porque e por ele que o launcher
# os procura.

set -euo pipefail

die() { echo "erro: $*" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-}"
[ -n "$APP" ] || die "uso: $0 <app>"

APP_DIR="$ROOT/$APP"
MANIFEST="$APP_DIR/Cargo.toml"

write_sha() {
  if command -v sha256sum >/dev/null; then
    (cd "$DIST" && sha256sum "$1" > "$1.sha256")
  else
    (cd "$DIST" && shasum -a 256 "$1" > "$1.sha256")
  fi
}

# O Manager le version.txt na branch main para saber se ha atualizacao.
read_version_file() {
  [ -f "$APP_DIR/version.txt" ] || die "falta $APP/version.txt"
  tr -d ' \r\n' < "$APP_DIR/version.txt"
}

if [ "$APP" = "tbip-manager" ]; then
  SCRIPT="$APP_DIR/TBIP Manager.sh"
  [ -f "$SCRIPT" ] || die "nao encontrado: $SCRIPT"
  [ -f "$APP_DIR/catalog.json" ] || die "falta $APP/catalog.json"
  VERSION="$(read_version_file)"
  SCRIPT_VERSION="$(sed -nE 's/^MANAGER_VER="([^"]+)".*/\1/p' "$SCRIPT")"
  [ "$VERSION" = "$SCRIPT_VERSION" ] ||
    die "version.txt ($VERSION) difere de MANAGER_VER ($SCRIPT_VERSION)"
  if command -v jq >/dev/null; then
    jq -e '.tools | length > 0' "$APP_DIR/catalog.json" >/dev/null || die "catalog.json invalido"
  fi

  DIST="$APP_DIR/dist"
  STAGE="$(mktemp -d)"
  trap 'rm -rf "$STAGE"' EXIT
  cp "$SCRIPT" "$APP_DIR/catalog.json" "$STAGE/"
  chmod 755 "$STAGE/TBIP Manager.sh"
  chmod 644 "$STAGE/catalog.json"
  mkdir -p "$DIST"
  (cd "$STAGE" && COPYFILE_DISABLE=1 tar -czf "$DIST/$APP.tar.gz" -- *)
  write_sha "$APP.tar.gz"

  echo "Pronto em $DIST ($VERSION):"
  echo "  $APP.tar.gz"
  echo "  $APP.tar.gz.sha256"
  cat "$DIST/$APP.tar.gz.sha256"
  exit 0
fi

[ -f "$MANIFEST" ] || die "app nao encontrado: $APP"
command -v cargo >/dev/null || die "cargo nao encontrado no PATH"

# Imprime as linhas "chave = valor" de uma secao do Cargo.toml.
section() {
  awk -v header="[$1]" '
    /^\[/ { inside = ($0 == header); next }
    inside && /^[A-Za-z0-9_-]+[[:space:]]*=/ { print }
  ' "$MANIFEST"
}

toml_value() { sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*(#.*)?$//; s/^"(.*)"$/\1/'; }

VERSION="$(section package | grep -E '^version[[:space:]]*=' | head -n 1 | toml_value)"
[ -n "$VERSION" ] || die "versao nao encontrada em $MANIFEST"
VERSION_FILE="$(read_version_file)"
[ "$VERSION" = "$VERSION_FILE" ] ||
  die "$APP/version.txt ($VERSION_FILE) difere do Cargo.toml ($VERSION)"

BINS="$(awk '
  /^\[/ { inside = ($0 == "[[bin]]"); next }
  inside && /^name[[:space:]]*=/ { print }
' "$MANIFEST" | toml_value)"
[ -n "$BINS" ] || BINS="$APP"
echo "$BINS" | grep -qx "$APP" || die "binario principal '$APP' nao declarado em $MANIFEST"

detect_platform() {
  local os arch
  case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=macos ;;
    *) die "sistema nao suportado: $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    aarch64 | arm64) arch=arm64 ;;
    x86_64 | amd64) arch=amd64 ;;
    armv7l) arch=armhf ;;
    *) die "arquitetura nao suportada: $(uname -m)" ;;
  esac
  echo "$os-$arch"
}

PLATFORM="${PLATFORM:-$(detect_platform)}"
BASE="$APP-$VERSION-$PLATFORM"
DIST="$APP_DIR/dist"

# Launcher: exatamente um .sh em <app>/scripts.
LAUNCHER=""
for candidate in "$APP_DIR"/scripts/*.sh; do
  [ -f "$candidate" ] || continue
  [ -z "$LAUNCHER" ] || die "mais de um .sh em $APP_DIR/scripts"
  LAUNCHER="$candidate"
done
[ -n "$LAUNCHER" ] || die "nenhum .sh em $APP_DIR/scripts"

# Em um workspace o Cargo ignora o [profile.release] dos membros. Aplica o do app via
# ambiente para manter LTO, strip etc. e o opt-level de cada um.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  key="$(printf '%s' "${line%%=*}" | tr -d '[:space:]' | tr 'a-z-' 'A-Z_')"
  export "CARGO_PROFILE_RELEASE_$key=$(printf '%s\n' "$line" | toml_value)"
done <<< "$(section profile.release)"

echo "==> Compilando $APP $VERSION ($PLATFORM)"
(cd "$ROOT" && cargo build --release -p "$APP")

TARGET_DIR="$(cd "$ROOT" && cargo metadata --format-version 1 --no-deps |
  sed -E 's/.*"target_directory":"([^"]+)".*/\1/')"
[ -d "$TARGET_DIR/release" ] || die "pasta de build nao encontrada: $TARGET_DIR/release"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

while IFS= read -r bin; do
  [ -f "$TARGET_DIR/release/$bin" ] || die "binario nao gerado: $bin"
  cp "$TARGET_DIR/release/$bin" "$STAGE/$bin"
  chmod 755 "$STAGE/$bin"
  # PLATFORM so muda o rotulo: nao deixa publicar binario de outra arquitetura para o aparelho.
  if [ "$PLATFORM" = "linux-arm64" ]; then
    header="$(od -An -tx1 -N20 "$STAGE/$bin" | tr -d ' \n')"
    [ "${header:0:8}" = "7f454c46" ] && [ "${header:36:4}" = "b700" ] ||
      die "$bin nao e um binario Linux aarch64; compile no aparelho ou em ambiente arm64"
  fi
done <<< "$BINS"

LAUNCHER_NAME="$(basename "$LAUNCHER")"
cp "$LAUNCHER" "$STAGE/$LAUNCHER_NAME"
chmod 755 "$STAGE/$LAUNCHER_NAME"

mkdir -p "$DIST"
cp "$STAGE/$APP" "$DIST/$BASE"

echo "==> Empacotando $BASE.tar.gz"
# COPYFILE_DISABLE evita arquivos ._* do macOS dentro do pacote.
# Lista os arquivos (e nao ".") para a extracao nao alterar a permissao da pasta de destino.
(cd "$STAGE" && COPYFILE_DISABLE=1 tar -czf "$DIST/$BASE.tar.gz" -- *)

echo "==> Gerando SHA-256"
write_sha "$BASE.tar.gz"

# Nome estavel para /releases/latest/download, so para o alvo do aparelho.
rm -f "$DIST/$APP.tar.gz" "$DIST/$APP.tar.gz.sha256"
if [ "$PLATFORM" = "linux-arm64" ]; then
  cp "$DIST/$BASE.tar.gz" "$DIST/$APP.tar.gz"
  write_sha "$APP.tar.gz"
fi

echo
echo "Pronto em $DIST:"
echo "  $BASE"
echo "  $BASE.tar.gz"
echo "  $BASE.tar.gz.sha256"
cat "$DIST/$BASE.tar.gz.sha256"
if [ "$PLATFORM" = "linux-arm64" ]; then
  echo
  echo "Publique na GitHub Release:"
  echo "  $APP.tar.gz"
  echo "  $APP.tar.gz.sha256"
else
  echo
  echo "aviso: $PLATFORM nao roda no aparelho; nenhum pacote para a GitHub Release foi gerado." >&2
fi
