---
name: audit-sentry
description: 'Read-only scored audit of your Sentry org: project privacy scrubbing, alert rule tiers and receiver liveness, integrations, releases and source maps, and cron/uptime monitors; writes findings.json and report.md, changes nothing. Use when the user mentions auditing or scoring Sentry, Sentry alert rules or receivers, privacy scrubbing or PII, source maps, release health, or cron/uptime monitors, or asks whether Sentry paging actually works. Do not use for Sentry data in Grafana dashboards (use audit-grafana), for metrics/logs/traces backends (use audit-lgtm), for the Alertmanager paging path (use audit-alert-routing), or to change anything (use setup-sentry).'
---

# Audit Sentry

Score how much your Sentry would actually help during an incident. Inventory the org through the API, then judge live state: does every production project scrub what it should, do alert rules route to receivers that exist, do stack traces resolve to readable source, do monitors reflect real check-ins, and does every critical service have working error tracking? Output is `findings.json` and `report.md` per the [report standard](../../report-standard/README.md), with stable `SNTRY-NNN` finding IDs.

Run it standalone, from `/scoutflo:audit-all`, or on a schedule via `/scoutflo:schedule-audits`.

## Scope and boundaries

This audit owns the Sentry account layer: org and team structure, project inventory and configuration (environments, privacy scrubbing, client-key rate limits, default-rule noise), issue alert rules and their routing against the two-tier model, metric alerts, integration state (Slack, PagerDuty, VCS), release and source-map health signals, and cron and uptime monitors.

- Grafana dashboards that display Sentry data belong to `audit-grafana`.
- Metrics, logs, and traces backends belong to `audit-lgtm`. A backend service absent from Sentry is not automatically a gap when your metrics and logs stack owns backend incidents by decision; record the boundary and score against the owning tool.
- The Alertmanager paging path belongs to `audit-alert-routing`. Here you judge Sentry's own alert wiring and flag unproven routes.
- Every fix points at `setup-sentry`, which also holds SDK instrumentation guidance.

**Read-only, absolutely.** Every call in this audit is a GET; verb and effect align, there are no read-only POSTs in this surface. No test events, no envelope seeding, no test notifications, no rule edits, no state creation of any kind. Even one "test" event mutates the org: it can create issues, seed environments, and page people. Event seeding and delivery tests live in `setup-sentry` behind its confirmation gate.

## Doctor gate

| Integration | Config keys | Env var | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| Sentry | `sentry.host`, `sentry.org`, `sentry.token_env` | named by `sentry.token_env` | `org:read`, `project:read`, `event:read`, `alerts:read`; add `team:read` and `member:read` for ownership checks (token recipes in `/scoutflo:connect`) | read-only |
| Slack (optional) | `slack.webhook_env` | named by `slack.webhook_env` | post to one incoming webhook | optional |

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host: us.sentry.io, de.sentry.io, or your self-hosted host
SENTRY_ORG="your-org-slug"   # sentry.org
API="https://${SENTRY_HOST}/api/0"
# sentry.token_env names the variable; presence check only, never print the value.
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
command -v curl >/dev/null || { echo "curl is required"; exit 1; }
command -v jq   >/dev/null || { echo "jq is required"; exit 1; }

