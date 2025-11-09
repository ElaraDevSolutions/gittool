#!/usr/bin/env bash
# Generate release archives and SHA256 checksums for gittool.
# Usage: scripts/release_checksums.sh --version v1.0.5
set -euo pipefail

VERSION=""
OUT_DIR="dist"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for arg in "$@"; do
  case "$arg" in
    --version=*) VERSION="${arg#*=}" ;;
    -h|--help)
      echo "Usage: $0 --version vX.Y.Z"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "Missing --version argument (e.g. --version v1.0.5)" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
ARCHIVE_BASENAME="gittool-${VERSION}"
ARCHIVE_TGZ="$OUT_DIR/${ARCHIVE_BASENAME}.tar.gz"
ARCHIVE_ZIP="$OUT_DIR/${ARCHIVE_BASENAME}.zip"
CHECKSUM_FILE="$OUT_DIR/SHA256SUMS"

echo "==> Creating archives for version $VERSION"
tar -czf "$ARCHIVE_TGZ" -C "$PROJECT_ROOT" install.sh src README.md LICENCE.md || {
  echo "Failed to create tar.gz archive" >&2; exit 1; }
zip -q -r "$ARCHIVE_ZIP" install.sh src README.md LICENCE.md || {
  echo "Failed to create zip archive" >&2; exit 1; }

echo "==> Generating SHA256 checksums"
rm -f "$CHECKSUM_FILE"
{
  shasum -a 256 "$ARCHIVE_TGZ"
  shasum -a 256 "$ARCHIVE_ZIP"
  shasum -a 256 "$PROJECT_ROOT/install.sh"
} > "$CHECKSUM_FILE"

echo "==> Checksums written to $CHECKSUM_FILE"
echo "==> Example verification:"
echo "    shasum -a 256 -c <(grep install.sh $CHECKSUM_FILE | sed 's# $PROJECT_ROOT/##')" 

echo "Artifacts:"
echo "  $ARCHIVE_TGZ"
echo "  $ARCHIVE_ZIP"
echo "  $CHECKSUM_FILE"
echo "Done."
