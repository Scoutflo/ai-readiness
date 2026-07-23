---
name: audit-gcp
description: Read-only scored audit of Google Cloud observability, covering Cloud Monitoring alert policies, notification channels, uptime checks, dashboards, logs-based metrics and sinks, GKE telemetry settings, Compute Engine VM metrics, and load balancer health wiring; writes findings.json and report.md and changes nothing. Use when the user mentions auditing or scoring GCP or Google Cloud monitoring and alerting, Cloud Monitoring, uptime checks, Ops Agent coverage, or noisy GCP alerts. Do not use to change GCP resources (use setup-gcp), for in-cluster Prometheus stacks on GKE (use audit-lgtm), or for DigitalOcean (use audit-digitalocean).
---

# audit-gcp

Scored, read-only audit of the Google Cloud surfaces that carry production observability: Cloud Monitoring alert policies, notification channels, uptime checks, dashboards, logs-based metrics and sinks, GKE cluster telemetry settings, Compute Engine VM metrics, and load balancer health wiring. It answers one question: when a GCP-hosted service degrades tonight, does an alert fire, reach a human, and give the responder enough to act?

Every command in this audit is read-only: gcloud `list`, `describe`, and `read` subcommands, GET calls against the Monitoring and Logging REST APIs, and `curl` GET probes against public endpoints. Nothing is created, updated, snoozed, verified, test-fired, or deleted, however small, and no command mutates local gcloud state (`gcloud config set` is as forbidden as a cloud write; every command passes explicit flags instead). The one POST-shaped call allowed is `gcloud compute backend-services get-health`, which reads state; classification is by effect, not verb. The full forbidden-command list is in [references/gcp-checks.md](references/gcp-checks.md) section 15.

Scope boundaries, stated so a green score never overpromises:

- One project per run: the audit judges `gcp.project` from `~/.scoutflo/toolkit.yaml`. Multi-project estates run once per project.
- Covered: Cloud Monitoring, Cloud Logging (metrics and sinks), uptime checks, Compute Engine VMs, GKE cluster telemetry settings, and load balancers. Not covered: Cloud Run, Cloud Functions, App Engine, Cloud SQL, Pub/Sub, and Memorystore; if those carry production traffic, say so in the report as unaudited surface.
- In-cluster stacks (Prometheus, Alertmanager, Grafana running inside GKE) belong to `/scoutflo:audit-lgtm`; this audit covers the Google-managed plane and states the split.

Run this standalone, from `/scoutflo:audit-all`, or on a schedule via `/scoutflo:schedule-audits`.

Outputs, per the [report standard](../../report-standard/README.md):

- `./scoutflo-audits/gcp/<YYYY-MM-DD>/findings.json` per the [findings schema](../../report-standard/findings-schema.md), finding IDs `GCP-NNN`
- `./scoutflo-audits/gcp/<YYYY-MM-DD>/report.md` per the [report template](../../report-standard/report-template.md)
- One appended line in `./scoutflo-audits/gcp/history.jsonl`
- One Slack brief, when `slack.webhook_env` is configured

## Doctor gate

| Integration | toolkit.yaml keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| GCP | `gcp.project`, optional `gcp.region`, optional `gcp.credentials_env` | none in the config; `credentials_env` names the variable holding a service-account key file path (presence checked, contents never printed). Without it, your active gcloud login is the identity | `roles/monitoring.viewer`, `roles/logging.viewer`, `roles/compute.viewer`, `roles/container.viewer` (recipe in `/scoutflo:connect`) | read-only |
| Slack (optional) | `slack.webhook_env` | webhook variable | post to one channel | n/a |

