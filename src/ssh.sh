#!/usr/bin/env bash
set -euo pipefail

SSH_DIR="$HOME/.ssh"
CONFIG_FILE="$SSH_DIR/config"

ensure_ssh_dir_and_config() {
	if [ ! -d "$SSH_DIR" ]; then
		mkdir -p "$SSH_DIR" && chmod 700 "$SSH_DIR"
	fi
	if [ ! -f "$CONFIG_FILE" ]; then
		: > "$CONFIG_FILE" && chmod 600 "$CONFIG_FILE"
	fi
}

show_help() {
	cat <<EOF
Commands (shortcuts):
	add    (-a) [pattern|path]  Create a new key (no args) or register existing key by pattern or explicit path.
	remove (-r) <HostAlias>     Remove SSH key files and its config block.
	list   (-l)                 List configured Host aliases.
	select                      Select a configured HostAlias and rewrite current Git origin URL to use it.
	help   (-h)                 Show this help message.

Pattern example:
	gt ssh add personal
	  - Searches for existing key files containing 'personal' not yet in config.
	  - If exactly one match, it's registered automatically; if multiple, interactive selection (fzf or select).
EOF
}

list_host_aliases() {
	if [ ! -f "$CONFIG_FILE" ]; then
		echo "No SSH config file found at $CONFIG_FILE."
		return 1
	fi
	echo "Current HostAliases in $CONFIG_FILE:"
	grep -E '^Host[[:space:]]+[^ ]+$' "$CONFIG_FILE" | awk '{print $2}' || true
}

remove_ssh_key() {
	local HOST_ALIAS="$1"
	ensure_ssh_dir_and_config
	if [ -z "${HOST_ALIAS:-}" ]; then echo "Missing HostAlias."; show_help; return 1; fi
	if ! grep -qE "^Host[[:space:]]+${HOST_ALIAS}$" "$CONFIG_FILE"; then echo "Host '${HOST_ALIAS}' not found in $CONFIG_FILE."; return 0; fi
	echo "Removing configuration for Host '${HOST_ALIAS}'..."
	awk -v alias="$HOST_ALIAS" '
		BEGIN {skip=0}
		/^Host[[:space:]]+/ {
			if ($2 == alias) { skip=1; next } else if (skip) { skip=0 }
		}
		skip==0 { print }
	' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
	KEYFILE="$SSH_DIR/id_ed25519_${HOST_ALIAS}"
	if [ -f "$KEYFILE" ]; then ssh-add -d "$KEYFILE" || true; rm -f "$KEYFILE"; echo "Private key removed: $KEYFILE"; fi
	if [ -f "$KEYFILE.pub" ]; then rm -f "$KEYFILE.pub"; echo "Public key removed: $KEYFILE.pub"; fi
	echo "Removal completed."
}

