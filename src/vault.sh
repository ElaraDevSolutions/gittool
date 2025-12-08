#!/usr/bin/env bash
set -euo pipefail

# Simple vault module for gittool
# - Stores a master secret encrypted with GPG in ~/.gittool/vault

GITTOOL_CONFIG_DIR="${GITTOOL_CONFIG_DIR:-$HOME/.gittool}"
VAULT_DIR="$GITTOOL_CONFIG_DIR/vault"
GITTOOL_CFG_ROOT="${GITTOOL_CFG_ROOT:-$HOME/.config/gittool}"
GITTOOL_CFG_FILE="$GITTOOL_CFG_ROOT/vault"

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

calculate_expire_date() {
	local days="$1"
	if [ -z "$days" ] || [ "$days" = "0" ]; then
		echo "0"
		return
	fi
	if date -v+1d +%Y-%m-%d >/dev/null 2>&1; then
		# BSD/macOS date
		date -v+"${days}"d +%Y-%m-%d 2>/dev/null || echo "0"
	else
		# GNU date fallback
		date -d "+${days} days" +%Y-%m-%d 2>/dev/null || echo "0"
	fi
}

write_local_vault_config() {
	# Persist local vault provider configuration to ~/.config/gittool/vault
	# Format (single local provider, always overwritten on init inside [vault] section):
	# [vault]
	# provider=local
	# path=/absolute/path/to/vault-XXXX.gpg
	# expires=<iso-date>
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
		# Write expires date (ISO-8601) only if non-zero or previously set
		local expire_date
		expire_date="$(calculate_expire_date "$expire_days")"
		if [ "$expire_date" != "0" ]; then
			echo "expires=$expire_date"
		elif [ -n "$existing_expires" ]; then
			echo "$existing_expires"
		fi
		# Preserve existing ssh_hosts mapping if present
		[ -n "$existing_ssh_hosts" ] && echo "$existing_ssh_hosts"
	} >"$GITTOOL_CFG_FILE"

	rm -f "$tmp" "$original_tmp" 2>/dev/null || true
}

