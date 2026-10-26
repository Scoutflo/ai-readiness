#!/bin/sh
# test-doctor-matrix-consumers.sh
#
# doctor's `tint()` writes the matrix's first field as the bare block name when a block
# configures ONE target, and as `<block> (<label>)` when it configures several. Every
# consumer of that matrix used to match the bare form only, so on a multi-target config
# the gate that decides whether a provider's cost checks may run matched ZERO rows — and
# since those sites printed the row with no empty-guard, zero rows printed nothing and
# read exactly like a clean gate. That is how a whole priced-savings section can vanish
# from a report with no error anywhere: the same class that cost a real customer their
# GCP savings figure, arriving from the consumer side instead of the producer side.
#
# This locks all three required behaviours for every consumer shipped in the repo:
#   1. a labeled row is matched (the regression),
#   2. no matching row is a STOP, never silence,
#   3. several matching rows is a STOP, never "pick one and attribute the bill to it".
#
# The awks are extracted from the shipped docs, so the test cannot drift from them.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

echo "=== doctor matrix consumers ==="

# --- find every consumer in the shipped tree -------------------------------------
# A consumer is an awk that reads "$MATRIX" and selects on the block-name field.
CONSUMERS="$WORK/consumers.txt"
grep -rln 'awk -F.\\t. -v b=' "$ROOT/skills" --include='*.md' | sort > "$CONSUMERS"
[ -s "$CONSUMERS" ] || fail "found no matrix consumers at all — did the extraction pattern change?"
N="$(grep -c . "$CONSUMERS")"
echo "found $N file(s) with matrix consumers"

# Every block-name selection in the repo must use the label-tolerant form. A bare
# equality is the bug this test exists to prevent.
if grep -rn '\$1 == "\(aws\|azure\|gcp\|datadog\|digitalocean\|kubernetes\|sentry\|grafana\)" &&' \
     "$ROOT/skills" --include='*.md' > "$WORK/bare.txt" 2>/dev/null; then
  if [ -s "$WORK/bare.txt" ]; then
    fail "a consumer matches the BARE block name only, so a multi-target config matches zero rows:
$(cat "$WORK/bare.txt")"
  fi
fi
echo "PASS: no consumer matches the bare block name alone"

# --- extract each awk and exercise it --------------------------------------------
# Pull the multi-line awk programs out of the fenced blocks.
awk '
  /awk -F.\\t. -v b=/ { inp=1 }
  inp { print }
  inp && /"\$MATRIX"/ { print "###END###"; inp=0 }
' $(cat "$CONSUMERS") > "$WORK/all-awks.txt"
[ -s "$WORK/all-awks.txt" ] || fail "extracted no awk bodies"

# Split into one program per file.
mkdir -p "$WORK/progs"
awk -v d="$WORK/progs" '
  BEGIN { n = 0; f = sprintf("%s/p%03d.sh", d, n) }
  /^###END###$/ { close(f); n++; f = sprintf("%s/p%03d.sh", d, n); next }
  { print > f }
' "$WORK/all-awks.txt"
find "$WORK/progs" -name 'p*.sh' -size 0 -exec rm -f {} +
COUNT="$(find "$WORK/progs" -name 'p*.sh' | wc -l | tr -d ' ')"
[ "$COUNT" -ge 9 ] || fail "expected at least 9 consumer programs, extracted $COUNT"
echo "extracted $COUNT consumer program(s)"

hdr() { printf 'block\tcheck\tconfigured\tenv\tresult\tcode\thint\n'; }

checked=0
for prog in "$WORK"/progs/p*.sh; do
  # The block and check this consumer selects on.
  b="$(sed -n 's/.*-v b="\([^"]*\)".*/\1/p' "$prog" | head -1)"
  c="$(sed -n 's/.*-v c="\([^"]*\)".*/\1/p' "$prog" | head -1)"
  [ -n "$b" ] && [ -n "$c" ] || fail "could not read b/c out of $prog"

  # 1. A LABELED row must be matched. This is the regression.
  M="$WORK/m.tsv"; hdr > "$M"
  printf '%s (prod)\t%s\tyes\t-\tpass\t200\t-\n' "$b" "$c" >> "$M"
  out="$(MATRIX="$M" sh -c "$(cat "$prog")" 2>"$WORK/err")" \
    || fail "$b/$c: a single LABELED target was not matched (exit non-zero): $(cat "$WORK/err")"
  printf '%s' "$out" | grep -q "$b" \
    || fail "$b/$c: a single LABELED target produced no row (this is the zero-match bug)"

  # The bare form must keep working — single-target configs are the common case.
  hdr > "$M"; printf '%s\t%s\tyes\t-\tpass\t200\t-\n' "$b" "$c" >> "$M"
  MATRIX="$M" sh -c "$(cat "$prog")" >/dev/null 2>&1 \
    || fail "$b/$c: the BARE (single-target) form stopped being matched"

  # 2. No row at all must STOP, not print nothing.
  hdr > "$M"
  if MATRIX="$M" sh -c "$(cat "$prog")" >/dev/null 2>&1; then
    fail "$b/$c: a matrix with NO matching row exited 0 — a missing gate row must stop the phase, never read as a pass"
  fi

  # 3. Several targets must STOP rather than attribute one target's answer to another.
  hdr > "$M"
  printf '%s (prod)\t%s\tyes\t-\tpass\t200\t-\n' "$b" "$c" >> "$M"
  printf '%s (dr)\t%s\tyes\t-\tskipped\t-\tno access\n' "$b" "$c" >> "$M"
  if MATRIX="$M" sh -c "$(cat "$prog")" >/dev/null 2>&1; then
    fail "$b/$c: TWO matching targets exited 0 — the gate must stop and ask for SCOUTFLO_TARGET, not pick one"
  fi

  checked=$((checked + 1))
done

[ "$checked" -ge 9 ] || fail "only exercised $checked consumers"
echo "PASS: $checked consumers each match a labeled row, stop on none, and stop on several"

echo
echo "=== doctor matrix consumer tests passed ==="
