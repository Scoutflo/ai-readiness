# audit-prometheus: Check Catalog and Commands

Runnable, read-only checks for every surface the [audit-prometheus](../SKILL.md) workflow covers. This audit reads **one** surface: the Prometheus HTTP API (`/api/v1/*`, `/-/healthy`, `/-/ready`) over `prometheus.url`. Each section lists the catalog IDs it serves, the exact read command, the healthy target, the finding it emits, and the mutations forbidden on that surface. Evidence for a finding is the command plus its observed output, trimmed with truncation marked.

## 1. Conventions

- The HTTP API paths below (`/api/v1/status/{buildinfo,runtimeinfo,flags,tsdb,config}`, `/api/v1/{targets,rules,alerts,alertmanagers,query,label/<name>/values}`, `/-/healthy`, `/-/ready`) are the **stable, documented Prometheus 2.x / 3.x API**. The rule-health (`/api/v1/rules`), target (`/api/v1/targets`), and sample-age (`time() - timestamp(up)`) reads were **confirmed on live reads** (as part of audit-lgtm / audit-alertmanager on the benchmark Prometheus). Anything marked **confirm-live** — the exact self-metric set exposed by *your* build, and whether a metric exists at all — must be resolved from the live `/metrics` or an instant query this run, never assumed. Never invent a metric, label, or endpoint.
- **Same server, three planes:** `prometheus.url` is a shared backend. This audit reads the *server + rule-engine* plane. `audit-lgtm` reads the *stores* (Loki/Tempo/Mimir/VictoriaMetrics) plane over their own URLs; `audit-alertmanager` reads the *Alertmanager* plane over `prometheus.alertmanager_url`. Do not read the Alertmanager API or a store's API from here.
- **Auth:** Prometheus has no native authz. Every call sends `Accept: application/json`, or `Authorization: Bearer <token>` when `prometheus.token_env` names a set variable. A `401`/`403` on `/api/v1/*` is an auth-scope problem (token missing/wrong), not a missing-rules or fleet-down problem. A `200` with an HTML body is an SSO/reverse-proxy/login page in front of the API — fail closed, never credit it.
- **Engine detection (rule + remote-write metrics differ by engine):** before reading a `prometheus_*` self-metric, detect the engine. Prometheus exposes `prometheus_build_info` and `prometheus_rule_*`; vmalert exposes `vmalert_*` and `vm_app_version` and has **no** `prometheus_rule_group_interval_seconds` analog; the Mimir ruler exposes `cortex_*`. An empty self-metric result **on the wrong engine** is `not observable`, never `healthy` — state which engine was detected.
- Presence-check tokens only; never echo, log, or write a secret value anywhere. A scrape target's `scrapeUrl`, an Alertmanager URL, or a remote-write queue URL can embed credentials in userinfo — record host/job/class only (loopback / private / public / placeholder), never the full URL.
- `curl -fsS --max-time 20` is the default. Where a status code is itself the evidence (the unauthenticated exposure probe in PROM-051), `-f` is dropped deliberately and `-w '%{http_code}'` is used; that block says so.
- Time windows and thresholds are examples; tune to your setup: `RANGE="1h"` for `increase()` windows, `FRESH_LAG_S=120` for scrape freshness, cardinality and churn thresholds per your series budget.

Helpers (declare once per session; every block below calls `pq` / `pqq`):

