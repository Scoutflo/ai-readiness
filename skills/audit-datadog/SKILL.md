---
name: audit-datadog
description: Read-only scored audit of Datadog monitor health across notification delivery, monitor noise controls (recovery thresholds, no-data, renotify, auto-resolve), muting and downtimes, SLO and composite coverage, plus a separate non-scored Cost & Resource Optimization section from Datadog's own usage endpoints; writes findings.json and report.md and changes nothing. Use when the user mentions auditing or scoring Datadog, Datadog monitors, monitor noise or flapping, muted or downtimed monitors, dead notification handles, SLO alerting, or Datadog custom-metric cost. Do not use to change Datadog (no setup-datadog ships yet; the audit names each fix), for Datadog data shown in Grafana (use audit-grafana), or for the paging layer downstream of a monitor (use audit-pagerduty).
---

# audit-datadog

Scored, read-only audit of the Datadog monitors that carry your alerting: whether each monitor reaches a live target, whether its noise controls are tuned, whether anything is muted or downtimed into a blind spot, whether SLOs and composite monitors are intact, and — as a separate non-scored section — where Datadog's own usage data says your spend is going. It answers one question: when a metric breaches tonight, does exactly one useful page reach the right team, and is Datadog itself telling you something the config does not?

This skill audits the monitor layer inside Datadog. Whether the page that a monitor sends then reaches a human through PagerDuty is the paging layer's job (`audit-pagerduty`); Datadog data rendered in Grafana dashboards is `audit-grafana`. This audit stops at the monitor and its notification targets.

Every command is read-only: GET on monitors, downtimes, SLOs, integrations, usage, and dashboards. Unlike the PagerDuty audit, Datadog exposes no read-by-effect POST, so every mutating verb — muting, resolving, creating downtimes, test events — is forbidden; the full list is in [references/datadog-checks.md](references/datadog-checks.md) section 13. There is no `setup-datadog` yet, so every finding names its manual fix path instead of a setup anchor.

Run this standalone, from `/scoutflo:audit-all`, or on a schedule via `/scoutflo:schedule-audits`.

Outputs, per the [report standard](../../report-standard/README.md):

- `./scoutflo-audits/datadog/<YYYY-MM-DD>/findings.json` per the [findings schema](../../report-standard/findings-schema.md), finding IDs `DD-NNN` (scored) and `DDOPT-NNN` (non-scored cost)
- `./scoutflo-audits/datadog/<YYYY-MM-DD>/report.md` per the [report template](../../report-standard/report-template.md), including the `## Inventory` section (the `render-report-viz.sh inventory` output)
- `./scoutflo-audits/datadog/<YYYY-MM-DD>/inventory.json` per the [inventory schema](../../report-standard/inventory-schema.md) (`scoutflo-inventory/v1`): the complete Phase-2 catalog — one item per monitor, SLO, and downtime (`kind`: `monitor`, `slo`, `downtime`) — each with `kind`, `covers`, `enabled`, `severity`, and `routes_to` for alerting objects. Built from the raw pull, never invented; redacted at capture, never a secret value.
- One appended line in `./scoutflo-audits/datadog/history.jsonl`
- One Slack brief, when `slack.webhook_env` is configured

## Doctor gate

| Integration | toolkit.yaml keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| Datadog | `datadog.site`, `datadog.api_key_env`, `datadog.app_key_env`, optional `datadog.cost_checks` | the variables named by `api_key_env` (`DATADOG_API_KEY`) and `app_key_env` (`DATADOG_APP_KEY`) | scoped app key: `monitors_read`, `monitors_downtime`, `slos_read`, `events_read` (+ `usage_read`, `billing_read` for the cost section) | read-only |
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
# datadog.api_key_env / app_key_env name the variables; presence check only, never print.
[ -n "${DATADOG_API_KEY:-}" ] || { echo "DATADOG_API_KEY is not set; run /scoutflo:connect"; exit 1; }
[ -n "${DATADOG_APP_KEY:-}" ] || { echo "DATADOG_APP_KEY is not set; both keys are required; run /scoutflo:connect"; exit 1; }

