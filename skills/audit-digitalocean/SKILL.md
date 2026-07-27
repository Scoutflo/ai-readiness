---
name: audit-digitalocean
description: Read-only scored audit of DigitalOcean observability across App Platform apps, managed databases, uptime checks, alert policies, Slack and email routing, and log forwarding; writes findings.json and report.md and changes nothing. Use when the user mentions auditing or scoring DigitalOcean, doctl, App Platform alerts or health checks, managed database alert policies, or DO uptime checks. Do not use to change DO resources (use setup-digitalocean), for DOKS cluster telemetry (use audit-lgtm), or for Grafana or Sentry (use audit-grafana, audit-sentry).
---

# audit-digitalocean

Scored, read-only audit of the DigitalOcean surfaces that carry production observability: App Platform apps, managed databases, uptime checks, DO Monitoring alert policies, Slack and email alert routing, and log forwarding. It answers one question: when a DO-hosted service degrades tonight, does an alert fire, reach the right channel, and give the responder enough to act?

Every command in this audit is read-only: `doctl` list and get calls, plus `curl` GET or HEAD probes against public endpoints. Nothing is created, updated, test-fired, or deleted, however small. `doctl apps propose` is a validation-only API call that deploys nothing, but it belongs to the setup lane where specs actually get edited; this audit never calls it. Posting even one test message to a webhook is a mutation; delivery proof lives in `/scoutflo:setup-digitalocean` behind its confirmation gate. The full forbidden-command list is in [references/do-checks.md](references/do-checks.md) section 14.

Out of scope: DigitalOcean Kubernetes (DOKS) cluster telemetry. If your workloads run on DOKS, this audit covers only the DO-level surfaces above; the in-cluster stack belongs to `/scoutflo:audit-lgtm` and its Grafana layer to `/scoutflo:audit-grafana`. The report states this boundary so a green DO score never implies cluster coverage.

Run this standalone, from `/scoutflo:audit-all`, or on a schedule via `/scoutflo:schedule-audits`.

Outputs, per the [report standard](../../report-standard/README.md):

- `./scoutflo-audits/digitalocean/<YYYY-MM-DD>/findings.json` per the [findings schema](../../report-standard/findings-schema.md), finding IDs `DO-NNN`
- `./scoutflo-audits/digitalocean/<YYYY-MM-DD>/report.md` per the [report template](../../report-standard/report-template.md)
- One appended line in `./scoutflo-audits/digitalocean/history.jsonl`
- One Slack brief, when `slack.webhook_env` is configured

## Doctor gate

| Integration | toolkit.yaml keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| DigitalOcean | `digitalocean.token_env`, optional `digitalocean.team` | the variable named by `token_env` (`DIGITALOCEAN_ACCESS_TOKEN`; doctl reads it natively) | custom-scoped API token with read access to apps, databases, monitoring, uptime, and domains (token recipe in `/scoutflo:connect`) | read-only |
| Slack (optional) | `slack.webhook_env` | webhook variable | post to one channel | n/a |

```bash
set -eu
CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
for bin in doctl curl jq; do
  command -v "$bin" >/dev/null || { echo "missing binary: $bin"; exit 1; }
done
# digitalocean.token_env names the variable; presence check only, never print the value.
[ -n "${DIGITALOCEAN_ACCESS_TOKEN:-}" ] || { echo "DIGITALOCEAN_ACCESS_TOKEN is not set; run /scoutflo:connect"; exit 1; }

DOCTL_VERSION="$(doctl version)"
[ -n "${DOCTL_VERSION}" ] || { echo "doctl version printed no output; doctl is broken or not on PATH"; exit 1; }
echo "doctl: ${DOCTL_VERSION}"

ACCOUNT_JSON="$(doctl account get -o json)"
echo "${ACCOUNT_JSON}" | jq -e '(if type=="array" then .[0] else . end) | .status == "active"' >/dev/null \
  && echo "account status: active" \
  || { S="$(echo "${ACCOUNT_JSON}" | jq -r '(if type=="array" then .[0] else . end) | .status')"; \
       echo "account status is '${S}', not active; a 401 upstream means the token is invalid or revoked, an inactive status means the account cannot serve the audit"; exit 1; }
echo "doctor gate: pass"
```

Never proceed past a failed doctor check and never downgrade one into a finding. `/scoutflo:doctor` runs the same checks standalone.

The DigitalOcean API cannot introspect a token's scopes, so the read-only tier is declared, not proven: create a custom-scoped read token for audits (recipe in `/scoutflo:connect`). If only a full-access token is available, the audit still runs, but record in the report that the audit credential can write; a scoped-down token is itself part of good posture.

