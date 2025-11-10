#!/usr/bin/env bash
# Update external Homebrew tap formula with new version and checksum.
# Features:
#   - Clona o repositório do tap se não existir (default: https://github.com/ElaraDevSolutions/homebrew-tools.git)
#   - Atualiza a fórmula gt.rb com nova versão e sha256 do tarball gerado em dist/
#   - Opções flexíveis para versão e caminho do tap.
#   - Pode fazer commit + push automático com --commit.
# Uso:
#   scripts/update_homebrew_formula.sh --version v1.2.3 --commit
#   scripts/update_homebrew_formula.sh --version=v1.2.3 --tap-url https://github.com/YourOrg/homebrew-tools.git
# Flags:
#   --version / --version= / -v   Versão (ex: v1.2.3)
#   --tap-url URL                 URL do repo tap (HTTPS)
#   --tap-dir DIR                 Diretório destino (default: ../homebrew-tools)
#   --commit                      Faz git add/commit/push
#   -h / --help                   Mostra ajuda
# Auth para push cross-repo:
#   Necessário PAT com permissões repo (ex: segredo HOMEBREW_TAP_PAT). GITHUB_TOKEN NÃO consegue push em outro repo.
set -euo pipefail

VERSION=""
TAP_URL="https://github.com/ElaraDevSolutions/homebrew-tools.git"
TAP_DIR_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/../homebrew-tools"
TAP_DIR="$TAP_DIR_DEFAULT"
DO_COMMIT=0

usage() { grep '^# ' "$0" | sed 's/^# //' ; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version=*) VERSION="${1#*=}"; shift ;;
    --version|-v) VERSION="$2"; shift 2 ;;
    --tap-url) TAP_URL="$2"; shift 2 ;;
    --tap-dir) TAP_DIR="$2"; shift 2 ;;
    --commit) DO_COMMIT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "Missing --version vX.Y.Z" >&2; usage; exit 1
fi

VERSION_NO_V="${VERSION#v}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT/dist"

# Clonar ou atualizar tap
if [[ ! -d "$TAP_DIR/.git" ]]; then
  echo "Cloning tap repo $TAP_URL into $TAP_DIR";
  git clone "$TAP_URL" "$TAP_DIR"
else
  echo "Updating existing tap repo at $TAP_DIR";
  (cd "$TAP_DIR" && git pull --ff-only)
fi

FORMULA="$TAP_DIR/Formula/gt.rb"
if [[ ! -f "$FORMULA" ]]; then
  echo "Formula file not found: $FORMULA" >&2; exit 1
fi

TARBALL="gittool-v${VERSION_NO_V}.tar.gz"
if [[ ! -f "$DIST_DIR/$TARBALL" ]]; then
  echo "Archive $DIST_DIR/$TARBALL not found. Run release_checksums.sh first." >&2; exit 1
fi

SHA256=$(shasum -a 256 "$DIST_DIR/$TARBALL" | awk '{print $1}')
echo "Updating formula to version $VERSION with sha256 $SHA256"

# Editar fórmula
tmp_file="$(mktemp)"
awk -v ver="$VERSION" -v sha="$SHA256" 'BEGIN{u_done=0;s_done=0} {
  if ($0 ~ /url "/ && u_done==0) { gsub(/v[0-9.]+/, ver); print; u_done=1; next }
  if ($0 ~ /sha256 "/ && s_done==0) { gsub(/"[0-9a-f]+"/, "\"" sha "\""); print; s_done=1; next }
  print
}' "$FORMULA" > "$tmp_file"
mv "$tmp_file" "$FORMULA"
echo "Formula updated: $FORMULA"

if [[ $DO_COMMIT -eq 1 ]]; then
  echo "Committing and pushing changes to tap repo"
  (cd "$TAP_DIR" && git add Formula/gt.rb && git commit -m "gt: update to $VERSION" || echo "No changes to commit")
  # Autenticação: usar HOMEBREW_TAP_PAT se existir; caso contrário tentar GITHUB_TOKEN (pode falhar cross-repo)
  GIT_PUSH_TOKEN="${HOMEBREW_TAP_PAT:-${GITHUB_TOKEN:-}}"
  if [[ -z "$GIT_PUSH_TOKEN" ]]; then
    echo "WARNING: No token (HOMEBREW_TAP_PAT or GITHUB_TOKEN) set; skipping push." >&2
  else
    # Reescreve origem para incluir token (somente se URL for github HTTPS)
    if [[ "$TAP_URL" == https://github.com/* ]]; then
      (cd "$TAP_DIR" && git remote set-url origin "https://${GITHUB_ACTOR:-bot}:$GIT_PUSH_TOKEN@github.com/${TAP_URL#https://github.com/}" )
    fi
    (cd "$TAP_DIR" && git push origin HEAD) || { echo "Push failed" >&2; exit 1; }
  fi
fi

echo "Done."
