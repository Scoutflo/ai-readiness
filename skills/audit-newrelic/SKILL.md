---
name: audit-newrelic
description: Read-only scored audit of a New Relic account across alert delivery (condition to policy to workflow to destination), alert noise (tiering, evaluation sanity, muting hygiene, measured fire-history from NrAiIncident), entity coverage and span-derived topology, SLO and dashboard posture, and data health (NrIntegrationError, cardinality, ingest concentration), plus a separate non-scored ingest and cost section; writes findings.json and report.md and changes nothing. Use when the user mentions auditing or scoring New Relic, NR alerts or alert policies, NRQL conditions, workflows and notification destinations, muting rules, New Relic entity or service coverage, NrAiIncident noise, or New Relic ingest volume. Do not use to change New Relic (use setup-newrelic; this audit only names each fix), for OTel collector configuration on the shipping side (that is the cluster's own config), or for the paging layer downstream of a notification (use audit-pagerduty or audit-zenduty).
---

# audit-newrelic

Scored, read-only audit of the New Relic account that carries your alerting and
telemetry: whether each conditioned policy actually reaches a live destination,
whether the conditions are tuned or noisy (including the measured fire-history New
Relic itself records in `NrAiIncident`), whether the entities that matter are
covered and connected in the span-derived topology, whether SLOs and dashboards
exist where the business says they must, and whether New Relic silently rejected
telemetry you believe you sent. It answers one question: when a critical service
breaks tonight, does exactly one useful notification reach the right team — and is
the data that notification depends on actually arriving?

This skill audits inside New Relic via NerdGraph. The OTel collectors that ship
telemetry into it belong to their own estates (`audit-kubernetes` for the cluster);
the paging layer downstream of a webhook/PagerDuty destination is `audit-pagerduty`
/ `audit-zenduty`. This audit stops at the New Relic account boundary.

Every call is a **read**: NerdGraph `query` documents only, on the single
`/graphql` endpoint (a documented read-by-POST — the GraphQL body decides the
effect, and this audit never sends a `mutation` document; the full forbidden list
is in [references/newrelic-checks.md](references/newrelic-checks.md) section 13).
Fixes are `setup-newrelic`'s job — each mapped finding points at its fix
section there (the remediation map), with the manual path also named inline.

**Multiple New Relic accounts, one run:** `newrelic` may be a single block (one
`account_id`/`api_key_env`/`region`) or a **list of labeled targets**, each with
its own. The audit **iterates every target** — enumerate with
`sh "${CLAUDE_PLUGIN_ROOT}/report-standard/toolkit-targets.sh" <cfg> newrelic labels`
and run the full sequence below once per target with `SCOUTFLO_TARGET=<label>`
set. Output goes to `newrelic/<label>/<date>/` for a list, or the flat
`newrelic/<date>/` for a single block. Every API call resolves and uses the
target's own region host and User key — `api_key_env` names the variable holding
the secret, sent as the `API-Key` header; there is no ambient default.

Run this standalone, from `/scoutflo:audit-all`, or on a schedule via
`/scoutflo:schedule-audits`.

Outputs, per the [report standard](../../report-standard/README.md):

- `./scoutflo-audits/newrelic/[<label>/]<YYYY-MM-DD>/findings.json` per the
  [findings schema](../../report-standard/findings-schema.md), finding IDs
  `NR-NNN` (scored) and `NROPT-NNN` (non-scored ingest/cost)
- `./scoutflo-audits/newrelic/[<label>/]<YYYY-MM-DD>/report.md` per the
  [report template](../../report-standard/report-template.md), including the
  `## Inventory` section (the `render-report-viz.sh inventory` output)
- `./scoutflo-audits/newrelic/[<label>/]<YYYY-MM-DD>/report.html` — the
  self-contained visual report (`render-report-viz.sh html`)
- `./scoutflo-audits/newrelic/[<label>/]<YYYY-MM-DD>/inventory.json` per the
  [inventory schema](../../report-standard/inventory-schema.md)
  (`scoutflo-inventory/v1`): the complete Phase-2 catalog — one item per policy
  (`kind: policy`), condition (**`kind: alert_rule`** — the coverage-countable
  kind the cross-tool engine keys on, contract C14; `covers` = the service its
  NRQL selects, `routes_to` = its policy id), workflow (`workflow`), destination
  (`destination`), channel (`channel`), muting rule (`muting_rule`), service
  entity (`service`), synthetic monitor (**`kind: uptime_check`** — also
  coverage-countable), SLO (`slo`), and dashboard (`dashboard`) — each with
  `kind`, `covers`, `enabled`, `severity`, and `routes_to` for alerting objects.
  Built from the raw pull, never invented; redacted at capture, never a secret
  value.
- One appended line in `./scoutflo-audits/newrelic/[<label>/]history.jsonl`
- One Slack brief, when `slack.webhook_env` is configured

## Doctor gate

| Integration | toolkit.yaml keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| New Relic | `newrelic.account_id`, `newrelic.api_key_env`, optional `newrelic.region` (`US` default, or `EU`) | the variable named by `api_key_env` (`NEW_RELIC_USER_API_KEY`) — a **User** API key (`NRAK-…`), never a license/ingest key | NerdGraph read access to the account (a standard user's key suffices; no admin role needed) | read-only |
| Slack (optional) | `slack.webhook_env` | webhook variable | post to one channel | n/a |

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"
[ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done
[ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
if [ ! -f "$CFG" ]; then
  ENVCFGS=$(for d in "./.scoutflo" "$HOME/.scoutflo"; do ls "$d"/toolkit-*.yaml 2>/dev/null; done)
  if [ -n "$ENVCFGS" ]; then
    echo "no default config at $CFG, but found environment-specific configs:"
    printf '%s\n' "$ENVCFGS" | sed 's/^/  - /'
    echo "re-run with SCOUTFLO_CONFIG=<one of the above> for the environment you want (never auto-picked), or run /scoutflo:connect to create a default"
  else
    echo "missing $CFG; run /scoutflo:connect"
  fi
  exit 1
fi
# Load the home-anchored secret store so a token added to ~/.scoutflo/env (by connect,
# even mid-session) is seen here without re-exporting or opening a new terminal. It only
# sets *_env variables; no secret value is printed. A profile that already sources it makes
# this a no-op. This mirrors what /scoutflo:doctor does, so doctor and this audit agree.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
for bin in curl jq; do
  command -v "$bin" >/dev/null || { echo "missing binary: $bin"; exit 1; }
done
# Resolve the CURRENT newrelic target from toolkit.yaml — a single block, or the SCOUTFLO_TARGET-selected
# item of a labeled list (the shared enumerator handles both; no yq required).
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
NR_KIND=$(sh "$TT" "$CFG" newrelic kind); NR_N=$(sh "$TT" "$CFG" newrelic count)
[ "${NR_N:-0}" -ge 1 ] || { echo "no newrelic target configured in $CFG; run /scoutflo:connect"; exit 1; }
NR_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$NR_N" ]; do [ "$(sh "$TT" "$CFG" newrelic label "$_i")" = "$SCOUTFLO_TARGET" ] && { NR_IDX=$_i; break; }; _i=$((_i+1)); done; fi
NR_LABEL=$(sh "$TT" "$CFG" newrelic label "$NR_IDX")
if [ "$NR_KIND" = seq ]; then NR_SEG="newrelic/${NR_LABEL}"; else NR_SEG="newrelic"; fi
NR_ACCT=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" account_id)
[ -n "$NR_ACCT" ] || { echo "newrelic target '${NR_LABEL:-?}' has no account_id in $CFG; run /scoutflo:connect"; exit 1; }
NR_REGION=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" region); NR_REGION="${NR_REGION:-US}"
case "$NR_REGION" in
  US|us) NR_API_HOST="api.newrelic.com" ;;
  EU|eu) NR_API_HOST="api.eu.newrelic.com" ;;
  *) echo "newrelic.region must be US or EU (got '${NR_REGION}')"; exit 1 ;;
esac
echo "newrelic target: ${NR_LABEL} (account ${NR_ACCT}, region ${NR_REGION}) -> ${NR_SEG}/"
# newrelic.api_key_env names the VARIABLE holding this target's User key; read it by name so
# every target uses its own key (default NEW_RELIC_USER_API_KEY). Presence check only, never print.
NR_KEY_VAR=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" api_key_env); NR_KEY_VAR="${NR_KEY_VAR:-NEW_RELIC_USER_API_KEY}"
NEW_RELIC_USER_KEY="$(printenv "$NR_KEY_VAR" 2>/dev/null || true)"; export NEW_RELIC_USER_KEY
[ -n "${NEW_RELIC_USER_KEY:-}" ] || { echo "${NR_KEY_VAR} is not set — add it to ~/.scoutflo/env (echo 'export ${NR_KEY_VAR}=\"<paste>\"' >> ~/.scoutflo/env; chmod 600 ~/.scoutflo/env), or run /scoutflo:connect. The plugin reads that file, not your interactive shell."; exit 1; }
# Three-outcome authenticated probe. Keep the body and content-type (never /dev/null) so a
# 200 that is really an HTML proxy/SSO page fails closed instead of false-greening.
NRB="$(mktemp)"
NRM="$(curl -s -o "$NRB" -w '%{http_code} %{content_type}' --max-time 15 \
  -X POST "https://${NR_API_HOST}/graphql" \
  -H 'Content-Type: application/json' -H "API-Key: ${NEW_RELIC_USER_KEY}" \
  --data '{"query":"{ actor { user { name } accounts { id name } } }"}')" || true
