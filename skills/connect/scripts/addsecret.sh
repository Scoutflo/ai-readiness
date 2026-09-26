#!/bin/sh
# addsecret.sh — write ONE credential into the Scoutflo secret store the plugin
# actually reads. Shipped as a real command so it can never be "command not
# found" the way the scoutflo_addsecret shell function can (that trap left a
# customer's store empty and every token reading as missing).
#
#   Usage:  sh addsecret.sh VARNAME              # prompts SILENTLY for a literal value
#           sh addsecret.sh --command VARNAME    # prompts for a COMMAND; stores
#                                                #   export VAR="$(command)" — runs on every
#                                                #   store load (e.g. vault kv get). Trusted fetch only.
#
# Guarantees (same as the scoutflo_addsecret function, minus the parent-shell
# export a subprocess cannot do):
#  - the NAME is a fixed argument, so a wrapped paste can never split it
#    (HDX_EU_KEY never becomes "HDX_E U_KEY") and there is no path to "export VAR==";
#  - the value is read once, silently, never echoed, never in argv or shell history;
#  - it is single-quote-escaped before storage, so a $, ", ' or backtick is stored
#    literally;
#  - a re-run REPLACES that variable's line, never appends a duplicate;
#  - the store stays chmod 600;
#  - it prints only the NAME and where it was saved — NEVER the value (leak-safe).
#
# It writes to the SAME store doctor and every audit read (resolved identically:
# $SCOUTFLO_ENV_FILE, else ./.scoutflo/env if it exists, else ~/.scoutflo/env), so
# a token added here is picked up in the same run. Being a subprocess it cannot
# export into your current shell; load it here with `. <store>` (printed at the
# end) or open a new terminal — doctor/audits read the file directly either way.
set -eu
# Tighten the mode of anything we create (the store, its dir, and the temp file
# that briefly holds the secret) to owner-only, so a secret is never group- or
# world-readable even for the sub-millisecond before the explicit chmod 600.
umask 077

_n="${1:-}"
_mode=value
case "$_n" in
  -h|--help) echo "usage: sh addsecret.sh VARNAME            (prompts silently for a literal value)"; echo "       sh addsecret.sh --command VARNAME  (prompts for a command; stores export VAR=\"\$(command)\" — runs on load, e.g. vault kv get)"; exit 0 ;;
  --command|-c) _mode=command; _n="${2:-}" ;;
  "") echo "usage: sh addsecret.sh VARNAME | --command VARNAME" >&2; exit 2 ;;
esac
[ -n "$_n" ] || { echo "usage: sh addsecret.sh --command VARNAME  (a variable name is required)" >&2; exit 2; }
# The name must be a valid env identifier; reject a mistyped/split name (e.g. a
# wrapped paste that put a space in it) instead of writing a line nothing can read.
case "$_n" in
  [0-9]*|*[!A-Za-z0-9_]*)
    echo "addsecret: '$_n' is not a valid variable name (letters, digits, underscore; not starting with a digit)" >&2
    exit 2 ;;
esac

# Resolve the store EXACTLY as doctor/audits do, so we write where they read.
STORE="${SCOUTFLO_ENV_FILE:-}"
if [ -z "$STORE" ]; then
  if [ -f "./.scoutflo/env" ]; then STORE="./.scoutflo/env"; else STORE="$HOME/.scoutflo/env"; fi
fi
mkdir -p "$(dirname "$STORE")" && touch "$STORE" && chmod 600 "$STORE"

if [ "$_mode" = command ]; then
  # Command-sourced secret. The store is a sourced shell file, so `export VAR="$(cmd)"` runs
  # the command every time the store loads (doctor + every audit source it). The command LINE
  # is not itself the secret, so read it visibly; the resolved VALUE is never written here (it
  # resolves at load, not now). Use ONLY a trusted secret fetch.
  printf 'command to fetch %s (e.g. vault kv get -field=token secret/grafana): ' "$_n" >&2
  IFS= read -r _c || :
  [ -n "${_c:-}" ] || { echo "addsecret: no command entered; nothing written for $_n" >&2; exit 2; }
  # Write export VAR="$(command)" — NOT single-quote-escaped, so the command substitution
  # survives to run on load. Replace-or-append the line atomically.
  _tmp="${STORE}.tmp.$$"
  { grep -v "^export ${_n}=" "$STORE" 2>/dev/null || :; } > "$_tmp"
  printf 'export %s="$(%s)"\n' "$_n" "$_c" >> "$_tmp"
  mv "$_tmp" "$STORE" && chmod 600 "$STORE"
  unset _c
  echo "$_n saved to $STORE as a command-sourced secret  (load it into this shell with: . $STORE)" >&2
  echo "NOTE: that command RUNS every time the store is loaded (doctor + every audit). Use ONLY a trusted secret fetch (e.g. vault kv get); never an untrusted or side-effecting command. The resolved value is never printed or stored." >&2
else
  # Read the value silently: no echo, no argv, no history. stty guards a non-tty
  # (piped input, e.g. tests) rather than failing.
  printf '%s: ' "$_n" >&2
  stty -echo 2>/dev/null || :
  IFS= read -r _v || :
  stty echo 2>/dev/null || :
  printf '\n' >&2
  [ -n "${_v:-}" ] || { echo "addsecret: no value entered; nothing written for $_n" >&2; exit 2; }

  # Single-quote-escape the value, then replace-or-append the export line atomically.
  _e=$(printf '%s' "$_v" | sed "s/'/'\\\\''/g")
  _tmp="${STORE}.tmp.$$"
  { grep -v "^export ${_n}=" "$STORE" 2>/dev/null || :; } > "$_tmp"
  printf "export %s='%s'\n" "$_n" "$_e" >> "$_tmp"
  mv "$_tmp" "$STORE" && chmod 600 "$STORE"
  unset _v _e
  echo "$_n saved to $STORE  (load it into this shell with: . $STORE)" >&2
fi
