# Grafana Audit: API Surface, Permissions, Payloads, Check Catalog

Lookup material for the `audit-grafana` workflow. The workflow itself lives in [SKILL.md](../SKILL.md).

## Read-only API surface

Every call this audit makes. Classify by effect, not verb: `/api/ds/query` is a POST but executes a read-only query; it creates and changes nothing.

| Purpose | Method | Path | Notes |
| --- | --- | --- | --- |
| Instance health | GET | `/api/health` | No auth required. `database: "ok"` is healthy |
| Org identity | GET | `/api/org` | Org id and name; the identity check for both the doctor gate and the live-safety gate. `GET /api/user` is deliberately not used anywhere in this skill — confirmed live on Grafana 10.4.1 that a real, correctly-scoped service-account token gets a hard `403 "Endpoint only available for users"` from `/api/user` regardless of role, because that endpoint identifies an interactively logged-in user, not a service account |
| Folders | GET | `/api/folders?limit=1000` | Folder inventory |
| Datasource list | GET | `/api/datasources` | Full definitions minus secure fields |
| Datasource health | GET | `/api/datasources/uid/{uid}/health` | Some plugins do not implement it; fall back to a minimal query |
| Dashboard index | GET | `/api/search?type=dash-db&limit=1000&page={n}` | Paginated; loop until a short page |
| Dashboard JSON | GET | `/api/dashboards/uid/{uid}` | Live JSON, the object the QA gate judges |
| Alert rules | GET | `/api/v1/provisioning/alert-rules` | Grafana-managed rules with full definitions |
| One alert rule | GET | `/api/v1/provisioning/alert-rules/{uid}` | For focused re-checks |
| Alert rules fallback | GET | `/api/ruler/grafana/api/v1/rules` | Readable at lower privilege when provisioning returns 403 |
| Contact points | GET | `/api/v1/provisioning/contact-points` | Receiver inventory; secure settings are masked |
| Notification policies | GET | `/api/v1/provisioning/policies` | The routing tree |
| Mute timings | GET | `/api/v1/provisioning/mute-timings` | Silencing windows |
| Query execution | POST | `/api/ds/query` | Read-only query replay for panels and rules |
| Datasource proxy | GET | `/api/datasources/proxy/uid/{uid}/{backend-path}` | Read backend label APIs through Grafana, no backend credentials needed |

Proxy paths used by this audit (all GET, all read-only):

| Backend | Proxy path suffix | Returns |
| --- | --- | --- |
| Prometheus-compatible | `api/v1/label/{label}/values` | Values of one label, e.g. `service` |
| Prometheus-compatible | `api/v1/query?query={promql}` | Instant query result |
| Loki | `loki/api/v1/labels` | Log stream label names |
| Loki | `loki/api/v1/label/{label}/values` | Values of one log label |
| Loki | `loki/api/v1/query?query={logql}` | Instant LogQL result |

Anything deeper than label and instant-query reads (ingester health, retention config, compactor state, cardinality explorers) belongs to `audit-lgtm`, not here.

## Evidence-state contract

The bundled inventory script writes `request-status.jsonl`. Judge whether a
check is assessable from this ledger before interpreting a response file:

| State | Meaning | Audit treatment |
| --- | --- | --- |
| `success-empty` | HTTP 2xx, valid expected JSON shape, collection/object is empty | Verified empty only for the requested endpoint and scope |
| `success-nonempty` | HTTP 2xx, valid expected JSON shape, response is non-empty | Usable evidence; still apply the semantic check |
| `unauthenticated` | HTTP 401 | Blocked on credential validity |
| `forbidden` | HTTP 403 | Blocked on read scope; not an empty collection |
| `unsupported` | HTTP 404, 405, or 501 | Endpoint is unavailable on this deployment/version; use a documented fallback or mark blocked/not applicable |
| `transport-error` | DNS, TLS, timeout, connection, or other curl failure | Blocked on reachability |
| `http-error` | Other non-2xx response | Blocked unless a check explicitly defines that status as its result |
| `invalid-response` | HTTP 2xx but malformed JSON or wrong top-level shape | Blocked; often a proxy/login page or incompatible API |
| `partial` | One or more pages succeeded but a later required page failed | Object-level evidence only; never a complete-estate denominator |

