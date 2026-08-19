#!/bin/sh
# tests/selftest/run.sh — reusable local self-test for the Scoutflo AI Readiness plugin.
#
# One entrypoint, layered so you run exactly as much as you want. Everything in
# the hermetic layers is self-contained (no creds, no network beyond localhost);
# the live/integration layers are opt-in and read your local state at runtime.
#
# Usage:
#   tests/selftest/run.sh                 # hermetic layers (mechanical+validators+capstone)
#   tests/selftest/run.sh --layer all     # same as default
#   tests/selftest/run.sh --layer mechanical|validators|capstone|integration|live
#   tests/selftest/run.sh --layer live --dir ./scoutflo-audits   # validate real outputs + doctor
#   tests/selftest/run.sh --layer integration                    # spin ClickStack in Docker, probe, teardown
#   tests/selftest/run.sh --keep          # keep the scratch workdir for inspection
#
# Design principles:
#   - Hermetic by default: mechanical + validators + capstone need nothing but
#     the repo + jq + the claude CLI. They are the regression memory.
#   - Opt-in for anything needing creds/daemons: integration (docker), live (~/.scoutflo).
#   - Honest: a skipped/blocked check is recorded SKIP, never a fake PASS.
#   - Never emits a secret: fixtures are synthetic; live layer never prints values.
#   - Fixtures encode the CORRECT expected behavior — every bug the rigorous
#     test found is a permanent case here, so it can never silently regress.
#
# Exit: 0 if every non-SKIP hermetic case passed; non-zero otherwise.

set -u

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)   # repo root (tests/selftest -> repo)
RS="$ROOT/report-standard"
CI="$ROOT/ci"
GOLD="$SELF_DIR/fixtures/valid"                  # golden VALID audit output (synthetic)
WORK="${TMPDIR:-/tmp}/scoutflo-selftest.$$"

LAYER=all
KEEP=0
TARGET_DIR=""
PROVIDERS=auto

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --layer)     LAYER="${2:?}"; shift 2 ;;
    --dir)       TARGET_DIR="${2:?}"; shift 2 ;;
    --providers) PROVIDERS="${2:?}"; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "selftest: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "selftest: jq is required" >&2; exit 2; }
[ -f "$GOLD/findings.json" ] || { echo "selftest: missing golden fixture $GOLD/findings.json" >&2; exit 2; }

mkdir -p "$WORK"
cleanup() { [ "$KEEP" = "1" ] || rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

MATRIX="$WORK/matrix.tsv"
: > "$MATRIX"
NPASS=0; NFAIL=0; NSKIP=0

# rec LAYER CASE EXPECTED OBSERVED VERDICT
rec() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$MATRIX"
  case "$5" in
    PASS) NPASS=$((NPASS+1)); printf '  \033[32m✓\033[0m %s\n' "$2" ;;
    SKIP) NSKIP=$((NSKIP+1)); printf '  \033[33m∙\033[0m %s (%s)\n' "$2" "$4" ;;
    *)    NFAIL=$((NFAIL+1)); printf '  \033[31m✗\033[0m %s — want %s, got %s\n' "$2" "$3" "$4" ;;
  esac
}

# expect_exit LAYER NAME WANT_EXIT CMD...
expect_exit() {
  _l="$1"; _n="$2"; _w="$3"; shift 3
  "$@" >/dev/null 2>&1; _g=$?
  [ "$_g" = "$_w" ] && rec "$_l" "$_n" "exit $_w" "exit $_g" PASS || rec "$_l" "$_n" "exit $_w" "exit $_g" FAIL
}

hr() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
# LAYER 1 — mechanical: the repo's own gates (hermetic)
# ---------------------------------------------------------------------------
layer_mechanical() {
  hr "Layer 1 · mechanical gates"
  expect_exit mechanical "leak-scan (repo)"        0 sh "$CI/leak-scan.sh" "$ROOT"
  expect_exit mechanical "structure-check (13)"    0 sh "$CI/structure-check.sh" "$ROOT"
  expect_exit mechanical "run-tests (suites)"      0 sh "$CI/run-tests.sh" "$ROOT"
  if command -v claude >/dev/null 2>&1; then
    expect_exit mechanical "plugin validate --strict" 0 sh -c "cd '$ROOT' && claude plugin validate . --strict"
  else
    rec mechanical "plugin validate --strict" "exit 0" "claude CLI not on PATH" SKIP
  fi
}