```bash
set -eu
# Resolve the shared prometheus block from ~/.scoutflo/toolkit.yaml via the shared enumerator (single
# mapping = target 0; this audit never iterates labels). url + the token_env VARIABLE NAME come from the
# block; the token value is read from the store with printenv — presence only, NEVER printed.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
PROM_URL=$(sh "$TT" "$CFG" prometheus get 0 url); PROM_URL="${PROM_URL%/}"
PROM_TOKEN_VAR=$(sh "$TT" "$CFG" prometheus get 0 token_env)
PROM_TOKEN=""; [ -n "$PROM_TOKEN_VAR" ] && PROM_TOKEN=$(printenv "$PROM_TOKEN_VAR" 2>/dev/null || true)
AUTH="Authorization: Bearer ${PROM_TOKEN}"; [ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"

# pq  <path>          -> GET a raw API path (e.g. /api/v1/targets?state=active). GET only.
# pqq <promql>        -> GET an instant query, url-encoded. GET only, no writes possible.
pq()  { curl -fsS --max-time 20 -H "$AUTH" "${PROM_URL}$1"; }
pqq() { curl -fsS --max-time 20 -H "$AUTH" --get --data-urlencode "query=$1" "${PROM_URL}/api/v1/query"; }

# Detect the rule/metrics engine once (drives which self-metric names are valid downstream).
ENGINE="unknown"
if   pq "/api/v1/status/buildinfo" | jq -e '.data.version' >/dev/null 2>&1; then ENGINE="prometheus"
elif pqq 'vmalert_iteration_total' | jq -e '.data.result | length > 0' >/dev/null 2>&1; then ENGINE="vmalert"
elif pqq 'cortex_build_info' | jq -e '.data.result | length > 0' >/dev/null 2>&1; then ENGINE="mimir"
fi
echo "prometheus target: ${PROM_URL}  engine=${ENGINE}"
```

## 2. Check catalog

One permanent ID per check. IDs never change or get reused; retired checks keep their number. Severity listed is the typical severity when the check fails; judge real impact in your environment.

| ID | Category | Check | Typical fail severity |
| --- | --- | --- | --- |
| PROM-001 | Server reachability and config | API reachable and healthy — `/-/healthy` 200, `vector(1)` status=success, buildinfo returns a version | critical |
| PROM-002 | Server reachability and config | Last config reload succeeded — `prometheus_config_last_reload_successful == 1` (a `0` means changes since are not applied) | high |
| PROM-003 | Server reachability and config | Runtime + retention posture — `runtimeinfo` corruption count, `flags` retention window | medium |
| PROM-007 | Scrape targets and coverage | Reachable Prometheus with **zero active targets and zero `up` series** (blocks coverage), or **zero loaded rules** (rules not-in-scope) — a visibility/config gap, never a confident 0 | info |
| PROM-010 | Scrape targets and coverage | Scrape targets healthy — no `health != "up"` target for a critical-service job (a down target reads stale, not absent) | high |
| PROM-011 | Scrape targets and coverage | Per-service `up == 1` **and** fresh — `time() - timestamp(up)` within threshold (up-but-stale = ingestion lag) | high |
| PROM-012 | Scrape targets and coverage | Scrape-config limits not breached — no `..._exceeded_sample_limit_total` / target-limit increase (series silently dropped while `up==1`) | medium |
| PROM-020 | Rule-engine health | Rules load and evaluate error-free — no `health != "ok"` and no non-empty `lastError` | high |
| PROM-021 | Rule-engine health | Rules evaluate on time — no group `evaluationTime > interval`, no `prometheus_rule_evaluation_failures_total` increase | medium |
| PROM-022 | Rule-engine health | Rules are backed by live metrics — each critical alerting rule's query metric returns data now; expected rules exist (rule presence) | high |
| PROM-023 | Rule-engine health | Notify path live — `/api/v1/alertmanagers` has an active AM and `prometheus_notifications_dropped_total` is flat (the Prometheus→AM hop; routing itself is audit-alertmanager) | high |
| PROM-030 | TSDB cardinality and storage | Cardinality — no runaway `labelValueCountByLabelName` / `seriesCountByMetricName` driven by IDs/emails/URLs | medium |
| PROM-031 | TSDB cardinality and storage | WAL + compaction integrity — no `wal_corruptions_total`, no `compactions_failed_total` increase, no failed truncations/reloads | high |
| PROM-032 | TSDB cardinality and storage | Head-series churn + growth — `head_series` and `rate(head_series_created_total[..])` not exploding relative to a flat total | medium |
| PROM-040 | Remote-write and federation | Remote-write health — `samples_pending` draining, shards below max, no `samples_failed/dropped_total` increase, write lag bounded (not-in-scope if no remote_write) | high |
| PROM-050 | Security posture | Destructive-API exposure — `--web.enable-admin-api` / `--web.enable-lifecycle` (delete_series / reload / quit reachable); enabled + unauth = critical | high |
| PROM-051 | Security posture | Transport + auth exposure — TLS on the wire; not reachable unauthenticated on a public host | high |

