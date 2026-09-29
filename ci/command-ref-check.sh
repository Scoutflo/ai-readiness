#!/bin/sh
# command-ref-check.sh — every ${CLAUDE_PLUGIN_ROOT}-relative *.sh reference in a
# SKILL.md / references doc must resolve to a shipped file, and the DEMOTED
# `scoutflo_addsecret` helper must never appear as a runnable recipe line
# (prose or an optional note is fine).
#
# Why this exists: IMP-012 was a live "command not found" trap — providers.md's
# provider recipes still invoked the `scoutflo_addsecret` shell FUNCTION that
# v0.1.207 had removed, and nothing caught it mechanically; a human rubric review
# caught it, twice. Separately, a skill that references
# `${CLAUDE_PLUGIN_ROOT}/skills/x/scripts/foo.sh` after that script is renamed or
# removed leaves a dead reference every other static gate passes over. This gate
# makes both drift classes a red CI check, closing the doc<->code drift class
# going forward.
#
# What it flags:
#   (1) a `${CLAUDE_PLUGIN_ROOT}` / `${CLAUDE_PLUGIN_ROOT:-.}`-relative `*.sh`
#       reference whose target file does not exist under the repo root, AND
#   (2) `scoutflo_addsecret` on a non-comment line INSIDE a fenced ``` block (a
#       runnable recipe) — the shipped `addsecret.sh` is the only supported
#       secret writer; the function was removed in v0.1.207.
#
# Scope is deliberately narrow to stay false-positive-free: only the runnable,
# plugin-root-relative script references skills actually execute (all four forms:
# `sh "${...}/x.sh"`, `. "${...}/x.sh"`, `VAR="${...}/x.sh"`, and the `:-.`
# variant), across skills/*/SKILL.md and skills/*/references/*.md. Bare-relative
# invocations, markdown link targets, and prose are out of scope here.
#
# Read-only. POSIX sh + awk.
set -eu
DIR="${1:-.}"
FAIL=0

# (1) emit "<line> <plugin-root-relative-path>" for each ${CLAUDE_PLUGIN_ROOT}/*.sh
#     reference in the file (line numbers have no spaces, paths have no spaces).
refs() {
  awk '
    {
      s = $0
      while (match(s, /\$\{CLAUDE_PLUGIN_ROOT(:-\.)?\}\/[A-Za-z0-9_.\/-]+\.sh/)) {
        tok = substr(s, RSTART, RLENGTH)
        s = substr(s, RSTART + RLENGTH)
        p = tok
        sub(/^\$\{CLAUDE_PLUGIN_ROOT(:-\.)?\}\//, "", p)
        print FNR " " p
      }
    }
  ' "$1"
}

# (2) emit "<line>: <content>" for each scoutflo_addsecret occurrence inside a
#     fenced ``` block that is not a comment line.
addsecret_recipe() {
  awk '
    /^[[:space:]]*```/ { inblock = !inblock; next }
    inblock {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^#/) next
      if (line ~ /scoutflo_addsecret/) print FNR ": " $0
    }
  ' "$1"
}

for f in "$DIR"/skills/*/SKILL.md "$DIR"/skills/*/references/*.md; do
  [ -f "$f" ] || continue

  # (1) unresolved ${CLAUDE_PLUGIN_ROOT}-relative *.sh references
  MISS=""
  REFLIST="$(refs "$f")"
  if [ -n "$REFLIST" ]; then
    OLDIFS=$IFS
    IFS='
'
    for entry in $REFLIST; do
      ln=${entry%% *}
      p=${entry#* }
      [ -n "$p" ] || continue
      [ -f "$DIR/$p" ] || MISS="${MISS}COMMAND-REF: $f:$ln: \${CLAUDE_PLUGIN_ROOT}/$p does not resolve to a shipped file
"
    done
    IFS=$OLDIFS
  fi
  if [ -n "$MISS" ]; then
    printf '%s' "$MISS"
    FAIL=1
  fi

  # (2) scoutflo_addsecret as a runnable recipe line
  RECIPE="$(addsecret_recipe "$f")"
  if [ -n "$RECIPE" ]; then
    echo "COMMAND-REF: $f invokes the removed scoutflo_addsecret helper as a runnable recipe line (use the shipped addsecret.sh; prose/notes are fine):"
    printf '%s\n' "$RECIPE"
    FAIL=1
  fi
done

if [ "$FAIL" -ne 0 ]; then
  echo "COMMAND-REF CHECK FAILED"
  exit 1
fi
echo "COMMAND-REF-OK (every \${CLAUDE_PLUGIN_ROOT}/*.sh reference resolves to a shipped file; scoutflo_addsecret never a runnable recipe line)"
