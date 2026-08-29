# audit-lgtm: Backend Check Catalog and Commands

Runnable, read-only checks for every backend the [audit-lgtm](../SKILL.md) workflow covers. Each section lists the catalog IDs it serves, the commands, the expected healthy output, and what the common failure shapes mean. Evidence for a finding is the command plus its observed output, trimmed with truncation marked.

## Conventions

Every block declares its variables at the top with the `toolkit.yaml` key it resolves from. Auth uses this pattern throughout; endpoints without auth send a harmless `Accept` header instead of a broken empty bearer:

```bash
set -eu
LOKI_URL="https://loki.example.com"    # loki.url
LOKI_TOKEN="${LOKI_TOKEN:-}"           # loki.token_env; leave unset for open endpoints
AUTH="Authorization: Bearer ${LOKI_TOKEN}"
[ -n "$LOKI_TOKEN" ] || AUTH="Accept: application/json"
```

- Presence-check tokens only; never echo, log, or write a secret value anywhere.
- `curl -fsS --max-time 10` is the default. Where a status code is itself the evidence (detection, exposure checks), `-f` is dropped deliberately and `-w '%{http_code}'` used instead; those blocks say so.
- Some query endpoints are POST by protocol (VictoriaLogs LogsQL, Prometheus `--get --data-urlencode` alternatives). They execute a query and store nothing; they are classified read-only by effect.
- Time windows are examples; tune to your environment: `RECENT_WINDOW="15m"` for "recent data", `LOOKBACK_S="3600"` seconds for search windows.
- Multi-tenant backends need the tenant on every call: Mimir and Loki via `X-Scope-OrgID`, VictoriaMetrics cluster via the `/select/<tenant>/prometheus` path prefix. A missing tenant usually looks like `401 no org id` or silently empty results.

## Check catalog

One permanent ID per check. IDs never change or get reused; retired checks keep their number. Severity listed is the typical severity when the check fails; judge the real impact in your environment.

| ID | Category | Check | Typical fail severity |
| --- | --- | --- | --- |
| LGTM-001 | Metrics stores | Metrics **store** reachable and healthy (Mimir/VictoriaMetrics via `mimir.url`/`victoriametrics.url`; a vanilla Prometheus server → `/scoutflo:audit-prometheus`) | critical |
| LGTM-002 | Metrics stores | Deployed metrics backend matches the advertised one | medium |
| LGTM-003 | Metrics stores | Smallest useful query (`up`) returns recent samples from the store | high |
| LGTM-004 | Metrics stores | Store ruler (Mimir ruler / vmalert) rule groups load and evaluate without errors | high |
| LGTM-005 | (retired v0.1.157) | Scrape-target health moved to `/scoutflo:audit-prometheus` (PROM-010/PROM-012); ID retired, never reused | — |
| LGTM-006 | Metrics stores | Multi-tenant path or header verified — Mimir `X-Scope-OrgID` / VM `/select/<tenant>/` (single-tenant: not-in-scope) | high |
| LGTM-007 | Metrics stores | Store-side ingestion freshness: newest queryable sample from the store is recent | high |
| LGTM-008 | Metrics stores | Store ruler rule-evaluation lag: no rule group evaluates slower than its own interval | medium |
| LGTM-010 | Alert routing | Alertmanager reachable, config parses, cluster ready | critical |
| LGTM-011 | Alert routing | At least one real receiver defined | critical |
| LGTM-012 | Alert routing | vmalert loads rules and points at a live notifier | critical |
| LGTM-013 | Alert routing | Notification failure counter delta is zero across two reads; counters do not prove human receipt | high |
| LGTM-014 | Alert routing | Default route receiver is real, not null, loopback, or placeholder | critical |
| LGTM-015 | Alert routing | Severity-based routes select a paging receiver | medium |
| LGTM-016 | Alert routing | Grouping, inhibition, and repeat interval configured | medium |
| LGTM-017 | Alert routing | No noisy rules: missing `for`, Jobs paging, dev namespaces routed to paging | medium |
| LGTM-018 | Alert routing | Currently firing alerts have owners and action annotations; acknowledgement is checked downstream | medium |
| LGTM-020 | Logs layer | Log endpoint reachable and ready | high |
| LGTM-021 | Logs layer | Deployed log backend matches the advertised one (LogQL vs LogsQL) | medium |
| LGTM-022 | Logs layer | Smoke query returns recent log lines | high |
| LGTM-023 | Logs layer | Standard labels present: service, namespace, level | medium |
| LGTM-024 | Logs layer | Trace ID present in log fields where tracing is deployed | medium |
| LGTM-025 | Logs layer | Collectors ingest cleanly: no drops, buffer pressure, or send errors | high |
| LGTM-030 | Service coverage | No critical service is blind in every signal | critical |
| LGTM-031 | Service coverage | Each service resolves to one name across metrics, logs, and traces | medium |
| LGTM-032 | Service coverage | Every critical service has recent metrics under a stable service label, at real depth: per-pod resource series, HTTP status-code labels, and a latency histogram, not existence alone | high |
| LGTM-033 | Service coverage | Every critical service has recent searchable logs | high |
| LGTM-034 | Service coverage | Every critical service has recent traces or a documented sampling decision | high |
| LGTM-035 | Service coverage | Every critical service has at least one severity-labeled alert rule | high |
| LGTM-036 | Service coverage | Owner and escalation route known per critical service | low |
| LGTM-037 | Service coverage | Runbook link on paging alerts per critical service | low |
| LGTM-038 | Service coverage | Deploy or change context available (markers, annotations, image tags) | low |
| LGTM-039 | Service coverage | Telemetry scope established: the backends demonstrably monitor the audited cluster (mismatch reclassifies coverage rows to blocked, never fail) | info |
| LGTM-040 | Traces layer | Trace endpoint reachable and ready | high |
| LGTM-041 | Traces layer | Deployed trace backend matches the advertised one | medium |
| LGTM-042 | Traces layer | Search returns recent traces | high |
| LGTM-043 | Traces layer | `service.name` values discoverable and consistent | medium |
| LGTM-044 | Traces layer | Error and slow traces retrievable by query | medium |
| LGTM-045 | Traces layer | Sampling policy known and documented | low |
| LGTM-050 | Dashboards and correlation | Grafana healthy and every datasource passes its health check | high |
| LGTM-051 | Dashboards and correlation | Incident view exists per critical service linking signals and alerts | medium |
| LGTM-052 | Dashboards and correlation | No broken panels or dead datasource references in responder dashboards | medium |
| LGTM-053 | Dashboards and correlation | Cross-signal pivots work: metrics to logs, trace to logs via trace ID | medium |
| LGTM-054 | Dashboards and correlation | Panel scope honest: no org-wide queries behind per-service titles; reducers match source shape | medium |
| LGTM-060 | Reliability and security | Telemetry stores not single-replica without accepted RPO/RTO and backups | high |
| LGTM-061 | Reliability and security | Retention configured and known per signal store | medium |
| LGTM-062 | Reliability and security | Backups or snapshots exist for telemetry storage | high |
| LGTM-063 | Reliability and security | Observability endpoints not publicly reachable without auth | high |
| LGTM-064 | Reliability and security | Kubernetes runtime only: NetworkPolicies and PodDisruptionBudgets present in the monitoring namespace | medium |
| LGTM-065 | Reliability and security | No high-cardinality label values (IDs, users, sessions, URLs) | medium |
| LGTM-066 | Reliability and security | No secrets in plain ConfigMaps, chart values, or annotations | high |
| LGTM-070 | Alert routing | Ruler paging rules carry an anti-flap resolve hold (`keep_firing_for`) where they flap; Loki ruler has no such field (not-in-scope) | medium |
| LGTM-071 | Alert routing | Ruler rule groups cap fan-out: group `limit` is not 0/unlimited on high-cardinality rules | medium |
| LGTM-072 | Alert routing | Ruler re-notify and restart-state timing deliberate (resend delay, resolve duration, outage/grace tolerances) | low |
| LGTM-073 | Alert routing | HA ruler replicas do not double-evaluate rules (Loki sharding ring; VM-family sample dedup) | low |
| LGTM-080 | Service coverage | PostgreSQL series present are covered by alert rules on a seeing evaluator (connections vs max, deadlocks, commit rate) | high |
| LGTM-081 | Service coverage | Redis/Valkey series present are covered by alert rules on a seeing evaluator (evictions, connected clients) | medium |
| LGTM-082 | Service coverage | Kafka series present are covered by alert rules on a seeing evaluator (consumer-group lag) | high |

## Runtime applicability matrix

Record one live-evidenced `runtime_mode` before using any platform-specific command: `kubernetes`, `ec2-systemd`, `docker`, or `external`. Backend API checks in sections 1 through 10 and 12 through 14 remain applicable wherever their endpoints are configured. Section 11 is Kubernetes-only.

| Runtime mode | Platform evidence allowed | Section 11 treatment |
| --- | --- | --- |
| `kubernetes` | Explicit configured kube context and telemetry workloads from that context | Run section 11 as written |
| `ec2-systemd` | Named instance identity plus on-target service/process inventory | Do not run `kubectl`; LGTM-064 is `not-in-scope`; LGTM-025/060/061/062/066 need equivalent host or cloud evidence and are `blocked` when that evidence is unavailable |
| `docker` | Explicit Docker context plus on-target telemetry container inventory | Do not run `kubectl`; LGTM-064 is `not-in-scope`; LGTM-025/060/061/062/066 need equivalent container/host evidence and are `blocked` when unavailable |
| `external` | Provider identity plus the documented shared-responsibility boundary | Do not run `kubectl`; provider-owned platform controls are `not-in-scope` only when the responsibility boundary proves that ownership, otherwise `blocked` |

Do not infer `kubernetes` from `kube_*` metrics: a Prometheus server on EC2 can scrape Kubernetes workloads. Do not infer `ec2-systemd` from an EC2 inventory row alone: containers may run on that host. If the deployment identity cannot be verified, state that the runtime is unresolved and block platform-specific checks instead of forcing one of the modes.

## 1. Backend detection (LGTM-002, LGTM-021, LGTM-041)

Run before any validation. Status codes are the evidence here, so `-f` is intentionally dropped.

Metrics engine:

```bash
set -eu
METRICS_URL="https://prometheus.example.com"   # prometheus.url / mimir.url / victoriametrics.url
METRICS_TOKEN="${METRICS_TOKEN:-}"             # the token_env for that block, if set
AUTH="Authorization: Bearer ${METRICS_TOKEN}"
[ -n "$METRICS_TOKEN" ] || AUTH="Accept: application/json"

curl -sS -o /dev/null -w 'prometheus /-/healthy: %{http_code}\n' --max-time 10 -H "$AUTH" "${METRICS_URL}/-/healthy"
curl -sS --max-time 10 -H "$AUTH" "${METRICS_URL}/health" ; echo " <- vm family /health"
curl -sS -o /dev/null -w 'mimir /ready: %{http_code}\n' --max-time 10 -H "$AUTH" "${METRICS_URL}/ready"
curl -sS --max-time 10 -H "$AUTH" "${METRICS_URL}/metrics" | grep -c '^vm_'     || true  # >0: VictoriaMetrics
curl -sS --max-time 10 -H "$AUTH" "${METRICS_URL}/metrics" | grep -c '^cortex_' || true  # >0: Mimir
```