## 3. Server reachability and config reload (PROM-001, PROM-002, PROM-003)

### PROM-001 — reachable and healthy

```bash
# Health, API liveness (tests the API, not the fleet), and the version string.
pq "/-/healthy" ; echo " <- /-/healthy"
pqq 'vector(1)' | jq '.status'
pq "/api/v1/status/buildinfo" | jq '.data.version'
```

- **Healthy target:** `/-/healthy` returns `Prometheus ... Healthy`, `vector(1)` returns `"success"`, buildinfo returns a version.
- **Finding (PROM-001, critical):** an unreachable Prometheus is the root of a cascade, not a yes/no. Pull `/api/v1/rules` and `/api/v1/targets` first and state what goes dark — "this server loads N alerting rules (M at `severity=page`) and scrapes K critical services; while it is down every rule evaluates to no-data and pages nothing, and every service is unmonitored." This is an availability incident (restore/scale/failover the server), then close the HA gap that let one instance take the plane down.
- **Forbidden:** GET only; see section 9.

### PROM-002 — last config reload succeeded

```bash
# 1 = last reload OK; 0 = last reload FAILED (running config is the last-good one; changes since not applied).
pqq 'prometheus_config_last_reload_successful' | jq -r '.data.result[]? | "reload_ok=\(.value[1])"'
# How long the running config has been in effect (age of the last SUCCESSFUL reload):
pqq 'time() - prometheus_config_last_reload_success_timestamp_seconds' | jq -r '.data.result[]? | "seconds_since_last_good_reload=\(.value[1])"'
```

- **Healthy target:** `reload_ok=1`.
- **Finding (PROM-002, high):** `reload_ok=0` means the last attempted reload failed — new rules, targets, and remote-write config the operator added are **silently not live**; the server runs the last-good config while the file on disk has diverged. Blast radius: any alert or scrape added since the last good reload does not exist at runtime. Remediation: fix the config error the logs name, reload, and re-check this returns `1`.
- **Forbidden:** GET only.

### PROM-003 — runtime and retention posture

```bash
pq "/api/v1/status/runtimeinfo" | jq '.data | {storageRetention, corruptionCount, goroutineCount, timeSeriesCount: .timeSeriesCount?}'
pq "/api/v1/status/flags" | jq '.data | {retention_time: ."storage.tsdb.retention.time", retention_size: ."storage.tsdb.retention.size", admin_api: ."web.enable-admin-api", lifecycle: ."web.enable-lifecycle"}'
```

- **Healthy target:** a deliberate retention window that matches the team's stated need; `corruptionCount` is `0`.
- **Finding (PROM-003, medium):** a non-zero `corruptionCount` is a TSDB-integrity signal (cross-reference PROM-031); a retention window far shorter than the stated need is a data-availability posture note. The `admin_api`/`lifecycle` flags are read here and scored in PROM-050.
- **Forbidden:** GET only.

## 4. Scrape health and coverage (PROM-010, PROM-011, PROM-012)

### PROM-010 — scrape targets healthy

```bash
# Down/unhealthy active targets, grouped by scrape pool/job, with the last error.
pq "/api/v1/targets?state=active" \
  | jq -r '[.data.activeTargets[] | select(.health != "up")]
           | group_by(.scrapePool) | .[]
           | "\(.[0].scrapePool): \(length) down — e.g. \(.[0].labels.job) lastError=\(.[0].lastError)"'
# Census for PROM-007: how many active targets exist at all.
pq "/api/v1/targets?state=active" | jq '.data.activeTargets | length'
```

