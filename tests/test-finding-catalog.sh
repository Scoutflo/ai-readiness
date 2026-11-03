#!/bin/sh
# Current reports must cite checks that exist in their owning skill's catalog.
# Historical reports keep their original version and schema/scoring validation.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
CHECK="$ROOT/report-standard/check-findings.sh"
VERSION="$(jq -r .version "$ROOT/.claude-plugin/plugin.json")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
count=0
fail() { cat "$WORK/result" >&2; echo "FAIL: $1" >&2; exit 1; }

# One real failed check; scores and evidence are deliberately uncomplicated so
# catalog failures cannot be confused with unrelated arithmetic/schema failures.
baseline() {
  jq -n --arg version "$VERSION" '{
    schema:"scoutflo-findings/v2", toolkit_version:$version,
    skill:"audit-grafana", target:"fixture", run_date:"2026-11-03",
    generated_at:"2026-11-03T00:00:00Z",
    checks:[{id:"GRAF-001",category:"Signals",result:"fail"}],
    score:{overall:0,state:"assessed",gate:85,end_to_end:false,
      scoring_model:"assessed-only-v1",check_set:"pending",
      assessment:{applicable_checks:1,assessed_checks:1,scored_checks:1,
        blocked_checks:0,suppressed_checks:0,not_in_scope_checks:0,coverage_percent:100},
      categories:[{name:"Signals",weight:100,score:0,maturity:"reactive",
        checks_passed:0,checks_partial:0,checks_failed:1,checks_blocked:0,
        checks_suppressed:0,checks_not_in_scope:0,checks_total:1}],excluded:[]},
    severity_counts:{critical:0,high:1,medium:0,low:0,info:0},
    findings:[{id:"GRAF-001",title:"Fixture gap",severity:"high",area:"signals",
      status:"validated-live",lifecycle:"new",scoring_scope:"readiness",
      report_lanes:["general-audit"],points_recoverable:100,affected:["fixture"],
      evidence:[{check:"fixture",command:"local fixture",observed:"fixture gap"}],
      recommendation:"Resolve fixture gap",remediation:"setup-grafana#fixture"}]
  }'
}
fingerprint() {
  fp="$(jq -r '
    ([.checks[] | "chk\t"+.id+"\t"+.category]
      + [.score.categories[] | "cat\t"+.name+"\t"+(.weight|tostring)]
      + ["gate\t"+(.score.gate|tostring)]) | sort | .[]
    ' "$WORK/f.json" | LC_ALL=C cksum | awk '{print "cksum-v2:" $1 ":" $2}')"
  jq --arg fp "$fp" '.score.check_set=$fp' "$WORK/f.json" > "$WORK/tmp"
  mv "$WORK/tmp" "$WORK/f.json"
}
mutate() { baseline | jq "$1" > "$WORK/f.json"; fingerprint; }
expect_ok() {
  sh "$CHECK" "$WORK/f.json" > "$WORK/result" 2>&1 || fail "$1"
  grep -q '^FINDINGS-OK:' "$WORK/result" || fail "missing success diagnostic: $1"
  count=$((count + 1))
}
expect_fail() {
  if sh "$CHECK" "$WORK/f.json" > "$WORK/result" 2>&1; then fail "$1"; fi
  grep -q "$2" "$WORK/result" || fail "missing expected diagnostic '$2': $1"
  count=$((count + 1))
}

mutate '.'
expect_ok 'real current-version catalog ID rejected'
mutate '.schema="scoutflo-findings/v1"'
expect_ok 'current-version v1 catalog ID rejected'

for schema in v1 v2; do
  mutate ".schema=\"scoutflo-findings/$schema\" | .checks[0].id=\"GRAF-999\" | .findings[0].id=\"GRAF-999\""
  expect_fail "invented same-prefix ID accepted in $schema" 'IDs absent from audit-grafana catalog'
done
mutate '.findings[0].id="GRAF-999"'
expect_fail 'invented finding ID accepted' 'IDs absent from audit-grafana catalog'
# Passing checks have no finding, but still need a real catalog ID.
mutate '.checks[0]={id:"GRAF-999",category:"Signals",result:"pass"}
  | .findings=[] | .severity_counts.high=0 | .score.overall=100
  | .score.categories[0] |= (.score=100 | .checks_passed=1 | .checks_failed=0)'
expect_fail 'invented passing check accepted' 'IDs absent from audit-grafana catalog'
mutate '.skill="audit-prometheus"'
expect_fail 'another audit owner accepted Grafana IDs' 'IDs absent from audit-prometheus catalog'
mutate '.skill="../audit-grafana"'
expect_fail 'owner traversal accepted' 'no paths or traversal'
mutate '.skill="audit-nonexistent-fixture"'
expect_fail 'missing owner catalog accepted' 'no shipped catalog'
mutate '.skill="audit-all"'
expect_fail 'orchestrator certified as a check catalog' 'no explicit ID table catalog'

for version in null '238' '"v0.1.238"' '"0.1"' '"0.01.238"' '"0.1.238-custom"'; do
  mutate ".toolkit_version=$version"
  expect_fail 'invalid version accepted' 'toolkit_version must be a numeric'