Read it as: `/-/healthy` 200 means Prometheus; `/health` returning `OK` means VictoriaMetrics family; `/ready` 200 with `cortex_` self-metrics means Mimir. The `/api/v1/status/buildinfo` version string is not reliable for detection; VictoriaMetrics emulates Prometheus there.

Log engine:

```bash
set -eu
LOGS_URL="https://loki.example.com"    # loki.url
LOGS_TOKEN="${LOKI_TOKEN:-}"           # loki.token_env, if set
AUTH="Authorization: Bearer ${LOGS_TOKEN}"
[ -n "$LOGS_TOKEN" ] || AUTH="Accept: application/json"

curl -sS -o /dev/null -w 'loki labels api: %{http_code}\n' --max-time 10 -H "$AUTH" "${LOGS_URL}/loki/api/v1/labels"
curl -sS --max-time 10 -H "$AUTH" "${LOGS_URL}/health" ; echo " <- victorialogs /health"
```

`/loki/api/v1/labels` answering 200 means Loki and LogQL. `/health` returning `OK` with the Loki path 404ing means VictoriaLogs and LogsQL. A LogQL query against VictoriaLogs fails with a parse error; that is a backend mismatch, not a broken logs layer.

Trace engine:

```bash
set -eu
TRACES_URL="https://tempo.example.com"   # tempo.url
TRACES_TOKEN="${TEMPO_TOKEN:-}"          # tempo.token_env, if set
AUTH="Authorization: Bearer ${TRACES_TOKEN}"
[ -n "$TRACES_TOKEN" ] || AUTH="Accept: application/json"

curl -sS --max-time 10 -H "$AUTH" "${TRACES_URL}/api/echo" ; echo " <- tempo (expect: echo)"
curl -sS --max-time 10 -H "$AUTH" "${TRACES_URL}/health" ; echo " <- victoriatraces /health"
curl -sS -o /dev/null -w 'jaeger api: %{http_code}\n' --max-time 10 -H "$AUTH" "${TRACES_URL}/select/jaeger/api/services"
```

`/api/echo` returning `echo` means Tempo (TraceQL, `/api/search`). `/health` returning `OK` plus a 200 on `/select/jaeger/api/services` means VictoriaTraces, which speaks the Jaeger query API, not Tempo's.

Record for each signal: advertised backend, detected backend, query language. Mismatch: emit the finding and use the detected backend's section below for the rest of the audit.

## 2. Prometheus-compatible metrics API (LGTM-001, LGTM-003, LGTM-004 — applied to the Mimir/VictoriaMetrics stores)

The query/rule template below is the Prometheus HTTP API shape. `audit-lgtm` scores it against the **metrics stores** — Mimir (section 3) and VictoriaMetrics/vmalert (section 4) — so set `METRICS_URL` to `mimir.url` / `victoriametrics.url` when scoring these IDs. When your metrics backend is a **vanilla Prometheus** reached at `prometheus.url`, its whole server + rule-engine plane — these same reads *plus* scrape targets, TSDB, remote-write, and config reload — is scored by `/scoutflo:audit-prometheus` (PROM-*), not here. **LGTM-005 (scrape-target health) is retired — `audit-prometheus` owns it (PROM-010/PROM-012).**

```bash
set -eu
METRICS_URL="https://prometheus.example.com"   # prometheus.url
METRICS_TOKEN="${PROM_TOKEN:-}"                # prometheus.token_env, if set
AUTH="Authorization: Bearer ${METRICS_TOKEN}"
[ -n "$METRICS_TOKEN" ] || AUTH="Accept: application/json"

# LGTM-001: health and readiness
curl -fsS --max-time 10 -H "$AUTH" "${METRICS_URL}/-/ready"
curl -fsS --max-time 10 -H "$AUTH" "${METRICS_URL}/api/v1/status/buildinfo" | jq '.data.version'

# LGTM-003: smallest useful query
curl -fsS --max-time 10 -H "$AUTH" --get --data-urlencode 'query=up' \
  "${METRICS_URL}/api/v1/query" | jq '.data.result | length'

# LGTM-004: rule groups and evaluation errors (the store ruler — Mimir ruler / vmalert)
curl -fsS --max-time 10 -H "$AUTH" "${METRICS_URL}/api/v1/rules" \
  | jq -r '.data.groups | length as $g | [.[].rules[]] | "\($g) groups, \(length) rules"'
curl -fsS --max-time 10 -H "$AUTH" "${METRICS_URL}/api/v1/rules" \
  | jq -r '.data.groups[].rules[] | select((.lastError // "") != "") | "\(.name): \(.lastError)"'
```

