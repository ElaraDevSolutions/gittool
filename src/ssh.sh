#!/usr/bin/env bash
set -euo pipefail

SSH_DIR="$HOME/.ssh"
CONFIG_FILE="$SSH_DIR/config"
FZF_INLINE_OPTS="--height=40% --layout=reverse --border"

GITTOOL_CFG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}/gittool"
GITTOOL_CFG_FILE="$GITTOOL_CFG_ROOT/vault"

get_vault_master() {
	local master
	if ! master="$(GITTOOL_CFG_ROOT="$GITTOOL_CFG_ROOT" GITTOOL_CFG_FILE="$GITTOOL_CFG_FILE" "$(dirname "$0")/vault.sh" -m)"; then
		return 1
	fi
	[ -n "$master" ] || return 1
	printf '%s' "$master"
}

ensure_vault_initialized() {
	# Returns 0 if a vault is already initialized, otherwise runs `vault init` interactively.
	local vault_dir
	vault_dir="${GITTOOL_CONFIG_DIR:-$HOME/.gittool}/vault"
	if [ -d "$vault_dir" ] && ls "$vault_dir"/vault-*.gpg >/dev/null 2>&1; then
		return 0
	fi
	echo "Vault is not initialized yet. Running 'gt vault init'..." >&2
	"$(dirname "$0")/vault.sh" init || {
		echo "Failed to initialize vault." >&2
		return 1
	}
	return 0
}