- **Healthy target:** every critical-service job appears with `health="up"`.
- **Finding (PROM-010, high):** a down target's data goes **stale, not absent** — dashboards and rules read the last-scraped value and look alive while the pod may be dead. Map each down target's `job`/`namespace`/`pod` to the critical set and name it in `affected`; a saturation or error there is invisible until scrape resumes. Zero active targets everywhere routes to PROM-007, not a confident fail. Remediation is inline (fix the ServiceMonitor/PodMonitor selector, the target port, or a relabel drop rule for the named job).
- **Forbidden:** GET only.

### PROM-011 — per-service coverage and freshness

```bash
# up per target: 1 = scraped OK, 0 = scrape failing. Zero SERIES = nothing scraped (routes to PROM-007).
pqq 'up' | jq -r '.data.result | length as $n | "up_series=\($n)"'
pqq 'up == 0' | jq -r '.data.result[]? | "\(.metric.job // .metric.instance) is up==0"'
# Real per-target sample age (verified live 0.4s..100s across many targets — does NOT collapse to 0).
pqq 'time() - timestamp(up)' | jq -r '[.data.result[].value[1]|tonumber] | "max_sample_age_s=\(max) targets=\(length)"'
# Widen the detection window to a target last seen up to 15m ago:
pqq 'time() - max_over_time(timestamp(up)[15m:1m])' | jq -r '[.data.result[]?.value[1]|tonumber] | "max_age_15m_window_s=\(if length>0 then max else 0 end)"'
```

- **Healthy target:** every critical-service job has `up == 1` and a sample age below `FRESH_LAG_S`.
- **Finding (PROM-011, high):** a critical service with **no `up` target** (zero series) is a coverage gap; a target `up == 1` whose newest sample is minutes old is an **ingestion-lag** gap — every rule with `for: Nm` on it pages ~N+lag late; the computed delay *is* the blast radius, distinct from a down target (PROM-010). Name the critical services in the lagging/absent set. Zero `up` series everywhere is PROM-007.
- **Forbidden:** GET only.

### PROM-012 — scrape-config limits not breached

```bash
# Silent series drops: a target hitting its sample_limit reads up==1 while data is thrown away.
for m in \
  prometheus_target_scrapes_exceeded_sample_limit_total \
  prometheus_target_scrape_pool_exceeded_target_limit_total \
  prometheus_target_scrapes_exceeded_body_size_limit_total \
  prometheus_target_scrapes_sample_out_of_order_total \
  prometheus_target_scrapes_exceeded_native_histogram_bucket_limit_total ; do
  # Confirmed live (Prometheus 3.14): these are GLOBAL counters, labelled only by the Prometheus
  # instance (`instance`/`job`), NOT by the scraped target — so sum to a total, never imply a per-job
  # attribution the metric can't give. A non-zero total means >=1 target breached; find which by reading
  # the scrape configs that set that limit.
  pqq "sum(increase(${m}[1h]))" \
    | jq -r --arg m "$m" '.data.result[]? | select((.value[1]|tonumber) > 0) | "\($m): +\(.value[1]) breach(es) in 1h (global counter — check scrape configs that set this limit)"'
done
```

- **Healthy target:** every counter's 1h increase is `0`.
- **Finding (PROM-012, medium):** a target hitting `sample_limit`/`target_limit`/`body_size_limit` has series **silently dropped** — it reads `up == 1` (PROM-010/011 pass) while data is discarded, so a metric the responder expects simply is not there. Name the job and the limit; remediation is inline (raise the limit in the scrape config, or reduce what the target exposes).
- **Forbidden:** GET only.

## 5. Rule-engine health (PROM-020, PROM-021, PROM-022, PROM-023) — flagship

Detect the engine (section 1) first; the `/api/v1/rules` `health`/`lastError` read is engine-agnostic (Prometheus **and** vmalert expose it), but the self-metric confirmations are engine-gated.