NRC="${NRM%% *}"; NRCT="${NRM#* }"
if [ "$NRC" = "401" ]; then rm -f "$NRB"; echo "NerdGraph returned 401 'authentication required': the User key is missing or invalid — the two are INDISTINGUISHABLE server-side; re-paste or mint a User key (NRAK-…, not a license key) and store it in ${NR_KEY_VAR}"; exit 1; fi
if [ "$NRC" = "403" ]; then rm -f "$NRB"; echo "NerdGraph returned 403: a valid key on the WRONG REGION endpoint ('not authorized for account region') — set newrelic.region to this account's real region (US or EU) in $CFG"; exit 1; fi
[ "$NRC" = "200" ] || { rm -f "$NRB"; echo "NerdGraph returned ${NRC} from https://${NR_API_HOST}/graphql — endpoint unreachable or blocked"; exit 1; }
printf '%s' "$NRCT" | grep -qi json && jq -e '.data.actor.user.name' "$NRB" >/dev/null 2>&1 \
  || { rm -f "$NRB"; echo "200 but Content-Type=${NRCT} and the body is not the NerdGraph actor JSON — looks like an HTML proxy/SSO page, not ${NR_API_HOST}"; exit 1; }
jq -e --argjson a "$NR_ACCT" '.data.actor.accounts | any(.[]; .id == $a)' "$NRB" >/dev/null 2>&1 \
  || { echo "the key is valid but account ${NR_ACCT} is NOT among the accounts it can see:"; jq -r '.data.actor.accounts[] | "  - \(.id) \(.name)"' "$NRB"; rm -f "$NRB"; echo "fix newrelic.account_id in $CFG (one of the above), or use the key for the right account"; exit 1; }