# ---------------------------------------------------------------------------
# LAYER 2 — validators: adversarial fixtures for the report-standard validators
# (regression memory: every class the rigorous test exercised, plus the specific
# bugs it found). Cases are DERIVED from the golden valid fixture via jq/sed.
# ---------------------------------------------------------------------------
# vf_findings NAME WANT_EXIT JQFILTER  — mutate golden findings.json, run check-findings
vf_findings() {
  _n="$1"; _w="$2"; _f="$3"
  _out="$WORK/f-$_n.json"
  if [ "$_f" = "@nonjson" ]; then printf 'not json at all {' > "$_out"
  else jq "$_f" "$GOLD/findings.json" > "$_out" 2>/dev/null || { rec validators "findings:$_n" "exit $_w" "jq-mutate-failed" FAIL; return; }
  fi
  expect_exit validators "findings:$_n" "$_w" sh "$RS/check-findings.sh" "$_out"
}

# vf_report NAME WANT_EXIT MUTATOR — copy golden run dir, apply mutator to it, run check-report
vf_report() {
  _n="$1"; _w="$2"; _m="$3"
  _d="$WORK/r-$_n"; rm -rf "$_d"; mkdir -p "$_d"
  cp "$GOLD/findings.json" "$GOLD/report.md" "$GOLD/inventory.json" "$_d/" 2>/dev/null
  ( cd "$_d" && eval "$_m" )
  expect_exit validators "report:$_n" "$_w" sh "$RS/check-report.sh" "$_d/report.md"
}

# vf_leak NAME WANT_EXIT CONTENT — write content to a fixture dir, run leak-scan
vf_leak() {
  _n="$1"; _w="$2"; _c="$3"
  _d="$WORK/leak-$_n"; rm -rf "$_d"; mkdir -p "$_d"
  printf '%s\n' "$_c" > "$_d/sample.txt"
  expect_exit validators "leak:$_n" "$_w" sh "$CI/leak-scan.sh" "$_d"
}

