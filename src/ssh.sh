list_host_aliases() {
	if [ ! -f "$CONFIG_FILE" ]; then
		echo "No SSH config file found at $CONFIG_FILE."
		return 1
	fi
	echo "Current HostAliases in $CONFIG_FILE:"
	grep -E '^Host[[:space:]]+[^ ]+$' "$CONFIG_FILE" | awk '{print $2}'
}
#!/usr/bin/env bash
set -euo pipefail

# Show usage/help
show_help() {
	cat <<EOF
Commands (shortcuts):
	add    (-a)              Add a new SSH key and config block (interactive).
	remove (-r) <HostAlias>  Remove SSH key files and its config block.
	help   (-h)              Show this help message.
EOF
}

# Function to remove Host configuration from ~/.ssh/config
remove_ssh_key() {
	local HOST_ALIAS="$1"

	ensure_ssh_dir_and_config

	if [ -z "${HOST_ALIAS:-}" ]; then
		echo "Missing HostAlias."
		show_help
		return 1
	fi

	if ! grep -qE "^Host[[:space:]]+${HOST_ALIAS}$" "$CONFIG_FILE"; then
		echo "Host '${HOST_ALIAS}' not found in $CONFIG_FILE."
		return 0
	fi

	echo "Removing configuration for Host '${HOST_ALIAS}'..."
	awk -v alias="$HOST_ALIAS" '
		BEGIN {skip=0}
		/^Host[[:space:]]+/ {
			if ($2 == alias) { skip=1; next }
			else if (skip) { skip=0 }
		}
		skip==0 { print }
	' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
	echo "Configuration removed from config file."

	KEYFILE="$SSH_DIR/id_ed25519_${HOST_ALIAS}"
	if [ -f "$KEYFILE" ]; then
		rm -f "$KEYFILE"
		echo "Private key removed: $KEYFILE"
	fi
	if [ -f "$KEYFILE.pub" ]; then
		rm -f "$KEYFILE.pub"
		echo "Public key removed: $KEYFILE.pub"
	fi
	echo "Removal completed."
}
#!/bin/bash

SSH_DIR="$HOME/.ssh"
CONFIG_FILE="$SSH_DIR/config"

function ensure_ssh_dir_and_config() {
	if [ ! -d "$SSH_DIR" ]; then
		echo "Creating ~/.ssh directory..."
		mkdir -p "$SSH_DIR"
		chmod 700 "$SSH_DIR"
	fi
	if [ ! -f "$CONFIG_FILE" ]; then
		echo "Creating ~/.ssh/config file..."
		touch "$CONFIG_FILE"
		chmod 600 "$CONFIG_FILE"
	fi
}

add_ssh_key() {
	ensure_ssh_dir_and_config

	read -p "HostName (default: github.com): " HOSTNAME
	HOSTNAME=${HOSTNAME:-github.com}

	read -p "Key name (e.g.: personal): " HOST_ALIAS
	if [ -z "${HOST_ALIAS}" ]; then
		echo "Key name cannot be empty."
		exit 1
	fi
	if echo "$HOST_ALIAS" | grep -q '[[:space:]]'; then
		echo "Key name cannot contain spaces."
		exit 1
	fi

	KEYFILE="$SSH_DIR/id_ed25519_${HOST_ALIAS}"

	if [ -f "$KEYFILE" ]; then
		echo "SSH key already exists: $KEYFILE"
	else
		read -p "Email for the key: " EMAIL
		if [ -z "${EMAIL}" ]; then
			echo "Email cannot be empty."
			exit 1
		fi
		echo "Generating SSH key..."
		ssh-keygen -t ed25519 -C "$EMAIL" -f "$KEYFILE"
	fi

	if grep -qE "^Host[[:space:]]+${HOST_ALIAS}$" "$CONFIG_FILE"; then
		echo "Configuration for '${HOST_ALIAS}' already exists in $CONFIG_FILE."
	else
		echo "Adding configuration to $CONFIG_FILE..."
		{
			echo "Host $HOST_ALIAS"
			echo "  HostName $HOSTNAME"
			echo "  User git"
			echo "  IdentityFile $KEYFILE"
			echo "  IdentitiesOnly yes"
		} >> "$CONFIG_FILE"
		echo "Configuration added: $HOST_ALIAS"
	fi
}

main() {
	if [ $# -eq 0 ]; then
		show_help
		exit 0
	fi

	case "$1" in
		add|-a)
			add_ssh_key
			;;
		remove|-r)
			shift || true
			remove_ssh_key "${1:-}"
			;;
		list|-l)
			list_host_aliases
			;;
		help|-h)
			show_help
			;;
		*)
			echo "Unknown command: $1"
			show_help
			exit 1
			;;
	esac
}

main "$@"
