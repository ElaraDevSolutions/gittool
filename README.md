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

### Alternative install (portable script)

If you don't (or can't) use Homebrew (e.g. on minimal Linux images), a self-contained installer script is provided. It copies the scripts under `src/` to a prefix and creates a lightweight wrapper `gt` in `<prefix>/bin`.

Quick install (defaults to `/usr/local` if writable, otherwise `~/.local`):

```
curl -fsSL https://raw.githubusercontent.com/ElaraDevSolutions/gittool/v1.0.4/install.sh | bash
```

You can override the prefix:

```
curl -fsSL https://raw.githubusercontent.com/ElaraDevSolutions/gittool/v1.0.4/install.sh | bash -s -- --prefix=$HOME/.local
```

Options supported by `install.sh`:

| Option | Description |
|--------|-------------|
| `--prefix=DIR` | Installation root (`DIR/bin/gt` + `DIR/lib/gittool`). |
| `--force` | Overwrite existing files. |
| `--uninstall` | Remove previously installed wrapper and library directory. |
| `--dry-run` | Show actions without performing them. |
| `-h, --help` | Show help extracted from the script header. |

After install, ensure `<prefix>/bin` is on your PATH (add `export PATH="<prefix>/bin:$PATH"` to your shell profile if needed). Upgrading is just re-running the install command (possibly with `--force`). Uninstall with:

```
bash install.sh --uninstall --prefix=/usr/local   # or the prefix you used
```

Security note: Prefer pinning to a version tag (`vX.Y.Z`) instead of a mutable branch name. Optionally download first and inspect:

```
curl -fsSLO https://raw.githubusercontent.com/ElaraDevSolutions/gittool/vX.Y.Z/install.sh
less install.sh  # inspect
bash install.sh
```

## Quick overview

Common commands:

| Command | Description |
|---|---|
| `gt ssh add` | Add a new SSH key and append a Host block to `~/.ssh/config` (interactive). |
| `gt ssh add <alias-or-pattern>` | Register an existing key whose filename contains the pattern (auto or interactive selection). |
| `gt ssh remove <HostAlias>` | Remove key files and the Host block for the given HostAlias. |
| `gt ssh rotate [flags] <HostAlias>` | Rotate (replace) the SSH key for an existing HostAlias (backup & regenerate). |
| `gt ssh list` | Show Host aliases declared in `~/.ssh/config`. |
| `gt ssh help` | Show help for the SSH helper. |
| `gt ssh select` | Interactively pick a configured HostAlias and rewrite the current repo's `origin` remote to use it. |
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

1.1) Add a key (não-interativo / CI)

Agora é possível criar ou registrar chaves sem prompts usando flags:

```
gt ssh add --alias pessoal --email user@example.com --hostname github.com
```

Se a chave ainda não existe, será (ou seria em modo dry-run) gerada em `~/.ssh/id_ed25519_pessoal`.

Registrar chave existente por caminho:
```
gt ssh add --path ~/.ssh/id_ed25519_work --alias work --hostname github.com
```

Registrar por padrão (pattern) buscando em `~/.ssh` (auto se só 1 match):
```
gt ssh add --pattern work
```

Flags suportadas em `add`:
| Flag | Função |
|------|--------|
| `--alias <nome>` | Define o HostAlias (para nova chave ou ao registrar existente). |
| `--email <email>` | Comentário da chave (obrigatório para geração não-interativa). |
| `--hostname <h>` | HostName do bloco (default `github.com`). |
| `--path <arquivo>` | Caminho para chave privada existente. |
| `--pattern <frag>` | Fragmento para localizar chaves não configuradas. |
| `--no-agent` | Não executa `ssh-add`. |
| `--no-sign` | Não altera allowed_signers / configs de assinatura. |
| `--dry-run` | Apenas mostra ações planejadas. |

Erros comuns:
* Usar `--alias` sem `--email` ao gerar nova chave (exige email).
* `--pattern` com múltiplos matches sem `fzf` instalado → aborta solicitando uso de `--path`.

Exemplo dry-run seguro:
```
gt ssh add --alias tempkey --email temp@example.com --dry-run
```

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

7) Select a key for the current repository (new)

Use this when you already have multiple HostAliases configured and want to switch which SSH identity Git uses for pushes/clones in the current repo:

