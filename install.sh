#!/usr/bin/env bash
###############################################################################
# gittool install script
#
# Installs the scripts under a chosen prefix and creates a "gt" wrapper in <prefix>/bin.
# Works on macOS and Linux. Requires: bash, cp, mkdir, grep, sed.
# This script also checks for and attempts to install GnuPG (gpg) and fzf
# using the native package manager when possible.
#
# Quick usage (installs to /usr/local if writable, otherwise ~/.local):
#   curl -fsSL https://raw.githubusercontent.com/<OWNER>/<REPO>/latest/install.sh | bash
#
# Options:
#   --prefix=DIR     Installation prefix (default: auto-detected)
#   --force          Overwrite existing files
#   --uninstall      Remove an existing installation (same prefix logic)
#   --dry-run        Show actions without performing them
#   -h|--help        Show this help summary
#
# Installed layout:
#   <prefix>/lib/gittool/{gt.sh,git.sh,ssh.sh,vault.sh,doctor.sh}
#   <prefix>/bin/gt (wrapper)
#
# Identification marker (for safe uninstall): line containing: GT_INSTALL_WRAPPER_MARKER
###############################################################################
set -euo pipefail

SCRIPT_DIR_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/src"
DEFAULT_PREFIX="/usr/local"

# Decide default prefix: /usr/local if writable; otherwise ~/.local
detect_default_prefix() {
  if [[ -w "$DEFAULT_PREFIX" ]] || sudo -n test -w "$DEFAULT_PREFIX" 2>/dev/null; then
    echo "$DEFAULT_PREFIX"
  else
    echo "$HOME/.local"
  fi
}

PREFIX="$(detect_default_prefix)"
FORCE=0
UNINSTALL=0
DRY_RUN=0

print_help() {
  sed -n '1,50p' "$0" | grep -E '^#( |$)' | sed 's/^# ?//'
}

for arg in "$@"; do
  case "$arg" in
    --prefix=*) PREFIX="${arg#*=}" ;;
    --force) FORCE=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) print_help; exit 0 ;;
  *) echo "[ERROR] Unknown option: $arg" >&2; exit 1 ;;
  esac
done

LIB_DIR="$PREFIX/lib/gittool"
BIN_DIR="$PREFIX/bin"
WRAPPER="$BIN_DIR/gt"

announce() { echo "==> $*"; }
do_cmd() { if (( DRY_RUN )); then echo "DRY: $*"; else eval "$@"; fi }

detect_os() {
  # Prints: macos | linux | other
  local uname
  uname="$(uname -s 2>/dev/null || echo unknown)"
  case "$uname" in
    Darwin) echo "macos" ;;
    Linux)  echo "linux" ;;
    *)      echo "other" ;;
  esac
}

ensure_tool() {
  # ensure_tool <binary> <brew_formula> <linux_pkg_name>
  local bin="$1"; local brew_pkg="$2"; local linux_pkg="$3"
  if command -v "$bin" >/dev/null 2>&1; then
    return 0
  fi

  local os
  os="$(detect_os)"

  if (( DRY_RUN )); then
    echo "DRY: would ensure presence of $bin (os=$os, brew=$brew_pkg, linux_pkg=$linux_pkg)"
    return 0
  fi

  case "$os" in
    macos)
      if command -v brew >/dev/null 2>&1; then
        announce "Installing missing dependency '$bin' via Homebrew ($brew_pkg)"
        if ! brew install "$brew_pkg"; then
          echo "[ERROR] Failed to install $brew_pkg via Homebrew. Please install $bin manually." >&2
          exit 1
        fi
      else
        echo "[ERROR] '$bin' is required but not found, and Homebrew is not available on macOS." >&2
        echo "        Install Homebrew from https://brew.sh/ or install $brew_pkg manually and re-run." >&2
        exit 1
      fi
      ;;
    linux)
      # Try common package managers in a best-effort, non-interactive way
      if command -v apt-get >/dev/null 2>&1; then
        announce "Installing missing dependency '$bin' via apt-get ($linux_pkg)"
        if ! sudo apt-get update -y && sudo apt-get install -y "$linux_pkg"; then
          echo "[ERROR] Failed to install $linux_pkg via apt-get. Please install $bin manually." >&2
          exit 1
        fi
      elif command -v dnf >/dev/null 2>&1; then
        announce "Installing missing dependency '$bin' via dnf ($linux_pkg)"
        if ! sudo dnf install -y "$linux_pkg"; then
          echo "[ERROR] Failed to install $linux_pkg via dnf. Please install $bin manually." >&2
          exit 1
        fi
      elif command -v yum >/dev/null 2>&1; then
        announce "Installing missing dependency '$bin' via yum ($linux_pkg)"
        if ! sudo yum install -y "$linux_pkg"; then
          echo "[ERROR] Failed to install $linux_pkg via yum. Please install $bin manually." >&2
          exit 1
        fi
      elif command -v pacman >/dev/null 2>&1; then
        announce "Installing missing dependency '$bin' via pacman ($linux_pkg)"
        if ! sudo pacman -Sy --noconfirm "$linux_pkg"; then
          echo "[ERROR] Failed to install $linux_pkg via pacman. Please install $bin manually." >&2
          exit 1
        fi
      else
        echo "[ERROR] '$bin' is required but was not found. No supported package manager detected." >&2
        echo "        Please install it manually and re-run this installer." >&2
        exit 1
      fi
      ;;
    *)
      echo "[ERROR] '$bin' is required but OS detection failed or is unsupported." >&2
      echo "        Please install it manually and re-run this installer." >&2
      exit 1
      ;;
  esac
}

