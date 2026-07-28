---
name: audit-lgtm
description: Read-only scored audit of LGTM and VictoriaMetrics observability stacks; writes findings.json and report.md. Use when the user mentions auditing or scoring Loki, Tempo, Mimir, VictoriaMetrics, VictoriaLogs, VictoriaTraces, vmalert, or Alertmanager, or asks whether metrics, logs, traces, or alerting are healthy or production-ready. Do not use for the Grafana application layer (use audit-grafana), for proving alerts reach a human (use audit-alert-routing), for application error tracking (use audit-sentry), for DigitalOcean-managed infrastructure (use audit-digitalocean), for GCP-managed infrastructure (use audit-gcp), or to change anything (use setup-lgtm).
---

# audit-lgtm

Scored, read-only audit of an LGTM stack (Loki, Grafana, Tempo, Mimir or Prometheus) or a VictoriaMetrics-family stack (VictoriaMetrics, VictoriaLogs, VictoriaTraces, vmalert), plus Alertmanager and the collectors that feed them. It answers one question: when something breaks tonight, can a responder detect it, identify the service, pull its logs and traces, and get paged on a receiver that actually delivers?

Every command in this audit is read-only: GET requests, read-only query calls, `kubectl get`. Nothing is created, silenced, test-fired, annotated, or modified. Some query endpoints are POST by protocol; they are classified read-only by effect and marked as such in [references/backend-checks.md](references/backend-checks.md). Fixes belong to `/scoutflo:setup-lgtm` and `/scoutflo:setup-grafana`. Firing a controlled test notification to prove delivery end to end is also a mutation; it lives in the setup lane, and `/scoutflo:audit-alert-routing` covers the deep read-only walk of the paging path.

Run this standalone, from `/scoutflo:audit-all`, or on a schedule via `/scoutflo:schedule-audits`.

Outputs, per the [report standard](../../report-standard/README.md):

- `./scoutflo-audits/lgtm/<YYYY-MM-DD>/findings.json` per the [findings schema](../../report-standard/findings-schema.md)
- `./scoutflo-audits/lgtm/<YYYY-MM-DD>/report.md` per the [report template](../../report-standard/report-template.md)
- One Slack brief, when `slack.webhook_env` is configured

## Doctor gate

Requirements. Configure only the blocks that exist in your environment; delete the rest from `~/.scoutflo/toolkit.yaml`. At least one metrics backend plus Grafana or Alertmanager must be configured for this audit to be worth running.

| Integration | toolkit.yaml keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| Metrics | `prometheus.url`, or `mimir.url` (+ `mimir.tenant_id`), or `victoriametrics.url` (+ `victoriametrics.vmalert_url`) | the `token_env` variable, if set | query and read APIs | read-only |
| Logs | `loki.url` | `loki.token_env`, if set | query and label APIs | read-only |
| Traces | `tempo.url` | `tempo.token_env`, if set | search and trace APIs | read-only |
| Alerting | `prometheus.alertmanager_url`, `victoriametrics.vmalert_url` | token, if fronted by auth | status, receivers, alerts | read-only |
| Grafana | `grafana.url` | `grafana.token_env` (`GRAFANA_TOKEN`) | service account: datasources, dashboards, and alert rules read | read-only |
| Kubernetes | `kubernetes.context`, `kubernetes.monitoring_namespace` | kubeconfig | get, list | read-only |
| Slack (optional) | `slack.webhook_env` | webhook variable | post to one channel | n/a |

Preflight. A failed check stops the audit with the exact failure and the fix (usually `/scoutflo:connect`). Never downgrade a doctor failure into a finding.

```bash
set -eu
CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
command -v curl >/dev/null || { echo "curl not installed"; exit 1; }
command -v jq   >/dev/null || { echo "jq not installed"; exit 1; }
command -v kubectl >/dev/null || echo "WARN: kubectl missing; cluster-side checks will be blocked"

# For every configured *_env key: presence only, never the value.
# Grafana is one of several optional blocks (see the requirements table above);
# only gate GRAFANA_TOKEN when a grafana block is actually configured in
# toolkit.yaml. LOKI_TOKEN, PROM_TOKEN, and TEMPO_TOKEN stay optional even when
# their blocks are configured (their endpoints may run open), so they are never
# gated here; each check block in references/backend-checks.md resolves them
# itself and falls back to an unauthenticated call when unset.
if grep -q '^grafana:' "$CFG"; then
  [ -n "${GRAFANA_TOKEN:-}" ] || { echo "grafana block configured but GRAFANA_TOKEN not set; run /scoutflo:connect"; exit 1; }
else
  echo "grafana block not configured in toolkit.yaml; Grafana and dashboard checks (Phase 9) will be marked not-in-scope"
fi
```

Then one cheap live call per configured integration (health or identity endpoint; exact commands in [references/backend-checks.md](references/backend-checks.md)). `/scoutflo:doctor` runs the same checks standalone.