### PROM-020 — rules load and evaluate error-free

```bash
# Group + rule census, then every rule carrying a lastError or non-ok health.
pq "/api/v1/rules" | jq -r '.data.groups | length as $g | [.[].rules[]] | "\($g) groups, \(length) rules"'
pq "/api/v1/rules" | jq -r '.data.groups[].rules[]
  | select(((.health // "ok") != "ok") or ((.lastError // "") != ""))
  | "\(.type) \(.name) health=\(.health) severity=\(.labels.severity // "-") lastEvaluation=\(.lastEvaluation) lastError=\(.lastError)"'
```

- **Healthy target:** every rule has `health="ok"` and an empty `lastError`.
- **Finding (PROM-020, high):** a rule with `health != "ok"` or a non-empty `lastError` has fired zero times and never will until fixed. For each, resolve `.name`/`.labels`/`.query` to a topology service, read `.labels.severity`, and use `.lastEvaluation` for how long it has been broken — "`HighErrorRate{service=checkout}` severity=page has carried a PromQL parse error for 3 days; a spike tonight fires nothing." Blast radius: count of paging rules broken and critical services left with a dead rule. Remediation inline (fix the named rule's expression — the `lastError` says what).
- **Forbidden:** GET only.

### PROM-021 — rules evaluate on time

```bash
# A group whose evaluationTime exceeds its interval fires late / skips windows even with health=ok.
pq "/api/v1/rules" | jq -r '.data.groups[]
  | select((.evaluationTime // 0) > (.interval // 0))
  | "\(.name) eval=\(.evaluationTime)s > interval=\(.interval)s file=\(.file)"'
# Engine-gated confirmation (Prometheus). On vmalert, DROP the overrun query (no interval-seconds analog)
# and read vmalert_execution_errors_total / vmalert_alerting_rules_errors_total instead.
if [ "${ENGINE:-unknown}" = "prometheus" ]; then
  pqq 'sum by (rule_group) (increase(prometheus_rule_evaluation_failures_total[1h]))' \
    | jq -r '.data.result[]? | select((.value[1]|tonumber) > 0) | "\(.metric.rule_group): \(.value[1]) eval failures/1h"'
  pqq '(prometheus_rule_group_last_duration_seconds > prometheus_rule_group_interval_seconds)' \
    | jq -r '.data.result[]? | "\(.metric.rule_group): eval overran its interval"'
elif [ "${ENGINE:-unknown}" = "vmalert" ]; then
  pqq 'sum(increase(vmalert_execution_errors_total[1h]))' | jq -r '.data.result[]? | "vmalert exec errors/1h=\(.value[1])"'
fi
```

- **Healthy target:** no group evaluates slower than its interval; no eval-failure increase.
- **Finding (PROM-021, medium):** a group's `evaluationTime > interval` — every rule in it (including an SLO burn-rate page) evaluates late and can skip windows; a rule with no `lastError` (PROM-020 passes) can still be silently late here. An empty self-metric result on the *wrong* engine is `not observable`, never `healthy` — state the detected engine. Remediation inline (raise the group interval or split it).
- **Forbidden:** GET only.

### PROM-022 — rules are backed by live metrics (the correlation flagship)

The one failure that looks fine in `/api/v1/rules` (health=ok) **and** fine in `/api/v1/targets`, but is dead: a loaded, error-free alerting rule whose backing metric stopped being scraped evaluates to no-data forever and pages nobody.

```bash
# 1) Pull critical/paging alerting rules and their expressions.
pq "/api/v1/rules" | jq -r '.data.groups[].rules[]
  | select(.type=="alerting")
  | select((.labels.severity // "") | test("page|critical";"i"))
  | "\(.name)\t\(.query)"'

# 2) For each rule, extract the metric names its expression reads and confirm each returns data NOW.
#    (Extract the bare metric identifiers from the printed query, then, per metric M:)
#    pqq "count(M)" | jq -r '.data.result[0].value[1] // "0"'
#    A metric that returns 0 (or empty) is the dead-rule root cause — the rule can never fire.

# 3) Rule presence: an EXPECTED paging rule for a critical service that does not exist at all.
#    Compare the critical-service list (topology.md) against the alerting-rule names above; a critical
#    service with no owning paging rule is a PROM-022 presence gap, not a broken rule.
```

- **Healthy target:** every critical/paging rule's backing metric(s) return data now, and every critical service has an owning paging rule.
- **Finding (PROM-022, high):** a rule whose query metric returns `0`/empty is dead — name the rule, the missing metric, and the critical service; chain it to the metric's scrape (PROM-011) and, if that scrape is down, to PROM-010. A critical service with no paging rule at all is a presence gap. Remediation inline (fix the *scrape* of the metric — then confirm `count(<metric>) > 0` and the rule's `health` returns to `ok` — or author the missing rule).
- **Forbidden:** GET only.