Expected: `/-/ready` returns ready text; `up` returns more than zero series from the store; the evaluation-error list is empty. Failure shapes: `up` returning `0` series means the store holds nothing queryable (LGTM-003 fail, and every coverage check downstream will fail with it); any `lastError` line is LGTM-004 with the line as evidence. Connection refused or 404 on `/api/v1/query` means wrong backend or wrong path prefix; go back to section 1. (Scrape-target health — the old LGTM-005 — is `/scoutflo:audit-prometheus`'s job now, PROM-010/PROM-012.)

**Depth (per the [depth doctrine](../../report-standard/depth-doctrine.md)) — do not stop at the binary.** These three checks are the ones most likely to read like a free health banner, so each carries a computed blast radius and a correlation, not a status line:
- **LGTM-001 (down/unreachable)** is the root of a cascade, not a yes/no: when the metrics store is down, pull `/api/v1/rules` first and state what goes dark — "this store is the sole datasource for the N alerting rules LGTM-004 inventoried, M at `severity=page`; while it is unreachable every one evaluates to no-data and pages nothing, and the K critical services whose rule lives here are unmonitored." Chains to LGTM-004 → LGTM-035 (per-service alerts silent) → LGTM-032/030 (coverage queries return empty and must be read as backend-down, never a false LGTM-030). Remediation: this is an availability incident (restore/scale the store), then close the HA gap that let one instance take the alert plane down (`setup-lgtm#enable-ha`).
- **LGTM-004 (rule `lastError`)** never stops at the raw line: for each rule with a non-empty `lastError`, resolve `.name`/`.labels`/`.query` to a topology critical service and read `.labels.severity`, and use `.lastEvaluation` to say how long it has been broken — "`HighErrorRate{service=checkout}` severity=page has carried a PromQL parse error for 3 days; checkout's only error-rate page has not evaluated once — a spike tonight fires nothing." Chains to LGTM-035 and, when it is the service's only alerting path, LGTM-030. Fix the specific error the string names on the named rule (remediation `setup-lgtm`).
- **Scrape-target health (retired LGTM-005 → `/scoutflo:audit-prometheus` PROM-010/PROM-012)** — scrape targets are a Prometheus-scraper concern, not a metrics-store one (Mimir/VM ingest via remote-write, they do not scrape). The down-target staleness cascade — a target `up` but reading the last-scraped value while the pod may be dead — is now audited there. When `audit-prometheus` reports a down target for a critical service, this audit's store-side coverage (LGTM-032/030) inherits it as the "backend-stale, not a false LGTM-030" guard.

## 2b. Ingestion freshness and rule-evaluation lag (LGTM-007, LGTM-008)

Two failure modes a green `up` and an error-free rule list both hide: data that is minutes stale while `up==1`, and a rule group that runs slower than its own interval so the page fires late against old data. Both are read-only and proven live against the benchmark Prometheus (which remote-writes to VictoriaMetrics).

```bash
# LGTM-007: age of the newest queryable sample per target. time()-timestamp(up) returns the real
# scrape age (verified 0.4s..100s across 44 targets on the benchmark — it does NOT collapse to 0).
# DETECTION CEILING = the staleness horizon: once a target is silent past the lookback window, up
# goes stale/absent and this stops returning it — that regime is scrape-target health (the retired LGTM-005, now /scoutflo:audit-prometheus PROM-010/PROM-012), not this check. The
# subquery widens the detection window to a target last seen up to 15m ago.
curl -fsS --max-time 10 -H "$AUTH" --get --data-urlencode 'query=time() - timestamp(up)' \
  "${METRICS_URL}/api/v1/query" | jq -r '[.data.result[].value[1]|tonumber] | "max_sample_age_s=\(max) targets=\(length)"'
curl -fsS --max-time 10 -H "$AUTH" --get --data-urlencode 'query=time() - max_over_time(timestamp(up)[15m:1m])' \
  "${METRICS_URL}/api/v1/query" | jq -r '[.data.result[].value[1]|tonumber] | "max_age_15m_window_s=\(max)"'

# Write-path high-water mark (remote-write / Mimir / VM-cluster topologies). On a direct-scrape
# Prometheus that remote-writes (benchmark -> victoria-metrics ...:8428/api/v1/write) these exist and
# samples_pending is the live backlog gauge; absent on a pure local-TSDB Prometheus (the fallback fires).
curl -fsS --max-time 10 -H "$AUTH" "${METRICS_URL}/metrics" \
  | grep -E '^prometheus_remote_storage_(highest_timestamp_in_seconds|queue_highest_sent_timestamp_seconds|samples_pending)' \
  || echo 'no remote_write self-metrics (direct-scrape local TSDB, or non-Prometheus backend)'

# LGTM-008: a rule group evaluating slower than its own interval — fires late even with no lastError.
curl -fsS --max-time 10 -H "$AUTH" "${METRICS_URL}/api/v1/rules" \
  | jq -r '.data.groups[] | select((.evaluationTime // 0) > (.interval // 0)) | "\(.name) eval=\(.evaluationTime)s > interval=\(.interval)s file=\(.file)"'
curl -fsS --max-time 10 -H "$AUTH" --get \
  --data-urlencode 'query=prometheus_rule_group_last_duration_seconds > prometheus_rule_group_interval_seconds' \
  "${METRICS_URL}/api/v1/query" | jq -r '.data.result[]? | "\(.metric.rule_group) over-interval"'
```

Healthy: newest sample under one scrape interval old for every target; no group over its interval (benchmark: max age ~100s, both storefront groups eval in ~0.002s vs a 60s interval). Fail (**LGTM-007**, high): a target's newest sample is minutes old while `up` still reads 1 — every rule with `for: Nm` on it pages ~N+lag late; name the critical services (topology) in the lagging set and state the computed delay, which *is* the blast radius. Distinct from scrape-target health (the retired LGTM-005, now /scoutflo:audit-prometheus PROM-010/PROM-012): a target can be `up` while ingestion lags in a remote-write/Mimir/VM topology. Fail (**LGTM-008**, medium): a group's `evaluationTime` exceeds its `interval` — every rule in it, including an SLO burn-rate page, evaluates late and can skip windows; a rule with no `lastError` (LGTM-004 passes) can still be silently late here. Both chain to /scoutflo:audit-prometheus PROM-010/PROM-012 (scrape-target up-but-stale from the read side, the retired LGTM-005), LGTM-001 (the extreme of lag is unreachability), and LGTM-035 (the service's page is delayed). Remediation: `setup-lgtm#enable-ha`.

## 3. Mimir specifics (LGTM-001, LGTM-003, LGTM-004, LGTM-006)

Mimir serves the Prometheus API under a `/prometheus` prefix and requires the tenant header on every query.

```bash
set -eu
MIMIR_URL="https://mimir.example.com"   # mimir.url
MIMIR_TENANT="your-tenant"              # mimir.tenant_id; "anonymous" is a common bootstrap
                                         # default when multi-tenancy was never explicitly set up
MIMIR_TOKEN="${MIMIR_TOKEN:-}"          # mimir.token_env, if set
AUTH="Authorization: Bearer ${MIMIR_TOKEN}"
[ -n "$MIMIR_TOKEN" ] || AUTH="Accept: application/json"

curl -fsS --max-time 10 -H "$AUTH" "${MIMIR_URL}/ready"
curl -fsS --max-time 10 -H "$AUTH" -H "X-Scope-OrgID: ${MIMIR_TENANT}" --get --data-urlencode 'query=up' \
  "${MIMIR_URL}/prometheus/api/v1/query" | jq '.data.result | length'
curl -fsS --max-time 10 -H "$AUTH" -H "X-Scope-OrgID: ${MIMIR_TENANT}" \
  "${MIMIR_URL}/prometheus/api/v1/rules" | jq '.data.groups | length'
```

Failure shapes: `401` with a body mentioning `no org id` means the tenant header is missing or wrong (LGTM-006); a valid response with zero series for a tenant that should have data usually means the wrong tenant value, which is also LGTM-006, not an empty metrics layer. Run the section 2 rule-error check (LGTM-004) **and the section 2b freshness / rule-eval-lag checks (LGTM-007/008)** through the same `/prometheus` prefix and `X-Scope-OrgID` header — e.g. `${MIMIR_URL}/prometheus/api/v1/query?query=time()-timestamp(up)` and `${MIMIR_URL}/prometheus/api/v1/rules` — so the store checks hit the Mimir path, not the bare root (scrape-target health is `/scoutflo:audit-prometheus`'s, not re-run here).

If `mimir.tenant_id` is unset or its placeholder value was never replaced, try `anonymous` before concluding the metrics layer is broken: confirmed live that a real deployment's actual tenant was `anonymous`, the value Mimir defaults to when multi-tenancy auth was never configured, not `your-tenant` or any other guessable string. The failure without the right header is not always a clean `401`; it can come back as a plain-text `no org id` body with no `Content-Type: application/json`, which `jq` fails to parse. Wrap the `jq` calls with a body-shape check first (`curl ... | { read -r first_line; case "$first_line" in '{'*) ... ;; *) echo "non-JSON response, likely a tenant-header failure: $first_line" ;; esac; }`, or simply capture the raw body and inspect it before piping to `jq`) so a wrong tenant produces a clear diagnostic instead of a `jq` parse-error stack trace.

## 4. VictoriaMetrics and vmalert (LGTM-001, LGTM-003, LGTM-004, LGTM-006, LGTM-012)

Single-node VictoriaMetrics serves the Prometheus API at the root. Cluster VictoriaMetrics serves reads through vmselect under `/select/<tenant>/prometheus`; tenant `0` is the default.

```bash
set -eu
VM_URL="https://vm.example.com"        # victoriametrics.url
VM_TENANT="0"                          # tenant for cluster mode; example, tune to your setup
VM_TOKEN="${VM_TOKEN:-}"               # victoriametrics.token_env, if set
AUTH="Authorization: Bearer ${VM_TOKEN}"
[ -n "$VM_TOKEN" ] || AUTH="Accept: application/json"

# LGTM-001: health; both single-node and cluster components answer /health with OK
curl -fsS --max-time 10 -H "$AUTH" "${VM_URL}/health"

# LGTM-003: single-node form, then cluster form; use whichever answers
curl -fsS --max-time 10 -H "$AUTH" --get --data-urlencode 'query=up' \
  "${VM_URL}/api/v1/query" | jq '.data.result | length'
curl -fsS --max-time 10 -H "$AUTH" --get --data-urlencode 'query=up' \
  "${VM_URL}/select/${VM_TENANT}/prometheus/api/v1/query" | jq '.data.result | length'
```

The section 2b freshness / rule-eval-lag checks (LGTM-007/008) route the same way as the `up` query above: root `/api/v1/query` (and `/api/v1/rules` on vmalert) on single-node VM, and the `/select/<tenant>/prometheus/api/v1/query` prefix on cluster VM (vmselect).

VictoriaMetrics evaluates no alerting rules itself; that is vmalert's job. If `victoriametrics.vmalert_url` is unset while alert rules are supposed to exist, that is LGTM-012 fail, not not-in-scope: metrics with no evaluator means no alerts fire.

```bash
set -eu
VMALERT_URL="https://vmalert.example.com"   # victoriametrics.vmalert_url
VM_TOKEN="${VM_TOKEN:-}"                    # victoriametrics.token_env, if set
AUTH="Authorization: Bearer ${VM_TOKEN}"
[ -n "$VM_TOKEN" ] || AUTH="Accept: application/json"

# LGTM-004 / LGTM-012: rule groups load, evaluation errors, firing alerts
curl -fsS --max-time 10 -H "$AUTH" "${VMALERT_URL}/api/v1/rules" \
  | jq -r '.data.groups | length as $g | [.[].rules[]] | "\($g) groups, \(length) rules"'
curl -fsS --max-time 10 -H "$AUTH" "${VMALERT_URL}/api/v1/rules" \
  | jq -r '.data.groups[].rules[] | select((.lastError // "") != "") | "\(.name): \(.lastError)"'

# LGTM-012 / LGTM-013: notifier delivery errors from vmalert self-metrics
curl -fsS --max-time 10 -H "$AUTH" "${VMALERT_URL}/metrics" \
  | grep -E '^vmalert_alerts_(sent|send_errors)_total' || echo "no send counters exposed"
```

Expected: rules present, no `lastError` lines, `vmalert_alerts_send_errors_total` at 0 while `vmalert_alerts_sent_total` grows. Send errors climbing means vmalert cannot reach its notifier: alerts evaluate and go nowhere. Record counter values, never the notifier URL.

vmalert now also evaluates **VictoriaLogs** rules (`type: vlogs`, alongside `prometheus` and `graphite`), so a rule's `type`/`.Type` field is not always PromQL/MetricsQL. When reading `/api/v1/rules`, honor each rule's declared type and never flag a `vlogs`-type rule as a malformed metrics rule — its expression is LogsQL. To isolate them, `/api/v1/rules` supports a `datasource_type` filter (also `search`, `group_limit`, `page_num`):

```bash
set -eu
VMALERT_URL="https://vmalert.example.com"   # victoriametrics.vmalert_url
VM_TOKEN="${VM_TOKEN:-}"
AUTH="Authorization: Bearer ${VM_TOKEN}"
[ -n "$VM_TOKEN" ] || AUTH="Accept: application/json"

# Bucket GROUPS by datasource type so a vlogs (VictoriaLogs/LogsQL) group is not judged as
# PromQL. The datasource type lives at the GROUP level (.data.groups[].type = prometheus /
# graphite / vlogs); the RULE-level .type is alerting/recording (see the alerting filters
# below), so bucketing rules by .type would only ever show alerting/recording counts and a
# vlogs group would silently read as PromQL — the exact mis-judgement this check prevents.
# Default per-group so an untyped group counts as prometheus rather than vanishing.
curl -fsS --max-time 10 -H "$AUTH" "${VMALERT_URL}/api/v1/rules" \
  | jq -r '[.data.groups[].type // "prometheus"] | group_by(.) | map("\(.[0]): \(length)") | .[]'
# VictoriaLogs rules only, via the datasource_type filter:
curl -fsS --max-time 10 -H "$AUTH" "${VMALERT_URL}/api/v1/rules?datasource_type=vlogs" \
  | jq -r '[.data.groups[].rules[]?] | "\(length) vlogs rules"' || echo "no vlogs rules or filter unsupported on this version"
```

## 5. Loki (LGTM-020, LGTM-022, LGTM-023, LGTM-024, LGTM-025)

Deployment-mode note (feeds the LGTM-060 reliability read, not a new ID): Loki's **Simple Scalable Deployment (SSD)** mode — the three-target `-target=read` / `-target=write` / `-target=backend` split — is **deprecated and will be removed in Loki 4.0**, replaced by the HA single-binary (monolithic) mode. When the Loki topology is SSD (visible from those `-target` args on the pods inventoried in Phase 2), note it as pre-4.0 deprecation debt: it still runs today but will not under Loki 4.0. This is an advisory reliability note, not a scored fail on its own.

```bash
set -eu
LOKI_URL="https://loki.example.com"    # loki.url
LOKI_TOKEN="${LOKI_TOKEN:-}"           # loki.token_env, if set
AUTH="Authorization: Bearer ${LOKI_TOKEN}"
[ -n "$LOKI_TOKEN" ] || AUTH="Accept: application/json"
# Multi-tenant Loki also needs: -H "X-Scope-OrgID: <tenant>" on every call.
SERVICE_LABEL="service"                # your canonical service label; tune
TRACED_SERVICE="checkout"              # one topology.md service that emits traces
TRACED_NS="shop"                       # that service's Namespace column from topology.md; key on namespace+service, never bare name
RECENT_S="900"                         # smoke window in seconds; example, tune to your volume
LOG_SAMPLE="50"                        # lines sampled for the trace-ID check; 5 was too thin to trust a zero

# LGTM-020: readiness
curl -fsS --max-time 10 -H "$AUTH" "${LOKI_URL}/ready"

# LGTM-023: label keys, then service-label values
curl -fsS --max-time 10 -H "$AUTH" "${LOKI_URL}/loki/api/v1/labels" | jq -r '.data[]'
curl -fsS --max-time 10 -H "$AUTH" "${LOKI_URL}/loki/api/v1/label/${SERVICE_LABEL}/values" | jq -r '.data[]'

# LGTM-022: smoke query, any stream, last RECENT_S seconds, 5 lines max
END="$(date -u +%s)000000000"
START="$(( $(date -u +%s) - RECENT_S ))000000000"
curl -fsS --max-time 15 -H "$AUTH" --get \
  --data-urlencode 'query={namespace=~".+"}' \
  --data-urlencode "start=${START}" --data-urlencode "end=${END}" \
  --data-urlencode 'limit=5' \
  "${LOKI_URL}/loki/api/v1/query_range" | jq '.data.result | length'

# LGTM-024: trace ID present in recent log lines of one traced service
curl -fsS --max-time 15 -H "$AUTH" --get \
  --data-urlencode "query={${SERVICE_LABEL}=\"${TRACED_SERVICE}\", namespace=\"${TRACED_NS}\"}" \
  --data-urlencode "start=${START}" --data-urlencode "end=${END}" \
  --data-urlencode "limit=${LOG_SAMPLE}" \
  "${LOKI_URL}/loki/api/v1/query_range" \
  | jq -r '.data.result[].values[][1]' | grep -ciE 'trace[_-]?id' || true

# LGTM-024 (alternate join): an OTLP-shipping collector moves the trace ID out of
# the line body into Loki structured metadata, so the body grep above reads 0 on a
# healthy pipeline. Before failing this check, count lines whose structured-metadata
# trace_id field is populated (needs Loki >= 3.0 with schema v13 structured
# metadata; confirm-live on your install — a parse error here on older Loki means
# the feature is absent, not that the check failed):
curl -fsS --max-time 15 -H "$AUTH" --get \
  --data-urlencode "query={${SERVICE_LABEL}=\"${TRACED_SERVICE}\", namespace=\"${TRACED_NS}\"} | trace_id != \"\"" \
  --data-urlencode "start=${START}" --data-urlencode "end=${END}" \
  --data-urlencode "limit=${LOG_SAMPLE}" \
  "${LOKI_URL}/loki/api/v1/query_range" \
  | jq '[.data.result[].values[]] | length' || echo "structured-metadata filter unsupported on this Loki"

# LGTM-025 (backend side): discarded or rejected ingestion, from Loki self-metrics
curl -fsS --max-time 10 -H "$AUTH" "${LOKI_URL}/metrics" \
  | grep -E '^loki_discarded_samples_total' || echo "no discarded-samples counters (nothing discarded)"
```

Expected: `/ready` returns `ready`; label keys include a service-identifying label and `namespace`; the smoke query returns at least one stream; the LGTM-024 count is nonzero for a service that emits traces; discarded-samples counters are absent or flat. Failure shapes: `parse error` on a valid LogQL query means the backend is not Loki (back to section 1); zero streams with healthy collectors means ingestion is broken upstream (collector-side evidence in section 11); `too many outstanding requests` means the query window is too wide for your install, shrink `RECENT_S`. A zero on **both** LGTM-024 forms — line body and structured metadata — over a `LOG_SAMPLE`-sized sample means responders cannot pivot log to trace; check that the log pipeline keeps the trace ID field (OTLP structured metadata is the modern carrier). A zero on the body grep alone is not the finding when the metadata form is populated; say which form carries the ID, because dashboards' derived-field regexes need to match it. Discarded counters present and rising name their reason in the label (rate limits, out-of-order writes, label cardinality); quote the counter line as evidence. If `/metrics` 404s behind your gateway, score LGTM-025 from the collector-side checks in section 11 instead.

## 6. VictoriaLogs (LGTM-020, LGTM-022, LGTM-023)

LogsQL, not LogQL. The query endpoint takes a form-encoded POST; it runs a query and stores nothing, so it is read-only by effect.

```bash
set -eu
VLOGS_URL="https://vlogs.example.com"   # loki.url block repurposed, or your VictoriaLogs endpoint
VLOGS_TOKEN="${LOKI_TOKEN:-}"           # the matching token_env, if set
AUTH="Authorization: Bearer ${VLOGS_TOKEN}"
[ -n "$VLOGS_TOKEN" ] || AUTH="Accept: application/json"
RECENT_WINDOW="15m"                     # example, tune to your volume

# LGTM-020: health
curl -fsS --max-time 10 -H "$AUTH" "${VLOGS_URL}/health"

# LGTM-022: smoke query, newline-delimited JSON, 5 entries
curl -fsS --max-time 15 -H "$AUTH" "${VLOGS_URL}/select/logsql/query" \
  --data-urlencode "query=_time:${RECENT_WINDOW} | limit 5"

# LGTM-023: field discovery
curl -fsS --max-time 15 -H "$AUTH" "${VLOGS_URL}/select/logsql/field_names" \
  --data-urlencode "query=_time:${RECENT_WINDOW}" | jq .
```

Expected: `/health` returns `OK`; the smoke query streams up to 5 JSON log entries with `_time` and `_msg`; field names include your service and namespace fields. An empty smoke result with healthy collectors points at ingestion; a syntax error against a query this simple points at the wrong backend.

## 7. Tempo (LGTM-040, LGTM-042, LGTM-043, LGTM-044)

```bash
set -eu
TEMPO_URL="https://tempo.example.com"   # tempo.url
TEMPO_TOKEN="${TEMPO_TOKEN:-}"          # tempo.token_env, if set
AUTH="Authorization: Bearer ${TEMPO_TOKEN}"
[ -n "$TEMPO_TOKEN" ] || AUTH="Accept: application/json"
LOOKBACK_S="3600"                       # search window in seconds; example, tune to your sampling

# LGTM-040: readiness
curl -fsS --max-time 10 -H "$AUTH" "${TEMPO_URL}/ready"

# LGTM-042: recent traces, bounded window
END_S="$(date -u +%s)"
START_S="$(( END_S - LOOKBACK_S ))"
curl -fsS --max-time 15 -H "$AUTH" --get \
  --data-urlencode "start=${START_S}" --data-urlencode "end=${END_S}" \
  --data-urlencode 'limit=5' \
  "${TEMPO_URL}/api/search" | jq '{traces: (.traces | length), sample: .traces[0].rootServiceName?}'

# LGTM-043: service names (v1 path; v2 scoped form: /api/v2/search/tag/resource.service.name/values)
curl -fsS --max-time 10 -H "$AUTH" "${TEMPO_URL}/api/search/tag/service.name/values" | jq .

# LGTM-044: error traces via TraceQL
curl -fsS --max-time 15 -H "$AUTH" --get \
  --data-urlencode 'q={ status = error }' \
  --data-urlencode "start=${START_S}" --data-urlencode "end=${END_S}" \
  --data-urlencode 'limit=5' \
  "${TEMPO_URL}/api/search" | jq '.traces | length'
```

Expected: `/ready` returns ready text; recent search returns traces with plausible `rootServiceName` values; the tag-values list matches your services; the error search parses (zero results is fine when nothing is erroring, a parse failure is not). Failure shapes: 404 on `/api/search` means not Tempo (section 1); traces present but `service.name` values like `unknown_service` mean OTel resource attributes are missing at the SDK or collector (feeds LGTM-043 and LGTM-031). Trace-to-logs correlation for LGTM-053 runs through the normalized pivot in section 7.1 below — never a literal grep of a single search-returned ID.

### 7.1 Trace-to-logs pivot with trace-ID normalization (LGTM-053, cross-checks LGTM-024)

Tempo search returns trace IDs with their **leading zeros trimmed** (a 31-character ID was observed live on a real estate; W3C/OTLP trace IDs are 32 lowercase hex characters). Log lines and structured metadata usually carry the full padded form, so an exact-match join on the trimmed ID — a structured-metadata field filter, a JSON field equality, or an anchored grep — false-negatives and produces the phantom finding "this trace has no logs". Normalize before joining: left-pad the ID to 32 hex characters and search **both** forms. And never judge the pivot from one trace; sample several.

```bash
set -eu
TEMPO_URL="https://tempo.example.com"   # tempo.url
TEMPO_TOKEN="${TEMPO_TOKEN:-}"          # tempo.token_env, if set
LOKI_URL="https://loki.example.com"     # loki.url
LOKI_TOKEN="${LOKI_TOKEN:-}"            # loki.token_env, if set
TAUTH="Authorization: Bearer ${TEMPO_TOKEN}"; [ -n "$TEMPO_TOKEN" ] || TAUTH="Accept: application/json"
LAUTH="Authorization: Bearer ${LOKI_TOKEN}";  [ -n "$LOKI_TOKEN" ]  || LAUTH="Accept: application/json"
TRACE_SAMPLE="10"                       # traces sampled for the pivot; one trace proves nothing, tune upward on busy estates
LOOKBACK_S="3600"                       # search window in seconds; example, tune to your sampling

END_S="$(date -u +%s)"; START_S="$(( END_S - LOOKBACK_S ))"
END_NS="${END_S}000000000"; START_NS="${START_S}000000000"

curl -fsS --max-time 15 -H "$TAUTH" --get \
  --data-urlencode "start=${START_S}" --data-urlencode "end=${END_S}" \
  --data-urlencode "limit=${TRACE_SAMPLE}" \
  "${TEMPO_URL}/api/search" | jq -r '.traces[].traceID' > /tmp/lgtm-trace-ids.txt

while read -r tid; do
  [ -n "$tid" ] || continue
  padded="$(printf '%032s' "$tid" | tr ' ' '0')"   # left-pad to 32 hex chars
  hits="$(curl -fsS --max-time 15 -H "$LAUTH" --get \
    --data-urlencode "query={namespace=~\".+\"} |~ \"(${padded}|${tid})\"" \
    --data-urlencode "start=${START_NS}" --data-urlencode "end=${END_NS}" \
    --data-urlencode 'limit=5' \
    "${LOKI_URL}/loki/api/v1/query_range" | jq '[.data.result[].values[]] | length')"
  echo "trace ${tid} (padded: ${padded}): ${hits} log lines"
done < /tmp/lgtm-trace-ids.txt
```

Read it as: most sampled traces landing log lines is a `pass` for the trace-to-logs side of LGTM-053; zero across the whole sample is the pivot genuinely broken — and it cross-checks LGTM-024 (if log lines carry no trace IDs at all, this pivot cannot work, and the LGTM-024 finding owns the root cause). A mixed result names which services' traces found logs in the evidence. Where the pipeline ships the trace ID as OTLP structured metadata rather than in the line body (see the LGTM-024 alternate join in section 5), replace the line-body regex with the structured-metadata field filter — `| trace_id = "<id>"` — and try **both** the padded and trimmed forms there too: exact-match field filters are precisely where the padded/trimmed mismatch bites hardest. The same normalization applies to IDs taken from the Jaeger-shaped VictoriaTraces API (section 8) and to any trace ID a responder copies out of a Grafana panel for the section 10 pivot.

## 8. VictoriaTraces (LGTM-040, LGTM-042, LGTM-043)

VictoriaTraces speaks the Jaeger query HTTP API under `/select/jaeger`. Timestamps in the Jaeger API are microseconds, not nanoseconds; do not reuse Tempo values.

```bash
set -eu
VTRACES_URL="https://vtraces.example.com"   # tempo.url block repurposed, or your VictoriaTraces endpoint
VTRACES_TOKEN="${TEMPO_TOKEN:-}"            # the matching token_env, if set
AUTH="Authorization: Bearer ${VTRACES_TOKEN}"
[ -n "$VTRACES_TOKEN" ] || AUTH="Accept: application/json"
SERVICE="checkout"                          # one service from topology.md

# LGTM-040: health
curl -fsS --max-time 10 -H "$AUTH" "${VTRACES_URL}/health"

# LGTM-043: service discovery
curl -fsS --max-time 10 -H "$AUTH" "${VTRACES_URL}/select/jaeger/api/services" | jq '.data'

# LGTM-042: recent traces for one service
curl -fsS --max-time 15 -H "$AUTH" --get \
  --data-urlencode "service=${SERVICE}" --data-urlencode 'limit=5' --data-urlencode 'lookback=1h' \
  "${VTRACES_URL}/select/jaeger/api/traces" | jq '.data | length'
```

Expected: `OK`, a service list matching your workloads, and at least one trace per active service. Verify the exact query parameters against the docs for your deployed VictoriaTraces version; the product is young and its API surface moves.

## 9. Alertmanager (LGTM-010, LGTM-011, LGTM-013, LGTM-014, LGTM-015, LGTM-016, LGTM-017, LGTM-018)

The rendered Alertmanager config can contain webhook URLs with embedded secrets. Inspect it in the terminal, record shapes and host classes (loopback, private, public) in evidence, and never paste a full webhook URL anywhere.

```bash
set -eu
AM_URL="https://alertmanager.example.com"   # prometheus.alertmanager_url
AM_TOKEN="${PROM_TOKEN:-}"                  # prometheus.token_env, if set
AUTH="Authorization: Bearer ${AM_TOKEN}"
[ -n "$AM_TOKEN" ] || AUTH="Accept: application/json"

# LGTM-010: ready, cluster status, config parses
curl -fsS --max-time 10 -H "$AUTH" "${AM_URL}/-/ready"
curl -fsS --max-time 10 -H "$AUTH" "${AM_URL}/api/v2/status" | jq -r '.cluster.status'

# LGTM-011: receivers beyond a bare null
curl -fsS --max-time 10 -H "$AUTH" "${AM_URL}/api/v2/receivers" | jq -r '.[].name'

# LGTM-014 / LGTM-015 / LGTM-016: route tree and receiver targets; inspect, record shape only
curl -fsS --max-time 10 -H "$AUTH" "${AM_URL}/api/v2/status" | jq -r '.config.original' \
  | grep -nE 'receiver:|routes:|matchers|match(_re)?:|group_by|repeat_interval|inhibit'

# LGTM-018: firing alerts, age, owner, and action metadata
curl -fsS --max-time 10 -H "$AUTH" "${AM_URL}/api/v2/alerts?active=true" \
  | jq -r '.[] | [(.labels.alertname // "unnamed"), (.labels.severity // "none"), (.labels.owner // .annotations.owner // "owner-missing"), (.annotations.runbook_url // .annotations.summary // "action-missing"), .startsAt] | @tsv'

# Silence state is suppression context only. Alertmanager does not expose human acknowledgement.
curl -fsS --max-time 10 -H "$AUTH" "${AM_URL}/api/v2/silences" \
  | jq '{active: ([.[] | select(.status.state == "active")] | length), pending: ([.[] | select(.status.state == "pending")] | length)}'

# LGTM-013: notification attempt/failure counter snapshot, by integration.
# Capture once here and repeat the same read at the end of the audit. Compare each labeled
# series. A single cumulative value cannot establish whether failures are currently rising.
curl -fsS --max-time 10 -H "$AUTH" "${AM_URL}/metrics" \
  | grep -E '^alertmanager_notifications_(total|failed_total)'
```

What to look for. LGTM-014: the top-level `receiver:` is where unmatched alerts land; a receiver named `null`/`blackhole` with real alerts flowing, or a `webhook_configs` URL pointing at a loopback or placeholder address, is a critical finding (evidence: the receiver name and host class, for example `webhook target is a loopback address`). LGTM-015: no route matching on a severity label means paging and info alerts share one configured path. LGTM-016: absent `group_by` and `repeat_interval` defaults, no inhibit rules. LGTM-017: cross-check firing alerts against rule definitions from section 2; rules with no `for:` duration and pages sourced from completed Jobs or dev namespaces are noise findings. LGTM-013: a positive `failed_total` delta between two reads proves that Alertmanager-side notification attempts failed during the sample. A zero or flat delta proves only that Alertmanager recorded no new failures in that interval. `notifications_total` is an attempt counter, not a receipt counter. Neither counter proves that a paging provider accepted the event or that a human received or acknowledged it. LGTM-018: list long-firing alerts, ages, owners, and action annotations for owner review. Alertmanager exposes no acknowledgement state, and zero active silences means only that no Alertmanager suppression is active. Use `/scoutflo:audit-alertmanager` with downstream paging evidence for receipt or acknowledgement claims. Grafana-managed alerting has its own equivalents in section 10.

## 10. Grafana (LGTM-050, LGTM-051, LGTM-052, LGTM-054, and Grafana-managed alerting)

Requires a service-account token with datasources, dashboards, and alert-rules read. If listing datasources returns `403`, the token lacks `datasources:read`; mark those checks `blocked` with that reason rather than guessing.

```bash
set -eu
GRAFANA_URL="https://grafana.example.com"   # grafana.url
# grafana.token_env names the variable; presence was checked by the doctor gate.
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }

# LGTM-050: health, identity, datasource inventory and per-datasource health
curl -fsS --max-time 10 "${GRAFANA_URL}/api/health" | jq .
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/org" | jq '.name'
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/datasources" \
  | jq -r '.[] | "\(.uid) \(.type) \(.name)"'
DS_UID="your-datasource-uid"                # one uid per line from the list above
curl -fsS --max-time 15 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  "${GRAFANA_URL}/api/datasources/uid/${DS_UID}/health" | jq '{status, message}'

# LGTM-051 / LGTM-052: dashboards responders use, then panel datasource references
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  "${GRAFANA_URL}/api/search?type=dash-db&limit=100" | jq -r '.[] | "\(.uid) \(.title)"'
DASH_UID="your-dashboard-uid"
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  "${GRAFANA_URL}/api/dashboards/uid/${DASH_UID}" \
  | jq -r '.dashboard.panels[]? | "\(.title) | ds=\(.datasource.uid // .datasource // "inherit")"'

# Grafana-managed alert rules and notification policy (read-only)
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  "${GRAFANA_URL}/api/prometheus/grafana/api/v1/rules" | jq '[.data.groups[].rules[]] | length'
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  "${GRAFANA_URL}/api/v1/provisioning/policies" | jq '{default_receiver: .receiver}'
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  "${GRAFANA_URL}/api/v1/provisioning/contact-points" | jq -r '.[] | "\(.name) \(.type)"'
```

The contact-points response can include webhook URLs; the `jq` above extracts names and types only, and that is all that goes into evidence. Datasource health failures name the broken datasource; a dashboard panel whose `ds=` uid is absent from the datasource list is a dead reference (LGTM-052). For LGTM-054, open the panels behind your key stat numbers: a per-service title over an unfiltered org-wide query, or a `count` of a paginated list used as a total, is a dishonest panel. For LGTM-053, follow one metrics panel's data links into the log backend and run the section 7.1 pivot (which left-pads leading-zero-trimmed trace IDs to 32 hex chars, searches both forms, and samples several traces rather than one), confirming the pivot lands scoped to the same service and environment; a Grafana trace-to-logs data link built on the trimmed ID has the same false-negative shape. The full dashboard-quality pass is `/scoutflo:audit-grafana`.

## 11. Kubernetes-side reliability checks (LGTM-025, LGTM-060 to LGTM-066)

Run this section only when the runtime applicability gate recorded `runtime_mode=kubernetes`. For every other mode, use the matrix above; missing StatefulSets, PVCs, NetworkPolicies, or PDBs outside Kubernetes are not findings.

A Kubernetes observability estate rarely fits one namespace: the metrics family, the LGTM components, and a legacy stack commonly live in two or three separate namespaces, and checking only one silently passes the others. `MONITORING_NAMESPACES` is a space-separated list (from `kubernetes.monitoring_namespace`, which may name several); every check below loops over it, and the evidence names which namespace each result came from.

```bash
set -eu
RUNTIME_MODE="required-runtime-mode" # replace with the recorded runtime applicability value
KUBE_CONTEXT="your-kube-context"    # kubernetes.context
MONITORING_NAMESPACES="monitoring"  # kubernetes.monitoring_namespace; space-separated when the
                                    # stack spans several namespaces, e.g. "monitoring lgtm victoriametrics"
COLLECTOR="alloy"                   # your log/metric collector daemonset name, from Phase 2 inventory
SINCE="15m"                         # log inspection window; example, tune

case "$RUNTIME_MODE" in
  kubernetes) ;;
  ec2-systemd|docker|external) echo "section 11 not-in-scope for runtime_mode=${RUNTIME_MODE}"; exit 0 ;;
  *) echo "set RUNTIME_MODE from the runtime applicability gate"; exit 1 ;;
esac

for MON_NS in $MONITORING_NAMESPACES; do
  echo "== monitoring namespace: ${MON_NS} =="

  # LGTM-060: single-replica telemetry stores
  kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get sts -o json \
    | jq -r '.items[] | select(.spec.replicas == 1) | "\(.metadata.name): 1 replica"'

  # LGTM-025: collector rollout and recent error volume (skip namespaces without the collector)
  kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get ds -o json \
    | jq -r '.items[] | "\(.metadata.name): desired=\(.status.desiredNumberScheduled) ready=\(.status.numberReady)"'
  kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" logs "ds/${COLLECTOR}" --since="$SINCE" 2>/dev/null \
    | grep -ciE 'error|dropped|failed|retry' || echo "collector ds/${COLLECTOR} not in ${MON_NS} or 0 error lines"

  # LGTM-025 (EOL collectors): flag Promtail (EOL 2026-03-02) and Grafana Agent (EOL 2025-11-01)
  # pods still running; both are superseded by Grafana Alloy. Scan daemonset AND deployment images
  # across the namespace, not just the one named COLLECTOR, so a second legacy collector is caught.
  kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get ds,deploy -o json \
    | jq -r '.items[].spec.template.spec.containers[].image
        | select(test("promtail|grafana[-/]agent|grafana/agent"))'
  echo "flag: each image above is an EOL collector (Promtail/Grafana Agent) -> migration-debt finding, migrate to grafana/alloy"

  # LGTM-061 / LGTM-062: storage sizing as retention input; snapshot objects if a backup operator runs
  kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get pvc
  kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get volumesnapshot 2>/dev/null || echo "no VolumeSnapshot objects"

  # LGTM-063: what is exposed; probe each listed host unauthenticated afterwards (expect a non-200)
  kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get ingress -o json \
    | jq -r '.items[] | "\(.metadata.name) \(.spec.rules[].host)"'

  # LGTM-064: network and disruption controls
  kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get networkpolicy
  kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get pdb

  # LGTM-066: secret-shaped values in plain ConfigMaps
  kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get configmap -o json \
    | jq -r '.items[] | select(.data | tostring | test("token|password|secret|api[_-]?key"; "i")) | .metadata.name'
done

# LGTM-063 (probe): each host the ingress listing above printed, from any namespace
EXPOSED_HOST="grafana.example.com"          # each host from the lists above
curl -sS -o /dev/null -w '%{http_code}\n' --max-time 10 "https://${EXPOSED_HOST}/"
```

Reading the results. LGTM-060: any single-replica statefulset holding metrics, logs, or traces is a finding unless an accepted RPO/RTO with proven backups is on record. LGTM-061: PVC size alone is not retention; read the store's retention flag or chart values (`helm --kube-context "$KUBE_CONTEXT" -n "$MON_NS" get values <release>` is read-only) and record the period per store. LGTM-063: an unauthenticated `200` from a metrics store, Alertmanager, or a raw Grafana render is exposure; `401`, `403`, or a `302` to a login is the healthy shape. LGTM-064: `No resources found` on both queries means one bad node drain can take monitoring down silently. LGTM-066: the jq filter is a heuristic for where to look, not proof; open the named ConfigMaps and confirm before filing, and never copy the matched values into evidence. For LGTM-065, sample label cardinality from the metrics **store** — Mimir per-tenant `/prometheus/api/v1/status/tsdb` (with `X-Scope-OrgID`) or VictoriaMetrics `/api/v1/status/tsdb` — and look for IDs, emails, session tokens, or full URLs used as label values. (The vanilla-Prometheus TSDB cardinality — `prometheus.url` `/api/v1/status/tsdb` — is `/scoutflo:audit-prometheus`'s PROM-030, not scored here, so the two audits never double-count the same series.)

## 12. Per-service coverage queries (LGTM-030 to LGTM-035, gated by LGTM-039)

**LGTM-039 telemetry-scope probe — run ONCE, before any per-service row.** Establishes whether the metrics backend actually monitors the cluster each critical service runs on; SKILL.md Phase 6 defines how each outcome reclassifies the rows below.

**Trust `topology-export.json`'s declared `cluster_id` per service first — never the current kubectl context.** The kubectl context active during this run is frequently *not* the cluster the critical services live on (a central telemetry stack is commonly reached by port-forward or a separate context, exactly while the services themselves run elsewhere) — comparing telemetry only against "whatever context is active right now" silently passes the gate in that exact case and lets real scope mismatches through as false-positive LGTM-030s. Each service in `topology-export.json` already carries its own `attributes.cluster_id` (written by `/scoutflo:map-topology`); that field, not the live kubectl context, is Side B.

```bash
set -eu
METRICS_URL="https://prometheus.example.com"   # prometheus.url (adjust prefix per sections 3-4)
METRICS_TOKEN="${PROM_TOKEN:-}"
MAUTH="Authorization: Bearer ${METRICS_TOKEN}"; [ -n "$METRICS_TOKEN" ] || MAUTH="Accept: application/json"

# Side A: what the telemetry backend thinks it monitors.
# Cluster-identifying label values on ingested series (label name varies by
# setup: cluster, k8s_cluster_name, kubernetes_cluster — try each configured one):
curl -fsS --max-time 10 -H "$MAUTH" "${METRICS_URL}/api/v1/label/cluster/values" | jq -r '.data[]?'
# Node inventory as seen by the backend (kube-state-metrics / kubelet series):
curl -fsS --max-time 10 -H "$MAUTH" --get \
  --data-urlencode 'query=count(kube_node_info) by (cluster)' \
  "${METRICS_URL}/api/v1/query" | jq -r '.data.result[] | "\(.metric.cluster // "(no cluster label)") nodes=\(.value[1])"'
curl -fsS --max-time 10 -H "$MAUTH" "${METRICS_URL}/api/v1/label/namespace/values" | jq -r '.data[]?' | sort > /tmp/lgtm-ns-telemetry.txt

# Side B, primary source: each critical service's declared cluster_id from the export.
jq -r '.services[] | "\(.name)\t\(.attributes.cluster_id // "MISSING")"' ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/topology-export.json

# Side B, fallback only — use ONLY when topology-export.json is absent or a service's
# cluster_id is null/MISSING (score that service's gate as undetermined otherwise; do not
# silently substitute the active kubectl context for a missing declared cluster_id):
KUBE_CONTEXT="your-kube-context"               # kubernetes.context
kubectl --context "$KUBE_CONTEXT" get nodes -o name | wc -l
kubectl --context "$KUBE_CONTEXT" get nodes -o jsonpath='{.items[0].metadata.name}'
kubectl --context "$KUBE_CONTEXT" get namespaces -o name | sed 's|namespace/||' | sort > /tmp/lgtm-ns-local.txt
comm -12 /tmp/lgtm-ns-local.txt /tmp/lgtm-ns-telemetry.txt | wc -l   # shared namespaces
comm -23 /tmp/lgtm-ns-local.txt /tmp/lgtm-ns-telemetry.txt | head    # local-only (backend doesn't see these)
```

Interpretation, evaluated **per critical service**, not once globally: take that service's `attributes.cluster_id` from `topology-export.json` and check whether the telemetry backend's Side A cluster values/labels include it (exact match, or the backend's node inventory and namespace overlap corroborate it). A service whose declared cluster_id matches the telemetry side = same cluster, proceed with scoring for that service. A service whose declared cluster_id does not appear anywhere in the telemetry backend's cluster values, node inventory, or namespace overlap = different cluster; that service's workload-coverage row is `blocked` per SKILL.md Phase 6, filed as LGTM-039 naming both cluster_ids as evidence. Only fall back to the kubectl-context comparison (Side B fallback above) for services with no `cluster_id` in the export, and when you do, say so explicitly in the LGTM-039 finding rather than presenting it as equivalent evidence — a kubectl-context match is weaker proof than a declared, map-topology-authored `cluster_id` match. No `kube_node_info`, no cluster label, thin namespace sets, and no declared `cluster_id` = undetermined; state it and score conservatively without inventing a critical finding. Because the gate is now per-service, a single run can have some services pass the gate and others blocked — do not collapse this to one global verdict.

Then run the queries below once per critical service from `./scoutflo-audits/topology.md`. **Key every pass on namespace + service, never the bare name**: the same service name legitimately runs in two namespaces on real estates (an `api-gateway` per tier is a live-observed shape), and a bare-name query merges their telemetry so one covered instance masks the other's blindness. Coverage-matrix rows, worklist rows, and `affected` entries all carry the `namespace/service` form. Label names are yours to tune.

```bash
set -eu
SERVICE="checkout"                     # one topology.md service per pass (Service column)
SERVICE_NS="shop"                      # that service's Namespace column from topology.md
SERVICE_LABEL="service"                # your canonical metrics/logs service label; tune
NS_LABEL="namespace"                   # your namespace label on metrics/logs series; tune
RECENT_S="900"                         # freshness window in seconds; example, tune
METRICS_URL="https://prometheus.example.com"   # prometheus.url (adjust prefix per sections 3-4)
LOKI_URL="https://loki.example.com"            # loki.url
TEMPO_URL="https://tempo.example.com"          # tempo.url
METRICS_TOKEN="${PROM_TOKEN:-}"; LOKI_TOKEN="${LOKI_TOKEN:-}"; TEMPO_TOKEN="${TEMPO_TOKEN:-}"
MAUTH="Authorization: Bearer ${METRICS_TOKEN}"; [ -n "$METRICS_TOKEN" ] || MAUTH="Accept: application/json"
LAUTH="Authorization: Bearer ${LOKI_TOKEN}";    [ -n "$LOKI_TOKEN" ]    || LAUTH="Accept: application/json"
TAUTH="Authorization: Bearer ${TEMPO_TOKEN}";   [ -n "$TEMPO_TOKEN" ]   || TAUTH="Accept: application/json"

# LGTM-032: recent metric series for this service (existence), keyed namespace+service
curl -fsS --max-time 10 -H "$MAUTH" --get \
  --data-urlencode "query=count({${SERVICE_LABEL}=\"${SERVICE}\", ${NS_LABEL}=\"${SERVICE_NS}\"})" \
  "${METRICS_URL}/api/v1/query" | jq '.data.result[0].value[1] // "0"'

# LGTM-032 depth, real, not just existence: per-pod resource series, HTTP status-code
# labels, and a latency histogram. A service can pass the existence check above while
# every one of these is absent, and RCA quality has already been observed to depend on
# exactly this depth, not on "metrics exist" alone.
curl -fsS --max-time 10 -H "$MAUTH" --get \
  --data-urlencode "query=count(container_cpu_usage_seconds_total{${SERVICE_LABEL}=\"${SERVICE}\", ${NS_LABEL}=\"${SERVICE_NS}\"}) by (pod)" \
  "${METRICS_URL}/api/v1/query" | jq '.data.result | length'   # per-pod cAdvisor CPU series present, one row per pod
curl -fsS --max-time 10 -H "$MAUTH" --get \
  --data-urlencode "query=count(http_requests_total{${SERVICE_LABEL}=\"${SERVICE}\", ${NS_LABEL}=\"${SERVICE_NS}\"}) by (status_code)" \
  "${METRICS_URL}/api/v1/query" | jq '.data.result | length'   # >1 distinct status_code value proves the label exists and is populated, tune the metric name to your app's actual HTTP metric
curl -fsS --max-time 10 -H "$MAUTH" --get \
  --data-urlencode "query=count(http_request_duration_seconds_bucket{${SERVICE_LABEL}=\"${SERVICE}\", ${NS_LABEL}=\"${SERVICE_NS}\"}) by (le)" \
  "${METRICS_URL}/api/v1/query" | jq '.data.result | length'   # >0 le buckets prove a real latency histogram exists, not just a bare counter

# LGTM-033: recent log streams for this service, keyed namespace+service
END="$(date -u +%s)000000000"; START="$(( $(date -u +%s) - RECENT_S ))000000000"
curl -fsS --max-time 15 -H "$LAUTH" --get \
  --data-urlencode "query={${SERVICE_LABEL}=\"${SERVICE}\", ${NS_LABEL}=\"${SERVICE_NS}\"}" \
  --data-urlencode "start=${START}" --data-urlencode "end=${END}" --data-urlencode 'limit=1' \
  "${LOKI_URL}/loki/api/v1/query_range" | jq '.data.result | length'

# LGTM-034: recent traces for this service (Tempo form; VictoriaTraces form in section 8).
# resource.k8s.namespace.name is the standard OTel resource attribute; if your spans
# carry a different namespace attribute (or none), tune or drop the second clause and
# record the weaker keying in evidence.
END_S="$(date -u +%s)"; START_S="$(( END_S - RECENT_S ))"
curl -fsS --max-time 15 -H "$TAUTH" --get \
  --data-urlencode "q={ resource.service.name = \"${SERVICE}\" && resource.k8s.namespace.name = \"${SERVICE_NS}\" }" \
  --data-urlencode "start=${START_S}" --data-urlencode "end=${END_S}" --data-urlencode 'limit=1' \
  "${TEMPO_URL}/api/search" | jq '.traces | length'

# LGTM-035: alert rules that reference this service, with their severity labels
curl -fsS --max-time 10 -H "$MAUTH" "${METRICS_URL}/api/v1/rules" \
  | jq -r --arg s "$SERVICE" \
    '.data.groups[].rules[] | select(.query? // "" | contains($s)) | "\(.name) severity=\(.labels.severity // "none")"'
```

Row scoring: a nonzero count is `pass` for that signal; zero where the signal should exist is `fail`; zero because tracing is intentionally sampled out or not deployed for this service, with the decision recorded, is `not-in-scope`; zero where the LGTM-039 probe showed the backend does not monitor this service's cluster is `blocked`, never `fail`. All applicable signals at zero makes this service part of LGTM-030, critical — only under a confirmed same-cluster scope. Rules matching by name substring is a starting heuristic; confirm the rule's selector actually targets the service **in its namespace** before crediting LGTM-035 — a rule scoped to the other namespace's same-named service is not coverage for this one. For LGTM-036 to LGTM-038, check the paging rules' annotations for `runbook_url` and owner labels, and dashboards for deploy markers.

For LGTM-032 specifically: the existence query passing is `partial`, not `pass`, on its own. Full `pass` needs the depth queries too — per-pod cAdvisor series (proves resource-saturation questions are answerable per pod, not just in aggregate), a populated status-code label on the HTTP metric (proves error-rate-by-code is measurable, not just total request count), and a real latency histogram (proves percentile/SLO questions are answerable, not just averages). A service with metrics that exist but lack all three is a real, common shape: it looks "covered" in a naive dashboard scan while an actual investigation into "is this pod resource-starved" or "what's our p99" has nothing to query.

LGTM-031, name parity across signals:

```bash
set -eu
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm/$(date -u +%Y-%m-%d)"; mkdir -p "$OUT"
SERVICE_LABEL="service"                        # tune to your canonical label
METRICS_URL="https://prometheus.example.com"   # prometheus.url (adjust prefix per sections 3-4)
LOKI_URL="https://loki.example.com"            # loki.url
TEMPO_URL="https://tempo.example.com"          # tempo.url
METRICS_TOKEN="${PROM_TOKEN:-}"; LOKI_TOKEN="${LOKI_TOKEN:-}"; TEMPO_TOKEN="${TEMPO_TOKEN:-}"
MAUTH="Authorization: Bearer ${METRICS_TOKEN}"; [ -n "$METRICS_TOKEN" ] || MAUTH="Accept: application/json"
LAUTH="Authorization: Bearer ${LOKI_TOKEN}";    [ -n "$LOKI_TOKEN" ]    || LAUTH="Accept: application/json"
TAUTH="Authorization: Bearer ${TEMPO_TOKEN}";   [ -n "$TEMPO_TOKEN" ]   || TAUTH="Accept: application/json"
curl -fsS --max-time 10 -H "$MAUTH" "${METRICS_URL}/api/v1/label/${SERVICE_LABEL}/values" \
  | jq -r '.data[]' | sort > "$OUT/services-metrics.txt"
curl -fsS --max-time 10 -H "$LAUTH" "${LOKI_URL}/loki/api/v1/label/${SERVICE_LABEL}/values" \
  | jq -r '.data[]' | sort > "$OUT/services-logs.txt"
curl -fsS --max-time 10 -H "$TAUTH" "${TEMPO_URL}/api/search/tag/service.name/values" \
  | jq -r '.tagValues[]' | sort > "$OUT/services-traces.txt"
diff "$OUT/services-metrics.txt" "$OUT/services-logs.txt" || true
diff "$OUT/services-metrics.txt" "$OUT/services-traces.txt" || true
```

Empty diffs are a pass. Every diverging name (`payment` vs `paymentsvc` vs `payment-service`) is one entry in LGTM-031's evidence, with the affected canonical service named in `affected`. Normalizing aliases in your matrix is fine; hiding them is not.

## 13. Alert hygiene: ruler-native noise controls (LGTM-070 to LGTM-073)

Runs [Phase 7b](../SKILL.md#phase-7b-alert-hygiene-ruler-native-noise-controls). Every block is read-only and reads only the rule evaluators these stacks ship — vmalert, the Loki ruler, the Mimir ruler — via their own rules and config APIs. Honest ceiling, repeated because it belongs in the evidence: these are **structural** noise signals (missing anti-flap holds, unbounded fan-out, re-notify cadence, duplicate evaluation), not an actionability rate; and grouping, inhibition, silences, and mute/active time intervals are **not** implemented in vmalert or the Loki ruler at all — they live in the Alertmanager (or Grafana) the ruler forwards to and are audited by `/scoutflo:audit-alertmanager` and `/scoutflo:audit-grafana`, never re-checked here. Mimir bundles a per-tenant Alertmanager on the identical config format; point those routing/grouping/inhibition checks at it per tenant, do not reimplement them. Apply the named thresholds (`MIN_RESEND_S`, `LIMIT_EXPECTED`) as the reader, exactly as the rest of this audit does. A `401`/`403` on any read here blocks its check; it is never a clean or passing result.

### 13.1 vmalert: rule holds, group fan-out, notify timing, sample dedup (LGTM-070, LGTM-071, LGTM-072, LGTM-073)

vmalert's `/api/v1/rules` carries the parsed `duration` (the `for`, seconds), the `keep_firing_for` field (seconds), and each group's `limit` (0 = unlimited). Its `/flags` endpoint exposes the notify-cadence flags. The datasource-side `-dedup.minScrapeInterval` lives on the VictoriaMetrics `vmsingle`/`vmselect` process, not on vmalert.

```bash
set -eu
VMALERT_URL="https://vmalert.example.com"   # victoriametrics.vmalert_url
VM_URL="https://vm.example.com"             # victoriametrics.url (vmsingle/vmselect)
VM_TOKEN="${VM_TOKEN:-}"                     # victoriametrics.token_env, if set
AUTH="Authorization: Bearer ${VM_TOKEN}"
[ -n "$VM_TOKEN" ] || AUTH="Accept: application/json"
MIN_RESEND_S="10"     # example, tune it: -rule.resendDelay below this re-pushes firing alerts aggressively
LIMIT_EXPECTED="0"    # example, tune it: a high-cardinality paging rule with group limit==0 is unbounded fan-out

# LGTM-070 / LGTM-071: per-rule for + keep_firing_for, and per-group limit (0 = unlimited)
curl -fsS --max-time 15 -H "$AUTH" "${VMALERT_URL}/api/v1/rules" \
  | jq -r '.data.groups[]
      | .name as $g | (.limit // 0) as $lim
      | .rules[] | select(.type == "alerting")
      | "\(.name) group=\($g) group_limit=\($lim) for=\(.duration // 0)s keep_firing_for=\(.keep_firing_for // 0)s severity=\(.labels.severity // "-")"'

# LGTM-072: re-notify and resolve/restart-state timing from vmalert flags
curl -fsS --max-time 10 -H "$AUTH" "${VMALERT_URL}/flags" \
  | grep -E 'rule\.resendDelay|rule\.maxResolveDuration|rule\.resultsLimit|remoteWrite\.url|remoteRead\.url|notifier\.url' \
  || echo "no matching vmalert flags exposed"

# LGTM-073: datasource-side sample dedup for HA writers (0/unset = duplicate samples reach queries)
curl -fsS --max-time 10 -H "$AUTH" "${VM_URL}/flags" \
  | grep -E 'dedup\.minScrapeInterval' || echo "-dedup.minScrapeInterval not set (0 = no dedup)"
```

Read it as: a paging-severity rule with `keep_firing_for=0s` **and** a flap history (from LGTM-018 / the firing-alert churn) is LGTM-070. `group_limit=0` on a high-cardinality expression is LGTM-071 — remember exceeding a set `limit` discards the whole rule's results, so neither `0` nor a too-tight value is automatically right. `-rule.resendDelay` far below `MIN_RESEND_S`, or `-remoteWrite.url`/`-remoteRead.url` absent (so `for` state is in-memory only and resets every restart), is LGTM-072. `-rule.maxResolveDuration` defaults to 4x the group's evaluation interval; record the value, do not assume a fixed number. Record counter and flag values only, never the notifier or remote-write URL.

### 13.2 Loki ruler: for, group limit, resend and restart timing, sharding dedup (LGTM-071, LGTM-072, LGTM-073)

The Loki ruler is Prometheus-rule-compatible but has **no** `keep_firing_for` field (so LGTM-070 is `not-in-scope` on Loki). Rule state comes from `/prometheus/api/v1/rules` (JSON, `jq`-friendly); the raw rule YAML is at `/loki/api/v1/rules`. Ruler timing and sharding come from the running `/config`, and ring membership from `/ruler/ring`.

```bash
set -eu
LOKI_URL="https://loki.example.com"    # loki.url
LOKI_TOKEN="${LOKI_TOKEN:-}"           # loki.token_env, if set
AUTH="Authorization: Bearer ${LOKI_TOKEN}"
[ -n "$LOKI_TOKEN" ] || AUTH="Accept: application/json"
# Multi-tenant Loki also needs: -H "X-Scope-OrgID: <tenant>" on every call.

# LGTM-071: per-group limit (0/absent = unbounded emission) and per-rule for
curl -fsS --max-time 15 -H "$AUTH" "${LOKI_URL}/prometheus/api/v1/rules" \
  | jq -r '.data.groups[]
      | .name as $g | (.limit // 0) as $lim
      | .rules[] | select(.type == "alerting")
      | "\(.name) group=\($g) group_limit=\($lim) for=\(.duration // 0)s severity=\(.labels.severity // "-")"'

# LGTM-072 / LGTM-073: ruler resend/restart timing and sharding, from the running config
curl -fsS --max-time 10 -H "$AUTH" "${LOKI_URL}/config" \
  | grep -nE 'resend_delay|for_outage_tolerance|for_grace_period|enable_sharding|sharding_strategy|alertmanager_url' \
  || echo "ruler config keys not present in /config output"

# LGTM-073: ruler ring members; >1 active with enable_sharding=false = duplicate evaluation
curl -fsS --max-time 10 -H "$AUTH" "${LOKI_URL}/ruler/ring" \
  | grep -ciE 'ACTIVE' || echo "0 active ruler ring members reported"
```

Read it as: `group_limit` of `0`/absent is LGTM-071. `ruler.resend_delay` (default 1m), `for_outage_tolerance` (default 1h), and `for_grace_period` (default 10m) far below their defaults are LGTM-072 — the defaults are protective, so flag deviations, not the defaults. `enable_sharding: false` (its default) with more than one active member in `/ruler/ring` is LGTM-073: every replica evaluates every rule and emits duplicates, deduplicated downstream only by Alertmanager, so score it as evaluation-efficiency/cost. If `alertmanager_url` is empty, the ruler evaluates but forwards nothing — that is a delivery gap owned by LGTM-012, not a hygiene finding. If `/config` is disabled behind your gateway, note it and mark LGTM-072/LGTM-073 `blocked` rather than passing them.

### 13.3 Mimir ruler: for and keep_firing_for per tenant; routing delegated (LGTM-070, LGTM-071, LGTM-072)

The Mimir ruler serves the Prometheus rules API under its prometheus-http-prefix (default `/prometheus`) and requires the tenant header. The compiled fields are `duration` (the `for`) and `keepFiringFor` (camelCase, as modern Prometheus vendors it).

```bash
set -eu
MIMIR_URL="https://mimir.example.com"   # mimir.url
MIMIR_TENANT="your-tenant"              # mimir.tenant_id; "anonymous" is a common bootstrap default
MIMIR_TOKEN="${MIMIR_TOKEN:-}"          # mimir.token_env, if set
AUTH="Authorization: Bearer ${MIMIR_TOKEN}"
[ -n "$MIMIR_TOKEN" ] || AUTH="Accept: application/json"

# LGTM-070 / LGTM-071 / LGTM-072: per-tenant ruler rules (for, keepFiringFor, group limit)
curl -fsS --max-time 15 -H "$AUTH" -H "X-Scope-OrgID: ${MIMIR_TENANT}" \
  "${MIMIR_URL}/prometheus/api/v1/rules" \
  | jq -r '.data.groups[]
      | .name as $g | (.limit // 0) as $lim
      | .rules[] | select(.type == "alerting")
      | "\(.name) group=\($g) group_limit=\($lim) for=\(.duration // 0)s keep_firing_for=\(.keepFiringFor // 0)s severity=\(.labels.severity // "-")"'
```

Grouping, inhibition, silences, mute/active time intervals, and `repeat_interval` for a Mimir stack live in its bundled per-tenant Alertmanager, which consumes the **identical** Alertmanager config format; its loaded config is readable per tenant via `GET /api/v1/alerts` with `X-Scope-OrgID`, and its silences via the standard `/api/v2/silences`. Audit that routing surface with `/scoutflo:audit-alertmanager` (and `/scoutflo:audit-grafana` for Grafana-managed rules), not here. A `401` with a `no org id` body means the tenant header is missing or wrong (same shape as LGTM-006), not an empty ruler.

### 13.4 Tempo metrics-generator: cardinality feeds downstream metric-alert noise (not scored here)

Tempo has no alerting of its own, so this is **not** a scored alert-rule check. Its metrics-generator turns spans into RED metrics and service-graph series; the more series it emits, the more thin, flappy series the downstream metrics backend's alert rules evaluate. Read these controls only to explain a noisy *metric* alert, and record any resulting finding against the owning metrics-layer (LGTM-032/LGTM-065) or alert-routing check — never as a Tempo score.

```bash
set -eu
TEMPO_URL="https://tempo.example.com"   # tempo.url
TEMPO_TOKEN="${TEMPO_TOKEN:-}"          # tempo.token_env, if set
AUTH="Authorization: Bearer ${TEMPO_TOKEN}"
[ -n "$TEMPO_TOKEN" ] || AUTH="Accept: application/json"

# Global metrics-generator config (span-metrics / service-graph cardinality controls)
curl -fsS --max-time 10 -H "$AUTH" "${TEMPO_URL}/status/config" \
  | grep -nE 'filter_policies|max_active_series|max_active_entities|stale_duration|collection_interval|enable_target_info' \
  || echo "metrics-generator config keys not present at /status/config"

# Per-tenant overrides, if the user-configurable overrides API is exposed
curl -fsS --max-time 10 -H "$AUTH" "${TEMPO_URL}/api/overrides" 2>/dev/null \
  | jq '.metrics_generator? // "no per-tenant metrics_generator overrides"' \
  || echo "/api/overrides not exposed"
```

Documented defaults to read against: `registry.stale_duration` 15m (a much longer value keeps dead series lingering, a stuck-metric risk), `registry.collection_interval` 15s, `max_label_name_length`/`max_label_value_length` 1024/2048, and `metrics_ingestion_time_range_slack` 30s (late spans excluded to avoid retroactive rate spikes). `max_active_series`/`max_active_entities` are per-tenant overrides; unset means no cap. `filter_policies` empty means every span becomes a metric — the noisy default. Enabling `enable_target_info` or service-graph `enable_client_server_prefix` multiplies cardinality. These are cardinality inputs to metric-alert noise, not alert-rule config; frame them that way in the report.

## 14. Datastore alert depth (LGTM-080, LGTM-081, LGTM-082)

Runs [Phase 6b](../SKILL.md#phase-6b-datastore-alert-depth). Databases, caches, and queues fail differently from request-serving services — connection exhaustion, deadlocks, evictions, consumer lag — and their series routinely land in a different metrics backend than the request-path series. Each check here asks two live questions per datastore family: do the series exist in some configured metrics backend, and does at least one alerting rule **on an evaluator that can actually see those series** cover the family's key signals? A present series with no covering alert is the finding. No series of the family anywhere is `not-in-scope` for this lane — a datastore workload running with no exporter at all is a coverage gap owned by LGTM-032/LGTM-035, not re-filed here.

Run the discovery against **every** configured metrics backend (Prometheus per section 2, Mimir per section 3, VictoriaMetrics per section 4 — adjust the path prefix and tenant header accordingly). The two naming families in the wild are exporter-style (`pg_*`, `redis_*`, `kafka_*`) and OTel-collector-style (`postgresql_*`, `redis_*`/`valkey_*`, `kafka_*`); the live `__name__` list is the truth, never an assumed name:

```bash
set -eu
METRICS_URL="https://prometheus.example.com"   # prometheus.url / mimir.url / victoriametrics.url; repeat per configured backend
METRICS_TOKEN="${PROM_TOKEN:-}"                # the matching token_env, if set
MAUTH="Authorization: Bearer ${METRICS_TOKEN}"
[ -n "$METRICS_TOKEN" ] || MAUTH="Accept: application/json"

# LGTM-080 / LGTM-081 / LGTM-082: which datastore series actually exist here
for fam in 'pg_.*|postgresql_.*' 'redis_.*|valkey_.*' 'kafka_.*'; do
  echo "== family: ${fam} =="
  curl -fsS --max-time 15 -H "$MAUTH" --get \
    --data-urlencode "match[]={__name__=~\"${fam}\"}" \
    "${METRICS_URL}/api/v1/label/__name__/values" | jq -r '.data[]?' | head -40
done
```

Key signals to locate in the live list, per check. The names in the last column are the common exporter-style / OTel-collector-style candidates — starting points to grep the live list for, **not** an assumed truth; confirm each name against the discovery output before judging (confirm-live):

| Check | Family | Key signals | Common series names (exporter / OTel; confirm against the live list) |
| --- | --- | --- | --- |
| LGTM-080 | PostgreSQL | connections vs max; deadlocks; commit rate | `pg_stat_activity_count` + `pg_settings_max_connections` / `postgresql_backends` + `postgresql_connection_max`; `pg_stat_database_deadlocks` / `postgresql_deadlocks`; `pg_stat_database_xact_commit` / `postgresql_commits` |
| LGTM-081 | Redis or Valkey | evictions; connected clients | `redis_evicted_keys_total` / `redis_keys_evicted`; `redis_connected_clients` / `redis_clients_connected` (Valkey deployments may keep `redis_*` names or use `valkey_*`) |
| LGTM-082 | Kafka | consumer-group lag | `kafka_consumergroup_lag` / `kafka_consumer_group_lag` |

Then read the alerting rules from **every evaluator wired to a backend that stores these series**: Prometheus `/api/v1/rules` (section 2), vmalert `/api/v1/rules` (section 4), the Mimir ruler per tenant (section 13.3). A rule that references `postgresql_*` in an evaluator whose datasource does not store those series covers nothing — verify by running the rule's expression against that evaluator's own datasource; an empty result is not coverage. This is a real, observed estate shape: the richest datastore series in one backend while the only rule evaluator watches another (that evaluator gap itself is LGTM-012; the uncovered series are this lane's finding).

```bash
set -eu
RULES_URL="https://prometheus.example.com"   # prometheus.url or victoriametrics.vmalert_url; repeat once per evaluator
RULES_TOKEN="${PROM_TOKEN:-}"                # the matching token_env, if set
RAUTH="Authorization: Bearer ${RULES_TOKEN}"
[ -n "$RULES_TOKEN" ] || RAUTH="Accept: application/json"

# LGTM-080 / LGTM-081 / LGTM-082: alerting rules whose expression touches a datastore family
curl -fsS --max-time 15 -H "$RAUTH" "${RULES_URL}/api/v1/rules" \
  | jq -r '.data.groups[].rules[] | select(.type == "alerting") | "\(.name)\t\(.query // "")"' \
  | grep -iE 'pg_|postgresql_|redis_|valkey_|kafka_' \
  || echo "no alerting rule on this evaluator references any datastore series"
```

Scoring, per family: every key signal present in the live series list and referenced by at least one alerting rule on a seeing evaluator is `pass`; some signals covered but not all is `partial`; series present and zero covering rules is `fail` — the finding names the observed series counts and the uncovered signals in evidence, and `affected` names the datastore workloads from topology, keyed `namespace/service`. No series of the family in any configured backend is `not-in-scope`, stated with the LGTM-032/LGTM-035 pointer above. These checks join the Service coverage category (LGTM-080 to LGTM-082); like Phase 7b's additions to Alert routing, they add no category and do not change its weight — they grow its denominator. They are structural presence-and-reference checks: whether the covering rule's threshold or `for` is any good is alert hygiene (Phase 7b) and rule-noise territory (LGTM-017), not re-scored here.