DD_SITE="datadoghq.com"   # datadog.site: e.g. datadoghq.com, us5.datadoghq.com, datadoghq.eu
DD_HOST="api.${DD_SITE}"
VCODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -H "DD-API-KEY: ${DATADOG_API_KEY}" "https://${DD_HOST}/api/v1/validate")"
[ "$VCODE" = "200" ] || { echo "validate returned ${VCODE}: API key invalid or wrong datadog.site (a valid key on the wrong site returns 403)"; exit 1; }
MCODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v1/monitor?page_size=1")"
[ "$MCODE" = "200" ] || { echo "monitor read returned ${MCODE}: app key invalid, missing monitors_read scope, or its user was disabled (app keys are user-bound)"; exit 1; }
echo "doctor gate: pass"
```

Never proceed past a failed doctor check and never downgrade one into a finding. `/scoutflo:doctor` runs the same checks standalone, plus the non-failing cost-permission probe this audit's Cost & Resource Optimization section reads.

Datadog needs a key pair: the API key alone validates identity; the app key plus its scopes authorizes reads. The tier is scope-declared at key creation and cannot be introspected afterward, so if a broader app key is used the audit still runs, but record in the report that the audit credential can do more than read.

## Live-safety gate

Print what you are pointed at and compare it to the config before the first real check:

```bash
set -eu
DD_SITE="datadoghq.com"   # datadog.site
DD_HOST="api.${DD_SITE}"
# There is no org-name whoami on the key pair; identify the org by what it reads and by
# the site it is bound to. A mismatch between the exported keys' site and datadog.site
# surfaces here as a 403 rather than a wrong-account read.
ORG_JSON="$(curl -fsS --max-time 15 \
  -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v1/org" 2>/dev/null || echo '{}')"
ORG_NAME="$(printf '%s' "$ORG_JSON" | jq -r '(.orgs[0].name // "unreadable")')"
MON_SAMPLE="$(curl -fsS --max-time 15 \
  -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v1/monitor?page_size=3")"
NAMES="$(printf '%s' "$MON_SAMPLE" | jq -r '[.[].name] | join(", ")')"
echo "site=${DD_SITE} org=${ORG_NAME} sample_monitors: ${NAMES}"
printf '%s' "$MON_SAMPLE" | jq -e 'type == "array"' >/dev/null \
  || { echo "monitor endpoint did not return a list; wrong site or wrong keys — stop"; exit 1; }
echo "live-safety gate: pass — confirm this org and these monitor names are the account you intend to audit"
```

The key pair and the site together select the account; there is no ambient default. The `/api/v1/org` read is best-effort (some scoped keys cannot read org metadata — an `unreadable` there is fine); the monitor sample names are the human confirmation.

## Ground rules

- Configuration is metadata; observed behavior is proof. A monitor with an `@handle` in its message is `configured`; only a resolved live target (an integration/channel/webhook that exists) makes delivery `validated-live`.
- API errors are evidence. A `403` means the API key is wrong, the site is wrong, or the app key lacks the scope; record which, and never convert an error into empty success. On Datadog specifically, check the site before concluding a scope problem — a valid key on the wrong site returns 403.
- Never score from object counts.
  - ❌ `Scored monitor coverage 90: two hundred monitors exist.`
  - ✅ `Scored monitor coverage 45: two hundred monitors exist, but eleven are drafts, six target a deleted Slack channel, and thirty have no service tag; credit stops at partial.`
- Trust Datadog's own signals, and reconcile them. `GET /api/v1/monitor/search` returns a `quality_issues[]` array on each monitor object (top-level on the monitor, not under `.metadata`; verified live), flagging muted >60 days, missing recipients, stuck in alert, composite missing constituents. Report the vendor's flags alongside this audit's findings; where they disagree about a monitor, the disagreement is itself the finding (DD-015).
- Downtimes are v2 only. Every v1 downtime endpoint is deprecated including its reads; this audit reads `/api/v2/downtime` and never `/api/v1/downtime`.
- Never write a monitor message body verbatim if it embeds a secret-shaped value, and never write API/app keys anywhere. Captures keep IDs, names, options, and tags.

## Estate sizing

Count before judging, and declare the path in the terminal output:

```bash
set -eu
DD_SITE="datadoghq.com"   # datadog.site
DD_HOST="api.${DD_SITE}"
SMALL_MAX_OBJECTS="25"    # example, tune to your environment
MEDIUM_MAX_OBJECTS="150"  # example, tune to your environment
BATCH_SIZE="50"           # monitors per batch on the large path; example, tune it
MON_COUNT="$(curl -fsS --max-time 30 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v1/monitor/search?per_page=1" | jq -r '.metadata.total_count // 0')"
SLO_COUNT="$(curl -fsS --max-time 30 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v1/slo?limit=1" | jq -r '.metadata.pagination.total_count // (.data | length) // 0' 2>/dev/null || echo 0)"
TOTAL="$MON_COUNT"
echo "monitors=${MON_COUNT} slos=${SLO_COUNT} scored_objects=${TOTAL}"

