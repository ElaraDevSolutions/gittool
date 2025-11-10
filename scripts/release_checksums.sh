#!/usr/bin/env bash
# Generate release archives and SHA256 checksums for gittool.
# Usage:
#   scripts/release_checksums.sh --version v1.0.5
#   scripts/release_checksums.sh --version=v1.0.5
#   scripts/release_checksums.sh -v v1.0.5
set -euo pipefail

VERSION=""
OUT_DIR="dist"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<EOF
Generate release archives and SHA256 checksums for gittool.

Usage: $0 --version vX.Y.Z
  --version vX.Y.Z    Version tag (space separated)
  --version=vX.Y.Z    Version tag (equals form)
  -v vX.Y.Z           Short version flag
  -h, --help          Show this help text
EOF
}

# Parse arguments, accepting both '--version value' and '--version=value'
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version=*) VERSION="${1#*=}"; shift ;;
    --version)  [[ $# -lt 2 ]] && { echo "Missing value after --version" >&2; usage; exit 1; }; VERSION="$2"; shift 2 ;;
    -v)         [[ $# -lt 2 ]] && { echo "Missing value after -v" >&2; usage; exit 1; }; VERSION="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "Missing --version argument (e.g. --version v1.0.5)" >&2
  usage
  exit 1
fi

mkdir -p "$OUT_DIR"
ARCHIVE_BASENAME="gittool-${VERSION}"
ARCHIVE_TGZ="$OUT_DIR/${ARCHIVE_BASENAME}.tar.gz"
ARCHIVE_ZIP="$OUT_DIR/${ARCHIVE_BASENAME}.zip"
CHECKSUM_FILE="$OUT_DIR/SHA256SUMS"
NUM_VERSION="${VERSION#v}"

echo "==> Creating archives for version $VERSION"
tar -czf "$ARCHIVE_TGZ" -C "$PROJECT_ROOT" install.sh src README.md LICENCE.md || {
  echo "Failed to create tar.gz archive" >&2; exit 1; }
zip -q -r "$ARCHIVE_ZIP" install.sh src README.md LICENCE.md || {
  echo "Failed to create zip archive" >&2; exit 1; }

echo "==> Generating SHA256 checksums (relative filenames)"
rm -f "$CHECKSUM_FILE"
pushd "$OUT_DIR" >/dev/null
{
  shasum -a 256 "$(basename "$ARCHIVE_TGZ")"
  shasum -a 256 "$(basename "$ARCHIVE_ZIP")"
  # Include native packages if they were already built
  if [ -f "gittool_${NUM_VERSION}_all.deb" ]; then
    shasum -a 256 "gittool_${NUM_VERSION}_all.deb"
  fi
  if [ -f "gittool-${NUM_VERSION}-1.noarch.rpm" ]; then
    shasum -a 256 "gittool-${NUM_VERSION}-1.noarch.rpm"
  fi
} > "$(basename "$CHECKSUM_FILE")"
popd >/dev/null

echo "==> Checksums written to $CHECKSUM_FILE"
echo "==> Example verification:"
echo "    shasum -a 256 -c <(grep install.sh $CHECKSUM_FILE | sed 's# $PROJECT_ROOT/##')" 

echo "Artifacts present in $OUT_DIR:"
ls -1 "$OUT_DIR" | sed 's/^/  /'
echo "==> SHA256SUMS contents:"; cat "$CHECKSUM_FILE"
echo "Done."
