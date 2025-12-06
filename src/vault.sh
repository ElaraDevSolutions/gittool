#!/usr/bin/env bash
set -euo pipefail

# Simple vault module for gittool
# - Stores a master secret encrypted with GPG in ~/.gittool/vault

GITTOOL_CONFIG_DIR="${GITTOOL_CONFIG_DIR:-$HOME/.gittool}"
VAULT_DIR="$GITTOOL_CONFIG_DIR/vault"
GITTOOL_CFG_ROOT="${GITTOOL_CFG_ROOT:-$HOME/.config/gittool}"
GITTOOL_CFG_FILE="$GITTOOL_CFG_ROOT/config"

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

write_local_vault_config() {
	# Persist local vault provider configuration to ~/.config/gittool/config
	# Format (single local provider, always overwritten on init inside [vault] section):
	# [vault]
	# provider=local
	# path=/absolute/path/to/vault-XXXX.gpg
	# expires=<days>
	# ssh_hosts=comma,separated,host,aliases
	local master_file="$1" expire_days="${2:-0}"

	mkdir -p "$GITTOOL_CFG_ROOT"

	local existing_ssh_hosts="" existing_expires=""
	local original_tmp
	original_tmp="$(mktemp)"
	if [ -f "$GITTOOL_CFG_FILE" ]; then
		cp "$GITTOOL_CFG_FILE" "$original_tmp" 2>/dev/null || :
		# Extract ssh_hosts and expires only from the existing [vault] block
		existing_ssh_hosts="$(
			awk '
				BEGIN { in_vault=0 }
				/^[[]vault[]]/ { in_vault=1; next }
				/^[[][^]]+[]]/ { in_vault=0 }
				in_vault==1 && /^ssh_hosts=/ { print; exit }
			' "$original_tmp" 2>/dev/null || true
		)"
		# Preserve previous expires if present and no new value was provided
		if [ -z "$expire_days" ] || [ "$expire_days" = "0" ]; then
			existing_expires="$(
				awk '
					BEGIN { in_vault=0 }
					/^[[]vault[]]/ { in_vault=1; next }
					/^[[][^]]+[]]/ { in_vault=0 }
					in_vault==1 && /^expires=/ { print; exit }
				' "$original_tmp" 2>/dev/null || true
			)"
		fi
	fi

	# Preserve any non-[vault] content by filtering existing file, then append new block
	local tmp
	tmp="$(mktemp)"
	if [ -f "$original_tmp" ]; then
		awk '
			BEGIN { in_vault=0 }
			/^[[]vault[]]/ { in_vault=1; next }
			/^[[][^]]+[]]/ { in_vault=0 }
			in_vault==0 { print }
		' "$original_tmp" >"$tmp" 2>/dev/null || cp "$original_tmp" "$tmp" 2>/dev/null || true
	else
		: >"$tmp"
	fi

	{
		cat "$tmp"
		# Ensure a trailing newline before appending new block
		echo ""
		echo "[vault]"
		echo "provider=local"
		echo "path=$master_file"
		# Write expires only if non-zero or previously set
		if [ -n "$expire_days" ] && [ "$expire_days" != "0" ]; then
			echo "expires=$expire_days"
		elif [ -n "$existing_expires" ]; then
			echo "$existing_expires"
		fi
		# Preserve existing ssh_hosts mapping if present
		[ -n "$existing_ssh_hosts" ] && echo "$existing_ssh_hosts"
	} >"$GITTOOL_CFG_FILE"

	rm -f "$tmp" "$original_tmp" 2>/dev/null || true
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
	# Ask vault expiration in days (0 or empty means never expires)
	local expire_days_raw="" expire_days="0"
	if [ -t 0 ]; then
		printf "Vault expiration in days (0 for never): " >&2
		IFS= read -r expire_days_raw || true
	fi
	if [ -n "$expire_days_raw" ] && [ "$expire_days_raw" != "0" ]; then
		expire_days="$expire_days_raw"
	else
		expire_days="0"
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
Expire-Date: $expire_days
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

	# Persist/refresh local provider configuration for the vault
	write_local_vault_config "$master_file" "$expire_days"

	# Ensure global config file exists with default expiry warning threshold
	# ~/.config/gittool/config -> vault_expiry_warn_days=5 (if not present)
	local general_cfg="$GITTOOL_CFG_ROOT/config"
	if [ ! -f "$general_cfg" ]; then
		mkdir -p "$GITTOOL_CFG_ROOT"
		printf '%s\n' "vault_expiry_warn_days=5" >"$general_cfg"
	elif ! grep -qE '^vault_expiry_warn_days=' "$general_cfg" 2>/dev/null; then
		printf '%s\n' "vault_expiry_warn_days=5" >>"$general_cfg"
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

