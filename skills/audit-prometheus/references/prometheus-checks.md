# audit-prometheus: Check Catalog and Commands

Runnable, read-only checks for every surface the [audit-prometheus](../SKILL.md) workflow covers. This audit reads **one** surface: the Prometheus HTTP API (`/api/v1/*`, `/-/healthy`, `/-/ready`) over `prometheus.url`. Each section lists the catalog IDs it serves, the exact read command, the healthy target, the finding it emits, and the mutations forbidden on that surface. Evidence for a finding is the command plus its observed output, trimmed with truncation marked.

## Target profile

A 100/100 result means all applicable, assessed checks meet these published targets;
blocked reads never earn credit. Provider limitations and declared exclusions stay
visible outside the assessed denominator. This score is a posture measure, not an
uptime guarantee or proof of alert delivery.

| Category | Healthy target |
| --- | --- |
| Server reachability and config | Healthy API/query responses, successful reload and deliberate retention; retired endpoints classified separately |
| Scrape targets and coverage | Critical targets are observed, healthy and fresh, with collection limits respected |
| Rule-engine health | Required rules load, evaluate on time against live metrics and have an observed notification next hop |
| TSDB cardinality and storage | Cardinality/churn stays within declared budgets; no observed WAL or compaction corruption |
| Remote-write and federation | Configured remote-write queues drain without observed drops or excessive lag |
| Security posture | Deliberate access controls and TLS; destructive administrative endpoints are not exposed unnecessarily |

## 1. Conventions

- The HTTP API paths below (`/api/v1/status/{buildinfo,runtimeinfo,flags,tsdb,config}`, `/api/v1/{targets,rules,alerts,alertmanagers,query,label/<name>/values}`, `/-/healthy`, `/-/ready`) are the **stable, documented Prometheus 2.x / 3.x API**. The rule-health (`/api/v1/rules`), target (`/api/v1/targets`), and sample-age (`time() - timestamp(up)`) reads were **confirmed on live reads** (as part of audit-lgtm / audit-alertmanager on the benchmark Prometheus). Anything marked **confirm-live** — the exact self-metric set exposed by *your* build, and whether a metric exists at all — must be resolved from the live `/metrics` or an instant query this run, never assumed. Never invent a metric, label, or endpoint.
- **Same server, three planes:** `prometheus.url` is a shared backend. This audit reads the *server + rule-engine* plane. `audit-lgtm` reads the *stores* (Loki/Tempo/Mimir/VictoriaMetrics) plane over their own URLs; `audit-alertmanager` reads the *Alertmanager* plane over `prometheus.alertmanager_url`. Do not read the Alertmanager API or a store's API from here.
- **Auth:** Prometheus has no native authz. Every call sends `Accept: application/json`, or `Authorization: Bearer <token>` when `prometheus.token_env` names a set variable. A `401`/`403` on `/api/v1/*` is an auth-scope problem (token missing/wrong), not a missing-rules or fleet-down problem. A `200` with an HTML body is an SSO/reverse-proxy/login page in front of the API — fail closed, never credit it.
- **Engine detection (rule + remote-write metrics differ by engine):** before reading a `prometheus_*` self-metric, detect the engine. Prometheus exposes `prometheus_build_info` and `prometheus_rule_*`; vmalert exposes `vmalert_*` and `vm_app_version` and has **no** `prometheus_rule_group_interval_seconds` analog; the Mimir ruler exposes `cortex_*`. An empty self-metric result **on the wrong engine** is `not observable`, never `healthy` — state which engine was detected.
- Presence-check tokens only; never echo, log, or write a secret value anywhere. A scrape target's `scrapeUrl`, an Alertmanager URL, or a remote-write queue URL can embed credentials in userinfo — record host/job/class only (loopback / private / public / placeholder), never the full URL.
- `curl -fsS --max-time 20` is the default. Where a status code is itself the evidence (the unauthenticated exposure probe in PROM-051), `-f` is dropped deliberately and `-w '%{http_code}'` is used; that block says so.
- Time windows and thresholds are examples; tune to your setup: `RANGE="1h"` for `increase()` windows, `FRESH_LAG_S=120` for scrape freshness, cardinality and churn thresholds per your series budget.

Each command block sources the shared config/auth/HTTP helper in its own fresh shell:

```bash
. "${CLAUDE_PLUGIN_ROOT:?plugin root is required}/skills/audit-prometheus/scripts/prometheus-http.sh"
```

## 2. Check catalog

One permanent ID per check. IDs never change or get reused; retired checks keep their number. Severity listed is the typical severity when the check fails; judge real impact in your environment.

