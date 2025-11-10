#!/usr/bin/env bash
# Update external Homebrew tap formula with new version and checksum.
# Features:
#   - Clone tap repository if missing (default: https://github.com/ElaraDevSolutions/homebrew-tools.git)
#   - Update gt.rb formula with new version and SHA256 from dist/ tarball.
#   - Flexible options for version and tap location.
#   - Can optionally git commit + push with --commit.
# Usage:
#   scripts/update_homebrew_formula.sh --version v1.2.3 --commit
#   scripts/update_homebrew_formula.sh --version=v1.2.3 --tap-url https://github.com/YourOrg/homebrew-tools.git
# Flags:
#   --version / --version= / -v   Version (e.g. v1.2.3)
#   --tap-url URL                 Tap repository URL (HTTPS)
#   --tap-dir DIR                 Destination directory (default: ../homebrew-tools)
#   --commit                      Perform git add/commit/push
#   -h / --help                   Show help text
# Auth for cross-repo push:
#   Requires a PAT with repo permissions (secret HOMEBREW_TAP_PAT). GITHUB_TOKEN usually cannot push to another repo.
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

# Clone or update tap
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

# Edit formula file
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
  # Auth: prefer HOMEBREW_TAP_PAT if present; fallback to GITHUB_TOKEN (may fail cross-repo)
  GIT_PUSH_TOKEN="${HOMEBREW_TAP_PAT:-${GITHUB_TOKEN:-}}"
  if [[ -z "$GIT_PUSH_TOKEN" ]]; then
    echo "WARNING: No token (HOMEBREW_TAP_PAT or GITHUB_TOKEN) set; skipping push." >&2
  else
  # Rewrite origin remote to embed token (only for github HTTPS URL)
    if [[ "$TAP_URL" == https://github.com/* ]]; then
      (cd "$TAP_DIR" && git remote set-url origin "https://${GITHUB_ACTOR:-bot}:$GIT_PUSH_TOKEN@github.com/${TAP_URL#https://github.com/}" )
    fi
    (cd "$TAP_DIR" && git push origin HEAD) || { echo "Push failed" >&2; exit 1; }
  fi
fi

echo "Done."
