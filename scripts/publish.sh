#!/usr/bin/env bash
#
# Publica na GitHub Release do repositorio de cada app os pacotes de <app>/dist.
#
#   ./scripts/publish.sh <app> [<app>...]   ex.: ./scripts/publish.sh led-rgb system-info
#   ./scripts/publish.sh --all              todos os apps
#   ./scripts/publish.sh --dry-run --all    so valida e mostra o que seria publicado
#   ./scripts/publish.sh --replace <app>    substitui os arquivos de uma release ja existente
#
# Antes: gere os pacotes com ./scripts/release.sh <app>, faca push da main do app e
# autentique o GitHub CLI (gh auth login).
#
# A tag e v<versao>, lida de <app>/version.txt. Todos os apps sao validados antes do
# primeiro envio: se um tiver problema, nada e publicado.
#
# A fonte das tools e <app>-<versao>-linux-arm64.tar.gz. A copia <app>.tar.gz, que o
# instalador e o Manager baixam, e criada na hora do envio.

set -euo pipefail

die() { echo "erro: $*" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALL_APPS=(controller-test led-rgb remote-services system-info tbip-manager)
MANAGER="tbip-manager"

usage() { sed -n '3,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

DRY_RUN=0
REPLACE=0
USE_ALL=0
APPS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --all) USE_ALL=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --replace) REPLACE=1 ;;
    -h | --help) usage; exit 0 ;;
    -*) die "opcao desconhecida: $1" ;;
    *) APPS+=("$1") ;;
  esac
  shift
done

if [ "$USE_ALL" = 1 ]; then
  [ "${#APPS[@]}" -eq 0 ] || die "use --all ou nomes de apps, nao os dois"
  APPS=("${ALL_APPS[@]}")
fi
[ "${#APPS[@]}" -gt 0 ] || { usage; exit 1; }

for app in "${APPS[@]}"; do
  case " ${ALL_APPS[*]} " in
    *" $app "*) ;;
    *) die "app desconhecido: $app (validos: ${ALL_APPS[*]})" ;;
  esac
done

command -v git >/dev/null || die "git nao encontrado no PATH"
if [ "$DRY_RUN" = 0 ]; then
  command -v gh >/dev/null || die "GitHub CLI nao encontrado (instale com: brew install gh)"
  gh auth status >/dev/null 2>&1 || die "GitHub CLI sem login (rode: gh auth login)"
fi

PROBLEMS=0
problem() { echo "erro [$1]: $2" >&2; PROBLEMS=$((PROBLEMS + 1)); }

sha_of() {
  if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi |
    awk '{print $1}'
}

repo_of() {
  git -C "$ROOT/$1" config --get remote.origin.url |
    sed -E 's#^(git@github\.com:|ssh://git@github\.com/|https://github\.com/)##; s#\.git$##'
}

version_of() { tr -d ' \r\n' < "$ROOT/$1/version.txt"; }

# Pacote e .sha256 existem, conferem entre si e o tar.gz e legivel.
check_package() {
  local app="$1" file="$2" expected
  if [ ! -f "$file" ] || [ ! -f "$file.sha256" ]; then
    problem "$app" "falta $(basename "$file") ou seu .sha256 em dist (rode ./scripts/release.sh $app)"
    return 1
  fi
  expected="$(awk '{print tolower($1); exit}' "$file.sha256" | tr -d '\r')"
  if [ "$expected" != "$(sha_of "$file")" ]; then
    problem "$app" "hash nao confere: $(basename "$file")"
    return 1
  fi
  if ! tar -tzf "$file" >/dev/null 2>&1; then
    problem "$app" "pacote invalido: $(basename "$file")"
    return 1
  fi
}

# O aparelho so executa Linux aarch64.
check_tool_package() {
  local app="$1" version="$2" versioned header
  versioned="$ROOT/$app/dist/$app-$version-linux-arm64.tar.gz"
  check_package "$app" "$versioned" || return 0
  tar -tzf "$versioned" | grep -q '\.sh$' || problem "$app" "pacote sem launcher .sh"
  header="$(tar -xOzf "$versioned" "$app" 2>/dev/null | od -An -tx1 -N20 | tr -d ' \n' || true)"
  if [ "${header:0:8}" != "7f454c46" ] || [ "${header:36:4}" != "b700" ]; then
    problem "$app" "o binario do pacote nao e Linux aarch64"
  fi
}

# O pacote do Manager precisa ser igual aos arquivos commitados.
check_manager_package() {
  local app="$1" dir="$ROOT/$1" stable="$ROOT/$1/dist/$1.tar.gz" name
  check_package "$app" "$stable" || return 0
  for name in "TBIP Manager.sh" "catalog.json"; do
    if ! tar -xOzf "$stable" "$name" 2>/dev/null | cmp -s - "$dir/$name"; then
      problem "$app" "$name no pacote difere do repositorio (rode ./scripts/release.sh $app)"
    fi
  done
}

