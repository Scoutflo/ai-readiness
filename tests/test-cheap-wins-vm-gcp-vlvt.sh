#!/bin/sh
# Regression locks for the v0.1.208 cheap-wins batch:
#   IMP-004 doctor VictoriaMetrics cluster-mode probe (root /health, else the vmselect
#           tenant-0 query path, JSON-asserted) — a healthy cluster store must not false-fail.
#   IMP-005 doctor GCP Recommender hint prints the exact copy-paste unlock (enable + grant).
#   IMP-006 VictoriaLogs / VictoriaTraces are DISCOVERABLE — named in connect, providers.md,
#           the config template, and the start catalog (audited via the loki/tempo blocks).
# Structural locks (behavior for IMP-004 is proven live in the ship smoke against a mock).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCTOR="$ROOT/skills/doctor/scripts/doctor.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }
ok() { echo "ok: $1"; }
has() { grep -qF "$2" "$1" || fail "$3"; }

[ -f "$DOCTOR" ] || fail "doctor.sh missing"

# --- IMP-004: VM cluster-mode probe -----------------------------------------------------
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# Extract just the victoriametrics block so the assertions can't match a coincidental
# mention elsewhere in the script.
awk '/--- victoriametrics and vmalert/,/--- signoz/' "$DOCTOR" > "$WORK/vm.sh"
[ -s "$WORK/vm.sh" ] || fail "could not extract the victoriametrics block from doctor.sh"
grep -qF '/health' "$WORK/vm.sh" || fail "VM block no longer probes the root /health"
grep -qF '/select/0/prometheus/api/v1/query?query=1' "$WORK/vm.sh" \
  || fail "VM block lost the cluster-mode (vmselect tenant-0) retry path"
grep -qF '.status=="success"' "$WORK/vm.sh" \
  || fail "VM cluster retry no longer asserts a {\"status\":\"success\"} JSON body"
# The retry must be conditional on a non-200 (single-node still passes on /health 200).
grep -qE 'HTTP_CODE.*=.*"200".*\]; then|"200" \]; then' "$WORK/vm.sh" \
  || fail "VM block no longer has the /health 200 fast-path (single-node would regress)"
ok "IMP-004: VM probe = root /health, else vmselect tenant-0 query (JSON-asserted), 200 fast-path"

# --- IMP-005: GCP Recommender unlock command --------------------------------------------
# The cost-permissions hint must print the two exact copy-paste commands, not just name the gap.
grep -qF 'services enable recommender.googleapis.com' "$DOCTOR" \
  || fail "GCP cost-permissions hint no longer prints the 'gcloud services enable recommender.googleapis.com' unlock"
grep -qF 'roles/recommender.viewer' "$DOCTOR" \
  || fail "GCP cost-permissions hint no longer prints the 'roles/recommender.viewer' grant"
grep -qF 'add-iam-policy-binding' "$DOCTOR" \
  || fail "GCP cost-permissions hint no longer prints the IAM binding command"
ok "IMP-005: GCP Recommender hint prints the enable + grant copy-paste commands"

# --- IMP-006: VictoriaLogs / VictoriaTraces discoverability -----------------------------
for pair in \
  "skills/connect/SKILL.md|connect catalog" \
  "skills/connect/references/providers.md|providers.md" \
  "templates/toolkit.yaml.example|config template" \
  "skills/start/SKILL.md|start catalog" ; do
  f="${pair%%|*}"; label="${pair##*|}"
  [ -f "$ROOT/$f" ] || fail "$f missing"
  has "$ROOT/$f" "VictoriaLogs" "IMP-006: '$label' ($f) no longer names VictoriaLogs"
  has "$ROOT/$f" "VictoriaTraces" "IMP-006: '$label' ($f) no longer names VictoriaTraces"
done
# And it must say WHERE they go (loki/tempo blocks), not just name them.
grep -qiE "VictoriaLogs.*loki|loki.*VictoriaLogs" "$ROOT/skills/connect/references/providers.md" \
  || fail "IMP-006: providers.md must say VictoriaLogs goes in the loki block"
grep -qiE "VictoriaTraces.*tempo|tempo.*VictoriaTraces" "$ROOT/skills/connect/references/providers.md" \
  || fail "IMP-006: providers.md must say VictoriaTraces goes in the tempo block"
ok "IMP-006: VL/VT named + mapped to loki/tempo blocks in connect, providers.md, template, start"

echo "PASS: cheap-wins-vm-gcp-vlvt (IMP-004/005/006 locks)"