vault_add_ssh_host() {
	local alias="$1"
	[ -n "$alias" ] || return 0
	mkdir -p "$GITTOOL_CFG_ROOT"
	touch "$GITTOOL_CFG_FILE"
	local has_vault existing line
	has_vault=0
	if grep -qE '^\[vault\]' "$GITTOOL_CFG_FILE" 2>/dev/null; then
		has_vault=1
	fi
	if [ $has_vault -eq 0 ]; then
		# No vault config yet; do not create it implicitly
		return 0
	fi
	existing="$(awk '/^\[vault\]/{in_v=1;next} /^\[/{in_v=0} in_v && /^ssh_hosts=/{print $0;exit}' "$GITTOOL_CFG_FILE" 2>/dev/null || true)"
	if [ -z "$existing" ]; then
		# Append ssh_hosts line inside existing [vault] block
		awk -v a="$alias" '
			/^\[vault\]/{print;printed=1;next}
			printed==1 && !seen && /^\[/{print "ssh_hosts=" a;seen=1}
			{print}
			END{if(printed==1 && !seen)print "ssh_hosts=" a}
		' "$GITTOOL_CFG_FILE" >"$GITTOOL_CFG_FILE.tmp" && mv "$GITTOOL_CFG_FILE.tmp" "$GITTOOL_CFG_FILE"
		return 0
	fi
	line="${existing#ssh_hosts=}"
	IFS=',' read -r -a hosts <<<"$line"
	local h
	for h in "${hosts[@]:-}"; do
		[ "$h" = "$alias" ] && return 0
	done
	if [ -z "$line" ]; then
		new_line="ssh_hosts=$alias"
	else
		new_line="ssh_hosts=${line},$alias"
	fi
	awk -v old="$existing" -v neu="$new_line" '{gsub(old,neu);print}' "$GITTOOL_CFG_FILE" >"$GITTOOL_CFG_FILE.tmp" && mv "$GITTOOL_CFG_FILE.tmp" "$GITTOOL_CFG_FILE"
}

show_help() {
	cat <<EOF
Commands (shortcuts):
  add    (-a) [pattern|path]      Create new key (no args) or register existing key by pattern/path.
  remove (-r) <HostAlias>         Remove key files and its Host block.
  rotate (-R) <HostAlias> [flags] Rotate (replace) key for existing HostAlias.
  list   (-l)                     List configured Host aliases.
  select                          Rewrite current repo origin to chosen HostAlias.
  sign-status                     Show if signing key is in allowed_signers.
  show   (-s) <HostAlias>         Show details about a configured SSH key.
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

show_ssh_key_details() {
	local HOST_ALIAS="$1"
	ensure_ssh_dir_and_config
	if [ -z "$HOST_ALIAS" ]; then
		echo "Usage: ssh.sh show <HostAlias>" >&2
		return 1
	fi
	if ! grep -qE "^Host[[:space:]]+${HOST_ALIAS}$" "$CONFIG_FILE" 2>/dev/null; then
		echo "Host '${HOST_ALIAS}' not found in $CONFIG_FILE." >&2
		return 1
	fi

	# Extract SSH config block fields
	local hostname user identity_file
	hostname="$(awk -v target="$HOST_ALIAS" '
		/^Host[[:space:]]+/ { in_block = ($2 == target); next }
		in_block && /^[[:space:]]*HostName[[:space:]]+/ { print $2; next }
		in_block && /^[[:space:]]*User[[:space:]]+/ { print $2; next }
		in_block && /^[[:space:]]*IdentityFile[[:space:]]+/ { print $2; next }
	' "$CONFIG_FILE" 2>/dev/null | paste -sd' ' - || true)"
	# hostname user identity
	set -- $hostname
	hostname="${1:-}"
	user="${2:-}"
	identity_file="${3:-}"
	[ -z "$identity_file" ] && identity_file="$(get_identity_file_for_alias "$HOST_ALIAS" || true)"

	local identity_abs
	identity_abs="$identity_file"
	if [ -n "$identity_abs" ] && [ "${identity_abs#~/}" != "$identity_abs" ]; then
		identity_abs="$HOME/${identity_abs#~/}"
	fi

	echo "HostAlias: $HOST_ALIAS"
	echo "  Config file: $CONFIG_FILE"
	echo
	echo "SSH config:"
	echo "  HostName      ${hostname:-<unset>}"
	echo "  User          ${user:-<unset>}"
	echo "  IdentityFile  ${identity_file:-<unset>}"

	local in_agent="unknown"
	if [ -n "$identity_abs" ] && command -v ssh-add >/dev/null 2>&1; then
		if ssh-add -L 2>/dev/null | grep -Fq "$identity_abs" 2>/dev/null; then
			in_agent="yes"
		else
			in_agent="no"
		fi
	fi
	echo "  In ssh-agent  $in_agent"

	echo
	echo "Key details:"
	if [ -z "$identity_abs" ]; then
		echo "  IdentityFile not resolved."
	else
		echo "  Key file      $identity_abs"
		local pub_file="$identity_abs.pub"
		if [ -f "$pub_file" ]; then
			echo "  Public key    $pub_file"
			local key_type="" fingerprint="" email="" created_at="" age_days=""
			key_type="$(cut -d' ' -f1 "$pub_file" 2>/dev/null || true)"
			if command -v ssh-keygen >/dev/null 2>&1; then
				fingerprint="$(ssh-keygen -lf "$pub_file" 2>/dev/null | awk '{print $2" "$3}' || true)"
			fi
			email="$(extract_email_from_pub "$pub_file" 2>/dev/null || true)"
			if [ -n "$email" ]; then
				:
			else
				email="<unknown>"
			fi
			if stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$identity_abs" >/dev/null 2>&1; then
				created_at="$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$identity_abs" 2>/dev/null || true)"
				# Compute age in days in a POSIX-safe way without nested $(( ))
				local now_ts mtime_ts diff_ts
				now_ts="$(date +%s 2>/dev/null || echo 0)"
				mtime_ts="$(stat -f '%m' "$identity_abs" 2>/dev/null || echo 0)"
				if [ -n "$now_ts" ] && [ -n "$mtime_ts" ]; then
					diff_ts=$(( now_ts - mtime_ts ))
					age_days=$(( diff_ts / 86400 ))
				fi
			fi
			echo "  Type          ${key_type:-<unknown>}"
			echo "  Fingerprint   ${fingerprint:-<unknown>}"
			echo "  Created at    ${created_at:-<unknown>}"
			echo "  Age           ${age_days:-<unknown>} days"
			echo "  Email         $email"
		else
			echo "  Public key    $pub_file (missing)"
		fi
	fi

	echo
	echo "Git & signing:"
	local cwd
	cwd="$(pwd)"
	if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		local repo_root origin_url
		repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$cwd")"
		origin_url="$(git remote get-url origin 2>/dev/null || true)"
		echo "  Local repo    $repo_root"
		if [ -n "$origin_url" ]; then
			echo "  origin remote $origin_url"
			if echo "$origin_url" | grep -qE "^git@${HOST_ALIAS}:"; then
				echo "  origin uses   this HostAlias: yes"
			else
				echo "  origin uses   this HostAlias: no"
			fi
		else
			echo "  origin remote <none>"
		fi
		local local_email
		local_email="$(git config user.email 2>/dev/null || true)"
		[ -n "$local_email" ] && echo "  user.email   (local)  $local_email"
	else
		echo "  Local repo    <none> (not in a git work tree)"
	fi
	local global_email signing_key allowed_file="$HOME/.config/git/allowed_signers"
	global_email="$(git config --global user.email 2>/dev/null || true)"
	[ -n "$global_email" ] && echo "  user.email  (global)  $global_email"
	signing_key="$(git config --global user.signingkey 2>/dev/null || true)"
	if [ -n "$signing_key" ]; then
		local matches="no"
		if [ -n "$identity_abs" ] && [ "$signing_key" = "$identity_abs" ]; then
			matches="yes"
		fi
		echo "  signingkey    $signing_key (matches: $matches)"
	else
		echo "  signingkey    <unset>"
	fi
	if [ -f "$allowed_file" ] && [ -n "$identity_abs" ] && [ -f "${identity_abs}.pub" ]; then
		if grep -Fq "$(cat "${identity_abs}.pub" 2>/dev/null || true)" "$allowed_file" 2>/dev/null; then
			echo "  allowed_signers: present ($allowed_file)"
		else
			echo "  allowed_signers: not present ($allowed_file)"
		fi
	else
		echo "  allowed_signers: file not found or key missing ($allowed_file)"
	fi

	# Vault expiration info (global vault, not per-alias)
	local vault_cfg_file="$HOME/.config/gittool/vault"
	if [ -f "$vault_cfg_file" ]; then
		local expires_line expires
		expires_line="$(
			awk '
				BEGIN { in_vault=0 }
				/^[[]vault[]]/ { in_vault=1; next }
				/^[[][^]]+[]]/ { in_vault=0 }
				in_vault==1 && /^expires=/ { print; exit }
			' "$vault_cfg_file" 2>/dev/null || true
		)"
		if [ -n "$expires_line" ]; then
			expires="${expires_line#expires=}"
			if [ -n "$expires" ] && [ "$expires" != "0" ]; then
				echo "Vault expiration (days): $expires"
			else
				echo "Vault expiration: never"
			fi
		else
			echo "Vault expiration: not configured"
		fi
	fi

	echo
	# Simple hint on age if known
	if [ -n "${age_days:-}" ] && [ "${age_days:-0}" -ge 180 ]; then
		echo "Hint: key is older than 180 days. Consider: gt ssh rotate $HOST_ALIAS"
	fi
}