rm -f "$NRB"
echo "doctor gate: pass"
```

Never proceed past a failed doctor check and never downgrade one into a finding.
`/scoutflo:doctor` runs the same three-outcome probe standalone.

New Relic needs exactly one secret here: the **User** key (NerdGraph). The
account's license/ingest keys are a different family this audit never touches.
There is no scope introspection on a User key — it reads what its user can read;
if a broader-than-needed user's key is used the audit still runs, but record in
the report that the audit credential can do more than read.

## Live-safety gate

Print what you are pointed at and compare it to the config before the first real
check:

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
# Self-load the secret store: each block runs in a fresh shell, so the doctor gate's export
# does not persist here (live-caught: this block failed on a key the doctor gate had just seen).
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
NR_KIND=$(sh "$TT" "$CFG" newrelic kind); NR_N=$(sh "$TT" "$CFG" newrelic count)
NR_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$NR_N" ]; do [ "$(sh "$TT" "$CFG" newrelic label "$_i")" = "$SCOUTFLO_TARGET" ] && { NR_IDX=$_i; break; }; _i=$((_i+1)); done; fi
NR_LABEL=$(sh "$TT" "$CFG" newrelic label "$NR_IDX"); NR_ACCT=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" account_id)
if [ "$NR_KIND" = seq ]; then NR_SEG="newrelic/${NR_LABEL}"; else NR_SEG="newrelic"; fi
NR_REGION=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" region); NR_REGION="${NR_REGION:-US}"
case "$NR_REGION" in US|us) NR_API_HOST="api.newrelic.com" ;; EU|eu) NR_API_HOST="api.eu.newrelic.com" ;; esac
NR_KEY_VAR=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" api_key_env); NR_KEY_VAR="${NR_KEY_VAR:-NEW_RELIC_USER_API_KEY}"
NEW_RELIC_USER_KEY="$(printenv "$NR_KEY_VAR" 2>/dev/null || true)"; export NEW_RELIC_USER_KEY
[ -n "${NEW_RELIC_USER_KEY:-}" ] || { echo "newrelic target '${NR_LABEL}' key variable ${NR_KEY_VAR} is not set — add it to ~/.scoutflo/env, or run /scoutflo:connect"; exit 1; }
# Identify the account by name and by a sample of what it contains — the human confirmation
# that this is the account you intend to audit (content-type + body asserted, fails closed).
LSB="$(mktemp)"
LSM="$(curl -s -o "$LSB" -w '%{http_code} %{content_type}' --max-time 15 \
  -X POST "https://${NR_API_HOST}/graphql" \
  -H 'Content-Type: application/json' -H "API-Key: ${NEW_RELIC_USER_KEY}" \
  --data "{\"query\":\"{ actor { account(id: ${NR_ACCT}) { id name } entitySearch(query: \\\"accountId = ${NR_ACCT} AND (domain = 'EXT' OR domain = 'APM')\\\") { count results { entities { name } } } } }\"}")" || true
LSC="${LSM%% *}"; LSCT="${LSM#* }"
[ "$LSC" = "200" ] && printf '%s' "$LSCT" | grep -qi json && jq -e '.data.actor.account.id' "$LSB" >/dev/null 2>&1 \
  || { rm -f "$LSB"; echo "account identification failed (HTTP ${LSC}); wrong account_id, region, or key — stop"; exit 1; }
ACCT_NAME="$(jq -r '.data.actor.account.name' "$LSB")"
SVC_COUNT="$(jq -r '.data.actor.entitySearch.count' "$LSB")"
SAMPLE="$(jq -r '[.data.actor.entitySearch.results.entities[:3][].name] | join(", ")' "$LSB")"
rm -f "$LSB"
echo "account=${NR_ACCT} (${ACCT_NAME}) region=${NR_REGION} label=${NR_LABEL} -> ${NR_SEG}/ services=${SVC_COUNT} sample: ${SAMPLE}"
echo "live-safety gate: pass — confirm this account name and these service names are the estate you intend to audit"
```

The account id, the key, and the region host together select the estate; there is
no ambient default. The service-name sample is the human confirmation.

## Ground rules

- Configuration is metadata; observed behavior is proof. A workflow that catches a
  policy is `configured`; only an observed notification (a fired `NrAiIncident`
  that delivered) makes the path `validated-live` — say which level each earned.
- **HTTP 200 from the ingest side is not proof of ingestion.** New Relic documents
  that success codes can still mean dropped data; `NrIntegrationError` is the only
  visibility (NR-004). Never let an exporter's 200s override that event type.
- API errors are evidence. 401 = key missing/invalid (indistinguishable — one
  diagnosis state); 403 = wrong region host (diagnosable, distinct). Record which,
  and never convert an error into empty success.
- OTel-instrumented services are `domain 'EXT'` entities, NOT `APM` — an entity
  query that only reads APM on an OTel estate sees zero services and lies. Query
  both domains, always.
- An EXT entity **expires from the UI after 8 idle days** while its telemetry
  stays queryable — distinguish "never reported" from "stopped reporting" before
  writing a coverage finding (NR-031).
- Alert evaluation and NRQL charts diverge by design: late data points are
  excluded from streaming evaluation forever. "The chart shows a breach but no
  alert fired" is an `aggregationDelay`/method finding (NR-021), not a platform
  bug and not a delivery finding.
- The "Service Levels default policy" is a platform artifact auto-created by SLO
  creation — and it arrives WITH an enabled error-budget condition that NO
  workflow catches (live-verified). NR-011 reports it at reduced severity with
  the platform behavior named: error-budget incidents notify nobody until the
  operator wires a workflow or deliberately disables the auto condition.
- Never score from object counts.
  - ❌ `Scored alert delivery 90: forty conditions exist.`
  - ✅ `Scored alert delivery 45: forty conditions exist, but two policies with
    enabled conditions are caught by no workflow and one destination is inactive;
    credit stops at partial.`
- Sequential NerdGraph calls only — the platform allows 25 concurrent requests
  per user and this audit must not starve the account's other automation.
- Secret discipline per [secret-redaction](../../report-standard/secret-redaction.md):
  the User key is read from its env var by name and sent as a header — its value
  is never echoed, written to evidence, or embedded in a report; captures keep
  ids, names, types, and settings only. A condition's NRQL or a workflow name
  that embeds a secret-shaped value is redacted at capture.

## Estate sizing

Count before judging, and declare the path in the terminal output:

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
NR_KIND=$(sh "$TT" "$CFG" newrelic kind); NR_N=$(sh "$TT" "$CFG" newrelic count)
NR_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$NR_N" ]; do [ "$(sh "$TT" "$CFG" newrelic label "$_i")" = "$SCOUTFLO_TARGET" ] && { NR_IDX=$_i; break; }; _i=$((_i+1)); done; fi
NR_LABEL=$(sh "$TT" "$CFG" newrelic label "$NR_IDX"); NR_ACCT=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" account_id)
if [ "$NR_KIND" = seq ]; then NR_SEG="newrelic/${NR_LABEL}"; else NR_SEG="newrelic"; fi
NR_REGION=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" region); NR_REGION="${NR_REGION:-US}"
case "$NR_REGION" in US|us) NR_API_HOST="api.newrelic.com" ;; EU|eu) NR_API_HOST="api.eu.newrelic.com" ;; esac
NR_KEY_VAR=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" api_key_env); NR_KEY_VAR="${NR_KEY_VAR:-NEW_RELIC_USER_API_KEY}"
# Self-load the secret store (fresh shell per block; the doctor gate's export does not persist here).
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
NEW_RELIC_USER_KEY="$(printenv "$NR_KEY_VAR" 2>/dev/null || true)"; export NEW_RELIC_USER_KEY
[ -n "${NEW_RELIC_USER_KEY:-}" ] || { echo "${NR_KEY_VAR} is not set — run the doctor gate first"; exit 1; }
SMALL_MAX_OBJECTS="25"    # example, tune to your environment
MEDIUM_MAX_OBJECTS="150"  # example, tune to your environment
BATCH_SIZE="50"           # conditions/entities per batch on the large path; example, tune it
SZB="$(mktemp)"
curl -s -o "$SZB" --max-time 30 -X POST "https://${NR_API_HOST}/graphql" \
  -H 'Content-Type: application/json' -H "API-Key: ${NEW_RELIC_USER_KEY}" \
  --data "{\"query\":\"{ actor { account(id: ${NR_ACCT}) { alerts { nrqlConditionsSearch { totalCount } policiesSearch { totalCount } } } entitySearch(query: \\\"accountId = ${NR_ACCT} AND (domain = 'EXT' OR domain = 'APM')\\\") { count } } }\"}"
