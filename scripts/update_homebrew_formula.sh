#!/usr/bin/env bash
# Update external Homebrew tap formula with new version and checksum.
# Assumptions:
#   - The tap repo (homebrew-tools) is checked out as a sibling directory: ../homebrew-tools
#   - Formula file path: ../homebrew-tools/Formula/gt.rb (adjust if different)
#   - Archives generated via scripts/release_checksums.sh exist in dist/
# Usage:
#   scripts/update_homebrew_formula.sh --version v1.0.5
set -euo pipefail

VERSION=""
for arg in "$@"; do
  case "$arg" in
    --version=*) VERSION="${arg#*=}" ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# //' ; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "Missing --version vX.Y.Z" >&2; exit 1
fi

VERSION_NO_V="${VERSION#v}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT/dist"
TAP_DIR="$ROOT/../homebrew-tools"
FORMULA="$TAP_DIR/Formula/gt.rb"

if [[ ! -d "$TAP_DIR" ]]; then
  echo "Tap directory not found: $TAP_DIR" >&2; exit 1
fi
if [[ ! -f "$FORMULA" ]]; then
  echo "Formula file not found: $FORMULA" >&2; exit 1
fi

TARBALL="gittool-v${VERSION_NO_V}.tar.gz"
if [[ ! -f "$DIST_DIR/$TARBALL" ]]; then
  echo "Archive $DIST_DIR/$TARBALL not found. Run release_checksums.sh first." >&2; exit 1
fi

SHA256=$(shasum -a 256 "$DIST_DIR/$TARBALL" | awk '{print $1}')
echo "Updating formula to version $VERSION with sha256 $SHA256"

# Perform in-place edits: replace url and sha256 lines
tmp_file="$(mktemp)"
awk -v ver="$VERSION" -v sha="$SHA256" 'BEGIN{u_done=0;s_done=0} {
  if ($0 ~ /url "/ && u_done==0) { gsub(/v[0-9.]+/, ver); print; u_done=1; next }
  if ($0 ~ /sha256 "/ && s_done==0) { gsub(/"[0-9a-f]+"/, "\"" sha "\""); print; s_done=1; next }
  print
}' "$FORMULA" > "$tmp_file"

mv "$tmp_file" "$FORMULA"
echo "Formula updated: $FORMULA"
echo "Next steps: commit and push in tap repo"
echo "  cd '$TAP_DIR' && git add Formula/gt.rb && git commit -m 'gt: update to $VERSION' && git push"