| ID | Category | Check | Typical fail severity |
| --- | --- | --- | --- |
| PROM-001 | Server reachability and config | API reachable and healthy — `/-/healthy` 200, `vector(1)` status=success, buildinfo returns a version | critical |
| PROM-002 | Server reachability and config | Last config reload succeeded — `prometheus_config_last_reload_successful == 1` (a `0` means changes since are not applied) | high |
| PROM-003 | Server reachability and config | Runtime + retention posture — `runtimeinfo` corruption count, `flags` retention window | medium |
| PROM-007 | Scrape targets and coverage | Reachable Prometheus with **zero active targets and zero `up` series** (blocks coverage), or **zero loaded rules** (rules not-in-scope) — a visibility/config gap, never a confident 0 | info |
| PROM-010 | Scrape targets and coverage | Scrape targets healthy — no `health != "up"` target for a critical-service job (inspect actual series and sample age for a down target) | high |
| PROM-011 | Scrape targets and coverage | Per-service `up == 1` **and** fresh — `time() - timestamp(up)` within threshold (up-but-stale = ingestion lag) | high |
| PROM-012 | Scrape targets and coverage | Scrape-config limits not breached — no `..._exceeded_sample_limit_total` / target-limit increase (correlate with target scrape errors) | medium |
| PROM-020 | Rule-engine health | Rules load and evaluate error-free — no `health != "ok"` and no non-empty `lastError` | high |
| PROM-021 | Rule-engine health | Rules evaluate on time — no group `evaluationTime > interval`, no `prometheus_rule_evaluation_failures_total` increase | medium |
| PROM-022 | Rule-engine health | Rules are backed by live metrics — each critical alerting rule's query metric returns data now; expected rules exist (rule presence) | high |
| PROM-023 | Rule-engine health | Notify path live — `/api/v1/alertmanagers` has an active AM and `prometheus_notifications_dropped_total` is flat (the Prometheus→AM hop; routing itself is audit-alertmanager) | high |
| PROM-030 | TSDB cardinality and storage | Cardinality — no runaway `labelValueCountByLabelName` / `seriesCountByMetricName` driven by IDs/emails/URLs | medium |
| PROM-031 | TSDB cardinality and storage | WAL + compaction integrity — no `wal_corruptions_total`, no `compactions_failed_total` increase, no failed truncations/reloads | high |
| PROM-032 | TSDB cardinality and storage | Head-series churn + growth — `head_series` and `rate(head_series_created_total[..])` not exploding relative to a flat total | medium |
| PROM-040 | Remote-write and federation | Remote-write health — `samples_pending` draining, shards below max, no `samples_failed/dropped_total` increase, write lag bounded (not-in-scope if no remote_write) | high |
| PROM-050 | Security posture | Admin/lifecycle flags plus read-only access-policy evidence of exposure | high |
| PROM-051 | Security posture | Transport + auth exposure — TLS on the wire; not reachable unauthenticated on a public host | high |

## 3. Server reachability and config reload (PROM-001, PROM-002, PROM-003)

### PROM-001 — reachable and healthy

```bash
. "${CLAUDE_PLUGIN_ROOT:?plugin root is required}/skills/audit-prometheus/scripts/prometheus-http.sh"
# Health, API liveness (tests the API, not the fleet), and the version string.
HEALTH=$(pq "/-/healthy") || { echo "PROM-001 blocked: health response unavailable; classify the observed HTTP/access error before a server verdict"; exit 1; }
printf '%s\n' "$HEALTH"
RESPONSE=$(pqq_json 'vector(1)') || exit 1
printf '%s' "$RESPONSE" | jq '.status'
RESPONSE=$(pq_json "/api/v1/status/buildinfo") || exit 1
printf '%s' "$RESPONSE" | jq '.data.version'
```

- **Healthy target:** `/-/healthy` returns `Prometheus ... Healthy`, `vector(1)` returns `"success"`, buildinfo returns a version.
- **DNS classification (on a resolution failure, sharpens the PROM-001 evidence).** A missing DNS record and an unreachable server need different investigation. Query the zone's authoritative nameserver, read the DNS `status`, and check that the zone apex also answers authoritatively. This establishes DNS evidence only; separate retirement evidence is required before removing the configured target. All `dig` lookups are read-only:

```bash
# PROM-001 DNS classification: self-contained and read-only; no token is needed.
set -eu
CFG="${SCOUTFLO_CONFIG:-}"
[ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done
[ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:?plugin root is required}/report-standard/toolkit-targets.sh"
[ -f "$CFG" ] || { echo "PROM-001 blocked: configuration is missing"; exit 0; }
[ "$(sh "$TT" "$CFG" prometheus kind)" != seq ] || { echo "PROM-001 blocked: give the selected Prometheus target a single-block config"; exit 0; }
PROM_URL=$(sh "$TT" "$CFG" prometheus get 0 url)
HOST=${PROM_URL#*://}; HOST=${HOST%%/*}; HOST=${HOST##*@}; HOST=${HOST%%:*}
case "$HOST" in ''|*[!a-zA-Z0-9.-]*) echo "PROM-001 blocked: DNS classifier requires a DNS hostname"; exit 0;; esac
command -v dig >/dev/null 2>&1 || { echo "PROM-001 blocked: dig is unavailable; install DNS tools or obtain authoritative evidence separately"; exit 0; }
# Discover the closest enclosing DNS zone, rather than guessing a two-label TLD.
ZONE=$HOST; NS=""
while :; do
  NS=$(dig +time=5 +tries=1 +short NS "$ZONE" 2>/dev/null | head -1) || NS=""
  [ -z "$NS" ] || break
  case "$ZONE" in *.*) ZONE=${ZONE#*.};; *) break;; esac
done
[ -n "$NS" ] || { echo "PROM-001 blocked: no authoritative nameserver found"; exit 0; }
ANSWER=$(dig +time=5 +tries=1 +norecurse "@$NS" "$HOST" A +noall +comments 2>/dev/null) || ANSWER=""
APEX=$(dig +time=5 +tries=1 +norecurse "@$NS" "$ZONE" SOA +noall +comments 2>/dev/null) || APEX=""
STATUS=$(printf '%s\n' "$ANSWER" | sed -n 's/.*status: \([A-Z]*\),.*/\1/p' | head -1)
if ! printf '%s\n' "$ANSWER" | grep -Eq 'flags: ([^;]* )?aa( |;)'; then
  echo "PROM-001 blocked: response is not authoritative"; exit 0
fi
case "$STATUS" in
  NXDOMAIN)
    if printf '%s\n' "$APEX" | grep -q 'status: NOERROR,' && printf '%s\n' "$APEX" | grep -Eq 'flags: ([^;]* )?aa( |;)'; then
      echo "PROM-001 evidence: authoritative DNS record absent; corroborate decommissioning before target-gone, otherwise blocked"
    else echo "PROM-001 blocked: zone apex also failed; resolver or network failure remains possible"; fi ;;
  SERVFAIL) echo "PROM-001 blocked: DNS delegation or DNSSEC failure" ;;
  NOERROR) echo "PROM-001 blocked: DNS exists; restore the network or API read path before judging server health" ;;
  *) echo "PROM-001 blocked: no conclusive authoritative answer" ;;
esac
```