# Fail closed on a non-JSON / errored sizing read: `// 0` on a 401 body would silently report an
# empty estate (live-caught) — a false zero must never route a real account into the guardrail.
jq -e '.data.actor.account.alerts' "$SZB" >/dev/null 2>&1 \
  || { echo "estate sizing read failed: $(jq -r '.errors[0].message // "non-JSON response"' "$SZB" 2>/dev/null)"; rm -f "$SZB"; exit 1; }
COND_COUNT="$(jq -r '.data.actor.account.alerts.nrqlConditionsSearch.totalCount // 0' "$SZB")"
POL_COUNT="$(jq -r '.data.actor.account.alerts.policiesSearch.totalCount // 0' "$SZB")"
SVC_COUNT="$(jq -r '.data.actor.entitySearch.count // 0' "$SZB")"
rm -f "$SZB"
TOTAL=$((COND_COUNT + SVC_COUNT))
echo "conditions=${COND_COUNT} policies=${POL_COUNT} service_entities=${SVC_COUNT} scored_objects=${TOTAL}"

# Guided-walkthrough drift check, per report-standard/README.md: compare against the last run.
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${NR_SEG}"
PREV_RUN="$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)"
DRIFT="first run"
if [ -n "$PREV_RUN" ] && [ -f "${PREV_RUN}/findings.json" ]; then
  PREV_TOTAL="$(jq -r '.estate.objects // empty' "${PREV_RUN}/findings.json")"
  if [ -n "$PREV_TOTAL" ]; then
    if [ "$PREV_TOTAL" -eq "$TOTAL" ]; then
      DRIFT="estate unchanged since ${PREV_RUN##*/} (${PREV_TOTAL} objects then, ${TOTAL} now)"
    else
      DRIFT="estate changed since ${PREV_RUN##*/}: ${PREV_TOTAL} -> ${TOTAL} objects"
    fi
  else
    DRIFT="previous run recorded no estate data; treating as first run"
  fi
fi
echo "drift: ${DRIFT}"
```

- **Small** (`TOTAL <= SMALL_MAX_OBJECTS`): one pass over everything.
- **Medium** (`TOTAL <= MEDIUM_MAX_OBJECTS`): per-category passes (data health,
  delivery, noise, coverage), completed in one run.
- **Large**: work conditions and entities in batches of `BATCH_SIZE` against a
  durable, run-ID-keyed worklist per the worklist rules in
  [skill-authoring-conventions.md](../../docs/skill-authoring-conventions.md):
  scan for a resumable run before minting a new run ID, one row per object id,
  lock before claiming a batch, mark rows done only after their pulls succeed,
  and assert zero pending rows before Phase 8 writes anything.

Never silently truncate: if the run judged a subset, the report names what was
skipped and the coverage denominators reflect it. The pagination and retry rules
in [references/newrelic-checks.md](references/newrelic-checks.md) section 10
apply to every call.

### Scope checkpoint

On a large estate this audit pauses to let you scope before spending tokens, per
the shared [estate-sizing scope checkpoint](../../report-standard/estate-scope-checkpoint.md).
After the sizing step above computes the object count, run the shared checkpoint
block:

```bash
set -eu
# The Estate sizing step above sets TOTAL to this audit's object count.
TOTAL="${TOTAL:?estate sizing must set TOTAL before the scope checkpoint}"
. "${CLAUDE_PLUGIN_ROOT}/skills/cli-interactive/lib/cli-interactive.sh"
. "${CLAUDE_PLUGIN_ROOT}/skills/checkpoint/lib/checkpoint.sh"
SCOPE="$(checkpoint_load_scope)"                # reuse a saved scope, or "all"
[ "$SCOPE" = "all" ] || echo "[checkpoint] reusing saved audit scope: ${SCOPE}"
if [ "${TOTAL}" -ge 501 ]; then
  echo "estate: ${TOTAL} objects (large path) — pausing to let you scope before spending tokens"
  cli_pause_before_audit "${TOTAL}"             # confirm before a large run
  cli_prompt_exclude_services                   # offer service/entity exclusions
  echo "[checkpoint] narrow scope any time with /scoutflo:checkpoint; reset with /scoutflo:checkpoint --reset-scope"