ensure_dirs() {
  announce "Creating directories ($LIB_DIR, $BIN_DIR)"
  do_cmd "mkdir -p '$LIB_DIR'"
  do_cmd "mkdir -p '$BIN_DIR'"
}

install_files() {
  announce "Copying scripts to $LIB_DIR"
  # Keep this list in sync with src/ helpers used by gt.sh
  for f in gt.sh git.sh ssh.sh vault.sh doctor.sh; do
    if [[ ! -f "$SCRIPT_DIR_SRC/$f" ]]; then
  echo "[ERROR] Source file not found: $SCRIPT_DIR_SRC/$f" >&2; exit 1
    fi
    if [[ -f "$LIB_DIR/$f" && $FORCE -ne 1 ]]; then
  echo "[ERROR] $LIB_DIR/$f already exists (use --force to overwrite)" >&2; exit 1
    fi
    do_cmd "cp '$SCRIPT_DIR_SRC/$f' '$LIB_DIR/$f'"
    do_cmd "chmod 0755 '$LIB_DIR/$f'"
  done
}

create_wrapper() {
  announce "Creating wrapper $WRAPPER"
  if [[ -f "$WRAPPER" && $FORCE -ne 1 ]]; then
  # If it's already our wrapper, allow silent overwrite
    if grep -q 'GT_INSTALL_WRAPPER_MARKER' "$WRAPPER" 2>/dev/null; then
      :
    else
  echo "[ERROR] $WRAPPER already exists and does not look like this project (use --force to overwrite)" >&2; exit 1
    fi
  fi
  local tmp_file
  tmp_file="$(mktemp)"
  cat > "$tmp_file" <<'EOF'
#!/usr/bin/env bash
# GT_INSTALL_WRAPPER_MARKER
# Wrapper generated by gittool install.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib/gittool" && pwd)"
exec bash "$SCRIPT_DIR/gt.sh" "$@"
EOF
  do_cmd "mv '$tmp_file' '$WRAPPER'"
  do_cmd "chmod 0755 '$WRAPPER'"
}

perform_install() {
  # Ensure core runtime dependencies
  ensure_tool gpg gnupg gnupg
  # fzf is optional but highly recommended for a good UX; install if missing.
  ensure_tool fzf fzf fzf || true

  ensure_dirs
  install_files
  create_wrapper
  # Write VERSION into user config so gt -v has a canonical source
  local config_dir config_version_file src_version_file ver
  config_dir="${HOME}/.config/gittool"
  config_version_file="${config_dir}/VERSION"
  src_version_file="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/VERSION"
  if [[ -f "$src_version_file" ]] && ver="$(tr -d '\n' < "$src_version_file" 2>/dev/null)" && [[ -n "$ver" ]]; then
    announce "Writing VERSION $ver to $config_version_file"
    if (( DRY_RUN )); then
      echo "DRY: would write VERSION to $config_version_file"
    else
      mkdir -p "$config_dir"
      printf '%s\n' "$ver" > "$config_version_file"
    fi
  else
    echo "[WARNING] VERSION file not found or empty; skipping config version write" >&2
  fi
  announce "Installation complete. Add $BIN_DIR to your PATH if it isn't already."
  if ! command -v gt >/dev/null 2>&1; then
  echo "[INFO] Open a new shell or export PATH:\n  export PATH=\"$BIN_DIR:\$PATH\""
  fi
}

perform_uninstall() {
  announce "Removing installation at $PREFIX"
  if [[ -f "$WRAPPER" ]] && grep -q 'GT_INSTALL_WRAPPER_MARKER' "$WRAPPER" 2>/dev/null; then
    do_cmd "rm -f '$WRAPPER'"
  announce "Removed wrapper: $WRAPPER"
  else
  echo "[WARNING] Wrapper not found or not recognized as this project: $WRAPPER" >&2
  fi
  if [[ -d "$LIB_DIR" ]]; then
    do_cmd "rm -rf '$LIB_DIR'"
  announce "Removed directory: $LIB_DIR"
  else
  echo "[WARNING] Directory not found: $LIB_DIR" >&2
  fi
  announce "Uninstall complete."
}

main() {
  if (( UNINSTALL )); then
    perform_uninstall
    return 0
  fi
  perform_install
}

main "$@"