For paginated dashboard search, `dashboard-index.json` means the pagination
completed. `dashboard-index.partial.json` means it did not. A failed first page
creates neither file. Never manufacture `[]` for a failed read, and never use a
partial index to pass GRAF-080, GRAF-090, GRAF-091, GRAF-092, or any other
estate-wide coverage claim.

## Minimum permissions

Build a dedicated read-only service account for auditing. With RBAC (Grafana Cloud, Enterprise, or OSS with RBAC enabled), grant exactly:

| Call group | RBAC action | Basic-role floor without RBAC |
| --- | --- | --- |
| Dashboards, folders, search | `dashboards:read`, `folders:read` | Viewer |
| Query execution, proxy reads | `datasources:query` | Viewer |
| Datasource enumeration | `datasources:read` | Org Admin |
| Provisioning reads (rules, contact points, policies) | `alert.provisioning:read` | Org Admin |
| Ruler fallback for rules | `alert.rules:read` | Viewer |

Without RBAC, a Viewer token runs a degraded but honest audit: datasource enumeration and provisioning reads return 403, those checks report `blocked` with the 403 as evidence, and rule reads fall back to the ruler API. Never upgrade the token to Admin just to avoid a `blocked` row; report the tradeoff and let your team decide.

Over-privilege probe (read-only; the desired outcome for an audit token is 403):

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }

# -sS without -f on purpose: a 403 here is the expected, healthy result.
# status-probe-ok: the HTTP status IS the evidence (a 403 is the expected healthy least-privilege result); asserting a JSON body would defeat the check.
code="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/org/users")"
echo "org-users read: HTTP ${code}"
```

Expected: `403` means least privilege holds. `200` means the token can administer org membership; file GRAF-006.

## /api/ds/query cookbook

**Always express the time window as Grafana relative-time strings — `from: "now-1h"`, `to: "now"` — for every datasource type, including Prometheus, Mimir, Loki, and other time-series backends.** Grafana parses these server-side into the range each datasource needs, so a panel or rule replays over a real, recent window with no client-side clock math. Do **not** compute an absolute epoch-milliseconds window (e.g. `NOW_MS=$(date +%s%3N); FROM_MS=$((NOW_MS - 300000))`) and pass it as `from`/`to`: it is unnecessary (the relative strings already cover instant and range queries), it makes the payload non-reproducible, and the `$(( … ))` arithmetic on a shell variable is rejected outright by Claude Code's command sandbox ("Arithmetic expansion references variable or non-literal"), which stops the audit for a permission prompt mid-run. If you ever need an instant value at "now" (for a cadvisor-style `count by(instance)(...)` probe), set `instant: true` on the query and keep `from: "now-5m", to: "now"` — never a computed millisecond literal.

### Pattern 1: replay a panel's own target (preferred)

The most reliable payload is the panel's own target object, because it carries every plugin-specific field. Build it from the raw dump written by `scripts/grafana-audit.sh`:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"          # grafana.url
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/$(date -u +%Y-%m-%d)/raw" # output dir of scripts/grafana-audit.sh
DASH_UID="abcd1234"                                 # from dashboard-index.json
PANEL_ID="3"                                        # from panel-targets.json
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }

jq --argjson pid "${PANEL_ID}" '
  .dashboard as $d
  | [ ($d.panels // [])[] | ., ((.panels // [])[]) ]
  | map(select(.id == $pid))[0] as $p
  | { from: "now-1h", to: "now",
      queries: [ ($p.targets // [])[]
                 | . + { datasource: (.datasource // $p.datasource),
                         maxDataPoints: 100, intervalMs: 60000 } ] }
' "${RAW_DIR}/dashboards/${DASH_UID}.json" > "${RAW_DIR}/replay-${DASH_UID}-${PANEL_ID}.json"

curl -fsS --max-time 20 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  -H "Content-Type: application/json" \
  -d @"${RAW_DIR}/replay-${DASH_UID}-${PANEL_ID}.json" \
  "${GRAFANA_URL}/api/ds/query" \
  > "${RAW_DIR}/replay-result-${DASH_UID}-${PANEL_ID}.json"

jq '{results: (.results | to_entries
      | map({refId: .key, error: (.value.error // null),
             frames: ((.value.frames // []) | length)}))}' \
  "${RAW_DIR}/replay-result-${DASH_UID}-${PANEL_ID}.json"

# Assert no refId came back with a live error. frames:0 with no error still needs
# a judgment call (intentional no-data vs label drift), so it is reported above,
# not asserted here.
jq -e '[.results[] | select(.error != null)] | length == 0' \
  "${RAW_DIR}/replay-result-${DASH_UID}-${PANEL_ID}.json" >/dev/null \
  && echo "no live query errors"
```

