#!/usr/bin/env bash
set -euo pipefail

SSH_DIR="$HOME/.ssh"
CONFIG_FILE="$SSH_DIR/config"
FZF_INLINE_OPTS="--height=40% --layout=reverse --border"

show_help() {
	cat <<EOF
Commands (shortcuts):
  add    (-a) [pattern|path]      Create new key (no args) or register existing key by pattern/path.
  remove (-r) <HostAlias>         Remove key files and its Host block.
  rotate (-R) <HostAlias> [flags] Rotate (replace) key for existing HostAlias.
  list   (-l)                     List configured Host aliases.
  select                          Rewrite current repo origin to chosen HostAlias.
  sign-status                     Show if signing key is in allowed_signers.
  help   (-h)                     Show this help.

Rotate flags:
  --dry-run    Show planned actions (no backups, no generation)
  --no-agent   Skip ssh-add of new key
  --no-sign    Skip allowed_signers & git signing setup
  --email <e>  Provide new key email non-interactively

Add flags (non-interactive):
	--alias <name>      Alias (HostAlias) for new or existing key
	--email <e>         Email comment for new key or signing setup
	--hostname <h>      HostName for config block (default: github.com)
	--path <file>       Path to existing private key file to register
	--pattern <frag>    Pattern to search inside ~/.ssh for unconfigured keys
	--no-agent          Skip ssh-add
	--no-sign           Skip allowed_signers & git signing setup
	--dry-run           Show actions only, do not modify files
EOF
}

ensure_ssh_dir_and_config() {
	mkdir -p "$SSH_DIR"
	[ -f "$CONFIG_FILE" ] || : > "$CONFIG_FILE"
}

