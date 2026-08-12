#!/bin/sh
# min-version-consistency-check.sh — the stated minimum Claude Code version must
# be ONE number, identical everywhere it appears, and it must match the floor the
# doctor client-version check enforces.
#
# Why this exists: the minimum version was written three different ways across
# README.md, docs/install.md, and docs/faq.md ("roughly v2.1.140", "~v2.1.140+",
# "v2.1.140 or newer"). Inconsistent floors are how a customer ends up unsure
# what they actually need. This gate pins a single canonical token and keeps the
# docs in lockstep with skills/doctor/scripts/doctor.sh's MIN_CLAUDE_VERSION, so
# a future bump to the floor has to be made in one deliberate, consistent sweep.
#
# Read-only. POSIX sh + grep/sed.
set -eu
DIR="${1:-.}"
FAIL=0

DOCTOR="$DIR/skills/doctor/scripts/doctor.sh"
DOCS="$DIR/README.md $DIR/docs/install.md $DIR/docs/faq.md"

# 1. The floor the code enforces (source of truth).
[ -f "$DOCTOR" ] || { echo "MIN-VERSION: $DOCTOR not found"; exit 1; }
CODE_FLOOR="$(sed -n 's/^MIN_CLAUDE_VERSION="\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p' "$DOCTOR" | head -1)"
[ -n "$CODE_FLOOR" ] || { echo "MIN-VERSION: no MIN_CLAUDE_VERSION=\"x.y.z\" in doctor.sh"; exit 1; }

# 2. Every v2.1.x-style floor token that appears in the customer docs.
#    Collect distinct vX.Y.Z tokens; there must be exactly one, and it must equal
#    the code floor (with the leading 'v' the docs use).
TOKENS="$(grep -rhoE 'v[0-9]+\.[0-9]+\.[0-9]+' $DOCS 2>/dev/null | sort -u)"
[ -n "$TOKENS" ] || { echo "MIN-VERSION: no version floor token (vX.Y.Z) found in README/install/faq — the minimum must be stated"; exit 1; }

NTOK="$(printf '%s\n' "$TOKENS" | grep -c .)"
if [ "$NTOK" -ne 1 ]; then
  echo "MIN-VERSION: the docs state more than one distinct version token — pin a single minimum:"
  printf '  %s\n' $TOKENS
  FAIL=1
fi

DOC_FLOOR="$(printf '%s\n' "$TOKENS" | head -1 | sed 's/^v//')"
if [ "$DOC_FLOOR" != "$CODE_FLOOR" ]; then
  echo "MIN-VERSION: docs floor (v${DOC_FLOOR}) != doctor.sh MIN_CLAUDE_VERSION (${CODE_FLOOR}); keep them identical"
  FAIL=1
fi

# 3. Each of the three docs must actually state the floor (not silently drop it).
for f in $DOCS; do
  [ -f "$f" ] || continue
  grep -qE "v${CODE_FLOOR}" "$f" || { echo "MIN-VERSION: $f does not state the minimum v${CODE_FLOOR}"; FAIL=1; }
done

if [ "$FAIL" -ne 0 ]; then
  echo "MIN-VERSION CHECK FAILED"
  exit 1
fi
echo "MIN-VERSION-OK (single stated minimum v${CODE_FLOOR}, consistent across docs and doctor.sh)"
