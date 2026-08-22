---
name: audit-groundcover
description: Read-only scored audit of groundcover monitors and alerting hygiene across per-monitor firing controls (pendingFor, hysteresis resolve threshold, auto-resolve, no-data and execution-error state), notification noise (re-notification interval, status filters, route-bypass), monitor health and silence hygiene, and destination liveness via workflows; writes findings.json and report.md and changes nothing. Use when the user mentions auditing or scoring groundcover, groundcover monitors, groundcover alerts, flapping or no-data groundcover monitors, groundcover notification routes, or groundcover silences. Do not use to change groundcover (no setup-groundcover ships yet; the audit names each fix), or for the underlying metrics/traces/logs data groundcover queries (audit the monitors, not the telemetry).
---

# audit-groundcover

Scored, read-only audit of the groundcover monitors that watch your telemetry: whether each monitor's firing controls are tuned so it does not flap or fire on transient blips, whether its notification settings avoid repeat-page storms and resolve-churn, whether the monitor is actually evaluating rather than paused or silenced, and whether the destinations it routes to are live. It answers one question: when a condition trips in groundcover tonight, does a well-tuned monitor fire once to a reachable destination without drowning the responder in repeats?

This skill audits the groundcover **monitors and alerting layer**, not the metrics, traces, or logs the monitors query. The upstream data quality is out of scope; this audit picks up at the monitor definition.

groundcover's monitors and workflows are built on Keep, which means it is strong on per-monitor firing hygiene but deliberately thin on cross-alert controls: it has **no group-by alert bundling, no inhibition rules, and no native deduplication, throttling, or rate-limiting primitive** (any such logic is hand-coded in Workflow filter blocks). This audit scores what groundcover actually offers and states that ceiling plainly rather than filing findings for controls the platform does not have.

Every command is read-only: a list/read GET, plus two documented read-by-query POSTs (`POST /api/monitors/list` and `POST /api/workflows/list`, which return data and change nothing). Every mutating verb — creating or editing a monitor, silence, route, or workflow — is forbidden; the full list is in [references/groundcover-checks.md](references/groundcover-checks.md) section 13. There is no `setup-groundcover` yet, so every finding names its manual fix path in the groundcover UI instead of a setup anchor.

Run this standalone, from `/scoutflo:audit-all`, or on a schedule via `/scoutflo:schedule-audits`.

Outputs, per the [report standard](../../report-standard/README.md):

- `./scoutflo-audits/groundcover/<YYYY-MM-DD>/findings.json` per the [findings schema](../../report-standard/findings-schema.md), finding IDs `GC-NNN`
- `./scoutflo-audits/groundcover/<YYYY-MM-DD>/report.md` per the [report template](../../report-standard/report-template.md), including the `## Inventory` section (the `render-report-viz.sh inventory` output)
- `./scoutflo-audits/groundcover/<YYYY-MM-DD>/inventory.json` per the [inventory schema](../../report-standard/inventory-schema.md) (`scoutflo-inventory/v1`): the complete Phase-2 catalog — one item per monitor, workflow, and recurring silence (`kind`: `monitor`, `workflow`, `silence`) — each with `kind`, `covers`, `enabled`, `severity`, and `routes_to` for alerting objects. Built from the raw pull, never invented; redacted at capture, never a secret value.
- One appended line in `./scoutflo-audits/groundcover/history.jsonl`
- One Slack brief, when `slack.webhook_env` is configured

## Doctor gate

| Integration | toolkit.yaml keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| groundcover | `groundcover.token_env`, optional `groundcover.backend_id`, `groundcover.api_url` | the variable named by `token_env` (`GROUNDCOVER_API_KEY`) | API key on a **Viewer**-role service account (recipe in `/scoutflo:connect`) | read-only |
| Slack (optional) | `slack.webhook_env` | webhook variable | post to one channel | n/a |

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || { if [ -f "./.scoutflo/toolkit.yaml" ]; then CFG="./.scoutflo/toolkit.yaml"; else CFG="$HOME/.scoutflo/toolkit.yaml"; fi; }
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
# groundcover.token_env names the variable; presence check only, never print the value.
[ -n "${GROUNDCOVER_API_KEY:-}" ] || { echo "GROUNDCOVER_API_KEY is not set; run /scoutflo:connect"; exit 1; }