# Guided-walkthrough drift check, per report-standard/README.md: compare against the last run.
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/datadog"
PREV_RUN="$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)"
DRIFT="first run"
if [ -n "$PREV_RUN" ] && [ -f "${PREV_RUN}/findings.json" ]; then
  PREV_TOTAL="$(jq -r '.estate.objects // empty' "${PREV_RUN}/findings.json")"
  if [ -n "$PREV_TOTAL" ]; then
    if [ "$PREV_TOTAL" -eq "$TOTAL" ]; then
      DRIFT="estate unchanged since ${PREV_RUN##*/} (${PREV_TOTAL} monitors then, ${TOTAL} now)"
    else
      DRIFT="estate changed since ${PREV_RUN##*/}: ${PREV_TOTAL} -> ${TOTAL} monitors"
    fi
  else
    DRIFT="previous run recorded no estate data; treating as first run"
  fi
fi
echo "drift: ${DRIFT}"
```

- **Small** (`TOTAL <= SMALL_MAX_OBJECTS`): one pass over everything.
- **Medium** (`TOTAL <= MEDIUM_MAX_OBJECTS`): per-category passes (delivery, noise, muting, coverage), completed in one run.
- **Large**: work monitors in batches of `BATCH_SIZE` against a durable, run-ID-keyed worklist per the worklist rules in [skill-authoring-conventions.md](../../docs/skill-authoring-conventions.md): scan for a resumable run before minting a new run ID, one row per monitor ID, lock before claiming a batch, mark rows done only after their pulls succeed, and assert zero pending rows before Phase 8 writes anything.

Never silently truncate: if the run judged a subset, the report names what was skipped and the coverage denominators reflect it. The rate-limit retry rule in [references/datadog-checks.md](references/datadog-checks.md) section 9 applies to every call.

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

If `./scoutflo-audits/topology.md` exists, load it. Its service list is the critical-service list and its names are canonical; map Datadog monitors to those names by their `service:` tag (fall back to name match, recorded). If it does not exist, infer critical services from monitor `service:` tags, note the inference, and suggest `/scoutflo:map-topology`.

## Phase 2: Read-only inventory

Build the raw picture with the commands in [references/datadog-checks.md](references/datadog-checks.md) section 4: all monitors with messages, options, tags, and state; Datadog's own `quality_issues[]` per monitor; v2 downtimes; and SLOs with their attached monitor IDs. Judgment starts in Phase 3. A 403 on any surface is an auth/scope note attached to the checks that need it, naming the missing scope.

## Phase 3: Monitor delivery (DD-001 to DD-005)

Commands in section 5. Judge whether a monitor reaches a live target: every monitor names at least one `@handle` (`DD-001`, critical when a monitor notifies nobody), no monitor targets a dead handle — a Slack channel, webhook, or PagerDuty service that no longer resolves (`DD-002`, high), no monitor left in `draft` status masquerading as coverage (`DD-003`, high — drafts never notify), org-level notification rules and config policies reviewed where the org uses them (`DD-004`, computing the routing fall-through set), and critical-service monitors carrying a `priority` so paging can be tiered rather than flat (`DD-005`, medium, **verify-pending** — section 5.1). DD-001/DD-002/DD-003 do not stop at a count: each joins the failing monitor to its `service:` tag and criticality so the finding names which service goes blind, and each is one of the suppressors the Phase-6 DD-033 effective-coverage flagship subtracts.

- ❌ `Delivery pass: every monitor has a message.`
- ✅ `Delivery partial: every monitor has a message, but six target @slack-prod-alerts which is not in the Slack integration's channel list (DD-002), and two are drafts (DD-003); affected: checkout, payments.`

