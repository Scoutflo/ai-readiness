# Bounded collection, identity and resume

This is the execution path for standalone collection. Local roll-up mode needs no
provider preflight. Keep provider reads in the fixed recipes in
[fire-history-reads.md](fire-history-reads.md), with the owning `audit-*` as the
source of truth for transport and identity. The workflow harness handles only
local state and the existing doctor invocation; it is not a provider SDK.

## Select and freeze the run

Use an explicit `SCOUTFLO_CONFIG` for the selected environment; otherwise the
home config is used. Enumerate the selected provider with the shared
`report-standard/toolkit-targets.sh` helper. Select exactly one label per run,
including for a single-block configuration. For Alertmanager use its owning
`prometheus` config label. Do not select the first item of a list implicitly.
For several providers/labels create one plan per target and combine only their
validated final fragments at the end.

Prepare `AF_COLLECTION_PLAN`, a local JSON file, before provider reads. The skill fills this from the selected config, existing inventory and already stated scope; do not ask you to hand-author bookkeeping or re-answer known choices. A small object set uses one bounded batch; only larger sets need repeated batches. The same compact receipts make either path safely resumable. Its
identity expectation comes from your intended account/project/organization or a
known object in that target, never from the response you are about to test.
Inventory input comes from the same target's existing audit; retain its evidence
reference. Without inventory, run the owning audit's bounded alerting inventory
step after its doctor and live-safety gates. Do not repeat the rest of that audit.

Example plan (replace the example scope and absolute epoch window; do not copy
the sample timestamps into a live run):

```json
{
  "schema": "scoutflo-fatigue-collection/v1",
  "run_id": "20261104T100000Z-prometheus-primary",
  "run_date": "2026-11-04",
  "provider": "prometheus",
  "target_label": "primary",
  "identity": {"expected": "cluster-example", "path": ["identity"],
    "query": "up{cluster=\"cluster-example\"}", "label": "cluster"},
  "window": {"start": 1793700000, "end": 1793786400, "description": "24h"},
  "limits": {"batch_size": 10, "max_pages": 20, "page_size": 100},
  "thresholds": {"sample_step_seconds": 30, "chronic_seconds": 86400},
  "objects": [{"job_id": "job-001", "object_id": "CheckoutErrors",
    "object_kind": "prometheus_alert", "source_finding_ids": []}]
}
```

The limits are bounded execution examples, not universal alert policies. Choose
page/window sizes within the provider's published limits and the estate's rate
budget. `sample_step_seconds` sets observational resolution, not completeness;
shorter episodes may be missed. Choose chronic/flapping thresholds from your SLO
and paging policy. Do not infer them from vendor defaults.

