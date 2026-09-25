#!/bin/sh
# doctor missing_hint: the three env-missing branches (malformed / missing-export /
# not-present) each name the precise fix and point at the shipped addsecret.sh.
# Read-only and leak-safe (greps the NAME, never the value). Extracts the SHIPPED
# function from doctor.sh so this can't drift from a copy.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
D="$ROOT/skills/doctor/scripts/doctor.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }
ok() { echo "ok: $1"; }
[ -f "$D" ] || fail "doctor.sh missing"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
SCOUTFLO_ENV="$WORK/env"
ADDSECRET="/PLUGIN/skills/connect/scripts/addsecret.sh"

awk '/^missing_hint\(\) \{/,/^\}/' "$D" > "$WORK/fn.sh"
grep -q 'missing_hint()' "$WORK/fn.sh" || fail "could not extract missing_hint from doctor.sh"
. "$WORK/fn.sh"

# A. correctly export-prefixed line present but did not load -> did-not-parse
printf "export GRAFANA_TOKEN='sekret'\n" > "$SCOUTFLO_ENV"
MA=$(missing_hint GRAFANA_TOKEN)
printf '%s' "$MA" | grep -q "failed to parse" || fail "prefixed-but-unloaded should say it failed to parse: $MA"
printf '%s' "$MA" | grep -q "addsecret.sh GRAFANA_TOKEN" || fail "branch A should point at the shipped writer: $MA"
printf '%s' "$MA" | grep -q "sekret" && fail "hint A leaked the value" || :
ok "branch A: unparseable line (points at addsecret)"

# B. line present WITHOUT export prefix -> missing-export, points at addsecret
printf "GRAFANA_TOKEN=sekret\n" > "$SCOUTFLO_ENV"
MB=$(missing_hint GRAFANA_TOKEN)
printf '%s' "$MB" | grep -q "missing the 'export ' prefix" || fail "no-export should flag the missing prefix: $MB"
printf '%s' "$MB" | grep -q "$ADDSECRET" || fail "no-export hint should point at addsecret.sh"
printf '%s' "$MB" | grep -q "sekret" && fail "hint B leaked the value" || :
ok "branch B: missing export prefix -> addsecret"

# C. not present at all -> shell-only cause, points at addsecret
: > "$SCOUTFLO_ENV"
MC=$(missing_hint GRAFANA_TOKEN)
printf '%s' "$MC" | grep -qi "invisible" || fail "absent should name the shell-only cause: $MC"
printf '%s' "$MC" | grep -q "$ADDSECRET" || fail "absent hint should point at addsecret.sh"
ok "branch C: absent -> shell-only cause + addsecret"

echo "PASS: doctor env-missing hints"