Expect: exit 0, prints `no live query errors`. A nonzero exit means at least one `refId` errored; the printed `results` block above names which one. Failure shapes:

| Shape | Meaning |
| --- | --- |
| `error` populated | Query is broken live: bad expression, missing label, wrong syntax for the backend. File GRAF-020 (panels) or GRAF-051 (rules) |
| `frames: 0`, no error | Query is valid but matches nothing. Distinguish "intentional no-data" from "label drift" before scoring |
| HTTP 400 | Malformed replay. Some plugins need extra target fields; copy the target object verbatim, do not reconstruct it |
| HTTP 403 | Token lacks query access on that datasource. Record as `blocked` |
| `datasource` null in the payload | The panel inherits the org default (GRAF-003). Fill in the default's UID from `datasources.json` to replay |

### Pattern 2: direct Prometheus-style instant query

For parity checks and coverage probes where you write the expression yourself:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
DS_UID="prom-uid"                            # datasource uid from datasources.json
PROMQL="sum(rate(http_requests_total[5m]))"  # the expression under test
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }

jq -n --arg uid "${DS_UID}" --arg expr "${PROMQL}" '
  { from: "now-5m", to: "now",
    queries: [ { refId: "A", datasource: { uid: $uid }, expr: $expr,
                 instant: true, maxDataPoints: 100, intervalMs: 60000 } ] }' \
| curl -fsS --max-time 20 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
    -H "Content-Type: application/json" -d @- "${GRAFANA_URL}/api/ds/query" \
| jq '.results.A | {error: (.error // null), frames: ((.frames // []) | length)}'
```

### Pattern 3: label parity and ingestion probes via the proxy

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
PROM_UID="prom-uid"                          # Prometheus-compatible datasource uid
LOKI_UID="loki-uid"                          # Loki datasource uid
SERVICE="checkout"                           # one service name from topology.md
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
SCRATCH="$(mktemp -d)"                       # this run's throwaway comparison files
trap 'rm -rf "${SCRATCH}"' EXIT

# Service label values on the metrics side
curl -fsS --max-time 15 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  "${GRAFANA_URL}/api/datasources/proxy/uid/${PROM_UID}/api/v1/label/service/values" \
  | jq -r '.data[]' | sort | tee "${SCRATCH}/metrics-services.txt"

# Service label values on the logs side; diff the two lists for identity drift
curl -fsS --max-time 15 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  "${GRAFANA_URL}/api/datasources/proxy/uid/${LOKI_UID}/loki/api/v1/label/service/values" \
  | jq -r '.data[]' | sort | tee "${SCRATCH}/logs-services.txt"

# Assert SERVICE resolves under the same name on both sides.
grep -qx -- "${SERVICE}" "${SCRATCH}/metrics-services.txt" \
  && grep -qx -- "${SERVICE}" "${SCRATCH}/logs-services.txt" \
  && echo "${SERVICE}: present under the same name on metrics and logs"

# Recent log ingestion for one service (instant LogQL through the proxy)
count_result="$(curl -fsS --max-time 15 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  --get --data-urlencode "query=sum(count_over_time({service=\"${SERVICE}\"}[15m]))" \
  "${GRAFANA_URL}/api/datasources/proxy/uid/${LOKI_UID}/loki/api/v1/query")"
echo "${count_result}" | jq '.data.result'

# Assert the instant LogQL query returned at least one nonzero sample.
echo "${count_result}" | jq -e '[.data.result[]?.value[1] // "0" | tonumber] | any(. > 0)' >/dev/null \
  && echo "recent log ingestion confirmed"
```

Expect: both `grep -qx` checks succeed (`${SERVICE}` present under the same name on both sides) and the final `jq -e` exits 0 with recent ingestion confirmed. A missing grep match means the name differs across sources; a nonzero `jq -e` exit means the LogQL count is zero or absent. Either is a correlation defect: name both spellings in the finding. For metrics ingestion, probe a metric you know the service emits; a bare `{service="x"}` selector over all series can be expensive on large installations, so prefer a scoped expression (example approach, tune to your environment).

## Datasource inspection snippets

