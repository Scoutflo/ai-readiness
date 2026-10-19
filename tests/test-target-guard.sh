#!/bin/sh
# test-target-guard.sh: every SCOUTFLO_TARGET label loop in every skill is followed by a stop
# (CONTRACTS C3). On a labeled list, a SCOUTFLO_TARGET that matches no label must never fall back
# to the first target: before this guard a typo silently audited the first target instead of the
# one named. A single block ignores SCOUTFLO_TARGET, which keeps audit-all's per-label runs safe.
#
# Test 1 checks every loop statically; Test 2 runs every distinct published audit guard against a
# two-target and a single-block fixture; Tests 3 and 4 run audit-lgtm's and rca's own forms.
# Read-only; POSIX sh + awk.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TT="$ROOT/report-standard/toolkit-targets.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/target-guard.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

echo "=== target guard ==="

echo "Test 1: every SCOUTFLO_TARGET label loop is followed by a stop for its own integration"
find "$ROOT/skills" -name '*.md' | sort > "$WORK/files"
: > "$WORK/unguarded"; LOOPS=0
while IFS= read -r f; do
  out="$(awk -v fname="${f#"$ROOT"/}" '
    { line[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (line[i] !~ /while \[ "\$_i" -lt/ || line[i] !~ /SCOUTFLO_TARGET/) continue
        n++; var = ""; integ = ""
        if (match(line[i], /&& \{ [A-Z_][A-Z0-9_]*=/)) var = substr(line[i], RSTART + 5, RLENGTH - 6)
        if (match(line[i], /" [a-z0-9_-]+ label "\$_i"/)) integ = substr(line[i], RSTART + 2, RLENGTH - 14)
        ok = 0
        for (j = i + 1; j <= i + 4 && j <= NR; j++) {
          l = line[j]
          names_var = (var != "" && index(l, "\"$" var "\""))
          names_integ = (integ != "" && index(l, " " integ " "))
          if ((names_var || l ~ /SCOUTFLO_TARGET/) && (l ~ /exit 1/ || l ~ /report-only/) && (names_var || names_integ)) ok = 1
        }
        if (!ok) print "U " fname ":" i
      }
      print "N " n + 0
    }' "$f")"
  printf '%s\n' "$out" | sed -n 's/^U //p' >> "$WORK/unguarded"
  LOOPS=$((LOOPS + $(printf '%s\n' "$out" | sed -n 's/^N //p')))
done < "$WORK/files"
[ "$LOOPS" -gt 100 ] || fail "found only ${LOOPS} label loops; the scan is not matching the published loop shape"
if [ -s "$WORK/unguarded" ]; then
  sed 's/^/  falls back to the first target: /' "$WORK/unguarded" >&2
  fail "$(wc -l < "$WORK/unguarded" | tr -d ' ') of ${LOOPS} label loops have no stop for a SCOUTFLO_TARGET that matches no label"
fi
echo "PASS (${LOOPS} label loops)"

echo "Test 2: every distinct published audit guard stops on an unknown label, and only then"
# Each audit guard line follows its loop line. Collect the distinct (loop, guard) pairs.
: > "$WORK/pairs"
while IFS= read -r f; do
  awk '{ sub(/^[ \t]+/, "") } prev != "" && /^\[ "\$\(sh "\$[A-Z_]+" "\$[A-Z_]+" [a-z0-9_-]+ kind\)" != seq \]/ { print prev "\t" $0 } { prev = $0 }' "$f" >> "$WORK/pairs"
done < "$WORK/files"
sort -u "$WORK/pairs" > "$WORK/pairs.u"
VARIANTS="$(wc -l < "$WORK/pairs.u" | tr -d ' ')"
[ "$VARIANTS" -gt 10 ] || fail "found only ${VARIANTS} distinct audit guards"
k=0
while IFS="$(printf '\t')" read -r loop guard; do
  k=$((k + 1))
  integ="$(printf '%s\n' "$guard" | sed -E 's/^\[ "\$\(sh "\$[A-Z_]+" "\$[A-Z_]+" ([a-z0-9_-]+) kind.*/\1/')"
  ttv="$(printf '%s\n' "$guard" | sed -E 's/^\[ "\$\(sh "\$([A-Z_]+)".*/\1/')"
  cfgv="$(printf '%s\n' "$guard" | sed -E 's/^\[ "\$\(sh "\$[A-Z_]+" "\$([A-Z_]+)".*/\1/')"
  pfx="$(printf '%s\n' "$loop" | sed -E 's/^([A-Z][A-Z0-9_]*)_IDX=0;.*/\1/')"
  case "$pfx" in *" "*|"") fail "variant ${k}: the line before the ${integ} guard is not its label loop: $loop" ;; esac
  printf '%s:\n  - label: alpha\n    note: one\n  - label: beta\n    note: two\n' "$integ" > "$WORK/list.yaml"
  printf '%s:\n  note: one\n' "$integ" > "$WORK/single.yaml"
  { echo 'set -eu'
    echo "${ttv}=\"\$GT_TT\"; ${cfgv}=\"\$GT_CFG\""
    echo "${pfx}_N=\$(sh \"\$${ttv}\" \"\$${cfgv}\" ${integ} count)"
    printf '%s\n%s\n' "$loop" "$guard"
    echo "echo \"resolved: \$(sh \"\$${ttv}\" \"\$${cfgv}\" ${integ} label \"\$${pfx}_IDX\")\""
  } > "$WORK/v.sh"
  run() { ( cd "$WORK" && GT_TT="$TT" GT_CFG="$WORK/$1" SCOUTFLO_TARGET="$2" sh "$WORK/v.sh" ) < /dev/null 2>&1; }
  out="$(run list.yaml beta)" || fail "${integ} guard refused a label that exists: $out"
  [ "$out" = "resolved: beta" ] || fail "${integ} guard: label beta resolved to: $out"
  if out="$(run list.yaml betta)"; then fail "${integ} guard did not stop on a mistyped label (output: $out)"; fi
  printf '%s\n' "$out" | grep -q "SCOUTFLO_TARGET=betta matches no ${integ} target in .*labels: alpha beta" \
    || fail "${integ} guard's stop does not name the target and list the labels: $out"
  out="$(run list.yaml '')" || fail "${integ} guard refused an unset SCOUTFLO_TARGET: $out"
  [ "$out" = "resolved: alpha" ] || fail "${integ} guard: an unset target resolved to: $out"
  out="$(run single.yaml some-other-label)" || fail "${integ} guard stopped a single block for an unrelated SCOUTFLO_TARGET: $out"
  [ "$out" = "resolved: ${integ}" ] || fail "${integ} guard: a single block resolved to: $out"
done < "$WORK/pairs.u"
echo "PASS (${VARIANTS} distinct guards, each run four ways)"

echo "Test 3: audit-lgtm stops on a stack label that matches nothing"
awk '/^LG_KIND="\$\(sh "\$TT" "\$CFG" lgtm kind/ { p = 1 } p { print } p && /matches no lgtm target/ { s = 1 } s && /^fi$/ { exit }' \
  "$ROOT/skills/audit-lgtm/SKILL.md" > "$WORK/lgtm-body.sh"
grep -q 'matches no lgtm target' "$WORK/lgtm-body.sh" || fail "could not extract audit-lgtm's target resolution"
{ echo 'set -eu'; cat "$WORK/lgtm-body.sh"; echo 'echo "resolved: $LG_LABEL"'; } > "$WORK/lgtm.sh"
printf 'lgtm:\n  - label: prod\n    runtime_mode: http\n  - label: preprod\n    runtime_mode: http\n' > "$WORK/lgtm.yaml"
lg() { ( cd "$WORK" && TT="$TT" CFG="$WORK/lgtm.yaml" SCOUTFLO_TARGET="$1" sh "$WORK/lgtm.sh" ) < /dev/null 2>&1; }
out="$(lg preprod)" || fail "audit-lgtm refused a stack that exists: $out"
[ "$out" = "resolved: preprod" ] || fail "audit-lgtm: stack preprod resolved to: $out"
if out="$(lg prdo)"; then fail "audit-lgtm audited a stack although the label matches none (output: $out)"; fi
printf '%s\n' "$out" | grep -q 'SCOUTFLO_TARGET=prdo matches no lgtm target in .*labels: prod preprod' \
  || fail "audit-lgtm's stop does not name the target and list the labels: $out"
echo "PASS"

echo "Test 4: rca leaves the live probe off for a cluster label that matches nothing"
awk '/^KUBE_CONTEXT=""$/ { p = 1 } p { print } p && /^fi$/ { exit }' "$ROOT/skills/rca/SKILL.md" > "$WORK/rca-body.sh"
grep -q 'report-only proceeds' "$WORK/rca-body.sh" || fail "could not extract rca's cluster resolution"
{ echo 'set -eu'; cat "$WORK/rca-body.sh"; echo 'echo "context: ${KUBE_CONTEXT:-none}"'; } > "$WORK/rca.sh"
printf 'kubernetes:\n  - label: eks-prod\n    context: prod-ctx\n  - label: eks-staging\n    context: staging-ctx\n' > "$WORK/k8s.yaml"
rc() { ( cd "$WORK" && TT="$TT" CFG="$WORK/k8s.yaml" SCOUTFLO_TARGET="$1" sh "$WORK/rca.sh" ) < /dev/null 2>&1; }
out="$(rc eks-staging)" || fail "rca stopped on a cluster label that exists: $out"
[ "$out" = "context: staging-ctx" ] || fail "rca: eks-staging resolved to: $out"
out="$(rc eks-prdo)" || fail "rca stopped instead of degrading to report-only: $out"
printf '%s\n' "$out" | grep -q 'SCOUTFLO_TARGET=eks-prdo matches no kubernetes target' || fail "rca does not name the unknown label: $out"
printf '%s\n' "$out" | tail -1 | grep -qx 'context: none' || fail "rca probed a cluster for a label that matches none: $out"
echo "PASS"

echo "TARGET-GUARD-OK"