- **The classification above decides the verdict — it is not decoration.** The outcomes need opposite responses, and reporting the wrong one is the fastest way to lose a reader who knows the estate. **Every branch the classifier can print has a row here; there is no default.** Note that only the last row is a finding about the *server*, because only the last row has evidence about the server:

  | Classification the block printed | PROM-001 result | What to say |
  | --- | --- | --- |
  | Authoritative DNS record absent, **apex resolves**, and independent lifecycle evidence or operator confirmation says the endpoint was deliberately retired | `not-in-scope`, `not_in_scope_reason: target-gone` | Cite both pieces of evidence and retarget/remove the stale `prometheus:` block. **Never** a restore/scale/failover recommendation |
  | Authoritative DNS absence without corroborated retirement, missing `dig`, or a non-authoritative answer | `blocked` | A missing record is not proof that the server was deleted. Establish the intended endpoint/lifecycle before choosing a remedy |
  | NXDOMAIN but **the apex also failed** | `blocked` | The classifier itself says this cannot be told apart from a resolver/network failure. Re-run from a working resolver before concluding anything. **Not** `target-gone` |
  | SERVFAIL | `blocked` | A broken zone delegation or DNSSEC — upstream of this server and says nothing about its health. Fix the zone, then re-run |
  | No authoritative answer for the host | `blocked` | We could not even ask. Classify manually (`dig NS <zone>`; `dig @<ns> <host>`) and re-run |
  | NOERROR at the authoritative NS, local path failed | `blocked` | The name exists, the path is down. Unlock the read (VPN, ingress, port-forward), then re-run — the server's health is still unknown |
  | **Reachable**, but unhealthy | `fail` (severity `critical`) | A real availability incident — the finding below |

  The healthy path is `pass`. Everything except the corroborated-retirement and reachable-unhealthy rows is `blocked`: a DNS answer that does not authoritatively prove absence is **evidence about DNS, not about the server**, and filing "restore or fail over the server" on it is the same wrong-finding class this release exists to remove. A timeout or refused connection is likewise `blocked`, never `target-gone` — it is indistinguishable from a firewall you are not behind. Authoritative NXDOMAIN proves the DNS name is absent; it requires separate retirement evidence before the configured server is classified as gone. Full rules: [not-in-scope-reasons.md](../../../report-standard/not-in-scope-reasons.md).

- **Finding (PROM-001, critical) — only on the reachable-but-unhealthy path:** a reachable but unhealthy Prometheus can interrupt monitoring. If access allows, pull `/api/v1/rules` and `/api/v1/targets` first and state what goes dark — "this server loads N alerting rules (M at `severity=page`) and scrapes K critical services; these are the observed dependencies at risk." Never invent counts when those reads fail, and do not assume redundancy or actual delivery impact from server health alone. Investigate the observed failure and verify redundancy before recommending restoration or failover; one unhealthy endpoint does not prove a plane-wide outage or an HA gap.
- **On the `target-gone` path, the cascade framing is wrong and must not be emitted.** Nothing "goes dark" — it went dark when the server was deleted, and the rules and targets you would enumerate no longer exist to enumerate. Report the stale config, and if this was the only metrics backend, that absence is a separate, honest finding about the estate having no metrics plane — not about this host being down.
- **Forbidden:** GET only; see section 9.

### PROM-002 — last config reload succeeded

```bash
. "${CLAUDE_PLUGIN_ROOT:?plugin root is required}/skills/audit-prometheus/scripts/prometheus-http.sh"
# 1 = last reload OK; 0 = last reload FAILED (running config is the last-good one; changes since not applied).
RESPONSE=$(pqq_json 'prometheus_config_last_reload_successful') || exit 1
printf '%s' "$RESPONSE" | jq -r '.data.result[]? | "reload_ok=\(.value[1])"'
# How long the running config has been in effect (age of the last SUCCESSFUL reload):
RESPONSE=$(pqq_json 'time() - prometheus_config_last_reload_success_timestamp_seconds') || exit 1
printf '%s' "$RESPONSE" | jq -r '.data.result[]? | "seconds_since_last_good_reload=\(.value[1])"'
```

