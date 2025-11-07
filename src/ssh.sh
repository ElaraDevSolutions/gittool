#!/bin/bash

# Show usage/help
function show_help() {
	echo "Commands [shortcut]:"
	echo "  add    [-a]              Add a new SSH key and config block interactively."
	echo "  remove [-r] <HostAlias>  Remove SSH key and config block for given HostAlias."
	echo "  help   [-h]              Show this help message."
}

# Function to remove Host configuration from ~/.ssh/config
function remove_ssh_key() {
	ensure_ssh_dir_and_config
	HOST_ALIAS="$2"
	if [ -z "$HOST_ALIAS" ]; then
		echo "Usage: $0 remove <HostAlias>"
		return 1
	fi
	if grep -q "^Host $HOST_ALIAS" "$CONFIG_FILE"; then
		echo "Removing configuration for Host $HOST_ALIAS..."
		awk -v alias="$HOST_ALIAS" '
			BEGIN {skip=0}
			/^Host[ ]+[^ ]/ {
				if ($2 == alias) {skip=1; next}
				else if (skip) {skip=0}
			}
			skip==0 {print}
		' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
	echo "Configuration removed."

		# Remove arquivos da chave
		KEYFILE="$SSH_DIR/id_ed25519_$HOST_ALIAS"
		if [ -f "$KEYFILE" ]; then
			rm -f "$KEYFILE"
		echo "Private key file removed: $KEYFILE"
		fi
		if [ -f "$KEYFILE.pub" ]; then
			rm -f "$KEYFILE.pub"
		echo "Public key file removed: $KEYFILE.pub"
		fi
	else
	echo "Host $HOST_ALIAS not found in $CONFIG_FILE."
	fi
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

function add_ssh_key() {
	ensure_ssh_dir_and_config

	read -p "HostName (default: github.com): " HOSTNAME
	HOSTNAME=${HOSTNAME:-github.com}

	read -p "Key name (e.g.: personal): " HOST_ALIAS
	KEYFILE="$SSH_DIR/id_ed25519_$HOST_ALIAS"

	if [ -f "$KEYFILE" ]; then
		echo "SSH key already exists: $KEYFILE"
	else
		read -p "Email for the key: " EMAIL
		echo "Generating SSH key..."
		ssh-keygen -t ed25519 -C "$EMAIL" -f "$KEYFILE"
	fi

	# Check if configuration for this Host already exists
	if grep -q "Host $HOST_ALIAS" "$CONFIG_FILE"; then
		echo "Configuration for $HOST_ALIAS already exists in $CONFIG_FILE."
	else
		echo "Adding configuration to $CONFIG_FILE..."
	cat <<EOL >> "$CONFIG_FILE"
Host $HOST_ALIAS
  HostName $HOSTNAME
  User git
  IdentityFile $KEYFILE
  IdentitiesOnly yes
EOL
		echo "Configuration added: $HOST_ALIAS"
	fi
}

case "$1" in
	add|-a)
		add_ssh_key
		;;
	remove|-r)
		remove_ssh_key "$@"
		;;
	help|-h)
		show_help
		;;
	*)
		show_help
		;;
esac