unlock_ssh_key() {
	local HOST_ALIAS="$1"
	ensure_ssh_dir_and_config
	if [ -z "${HOST_ALIAS:-}" ]; then echo "Missing HostAlias."; show_help; return 1; fi
	if ! grep -qE "^Host[[:space:]]+${HOST_ALIAS}$" "$CONFIG_FILE" 2>/dev/null; then
		echo "Host '${HOST_ALIAS}' not found in $CONFIG_FILE." >&2
		return 1
	fi
	local identity_file
	identity_file="$(get_identity_file_for_alias "$HOST_ALIAS" || true)"
	if [ -z "$identity_file" ]; then
		echo "Unable to determine IdentityFile for alias '$HOST_ALIAS'." >&2
		return 1
	fi
	# Check if alias is mapped in vault ssh_hosts
	if [ ! -f "$GITTOOL_CFG_FILE" ] || ! grep -qE '^\[vault\]' "$GITTOOL_CFG_FILE" 2>/dev/null; then
		echo "No vault configuration found for gittool; nothing to unlock via vault." >&2
		return 1
	fi
	local hosts_line
	hosts_line="$(awk '/^\[vault\]/{in_v=1;next} /^\[/{in_v=0} in_v && /^ssh_hosts=/{print $0;exit}' "$GITTOOL_CFG_FILE" 2>/dev/null || true)"
	if [ -z "$hosts_line" ]; then
		echo "Vault config has no ssh_hosts mapping; alias '$HOST_ALIAS' not linked to vault." >&2
		return 1
	fi
	local value
	value="${hosts_line#ssh_hosts=}"
	IFS=',' read -r -a hosts <<<"$value"
	local linked=0 h
	for h in "${hosts[@]:-}"; do
		[ "$h" = "$HOST_ALIAS" ] && { linked=1; break; }
	done
	if [ $linked -eq 0 ]; then
		echo "Alias '$HOST_ALIAS' is not listed in vault ssh_hosts; refusing automatic unlock." >&2
		return 1
	fi
	# Already loaded in agent?
	if command -v ssh-add >/dev/null 2>&1; then
		if ssh-add -L 2>/dev/null | grep -Fq "$identity_file" 2>/dev/null; then
			echo "Key already present in ssh-agent for alias '$HOST_ALIAS'."
			return 0
		fi
	fi
	local master
	master="$(GITTOOL_CFG_ROOT="$GITTOOL_CFG_ROOT" GITTOOL_CFG_FILE="$GITTOOL_CFG_FILE" "$(dirname "$0")/vault.sh" -m 2>/dev/null || true)"
	if [ -z "$master" ]; then
		echo "Failed to obtain vault master; cannot unlock key automatically." >&2
		return 1
	fi
	if ! command -v ssh-add >/dev/null 2>&1; then
		echo "ssh-add not found; cannot add key to agent." >&2
		return 1
	fi
	# Use SSH_ASKPASS helper to provide the vault master non-interactively
	local askpass
	askpass="$(cd "$(dirname "$0")/.." && pwd)/scripts/askpass.sh"
	if [ ! -x "$askpass" ]; then
		echo "SSH askpass helper not found or not executable: $askpass" >&2
		return 1
	fi
	SSH_ASKPASS_REQUIRE=force SSH_ASKPASS="$askpass" DISPLAY=none ssh-add "$identity_file" </dev/null 2>/dev/null || {
		echo "ssh-add failed; you may need to unlock the key manually." >&2
		return 1
	}
	echo "Key for alias '$HOST_ALIAS' unlocked in ssh-agent using vault master."
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
			read -p "Email for new key (enter to reuse '${prev_email}'): " email || true
		fi
	fi
	[ -z "$email" ] && email="$prev_email"
	if [ -z "$email" ]; then echo "Email not provided. Aborting."; [ $DRY_RUN -eq 0 ] && {
		[ -f "${old_priv}.${backup_suffix}" ] && mv "${old_priv}.${backup_suffix}" "$old_priv" || true
		[ -f "${old_pub}.${backup_suffix}" ] && mv "${old_pub}.${backup_suffix}" "$old_pub" || true
	}; return 1; fi
	local pass_flag="-N ''"
	if [ -z "${GITTOOL_NON_INTERACTIVE:-}" ] && [ -t 0 ]; then
		read -p "Add passphrase? [y/N]: " add_pass || true
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
	if [ $DO_AGENT -eq 1 ]; then ssh-add "$identity_file" 2>/dev/null || echo "Warning: ssh-add failed (continuing)" >&2; fi
	local allowed_file="$HOME/.config/git/allowed_signers"
	if [ $DO_SIGN -eq 1 ]; then
		if [ -n "$old_pub_content" ] && [ -f "$allowed_file" ] && grep -Fq "$old_pub_content" "$allowed_file"; then
			grep -Fv "$old_pub_content" "$allowed_file" > "${allowed_file}.tmp" && mv "${allowed_file}.tmp" "$allowed_file" && echo "Removed old key from allowed_signers." || true
		fi
		ensure_signing_setup "$identity_file" || true
	else
		echo "(--no-sign) Skipping signing setup.";
	fi
	echo "Rotation completed for alias '$HOST_ALIAS'."
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
	# Update vault ssh_hosts mapping (if a vault is configured)
	if [ -f "$GITTOOL_CFG_FILE" ] && grep -qE '^\[vault\]' "$GITTOOL_CFG_FILE" 2>/dev/null; then
		current_line="$(awk '/^\[vault\]/{in_v=1;next} /^\[/{in_v=0} in_v && /^ssh_hosts=/{print $0;exit}' "$GITTOOL_CFG_FILE" 2>/dev/null || true)"
		if [ -n "$current_line" ]; then
			value="${current_line#ssh_hosts=}"
			IFS=',' read -r -a hosts <<<"$value"
			new_hosts=()
			for h in "${hosts[@]:-}"; do
				[ "$h" = "$HOST_ALIAS" ] && continue
				[ -n "$h" ] && new_hosts+=("$h")
			done
			if [ ${#new_hosts[@]} -eq 0 ]; then
				new_line="ssh_hosts="
			else
				joined="${new_hosts[*]}"
				joined="${joined// /,}"
				new_line="ssh_hosts=${joined}"
			fi
			awk -v old="$current_line" -v neu="$new_line" '{gsub(old,neu);print}' "$GITTOOL_CFG_FILE" >"${GITTOOL_CFG_FILE}.tmp" && mv "${GITTOOL_CFG_FILE}.tmp" "$GITTOOL_CFG_FILE"
		fi
	fi
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
			if [ -n "${GITTOOL_SSH_SKIP_AGENT_ON_VAULT:-}" ]; then
				echo "Skipping direct ssh-add (will attempt vault unlock)..."
			else
				ssh-add "$keyfile" 2>/dev/null && echo "Key added to ssh-agent: $keyfile" || echo "Warning: ssh-add failed for $keyfile (continuing)" >&2
			fi
		else
			echo "(--no-agent) Skipping ssh-add"
		fi
		[ "$do_sign" -eq 1 ] && ensure_signing_setup "$keyfile" || echo "(--no-sign) Skipping signing setup"
		# Copy public key to clipboard (if available) and notify user
		local pub_file="${keyfile}.pub"
		if [ -f "$pub_file" ]; then
			local copied=0
			if command -v pbcopy >/dev/null 2>&1; then
				cat "$pub_file" | pbcopy 2>/dev/null || true
				copied=1
			elif command -v xclip >/dev/null 2>&1; then
				cat "$pub_file" | xclip -selection clipboard 2>/dev/null || true
				copied=1
			elif command -v xsel >/dev/null 2>&1; then
				cat "$pub_file" | xsel --clipboard --input 2>/dev/null || true
				copied=1
			fi
			if [ "$copied" -eq 1 ]; then
				# Bold message using ANSI escape codes
				printf '\033[1m%s\033[0m\n' "Public key content copied to clipboard from $pub_file."
			else
				echo "Public key at $pub_file (clipboard tool not found; please copy it manually)."
			fi
		fi
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
					ssh-keygen -t ed25519 -C "$EMAIL" -f "$KEYFILE"
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
		if [ -f "$KEYFILE" ]; then
			echo "SSH key already exists: $KEYFILE"
		else
			read -p "Email for the key: " EMAIL; [ -z "${EMAIL}" ] && { echo "Email cannot be empty."; exit 1; }
			local use_vault="N" master=""
			if [ -t 0 ]; then
				read -p "Protect key with vault master secret? [y/N]: " use_vault || true
			fi
			case "$use_vault" in
				[yY]|[yY][eE][sS])
					local user_input=""
					if [ -t 0 ]; then
						printf "Enter vault master secret (leave empty to auto-retrieve): "
						stty -echo 2>/dev/null || true
						read -r user_input || true
						stty echo 2>/dev/null || true
						echo
					fi

					if [ -n "$user_input" ]; then
						master="$user_input"
						# Ensure vault is initialized so mapping can be added later
						ensure_vault_initialized >/dev/null 2>&1 || true
					else
						if ensure_vault_initialized; then
							master="$(get_vault_master || true)"
						fi
						if [ -z "$master" ]; then
							echo "Error: Failed to retrieve vault master secret." >&2
							exit 1
						fi
					fi
				;;
			esac
			echo "Generating SSH key..."
			if [ -n "$master" ]; then
				echo "Encrypting new SSH key with vault master secret (no passphrase prompt needed)..."
				ssh-keygen -t ed25519 -C "$EMAIL" -f "$KEYFILE" -N "$master"
				GITTOOL_SSH_SKIP_AGENT_ON_VAULT=1
			else
				ssh-keygen -t ed25519 -C "$EMAIL" -f "$KEYFILE"
			fi
			vault_add_ssh_host "$HOST_ALIAS" || true
		fi
		register_key_file "$KEYFILE" "$HOST_ALIAS" "$HOSTNAME" "$DO_AGENT" "$DO_SIGN" "$DRY_RUN"
		if [ -n "${GITTOOL_SSH_SKIP_AGENT_ON_VAULT:-}" ] && [ "$DO_AGENT" -eq 1 ]; then
			unlock_ssh_key "$HOST_ALIAS" || echo "Warning: failed to auto-unlock new key."
		fi
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
		# Always add key to allowed_signers without prompting
		echo "$email $pub_content" >> "$allowed_file"
		echo "Added key to allowed_signers."
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
			show|-s) shift || true; show_ssh_key_details "${1:-}" ;;
			unlock) shift || true; unlock_ssh_key "${1:-}" ;;
			select)
				shift || true
				ensure_ssh_dir_and_config
				if [ ! -f "$CONFIG_FILE" ]; then echo "No SSH config file found."; exit 1; fi
				local -a aliases
				aliases=()
				while IFS= read -r line; do aliases+=("$line"); done < <(grep -E '^Host[[:space:]]+[^ ]+$' "$CONFIG_FILE" | awk '{print $2}' || true)
				if [ ${#aliases[@]} -eq 0 ]; then echo "No Host aliases found."; exit 1; fi
				# Parse optional flags and/or explicit alias argument
				local DO_SIGN=1 EXPLICIT_ALIAS="" arg
				while [ $# -gt 0 ]; do
					case "$1" in
						--no-sign) DO_SIGN=0; shift ;;
						-*) echo "Unknown flag for select: $1"; exit 1 ;;
						*) EXPLICIT_ALIAS="$1"; shift ;;
					esac
				done
				local chosen=""
				if [ -n "$EXPLICIT_ALIAS" ]; then
					# Validate alias exists
					if grep -qE "^Host[[:space:]]+${EXPLICIT_ALIAS}$" "$CONFIG_FILE"; then chosen="$EXPLICIT_ALIAS"; else echo "Alias '$EXPLICIT_ALIAS' not found."; exit 1; fi
				elif [ ${#aliases[@]} -eq 1 ]; then chosen="${aliases[0]}"; else
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
				# Determine identity and optionally setup signing
				local sel_identity
				sel_identity="$(get_identity_file_for_alias "$chosen" || true)"
				if [ -n "$sel_identity" ]; then
					if [ $DO_SIGN -eq 1 ]; then
						git config --global user.signingkey "$sel_identity" 2>/dev/null || true
						echo "Set global user.signingkey -> $sel_identity"
						ensure_signing_setup "$sel_identity" || true
					else
						echo "(--no-sign) Skipping signing setup/update."
					fi
				else
					echo "Warning: could not determine IdentityFile for alias '$chosen'."
				fi
				# Ensure this alias is mapped in vault ssh_hosts, then auto-unlock it
				if [ -f "$GITTOOL_CFG_FILE" ] && grep -qE '^\[vault\]' "$GITTOOL_CFG_FILE" 2>/dev/null; then
					# Reuse vault_add_ssh_host to guarantee mapping exists
					vault_add_ssh_host "$chosen" || true
					if unlock_ssh_key "$chosen"; then
						echo "Alias '$chosen' unlocked via vault for this session."
					else
						echo "Warning: failed to unlock alias '$chosen' via vault; SSH may still prompt for passphrase." >&2
					fi
				fi
			;;
			help|-h) show_help ;;
			*) echo "Unknown command: $1"; show_help; exit 1 ;;
		esac
	}

	main "$@"