- **Healthy target:** `reload_ok=1`.
- **Finding (PROM-002, high):** `reload_ok=0` means the last attempted reload failed — new rules, targets, and remote-write config the operator added are **silently not live**; the server runs the last-good config while the file on disk has diverged. Blast radius: any alert or scrape added since the last good reload does not exist at runtime. Remediation: fix the config error the logs name, reload, and re-check this returns `1`.
- **Forbidden:** GET only.

### PROM-003 — runtime and retention posture

```bash
. "${CLAUDE_PLUGIN_ROOT:?plugin root is required}/skills/audit-prometheus/scripts/prometheus-http.sh"
RESPONSE=$(pq_json "/api/v1/status/runtimeinfo") || exit 1
printf '%s' "$RESPONSE" | jq '.data | {storageRetention, corruptionCount, goroutineCount, timeSeriesCount: .timeSeriesCount?}'
RESPONSE=$(pq_json "/api/v1/status/flags") || exit 1
printf '%s' "$RESPONSE" | jq '.data | {retention_time: ."storage.tsdb.retention.time", retention_size: ."storage.tsdb.retention.size", admin_api: ."web.enable-admin-api", lifecycle: ."web.enable-lifecycle"}'
```

- **Healthy target:** a deliberate retention window that matches the team's stated need; `corruptionCount` is `0`.
- **Finding (PROM-003, medium):** a non-zero `corruptionCount` is a TSDB-integrity signal (cross-reference PROM-031); a retention window far shorter than the stated need is a data-availability posture note. The `admin_api`/`lifecycle` flags are read here and scored in PROM-050.
- **Forbidden:** GET only.

## 4. Scrape health and coverage (PROM-010, PROM-011, PROM-012)

### PROM-010 — scrape targets healthy

```bash
. "${CLAUDE_PLUGIN_ROOT:?plugin root is required}/skills/audit-prometheus/scripts/prometheus-http.sh"
# Down/unhealthy active targets, grouped by scrape pool/job, with the last error.
RESPONSE=$(pq_json "/api/v1/targets?state=active") || exit 1
printf '%s' "$RESPONSE" | jq -r '[.data.activeTargets[] | select(.health != "up")]
           | group_by(.scrapePool) | .[]
           | "\(.[0].scrapePool): \(length) down — e.g. \(.[0].labels.job) lastError=\(.[0].lastError)"'
# Census for PROM-007: how many active targets exist at all.
RESPONSE=$(pq_json "/api/v1/targets?state=active") || exit 1
printf '%s' "$RESPONSE" | jq '.data.activeTargets | length'
```

- **Healthy target:** every critical-service job appears with `health="up"`.
- **Finding (PROM-010, high):** a failed scrape interrupts fresh collection. Existing series may become stale or absent depending on the engine and query window; inspect actual series and sample age before claiming impact. Map each down target's `job`/`namespace`/`pod` to the critical set and name it in `affected`; a saturation or error there is invisible until scrape resumes. Zero active targets everywhere routes to PROM-007, not a confident fail. Remediation is inline (fix the ServiceMonitor/PodMonitor selector, the target port, or a relabel drop rule for the named job).
- **Forbidden:** GET only.

### PROM-011 — per-service coverage and freshness

```bash
. "${CLAUDE_PLUGIN_ROOT:?plugin root is required}/skills/audit-prometheus/scripts/prometheus-http.sh"
# up per target: 1 = scraped OK, 0 = scrape failing. Zero SERIES = nothing scraped (routes to PROM-007).
RESPONSE=$(pqq_json 'up') || exit 1
printf '%s' "$RESPONSE" | jq -r '.data.result | length as $n | "up_series=\($n)"'
RESPONSE=$(pqq_json 'up == 0') || exit 1
printf '%s' "$RESPONSE" | jq -r '.data.result[]? | "\(.metric.job // .metric.instance) is up==0"'
# Real per-target sample age (verified live 0.4s..100s across many targets — does NOT collapse to 0).
RESPONSE=$(pqq_json 'time() - timestamp(up)') || exit 1
printf '%s' "$RESPONSE" | jq -r '[.data.result[].value[1]|tonumber] | "max_sample_age_s=\(max) targets=\(length)"'
# Widen the detection window to a target last seen up to 15m ago:
RESPONSE=$(pqq_json 'time() - max_over_time(timestamp(up)[15m:1m])') || exit 1
printf '%s' "$RESPONSE" | jq -r '[.data.result[]?.value[1]|tonumber] | "max_age_15m_window_s=\(if length>0 then max else 0 end)"'
```

- **Healthy target:** every critical-service job has `up == 1` and a sample age below `FRESH_LAG_S`.
- **Finding (PROM-011, high):** a critical service with **no `up` target** (zero series) is a coverage gap; a target `up == 1` whose newest sample is minutes old is an **ingestion-lag** gap — every rule with `for: Nm` on it pages ~N+lag late; the computed delay *is* the blast radius, distinct from a down target (PROM-010). Name the critical services in the lagging/absent set. Zero `up` series everywhere is PROM-007.
- **Forbidden:** GET only.

### PROM-012 — scrape-config limits not breached

```bash
. "${CLAUDE_PLUGIN_ROOT:?plugin root is required}/skills/audit-prometheus/scripts/prometheus-http.sh"
# Scrape-limit rejection: correlate these counters with failed scrapes and target errors.
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
  RESPONSE=$(pqq_json "sum(increase(${m}[1h]))") || exit 1
  printf '%s' "$RESPONSE" | jq -r --arg m "$m" '.data.result[]? | select((.value[1]|tonumber) > 0) | "\($m): +\(.value[1]) breach(es) in 1h (global counter — check scrape configs that set this limit)"'
done
```