`gt ssh select`

What it does:
* Ensures you are inside a Git work tree and that `origin` exists.
* Lists all configured `Host` aliases from `~/.ssh/config`.
* Lets you choose one (via `fzf` if installed, or a numbered menu).
* Rewrites the `origin` remote from `git@original-host:owner/repo.git` to `git@<chosen-alias>:owner/repo.git`.

Example:

Initial remote:
`git@github.com:ElaraDevSolutions/gittool.git`

Run:
`gt ssh select` → choose `work-ssh`

New remote:
`git@work-ssh:ElaraDevSolutions/gittool.git`

Return codes / edge cases:
* Exits with error if not inside a Git repo, if `origin` is missing, or if the current `origin` URL is not SSH format (`git@host:path`).
* If only one alias exists, it's auto-selected.
* No changes are made if selection is aborted (ESC/Ctrl-C in `fzf` or empty choice).

8) Rotate an existing key (new)

Use this to periodically replace a key while keeping the same HostAlias (remotes like `git@alias:org/repo.git` keep working):

```
gt ssh rotate personal
```

What happens:
* Backs up current private & public key to `id_ed25519_<alias>.old-<timestamp>`.
* Prompts for email (defaults to previous key comment or `git config user.email`).
* Optional passphrase prompt.
* Generates fresh Ed25519 key at original path.
* Adds to ssh-agent (unless `--no-agent`).
* Updates commit signing & allowed_signers (unless `--no-sign`).
* Removes old key content from `allowed_signers` (unless `--no-sign`).

Flags:
* `--dry-run`         Show planned actions only (no backups, no key generation).
* `--no-agent`        Skip `ssh-add`.
* `--no-sign`         Skip signing setup & allowed_signers adjustments.
* `--email <address>` Provide new key email non-interactively (CI/automation).

Examples:
```
# Preview without touching files
gt ssh rotate --dry-run personal

# Rotate skipping side-effects
gt ssh rotate --no-agent --no-sign personal

# Provide a new email non-interactively (then passphrase default answer)
echo -e "new.email@example.com\n\n" | gt ssh rotate personal
```

Exit codes: 0 success / dry-run; 1 on errors (missing alias, invalid flag, generation failure).

Why rotate? Reduced exposure window, algorithm migration, enforce periodic hygiene, refresh signing metadata.

### SSH commit signing automation

Ao adicionar ou selecionar uma chave, o helper tenta configurar assinatura de commits via SSH:

1. Cria (se necessário) `~/.config/git/allowed_signers` e adiciona uma linha `email chave_publica` se a chave ainda não estiver presente.
2. Define `git config --global gpg.ssh.allowedSignersFile ~/.config/git/allowed_signers`.
3. Ajusta `git config --global user.signingkey` para apontar para o arquivo de chave privada (sem `.pub`).
4. Comando de verificação: `gt ssh sign-status`.

Se o e-mail não puder ser detectado (via `git config user.email` ou comentário da chave `.pub`), será solicitado interativamente.

Para assinar commits:
```bash
git config --global commit.gpgsign true
git commit -S -m "feat: exemplo"
```

Status rápido:
```bash
gt ssh sign-status
```

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
- Set environment variable `GITTOOL_NON_INTERACTIVE=1` to suppress email & passphrase prompts during `gt ssh rotate` (it auto reuses previous email and skips passphrase query). This is useful for unattended rotations. For `add`, supplying the needed flags (`--alias`, `--email`, etc.) already avoids prompts.

## Troubleshooting

- If `gt ssh list` reports no config found, ensure `~/.ssh/config` exists and is readable by your user.
- If `ssh-add` fails, check that an ssh-agent is running or use the system keychain (macOS) or other helpers.
- The `gt` dispatcher looks for the helper scripts relative to the `gt` binary (this works both when run from source and when installed via Homebrew).

## Contributing

Patches, bug reports and improvements are welcome. Tests are a small bash test script under `test/test_ssh.sh` that runs in an isolated temporary HOME.

## Distribution / packaging options

Current distribution: Homebrew tap + raw repo.

Potential additional channels (pick those that bring real user value; simplest first):

