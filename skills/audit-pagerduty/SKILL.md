---
name: audit-pagerduty
description: Read-only scored audit of PagerDuty paging health across services, escalation policies, on-call schedules, alert grouping and noise controls, incident aging, and a vendor-analytics-backed actionability section (auto-resolved share, MTTA, sleep-hour interruptions); writes findings.json and report.md and changes nothing. Use when the user mentions auditing or scoring PagerDuty, escalation policies, on-call coverage or schedule gaps, alert grouping, unacknowledged incidents, pages nobody takes, or PagerDuty noise. Do not use to change PagerDuty (no setup-pagerduty ships yet; the audit names each fix), for Alertmanager routing (use audit-alert-routing), or for monitoring-tool alert rules (use audit-lgtm, audit-grafana, audit-sentry).
---

# audit-pagerduty

Scored, read-only audit of the PagerDuty account that carries your paging: services and their integrations, escalation policies and on-call schedules, alert grouping and noise controls, incident aging, and — where the account's plan and key allow — the vendor's own analytics on what happened to the pages it sent. It answers one question: when a monitoring tool hands PagerDuty an alert tonight, does a reachable human get paged exactly once, and was that page worth taking?

This skill audits the paging layer, not the monitoring layer. The `for` durations, recovery thresholds, and grouping of the tools that *send* events to PagerDuty belong to their own audits (`audit-lgtm`, `audit-grafana`, `audit-sentry`, `audit-alert-routing`); this audit picks up where an event has already arrived.

Every command is read-only by effect. Almost all are GET. Two documented exceptions are POST requests that read: the Analytics metrics calls (a filter body, server-side aggregation, nothing changes) and the doctor probe of the same surface. Everything else with a mutating verb — acking, snoozing, merging, test events, schedule previews — is forbidden; the full list is in [references/pagerduty-checks.md](references/pagerduty-checks.md) section 13. There is no `setup-pagerduty` yet, so every finding names its manual fix path in the PagerDuty UI or API instead of a setup anchor.

Run this standalone, from `/scoutflo:audit-all`, or on a schedule via `/scoutflo:schedule-audits`.

Outputs, per the [report standard](../../report-standard/README.md):

- `./scoutflo-audits/pagerduty/<YYYY-MM-DD>/findings.json` per the [findings schema](../../report-standard/findings-schema.md), finding IDs `PD-NNN`
- `./scoutflo-audits/pagerduty/<YYYY-MM-DD>/report.md` per the [report template](../../report-standard/report-template.md), including the `## Inventory` section (the `render-report-viz.sh inventory` output)
- `./scoutflo-audits/pagerduty/<YYYY-MM-DD>/inventory.json` per the [inventory schema](../../report-standard/inventory-schema.md) (`scoutflo-inventory/v1`): the complete Phase-2 catalog — one item per service, escalation policy, schedule, integration, and user (`kind` `service`, `escalation_policy`, `schedule`, `integration`, `user`), each with `covers` (the topology service it pages for), `enabled`, `severity` (the object's own, or null), and `routes_to` for alerting objects (a service's escalation policy). Built from the raw pull, never invented; redacted at capture, never a secret value.
- One appended line in `./scoutflo-audits/pagerduty/history.jsonl`
- One Slack brief, when `slack.webhook_env` is configured

## Doctor gate