### PROM-023 — the notify path is live (the seam with audit-alertmanager)

```bash
# Does Prometheus have a live Alertmanager to send to, and is it dropping notifications?
pq "/api/v1/alertmanagers" | jq -r '{active: (.data.activeAlertmanagers | length), dropped: (.data.droppedAlertmanagers | length)}'
pqq 'increase(prometheus_notifications_dropped_total[1h])' | jq -r '.data.result[]? | "dropped_notifications/1h=\(.value[1])"'
pqq 'prometheus_notifications_queue_length / prometheus_notifications_queue_capacity' | jq -r '.data.result[]? | "notif_queue_fill=\(.value[1])"'
```

- **Healthy target:** at least one **active** Alertmanager, `dropped_notifications/1h == 0`, queue fill well below `1`.
- **Finding (PROM-023, high):** zero active Alertmanagers means a firing rule pages nobody (Prometheus has nowhere to send); a rising `prometheus_notifications_dropped_total` or a saturated queue means notifications are being dropped before they leave Prometheus. This is the **seam**: PROM-023 proves only the Prometheus→Alertmanager hop exists and is not dropping — the routing tree, silences, receivers, and delivery to a human are `/scoutflo:audit-alertmanager`. If there are no alerting rules and no configured Alertmanager, PROM-023 is `not-in-scope`, not a fail. Remediation inline (configure `alerting.alertmanagers`, confirm the AM lists active).
- **Forbidden:** GET only.

## 6. TSDB cardinality and storage (PROM-030, PROM-031, PROM-032)

### PROM-030 — cardinality

```bash
pq "/api/v1/status/tsdb" | jq '{headSeries: .data.headStats.numSeries,
  topMetrics: [.data.seriesCountByMetricName[0:10][] | {name: .name, series: .value}],
  topLabels:  [.data.labelValueCountByLabelName[0:10][] | {label: .name, values: .value}],
  topPairs:   [.data.seriesCountByLabelValuePair[0:10][] | {pair: .name, series: .value}]}'
```

- **Healthy target:** no single label with a runaway distinct-value count; top metrics/pairs proportionate to your series budget.
- **Finding (PROM-030, medium):** a label whose `labelValueCountByLabelName` is driven by IDs, emails, session tokens, or full URLs is the classic cardinality/cost gap — it bloats the head, slows every query, and inflates remote-write. Name the metric or label and its count; apply `cost_sensitivity` to ordering. Remediation inline (`metric_relabel_configs` `labeldrop`/`drop`, or fix the instrumentation).
- **Forbidden:** GET only.

### PROM-031 — WAL and compaction integrity

```bash
for m in \
  prometheus_tsdb_wal_corruptions_total \
  prometheus_tsdb_wal_truncations_failed_total \
  prometheus_tsdb_head_truncations_failed_total \
  prometheus_tsdb_reloads_failures_total ; do
  pqq "$m" | jq -r --arg m "$m" '.data.result[]? | select((.value[1]|tonumber) > 0) | "\($m)=\(.value[1])"'
done
pqq 'increase(prometheus_tsdb_compactions_failed_total[6h])' | jq -r '.data.result[]? | select((.value[1]|tonumber) > 0) | "compactions_failed/6h=\(.value[1])"'
```

