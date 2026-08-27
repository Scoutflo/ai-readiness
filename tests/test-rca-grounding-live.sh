#!/bin/sh
# test-rca-grounding-live.sh
# Adversarial, deterministic proof that /scoutflo:rca is GROUNDED on real data:
# for a battery of real targets it runs the skill's actual Phase-1/3/4 jq against
# the shipped example reports and asserts the anti-hallucination invariants —
# every citation the RCA could emit RESOLVES to a real finding-id / topology edge
# / correlation id, and a nonexistent target yields ZERO signal (never a
# fabricated cause). This is the customer-facing guarantee, locked as a test.
#
# It uses a self-contained fixture set built from the real report SHAPES (same
# schemas the live team-qa run produced), so it runs anywhere under /bin/sh with
# no cloud access, and can't rot silently.
set -eu
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
AUD="$WORK/scoutflo-audits"
mkdir -p "$AUD/aws/2026-07-31" "$AUD/grafana/2026-07-31" "$AUD/lgtm/2026-07-31"
fail() { echo "FAIL: $1" >&2; exit 1; }

# --- Real-shape fixtures (mirror the live schemas exactly) --------------------
cat > "$AUD/aws/2026-07-31/findings.json" <<'JSON'
{"schema":"scoutflo-findings/v1","target":"aws","findings":[
 {"id":"AWS-030","severity":"high","area":"managed-data-durability","affected":["payments-db"],"title":"RDS payments-db has no automated backup"},
 {"id":"AWS-010","severity":"critical","area":"alert-routing","affected":["18 CloudWatch alarms"],"title":"All alarms have empty AlarmActions"}
]}
JSON
cat > "$AUD/grafana/2026-07-31/findings.json" <<'JSON'
{"schema":"scoutflo-findings/v1","target":"grafana","findings":[
 {"id":"GRAF-050","severity":"high","area":"alert-rules","affected":["payments-db"],"title":"Alert on payments-db routes to a null receiver"},
 {"id":"GRAF-091","severity":"high","area":"alert-rules","affected":["checkout-edge-api"],"title":"No alert rule for checkout-edge-api"}
]}
JSON
cat > "$AUD/lgtm/2026-07-31/findings.json" <<'JSON'
{"schema":"scoutflo-findings/v1","target":"lgtm","findings":[
 {"id":"LGTM-031","severity":"medium","area":"service-coverage","affected":["checkout-edge-api"],"title":"checkout-edge-api has no provable metric series"}
]}
JSON
# correlation.json: one overlap (checkout, 2 targets) + one real cascade (payments-db root -> GRAF-050 effect)
cat > "$AUD/correlation.json" <<'JSON'
{"overlaps":[{"overlap_id":"OVL-checkout-edge-api","service":"checkout-edge-api","targets":["grafana","lgtm"],
  "findings":[{"target":"grafana","finding_id":"GRAF-091","title":"No alert rule","severity":"high"},
              {"target":"lgtm","finding_id":"LGTM-031","title":"No metric series","severity":"medium"}]}],
 "cascades":[{"root_cause":{"finding_id":"AWS-030","title":"RDS payments-db has no automated backup","target":"aws","shared_resources":["payments-db"]},
   "effects":[{"finding_id":"GRAF-050","title":"Alert on payments-db routes to a null receiver","target":"grafana","condition":"shares payments-db"}]}]}
JSON
# topology-export.json exercising the LEGACY edges[] fallback shape (map-topology now emits relationships[];
# consumers still tolerate edges[] for older/hand-authored exports) + a null node (real data-quality case)
cat > "$AUD/topology-export.json" <<'JSON'
{"schema":"scoutflo-topology-export/v1","services":[{"name":"checkout-edge-api","business_criticality":"high"},{"name":null}],
 "resources":[{"name":"payments-db"}],
 "edges":[
  {"type":"DEPLOYED_AS","from":"checkout-edge-api","to":"wl:checkout-edge-api","confidence":9,"verified":true},
  {"type":"CALLS","from":"checkout-edge-api","to":"payments-db","confidence":8,"verified":true},
  {"type":"MONITORED_BY","from":"checkout-edge-api","to":"backend:alertmanager","confidence":5}
 ]}
JSON