## Phase 4: Monitor noise (DD-010 to DD-017)

Commands in section 6. This is the alert-hygiene category. Recovery thresholds where a monitor has warning/critical thresholds and can flap (`DD-010`, joined to the notification handle so the finding names where the flap noise lands), deliberate no-data handling rather than a silent blind spot or a false page (`DD-011`, isolating the dangerous notify_no_data=false heartbeats), bounded renotification instead of forever (`DD-012`), evaluation and new-group delay where the query needs late data (`DD-013`), deliberate auto-resolve per type (`DD-014`), and Datadog's own `quality_issues[]` reviewed and reconciled with this audit (`DD-015`, info).

Two noise checks are **verify-pending** (section 6.1): receiver noise concentration — the real critical-service pages sharing a handle with many flap-prone/renotify-heavy monitors so they are statistically buried (`DD-016`, high, the doctrine's alert-fatigue worked example made executable for Datadog); and monitors stuck in `overall_state == "Alert"` so long they can never re-page a new breach (`DD-017`, medium). DD-016's load-bearing computation is the handle→monitor concentration map plus the DD-010/DD-012 noisy set — no unverified vendor string; the `quality_issues[]` corroboration (high-alert-volume / stuck member strings) is provisional until a live run pins the exact member strings, since only `broken_at_handle` is proven. Never present those regex members as fact.

Honest ceiling, stated in the report every run: monitor options are metadata about intent; whether a monitor actually flapped is visible only in its state history, which this audit samples but does not exhaustively reconstruct. Event Management correlation exists in Datadog but has no public API for its rules, so this audit reports correlation as UI-only and does not score it.

## Phase 5: Muting and downtime (DD-020 to DD-022)

Commands in section 7. Indefinitely muted monitors — a stuck/suppressed alert wearing a mute (`DD-020`, high), no always-on broad-scope downtime masking real alerts (`DD-021`, high — read from `/api/v2/downtime`), and downtimes scoped tightly rather than muting whole environments open-ended (`DD-022`). A tightly scoped recurring maintenance window is healthy; an active downtime with no end and a `*` or `env:prod` scope is a permanent blind spot.

## Phase 6: Coverage and staleness (DD-030 to DD-034)

Commands in section 8. Stale monitors distinguished from dead ones by pairing `last_triggered_ts` with `overall_state` — a monitor stuck in persistent `No Data` because its metric vanished is a silent coverage hole, not a quiet-but-healthy monitor (`DD-030`); composite monitors whose constituent IDs all resolve, naming the service the broken aggregate gates (`DD-031` — a composite referencing a deleted monitor silently misfires); SLOs with an error-budget or burn-rate monitor attached, naming the SLO target/service and reading the trailing SLI-vs-target so the finding states whether the budget is already burning (`DD-032`, high); critical-service **effective** coverage (`DD-033`, the flagship — section 8.1); and monitor tag hygiene computed as routing fall-through against DD-004's rules, not a bare hygiene count (`DD-034`).

**Flagship correlation — the effective-coverage blind-spot cascade (home: DD-033).** No free scanner assembles it, because it requires joining the critical-service→monitor map against every suppression mechanism at once. Per critical service, start from monitors tagged `service:X`, then subtract drafts (DD-003), no-`@handle` (DD-001), dead-handle (DD-002/`broken_at_handle`), indefinitely-silenced (DD-020), monitors whose tags match an active `end=null` downtime's scope (DD-021 tag-join — the single highest-value sub-computation), and heartbeats with `notify_no_data=false` (DD-011). What remains is the count that would actually page a human tonight. The differentiator line — *"service:payments shows 8 monitors in the Datadog UI but 0 that reach a human tonight: 2 drafts, 1 dead Slack handle, 3 under the open-ended env:prod downtime, 2 heartbeats with no-data off"* — is the direct Datadog analog of audit-kubernetes's external→cluster-secrets path: the customer's console shows 8 green monitors and cannot show that the service is effectively unmonitored. Assemble this in Phase 8 as one finding per critical service, ranked by `points_recoverable`, scoring coverage on **effective** (not inventory) monitors.

## Phase 7: Coverage matrix and topology readiness

Fill one row per critical service using the per-service mapping in section 10 and the check-result vocabulary (`pass`, `partial`, `fail`, `blocked`, `not-in-scope`):

| Service | Ready | Delivery | Noise | Muting | Coverage | SLO | Owner | Gap |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |

Every cell carries its `passed/total` denominator. Name affected services in findings.

Then render the Scoutflo Topology Readiness section per [topology-readiness.md](../../report-standard/topology-readiness.md): evaluate the six checks per critical service from `./scoutflo-audits/topology-export.json`, read-only. A `MONITORED_BY` connection to Datadog that this audit verified live (the monitor resolved, names a live target, and covers the service) counts toward Match confidence per the standard's live-verification rule. Gaps that map to an existing finding reference its ID; gaps with no finding get a `TOPO-` row pointing at `/scoutflo:map-topology`. Render check names and confidence per the standard: plain-English column headers, confidence as `n/10`, and — whenever any service is below ready — the ticket-ready readiness action plan table. If the export or topology.md is missing, or exists but describes a different target than this audit covers, the section renders the matching state from topology-readiness.md with its one-line unlock; it never guesses and never says a bare "unavailable". Readiness is reported, never folded into the 0-100 score.

**Provider-identity note, verified against the platform's current model:** `datadog` is a valid provider identity with a typed attribute schema (`monitoring.datadog`) on the Scoutflo platform, so a `MONITORED_BY` connection naming Datadog can reach full confidence. The schema's required field is `monitorId`; its identity fields are camelCase (`serviceName`, `hostname`, `clusterId`), and the platform's correlation-category mapping does not split camelCase — populating only `serviceName` satisfies Connection details but leaves the Match confidence service anchor unpopulated (see [topology-readiness.md](../../report-standard/topology-readiness.md)'s internal note on this pattern). Mirror the `serviceName` value into a literal `service` or `service_name` key on the connection, or Match confidence reads partial even though the connection resolved. State which fields the export carries versus which the schema requires when a connection stalls at partial.