1. GitHub Releases (recommended early step)
	- For each version tag (`vX.Y.Z`), create a Release and attach a tarball or just rely on the auto-generated source tarball. Provide SHA256 sums. Users can: `curl -L -o gittool.tgz ...` and extract, or consume the `install.sh` pinned to the tag.
2. Linuxbrew (already supported implicitly)  
	- The existing Homebrew formula works on Linux if users install Homebrew (Linuxbrew). Just document it.
3. Simple curl|bash installer (done)  
	- Already covered above. Optionally add a signature (GPG) and detached `.asc` file in Releases.
4. Debian / Ubuntu (`.deb` package)  
	- Create a minimal deb: place scripts into `/usr/lib/gittool` or `/usr/share/gittool` and a symlink `/usr/bin/gt`. Tools: `dpkg-deb` manually or use `fpm` (`fpm -s dir -t deb ...`).  
	- To publish broadly, either host your own APT repo (serve `Release`, `Packages`, etc.) or use a PPA via Launchpad (requires packaging metadata). For a simple project, publishing a `.deb` asset in Releases might be enough for advanced users.
5. RPM (Fedora / RHEL / openSUSE)  
	- Similar: use `fpm -s dir -t rpm ...` or create an RPM spec and build with `rpmbuild`. Host via OBS (openSUSE Build Service) for multiple distros.
6. Snap (optional)  
	- Create a `snapcraft.yaml` with a `command: gt`; confinement: `classic` may be needed for seamless access to SSH keys. Users then `snap install gittool --classic`. Overhead may not justify for small bash scripts.
7. Nix / flakes  
	- Provide a `default.nix` or `flake.nix` that installs scripts and wrapper. Users: `nix profile install github:ElaraDevSolutions/gittool` (if flake). Very low maintenance once added.
8. asdf plugin  
	- Create `asdf-community/asdf-gittool` (or your namespace) with a `bin/install` that fetches a tagged tarball and places `gt` on PATH. Popular for multi-language/dev-tool environments.
9. Homebrew Core (later)  
	- Once stable and with sufficient popularity, you could propose inclusion in homebrew-core for broader visibility (must meet their acceptance guidelines).

What NOT to prioritize early: Flatpak (not ideal for simple CLI), AppImage (benefits mostly binaries, not bash scripts).

### Automated release flow

When you push a tag `vX.Y.Z`:
1. GitHub Actions workflow `release.yml` runs.
2. It builds archives (`tar.gz`, `zip`), `.deb`, `.rpm`, and `SHA256SUMS`.
3. Checksums are verified and the relevant changelog section is extracted.
4. Assets are attached to the GitHub Release created (or updated) for the tag.

Manual scripts (under `scripts/`):
| Script | Purpose |
|--------|---------|
| `release_checksums.sh` | Create `tar.gz`, `zip`, and `SHA256SUMS`. |
| `build_fpm_packages.sh` | Generate `.deb` and `.rpm` using `fpm`. |
| `sign_release.sh` | GPG sign artifacts (optional). |
| `update_homebrew_formula.sh` | Update external Homebrew tap formula with version + sha256. |

### Updating the Homebrew tap (external repo)

Assuming sibling repo layout:
```
gittool/
homebrew-tools/
```
Run a release, then:
```
bash scripts/update_homebrew_formula.sh --version vX.Y.Z
cd ../homebrew-tools
git add Formula/gt.rb
git commit -m "gt: update to vX.Y.Z"
git push
```
The script replaces the version in the formula `url` and updates `sha256` to match the new source archive.

### SSH signing (recap)
Caso queira configurar manualmente:
```bash
mkdir -p ~/.config/git
echo "seu.email@exemplo.com $(cat ~/.ssh/sua-chave.pub)" >> ~/.config/git/allowed_signers
git config --global gpg.ssh.allowedSignersFile ~/.config/git/allowed_signers
git config --global user.signingkey /Users/seuuser/.ssh/sua-chave
git config --global commit.gpgsign true
```

### Suggested future enhancements
* Optional GPG auto-sign integration in CI (provide `GPG_PRIVATE_KEY` + `GPG_PASSPHRASE` secrets).
* Publish asdf plugin for easy multi-tool management.
* Provide a Nix flake for reproducible installations.

Open an issue if you want help bootstrapping any further distribution channel.

## License

See `LICENCE.md` for license details.