Live-safety gate. Before the first real check, print what you are pointed at and compare it to the config:

```bash
set -eu
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
kubectl config current-context
kubectl --context "$KUBE_CONTEXT" auth whoami 2>/dev/null || kubectl --context "$KUBE_CONTEXT" version
```

If the resolved context or API identity differs from what `toolkit.yaml` names, stop and report the mismatch. Never proceed on "probably the right cluster". Every command in this skill names its target explicitly: `kubectl --context "$KUBE_CONTEXT"`, `curl` against a URL resolved from the config.

## Ground rules

- Config and inventory records are discovery metadata; live validation is proof. Credit nothing you did not query live this run.
- Evidence is real command output. An assertion without the command and its observed output is a suspicion, not a finding.
- API errors are evidence. A `401`, `403`, `404`, or timeout tells you: wrong path, wrong tenant, missing auth, wrong backend, blocked network. Never convert an upstream error into empty success.
- Never score from object counts. Forty dashboards and two hundred rules prove nothing; credit comes from meaningful queries returning data a responder could act on.
  - ❌ `Scored dashboards 100: forty dashboards exist in Grafana.`
  - ✅ `Scored dashboards 60: dashboards exist and datasources are healthy, but two critical services have no incident view (LGTM-051) and one dashboard has a dead datasource reference (LGTM-052), so credit stops short of full.`
- A successful API response is syntax evidence only. Check scope, labels, reducers, and pagination before trusting the number it shows.
- Respect tool ownership boundaries. A backend service absent from your error tracker is not automatically a gap when metrics, logs, and traces own backend incidents by decision; record the boundary and audit the owning stack. `/scoutflo:audit-sentry` covers the error-tracking side.
- Alerts are not live until the route reaches a receiver proven to deliver. Configured is `configured`, not working.
  - ❌ `LGTM-014 passed: the default route points at a receiver named "oncall-webhook".`
  - ✅ `LGTM-014 configured, not validated-live: the receiver name and route resolve, but no observed notification has reached it; delivery proof is a controlled test in setup-lgtm#test-fire-receivers, not this audit.`
- Never print, log, or write a secret: no tokens, webhook URLs, DSNs, auth headers, or rendered configs containing them, in terminal output or in any output file.

## Phase 1: Service context

If `./scoutflo-audits/topology.md` exists, load it. Its service list is your critical-service list and its names are the canonical names in findings, the coverage matrix, and `affected` arrays. If it does not exist, discover services live (Kubernetes workloads, trace `service.name` values, metric and log service labels), note in the report that the list was inferred, and suggest `/scoutflo:map-topology`. If live discovery contradicts topology.md, record the discrepancy in the report; only the mapping skill and you edit that file.

## Estate sizing

Count before judging, and declare the path in the terminal output. This count sizes how much ceremony the run uses; it never feeds the score itself (see the "never score from object counts" ground rule above; that rule is about credit, this is about proportionality).

The objects that actually drive this audit's cost are the ones Phases 6, 9, and 12 iterate per item: critical services (each gets a coverage-matrix row and a set of per-service queries) and Grafana dashboards (each gets a broken-panel and datasource check). Backend-level checks (Phases 2, 4, 5, 7, 8) run once per configured backend regardless of estate size and are never batched.

```bash
set -euo pipefail   # pipefail matters here: the DASHBOARDS fetch is a `curl | jq` pipe and
                    # /api/search needs dashboards:read (which the doctor gate does NOT prove
                    # — it only checks /api/health and /api/org). Without pipefail a 403 makes
                    # the pipe succeed with empty output, DASHBOARDS becomes empty, and
                    # $((SERVICES + )) silently sizes the estate as if there were zero
                    # dashboards (possibly picking small/medium when it is really large).
SMALL_MAX_OBJECTS="15"    # example, tune to your environment
MEDIUM_MAX_OBJECTS="60"   # example, tune to your environment
BATCH_SIZE="15"           # services per batch on the large path; example, tune it
GRAFANA_URL="https://grafana.example.com"   # grafana.url
GRAFANA_TOKEN="${GRAFANA_TOKEN:-}"          # grafana.token_env, set only if the grafana block is configured

SERVICES=0
if [ -f "${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/topology.md" ]; then
  # Count ONLY the rows of the `## Services` table. A bare `grep '^| ... |'` also
  # matches the metadata, Traffic-map, Entry-points, and Integration-watchpoints tables
  # (and header/`---` rows), so it double-counts every real service and scores phantom
  # rows named `---`/`Mesh` — inflating estate.objects ~6x and corrupting coverage.
  SERVICES="$(awk '/^## Services$/{f=1;next} /^## /{f=0} f' ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/topology.md \
    | grep -E '^\| ' \
    | grep -vE '^\| *Service *\||^\| *-{2,}' \
    | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); if($2!="") print $2}' \
    | sort -u | grep -c . || true)"
fi