GC_API="https://api.groundcover.com"   # groundcover.api_url override if set
# There is no whoami endpoint; listing monitors is the auth probe. Add the X-Backend-Id header
# (from groundcover.backend_id) on multi-backend accounts. This POST lists, it does not mutate.
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -H "Authorization: Bearer ${GROUNDCOVER_API_KEY}" -H "Content-Type: application/json" \
  -X POST "${GC_API}/api/monitors/list" --data '{"sources":[]}')"
[ "$CODE" = "200" ] || { echo "monitors/list probe returned ${CODE}: 401 = key invalid; 403 = key lacks Viewer access, or a multi-backend account is missing groundcover.backend_id (X-Backend-Id)"; exit 1; }
echo "doctor gate: pass"
```

Never proceed past a failed doctor check and never downgrade one into a finding. `/scoutflo:doctor` runs the same probe standalone.

Read-only is a real tier here: a Viewer-role service account cannot mutate, so binding the audit key to Viewer makes the read-only guarantee structural, not just convention. If a broader-role key is used the audit still runs, but record in the report that the audit credential can write.

## Live-safety gate

Print what you are pointed at and compare it to the config before the first real check:

```bash
set -eu
GC_API="https://api.groundcover.com"   # groundcover.api_url
# groundcover has no whoami; the account is identified by the monitors the key reads.
MON_SAMPLE="$(curl -fsS --max-time 15 -H "Authorization: Bearer ${GROUNDCOVER_API_KEY}" \
  -H "Content-Type: application/json" -X POST "${GC_API}/api/monitors/list" --data '{"sources":[]}')"
COUNT="$(printf '%s' "$MON_SAMPLE" | jq 'if type=="array" then length else (.monitors // .results // []) | length end')"
TITLES="$(printf '%s' "$MON_SAMPLE" | jq -r 'if type=="array" then . else (.monitors // .results // []) end | [.[0:3][].title] | join(", ")')"
echo "api=${GC_API} monitors=${COUNT} sample: ${TITLES}"
printf '%s' "$MON_SAMPLE" | jq -e 'if type=="array" then . else (.monitors // .results // []) end | type == "array"' >/dev/null \
  || { echo "monitors/list did not return a monitor list; wrong key, host, or backend_id — stop"; exit 1; }
