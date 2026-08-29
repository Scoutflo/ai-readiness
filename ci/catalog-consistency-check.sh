#!/bin/sh
# catalog-consistency-check.sh — every public, user-runnable skill must appear in
# BOTH customer-facing catalogs (README.md and the /scoutflo:start catalog), and
# every skill a catalog names must actually exist.
#
# Why this exists: new skills kept shipping without being added to the catalogs
# (rca, business-context, audit-cost, setup-kubernetes were each fixed by hand in
# v0.1.89/93/94/97). A customer reads the catalog to learn what they can run; a
# skill missing from it is effectively invisible, and a catalog entry with no
# skill behind it is a dead command. This gate makes that drift a red CI check
# instead of a thing someone notices three releases later.
#
# The invariant is NOT "every skill in every catalog" — 5 skills are internal
# machinery that other skills call and users never run directly, so they are an
# explicit, documented allowlist below. Everything else (all audit-*, all
# setup-*, and the user-facing harness skills) is "public" and must be cataloged.
#
# Read-only. POSIX sh + grep/sed.
set -eu
DIR="${1:-.}"
FAIL=0

SKILLS_DIR="$DIR/skills"
README="$DIR/README.md"
START="$DIR/skills/start/SKILL.md"

[ -d "$SKILLS_DIR" ] || { echo "CATALOG: $SKILLS_DIR not found"; exit 1; }
[ -f "$README" ]     || { echo "CATALOG: $README not found"; exit 1; }
[ -f "$START" ]      || { echo "CATALOG: $START not found"; exit 1; }

# Internal helper skills: called BY other skills, never run directly by a user,
# so they are intentionally NOT required to be catalog entries. Keep this list
# tight — adding a skill here must be a deliberate "this is machinery" decision.
INTERNAL_HELPERS="correlation-engine checkpoint cost-analysis topology-guided-setup business-context-resolver alert-fatigue"

is_internal() {
  for h in $INTERNAL_HELPERS; do [ "$1" = "$h" ] && return 0; done
  return 1
}

# The set of skill names actually shipped (one dir per skill with a SKILL.md).
SHIPPED=""
for f in "$SKILLS_DIR"/*/SKILL.md; do
  [ -f "$f" ] || continue
  SHIPPED="$SHIPPED $(basename "$(dirname "$f")")"
done

# References a catalog makes, as a set of skill tokens (scoutflo:<name>).
# Matching the whole [a-z0-9-]+ run keeps business-context distinct from
# business-context-resolver (they are different tokens, not a prefix match).
refs() { grep -oE 'scoutflo:[a-z][a-z0-9-]*' "$1" 2>/dev/null | sed 's/^scoutflo://' | sort -u; }
README_REFS="$(refs "$README")"
START_REFS="$(refs "$START")"

in_set() { printf '%s\n' "$2" | grep -qx -- "$1"; }

# 1. Every PUBLIC skill must be named in BOTH catalogs.
for s in $SHIPPED; do
  is_internal "$s" && continue
  in_set "$s" "$README_REFS" || { echo "CATALOG: public skill '$s' is not referenced in README.md — add it to the catalog"; FAIL=1; }
  in_set "$s" "$START_REFS"  || { echo "CATALOG: public skill '$s' is not referenced in skills/start/SKILL.md — add it to the start catalog"; FAIL=1; }
done

# 2. Every skill a catalog names must actually exist (no dead command in the docs).
for r in $README_REFS; do
  in_set "$r" "$(printf '%s\n' $SHIPPED | tr ' ' '\n')" || { echo "CATALOG: README.md references scoutflo:$r but skills/$r/ does not exist (dangling or typo)"; FAIL=1; }
done
for r in $START_REFS; do
  in_set "$r" "$(printf '%s\n' $SHIPPED | tr ' ' '\n')" || { echo "CATALOG: skills/start/SKILL.md references scoutflo:$r but skills/$r/ does not exist (dangling or typo)"; FAIL=1; }
done

if [ "$FAIL" -ne 0 ]; then
  echo "CATALOG-CONSISTENCY CHECK FAILED"
  exit 1
fi
echo "CATALOG-CONSISTENCY-OK (every public skill is in README + start; no dangling catalog entries)"