- **Healthy target:** every counter's 1h increase is `0`.
- **Finding (PROM-012, medium):** exceeded sample/body-size limits reject the affected scrape. Target-limit failures and out-of-order samples have distinct causes; inspect target errors and the relevant live limit before naming impact. Do not claim `up == 1` or identify a job from a global counter alone. Fix the evidenced limit or reduce scrape volume, then verify successful collection.
- **Forbidden:** GET only.

## 5. Rule-engine health (PROM-020, PROM-021, PROM-022, PROM-023) — flagship

Detect the engine (section 1) first; the `/api/v1/rules` `health`/`lastError` read is engine-agnostic (Prometheus **and** vmalert expose it), but the self-metric confirmations are engine-gated.

### PROM-020 — rules load and evaluate error-free

```bash
. "${CLAUDE_PLUGIN_ROOT:?plugin root is required}/skills/audit-prometheus/scripts/prometheus-http.sh"
# Group + rule census, then every rule carrying a lastError or non-ok health.
RESPONSE=$(pq_json "/api/v1/rules") || exit 1
printf '%s' "$RESPONSE" | jq -r '.data.groups | length as $g | [.[].rules[]] | "\($g) groups, \(length) rules"'
RESPONSE=$(pq_json "/api/v1/rules") || exit 1
printf '%s' "$RESPONSE" | jq -r '.data.groups[].rules[]
  | select(((.health // "ok") != "ok") or ((.lastError // "") != ""))
  | "\(.type) \(.name) health=\(.health) severity=\(.labels.severity // "-") lastEvaluation=\(.lastEvaluation) lastError=\(.lastError)"'
```

- **Healthy target:** every rule has `health="ok"` and an empty `lastError`.
- **Finding (PROM-020, high):** non-ok health or a nonempty `lastError` records an evaluation failure. `lastEvaluation` is the latest attempt, not error onset; prior firing and failure duration require history. Name the observed rule, its mapped service and current error, then fix that expression and verify subsequent evaluations. Never infer three days of failure from one timestamp.
- **Forbidden:** GET only.

### PROM-021 — rules evaluate on time

```bash
. "${CLAUDE_PLUGIN_ROOT:?plugin root is required}/skills/audit-prometheus/scripts/prometheus-http.sh"
# A group whose evaluationTime exceeds its interval fires late / skips windows even with health=ok.
RESPONSE=$(pq_json "/api/v1/rules") || exit 1
printf '%s' "$RESPONSE" | jq -r '.data.groups[]
  | select((.evaluationTime // 0) > (.interval // 0))
  | "\(.name) eval=\(.evaluationTime)s > interval=\(.interval)s file=\(.file)"'
# Engine-gated confirmation (Prometheus). On vmalert, DROP the overrun query (no interval-seconds analog)
# and read vmalert_execution_errors_total / vmalert_alerting_rules_errors_total instead.
if [ "${ENGINE:-unknown}" = "prometheus" ]; then
  RESPONSE=$(pqq_json 'sum by (rule_group) (increase(prometheus_rule_evaluation_failures_total[1h]))') || exit 1
  printf '%s' "$RESPONSE" | jq -r '.data.result[]? | select((.value[1]|tonumber) > 0) | "\(.metric.rule_group): \(.value[1]) eval failures/1h"'
  RESPONSE=$(pqq_json '(prometheus_rule_group_last_duration_seconds > prometheus_rule_group_interval_seconds)') || exit 1
  printf '%s' "$RESPONSE" | jq -r '.data.result[]? | "\(.metric.rule_group): eval overran its interval"'
elif [ "${ENGINE:-unknown}" = "vmalert" ]; then
  RESPONSE=$(pqq_json 'sum(increase(vmalert_execution_errors_total[1h]))') || exit 1
  printf '%s' "$RESPONSE" | jq -r '.data.result[]? | "vmalert exec errors/1h=\(.value[1])"'
fi
```

- **Healthy target:** no group evaluates slower than its interval; no eval-failure increase.
- **Finding (PROM-021, medium):** a group's `evaluationTime > interval` — every rule in it (including an SLO burn-rate page) evaluates late and can skip windows; a rule with no `lastError` (PROM-020 passes) can still be silently late here. An empty self-metric result on the *wrong* engine is `not observable`, never `healthy` — state the detected engine. Remediation inline (raise the group interval or split it).
- **Forbidden:** GET only.

### PROM-022 — rules are backed by live metrics (the correlation flagship)

A positive-signal rule can evaluate without errors while a required selector has no data. Inspect the full expression and service scope; absence-alert designs intentionally handle missing input and must be judged differently.

