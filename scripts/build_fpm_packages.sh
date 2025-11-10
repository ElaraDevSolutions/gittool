#!/usr/bin/env bash
# Build .deb and .rpm packages for gittool using fpm.
#
# Prerequisites:
#   - Ruby + fpm gem installed (gem install --user-install fpm)
#   - Or package manager install (apt-get install ruby ruby-dev && gem install fpm)
#
# Usage examples:
#   scripts/build_fpm_packages.sh --version v1.0.4
#   scripts/build_fpm_packages.sh            # auto-detect version from last tag
#
# Output packages will be placed under dist/:
#   dist/gittool_<version>_all.deb
#   dist/gittool-<version>-1.noarch.rpm (name may vary by fpm defaults)
#
# Package contents layout:
#   /usr/lib/gittool/{gt.sh,git.sh,ssh.sh}
#   /usr/bin/gt (wrapper)
#   /usr/share/doc/gittool/README.md
#   /usr/share/licenses/gittool/LICENCE.md
#
# The wrapper simply executes gt.sh with passed arguments.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
  # Attempt auto-detect via git tags
  if command -v git >/dev/null 2>&1 && git -C "$PROJECT_ROOT" describe --tags --abbrev=0 >/dev/null 2>&1; then
    VERSION="$(git -C "$PROJECT_ROOT" describe --tags --abbrev=0 | sed 's/^v//')"
  else
    echo "Unable to auto-detect version (provide --version vX.Y.Z)" >&2
    exit 1
  fi
else
  VERSION="${VERSION#v}"  # strip leading v for package version semantics
fi

if ! command -v fpm >/dev/null 2>&1; then
  echo "fpm not found. Install with: gem install --user-install fpm" >&2
  exit 1
fi

echo "==> Building gittool packages version $VERSION"
DIST_DIR="$PROJECT_ROOT/dist"
STAGE_DIR="$PROJECT_ROOT/.pkgstage"
# Preserve existing dist (may already contain source archives) – only clean staging area.
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/usr/lib/gittool" "$STAGE_DIR/usr/bin" "$STAGE_DIR/usr/share/doc/gittool" "$STAGE_DIR/usr/share/licenses/gittool" "$DIST_DIR"

# Copy scripts
cp "$PROJECT_ROOT/src/gt.sh" "$PROJECT_ROOT/src/git.sh" "$PROJECT_ROOT/src/ssh.sh" "$STAGE_DIR/usr/lib/gittool/"
chmod 0755 "$STAGE_DIR/usr/lib/gittool"/*.sh

# Wrapper
cat > "$STAGE_DIR/usr/bin/gt" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="/usr/lib/gittool"
exec bash "$SCRIPT_DIR/gt.sh" "$@"
EOF
chmod 0755 "$STAGE_DIR/usr/bin/gt"

# Docs / license
cp "$PROJECT_ROOT/README.md" "$STAGE_DIR/usr/share/doc/gittool/README.md"
cp "$PROJECT_ROOT/LICENCE.md" "$STAGE_DIR/usr/share/licenses/gittool/LICENCE.md" || true

DESCRIPTION="A small CLI helper wrapping Git and managing multiple SSH keys (gt)."
VENDOR="ElaraDevSolutions"
LICENSE="MIT"  # Adjust if LICENCE.md differs
URL="https://github.com/ElaraDevSolutions/gittool"

FPM_COMMON=( -s dir -n gittool -v "$VERSION" --description "$DESCRIPTION" --vendor "$VENDOR" --url "$URL" --license "$LICENSE" --maintainer "${USER:-gittool}" --architecture all -C "$STAGE_DIR" usr/lib/gittool usr/bin/gt usr/share/doc/gittool usr/share/licenses/gittool )

echo "==> Creating .deb"
fpm -t deb --deb-no-default-config-files -p "$DIST_DIR/gittool_${VERSION}_all.deb" "${FPM_COMMON[@]}"

echo "==> Creating .rpm"
fpm -t rpm -p "$DIST_DIR/gittool-${VERSION}-1.noarch.rpm" "${FPM_COMMON[@]}"

echo "==> Packages created:"
ls -1 "$DIST_DIR"

echo "==> Done creating native packages (.deb/.rpm)"
echo "NOTE: Combined SHA256SUMS will be generated later by release_checksums.sh after archives are built."

echo "Done. Packages ready in $DIST_DIR."