validate() {
  local app="$1" dir="$ROOT/$1" version repo head remote_head tag tag_commit
  if [ ! -f "$dir/version.txt" ]; then
    problem "$app" "falta version.txt (atualize o checkout do submodulo: git -C $app pull --ff-only origin main)"
    return 0
  fi
  version="$(version_of "$app")"
  tag="v$version"
  if [[ ! "$version" =~ ^[0-9A-Za-z.+-]+$ ]]; then
    problem "$app" "versao invalida: $version"
    return 0
  fi

  repo="$(repo_of "$app")"
  if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    problem "$app" "origin nao e um repositorio do GitHub: $repo"
    return 0
  fi

  # O Manager le version.txt e catalog.json da main: a release tem de sair dela.
  if [ "$(git -C "$dir" branch --show-current)" != "main" ]; then
    problem "$app" "precisa estar na branch main"
  fi
  if [ -n "$(git -C "$dir" status --porcelain)" ]; then
    problem "$app" "ha alteracoes sem commit"
  fi
  head="$(git -C "$dir" rev-parse HEAD)"
  if ! git -C "$dir" fetch -q origin main; then
    problem "$app" "nao foi possivel consultar origin/main"
    return 0
  fi
  remote_head="$(git -C "$dir" rev-parse origin/main)"
  [ "$head" = "$remote_head" ] || problem "$app" "HEAD difere de origin/main (faca pull ou push)"

  tag_commit="$(git -C "$dir" ls-remote origin "refs/tags/$tag" "refs/tags/$tag^{}" | tail -n 1 | cut -f1)"
  if [ -n "$tag_commit" ] && [ "$tag_commit" != "$head" ]; then
    problem "$app" "a tag $tag ja aponta para outro commit (suba a versao em version.txt)"
  fi
  if [ "$DRY_RUN" = 0 ] && [ "$REPLACE" = 0 ] && gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    problem "$app" "a release $tag ja existe (use --replace ou suba a versao)"
  fi

  if [ "$app" = "$MANAGER" ]; then
    check_manager_package "$app"
  else
    check_tool_package "$app" "$version"
  fi
}

assets_of() {
  local app="$1" version="$2" dist="$ROOT/$1/dist" versioned
  if [ "$app" = "$MANAGER" ]; then
    ASSETS=("$dist/$app.tar.gz" "$dist/$app.tar.gz.sha256")
    return 0
  fi
  versioned="$dist/$app-$version-linux-arm64.tar.gz"
  cp "$versioned" "$STAGE/$app.tar.gz"
  printf '%s  %s\n' "$(sha_of "$STAGE/$app.tar.gz")" "$app.tar.gz" > "$STAGE/$app.tar.gz.sha256"
  ASSETS=("$STAGE/$app.tar.gz" "$STAGE/$app.tar.gz.sha256" "$versioned" "$versioned.sha256")
}

publish() {
  local app="$1" version repo tag sha latest names file
  version="$(version_of "$app")"
  repo="$(repo_of "$app")"
  tag="v$version"
  sha="$(git -C "$ROOT/$app" rev-parse HEAD)"
  assets_of "$app" "$version"

  if [ "$DRY_RUN" = 1 ]; then
    echo "[dry-run] $repo $tag (${sha:0:7})"
    for file in "${ASSETS[@]}"; do echo "  $(basename "$file")"; done
    return 0
  fi

  echo "==> Publicando $app $tag em $repo"
  if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    gh release upload "$tag" "${ASSETS[@]}" --repo "$repo" --clobber
  else
    # Nao marcar como prerelease, mesmo em versao -alpha: o instalador e o Manager baixam
    # de /releases/latest, que ignora prereleases.
    gh release create "$tag" "${ASSETS[@]}" --repo "$repo" --target "$sha" \
      --title "$app $version" --notes "Release $version de $app." --latest
  fi

  latest="$(gh release view --repo "$repo" --json tagName --jq .tagName)"
  [ "$latest" = "$tag" ] || die "$app: a release mais recente do repositorio e $latest, nao $tag"
  names="$(gh release view "$tag" --repo "$repo" --json assets --jq '.assets[].name')"
  for file in "${ASSETS[@]}"; do
    echo "$names" | grep -qxF "$(basename "$file")" || die "$app: $(basename "$file") nao aparece na release"
  done
  echo "    ok: https://github.com/$repo/releases/tag/$tag"
}

for app in "${APPS[@]}"; do
  validate "$app"
done
[ "$PROBLEMS" -eq 0 ] || die "$PROBLEMS problema(s) encontrado(s); nada foi publicado"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

for app in "${APPS[@]}"; do
  publish "$app"
done

if [ "$DRY_RUN" = 1 ]; then
  echo "Validacao ok; nada foi publicado."
else
  echo "Pronto: ${#APPS[@]} app(s) publicado(s)."
fi