```bash
. "${CLAUDE_PLUGIN_ROOT:?plugin root is required}/skills/audit-prometheus/scripts/prometheus-http.sh"
# 1) Pull critical/paging alerting rules and their expressions.
RESPONSE=$(pq_json "/api/v1/rules") || exit 1
printf '%s' "$RESPONSE" | jq -r '.data.groups[].rules[]
  | select(.type=="alerting")
  | select((.labels.severity // "") | test("page|critical";"i"))
  | "\(.name)\t\(.query)"'

# 2) Inspect each full expression and its exact label selectors, preserving job/service scope.
#    For ordinary positive-signal rules, query each exact selector with pqq_json.
#    A successful empty selector is missing evidence for THAT scope, not every service.
#    For absent()/absent_over_time() rules, missing input is the intended trigger:
#    evaluate the full rule expression and expected absence window; never call it dead.
#    An empty full expression may simply mean a threshold is not breached.
#    Unsupported/ambiguous expression analysis is blocked; never replace it with count(M).

# 3) Rule presence: an EXPECTED paging rule for a critical service that does not exist at all.
#    Compare the critical-service list (topology.md) against the alerting-rule names above; a critical
#    service with no owning paging rule is a PROM-022 presence gap, not a broken rule.
```

- **Healthy target:** required rules exist and their full expressions work as intended, including absence alerts; selector-specific evidence is available for positive-signal rules.
- **Finding (PROM-022, high):** a positive-signal rule whose exact required selector is successfully observed empty can have a backing-data gap. Name that selector and service and correlate its scrape evidence. For absence alerts, empty input may be correct; evaluate intended absence behavior. A zero-valued series is present data, not an absent metric. Do not diagnose dead rules from `count(<metric>)` or an empty filtered expression. Unsupported analysis stays `blocked`. A missing required rule is a separate presence gap.
- **Forbidden:** GET only.

### PROM-023 — the notify path is live (the seam with audit-alertmanager)

```bash
. "${CLAUDE_PLUGIN_ROOT:?plugin root is required}/skills/audit-prometheus/scripts/prometheus-http.sh"
# Does Prometheus have a live Alertmanager to send to, and is it dropping notifications?
RESPONSE=$(pq_json "/api/v1/alertmanagers") || exit 1
printf '%s' "$RESPONSE" | jq -r '{active: (.data.activeAlertmanagers | length), dropped: (.data.droppedAlertmanagers | length)}'
RESPONSE=$(pqq_json 'increase(prometheus_notifications_dropped_total[1h])') || exit 1
printf '%s' "$RESPONSE" | jq -r '.data.result[]? | "dropped_notifications/1h=\(.value[1])"'
# sum()/max() is load-bearing, not style: on Prometheus 3.14 (confirmed live) queue_length carries
# an `alertmanager` label while queue_capacity has none, so a bare division fails vector matching
# and returns EMPTY — which reads as "healthy" when the queue could be saturating.
RESPONSE=$(pqq_json 'sum(prometheus_notifications_queue_length) / max(prometheus_notifications_queue_capacity)') || exit 1
printf '%s' "$RESPONSE" | jq -r '.data.result[]? | "notif_queue_fill=\(.value[1])"'
```

- **Healthy target:** at least one **active** Alertmanager, `dropped_notifications/1h == 0`, queue fill well below `1`.
- **Finding (PROM-023, high):** zero active Alertmanagers means a firing rule pages nobody (Prometheus has nowhere to send); a rising `prometheus_notifications_dropped_total` or a saturated queue means notifications are being dropped before they leave Prometheus. This is the **seam**: PROM-023 proves only the Prometheus→Alertmanager hop exists and is not dropping — the routing tree, silences, receivers, and delivery to a human are `/scoutflo:audit-alertmanager`. If there are no alerting rules and no configured Alertmanager, PROM-023 is `not-in-scope`, not a fail. Remediation inline (configure `alerting.alertmanagers`, confirm the AM lists active).
- **Forbidden:** GET only.

## 6. TSDB cardinality and storage (PROM-030, PROM-031, PROM-032)

### PROM-030 — cardinality

```bash
. "${CLAUDE_PLUGIN_ROOT:?plugin root is required}/skills/audit-prometheus/scripts/prometheus-http.sh"
RESPONSE=$(pq_json "/api/v1/status/tsdb") || exit 1
printf '%s' "$RESPONSE" | jq '{headSeries: .data.headStats.numSeries,
  topMetrics: [.data.seriesCountByMetricName[0:10][] | {name: .name, series: .value}],
  topLabels:  [.data.labelValueCountByLabelName[0:10][] | {label: .name, values: .value}],
  topPairs:   [.data.seriesCountByLabelValuePair[0:10][] | {pair: .name, series: .value}]}'
```

- **Healthy target:** no single label with a runaway distinct-value count; top metrics/pairs proportionate to your series budget.
- **Finding (PROM-030, medium):** a label whose `labelValueCountByLabelName` is driven by IDs, emails, session tokens, or full URLs is the classic cardinality/cost gap — it bloats the head, slows every query, and inflates remote-write. Name the metric or label and its count; apply `cost_sensitivity` to ordering. Remediation inline (`metric_relabel_configs` `labeldrop`/`drop`, or fix the instrumentation).
- **Forbidden:** GET only.

### PROM-031 — WAL and compaction integrity

```bash
. "${CLAUDE_PLUGIN_ROOT:?plugin root is required}/skills/audit-prometheus/scripts/prometheus-http.sh"
for m in \
  prometheus_tsdb_wal_corruptions_total \
  prometheus_tsdb_wal_truncations_failed_total \
  prometheus_tsdb_head_truncations_failed_total \
  prometheus_tsdb_reloads_failures_total ; do
  RESPONSE=$(pqq_json "$m") || exit 1
  printf '%s' "$RESPONSE" | jq -r --arg m "$m" '.data.result[]? | select((.value[1]|tonumber) > 0) | "\($m)=\(.value[1])"'
done
RESPONSE=$(pqq_json 'increase(prometheus_tsdb_compactions_failed_total[6h])') || exit 1
printf '%s' "$RESPONSE" | jq -r '.data.result[]? | select((.value[1]|tonumber) > 0) | "compactions_failed/6h=\(.value[1])"'
```