| Integration | toolkit.yaml keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| PagerDuty | `pagerduty.token_env`, optional `pagerduty.region` | the variable named by `token_env` (`PAGERDUTY_TOKEN`) | General Access REST API key, read-only checkbox ticked (recipe in `/scoutflo:connect`) | read-only |
| Slack (optional) | `slack.webhook_env` | webhook variable | post to one channel | n/a |

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"
[ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done
[ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
if [ ! -f "$CFG" ]; then
  # Multi-environment setup: a customer running prod+nonprod often has no default
  # toolkit.yaml but named variants (toolkit-prod.yaml, toolkit-nonprod.yaml). List
  # them so the choice is directed, not a dead stall — but NEVER auto-pick an
  # environment (auditing the wrong one is worse than asking).
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
# pagerduty.token_env names the variable; presence check only, never print the value.
[ -n "${PAGERDUTY_TOKEN:-}" ] || { echo "PAGERDUTY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

PD_API="https://api.pagerduty.com"   # pagerduty.region: us -> api.pagerduty.com, eu -> api.eu.pagerduty.com
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -H "Authorization: Token token=${PAGERDUTY_TOKEN}" \
  -H "Content-Type: application/json" "${PD_API}/abilities")"
[ "$CODE" = "200" ] || { echo "abilities probe returned ${CODE}: 401 means the key is invalid, revoked, or the region host is wrong (pagerduty.region us vs eu)"; exit 1; }
echo "doctor gate: pass"
```

Never proceed past a failed doctor check and never downgrade one into a finding. `/scoutflo:doctor` runs the same checks standalone, plus the analytics probe this audit's Actionability category depends on (see [Phase 7](#phase-7-actionability-pd-040-to-pd-042)).

The identity probe is `GET /abilities`, deliberately not `/users/me`: account-level API keys are not users, and `/users/me` rejects them by design. A read-only key cannot be scope-introspected either, so the tier is declared, not proven; if only a full-access key is available the audit still runs, but record in the report that the audit credential can write.

## Live-safety gate

Print what you are pointed at and compare it to the config before the first real check:

```bash
set -eu
PD_API="https://api.pagerduty.com"   # pagerduty.region: us -> api.pagerduty.com, eu -> api.eu.pagerduty.com
# PagerDuty account keys have no whoami; the account is identified by what the key reads.
# Resolve one page of services and print account-identifying, non-secret facts.
SVC_SAMPLE="$(curl -fsS --max-time 15 \
  -H "Authorization: Token token=${PAGERDUTY_TOKEN}" \
  -H "Content-Type: application/json" "${PD_API}/services?limit=3")"
COUNT="$(printf '%s' "$SVC_SAMPLE" | jq '.services | length')"
NAMES="$(printf '%s' "$SVC_SAMPLE" | jq -r '[.services[].name] | join(", ")')"
echo "region_host=${PD_API} sample_services=${COUNT}: ${NAMES}"
printf '%s' "$SVC_SAMPLE" | jq -e '.services | type == "array"' >/dev/null \
  || { echo "services endpoint did not return a service list; wrong region host or wrong key — stop"; exit 1; }
echo "live-safety gate: pass — confirm these service names belong to the account you intend to audit before continuing"
```

The key in the environment is the account selector; there is no ambient default beyond it. The printed sample-service names are the human check: if they belong to a different team or account than intended, stop and fix the exported key before any further read.

## Ground rules

- Configuration is metadata; observed behavior is proof. An escalation policy in the list is `configured`; only rendered schedule coverage, a live on-call row, or an analytics-observed acknowledgement makes the paging path `validated-live`.
- API errors are evidence. A `401`, `403`, `404`, or timeout means wrong key, wrong region, or a plan gate. Record the code and what it implies; never convert an error into empty success.
- Plan gates are not misconfigurations. Alert grouping (all four types), Auto-Pause, and advanced Event Orchestration actions require the AIOps add-on; Analytics may be plan-gated too. Probe entitlement first (`GET /services/<id>/enablements`, `GET /abilities`, the doctor analytics row) and report "not available on this plan" as an excluded row with the probe evidence, never as a customer failure.
  - ❌ `PD-020 fail: no alert grouping on any service.`
  - ✅ `PD-020 excluded for this account: the enablements probe warns AIOps is not entitled; grouping cannot be configured on this plan. Noise reduction currently depends entirely on the sending tools' own controls.`
- Never score from object counts.
  - ❌ `Scored escalation 90: eleven escalation policies exist.`
  - ✅ `Scored escalation 45: every service has a policy, but two policies are single-target with no loop, and one references a deleted schedule; credit stops at partial.`
- The auto-resolved share is a measured vendor statistic, never a fabricated actionability rate. `total_incidents_auto_resolved / total_incident_count` from the Analytics API is quotable evidence; an invented "N% of your alerts are actionable" figure is banned, consistent with every other skill in this toolkit.
- Respect the two hard API limits in every claim: incident list queries see at most 6 months back, and Analytics data lags up to 24 hours. Findings that depend on either state the bound.
- Never write a raw integration config, webhook URL, or user contact value to disk, evidence, or the report. Captures keep IDs, types, and names only.

## Version and shape traps

Two current API-shape traps, both handled in the reference commands; do not "simplify" them away:

- **Schedules v3.** Accounts are being upgraded to shift-based schedules (rollout to all accounts announced for Summer 2026). An upgraded schedule returns `400` with `type: schedule_v3` from the classic v2 schedule detail endpoint. On that shape, record the schedule as v3, skip the v2-only coverage read for it, and state in the report that its coverage was judged from the on-calls endpoint instead. Never file a 400-on-v3 as a broken schedule.
- **Rulesets EOL.** Rulesets and Event Rules are vendor-announced end-of-life in favor of Event Orchestration. Their presence is migration debt (PD-014), not a working configuration to score as healthy.

## Estate sizing

Count before judging, and declare the path in the terminal output:

```bash
set -eu
PD_API="https://api.pagerduty.com"   # pagerduty.region
SMALL_MAX_OBJECTS="15"    # example, tune to your environment
MEDIUM_MAX_OBJECTS="60"   # example, tune to your environment
BATCH_SIZE="20"           # services per batch on the large path; example, tune it
pd_count() {
  curl -fsS --max-time 15 -H "Authorization: Token token=${PAGERDUTY_TOKEN}" \
    "${PD_API}${1}?limit=1&total=true" | jq -r '.total // 0'
}
SERVICES="$(pd_count /services)"
POLICIES="$(pd_count /escalation_policies)"
SCHEDULES="$(pd_count /schedules)"
USERS="$(pd_count /users)"
TOTAL=$((SERVICES + POLICIES + SCHEDULES))
echo "services=${SERVICES} escalation_policies=${POLICIES} schedules=${SCHEDULES} users=${USERS} scored_objects=${TOTAL}"

# Guided-walkthrough drift check, per report-standard/README.md: compare against the
# last run rather than a blank slate; state the result in the executive summary.
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/pagerduty"
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

- **Small** (`TOTAL <= SMALL_MAX_OBJECTS`): one pass over everything. No worklist, no batching.
- **Medium** (`TOTAL <= MEDIUM_MAX_OBJECTS`): per-category passes (services, escalation/on-call, noise, incidents), completed in one run.
- **Large**: work services in batches of `BATCH_SIZE` against a durable, run-ID-keyed worklist per the worklist rules in [skill-authoring-conventions.md](../../docs/skill-authoring-conventions.md): scan for a resumable run before minting a new run ID, build one row per service, lock before claiming a batch (stale locks reclaimable after `LOCK_STALE_MINUTES`), mark rows done only after their pulls succeed, and assert zero pending rows before Phase 9 writes anything.

Never silently truncate: if the run judged a subset, the report names what was skipped and the coverage denominators reflect it. The 960 requests/minute rate limit is generous, but the retry rule in [references/pagerduty-checks.md](references/pagerduty-checks.md) section 9 applies to every call.

### Scope checkpoint

On a large estate this audit pauses to let you scope before spending tokens, per the shared [estate-sizing scope checkpoint](../../report-standard/estate-scope-checkpoint.md). After the sizing step above computes the object count, run the shared checkpoint block:

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
  cli_prompt_exclude_services                   # offer service/region exclusions
  echo "[checkpoint] narrow scope any time with /scoutflo:checkpoint; reset with /scoutflo:checkpoint --reset-scope"
fi
```

The large-path phases then run against the scoped set; the report names anything scoped out.

## Phase 1: Service context

If `./scoutflo-audits/topology.md` exists, load it. Its service list is the critical-service list and its names are canonical in findings, the coverage matrix, and `affected` arrays; map PagerDuty services to those names by name match and record unmatched names honestly. If it does not exist, infer critical services from PagerDuty service names and urgency rules, note the inference in the report, and suggest `/scoutflo:map-topology`.

## Phase 2: Read-only inventory

Build the raw picture with the commands in [references/pagerduty-checks.md](references/pagerduty-checks.md) section 4: all services with grouping parameters and integration IDs, escalation policies with rule shapes, schedules, users with contact-method types, priorities, business services, rulesets, and maintenance windows. Judgment starts in Phase 3; inventory records what exists. A 403 on any surface is an auth-scope note attached to the checks that need it.

## Phase 3: Escalation and on-call (PD-001 to PD-007)

Commands in section 5. Judge whether a page reaches a reachable human: every active service has an escalation policy (`PD-001`, critical when missing), no single-point-of-failure policy shape on production services (`PD-002`), loops and final rules are deliberate (`PD-003`), rendered schedule coverage is 100 percent over the audit window (`PD-004` — always pass `since`/`until`; the field is null without them, and v3-upgraded schedules follow the trap rule above), every schedule referenced by a policy resolves and staffs an on-call now (`PD-005`), responders are reachable beyond email alone (`PD-006` — the vendor's own docs rank push as the most reliable channel), and no never-logged-in invitee sits inside an escalation target (`PD-007`).

- ❌ `Escalation pass: every service names a policy.`
- ✅ `Escalation partial: every service names a policy, but checkout's policy is one rule, one user, no loop (PD-002), and the weekend schedule renders 92/100 coverage for the last 14 days (PD-004); affected: checkout, payments.`

## Phase 4: Service hygiene (PD-010 to PD-015)

Commands in section 6. Per active service: at least one integration exists so something can actually page it (`PD-010`), staleness against the no-incident window with the healthy-but-quiet judgment applied (`PD-011`), no service parked in maintenance or disabled status outside a real window (`PD-012`), business-service mapping for the critical services (`PD-013`), rulesets named as migration debt (`PD-014`), and the vendor's own Standards scores read and reconciled — where PagerDuty's native score and this audit disagree about a service, the disagreement itself is the finding (`PD-015`, info).

## Phase 5: Alert grouping and noise (PD-020 to PD-025)

Commands in section 7. This is the alert-hygiene category for the paging layer, and it is entitlement-gated end to end: probe AIOps entitlement before judging. Grouping type and window per production service, across all four types including the newest unified type (`PD-020`), `auto_resolve_timeout` deliberate per service tier (`PD-021` — null is defensible on paging services, debt on intake services), Auto-Pause posture (`PD-022`), Event Orchestration suppress and pause rules reviewed rule by rule for accidental drop-alls (`PD-023`, high — a suppress-all silently deletes alerts before they become incidents), maintenance windows that are permanent mutes in costume (`PD-024`), and whether grouping actually collapses anything, from `alert_counts` on recent incidents (`PD-025`).

Honest ceiling, stated in the report every run: grouping and orchestration configuration is metadata about intent; only the incident-level `alert_counts` and the Analytics category measure whether noise actually reached humans. On accounts without AIOps, the noise levers largely do not exist on this layer, and the report says the sending tools' own hygiene (audited by their own skills) is the whole story.

## Phase 6: Incident health (PD-030 to PD-032)

Commands in section 8. Triggered-and-unacknowledged incidents older than the aging threshold, with the 6-month visibility bound stated (`PD-030`), priorities configured and in real use rather than decoration (`PD-031`), and urgency mapping deliberate — a production service paging low-urgency delivers real incidents as silent notifications (`PD-032`).

## Phase 7: Actionability (PD-040 to PD-042)

Commands in section 10. **Gate first**: this category runs only when the doctor matrix's `pagerduty analytics` row is `pass`. On `skipped` (read-only key rejected the POST, or the plan lacks Analytics), exclude the whole category with the doctor reason and renormalize per the scoring standard — never fabricate and never fail the account for a plan gate.

When it runs, the vendor's own per-service metrics answer the question every other category approximates: the auto-resolved share against the noise threshold (`PD-040` — incidents that opened and closed with no human in the loop), MTTA against target where humans acked (`PD-041`), and sleep-hour interruptions cross-referenced with the auto-resolved share (`PD-042` — waking humans for pages that then resolve themselves is the compound finding). All figures carry the 24-hour data-lag caveat and the analytics window in evidence.

- ❌ `Actionability: roughly 3% of pages appear actionable (industry benchmark).`
- ✅ `PD-040 fail for checkout: 41% of 122 incidents in the last 30 days auto-resolved (50/122, vendor analytics, 24h lag); the pages mostly close themselves, affected: checkout.`

## Phase 8: Coverage matrix and topology readiness

Fill one row per critical service using the per-service mapping in section 11 and the check-result vocabulary (`pass`, `partial`, `fail`, `blocked`, `not-in-scope`):

| Service | Ready | Escalation | On-call | Grouping | Incident health | Actionability | Owner | Gap |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |

Every cell carries its `passed/total` denominator. Plan-gated cells read `not-in-scope` with the entitlement evidence, not `fail`. Name affected services in findings.

Then render the Scoutflo Topology Readiness section per [topology-readiness.md](../../report-standard/topology-readiness.md): evaluate the six checks per critical service from `./scoutflo-audits/topology-export.json`, read-only. A `MONITORED_BY` connection to PagerDuty that this audit verified live (the service resolved, its escalation staffed, and an analytics-observed acknowledgement in the window) counts toward Match confidence per the standard's live-verification rule. Gaps that map to an existing finding reference its ID; gaps with no finding get a `TOPO-` row pointing at `/scoutflo:map-topology`. Render check names and confidence per the standard: plain-English column headers, confidence as `n/10`, and — whenever any service is below ready — the ticket-ready readiness action plan table. If the export or topology.md is missing, or exists but describes a different target than this audit covers, the section renders the matching state from topology-readiness.md with its one-line unlock; it never guesses and never says a bare "unavailable". Readiness is reported, never folded into the 0-100 score.

**Provider-identity caveat, verified against the platform's current model:** `pagerduty` is a valid provider identity with a typed attribute schema on the Scoutflo platform, so — unlike some providers in this toolkit — a `MONITORED_BY` connection naming PagerDuty can genuinely reach full confidence when its fields are present and this audit verified the path live. One trap carries over from the shared standard: the schema's identity fields are camelCase (`serviceName`, `serviceId`, `escalationPolicyId`), and the platform's correlation-category mapping does not split camelCase — populating only `serviceName` satisfies Connection details but leaves the Match confidence service anchor unpopulated (see [topology-readiness.md](../../report-standard/topology-readiness.md)'s internal note on this exact pattern). Mirror the `serviceName` value into a literal `service` or `service_name` key on the same connection's attributes, or Match confidence reads partial even though the connection genuinely resolved. State which fields the export carries versus which the schema requires when a connection stalls at partial.

## Phase 9: Score, write, brief

Score per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md): each check yields `pass` (1.0), `partial` (0.5), `fail`/`blocked` (0), `not-in-scope` leaves the denominator. Category score is the credit ratio times 100 rounded down; overall is the weight-normalized sum over included categories. Whole categories that could not be assessed (Actionability without the analytics probe; grouping checks without AIOps) are excluded, renormalized, and stated; blocked checks inside an assessable category score 0. Score conservatively: when unsure between two results, pick the lower and say why. Assign each category a maturity value (`reactive`, `proactive`, `systematic`) per the shared definitions.

| Category | Weight | ID range |
| --- | ---: | --- |
| Escalation and on-call | 30 | PD-001 to PD-009 |
| Alert grouping and noise | 25 | PD-020 to PD-025 |
| Actionability | 20 | PD-040 to PD-042 |
| Incident health | 15 | PD-030 to PD-032 |
| Service hygiene | 10 | PD-010 to PD-015 |

The full check catalog and the target profile (what 100 means per category) are at the top of [references/pagerduty-checks.md](references/pagerduty-checks.md). IDs are stable: the same defect gets the same ID every run, one finding per failed check, affected objects enumerated. Compute `points_recoverable` per finding by re-running the scoring model with that check at full credit; `info` findings and excluded categories carry 0. The executive summary states the gap to target and the two or three findings with the highest `points_recoverable` as the biggest levers.

End-to-end gate: claim end-to-end coverage only when the overall score is at or above 85, every critical service passes every applicable coverage row, and no category was excluded. Below the gate, write "good base coverage", never "end to end". An account whose Actionability category was plan-excluded cannot claim end-to-end paging health; say which categories the claim rests on.

Lifecycle, exemptions, and totals, before rendering the report:

1. Load the previous run's `findings.json` when one exists; classify every finding per the lifecycle table in the [findings schema](../../report-standard/findings-schema.md) (`new`, `unchanged`, `regressed`; resolved IDs go to the delta, and the executive summary names regressions first).
2. Load `./scoutflo-audits/exemptions.yaml` when present. Entries with `id`, `reason`, and `expires` all set and unexpired suppress their finding into the Suppressed appendix; malformed or expired entries are reported, never honored.
3. Every findings area and coverage cell carries its denominator (`passed/total`).

Emit and verify:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/pagerduty/${RUN_DATE}"
mkdir -p "$OUT"
# ... write findings.json, inventory.json, and report.md per the report standard, then verify:
jq -e '.schema == "scoutflo-findings/v1" and .target == "pagerduty" and (.findings | type == "array")' \
  "$OUT/findings.json" >/dev/null && echo "findings.json valid"
grep -q '^# ' "$OUT/report.md" && echo "report.md present"
# Output conformance: the emitted report.md must match report-standard/report-template.md.
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-findings.sh" "$OUT/findings.json"
# Inventory (scoutflo-inventory/v1): the complete Phase-2 catalog of what exists,
# built from the raw pull (never invented, redacted). counts.total must reconcile
# with items; the ## Inventory section of report.md IS this render.
jq -e '.schema == "scoutflo-inventory/v1" and (.items | type == "array") and (.counts.total == (.items | length))' "$OUT/inventory.json" >/dev/null && echo "inventory.json valid"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" inventory "$OUT/inventory.json" >/dev/null && echo "inventory section renders"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" html "$OUT/findings.json" "$OUT/report.html" "$(dirname "$OUT")/history.jsonl"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-report.sh" "$OUT/report.md"
```

Compute the delta against the previous run's `findings.json` (the latest two date directories; first run states "first run, no delta"), then append one line to the history ledger, replacing any line for the same date:

```bash
set -eu
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/pagerduty"
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${TARGET_DIR}/${RUN_DATE}"
RESOLVED="0"   # fixed count from this run's delta; 0 on the first run
LINE="$(jq -c --arg d "$RUN_DATE" --argjson resolved "$RESOLVED" \
  '{run_date:$d, skill:"audit-pagerduty", overall:.score.overall, gate:.score.gate,
    end_to_end:.score.end_to_end, severity_counts:.severity_counts,
    lifecycle_counts:((reduce .findings[].lifecycle as $l ({}; .[$l] = (.[$l] // 0) + 1)) + {resolved:$resolved})}' \
  "$OUT/findings.json")"
TMP="$(mktemp)"
[ -f "${TARGET_DIR}/history.jsonl" ] && grep -v "\"run_date\":\"${RUN_DATE}\"" "${TARGET_DIR}/history.jsonl" > "$TMP" || true
printf '%s\n' "$LINE" >> "$TMP"
mv "$TMP" "${TARGET_DIR}/history.jsonl"
tail -1 "${TARGET_DIR}/history.jsonl" | jq -e '.run_date and (.overall >= 0)' >/dev/null && echo "history.jsonl updated"
```

The report's trend line renders the last five history.jsonl entries, oldest first. After the report is written, close with the run-completion message per the report standard ([report-template.md](../../report-standard/report-template.md#run-completion-message-what-the-skill-says-in-chat-when-the-run-finishes)): the one-line score headline, the top fixes by points_recoverable, the **absolute** report path, the OS-specific open command, and the leak-safe share pointer (Slack brief). Then send the Slack brief exactly as [report-template.md](../../report-standard/report-template.md) specifies: score, severity counts, top finding titles, delta line, topology readiness line, report path — titles only, never evidence values, service names allowed. When invoked by `audit-all`, skip the brief; the orchestrator sends exactly one combined message per run. Keep `./scoutflo-audits/` out of public version control; reports describe your paging setup.


## Metadata Load (v0.1.68+)

This skill reads the optional business-context SSOT to honor your guardrails:

```bash
set -eu
BC_JSON="${HOME}/.scoutflo/business_context.json"      # derived from business_context.md (the SSOT)
METADATA="${HOME}/.scoutflo/computed_metadata.jsonl"   # per-resource cache from business-context-resolver
LOAD_METADATA_MODE="none"
if [ -f "$METADATA" ] && jq -e '.' "$METADATA" >/dev/null 2>&1; then
  LOAD_METADATA_MODE="per-resource"
elif [ -f "$BC_JSON" ] && jq -e '.' "$BC_JSON" >/dev/null 2>&1; then
  LOAD_METADATA_MODE="workspace"
fi
echo "metadata mode: $LOAD_METADATA_MODE"
```

When context is available, apply it per [BUSINESS-CONTEXT-INTEGRATION-v0168.md](../../docs/BUSINESS-CONTEXT-INTEGRATION-v0168.md): **exclude** resources matched by an exclusion (record them `not-in-scope` with the reason, never a fail); **escalate** findings on a `critical_dependencies` service; reduce severity for a gap that exists only in a non-production `environment`; and apply `cost_sensitivity` to ordering. With no context, run neutral defaults and say so — never invent a business rule.

## Remediation pointers

No `setup-pagerduty` ships yet, so every finding's `remediation` field names the concrete manual fix location instead of a setup anchor. When a setup skill lands, these become anchors without the finding IDs changing:

| Finding area | Fix location today |
| --- | --- |
| Missing or SPOF escalation (PD-001 to PD-003) | PagerDuty UI: People > Escalation Policies — add a second target or loop; API: escalation policy update |
| Schedule gaps, dead references, unstaffed on-call (PD-004, PD-005) | People > Schedules — fill layers or overrides; re-point the policy at a live schedule |
| Email-only or phantom responders (PD-006, PD-007) | Each user's profile > Contact Methods and Notification Rules; remove never-active invitees from targets |
| Delayed first page (PD-008) | Each escalation-target user's profile > Notification Rules — add a 0-minute high-urgency rule on push/phone |
| Single-participant rotation / human SPOF (PD-009) | People > Schedules — add a second participant to the layer, or add a staffed secondary layer/escalation level |
| Orphaned, stale, or parked services (PD-010 to PD-012) | Service Directory — wire an integration, record dormancy, or retire the service |
| Business-service mapping (PD-013) | Service Directory > Business Services — map technical services to the business services they serve |
| Rulesets migration debt (PD-014) | Vendor migration guide: Rulesets to Event Orchestration; migrate rule by rule |
| Grouping, auto-resolve, Auto-Pause, orchestration, maintenance (PD-020 to PD-024) | Per-service Settings > Alert Grouping / Incident Settings; Event Orchestration UI for suppress and pause rules |
| Unacked aging, priorities, urgency (PD-030 to PD-032) | On-call process review plus per-service Incident Settings > Urgency |
| Noisy or slow services per analytics (PD-040 to PD-042) | Fix the sending tool's rule (its own audit names it) or this account's grouping; the analytics section names which service and which lever |
| Topology readiness gaps with no finding | `/scoutflo:map-topology` |

## Common Failure Modes

All thresholds and windows named in the checks are example values; tune them to your workloads before treating a miss as a failure.

| Failure | Prevention |
| --- | --- |
| Grouping absence filed as misconfiguration on a non-AIOps account | Probe entitlement first; plan gates render as excluded rows with evidence, never customer failures |
| Actionability fabricated when Analytics is unavailable | The category runs only on a passing doctor analytics row; otherwise it is excluded with the probe reason |
| `/users/me` used to identify an account key | Account keys are not users; `GET /abilities` is the identity probe for this credential type |
| v3-upgraded schedule filed as broken on a v2 400 | Branch on the `schedule_v3` error type; judge that schedule from on-calls instead |
| Schedule coverage read without `since`/`until` | `rendered_coverage_percentage` is null without an explicit window; always pass one |
| Unacked-incident sweep trusted beyond its window | Incident list queries see at most 6 months; state the bound wherever it applies |
| Analytics treated as real-time | Data lags up to 24 hours; every analytics figure carries the lag caveat |
| Escalation judged by policy count | Judge the shape: single-rule single-target no-loop is a SPOF regardless of how many policies exist |
| Quiet service filed as stale without checking why | Pair last-incident age with integration liveness and alert_creation mode before filing |
| A suppress-all orchestration rule scored as noise reduction | Review suppress conditions rule by rule; an over-broad matcher deletes alerts, it does not tidy them |
| Integration config bodies written into evidence | Captures keep IDs, types, and names only; webhook URLs and configs never leave the API response |
| Toolkit brief webhook conflated with PagerDuty notification channels | Two different systems; the Slack brief webhook is the toolkit's own reporting channel |