vault_init() {
	local general_cfg="$GITTOOL_CFG_ROOT/config"
	if [ -f "$general_cfg" ] && grep -qE "^bitwarden=true" "$general_cfg"; then
		local provider="local"
		if command -v fzf >/dev/null 2>&1; then
			provider="$(printf "local\nbitwarden" | fzf --height=20% --layout=reverse --border --prompt="Vault Provider> ")"
		else
			echo "Select Vault Provider:" >&2
			PS3="Enter number> "
			select p in "local" "bitwarden"; do
				if [ -n "$p" ]; then
					provider="$p"
					break
				else
					echo "Invalid selection." >&2
				fi
			done
		fi

		if [ "$provider" = "bitwarden" ]; then
			echo "Bitwarden provider selected."
			return 0
		fi
	fi

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

		local gpg_expire_date
		gpg_expire_date="$(calculate_expire_date "$expire_days")"

		cat >"$key_params" <<EOF
Key-Type: RSA
Key-Length: 3072
Subkey-Type: RSA
Subkey-Length: 3072
Name-Real: gittool-vault
Name-Comment: auto-generated key for gittool vault
Name-Email: gittool-vault@local
Expire-Date: $gpg_expire_date
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

vault_update_expiration() {
	local days="$1"
	[ -z "$days" ] && return 0
	
	local expire_date
	expire_date="$(calculate_expire_date "$days")"
	[ -z "$expire_date" ] && return 0

	mkdir -p "$GITTOOL_CFG_ROOT"
	touch "$GITTOOL_CFG_FILE"
	
	if ! grep -qE '^\[vault\]' "$GITTOOL_CFG_FILE" 2>/dev/null; then
		return 0
	fi

	if grep -q "^expires=" "$GITTOOL_CFG_FILE"; then
		awk -v d="$expire_date" '/^expires=/{print "expires=" d; next} {print}' "$GITTOOL_CFG_FILE" > "$GITTOOL_CFG_FILE.tmp" && mv "$GITTOOL_CFG_FILE.tmp" "$GITTOOL_CFG_FILE"
	else
		awk -v d="$expire_date" '
			/^\[vault\]/{print;printed=1;next}
			printed==1 && !seen && /^\[/{print "expires=" d;seen=1}
			{print}
			END{if(printed==1 && !seen)print "expires=" d}
		' "$GITTOOL_CFG_FILE" >"$GITTOOL_CFG_FILE.tmp" && mv "$GITTOOL_CFG_FILE.tmp" "$GITTOOL_CFG_FILE"
	fi
	echo "Vault expiration updated to $expire_date" >&2
}

vault_set_bitwarden() {
	local enabled="$1"
	local general_cfg="$GITTOOL_CFG_ROOT/config"
	mkdir -p "$GITTOOL_CFG_ROOT"
	[ -f "$general_cfg" ] || touch "$general_cfg"

	local current_status="false"
	if grep -q "^bitwarden=true" "$general_cfg"; then
		current_status="true"
	fi

	if [ "$enabled" = "true" ] && [ "$current_status" = "true" ]; then
		echo "Bitwarden integration is already enabled."
		return 1
	fi

	if grep -q "^bitwarden=" "$general_cfg"; then
		# Replace existing line
		if [ "$(uname)" = "Darwin" ]; then
			sed -i '' "s/^bitwarden=.*/bitwarden=$enabled/" "$general_cfg"
		else
			sed -i "s/^bitwarden=.*/bitwarden=$enabled/" "$general_cfg"
		fi
	else
		# Append new line
		echo "bitwarden=$enabled" >> "$general_cfg"
	fi
	echo "Bitwarden integration set to: $enabled"
}

write_bitwarden_config() {
	local encrypted_path="$1"
	mkdir -p "$GITTOOL_CFG_ROOT"
	local tmp
	tmp="$(mktemp)"

	if [ -f "$GITTOOL_CFG_FILE" ]; then
		awk '
			BEGIN { in_bw=0; n=0 }
			/^[[]bitwarden[]]/ { in_bw=1; next }
			/^[[][^]]+[]]/ { in_bw=0 }
			in_bw==0 { lines[n++] = $0 }
			END {
				last = n - 1
				while (last >= 0 && lines[last] == "") { last-- }
				for (i = 0; i <= last; i++) {
					print lines[i]
				}
			}
		' "$GITTOOL_CFG_FILE" > "$tmp"
	else
		touch "$tmp"
	fi

	{
		if [ -s "$tmp" ]; then
			cat "$tmp"
			echo ""
		fi
		echo "[bitwarden]"
		echo "provider=bitwarden"
		echo "path=$encrypted_path"
	} > "$GITTOOL_CFG_FILE"
	rm -f "$tmp"
}

configure_bitwarden() {
	if ! command -v bw >/dev/null 2>&1; then
		echo "Error: 'bw' (Bitwarden CLI) is not installed." >&2
		echo "Please install it first: https://bitwarden.com/help/cli/" >&2
		return 1
	fi

	# Check status to see if we need to logout first
	local status_out
	status_out="$(bw status 2>/dev/null || true)"
	if echo "$status_out" | grep -qE '"status":"(locked|unlocked)"'; then
		echo "You are already logged in. Logging out to start fresh session..."
		bw logout
	fi

	echo "Logging in to Bitwarden..."
	local login_log
	login_log="$(mktemp)"

	# Run login, capture output to file (hiding stdout from user to suppress session key message)
	# Prompts should appear on stderr/tty.
	if ! bw login > "$login_log"; then
		echo "Bitwarden login failed." >&2
		rm -f "$login_log"
		return 1
	fi

	local session_key
	# Extract session key: $ export BW_SESSION="<KEY>"
	session_key="$(grep 'export BW_SESSION=' "$login_log" | cut -d'"' -f2)"
	rm -f "$login_log"

	if [ -z "$session_key" ]; then
		echo "Could not extract BW_SESSION from login output." >&2
		return 1
	fi

	# Encrypt session key
	ensure_vault_dir
	if ! command -v gpg >/dev/null 2>&1; then
		echo "Error: gpg is required for encryption." >&2
		return 1
	fi

	local key_id
	key_id="$(gpg --list-keys --with-colons 2>/dev/null | awk -F: '/^pub/ {print $5; exit}')"
	if [ -z "$key_id" ]; then
		echo "Error: No GPG key found to encrypt Bitwarden session." >&2
		echo "Please run 'gt vault init' first to generate/select a key." >&2
		return 1
	fi

	local file_id
	if command -v openssl >/dev/null 2>&1; then
		file_id="$(openssl rand -hex 8)"
	else
		file_id="$(date +%s)"
	fi
	local session_file="$VAULT_DIR/bw-session-${file_id}.gpg"

	printf "%s" "$session_key" | gpg --batch --yes \
		--encrypt --armor \
		-r "$key_id" \
		-o "$session_file"

	if [ ! -s "$session_file" ]; then
		echo "Error: failed to encrypt Bitwarden session." >&2
		return 1
	fi

	write_bitwarden_config "$session_file"
	echo "Bitwarden session key encrypted and stored in $GITTOOL_CFG_FILE"
}

remove_bitwarden_config() {
	if [ -f "$GITTOOL_CFG_FILE" ]; then
		local tmp
		tmp="$(mktemp)"
		awk '
			BEGIN { in_bw=0; n=0 }
			/^[[]bitwarden[]]/ { in_bw=1; next }
			/^[[][^]]+[]]/ { in_bw=0 }
			in_bw==0 { lines[n++] = $0 }
			END {
				last = n - 1
				while (last >= 0 && lines[last] == "") { last-- }
				for (i = 0; i <= last; i++) {
					print lines[i]
				}
			}
		' "$GITTOOL_CFG_FILE" > "$tmp" && mv "$tmp" "$GITTOOL_CFG_FILE"
	fi
}

deconfigure_bitwarden() {
	if command -v bw >/dev/null 2>&1; then
		echo "Logging out from Bitwarden..."
		bw logout 2>/dev/null || true
	fi

	# Find and remove the encrypted session file
	local bw_path
	if [ -f "$GITTOOL_CFG_FILE" ]; then
		bw_path="$(awk '
			BEGIN { in_bw=0 }
			/^[[]bitwarden[]]/ { in_bw=1; next }
			/^[[][^]]+[]]/ { in_bw=0 }
			in_bw==1 && /^path=/ { print substr($0, 6); exit }
		' "$GITTOOL_CFG_FILE")"
	fi

	remove_bitwarden_config

	if [ -n "$bw_path" ] && [ -f "$bw_path" ]; then
		rm -f "$bw_path"
		echo "Removed encrypted session file: $bw_path"
	fi
	echo "Bitwarden configuration removed from $GITTOOL_CFG_FILE"
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
		update-expiration)
			vault_update_expiration "$@"
			;;
		--enable-bitwarden)
			if vault_set_bitwarden "true"; then
				configure_bitwarden
			fi
			;;
		--disable-bitwarden)
			vault_set_bitwarden "false"
			deconfigure_bitwarden
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

