#!/usr/bin/env bash
set -euo pipefail

# Simple vault module for gittool
# - Stores a master secret encrypted with GPG in ~/.gittool/vault

GITTOOL_CONFIG_DIR="${GITTOOL_CONFIG_DIR:-$HOME/.gittool}"
VAULT_DIR="$GITTOOL_CONFIG_DIR/vault"

usage() {
	cat <<EOF
gt vault <command>

Commands:
  init           Initialize vault using your default GPG key and a master secret.
  show-master    Decrypt and print the master secret.
  help           Show this help.
EOF
}

ensure_vault_dir() {
	mkdir -p "$VAULT_DIR"
}

vault_init() {
	# Prevent re-init if there's already a vault file
	if [ -d "$VAULT_DIR" ] && ls "$VAULT_DIR"/vault-*.gpg >/dev/null 2>&1; then
		echo "Vault is already initialized in $VAULT_DIR" >&2
		return 0
	fi

	ensure_vault_dir

	if ! command -v gpg >/dev/null 2>&1; then
		echo "Error: gpg is required but not installed." >&2
		exit 1
	fi

	# Parse flags/args:
	#   -p|--password <value> : master password to use (non-empty)
	#   [key_id]              : GPG key id override (advanced use)
	local master_from_flag=""
	local key_id=""
	while [ "$#" -gt 0 ]; do
		case "$1" in
			-p|--password)
				shift || true
				master_from_flag="${1:-}"
				;;
			*)
				if [ -z "$key_id" ]; then
					key_id="$1"
				fi
				;;
		esac
		shift || true
	done

	if [ -z "$key_id" ]; then
		key_id="$(gpg --list-keys --with-colons 2>/dev/null | awk -F: '/^pub/ {print $5; exit}')"
	fi
	if [ -z "$key_id" ]; then
		# No key found: create a non-interactive RSA key specifically for the vault
		local key_params
		key_params="$VAULT_DIR/gpg-key-params.txt"
		cat >"$key_params" <<EOF
Key-Type: RSA
Key-Length: 3072
Subkey-Type: RSA
Subkey-Length: 3072
Name-Real: gittool-vault
Name-Comment: auto-generated key for gittool vault
Name-Email: gittool-vault@local
Expire-Date: 0
%no-protection
%commit
EOF
		echo "No GPG key found. Generating a new RSA key for gittool vault..." >&2
		gpg --batch --generate-key "$key_params"
		# Re-read the first public key as our default
		key_id="$(gpg --list-keys --with-colons 2>/dev/null | awk -F: '/^pub/ {print $5; exit}')"
		if [ -z "$key_id" ]; then
			echo "Error: failed to generate a GPG key for the vault." >&2
			exit 1
		fi
	fi

	# Determine master secret:
	# - If -p/--password was provided, use that (no prompt).
	# - Else if running in a TTY, ask interactively.
	# - Else generate a random one.
	local master
	if [ -n "$master_from_flag" ]; then
		master="$master_from_flag"
	elif [ -t 0 ]; then
		local first confirm
		printf "Enter master password (leave empty to auto-generate): " >&2
		stty -echo 2>/dev/null || true
		IFS= read -r first || true
		stty echo 2>/dev/null || true
		printf "\n" >&2
		if [ -n "$first" ]; then
			printf "Confirm master password: " >&2
			stty -echo 2>/dev/null || true
			IFS= read -r confirm || true
			stty echo 2>/dev/null || true
			printf "\n" >&2
			if [ "$first" != "$confirm" ]; then
				echo "Passwords do not match. Aborting." >&2
				exit 1
			fi
			master="$first"
		fi
	fi
	if [ -z "${master:-}" ]; then
		if command -v openssl >/dev/null 2>&1; then
			master="$(openssl rand -base64 32)"
		else
			master="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 32 || true)"
			if [ -z "$master" ]; then
				master="master-$(date +%s)"
			fi
		fi
		echo "Generated master secret (DO NOT SHARE)." >&2
	fi

	echo "Encrypting master secret with GPG key: $key_id" >&2

	# Generate a random id for the vault filename
	local file_id master_file
	if command -v openssl >/dev/null 2>&1; then
		file_id="$(openssl rand -hex 8)"
	else
		file_id="$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c 16 || true)"
		[ -z "$file_id" ] && file_id="$(date +%s)"
	fi
	master_file="$VAULT_DIR/vault-${file_id}.gpg"

	# Encrypt using the provided GPG public key (asymmetric)
	printf "%s" "$master" | gpg --batch --yes \
		--encrypt --armor \
		-r "$key_id" \
		-o "$master_file"

	if [ ! -s "$master_file" ]; then
		echo "Error: failed to create encrypted master password file." >&2
		exit 1
	fi

	echo "Vault initialized at $master_file" >&2
}

vault_show_master() {
	if ! command -v gpg >/dev/null 2>&1; then
		echo "Error: gpg is required but not installed." >&2
		exit 1
	fi

	# Find the first vault-*.gpg file
	local master_file
	if [ ! -d "$VAULT_DIR" ]; then
		echo "Vault is not initialized. Run 'gt vault init' first." >&2
		exit 1
	fi
	master_file="$(ls "$VAULT_DIR"/vault-*.gpg 2>/dev/null | head -n 1 || true)"
	if [ -z "$master_file" ] || [ ! -f "$master_file" ]; then
		echo "Vault is not initialized. Run 'gt vault init' first." >&2
		exit 1
	fi

	# Let gpg handle any required passphrase/pinentry for the private key
	# and normalize output by stripping trailing whitespace/newlines.
	local value
	if ! value="$(gpg --quiet --decrypt "$master_file" 2>/dev/null | tr -d '\r' | sed -e 's/[[:space:]]*$//')"; then
		echo "Failed to decrypt master password." >&2
		exit 1
	fi

	printf '%s\n' "$value"
}

main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
		init)
			vault_init "$@"
			;;
		show-master|--master|-m)
			vault_show_master "$@"
			;;
		help|-h|--help)
			usage
			;;
		"")
			usage
			;;
		*)
			echo "Unknown vault command: $cmd" >&2
			usage >&2
			exit 1
			;;
	esac
}

main "$@"