Plaintext secret check (GRAF-002). The API masks `secureJsonData`, so any secret-shaped value visible in `jsonData` or in the URL userinfo is stored in the wrong place:

```bash
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/$(date -u +%Y-%m-%d)/raw"   # output dir of scripts/grafana-audit.sh
jq '[ .[] | { name, uid, type,
      secure_fields: ((.secureJsonFields // {}) | keys),
      plaintext_suspects: [ (.jsonData // {}) | to_entries[]
        | select(.value | type == "string" and length > 0)
        | select(.key | test("key|token|secret|password|credential"; "i"))
        | .key ],
      userinfo_in_url: ((.url // "") | test("://[^/]*:[^/]*@")) }
    | select((.plaintext_suspects | length) > 0 or .userinfo_in_url) ]' \
  "${RAW_DIR}/datasources.json"
```

Report the key names only, never the values. Duplicate backends (GRAF-005):

```bash
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/$(date -u +%Y-%m-%d)/raw"   # output dir of scripts/grafana-audit.sh
jq '[ group_by(.type + "|" + (.url // ""))[] | select(length > 1)
      | { type: .[0].type, url: .[0].url, names: [ .[].name ] } ]' \
  "${RAW_DIR}/datasources.json"
```

Dangling datasource references in panels (GRAF-028):

```bash
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/$(date -u +%Y-%m-%d)/raw"   # output dir of scripts/grafana-audit.sh
jq --slurpfile ds "${RAW_DIR}/datasources.json" '
  ([ $ds[0][].uid ]) as $known
  | [ .[] | . as $row | ($row.datasource.uid? // empty)
      | select(test("^\\$") | not)            # skip datasource template variables
      | select(. as $u | $known | index($u) | not)
      | { dashboard_uid: $row.dashboard_uid, panel_id: $row.panel_id, missing_uid: . } ]' \
  "${RAW_DIR}/panel-targets.json"
```

## Check catalog

Permanent IDs. Never renumber, never reuse a retired ID; deltas depend on stability. One finding per failed check, with every affected object in `affected`.

