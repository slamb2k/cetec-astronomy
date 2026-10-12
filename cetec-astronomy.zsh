# CETEC ASTRONOMY: Keeper-backed environment variables for zsh.
# https://github.com/slamb2k/cetec-astronomy
#
# Secret values never live in dotfiles. The managed names are listed in
# ~/.config/cetec-astronomy/keeper-secrets.list (override with KEEPER_SECRETS_LIST);
# each is fetched from the Keeper record titled env:global:<NAME>.
# Needs Keeper Commander, jq, and Keeper persistent login.
#
# Values are cached in $XDG_RUNTIME_DIR (tmpfs, 0700 dir, 0600 file) so shells
# load them instantly. Keeper is never called on the startup path: a stale cache
# is refreshed in the background, and every shell picks up new values at its next
# prompt. Without $XDG_RUNTIME_DIR there is no cache; secrets-refresh still works.
#
#   secrets-refresh [filter...]  fetch now from Keeper; updates the cache, so all shells
#   secrets-add NAME [tags...]   add a secret: creates the Keeper record if needed
#   secrets-status               show managed, ignored and unlisted Keeper records
#   secrets-unset [filter...]    unset vars and stop auto-loading them in this shell
#   nosecrets <cmd> [args...]    run a command with all managed vars removed
#
# Filters are case-insensitive substrings matched against name and tags.
# Full refreshes also search Keeper for env:global:* records missing from the
# list and report each new one once.

zmodload zsh/system zsh/datetime zsh/regex
zmodload -F zsh/stat b:zstat

typeset -g KEEPER_SECRETS_TTL=${KEEPER_SECRETS_TTL:-3600}     # refresh the cache after this many seconds
typeset -g KEEPER_SECRETS_RETRY=${KEEPER_SECRETS_RETRY:-300}  # wait this long after a failed refresh
typeset -g _keeper_secrets_list=${KEEPER_SECRETS_LIST:-${XDG_CONFIG_HOME:-$HOME/.config}/cetec-astronomy/keeper-secrets.list}
typeset -g _keeper_secrets_dir=${XDG_RUNTIME_DIR:+${XDG_RUNTIME_DIR%/}/keeper-secrets}
typeset -g _keeper_secrets_log=${_keeper_secrets_dir:+$_keeper_secrets_dir/refresh.log}
typeset -g _keeper_secrets_loaded= _keeper_secrets_warned= _keeper_secrets_list_sig= _keeper_secrets_unlisted_sig=
typeset -gA _keeper_secrets_skip
# Filled from the list file: _KEEPER_SECRETS holds pairs of name and tags.
typeset -ga _KEEPER_SECRETS _keeper_secrets_names _keeper_secrets_ignore

# Names that must never be set from Keeper, even if listed.
_keeper_secrets_valid_name() {
  [[ $1 =~ '^[A-Z_][A-Z0-9_]*$' ]] || return 1
  case $1 in
    PATH|HOME|SHELL|USER|LOGNAME|IFS|ENV|BASH_ENV|ZDOTDIR|FPATH|CDPATH|PS[1-4]|PROMPT*|TMPDIR|TERM|EDITOR|VISUAL|PAGER) return 1 ;;
    LD_*|DYLD_*|GIT_*|SSH_*|XDG_*|KEEPER_*|ZSH*|BASH*|PYTHON*|NODE_*|PERL*|RUBY*|LC_*|LANG*) return 1 ;;
  esac
}