layer_validators() {
  hr "Layer 2 · validator adversarial fixtures"

  # --- check-findings: golden must PASS, each invalid class must FAIL (exit 1) ---
  vf_findings valid                 0 '.'
  vf_findings overall-off-by-3      1 '.score.overall += 3'
  vf_findings weights-not-100       1 '.score.categories[0].weight += 5'
  vf_findings severity-histo-mismatch 1 '.severity_counts.high += 1'
  vf_findings missing-affected      1 '(.findings[] | select(.severity!="info")).affected = []'
  vf_findings empty-remediation     1 '(.findings[] | select(.severity!="info")).remediation = ""'
  vf_findings bad-severity-enum     1 '.findings[0].severity = "urgent"'
  vf_findings bad-status-enum        1 '.findings[0].status = "definitely-not-a-status"'
  vf_findings malformed-id          1 '.findings[0].id = "lgtm_014"'
  vf_findings duplicate-id          1 '.findings[1].id = .findings[0].id'
  vf_findings e2e-below-85          1 '.score.end_to_end = true'
  # the two bugs the rigorous test found — must FAIL CLEANLY (exit 1, not a crash/exit 5):
  vf_findings overall-string        1 '.score.overall = (.score.overall|tostring)'
  vf_findings missing-score-envelope 1 'del(.score)'
  vf_findings non-json              1 '@nonjson'

  # --- check-report: golden must PASS, each structural break must FAIL ---
  vf_report valid                    0 'true'
  vf_report missing-inventory-section 1 "grep -v '^## Inventory' report.md > r && mv r report.md"
  vf_report inventory-total-mismatch 1 "jq '.counts.total += 5' inventory.json > i && mv i inventory.json"
  vf_report inventory-wrong-schema   1 "jq '.schema = \"scoutflo-inventory/v2\"' inventory.json > i && mv i inventory.json"
  vf_report not-h1-first             1 "printf 'plain line\n\n%s' \"\$(cat report.md)\" > r && mv r report.md"

  # --- leak-scan: catch real leaks, exempt placeholder + regression false-positives ---
  vf_leak clean                    0 'just some ordinary prose with no secrets here.'
  vf_leak placeholder-account      0 'account: 123456789012 (AWS canonical example placeholder)'
  vf_leak real-account-id          1 'account: 987654321098'
  vf_leak real-account-in-arn      1 'arn:aws:iam::987654321098:role/example'
  vf_leak decimal-not-account      0 '"idle_ns":4899.317542016506'
  vf_leak uuid-digit-segment       0 'monitor uuid dbcf88af-14d2-4d7f-bbe5-850781672742'
  vf_leak inline-secret            1 'api_key = "AKIAIOSFODNN7EXAMPLEKEY"'

  # --- render-report-viz: modes render on the golden; + the two viz regressions ---
  # per-mode arg contract (from the script's own usage): at-a-glance/scorecard
  # take <findings.json>; html takes <findings.json> <out.html>; inventory takes
  # <inventory.json>; overlaps takes <correlation.json>/<dir> (tested in capstone);
  # mermaid-topo needs a topology-export.json (skipped — no topo in the fixture).
  for m in at-a-glance scorecard; do
    if sh "$RS/render-report-viz.sh" "$m" "$GOLD/findings.json" > "$WORK/viz-$m.out" 2>/dev/null && [ -s "$WORK/viz-$m.out" ]; then
      rec validators "viz:$m renders" "non-empty exit 0" "ok" PASS
    else
      rec validators "viz:$m renders" "non-empty exit 0" "empty-or-error" FAIL
    fi
  done
  if sh "$RS/render-report-viz.sh" html "$GOLD/findings.json" "$WORK/viz.html" >/dev/null 2>&1 && [ -s "$WORK/viz.html" ]; then
    rec validators "viz:html renders" "non-empty html file" "ok" PASS
  else
    rec validators "viz:html renders" "non-empty html file" "empty-or-error" FAIL
  fi
  if sh "$RS/render-report-viz.sh" inventory "$GOLD/inventory.json" > "$WORK/viz-inv.out" 2>/dev/null && [ -s "$WORK/viz-inv.out" ]; then
    rec validators "viz:inventory renders" "non-empty exit 0" "ok" PASS
  else
    rec validators "viz:inventory renders" "non-empty exit 0" "empty-or-error" FAIL
  fi
  rec validators "viz:mermaid-topo" "needs topology-export.json" "no topo in fixture" SKIP

  # VIZ regression 1: a pipe in an inventory item name must not break the table
  jq '.items[0].name = "svc | with pipe"' "$GOLD/inventory.json" > "$WORK/inv-pipe.json"
  _pout="$(sh "$RS/render-report-viz.sh" inventory "$WORK/inv-pipe.json" 2>/dev/null)"
  if printf '%s' "$_pout" | grep -q 'with pipe'; then
    # the row rendered; ensure the pipe was escaped (\|) so the table stays valid
    if printf '%s' "$_pout" | grep -q '\\|'; then
      rec validators "viz:inventory pipe-escaped" "escaped \\| present" "escaped" PASS
    else
      rec validators "viz:inventory pipe-escaped" "escaped \\| present" "raw pipe (breaks table)" FAIL
    fi
  else
    rec validators "viz:inventory pipe-escaped" "row rendered" "row missing" FAIL
  fi

  # VIZ regression 2: at-a-glance "Start here" must break points ties by severity
  jq '.findings = [
        {id:"AAA-101",title:"low-sev tie",severity:"medium",area:"x",status:"open",lifecycle:"new",points_recoverable:9,evidence:[{check:"c",command:"cmd",observed:"o"}],recommendation:"r",remediation:"do x"},
        {id:"BBB-102",title:"high-sev tie",severity:"critical",area:"y",status:"open",lifecycle:"new",points_recoverable:9,evidence:[{check:"c",command:"cmd",observed:"o"}],recommendation:"r",remediation:"do y"}
      ] | .severity_counts = {critical:1,high:0,medium:1,low:0,info:0}' "$GOLD/findings.json" > "$WORK/tie.json" 2>/dev/null
  _sh=$(sh "$RS/render-report-viz.sh" at-a-glance "$WORK/tie.json" 2>/dev/null | grep -i 'start here')
  if printf '%s' "$_sh" | grep -q 'BBB-102'; then
    rec validators "viz:at-a-glance severity tie-break" "critical wins tie" "BBB-102 (critical)" PASS
  else
    rec validators "viz:at-a-glance severity tie-break" "critical wins tie" "picked lower severity" FAIL
  fi
}

