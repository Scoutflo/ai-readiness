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
  /awk -F.\\t. -v b=/ { if (prev ~ /^[A-Z_]+_MATRIX_LABEL=/) print prev; inp=1 }
  inp { print }
  inp && /"\$MATRIX"/ { print "###END###"; inp=0 }
  { prev=$0 }
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
# audit-azure now probes real Cost/Advisor/Resource Graph access independently;
# its former ninth matrix consumer depended on a row Doctor never emitted.
# Count every remaining source program, not a stale historical total, and assert
# that extraction/execution covers all of them (including future additions).
EXPECTED="$(while IFS= read -r consumer; do
  grep -c 'awk -F.\\t. -v b=' "$consumer"
done < "$CONSUMERS" | awk '{n += $1} END {print n}')"
[ "$EXPECTED" -ge 8 ] || fail "expected at least 8 current source consumers, found $EXPECTED"
[ "$COUNT" -eq "$EXPECTED" ] || fail "found $EXPECTED source consumers but extracted $COUNT"
echo "extracted $COUNT consumer program(s)"

hdr() { printf 'block\tcheck\tconfigured\tenv\tresult\tcode\thint\n'; }

checked=0
for prog in "$WORK"/progs/p*.sh; do
  # The block and check this consumer selects on.
  b="$(sed -n 's/.*-v b="\([^"]*\)".*/\1/p' "$prog" | head -1)"
  c="$(sed -n 's/.*-v c="\([^"]*\)".*/\1/p' "$prog" | head -1)"
  [ -n "$b" ] && [ -n "$c" ] || fail "could not read b/c out of $prog"

  # Some consumers resolve a selected label before their exact-match awk. Execute
  # that real assignment with fixture KIND/LABEL inputs, never treat "$VAR" as a
  # literal block name and never eval an extracted variable name.
  bound=0
  case "$b" in
    '$AWS_MATRIX_LABEL') b=aws; bound=1 ;;
    '$AZ_MATRIX_LABEL') b=azure; bound=1 ;;
    *'$'*) fail "unknown dynamic matrix label in $prog: $b" ;;
  esac
  matrix_kind=seq; matrix_n=2
  consume() {
    MATRIX="$M" AWS_KIND="$matrix_kind" AWS_N="$matrix_n" AWS_LABEL=prod AZ_KIND="$matrix_kind" AZ_N="$matrix_n" AZ_LABEL=prod \
      sh "$prog"
  }

  # 1. A LABELED row must be matched. This is the regression.
  M="$WORK/m.tsv"; hdr > "$M"
  printf '%s (prod)\t%s\tyes\t-\tpass\t200\t-\n' "$b" "$c" >> "$M"
  out="$(consume 2>"$WORK/err")" \
    || fail "$b/$c: a single LABELED target was not matched (exit non-zero): $(cat "$WORK/err")"
  printf '%s' "$out" | grep -q "$b" \
    || fail "$b/$c: a single LABELED target produced no row (this is the zero-match bug)"

  # The bare form must keep working — single-target configs are the common case.
  hdr > "$M"; printf '%s\t%s\tyes\t-\tpass\t200\t-\n' "$b" "$c" >> "$M"
  matrix_kind=map; matrix_n=1
  consume >/dev/null 2>&1 \
    || fail "$b/$c: the BARE (single-target) form stopped being matched"

  # doctor tint() also emits a bare row for a list containing exactly one target.
  if [ "$bound" -eq 1 ]; then
    matrix_kind=seq; matrix_n=1
    consume >/dev/null 2>&1 || fail "$b/$c: one-element list did not match doctor bare row"
  fi

  # 2. No row at all must STOP, not print nothing.
  hdr > "$M"
  if consume >/dev/null 2>&1; then
    fail "$b/$c: a matrix with NO matching row exited 0 — a missing gate row must stop the phase, never read as a pass"
  fi

  # 3. Bound consumers select exactly prod; broad consumers must stop on ambiguity.
  matrix_kind=seq; matrix_n=2
  hdr > "$M"
  printf '%s (prod)\t%s\tyes\t-\tpass\t200\t-\n' "$b" "$c" >> "$M"
  printf '%s (dr)\t%s\tyes\t-\tskipped\t-\tno access\n' "$b" "$c" >> "$M"
  if [ "$bound" -eq 1 ]; then
    out=$(consume) || fail "$b/$c: selected prod was rejected because another target exists"
    printf '%s' "$out" | grep -qF "$b (prod)" || fail "$b/$c: selected target missing"
    printf '%s' "$out" | grep -qF "$b (dr)" && fail "$b/$c: unselected target leaked into result"
    # A real row for only another target is not a match, even when its permission passes.
    hdr > "$M"; printf '%s (dr)\t%s\tyes\t-\tpass\t200\t-\n' "$b" "$c" >> "$M"
    if consume >/dev/null 2>&1; then fail "$b/$c: wrong-label row passed selected-target gate"; fi
  else
    if consume >/dev/null 2>&1; then fail "$b/$c: ambiguous targets exited 0"; fi
  fi
  # Duplicate rows for the SAME selected target must always stop.
  hdr > "$M"
  printf '%s (prod)\t%s\tyes\t-\tpass\t200\t-\n' "$b" "$c" >> "$M"
  printf '%s (prod)\t%s\tyes\t-\tskipped\t-\tconflicting duplicate\n' "$b" "$c" >> "$M"
  if consume >/dev/null 2>&1; then fail "$b/$c: duplicate matching rows exited 0"; fi

  checked=$((checked + 1))
done

[ "$checked" -eq "$EXPECTED" ] || fail "only exercised $checked of $EXPECTED source consumers"
echo "PASS: $checked consumers each match a labeled row, stop on none/duplicates, and reject ambiguous or wrong-target rows"

echo
echo "=== doctor matrix consumer tests passed ==="