Each executable block below resolves its own helper, config and immutable plan.
Set `AF_COLLECTION_PLAN` and `SCOUTFLO_CONFIG` explicitly in each fresh shell;
never depend on an earlier shell's token variables. Dependencies for collection:
POSIX sh, jq, shasum, curl, and the selected provider's CLI only when required.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/alert-fatigue/lib/collection-workflow.sh"
afc_open "${AF_COLLECTION_PLAN:?path to the selected collection plan}"
```

Expected: one selected target and run directory under
`${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/alert-fatigue/runs/<run_id>/`.
`plan.json` and `config.yaml` are immutable metadata snapshots; credential values
are never copied. Reopening the same plan resumes. A changed target, config,
window, limits, identity expectation or object set requires a new run ID and
preserves the old run. A legacy run without a basis cannot be silently reused.

## Doctor gate and live-safety gate

Before **every batch**, source the helper, reopen the plan, and run
`afc_preflight`. It reloads only the selected config's credential names, rejects
named-but-empty credentials, and runs the existing doctor against a private
single-target config. It cannot contact unrelated configured stacks. It never
passes `--slack-test`. Failed, empty or malformed doctor output stops the batch,
removes an earlier identity receipt, and retains its diagnostic directory.

Then execute the owning audit's **complete live-safety/identity block**, not only
its check catalog. Use the selected config snapshot with `SCOUTFLO_TARGET` unset
because that snapshot is one mapping. Pin cloud profile/configuration, account,
project, subscription, region and kube context as that audit requires; never
change shared CLI defaults. Reconcile the observed identity with the intended
identity fixed in the plan. API hostname alone is not tenant proof for shared
SaaS endpoints: use the account/org response or a known scoped object.

| Provider | Existing identity read / expected identity | Authentication for subsequent fixed reads |
| --- | --- | --- |
| AWS | `sts get-caller-identity`; `Account` equals configured `account_id`; explicit configured profile and region | configured AWS credential chain; no ambient fallback |
| Azure | `az account show --subscription ...`; `id` and configured tenant match | existing signed-in read-only identity; explicit subscription |
| GCP | configured CLI identity and `projects describe --project ...`; compare project and intended principal; explicit CLI configuration | same selected configuration; no activation or impersonation change |
| Grafana | GET `/api/org`; intended organization ID | `Authorization: Bearer` with `token_env` |
| Sentry | GET `/api/0/organizations/<configured-org>/`; slug match | `Authorization: Bearer` with `token_env` |
| Datadog | owning audit's validation plus GET the intended known monitor; numeric `id` match | `DD-API-KEY` and `DD-APPLICATION-KEY` |
| PagerDuty | owning audit's abilities check plus GET intended known service; `.service.id` match | `Authorization: Token token=...` |
| Splunk On-Call | owning audit's known-team read; configured team slug match | `X-VO-Api-Id` and `X-VO-Api-Key`; management host only |
| New Relic | owning audit's NerdGraph account query; configured account ID present | `API-Key` with `api_key_env`; query documents only |
| SigNoz / ELK / Groundcover / Zenduty | owning audit's identity and intended known rule, space/backend or team; assert returned ID using the observed deployment's documented shape | owning audit's scheme; SigNoz `SIGNOZ-API-KEY`, ELK `ApiKey`, Groundcover `Bearer`, Zenduty `Token` |
| Prometheus / Alertmanager / LGTM | owning audit's runtime identity plus an explicit known series/target in the intended deployment; example below | configured basic-auth pair, else configured bearer token, else no header for an explicitly unauthenticated endpoint |

A shape not yet verified on the selected deployment cannot mint an identity
receipt. Keep that target blocked, report the failed assertion and use the owning
audit's supported identity route. Do not treat missing identity as “not needed.”
The reference-only incident.io/Opsgenie operations retain their API research but
have no native toolkit config/audit adapter: use separately verified incident
counts via the existing operator input, or a read-only adapter with the same
identity evidence contract. Do not invent auth or silently configure a provider.

Prometheus example: the plan pins a known, unique series selector and label from
your intended deployment. An absent/multiple series or wrong label stops. The
response is held in memory; the saved projection contains only the scope label.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/alert-fatigue/lib/collection-workflow.sh"
afc_open "${AF_COLLECTION_PLAN:?path to the selected collection plan}"
[ "$AFC_PROVIDER" = prometheus ] || { echo 'use the selected provider identity recipe'; exit 1; }
afc_preflight
AFC_URL=$(afc_get url)
AFC_QUERY=$(jq -er '.identity.query | select(type=="string" and length>0)' "$AFC_PLAN")
AFC_LABEL_KEY=$(jq -er '.identity.label | select(type=="string" and length>0)' "$AFC_PLAN")
set -- --fail --silent --show-error --max-time 20 --get
if [ -n "$AFC_BASIC_USER" ]; then set -- "$@" -u "$AFC_BASIC_USER:$AFC_BASIC_PASS"
elif [ -n "$AFC_TOKEN" ]; then set -- "$@" -H "Authorization: Bearer $AFC_TOKEN"; fi
AFC_RESPONSE=$(curl "$@" --data-urlencode "query=$AFC_QUERY" "$AFC_URL/api/v1/query")
printf '%s' "$AFC_RESPONSE" | jq -e --arg label "$AFC_LABEL_KEY" '
  select(.status=="success" and .data.resultType=="vector" and (.data.result|length)==1)
  | {identity:.data.result[0].metric[$label]} | select((.identity|type)=="string" and (.identity|length)>0)
' > "$AFC_RUN/identity-response.json"
afc_verify_identity "$AFC_RUN/identity-response.json"
afc_next
```

Expected: doctor succeeds; expected and observed scope match exactly; at most
`limits.batch_size` pending jobs print. Empty pending output means all jobs have
validated receipts, not that the provider returned no alerts. No history read may
start before this gate. A receipt expires after five minutes; this is a safety
bound for a batch, not an alerting threshold. Refresh it for a long-running batch.

## Claim, read, verify, record

Before each read call `afc_claim <job_id>`: exit 0 grants this session the job;
exit 3 means a verified completed result exists and **must not be read again**;
other nonzero means stop. A per-job lock prevents duplicate parallel reads.
Install a trap to `afc_release` the claim on failure or interruption. The owner PID is recorded; the helper refuses another session’s release. Keep each attempt in its own directory with safe stage/exit diagnostics, so a retry cannot erase a previous failure. Never delete
another session's lock; investigate an abandoned lock and preserve its evidence.

Use only the fixed provider operation from `fire-history-reads.md`, with explicit
window, page size and a bounded page counter. Reload auth with `afc_load_auth` in
the same shell as the request. Repeat the target’s doctor and identity read with
those same loaded credentials for each fresh request block; a prior receipt alone
does not authorize a token that changed since the earlier check. Capture the provider command's exit before jq;
HTTP failure, non-JSON, missing/wrong wrapper, repeated cursor, page cap, scope
mismatch or absent required field keeps the job pending with a safe error record.
Never let an exhausted page budget mean a complete empty history. Save only
redacted, bounded evidence; retain incident text, auth headers, inbound routing
URLs and secret values in neither logs nor raw files.

Normalize one local result per job:

```json
{
  "signal": {"provider": "prometheus", "target": "prometheus/primary",
    "object_id": "CheckoutErrors", "object_kind": "prometheus_alert",
    "source_finding_ids": [], "distinct_active_since_values": 3},
  "proof": {"window": {"start": 1793700000, "end": 1793786400, "description": "24h"},
    "response_assertions_passed": true, "method": "sampled activeAt values while firing",
    "complete_window": false, "count_semantics": "sampled-state-values"}
}
```

`fires` is permitted only for an exhausted, correctly scoped event-history read
with exact event semantics. A sampled state observation has its own field and cannot
populate `fires`. Unknown routing/chronic/off-hours fields stay absent. Attach
source finding IDs only where those findings exist in the selected run.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/alert-fatigue/lib/collection-workflow.sh"
afc_open "${AF_COLLECTION_PLAN:?path to the selected collection plan}"
afc_load_auth
# AF_RESULT is the verified, redacted output of the fixed provider recipe.
afc_complete "${AF_JOB_ID:?selected job}" "${AF_RESULT:?verified result JSON}"
afc_assemble
```

Expected: only validated results gain `complete.json`. Result hashes are checked
before reuse; changed/missing completed evidence stops instead of re-pulling or
silently replacing it. `afc_assemble` refuses unfinished jobs and writes a
per-run `fatigue-signals.json` only after the shared validator passes. Run the
local analysis with `ALERT_FATIGUE_SIGNALS` pointing at that fragment. For several
targets, concatenate their `.signals` and `.provider_coverage` only after asserting
identical run date and window, validate the combined file, then use that file.
Never overwrite a different target's fragment.

A calendar-date change preserves work and receipts but cannot silently relabel
old measurements as current. The existing shared validator may block publication
for the original audit date; retain the run and report the exact date/provenance
conflict. Do not change `generated_at`, discard source IDs or re-pull completed
jobs merely to make a date gate pass. Missing provider permission/unsupported
history is a named `verify-pending` coverage outcome, not a successful zero.