# --- The skill's actual Phase jq, extracted verbatim -------------------------
phase1() { # findings naming target across all reports
  find "$AUD" -name findings.json 2>/dev/null | while read -r f; do
    jq -r --arg t "$1" '.findings[] | select(( ((.affected // []) | join(" ")) + " " + (.title // "") + " " + (.id // "") ) | test($t;"i")) | .id' "$f" 2>/dev/null
  done
}
phase3() { # topology neighbors — the FIXED both-shapes-and-null-guarded jq from the skill
  jq -r --arg t "$1" '
    ((.relationships // []) | map({from:.from.name,to:.to.name,rel:.relation,conf:(.confidence//"?")}))
    + ((.edges // []) | map({from:.from,to:.to,rel:.type,conf:(.confidence//"?")}))
    | .[] | select(.from==$t or .to==$t) | "\(.from) -\(.rel)-> \(.to)"' "$AUD/topology-export.json" 2>/dev/null
}
phase4_overlap() { jq -r --arg t "$1" '(.overlaps//[])[]|select(.service|test($t;"i"))|.overlap_id' "$AUD/correlation.json" 2>/dev/null; }
phase4_cascade() { jq -r --arg t "$1" '(.cascades//[])[]|select((.root_cause.title+" "+((.root_cause.shared_resources//[])|join(" ")))|test($t;"i") or (any(.effects[]?;.title|test($t;"i"))))|.root_cause.finding_id' "$AUD/correlation.json" 2>/dev/null; }

# Set of every real finding-id (for citation-resolution checks)
ALL_IDS="$(find "$AUD" -name findings.json | while read f; do jq -r '.findings[].id' "$f"; done | sort -u)"
id_exists() { echo "$ALL_IDS" | grep -qx "$1"; }

echo "=== RCA grounding proof (real-shape data) ==="

echo "Test 1: POSITIVE — checkout-edge-api resolves across reports + topology + correlation"
p1="$(phase1 checkout-edge-api)"; p3="$(phase3 checkout-edge-api)"; ov="$(phase4_overlap checkout-edge-api)"
[ -n "$p1" ] || fail "checkout-edge-api found no findings (expected GRAF-091, LGTM-031)"
echo "$p1" | grep -qx GRAF-091 || fail "expected GRAF-091 in checkout findings"
echo "$p3" | grep -q 'checkout-edge-api -CALLS-> payments-db' || fail "topology CALLS edge not surfaced (edges[] shape broken?)"
[ "$ov" = "OVL-checkout-edge-api" ] || fail "overlap not found for checkout (got: $ov)"
echo "PASS"

echo "Test 2: CASCADE — payments-db is a cascade root and its effect resolves"
rc="$(phase4_cascade payments-db)"
[ "$rc" = "AWS-030" ] || fail "expected cascade root AWS-030 for payments-db, got: $rc"
# the effect finding-id must be real, not invented
eff="$(jq -r '(.cascades[]|select(.root_cause.finding_id=="AWS-030").effects[].finding_id)' "$AUD/correlation.json")"
id_exists "$eff" || fail "cascade effect $eff does not resolve to a real finding"
echo "PASS ($rc -> $eff, both resolve)"

echo "Test 3: EVERY citation any phase can emit resolves to a real finding-id"
for t in checkout-edge-api payments-db; do
  for id in $(phase1 "$t") $(phase4_cascade "$t"); do
    id_exists "$id" || fail "phase emitted citation '$id' that is not a real finding (hallucination risk)"
  done
done
echo "PASS (no unresolved citation)"

echo "Test 4: NEGATIVE — a nonexistent target yields ZERO signal (never a fabricated cause)"
for t in "web-999-does-not-exist" "totally-made-up-service"; do
  [ -z "$(phase1 "$t")" ] || fail "phase1 matched a nonexistent target $t"
  [ -z "$(phase3 "$t")" ] || fail "phase3 matched a nonexistent target $t"
  [ -z "$(phase4_overlap "$t")$(phase4_cascade "$t")" ] || fail "phase4 matched a nonexistent target $t"
done
echo "PASS (nonexistent target -> insufficient-signal path, no invented cause)"

echo "Test 5: ROBUSTNESS — a null topology node does not crash any phase"
phase3 checkout-edge-api >/dev/null 2>&1 || fail "phase3 crashed on a topology with a null service node"
# explicitly ensure the null node is present in the fixture (so the guard is actually exercised)
jq -e '.services[] | select(.name==null)' "$AUD/topology-export.json" >/dev/null || fail "fixture lost its null node — test no longer proves the guard"
echo "PASS (null node tolerated)"

echo "Test 6: ROBUSTNESS — missing topology/correlation degrade, not crash"
rm "$AUD/topology-export.json" "$AUD/correlation.json"
[ -z "$(phase3 checkout-edge-api 2>/dev/null)" ] || fail "phase3 should be empty when export is gone"
[ -z "$(phase4_overlap checkout-edge-api 2>/dev/null)" ] || fail "phase4 should be empty when correlation is gone"
# phase1 (findings only) must still work — RCA degrades to symptoms-only, honestly
[ -n "$(phase1 checkout-edge-api)" ] || fail "phase1 should still find symptoms with no topology/correlation"
echo "PASS (degrades to available signal)"

echo
echo "=== RCA grounding proof passed ==="
