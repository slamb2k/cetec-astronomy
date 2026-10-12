# cetec-astronomy

```
░█▀▀░█▀▀░▀█▀░█▀▀░█▀▀░░░█▀█░█▀▀░▀█▀░█▀▄░█▀█░█▀█░█▀█░█▄█░█░█
░█░░░█▀▀░░█░░█▀▀░█░░░░░█▀█░▀▀█░░█░░█▀▄░█░█░█░█░█░█░█░█░░█░
░▀▀▀░▀▀▀░░▀░░▀▀▀░▀▀▀░░░▀░▀░▀▀▀░░▀░░▀░▀░▀▀▀░▀░▀░▀▀▀░▀░▀░░▀░
```

Too many secrets... 😎

Keep your API keys in [Keeper](https://www.keepersecurity.com/) and have them show up as ordinary environment variables in every zsh shell. Nothing secret is written to your dotfiles, and opening a shell never waits on Keeper.

```
$ secrets-add OPENAI_API_KEY
▸ Adding OPENAI_API_KEY
Checking Keeper for env:global:OPENAI_API_KEY…
Value for OPENAI_API_KEY (input hidden):
Saving env:global:OPENAI_API_KEY to Keeper…
Created Keeper record env:global:OPENAI_API_KEY.
Added OPENAI_API_KEY to ~/.config/cetec-astronomy/keeper-secrets.list (other shells load it at their next prompt).
```

## Requirements

- zsh
- [Keeper Commander](https://docs.keeper.io/en/keeperpam/commander-cli) (`pipx install keepercommander`), logged in with persistent login turned on
- `jq` and GNU `timeout` (coreutils)
- `setsid` (util-linux) is recommended. Without it everything still works, but an expired Keeper login is handled less cleanly.

Linux and WSL get a shared in-memory cache through `$XDG_RUNTIME_DIR`. On systems without it (macOS, for example) there's no cache, so each shell loads nothing at startup until you run `secrets-refresh`.

## Install

```sh
git clone https://github.com/slamb2k/cetec-astronomy.git
cd cetec-astronomy
./install.sh
```

Or without cloning:

```sh
curl -fsSL https://raw.githubusercontent.com/slamb2k/cetec-astronomy/main/install.sh | bash
```

The installer:

- copies `cetec-astronomy.zsh` to `~/.local/share/cetec-astronomy/`;
- creates your list at `~/.config/cetec-astronomy/keeper-secrets.list`, never overwriting an existing one;
- adds a marked loader block to your `.zshrc`, honouring `ZDOTDIR`.

It refuses to install if another copy of these commands is already loaded, because two copies would run two refreshers against one Keeper login. Running it again updates the script in place.

Then log in to Keeper once and keep the login:

```sh
keeper shell
My Vault> this-device persistent-login on
My Vault> quit
exec zsh
```

## Commands

Every command opens with the banner and the action it's taking. These go to stderr, so pipes and captured output stay clean.

| Command | What it does |
|---|---|
| `secrets-add NAME [tags...]` | Adds a secret. It uses an existing Keeper record `env:global:NAME`, or asks for the value with hidden input and creates one, then adds `NAME` to your list. |
| `secrets-refresh [filter...]` | Fetches from Keeper now and updates the cache, so every shell gets the new values at its next prompt. With no filter it also looks for `env:global:*` records missing from your list. |
| `secrets-status` | Shows managed, ignored and unlisted names, and the cache age. It never shows values. |
| `secrets-unset [filter...]` | Unsets the variables and stops auto-loading them in this shell. With no filter, child shells don't load them either. |
| `nosecrets <cmd> [args...]` | Runs a command with every managed variable removed from its environment. |

Filters are case-insensitive substrings matched against names and tags, so `secrets-refresh openai` refreshes anything whose name or tags contain "openai".

## The list file

`~/.config/cetec-astronomy/keeper-secrets.list` holds names, never values:

```
# VAR_NAME              optional search tags
OPENAI_API_KEY          openai ai
GITHUB_TOKEN            github git
ignore OLD_API_KEY
```

- **Keeper records:** each `NAME` is read from the Keeper login record titled `env:global:NAME`, whose password field is the value.
- **Ignoring a record:** `ignore NAME` stops an `env:global:NAME` record from being reported as unlisted.
- **Not allowed:** names like `PATH`, `HOME`, `LD_*`, `GIT_*` or `SSH_*` are refused, so a secret can't hijack your shell.
- **Safe to commit:** the list contains no secrets, so you can keep it in your dotfiles. Point `KEEPER_SECRETS_LIST` at it.

## How it works

- **Startup:** values are cached in `$XDG_RUNTIME_DIR/keeper-secrets/cache`.
  - That folder is in-memory (tmpfs), private to you (`0700`), and cleared at reboot.
  - The cache holds NUL-separated data and is read as data, never sourced as code.
  - Shells load it at startup in about a millisecond, and again at each prompt when it changes.
- **Refreshing:** when the cache is older than an hour, a shell refreshes it in the background, so the prompt never waits.
  - One `keeper` process fetches every secret in a single batch, with a 30-second timeout.
  - A failed fetch keeps the existing values and logs the failure to `refresh.log` in the cache folder. The next prompt shows it once.
- **One Keeper process at a time:** every login rotates a code in Keeper's config, and two logins at once can revoke your persistent login. A lock file ensures only one shell talks to Keeper at a time.
- **Never prompting:** `keeper` runs in batch mode with no controlling terminal. An expired login fails at once and is logged, instead of waiting for a password nobody can see.

## Configuration

Set these before the loader block in your `.zshrc`:

| Variable | Default | Meaning |
|---|---|---|
| `KEEPER_SECRETS_LIST` | `~/.config/cetec-astronomy/keeper-secrets.list` | Where the list lives |
| `KEEPER_SECRETS_TTL` | `3600` | Refresh the cache after this many seconds |
| `KEEPER_SECRETS_RETRY` | `300` | Wait this long before retrying a failed refresh |
| `KEEPER_SECRETS_DISABLED` | unset | If set, don't load or refresh secrets in this shell |

## Troubleshooting

**Secrets stopped updating, or `refresh.log` reports "Persistent login is not working".** Your Keeper persistent login has lapsed. Log in again and turn it back on:

```sh
keeper shell
My Vault> this-device persistent-login on
My Vault> quit
secrets-refresh
```

**"Timed out waiting for another Keeper refresh to finish."** Another process holds the lock. Find it with `lsof "$XDG_RUNTIME_DIR/keeper-secrets/lock"`. If it's a stuck background refresh, not one of your shells, stop it with `kill <pid>`.

**A new secret isn't in an old shell.** Shells pick up cache changes at their next prompt. Press Enter, or run `secrets-refresh NAME`.

## Uninstall

```sh
./install.sh --uninstall
```

This removes the script and the loader block. Your list file and your Keeper records are left alone.
