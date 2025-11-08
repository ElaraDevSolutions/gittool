# gittool (gt)

A small, focused command-line helper that makes working with Git and multiple SSH keys easier. It provides:

- Simple SSH key and config management (add, remove, list keys).
- A tiny wrapper to clone repositories using a chosen SSH HostAlias.

The command is distributed as `gt` and includes a dispatcher that forwards SSH-related commands to the bundled `ssh.sh` helper.

## Installation

Install via Homebrew using the project's tap and package name:
```
brew tap ElaraDevSolutions/tools
brew install gt
```
After installation the `gt` executable will be on your PATH. Locally (from source) you can run the scripts under `src/` directly (for example `bash src/gt.sh ssh help`).

## Quick overview

Common commands:

| Command | Description |
|---|---|
| `gt ssh add` | Add a new SSH key and append a Host block to `~/.ssh/config` (interactive). |
| `gt ssh add <alias-or-pattern>` | Register an existing key whose filename contains the pattern (auto or interactive selection). |
| `gt ssh remove <HostAlias>` | Remove key files and the Host block for the given HostAlias. |
| `gt ssh list` | Show Host aliases declared in `~/.ssh/config`. |
| `gt ssh help` | Show help for the SSH helper. |
| `gt clone <SSH-link>` | Clone using a selected HostAlias (replaces the host in the SSH link). |

The `gt` dispatcher forwards `gt ssh ...` to the `ssh.sh` helper in the installation directory. For normal Git commands `gt` simply forwards to `git`.

## SSH helper (commands & examples)

All SSH helper commands are exposed via `gt ssh <cmd>` (or by running `src/ssh.sh` directly).

1) Add a key (interactive)

This is the normal path for creating and registering a new SSH key:

gt ssh add

The script will prompt for:
- HostName (defaults to github.com)
- Key name (a short alias used as HostAlias in ~/.ssh/config, e.g. `personal`)
- Email (used as the key comment during generation)

After successful generation the key is stored at `~/.ssh/id_ed25519_<alias>` and a Host block is appended to `~/.ssh/config`.

2) Register an existing key by path

If you already have a private key file you can point the helper at it (path to the private key):

`gt ssh add /path/to/id_ed25519_alias`

This registers the provided key in `~/.ssh/config` (it may still prompt for a HostName). The helper attempts to add the key to `ssh-agent` (warnings from `ssh-add` are non-fatal).

3) Register an existing key by pattern (new)

You can now pass just a pattern (alias fragment). The tool searches `~/.ssh` for private key files whose names contain that fragment and are not yet configured as a `Host`.

Examples (assume files like `id_ed25519_personal`, `personal-ssh`, `my-personal` exist):

`gt ssh add personal`

Behavior:
* If exactly one unconfigured match is found, it's registered automatically.
* If multiple matches are found, you'll get an interactive selector:
	* Uses `fzf` if installed (arrow keys / fuzzy search).
	* Falls back to a numbered Bash `select` menu otherwise.
* After choosing (or auto-detecting), a Host block is added and the key is loaded into `ssh-agent`.

Notes:
* Only private key files (non-`.pub`) are considered.
* The HostAlias used is derived from the filename (strips `id_ed25519_` prefix and any `.pub` suffix).
* Already-configured aliases are skipped so you don't create duplicates.

4) List configured Host aliases

gt ssh list

This prints a short list of Host aliases found in `~/.ssh/config`.

5) Remove a key and its Host block

gt ssh remove personal

This removes the Host block for `personal` from `~/.ssh/config` and deletes `~/.ssh/id_ed25519_personal` (and the .pub file) if present. The helper will also ask `ssh-agent` to unload the key (`ssh-add -d`) but will continue if `ssh-agent` is not available.

6) Help

gt ssh help

Shows the available SSH helper commands.

## Cloning with a chosen HostAlias

`gt` includes a tiny wrapper around `git clone` that replaces the host portion of an SSH repo link with a selected HostAlias from your SSH config. Example:

gt clone git@github.com:owner/repo.git

If multiple HostAlias entries exist the script will prompt you to choose one (it integrates with `fzf` if available). The final `git clone` will use the selected HostAlias so the specified key is used for authentication.

Example flow (multiple keys configured):

- You run: `gt clone git@github.com:acme/service.git`
- Script lists `personal` and `work` (or opens `fzf` if installed)
- You choose `work`
- It runs `git clone git@work:acme/service.git`

## Non-interactive / CI notes

- The `ssh.sh` helper is primarily interactive for the `add` flow. In CI or automation you can pre-generate keys and append Host blocks to `~/.ssh/config` directly (the test suite uses this approach). The helper supports passing an existing key path to `gt ssh add` but it may still prompt for HostName.
- The helper tolerates `ssh-agent` not being present; `ssh-add` warnings are non-fatal. For CI ensure your runner has the right key permissions (600) and that `~/.ssh` exists.

## Troubleshooting

- If `gt ssh list` reports no config found, ensure `~/.ssh/config` exists and is readable by your user.
- If `ssh-add` fails, check that an ssh-agent is running or use the system keychain (macOS) or other helpers.
- The `gt` dispatcher looks for the helper scripts relative to the `gt` binary (this works both when run from source and when installed via Homebrew).

## Contributing

Patches, bug reports and improvements are welcome. Tests are a small bash test script under `test/test_ssh.sh` that runs in an isolated temporary HOME.

## License

See `LICENCE.md` for license details.