echo "live-safety gate: pass — confirm these monitor titles belong to the account you intend to audit"
```

The key plus the API host (and backend id, if multi-backend) select the target; there is no ambient default. The printed sample monitor titles are the human check: if they belong to a different environment than intended, stop and fix the exported key or `groundcover.backend_id` before any further read.

## Ground rules

- Configuration is metadata; execution state is proof. A monitor that exists is `configured`; a monitor whose config is tuned (a real `pendingFor`, resolve threshold, and re-notification setting) and that is actually evaluating is closer to `validated-live`. Where runtime state is readable (see the capability note below), a monitor observed firing-and-resolving is the strongest signal.
- API errors are evidence. A `401` means the key is invalid; a `403` means the key lacks Viewer access or a multi-backend account is missing `groundcover.backend_id`. Record which, never convert an error into empty success.
- Score what groundcover actually has. It has no group-by bundling, no inhibition, and no native dedup/throttle — those are Keep-hand-coded at best. Never file a finding for a missing control the platform does not offer; state the ceiling instead.
  - ❌ `GC fail: no alert grouping or inhibition configured.`
  - ✅ `Noise ceiling stated: groundcover has no group-by bundling or inhibition (it is built on Keep); this audit scores per-monitor firing hygiene and destination routing, which is what the platform offers.`
- Never score from monitor counts.
  - ❌ `Scored hygiene 90: eighty monitors exist.`
  - ✅ `Scored hygiene 45: sixty monitors evaluate, but forty have pendingFor 0s (fire on the first blip) and twelve set executionErrorState Alerting (broken queries page); credit stops at partial.`
- The runtime monitor-state source (per-monitor firing state, last error, silence flags) is **not confirmed in groundcover's public docs**. This audit probes for it once and, if it is absent or errors, marks the health checks that depend on it `not-in-scope` with that reason rather than guessing a monitor's live state. The config checks never depend on it.
- Silences: groundcover has one-time silences (no list endpoint) and recurring silences (`GET /api/monitors/recurring-silences`). This audit reads recurring silences for open-ended-suppression hygiene and states that one-time silences are not enumerable via the API, so a currently-silenced monitor may not be visible; it never claims a clean silence bill it cannot prove.
- Never write a monitor's raw query, a destination config, or a webhook to disk, evidence, or the report. Captures keep monitor UUIDs, titles, the tuning fields, and workflow/route metadata only.

## Version and shape traps

Current API-shape facts, all handled in the reference commands; do not "simplify" them away:

- **Auth is `Authorization: Bearer <key>` plus `X-Backend-Id` on multi-backend accounts.** A multi-backend account with no backend id 403s; that is a config gap, not an empty account.
- **Listing is a read-by-POST**: `POST /api/monitors/list` with `{"sources":[]}` (empty returns all). There is no whoami and no GET list; the POST is a query, not a mutation.
- **The dedup/grouping controls do not exist.** `category` groups the Monitor List UI only, not notifications. Do not read it as alert bundling.
- **`noDataState` defaults to `NoData` and `executionErrorState` defaults to `OK`.** So a no-data result does not page by default (quiet), but a monitor that sets `executionErrorState: Alerting` pages on its own broken query. Judge each against intent.
- **The runtime monitor-summary endpoint is unconfirmed in public docs.** Treat any per-monitor live state (firing history, last evaluation error, silence flags) as capability-gated: probe once, and if it is not there, the health checks are `not-in-scope`, never a fabricated pass or fail.
- **SaaS vs self-hosted are different API surfaces — detect which you are on.** On SaaS (`api.groundcover.com`) the `/api/monitors/*` paths in this skill are correct. On a **self-hosted** deployment (`api_url` set to any non-`api.groundcover.com` host — often an in-cluster service reached through a proxy) those same paths can `404` even with a valid token, because the self-hosted monitors component does not always expose the cloud monitors API at that base. Verified live (2026-07-26): a self-hosted `host_endpoint` authenticated the token but returned `404` on `/api/monitors/list` and `/api/monitors/summary/query`. When `api_url` is non-cloud and the monitors paths `404` after a `200`-authenticating base, do not report "no monitors": fall back to the **Alertmanager-compatible firing surface** `GET /api/alertmanager/grafana/api/v2/alerts` (the same fallback the platform itself uses for self-hosted Groundcover) for the firing-state signal, and mark the config-level monitor checks (`GC-001` to `GC-023`) `not-in-scope` with the reason "self-hosted monitors API not exposed at this host", never a fabricated pass. State plainly in the report which mode was detected.
- **Recurring silences are a first-class resource** (`GET /api/monitors/recurring-silences`); one-time silences have no list endpoint. There is no Terraform `groundcover_silence` resource, so silences are API/UI state, not declarative IaC.

## Estate sizing

Count before judging, and declare the path in the terminal output. The unit here is monitors:

```bash
set -eu
GC_API="https://api.groundcover.com"   # groundcover.api_url
SMALL_MAX_OBJECTS="30"    # example, tune to your environment
MEDIUM_MAX_OBJECTS="150"  # example, tune to your environment
BATCH_SIZE="50"           # monitors per batch on the large path; example, tune it
MON_JSON="$(curl -fsS --max-time 30 -H "Authorization: Bearer ${GROUNDCOVER_API_KEY}" \
  -H "Content-Type: application/json" -X POST "${GC_API}/api/monitors/list" --data '{"sources":[]}')"
TOTAL="$(printf '%s' "$MON_JSON" | jq 'if type=="array" then length else (.monitors // .results // []) | length end')"
echo "monitors=${TOTAL} scored_objects=${TOTAL}"

# Guided-walkthrough drift check, per report-standard/README.md.
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/groundcover"
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

- **Small** (`TOTAL <= SMALL_MAX_OBJECTS`): one pass over everything. No worklist, no batching.
- **Medium** (`TOTAL <= MEDIUM_MAX_OBJECTS`): per-category passes (firing hygiene, notification noise, health, coverage), completed in one run.
- **Large**: work monitors in batches of `BATCH_SIZE` against a durable, run-ID-keyed worklist per the worklist rules in [skill-authoring-conventions.md](../../docs/skill-authoring-conventions.md): scan for a resumable run before minting a new run ID, one row per monitor uuid, lock before claiming a batch, mark rows done only after their per-monitor reads succeed, and assert zero pending rows before Phase 8 writes anything.

Never silently truncate: name the monitor count audited and any batch skipped, and reflect it in the coverage denominators. Rate limits are not documented, so throttle defensively on the per-monitor read path per [references/groundcover-checks.md](references/groundcover-checks.md) section 9.

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

If `./scoutflo-audits/topology.md` exists, load it; its service list is the critical-service list and its names are canonical. Map monitors to services by the monitor's `labels`/`title` and the k8s fields groundcover monitors carry (namespace, workload). If topology.md does not exist, infer critical services from monitor titles and labels, note the inference, and suggest `/scoutflo:map-topology`.

## Phase 2: Read-only inventory

Build the raw picture with the commands in [references/groundcover-checks.md](references/groundcover-checks.md) section 4: the monitor list, then per monitor the full config (`GET /api/monitors/{uuid}`) capturing the tuning fields; the workflows list (`POST /api/workflows/list`) for destination liveness; and the recurring silences (`GET /api/monitors/recurring-silences`). Probe the runtime monitor-state endpoint once and record whether it is available. Judgment starts in Phase 3. A 403 is an auth/backend note; a 401 is a bad key.

## Phase 3: Monitor firing hygiene (GC-001 to GC-005)

Commands in section 5. These are the per-monitor quality controls, groundcover's real strength. `evaluationInterval.pendingFor` set (not `0s`/empty) so a monitor does not fire on a transient blip (`GC-001`, the equivalent of a missing Prometheus `for`), `model.thresholds.customResolveThreshold` present where a monitor sits near a boundary so it does not flap around a single value (`GC-002`), `autoResolve` true where the condition can clear so issues self-close instead of lingering (`GC-003`), `noDataState` deliberate — the default `NoData` is quiet, but a monitor set to `Alerting` on no-data pages on empty results (`GC-004`, judge against intent), and `executionErrorState` not silently masking broken queries at scale nor set to `Alerting` on a flaky query so the query's own failures page (`GC-005`).

- ❌ `Hygiene pass: monitors have thresholds.`
- ✅ `Hygiene partial: sixty monitors evaluate, but forty have pendingFor 0s (GC-001) and eight set executionErrorState Alerting on queries that error intermittently (GC-005); affected: checkout-latency, payments-error-rate.`

## Phase 4: Notification noise (GC-010 to GC-013)

Commands in section 6. `notificationSettings.renotificationInterval` set to a sane cadence, or `disableRenotification` true, so a long-lived issue does not repeat-page every cycle (`GC-010`), `statusFilters` deliberate — including `Resolved` doubles the message volume, so its presence on high-churn monitors is resolve-noise (`GC-011`), `notificationSettings.method` not `noNotifications` on a monitor that should page, and not `connectedApps` (route-bypass) at scale where notification routes would centralize delivery (`GC-012`), and monitors that name a `method` but resolve to no destination — a monitor that detects but pages nobody (`GC-013`, high).

## Phase 5: Monitor health and silences (GC-020 to GC-023)

Commands in section 7. `isPaused` monitors judged against intent — a paused monitor is defined but never evaluates, so a paused monitor named for a live SLO is a coverage gap (`GC-020`), recurring silences that are open-ended or blanket — a broad matcher on a permanent recurring schedule is a standing blackout (`GC-021`, high), and — **only when the runtime monitor-state endpoint probed available in Phase 2** — monitors stuck permanently firing or in an evaluation-error state (`GC-022`), and monitors fully silenced with no end in sight (`GC-023`). When the runtime endpoint is unavailable, GC-022 and GC-023 are `not-in-scope` with that reason, and the report states that live monitor state could not be read, so one-time-silenced or stuck monitors may not be visible.

## Phase 6: Coverage and destination liveness (GC-030 to GC-032)

Commands in section 8. Workflow-backed destinations live — a workflow with `invalid: true`, a `last_execution_status` of error, or a provider with `installed: false` is a dead delivery path (`GC-030`, high — the monitor fires but the notification cannot be delivered), `severity` set and used rather than every monitor at one level, which defeats prioritized routing (`GC-031`), and critical services from topology each covered by at least one evaluating monitor (`GC-032`, high). Notification-route overlap is best-effort: the routes list has no confirmed REST endpoint and is BYOC-only, so when routes cannot be read the report says so rather than asserting a clean routing bill.

## Phase 7: Coverage matrix and topology readiness

Fill one row per critical service using the per-service mapping in section 10 and the check-result vocabulary (`pass`, `partial`, `fail`, `blocked`, `not-in-scope`):

| Service | Ready | Firing hygiene | Notification | Health | Liveness | Gap |
| --- | --- | --- | --- | --- | --- | --- |

Every cell carries its `passed/total` denominator. Runtime-gated cells read `not-in-scope` when the state endpoint was unavailable, not `fail`. Name affected services in findings.

Then render the Scoutflo Topology Readiness section per [topology-readiness.md](../../report-standard/topology-readiness.md): evaluate the six checks per critical service from `./scoutflo-audits/topology-export.json`, read-only. A `MONITORED_BY` connection to groundcover that this audit verified live (the monitor evaluates and its destination is a live workflow) counts toward Match confidence per the standard's live-verification rule. Gaps that map to an existing finding reference its ID; gaps with no finding get a `TOPO-` row pointing at `/scoutflo:map-topology`. Render check names and confidence per the standard: plain-English column headers, confidence as `n/10`, and — whenever any service is below ready — the ticket-ready readiness action plan table. If the export or topology.md is missing, or exists but describes a different target than this audit covers, the section renders the matching state from topology-readiness.md with its one-line unlock; it never guesses and never says a bare "unavailable". Readiness is reported, never folded into the 0-100 score.

**Provider-identity note, verified against the platform's current model:** `groundcover` is a valid provider identity with a typed attribute schema on the Scoutflo platform (`monitoring.groundcover`), an alerting provider like PagerDuty (a `MONITORED_BY` connection can reach full confidence when its fields are present and this audit verified the path live). Unlike most providers in this toolkit, its schema **requires `namespace` and `workloadName`** (plus optional `serviceName`, `clusterId`, `deploymentName`, `podPattern`, `containerName`), which gives a groundcover connection a strong Kubernetes-anchored identity when those are populated. The identity fields are camelCase (`workloadName`, `serviceName`), and the platform's correlation-category mapping does not split camelCase, so populating only `workloadName`/`serviceName` satisfies Connection details but leaves the Match confidence anchor unpopulated (see [topology-readiness.md](../../report-standard/topology-readiness.md)'s internal note on this exact pattern). Mirror those values into literal `workload_name`/`service_name` keys on the same connection's attributes, or Match confidence reads partial even though the connection genuinely resolved. State which fields the export carries versus which the schema requires when a connection stalls at partial.

## Phase 8: Score, write, brief

Score per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md): each check yields `pass` (1.0), `partial` (0.5), `fail`/`blocked` (0), `not-in-scope` leaves the denominator. Category score is the credit ratio times 100 rounded down; overall is the weight-normalized sum over included categories. Whole categories or checks that could not be assessed (the runtime-state-gated health checks when that endpoint is absent; routes when they cannot be read) are excluded, renormalized, and stated; blocked checks inside an assessable category score 0. Score conservatively: when unsure between two results, pick the lower and say why. Assign each category a maturity value (`reactive`, `proactive`, `systematic`).

| Category | Weight | ID range |
| --- | ---: | --- |
| Monitor firing hygiene | 35 | GC-001 to GC-005 |
| Notification noise | 25 | GC-010 to GC-013 |
| Monitor health and silences | 15 | GC-020 to GC-023 |
| Coverage and destination liveness | 25 | GC-030 to GC-032 |

The full check catalog and the target profile (what 100 means per category) are at the top of [references/groundcover-checks.md](references/groundcover-checks.md). IDs are stable: the same defect gets the same ID every run, one finding per failed check, affected monitors enumerated. Compute `points_recoverable` per finding by re-running the scoring model with that check at full credit; `info` findings and excluded categories carry 0. The executive summary states the gap to target and the two or three findings with the highest `points_recoverable` as the biggest levers.

End-to-end gate: claim end-to-end coverage only when the overall score is at or above 85, every critical service passes every applicable coverage row, and no category was excluded. Below the gate, write "good base coverage", never "end to end". A run whose monitor-health category was runtime-gated out cannot claim end-to-end monitor health; say which categories the claim rests on.

Lifecycle, exemptions, and totals, before rendering the report:

1. Load the previous run's `findings.json` when one exists; classify every finding per the lifecycle table in the [findings schema](../../report-standard/findings-schema.md) (`new`, `unchanged`, `regressed`; resolved IDs go to the delta, and the executive summary names regressions first).
2. Load `./scoutflo-audits/exemptions.yaml` when present. Entries with `id`, `reason`, and `expires` all set and unexpired suppress their finding into the Suppressed appendix; malformed or expired entries are reported, never honored.
3. Every findings area and coverage cell carries its denominator (`passed/total`).

Emit and verify:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/groundcover/${RUN_DATE}"
mkdir -p "$OUT"
# ... write findings.json, inventory.json, and report.md per the report standard, then verify:
jq -e '.schema == "scoutflo-findings/v1" and .target == "groundcover" and (.findings | type == "array")' \
  "$OUT/findings.json" >/dev/null && echo "findings.json valid"
grep -q '^# ' "$OUT/report.md" && echo "report.md present"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-findings.sh" "$OUT/findings.json"
# Inventory (scoutflo-inventory/v1): the complete Phase-2 catalog of what exists,
# built from the raw pull (never invented, redacted). counts.total must reconcile
# with items; the ## Inventory section of report.md IS this render.
jq -e '.schema == "scoutflo-inventory/v1" and .target == "groundcover" and (.items | type == "array") and (.counts.total == (.items | length))' "$OUT/inventory.json" >/dev/null && echo "inventory.json valid"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" inventory "$OUT/inventory.json" >/dev/null && echo "inventory section renders"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" html "$OUT/findings.json" "$OUT/report.html" "$(dirname "$OUT")/history.jsonl"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-report.sh" "$OUT/report.md"
```

Compute the delta against the previous run's `findings.json` (the latest two date directories; first run states "first run, no delta"), then append one line to the history ledger, replacing any line for the same date:

```bash
set -eu
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/groundcover"
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${TARGET_DIR}/${RUN_DATE}"
RESOLVED="0"   # fixed count from this run's delta; 0 on the first run
LINE="$(jq -c --arg d "$RUN_DATE" --argjson resolved "$RESOLVED" \
  '{run_date:$d, skill:"audit-groundcover", overall:.score.overall, gate:.score.gate,
    end_to_end:.score.end_to_end, severity_counts:.severity_counts,
    lifecycle_counts:((reduce .findings[].lifecycle as $l ({}; .[$l] = (.[$l] // 0) + 1)) + {resolved:$resolved})}' \
  "$OUT/findings.json")"
TMP="$(mktemp)"
[ -f "${TARGET_DIR}/history.jsonl" ] && grep -v "\"run_date\":\"${RUN_DATE}\"" "${TARGET_DIR}/history.jsonl" > "$TMP" || true
printf '%s\n' "$LINE" >> "$TMP"
mv "$TMP" "${TARGET_DIR}/history.jsonl"
tail -1 "${TARGET_DIR}/history.jsonl" | jq -e '.run_date and (.overall >= 0)' >/dev/null && echo "history.jsonl updated"
```

The report's trend line renders the last five history.jsonl entries, oldest first. After the report is written, close with the run-completion message per the report standard ([report-template.md](../../report-standard/report-template.md#run-completion-message-what-the-skill-says-in-chat-when-the-run-finishes)): the one-line score headline, the top fixes by points_recoverable, the **absolute** report path, the OS-specific open command, and the leak-safe share pointer (Slack brief). Then send the Slack brief exactly as [report-template.md](../../report-standard/report-template.md) specifies: score, severity counts, top finding titles, delta line, topology readiness line, report path — titles only, never evidence values, monitor titles allowed. When invoked by `audit-all`, skip the brief; the orchestrator sends exactly one combined message per run. Keep `./scoutflo-audits/` out of public version control; reports describe your alerting setup.

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

No `setup-groundcover` ships yet, so every finding's `remediation` field names the concrete manual fix location. When a setup skill lands, these become anchors without the finding IDs changing:

| Finding area | Fix location today |
| --- | --- |
| Fire-on-first-blip, no hysteresis, no auto-resolve (GC-001 to GC-003) | Monitor edit > Evaluation / Thresholds — set `pendingFor`, add a `customResolveThreshold`, enable `autoResolve` |
| No-data and execution-error state (GC-004, GC-005) | Monitor edit > Advanced — set `noDataState`/`executionErrorState` deliberately, not paging on empty or broken queries at scale |
| Repeat-page storms, resolve-noise, route-bypass, no destination (GC-010 to GC-013) | Monitor edit > Notifications — set `renotificationInterval` or `disableRenotification`, trim `statusFilters`, prefer notification routes over `connectedApps`, wire a destination |
| Paused live monitor, open-ended recurring silence (GC-020, GC-021) | Monitor List — unpause the monitor; Silences > Recurring — bound or narrow the recurring silence |
| Stuck-firing / error-state / fully-silenced monitors (GC-022, GC-023) | Monitor details — fix the query or condition; clear the silence (only assessable when the runtime state endpoint is available) |
| Dead workflow destination (GC-030) | Workflows / Integrations > Destinations — reinstall the provider or fix the failing workflow |
| Severity not used, uncovered critical service (GC-031, GC-032) | Set monitor `severity` deliberately; add a monitor for the uncovered service |
| Topology readiness gaps with no finding | `/scoutflo:map-topology` |

## Common Failure Modes

All thresholds and windows named in the checks are example values; tune them to your workloads before treating a miss as a failure.

| Failure | Prevention |
| --- | --- |
| Filing findings for missing grouping/inhibition/dedup | groundcover has none of these (it is built on Keep); state the ceiling, never file a finding for a control the platform lacks |
| Runtime monitor state assumed readable | The monitor-summary endpoint is not confirmed in public docs; probe once, mark GC-022/GC-023 `not-in-scope` if absent, never guess a monitor's live state |
| Multi-backend 403 read as an empty account | A multi-backend account needs `groundcover.backend_id` (the `X-Backend-Id` header); a 403 there is a config gap, not "no monitors" |
| `category` read as alert grouping | `category` groups the Monitor List UI only; it does not bundle notifications |
| No-data default misread | `noDataState` defaults to `NoData` (quiet); the finding is a monitor set to `Alerting` on no-data, not the default |
| One-time silence assumed visible | One-time silences have no list endpoint; the report states a silenced monitor may not be visible rather than claiming a clean silence bill |
| Recurring silence with a broad matcher passed as fine | An open-ended recurring silence with a broad matcher is a standing blackout (GC-021) |
| Monitor count scored as coverage | Count monitors that actually evaluate and route to a live destination, per service |
| `connectedApps` route-bypass ignored at scale | Many monitors bypassing notification routes via `connectedApps` fragments delivery control (GC-012) |
| Dead workflow destination missed | A workflow with `invalid: true` / error status / `installed: false` is a dead delivery path (GC-030); the monitor fires but pages nobody |
| Monitor query or destination config written to evidence | Captures keep UUIDs, titles, tuning fields, and workflow/route metadata only |
| Toolkit brief webhook conflated with groundcover destinations | Two different systems; the Slack brief webhook is the toolkit's own reporting channel |