- **Healthy target:** every counter is `0`.
- **Finding (PROM-031, high):** a WAL corruption or a failing compaction risks data loss and lets the head grow unbounded until the process OOMs — the *symptom* is head growth, the *cause* is a broken block lifecycle (distinct from cardinality). Treat as a storage incident (disk full, permissions, corruption); a persistent corruption may need a controlled restart to replay. Remediation inline.
- **Forbidden:** GET only.

### PROM-032 — head-series churn and growth

```bash
pqq 'prometheus_tsdb_head_series' | jq -r '.data.result[]? | "head_series=\(.value[1])"'
pqq 'sum(rate(prometheus_tsdb_head_series_created_total[1h]))' | jq -r '.data.result[]? | "series_created_per_s(1h)=\(.value[1])"'
pqq 'sum(rate(prometheus_tsdb_head_series_removed_total[1h]))' | jq -r '.data.result[]? | "series_removed_per_s(1h)=\(.value[1])"'
```

- **Healthy target:** creation rate roughly balances removal against a stable `head_series` total.
- **Finding (PROM-032, medium):** a high series-*creation* rate relative to a flat total means labels are constantly born and retired (pod-name/UUID/build-hash labels) — a slow-motion cardinality explosion that PROM-030's point-in-time snapshot understates, driving memory and query cost. Record the churn rate and the labels driving it. Remediation inline (drop the churning label).
- **Forbidden:** GET only.

## 7. Remote-write and federation (PROM-040)

Only when the remote-write self-metrics exist; a pure local-TSDB Prometheus has none → PROM-040 `not-in-scope`.

```bash
# Presence gate: no remote_write self-metrics => not-in-scope, never a fail.
if pqq 'prometheus_remote_storage_samples_pending' | jq -e '.data.result | length > 0' >/dev/null 2>&1; then
  # Key the display on remote_name only (operator-set name, or a Prometheus-generated hash) — NEVER the
  # `url` label, which can carry basic-auth userinfo (https://user:pass@host/...) and would leak a secret.
  pqq 'prometheus_remote_storage_samples_pending' | jq -r '.data.result[]? | "\(.metric.remote_name // "queue"): pending=\(.value[1])"'
  pqq 'prometheus_remote_storage_shards' | jq -r '.data.result[]? | "shards=\(.value[1])"'
  pqq 'prometheus_remote_storage_shards_max' | jq -r '.data.result[]? | "shards_max=\(.value[1])"'
  pqq 'increase(prometheus_remote_storage_samples_failed_total[1h])' | jq -r '.data.result[]? | select((.value[1]|tonumber) > 0) | "samples_failed/1h=\(.value[1])"'
  pqq 'increase(prometheus_remote_storage_samples_dropped_total[1h])' | jq -r '.data.result[]? | select((.value[1]|tonumber) > 0) | "samples_dropped/1h=\(.value[1])"'
  # Write lag: how far behind the remote endpoint is (highest local ts minus highest sent ts).
  pqq 'prometheus_remote_storage_highest_timestamp_in_seconds - ignoring(remote_name,url) group_right prometheus_remote_storage_queue_highest_sent_timestamp_seconds' \
    | jq -r '.data.result[]? | "write_lag_s=\(.value[1])"'
else
  echo "no prometheus_remote_storage_* self-metrics — remote-write not configured; PROM-040 not-in-scope"
fi
```