extract_email_from_pub() { grep -E -o '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$1" | head -n1 || true; }

get_identity_file_for_alias() {
	local alias="$1" identity
	[ -f "$CONFIG_FILE" ] || return 1
	identity="$(awk -v target="$alias" '/^Host[[:space:]]+/ { in_block = ($2 == target); next } in_block && /^[[:space:]]*IdentityFile[[:space:]]+/ { print $2; exit }' "$CONFIG_FILE" || true)"
	[ -n "$identity" ] && printf '%s' "$identity"
}

rotate_ssh_key() {
	local HOST_ALIAS="" DO_AGENT=1 DO_SIGN=1 DRY_RUN=0 EMAIL_ARG=""
	while [ $# -gt 0 ]; do
		case "$1" in
			--no-agent) DO_AGENT=0; shift ;;
			--no-sign) DO_SIGN=0; shift ;;
			--dry-run) DRY_RUN=1; shift ;;
			--email) shift; EMAIL_ARG="${1:-}"; [ -z "$EMAIL_ARG" ] && { echo "--email requires value"; return 1; }; shift ;;
			-*) echo "Unknown flag for rotate: $1"; return 1 ;;
			*) [ -z "$HOST_ALIAS" ] && HOST_ALIAS="$1"; shift ;;
		esac
	done
	ensure_ssh_dir_and_config
	if [ -z "$HOST_ALIAS" ]; then echo "Missing HostAlias."; show_help; return 1; fi
	if ! grep -qE "^Host[[:space:]]+${HOST_ALIAS}$" "$CONFIG_FILE"; then echo "Host '${HOST_ALIAS}' not found in $CONFIG_FILE."; return 1; fi
	local identity_file="$(get_identity_file_for_alias "$HOST_ALIAS" || true)"
	[ -z "$identity_file" ] && { echo "Unable to determine IdentityFile for alias '$HOST_ALIAS'."; return 1; }
	local backup_suffix="old-$(date +%Y%m%d%H%M%S)"
	local old_priv="$identity_file" old_pub="${identity_file}.pub" old_pub_content=""
	[ -f "$old_pub" ] && old_pub_content="$(cat "$old_pub" || true)"
	local prev_email=""
	[ -n "$old_pub_content" ] && prev_email="$(echo "$old_pub_content" | grep -E -o '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' | head -n1 || true)"
	[ -z "$prev_email" ] && prev_email="$(git config user.email 2>/dev/null || true)"
	echo "Rotating key for alias '$HOST_ALIAS' (IdentityFile: $identity_file)"
	if [ $DRY_RUN -eq 1 ]; then
		echo "[dry-run] Would backup private key -> ${old_priv}.${backup_suffix}"
		[ -f "$old_pub" ] && echo "[dry-run] Would backup public key -> ${old_pub}.${backup_suffix}" || true
	else
		[ -f "$old_priv" ] && mv "$old_priv" "${old_priv}.${backup_suffix}" && echo "Backup private key -> ${old_priv}.${backup_suffix}" || true
		[ -f "$old_pub" ] && mv "$old_pub" "${old_pub}.${backup_suffix}" && echo "Backup public key -> ${old_pub}.${backup_suffix}" || true
	fi
	local email="$EMAIL_ARG"
	if [ -z "$email" ]; then
		# Non-interactive mode: reuse previous email silently
		if [ -n "${GITTOOL_NON_INTERACTIVE:-}" ] || [ ! -t 0 ]; then
			email="$prev_email"
		else
			read -p "Email para nova chave (enter para reutilizar '${prev_email}'): " email || true
		fi
	fi
	[ -z "$email" ] && email="$prev_email"
	if [ -z "$email" ]; then echo "Email não fornecido. Abortando."; [ $DRY_RUN -eq 0 ] && {
		[ -f "${old_priv}.${backup_suffix}" ] && mv "${old_priv}.${backup_suffix}" "$old_priv" || true
		[ -f "${old_pub}.${backup_suffix}" ] && mv "${old_pub}.${backup_suffix}" "$old_pub" || true
	}; return 1; fi
	local pass_flag="-N ''"
	if [ -z "${GITTOOL_NON_INTERACTIVE:-}" ] && [ -t 0 ]; then
		read -p "Adicionar passphrase? [y/N]: " add_pass || true
		case "$add_pass" in [yY]|[yY][eE][sS]) pass_flag="" ;; esac
	fi
	if [ $DRY_RUN -eq 1 ]; then
		echo "[dry-run] Would generate new key: ssh-keygen -t ed25519 -C '$email' -f '$identity_file'"
		echo "[dry-run] Would chmod 600 '$identity_file'"
		[ $DO_AGENT -eq 1 ] && echo "[dry-run] Would ssh-add '$identity_file'" || echo "[dry-run] Skipping agent add (--no-agent)"
		[ $DO_SIGN -eq 1 ] && echo "[dry-run] Would update allowed_signers & git signing setup" || echo "[dry-run] Skipping signing setup (--no-sign)"
		echo "[dry-run] Rotation simulated."; return 0
	fi
	if ! eval ssh-keygen -t ed25519 -C "$email" -f "$identity_file" $pass_flag; then
		echo "Falha ao gerar nova chave. Restaurando backups..."
		[ -f "${old_priv}.${backup_suffix}" ] && mv "${old_priv}.${backup_suffix}" "$old_priv" || true
		[ -f "${old_pub}.${backup_suffix}" ] && mv "${old_pub}.${backup_suffix}" "$old_pub" || true
		return 1
	fi
	chmod 600 "$identity_file" 2>/dev/null || true
	if [ $DO_AGENT -eq 1 ]; then ssh-add "$identity_file" 2>/dev/null || echo "Aviso: ssh-add falhou (continuando)" >&2; else echo "(--no-agent) Skipping ssh-add."; fi
	local allowed_file="$HOME/.config/git/allowed_signers"
	if [ $DO_SIGN -eq 1 ]; then
		if [ -n "$old_pub_content" ] && [ -f "$allowed_file" ] && grep -Fq "$old_pub_content" "$allowed_file"; then
			grep -Fv "$old_pub_content" "$allowed_file" > "${allowed_file}.tmp" && mv "${allowed_file}.tmp" "$allowed_file" && echo "Removed old key from allowed_signers." || true
		fi
		ensure_signing_setup "$identity_file" || true
	else
		echo "(--no-sign) Skipping signing setup.";
	fi
	echo "Rotação concluída para alias '$HOST_ALIAS'."
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

	# Flag variables
	local HOST_ALIAS="" EMAIL="" HOSTNAME="github.com" PATH_ARG="" PATTERN_ARG="" DO_AGENT=1 DO_SIGN=1 DRY_RUN=0

	# Parse flags (stop at first non-flag if legacy positional usage)
	while [ $# -gt 0 ]; do
		case "$1" in
			--alias) shift; HOST_ALIAS="${1:-}"; shift ;;
			--email) shift; EMAIL="${1:-}"; shift ;;
			--hostname) shift; HOSTNAME="${1:-}"; shift ;;
			--path) shift; PATH_ARG="${1:-}"; shift ;;
			--pattern) shift; PATTERN_ARG="${1:-}"; shift ;;
			--no-agent) DO_AGENT=0; shift ;;
			--no-sign) DO_SIGN=0; shift ;;
			--dry-run) DRY_RUN=1; shift ;;
			-*) echo "Unknown add flag: $1"; return 1 ;;
			*) break ;;
		esac
	done

	local LEGACY_ARG="${1:-}"

	extract_alias() {
		local f="$1" b
		b="$(basename "$f")"; b="${b%.pub}"
		if [[ "$b" == id_ed25519_* ]]; then printf '%s' "${b#id_ed25519_}"; else printf '%s' "$b"; fi
	}

	register_key_file() {
		local keyfile="$1" alias="$2" hostname="$3" do_agent="$4" do_sign="$5" dry_run="$6"
		if grep -qE "^Host[[:space:]]+${alias}$" "$CONFIG_FILE" 2>/dev/null; then echo "Configuration for '${alias}' already exists in $CONFIG_FILE."; return 0; fi
		if [ "$dry_run" -eq 1 ]; then
			echo "[dry-run] Would append Host block for '$alias' to $CONFIG_FILE"
			echo "[dry-run] Would set IdentityFile $keyfile"
			[ "$do_agent" -eq 1 ] && echo "[dry-run] Would ssh-add $keyfile" || echo "[dry-run] Skipping ssh-add (--no-agent)"
			[ "$do_sign" -eq 1 ] && echo "[dry-run] Would run signing setup" || echo "[dry-run] Skipping signing setup (--no-sign)"
			return 0
		fi
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
		if [ "$do_agent" -eq 1 ]; then
			ssh-add "$keyfile" 2>/dev/null && echo "Key added to ssh-agent: $keyfile" || echo "Warning: ssh-add failed for $keyfile (continuing)" >&2
		else
			echo "(--no-agent) Skipping ssh-add"
		fi
		[ "$do_sign" -eq 1 ] && ensure_signing_setup "$keyfile" || echo "(--no-sign) Skipping signing setup"
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
				chosen="$(printf '%s\n' "${candidates[@]}" | sort | fzf ${FZF_INLINE_OPTS} --prompt="Key> ")"
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

	# Non-interactive priority path if flags provided
	if [ -n "$PATH_ARG" ] || [ -n "$PATTERN_ARG" ] || [ -n "$HOST_ALIAS" ]; then
		if [ -n "$PATH_ARG" ]; then
			local KEY_PATH="$PATH_ARG"; KEY_PATH="${KEY_PATH%.pub}"
			if [ ! -f "$KEY_PATH" ]; then echo "Provided --path does not exist: $KEY_PATH"; return 1; fi
			if [ -z "$HOST_ALIAS" ]; then
				local BASENAME="$(basename "$KEY_PATH")"
				if [[ "$BASENAME" == id_ed25519_* ]]; then HOST_ALIAS="${BASENAME#id_ed25519_}"; else HOST_ALIAS="$BASENAME"; fi
			fi
			register_key_file "$KEY_PATH" "$HOST_ALIAS" "$HOSTNAME" "$DO_AGENT" "$DO_SIGN" "$DRY_RUN"
			return $?
		fi
		if [ -n "$PATTERN_ARG" ]; then
			# Use search path logic but without interactive selection if single match
			local -a matches; matches=()
			if [ -d "$SSH_DIR" ]; then
				while IFS= read -r f; do matches+=("$f"); done < <(find "$SSH_DIR" -maxdepth 1 -type f -name "*${PATTERN_ARG}*" ! -name "*.pub" 2>/dev/null || true)
			fi
			if [ ${#matches[@]} -eq 0 ]; then echo "No key matching pattern '${PATTERN_ARG}'"; return 1; fi
			local chosen=""
			if [ ${#matches[@]} -eq 1 ]; then chosen="${matches[0]}"; else
				if command -v fzf >/dev/null 2>&1; then chosen="$(printf '%s\n' "${matches[@]}" | sort | fzf ${FZF_INLINE_OPTS} --prompt="Key> ")"; else echo "Pattern matches multiple keys; need interactive selection; aborting (supply --path)."; return 1; fi
			fi
			local DERIVED_ALIAS="$(extract_alias "$chosen")"
			[ -z "$HOST_ALIAS" ] && HOST_ALIAS="$DERIVED_ALIAS"
			register_key_file "$chosen" "$HOST_ALIAS" "$HOSTNAME" "$DO_AGENT" "$DO_SIGN" "$DRY_RUN"
			return $?
		fi
		# Create new key if alias specified but no path/pattern
		if [ -n "$HOST_ALIAS" ] && [ -z "$LEGACY_ARG" ]; then
			if echo "$HOST_ALIAS" | grep -q '[[:space:]]'; then echo "Alias cannot contain spaces."; return 1; fi
			local KEYFILE="$SSH_DIR/id_ed25519_${HOST_ALIAS}"
			if [ -f "$KEYFILE" ]; then echo "SSH key already exists: $KEYFILE"; else
				if [ -z "$EMAIL" ]; then echo "--email required for non-interactive new key"; return 1; fi
				if [ $DRY_RUN -eq 1 ]; then
					echo "[dry-run] Would generate SSH key: $KEYFILE (email: $EMAIL)"
				else
					echo "Generating SSH key..."; ssh-keygen -t ed25519 -C "$EMAIL" -f "$KEYFILE"
				fi
			fi
			register_key_file "$KEYFILE" "$HOST_ALIAS" "$HOSTNAME" "$DO_AGENT" "$DO_SIGN" "$DRY_RUN"
			return $?
		fi
	fi

	# Legacy positional behavior preserved below
	local ARG="$LEGACY_ARG"
	if [ -n "$ARG" ]; then
		local KEY_PATH="$ARG"; KEY_PATH="${KEY_PATH%.pub}"
		if [ -f "$KEY_PATH" ]; then
			local BASENAME="$(basename "$KEY_PATH")" HOST_ALIAS
			if [[ "$BASENAME" == id_ed25519_* ]]; then HOST_ALIAS="${BASENAME#id_ed25519_}"; else HOST_ALIAS="$BASENAME"; fi
			read -p "HostName (default: github.com): " HOSTNAME; HOSTNAME=${HOSTNAME:-github.com}
			register_key_file "$KEY_PATH" "$HOST_ALIAS" "$HOSTNAME" "$DO_AGENT" "$DO_SIGN" "$DRY_RUN"
		else
			search_and_select_existing_key "$ARG" || exit 1
		fi
	else
		read -p "HostName (default: github.com): " HOSTNAME; HOSTNAME=${HOSTNAME:-github.com}
		read -p "Key name (e.g.: personal): " HOST_ALIAS; [ -z "${HOST_ALIAS}" ] && { echo "Key name cannot be empty."; exit 1; }
		if echo "$HOST_ALIAS" | grep -q '[[:space:]]'; then echo "Key name cannot contain spaces."; exit 1; fi
		local KEYFILE="$SSH_DIR/id_ed25519_${HOST_ALIAS}"
		if [ -f "$KEYFILE" ]; then echo "SSH key already exists: $KEYFILE"; else read -p "Email for the key: " EMAIL; [ -z "${EMAIL}" ] && { echo "Email cannot be empty."; exit 1; }; echo "Generating SSH key..."; ssh-keygen -t ed25519 -C "$EMAIL" -f "$KEYFILE"; fi
		register_key_file "$KEYFILE" "$HOST_ALIAS" "$HOSTNAME" "$DO_AGENT" "$DO_SIGN" "$DRY_RUN"
	fi
}

# --- Git SSH signing helpers -------------------------------------------------
ensure_signing_setup() {
	local private_key="$1"
	[ -f "$private_key" ] || return 0
	local pub_key="${private_key}.pub"
	[ -f "$pub_key" ] || { echo "Public key not found: $pub_key" >&2; return 0; }
	local allowed_file="$HOME/.config/git/allowed_signers"
	mkdir -p "$HOME/.config/git"
	[ -f "$allowed_file" ] || : > "$allowed_file"
	# Detect existing
	local pub_content email
	pub_content="$(cat "$pub_key")"
	# Attempt to discover email
	email="$(git config user.email 2>/dev/null || true)"
	if [ -z "$email" ]; then if email_from_pub="$(extract_email_from_pub "$pub_key" 2>/dev/null)"; then email="$email_from_pub"; fi; fi
	# Only prompt in interactive mode when not forced non-interactive
	if [ -z "$email" ] && [ -z "${GITTOOL_NON_INTERACTIVE:-}" ] && [ -t 0 ]; then read -p "Email not detected. Provide email for signing: " email; fi
	if [ -z "$email" ]; then echo "Empty email; skipping signing setup."; return 0; fi
	if grep -Fq "$pub_content" "$allowed_file"; then
		echo "Key already present in allowed_signers."
	else
		local ans="N"
		if [ -z "${GITTOOL_NON_INTERACTIVE:-}" ] && [ -t 0 ]; then read -p "Add key to allowed_signers for commit signing? [y/N]: " ans; fi
		case "$ans" in [yY]|[yY][eE][sS]) echo "$email $pub_content" >> "$allowed_file"; echo "Added to allowed_signers." ;; *) echo "Not added." ;; esac
	fi
	# Configure git global allowedSignersFile
	local current_allowed
	current_allowed="$(git config --global gpg.ssh.allowedSignersFile 2>/dev/null || true)"
	if [ "$current_allowed" != "$allowed_file" ]; then
		git config --global gpg.ssh.allowedSignersFile "$allowed_file"
		echo "Set gpg.ssh.allowedSignersFile -> $allowed_file"
	fi
	# Ensure signingkey points to private key (not .pub)
	local current_signing
	current_signing="$(git config --global user.signingkey 2>/dev/null || true)"
	if [ -z "$current_signing" ] || [[ "$current_signing" == *.pub ]]; then
		git config --global user.signingkey "$private_key"
		echo "Set user.signingkey -> $private_key"
	fi
	}

	sign_status() {
		local allowed_file="$HOME/.config/git/allowed_signers"
		local signing_key="$(git config --global user.signingkey 2>/dev/null || true)"
		[ -z "$signing_key" ] && { echo "No global user.signingkey set."; return 0; }
		local pub="${signing_key}.pub"
		[ -f "$pub" ] || { echo "Public key not found: $pub"; return 0; }
		if [ -f "$allowed_file" ] && grep -Fq "$(cat "$pub")" "$allowed_file"; then
			echo "Status: key IS in allowed_signers ($allowed_file)"; else echo "Status: key NOT in allowed_signers"; fi
	}

	main() {
		if [ $# -eq 0 ]; then show_help; exit 0; fi
		case "$1" in
			add|-a) shift || true; add_ssh_key "${1:-}" ;;
			remove|-r) shift || true; remove_ssh_key "${1:-}" ;;
			rotate|-R) shift || true; rotate_ssh_key "$@" ;;
			list|-l) list_host_aliases ;;
			sign-status) sign_status ;;
			select)
				shift || true
				ensure_ssh_dir_and_config
				if [ ! -f "$CONFIG_FILE" ]; then echo "No SSH config file found."; exit 1; fi
				local -a aliases
				aliases=()
				while IFS= read -r line; do aliases+=("$line"); done < <(grep -E '^Host[[:space:]]+[^ ]+$' "$CONFIG_FILE" | awk '{print $2}' || true)
				if [ ${#aliases[@]} -eq 0 ]; then echo "No Host aliases found."; exit 1; fi
				local chosen=""
				if [ ${#aliases[@]} -eq 1 ]; then chosen="${aliases[0]}"; else
					if command -v fzf >/dev/null 2>&1; then
						chosen="$(printf '%s\n' "${aliases[@]}" | fzf ${FZF_INLINE_OPTS} --prompt="Alias> ")"
					else
						echo "Select HostAlias:" >&2
						select a in "${aliases[@]}"; do [ -n "$a" ] && chosen="$a" && break; done
					fi
				fi
				[ -z "$chosen" ] && { echo "No selection made."; exit 1; }
				local origin
				origin="$(git remote get-url origin 2>/dev/null || true)"
				[ -z "$origin" ] && { echo "Origin remote not found."; exit 1; }
				if ! echo "$origin" | grep -qE '^git@[^:]+:'; then echo "Origin is not SSH format (git@host:path)."; exit 1; fi
				local new_url
				new_url="$(echo "$origin" | sed -E "s/^git@[^:]+:/git@${chosen}:/")"
				git remote set-url origin "$new_url"
				echo "Rewrote origin -> $new_url"
				# Update signing key to match selected alias identity
				local sel_identity
				sel_identity="$(get_identity_file_for_alias "$chosen" || true)"
				if [ -n "$sel_identity" ]; then
					git config --global user.signingkey "$sel_identity" 2>/dev/null || true
					echo "Set global user.signingkey -> $sel_identity"
					ensure_signing_setup "$sel_identity" || true
				else
					echo "Warning: could not determine IdentityFile for alias '$chosen' to update signing setup" >&2
				fi
			;;
			help|-h) show_help ;;
			*) echo "Unknown command: $1"; show_help; exit 1 ;;
		esac
	}

	main "$@"