```bash
set -eu
CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
for bin in gcloud curl jq; do
  command -v "$bin" >/dev/null || { echo "missing binary: $bin"; exit 1; }
done
gcloud --version | head -1
GCP_PROJECT="your-project-id"   # gcp.project
# gcp.credentials_env (optional) names GOOGLE_APPLICATION_CREDENTIALS, the path-to-key-file
# variable application-default credentials read. Presence and file existence only; never
# print the file's contents anywhere.
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then
  [ -f "$GOOGLE_APPLICATION_CREDENTIALS" ] || { echo "GOOGLE_APPLICATION_CREDENTIALS names a missing file"; exit 1; }
  TOKEN="$(gcloud auth application-default print-access-token)"
  export CLOUDSDK_AUTH_ACCESS_TOKEN="$TOKEN"
else
  TOKEN="$(gcloud auth print-access-token)"
fi
PROJECT_ID="$(gcloud projects describe "$GCP_PROJECT" --format='value(projectId)')"
[ "$PROJECT_ID" = "$GCP_PROJECT" ] || { echo "project mismatch: gcloud resolved '${PROJECT_ID}', config names '${GCP_PROJECT}'"; exit 1; }
echo "project id confirmed: ${PROJECT_ID}"

code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "Authorization: Bearer ${TOKEN}" \
  "https://monitoring.googleapis.com/v3/projects/${GCP_PROJECT}/notificationChannels?pageSize=1")"
[ "$code" = "200" ] || { echo "monitoring api: ${code} (expected 200); a 403 means the identity lacks monitoring.viewer or the Monitoring API is disabled, a 404 means the project id is wrong"; exit 1; }
echo "monitoring api: ${code}"
```

Expected: `project id confirmed: <your project>` and `monitoring api: 200`, both asserted by the block itself, not read off the printout. Either assertion failing stops the block with a nonzero exit; never proceed past a failed doctor check and never downgrade one into a finding. `/scoutflo:doctor` runs the same checks standalone.

Two notes that live here because they bite at the gate:

- If the audit identity holds `editor` or `owner`, the audit still runs, but record in the report that the audit credential can write; a viewer-tier identity is itself part of good posture.
- Command surfaces move between gcloud release tracks. This skill pins REST for alert policies, notification channels, and snoozes, and GA gcloud for the rest; verify the named gcloud groups exist in your installed version before the first run (details in [references/gcp-checks.md](references/gcp-checks.md) section 1).

## Live-safety gate

Print what you are pointed at and compare it to the config before the first real check:

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then
  echo "identity: $(jq -r '.client_email // "unknown"' "$GOOGLE_APPLICATION_CREDENTIALS") (key file)"
else
  echo "identity: $(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -1)"