Troubleshooting, not a rule: if `doctl` times out while `curl` to public sites works, retry the same command once with proxy variables cleared (`env -u HTTPS_PROXY -u https_proxy doctl account get`) before concluding permissions are broken.

## Live-safety gate

Print what you are pointed at and compare it to the config before the first real check:

```bash
set -eu
DO_TEAM="your-team-uuid"   # digitalocean.team; "personal" if the key is absent
ACCOUNT_JSON="$(doctl account get -o json)"
RESOLVED_TEAM="$(echo "${ACCOUNT_JSON}" | jq -r '(if type=="array" then .[0] else . end) | .team.uuid // "personal"')"
RESOLVED_STATUS="$(echo "${ACCOUNT_JSON}" | jq -r '(if type=="array" then .[0] else . end) | .status')"
echo "status=${RESOLVED_STATUS} team=${RESOLVED_TEAM} config_team=${DO_TEAM}"
echo "${ACCOUNT_JSON}" | jq -e --arg team "${DO_TEAM}" \
  '(if type=="array" then .[0] else . end) | (.team.uuid // "personal") == $team' >/dev/null \
  || { echo "resolved team '${RESOLVED_TEAM}' does not match toolkit.yaml digitalocean.team '${DO_TEAM}'; stop, this token points at the wrong account"; exit 1; }
echo "live-safety gate: pass, target confirmed"
```

Never proceed on "probably the right account": the assertion above is what stops the run, not a human comparing two printed lines. doctl reads exactly one token from `DIGITALOCEAN_ACCESS_TOKEN`, so the token in the environment is the target selector; there is no ambient default beyond it.

## Ground rules

- Configuration is metadata; live validation is proof. An alert policy seen in `doctl monitoring alert list` is `configured`; only an observed DO-generated delivery makes routing `validated-live`.
- API errors are evidence. A `401`, `403`, `404`, or timeout means wrong token, wrong team, or a retired resource. Record the code and what it implies; never convert an error into empty success.
- Never score from object counts.
  - ❌ `Scored alert routing 90: eleven alert policies exist across apps and databases.`
  - ✅ `Scored alert routing 45: policies exist and each names a destination, but no delivery was ever observed and two destinations point at a channel nobody reads; credit stops at partial.`
- App Platform alerts and DO Monitoring database policies are separate systems. App alert rules live in the app spec and `doctl apps list-alerts`; database CPU, memory, and disk policies are DO Monitoring policies in `doctl monitoring alert list`. Neither covers the other.
  - ❌ `Databases covered: the app has CPU and memory alerts.`
  - ✅ `App CPU alert present (DO-022 pass); database has no CPU policy in doctl monitoring alert list, so DO-040 fails for db-main.`
- A webhook smoke test is not delivery proof, and this audit does not even run one. Slack incoming webhooks are channel-bound; a payload `channel` override is ignored, so a `200 ok` proves acceptance by whatever channel the webhook was installed in, nothing more.
  - ❌ `Routing validated-live: the webhook returned ok last month.`
  - ✅ `Routing configured: destinations exist; no DO-generated event was observed reaching the channel this run (DO-004 partial, remediation setup-digitalocean#prove-alert-delivery).`
- Never write a raw app spec to disk, evidence, or the report. Specs carry env values, keys, and webhook URLs. Capture env key names and types only, per the redaction procedure in [references/do-checks.md](references/do-checks.md) section 7. Alert-policy JSON includes Slack webhook URLs; strip them at capture.
- Label every recommendation with its change-risk class (next section) so "Next safe actions" never hides a redeploy behind a "monitoring tweak".

## The four change-risk classes

Every fix this audit recommends carries one of four classes. The classification is the single most load-bearing judgment in the DO domain because of one trap: **most App Platform "observability" settings live in the app spec, and updating the spec triggers a new deployment.** Adding a health check, an alert rule, or a log destination can rebuild and redeploy the app, and a private build failure can take it down.

| Class | Examples | Rule |
| --- | --- | --- |
| Read-only | `doctl` list/get, curl GET/HEAD probes | The only class allowed in this audit. |
| Non-disruptive write | Create an uptime check for a verified target, update alert-policy destinations, update existing app alert destinations | No redeploy, but can create noise. Setup lane, confirmation-gated. |
| Controlled rollout | Any app spec change: health checks, alert rules, log destinations, env vars | Triggers a deployment. Setup lane: snapshot, validate, one app at a time. |
| Traffic-impacting | Autoscaling, instance counts, DB resize or standby, DB firewall, DNS or domain changes | Outside the setup skill's write scope; it records a plan with an owner instead. |

