#!/usr/bin/env bash
# CETEC ASTRONOMY installer: Keeper-backed environment variables for zsh.
#
#   ./install.sh              install or update
#   ./install.sh --uninstall  remove the script and the .zshrc hook (keeps your list)
#
# Or without cloning:
#   curl -fsSL https://raw.githubusercontent.com/slamb2k/cetec-astronomy/main/install.sh | bash
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/slamb2k/cetec-astronomy/main"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/cetec-astronomy"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cetec-astronomy"
SCRIPT="$DATA_DIR/cetec-astronomy.zsh"
LIST="$CONFIG_DIR/keeper-secrets.list"
BEGIN="# >>> cetec-astronomy >>>"
END="# <<< cetec-astronomy <<<"

say() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

banner() {
  cat <<'ART'

░█▀▀░█▀▀░▀█▀░█▀▀░█▀▀░░░█▀█░█▀▀░▀█▀░█▀▄░█▀█░█▀█░█▀█░█▄█░█░█
░█░░░█▀▀░░█░░█▀▀░█░░░░░█▀█░▀▀█░░█░░█▀▄░█░█░█░█░█░█░█░█░░█░
░▀▀▀░▀▀▀░░▀░░▀▀▀░▀▀▀░░░▀░▀░▀▀▀░░▀░░▀░▀░▀▀▀░▀░▀░▀▀▀░▀░▀░░▀░

ART
  say "▸ $1"
}

command -v zsh >/dev/null || die "zsh is required."

# zsh may keep its config somewhere else (ZDOTDIR, often set in ~/.zshenv), which bash can't see.
ZDOT="$(zsh -c 'printf %s "${ZDOTDIR:-$HOME}"')"
ZSHRC="$ZDOT/.zshrc"

# Copies a repo file to $2: from beside this script when cloned, otherwise from GitHub.
fetch() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
  if [[ -n $here && -f "$here/$1" ]]; then
    cp "$here/$1" "$2"
  else
    command -v curl >/dev/null || die "curl is required to download $1."
    curl -fsSL "$REPO_RAW/$1" -o "$2" || die "couldn't download $REPO_RAW/$1"
  fi
}

remove_hook() {
  [[ -f $ZSHRC ]] && grep -qF "$BEGIN" "$ZSHRC" || return 0
  local tmp
  tmp="$(mktemp)"
  awk -v b="$BEGIN" -v e="$END" '$0 == b {skip = 1; next} $0 == e {skip = 0; next} !skip' "$ZSHRC" > "$tmp"
  cat "$tmp" > "$ZSHRC"  # keeps the file's permissions and any symlink
  rm -f "$tmp"
}

if [[ ${1:-} == --uninstall ]]; then
  banner "Uninstalling"
  remove_hook
  rm -f "$SCRIPT"
  rmdir "$DATA_DIR" 2>/dev/null || true
  say "Removed $SCRIPT and the hook in $ZSHRC."
  say "Kept your list at $LIST and your Keeper records. Open a new shell to finish."
  exit 0
fi
[[ $# -eq 0 ]] || die "usage: install.sh [--uninstall]"

banner "Installing"

# Loading two copies would run two refreshers against one Keeper login.
if ! grep -qsF "$BEGIN" "$ZSHRC"; then
  existing="$(KEEPER_SECRETS_DISABLED=1 zsh -ic 'whence -v secrets-refresh' 2>/dev/null || true)"
  if [[ $existing == *"shell function from"* ]]; then
    die "another copy is already loaded (${existing##* from }). Remove it from your zsh config first."
  fi
fi

missing=()
for tool in keeper jq timeout; do command -v "$tool" >/dev/null || missing+=("$tool"); done
command -v setsid >/dev/null || warn "setsid not found: background refreshes still work, but an expired Keeper login can't be detected as cleanly."

mkdir -p "$DATA_DIR" "$CONFIG_DIR"
fetch cetec-astronomy.zsh "$SCRIPT.tmp"
mv -f "$SCRIPT.tmp" "$SCRIPT"
say "Installed $SCRIPT"

if [[ -f $LIST ]]; then
  say "Kept your existing list at $LIST"
else
  fetch keeper-secrets.list.example "$LIST"
  say "Created $LIST"
fi

if grep -qsF "$BEGIN" "$ZSHRC"; then
  say "$ZSHRC already loads it."
else
  mkdir -p "$ZDOT"
  printf '\n%s\n[[ -r "%s" ]] && source "%s"\n%s\n' "$BEGIN" "$SCRIPT" "$SCRIPT" "$END" >> "$ZSHRC"
  say "Added the loader to $ZSHRC"
fi

say ""
if (( ${#missing[@]} )); then
  warn "missing: ${missing[*]}. Install them before using the commands:"
  [[ " ${missing[*]} " == *" keeper "* ]] && say "  pipx install keepercommander"
  [[ " ${missing[*]} " == *" jq "* ]] && say "  jq: your package manager (apt install jq, brew install jq)"
  [[ " ${missing[*]} " == *" timeout "* ]] && say "  timeout: GNU coreutils (brew install coreutils on macOS)"
  say ""
fi
cat <<EOF
Next steps:
  1. Log in to Keeper and keep the login:
       keeper shell
       My Vault> this-device persistent-login on
       My Vault> quit
  2. Open a new shell (or run: exec zsh).
  3. Add a secret:   secrets-add OPENAI_API_KEY
     Check status:   secrets-status
EOF
