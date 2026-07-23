# audit-gcp: Check Catalog and Commands

Runnable, read-only checks for every surface the [audit-gcp](../SKILL.md) workflow covers. Each section lists the catalog IDs it serves, the commands, the expected healthy output, and what the common failure shapes mean. Evidence for a finding is the command plus its observed output, trimmed with truncation marked.

## 1. Conventions

- **Identity preamble.** Every block that talks to a Google API starts with the same lines, so each block runs alone in a fresh shell and the run holds exactly one identity with no silent fallback:

```bash
GCP_PROJECT="your-project-id"   # gcp.project
MON_API="https://monitoring.googleapis.com/v3"
# gcp.credentials_env (optional) names GOOGLE_APPLICATION_CREDENTIALS, the key-file path variable
# that application-default credentials read. Set: the key file is the identity for REST and gcloud
# alike (CLOUDSDK_AUTH_ACCESS_TOKEN hands gcloud the same token). Unset: your active gcloud login is.
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN="$TOKEN"; else TOKEN="$(gcloud auth print-access-token)"; fi
```

  `TOKEN` travels only in `Authorization` headers. Never echo it, never put it in a URL, never write it to a file, evidence, or the report. If minting the token fails, stop; do not fall back to a different credential.
- **Explicit project on everything.** Every gcloud command carries `--project "${GCP_PROJECT}"` and every REST path embeds `${GCP_PROJECT}`. Ambient gcloud config is never trusted; the audit never runs `gcloud config set` or `gcloud config configurations activate`.
- **Version sensitivity.** Cloud SDK moves command groups between alpha, beta, and GA over time. Before the first run on a machine, verify each gcloud group named here exists in your installed version (`gcloud monitoring --help`, `gcloud logging --help`) and use the REST fallback where one is noted. `CLOUDSDK_AUTH_ACCESS_TOKEN` also needs a reasonably current gcloud; if your version ignores it, the key-file path cannot drive gcloud commands and you should audit with a dedicated gcloud login instead.
- **Command surfaces pinned per object type.** Alert policies, notification channels, and snoozes: Monitoring REST API v3 via curl (their gcloud groups are alpha/beta or too new to assume). Uptime checks, dashboards, logging metrics and sinks, GKE, and Compute: GA gcloud. Do not swap surfaces mid-run; deltas depend on stable field shapes.
- **Pagination is real.** List endpoints return `nextPageToken`. The inventory blocks loop until it is empty; never judge counts from one page. A first page at the full `pageSize` means keep fetching.
- **Redaction procedure for notification channels.** Channel `labels` carry webhook URLs, auth tokens, and room IDs. Capture `name`, `type`, `displayName`, `enabled`, `verificationStatus`, and label *keys* only, exactly as the jq filters below do. Never relax those filters, never print label values.
- **Read-only by effect, not verb.** `gcloud compute backend-services get-health` is a POST-shaped RPC that reads state; it is allowed and its permission failure is evidence (`GCP-043`). Every REST call this audit makes itself is a GET. The forbidden list is section 15.
- **`curl -fsS --max-time 30` is the default** for API calls. Where the status code is itself the evidence (endpoint probes), `-f` is dropped deliberately and `-w '%{http_code}'` captures the code; those blocks say so. Scratch files come from `mktemp`, never a fixed path.
- Thresholds and windows are examples; tune to your workloads. Named defaults live in section 14.

## 2. Check catalog

One permanent ID per check. IDs never change or get reused; retired checks keep their number. Severity listed is the typical severity when the check fails; judge the real impact in your environment.

| ID | Category | Check | Typical fail severity |
| --- | --- | --- | --- |
| GCP-001 | Alert routing and delivery | At least one enabled notification channel exists | critical |
| GCP-002 | Alert routing and delivery | Every enabled alert policy has at least one notification channel | high |
| GCP-003 | Alert routing and delivery | Channels map to per-environment destinations, not one catch-all | medium |
| GCP-004 | Alert routing and delivery | Delivery proven by an observed Monitoring-generated notification | high |
| GCP-005 | Alert routing and delivery | No disabled or unverified channels still referenced by policies | medium |
| GCP-006 | Alert routing and delivery | Active snoozes reviewed; none silently muting a critical policy | medium |
| GCP-010 | Uptime and availability | Every active public serving endpoint has an uptime check | high |
| GCP-011 | Uptime and availability | Every uptime check has an alert policy on its check_passed metric | high |
| GCP-012 | Uptime and availability | SSL-expiry visibility for HTTPS endpoints | medium |
| GCP-013 | Uptime and availability | Check targets answer 200 live this session; no auth-only or timing-out targets | medium |
| GCP-014 | Uptime and availability | Multi-region checkers where regional failure matters | low |
| GCP-015 | Uptime and availability | No checks against dead or migrated targets | medium |
| GCP-020 | Compute VM coverage | CPU pressure policy on serving VMs, two tiers where stable | high |
| GCP-021 | Compute VM coverage | Memory and disk coverage claimed only with agent metric evidence | high |
| GCP-022 | Compute VM coverage | Ops Agent present on serving VMs | medium |
| GCP-023 | Compute VM coverage | Every policy condition filter matches live time series | high |
| GCP-024 | Compute VM coverage | Metadata and user-label filters validated against the real label shape | medium |
| GCP-030 | GKE coverage | Cluster logging and monitoring components enabled | high |
| GCP-031 | GKE coverage | Restart, pending, and unschedulable workload policies exist | high |
| GCP-032 | GKE coverage | Managed Prometheus state matches where workload alerting is expected | medium |
| GCP-033 | GKE coverage | Node pressure and readiness visibility | medium |
| GCP-040 | Load balancer coverage | Every serving backend service has a health check attached | high |
| GCP-041 | Load balancer coverage | 5xx-rate policy on every serving load balancer | high |
| GCP-042 | Load balancer coverage | Backend latency policy on every serving load balancer | medium |
| GCP-043 | Load balancer coverage | Backend health provable via get-health; permission denial recorded as blocked | medium |
| GCP-050 | Logs as a signal | Logs-based error metric per critical service | high |
| GCP-051 | Logs as a signal | Every logs-based metric filter matches recent log entries | medium |
| GCP-052 | Logs as a signal | Logs-based metrics that matter carry an alert policy | medium |
| GCP-053 | Logs as a signal | Sink routing and exclusion filters reviewed; no silent log loss | medium |
| GCP-054 | Logs as a signal | Log bucket retention is a deliberate decision, not an unexamined default | medium |
| GCP-060 | Alert quality | Policy documentation names env, resource, severity, threshold, datapoints | medium |
| GCP-061 | Alert quality | Severity expressed on policies so responders can triage | low |
| GCP-062 | Alert quality | No baseline-free noisy thresholds; two-tier pressure alerts where stable | medium |
| GCP-063 | Alert quality | Paging policy conditions set a retest window (duration); none fire on a single sample | medium |
| GCP-064 | Alert quality | alertStrategy.autoClose is a deliberate value, not the effective 7-day default | low |
| GCP-065 | Alert quality | High-churn policies throttle repeat notifications via alertStrategy.notificationRateLimit.period | low |
| GCP-066 | Alert quality | Renotify cadence in range and resolve prompts deliberate (renotifyInterval, notificationPrompts) | info |
| GCP-070 | Dashboards and correlation | Dashboards link signals for critical services | low |
| GCP-071 | Dashboards and correlation | Dashboards without corresponding alerting flagged | info |