- ❌ `Recommend: add a health check to checkout-api (low risk, config only).`
- ✅ `Recommend: add a health check to checkout-api (controlled rollout: spec edit triggers a redeploy; setup-digitalocean#harden-health-checks snapshots the spec and rolls one app at a time).`

## Estate sizing

Count before judging, and declare the path in the terminal output:

```bash
set -eu
SMALL_MAX_OBJECTS="10"    # example, tune to your environment
MEDIUM_MAX_OBJECTS="40"   # example, tune to your environment
BATCH_SIZE="10"           # apps per batch on the large path; example, tune it
APPS="$(doctl apps list -o json | jq 'length')"
DBS="$(doctl databases list -o json | jq 'length')"
CHECKS="$(doctl monitoring uptime list -o json | jq 'length')"
POLICIES="$(doctl monitoring alert list -o json | jq 'length')"
TOTAL=$((APPS + DBS + CHECKS))
echo "apps=${APPS} dbs=${DBS} uptime_checks=${CHECKS} alert_policies=${POLICIES} scored_objects=${TOTAL}"

# Guided-walkthrough drift check, per report-standard/README.md#using-topology-and-prior-runs-as-a-guided-walkthrough:
# compare against the last run rather than a blank slate. State the result in the executive summary;
# never silently omit it. This never skips a live check - every check in later phases still runs fresh.
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean"
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

- **Small** (`TOTAL <= SMALL_MAX_OBJECTS`): one pass over everything. No worklist, no batching; three apps do not need bookkeeping.
- **Medium** (`TOTAL <= MEDIUM_MAX_OBJECTS`): per-category passes (apps, databases, uptime, routing), completed in one run.
- **Large**: work apps in batches of `BATCH_SIZE` against a durable, run-ID-keyed worklist, per [Large-path worklist: apps in batches](#large-path-worklist-apps-in-batches) below.

Never silently truncate: if the run judged a subset, the report names what was skipped and the coverage denominators reflect it.

## Phase 1: Service context

If `./scoutflo-audits/topology.md` exists, load it. Its service list is the critical-service list and its names are canonical in findings, the coverage matrix, and `affected` arrays; map App Platform apps and components to those names. If it does not exist, infer services from app and component names, note the inference in the report, and suggest `/scoutflo:map-topology`. If live discovery contradicts topology.md, record the discrepancy; only the mapping skill and you edit that file.

## Phase 2: Read-only inventory

Build the raw picture with the commands in [references/do-checks.md](references/do-checks.md) section 4: apps with active and in-progress deployment IDs, per-app alert lists, spec-derived alert/health/log settings (redacted at capture), databases with engine, nodes, backups, firewalls, and logsinks, uptime checks with their alert rules, DO Monitoring policies grouped by entity and metric, and the live HTTP status of each candidate public endpoint. Judgment starts in Phase 4; inventory records what exists.

## Phase 3: Alert routing (DO-001 to DO-005)

Commands in [references/do-checks.md](references/do-checks.md) section 5. Judge whether an alert that fires reaches a human: any destination at all (`DO-001`, critical when none exists anywhere), every enabled policy and app alert has at least one destination (`DO-002`), destinations map to the right team and environment channel with the channel-binding caveat recorded (`DO-003`), delivery proven by an observed DO-generated event rather than assumed (`DO-004`, capped at `configured` without one), and alert text tells the responder what to capture where the surface supports custom descriptions (`DO-005`).

Keep the toolkit's own Slack brief webhook (`slack.webhook_env`) strictly apart from the DO alert destinations under audit. They are different webhooks with different jobs; flag any destination that appears to be the toolkit reporting webhook.

### Alert hygiene (DO-070 to DO-072)

Phase 3 proves an alert that fires can reach a human. These three checks fold into the same **Alert routing and delivery** category and ask the opposite: is what reaches them tunable and free of self-inflicted noise, or has the policy set become churn? Every check is read-only and reuses the redacted `alert-policies.json` capture from the Phase 2 inventory (section 4); no new API surface is touched. Commands in [references/do-checks.md](references/do-checks.md) section 15.

Honest ceiling, stated in the report every run: DO Monitoring is a genuinely thin noise surface, and these checks are deliberately thin because of it. DO Monitoring has no real flapping suppression, resolve-hold, or hysteresis; no alert grouping, deduplication, or inhibition; no timed muting of any kind (no silences, snooze, maintenance windows, or time-of-day mutes); no suppressible resolve notification; and no multi-tier severity in a single policy. There is nothing to read for those controls because they do not exist on the platform, so this phase never scores them and never fabricates an alert-to-incident "N% actionable" rate. It reports three **structural** signals the API does expose. Say plainly which controls are simply absent rather than marking them fail; an absent capability is a platform ceiling, not a customer misconfiguration. This is consistent with the DO provider-enum gap already documented in Phase 9.

Checks:

- **DO-070 (dwell window).** The fixed duration `window` (enum `5m|10m|30m|1h`) is the *only* built-in spike or flap damper DO offers: a metric must stay across the threshold for the whole window before the policy fires. The API/doctl default is `5m`, the shortest and noisiest choice. Flag every enabled policy pinned at `SHORT_WINDOW` (example `5m`, tune it) without a documented reason. This same short-window flag is also the closest read-only predictor of resolve-notification churn: DO sends a fire notification and a clear notification per incident, the pair is fixed with no off switch, and a short window on a boundary-hugging threshold roughly doubles volume through repeated fire/clear. There is no per-policy resolve field to inspect, so DO-070's short-window signal is the only lever a responder can act on; say so rather than implying a resolve toggle exists.
- **DO-071 (permanent mute).** DO's only mute is all-or-nothing: a policy is fully enabled or fully disabled, with no timed silence, snooze, or maintenance window. A long-lived `enabled:false` policy is therefore a permanent coverage gap until someone remembers to re-enable it, not managed noise. Flag every disabled policy for a mute-state review. The list API carries no created/updated timestamp, so "long-lived" cannot be proven from this read; state that limit in the finding instead of implying the policy is fresh or stale.
- **DO-072 (duplicate coverage).** Tag scoping (`tags[]`) is the closest thing DO has to grouping: one tag-scoped policy covers a whole fleet as a single rule instead of N per-entity copies. It does not group or dedupe the resulting notifications (each breaching entity still alerts on its own), but it does collapse duplicate *rules*. Flag groups of enabled policies that share the same `type`, `compare`, `value`, and `window`, each scoped to a single entity with no tags, as candidates to collapse into one tag-scoped policy. Threshold quality itself (50-percent-style pages, generic-plus-named duplicates on the same entity and metric) is already scored by DO-043 in the Managed databases category; DO-072 is the fleet-shape duplicate, not the threshold-value duplicate, and the two never double-count.

All three reads are single cheap `jq` passes over the existing inventory, done once per run; they do not batch per app on the large path. As everywhere in this audit, a `401`/`403` while refreshing the policy list is an auth-scope finding that blocks these checks, never a clean or passing result.

## Phase 4: Uptime and availability (DO-010 to DO-015)

Commands in section 6. Every active public hostname has an uptime check (`DO-010`); each check carries a down alert (`DO-011`), a latency alert (`DO-012`), and an SSL-expiry alert (`DO-013`); multi-region checks where a single region would mask regional failure (`DO-014`); and no check monitors a dead, archived, or migrated target (`DO-015`). Probe every check target live and capture the status code as evidence.

- ❌ `Uptime pass: a check exists for the storefront hostname.`
- ✅ `Uptime partial: the check exists but has no SSL-expiry alert (DO-013), and the target answered 404 this run, which makes it a noise source (DO-015), affected: storefront.`

## Phase 5: App Platform coverage (DO-020 to DO-033)

Commands in section 7. Per active app: deployment lifecycle alerts at least for failed and live (`DO-020`), domain lifecycle alerts (`DO-021`), CPU and memory alerts (`DO-022`), restart-count alert (`DO-023`), request-rate and p95-duration alerts backed by an observed baseline rather than guessed thresholds (`DO-024`), and alert rule names recorded exactly as the API returns them, noting any doc-versus-API enum mismatch for future automation (`DO-025`, info).

Runtime posture: a health check exists per service component (`DO-030`) and its path answers `200` live without auth, Origin, or session dependency (`DO-031`); single-instance production services named (`DO-032`); autoscaling posture recorded without recommending guessed thresholds (`DO-033`).

Two current-spec refinements, both read from the app spec already captured in Phase 2:

- **Liveness vs readiness (folds into DO-030).** App Platform components carry two distinct health-check blocks: the readiness `health_check` (stops routing traffic to an unhealthy instance) and a separate `liveness_health_check` (GA June 2025 — restarts the component when it fails). They are different objects with different defaults. A component that defines only `health_check` never auto-restarts when it hangs: traffic is withheld but the stuck instance sits there. Flag service components with a readiness `health_check` but no `liveness_health_check` as a DO-030 gap (a hang goes unrecovered), distinct from the "no health check at all" case.
- **Autoscaled without an alert on the scaled metric (folds into DO-033/DO-024).** A component with an `autoscaling` block (`min_instance_count`/`max_instance_count` plus a `metrics` object — `metrics.cpu.percent`, or the request-based `metrics.requests_per_second.per_instance` / `metrics.request_duration.p95_milliseconds`, GA May 2026) that has no App Platform alert rule on the metric it scales on is flying blind: it scales silently and pages nobody when it pins at `max_instance_count`. **Read this from the app spec's own `alerts` array (and `doctl apps list-alerts`), never from `doctl monitoring alert list`** — DO Monitoring alert policies have no App Platform metric type, so cross-referencing autoscaling against that surface is a category error. The finding is an autoscaled component whose app-spec `alerts` do not include the scaled metric (or at least a restart/CPU rule that would surface the pin).

Thresholds you compare against come from the starting alert set in section 12 of the reference; every number there is an example to tune, not a prescription.

## Phase 6: Managed databases (DO-040 to DO-048)

Commands in section 8. Per production database: CPU (`DO-040`), memory (`DO-041`), and disk (`DO-042`) policies exist as DO Monitoring policies with sane two-tier thresholds; no noisy or duplicate policies, for example a 50 percent page or a generic policy shadowing a named tier for the same database and metric (`DO-043`); recent backups listed (`DO-044`); standby or HA posture on production clusters (`DO-045`); firewall and trusted sources restricted, with drift against the expected source list recorded (`DO-046`); a logsink configured or its absence written down as a decision (`DO-047`); and engine signals beyond CPU, memory, and disk reviewed where exposed: connections, replication and failover, slow queries (`DO-048`).

- ❌ `Databases pass: CPU, memory, and disk policies exist for both clusters.`
- ✅ `Databases partial: the three resource policies exist, but db-main has no logsink decision (DO-047) and no policy or note covers connection saturation (DO-048); resource policies alone are not database observability.`

## Phase 7: Log forwarding (DO-050 to DO-052)

Commands in section 9. App Platform runtime logs forwarded to a central backend, or the absence recorded as a deliberate decision for the environment (`DO-050`, high for production); the backend decision complete with retention, redaction, index naming, and a named owner (`DO-051`); and the app-destination versus database-logsink mismatch handled explicitly, because the two surfaces support different destination lists (`DO-052`). Destination availability changes; verify the supported lists against current DigitalOcean docs at run time instead of trusting any static list, including the one in the reference.

## Phase 8: Ownership and hygiene (DO-060 to DO-062)

Commands in section 10. DNS and runtime ownership verified for every monitored hostname: a domain that now points at another platform while DO monitoring still watches the old app is false confidence, not coverage (`DO-060`); archived or migrated apps excluded from checks and policies (`DO-061`); secret-shaped env keys stored as `SECRET` type rather than plaintext `GENERAL` vars (`DO-062`, judged from key names and types only, never values).

## Phase 9: Coverage matrix and topology readiness

Fill one row per critical service using the per-service queries in section 11 and the check-result vocabulary (`pass`, `partial`, `fail`, `blocked`, `not-in-scope`):

| Service | Ready | Uptime | App alerts | Health | DB | Logs | Routing | Owner | Gap |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |

Cell composition, so the matrix hides nothing: the App alerts cell counts lifecycle, resource, and baseline-backed request and p95 rules (a guessed-threshold rule scores the cell `partial`); the DB cell folds in HA and autoscaling readiness (single instance or no standby caps the cell at `partial` with the gap named); every cell carries its `passed/total` denominator.

Name affected services in findings. "Two apps lack restart alerts" is not a finding; "checkout and billing lack restart alerts" is.

Then render the Scoutflo Topology Readiness section per [topology-readiness.md](../../report-standard/topology-readiness.md): evaluate T1 to T6 per critical service from `./scoutflo-audits/topology-export.json`, read-only. An edge this audit verified live (for example a `MONITORED_BY` edge to a DO alert policy the audit confirmed) counts toward T6 **only when the edge's identity resolves through a provider the platform actually models** (see the caveat immediately below); a confirmed-live edge whose provider identity cannot resolve at all stays capped regardless of how solid the live proof is. Gaps that map to an existing finding reference its ID; gaps with no finding get a `TOPO-` row pointing at `/scoutflo:map-topology`. Render check names and confidence per the standard: plain-English column headers (T-codes only in the legend line), confidence as `n/10`, and — whenever any service is below ready — the ticket-ready sync-readiness action plan table from [topology-readiness.md](../../report-standard/topology-readiness.md). If the export or topology.md is missing, or exists but describes a different target than this audit covers (wrong `cluster_id`, non-overlapping services), the section renders the matching state from topology-readiness.md with its one-line unlock (run `/scoutflo:map-topology` against the right estate, or hand-author the export per `scoutflo-export.md` for non-Kubernetes estates); it never guesses and never says a bare "unavailable". Readiness is reported, never folded into the 0-100 score.

**A confirmed, real platform gap specific to this provider**: DigitalOcean is not itself a valid topology provider identity on the Scoutflo platform — there is no `digitalocean` value in the platform's provider identity list, and no per-field attribute schema for it either, confirmed against the platform's current code. A `MONITORED_BY` or `SENDS_METRICS_TO` edge modeling **native, unrouted DO Monitoring or App Platform alerting as the edge's own identity** cannot satisfy T4 or T5 on the real platform no matter how solid the live delivery proof is — there is no correct value to put in that edge's provider field. This is not something `map-topology`'s export format can work around by choosing different field names; it is a gap in what the platform itself currently models. State this plainly in the Topology Readiness section for any service whose alerting backend is native DO Monitoring, rather than silently capping the edge at `partial` with no explanation. If the customer's real alerting instead routes DO Monitoring's notifications onward into Grafana, Sentry, or another provider the platform does model, T4/T5/T6 are fully reachable through *that* provider's edge instead — the gap is specific to representing native DO Monitoring as the edge's own identity, not to auditing a DigitalOcean-hosted service in general.

## Large-path worklist: apps in batches

Runs on the large path only (see [Estate sizing](#estate-sizing) above). All state lives under a run-ID-keyed run directory `./scoutflo-audits/digitalocean/runs/<RUN_ID>/`, not the calendar-date directory sections 4 to 11 of the reference write raw captures under, so a run that is still batching when the date rolls over UTC keeps writing into the same place. Full runnable commands (resume scan, run-ID mint, worklist build, lock, batch claim and mark-done, final pending assertion) are in [references/do-checks.md](references/do-checks.md) section 13; this section states the workflow they implement.

1. **Find a resumable run, or start a new one.** Before minting a new `RUN_ID`, scan `./scoutflo-audits/digitalocean/runs/*/worklist.tsv` for one with pending rows and offer to resume it instead of starting over.
2. **Build or resume the worklist.** One row per app ID from `doctl apps list`, status `pending` or `done`. A resumed run continues from its existing worklist; never rebuild one that already exists.
3. **Lock, then claim one batch.** Acquire `worklist.lock` in the run directory before reading pending rows; a lock older than `LOCK_STALE_MINUTES` (30 minutes; example, tune to your batch size) is abandoned and safe to reclaim. Take the next `BATCH_SIZE` pending app IDs and run the section 4 per-app inventory pull plus the Phase 3 to Phase 8 checks that key off an app ID, against just that batch. An app's row is marked `done` only after its pulls succeed, so an interrupted batch resumes at the app that failed. Release the lock once the batch's rows are marked.
4. **Assert before writing.** After every batch, print `done=X pending=Y`. Repeat from step 3 until the worklist has zero pending rows; assert `pending == 0` before Phase 10 writes `findings.json` or `report.md`. A run that stops mid-batch leaves the worklist as its resume point and never overwrites the previous complete report.

## Phase 10: Score, write, brief

Score per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md): each check yields `pass` (1.0), `partial` (0.5), `fail`/`blocked` (0), `not-in-scope` leaves the denominator. Category score is the credit ratio times 100 rounded down; overall is the weight-normalized sum over included categories. Whole categories that could not be assessed are excluded, renormalized, and stated; blocked checks inside an assessable category score 0. Score conservatively: when unsure between two results, pick the lower and say why. Assign each category a maturity value (`reactive`, `proactive`, `systematic`) per the shared definitions, judged conservatively.

| Category | Weight | ID range |
| --- | ---: | --- |
| Alert routing and delivery | 20 | DO-001 to DO-005, DO-070 to DO-072 |
| App Platform alert coverage | 20 | DO-020 to DO-025 |
| Managed databases | 20 | DO-040 to DO-048 |
| Uptime and availability | 15 | DO-010 to DO-015 |
| App health checks and runtime | 10 | DO-030 to DO-033 |
| Log forwarding | 10 | DO-050 to DO-052 |
| Ownership and hygiene | 5 | DO-060 to DO-062 |

The full check catalog and the target profile (what 100 means per category) are at the top of [references/do-checks.md](references/do-checks.md). IDs are stable: the same defect gets the same ID every run, one finding per failed check, affected objects enumerated. Compute `points_recoverable` per finding by re-running the scoring model with that check at full credit; `info` findings and excluded categories carry 0. The executive summary states the gap to target and the two or three findings with the highest `points_recoverable` as the biggest levers.

End-to-end gate: claim end-to-end coverage only when the overall score is at or above 85, every critical service passes every applicable coverage row, and no category was excluded. Below the gate, write "good base coverage", never "end to end".

Lifecycle, exemptions, and totals, before rendering the report:

1. Load the previous run's `findings.json` when one exists; classify every finding per the lifecycle table in the [findings schema](../../report-standard/findings-schema.md) (`new`, `unchanged`, `regressed`; resolved IDs go to the delta, and the executive summary names regressions first).
2. Load `./scoutflo-audits/exemptions.yaml` when present. Entries with `id`, `reason`, and `expires` all set and unexpired suppress their finding into the Suppressed appendix; malformed or expired entries are reported, never honored. Suppressed findings leave the score and severity counts; the scorecard states the suppressed count.
3. Every findings area and coverage cell carries its denominator (`passed/total`).

Emit and verify:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/${RUN_DATE}"
mkdir -p "$OUT"
# ... write findings.json and report.md per the report standard, then verify:
jq -e '.schema == "scoutflo-findings/v1" and .target == "digitalocean" and (.findings | type == "array")' \
  "$OUT/findings.json" >/dev/null && echo "findings.json valid"
grep -q '^# ' "$OUT/report.md" && echo "report.md present"
# Output conformance: the emitted report.md must match report-standard/report-template.md.
# This catches header/score-line/section drift before the run is declared done.
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-report.sh" "$OUT/report.md"
```

Compute the delta against the previous run's `findings.json` (the latest two date directories; first run states "first run, no delta"), then append one line to the history ledger, replacing any line for the same date:

```bash
set -eu
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean"
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${TARGET_DIR}/${RUN_DATE}"
RESOLVED="0"   # fixed count from this run's delta; 0 on the first run
LINE="$(jq -c --arg d "$RUN_DATE" --argjson resolved "$RESOLVED" \
  '{run_date:$d, skill:"audit-digitalocean", overall:.score.overall, gate:.score.gate,
    end_to_end:.score.end_to_end, severity_counts:.severity_counts,
    lifecycle_counts:((reduce .findings[].lifecycle as $l ({}; .[$l] = (.[$l] // 0) + 1)) + {resolved:$resolved})}' \
  "$OUT/findings.json")"
TMP="$(mktemp)"
[ -f "${TARGET_DIR}/history.jsonl" ] && grep -v "\"run_date\":\"${RUN_DATE}\"" "${TARGET_DIR}/history.jsonl" > "$TMP" || true
printf '%s\n' "$LINE" >> "$TMP"
mv "$TMP" "${TARGET_DIR}/history.jsonl"
tail -1 "${TARGET_DIR}/history.jsonl" | jq -e '.run_date and (.overall >= 0)' >/dev/null && echo "history.jsonl updated"
```

The report's trend line renders the last five history.jsonl entries, oldest first; the ledger is derived and never drives finding lifecycle. Then send the Slack brief: titles only, never evidence values, hostnames, or endpoints:

```bash
set -eu
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean"
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${TARGET_DIR}/${RUN_DATE}"
TOPO_LINE="Topology readiness: readiness not recorded"  # replace with "r/n services sync-ready" from Phase 9
# slack.webhook_env names the webhook variable; skip when unset.
if [ -n "${SCOUTFLO_SLACK_WEBHOOK:-}" ]; then
  SCORE="$(jq -r '.score.overall' "$OUT/findings.json")"
  E2E="$(jq -r 'if .score.end_to_end then "end-to-end" else "not end-to-end" end' "$OUT/findings.json")"
  COUNTS="$(jq -r '.severity_counts | "\(.critical) critical, \(.high) high, \(.medium) medium, \(.low) low"' "$OUT/findings.json")"
  CHECKS="$(jq -r '"\([.score.categories[].checks_passed] | add)/\([.score.categories[].checks_total] | add) checks passed"' "$OUT/findings.json")"
  TOP="$(jq -r '[.findings[] | "\(.id) \(.title)"] | .[0:5] | join("\n")' "$OUT/findings.json")"
  PREV="$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type d | sort | tail -2 | head -1)"
  MOVE=""; DELTA="first run"
  if [ -n "$PREV" ] && [ "$PREV" != "$OUT" ]; then
    MOVE="$(jq -rn --argjson prev "$(jq '.score.overall' "$PREV/findings.json")" --argjson cur "$SCORE" \
      '(($cur - $prev) | if . >= 0 then "(+\(.))" else "(\(.))" end)')"
    DELTA="$(jq -rn --slurpfile p "$PREV/findings.json" --slurpfile c "$OUT/findings.json" '
      [$p[0].findings[].id] as $b | [$c[0].findings[].id] as $n |
      "\(($b - $n) | length) fixed, \(($n - $b) | length) new, \(($n - ($n - $b)) | length) unchanged"')"
  fi
  jq -n --arg head "audit-digitalocean ${RUN_DATE}: ${SCORE}/100${MOVE:+ $MOVE}, ${E2E}. ${COUNTS}. ${CHECKS}." \
        --arg top "$TOP" --arg delta "$DELTA" --arg topo "$TOPO_LINE" --arg path "$OUT/report.md" \
        '{text: ($head + "\nTop findings:\n" + $top + "\nDelta: " + $delta + "\n" + $topo + "\nReport: " + $path)}' \
    | curl -fsS --max-time 10 -H 'Content-Type: application/json' -d @- "$SCOUTFLO_SLACK_WEBHOOK" \
    || echo "Slack brief failed to send; audit result unaffected"
fi
```

When invoked by `audit-all`, skip the Slack brief; the orchestrator sends exactly one combined message per run. Keep `./scoutflo-audits/` out of public version control; reports describe your infrastructure.

## Remediation pointers

Every finding's `remediation` field points at the fix, so "Next safe actions" starts at row 1 with no preparation:

| Finding area | Pointer |
| --- | --- |
| No or wrong alert destinations, channel binding, alert text | `setup-digitalocean#fix-alert-routing` |
| Delivery never proven | `setup-digitalocean#prove-alert-delivery` |
| Missing or noisy uptime checks and uptime alert rules | `setup-digitalocean#fix-uptime-coverage` |
| Missing App Platform lifecycle, resource, or request alerts | `setup-digitalocean#add-app-platform-alerts` |
| Missing or unsafe health checks | `setup-digitalocean#harden-health-checks` |
| Missing or noisy database alert policies | `setup-digitalocean#set-database-alert-policies` |
| Missing database logsink | `setup-digitalocean#configure-database-logsinks` |
| No central app log forwarding, incomplete backend decision | `setup-digitalocean#enable-app-log-forwarding` |
| Stale monitoring on migrated or archived services | `setup-digitalocean#retire-stale-monitoring` |
| Secret-shaped env vars stored as plaintext | `setup-digitalocean#move-secret-env-vars` |
| Single instance, no standby, firewall, autoscaling, DNS | `setup-digitalocean#plan-traffic-impacting-changes` (plan only) |
| Topology readiness gaps with no finding | `/scoutflo:map-topology` |

## Common Failure Modes

All thresholds and windows named in the checks are example values; tune them to your workloads before treating a miss as a failure.

| Failure | Prevention |
| --- | --- |
| Spec edit recommended as a "config-only" fix | Classify every recommendation by change-risk class; any app spec field change is a controlled rollout that redeploys |
| Database alerting judged by app alerts, or the reverse | Audit App Platform alerts and DO Monitoring database policies as separate systems; neither covers the other |
| Webhook smoke `200` counted as delivery proof | Routing stays `configured` until a DO-generated event is observed at the receiver; proof lives in the setup lane |
| Slack payload channel override trusted | Incoming webhooks are channel-bound; record the installed channel, not the payload field |
| Uptime check credited while its target 404s | Probe every check target live this run and capture the status code as evidence |
| Migrated service audited as a DO gap | Verify DNS and runtime ownership first; a hostname pointing off-DO makes the old app's monitoring noise, not coverage |
| App spec pasted into evidence or the report | Capture env key names and types only; strip webhook URLs from policy JSON at capture |
| Doc-listed alert enum assumed valid | Record rule names exactly as the API returns them; enum validation via propose belongs to the setup lane |
| Alert-policy count scored as coverage | Credit only policies whose metric, threshold, window, and destination a responder could act on |
| Toolkit brief webhook conflated with DO alert destinations | Two different webhooks with two different jobs; flag any overlap as a finding |
| One environment's thresholds treated as universal | Declare every threshold as a named variable with a tune-to-your-workload note |