- **Healthy target:** every counter is `0`.
- **Finding (PROM-031, high):** a WAL corruption or a failing compaction risks data loss and lets the head grow unbounded until the process OOMs — the *symptom* is head growth, the *cause* is a broken block lifecycle (distinct from cardinality). Treat as a storage incident (disk full, permissions, corruption); a persistent corruption may need a controlled restart to replay. Remediation inline.
- **Forbidden:** GET only.

### PROM-032 — head-series churn and growth

```bash
. "${CLAUDE_PLUGIN_ROOT:?plugin root is required}/skills/audit-prometheus/scripts/prometheus-http.sh"
RESPONSE=$(pqq_json 'prometheus_tsdb_head_series') || exit 1
printf '%s' "$RESPONSE" | jq -r '.data.result[]? | "head_series=\(.value[1])"'
RESPONSE=$(pqq_json 'sum(rate(prometheus_tsdb_head_series_created_total[1h]))') || exit 1
printf '%s' "$RESPONSE" | jq -r '.data.result[]? | "series_created_per_s(1h)=\(.value[1])"'
RESPONSE=$(pqq_json 'sum(rate(prometheus_tsdb_head_series_removed_total[1h]))') || exit 1
printf '%s' "$RESPONSE" | jq -r '.data.result[]? | "series_removed_per_s(1h)=\(.value[1])"'
```

- **Healthy target:** creation rate roughly balances removal against a stable `head_series` total.
- **Finding (PROM-032, medium):** a high series-*creation* rate relative to a flat total means labels are constantly born and retired (pod-name/UUID/build-hash labels) — a slow-motion cardinality explosion that PROM-030's point-in-time snapshot understates, driving memory and query cost. Record the churn rate and the labels driving it. Remediation inline (drop the churning label).
- **Forbidden:** GET only.

## 7. Remote-write and federation (PROM-040)

A successful empty self-metric query does not prove remote-write is absent: the
server may not scrape its own metrics. Failed reads are `blocked`. Only a
successful live-config read that proves an empty `remote_write` section makes
this check `not-in-scope`; record `inapplicable` and that evidence.

```bash
. "${CLAUDE_PLUGIN_ROOT:?plugin root is required}/skills/audit-prometheus/scripts/prometheus-http.sh"
# PROM-040 presence: distinguish failed, unobserved and explicitly absent.
PENDING=$(pqq_json 'prometheus_remote_storage_samples_pending') \
  || { echo "PROM-040 blocked: remote-write metric read failed"; exit 1; }
if [ "$(printf '%s' "$PENDING" | jq '.data.result | length')" -eq 0 ]; then
  CONFIG_BODY=$(pq_json '/api/v1/status/config') \
    || { echo "PROM-040 blocked: self-metrics absent and live config unreadable"; exit 1; }
  CONFIG_YAML=$(printf '%s' "$CONFIG_BODY" | jq -er '.data.yaml | select(type=="string" and length>0)') \
    || { echo "PROM-040 blocked: no readable live YAML config"; exit 1; }
  # Require an explicit empty field; missing/quoted/complex YAML stays unknown.
  if printf '%s\n' "$CONFIG_YAML" | grep -Eq '^remote_write:[[:space:]]*\[\][[:space:]]*$'; then
    echo "PROM-040 not-in-scope (inapplicable): live config explicitly has remote_write: []"
  else
    echo "PROM-040 blocked: self-metrics absent; live config does not prove remote-write is empty"
  fi
  exit 0
fi
# Key the display on remote_name, never the url label (which can contain secrets).
printf '%s' "$PENDING" | jq -r '.data.result[] | "\(.metric.remote_name // "queue"): pending=\(.value[1])"'
for QUERY in 'prometheus_remote_storage_shards' 'prometheus_remote_storage_shards_max' \
  'increase(prometheus_remote_storage_samples_failed_total[1h])' \
  'prometheus_remote_storage_highest_timestamp_in_seconds - ignoring(remote_name,url) group_right prometheus_remote_storage_queue_highest_sent_timestamp_seconds'; do
  RESULT=$(pqq_json "$QUERY") || { echo "PROM-040 blocked: required queue evidence unreadable"; exit 1; }
  if [ "$(printf '%s' "$RESULT" | jq '.data.result | length')" -eq 0 ]; then
    echo "PROM-040 blocked: required queue metric not observed on this engine"
  else
    printf '%s' "$RESULT" | jq -r '.data.result[] | "queue=\(.metric.remote_name // "queue") value=\(.value[1])"'
  fi
done
# Optional counter varies by build; a failed read is still different from absence.
DROPPED=$(pqq_json 'increase(prometheus_remote_storage_samples_dropped_total[1h])') \
  || { echo "PROM-040 blocked: optional drop-counter read failed"; exit 1; }
if [ "$(printf '%s' "$DROPPED" | jq '.data.result | length')" -eq 0 ]; then
  echo "samples_dropped_total not observed on this build; judge observed failures and lag"
else
  printf '%s' "$DROPPED" | jq -r '.data.result[] | "samples_dropped/1h=\(.value[1])"'
fi
```