add_ssh_key() {
	ensure_ssh_dir_and_config
	local ARG="${1:-}"

	extract_alias() {
		local f="$1" b
		b="$(basename "$f")"; b="${b%.pub}"
		if [[ "$b" == id_ed25519_* ]]; then printf '%s' "${b#id_ed25519_}"; else printf '%s' "$b"; fi
	}

	register_key_file() {
		local keyfile="$1" alias="$2" hostname="$3"
		if grep -qE "^Host[[:space:]]+${alias}$" "$CONFIG_FILE" 2>/dev/null; then echo "Configuration for '${alias}' already exists in $CONFIG_FILE."; return 0; fi
		echo "Adding configuration to $CONFIG_FILE..."
		{
			echo "Host $alias"
			echo "  AddKeysToAgent yes"
			echo "  HostName $hostname"
			echo "  User git"
			echo "  IdentityFile $keyfile"
			echo "  IdentitiesOnly yes"
		} >> "$CONFIG_FILE"
		chmod 600 "$keyfile" || true
		if ssh-add "$keyfile" 2>/dev/null; then echo "Key added to ssh-agent: $keyfile"; else echo "Warning: ssh-add failed for $keyfile (continuing)" >&2; fi
		echo "Configuration added: $alias"
	}

	search_and_select_existing_key() {
		local pattern="$1"
		# Initialize arrays explicitly to avoid unbound errors with set -u
		local -a files
		local -a candidates
		files=()
		candidates=()
		if [ -d "$SSH_DIR" ]; then
			# Use find; suppress errors if directory unreadable
			while IFS= read -r f; do files+=("$f"); done < <(find "$SSH_DIR" -maxdepth 1 -type f -name "*${pattern}*" ! -name "*.pub" 2>/dev/null || true)
		fi
		# Only iterate if there is at least one file (protect against unbound expansion)
		if [ ${#files[@]} -gt 0 ]; then
			for f in "${files[@]}"; do
				local a="$(extract_alias "$f")"
				if ! grep -qE "^Host[[:space:]]+${a}$" "$CONFIG_FILE" 2>/dev/null; then
					candidates+=("$f")
				fi
			done
		fi
		if [ ${#candidates[@]} -eq 0 ]; then
			echo "No existing key file matching '${pattern}' found (or all already configured)." >&2
			return 1
		fi
		local chosen=""
		if [ ${#candidates[@]} -eq 1 ]; then
			chosen="${candidates[0]}"
		else
			if command -v fzf >/dev/null 2>&1; then
				chosen="$(printf '%s\n' "${candidates[@]}" | sort | fzf --prompt="Key> ")"
			else
				echo "Multiple matching keys found:" >&2
				select f in "${candidates[@]}"; do [ -n "$f" ] && chosen="$f" && break; done
			fi
		fi
		if [ -z "${chosen}" ]; then
			echo "No selection made." >&2
			return 1
		fi
		local alias="$(extract_alias "$chosen")"
		read -p "HostName (default: github.com): " HOSTNAME
		HOSTNAME=${HOSTNAME:-github.com}
		register_key_file "$chosen" "$alias" "$HOSTNAME"
	}

	if [ -n "$ARG" ]; then
		local KEY_PATH="$ARG"; KEY_PATH="${KEY_PATH%.pub}"
		if [ -f "$KEY_PATH" ]; then
			local BASENAME="$(basename "$KEY_PATH")" HOST_ALIAS
			if [[ "$BASENAME" == id_ed25519_* ]]; then HOST_ALIAS="${BASENAME#id_ed25519_}"; else HOST_ALIAS="$BASENAME"; fi
			read -p "HostName (default: github.com): " HOSTNAME; HOSTNAME=${HOSTNAME:-github.com}
			register_key_file "$KEY_PATH" "$HOST_ALIAS" "$HOSTNAME"
		else
			search_and_select_existing_key "$ARG" || exit 1
		fi
	else
		read -p "HostName (default: github.com): " HOSTNAME; HOSTNAME=${HOSTNAME:-github.com}
		read -p "Key name (e.g.: personal): " HOST_ALIAS; [ -z "${HOST_ALIAS}" ] && { echo "Key name cannot be empty."; exit 1; }
		if echo "$HOST_ALIAS" | grep -q '[[:space:]]'; then echo "Key name cannot contain spaces."; exit 1; fi
		local KEYFILE="$SSH_DIR/id_ed25519_${HOST_ALIAS}"
		if [ -f "$KEYFILE" ]; then echo "SSH key already exists: $KEYFILE"; else read -p "Email for the key: " EMAIL; [ -z "${EMAIL}" ] && { echo "Email cannot be empty."; exit 1; }; echo "Generating SSH key..."; ssh-keygen -t ed25519 -C "$EMAIL" -f "$KEYFILE"; fi
		register_key_file "$KEYFILE" "$HOST_ALIAS" "$HOSTNAME"
	fi
}

main() {
	if [ $# -eq 0 ]; then show_help; exit 0; fi
	case "$1" in
		add|-a) shift || true; add_ssh_key "${1:-}" ;;
		remove|-r) shift || true; remove_ssh_key "${1:-}" ;;
		list|-l) list_host_aliases ;;
		select)
			shift || true
			ensure_ssh_dir_and_config
			if [ ! -f "$CONFIG_FILE" ]; then echo "No SSH config file found."; exit 1; fi
			# Portable alias collection without 'mapfile'
			local -a aliases
			aliases=()
			while IFS= read -r line; do
				local host_alias
				host_alias="$(echo "$line" | awk '{print $2}')"
				[ -n "$host_alias" ] && aliases+=("$host_alias")
			done < <(grep -E '^Host[[:space:]]+[^ ]+$' "$CONFIG_FILE" || true)
			if [ ${#aliases[@]} -eq 0 ]; then echo "No HostAliases configured."; exit 1; fi
			local chosen=""
			if [ ${#aliases[@]} -eq 1 ]; then
				chosen="${aliases[0]}"
			else
				if command -v fzf >/dev/null 2>&1; then
					chosen="$(printf '%s\n' "${aliases[@]}" | sort | fzf --prompt="Alias> ")"
				else
					echo "Select HostAlias:" >&2
					select a in "${aliases[@]}"; do [ -n "$a" ] && chosen="$a" && break; done
				fi
			fi
			if [ -z "${chosen:-}" ]; then echo "No selection made."; exit 1; fi
			# Validate inside a Git repo
			if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then echo "Not inside a Git repository."; exit 1; fi
			# Get current origin URL
			if ! current_url="$(git remote get-url origin 2>/dev/null)"; then echo "Remote 'origin' not found."; exit 1; fi
			if [[ ! "$current_url" =~ ^git@([^:]+):(.+) ]]; then echo "Origin is not an SSH URL (git@host:path)."; exit 1; fi
			# Replace host with chosen alias
			local new_url
			new_url="$(echo "$current_url" | sed -E "s#^git@[^:]+:#git@${chosen}:#")"
			git remote set-url origin "$new_url"
			echo "Updated origin to: $new_url"
			;;
		help|-h) show_help ;;
		*) echo "Unknown command: $1"; show_help; exit 1 ;;
	esac
}

main "$@"