## 3. Target profile

What 100/100 means per category; the checks above are this profile made executable.

- **Alert routing and delivery**: every enabled policy names an enabled, verified channel a human reads, channels split by environment, at least one observed Monitoring-generated delivery per channel class, and no snooze quietly muting a critical path.
- **Uptime and availability**: every live public endpoint has a multi-region uptime check whose target answers 200, with a check_passed alert policy and SSL-expiry visibility, and no check watches a dead target.
- **Compute VM coverage**: serving VMs carry two-tier CPU policies; memory and disk are covered where the Ops Agent proves the metrics exist, and every policy filter matches live series.
- **GKE coverage**: cluster telemetry components are on, workload health (restarts, pending, unschedulable) pages someone, Managed Prometheus state matches the alerting plan, and node pressure is visible.
- **Load balancer coverage**: every serving backend service has a health check, backend health is provable, and 5xx and latency policies page before users call.
- **Logs as a signal**: every critical service has a logs-based error metric whose filter matches real entries, alert policies ride the metrics that matter, and sinks lose nothing silently.
- **Alert quality**: every policy tells the responder where they are, how bad it is, and what to capture first.
- **Dashboards and correlation**: critical services have a view linking their signals, and nobody mistakes a dashboard for an alert.

## 4. Inventory (all categories)

Capture raw state once per run; later sections re-fetch specific objects before filing findings.

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
MON_API="https://monitoring.googleapis.com/v3"
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN="$TOKEN"; else TOKEN="$(gcloud auth print-access-token)"; fi
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/gcp/${RUN_DATE}/raw"
mkdir -p "$RAW_DIR"

# Alert policies: REST, paginated, one JSON object per line.
: > "${RAW_DIR}/alert-policies.jsonl"
PAGE=""
while :; do
  RESP="$(curl -fsS --max-time 30 -H "Authorization: Bearer ${TOKEN}" \
    "${MON_API}/projects/${GCP_PROJECT}/alertPolicies?pageSize=500${PAGE:+&pageToken=${PAGE}}")"
  printf '%s\n' "$RESP" | jq -c '.alertPolicies[]?' >> "${RAW_DIR}/alert-policies.jsonl"
  PAGE="$(printf '%s' "$RESP" | jq -r '.nextPageToken // empty')"
  [ -n "$PAGE" ] || break
done
wc -l "${RAW_DIR}/alert-policies.jsonl"