- **Healthy target:** `pending` drains, `shards` below `shards_max`, no failed/dropped increase, write lag bounded.
- **Finding (PROM-040, high):** a backlogged (`pending` climbing), saturated (`shards == shards_max`), or failing remote-write indicates delivery pressure or errors; confirm ingestion freshness on the remote store before claiming lost samples or unavailable dashboards. Name the queue and the observed backlog/lag. Remediation inline (fix the remote endpoint's auth/throughput/limits, or tune `queue_config`).
- **Forbidden:** GET only.

## 8. Security posture (PROM-050, PROM-051)

### PROM-050 — destructive-API exposure

```bash
. "${CLAUDE_PLUGIN_ROOT:?plugin root is required}/skills/audit-prometheus/scripts/prometheus-http.sh"
# Read the flags. NEVER call the destructive endpoints they gate.
# Flags live under .data (confirmed live on Prometheus 3.14) and each value is a STRING
# ("true"/"false") — compare to the string, never rely on jq truthiness (the string "false" is truthy).
RESPONSE=$(pq_json "/api/v1/status/flags") || exit 1
printf '%s' "$RESPONSE" | jq '.data | {admin_api: ."web.enable-admin-api", lifecycle: ."web.enable-lifecycle"}'
```

- **Healthy target:** `web.enable-admin-api` is `false` unless deliberately needed; if `true`, the endpoint is behind auth on a private network.
- **Finding (PROM-050):** enabled admin/lifecycle flags establish configured capability only. Reverse-proxy policy may block the mutation paths even when read queries are open. Use read-only access-policy evidence to assess potential exposure and severity; unknown routing/authorization remains unverified. Never send a destructive request to test it. Remediate unused flags or the evidenced access policy.
- **Forbidden:** GET only — **never** `POST /api/v1/admin/tsdb/delete_series`, `/-/reload`, or `/-/quit`; see section 9.

### PROM-051 — transport and auth exposure

This probe sends **no** credentials. A status code alone does not establish API
exposure: an HTML login page can also return 200. A successful `vector(1)` JSON
query proves unauthenticated query access from the current network only.

```bash
. "${CLAUDE_PLUGIN_ROOT:?plugin root is required}/skills/audit-prometheus/scripts/prometheus-http.sh"
# PROM-051 unauthenticated query proof; keep response private and remove on exit.
BODY=$(mktemp); chmod 600 "$BODY"
trap 'rm -f "$BODY"' EXIT HUP INT TERM
CODE=$(curl -sS -o "$BODY" -w '%{http_code}' --max-time 10 --get \
  --data-urlencode 'query=vector(1)' "${PROM_URL}/api/v1/query") \
  || { echo "PROM-051 blocked: unauthenticated probe failed"; exit 1; }
case "$CODE" in
  200)
    if jq -e '.status=="success" and (.data.resultType=="vector") and (.data.result|type=="array" and length==1) and (.data.result[0].value[1]=="1")' "$BODY" >/dev/null 2>&1; then
      echo "PROM-051 evidence: unauthenticated query access from this network; classify exposure using the observed host/network scope"
    else echo "PROM-051 blocked: 200 response is not a valid query result (possible login page)"; fi ;;
  401|403) echo "PROM-051 evidence: unauthenticated query was denied; authenticated audit evidence is separate" ;;
  *) echo "PROM-051 blocked: status=$CODE is inconclusive" ;;
esac
case "$PROM_URL" in https://*) echo "TLS: audit endpoint is https";; *) echo "TLS: audit endpoint is plaintext; confirm whether the path is loopback or trusted";; esac
```

- **Healthy target:** an observed public query endpoint requires authentication;
  plaintext traffic is confined to a trusted path such as loopback/port-forward.
- **Finding (PROM-051, high):** a verified unauthenticated query on an observed
  public host establishes public query access. Do not infer public reachability
  from a successful query over a VPN or local tunnel, or claim every series is
  exposed from `vector(1)` alone. Plaintext on an untrusted path is a separate
  transport finding. Record the host class and observed network scope. Remediate
  with an auth proxy/TLS or private access as appropriate.

- **Forbidden:** GET only.

## 9. Forbidden mutations

This audit is strictly read-only. Every command above is a `GET` on the Prometheus HTTP API — `/api/v1/*` reads, instant queries (`GET /api/v1/query`), `/-/healthy`, `/-/ready`. The following are **never** issued from audit-prometheus; each is a change that a human applies by hand under the inline remediation pointers, never from this audit:

- **Destructive admin API:** `POST /api/v1/admin/tsdb/delete_series`, `POST /api/v1/admin/tsdb/clean_tombstones`, `POST /api/v1/admin/tsdb/snapshot`. Gated by `--web.enable-admin-api`; this audit reads the flag (PROM-050), it never calls these.
- **Lifecycle:** `POST /-/reload`, `POST /-/quit`. Gated by `--web.enable-lifecycle`; read about (PROM-050), never called.
- **Any non-GET** on any `/api/v1/*` route. Prometheus's query API is read-only by design; there is no "harmless" write. A write attempt is a bug in the skill, not a finding — if any block above ever seems to need a mutation to produce evidence, that is the wrong command: read the state instead, and apply the change by hand per the remediation pointer.