| ID | Area | Default severity | Check |
| --- | --- | --- | --- |
| GRAF-001 | Datasources and access | high | At least one datasource exists, and every datasource passes its health check (or a minimal query when the plugin has no health endpoint). Zero datasources on a healthy instance is itself a `GRAF-001` fail, not a vacuous pass — a per-datasource loop over an empty list trivially "passes" with nothing actually checked, which is a real, previously-observed failure shape: `/api/health` reporting `ok` while the instance has zero datasources and zero dashboards configured, telling a customer nothing about whether the instance is actually usable for correlation |
| GRAF-002 | Datasources and access | critical | No datasource stores credentials in plaintext `jsonData` or URL userinfo; secrets live in secure fields |
| GRAF-003 | Datasources and access | low | Panels name their datasource explicitly instead of inheriting the implicit org default |
| GRAF-004 | Datasources and access | medium | Each datasource returns usable data for a minimal domain query, not just a passing health probe |
| GRAF-005 | Datasources and access | low | No duplicate datasources point at the same backend with diverging configs |
| GRAF-006 | Datasources and access | low | The audit token is least-privilege; it cannot administer the org |
| GRAF-007 | Datasources and access | high | No enabled public dashboard exposes internal queries and data to the internet without auth (`/api/dashboards/public-dashboards`) |
| GRAF-020 | Dashboard semantics | high | Every panel target succeeds when replayed live through `/api/ds/query` |
| GRAF-021 | Dashboard semantics | high | No panel silently queries org-wide, account-wide, or all-environment scope while its title claims one service |
| GRAF-022 | Dashboard semantics | medium | External-system panels filter by stable IDs, not text or slug matching |
| GRAF-023 | Dashboard semantics | medium | No capped or paginated list is presented as a total |
| GRAF-024 | Dashboard semantics | medium | Every stat reducer matches the source shape; row counts only over rows that are the intended unit |
| GRAF-025 | Dashboard semantics | medium | Every template variable resolves to at least one real value |
| GRAF-026 | Dashboard semantics | low | Panel links and inspect links preserve the panel's scope |
| GRAF-027 | Dashboard semantics | high | Key stat values agree with the provider-native source of truth |
| GRAF-028 | Dashboard semantics | high | No panel references a datasource UID that does not exist |
| GRAF-050 | Alerting | critical | No alert rule routes to an empty, missing, or placeholder receiver |
| GRAF-051 | Alerting | high | Every active rule's query succeeds when replayed live |
| GRAF-052 | Alerting | medium | `noDataState` and `execErrState` are set deliberately per rule, not left at defaults unexamined |
| GRAF-053 | Alerting | medium | Every rule carries severity and service labels |
| GRAF-054 | Alerting | low | Every paging rule has summary and runbook annotations |
| GRAF-055 | Alerting | medium | Each severity route has been proven live at least once; unproven routes are `configured`, not working |
| GRAF-056 | Alerting | low | Grouping, group wait, and repeat interval are tuned on high-volume routes |
| GRAF-057 | Alerting | high | No `isPaused==true` alert rule on a covered service silently monitors nothing (the rule exists so coverage counts it, but its evaluator is administratively off) |
| GRAF-070 | Query hygiene | medium | Counter metrics are queried with `rate` or `increase`, never raw |
| GRAF-071 | Query hygiene | low | Expensive expressions repeated across panels or rules are backed by recording rules |
| GRAF-072 | Query hygiene | medium | Log stream labels are low-cardinality; IDs, users, and URLs stay in fields, not labels |
| GRAF-080 | Usage and cost | medium | An ingestion and usage health dashboard exists and returns data |
| GRAF-081 | Usage and cost | medium | Alerts exist on ingestion volume or spend movement |
| GRAF-082 | Usage and cost | low | Retention is a documented decision, not an inherited default |
| GRAF-090 | Service coverage | medium | Every critical service has at least one dashboard |
| GRAF-091 | Service coverage | high | Every critical service has at least one severity-labeled alert rule |
| GRAF-092 | Service coverage | high | Recent ingestion is visible for every critical service label |
| GRAF-100 | Alerting | medium | Every paging-severity rule sets a pending period (`for` > 0) so a single transient breach does not page; `for: 0s` on a volatile signal is flap-prone |
| GRAF-101 | Alerting | medium | Flap-prone paging rules carry resolve damping: a `keep_firing_for` hold (Recovering state) and/or a distinct recovery-threshold (hysteresis) bound, not a single threshold with `keep_firing_for: 0s` |
| GRAF-102 | Alerting | low | Muting hygiene: every route-referenced mute timing resolves to a definition, and no active Grafana silence has a far-future or perpetually-renewed `endsAt` hiding real alerts |
| GRAF-103 | Alerting | low | Paging contact points set `disableResolveMessage` deliberately; always-on resolved-message traffic roughly doubles a paging integration's notification volume |

Remediation pointers: every GRAF finding points at `setup-grafana`, anchored to the section that fixes that class of defect (for example `setup-grafana#contact-points` for GRAF-050). GRAF-055 may alternatively point at `audit-alertmanager`, which proves delivery paths end to end.

## Paused rules and public dashboards (GRAF-057, GRAF-007)

Two exposures the presence-only checks miss: a rule that *exists* but is turned off, and a dashboard that is world-readable. Both endpoints verified live on Grafana 12.3.1 (read-only GET; they return valid JSON — an empty list is a clean pass, not an error).

```bash
# GRAF-057: alert rules that are administratively paused. A paused rule still counts toward
# coverage (GRAF-091) but evaluates nothing — the service looks monitored and is not.
curl -fsS --max-time 15 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  "${GRAFANA_URL}/api/v1/provisioning/alert-rules" \
  | jq -r '[.[]? | select(.isPaused==true)] as $p
           | "paused rules: \($p|length)", ($p[] | "  \(.title)\tservice=\(.labels.service // "-")\tseverity=\(.labels.severity // "-")")'
# Join the paused rules' service labels against the topology critical list to size the blast radius.

# GRAF-007: public (unauthenticated) dashboards. Each enabled one is reachable at
# /public-dashboards/{accessToken} with NO auth, exposing its panel queries and data.
curl -fsS --max-time 15 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  "${GRAFANA_URL}/api/dashboards/public-dashboards" \
  | jq -r '(.publicDashboards // .) as $d
           | if ($d|type)=="array" then "public dashboards: \($d|length)", ($d[] | select(.isEnabled==true) | "  ENABLED dashboardUid=\(.dashboardUid)")
             else "public dashboards: \(($d.publicDashboards // [])|length)" end'
```