## Phase 8: Score, write, brief

Score per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md): each check yields `pass` (1.0), `partial` (0.5), `fail`/`blocked` (0), `not-in-scope` leaves the denominator. Category score is the credit ratio times 100 rounded down; overall is the weight-normalized sum over included categories. Whole categories that could not be assessed are excluded, renormalized, and stated; blocked checks inside an assessable category score 0. Score conservatively. Assign each category a maturity value (`reactive`, `proactive`, `systematic`).

| Category | Weight | ID range |
| --- | ---: | --- |
| Monitor delivery | 30 | DD-001 to DD-005 |
| Monitor noise | 25 | DD-010 to DD-017 |
| Muting and downtime | 20 | DD-020 to DD-022 |
| Coverage and staleness | 25 | DD-030 to DD-034 |

The three checks added on the v0.1.134 depth pass fold into existing categories (DD-005 into Monitor delivery, DD-016/DD-017 into Monitor noise), so the weights are unchanged and still sum to 100. DD-005/DD-016/DD-017 are **verify-pending**: drafted against Datadog's documented API and adversarially reviewed, but not yet run against a live tenant (there is no Datadog org in the benchmark estate). They score like any other check once a live run confirms them; until then their findings carry the verify-pending caveat and never a fabricated live observation. See [references/datadog-checks.md](references/datadog-checks.md) sections 5.1 and 6.1.

The full check catalog and the target profile (what 100 means per category) are at the top of [references/datadog-checks.md](references/datadog-checks.md). IDs are stable: the same defect gets the same ID every run, one finding per failed check, affected objects enumerated. Compute `points_recoverable` per finding by re-running the scoring model with that check at full credit; `info` findings and excluded categories carry 0. The executive summary states the gap to target and the two or three findings with the highest `points_recoverable` as the biggest levers.

