#!/usr/bin/env bash
# Sign release artifacts with GPG if a key is available.
# Usage: scripts/sign_release.sh dist/*.tar.gz dist/*.zip dist/*.deb dist/*.rpm
set -euo pipefail

if ! command -v gpg >/dev/null 2>&1; then
  echo "gpg not found; install it to sign artifacts" >&2
  exit 1
fi

KEY_ID="${GPG_KEY_ID:-}" # optionally set env GPG_KEY_ID to force a specific key

ARTS=("$@")
if [ ${#ARTS[@]} -eq 0 ]; then
  echo "No artifacts provided. Example: scripts/sign_release.sh dist/*" >&2
  exit 1
fi

for f in "${ARTS[@]}"; do
  if [ ! -f "$f" ]; then
    echo "Missing file $f" >&2; exit 1
  fi
  echo "Signing $f"
  if [ -n "$KEY_ID" ]; then
    gpg --batch --yes --local-user "$KEY_ID" --armor --detach-sign "$f"
  else
    gpg --batch --yes --armor --detach-sign "$f"
  fi
done

echo "Done. Generated .asc signatures next to artifacts."