- **GRAF-057 (high):** any `isPaused==true` rule on a covered service — name the rule, its service, and severity, and state that the service's alerting coverage (GRAF-091) is illusory for as long as it stays paused. Blast radius is the count of covered critical services whose only rule is paused. Remediation `setup-grafana#alert-rules`.
- **GRAF-007 (high):** any `isEnabled==true` public dashboard — join `dashboardUid` to the dashboard title and its panel expressions and state exactly what internal data and label values are world-readable (host class only, never a secret value). Remediation `setup-grafana#dashboards`. Verified live: the benchmark Grafana returns `0` for both (a clean pass), proving the endpoints and filters work on a real instance.

## Alert-hygiene noise signals (GRAF-100 to GRAF-103)

Lookup material for [Phase 4b](../SKILL.md#phase-4b-alert-hygiene-noise-signals). Every block is read-only and reuses the provisioning objects the inventory script already wrote (`alert-rules.json`, `notification-policies.json`, `contact-points.json`) plus two cheap live reads. Each block re-declares its inputs so it runs pasted into a fresh shell.

Honest ceiling, repeated because it belongs in the evidence: these are **structural config signals**, not an observed flapping rate or a per-receiver page volume. Grafana-managed alerting's provisioning API exposes rule and policy *config* but no firing-episode history and no notification counters, so this audit reports the config that predicts noise, not measured noise — and inhibition is not checkable at all because the built-in Grafana Alertmanager does not support it (only Mimir/Cortex or an external Alertmanager do). A `401`/`403` on any read here blocks its check; it is never a clean or passing result.

### H.1 Pending period `for`, flap hold, and no-data/error state (GRAF-100, GRAF-101, and the GRAF-052 noise reading)

```bash
set -eu
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/$(date -u +%Y-%m-%d)/raw"   # this run's raw dir
# for: 0s -> no pending-period debounce (GRAF-100). keep_firing_for: 0s/absent -> no resolve/flap hold (GRAF-101).
# no_data_state / exec_err_state == "Alerting" is the noisy choice that pages on a transient gap (folds into GRAF-052).
jq -r '.[]
  | select((.labels.severity // "") != "")
  | "\(.uid) \(.title) severity=\(.labels.severity // "-") for=\(.["for"] // "0s") keep_firing_for=\(.keep_firing_for // "0s") no_data_state=\(.no_data_state // "NoData") exec_err_state=\(.exec_err_state // "Error")"' \
  "${RAW_DIR}/alert-rules.json" | sort
echo "flag: paging-severity rule with for=0s (GRAF-100); with keep_firing_for=0s and no recovery bound in H.2 (GRAF-101); with no_data_state/exec_err_state=Alerting (GRAF-052 noise reading)"
```

`for` and `keep_firing_for` are duration strings (`0s` is the flap-prone value). `no_data_state` takes `NoData`/`Alerting`/`OK`/`KeepLast` (default `NoData`); `exec_err_state` takes `Error`/`Alerting`/`OK`/`KeepLast` (default `Error`). `Alerting` on either is the noisy choice: a transient no-data gap or a query error pages via a synthetic `DatasourceNoData` / `DatasourceError` instance, especially when `for` is short or zero.

### H.2 Recovery-threshold (hysteresis) read (GRAF-101)

A recovery threshold sets a distinct bound for returning to Normal, separate from the firing bound, so a metric hovering at the threshold does not flap. It lives in the rule's threshold condition, which `alert-rules.json` already carries in each rule's `data` model (equivalent to `GET /api/v1/provisioning/alert-rules/{uid}/export`).

```bash
set -eu
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/$(date -u +%Y-%m-%d)/raw"   # this run's raw dir
# Surface every threshold condition on paging rules for a judgment read: a single evaluator with no
# distinct recovery bound is single-threshold (no hysteresis).
jq -r '.[]
  | select((.labels.severity // "") != "")
  | .uid as $u | .title as $t
  | (.data // [])[]
  | select((.model.type // "") == "threshold")
  | "\($u) \($t) refId=\(.refId // "-") conditions=\((.model.conditions // []) | length)"' \
  "${RAW_DIR}/alert-rules.json"
echo "read: the field naming for the recovery bound varies by Grafana version, so read the condition; do not pattern-match one field name. Single evaluator, no recovery bound = GRAF-101 flap protection absent."
```

The Grafana docs describe this as a recovery threshold and an explicit flapping-noise reducer; they do not use the terms "hysteresis" or "unloadEvaluator" (those are informal labels for the internal field). Read the condition, do not assert an exact field name as official.

### H.3 Grouping semantics and synthetic-alert routing (folds into GRAF-056 and GRAF-052)

```bash
set -eu
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/$(date -u +%Y-%m-%d)/raw"   # this run's raw dir
# group_by semantics (folds into GRAF-056). Empty list [] -> everything collapses into one group.
# The special value ["..."] -> "group by ALL labels", which DISABLES aggregation (one group per distinct alert).
jq -r '[.. | objects | select(has("group_by"))
        | {receiver: (.receiver // "-"), group_by: .group_by}]
       | .[] | "\(.receiver) group_by=\(.group_by | tojson)"' \
  "${RAW_DIR}/notification-policies.json"
# Any policy routing the synthetic no-data / error alerts deliberately (relevant to the GRAF-052 noise reading):
jq -r '[.. | objects | select(has("object_matchers"))
        | .object_matchers[]? | select(.[0] == "alertname") | .[2]]
       | unique[]?' "${RAW_DIR}/notification-policies.json"
```

A `group_by` of `[]` collapses everything into one group; `['...']` disables aggregation and yields one group per distinct alert — the opposite of grouping. A meaningful `group_by` names the few labels that define an incident (for example `['alertname','grafana_folder']`). The second read confirms whether `DatasourceNoData` / `DatasourceError` are deliberately routed; an unrouted synthetic alert produced by an `Alerting` no-data/error state (H.1) is silent noise.

### H.4 Mute-timing references and stale silences (GRAF-102)

```bash
set -eu
GRAFANA_URL="https://grafana.example.com"   # grafana.url
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/$(date -u +%Y-%m-%d)/raw"   # this run's raw dir
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }

# Defined mute timings, fetched live (read-only).
curl -fsS --max-time 15 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  "${GRAFANA_URL}/api/v1/provisioning/mute-timings" > "${RAW_DIR}/mute-timings.json"
jq -r '.[]?.name' "${RAW_DIR}/mute-timings.json" | sort -u

# Assert every route-referenced mute timing resolves to a definition (a dangling reference is a config error).
jq -e --slurpfile mt "${RAW_DIR}/mute-timings.json" '
  ([$mt[0][].name]) as $defined
  | ([.. | objects | select(has("mute_time_intervals")) | .mute_time_intervals[]?] | unique) as $referenced
  | ($referenced - $defined) | length == 0
' "${RAW_DIR}/notification-policies.json"
```

Expect: exit 0, prints `true`. A `false` (nonzero exit) means a route references a mute timing that does not exist; re-run with `- $defined` removed from the filter to print the dangling names. A mute timing defined but referenced by no route is configured-but-unused. Then list active silences:

```bash
set -eu
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
# Active Grafana silences (read-only). Grafana auto-deletes expired silences after 5 days, so a lingering
# active one is a deliberate act; a far-future or perpetually-renewed endsAt is hiding real alerts (GRAF-102).
curl -fsS --max-time 15 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  "${GRAFANA_URL}/api/alertmanager/grafana/api/v2/silences" \
  | jq -r '.[] | select(.status.state == "active")
      | "silence \(.id) starts=\(.startsAt) ends=\(.endsAt) by=\(.createdBy // "?") matchers=\([.matchers[]? | "\(.name)=\(.value)"] | join(","))"'
```

A `401`/`403` on either call blocks GRAF-102; it is never read as "no dangling references" or "no stale silences".

### H.5 Resolve-noise on paging contact points (GRAF-103)

```bash
set -eu
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/$(date -u +%Y-%m-%d)/raw"   # this run's raw dir
# disableResolveMessage true -> resolved notifications suppressed. false/absent -> a fire AND a resolve
# per incident, roughly doubling a paging integration's volume (GRAF-103).
jq -r '.[]
  | "\(.name) type=\(.type // "-") disableResolveMessage=\(.disableResolveMessage // false)"' \
  "${RAW_DIR}/contact-points.json" | sort
echo "flag: a paging contact point (referenced by a route reaching a paging severity) with disableResolveMessage=false is resolve-noise. Grafana's provisioning API carries no per-receiver notification counter, so this is a config signal, not an observed volume."
```

Cross-reference the receiver name against the policy tree (Phase 4's receiver-wiring read) to confirm it is on a paging path before filing; a `disableResolveMessage: false` on a low-severity informational receiver is not resolve-noise.