fi
```

The large-path phases then run against the scoped set; the report names anything
scoped out.

## Phase 1: Service context

Load business context per the Metadata Load section below. The critical-services
list drives NR-014 (the flagship paging path), NR-030/NR-031 escalation, and the
bounded per-entity topology reads; exclusions remove matched entities from every
denominator (recorded `not-in-scope` with the reason, never a fail).

## Phase 2: Read-only inventory

Run the raw pull in [references/newrelic-checks.md](references/newrelic-checks.md)
section 4 — one pass that captures policies, conditions (full noise-control field
set), workflows, destinations, channels, muting rules, entities (EXT + APM +
SYNTH + SERVICE_LEVEL + DASHBOARD, cursor-paginated), and the NRQL data-plane
reads (event types, `NrIntegrationError`, `NrAiIncident`, ingest bytes,
consumption, deployments, synthetic results) into `${RAW_DIR}`. Every later check
reads these files; nothing re-fetches.

Build `inventory.json` (`scoutflo-inventory/v1`) from the raw pull: one item per
object with `kind` — `policy`, **`alert_rule`** (each NRQL condition; the
coverage-countable kind per contract C14, so a New Relic condition can cover a
gap another tool has), `workflow`, `destination`, `channel`, `muting_rule`,
`service`, **`uptime_check`** (each synthetic monitor; also coverage-countable),
`slo`, `dashboard` — plus `covers` (for an `alert_rule`, the service its NRQL
selects; for an `uptime_check`, the endpoint), `enabled`, `severity`, and
`routes_to` for alerting objects (condition → policy id, workflow → channel ids,
channel → destination id). Routing/muting kinds are never coverage.
`counts.total` must reconcile with `items`.

## Phase 3: Reachability and data health (NR-001 to NR-006)

The doctor gate already proved NR-001/NR-002; re-assert them into the ledger from
its result. Then, from the raw pull: NR-003 (ingest alive — and the
**empty/hidden-scope guardrail**: reachable + valid key + zero event types and
zero entities marks the four downstream categories `blocked` with the reason,
renormalizes, and never reports a confident low score from an empty read), NR-004
(`NrIntegrationError` — the "200 is not ingested" check), NR-005 (cardinality
breaches), NR-006 (ingest concentration). Commands and interpretations:
[references/newrelic-checks.md](references/newrelic-checks.md) section 5.

## Phase 4: Alert delivery (NR-010 to NR-014)

The policy→workflow→channel→destination joins, the platform-artifact recognition
(Service Levels default policy), and the flagship NR-014 per-critical-service
paging path. Commands: [references/newrelic-checks.md](references/newrelic-checks.md)
section 6. Findings here carry the full paging-path narrative: which link is
broken, what fires into the void tonight, the exact fix, and the re-check that
proves it.

## Phase 5: Alert noise (NR-020 to NR-026)

Tiering, evaluation sanity (including the documented charts-vs-alerts divergence
and the sparse-signal EVENT_TIMER rule), loss-of-signal posture, disabled
conditions, muting hygiene, the **measured** fire-history from `NrAiIncident`
(chronic opens, top-noisy conditions, muted fires — the rows the alert-fatigue
roll-up consumes), and incidentPreference judgment. Commands:
[references/newrelic-checks.md](references/newrelic-checks.md) section 7.

## Phase 6: Coverage and topology (NR-030 to NR-035)

Zero-coverage entities (`alertSeverity: NOT_CONFIGURED`), critical services
present-and-reporting (with the 8-day-expiry distinction), span-derived topology
present (`relatedEntities` CALLS edges), golden signals resolvable
(`goldenMetrics`), synthetics coverage and health, ownership tags. Bounded
per-entity reads run for critical services only (≤10). Commands:
[references/newrelic-checks.md](references/newrelic-checks.md) section 8.

## Phase 7: SLO, dashboards, coverage matrix, and topology readiness (NR-040 to NR-042)

SLOs on critical services, dashboards (page-entity de-dup), change tracking.
Commands: [references/newrelic-checks.md](references/newrelic-checks.md)
section 9.

**Coverage matrix.** Fill one row per critical service — using the service names
from `topology.md` when the customer has run `/scoutflo:map-topology` (never a
re-inferred name for a mapped service) — with the check-result vocabulary
(`pass`, `partial`, `fail`, `blocked`, `not-in-scope`):

| Service | Ready | Delivery | Noise | Coverage | SLO | Owner | Gap |
| --- | --- | --- | --- | --- | --- | --- | --- |

Every cell carries its `passed/total` denominator. The audit's New Relic reads
feed the cells: entity present + reporting (NR-031), alert-covered (NR-030),
workflow-caught (NR-011/NR-014), noise posture (NR-020 to NR-026), CALLS edges +
golden metrics (NR-032/NR-033), SLO (NR-040), ownership tag (NR-035). Name
affected services in findings.

Then render the Scoutflo Topology Readiness section per
[topology-readiness.md](../../report-standard/topology-readiness.md): evaluate
the six checks per critical service from `./scoutflo-audits/topology-export.json`,
read-only. Render check names and confidence per the standard: plain-English
column headers (T-codes only in the legend line), confidence as `n/10`, the
verdicts `ready`/`partial`/`not-ready`, the exact headline
`<r> of <n> critical services are ready for automatic Scoutflo correlation`
(`audit-all` greps this plain-language line — never the forbidden `sync-ready`
jargon), and — whenever any service is below ready — the ticket-ready readiness
action plan table. Gaps that map to an existing finding reference its ID; gaps
with no finding get a `TOPO-` row pointing at `/scoutflo:map-topology`. If the
export or `topology.md` is missing, or describes a different target than this
audit covers, the section renders the matching state from topology-readiness.md
with its one-line unlock; it never guesses and never says a bare "unavailable".
Readiness is reported, never folded into the 0-100 score.

**A confirmed, real platform gap specific to this provider (verified against the
platform's current model):** New Relic is not itself a valid topology provider
identity on the Scoutflo platform — there is no `newrelic` value in the
platform's provider identity list, and no per-field attribute schema for it
either. A monitoring/alerting connection modeling **native New Relic alerting as
the connection's own tool identity** cannot satisfy Connection details (T4) or
Tool identity (T5) on the real platform, no matter how solid this audit's live
proof of the paging path is — there is no correct value to put in that
connection's provider field. This is not something the export format can work
around with different field names; it is a gap in what the platform itself
currently models. State this plainly in the Topology Readiness section for any
service whose alerting backend is native New Relic, rather than silently capping
the connection at `partial` with no explanation. If the real alerting funnel
routes New Relic's notifications onward into a provider the platform does model
(for example PagerDuty via a webhook destination), Connection details, Tool
identity, and Match confidence are fully reachable through *that* provider's
connection instead — the gap is specific to representing native New Relic as the
connection's own identity, not to auditing a New-Relic-monitored service in
general.

## Phase 8: Score, write, brief

1. Score each category from its checks; compute the weighted overall. The
   executive summary states the numeric gap to the target profile
   ([references §3](references/newrelic-checks.md)) and names the biggest levers
   by `points_recoverable` — "fix X, gain N points" — never just the score.
   Classify each finding's lifecycle (`new`/`unchanged`/`regressed`/`resolved`)
   by comparing against the PREVIOUS run's `findings.json` under
   `${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/<seg>/` (match on finding id +
   affected), never guessed; a first run marks everything `new`.
2. Load `./scoutflo-audits/exemptions.yaml` when present. Entries with `id`,
   `reason`, and `expires` all set and unexpired suppress their finding into the
   Suppressed appendix; malformed or expired entries are reported, never honored.
   For a readiness finding, retain the observed `partial` or `fail` result on the
   same-ID `checks[]` row and add `suppressed: true` plus `suppression_reason`;
   set the finding's `points_recoverable` to 0. Suppressed readiness checks
   remain assessed for coverage but are excluded from readiness scoring. A
   non-scored `NROPT-*` finding has no check row: set only its lifecycle to
   `suppressed`, preserve `scoring_scope: "non-scored"`, and keep zero readiness
   points.
3. Apply business context (Metadata Load): escalate critical-service findings,
   record exclusions `not-in-scope`, reduce severity for non-production-only
   gaps, order the cost section by `cost_sensitivity`.
4. Emit one `checks[]` row for every stable `NR-*` readiness catalog check,
   including passes, partials, failures, blockers, and not-in-scope checks.
   Derive category counts, readiness, assessment coverage, and `score.check_set`
   from that complete ledger; never write them independently. `NROPT-*` findings
   stay outside the readiness ledger and explicitly carry
   `scoring_scope: "non-scored"`.
5. Every finding declares `scoring_scope` (`readiness` for a same-ID non-pass
   `NR-*` check; `non-scored` for `NROPT-*`) and `report_lanes`:
   `general-audit`, `ai-sre-readiness`, or both. Default to `general-audit`
   (operational reliability); add or also use `ai-sre-readiness` only when the
   evidence bears on telemetry quality, service identity/naming,
   topology/ownership context, incident routing evidence, RCA trust, or action
   safety. A coverage/topology/routing-evidence finding is typically both; a
   pure noise/cost finding is `general-audit` only. This classification never
   changes severity or score.

Scorecard (categories and weights; the checks catalog in
[references/newrelic-checks.md](references/newrelic-checks.md) section 2 lists
every ID under these same category names). Each category also carries a
**maturity** rating for the executive narrative — `reactive` (gaps are found by
incidents), `proactive` (the category's checks pass by deliberate configuration),
`systematic` (passes are enforced by pipeline/IaC, not hand-maintenance) — judged
from the evidence, never from the score alone:

| Category | Weight | Checks |
| --- | --- | --- |
| Reachability and data health | 20 | NR-001 to NR-006 |
| Alert delivery | 25 | NR-010 to NR-014 |
| Alert noise | 20 | NR-020 to NR-026 |
| Coverage and topology | 25 | NR-030 to NR-035 |
| SLO and dashboards | 10 | NR-040 to NR-042 |

A category with zero applicable objects is excluded and the remaining weights
renormalize (per the findings schema); the empty/hidden-scope guardrail in
Phase 3 is what marks the downstream categories `blocked` on an empty account.

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
NR_KIND=$(sh "$TT" "$CFG" newrelic kind); NR_N=$(sh "$TT" "$CFG" newrelic count)
NR_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$NR_N" ]; do [ "$(sh "$TT" "$CFG" newrelic label "$_i")" = "$SCOUTFLO_TARGET" ] && { NR_IDX=$_i; break; }; _i=$((_i+1)); done; fi
NR_LABEL=$(sh "$TT" "$CFG" newrelic label "$NR_IDX")
if [ "$NR_KIND" = seq ]; then NR_SEG="newrelic/${NR_LABEL}"; else NR_SEG="newrelic"; fi
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${NR_SEG}/$(date +%Y-%m-%d)"
mkdir -p "$TARGET_DIR"
# ... write findings.json (scoutflo-findings/v2 with a complete checks[] ledger — one row per NR-* catalog
# check, lifecycle set per finding, scoring_scope, and report_lanes), inventory.json, and report.md per the
# report standard. The findings.json ".target" is the per-target slug (equal to $NR_SEG: "newrelic" for a
# single block, "newrelic/<label>" for a labeled-list target), so audit-all/correlation/render disambiguate
# multiple New Relic targets. Then verify:
jq -e --arg seg "$NR_SEG" '.schema == "scoutflo-findings/v2" and .target == $seg
  and (.score.check_set | type == "string" and length > 0)
  and (.checks | type == "array" and length > 0)
  and (.findings | all((.scoring_scope | IN("readiness","non-scored")) and (.report_lanes | type == "array" and length > 0)))' \
  "${TARGET_DIR}/findings.json" >/dev/null && echo "v2 envelope ok"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-findings.sh" "${TARGET_DIR}/findings.json"
# Output conformance: check-findings.sh recomputes every v2 denominator, category score, the
# assessment coverage, and the check_set fingerprint, and enforces the checks[]<->findings[]
# referential integrity — a score that does not reconcile with its own ledger fails here.
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-report.sh" "${TARGET_DIR}/report.md"
# Inventory (scoutflo-inventory/v1): the complete Phase-2 catalog of what exists,
# built from the raw pull (never invented, redacted). counts.total must reconcile with items.
jq -e '.schema == "scoutflo-inventory/v1" and (.counts.total == (.items | length))' \
  "${TARGET_DIR}/inventory.json" >/dev/null && echo "inventory ok"
# Render the derived views (contract C1: every run also writes report.html; the
# ## Inventory and findings-by-purpose sections of report.md ARE these renders):
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" inventory "${TARGET_DIR}/inventory.json" >/dev/null && echo "inventory section renders"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" lanes "${TARGET_DIR}/findings.json" >/dev/null && echo "findings-by-purpose section renders"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" html "${TARGET_DIR}/findings.json" "${TARGET_DIR}/report.html" "${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${NR_SEG}/history.jsonl" \
  && echo "report.html written"
# History: one line per run (v1 back-compat: overall may be null on a fully blocked run).
HIST="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${NR_SEG}/history.jsonl"
jq -c '{run_date:.run_date, overall:.score.overall, scoring_model:.score.scoring_model, check_set:.score.check_set,
  categories:(.score.categories | map({name:.name, score:.score})),
  counts:(.findings | group_by(.severity) | map({(.[0].severity): length}) | add)}' \
  "${TARGET_DIR}/findings.json" >> "$HIST"
tail -1 "$HIST" | jq -e '.run_date and ((.overall|type)=="number" or .overall==null) and .scoring_model and .check_set' >/dev/null && echo "history.jsonl updated"
```

The report's finding sections follow the depth doctrine: every finding names its
locus (the exact object), the live blast radius (what breaks tonight and who is
not paged), the correlation chain (which other findings share the cause), the
exact fix (the NerdGraph object and field, or the UI path), and the verification
read that proves the fix. "X is missing" alone is a scanner line, not a finding.

Send the Slack brief when `slack.webhook_env` is configured: overall, category
scores, top three findings with severities, and the report path — never a secret,
never a raw NRQL body.

## Cost & Ingest (non-scored)

This section is reported and never scored, the same pattern `audit-aws` uses.
Findings use the `NROPT-NNN` prefix, always carry `scoring_scope: "non-scored"`
and `points_recoverable: 0`, never appear in `score.categories`,
`score.excluded`, or the `checks[]` ledger, still carry their own `report_lanes`
(typically `general-audit`), and render under their own heading after Topology
Readiness. Commands in [references/newrelic-checks.md](references/newrelic-checks.md)
section 11. **Never invent a dollar**: GB figures come from the account's own
`NrConsumption`/`bytecountestimate()` reads; a dollar appears only when the
account's own consumption data exposes billed amounts. On a free-tier account the
100GB hard-lockout proximity is the headline, in GB.

## Metadata Load (v0.1.68+)

This skill reads the optional business-context SSOT to honor your guardrails:

```bash
set -eu
BC_JSON="${HOME}/.scoutflo/business_context.json"      # workspace projection, derived from the SSOT
BC_MD="${HOME}/.scoutflo/business_context.md"          # the SSOT itself (authoritative)
METADATA="${HOME}/.scoutflo/computed_metadata.jsonl"   # per-resource cache from business-context-resolver

# The workspace layer and the per-resource layer load TOGETHER, not either/or.
HAVE_PER_RESOURCE=0; HAVE_WORKSPACE=0
[ -f "$METADATA" ] && jq -e '.' "$METADATA" >/dev/null 2>&1 && HAVE_PER_RESOURCE=1
[ -f "$BC_JSON" ]  && jq -e '.' "$BC_JSON"  >/dev/null 2>&1 && HAVE_WORKSPACE=1
# Workspace source: the derived json, else the markdown SSOT directly (ssot-md fallback).
BC_SRC=""
if [ "$HAVE_WORKSPACE" -eq 1 ]; then BC_SRC="$BC_JSON"; elif [ -f "$BC_MD" ]; then BC_SRC="$BC_MD"; fi
if   [ "$HAVE_PER_RESOURCE" -eq 1 ] && [ "$HAVE_WORKSPACE" -eq 1 ]; then LOAD_METADATA_MODE="per-resource+workspace"
elif [ "$HAVE_PER_RESOURCE" -eq 1 ];                                then LOAD_METADATA_MODE="per-resource"
elif [ "$HAVE_WORKSPACE" -eq 1 ];                                   then LOAD_METADATA_MODE="workspace"
elif [ -n "$BC_SRC" ];                                              then LOAD_METADATA_MODE="ssot-md"
else                                                                     LOAD_METADATA_MODE="none"; fi
echo "metadata mode: $LOAD_METADATA_MODE"

# Load the workspace rules the apply step below honors. All fields optional; absence = neutral default.
if [ "$HAVE_WORKSPACE" -eq 1 ]; then
  ENVIRONMENT="$(jq -r '.environment // "production"' "$BC_JSON" 2>/dev/null || echo production)"
  COST_SENSITIVITY="$(jq -r '.cost_sensitivity // "medium"' "$BC_JSON" 2>/dev/null || echo medium)"
  CRITICAL="$(jq -r '.critical_dependencies[]? // empty' "$BC_JSON" 2>/dev/null || true)"
  EXCLUSIONS="$(jq -r '.exclusions // {} | [.accounts?, .regions?, .services?, .resources?] | add // [] | .[]? // empty' "$BC_JSON" 2>/dev/null || true)"
  jq -r --arg e "$ENVIRONMENT" '.environment_map[]? | select(.environment==$e)' "$BC_JSON" 2>/dev/null || true  # per-env profile/context + uptime_sla
  jq -r '.service_slas[]? | "\(.service)=\(.sla)"' "$BC_JSON" 2>/dev/null || true                               # per-service SLA (wins over the env default)
elif [ "$LOAD_METADATA_MODE" = "ssot-md" ]; then
  ENVIRONMENT="$(grep -iA5 '^## Environment' "$BC_MD" | grep -iE 'Stage:' | head -1 | sed -E 's/.*Stage:\**[[:space:]]*//; s/[][]//g; s/[[:space:]]*$//' | tr 'A-Z' 'a-z')"; [ -n "$ENVIRONMENT" ] || ENVIRONMENT="production"
  COST_SENSITIVITY="$(grep -iA3 '^## Cost Sensitivity' "$BC_MD" | grep -iE 'Primary:' | head -1 | sed -E 's/.*Primary:\**[[:space:]]*//; s/[][]//g; s/[[:space:]]*$//' | tr 'A-Z' 'a-z')"; [ -n "$COST_SENSITIVITY" ] || COST_SENSITIVITY="medium"
  CRITICAL="$(awk '/^## Critical Services/{f=1;next} /^## /{f=0} f' "$BC_MD" | grep -oE '`[^`]+`' | tr -d '`')"
  EXCLUSIONS="$(awk '/^## Exclusions/{f=1;next} /^## /{f=0} f' "$BC_MD" | grep -oE '`[^`]+`' | tr -d '`')"
fi
# When HAVE_PER_RESOURCE=1, look each finding's affected resource up in computed_metadata.jsonl and let
# its per-resource action/escalation/sla refine (never weaken) the workspace rule for that one resource.
```

When context is available, apply it per
[BUSINESS-CONTEXT-INTEGRATION-v0168.md](../../docs/BUSINESS-CONTEXT-INTEGRATION-v0168.md):
**exclude** entities matched by an exclusion (record them `not-in-scope` with the
reason, never a fail); **escalate** findings on a `critical_dependencies` service
(NR-014/NR-030/NR-031 severity rises one level); reduce severity for a gap that
exists only in a non-production `environment`; and apply `cost_sensitivity` to
the NROPT ordering. With no context, run neutral defaults and say so — never
invent a business rule.

## Remediation pointers

Every mapped finding's `remediation` points at its [setup-newrelic](../setup-newrelic/SKILL.md)
fix section per `docs/finding-remediation-map.json` (e.g.
`setup-newrelic#wire-a-workflow-to-an-uncaught-policy` for NR-011). The manual
fix locations below remain the operator's direct path for unmapped findings and
UI-only steps:

| Finding area | Fix location today |
| --- | --- |
| Key/region/account mismatch (NR-001, NR-002) | one.newrelic.com → API keys (mint a User key); `newrelic.region`/`account_id` in toolkit.yaml |
| Silent ingest failures (NR-004) | Fix at the SOURCE the error names: clock skew/buffering for stale spans, collector-side attribute trimming, delta temporality in SDKs — then watch the `NrIntegrationError` facet stop growing |
| Cardinality breaches (NR-005) | Collector attribute hygiene; NR metric normalization rules (UI: data management) |
| Ingest concentration (NR-006, NROPT-001) | Collector filter/sampler processors — NOT drop rules (legacy drop rules are dead for new accounts; the successor is permission-gated) |
| Unwatched estate / uncaught policies (NR-010, NR-011) | Alerts → Alert conditions / Workflows — create conditions; add a workflow filtered on `labels.policyIds` (or a deliberate catch-all) |
| Broken linkage / inactive destinations (NR-012, NR-013) | Alerts → Destinations — reactivate or recreate the destination; re-bind the channel |
| Broken paging path on a critical service (NR-014) | Fix the exact broken link the finding names (condition/policy/workflow/destination) — one link per fix, then re-run the join |
| Single-tier conditions (NR-020) | Condition edit — add a WARNING term below the CRITICAL one |
| Evaluation misconfiguration (NR-021) | Condition edit → signal: raise `aggregationDelay` past the real data latency; switch sparse signals to EVENT_TIMER; make durations multiples of the window |
| Missing loss-of-signal (NR-022) | Condition edit → loss of signal: set an expiration and a deliberate open-on-expiration |
| Dead-weight disabled conditions (NR-023) | Delete or re-enable — never park |
| Open-ended active mutes (NR-024) | Alerts → Muting rules — add a schedule/end date, or disable the rule |
| Chronic/noisy conditions (NR-025) | Tune the named condition's thresholds/duration; a chronic open with no close is a threshold the signal can never recover across |
| incidentPreference mismatch (NR-026) | Policy edit — pick the preference deliberately for the policy's condition mix |
| Zero-coverage entities (NR-030) | Create a condition whose NRQL selects the entity (its goldenMetrics NRQL is a ready-made starting query) |
| Absent/expired critical service (NR-031) | If NRDB shows history: re-start the telemetry (collector/exporter). If never: instrument the service (`service.name` is the only hard requirement) |
| Missing topology edges (NR-032) | Fix context propagation between the named services (W3C traceparent through queues/gateways); manual `entityRelationshipUserDefinedCreateOrReplace` is the operator's fallback |
| Unresolvable golden signals (NR-033) | Align the service's instrumentation with the golden metric's NRQL (usually a naming drift) |
| Synthetics gaps (NR-034) | Synthetic monitoring — add a monitor per public endpoint; re-enable or fix failing ones |
| Missing ownership tags (NR-035) | Entity tags (`taggingAddTagsToEntity` is the operator's one-call fix — this audit never performs it) |
| No SLOs on critical services (NR-040) | Service levels — define availability/latency SLOs on the named services |
| Dashboard gaps (NR-041) | Dashboards — golden signals per critical service |
| Change tracking unwired (NR-042) | Add a `changeTrackingCreateDeployment` call to the deploy pipeline (operator's step) |
| Ingest/cost opportunities (NROPT-NNN) | Data management UI — retention per namespace, events-to-metrics rules; collector-side filters |
| Topology readiness gaps with no finding | `/scoutflo:map-topology` |

## Common Failure Modes

All thresholds and windows named in the checks are example values; tune them to
your workloads before treating a miss as a failure.

| Failure | Prevention |
| --- | --- |
| 401 read as "key missing" vs "key wrong" | The two are indistinguishable server-side — one diagnosis state, one fix message (re-paste or mint); never speculate which |
| 403 read as a permission problem | On NerdGraph a valid key on the wrong region host 403s (`account region`) — check `newrelic.region` before concluding scope |
| Entity coverage measured on `domain = 'APM'` only | OTel services live in `domain 'EXT'`; query both domains or a fully-instrumented OTel estate scores zero |
| Exporter 200s trusted as ingestion proof | NR documents 200-with-drop; `NrIntegrationError` is the only rejection surface (NR-004) — read it every run |
| An idle service read as "never instrumented" | EXT entities expire from the UI after 8 idle days; check NRDB history first (NR-031 distinguishes stopped from never) |
| "Chart shows a breach but no alert fired" filed as delivery failure | Late data is excluded from streaming evaluation forever — that is an `aggregationDelay`/method finding (NR-021), not a routing bug |
| A sparse signal's silent non-firing missed | EVENT_FLOW windows never close on >65-min-gap signals; the condition looks healthy and never evaluates — flag for EVENT_TIMER |
| The "Service Levels default policy" mis-handled in either direction | It auto-arrives WITH an enabled error-budget condition and no workflow (live-verified) — NR-011 reports it at MEDIUM naming the platform behavior; suppressing it entirely hides real un-routed error-budget alerts, and flagging it critical overstates an unauthored default |
| A disabled condition counted as coverage | `enabled: false` never fires; NR-023 names it dead weight and NR-030's coverage join ignores it |
| Muting-rule schedule absence read from a missing field | `schedule: null` is the API's way of saying no schedule — that IS the NR-024 open-ended case when `enabled: true` |
| Dashboard count inflated by page entities | A one-page dashboard = 2 DASHBOARD entities; de-dup by unique name before judging (NR-041) |
| Fire-history judged from config presence | NR-025 reads `NrAiIncident` — measured opens/closes/muted-fires; a condition that never fired is a different (possibly correct) state than one that fires hourly |
| The audit's own calls starving account automation | NerdGraph allows 25 concurrent per USER; this audit is sequential by design — never parallelize the pull |
| A mutation smuggled in as a "quick fix" | The read surface is query-documents-only; every mutation is forbidden (references section 13) — findings name the operator's step instead |
| License key pasted where the User key belongs | License/ingest keys cannot query NerdGraph; the doctor gate's 401 message names the NRAK- User-key requirement |
| Empty account scored as a failing estate | The Phase-3 guardrail marks downstream categories `blocked` and renormalizes — reachable-but-empty is a scope problem, not a zero score |
