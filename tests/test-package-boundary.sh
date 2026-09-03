#!/bin/sh
# Package-boundary gate: every tracked top-level entry must be classified in
# docs/ship-manifest.md as either runtime SHIP surface or dev-only STRIP-able,
# and every SHIP path must exist. This stops a new top-level directory from
# silently landing on either side of the ship boundary unreviewed. It is a
# CHECK, not a build step — it changes nothing about what ships today.
#
# Run from the repo root (run-tests.sh does this). POSIX sh.
set -eu

ROOT="${1:-.}"
cd "$ROOT"

# Runtime surface a plugin consumer needs.
SHIP=".claude-plugin skills report-standard templates LICENSE README.md CHANGELOG.md"
# Dev-only paths safe to strip from a published artifact.
DEV=".claude .github .gitignore .gitleaksignore AGENTS.md CLAUDE.md GEMINI.md CONTRIBUTING.md ENGINEERING.md ci docs tests"

MANIFEST="docs/ship-manifest.md"
[ -f "$MANIFEST" ] || { echo "PACKAGE-BOUNDARY: $MANIFEST missing (the boundary must be declared)" >&2; exit 1; }

rc=0

# 1. Every tracked top-level entry is classified in exactly one list.
if command -v git >/dev/null 2>&1 && [ -d .git ]; then
  entries="$(git ls-files | sed 's#/.*##' | sort -u)"
else
  entries="$(ls -A | grep -v '^scoutflo-audits$' | sort -u)"
fi
for e in $entries; do
  case " $SHIP $DEV " in
    *" $e "*) : ;;
    *) echo "PACKAGE-BOUNDARY: top-level '$e' is not classified in docs/ship-manifest.md (add it to the SHIP runtime surface or the DEV-only list, then reflect it in $MANIFEST)" >&2; rc=1 ;;
  esac
done

# 2. Every declared SHIP path exists (a runtime surface can't name a missing dir).
for s in $SHIP; do
  [ -e "$s" ] || { echo "PACKAGE-BOUNDARY: declared SHIP path '$s' does not exist" >&2; rc=1; }
done

# 3. The manifest names both halves (keep the doc and the gate in lockstep).
grep -q 'Runtime surface (SHIP' "$MANIFEST" || { echo "PACKAGE-BOUNDARY: $MANIFEST lost its 'Runtime surface (SHIP' section" >&2; rc=1; }
grep -q 'Dev-only (STRIP' "$MANIFEST" || { echo "PACKAGE-BOUNDARY: $MANIFEST lost its 'Dev-only (STRIP' section" >&2; rc=1; }

[ "$rc" = 0 ] && echo "PACKAGE-BOUNDARY-OK (every tracked top-level entry is classified; SHIP surface exists)"
exit "$rc"