- **Healthy target:** `pending` drains, `shards` below `shards_max`, no failed/dropped increase, write lag bounded.
- **Finding (PROM-040, high):** a backlogged (`pending` climbing), saturated (`shards == shards_max`), or failing remote-write means long-term storage (Mimir/Thanos/VictoriaMetrics) is **missing samples right now** — dashboards and long-range/burn-rate alerts that read the remote store go blind while the local Prometheus looks fine. Name the queue and the observed backlog/lag. Remediation inline (fix the remote endpoint's auth/throughput/limits, or tune `queue_config`).
- **Forbidden:** GET only.

## 8. Security posture (PROM-050, PROM-051)

### PROM-050 — destructive-API exposure

```bash
# Read the flags. NEVER call the destructive endpoints they gate.
# Flags live under .data (confirmed live on Prometheus 3.14) and each value is a STRING
# ("true"/"false") — compare to the string, never rely on jq truthiness (the string "false" is truthy).
pq "/api/v1/status/flags" | jq '.data | {admin_api: ."web.enable-admin-api", lifecycle: ."web.enable-lifecycle"}'
```

- **Healthy target:** `web.enable-admin-api` is `false` unless deliberately needed; if `true`, the endpoint is behind auth on a private network.
- **Finding (PROM-050):** `web.enable-admin-api=true` means `POST /api/v1/admin/tsdb/delete_series` and `.../clean_tombstones` are **reachable** — anyone who can reach the API can delete series; `web.enable-lifecycle=true` means `POST /-/reload` and `POST /-/quit` are reachable (reload/shutdown). Enabled **and** unauthenticated **and** on a non-loopback host = **critical** (open destructive control). Enabled behind auth = a medium posture note. This audit reads the flag; it never exercises the endpoint. Remediation inline (disable the flag if unused, or put it behind an auth proxy).
- **Forbidden:** GET only — **never** `POST /api/v1/admin/tsdb/delete_series`, `/-/reload`, or `/-/quit`; see section 9.

### PROM-051 — transport and auth exposure

This probe sends **no** credentials, so the status code is the evidence and `-f` is dropped deliberately:

```bash
# Is the API reachable with NO credential? (On a public host, an unauth 200 = the whole metrics store is exposed.)
curl -s -o /dev/null -w 'unauth /api/v1/status/buildinfo: %{http_code}\n' --max-time 10 "${PROM_URL}/api/v1/status/buildinfo"
# TLS on the wire:
printf '%s\n' "$PROM_URL" | grep -qE '^https://' && echo "TLS: audit endpoint is https" || echo "TLS: audit endpoint is plaintext http — confirm this is loopback/port-forward, else a finding"
```

- **Healthy target:** on a public host the unauthenticated probe returns an auth-required status (behind a proxy); a plaintext `http://` endpoint is loopback/port-forward only.
- **Finding (PROM-051, high):** an unauthenticated `200` on a non-loopback/public host means the entire metrics store — and any sensitive values in metric labels — is readable by anyone who reaches it; plaintext `http://` across an untrusted network carries any bearer token in clear. Record the host class (loopback / private / public) and TLS state. Remediation inline (auth proxy + TLS, or move off public ingress to a private network / port-forward).
- **Forbidden:** GET only.

## 9. Forbidden mutations

This audit is strictly read-only. Every command above is a `GET` on the Prometheus HTTP API — `/api/v1/*` reads, instant queries (`GET /api/v1/query`), `/-/healthy`, `/-/ready`. The following are **never** issued from audit-prometheus; each is a change that a human applies by hand under the inline remediation pointers, never from this audit:

- **Destructive admin API:** `POST /api/v1/admin/tsdb/delete_series`, `POST /api/v1/admin/tsdb/clean_tombstones`, `POST /api/v1/admin/tsdb/snapshot`. Gated by `--web.enable-admin-api`; this audit reads the flag (PROM-050), it never calls these.
- **Lifecycle:** `POST /-/reload`, `POST /-/quit`. Gated by `--web.enable-lifecycle`; read about (PROM-050), never called.
- **Any non-GET** on any `/api/v1/*` route. Prometheus's query API is read-only by design; there is no "harmless" write. A write attempt is a bug in the skill, not a finding — if any block above ever seems to need a mutation to produce evidence, that is the wrong command: read the state instead, and apply the change by hand per the remediation pointer.