DASHBOARDS=0
if [ -n "${GRAFANA_TOKEN:-}" ]; then
  # Guard the fetch: a dashboards:read 403 (doctor doesn't prove that scope) must surface,
  # not silently count as zero dashboards and mis-size the estate. On failure, say so.
  if ! DASHBOARDS="$(curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
      "${GRAFANA_URL}/api/search?type=dash-db&limit=500" | jq 'length')"; then
    echo "WARN: /api/search failed (likely missing dashboards:read) — dashboard count unknown; estate sizing is a floor, not the truth. Grant dashboards:read for an accurate size."
    DASHBOARDS=0
  fi
fi

TOTAL=$((SERVICES + DASHBOARDS))
path="large"
[ "${TOTAL}" -le "${MEDIUM_MAX_OBJECTS}" ] && path="medium"
[ "${TOTAL}" -le "${SMALL_MAX_OBJECTS}" ] && path="small"
echo "estate: services=${SERVICES} dashboards=${DASHBOARDS} scored_objects=${TOTAL} sizing-path=${path}"

# Guided-walkthrough drift check, per report-standard/README.md#using-topology-and-prior-runs-as-a-guided-walkthrough:
# compare against the last run rather than a blank slate. This stays in the SAME block as the
# TOTAL computed above; a separate fence would run in a fresh shell where $TOTAL is unbound and,
# under set -eu, abort. State the result in the executive summary; never silently omit it. This
# never skips a live check — every later-phase check still runs fresh regardless of drift status.
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm"
# Only date-named dirs are runs. The large path creates a persistent `runs/` sibling here;
# it sorts after the dates, so an unfiltered `tail -1` would pick `runs/` (no findings.json)
# and wrongly report "first run" on every repeat run once the large path has been used.
PREV_RUN="$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*-[0-9]*-[0-9]*' 2>/dev/null | sort | tail -1)"
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

