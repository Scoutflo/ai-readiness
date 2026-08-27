#!/bin/sh
# contract-map-check.sh — keeps docs/CONTRACTS.md honest, so the cross-skill
# contract map cannot silently drift from the real gates. Two directions:
#   (1) every gate ci/structure-check.sh composes is named in docs/CONTRACTS.md
#       (a new gate MUST document its contract in the map), and
#   (2) every ci/<name>.sh AND report-standard/<name>.sh the map references
#       actually exists (a renamed/moved guard leaves a dead map reference).
set -eu
DIR="${1:-.}"
MAP="$DIR/docs/CONTRACTS.md"
SC="$DIR/ci/structure-check.sh"
[ -f "$MAP" ] && [ -f "$SC" ] || { echo "CONTRACT-MAP: docs/CONTRACTS.md or ci/structure-check.sh missing" >&2; exit 1; }

rc=0
# (1) gates composed by structure-check must appear in the map
composed="$(grep -oE '[a-z0-9-]+-check\.sh' "$SC" | sort -u)"
for g in $composed; do
  [ "$g" = "structure-check.sh" ] && continue
  grep -q "$g" "$MAP" || { echo "CONTRACT-MAP: gate '$g' is composed by structure-check.sh but not documented in docs/CONTRACTS.md — add its contract/row, then it passes" >&2; rc=1; }
done
# (2) every ci/*.sh AND report-standard/*.sh the map names must exist. Both dirs
# hold guards the map references (report-standard/check-findings.sh, check-report.sh,
# toolkit-targets.sh), so a rename/move in either leaves a dead reference the map
# would otherwise keep asserting green.
for p in $(grep -oE '(ci|report-standard)/[a-z0-9-]+\.sh' "$MAP" | sort -u); do
  [ -f "$DIR/$p" ] || { echo "CONTRACT-MAP: docs/CONTRACTS.md references $p which does not exist" >&2; rc=1; }
done

[ "$rc" = 0 ] && echo "CONTRACT-MAP-OK (every composed gate is documented in CONTRACTS.md; every referenced ci/ and report-standard/ guard exists)"
exit $rc
