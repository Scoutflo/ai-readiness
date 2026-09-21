#!/bin/sh
# Cloud Mode multi-cloud locks (DigitalOcean / Azure / GCP / APM overlay):
# per-cloud secret-safety invariants, shared-rules wiring, SKILL routing.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REF="$ROOT/skills/map-topology/references"
SKILL="$ROOT/skills/map-topology/SKILL.md"
fails=0
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
ok() { echo "ok: $1"; }

# --- 1. artifacts exist + shared-rules pointers -------------------------------
for f in cloud-mode-digitalocean.md cloud-mode-azure.md cloud-mode-gcp.md cloud-mode-apm-overlay.md; do
  [ -f "$REF/$f" ] || fail "$f missing"
  grep -q "Shared rules" "$REF/$f" || fail "$f lost its shared-rules pointer to the AWS cookbook"
done

# --- 2. DigitalOcean: the connection password can never surface ---------------
DO="$REF/cloud-mode-digitalocean.md"
grep -q "connection.password" "$DO" && { grep -q "never print" "$DO" || fail "DO: password mentioned without the never-print rule"; } || true
grep -qE 'doctl databases (list|connection)[^|]*> ' "$DO" && fail "DO: raw databases JSON redirected to a file" || ok "DO: no raw databases dump"
grep -q '.connection.host' "$DO" || fail "DO: catalog must field-select connection.host in-pipe"
grep -q "Traps" "$DO" || fail "DO: traps section missing"

# --- 3. Azure: elevated lane is opt-in; no vault secret reads -----------------
AZ="$REF/cloud-mode-azure.md"
grep -q "OPT-IN GATE" "$AZ" || fail "Azure: elevated lane lost its opt-in gate marker"
grep -q "az keyvault secret" "$AZ" && fail "Azure: a Key Vault secret read appeared" || ok "Azure: no vault secret reads"
n=$(grep -cF '(?i)password|passwd|secret|token|api_?key|private|credential' "$AZ" || true)
[ "$n" -ge 2 ] || fail "Azure: secret-key skip filter must guard both extraction blocks (found $n)"
grep -q "Verification status:" "$AZ" || fail "Azure: honesty banner missing"
grep -q "owed" "$AZ" || fail "Azure: banner must state what verification is still owed"

# --- 4. GCP: default-SA demotion; secret refs never resolved ------------------
GC="$REF/cloud-mode-gcp.md"
grep -qi "default.SA" "$GC" || grep -q "default compute service account" "$GC" || fail "GCP: default-SA demotion rule missing"
grep -q "gcloud secrets versions access" "$GC" && fail "GCP: a Secret Manager value read appeared" || ok "GCP: no secret value reads"
grep -qF '(?i)password|passwd|secret|token|api_?key|private|credential' "$GC" || fail "GCP: secret-key skip filter missing"

# --- 5. APM overlay: TTL + traffic-map separation + key guard -----------------
AP="$REF/cloud-mode-apm-overlay.md"
grep -qi "expire" "$AP" || fail "overlay: TTL/expiry rule missing"
grep -q "never enters the Traffic map" "$AP" || grep -q "not CALLS" "$AP" || fail "overlay: CALLS/Traffic-map separation missing"
grep -qF '[ -n "${NEW_RELIC_USER_KEY:-}" ]' "$AP" || fail "overlay: NR key guard missing (empty-header class)"

# --- 6. SKILL wiring -----------------------------------------------------------
grep -q "cloud-mode-digitalocean.md" "$SKILL" || fail "SKILL: DO cookbook not wired"
grep -q "cloud-mode-azure.md" "$SKILL" || fail "SKILL: Azure cookbook not wired"
grep -q "cloud-mode-gcp.md" "$SKILL" || fail "SKILL: GCP cookbook not wired"
grep -q "cloud-mode-apm-overlay.md" "$SKILL" || fail "SKILL: overlay cookbook not wired"
grep -q "for src in kubernetes aws digitalocean azure gcp newrelic sentry" "$SKILL" || fail "SKILL: Phase-0 routing loop missing azure/gcp"
grep -q "APM overlay" "$SKILL" || fail "SKILL: overlay step missing from Phase 2E"
RCA="$ROOT/skills/rca/SKILL.md"
grep -q "STORES_DATA_IN|CACHES_IN" "$RCA" || fail "rca: classifier lost the resource-dependency suspect branch (C7 promise)"

# --- 7. redaction behavior on the GCP/Azure-style env extraction --------------
command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }
OUT=$(printf '%s' '[{"metadata":{"name":"checkout"},"spec":{"template":{"spec":{"containers":[{"env":[
 {"name":"DATABASE_URL","value":"postgres://svc:my.secret.pw@db.internal.test:5432/orders"},
 {"name":"PGPASSWORD","value":"dotted.secret.value"},
 {"name":"CACHE_REF","valueFrom":{"secretKeyRef":{"name":"cache-dsn"}}}]}]}}}}]' \
| jq -r '.[] | .metadata.name as $svc
  | (.spec.template.spec.containers[]? .env // [])[]
  | select(.valueFrom == null)
  | select(.name | test("(?i)password|passwd|secret|token|api_?key|private|credential") | not)
  | .name as $k | (.value // "") | gsub("://[^@/]*@"; "://")
  | capture("(?<h>[A-Za-z0-9][A-Za-z0-9.-]+\\.[A-Za-z]{2,})(:(?<p>[0-9]{2,5}))?"; "g")
  | [$svc, $k, .h, (.p // "-")] | @tsv')
echo "$OUT" | grep -q "db.internal.test	5432" || fail "gcp-style extraction lost the endpoint join"
echo "$OUT" | grep -q "my.secret.pw" && fail "gcp-style extraction leaked a userinfo credential" || ok "userinfo stripped"
echo "$OUT" | grep -q "dotted.secret.value" && fail "gcp-style extraction leaked a secret-named key" || ok "secret key skipped"
echo "$OUT" | grep -q "cache-dsn" && fail "secretKeyRef resolved instead of skipped" || ok "secretRef entries excluded from value parsing"

[ "$fails" -eq 0 ] && echo "PASS: cloud-mode multicloud locks" || { echo "FAILURES: $fails"; exit 1; }