# Notification channels: REST, redacted at capture (label keys only, never values).
curl -fsS --max-time 30 -H "Authorization: Bearer ${TOKEN}" \
  "${MON_API}/projects/${GCP_PROJECT}/notificationChannels?pageSize=500" \
  | jq '[.notificationChannels[]? | {name, type, displayName, enabled, verificationStatus,
      label_keys: ((.labels // {}) | keys)}]' > "${RAW_DIR}/channels.json"

# Snoozes: REST (the gcloud group is newer; the REST surface is the pinned path).
curl -fsS --max-time 30 -H "Authorization: Bearer ${TOKEN}" \
  "${MON_API}/projects/${GCP_PROJECT}/snoozes?pageSize=500" \
  | jq '[.snoozes[]? | {name, displayName, interval, criteria}]' > "${RAW_DIR}/snoozes.json"

# GA gcloud surfaces. If `gcloud monitoring uptime` is missing on your version, use
# GET ${MON_API}/projects/${GCP_PROJECT}/uptimeCheckConfigs instead.
gcloud monitoring uptime list-configs --project "$GCP_PROJECT" --format=json \
  | jq '[.[] | {name, displayName, period, timeout,
      host: (.monitoredResource.labels.host // null),
      path: (.httpCheck.path // null), use_ssl: (.httpCheck.useSsl // null),
      regions: (.selectedRegions // ["all-default"])}]' > "${RAW_DIR}/uptime-checks.json"
gcloud monitoring dashboards list --project "$GCP_PROJECT" --format=json \
  | jq '[.[] | {name, displayName}]' > "${RAW_DIR}/dashboards.json"
gcloud logging metrics list --project "$GCP_PROJECT" --format=json \
  | jq '[.[] | {name, filter, description}]' > "${RAW_DIR}/logs-metrics.json"
gcloud logging sinks list --project "$GCP_PROJECT" --format=json \
  | jq '[.[] | {name, destination, filter: (.filter // "ALL"), disabled: (.disabled // false)}]' > "${RAW_DIR}/sinks.json"
gcloud container clusters list --project "$GCP_PROJECT" --format=json \
  | jq '[.[] | {name, location, status, node_count: (.currentNodeCount // 0),
      logging_components: (.loggingConfig.componentConfig.enableComponents // []),
      monitoring_components: (.monitoringConfig.componentConfig.enableComponents // []),
      managed_prometheus: (.monitoringConfig.managedPrometheusConfig.enabled // false)}]' > "${RAW_DIR}/gke-clusters.json"
gcloud compute instances list --project "$GCP_PROJECT" --format=json \
  | jq '[.[] | {name, zone: (.zone | sub(".*/"; "")), status, machine_type: (.machineType | sub(".*/"; "")),
      labels: (.labels // {}), public: ([.networkInterfaces[]?.accessConfigs[]?.natIP] | length > 0)}]' > "${RAW_DIR}/vms.json"
gcloud compute forwarding-rules list --project "$GCP_PROJECT" --format=json \
  | jq '[.[] | {name, IPProtocol, loadBalancingScheme, target: (.target // .backendService // null)}]' > "${RAW_DIR}/forwarding-rules.json"
gcloud compute backend-services list --project "$GCP_PROJECT" --format=json \
  | jq '[.[] | {name, protocol, scheme: .loadBalancingScheme, region: (.region // "global" | sub(".*/"; "")),
      health_checks: ((.healthChecks // []) | length), backends: ((.backends // []) | length)}]' > "${RAW_DIR}/backend-services.json"
gcloud compute health-checks list --project "$GCP_PROJECT" --format=json \
  | jq '[.[] | {name, type}]' > "${RAW_DIR}/health-checks.json"
```

Expected: one file per surface, non-empty JSON. An error naming a disabled API (Compute, Container) on a project that genuinely has no such resources means the area is `not-in-scope`; declare it in the scorecard instead of failing the run. Any other `403` is evidence of a missing viewer role; record it and mark the affected checks `blocked`.

## 5. Alert routing and delivery (GCP-001 to GCP-006)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/gcp/${RUN_DATE}/raw"
# GCP-001: enabled channels. 0 is critical.
jq '[.[] | select(.enabled == true)] | length' "${RAW_DIR}/channels.json"
# GCP-002: enabled policies with zero channels, one line per affected policy.
jq -r 'select((.enabled // true) == true) | select(((.notificationChannels // []) | length) == 0) | .displayName' \
  "${RAW_DIR}/alert-policies.jsonl"
```

`GCP-005` cross-references the channels policies actually reference against channel state; the scratch list comes from `mktemp` because fixed paths collide across parallel runs:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/gcp/${RUN_DATE}/raw"
REF="$(mktemp)"
jq -r '.notificationChannels[]?' "${RAW_DIR}/alert-policies.jsonl" | sort -u > "$REF"
jq -r --rawfile ref "$REF" '
  ($ref | split("\n") | map(select(length > 0))) as $used
  | .[] | select(.name as $n | $used | index($n))
  | select((.enabled != true) or (.verificationStatus == "UNVERIFIED"))
  | "\(.displayName) [\(.type)] enabled=\(.enabled) verification=\(.verificationStatus // "n/a")"' \
  "${RAW_DIR}/channels.json"
rm -f "$REF"
```

Expected: a positive channel count, no zero-channel policy lines, no disabled-or-unverified referenced channels. Each printed line is one member of the finding's `affected` array.

`GCP-003` is a judgment step: from `channels.json` display names and types, map each channel to the environment and team it serves. One channel absorbing every environment means responders cannot tell staging noise from production pages; separate logical channels per environment are worth a finding even when they route to the same chat workspace. Evidence is the channel-to-environment table you assemble, quoting display names only.

`GCP-004`: a listed channel proves configuration, not delivery. Look for an observed Monitoring-generated notification: an alert visible in the channel history your team confirms, or a documented past page. Cloud Monitoring's incident history has no public list API, so console screenshots or team confirmation are the documented manual exception here; say which you used. Without one, routing stays `configured` and `GCP-004` scores `partial` at best. The controlled proof lives in `setup-gcp#prove-channel-delivery`.

`GCP-006`: from `snoozes.json`, any snooze whose interval covers now and whose criteria matches a critical policy is an active mute. A snooze from a long-finished maintenance window still muting a production policy is the finding.

- ❌ `GCP-004 pass: four channels exist and all are enabled.`
- ✅ `GCP-004 partial: channels exist and are enabled, but no Monitoring-generated notification was observed reaching any of them this run; routing stays configured.`

## 6. Uptime and availability (GCP-010 to GCP-015)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/gcp/${RUN_DATE}/raw"
# GCP-010: hosts served (forwarding rules, VM public IPs, your topology list) vs hosts checked.
jq -r '.[].host // empty' "${RAW_DIR}/uptime-checks.json" | sort -u
# GCP-011: check ids that have a check_passed alert policy.
jq -r '.[].name | sub(".*/"; "")' "${RAW_DIR}/uptime-checks.json" | sort -u
jq -r '.conditions[]?.conditionThreshold.filter // empty
  | select(contains("uptime_check/check_passed"))
  | scan("check_id\\s*=\\s*\"[^\"]+\"")' "${RAW_DIR}/alert-policies.jsonl" | sort -u
# GCP-012: SSL-expiry policies.
jq -r 'select([.conditions[]?.conditionThreshold.filter // ""] | any(contains("time_until_ssl_cert_expires"))) | .displayName' \
  "${RAW_DIR}/alert-policies.jsonl"
```

Expected: every serving host appears in the checked list (`GCP-010`); every check id from the second list appears inside a `check_id="..."` capture from the third (`GCP-011`); at least one SSL-expiry policy covers your HTTPS estate or per-check SSL validation is on (`GCP-012`). **An uptime check with no alert policy notifies nobody; it only draws a graph.** That distinction is the whole point of `GCP-011`.

The `check_id` scan regex tolerates filters with or without spaces around `=` (`check_id="..."` and `check_id = "..."` both match). Confirmed live during the 2026-07-20 audit-gcp run: a real project's alert-policy filters used no spaces around `=`, and an earlier version of this regex that required `check_id = "` (with spaces) matched nothing, which would have falsely failed GCP-011 for every check even though all 12 genuinely had a policy.

`GCP-013`/`GCP-015`: probe every check target live. The status code is the evidence, so `-f` is dropped:

```bash
set -eu
TARGET_URL="https://www.example.com/healthz"   # each check's exact protocol, host, and path
BODY="$(mktemp)"
code="$(curl -sS -o "$BODY" -w '%{http_code}' --max-time 15 "$TARGET_URL")" || code="000"
echo "GET ${TARGET_URL} -> ${code}"
head -c 200 "$BODY"; echo; rm -f "$BODY"
```

Expected: `200`. A `401` means the check watches an auth-only endpoint and is a noise generator unless expected-status matching was configured deliberately (`GCP-013`). A `404`, `410`, or a parked page means a dead or migrated target (`GCP-015`); `000` means DNS or connect failure, which is either a real outage or a moved hostname; settle ownership before filing an outage. `GCP-014`: `regions` pinned to a single region for a globally used endpoint is the judgment call; note what would change it (single-region users, internal-only endpoint).

## 7. Compute VM coverage (GCP-020 to GCP-024)

`GCP-020`: from `alert-policies.jsonl`, CPU policies over serving VMs:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/gcp/${RUN_DATE}/raw"
jq -r 'select([.conditions[]?.conditionThreshold.filter // ""] | any(contains("compute.googleapis.com/instance/cpu/utilization")))
  | "\(.displayName): \([.conditions[].conditionThreshold | "\(.comparison // "?") \(.thresholdValue // "?") for \(.duration // "?")"] | join("; "))"' \
  "${RAW_DIR}/alert-policies.jsonl"
```

Expected: at least a warning tier per serving VM group; two named tiers (warning, saturation) where the workload is stable enough (section 14 has the starting values).

`GCP-021`/`GCP-022`, the Ops Agent gate: Compute Engine exposes CPU natively, but **memory and disk metrics exist only where an agent ships them** (`agent.googleapis.com/*`). Never credit memory or disk coverage, and never trust a memory policy, until the agent metrics prove live per VM:

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
MON_API="https://monitoring.googleapis.com/v3"
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN="$TOKEN"; else TOKEN="$(gcloud auth print-access-token)"; fi
# Portable 30-minute window: BSD date first, GNU fallback; both labeled.
START="$(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
curl -fsSG --max-time 30 -H "Authorization: Bearer ${TOKEN}" \
  "${MON_API}/projects/${GCP_PROJECT}/timeSeries" \
  --data-urlencode 'filter=metric.type = "agent.googleapis.com/agent/uptime"' \
  --data-urlencode "interval.startTime=${START}" \
  --data-urlencode "interval.endTime=${END}" \
  | jq -r '[.timeSeries[]?.resource.labels.instance_id] | unique | length'
```

Expected: the count equals your serving VM count. Compare the instance ids returned against `vms.json`; every VM missing from the list has no agent and therefore no memory or disk truth (`GCP-022`), and any memory or disk policy claiming to cover it is false confidence (`GCP-021`).

`GCP-023`, the can-this-ever-fire check: for each policy whose condition is a threshold or absence condition with a Monitoring filter, run that exact filter against timeSeries for the last hour; zero series means the policy can never fire. MQL and PromQL conditions cannot be validated this way; record them as `configured` unless separately proven, and say so.

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
MON_API="https://monitoring.googleapis.com/v3"
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN="$TOKEN"; else TOKEN="$(gcloud auth print-access-token)"; fi
POLICY_FILTER='metric.type = "compute.googleapis.com/instance/cpu/utilization"'  # copy the exact condition filter from the policy JSON
START="$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
curl -fsSG --max-time 30 -H "Authorization: Bearer ${TOKEN}" \
  "${MON_API}/projects/${GCP_PROJECT}/timeSeries" \
  --data-urlencode "filter=${POLICY_FILTER}" \
  --data-urlencode "interval.startTime=${START}" \
  --data-urlencode "interval.endTime=${END}" \
  | jq '[.timeSeries[]?] | length'
```

Expected: greater than 0. `GCP-024` is the same probe pointed at filters using `metadata.user_labels` or resource labels: those fail silently when the label key or shape is wrong, so a policy scoped by label earns credit only after its filter returned series. A `400` from the API on the filter is equally decisive evidence: the filter is invalid in a policy context too.

- ❌ `Scored VM coverage 100: CPU, memory, and disk policies exist for all VMs.`
- ✅ `Scored VM coverage 60: CPU covered with two tiers, but memory and disk are unproven because the agent is absent on 4 of 6 serving VMs; GCP-021 filed with the four VMs named.`

## 8. GKE coverage (GCP-030 to GCP-033)

`GCP-030`: from `gke-clusters.json`, `logging_components` and `monitoring_components` must include `SYSTEM_COMPONENTS`, and workloads logging (`WORKLOADS`) where you expect container logs in Cloud Logging. Empty arrays mean cluster telemetry is off; that silences every downstream check.

`GCP-031`: restart, pending, and unschedulable policies:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/gcp/${RUN_DATE}/raw"
for m in "kubernetes.io/container/restart_count" "kubernetes.io/pod" "kubernetes.io/node"; do
  echo "policies touching ${m}:"
  jq -r --arg m "$m" 'select([.conditions[]?.conditionThreshold.filter // "", .conditions[]?.conditionAbsent.filter // ""] | any(contains($m))) | "  \(.displayName)"' \
    "${RAW_DIR}/alert-policies.jsonl"
done
```

Expected: at least restart-count coverage for critical namespaces and some pod or node condition coverage. `GCP-032`: `managed_prometheus` false on a cluster whose alerting plan expects workload metrics is the finding; true with no consuming rules or policies is an unused engine worth an info note. `GCP-033`: node CPU and memory allocatable pressure visible via policies or an owned dashboard; absence on autoscaling-less node pools is the finding. If the in-cluster stack (Prometheus, Alertmanager, Grafana) is the primary alerting plane, mark the overlapping checks `not-in-scope` here and run `/scoutflo:audit-lgtm` against it; state the split in the report.

## 9. Load balancer coverage (GCP-040 to GCP-043)

`GCP-040`: from `backend-services.json`, any serving backend service with `health_checks: 0` cannot eject a bad backend. `GCP-041`/`GCP-042`:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/gcp/${RUN_DATE}/raw"
jq -r 'select([.conditions[]?.conditionThreshold.filter // ""] | any(contains("loadbalancing.googleapis.com"))) |
  "\(.displayName): \([.conditions[].conditionThreshold.filter] | join(" | "))"' "${RAW_DIR}/alert-policies.jsonl"
```

Expected: per serving load balancer, one policy on `https/request_count` filtered to `response_code_class = 500` (or equivalent) and one on `https/backend_latencies`. **A load balancer health check keeps traffic away from a bad backend; it pages nobody.** Health checks and alert policies are different systems; presence of one never scores the other.

- ❌ `LB covered: every backend service has a health check.`
- ✅ `LB partial: health checks present (GCP-040 pass), but no 5xx or latency policy exists for the public load balancer, so an all-backends-down event pages nobody (GCP-041 fail, GCP-042 fail).`

`GCP-043`: backend health, tolerating denial as evidence:

```bash
set -eu
GCP_PROJECT="your-project-id"       # gcp.project
BACKEND_SERVICE="your-backend"      # each serving backend service from the inventory
GCP_REGION="us-central1"            # gcp.region; only for regional backend services, example value
gcloud compute backend-services get-health "$BACKEND_SERVICE" --global --project "$GCP_PROJECT" --format=json \
  || gcloud compute backend-services get-health "$BACKEND_SERVICE" --region "$GCP_REGION" --project "$GCP_PROJECT" --format=json \
  || echo "get-health denied or failed: record GCP-043 as blocked with this output"
```

Expected: per-backend `healthState` values. `HEALTHY` everywhere is a pass; `UNHEALTHY` entries are affected objects for `GCP-040`-adjacent findings. A permission error means backend health is unprovable with the audit credential: file `GCP-043` with `status: blocked`, never guess health from the serving status of the frontend.

## 10. Logs as a signal (GCP-050 to GCP-054)

`GCP-050`: compare `logs-metrics.json` against the critical-service list from topology.md; every critical service wants one error-count logs-based metric (the roster comes from your topology, never from a canned list). `GCP-051`, the false-confidence check: a metric whose filter matches nothing recent counts nothing:

```bash
set -eu
GCP_PROJECT="your-project-id"       # gcp.project
METRIC_FILTER='resource.type="gce_instance" AND severity>=ERROR'   # copy the exact filter from logs-metrics.json
gcloud logging read "$METRIC_FILTER" --project "$GCP_PROJECT" --limit 1 --freshness=24h --format='value(timestamp)'
```

Expected: one timestamp. Empty output means the filter matched no entry in 24 hours: either the service is genuinely quiet (say so, with the service's traffic level as context) or the filter is wrong and the metric is a decoration (`GCP-051` fail). `GCP-052`: cross-reference metric names against `alert-policies.jsonl` filters containing `logging.googleapis.com/user/<metric-name>`; a critical-service error metric with no policy pages nobody. `GCP-053`: from `sinks.json`, verify the destinations your team expects exist and are not `disabled`, and read exclusion filters on the `_Default` sink; an exclusion that swallows a critical service's logs is silent loss.

`GCP-054`, retention: log buckets in Cloud Logging have their own retention period, independent of what's in `sinks.json`. A short retention on a bucket receiving critical-service logs means evidence ages out before anyone investigates, exactly the same failure shape as an unset retention flag on a self-hosted store (this audit's Prometheus/Loki/Tempo counterparts already check retention as its own line item; GCP logging needs the same one):

```bash
set -eu
GCP_PROJECT="your-project-id"       # gcp.project
gcloud logging buckets list --project "$GCP_PROJECT" --format='table(name,retentionDays,locked)'
```

Expected: every bucket receiving critical-service logs has a retention period that's a deliberate decision, not an unexamined default (`_Default` bucket ships at 30 days). A retention shorter than your team's real incident-to-investigation delay is a `GCP-054` finding; record the actual number and the decision (or its absence) in evidence, same discipline as `AWS-051`/`DO-051`.

## 11. Alert quality (GCP-060 to GCP-062)

`GCP-060`: policy `documentation.content` should follow the responder-ready shape (environment, resource, severity tier, metric, threshold and window, then the datapoints to capture first; the worked format lives in `setup-gcp#improve-alert-documentation`):

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/gcp/${RUN_DATE}/raw"
jq -r 'select(((.documentation.content // "") | length) < 40) | .displayName' "${RAW_DIR}/alert-policies.jsonl"
```

Expected: no output. The length cut is a screen, not the judgment: read what remains and fail documentation that names no environment, no resource, or no capture list. "Service down" alone tells a responder nothing at 3am. `GCP-061`: severity visible via `severity`, `userLabels`, or the documentation line; absence everywhere is the finding. `GCP-062`: thresholds with no baseline story (a 50 percent CPU page on a workload that idles at 60) and single-tier saturation-only alerts on volatile metrics; compare against the starting set in section 14 as examples, never as law.

## 12. Dashboards and correlation (GCP-070 to GCP-071)

From `dashboards.json` and the critical-service list: `GCP-070` wants per-service or per-surface dashboards that link the signals this audit covered (uptime, VM or GKE pressure, LB traffic, error logs). `GCP-071` is the inverse trap: **a dashboard is not an alert.** Dashboards covering a surface that has no alert policy get an info finding naming the surface, so nobody mistakes visibility for paging.

## 13. Per-service coverage rows

Assemble one row per critical service from the raw captures; re-fetch any cell you are about to fail. Matrix cell vocabulary is `pass`, `partial`, `fail`, `blocked`, `not-in-scope`, and every cell carries its `passed/total` denominator. Map VMs, GKE workloads, and backend services to canonical service names via topology.md when present; otherwise record the inference. The `Routing` cell folds in `GCP-002` to `GCP-006` for the channels this service's policies use; the `Logs` cell requires a matching, recently matching, policy-carrying logs-based metric to reach `pass`.

## 14. Starting alert set (tune per workload)

Conservative starting defaults, not prescriptions. Observe each workload's baseline before trusting any threshold; a threshold nobody derived is a page nobody believes.

```bash
UPTIME_PERIOD="60s"            # example check period
UPTIME_TIMEOUT="10s"           # example
UPTIME_FAIL_WINDOW="180s"      # example: alert when checks fail for this long
SSL_EXPIRY_DAYS="21"           # example: alert when the cert expires within this many days
CPU_WARN_PCT="80"              # example warning tier, tune to your baseline
CPU_SAT_PCT="95"               # example saturation tier; 99 for burst-tolerant workloads
CPU_WINDOW="300s"              # example
MEM_WARN_PCT="85"              # example; requires Ops Agent metrics first
DISK_WARN_PCT="85"             # example; requires Ops Agent metrics first
RESTART_SPIKE="3"              # example restarts per window per workload
LB_5XX_RATIO="0.05"            # example 5xx ratio, tune after observing normal error rates
LB_LATENCY_MS="1000"           # example p95 backend latency, tune to observed baseline
LOG_ERROR_RATE_WINDOW="300s"   # example window for logs-based error alerts
```

| Surface | Starting point | Avoid |
| --- | --- | --- |
| Uptime | HTTPS checks on verified 200 targets, `UPTIME_PERIOD` period, `UPTIME_TIMEOUT` timeout, multi-region, alert after `UPTIME_FAIL_WINDOW`; SSL expiry under `SSL_EXPIRY_DAYS` days | checks on auth-only 401 endpoints or unverified paths |
| Compute VM | CPU warning at `CPU_WARN_PCT` and saturation at `CPU_SAT_PCT` over `CPU_WINDOW`; memory `MEM_WARN_PCT` and disk `DISK_WARN_PCT` only after agent proof | memory or disk promises without agent metrics; single low thresholds with no baseline |
| GKE | restart spike above `RESTART_SPIKE` per workload window; pending and unschedulable pods; node pressure | assuming workload metrics exist without checking Managed Prometheus or components |
| Load balancer | 5xx ratio above `LB_5XX_RATIO`; p95 backend latency above `LB_LATENCY_MS` ms; request-anomaly alerts only after a baseline | thresholds copied between load balancers with different traffic shapes |
| Logs | one error-count metric per critical service, alert on rate over `LOG_ERROR_RATE_WINDOW` | metrics whose filter never matched a real entry |

Per-environment channel principle: keep separate logical notification channels per environment (for example `<team> staging alerts`, `<team> production alerts`) even when both route to the same chat workspace, so a page's origin is readable before its body.

## 15. Commands this audit must never run

Any of these appearing in an audit transcript is a lane violation, whatever the justification:

- `gcloud config set`, `gcloud config unset`, `gcloud config configurations activate|create` (mutates shared local gcloud state; the audit passes explicit flags instead)
- `gcloud auth login`, `gcloud auth activate-service-account`, `gcloud auth application-default login`, `gcloud auth revoke`
- `gcloud monitoring uptime create|update|delete`
- `gcloud monitoring dashboards create|update|delete`
- `gcloud monitoring snoozes create|update|cancel`
- `gcloud logging metrics create|update|delete`, `gcloud logging sinks create|update|delete`
- `gcloud container clusters create|update|delete|resize`, any `gcloud compute` mutation (`instances create|delete|reset|start|stop`, `backend-services create|update|delete`, firewall, DNS, or certificate changes)
- Any POST, PATCH, or DELETE against `monitoring.googleapis.com` or `logging.googleapis.com`, including `notificationChannels`, `alertPolicies`, `uptimeCheckConfigs`, `snoozes`, and `sendVerificationCode`/`verify` (setup lane only). The single POST-shaped call allowed is `gcloud compute backend-services get-health`, which reads state.
- Any POST to any webhook, including a smoke test; the toolkit Slack brief in the skill's final phase is the single exception and posts only to the brief webhook from `slack.webhook_env`
## 16. Large-path worklist: VMs and services in batches

Runnable commands for the large path named in [SKILL.md's Estate sizing](../SKILL.md#estate-sizing) and worked through in [Large-path worklist: VMs and services in batches](../SKILL.md#large-path-worklist-vms-and-services-in-batches). Every block here is stateless and redeclares its own inputs, per the stateless-command-block rule; nothing here depends on a prior block having run in the same shell. State lives under a run-ID-keyed directory, not a calendar-date directory: a run still batching at UTC midnight keeps writing into the same place instead of the next block landing in a fresh, empty date directory that abandons everything already pulled.

### 16.1 Find a resumable run, or start a new one

Scan for an interrupted run before minting a new `RUN_ID`. Never start fresh when a worklist with pending rows already exists; that throws away completed batches.

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
AUDIT_ROOT="./scoutflo-audits/gcp"

resumable=""
if [ -d "${AUDIT_ROOT}/runs" ]; then
  for d in "${AUDIT_ROOT}/runs"/*/; do
    [ -f "${d}worklist.tsv" ] || continue
    pending=$(awk -F'\t' '$3 == "pending"' "${d}worklist.tsv" | wc -l | tr -d ' ')
    [ "${pending}" -gt 0 ] || continue
    resumable="${d}"
    echo "resumable run found: ${d} (pending=${pending})"
  done
fi

if [ -n "${resumable}" ]; then
  echo "resume ${resumable} instead of starting a new run? offer this to the user before proceeding"
else
  echo "no resumable run found; safe to start a new one"
fi
```

### 16.2 Mint the run ID

Only after 16.1 finds nothing resumable. The run ID is a UTC second-precision timestamp, generated once and reused by every later block in the same run.

```bash
set -eu
AUDIT_ROOT="./scoutflo-audits/gcp"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"   # first-seen timestamp of this run; stable for its lifetime
RUN_DIR="${AUDIT_ROOT}/runs/${RUN_ID}"
mkdir -p "${RUN_DIR}"
echo "${RUN_ID}" > "${RUN_DIR}/run-id"
echo "run: ${RUN_ID}"
```

### 16.3 Build or resume the worklist

One row per VM, uptime check, and backend service from the Estate sizing counts, tab-separated: `kind` (`vm`, `uptime_check`, or `backend_service`), `name`, `status` (`pending` or `done`). Never rebuild a worklist that already exists in the resumed run directory; that forgets progress.

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
RUN_DIR="./scoutflo-audits/gcp/runs/20260717T140500Z"   # example; the resolved run directory from 16.1 or 16.2
WORKLIST="${RUN_DIR}/worklist.tsv"

if [ -f "${WORKLIST}" ]; then
  done=$(awk -F'\t' '$3 == "done"' "${WORKLIST}" | wc -l | tr -d ' ')
  pending=$(awk -F'\t' '$3 == "pending"' "${WORKLIST}" | wc -l | tr -d ' ')
  echo "resuming existing worklist: done=${done} pending=${pending}"
else
  : > "${WORKLIST}"
  gcloud compute instances list --project "$GCP_PROJECT" --format='value(name)' \
    | while read -r vm; do printf 'vm\t%s\tpending\n' "${vm}" >> "${WORKLIST}"; done
  gcloud monitoring uptime list-configs --project "$GCP_PROJECT" --format='value(name)' \
    | while read -r chk; do printf 'uptime_check\t%s\tpending\n' "${chk}" >> "${WORKLIST}"; done
  gcloud compute backend-services list --project "$GCP_PROJECT" --format='value(name)' \
    | while read -r bs; do printf 'backend_service\t%s\tpending\n' "${bs}" >> "${WORKLIST}"; done
  total=$(wc -l < "${WORKLIST}" | tr -d ' ')
  echo "built worklist: ${total} rows, all pending"
fi
```

### 16.4 Lock the worklist before claiming a batch

Two invocations of this skill running at once would otherwise race on the same worklist file and double-claim rows. A lock older than `LOCK_STALE_MINUTES` is treated as abandoned; processes die, laptops sleep, sessions get killed, so reclaiming a stale lock is a normal path, not an error.

```bash
set -eu
RUN_DIR="./scoutflo-audits/gcp/runs/20260717T140500Z"   # example; the resolved run directory
LOCK="${RUN_DIR}/worklist.lock"
LOCK_STALE_MINUTES="30"   # example, tune to your batch size and expected run length

now_epoch=$(date -u +%s)
if [ -f "${LOCK}" ]; then
  lock_pid=$(awk -F'\t' 'NR==1{print $1}' "${LOCK}")
  lock_epoch=$(awk -F'\t' 'NR==1{print $2}' "${LOCK}")
  age_minutes=$(( (now_epoch - lock_epoch) / 60 ))
  if [ "${age_minutes}" -lt "${LOCK_STALE_MINUTES}" ]; then
    echo "worklist locked by pid ${lock_pid}, age ${age_minutes}m; stop, do not claim a batch"
    exit 1
  fi
  echo "existing lock is ${age_minutes}m old (>= ${LOCK_STALE_MINUTES}m); treating as abandoned and reclaiming"
fi

printf '%s\t%s\n' "$$" "${now_epoch}" > "${LOCK}"
echo "lock acquired: pid=$$ at ${now_epoch}"
```

### 16.5 Claim a batch, pull and check, mark done, release the lock

Claim happens while the lock (16.4) is held; release happens right after the batch's rows are marked, so another process can claim the next batch. Run the Phase 4 (uptime), Phase 5 (VM), or Phase 7 (load balancer) checks against each claimed row using the commands already declared in sections 6, 7, and 9. A row is marked `done` only after its pulls and checks succeed, so a batch that fails partway resumes at the row that failed rather than replaying the whole batch.

```bash
set -eu
RUN_DIR="./scoutflo-audits/gcp/runs/20260717T140500Z"   # example; the resolved run directory
WORKLIST="${RUN_DIR}/worklist.tsv"
LOCK="${RUN_DIR}/worklist.lock"
BATCH_SIZE="10"   # example, tune it; matches the value declared in Estate sizing

BATCH_FILE="${RUN_DIR}/batch-$(date -u +%s).tsv"
awk -F'\t' '$3 == "pending"' "${WORKLIST}" | head -n "${BATCH_SIZE}" > "${BATCH_FILE}"
count=$(wc -l < "${BATCH_FILE}" | tr -d ' ')
echo "claimed batch: ${count} rows -> ${BATCH_FILE}"

# ... for each row in "${BATCH_FILE}", run the section 6 (uptime), section 7 (VM),
# or section 9 (load balancer) pulls and checks matching its kind, appending results
# to the run's incremental findings file. Only after every row's pulls succeed:

while IFS=$'\t' read -r kind name _status; do
  # mark this row done in place; a real run does this after its checks pass
  awk -F'\t' -v k="${kind}" -v n="${name}" 'BEGIN{OFS="\t"} $1==k && $2==n {$3="done"} {print}' \
    "${WORKLIST}" > "${WORKLIST}.tmp" && mv "${WORKLIST}.tmp" "${WORKLIST}"
done < "${BATCH_FILE}"

rm -f "${LOCK}"   # release once this batch (not the whole run) completes
done=$(awk -F'\t' '$3 == "done"' "${WORKLIST}" | wc -l | tr -d ' ')
pending=$(awk -F'\t' '$3 == "pending"' "${WORKLIST}" | wc -l | tr -d ' ')
echo "batch marked done: done=${done} pending=${pending}"
```

Expected: `pending` drops by the batch size (or less, on the final partial batch) after each pass through 16.4 and 16.5. Repeat 16.4 and 16.5 until `pending` reaches 0, then proceed to 16.6.

### 16.6 Assert pending=0 before the report is written

`findings.json` and `report.md` are written only once this assertion passes. A nonzero pending count means the run must resume batching, not publish.

```bash
set -eu
AUDIT_ROOT="./scoutflo-audits/gcp"
# RUN_DIR is the run-ID-keyed directory from this run; if this block runs in a
# fresh shell, fall back to the most recently modified run directory.
RUN_DIR="${RUN_DIR:-$(ls -dt "${AUDIT_ROOT}"/runs/*/ 2>/dev/null | head -n 1 | sed 's:/$::')}"
[ -n "${RUN_DIR}" ] && [ -f "${RUN_DIR}/worklist.tsv" ] || { echo "no worklist found; nothing to assert"; exit 1; }
pending=$(awk -F'\t' '$3 == "pending"' "${RUN_DIR}/worklist.tsv" | wc -l | tr -d ' ')
echo "worklist pending: ${pending}"
[ "${pending}" -eq 0 ] || { echo "worklist incomplete; do not write findings.json or report.md yet"; exit 1; }
echo "worklist complete; safe to write findings.json and report.md"
```

Rules:

- The lock covers one batch claim, not the whole run: acquire it right before reading pending rows, release it right after marking them done.
- A lock file holds exactly two tab-separated fields: the PID that holds it, and its UTC epoch start timestamp. Nothing else.
- `findings.json` and `report.md` are written only once 16.6 passes. A run stopped mid-batch leaves its worklist and partial findings in the run directory as the resume point; it never overwrites the previous complete report.
- Delete the run directory after `findings.json` and `report.md` are written; it is working state, not a report. Deleting it early forces a fresh start on the next invocation.

## 17. Alert hygiene: policy noise controls (GCP-063 to GCP-066)

Runs the Phase 9 alert-hygiene subsection. Every block is read-only and reuses the per-policy JSON already captured in section 4's `alert-policies.jsonl` (full policy objects, so `alertStrategy` and every condition are present); nothing here calls the API again or mutates. Honest ceiling, repeated because it belongs in the evidence: these are structural noise signals read off each policy's configuration, not an actionability rate. Cloud Monitoring keeps no public incident-history list API (the same limit `GCP-004` records), so the run cannot compute a fired-vs-actionable ratio and never reports one; it reports which policies are structurally noisy. Cloud Monitoring is rich per policy but has no cross-policy inhibition, no incident grouping, and no recurring time-based mute schedule (snoozes are one-off intervals) — state those as coverage limits, not findings. Snooze staleness that mutes a live critical policy is `GCP-006` (section 5) and is not re-checked here. Apply the named thresholds (`DURATION_MIN`, `AUTOCLOSE_MAX`, `RENOTIFY_MIN`, `RENOTIFY_MAX`) as the reader, exactly as the rest of this audit does; all are example values.

### 17.1 Retest window per condition (GCP-063)

`conditionThreshold.duration` (and `conditionAbsent.duration`) is the time the predicate must hold before an incident opens — the GCP analogue of a Prometheus `for`. `0s` or absent fires on a single violating sample. Log-match conditions carry no duration and are excluded (they are governed by 17.3); MQL and PromQL conditions carry their own duration and are read inline, the same limitation as `GCP-023`.

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/gcp/${RUN_DATE}/raw"
DURATION_MIN="60s"   # example, tune it: retest window below which a paging policy is single-sample noisy (multiples of 60s)

# GCP-063: per enabled policy, list every threshold/absence/MQL/PromQL condition's retest window;
# flag any policy with a 0s or absent duration. conditionMatchedLog conditions are skipped by design.
jq -r '
  select((.enabled // true) == true)
  | .displayName as $name
  | [ .conditions[]?
      | select(has("conditionThreshold") or has("conditionAbsent")
               or has("conditionMonitoringQueryLanguage") or has("conditionPrometheusQueryLanguage"))
      | ( .conditionThreshold.duration
          // .conditionAbsent.duration
          // .conditionMonitoringQueryLanguage.duration
          // .conditionPrometheusQueryLanguage.duration
          // "0s" ) ] as $durs
  | select(($durs | length) > 0)
  | select([ $durs[] | select(. == "0s" or . == "0") ] | length > 0)
  | "\($name): retest windows = [\($durs | join(", "))] (0s fires on a single sample)"
' "${RAW_DIR}/alert-policies.jsonl"
```

Expected: no output. Each printed line is one member of the `GCP-063` finding's `affected` array; a paging policy on a volatile metric with `0s` is the classic single-scrape-blip page. A duration below `DURATION_MIN` on a genuinely volatile signal is a judgment call — note the metric's volatility in evidence rather than failing on the number alone.

### 17.2 Auto-close of stale incidents (GCP-064)

`alertStrategy.autoClose` closes an open incident after the policy stops receiving data; unset means the effective seven-day default, so a transient condition can renotify for a week.

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/gcp/${RUN_DATE}/raw"
AUTOCLOSE_MAX="86400s"   # example, tune it: auto-close longer than this leaves incidents open too long

# GCP-064: autoClose per enabled policy; unset -> the effective 7-day default.
jq -r 'select((.enabled // true) == true)
  | "\(.displayName): autoClose=\(.alertStrategy.autoClose // "unset (effective 7d default)")"' \
  "${RAW_DIR}/alert-policies.jsonl"
```

Expected: every serving policy carries a deliberate `autoClose` no longer than `AUTOCLOSE_MAX`. `unset (effective 7d default)` on a serving policy is the finding; a stuck-open incident is renotify noise and a stale incident board, so this files at low severity, not a missed-page severity.

### 17.3 Repeat-notification throttle (GCP-065)

`alertStrategy.notificationRateLimit.period` caps notifications to one per period while an incident is open; absent means a notification per evaluation. Already required on log-based policies.

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/gcp/${RUN_DATE}/raw"

# GCP-065: repeat-notification throttle per enabled policy; unset = a notification per evaluation.
jq -r 'select((.enabled // true) == true)
  | "\(.displayName): notificationRateLimit.period=\(.alertStrategy.notificationRateLimit.period // "unset (no throttle)")"' \
  "${RAW_DIR}/alert-policies.jsonl"
```

Expected: a throttle on the high-churn policies. Flag `unset (no throttle)` only on the noisiest policies (the top-talkers the coverage work surfaces), not on every quiet one — a throttle absent on a policy that opens one incident a quarter is not a defect, and filing it there makes the finding itself noise.

### 17.4 Renotify cadence and resolve prompts (GCP-066)

`alertStrategy.notificationChannelStrategy[].renotifyInterval` is the reminder cadence for open incidents (documented range 30m-24h); `alertStrategy.notificationPrompts` including `CLOSED` emits a resolve notification per incident.

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/gcp/${RUN_DATE}/raw"
RENOTIFY_MIN="1800s"    # example: documented floor is 30 minutes
RENOTIFY_MAX="86400s"   # example: documented ceiling is 24 hours

# GCP-066: renotify cadence and resolve prompts per enabled policy.
jq -r 'select((.enabled // true) == true)
  | .displayName as $name
  | ([ .alertStrategy.notificationChannelStrategy[]?.renotifyInterval ] | map(. // "unset")) as $renotify
  | (.alertStrategy.notificationPrompts // ["OPENED (implied)"]) as $prompts
  | "\($name): prompts=[\($prompts | join(","))] renotifyInterval=[\($renotify | join(","))]"' \
  "${RAW_DIR}/alert-policies.jsonl"
echo "flag: renotifyInterval outside ${RENOTIFY_MIN}-${RENOTIFY_MAX} (GCP-066); CLOSED in prompts on a policy already flagged noisy by GCP-065 (resolve-noise)"
```

Expected: renotify intervals inside `RENOTIFY_MIN`-`RENOTIFY_MAX` where set, and `CLOSED` present only where a resolve notification is genuinely wanted. `CLOSED` roughly doubles a policy's volume, so it is `info` on its own and rises to `low` when it inflates a policy already flagged by 17.3. `OPENED (implied)` is the baseline and is not itself a finding.