- **Small** (`TOTAL <= SMALL_MAX_OBJECTS`): one pass over everything. No worklist, no batching; a handful of services and dashboards do not need bookkeeping.
- **Medium** (`TOTAL <= MEDIUM_MAX_OBJECTS`): per-category passes (Phases 6, 9, 12 run straight through their full service and dashboard lists), still completed in one run.
- **Large**: work services in batches of `BATCH_SIZE` against a durable, run-ID-keyed worklist, per [Large-path worklist: services in batches](#large-path-worklist-services-in-batches) below. Backend-level checks (Phases 2, 4, 5, 7, 8) still run once, un-batched.

Record `estate: {objects: TOTAL, path: path}` in `findings.json` per the [findings schema](../../report-standard/findings-schema.md). Never silently truncate a large estate: if the run judged a subset because it stopped early, the report names what was skipped and the coverage denominators reflect it.

- ❌ Built a worklist and ran service batches for a stack with 6 critical services and 4 dashboards.
- ✅ 10 scored objects is under `SMALL_MAX_OBJECTS`; declared the small path and ran Phases 6, 9, and 12 straight through, no worklist file.

## Phase 2: Read-only inventory

Build the raw picture before judging anything.

```bash
set -eu
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
MON_NS="monitoring"                # kubernetes.monitoring_namespace
kubectl --context "$KUBE_CONTEXT" get namespaces
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get deploy,sts,ds,svc,ingress,pvc
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get pods -o wide
helm --kube-context "$KUBE_CONTEXT" -n "$MON_NS" list 2>/dev/null \
  || echo "helm not installed; chart inventory skipped"
```

Expected: the monitoring namespace lists your telemetry stores (Loki, Tempo, Mimir, Prometheus, VictoriaMetrics components), Grafana, Alertmanager or vmalert, and collectors (Alloy, OTel Collector, Promtail, Fluent Bit, vmagent, exporters). Record what exists, replica counts, and PVC sizes as inventory, not yet as findings. Also inventory the data model as you go: metric names, label keys, log fields, trace attributes, service and environment label values, tenant labels. Note two collectors that are now end-of-life and superseded by **Grafana Alloy**: **Promtail** (EOL 2026-03-02) and **Grafana Agent** (EOL 2025-11-01). Finding either still running is a migration-debt signal scored under LGTM-025 (the image scan is in [references/backend-checks.md](references/backend-checks.md) section 11); record it and point at an Alloy migration.

## Phase 3: Tool ownership boundary

Write down which tool owns each incident area before scoring coverage:

| Incident area | Common owner |
| --- | --- |
| Frontend and app crashes | Error tracker (see `/scoutflo:audit-sentry`) |
| Backend service health | Prometheus, Mimir, or VictoriaMetrics |
| Backend logs | Loki or VictoriaLogs |
| Backend traces | Tempo or VictoriaTraces |
| Alert routing | Alertmanager, vmalert notifier, Grafana Alerting, paging service |
| Dashboards and incident views | Grafana |
| Managed database internals | The database provider's native observability first; exporters when needed |

Absence inside a tool that does not own the area is a boundary decision, not a gap. Score each signal against its owning backend only.

## Phase 4: Detect the deployed backends

The product name on the diagram is often not the process answering the URL. Loki-branded logs may be VictoriaLogs (LogsQL, not LogQL); Tempo-branded traces may be VictoriaTraces (Jaeger-shaped API); a "Mimir" endpoint may be plain Prometheus or VictoriaMetrics. Judging query failures against the wrong query language produces false findings, so detection comes before validation.

Run the detection recipes in [references/backend-checks.md](references/backend-checks.md) section 1 for each configured URL. Record advertised backend, detected backend, and query language. A mismatch is a finding (`LGTM-002`, `LGTM-021`, `LGTM-041`): not because the substitute is wrong, but because responders and dashboards built for the advertised API will use the wrong syntax against it.

## Phase 5: Validate each backend live

Work through [references/backend-checks.md](references/backend-checks.md) sections 2 through 10 for every backend that exists in your stack: health, smallest-useful query, rules, targets, ingestion health. Each check carries its catalog ID and states expected output and common failure shapes. Skip sections for backends you do not run; mark their checks `not-in-scope` only when the absence is a decision, and `fail` when the signal is supposed to exist but does not.

Managed Prometheus-compatible services expose the same query API behind cloud auth; run the Prometheus section through an authenticated proxy endpoint if you have one, otherwise mark those checks `blocked` with the reason. Log backends outside this family (for example Elasticsearch) are out of scope here; declare them `not-in-scope` and note the owning tool in the boundary table.

## Phase 6: Service coverage matrix

**Telemetry-scope gate first (LGTM-039), evaluated per critical service.** The configured backends are not guaranteed to monitor the cluster your kubeconfig happens to point at during this run: a central LGTM/VictoriaMetrics stack monitoring workloads on *other* clusters is a common, legitimate deployment, and the run's active kubectl context is frequently the telemetry stack's own cluster (reached by port-forward or a dedicated context) rather than the cluster the critical services actually run on. Before scoring any service, run the scope probe in [references/backend-checks.md](references/backend-checks.md) section 12: for each critical service, compare its **declared `attributes.cluster_id` from `topology-export.json`** (authoritative — written by `/scoutflo:map-topology`, not the live kubectl context) against the telemetry backend's cluster-identifying labels and node/namespace inventory. Only fall back to comparing the active kubectl context when a service has no `cluster_id` in the export. Per service, three outcomes:

- **Same cluster** (declared `cluster_id` found in the telemetry backend's cluster values/node inventory/namespace overlap) — proceed; coverage scoring below applies as written for that service.
- **Different or partially overlapping cluster** (declared `cluster_id` absent from the telemetry backend's side) — the backends monitor an estate that does not include this service. Mark that service's local-workload-derived row `blocked` (reason: telemetry backend monitors a different cluster), file it as `LGTM-039` (info) naming both cluster_ids as evidence, and say plainly in the report that this service's coverage was scoped to the telemetry estate, not its own cluster. **Never file LGTM-030 (or fail LGTM-032/033/034) for a service whose telemetry lives on a cluster these backends do not scrape — that is a scope mismatch, not missing coverage.** Likewise, service labels present in telemetry but matching no locally-declared service are *expected* here, not an orphan-label defect.
- **Cannot determine** (no `cluster_id` on that service in the export, and the kubectl-context fallback also finds no cluster-identifying labels, no `kube_*` inventory metrics, or too-thin namespace sets) — say so, score what is provable, and mark that service's row `blocked` with that stated reason. Score conservatively but never convert ambiguity into a critical finding.

A single run's services do not all have to land on the same outcome — one critical service can pass the gate (its telemetry backend genuinely covers it) while another is blocked (its cluster_id points elsewhere). Report the gate outcome per service, never as one collapsed verdict for the whole run.

Only after the gate: for every critical service from Phase 1, run the per-service coverage queries in [references/backend-checks.md](references/backend-checks.md) section 12 and fill one row:

| Service | Ready | Metrics | Logs | Traces | Alerts | View | Owner | Gap |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| checkout | 2/2 | pass | pass | fail | pass | partial | Known | no traces |

Use the check-result vocabulary (`pass`, `partial`, `fail`, `blocked`, `not-in-scope`) and canonical service names. Normalize aliases but never hide them: if one service appears under three different names across metrics, logs, and traces, that is a correlation finding (`LGTM-031`), and the diff belongs in evidence. Name affected services in findings; "three services lack log coverage" is not a finding, "checkout, payments, and search lack log coverage" is. A critical service with no telemetry in any signal is `LGTM-030`, critical severity — but only when the Phase 6 scope gate confirmed the backends actually monitor that service's cluster; a same-shaped zero on a different-cluster backend is `blocked` under `LGTM-039`, never LGTM-030.

- ❌ `LGTM-030 critical: local workloads have no matching telemetry label` — when the scope probe showed the backends scrape a different cluster.
- ✅ `LGTM-039 info: backends monitor cluster X while kubeconfig points at Y; local-workload coverage rows blocked, telemetry-estate services scored on their own labels.`

Then render the Scoutflo Topology Readiness section per [topology-readiness.md](../../report-standard/topology-readiness.md): evaluate T1 to T6 per critical service from `./scoutflo-audits/topology-export.json`, read-only. An edge this audit verified live (for example a `SENDS_METRICS_TO` edge to Prometheus/VictoriaMetrics this audit confirmed is actively scraped via the Phase 5 targets and ingestion checks) satisfies T4. **T6 needs one more thing T4 does not check**: the `serviceName` field (VictoriaLogs, Tempo, VictoriaTraces edges) and the `serviceLabel` field (Prometheus-family edges) are camelCase, and the platform's correlation-category mapping does not split camelCase, so populating only that field satisfies T4 but leaves T6's `service`-category anchor unpopulated (see [topology-readiness.md](../../report-standard/topology-readiness.md#t6s-category-mapping-is-stricter-than-a-providers-field-names-suggest)). Mirror that value into a literal `service` (or `service_name`) key on the same edge's attributes, or T6 will read `partial` even though the signal genuinely resolved to the right service. Loki's `app`/`namespace` fields do not have this problem. Gaps that map to an existing finding reference its ID; gaps with no finding get a `TOPO-` row pointing at `/scoutflo:map-topology`. Render check names and confidence per the standard: plain-English column headers (T-codes only in the legend line), confidence as `n/10`, and — whenever any service is below ready — the ticket-ready sync-readiness action plan table from [topology-readiness.md](../../report-standard/topology-readiness.md). If the export or topology.md is missing, or exists but describes a different target than this audit covers (wrong `cluster_id`, non-overlapping services), the section renders the matching state from topology-readiness.md with its one-line unlock (run `/scoutflo:map-topology` against the right estate, or hand-author the export per `scoutflo-export.md` for non-Kubernetes estates); it never guesses and never says a bare "unavailable". Readiness is reported, never folded into the 0-100 score.

## Phase 7: Alert routing, read-only

Prove as much of the paging path as reading allows (commands in [references/backend-checks.md](references/backend-checks.md) section 9):

- Alertmanager reachable, config parses, cluster ready (`LGTM-010`); at least one real receiver defined (`LGTM-011`).
- vmalert, if present, loads rules and points at a live notifier (`LGTM-012`).
- Notification failure counters flat at zero; a rising failed counter is delivery breaking right now (`LGTM-013`).
- Default route receiver is real: not a null receiver, not a loopback or placeholder webhook (`LGTM-014`).
- Severity-based routes exist so paging alerts reach a paging receiver (`LGTM-015`); grouping, inhibition, and repeat intervals are set (`LGTM-016`).
- Noise sources: rules with no `for` duration, pages on completed Jobs and CronJobs, dev namespaces routed to paging receivers (`LGTM-017`).
- Currently firing alerts each have an owner and an action; long-firing unacknowledged alerts are alarm fatigue in progress (`LGTM-018`).

Reading receivers and counters proves configuration and past delivery, not future delivery. Findings here are `validated-live` for what the API showed and `configured` for anything whose delivery was not observed. The controlled test notification that upgrades `configured` to proven belongs to `/scoutflo:setup-lgtm`.

## Phase 7b: Alert hygiene (ruler-native noise controls)

Phase 7 proved the paging path resolves to a receiver. This phase asks the narrower, backend-owned question: do the rule evaluators these stacks ship — vmalert, the Loki ruler, the Mimir ruler — carry the documented controls that keep the alert stream from becoming noise before it ever reaches Alertmanager? Every check is read-only and reads the ruler's own rules and config APIs (`/api/v1/rules`, `/flags`, `/config`, `/ruler/ring`). Commands are in [references/backend-checks.md](references/backend-checks.md) section 13. These checks join the Alert routing category (LGTM-070 to LGTM-073); they add no category and do not change its weight, they grow its denominator.

Honest ceiling, stated in the report every run:

- These are **structural** noise signals read off rule and ruler config — missing anti-flap holds, unbounded rule fan-out, re-notify cadence, duplicate evaluation. They are not an alert-to-incident actionability rate; this audit has no incident feed and never reports a fabricated "N% of alerts are actionable" number.
- Grouping, inhibition, silences, and mute/active time intervals are not implemented in vmalert or the Loki ruler at all. They live entirely in the Alertmanager (or Grafana) these rulers forward to, and are audited there by `/scoutflo:audit-alert-routing` and `/scoutflo:audit-grafana`, never re-checked here. Mimir bundles a per-tenant Alertmanager that consumes the identical Alertmanager config format; point those same routing, grouping, and inhibition checks at it per tenant (`X-Scope-OrgID`), do not reimplement them.
- Loki's ruler does not support `keep_firing_for`; where the detected log/rule backend is Loki, LGTM-070 is `not-in-scope`, stated, never a `fail`.
- Duplicate evaluation from unsharded HA rulers is deduplicated downstream by Alertmanager on identical label sets, so LGTM-073 is an evaluation-efficiency and cost signal more than raw page volume; say so rather than implying every operator is double-paged.

Checks:

- **LGTM-070 (anti-flap resolve hold).** vmalert exposes `keep_firing_for` and the Mimir ruler exposes `keepFiringFor` (camelCase over its Prometheus-format rules API): a hold that keeps an alert firing briefly after its condition clears, damping resolve/re-fire flapping. A paging-severity rule with a flap history (cross-check the firing churn already surfaced by Phase 7 / LGTM-018) and the hold at `0` has no damping. The Loki ruler has no such field, so on a Loki backend this check is `not-in-scope`.
- **LGTM-071 (bounded rule fan-out).** The vmalert group `limit` (`-rule.resultsLimit`) and the Loki per-group `limit` both default to `0` (unlimited). A high-cardinality expression with `limit == 0` can fan one rule out into a per-series alert storm. Note the exceed behavior both backends document: on overflow they discard the rule's **entire** result set (and set the rule to error), rather than truncating, so an over-tight limit is its own failure mode. `LIMIT_EXPECTED` is an example threshold, tune it to your rule cardinality.
- **LGTM-072 (re-notify and restart-state timing).** From vmalert `/flags` — `-rule.resendDelay` (default 1s), `-rule.maxResolveDuration` (default 4x the parent group's evaluation interval), and `-remoteWrite.url`/`-remoteRead.url` for `for`-state persistence across restarts — and from Loki `/config` — `ruler.resend_delay` (default 1m), `ruler.for_outage_tolerance` (default 1h), `ruler.for_grace_period` (default 10m). A `resendDelay` far below the notifier cadence re-pushes the same firing alert aggressively; outage/grace tolerances near zero re-arm every `for` window on a ruler restart, a thundering-herd re-page. The shipped defaults here are already sane, so flag deviations from them, not the defaults themselves; `MIN_RESEND_S` is an example floor, tune it.
- **LGTM-073 (no duplicate HA evaluation).** The Loki ruler evaluates every rule on every replica unless `ruler.enable_sharding == true`; read it from `/config` and confirm ring ownership at `/ruler/ring` (more than one active member with sharding off is duplicate evaluation). On the VM-family side, `-dedup.minScrapeInterval` on the datasource (`vmsingle`/`vmselect` `/flags`, default `0` = off) leaves HA writers' doubled samples reaching vmalert queries, which can drive spurious evaluations. Because Alertmanager dedup bounds the user-facing page count, score this as duplication and cost, medium at most.

Tempo carries no alerting of its own, so it gets no scored alert-rule check here. Its metrics-generator cardinality controls (`filter_policies`, `max_active_series`/`max_active_entities`, `registry.stale_duration`, `metrics_ingestion_time_range_slack`, `enable_target_info`, and friends) decide how many span and service-graph series reach the metrics backend, and those series are what downstream metric alert rules evaluate. Read them (section 13.4) only to explain a noisy *metric* alert, and record any finding against the owning metrics-layer or alert-routing check, never as a Tempo alert-rule score.

## Phase 8: Reliability, retention, and security

Inspection only, commands in [references/backend-checks.md](references/backend-checks.md) section 11: single-replica telemetry stores (`LGTM-060`), retention configuration (`LGTM-061`), backup and snapshot evidence (`LGTM-062`), public exposure of observability endpoints without auth (`LGTM-063`), NetworkPolicies and PodDisruptionBudgets in the monitoring namespace (`LGTM-064`), high-cardinality label values driving cost (`LGTM-065`), and secrets sitting in plain ConfigMaps or chart values (`LGTM-066`). Single-replica storage is a finding unless your team has explicitly accepted the RPO/RTO in writing and backups are proven; record the acceptance if it exists.

## Phase 9: Dashboards and correlation

Via the Grafana API ([references/backend-checks.md](references/backend-checks.md) section 10): Grafana and every datasource pass their health checks (`LGTM-050`); each critical service has an incident view linking its signals and active alerts (`LGTM-051`); no broken panels or dead datasource references in the dashboards responders use (`LGTM-052`); cross-signal pivots work, metrics to logs and trace to logs through the trace ID (`LGTM-053`); panel scope is honest, with no org-wide queries behind per-service titles and reducers matching the source shape (`LGTM-054`). A deeper Grafana-wide audit is `/scoutflo:audit-grafana`; this phase checks only what incident response needs from the LGTM side.

## Large-path worklist: services in batches

Runs on the large path only (see [Estate sizing](#estate-sizing) above). All state lives under a run-ID-keyed run directory `./scoutflo-audits/lgtm/runs/<RUN_ID>/`, not a calendar-date directory, so a run that is still batching when the date rolls over UTC keeps writing into the same place. Full runnable commands (resume scan, run-ID mint, worklist build, lock, batch claim, incremental report assembly) are in [references/estate-worklist.md](references/estate-worklist.md); this section states the workflow they implement.

1. **Find a resumable run, or start a new one.** Before minting a new `RUN_ID`, scan `./scoutflo-audits/lgtm/runs/*/worklist.tsv` for one with pending rows and offer to resume it instead of starting over.
2. **Build or resume the worklist.** One row per critical service (from Phase 1's topology.md list) plus one row per Grafana dashboard, status `pending` or `done`. A resumed run continues from its existing worklist; never rebuild one that already exists.
3. **Lock, then claim one batch.** Acquire `worklist.lock` in the run directory before reading pending rows; a lock older than `LOCK_STALE_MINUTES` (30 minutes; example, tune to your batch size) is abandoned and safe to reclaim. Take the next `BATCH_SIZE` pending rows and run Phase 6 (coverage), Phase 9 (dashboard checks), and section 12 of the reference against just that batch. A row is marked `done` only after its checks complete, so an interrupted batch resumes at the row that failed. Release the lock once the batch's rows are marked.
4. **Assemble incrementally.** After each batch, recompose the partial findings and coverage matrix from the batches completed so far, and print progress (`done=X pending=Y`). Repeat from step 3 until the worklist has zero pending rows, then proceed to Phase 10.

Two hard rules, matching the backend-level checks that never batch: Phases 2, 4, 5, 7, and 8 are cluster- or backend-scoped, not per-service, and always run once per run regardless of path. `findings.json` and `report.md` are written only once the worklist shows zero pending rows; a partial run's state stays in the run directory as the resume point and never overwrites the previous complete report.

## Phase 10: Score, write, brief

Score per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md): each check yields `pass` (1.0), `partial` (0.5), `fail`/`blocked` (0), with `not-in-scope` removed from the denominator; category score is the credit ratio times 100, rounded down; overall is the weight-normalized sum over included categories. Whole categories that could not be assessed are excluded, renormalized, and stated; blocked checks inside an assessable category score 0. Score conservatively: when unsure between two results, pick the lower and say why.

| Category | Weight | ID range |
| --- | ---: | --- |
| Service coverage | 20 | LGTM-030 to 039 |
| Metrics layer | 15 | LGTM-001 to 006 |
| Logs layer | 15 | LGTM-020 to 025 |
| Traces layer | 15 | LGTM-040 to 045 |
| Alert routing | 15 | LGTM-010 to 018, 070 to 073 |
| Dashboards and correlation | 10 | LGTM-050 to 054 |
| Reliability and security | 10 | LGTM-060 to 066 |

The full check catalog, one permanent ID per check with typical failure severity, is at the top of [references/backend-checks.md](references/backend-checks.md). IDs are stable; the same defect gets the same ID every run, which is what makes deltas exact. One finding per failed check, with every affected service enumerated in `affected`.

End-to-end gate: claim end-to-end coverage only when the overall score is at or above 85, every critical service passes every applicable coverage row, and no category was excluded. Below the gate, write "good base coverage" or "mostly covered", never "end to end".

### Lifecycle, exemptions, and totals

Before writing `findings.json` and `report.md`, since `findings.json` requires the `lifecycle` field on every finding:

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

Emit and verify:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm/${RUN_DATE}"
mkdir -p "$OUT"
# ... write findings.json (with lifecycle set per finding, and the estate
# object from the sizing pre-check) and report.md per the report standard,
# then verify:
jq -e '.schema == "scoutflo-findings/v1" and (.findings | type == "array") and (.findings | all(has("lifecycle")))' \
  "$OUT/findings.json" >/dev/null && echo "findings.json valid"
grep -q '^# ' "$OUT/report.md" && echo "report.md present"
# Output conformance: the emitted report.md must match report-standard/report-template.md.
# This catches header/score-line/section drift before the run is declared done.
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-report.sh" "$OUT/report.md"
ls -l "$OUT"
```

Compute the delta against the previous run date per the [report standard](../../report-standard/README.md); on the first run state "first run, no delta". After the report is written, close with the run-completion message per the report standard ([report-template.md](../../report-standard/report-template.md#run-completion-message-what-the-skill-says-in-chat-when-the-run-finishes)): the one-line score headline, the top fixes by points_recoverable, the **absolute** report path, the OS-specific open command, and the leak-safe share pointer (Slack brief). Then send the Slack brief, titles only, never evidence values:

```bash
set -eu
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm"
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${TARGET_DIR}/${RUN_DATE}"
# slack.webhook_env names the webhook variable; skip when unset.
if [ -n "${SCOUTFLO_SLACK_WEBHOOK:-}" ]; then
  SCORE="$(jq -r '.score.overall' "$OUT/findings.json")"
  E2E="$(jq -r 'if .score.end_to_end then "end-to-end" else "not end-to-end" end' "$OUT/findings.json")"
  COUNTS="$(jq -r '.severity_counts | "\(.critical) critical, \(.high) high, \(.medium) medium, \(.low) low"' "$OUT/findings.json")"
  TOP="$(jq -r '[.findings[] | "\(.id) \(.title)"] | .[0:5] | join("\n")' "$OUT/findings.json")"
  # Date-named run dirs only — exclude the persistent large-path `runs/` sibling, which
  # sorts after the dates and would otherwise be picked as today's OUT's predecessor,
  # falsely tripping "first run"/no-movement in the Slack brief.
  PREV="$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*-[0-9]*-[0-9]*' | sort | tail -2 | head -1)"
  MOVE=""; DELTA="first run"
  if [ -n "$PREV" ] && [ "$PREV" != "$OUT" ]; then
    MOVE="$(jq -rn --argjson prev "$(jq '.score.overall' "$PREV/findings.json")" --argjson cur "$SCORE" \
      '(($cur - $prev) | if . >= 0 then "(+\(.))" else "(\(.))" end)')"
    DELTA="$(jq -rn --slurpfile p "$PREV/findings.json" --slurpfile c "$OUT/findings.json" '
      [$p[0].findings[].id] as $b | [$c[0].findings[].id] as $n |
      "\(($b - $n) | length) fixed, \(($n - $b) | length) new, \(($n - ($n - $b)) | length) unchanged"')"
  fi
  jq -n --arg head "audit-lgtm ${RUN_DATE}: ${SCORE}/100${MOVE:+ $MOVE}, ${E2E}. ${COUNTS}." \
        --arg top "$TOP" --arg delta "$DELTA" --arg path "$OUT/report.md" \
        '{text: ($head + "\nTop findings:\n" + $top + "\nDelta: " + $delta + "\nReport: " + $path)}' \
    | curl -fsS --max-time 10 -H 'Content-Type: application/json' -d @- "$SCOUTFLO_SLACK_WEBHOOK" \
    || echo "Slack brief failed to send; audit result unaffected"
fi
```

When invoked by `audit-all`, skip the Slack brief; the orchestrator
sends exactly one combined message.

Keep `./scoutflo-audits/` out of public version control; reports describe your infrastructure.

## Remediation pointers

Every finding's `remediation` field points at the fix, so "Next safe actions" in the report starts at row 1 with no preparation:

| Finding area | Pointer |
| --- | --- |
| Dead or null default receiver, missing severity routes or inhibition | `setup-lgtm#fix-default-receiver`, `setup-lgtm#add-severity-routes-and-inhibition`; deep read-only path proof: `/scoutflo:audit-alert-routing` |
| Receivers `configured` but never proven to deliver | `setup-lgtm#test-fire-receivers` |
| Noisy rules, missing `for`, Jobs paging | `setup-lgtm#quiet-noisy-rules` |
| Service name mismatches across signals | `setup-lgtm#standardize-service-labels` |
| Missing signals for critical services, collector drops, tenant misconfig | `setup-lgtm` (label, collector, and tenant fixes; instrumentation gaps get a named owner) |
| Broken dashboards, dead datasources, dishonest panels | `/scoutflo:setup-grafana` |
| Single-replica storage, retention, backups, exposure, network policies | `setup-lgtm#set-retention`, `setup-lgtm#enable-ha`, `setup-lgtm#lock-down-exposure`, `setup-lgtm#add-network-policies`, `setup-lgtm#add-disruption-budgets` |

## Common Failure Modes

All thresholds and time windows named in the checks (`RECENT_WINDOW`, lookbacks, tolerances) are example values; tune them to your traffic and retention before treating a miss as a failure.

| Failure | Prevention |
| --- | --- |
| Loki syntax judged against VictoriaLogs | Detect the deployed backend and its query language (Phase 4) before scoring query failures |
| Tempo API used against VictoriaTraces | Validate the search path, API shape, and timestamp format before scoring the traces layer |
| Mimir claimed active while another engine serves the queries | Confirm the live process behind the metrics URL before recommending backend-specific work |
| Alerts exist but go nowhere | Read receivers, the default route, and notification-failure counters; rule lists prove nothing about delivery |
| Configured receiver counted as working | Mark it `configured`; only observed delivery upgrades it, and that test lives in the setup lane |
| Completed Jobs page as pods-not-ready | Check rules exclude Jobs, CronJobs, and expected terminal pods |
| Single-node storage passes silently | Record replicas, RPO/RTO acceptance, backups, and retention as explicit findings |
| Imported dashboards show empty panels | Validate panel queries and variables against real label values, not against render success |
| Trace coverage overclaimed | Query recent traces per service and name exactly the services with none |
| High-cardinality labels drive cost | Inspect label values for IDs, user names, sessions, and full URLs |
| Backend absence in the error tracker misreported as a gap | Record the ownership boundary (Phase 3) and audit the owning stack instead |
| Secrets leak into evidence | Record receiver host class and key names only; never webhook URLs, tokens, or rendered configs |
| Object counts scored as coverage | Credit only meaningful queries returning data a responder could act on |
| One environment's thresholds treated as universal | Declare every threshold as a named variable with a tune-to-your-environment note |
