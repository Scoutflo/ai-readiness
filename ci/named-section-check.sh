#!/bin/sh
# named-section-check.sh — every prose reference of the form (cookbook: "Section
# Name") in a skills/*/SKILL.md must resolve to an actual '## Section Name'
# heading in that skill's references/*.md files.
#
# Why this exists: SKILL.md phase lists point at named cookbook sections instead
# of restating commands (e.g. map-topology's (cookbook: "Namespace scan") ->
# references/istio-queries.md '## Namespace scan'). When a reference file is
# edited and a heading is renamed or dropped, the SKILL.md pointer silently goes
# dead — the model follows a reference to a section that no longer exists and
# improvises the commands. That lost-heading regression class was found live;
# this gate makes it a red CI check instead.
#
# Mechanics: extract every quoted name inside a (cookbook: ...) parenthetical —
# a single parenthetical may name several sections, e.g. (cookbook: "Worklist
# lock" and "Batch pull") — and require each to match a heading (## or deeper,
# exact text) in the same skill's references/*.md. Skills with no cookbook
# references are skipped; a skill that uses the form but has no references/
# directory fails.
#
# Read-only. POSIX sh + grep/sed.
set -eu
DIR="${1:-.}"
FAIL=0
TOTAL=0

for f in "$DIR"/skills/*/SKILL.md; do
  [ -f "$f" ] || continue
  SKILL_DIR="$(dirname "$f")"

  # All quoted section names referenced from this SKILL.md, one per line.
  NAMES="$(grep -o '(cookbook:[^)]*)' "$f" 2>/dev/null \
    | grep -o '"[^"]*"' \
    | sed 's/^"//; s/"$//' \
    | sort -u || true)"
  [ -n "$NAMES" ] || continue

  # All heading texts (## or deeper) across this skill's references/*.md,
  # trimmed of the marker and surrounding whitespace.
  HEADINGS=""
  for r in "$SKILL_DIR"/references/*.md; do
    [ -f "$r" ] || continue
    H="$(sed -n 's/^##[#]* *//p' "$r" | sed 's/[[:space:]]*$//')"
    HEADINGS="$HEADINGS
$H"
  done

  if [ -z "$(printf '%s' "$HEADINGS" | tr -d '[:space:]')" ]; then
    echo "NAMED-SECTION: $f references cookbook sections but $SKILL_DIR/references/ has no *.md headings"
    FAIL=1
    continue
  fi

  printf '%s\n' "$NAMES" | while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! printf '%s\n' "$HEADINGS" | grep -qxF "$name"; then
      echo "NAMED-SECTION: $f references (cookbook: \"$name\") but no '## $name' heading exists in $SKILL_DIR/references/*.md — the pointer is dead (renamed or lost heading)"
      exit 1
    fi
  done || FAIL=1

  TOTAL=$((TOTAL + $(printf '%s\n' "$NAMES" | grep -c . || true)))
done

if [ "$FAIL" -ne 0 ]; then
  echo "NAMED-SECTION CHECK FAILED"
  exit 1
fi
echo "NAMED-SECTION-OK ($TOTAL named cookbook reference(s) resolve to real headings)"