_keeper_secrets_read_list() {
  local line name
  local -a words

  _KEEPER_SECRETS=() _keeper_secrets_names=() _keeper_secrets_ignore=()
  _keeper_secrets_stat "$_keeper_secrets_list"
  _keeper_secrets_list_sig=$reply[1]
  [[ -r $_keeper_secrets_list ]] || return 0

  for line in "${(@f)$(<$_keeper_secrets_list)}"; do
    words=(${=line%%\#*})
    (( ${#words} )) || continue

    if [[ $words[1] == ignore ]]; then
      _keeper_secrets_ignore+=(${words[2,-1]})
    elif _keeper_secrets_valid_name "$words[1]"; then
      _KEEPER_SECRETS+=("$words[1]" "${words[2,-1]}")
      _keeper_secrets_names+=("$words[1]")
    else
      print -u2 -r -- "keeper-secrets: skipping disallowed name '${words[1]//[^A-Za-z0-9_]/?}' in $_keeper_secrets_list"
    fi
  done
}

# Re-reads the list if it changed, unsetting vars that are no longer listed.
_keeper_secrets_sync_list() {
  local name
  local -a old=($_keeper_secrets_names)

  _keeper_secrets_stat "$_keeper_secrets_list"
  [[ $reply[1] == $_keeper_secrets_list_sig ]] && return 1

  _keeper_secrets_read_list
  for name in $old; do
    (( ${_keeper_secrets_names[(Ie)$name]} )) || unset "$name"
  done
}

_keeper_secrets_matches() {
  local haystack="${(L)1}" filter
  shift

  (( $# == 0 )) && return 0

  for filter in "$@"; do
    [[ "$haystack" == *"${(L)filter}"* ]] && return 0
  done

  return 1
}

# Sets reply to the managed names matching the filters.
_keeper_secrets_select() {
  local name tags
  reply=()
  for name tags in "${_KEEPER_SECRETS[@]}"; do
    _keeper_secrets_matches "$name env:global:$name $tags" "$@" && reply+=($name)
  done
}

# Sets REPLY to the file's mtime (0 if missing), and reply to an inode:mtime:size
# signature that changes whenever the file is replaced or appended to (mtime
# alone has one-second resolution).
_keeper_secrets_stat() {
  local -A st
  if zstat -H st -- "$1" 2>/dev/null; then
    REPLY=$st[mtime] reply=("$st[inode]:$st[mtime]:$st[size]")
  else
    REPLY=0 reply=("")
  fi
}

_keeper_secrets_have_cli() {
  command -v keeper >/dev/null 2>&1 && command -v jq >/dev/null 2>&1
}

_keeper_secrets_cache_ready() {
  [[ -n $_keeper_secrets_dir ]] || return 1
  [[ -d $_keeper_secrets_dir ]] || mkdir -m 700 -- "$_keeper_secrets_dir" 2>/dev/null || return 1
  [[ -e $_keeper_secrets_dir/lock ]] || : >> "$_keeper_secrets_dir/lock"
}

# Every user-facing command opens with this banner and the action it's taking, on
# stderr so pipes and captured output stay clean.
typeset -g _keeper_secrets_art='░█▀▀░█▀▀░▀█▀░█▀▀░█▀▀░░░█▀█░█▀▀░▀█▀░█▀▄░█▀█░█▀█░█▀█░█▄█░█░█
░█░░░█▀▀░░█░░█▀▀░█░░░░░█▀█░▀▀█░░█░░█▀▄░█░█░█░█░█░█░█░█░░█░
░▀▀▀░▀▀▀░░▀░░▀▀▀░▀▀▀░░░▀░▀░▀▀▀░░▀░░▀░▀░▀▀▀░▀░▀░▀▀▀░▀░▀░░▀░'
_keeper_secrets_banner() {
  if [[ -t 2 ]]; then
    print -u2 -P -- "\n%F{75}${_keeper_secrets_art//\%/%%}%f\n"
    print -u2 -P -- "%F{75}▸%f %B${1//\%/%%}%b"
  else
    print -u2 -rl -- "" "$_keeper_secrets_art" "" "▸ $1"
  fi
}

_keeper_secrets_count() {
  print -rn -- "$1 managed secret${${1:#1}:+s}"
}

# Runs keeper with no controlling terminal and in batch mode, so an expired login
# fails at once (and is logged) instead of prompting. A background refresh that
# prompts is stopped by the terminal and holds the lock until it's killed.
_keeper_secrets_keeper() {
  if (( $+commands[setsid] )); then
    setsid -w timeout 30s keeper --batch-mode -
  else
    timeout 30s keeper --batch-mode -
  fi
}

# Fills the caller's `fetched` array from Keeper, and with --search also the
# caller's `seen` array with every env:global:* name in Keeper. Uses one keeper
# process for everything: each keeper login rotates the clone code in Keeper's
# config, and concurrent logins revoke persistent login, so keeper must never run
# in parallel (callers hold the cache lock). '@' keeps batch mode going past a
# missing record; JSON carries each record's title so values are matched by name,
# NUL-separated so any character in a value is safe.
_keeper_secrets_fetch() {
  local title value search=
  [[ $1 == --search ]] && { search=1; shift }
  (( $# )) || [[ -n $search ]] || return 0

  while IFS= read -r -d '' title && IFS= read -r -d '' value; do
    if [[ $title == '?' ]]; then
      seen+=(${value#env:global:})
    elif [[ -n "$value" ]]; then
      fetched[${title#env:global:}]=$value
    fi
  done < <(
    {
      [[ -n $search ]] && print -r -- '@search --format json env:global:'
      (( $# )) && printf '@get --format=json env:global:%s\n' "$@"
    } | _keeper_secrets_keeper 2>>"${_keeper_secrets_log:-/dev/null}" \
      | jq -j 'if type == "array"
               then .[] | (.name // "") | select(startswith("env:global:")) | "?", "\u0000", ., "\u0000"
               else (.title // ""), "\u0000", (first(.fields[]? | select(.type == "password") | .value[0]) // ""), "\u0000"
               end' 2>/dev/null
  )
}

# Fills the caller's `cached` array. The cache is NUL-separated name/value pairs:
# data only, never sourced, and names not in the list are ignored.
_keeper_secrets_read_cache() {
  local name value
  [[ -r $_keeper_secrets_dir/cache ]] || return 0

  while IFS= read -r -d '' name && IFS= read -r -d '' value; do
    (( ${_keeper_secrets_names[(Ie)$name]} )) && cached[$name]=$value
  done < "$_keeper_secrets_dir/cache"
}

# Writes the caller's `cached` array atomically. Caller holds the lock.
_keeper_secrets_write_cache() {
  local name tmp=$_keeper_secrets_dir/.cache.$$
  (
    umask 077
    for name in ${(k)cached}; do print -rN -- "$name" "${cached[$name]}"; done >| "$tmp"
  ) && mv -f -- "$tmp" "$_keeper_secrets_dir/cache"
}

_keeper_secrets_load_cache() {
  local name
  local -A cached

  _keeper_secrets_read_cache
  for name in ${(k)cached}; do
    (( ${+_keeper_secrets_skip[$name]} )) || export "$name=${cached[$name]}"
  done

  _keeper_secrets_stat "$_keeper_secrets_dir/cache"
  _keeper_secrets_loaded=$reply[1]
}

# Fetches the names from Keeper and merges them into the cache; a name that fails
# keeps its cached value. With --search, also records env:global:* records that
# are neither listed nor ignored. Sets reply to the failed names. Caller holds the lock.
_keeper_secrets_update() {
  local name tmp search=
  [[ $1 == --search ]] && { search=$1; shift }
  local -a failed seen unlisted
  local -A cached fetched

  _keeper_secrets_read_cache
  _keeper_secrets_fetch $search "$@"

  for name in "$@"; do
    if [[ -n ${fetched[$name]} ]]; then
      cached[$name]=${fetched[$name]}
    else
      failed+=($name)
    fi
  done

  (( ${#fetched} )) && _keeper_secrets_write_cache

  # An empty search result means the search itself failed, not that Keeper is empty.
  if (( ${#seen} )); then
    for name in $seen; do
      [[ $name =~ '^[A-Za-z0-9_]+$' ]] || continue
      (( ${_keeper_secrets_names[(Ie)$name]} || ${_keeper_secrets_ignore[(Ie)$name]} )) || unlisted+=($name)
    done
    tmp=$_keeper_secrets_dir/.unlisted.$$
    { (( ${#unlisted} )) && print -rl -- $unlisted } >| "$tmp"
    mv -f -- "$tmp" "$_keeper_secrets_dir/unlisted"
  fi

  if (( ${#failed} )); then
    print -r -- "$(strftime '%F %T' $EPOCHSECONDS) refresh failed: ${failed[*]}" >> "$_keeper_secrets_log"
    tmp=$_keeper_secrets_dir/.error.$$
    print -r -- "${failed[*]}" >| "$tmp" && mv -f -- "$tmp" "$_keeper_secrets_dir/error"
  else
    rm -f -- "$_keeper_secrets_dir/error"
  fi

  reply=($failed)
}

_keeper_secrets_needs_refresh() {
  _keeper_secrets_stat "$_keeper_secrets_dir/attempt"
  (( EPOCHSECONDS - REPLY >= KEEPER_SECRETS_RETRY )) || return 1
  _keeper_secrets_stat "$_keeper_secrets_dir/cache"
  (( EPOCHSECONDS - REPLY >= KEEPER_SECRETS_TTL ))
}

# Refreshes the whole cache in a detached process. The lock means only one shell
# ever runs keeper; the others skip, then load the result at their next prompt.
_keeper_secrets_bg_refresh() {
  _keeper_secrets_have_cli || return 0
  (
    zsystem flock -t 0 -f lockfd "$_keeper_secrets_dir/lock" 2>/dev/null || exit 0
    _keeper_secrets_needs_refresh || exit 0  # another shell refreshed while we waited
    : >| "$_keeper_secrets_dir/attempt"
    local -A st
    zstat -H st -- "$_keeper_secrets_log" 2>/dev/null && (( st[size] > 100000 )) && : >| "$_keeper_secrets_log"
    _keeper_secrets_sync_list
    _keeper_secrets_update --search $_keeper_secrets_names
  ) </dev/null >>"$_keeper_secrets_log" 2>&1 &!
}

# Prints a one-line notice for unlisted Keeper records not reported before. The
# reported file is shared, so each record is announced once, not once per shell.
_keeper_secrets_report_unlisted() {
  local name
  local -a unlisted reported new

  [[ -s $_keeper_secrets_dir/unlisted ]] || return 0
  unlisted=(${(f)"$(<$_keeper_secrets_dir/unlisted)"})
  [[ -r $_keeper_secrets_dir/reported ]] && reported=(${(f)"$(<$_keeper_secrets_dir/reported)"})

  for name in $unlisted; do
    (( ${_keeper_secrets_names[(Ie)$name]} || ${_keeper_secrets_ignore[(Ie)$name]} || ${reported[(Ie)$name]} )) || new+=($name)
  done
  (( ${#new} )) || return 0

  print -rl -- $new >> "$_keeper_secrets_dir/reported"
  print -u2 -r -- "keeper-secrets: Keeper has env:global records not in keeper-secrets.list: ${new[*]}. Use 'secrets-add NAME' to load one, or add 'ignore NAME' to the list."
}

_keeper_secrets_precmd() {
  [[ -n $KEEPER_SECRETS_DISABLED ]] && return
  _keeper_secrets_cache_ready || return

  _keeper_secrets_sync_list && _keeper_secrets_load_cache

  _keeper_secrets_stat "$_keeper_secrets_dir/cache"
  [[ -n $reply[1] && $reply[1] != $_keeper_secrets_loaded ]] && _keeper_secrets_load_cache

  _keeper_secrets_stat "$_keeper_secrets_dir/error"
  if [[ -n $reply[1] && $reply[1] != $_keeper_secrets_warned ]]; then
    _keeper_secrets_warned=$reply[1]
    print -u2 -r -- "keeper-secrets: refresh failed for $(<$_keeper_secrets_dir/error); using cached values (log: $_keeper_secrets_log)"
  fi

  _keeper_secrets_stat "$_keeper_secrets_dir/unlisted"
  if [[ $reply[1] != $_keeper_secrets_unlisted_sig ]]; then
    _keeper_secrets_unlisted_sig=$reply[1]
    _keeper_secrets_report_unlisted
  fi

  _keeper_secrets_needs_refresh && _keeper_secrets_bg_refresh
}

# Waits for the cache lock (so two keeper processes never overlap) and sets
# REPLY to its fd. Without a cache there is nothing to lock.
_keeper_secrets_lock() {
  local lockfd
  REPLY=
  _keeper_secrets_cache_ready || return 0
  if ! zsystem flock -t 45 -f lockfd "$_keeper_secrets_dir/lock"; then
    echo "Timed out waiting for another Keeper refresh to finish." >&2
    return 1
  fi
  REPLY=$lockfd
}

_keeper_secrets_unlock() {
  [[ -n $1 ]] && zsystem flock -u $1
}

_keeper_secrets_refresh_names() {
  local name lockfd search=
  [[ $1 == --search ]] && { search=$1; shift }
  local -a failed
  local -A fetched

  if ! _keeper_secrets_have_cli; then
    echo "keeper and jq CLIs are required." >&2
    return 1
  fi

  (( $# )) || return 0

  unset KEEPER_SECRETS_DISABLED
  for name in "$@"; do unset "_keeper_secrets_skip[$name]"; done

  _keeper_secrets_lock || return 1
  lockfd=$REPLY

  if [[ -n $lockfd ]]; then
    _keeper_secrets_update $search "$@"
    failed=($reply)
    _keeper_secrets_unlock $lockfd
    _keeper_secrets_load_cache
  else
    _keeper_secrets_fetch "$@"
    for name in "$@"; do
      if [[ -n ${fetched[$name]} ]]; then
        export "$name=${fetched[$name]}"
      else
        failed+=($name)
      fi
    done
  fi

  if (( ${#failed} )); then
    echo "Keeper secrets not loaded: ${failed[*]}. Check Keeper persistent login${_keeper_secrets_log:+ and $_keeper_secrets_log}." >&2
    return 1
  fi
}

secrets-refresh() {
  _keeper_secrets_sync_list
  _keeper_secrets_select "$@"
  local -a names=($reply)

  _keeper_secrets_banner "Refreshing $(_keeper_secrets_count ${#names}) from Keeper${*:+ (matching: $*)}"
  if (( ! ${#names} )); then
    print -u2 -r -- "No managed secrets match${*:+ '$*'}. See secrets-status."
    return 1
  fi

  # A full refresh also checks Keeper for env:global records missing from the list.
  if (( $# )); then
    _keeper_secrets_refresh_names $names
  else
    _keeper_secrets_refresh_names --search $names
  fi || return

  print -u2 -r -- "Refreshed: ${names[*]}"
}

# Adds a managed secret. If Keeper already has env:global:NAME it is adopted;
# otherwise the value is read with hidden input and the record is created. Either
# way the name is appended to the list and loaded into the cache and this shell.
secrets-add() {
  local name=$1 value tags out lockfd
  local -a seen
  local -A fetched cached

  if (( $# == 0 )); then
    echo "usage: secrets-add VAR_NAME [search tags...]" >&2
    return 2
  fi
  shift
  tags="$*"

  _keeper_secrets_sync_list
  if ! _keeper_secrets_valid_name "$name"; then
    echo "secrets-add: '$name' is not allowed: use UPPER_CASE letters, digits and _, and no system names like PATH or LD_*." >&2
    return 1
  fi
  if (( ${_keeper_secrets_names[(Ie)$name]} )); then
    echo "secrets-add: $name is already in $_keeper_secrets_list. Use 'secrets-refresh ${(L)name}' to reload it." >&2
    return 1
  fi
  if (( ${_keeper_secrets_ignore[(Ie)$name]} )); then
    echo "secrets-add: $name is marked 'ignore' in $_keeper_secrets_list; remove that line first." >&2
    return 1
  fi
  if ! _keeper_secrets_have_cli; then
    echo "keeper and jq CLIs are required." >&2
    return 1
  fi

  _keeper_secrets_banner "Adding $name"
  print -u2 -r -- "Checking Keeper for env:global:$name…"
  _keeper_secrets_lock || return 1
  lockfd=$REPLY
  _keeper_secrets_fetch "$name"
  _keeper_secrets_unlock $lockfd

  if [[ -n ${fetched[$name]} ]]; then
    echo "Using the existing Keeper record env:global:$name."
  else
    # Hidden input: the value never reaches the screen, shell history or ps.
    IFS= read -rs "value?Value for $name (input hidden): " || { print; return 1; }
    print

    # record-add trims whitespace, treats a leading '=' as escaping and '$GEN' as
    # "generate a password", so refuse values it would silently change.
    if [[ -z $value ]]; then
      echo "secrets-add: empty value, nothing added." >&2
      return 1
    elif [[ $value == [[:space:]]* || $value == *[[:space:]] || $value == '='* || ${(U)value} == '$GEN'* ]]; then
      echo "secrets-add: values starting with '=' or '\$GEN', or with leading/trailing spaces, can't be stored by keeper record-add; add this one in the Keeper app." >&2
      return 1
    fi

    print -u2 -r -- "Saving env:global:$name to Keeper…"
    _keeper_secrets_lock || return 1
    lockfd=$REPLY
    {
      # The value travels on keeper's stdin (print is a builtin), never in argv.
      out=$(print -r -- "record-add -t env:global:$name -rt login login=$name password=${(qq)value}" | _keeper_secrets_keeper 2>&1)
      _keeper_secrets_fetch "$name"
    } always {
      _keeper_secrets_unlock $lockfd
    }

    if [[ ${fetched[$name]} != "$value" ]]; then
      echo "secrets-add: Keeper did not save env:global:$name." >&2
      out=${out//${(qq)value}/<redacted>}
      [[ -n $out ]] && print -u2 -r -- "${out//$value/<redacted>}"
      return 1
    fi
    value=
    echo "Created Keeper record env:global:$name."
  fi

  _keeper_secrets_lock || return 1
  lockfd=$REPLY
  {
    # Keep the list's last line intact if it was saved without a trailing newline.
    [[ -s $_keeper_secrets_list && "$(tail -c1 -- "$_keeper_secrets_list"; print x)" != $'\nx' ]] && print >> "$_keeper_secrets_list"
    if [[ -n $tags ]]; then
      printf '%-24s %s\n' "$name" "$tags"
    else
      print -r -- "$name"
    fi >> "$_keeper_secrets_list"
    _keeper_secrets_read_list

    if [[ -n $lockfd ]]; then
      _keeper_secrets_read_cache
      cached[$name]=${fetched[$name]}
      _keeper_secrets_write_cache
    fi
  } always {
    _keeper_secrets_unlock $lockfd
  }

  unset "_keeper_secrets_skip[$name]"
  if [[ -n $lockfd ]]; then
    _keeper_secrets_load_cache
  else
    export "$name=${fetched[$name]}"
  fi

  echo "Added $name to $_keeper_secrets_list (other shells load it at their next prompt)."
}

secrets-status() {
  local name state
  local -a unlisted
  local -A cached

  _keeper_secrets_banner "Checking secret status"
  _keeper_secrets_sync_list
  print -r -- "List:  $_keeper_secrets_list"
  if _keeper_secrets_cache_ready; then
    _keeper_secrets_stat "$_keeper_secrets_dir/cache"
    if (( REPLY )); then
      print -r -- "Cache: $_keeper_secrets_dir (updated $(( (EPOCHSECONDS - REPLY) / 60 )) min ago; refreshes after $(( KEEPER_SECRETS_TTL / 60 )) min)"
    else
      print -r -- "Cache: $_keeper_secrets_dir (empty)"
    fi
    _keeper_secrets_read_cache
  else
    print "Cache: none (XDG_RUNTIME_DIR is not set)"
  fi
  [[ -n $KEEPER_SECRETS_DISABLED ]] && print "Auto-loading is off in this shell (secrets-unset or nosecrets)."

  print "\nManaged (${#_keeper_secrets_names}):"
  for name in $_keeper_secrets_names; do
    if (( ${+_keeper_secrets_skip[$name]} )); then
      state="unset in this shell"
    elif [[ -n "${(P)name}" ]]; then
      state="loaded"
    else
      state="not loaded"
    fi
    [[ -s $_keeper_secrets_dir/cache && -z ${cached[$name]} ]] && state+=", not in cache"
    printf '  %-28s %s\n' "$name" "$state"
  done

  (( ${#_keeper_secrets_ignore} )) && print -r -- $'\n'"Ignored: ${_keeper_secrets_ignore[*]}"

  if [[ -s $_keeper_secrets_dir/unlisted ]]; then
    for name in ${(f)"$(<$_keeper_secrets_dir/unlisted)"}; do
      (( ${_keeper_secrets_names[(Ie)$name]} || ${_keeper_secrets_ignore[(Ie)$name]} )) || unlisted+=($name)
    done
  fi
  if (( ${#unlisted} )); then
    print -r -- $'\n'"In Keeper but not listed (as of the last full refresh): ${unlisted[*]}"
    print "  Use 'secrets-add NAME' to load one, or add 'ignore NAME' to the list."
  fi

  [[ -s $_keeper_secrets_dir/error ]] && print -r -- $'\n'"Last refresh failed for: $(<$_keeper_secrets_dir/error) (log: $_keeper_secrets_log)"
  return 0
}

secrets-unset() {
  local name

  _keeper_secrets_select "$@"
  _keeper_secrets_banner "Unsetting $(_keeper_secrets_count ${#reply})${*:+ (matching: $*)}"
  for name in $reply; do
    unset "$name"
    _keeper_secrets_skip[$name]=1
  done

  # With no filter, child shells started from here don't auto-load either.
  (( $# )) || export KEEPER_SECRETS_DISABLED=1
  if (( ${#reply} )); then
    print -u2 -r -- "Unset: ${reply[*]}"
  else
    print -u2 -r -- "No managed secrets match${*:+ '$*'}."
  fi
}

nosecrets() {
  if (( $# == 0 )); then
    echo "usage: nosecrets <cmd> [args...]" >&2
    return 2
  fi

  local name
  local -a unset_args

  _keeper_secrets_banner "Running $1 without $(_keeper_secrets_count ${#_keeper_secrets_names})"
  for name in $_keeper_secrets_names; do
    unset_args+=(-u "$name")
  done

  # KEEPER_SECRETS_DISABLED stops any shell inside the command from re-loading them.
  env "${unset_args[@]}" KEEPER_SECRETS_DISABLED=1 "$@"
}

_keeper_secrets_read_list

if [[ -z $KEEPER_SECRETS_DISABLED ]] && _keeper_secrets_cache_ready; then
  _keeper_secrets_load_cache
  _keeper_secrets_needs_refresh && _keeper_secrets_bg_refresh
fi

if [[ -o interactive ]]; then
  autoload -Uz add-zsh-hook
  add-zsh-hook precmd _keeper_secrets_precmd
fi
