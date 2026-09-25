#!/bin/sh
# addsecret.sh locks: writes the export line, escapes special chars, replaces on
# re-run, never prints the value, keeps the store chmod 600, rejects a bad name
# or an empty value. Uses a temp store via SCOUTFLO_ENV_FILE (never ~/.scoutflo).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/skills/connect/scripts/addsecret.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }
ok() { echo "ok: $1"; }
[ -f "$S" ] || fail "addsecret.sh missing"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
STORE="$WORK/env"; export SCOUTFLO_ENV_FILE="$STORE"

# 1. simple write + sourced value round-trips
printf 'simpletok\n' | sh "$S" GRAFANA_TOKEN >/dev/null 2>&1 || fail "simple write exited nonzero"
grep -q "^export GRAFANA_TOKEN=" "$STORE" || fail "no export line written"
GOT=$( . "$STORE"; printf '%s' "${GRAFANA_TOKEN:-}" ); [ "$GOT" = "simpletok" ] || fail "sourced value wrong: '$GOT'"
ok "simple write round-trips"

# 2. special characters stored literally (the single-quote is the critical case)
VAL="a\$b\"c\`d'e f"
printf '%s\n' "$VAL" | sh "$S" SPECIAL >/dev/null 2>&1 || fail "special write exited nonzero"
GOT=$( . "$STORE"; printf '%s' "${SPECIAL:-}" ); [ "$GOT" = "$VAL" ] || fail "special value corrupted: got '$GOT' want '$VAL'"
ok "special chars (\$ \" ' backtick space) round-trip"

# 3. re-run replaces, never duplicates
printf 'first\n'  | sh "$S" DUP >/dev/null 2>&1
printf 'second\n' | sh "$S" DUP >/dev/null 2>&1
N=$(grep -c "^export DUP=" "$STORE"); [ "$N" -eq 1 ] || fail "re-run duplicated DUP ($N lines)"
GOT=$( . "$STORE"; printf '%s' "${DUP:-}" ); [ "$GOT" = "second" ] || fail "re-run did not replace ($GOT)"
ok "re-run replaces (single line, latest value)"

# 4. never prints the value
OUT=$(printf 'TOPSECRETVALUE\n' | sh "$S" LEAKCHK 2>&1)
printf '%s' "$OUT" | grep -q "TOPSECRETVALUE" && fail "addsecret printed the value" || ok "value never printed"

# 5. store stays chmod 600
MODE=$(ls -l "$STORE" | cut -c1-10)
[ "$MODE" = "-rw-------" ] || fail "store perms not 600 ($MODE)"
ok "store is chmod 600"

# 6. invalid name rejected, nothing written
if printf 'x\n' | sh "$S" "BAD NAME" >/dev/null 2>&1; then fail "accepted a name with a space"; fi
grep -q "BAD NAME" "$STORE" && fail "wrote a bad-name line" || :
if printf 'x\n' | sh "$S" 9DIGIT >/dev/null 2>&1; then fail "accepted a name starting with a digit"; fi
ok "invalid names rejected (nonzero exit, nothing written)"

# 7. empty value rejected
if printf '\n' | sh "$S" EMPTYVAR >/dev/null 2>&1; then fail "accepted an empty value"; fi
grep -q "^export EMPTYVAR=" "$STORE" && fail "wrote an empty EMPTYVAR" || :
ok "empty value rejected"

echo "PASS: connect addsecret.sh locks"