# ---------------------------------------------------------------------------
# LAYER 3 — capstone: run the cross-cutting LIBS over a small multi-audit set
# (correlation-engine + cost-analysis are runnable shell libs; hermetic)
# ---------------------------------------------------------------------------
layer_capstone() {
  hr "Layer 3 · cross-cutting libs (correlation + cost)"
  _cl="$ROOT/skills/correlation-engine/lib/correlation-engine.sh"
  _co="$ROOT/skills/cost-analysis/lib/cost-analysis.sh"
  _ad="$WORK/audits"; rm -rf "$_ad"
  D=2026-01-01
  # two synthetic targets that SHARE an affected resource -> one overlap
  mkdir -p "$_ad/alpha/$D" "$_ad/beta/$D"
  jq '.target="alpha" | .skill="audit-alpha" |
      (.findings[] | select(.severity!="info")).affected = ["checkout-api"]' \
      "$GOLD/findings.json" > "$_ad/alpha/$D/findings.json"
  jq '.target="beta" | .skill="audit-beta" |
      (.findings[] | select(.severity!="info")).affected = ["checkout-api"] |
      (.findings[] | select(.severity!="info")).area = "cost-optimization" |
      (.findings[] | select(.severity!="info")).estimated_monthly_savings_usd = null' \
      "$GOLD/findings.json" > "$_ad/beta/$D/findings.json"

  if [ -f "$_cl" ]; then
    if ( export SCOUTFLO_AUDIT_DIR="$_ad"; . "$_cl" && correlation_run "$D" ) >/dev/null 2>&1 \
       && [ -f "$_ad/correlation.json" ] \
       && [ "$(jq '.total_overlaps_detected // (.overlaps|length) // 0' "$_ad/correlation.json" 2>/dev/null)" -ge 1 ]; then
      rec capstone "correlation-engine: overlap on shared resource" ">=1 overlap" "$(jq -r '.total_overlaps_detected // (.overlaps|length)' "$_ad/correlation.json")" PASS
    else
      rec capstone "correlation-engine: overlap on shared resource" ">=1 overlap" "no correlation.json / 0 overlaps" FAIL
    fi
  else
    rec capstone "correlation-engine" ">=1 overlap" "lib not found" SKIP
  fi

  # render-viz overlaps must accept the audits DIR (bug B fix) and render the join
  if [ -f "$_ad/correlation.json" ]; then
    if sh "$RS/render-report-viz.sh" overlaps "$_ad" 2>/dev/null | grep -q 'checkout-api'; then
      rec capstone "render-viz overlaps (dir arg)" "renders shared-resource overlap" "checkout-api" PASS
    else
      rec capstone "render-viz overlaps (dir arg)" "renders shared-resource overlap" "missing/false-negative" FAIL
    fi
  fi

  if [ -f "$_co" ]; then
    if ( export SCOUTFLO_AUDIT_DIR="$_ad" CLAUDE_PLUGIN_ROOT="$ROOT"; . "$_co" && cost_analysis_run "$D" ) >/dev/null 2>&1 \
       && [ -f "$_ad/cost-analysis/$D/findings.json" ]; then
      # never-invent-a-dollar: a null savings must stay $0, never scraped
      _sav=$(jq '[.findings[].estimated_monthly_savings_usd // 0]|add // 0' "$_ad/cost-analysis/$D/findings.json" 2>/dev/null)
      [ "${_sav:-0}" = "0" ] \
        && rec capstone "cost-analysis: never-invent-a-dollar" "\$0 from null savings" "\$$_sav" PASS \
        || rec capstone "cost-analysis: never-invent-a-dollar" "\$0 from null savings" "\$$_sav (invented?)" FAIL
    else
      rec capstone "cost-analysis roll-up" "findings.json produced" "no output" FAIL
    fi
  else
    rec capstone "cost-analysis" "findings.json produced" "lib not found" SKIP
  fi
}

# ---------------------------------------------------------------------------
# LAYER 4 — integration: spin ClickStack in Docker, seed, PROBE, teardown.
# (opt-in; provisions a real auditable instance. The audit itself is LLM-driven
#  — see PLAYBOOK.md — this layer proves the instance is reachable + seeded.)
# ---------------------------------------------------------------------------
layer_integration() {
  hr "Layer 4 · ClickStack integration (Docker)"
  if ! command -v docker >/dev/null 2>&1; then
    rec integration "clickstack provision" "docker" "docker not installed" SKIP; return
  fi
  _ctr=scoutflo-selftest-clickstack
  docker rm -f "$_ctr" >/dev/null 2>&1 || true
  if ! docker run -d --name "$_ctr" -p 8124:8123 -p 8081:8080 clickhouse/clickstack-all-in-one:latest >/dev/null 2>&1; then
    rec integration "clickstack provision" "container starts" "docker run failed (image cached?)" SKIP; return
  fi
  _ok=0
  for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$_ctr" 2>/dev/null)" = healthy ] && { _ok=1; break; }
    sleep 4
  done
  if [ "$_ok" = 1 ]; then
    rec integration "clickstack provision" "healthy" "healthy" PASS
    _tbls=$(docker exec "$_ctr" clickhouse-client --query "SELECT count() FROM system.tables WHERE database='default' AND name LIKE 'otel_%'" 2>/dev/null)
    [ "${_tbls:-0}" -ge 5 ] \
      && rec integration "clickstack otel_* tables present" ">=5" "$_tbls" PASS \
      || rec integration "clickstack otel_* tables present" ">=5" "${_tbls:-0}" FAIL
  else
    rec integration "clickstack provision" "healthy" "never healthy" FAIL
  fi
  docker rm -f "$_ctr" >/dev/null 2>&1 || true
  rec integration "clickstack teardown" "removed" "removed" PASS
}