fi
echo "target project: ${GCP_PROJECT}"
echo "ambient gcloud project (printed for awareness, never used): $(gcloud config get-value project 2>/dev/null || echo unset)"
PROJECT_ID="$(gcloud projects describe "$GCP_PROJECT" --format='value(projectId)')"
[ "$PROJECT_ID" = "$GCP_PROJECT" ] || { echo "live-safety gate failed: gcloud resolved '${PROJECT_ID}', config names '${GCP_PROJECT}'"; exit 1; }
echo "project id confirmed: ${PROJECT_ID}"
```

The assertion is the gate: `projects describe` either returns a project id equal to `gcp.project`, or the block exits nonzero and stops the run. Never proceed on "probably the right project". If the printed identity line is not the one your team intends for audits, stop and report the mismatch even though the project-id assertion passed; identity and project are two separate checks. The ambient gcloud project is printed only so a drift is visible; no command in this audit reads it, every command names `--project "${GCP_PROJECT}"` explicitly, and pointing the audit somewhere else is an edit to `toolkit.yaml`, never a `gcloud config set`.

## Ground rules

- Configuration is metadata; live validation is proof. A policy in the list is `configured`; only an observed Monitoring-generated notification makes routing `validated-live`.
- API errors are evidence. A `403` means a missing role or a disabled API; a `404` means a wrong project or a retired resource. Record the code and what it implies; never convert an error into empty success.
- Never score from object counts.
  - ❌ `Scored alert routing 90: thirty-one alert policies and six channels exist.`
  - ✅ `Scored alert routing 45: policies name channels, but two referenced channels are disabled and no delivery was ever observed; credit stops at partial.`
- A load balancer health check keeps traffic away from a bad backend; it pages nobody. Health checks and Monitoring alert policies are different systems, and an uptime check with no alert policy on its metric only draws a graph. Neither presence scores the other.
- Memory and disk metrics on Compute VMs exist only where the Ops Agent ships them. Coverage claims come after agent metric evidence, never before.
- Notification channel `labels` carry webhook URLs and tokens. Capture label keys only, per the redaction procedure in [references/gcp-checks.md](references/gcp-checks.md) section 1; never print label values into evidence, the report, or the terminal.
- Two webhooks, two jobs: "Cloud Monitoring notification channel" is the object under audit; the "toolkit Slack brief webhook" (`slack.webhook_env`) is the reporting path. Name them exactly this way and flag any channel that appears to be the brief webhook.
- Label every recommendation with its change-risk class (next section) so "Next safe actions" never hides a cluster update behind a "monitoring tweak".

## The four change-risk classes

Every fix this audit recommends carries one of four classes:

| Class | Examples | Rule |
| --- | --- | --- |
| Read-only | gcloud list/describe/read, REST GET, curl probes | The only class allowed in this audit. |
| Monitoring-plane write | notification channels, uptime checks, alert policies, logs-based metrics, dashboards | `setup-gcp`, confirmation-gated. No workload restarts. |
| Controlled rollout | Ops Agent install, GKE logging/monitoring component enablement, log sink changes | Own change plan with a named owner; out of `setup-gcp` write scope. |
| Traffic-impacting | load balancer, backend, firewall, IAM, DNS, certificate, VM resize or restart, GKE node pools | Out of write scope everywhere; plan only. |

- ❌ `Recommend: enable system monitoring on the cluster (quick config toggle).`
- ✅ `Recommend: enable SYSTEM_COMPONENTS monitoring on cluster main-cluster (controlled rollout: a cluster update owned by the cluster team; setup-gcp#plan-out-of-scope-changes records the plan, it does not execute it).`

## Estate sizing

Count before judging, and declare the path in the terminal output:

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
MON_API="https://monitoring.googleapis.com/v3"
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN="$TOKEN"; else TOKEN="$(gcloud auth print-access-token)"; fi
SMALL_MAX_OBJECTS="15"    # example, tune to your environment
MEDIUM_MAX_OBJECTS="60"   # example, tune to your environment
BATCH_SIZE="10"           # VMs per batch on the large path; example, tune it
VMS="$(gcloud compute instances list --project "$GCP_PROJECT" --format='value(name)' | wc -l | tr -d ' ')"
CLUSTERS="$(gcloud container clusters list --project "$GCP_PROJECT" --format='value(name)' | wc -l | tr -d ' ')"
CHECKS="$(gcloud monitoring uptime list-configs --project "$GCP_PROJECT" --format='value(name)' | wc -l | tr -d ' ')"
BACKENDS="$(gcloud compute backend-services list --project "$GCP_PROJECT" --format='value(name)' | wc -l | tr -d ' ')"
POLICIES="$(curl -fsS --max-time 30 -H "Authorization: Bearer ${TOKEN}" \
  "${MON_API}/projects/${GCP_PROJECT}/alertPolicies?pageSize=500" | jq '[.alertPolicies[]?] | length')"
CHANNELS="$(curl -fsS --max-time 30 -H "Authorization: Bearer ${TOKEN}" \
  "${MON_API}/projects/${GCP_PROJECT}/notificationChannels?pageSize=500" | jq '[.notificationChannels[]?] | length')"
TOTAL=$((VMS + CLUSTERS + CHECKS + BACKENDS))
echo "vms=${VMS} clusters=${CLUSTERS} uptime_checks=${CHECKS} backend_services=${BACKENDS} alert_policies=${POLICIES} channels=${CHANNELS} scored_objects=${TOTAL}"

# Guided-walkthrough drift check, per report-standard/README.md#using-topology-and-prior-runs-as-a-guided-walkthrough:
# compare against the last run rather than a blank slate. State the result in the executive summary;
# never silently omit it. This never skips a live check - every check in later phases still runs fresh.
TARGET_DIR="./scoutflo-audits/gcp"
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

- **Small** (`TOTAL <= SMALL_MAX_OBJECTS`): one pass over everything. No worklist, no batching; three VMs do not need bookkeeping.
- **Medium** (`TOTAL <= MEDIUM_MAX_OBJECTS`): per-category passes (routing, uptime, VMs, GKE, LB, logs), completed in one run.
- **Large**: work VMs, uptime checks, and backend services in batches of `BATCH_SIZE` against a durable, run-ID-keyed worklist, per [Large-path worklist: VMs and services in batches](#large-path-worklist-vms-and-services-in-batches) below.

A policy or channel count sitting at exactly 500 means the first page was full: fetch the rest before judging (pagination loop in [references/gcp-checks.md](references/gcp-checks.md) section 4). A disabled Compute or Container API on a project that genuinely has none of those resources makes that area `not-in-scope`, declared in the scorecard, not a failure. Record the chosen path and counts in `findings.json` as `estate: {objects, path}`; `audit-all` reads them. Never silently truncate: if the run judged a subset, the report names what was skipped and the coverage denominators reflect it.

## Phase 1: Service context

If `./scoutflo-audits/topology.md` exists, load it. Its service list is the critical-service list and its names are canonical in findings, the coverage matrix, and `affected` arrays; map VMs, GKE workloads, and backend services to those names. If it does not exist, infer services from instance, workload, and backend-service names, note the inference in the report, and suggest `/scoutflo:map-topology`. If live discovery contradicts topology.md, record the discrepancy; only the mapping skill and you edit that file.

## Phase 2: Read-only inventory

Build the raw picture with the commands in [references/gcp-checks.md](references/gcp-checks.md) section 4: alert policies (REST, paginated, one JSON object per line), notification channels redacted at capture, snoozes, uptime checks, dashboards, logs-based metrics and sinks, GKE clusters with their telemetry component config and Managed Prometheus state, VMs with public exposure, and the load balancer chain (forwarding rules, backend services, health checks). Judgment starts in Phase 3; inventory records what exists.

## Phase 3: Alert routing and delivery (GCP-001 to GCP-006)

Commands in [references/gcp-checks.md](references/gcp-checks.md) section 5. Judge whether an alert that fires reaches a human: any enabled channel at all (`GCP-001`, critical when none), every enabled policy names at least one channel (`GCP-002`), channels split per environment instead of one catch-all (`GCP-003`), delivery proven by an observed Monitoring-generated notification rather than assumed (`GCP-004`, capped at `configured` without one; Cloud Monitoring's incident history has no public list API, so a team-confirmed sighting is the documented manual exception), no disabled or unverified channel still referenced by policies (`GCP-005`), and no forgotten snooze muting a critical policy (`GCP-006`).

## Phase 4: Uptime and availability (GCP-010 to GCP-015)

Commands in section 6. Every active public serving endpoint has an uptime check (`GCP-010`); every check has an alert policy on its `check_passed` metric, because a check without a policy notifies nobody (`GCP-011`); SSL-expiry visibility exists for HTTPS endpoints (`GCP-012`); every check target answers `200` live this session (`GCP-013`); checkers span regions where regional failure matters (`GCP-014`); and no check watches a dead or migrated target (`GCP-015`). Probe every target live and capture the status code as evidence.

- ❌ `Uptime pass: a check exists for the storefront host.`
- ✅ `Uptime partial: the check exists but no policy rides its check_passed metric (GCP-011), and the target answered 401 this run, which makes it a noise generator (GCP-013), affected: storefront.`

## Phase 5: Compute VM coverage (GCP-020 to GCP-024)

Commands in section 7. Per serving VM group: CPU pressure policies with two named tiers where the workload is stable (`GCP-020`); memory and disk coverage credited only after agent metrics prove live per VM (`GCP-021`); Ops Agent presence itself (`GCP-022`); every threshold or absence condition filter returns live time series, because a filter matching zero series can never fire (`GCP-023`); and metadata or user-label filters validated against the real label shape (`GCP-024`). MQL and PromQL conditions cannot be validated by the series probe; record them as `configured` unless separately proven.

## Phase 6: GKE coverage (GCP-030 to GCP-033)

Commands in section 8. Cluster logging and monitoring components enabled (`GCP-030`); restart, pending, and unschedulable workload policies exist (`GCP-031`); Managed Prometheus state matches where workload alerting is expected (`GCP-032`); node pressure and readiness visible (`GCP-033`). Where the in-cluster stack is the primary alerting plane, mark the overlapping checks `not-in-scope`, state the split, and run `/scoutflo:audit-lgtm` against that stack.

## Phase 7: Load balancer coverage (GCP-040 to GCP-043)

Commands in section 9. Every serving backend service has a health check attached (`GCP-040`); a 5xx-rate policy (`GCP-041`) and a backend latency policy (`GCP-042`) exist per serving load balancer; and backend health is provable via `get-health` (`GCP-043`; a permission denial files as `blocked`, never guessed from the frontend serving fine). The trap this phase exists for: LB health checks eject bad backends silently, so an estate can look "self-healing" while an all-backends-down event pages nobody.

## Phase 8: Logs as a signal (GCP-050 to GCP-054)

Commands in section 10. One logs-based error metric per critical service, the roster coming from topology.md, never from a canned list (`GCP-050`); every metric filter matches recent log entries, because a filter that matches nothing counts nothing (`GCP-051`); metrics that matter carry alert policies (`GCP-052`); sink routing and exclusion filters lose nothing silently (`GCP-053`); and log bucket retention is a deliberate decision, not an unexamined default, matching the same discipline `audit-aws`'s `AWS-051` and `audit-digitalocean`'s `DO-051` already require (`GCP-054`).

## Phase 9: Alert quality and dashboards (GCP-060 to GCP-071)

Commands in sections 11 and 12. Policy documentation tells the responder where they are, how bad it is, and what to capture first (`GCP-060`); severity is expressed somewhere a responder can read it (`GCP-061`); thresholds trace to baselines and use two tiers where stable (`GCP-062`). Dashboards link the signals for critical services (`GCP-070`), and any surface with a dashboard but no alerting is flagged, because a dashboard is not an alert (`GCP-071`).

## Large-path worklist: VMs and services in batches

Runs on the large path only (see [Estate sizing](#estate-sizing) above). All state lives under a run-ID-keyed run directory `./scoutflo-audits/gcp/runs/<RUN_ID>/`, not a calendar-date directory, so a run that is still batching when the date rolls over UTC keeps writing into the same place. Full runnable commands (resume scan, run-ID mint, worklist build, lock, batch claim, final pending assert) are in [references/gcp-checks.md](references/gcp-checks.md) section 16; this section states the workflow they implement.

1. **Find a resumable run, or start a new one.** Before minting a new `RUN_ID`, scan `./scoutflo-audits/gcp/runs/*/worklist.tsv` for one with pending rows and offer to resume it instead of starting over.
2. **Build or resume the worklist.** One row per VM, uptime check, and backend service counted in Estate sizing, status `pending` or `done`. A resumed run continues from its existing worklist; never rebuild one that already exists.
3. **Lock, then claim one batch.** Acquire `worklist.lock` in the run directory before reading pending rows; a lock older than `LOCK_STALE_MINUTES` (30 minutes; example, tune to your batch size) is abandoned and safe to reclaim. Take the next `BATCH_SIZE` pending rows and run the Phase 4 (uptime), Phase 5 (VM), or Phase 7 (load balancer) checks matching each row's kind against just that batch. A row is marked `done` only after its pulls succeed, so an interrupted batch resumes at the row that failed. Release the lock once the batch's rows are marked.
4. **Assemble incrementally.** After each batch, recompose the partial findings and coverage matrix from the batches completed so far, and print progress (`done=X pending=Y`). Repeat from step 3 until the worklist has zero pending rows.
5. **Assert before writing.** `findings.json` and `report.md` are written only once a final check confirms the worklist's `pending` count is `0`; see the assertion in reference section 16. A partial run's state stays in the run directory as the resume point and never overwrites the previous complete report.

Two hard rules, matching the estate-sizing rules above: alert routing, GKE, logs, and alert-quality checks (Phases 3, 6, 8, 9) are project- or category-scoped, not per-object, and always run once per run regardless of path. Delete the run directory after `findings.json` and `report.md` are written; it is working state, not a report.

### Alert hygiene: policy noise controls (GCP-063 to GCP-066)

Folds into Phase 9, after the `GCP-060` to `GCP-062` alert-quality checks. Phases 3 through 8 prove a policy that fires reaches a human; this subsection asks the opposite question a responder feels at 3am: does a firing policy generate a sustainable notification stream, or does its own configuration turn it into noise? Every check reads the per-policy `alertStrategy` and condition fields already captured in Phase 2's `alert-policies.jsonl` (no new call, no mutation) and applies a tunable threshold as the reader. Commands are in [references/gcp-checks.md](references/gcp-checks.md) section 17.

Honest ceiling, stated in the report every run:

- These are **structural** noise signals read off each policy's configuration (retest window, auto-close, notification rate limit, renotify cadence, resolve prompts), not an alert-to-incident actionability rate. Cloud Monitoring exposes no public incident-history list API, the same limit `GCP-004` already records, so this audit never reports a fabricated "N% of alerts are actionable" number; it names which policies are structurally noisy and why.
- Cloud Monitoring is comparatively rich per policy, but it genuinely lacks three Alertmanager-class controls, so their absence is a stated coverage limit, never a finding: there is no cross-policy inhibition (the `AND` combiner correlates conditions inside one policy only, not one policy against another), no grouping or bundling of distinct incidents into a single notification (`notificationRateLimit` throttles repeats of the *same* policy and nothing more), and no recurring time-based mute schedule (snoozes are one-off fixed intervals, not cron-style maintenance windows). Say this plainly rather than scoring a gap the platform cannot fill.
- Snooze staleness that mutes a live critical policy is already `GCP-006` in Alert routing (reference section 5); this subsection does not re-check it. A snooze whose interval has fully elapsed mutes nothing and is harmless clutter, not a noise signal, so it earns no separate check.

Checks:

- **GCP-063 (retest window).** Each threshold, absence, MQL, or PromQL condition carries a duration the predicate must hold before an incident opens (`conditionThreshold.duration`, `conditionAbsent.duration`; the GCP analogue of a Prometheus `for`). A paging policy whose duration is `0s` or absent fires on a single violating sample that may self-correct before anyone looks; the retest window resets on any non-violating sample, and the value is a multiple of 60s (example floor: `DURATION_MIN="60s"`, tune it). Log-match conditions (`conditionMatchedLog`) have no duration by design and are governed by `GCP-065` instead, so they are excluded here rather than false-flagged.
- **GCP-064 (auto-close).** `alertStrategy.autoClose` closes an open incident after the policy stops receiving data; when unset the effective default is seven days, so a transient condition can leave an incident open, and renotifying, for a week. A deliberate, tighter value (example, tune it: `AUTOCLOSE_MAX="86400s"`) is the fix. Absence is low severity: a stuck-open incident is renotify noise and a stale board, not a missed page.
- **GCP-065 (repeat-notification throttle).** `alertStrategy.notificationRateLimit.period` caps notifications to one per period while an incident stays open; absent on a high-churn policy means a notification per evaluation. It is already required on log-based policies, so read it there too. Flag its absence on the noisiest metric policies (the top-talkers the coverage work already surfaces), not on every quiet one, or the finding becomes noise itself.
- **GCP-066 (renotify and resolve cadence).** `alertStrategy.notificationChannelStrategy[].renotifyInterval` must sit inside the documented 30m-24h range when set (`RENOTIFY_MIN="1800s"`, `RENOTIFY_MAX="86400s"`; examples, tune them) rather than silently defaulting, and `alertStrategy.notificationPrompts` including `CLOSED` emits a resolve notification per incident, roughly doubling that policy's volume. `CLOSED` is often a deliberate choice, so this is `info` unless it inflates a policy already flagged noisy by `GCP-065`, where it rises to `low`.

## Phase 10: Coverage matrix and topology readiness

Fill one row per critical service using section 13 and the check-result vocabulary (`pass`, `partial`, `fail`, `blocked`, `not-in-scope`):

| Service | Ready | Uptime | VM | GKE | LB | Logs | Routing | Owner | Gap |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |

Cell composition, so the matrix hides nothing: the `VM` cell folds in the Ops Agent gate (CPU-only coverage caps it at `partial` with the gap named); the `Logs` cell requires a matching, recently matching, policy-carrying metric to reach `pass`; every cell carries its `passed/total` denominator. Name affected services in findings: "two VMs lack memory coverage" is not a finding; "checkout-vm-1 and checkout-vm-2 lack memory coverage" is.

Then render the Scoutflo Topology Readiness section per [topology-readiness.md](../../report-standard/topology-readiness.md): evaluate T1 to T6 per critical service from `./scoutflo-audits/topology-export.json`, read-only. An edge this audit verified live (for example a `MONITORED_BY` edge to an alert policy the audit confirmed fires on live series) counts toward T6, **with one caveat specific to this provider**: GCP is itself a valid topology provider identity on the platform, so T4/T5 are unaffected, but there is no per-field attribute schema for native GCP Cloud Monitoring or Cloud Logging on the platform today, confirmed against the platform's current schema definitions — unlike Prometheus, Grafana, Datadog, or Sentry, none of which need this caveat. A `MONITORED_BY` edge whose identity is native GCP Cloud Monitoring can still resolve and satisfy T4/T5, but T6's confidence-scored correlation has no typed fields to populate for it, so it caps at `partial` on attribute depth alone even with solid live-alert proof; state this plainly rather than silently capping the row. If the customer's GCP alerting instead routes into Prometheus, Grafana, Datadog, or another provider the platform has a full attribute schema for, T6 is fully reachable through that provider's edge instead. Gaps that map to an existing finding reference its ID; gaps with no finding get a `TOPO-` row pointing at `/scoutflo:map-topology`. Render check names and confidence per the standard: plain-English column headers (T-codes only in the legend line), confidence as `n/10`, and — whenever any service is below ready — the ticket-ready sync-readiness action plan table from [topology-readiness.md](../../report-standard/topology-readiness.md). If the export or topology.md is missing, or exists but describes a different target than this audit covers (wrong `cluster_id`, non-overlapping services), the section renders the matching state from topology-readiness.md with its one-line unlock (run `/scoutflo:map-topology` against the right estate, or hand-author the export per `scoutflo-export.md` for non-Kubernetes estates); it never guesses and never says a bare "unavailable". Readiness is reported, never folded into the 0-100 score.

## Phase 11: Score, write, brief

Score per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md): each check yields `pass` (1.0), `partial` (0.5), `fail`/`blocked` (0); `not-in-scope` leaves the denominator. Category score is the credit ratio times 100 rounded down; overall is the weight-normalized sum over included categories. Whole categories that could not be assessed are excluded, renormalized, and stated; blocked checks inside an assessable category score 0. Score conservatively: when unsure between two results, pick the lower and say why. Assign each category a maturity value (`reactive`, `proactive`, `systematic`) per the shared definitions, judged conservatively.

| Category | Weight | ID range |
| --- | ---: | --- |
| Alert routing and delivery | 20 | GCP-001 to GCP-006 |
| Uptime and availability | 15 | GCP-010 to GCP-015 |
| Compute VM coverage | 15 | GCP-020 to GCP-024 |
| GKE coverage | 15 | GCP-030 to GCP-033 |
| Logs as a signal | 15 | GCP-050 to GCP-054 |
| Load balancer coverage | 10 | GCP-040 to GCP-043 |
| Alert quality | 5 | GCP-060 to GCP-066 |
| Dashboards and correlation | 5 | GCP-070 to GCP-071 |

The full check catalog and the target profile (what 100 means per category) are at the top of [references/gcp-checks.md](references/gcp-checks.md). IDs are stable: the same defect gets the same ID every run, one finding per failed check, affected objects enumerated. Compute `points_recoverable` per finding by re-running the scoring model with that check at full credit; `info` findings and excluded categories carry 0. The executive summary states the gap to target and the two or three findings with the highest `points_recoverable` as the biggest levers.

End-to-end gate: claim end-to-end coverage only when the overall score is at or above 85, every critical service passes every applicable coverage row, and no category was excluded. Below the gate, write "good base coverage", never "end to end".

Lifecycle, exemptions, and totals, before rendering the report:

1. Load the previous run's `findings.json` when one exists; classify every finding per the lifecycle table in the [findings schema](../../report-standard/findings-schema.md) (`new`, `unchanged`, `regressed`; resolved IDs go to the delta, and the executive summary names regressions first).
2. Load `./scoutflo-audits/exemptions.yaml` when present. Entries with `id`, `reason`, and `expires` all set and unexpired suppress their finding into the Suppressed appendix; malformed or expired entries are reported, never honored. Suppressed findings leave the score and severity counts; the scorecard states the suppressed count.
3. Every findings area and coverage cell carries its denominator (`passed/total`).

Emit and verify:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="./scoutflo-audits/gcp/${RUN_DATE}"
mkdir -p "$OUT"
# ... write findings.json and report.md per the report standard, then verify:
jq -e '.schema == "scoutflo-findings/v1" and .target == "gcp" and (.findings | type == "array") and (.estate.path != null)' \
  "$OUT/findings.json" >/dev/null && echo "findings.json valid"
grep -q '^# ' "$OUT/report.md" && echo "report.md present"
# Output conformance: the emitted report.md must match report-standard/report-template.md.
# This catches header/score-line/section drift before the run is declared done.
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-report.sh" "$OUT/report.md"
```

Compute the delta against the previous run's `findings.json` (the latest two date directories; first run states "first run, no delta"), then append one line to the history ledger, replacing any line for the same date:

```bash
set -eu
TARGET_DIR="./scoutflo-audits/gcp"
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${TARGET_DIR}/${RUN_DATE}"
RESOLVED="0"   # fixed count from this run's delta; 0 on the first run
LINE="$(jq -c --arg d "$RUN_DATE" --argjson resolved "$RESOLVED" \
  '{run_date:$d, skill:"audit-gcp", overall:.score.overall, gate:.score.gate,
    end_to_end:.score.end_to_end, severity_counts:.severity_counts,
    lifecycle_counts:((reduce .findings[].lifecycle as $l ({}; .[$l] = (.[$l] // 0) + 1)) + {resolved:$resolved})}' \
  "$OUT/findings.json")"
TMP="$(mktemp)"
[ -f "${TARGET_DIR}/history.jsonl" ] && grep -v "\"run_date\":\"${RUN_DATE}\"" "${TARGET_DIR}/history.jsonl" > "$TMP" || true
printf '%s\n' "$LINE" >> "$TMP"
mv "$TMP" "${TARGET_DIR}/history.jsonl"
tail -1 "${TARGET_DIR}/history.jsonl" | jq -e '.run_date and (.overall >= 0)' >/dev/null && echo "history.jsonl updated"
```

The report's trend line renders the last five history.jsonl entries, oldest first; the ledger is derived and never drives finding lifecycle. Then send the Slack brief: titles only, never evidence values, hostnames, project ids, or endpoints:

```bash
set -eu
TARGET_DIR="./scoutflo-audits/gcp"
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${TARGET_DIR}/${RUN_DATE}"
TOPO_LINE="Topology readiness: readiness not recorded"  # replace with "r/n services sync-ready" from Phase 10
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
  jq -n --arg head "audit-gcp ${RUN_DATE}: ${SCORE}/100${MOVE:+ $MOVE}, ${E2E}. ${COUNTS}. ${CHECKS}." \
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
| No, catch-all, or dead notification channels | `setup-gcp#fix-notification-channels` |
| Policies with zero channels attached | `setup-gcp#attach-channels-to-policies` |
| Delivery never proven | `setup-gcp#prove-channel-delivery` |
| Forgotten or over-broad snoozes | `setup-gcp#review-snoozes` |
| Missing, noisy, or policy-less uptime checks, SSL expiry | `setup-gcp#fix-uptime-coverage` |
| Missing VM CPU tiers, dead filters, label-filter gaps | `setup-gcp#add-vm-pressure-policies` |
| Memory or disk claims without agent evidence | `setup-gcp#gate-memory-and-disk-on-the-ops-agent` |
| Missing GKE workload or node policies, Managed Prometheus drift | `setup-gcp#add-gke-health-policies` |
| Missing LB 5xx or latency policies | `setup-gcp#add-lb-alert-policies` |
| Missing or dead logs-based metrics, metric-without-policy | `setup-gcp#create-logs-based-metrics` |
| Vague documentation, missing severity, baseline-free thresholds | `setup-gcp#improve-alert-documentation` |
| Missing service dashboards, dashboard-without-alert | `setup-gcp#build-dashboards` |
| GKE components, backend health checks, get-health IAM, sinks, Ops Agent install, log bucket retention | `setup-gcp#plan-out-of-scope-changes` (plan only) |
| Topology readiness gaps with no finding | `/scoutflo:map-topology` |

## Common Failure Modes

All thresholds and windows named in the checks are example values; tune them to your workloads before treating a miss as a failure.

| Failure | Prevention |
| --- | --- |
| Wrong ambient project audited | Every command passes `--project "${GCP_PROJECT}"` from toolkit.yaml; the live-safety gate prints identity and target and stops on mismatch |
| Local gcloud config mutated to "fix" identity | `gcloud config set` and `configurations activate` are forbidden; identity comes from explicit flags and the documented auth paths |
| Permission error read as a resource problem | A `403` is evidence of a missing role or disabled API; record it and mark the check `blocked`, never "nothing exists" |
| LB health checks counted as alerting | Health checks eject backends silently; only Monitoring policies page; audit both, credit neither for the other |
| Uptime check credited while no policy rides it | `GCP-011` cross-references every check id against `check_passed` policy filters |
| Memory and disk coverage promised without the agent | Probe `agent.googleapis.com/agent/uptime` per VM before crediting any agent-dependent metric |
| Policy trusted whose filter matches zero series | Run every threshold condition filter against live timeSeries; zero series means the alert can never fire |
| `metadata.user_labels` filter assumed to work | Validate label-scoped filters against returned series or an API 400; label shape mismatches fail silently |
| Logs-based metric credited that matches nothing | `gcloud logging read` the exact filter with a freshness window; empty means decoration, not coverage |
| Channel webhook URLs leaked via labels | Capture label keys only, per the redaction procedure; never print label values |
| Toolkit brief webhook conflated with notification channels | Two different webhooks with two different jobs; flag any overlap as a finding |
| A full first page mistaken for the whole estate | Paginate every list; a page at pageSize means keep fetching |