org_tmp="$(mktemp)"
code=$(curl -s -o "${org_tmp}" -w '%{http_code}' --max-time 10 \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" "${API}/organizations/${SENTRY_ORG}/")
echo "org read: ${code}"
jq -e --arg org "${SENTRY_ORG}" '.slug == $org' "${org_tmp}" >/dev/null \
  && jq '{slug, name}' "${org_tmp}" \
  || { echo "doctor gate FAILED (http ${code}); see remediation below"; rm -f "${org_tmp}"; exit 1; }
rm -f "${org_tmp}"
```

Expect: `code` is `200` and the assertion prints `true`, followed by your org's `slug` and `name`. A `401` means the token is wrong for this host. A `404` almost always means the wrong region host, not a missing org: every SaaS org lives in exactly one region and the other region's API returns 404 for it. Run the region probe in `/scoutflo:connect` (Sentry section), fix `sentry.host`, and retry. Either way, stop; never proceed past a failed doctor check, and never downgrade one into a finding. `/scoutflo:doctor` runs the same checks standalone.

If the token also carries write scopes, the audit still runs, but note it in the report: the read-only tier exists so an audit can never mutate, and a scoped-down token is itself part of good posture.

## Live-safety gate

Confirm what you are pointed at before the first real check. Compare the slug printed by the doctor gate against `sentry.org` in `~/.scoutflo/toolkit.yaml`, and confirm the org is the one you intend to audit (not a sandbox org with a similar name, not a personal org). Print the target once: `echo "target: ${API} org: ${SENTRY_ORG}"`. On any mismatch, stop and report it. Never proceed on "probably the right org".

Load `./scoutflo-audits/topology.md` if it exists; its service list is your critical-service list and its names are canonical in findings, the coverage matrix, and `affected` arrays. If it does not exist, infer services from project slugs and platforms, note the inference in the report, and suggest `/scoutflo:map-topology`.

## Ground rules

- Evidence is a re-fetched API response. The Phase 2 raw dump is discovery input; before filing any finding, re-fetch the specific object with a single GET this run and quote that response. Configuration seen only in the dump is `configured`, never `validated-live`.
- API errors are evidence. Record the status code and what it implies; never convert a 403 or 404 into empty success. The workflow-engine endpoints (`/organizations/{org}/detectors/` and `/organizations/{org}/workflows/`) are feature-gated and 404 on many orgs; a 404 there means the feature is absent on that org, not that the org is broken. These endpoints are the new alerting model (detectors = what to detect, workflows = what to do) and their docs are current, but no explicit GA/stability label is published and the classic per-project `rules/` surface still works, so this audit treats them as capability-gated: probe once, act on them if present, fall back to the classic surface if not, never fail an org for their absence.
- Never score from object counts. Fifty projects and two hundred rules prove nothing; credit comes from live state a responder could act on.
  - ❌ `Scored alert rules and routing 90: fifty projects and two hundred rules exist.`
  - ✅ `Scored alert rules and routing 45: rules exist and are tiered, but SNTRY-005 shows every non-email action references a dead or missing integration, so credit stops at partial.`
- Totals come from numeric project IDs and native count or stats endpoints, never from the length of a capped issue list or a text `project:<slug>` search.
- Conservative posture wins ties: privacy-sensitive telemetry without a recorded decision is a finding, email-only routing is a temporary path, a monitor without observed check-ins is unproven.
  - ❌ `Routing validated-live: the rule has a Slack action configured.`
  - ✅ `Routing configured: the Slack action references integration id 42, which is absent from integrations.json; unproven until it appears active (SNTRY-005 partial).`
- Never print, store, or write a DSN, token, webhook URL, or auth header anywhere: not in terminal output, not in the raw dump, not in evidence. The inventory script strips DSNs at capture.

## Estate sizing

Count before judging, and declare the path in the terminal output. This is one cheap paginated listing call per object type, run once, before the per-project loop in Phase 1 that does the real work (four to five calls per project):

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host: us.sentry.io, de.sentry.io, or your self-hosted host
SENTRY_ORG="your-org-slug"   # sentry.org
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

SMALL_MAX_PROJECTS="15"    # single-pass ceiling; example, tune to your environment
MEDIUM_MAX_PROJECTS="60"   # one-run ceiling; example, tune to your environment
BATCH_SIZE="10"            # projects per batch on the large path; example, tune it

fetch_all() { # $1: full API URL. Follows cursor pagination, prints one merged JSON array.
  url="$1"; hdr="$(mktemp)"; acc="$(mktemp)"
  while [ -n "$url" ]; do
    curl -fsS --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" -D "$hdr" "$url" >> "$acc" \
      || { rm -f "$hdr" "$acc"; return 1; }
    printf '\n' >> "$acc"
    url="$(tr -d '\r' < "$hdr" | sed -n 's/.*<\([^>]*\)>; rel="next"; results="true".*/\1/p')"
  done
  jq -s 'add // []' "$acc"; rm -f "$hdr" "$acc"
}

PROJECT_COUNT="$(fetch_all "${API}/organizations/${SENTRY_ORG}/projects/" | jq 'length')"
TEAM_COUNT="$(fetch_all "${API}/organizations/${SENTRY_ORG}/teams/" | jq 'length')"

path="large"
[ "${PROJECT_COUNT}" -le "${MEDIUM_MAX_PROJECTS}" ] && path="medium"
[ "${PROJECT_COUNT}" -le "${SMALL_MAX_PROJECTS}" ] && path="small"
echo "estate: projects=${PROJECT_COUNT} teams=${TEAM_COUNT} sizing-path=${path}"

# Guided-walkthrough drift check, per report-standard/README.md#using-topology-and-prior-runs-as-a-guided-walkthrough:
# compare against the last run rather than a blank slate. State the result in the executive summary;
# never silently omit it. This never skips a live check - every check in later phases still runs fresh.
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry"
PREV_RUN="$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)"
DRIFT="first run"
if [ -n "$PREV_RUN" ] && [ -f "${PREV_RUN}/findings.json" ]; then
  PREV_TOTAL="$(jq -r '.estate.objects // empty' "${PREV_RUN}/findings.json")"
  if [ -n "$PREV_TOTAL" ]; then
    if [ "$PREV_TOTAL" -eq "$PROJECT_COUNT" ]; then
      DRIFT="estate unchanged since ${PREV_RUN##*/} (${PREV_TOTAL} projects then, ${PROJECT_COUNT} now)"
    else
      DRIFT="estate changed since ${PREV_RUN##*/}: ${PREV_TOTAL} -> ${PROJECT_COUNT} projects"
    fi
  else
    DRIFT="previous run recorded no estate data; treating as first run"
  fi
fi
echo "drift: ${DRIFT}"
```

Expect: one line, for example `estate: projects=8 teams=3 sizing-path=small`. Print the chosen path and the counts that drove it; carry the same numbers into `findings.json`'s optional `estate` object (`objects`, `path`).

| Path | When | How Phase 1 behaves |
| --- | --- | --- |
| small | `PROJECT_COUNT <= SMALL_MAX_PROJECTS` | Phase 1 runs exactly as written below: one pass over every project, no worklist file. |
| medium | `PROJECT_COUNT <= MEDIUM_MAX_PROJECTS` | Same single pass over every project, still completed in one run. |
| large | above `MEDIUM_MAX_PROJECTS` | The per-project loop in Phase 1 is replaced by the batched worklist procedure in [references/api-checks.md#large-orgs-worklist-batches-and-resume](references/api-checks.md#large-orgs-worklist-batches-and-resume): bounded batches of `BATCH_SIZE` projects against a durable, resumable worklist. |

Proportionality runs both directions:

- ❌ Built a worklist and ran project batches for an org with six projects.
- ✅ Six projects is under `SMALL_MAX_PROJECTS`; declared the small path and inventoried everything in one pass, no worklist file.

Never silently truncate a large org: if a run judged a subset because it stopped mid-batch, the report names what was skipped and the coverage denominators reflect it.

## Phase 1: Inventory

Paginated GETs only. Sentry paginates with a `Link` header cursor; the `fetch_all` helper follows it (rules in [references/api-checks.md](references/api-checks.md#pagination-and-rate-limits)).

On the small and medium paths, run every command below as written: the org-level fetches, then the per-project loop, in one pass. On the large path, run the org-level fetches below as written (they are cheap, cluster-wide-style calls, never batched), but replace the per-project loop with the batched worklist procedure in [references/api-checks.md#large-orgs-worklist-batches-and-resume](references/api-checks.md#large-orgs-worklist-batches-and-resume); it writes into the same `${RAW_DIR}/projects/<slug>/` layout the loop below produces, so Phases 2 through 8 run unchanged regardless of which path collected the data.

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host: us.sentry.io, de.sentry.io, or your self-hosted host
SENTRY_ORG="your-org-slug"   # sentry.org
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/$(date -u +%Y-%m-%d)/raw"
mkdir -p "${RAW_DIR}/projects"

fetch_all() { # $1: full API URL. Follows cursor pagination, prints one merged JSON array.
  url="$1"; hdr="$(mktemp)"; acc="$(mktemp)"
  while [ -n "$url" ]; do
    curl -fsS --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" -D "$hdr" "$url" >> "$acc" \
      || { rm -f "$hdr" "$acc"; return 1; }
    printf '\n' >> "$acc"
    url="$(tr -d '\r' < "$hdr" | sed -n 's/.*<\([^>]*\)>; rel="next"; results="true".*/\1/p')"
  done
  jq -s 'add // []' "$acc"; rm -f "$hdr" "$acc"
}

fetch_all "${API}/organizations/${SENTRY_ORG}/projects/"      > "${RAW_DIR}/projects.json"
fetch_all "${API}/organizations/${SENTRY_ORG}/teams/"         > "${RAW_DIR}/teams.json"
fetch_all "${API}/organizations/${SENTRY_ORG}/integrations/"  > "${RAW_DIR}/integrations.json"
fetch_all "${API}/organizations/${SENTRY_ORG}/repos/"         > "${RAW_DIR}/repos.json" \
  || echo '[]' > "${RAW_DIR}/repos.json"
fetch_all "${API}/organizations/${SENTRY_ORG}/code-mappings/" > "${RAW_DIR}/code-mappings.json" \
  || echo '[]' > "${RAW_DIR}/code-mappings.json"
fetch_all "${API}/organizations/${SENTRY_ORG}/releases/"      > "${RAW_DIR}/releases.json"
fetch_all "${API}/organizations/${SENTRY_ORG}/monitors/"      > "${RAW_DIR}/monitors.json" \
  || echo '[]' > "${RAW_DIR}/monitors.json"
fetch_all "${API}/organizations/${SENTRY_ORG}/alert-rules/"   > "${RAW_DIR}/metric-alerts.json" \
  || echo '[]' > "${RAW_DIR}/metric-alerts.json"
curl -fsS --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/organizations/${SENTRY_ORG}/" > "${RAW_DIR}/org.json"
# Outcome and per-project volume stats over a recent window (14d is an example, tune it)
curl -fsS --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/organizations/${SENTRY_ORG}/stats_v2/?statsPeriod=14d&interval=1d&field=sum(quantity)&groupBy=category&groupBy=outcome" \
  > "${RAW_DIR}/stats-outcomes.json" || echo '{}' > "${RAW_DIR}/stats-outcomes.json"
curl -fsS --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/organizations/${SENTRY_ORG}/stats_v2/?statsPeriod=14d&interval=1d&field=sum(quantity)&groupBy=project&groupBy=outcome&category=error" \
  > "${RAW_DIR}/stats-projects.json" || echo '{}' > "${RAW_DIR}/stats-projects.json"

# Small and medium paths only: one pass over every project. On the large path,
# stop here and run the batched worklist procedure in
# references/api-checks.md#large-orgs-worklist-batches-and-resume instead; it
# writes the same ${RAW_DIR}/projects/<slug>/ files this loop writes.
for p in $(jq -r '.[].slug' "${RAW_DIR}/projects.json"); do
  d="${RAW_DIR}/projects/${p}"; mkdir -p "$d"
  curl -fsS --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    "${API}/projects/${SENTRY_ORG}/${p}/" > "${d}/detail.json"
  fetch_all "${API}/projects/${SENTRY_ORG}/${p}/rules/"        > "${d}/rules.json"
  fetch_all "${API}/projects/${SENTRY_ORG}/${p}/environments/" > "${d}/environments.json"
  # Keys: keep only name, status, rate limit. Never store DSNs anywhere.
  fetch_all "${API}/projects/${SENTRY_ORG}/${p}/keys/" \
    | jq 'map({name, isActive, rateLimit})' > "${d}/keys.json"
  [ -s "${d}/keys.json" ] || echo '[]' > "${d}/keys.json"
  fetch_all "${API}/projects/${SENTRY_ORG}/${p}/uptime/"       > "${d}/uptime.json" \
    || echo '[]' > "${d}/uptime.json"
done

for f in projects teams integrations releases monitors; do
  jq -r --arg f "$f" '"\($f): \(length)"' "${RAW_DIR}/${f}.json"
done
```

Expected: counts print and the raw dir holds one JSON file per surface plus one directory per project. When an endpoint fails, do not leave a silent `[]`: re-run that single call with `curl -sS -o /dev/null -w '%{http_code}'` and record the status as `blocked` evidence for the checks that needed it. Counts are inventory, not results.

## Phase 2: Project configuration

Checks SNTRY-002, SNTRY-003, SNTRY-004 (snippets in [references/api-checks.md](references/api-checks.md#project-configuration-checks)):

1. **Privacy scrubbing (SNTRY-002).** Org defaults and every production project: data scrubber on, default scrubbers on, a non-empty sensitive-fields list, IP scrubbing deliberate, JavaScript source scraping off unless intentionally required. A production project sending real user traffic with scrubbing off is a high finding; PII that reaches Sentry cannot be unsent.
2. **Client-key rate limits (SNTRY-003).** Every active key on a production project carries a rate limit. An unlimited key means one crash loop or one leaked DSN burns the whole quota and drowns real errors.
3. **Environments (SNTRY-004).** Each active project distinguishes at least a production environment (`ENV_REQUIRED="production"` is the example baseline, tune to your promotion flow). A project with no environments cannot scope alerts or releases to production, so every rule fires on dev noise too.

Default-rule noise is checked with the other rule checks in Phase 3.

## Phase 3: Alert rules and routing

List rules per project via `/projects/{org}/{project}/rules/`. The workflow-engine listing is an optional extra check that tolerates 404 (feature-gated); its absence proves nothing and blocks nothing.

**Workflow-engine orphaned-detector check (SNTRY-015, capability-gated).** On orgs migrated to the workflow-engine model, probe `GET /organizations/{org}/detectors/` once. If it returns 200, this is the new-model equivalent of the classic "alert rule with no notification action": a detector carrying an empty `workflowIds` array detects a condition but is connected to no automation, so it notifies nobody. List every detector where `workflowIds` is `[]` (the linkage is readable both ways — a workflow also carries `detectorIds` — and the list endpoint supports `sortBy=connectedWorkflows`), naming each in `affected`. If the probe 404s, record SNTRY-015 as `not-in-scope` (the org is on the classic model, where SNTRY-001/SNTRY-005 already cover the no-receiver case) — never a fail. Uptime is a detector `type` (`uptime_domain_failure`) in this model, not its own endpoint; do not expect a standalone org uptime API.

Judge the rule set against the two-tier model. The recommended baseline is two tiers, each with its own receiver path (example model; tune families and thresholds to your event volume):

- **Immediate**: fatal events, new unhandled errors, regressions, escalations, user-impact and error-surge thresholds. Routed where your on-call actually looks.
- **Review**: first-seen issues, frequency trends, warning-level signals. Routed to a channel your team reads within working hours.

Checks SNTRY-001, SNTRY-005, SNTRY-011, SNTRY-013, SNTRY-014 (payload details in [references/api-checks.md](references/api-checks.md#alert-rule-checks)):

1. **Default auto-created rule (SNTRY-001).** Projects created without `defaultRules: false` carry an auto-created notify-everyone rule (`createdBy` is null). It pages all members about everything, which trains everyone to ignore Sentry.
2. **Receiver liveness (SNTRY-005).** Cross-check every non-email action against the live integrations list: the referenced integration exists and is `active`, and chat actions carry a channel ID, not just a display name. Rules whose only action is email are `configured`, a temporary path, never a proven paging route. An org where no rule reaches any live receiver escalates this to critical.
3. **Tier coverage (SNTRY-013).** Each production project has at least one immediate-tier and one review-tier rule. Also verify environment scoping: the rule-level `environment` field is the only environment scope; a `latest_adopted_release` filter scopes by release-adoption stage and silently does not mean "production".
4. **Noise posture (SNTRY-014).** Flag every-event conditions with paging actions, re-page frequencies below `FREQ_FLOOR_MIN="30"` minutes (example, tune to your volume), and rules that page on warning-level noise.
5. **Duplicate paths (SNTRY-011).** One primary alerting surface per signal: identical condition sets across rules, issue rules duplicating metric alerts, and Sentry uptime monitors duplicating an external synthetic tool all double-page the same incident.

## Phase 4: Integrations and source context

Checks SNTRY-009 (snippets in [references/api-checks.md](references/api-checks.md#integration-and-source-context-checks)). Inventory integrations by provider and status. Then judge the VCS chain as a chain, not as parts: a repo integration without code mappings resolves nothing; a code mapping whose `defaultBranch` differs from the branch you actually deploy resolves the wrong file; releases with `commitCount: 0` mean suspect commits have no data even though the integration looks connected. Each broken link is the finding; "GitHub is connected" alone earns no credit.

## Phase 5: Releases and source maps

Checks SNTRY-006. Release health signals, judged live:

1. Releases exist and are recent relative to your deploy cadence. An org with instrumented SDKs and an empty release list has no way to answer "did the last deploy cause this".
2. `deployCount` versus `commitCount` per release: deploys without commit association mean CI creates releases but never links commits.
3. Minified frames: sample the latest event of a recent issue in each JavaScript or TypeScript project and inspect in-app frames. Bundled filenames with no source context mean source maps are not resolving, whatever the upload pipeline claims. Command in [references/api-checks.md](references/api-checks.md#releases-and-source-map-checks); requires `event:read`, otherwise record the check `blocked`.

## Phase 6: Cron and uptime monitors

Checks SNTRY-007. From `monitors.json` plus a re-fetch per suspect monitor:

- A monitor in an active state that has never received a check-in is a false-page risk and proves the job is not instrumented; it should be paused or the check-ins shipped.
- A monitor in error or missed state right now is an incident signal: is anyone acting on it?
- Compare the monitor list against the scheduled jobs your team runs (topology.md or your job inventory). Jobs with no monitor are silent-failure candidates; record them in `affected` by job name.
- Uptime monitors: if another tool is your uptime source of truth, Sentry uptime duplicating it belongs under SNTRY-011.

## Phase 7: Volume, quota, and privacy-sensitive ingestion

Checks SNTRY-008 and SNTRY-010, from `stats-outcomes.json`:

1. **Quota pressure (SNTRY-008).** Nonzero `rate_limited`, `cardinality_limited`, or `abuse` outcomes mean events are being dropped right now; a drop share above `DROP_RATIO="0.05"` of accepted volume (example, tune to your quota) is a finding with the numbers as evidence. Dropped fatal events are invisible incidents.
2. **Privacy-sensitive telemetry (SNTRY-010).** Accepted volume in replay, profile, or log categories proves those features are live. Live is not the finding; live without a recorded decision is. Confirm your team has a written masking, consent, and retention decision for each; if none exists, file the finding and point at `setup-sentry#privacy-gates`.

## Phase 7b: Alert hygiene (noise posture)

Phases 3 through 8 prove a page can reach a human and that critical services are covered. This phase asks the opposite: is what reaches on-call tuned, or has Sentry been left on defaults that notify on every trigger, across every environment, on every ingested bot event? Every check re-reads objects the earlier phases already touch — the per-project `rules.json`, the org `metric-alerts.json`, and `stats-outcomes.json` — plus two reads Phase 1 does not do, `/projects/{org}/{project}/filters/` per project and a stats `reason` breakdown. Full commands are in [references/api-checks.md](references/api-checks.md#alert-hygiene-noise-control-checks). Checks SNTRY-101, 102, 103, 104, 105 join the existing Alert rules and routing category: they grow its denominator and do not re-weight it.

Honest ceiling, stated in the report every run:

- These are **structural** noise signals — un-gated rules, all-environment scope, flap-prone metric thresholds, absent ingest filters — not an alert-to-incident actionability rate. This audit has no incident feed, so it never reports a fabricated "N% of alerts are actionable" number; it names which rules and projects are structurally noisy and leaves the volume judgment to the reader.
- Some documented Sentry noise controls are **not cleanly readable** from the SaaS API and are reported as gaps rather than scored as passes. Issue-alert email **digests** are a self-hosted backend setting (`minimum_delay`/`maximum_delay`), invisible to this org-level read; say so and do not infer digest posture from the API. **Spike Protection** exposes no per-project enabled flag on project detail, so SNTRY-104 infers it from stats drop outcomes: a `spike_protection` drop proves it is live, but the absence of drops is inconclusive, never a hard fail.
- Two controls the underlying research surfaces are **already checked and are not re-scored here**: per-rule re-page `frequency` floor is SNTRY-014, and DSN client-key rate limits are SNTRY-003. Folding either again would double-count the same object; reference the existing finding instead.

Checks (payload details in [references/api-checks.md](references/api-checks.md#alert-hygiene-noise-control-checks)):

1. **Un-tuned issue rules (SNTRY-101).** A rule with an action but an empty `filters` array fires on every event its trigger matches, un-gated by issue age, times-seen, level, or assignment. Flag notifying rules whose `filters` is empty; the every-event and re-page-frequency subset is owned by SNTRY-014, so exclude every-event conditions here to avoid double-scoring. `filterMatch` (`all`/`any`/`none`) only matters once filters exist.
2. **All-environment scope (SNTRY-102).** By default an issue rule's `environment` is null and it evaluates across all environments, so dev and staging noise pages the same receivers as production. On a project with more than one environment, a notifying rule with `environment == null` is the finding; a single-environment project passes trivially (nothing to scope). SNTRY-013 owns tier coverage; this owns the distinct noise axis of a rule that fires everywhere.
3. **Flap-prone metric alerts (SNTRY-103).** From `/organizations/{org}/alert-rules/`: `resolveThreshold == null` means the alert relies on the default inverse-of-critical recovery, which flaps near the boundary; a missing `warning` trigger means single-threshold paging with no tiering; a `timeWindow` below `TIMEWINDOW_FLOOR_MIN` ("5" minutes is an example, tune it) on a fixed static threshold fires on transient spikes. `comparisonDelta` (percent-vs-previous mode) or a non-static `detectionType` count as flap resistance. Read the null `resolveThreshold` as the core flap defect; treat the missing warning tier and short window as contributing signals.
4. **Spike Protection posture (SNTRY-104).** Weakest of the five by read, stated plainly. Query stats with a `reason` breakdown for `spike_protection` drops: a nonzero count proves protection is enabled and firing (`pass`). Zero drops is inconclusive on an existing org (there may simply have been no spike) and is not scored as a fail; on a new org, where Spike Protection is OFF by default per project, it is a prompt to confirm enablement in Project Settings, not a proven gap. Spike *notifications* are off by default deliberately and are not a finding.
5. **Inbound Data Filters (SNTRY-105).** From `/projects/{org}/{project}/filters/`: with no inbound filter active, a project ingests known-junk events (web crawlers, browser-extension errors, localhost, legacy browsers) that create issues and feed alert streams. A production project with zero active filters is the finding; filtered events do not consume quota, so this also relieves SNTRY-008 pressure. Some filters carry `active` as a boolean, others (legacy browsers) as a non-empty subfilter array — treat either as active.

Per-project hygiene (SNTRY-101, 102, 105) batches with the same worklist as Phase 1 on the large path; the org-level metric-alert and stats reads (SNTRY-103, 104) are single cheap calls done once per run. A 401, 403, or 404 on any read here blocks its check with the status as evidence; it is never a clean or passing result. Findings point at `setup-sentry` (`setup-sentry#alert-rule-taxonomy` for SNTRY-101, 102, 103; `setup-sentry#privacy-gates` is unrelated — SNTRY-104 and 105 point at `setup-sentry#quota-spike-protection-and-privacy-sensitive-ingestion`).

## Phase 8: Coverage matrix

Judge coverage per critical service from topology.md, using its canonical names. Per service:

1. A Sentry project (or explicit shared-project mapping) owns this service's errors, unless the boundary decision assigns them to the metrics and logs stack; boundary rows are `not-in-scope`, stated.
2. Recent accepted events exist for that project, counted by numeric project ID from `stats-projects.json`. A mapped project with zero accepted events in the window is a dead project (SNTRY-012).
3. Both alert tiers exist for the project and route to a live receiver (from Phase 3 results).
4. An owner exists: the project maps to a team with members, or ownership rules assign issues somewhere real.

One row per service: `Service | Ready | Project | Events | Alert tiers | Receiver | Owner | Gap`, using `pass` / `partial` / `fail` / `blocked` / `not-in-scope`. Name services in findings: "checkout and payments have no error tracking" is a finding, "two services lack coverage" is not. When live discovery contradicts topology.md, propose an update in the report; only the mapping skill and you edit that file.

Then render the Scoutflo Topology Readiness section per [topology-readiness.md](../../report-standard/topology-readiness.md): evaluate T1 to T6 per critical service from `./scoutflo-audits/topology-export.json`, read-only. An edge this audit verified live (for example a `MONITORED_BY` edge to a Sentry project this audit confirmed exists and has recent accepted events in `stats-projects.json`, per the Phase 8 dead-project check) satisfies T4 — Sentry's own schema requires only `project`. **T6 needs more than that**: the platform's actionable-correlation rule requires a `service`-category anchor in addition to the `project`/`environment` anchor Sentry's own required field already gives you, and Sentry's schema field for that is the optional, camelCase `serviceName`, which the platform's category mapping does not split (see [topology-readiness.md](../../report-standard/topology-readiness.md#t6s-category-mapping-is-stricter-than-a-providers-field-names-suggest)). A Sentry edge populated with only the required `project` field satisfies T4 and half of T6's anchor rule, but stays `partial` on T6 until a literal `service` (or `service_name`) key is also present with the service's real name. Gaps that map to an existing finding reference its ID; gaps with no finding get a `TOPO-` row pointing at `/scoutflo:map-topology`. Render check names and confidence per the standard: plain-English column headers (T-codes only in the legend line), confidence as `n/10`, and — whenever any service is below ready — the ticket-ready sync-readiness action plan table from [topology-readiness.md](../../report-standard/topology-readiness.md). If the export or topology.md is missing, or exists but describes a different target than this audit covers (wrong `cluster_id`, non-overlapping services), the section renders the matching state from topology-readiness.md with its one-line unlock (run `/scoutflo:map-topology` against the right estate, or hand-author the export per `scoutflo-export.md` for non-Kubernetes estates); it never guesses and never says a bare "unavailable". Readiness is reported, never folded into the 0-100 score.

## Scoring and outputs

| Category | Weight | Checks |
| --- | ---: | --- |
| Alert rules and routing | 25 | SNTRY-001, 005, 011, 013, 014, 015, 101, 102, 103, 104, 105 |
| Privacy and data protection | 15 | SNTRY-002, 010 |
| Project configuration | 15 | SNTRY-003, 004 |
| Releases and source context | 15 | SNTRY-006, 009 |
| Service coverage | 15 | SNTRY-012 |
| Monitors | 10 | SNTRY-007 |
| Volume and quota | 5 | SNTRY-008 |

Mechanics follow [severity-and-scoring.md](../../report-standard/severity-and-scoring.md). Apply each check across its objects (projects, rules, monitors, services): `pass` when every inspected object passes; `partial` when failures are confined to non-critical objects or the state is present but unproven live; `fail` when a critical service is affected or failure is widespread; `blocked` with the blocker as evidence. Unsure between two results, pick the lower and say why. A whole category blocked (for example, `event:read` missing blocks every release-context check) is excluded from scoring, renormalized, and stated everywhere the score appears.

`findings.json` records the estate-sizing outcome in its optional `estate` object: `objects` (the `PROJECT_COUNT` from the sizing pre-check) and `path` (`small`, `medium`, or `large`). On the large path, if a run stopped with the worklist still holding pending rows, the report and the coverage denominators name the projects that were skipped; never publish a large-path run's findings as complete coverage while `worklist.tsv` still has pending rows.

Write both artifacts to `./scoutflo-audits/sentry/<YYYY-MM-DD>/` and verify:

```bash
set -eu
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/$(date -u +%Y-%m-%d)"
mkdir -p "$OUT"
# ... write findings.json and report.md per the report standard, then verify:
jq -e '.schema == "scoutflo-findings/v1" and (.findings | type == "array")' \
  "$OUT/findings.json" >/dev/null && echo "findings.json valid"
grep -q '^# ' "$OUT/report.md" && echo "report.md present"
# Output conformance: the emitted report.md must match report-standard/report-template.md.
# This catches header/score-line/section drift before the run is declared done.
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-report.sh" "$OUT/report.md"
```

`findings.json` uses prefix `SNTRY`, IDs from the [check catalog](references/api-checks.md#check-catalog), evidence quoting re-fetched API responses, and a `remediation` pointer into `setup-sentry` on every finding. `report.md` follows the [template](../../report-standard/report-template.md): executive summary, scorecard, findings table, the Phase 8 coverage matrix, next safe actions ordered severity-then-safety, delta against the previous run (or "first run, no delta"), evidence appendix. The end-to-end gate is 85 with zero exclusions and every critical service passing every coverage row; below it, write "good base coverage", never "end to end". Keep `./scoutflo-audits/` out of public version control.

After the report is written, close with the run-completion message per the report standard ([report-template.md](../../report-standard/report-template.md#run-completion-message-what-the-skill-says-in-chat-when-the-run-finishes)): the one-line score headline, the top fixes by points_recoverable, the **absolute** report path, the OS-specific open command, and the leak-safe share pointer (Slack brief).

If `slack.webhook_env` is configured, send exactly one brief, titles only, never evidence values:

```bash
set -eu
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/$(date -u +%Y-%m-%d)"
# slack.webhook_env names the webhook variable; skip when unset.
if [ -n "${SCOUTFLO_SLACK_WEBHOOK:-}" ]; then
  OUT_ABS="$(cd "$OUT" && pwd)"   # absolute path: the brief must be openable from anywhere
  SCORE="$(jq -r '.score.overall' "$OUT/findings.json")"
  COUNTS="$(jq -r '.severity_counts | "\(.critical) critical, \(.high) high, \(.medium) medium, \(.low) low"' "$OUT/findings.json")"
  TOP="$(jq -r '[.findings[] | "\(.id) \(.title)"] | .[0:3] | join("\n")' "$OUT/findings.json")"
  jq -n --arg head "audit-sentry $(date -u +%Y-%m-%d): ${SCORE}/100. ${COUNTS}." \
        --arg top "$TOP" --arg path "$OUT_ABS/report.md" \
        '{text: ($head + "\nTop findings:\n" + $top + "\nReport: " + $path)}' \
    | curl -fsS --max-time 10 -H 'Content-Type: application/json' -d @- "$SCOUTFLO_SLACK_WEBHOOK" \
    || echo "Slack brief failed to send; audit result unaffected"
fi
```

When invoked by `audit-all`, skip the Slack brief; the orchestrator
sends exactly one combined message.

To fix what you found, run `setup-sentry` with the finding IDs. To re-check after fixes, run this audit again; the delta computes itself.

### Lifecycle, exemptions, and totals

Before rendering the report:

1. Load the previous run's findings.json when one exists; classify every
   finding per the lifecycle table in report-standard/findings-schema.md
   (`new`, `unchanged`, `regressed`; resolved IDs go to the delta).
2. Load `./scoutflo-audits/exemptions.yaml` when present. Entries with
   `id`, `reason`, and `expires` all set and unexpired suppress their
   finding into the Suppressed appendix; malformed or expired entries are
   reported, never honored.
3. Every findings area and coverage cell carries its denominator
   (`passed/total checks`). The score excludes suppressed findings and
   the scorecard states the suppressed count.

## Metadata Load (v0.1.68+)

This skill reads optional business context metadata to apply intelligent filtering:

```bash
METADATA="${HOME}/.scoutflo/computed_metadata.jsonl"
CONTEXT="${HOME}/.scoutflo/business_context.md"
LOAD_METADATA_MODE="none"

if [ -f "$METADATA" ] && jq -e '.' "$METADATA" >/dev/null 2>&1; then
  LOAD_METADATA_MODE="v0168"
elif [ -f "$CONTEXT" ]; then
  LOAD_METADATA_MODE="v0167"
fi
```

When metadata is available: skip excluded resources, escalate critical services, apply cost sensitivity. See [BUSINESS-CONTEXT-INTEGRATION-v0168.md](../../docs/BUSINESS-CONTEXT-INTEGRATION-v0168.md) for patterns.


## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Region host copied from a docs example, every command 404s | Resolve the host from `sentry.host`; a 404 on the org read means wrong region, run the connect region probe |
| Workflow-engine 404 read as a broken org or blocked check | The endpoint is feature-gated; list `/projects/{p}/rules/` per project and treat the 404 as feature absence |
| Default auto-created rule left paging every member | Detect `createdBy: null` notify rules per project and file SNTRY-001 |
| Email-only routing counted as a working paging path | Classify it `configured`, a temporary path; only a live integration receiver earns credit |
| Environment scoping judged from a release-adoption filter | Rule-level `environment` is the only environment scope; `latest_adopted_release` filters by adoption stage |
| Totals taken from a capped issue list | Use numeric project IDs with stats and count endpoints; a first page is a sample, never a total |
| Rule count scored as alert coverage | Judge tier coverage and receiver liveness per project, not list length |
| DSNs or webhook URLs quoted into evidence | Strip keys to name and rate limit at capture; evidence carries key names and statuses only |
| Active cron monitor with zero check-ins counted as covered | Require an observed `lastCheckIn`; a silent active monitor is a false-page risk finding |
| `deployCount > 0` read as suspect commits working | Check `commitCount` separately; deploys without commit association leave suspect commits empty |
| Replay or log ingestion assumed approved because it works | Accepted volume proves the feature is live; file SNTRY-010 unless a recorded privacy decision exists |
| "Verifying" the pipeline by sending a test event | Audits never send events; envelope seeding and delivery tests live in `setup-sentry` behind confirmation |
| Backend service absence misreported as a Sentry gap | Record the tool ownership boundary first and score the owning stack; `audit-lgtm` covers that side |
| Worklist and batching run on a ten-project org | Size the estate first; at or below `SMALL_MAX_PROJECTS` the small path runs one pass with no worklist file |
| Interrupted large-org run restarted from project one, re-pulling every project | Resume from `worklist.tsv` in the run directory; only pending projects are pulled again |
| A command block copied out of order failed because it assumed a variable from an earlier block | Every block redeclares `SENTRY_HOST`, `SENTRY_ORG`, `API`, and the token check at its own top; none rely on a prior block having run |
| Two invocations of the large path pulled the same batch of projects at once and corrupted the worklist | Acquire `worklist.lock` before claiming a batch; treat a lock older than `LOCK_STALE_MINUTES` as abandoned and reclaim it |