End-to-end gate: claim end-to-end coverage only when the overall score is at or above 85, every critical service passes every applicable coverage row, and no category was excluded. Below the gate, write "good base coverage", never "end to end".

Lifecycle, exemptions, and totals, before rendering the report:

1. Load the previous run's `findings.json` when one exists; classify every finding per the lifecycle table in the [findings schema](../../report-standard/findings-schema.md) (`new`, `unchanged`, `regressed`; resolved IDs go to the delta, and the executive summary names regressions first).
2. Load `./scoutflo-audits/exemptions.yaml` when present. Entries with `id`, `reason`, and `expires` all set and unexpired suppress their finding into the Suppressed appendix; malformed or expired entries are reported, never honored.
3. Every findings area and coverage cell carries its denominator (`passed/total`).

Emit and verify:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/datadog/${RUN_DATE}"
mkdir -p "$OUT"
# ... write findings.json, inventory.json, and report.md per the report standard, then verify:
jq -e '.schema == "scoutflo-findings/v1" and .target == "datadog" and (.findings | type == "array")' \
  "$OUT/findings.json" >/dev/null && echo "findings.json valid"
grep -q '^# ' "$OUT/report.md" && echo "report.md present"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-findings.sh" "$OUT/findings.json"
# Inventory (scoutflo-inventory/v1): the complete Phase-2 catalog of what exists,
# built from the raw pull (never invented, redacted). counts.total must reconcile
# with items; the ## Inventory section of report.md IS this render.
jq -e '.schema == "scoutflo-inventory/v1" and .target == "datadog" and (.items | type == "array") and (.counts.total == (.items | length))' "$OUT/inventory.json" >/dev/null && echo "inventory.json valid"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" inventory "$OUT/inventory.json" >/dev/null && echo "inventory section renders"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" html "$OUT/findings.json" "$OUT/report.html" "$(dirname "$OUT")/history.jsonl"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-report.sh" "$OUT/report.md"
```

Compute the delta against the previous run's `findings.json` (the latest two date directories; first run states "first run, no delta"), then append one line to the history ledger, replacing any line for the same date:

```bash
set -eu
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/datadog"
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${TARGET_DIR}/${RUN_DATE}"
RESOLVED="0"   # fixed count from this run's delta; 0 on the first run
LINE="$(jq -c --arg d "$RUN_DATE" --argjson resolved "$RESOLVED" \
  '{run_date:$d, skill:"audit-datadog", overall:.score.overall, gate:.score.gate,
    end_to_end:.score.end_to_end, severity_counts:.severity_counts,
    lifecycle_counts:((reduce .findings[].lifecycle as $l ({}; .[$l] = (.[$l] // 0) + 1)) + {resolved:$resolved})}' \
  "$OUT/findings.json")"
TMP="$(mktemp)"
[ -f "${TARGET_DIR}/history.jsonl" ] && grep -v "\"run_date\":\"${RUN_DATE}\"" "${TARGET_DIR}/history.jsonl" > "$TMP" || true
printf '%s\n' "$LINE" >> "$TMP"
mv "$TMP" "${TARGET_DIR}/history.jsonl"
tail -1 "${TARGET_DIR}/history.jsonl" | jq -e '.run_date and (.overall >= 0)' >/dev/null && echo "history.jsonl updated"
```

The report's trend line renders the last five history.jsonl entries, oldest first. After the report is written, close with the run-completion message per the report standard ([report-template.md](../../report-standard/report-template.md#run-completion-message-what-the-skill-says-in-chat-when-the-run-finishes)): the one-line score headline, the top fixes by points_recoverable, the **absolute** report path, the OS-specific open command, and the leak-safe share pointer (Slack brief). Then send the Slack brief exactly as [report-template.md](../../report-standard/report-template.md) specifies: score, severity counts, top finding titles, delta line, topology readiness line, report path — titles only, never evidence values. When invoked by `audit-all`, skip the brief; the orchestrator sends exactly one combined message per run. Keep `./scoutflo-audits/` out of public version control; reports describe your monitoring setup.

## Cost & Resource Optimization (non-scored)

This section is reported and never scored, the same pattern `audit-aws` uses. It runs only when the doctor `datadog cost-permissions` row is `pass`; on `skipped` (the app key lacks `usage_read`/`billing_read`, or `datadog.cost_checks` is `false`), the section reports `excluded, reason: <the doctor reason>` and runs no partial checks. Commands in [references/datadog-checks.md](references/datadog-checks.md) section 11. Findings use the `DDOPT-NNN` prefix, always carry `points_recoverable: 0`, never appear in `score.categories` or `score.excluded`, and render under their own heading after Topology Readiness. An `estimated_monthly_cost_usd` field appears only on a finding whose number came straight from Datadog's own usage endpoint; presence facts (a top custom-metric contributor, an unused dashboard) carry no invented dollar figure.


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

No `setup-datadog` ships yet, so every finding's `remediation` field names the concrete manual fix location. When a setup skill lands, these become anchors without the finding IDs changing:

| Finding area | Fix location today |
| --- | --- |
| Monitors with no target or a dead handle (DD-001, DD-002) | Monitor's Notify section — add or repair the `@handle`; fix the Slack/webhook/PagerDuty integration it points at |
| Draft monitors (DD-003) | Monitor edit — publish the draft or delete it |
| Un-prioritized critical-service monitors (DD-005) | Monitor edit — set a `priority` (P1-P5) so the receiver can tier a real page above a warning |
| Missing recovery/no-data/renotify/auto-resolve (DD-010 to DD-014) | Monitor edit > Advanced options — set recovery thresholds, no-data handling, renotify caps |
| Receiver noise concentration (DD-016) | Split the noisy monitors onto a separate ticket/low-urgency route, or tune them (recovery threshold, renotify cap), so the real page is not buried on the shared handle |
| Stuck-in-Alert monitors (DD-017) | Monitor edit > Advanced options — fix the query/thresholds so the monitor can recover and re-alert on a fresh breach |
| Vendor quality issues (DD-015) | Datadog's own Monitor quality view lists each issue with its fix |
| Indefinite mutes and broad downtimes (DD-020 to DD-022) | Monitor > unmute, or Downtimes list — scope and time-bound the downtime |
| Stale, composite-broken, untagged monitors (DD-030, DD-031, DD-034) | Monitor edit — retire stale monitors, repair composite references, add service/team tags |
| SLOs without a monitor (DD-032) | SLO edit — attach or create a burn-rate/error-budget monitor |
| Custom-metric or dashboard cost (DDOPT-NNN) | Metrics Summary and Dashboard list — trim high-cardinality custom metrics and unused dashboards |
| Topology readiness gaps with no finding | `/scoutflo:map-topology` |

## Common Failure Modes

All thresholds and windows named in the checks are example values; tune them to your workloads before treating a miss as a failure.

| Failure | Prevention |
| --- | --- |
| 403 read as a scope problem when it is a wrong-site problem | Check `datadog.site` first; a valid key on the wrong site 403s |
| Auditing with only the API key | Datadog needs the API + app key pair; both headers on every management call |
| v1 downtime endpoint used | v1 downtimes are deprecated including reads; read `/api/v2/downtime` only |
| Draft monitor counted as coverage | Drafts never notify; DD-003 excludes them from the covered set |
| Recovery threshold flagged on a monitor type that has none | Event and composite monitors have no recovery concept; exclude them, do not fail them |
| No-data handling judged by a blanket rule | notify_no_data=false is a blind spot on a heartbeat, correct on a spiky metric; judge by intent |
| Dead-handle check asserted on plain email handles | Resolve integration handles (`@slack-`, `@webhook-`, `@pagerduty-`); mark plain email liveness unverifiable |
| Datadog's own quality_issues ignored | Read `monitor/search` quality_issues; report vendor flags alongside findings, name disagreements |
| Cost section scored into the number | DDOPT findings are non-scored, `points_recoverable: 0`, excluded when the probe is skipped |
| Cost savings invented | Only quote a dollar figure Datadog's usage endpoint computed; presence facts carry no estimate |
| App key created under a personal login | App keys die with their user; create the audit key under a service account |
| Monitor message with a secret written to evidence | Capture IDs, names, options, tags; never a raw message body carrying a secret |