done
mutate '.toolkit_version="99999.0.0"'
expect_fail 'future version accepted against an older catalog' 'newer than catalog'
for schema in v1 v2; do
  mutate ".schema=\"scoutflo-findings/$schema\" | .toolkit_version=\"0.1.0\"
    | .skill=\"audit-historical-fixture\" | .checks[0].id=\"FX-001\" | .findings[0].id=\"FX-001\""
  expect_ok "historical $schema artifact rejected"
  grep -q '^FINDINGS-CATALOG-SKIP: historical' "$WORK/result" || fail 'historical check silently skipped'
  jq '.severity_counts.high=0' "$WORK/f.json" > "$WORK/tmp"; mv "$WORK/tmp" "$WORK/f.json"
  expect_fail "historical $schema skipped schema validation" 'severity_counts'
done

topology='.findings += [(.findings[0] | .id="TOPO-123" | .area="topology-readiness"
  | .scoring_scope="non-scored" | .points_recoverable=0 | .severity="info")]
  | .severity_counts.info=1'
mutate "$topology"
expect_ok 'non-scored topology observation rejected'
mutate "$topology | .findings[1].area=\"signals\""
expect_fail 'TOPO prefix used outside topology section' 'IDs absent'
mutate "$topology | .findings[1].scoring_scope=\"readiness\""
expect_fail 'scored TOPO observation accepted' 'IDs absent'
mutate "$topology | .findings[1].points_recoverable=1"
expect_fail 'TOPO observation claiming recoverable points accepted' 'IDs absent'
mutate '.checks[0].id="TOPO-123" | .findings[0].id="TOPO-123"
  | .findings[0].area="topology-readiness" | .findings[0].scoring_scope="non-scored"
  | .findings[0].points_recoverable=0'
expect_fail 'TOPO ledger row bypassed exact catalog validation' 'IDs absent'

# Samples span all shipped scored audit owners and their differing table shapes.
# These are explicit known IDs, not IDs rediscovered by the parser being tested.
while read -r owner id; do
  mutate ".skill=\"$owner\" | .checks[0].id=\"$id\" | .findings[0].id=\"$id\""
  expect_ok "shipped catalog sample $owner/$id rejected"
done <<'CATALOGS'
audit-alertmanager ALR-001
audit-aws AWS-001
audit-azure AZR-001
audit-clickstack CS-007
audit-datadog DD-001
audit-digitalocean DO-001
audit-elk ELK-001
audit-gcp GCP-001
audit-grafana GRAF-001
audit-groundcover GC-001
audit-jsm JSM-001
audit-kubernetes K8S-001
audit-lgtm LGTM-080
audit-newrelic NR-001
audit-pagerduty PD-001
audit-prometheus PROM-001
audit-sentry SNTRY-001
audit-signoz SIG-001
audit-zenduty ZD-001
CATALOGS
for pair in 'aws AWS-001 AWSOPT-002' 'kubernetes K8S-001 K8SRT-001'; do
  set -- $pair
  mutate ".skill=\"audit-$1\" | .checks[0].id=\"$2\" | .findings[0].id=\"$2\"
    | .findings += [(.findings[0] | .id=\"$3\" | .scoring_scope=\"non-scored\"
      | .points_recoverable=0 | .severity=\"info\")] | .severity_counts.info=1"
  expect_ok "registered non-scored ID $3 rejected"
done

# An isolated plugin fixture proves prose, ranges, cross-reference tables and
# fenced examples do not manufacture catalog entries; no source files are edited.
mkdir -p "$WORK/plugin/report-standard" "$WORK/plugin/.claude-plugin" "$WORK/plugin/skills/audit-fixture/references"
cp "$ROOT/report-standard/check-findings.sh" "$WORK/plugin/report-standard/"
cp "$ROOT/.claude-plugin/plugin.json" "$WORK/plugin/.claude-plugin/"
CHECK="$WORK/plugin/report-standard/check-findings.sh"
cat > "$WORK/plugin/skills/audit-fixture/SKILL.md" <<'MARKDOWN'
# Fixture catalog
| ID | Check |
| --- | --- |
| FX-001 | Real check |
| FX-003–FX-005 | A range does not register individual IDs |

FX-002 is a prose mention.

| Check | Related |
| --- | --- |
| FX-006 | A cross-reference, not registration |

```markdown
| ID | Check |
| --- | --- |
| FX-007 | Example only |
```

~~~markdown
| ID | Check |
| --- | --- |
| FX-008 | Example only |
~~~
MARKDOWN
cat > "$WORK/plugin/skills/audit-fixture/references/checks.md" <<'MARKDOWN'
| **ID** | Signal |
| --- | --- |
| **`FX-009`** | A registered reference check |
MARKDOWN
for id in FX-001 FX-009; do
  mutate ".skill=\"audit-fixture\" | .checks[0].id=\"$id\" | .findings[0].id=\"$id\""
  expect_ok "explicit catalog entry $id rejected"
done
for id in FX-002 FX-003 FX-004 FX-005 FX-006 FX-007 FX-008; do
  mutate ".skill=\"audit-fixture\" | .checks[0].id=\"$id\" | .findings[0].id=\"$id\""
  expect_fail "non-catalog reference $id accepted" 'IDs absent from audit-fixture catalog'
done
ln -s "$ROOT/skills/audit-grafana" "$WORK/plugin/skills/audit-alias"
mutate '.skill="audit-alias"'
expect_fail 'symlink escaped the owning plugin catalog' 'no shipped catalog'

echo "FINDING-CATALOG-OK: $count assertions"