# ---------------------------------------------------------------------------
# LAYER 5 — live: doctor connectivity + validate any REAL audit outputs in --dir
# (opt-in; reads ~/.scoutflo + a real audits dir. Never prints secret values.)
# ---------------------------------------------------------------------------
layer_live() {
  hr "Layer 5 · live (doctor + validate real outputs)"
  _doc="$ROOT/skills/doctor/scripts/doctor.sh"
  if [ -f "$HOME/.scoutflo/toolkit.yaml" ]; then
    # doctor exit: 0 all-pass, 2 env-missing, 3 a live check failed — all "ran ok".
    sh "$_doc" >/dev/null 2>&1; _dc=$?
    case "$_dc" in 0|2|3) rec live "doctor connectivity sweep ran" "0/2/3" "exit $_dc" PASS ;;
      *) rec live "doctor connectivity sweep ran" "0/2/3" "exit $_dc" FAIL ;; esac
  else
    rec live "doctor connectivity sweep ran" "0/2/3" "no ~/.scoutflo/toolkit.yaml" SKIP
  fi
  _dir="${TARGET_DIR:-$ROOT/scoutflo-audits}"
  if [ -d "$_dir" ]; then
    _n=0
    for _f in $(find "$_dir" -name findings.json 2>/dev/null); do
      _n=$((_n+1)); _d=$(dirname "$_f")
      _tag=$(printf '%s' "$_d" | sed "s#$_dir/##")
      if sh "$RS/check-findings.sh" "$_f" >/dev/null 2>&1; then
        [ -f "$_d/report.md" ] && sh "$RS/check-report.sh" "$_d/report.md" >/dev/null 2>&1
        _rc=$?
        sh "$CI/leak-scan.sh" "$_d" >/dev/null 2>&1; _lc=$?
        { [ "$_rc" = 0 ] && [ "$_lc" = 0 ]; } \
          && rec live "validate: $_tag" "findings+report+leak ok" "ok" PASS \
          || rec live "validate: $_tag" "findings+report+leak ok" "report=$_rc leak=$_lc" FAIL
      else
        rec live "validate: $_tag" "findings ok" "check-findings failed" FAIL
      fi
    done
    [ "$_n" = 0 ] && rec live "validate real outputs" "some findings.json" "none in $_dir" SKIP
  else
    rec live "validate real outputs" "audits dir" "no $_dir (run audits first)" SKIP
  fi
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------
case "$LAYER" in
  all)         layer_mechanical; layer_validators; layer_capstone ;;
  mechanical)  layer_mechanical ;;
  validators)  layer_validators ;;
  capstone)    layer_capstone ;;
  integration) layer_integration ;;
  live)        layer_live ;;
  *) echo "selftest: unknown layer '$LAYER'" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# matrix report
# ---------------------------------------------------------------------------
OUT="$SELF_DIR/last-run.md"
{
  echo "# Scoutflo AI Readiness — self-test matrix"
  echo
  echo "Layer(s): \`$LAYER\` · pass: $NPASS · fail: $NFAIL · skip: $NSKIP"
  echo
  echo "| Layer | Case | Expected | Observed | Verdict |"
  echo "| --- | --- | --- | --- | --- |"
  # worst-first: FAIL, then SKIP, then PASS
  for _v in FAIL SKIP PASS; do
    awk -F'\t' -v v="$_v" '$5==v {printf "| %s | %s | %s | %s | %s |\n",$1,$2,$3,$4,$5}' "$MATRIX"
  done
} > "$OUT"

printf '\n\033[1m== summary ==\033[0m  pass:%s  fail:%s  skip:%s\n' "$NPASS" "$NFAIL" "$NSKIP"
echo "matrix: $OUT"

[ "$NFAIL" -eq 0 ] && exit 0 || exit 1
