# audit-digitalocean: Check Catalog and Commands

Runnable, read-only checks for every surface the [audit-digitalocean](../SKILL.md) workflow covers. Each section lists the catalog IDs it serves, the commands, the expected healthy output, and what the common failure shapes mean. Evidence for a finding is the command plus its observed output, trimmed with truncation marked.

## 1. Conventions

- doctl authenticates from the `DIGITALOCEAN_ACCESS_TOKEN` environment variable (named by `digitalocean.token_env` in `~/.scoutflo/toolkit.yaml`). Presence-check it only; never echo, log, or write the value anywhere.
- `doctl ... -o json` emits a JSON array for list commands. Get commands return an object on some doctl versions and a single-element array on others; the defensive filter `(if type=="array" then .[0] else . end)` handles both and appears wherever a get is parsed.
- Every command here is read-only: `doctl` list/get subcommands and `curl` GET or HEAD. The forbidden-command list is section 14. `doctl apps propose` deploys nothing but belongs to the setup lane; the audit never calls it.
- `curl -fsS --max-time 15` is the default. Where the status code is itself the evidence (endpoint probes, ownership checks), `-f` is dropped deliberately and `-w '%{http_code}'` captures the code; those blocks say so.
- Alert-policy and uptime-alert JSON can embed Slack webhook URLs. Every capture in this file strips them with jq at the source; never relax those filters.
- Thresholds and windows are examples; tune to your workloads. Named defaults live in section 12.
- Troubleshooting only: if doctl times out while curl to public sites works, retry once with proxy variables cleared (`env -u HTTPS_PROXY -u https_proxy doctl account get`) before concluding permissions are broken.

## 2. Check catalog

One permanent ID per check. IDs never change or get reused; retired checks keep their number. Severity listed is the typical severity when the check fails; judge the real impact in your environment.

| ID | Category | Check | Typical fail severity |
| --- | --- | --- | --- |
| DO-001 | Alert routing and delivery | Any alert destination exists across apps and policies | critical |
| DO-002 | Alert routing and delivery | Every enabled alert has at least one destination | high |
| DO-003 | Alert routing and delivery | Destinations reach the right team and environment channel | medium |
| DO-004 | Alert routing and delivery | Delivery proven by an observed DO-generated event | high |
| DO-005 | Alert routing and delivery | Alert text responder-ready where custom descriptions are supported | low |
| DO-070 | Alert routing and delivery | No enabled policy pinned at the shortest dwell window without a documented reason | medium |
| DO-071 | Alert routing and delivery | No disabled alert policy silently muting coverage (DO has no timed silence) | medium |
| DO-072 | Alert routing and delivery | Near-identical single-entity policies collapsed into one tag-scoped policy | low |
| DO-010 | Uptime and availability | Every active public hostname has an uptime check | high |
| DO-011 | Uptime and availability | Down alert on every uptime check | high |
| DO-012 | Uptime and availability | Latency alert on every uptime check | medium |
| DO-013 | Uptime and availability | SSL-expiry alert on every HTTPS uptime check | medium |
| DO-014 | Uptime and availability | Multi-region checks where regional failure matters | low |
| DO-015 | Uptime and availability | No checks against dead, archived, or migrated targets | medium |
| DO-016 | Uptime and availability | Live TLS certificate on a monitored HTTPS hostname is not within the expiry window now | high |
| DO-020 | App Platform alert coverage | Deployment lifecycle alerts, failed and live at minimum | high |
| DO-021 | App Platform alert coverage | Domain lifecycle alerts | medium |
| DO-022 | App Platform alert coverage | CPU and memory alerts per active service component | high |
| DO-023 | App Platform alert coverage | Restart-count alert per active service component | high |
| DO-024 | App Platform alert coverage | Request-rate and p95-duration alerts from observed baselines | medium |
| DO-025 | App Platform alert coverage | Alert rule enums recorded as the API returns them; doc mismatches noted | info |
| DO-030 | App health checks and runtime | Health check configured per service component | high |
| DO-031 | App health checks and runtime | Health-check path answers 200 live without auth, Origin, or session | high |
| DO-032 | App health checks and runtime | Single-instance production services identified | medium |
| DO-033 | App health checks and runtime | Autoscaling posture recorded; no guessed request-based scaling | info |
| DO-040 | Managed databases | CPU alert policy per production database | high |
| DO-041 | Managed databases | Memory alert policy per production database | high |
| DO-042 | Managed databases | Disk alert policy per production database | high |
| DO-043 | Managed databases | No noisy or duplicate database policies | medium |
| DO-044 | Managed databases | Recent backups listed for every production database | high |
| DO-045 | Managed databases | Standby or HA posture on production clusters | high |
| DO-046 | Managed databases | Firewall and trusted sources restricted; drift recorded | high |
| DO-047 | Managed databases | Logsink configured or absence recorded as a decision | medium |
| DO-048 | Managed databases | Engine signals beyond CPU, memory, and disk reviewed where exposed | medium |
| DO-050 | Log forwarding | App runtime logs forwarded centrally or absence a recorded decision | high |
| DO-051 | Log forwarding | Backend decision complete: retention, redaction, naming, owner | medium |
| DO-052 | Log forwarding | App-destination versus database-logsink mismatch handled | medium |
| DO-060 | Ownership and hygiene | DNS and runtime ownership verified per monitored hostname | medium |
| DO-061 | Ownership and hygiene | Archived or migrated apps excluded from monitoring | medium |
| DO-062 | Ownership and hygiene | Secret-shaped env keys stored as SECRET type | high |

## 3. Target profile

What 100/100 means per category; the checks above are this profile made executable.

- **Alert routing and delivery**: every enabled alert names a destination a human reads, mapped per service and environment, with at least one observed DO-generated delivery per destination class, and free-text descriptions that tell the responder what to capture.
- **App Platform alert coverage**: every active app alerts on deploy failure and go-live, domain failure, CPU, memory, and restarts; request-rate and p95 alerts exist where baselines support them, with the baseline recorded.
- **Managed databases**: every production cluster has two-tier CPU, memory, and disk policies, no duplicate or 50-percent-style noise, listed recent backups, an HA decision, a restricted firewall, a logsink decision, and a recorded view of engine signals beyond the big three.
- **Uptime and availability**: every live public hostname has a multi-region check with down, latency, and SSL-expiry alerts, and no check watches a dead target.
- **App health checks and runtime**: every service component has a verified, dependency-free health-check path; single-instance production services and autoscaling posture are named facts, not surprises.
- **Log forwarding**: runtime and database logs land in one owned backend with retention, redaction, and naming decided, or the absence is a written decision.
- **Ownership and hygiene**: monitoring watches only what DO actually serves, and no secret lives in a plaintext env var.

## 4. Inventory (all categories)

Capture raw state once per run; later sections re-fetch specific objects before filing findings.

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/${RUN_DATE}/raw"
mkdir -p "$RAW_DIR"

doctl apps list -o json | jq '[.[] | {id, name: .spec.name, live_url,
  active_deployment_id: (.active_deployment.id // null),
  active_phase: (.active_deployment.phase // null),
  in_progress_deployment: (.in_progress_deployment.id // null),
  domains: [.spec.domains[]?.domain]}]' > "${RAW_DIR}/apps.json"

doctl databases list -o json | jq '[.[] | {id, name, engine, version, num_nodes, size, status, region}]' \
  > "${RAW_DIR}/databases.json"

doctl monitoring uptime list -o json | jq '[.[] | {id, name, target, type, regions, enabled}]' \
  > "${RAW_DIR}/uptime-checks.json"

# Strip Slack webhook URLs at capture; keep channel names and counts only.
doctl monitoring alert list -o json | jq '[.[] | {uuid, type, description, compare, value, window, enabled,
  entities, tags, emails: ((.alerts.email // []) | length),
  slack_channels: [.alerts.slack[]?.channel]}]' > "${RAW_DIR}/alert-policies.json"

jq -r '.[].id' "${RAW_DIR}/apps.json" | while read -r app_id; do
  d="${RAW_DIR}/apps/${app_id}"; mkdir -p "$d"
  doctl apps list-alerts "$app_id" -o json | jq '[.[] | {id, rule: .spec.rule, disabled: (.spec.disabled // false),
    operator: (.spec.operator // null), value: (.spec.value // null), window: (.spec.window // null),
    emails: ((.emails // []) | length), slack_channels: [.slack_webhooks[]?.channel]}]' > "${d}/alerts.json"
  doctl apps list-deployments "$app_id" -o json | jq '[.[0:5][] | {id, phase, cause, updated_at}]' > "${d}/deployments.json"
done
```

Expected: one JSON file per surface, plus per-app alert and deployment files. An empty `apps.json` with a non-empty account is itself information: the estate may be Droplet- or DOKS-based, and this audit covers only the App Platform, database, uptime, and monitoring surfaces.

Per-database detail (`doctl databases backups` lists backups; the logsink subcommand is unreliable across doctl versions, so this always uses the curl endpoint directly — see the note below):

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/${RUN_DATE}/raw"
jq -r '.[].id' "${RAW_DIR}/databases.json" | while read -r db_id; do
  d="${RAW_DIR}/databases/${db_id}"; mkdir -p "$d"
  doctl databases firewalls list "$db_id" > "${d}/firewall.txt" || echo "firewall read failed" > "${d}/firewall.txt"
  doctl databases backups "$db_id" > "${d}/backups.txt" || echo "no backups listed" > "${d}/backups.txt"
  doctl databases user list "$db_id" --format Name --no-header | wc -l > "${d}/user-count.txt"
  curl -fsS --max-time 15 -H "Authorization: Bearer ${DIGITALOCEAN_ACCESS_TOKEN}" \
       "https://api.digitalocean.com/v2/databases/${db_id}/logsink" > "${d}/logsinks.json" \
    || echo '{"sinks":[]}' > "${d}/logsinks.json"
done
```

`doctl databases logsink list` is not a real subcommand on at least doctl 1.155.0: it silently prints the top-level `databases --help` text and **exits 0**, so a `|| curl fallback` after it never triggers — the help text gets written into `logsinks.json` as if it were data. Confirmed live during the 2026-07-20 audit-digitalocean run against a real DO account. Also confirmed live: the correct REST path is singular, `/v2/databases/{id}/logsink`, not `/v2/databases/{id}/logsinks` as an earlier version of this doc had it — the plural path 404s. Go straight to the curl call; do not attempt the doctl subcommand first.

## 5. Alert routing and delivery (DO-001 to DO-005)

Any destination at all, and per-alert destinations:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/${RUN_DATE}/raw"
# DO-001: total destinations across monitoring policies and app alerts. 0 total is critical.
jq '[.[] | .emails + (.slack_channels | length)] | add // 0' "${RAW_DIR}/alert-policies.json"
cat "${RAW_DIR}"/apps/*/alerts.json | jq -s '[.[][] | .emails + (.slack_channels | length)] | add // 0'
# DO-002: enabled alerts with zero destinations, by surface.
jq -r '.[] | select(.enabled and (.emails + (.slack_channels | length)) == 0) | "policy \(.uuid) \(.type)"' \
  "${RAW_DIR}/alert-policies.json"
cat "${RAW_DIR}"/apps/*/alerts.json | jq -rs '.[][] | select((.disabled | not) and (.emails + (.slack_channels | length)) == 0) | "app-alert \(.id) \(.rule)"'
```

Expected: positive totals and no zero-destination lines. Each line is one affected object for the `DO-002` finding.

**Deepen `DO-002` past the bare `policy <uuid> <type>` line (this is the depth bar, not the scanner line).** A zero-destination policy is not "a policy with no destination" — it is a *silent* detector: it fires into the void, and the first human-visible signal becomes the failure itself. Join each flagged policy's `.entities[]` UUID back to `databases.json` / `apps.json` to name the real resource and the exact consequence, and count the blast radius as *enabled zero-destination policies × the resources they nominally cover*:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/${RUN_DATE}/raw"
# For every enabled zero-destination policy, resolve its entities[] to a named DB/app so the
# finding says WHAT silently pages nobody, not just the policy UUID.
jq -r '.[] | select(.enabled and (.emails + (.slack_channels | length)) == 0)
  | "policy \(.uuid) type=\(.type) entities=\((.entities // []) | join(","))"' \
  "${RAW_DIR}/alert-policies.json" | while read -r line; do
  ent="$(printf '%s\n' "$line" | sed -n 's/.*entities=//p')"
  for e in $(printf '%s' "$ent" | tr ',' ' '); do
    name="$(jq -r --arg e "$e" '.[] | select(.id == $e) | "db:\(.name)"' "${RAW_DIR}/databases.json" 2>/dev/null)"
    [ -n "$name" ] || name="$(jq -r --arg e "$e" '.[] | select(.id == $e) | "app:\(.name)"' "${RAW_DIR}/apps.json" 2>/dev/null)"
    echo "${line}  covers=${name:-unresolved-entity:$e}"
  done
done
```

Blast radius, stated concretely: e.g. *"the `v1/dbaas/disk` policy on `db-main` (entities[] → databases.json id) has emails + slack_channels == 0, so when disk crosses the threshold the notification fires into the void and the first human-visible signal is the engine flipping read-only."* Correlation: DO-002 chains with DO-001 (if this is the *only* routing gap anywhere, it is critical — nothing pages) and it is the silent detection leg of the DB-blindspot cascade (a zero-destination disk policy silently shadows DO-040/DO-042). Verification: re-run the section-5 jq — the policy's `(.emails + (.slack_channels | length))` must be `> 0`. Fix: `setup-digitalocean#fix-alert-routing`.

`DO-003` is a judgment step: map each `slack_channels` value and email recipient class to the service and environment it should page. Weigh: a production database paging a general channel, one shared channel absorbing every service, or a channel named for a team that no longer owns the service. Slack incoming webhooks are bound to the channel they were installed in; a payload `channel` field does not re-route them, so the installed channel recorded here is the truth, not any override. Evidence is the channel-to-service table you assemble, quoting channel names only, never URLs.

**Deepen `DO-003` from "shared channel" (an adjective) to a computed MTTA tax.** From the channel → service table (assembled across `alert-policies.json` `slack_channels` and each app's `alerts.json` `slack_channels`), count how many *distinct* services page into one shared channel. If a critical service's real page is one of N routed to the same channel, state N: that count is the MTTA tax during an incident — a responder scanning a channel carrying N services' alerts takes longer to spot the one that matters. "checkout pages into `#alerts` alongside 11 other services" is a blast radius; "shared channel" is not. Correlation: chains with DO-070 (shortest-window flapping into the same channel) into an overall paging-fatigue picture where genuine pages are buried. Verification: recompute the channel → service table — each critical service's paging channel is distinct from bulk/info channels. Fix: `setup-digitalocean#fix-alert-routing`.

`DO-004`: reading destinations proves configuration, not delivery. Look for an observed DO-generated event: an alert visible in the channel history your team confirms, or a documented past incident page. Without one, the routing checks stay `configured` and `DO-004` scores `partial` at best. The controlled delivery proof lives in `setup-digitalocean#prove-alert-delivery`.

`DO-005`: for policies whose surface supports free-form descriptions (DO Monitoring policies do; App Platform alert rules do not), the description should name environment, resource, severity tier, metric, threshold, window, and the datapoints to capture first. For App Platform alerts, record the equivalent capture checklist in the report instead; do not force a spec rollout just to add text.

- ❌ `DO-005 pass: every policy has a description field set.`
- ✅ `DO-005 partial: descriptions exist but none name the environment or what to capture; a responder reading "CPU is running high" learns nothing actionable.`

## 6. Uptime and availability (DO-010 to DO-015)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/${RUN_DATE}/raw"
# DO-010: hostnames served by apps vs hostnames covered by checks.
jq -r '.[] | .domains[]?, (.live_url | sub("^https?://"; "") | select(. != ""))' "${RAW_DIR}/apps.json" | sort -u
jq -r '.[] | select(.enabled) | .target | sub("^https?://"; "")' "${RAW_DIR}/uptime-checks.json" | sort -u
# DO-011 to DO-013: alert rules per check, webhook URLs stripped at capture.
jq -r '.[].id' "${RAW_DIR}/uptime-checks.json" | while read -r check_id; do
  echo "check ${check_id}:"
  doctl monitoring uptime alert list "$check_id" -o json | jq '[.[] | {name, type, threshold, comparison, period,
    emails: ((.notifications.email // []) | length), slack_channels: [.notifications.slack[]?.channel]}]'
done
```

Expected: every hostname in the first list appears in the second (`DO-010`), and each check shows alert types covering `down` (or `down_global`), `latency`, and `ssl_expiry` for HTTPS targets (`DO-011` to `DO-013`). `regions` with a single entry on a check whose users are global is the `DO-014` judgment call; say what evidence would change it (single-region user base, internal-only endpoint).

**Deepen `DO-010` from "hostname X has no uptime check" to the outage that goes undetected.** Name the specific public hostname (from `apps.json` `domains` / `live_url`) that is absent from `uptime-checks.json` targets, then state what its absence removes: with no synthetic check, the *only external backstop* for that hostname is gone — a hung-but-still-503ing app produces no in-band alert either, so detection depends entirely on a customer reporting it. Correlation: DO-010 is the **detection leg of the flagship silent-outage cascade** (see section 16) — the synthetic is the last line of defense once the liveness (DO-030) and restart-alert (DO-023) legs are also missing. Verification: `doctl monitoring uptime list` shows a check whose target matches the hostname, and its `doctl monitoring uptime alert list` carries down/latency/ssl_expiry rules with destinations. Fix: `setup-digitalocean#fix-uptime-coverage` (create a down + latency + ssl-expiry check for the DNS-verified target — non-disruptive write).

### 6.1 Live TLS certificate expiry on a monitored HTTPS hostname (DO-016)

> **Live-verified (read-only).** Run against a live DigitalOcean account: the account/apps APIs answer 200, and the passive TLS handshake below was executed against a real App Platform app hostname and returned a valid certificate expiry date — the openssl mechanic works end to end. The finding reflects the app's real cert state each run.

`DO-013` only checks that an *SSL-EXPIRY alert is configured*; it never reads the actual certificate. DO-016 does the read: a passive TLS handshake against the monitored hostname reads the presented certificate's `notAfter` and flags a host whose certificate expires within `SSL_EXPIRY_DAYS` (section 12 default `21`). This is an imminent hard outage the alert-existence check cannot see — when the cert lapses, every client gets a TLS error. The handshake sends no application data and changes nothing.

```bash
set -eu
HOST="www.example.com"   # each monitored HTTPS hostname from apps.json domains/live_url
SSL_EXPIRY_DAYS="21"     # section 12 default; alert when the cert expires within this many days
# Read the presented cert's expiry (passive, read-only). A 000/handshake error is BLOCKED, not a fail.
END="$(echo | openssl s_client -servername "$HOST" -connect "${HOST}:443" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null)"
if [ -z "$END" ]; then
  echo "BLOCKED ${HOST}: no TLS handshake / no cert presented (connect failure or moved host) — cross-ref DO-010/DO-060, do NOT file a high fail"
else
  echo "${HOST} ${END}"
  # checkend N: exit non-zero => cert expires within N seconds (here SSL_EXPIRY_DAYS days).
  echo | openssl s_client -servername "$HOST" -connect "${HOST}:443" 2>/dev/null \
    | openssl x509 -noout -checkend "$((SSL_EXPIRY_DAYS * 86400))" >/dev/null 2>&1 \
    && echo "  ok: not within ${SSL_EXPIRY_DAYS}d" \
    || echo "  DO-016 fail: expires within ${SSL_EXPIRY_DAYS}d — name the host and the exact enddate above"
fi
```

Blast radius: name the host and the exact `notAfter`; an imminent expiry is a whole-audience TLS outage on that hostname. Correlation: on App Platform managed domains Let's Encrypt auto-renews, so an imminent expiry usually means domain validation broke because the CNAME moved off DO — the same root cause `DO-060` detects; if `DO-013` also fails (no expiry alert), the outage arrives with no warning at all. Blocked path, stated explicitly per the depth doctrine: a connect failure / `000` or a handshake error is a **BLOCKED** result cross-referenced to DO-010 (no check at all) and DO-060 (the hostname may have moved off DO), **never** a fabricated high fail — you cannot compute a cert-expiry blast radius for a cert you could not read. Verification: re-run the `checkend` probe after renewal; it must exit `0` (not within the window). Fix: `setup-digitalocean#fix-uptime-coverage`.

`DO-015`: probe every enabled check target live. The status code is the evidence, so `-f` is dropped:

```bash
set -eu
TARGET_URL="https://www.example.com/"   # each enabled check's exact target
BODY="$(mktemp)"
code="$(curl -sS -o "$BODY" -w '%{http_code}' --max-time 15 "$TARGET_URL")" || code="000"
echo "GET ${TARGET_URL} -> ${code}"
head -c 200 "$BODY"; echo; rm -f "$BODY"
```

Expected: `200`. A `404`, `410`, or an archived-app page means the check is watching a dead target and paging on noise; `000` means DNS or connect failure, which either confirms an outage or means the hostname moved (cross-check section 10 before filing).

## 7. App Platform coverage (DO-020 to DO-033)

Redacted spec summary. This is the only sanctioned way to read a spec in the audit; raw specs carry env values and never touch disk, evidence, or the report:

```bash
set -eu
APP_ID="your-app-id"   # from the inventory
doctl apps get "$APP_ID" -o json | jq '(if type=="array" then .[0] else . end) | {
  name: .spec.name,
  top_level_alert_rules: [.spec.alerts[]?.rule],
  services: [.spec.services[]? | {name, instance_count, instance_size_slug,
    autoscaling: (.autoscaling // null),
    autoscaling_metric: (.autoscaling.metrics // null),
    alert_rules: [.alerts[]?.rule],
    health_check: (.health_check // null),
    liveness_health_check: (.liveness_health_check // null),
    log_destinations: [.log_destinations[]?.name],
    envs: [.envs[]? | {key, type: (.type // "GENERAL")}]}],
  domains: [.spec.domains[]?.domain]}'
```

Expected shape: lifecycle rules (`DEPLOYMENT_FAILED`, `DEPLOYMENT_LIVE`, `DOMAIN_FAILED`, `DOMAIN_LIVE`) at the top level for `DO-020`/`DO-021`, and per-service `CPU_UTILIZATION`, `MEM_UTILIZATION`, `RESTART_COUNT` rules for `DO-022`/`DO-023`. Cross-check against the live alert list (`apps/<id>/alerts.json` from section 4), which is authoritative for what actually fires; the spec is authoritative for what a redeploy would restore.

`DO-024`: request-rate and p95-duration alerts earn credit only when their thresholds trace to an observed baseline (App Platform Insights history, a load-test record, or the team's stated traffic numbers). A guessed threshold is `partial` even when the rule exists, because it pages on normal traffic or never fires.

`DO-025`: record rule names exactly as `list-alerts` returns them. Documented enum names and API-accepted names have diverged before; when the audit sees a rule name the current docs do not list, or the docs list a rule no live app carries, note both spellings so setup automation uses the accepted one. Validation via `doctl apps propose` belongs to the setup lane.

`DO-030`/`DO-031`: a `health_check` object with an `http_path` exists per service, and that exact path answers `200` live with no auth header, no Origin requirement, no session redirect. Probe it with the section 6 status-code block against the app's public URL plus the path. A path that 404s or redirects to a login page would mark a healthy app unhealthy the moment it ships; that is a finding against the configured path, filed with the captured code.

`DO-030` also reads `liveness_health_check` (a distinct block from the readiness `health_check`, GA June 2025). Readiness withholds traffic from an unhealthy instance; liveness *restarts* a hung one. A component with a `health_check` but `liveness_health_check == null` never auto-restarts on a hang — flag it as a DO-030 gap distinct from having no health check at all. Both blocks share the same sub-fields (`http_path`, `port`, `initial_delay_seconds`, `period_seconds`, `timeout_seconds`, `success_threshold`, `failure_threshold`), with liveness defaults `initial_delay_seconds: 5`, `failure_threshold: 18`.

**Deepen the `liveness_health_check == null` gap to what a hang costs on this specific service (not "liveness is missing").** Name the exact component and its `instance_count`: when its process deadlocks, App Platform stops routing to it (readiness) so it shows unhealthy but is **never auto-restarted**; on a single-instance service (join DO-032) that is a hang lasting until a human manually redeploys. Correlation: this is the **center leg of the flagship silent-outage cascade** (DO-032 + DO-023 + DO-010, see section 16). Verification: `doctl apps get <id>` shows the service's `liveness_health_check` non-null; probe its `http_path` live and confirm `200` with no auth/Origin/session (the section-6 status-code block). Fix: `setup-digitalocean#harden-health-checks` (add a `liveness_health_check` stanza — controlled rollout: the spec edit redeploys; roll one app at a time).

`DO-032`: `instance_count` of 1 on a production service is a named fact with `high` impact when the service is critical; pair it with the deployment history (frequent restarts make it worse). **Deepen it past the isolated `instance_count=1` fact — that fact is exactly what a scanner prints; the value is the cascade it triggers.** Blast radius, computed from live data: from `apps.json` / the spec join the single-instance service to `topology.md` dependents — with `instance_count == 1`, any instance restart, node recycle, or failed deploy is a **full outage window** for that service and everything downstream of it (name the dependents). Query the single-instance services with `doctl apps get <id> -o json | jq '.spec.services[] | select((.instance_count // 1) == 1) | .name'`, then cross-reference topology dependents.

> **THE FLAGSHIP CASCADE (assemble it, do not itemize).** For a critical single-instance App Platform service: **DO-032** (`instance_count == 1`) + **DO-030** (a readiness `health_check` but `liveness_health_check == null`) + **DO-023** (no `RESTART_COUNT` alert) + **DO-010** (no uptime check) collapse into one finding: *"`checkout` runs one instance; when its process deadlocks, App Platform withholds traffic via the readiness probe so the instance shows unhealthy but is NEVER auto-restarted (no liveness probe), no restart alert fires (there is no restart to count), and no synthetic uptime check notices the site is down — so the service is fully hung and the first human signal is a customer complaint."* No free scanner assembles this: each leg lives in a different config surface and a different audit category, and it hinges on the App-Platform liveness-vs-readiness split (GA June 2025) and the hard App-Platform-vs-DO-Monitoring boundary. When the cascade holds, **escalate DO-032 to `high`** (a live total-outage risk, not an isolated fact) and emit ONE correlated finding whose evidence names the other four IDs, rather than four independent "X is missing" lines. `DORT-001` (section 16) upgrades this from hypothetical to validated-live whenever an active deployment is observed in a failed phase this run. Fix for the DO-032 leg: `setup-digitalocean#plan-traffic-impacting-changes` (scale to `instance_count >= 2`; plan-only, traffic-impacting, redeploys) — note this only closes the cascade when the other three legs are also fixed. Verification: `doctl apps get <id> -o json | jq '.spec.services[].instance_count'` returns `>= 2` for the critical service. `DO-033`: record whether autoscaling is configured and on what metric. Recommending scaling *thresholds* is out of audit scope, but a component with an `autoscaling` block whose `metrics` object is set (`metrics.cpu.percent`, or the request-based `metrics.requests_per_second.per_instance` / `metrics.request_duration.p95_milliseconds`, GA May 2026) and **no app-spec alert rule on the metric it scales on** is silently scaling and pages nobody when it pins at `max_instance_count`. Read the alert side from the same spec's per-service `alert_rules` (and the live `apps/<id>/alerts.json`), never from `doctl monitoring alert list` — DO Monitoring policies carry no App Platform metric type, so cross-referencing there is a category error. The finding is autoscaling configured with no corresponding App Platform alert (`CPU_UTILIZATION`, `RESTART_COUNT`, or a request-rate rule) that would surface the pin. Enabling scaling changes is traffic-impacting even in the setup lane.

`DO-062` (hygiene, scored in section 10's category): from the redacted env list, any key matching secret shapes stored as `GENERAL`:

```bash
set -eu
APP_ID="your-app-id"   # from the inventory
doctl apps get "$APP_ID" -o json | jq -r '(if type=="array" then .[0] else . end) |
  .spec.services[]? | .name as $svc | .envs[]?
  | select((.type // "GENERAL") == "GENERAL")
  | select(.key | test("(?i)(secret|token|password|api_?key|private|credential)"))
  | "\($svc): \(.key) is GENERAL"'
```

Expected: no output. Each line names a key only; the value is never read.

**Deepen `DO-062` from "key X is GENERAL" to who can read the value.** A `GENERAL` env var's value is returned in **plaintext** by `doctl apps get` / the API to any principal with app-read scope — *including the read-only audit token this run used*. Naming the key (e.g. `DATABASE_URL`, an API secret) makes the exposure concrete: a leaked or over-scoped read token exfiltrates it with one GET. (This is why the audit reads key names and types only — it never captures the value, precisely because the value is retrievable.) Correlation: DO-062 is the **middle leg of the external→data security chain** when the key is a DB credential and `DO-046` shows that DB is publicly reachable: DO-046 (public DB) + DO-062 (its creds plaintext GENERAL) + DO-047 (no logsink so a breach leaves no audit trail) = a direct external→data path with no forensic trail. Verification: `doctl apps get <id>` shows the key with `type: SECRET` and its value field null/encrypted. Fix: `setup-digitalocean#move-secret-env-vars` (change the env type to `SECRET` — controlled rollout: redeploys, and the value must be re-supplied once, since `SECRET` values are write-only).

## 8. Managed databases (DO-040 to DO-048)

DO Monitoring owns database policies; App Platform alerts have no reach here. Group policies by database and metric:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/${RUN_DATE}/raw"
jq -r '.[] | select(.type | startswith("v1/dbaas/")) |
  [(.entities | join(",")), .type, (.value | tostring), .window, .enabled, .description] | @tsv' \
  "${RAW_DIR}/alert-policies.json" | sort
```

Read per production cluster UUID: a CPU-class, a memory-class, and a disk-class policy present (`DO-040` to `DO-042`). Policy `type` strings are account-observable facts; take the accepted spellings from this very output rather than from docs or memory.

**Deepen `DO-040`/`DO-041`/`DO-042` past "policy missing for db X" — the blast radius is the dependent-service set, not "no policy".** For the **disk** policy (DO-042): from `databases.json` name the cluster, its `size` / `num_nodes`, and its `topology.md` dependents; a managed engine that hits disk-full flips to **READ-ONLY**, so every *writing* service errors at once — name them. For **CPU/memory** (DO-040/DO-041): saturation drives query latency straight into the dependent app's p95 — name the dependent services whose latency degrades. Correlation, the **DB-blindspot cascade**: DO-040/041/042 (no resource policy) + DO-045 (`num_nodes == 1`, no standby to absorb load) + DO-044 (no backup, cannot recover) + DO-047 (no logsink, cannot diagnose after the fact) — a database that is unwatched, has no standby, no recovery point, and no queryable logs. Fix: `setup-digitalocean#set-database-alert-policies` (two named tiers — warn at `DB_WARN_PCT`, saturation at `DB_SAT_PCT` — per metric). Verification: `doctl monitoring alert list` shows a `v1/dbaas/<metric>` policy whose `entities[]` include the DB id, for each of cpu/mem/disk, each with `>= 1` destination.

`DO-043`, the noise gate: flag thresholds around 50 percent routed to a paging channel without a written owner-approved reason (managed engines often sit at 50 percent from cache residency alone), and flag duplicate coverage where a generic policy and a named tier watch the same database and metric. A sane starting shape is two named tiers per metric: warning at `DB_WARN_PCT` and saturation at `DB_SAT_PCT` over `DB_WINDOW` (section 12; examples, tune per workload).

- ❌ `DO-043 fail filed because the CPU policy uses 65 percent instead of 80.`
- ✅ `DO-043 fail filed because db-main has both "CPU is running high" at 50 percent and a named warning tier at 80 percent for the same metric, paging twice with no documented reason.`

`DO-044`: `doctl databases backups <id>` lists recent backups with timestamps; an empty list on an engine that supports backups is the finding, with the command output as evidence. **Deepen it from "empty backup list" to a recovery-cost statement.** From `databases.json` name the cluster and its `topology.md` dependents; an empty backup list = **unbounded RPO** — an accidental drop, corruption, or bad migration on the data backing [dependents] is *unrecoverable*, not merely "no backups". Correlation: chains with DO-045 (`num_nodes == 1`) — the single copy of the data has neither a standby nor a recovery point, so one disk failure is permanent data loss. Verification: `doctl databases backups <id>` returns at least one dated entry. Fix: `setup-digitalocean#plan-traffic-impacting-changes` (backup enablement is a cluster setting; record a plan with a named owner — plan-only). `DO-045`: `num_nodes` of 1 on a production cluster means no standby; record it. The fix (adding nodes) is traffic-impacting and lands in the setup skill's plan section, not its write scope. `DO-046`: the firewall listing should name specific droplets, tags, Kubernetes clusters, or app components; a rule open to broad public ranges, or drift against the source list your team expects, is the finding (quote rule types and counts, not addresses, in the Slack-safe report body). **Deepen it from "a rule open to broad ranges" to computed reachability, and read it only through the verified path.** An empty `trusted_sources` list OR a `0.0.0.0/0` rule means the managed DB's public connection endpoint is reachable from the internet: state the DB and that its public host answers. Read it with `doctl databases firewalls list <id>` (the primary read already used in section 4); if a curl fallback is needed it MUST be the **singular** `GET https://api.digitalocean.com/v2/databases/<id>/firewall` and parse `.rules[]` — there is no `/firewall_rules` path (it does not exist, the same plural/singular trap the logsink path documents in section 4), and it stays read-only (GET only). A DB with no restricting rule is publicly *dialable*, not merely "unrestricted". Correlation: the **security flagship (secondary chain)** — DO-046 (publicly reachable DB) + DO-062 (its connection creds plaintext `GENERAL` in an app spec any app-read token can dump) + DO-047 (no logsink so a breach leaves no audit trail) = a direct external→data path. Verification: `doctl databases firewalls list <id>` shows only specific named sources and no `0.0.0.0/0` rule. Fix: `setup-digitalocean#plan-traffic-impacting-changes` (restrict `trusted_sources` to specific droplets/tags/k8s clusters/app components — traffic-impacting; plan-only). `DO-047`: `logsinks.json` empty is a `fail` for production unless a written decision says logs stay in DO; quote the decision when it exists. `DO-048`: list which engine signals your plan exposes (connections, replication or failover state, slow queries) and whether anything watches them; absence with no compensating signal is the finding.

## 9. Log forwarding (DO-050 to DO-052)

From the section 7 redacted summary, `log_destinations` per service answers `DO-050`: empty on production apps means runtime logs live only in DO's short-lived runtime view. **Deepen it from "no log_destinations on app X" to the RCA cost.** Name the app; with no forwarded destination its runtime logs live only in DO's short-lived, non-historically-queryable runtime view, so during and after an incident there is **no queryable log history for this service** — RCA is blind exactly when it is needed. Correlation: chains with DO-047 (DB logsink absent) — if both the app and its backing DB are unforwarded, the *entire request path* is un-investigable post-incident. Verification: `doctl apps get <id>` shows the service's `log_destinations` non-empty and pointing at the chosen backend. Fix: `setup-digitalocean#enable-app-log-forwarding` (add a `log_destination` to the chosen backend — controlled rollout: spec edit redeploys). `DO-051` is a judgment step over the team's own answers: which backend, what retention, what redaction before shipping, what index or stream naming, who owns cost and access. A backend with none of those answered is `partial`, not `pass`.

`DO-052`: App Platform log destinations and managed-database logsinks are different surfaces with different supported backend lists (historically: Papertrail, Datadog, Logtail, and OpenSearch for apps; rsyslog, Elasticsearch, and OpenSearch for database logsinks). The lists change; verify against current DigitalOcean docs at run time and record what your account actually accepts. Promising one universal log path without checking both lists is the failure this check exists to catch.

## 10. Ownership and hygiene (DO-060 to DO-062)

`DO-060`: for every monitored hostname, confirm DNS still points at DigitalOcean before judging anything else about it. Both resolver forms shown; use whichever your system has:

```bash
set -eu
HOSTNAME_TO_CHECK="www.example.com"   # each monitored hostname from the inventory
dig +short "$HOSTNAME_TO_CHECK" CNAME 2>/dev/null || host -t CNAME "$HOSTNAME_TO_CHECK" || true
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "https://${HOSTNAME_TO_CHECK}/")" || code="000"
echo "GET https://${HOSTNAME_TO_CHECK}/ -> ${code}"
```

App Platform custom domains normally CNAME to an `ondigitalocean.app` hostname. A CNAME into another platform, or a body served by something that is clearly not the DO app, means the service moved: its DO checks and alerts are watching a ghost (`DO-060`), and any "app down" conclusion about it is wrong until ownership is settled. `DO-061`: apps whose active deployment is old and whose domains have moved, or apps in an archived state, should not appear in checks or policies; enumerate the stale watchers. `DO-062` runs in section 7.

## 11. Per-service coverage rows

Assemble one row per critical service from the raw captures; re-fetch any cell you are about to fail:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/${RUN_DATE}/raw"
SERVICE_NAME="checkout"   # canonical name from topology.md
APP_ID="$(jq -r --arg s "$SERVICE_NAME" '.[] | select(.name == $s) | .id' "${RAW_DIR}/apps.json")"
[ -n "$APP_ID" ] || { echo "no app matches ${SERVICE_NAME}; record the mapping gap"; exit 0; }
echo "uptime: $(jq -r --arg s "$SERVICE_NAME" '[.[] | select(.enabled and (.target | contains($s)))] | length' "${RAW_DIR}/uptime-checks.json") checks matched by name (verify by target hostname)"
jq -r '[.[] | select(.disabled | not) | .rule] | sort | join(",")' "${RAW_DIR}/apps/${APP_ID}/alerts.json"
```

The matrix cell vocabulary is `pass`, `partial`, `fail`, `blocked`, `not-in-scope`. Databases map to services through topology.md dependencies when present; otherwise record the database under the service that names it and say the mapping was inferred.

## 12. Starting alert set (tune per workload)

Conservative starting defaults, not prescriptions. Adjust thresholds and windows after observing each workload's baselines; request-rate and p95 alerts should not exist at all until a baseline does.

```bash
UPTIME_DOWN_WINDOW="2m"       # example, tune to your traffic
UPTIME_LATENCY_MS="1000"      # example, tune after observing normal latency
UPTIME_LATENCY_WINDOW="10m"   # example
SSL_EXPIRY_DAYS="21"          # example, alert when the cert expires within this many days
APP_CPU_PCT="80"              # example, tune per service
APP_MEM_PCT="80"              # example, tune per service
APP_RESTART_COUNT="1"         # example
APP_WINDOW="5m"               # example
DB_WARN_PCT="80"              # example warning tier, tune per engine and workload
DB_SAT_PCT="99"               # example saturation tier
DB_WINDOW="5m"                # example
```

| Surface | Starting point | Avoid |
| --- | --- | --- |
| Uptime | down for `UPTIME_DOWN_WINDOW`; latency above `UPTIME_LATENCY_MS` ms for `UPTIME_LATENCY_WINDOW`; SSL expiry under `SSL_EXPIRY_DAYS` days; multiple regions where relevant | checks against unverified or moved targets |
| App Platform | deploy failed and live; domain failed and live; CPU above `APP_CPU_PCT` and memory above `APP_MEM_PCT` for `APP_WINDOW`; restarts above `APP_RESTART_COUNT` | request or p95 rules with guessed thresholds |
| Managed databases | named warning tier at `DB_WARN_PCT` and named saturation tier at `DB_SAT_PCT` per metric over `DB_WINDOW` | 50-percent pages without an owner-approved reason; generic duplicates beside named tiers |

## 13. Large-path worklist: apps in batches

Runnable commands for the large path named in [SKILL.md's Estate sizing](../SKILL.md#estate-sizing) and worked through in [Large-path worklist: apps in batches](../SKILL.md#large-path-worklist-apps-in-batches). Every block here is stateless and redeclares its own inputs, per the stateless-command-block rule; nothing here depends on a prior block having run in the same shell.

### 13.1 Find a resumable run, or start a new one

Scan for an interrupted run before minting a new `RUN_ID`. Never start fresh when a worklist with pending rows already exists; that throws away completed batches.

```bash
set -eu
AUDIT_ROOT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean"

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

### 13.2 Mint the run ID

Only after 13.1 finds nothing resumable. The run ID is a UTC second-precision timestamp, generated once and reused by every later block in the same run; it is what keeps the run directory stable across a midnight UTC rollover mid-batch.

```bash
set -eu
AUDIT_ROOT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"   # first-seen timestamp of this run; stable for its lifetime
RUN_DIR="${AUDIT_ROOT}/runs/${RUN_ID}"
mkdir -p "${RUN_DIR}"
echo "${RUN_ID}" > "${RUN_DIR}/run-id"
echo "run: ${RUN_ID}"
```

### 13.3 Build or resume the worklist

One row per app, tab-separated: `kind` (always `app`), `app_id`, `status` (`pending` or `done`). Never rebuild a worklist that already exists in the resumed run directory; that forgets progress.

```bash
set -eu
RUN_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/runs/20260717T140500Z"   # example; resolved run directory from 13.1 or 13.2

WORKLIST="${RUN_DIR}/worklist.tsv"
if [ -f "${WORKLIST}" ]; then
  done=$(awk -F'\t' '$3 == "done"' "${WORKLIST}" | wc -l | tr -d ' ')
  pending=$(awk -F'\t' '$3 == "pending"' "${WORKLIST}" | wc -l | tr -d ' ')
  echo "resuming existing worklist: done=${done} pending=${pending}"
else
  : > "${WORKLIST}"
  doctl apps list -o json | jq -r '.[].id' \
    | while read -r app_id; do printf 'app\t%s\tpending\n' "${app_id}" >> "${WORKLIST}"; done
  total=$(wc -l < "${WORKLIST}" | tr -d ' ')
  echo "built worklist: ${total} rows, all pending"
fi
```

### 13.4 Lock the worklist before claiming a batch

Two invocations of this skill running at once would otherwise race on the same worklist file and double-claim rows. A lock older than `LOCK_STALE_MINUTES` is treated as abandoned; processes die, laptops sleep, sessions get killed, so reclaiming a stale lock is a normal path, not an error.

```bash
set -eu
RUN_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/runs/20260717T140500Z"   # example; resolved run directory
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

### 13.5 Claim a batch, pull its apps, mark done, release the lock

Claim happens while the lock (13.4) is held; release happens right after the batch's rows are marked, so another process can claim the next batch. For each app ID in the claimed batch, run the section 4 per-app inventory pull (`doctl apps list-alerts`, `doctl apps list-deployments`) plus the section 5, 7, and 10 checks that key off an app ID, writing raw captures under `${RUN_DIR}/raw/apps/<app_id>/` and appending results to `${RUN_DIR}/findings-partial.jsonl`. A row is marked `done` only after that app's pulls succeed without error, so a batch that fails partway resumes at the app that failed rather than replaying the whole batch.

```bash
set -eu
RUN_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/runs/20260717T140500Z"   # example; resolved run directory
WORKLIST="${RUN_DIR}/worklist.tsv"
LOCK="${RUN_DIR}/worklist.lock"
BATCH_SIZE="10"   # example, tune it; matches the value declared in SKILL.md's Estate sizing

BATCH_FILE="${RUN_DIR}/batch-$(date -u +%s).tsv"
awk -F'\t' '$3 == "pending"' "${WORKLIST}" | head -n "${BATCH_SIZE}" > "${BATCH_FILE}"
count=$(wc -l < "${BATCH_FILE}" | tr -d ' ')
echo "claimed batch: ${count} rows -> ${BATCH_FILE}"

# ... for each app_id in "${BATCH_FILE}", run the section 4/5/7/10 pulls for that
# app, writing raw captures under "${RUN_DIR}/raw/apps/<app_id>/" and appending
# results to "${RUN_DIR}/findings-partial.jsonl". Only after every row's pulls
# succeed:

while IFS=$'\t' read -r kind app_id _status; do
  awk -F'\t' -v k="${kind}" -v n="${app_id}" 'BEGIN{OFS="\t"} $1==k && $2==n {$3="done"} {print}' \
    "${WORKLIST}" > "${WORKLIST}.tmp" && mv "${WORKLIST}.tmp" "${WORKLIST}"
done < "${BATCH_FILE}"

rm -f "${LOCK}"   # release once this batch (not the whole run) completes
done=$(awk -F'\t' '$3 == "done"' "${WORKLIST}" | wc -l | tr -d ' ')
pending=$(awk -F'\t' '$3 == "pending"' "${WORKLIST}" | wc -l | tr -d ' ')
echo "batch marked done: done=${done} pending=${pending}"
```

Expected: `pending` drops by the batch size (or less, on the final partial batch) after each pass through 13.4 and 13.5. Repeat 13.4 and 13.5 until `pending` reaches 0.

### 13.6 Assert the worklist is complete before writing the report

Phase 10 writes `findings.json` and `report.md` only when this assertion passes. A run stopped mid-batch leaves its worklist and partial findings in the run directory as the resume point; it never overwrites the previous complete report.

```bash
set -eu
RUN_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/runs/20260717T140500Z"   # example; resolved run directory
WORKLIST="${RUN_DIR}/worklist.tsv"

pending=$(awk -F'\t' '$3 == "pending"' "${WORKLIST}" | wc -l | tr -d ' ')
echo "pending=${pending}"
[ "${pending}" -eq 0 ] || { echo "worklist not complete; repeat 13.4 and 13.5 before writing findings.json or report.md"; exit 1; }
echo "worklist complete: safe to proceed to Phase 10 (score, write, brief)"
```

Rules:

- The lock covers one batch claim, not the whole run: acquire it right before reading pending rows, release it right after marking them done.
- A lock file holds exactly two tab-separated fields: the PID that holds it, and its UTC epoch start timestamp. Nothing else.
- `findings.json` and `report.md` are written only once `pending` is 0 (13.6). Never assemble the final report from a worklist with pending rows.
- Delete the run directory after `findings.json` and `report.md` are written; it is working state, not a report. Deleting it early forces a fresh start on the next invocation.

## 14. Commands this audit must never run

Any of these appearing in an audit transcript is a lane violation, whatever the justification:

- `doctl apps update`, `doctl apps create`, `doctl apps delete`, `doctl apps create-deployment`, `doctl apps propose`, `doctl apps update-alert-destinations`
- `doctl monitoring uptime create|update|delete`, `doctl monitoring uptime alert create|update|delete`
- `doctl monitoring alert create|update|delete`
- `doctl databases create|delete|resize|migrate`, `doctl databases firewalls append|replace|remove`, `doctl databases logsink create|update|delete`, `doctl databases user create`
- Any `curl` POST, PUT, PATCH, or DELETE against `api.digitalocean.com`
- Any POST to any webhook, including a smoke test; the toolkit Slack brief in the skill's final phase is the single exception and posts only to the brief webhook from `slack.webhook_env`

## 15. Alert hygiene: dwell window, mute state, and duplicate coverage (DO-070 to DO-072)

Serves Phase 3's [Alert hygiene](../SKILL.md#alert-hygiene-do-070-to-do-072) subsection. Every block is read-only and reuses the redacted `alert-policies.json` written by the section 4 inventory; nothing here calls a new endpoint. Honest ceiling, repeated because it belongs in the evidence: DO Monitoring has no grouping, deduplication, inhibition, resolve-hold, timed silence, or maintenance window, so there is no config to read for any of them and this section never scores their absence as a fail. The `window` enum is fixed at `5m|10m|30m|1h`; the only field a resolve-notification churn signal can key off is that window (there is no per-policy resolve toggle in `GET /v2/monitoring/alerts`). A `401`/`403` while refreshing the policy list blocks these checks; it is never a clean result.

### 15.1 Dwell window pinned at the shortest option (DO-070)

The duration `window` is DO's only built-in spike/flap damper: the metric must stay across the threshold for the whole window before the policy fires. The API and `doctl` default is `5m`, the shortest and noisiest choice.

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/${RUN_DATE}/raw"
SHORT_WINDOW="5m"   # example, tune it: DO's window enum is fixed at 5m|10m|30m|1h; 5m is the shortest, noisiest option
# DO-070: enabled policies pinned at the shortest dwell window, DO's only spike/flap damper.
jq -r --arg w "$SHORT_WINDOW" '.[] | select(.enabled and .window == $w)
  | "policy \(.uuid) type=\(.type) window=\(.window) compare=\(.compare) value=\(.value)"' \
  "${RAW_DIR}/alert-policies.json"
```

Expected: no output on a tuned estate. Each line is one affected policy for the DO-070 finding. The same short window is the closest read-only predictor of resolve-notification churn (DO's fire+clear pair is fixed with no off switch), so a policy flagged here on a boundary-hugging threshold is doubly noisy; note that in the finding rather than looking for a resolve field that does not exist.

### 15.2 Permanently-disabled policies (DO-071)

DO's only mute is all-or-nothing: fully enabled or fully disabled, with no timed silence, snooze, or maintenance window. A disabled policy is a coverage gap until re-enabled.

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/${RUN_DATE}/raw"
# DO-071: disabled policies. The list API carries no created/updated timestamp, so "long-lived"
# cannot be proven from this read; flag every disabled policy for a mute-state review rather than
# implying it is fresh or stale.
jq -r '.[] | select(.enabled == false)
  | "disabled policy \(.uuid) type=\(.type) entities=\((.entities // []) | length) tags=\((.tags // []) | join(","))"' \
  "${RAW_DIR}/alert-policies.json"
```

Expected: no output, or a short list a responder can confirm is intentional. Because there is no timestamp and no timed-mute state to inspect, a disabled policy cannot be aged from this API; the finding says so and asks the owner whether the mute is deliberate, never asserts it is forgotten.

### 15.3 Near-identical single-entity policies (DO-072)

Tag scoping (`tags[]`) is DO's closest analog to grouping: one tag-scoped policy covers a tagged fleet as a single rule instead of N per-entity copies. It does not dedupe the resulting notifications, but it collapses duplicate rules.

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/${RUN_DATE}/raw"
# DO-072: enabled policies sharing type/compare/value/window, each scoped to at most one entity and
# carrying no tags, are duplicate coverage one tag-scoped policy would collapse.
jq -r '
  [ .[] | select(.enabled)
    | { type, compare, value: (.value | tostring), window,
        entity_count: ((.entities // []) | length),
        tag_count: ((.tags // []) | length), uuid } ]
  | group_by([.type, .compare, .value, .window])
  | .[] | select(length > 1)
  | select(all(.[]; .tag_count == 0 and .entity_count <= 1))
  | "\(length) near-identical single-entity policies: \(.[0].type) \(.[0].compare) \(.[0].value) over \(.[0].window) -> \([.[].uuid] | join(","))"
' "${RAW_DIR}/alert-policies.json"
```

Expected: no output when the estate uses tag-scoped policies. Each line names one collapsible group with its policy UUIDs as the affected objects. This is the fleet-shape duplicate only; threshold-value duplicates and 50-percent-style pages on the same entity and metric stay with DO-043 in the Managed databases category, so the two checks never double-count the same policy.

## 16. Live-runtime snapshot (DORT — evidence, not scored)

> **Verify-pending.** These two checks are drafted against DigitalOcean's documented App Platform deployment-phase API and adversarially reviewed, but have **not** been run against a live DO tenant — status is unproven until a first live run with a read-only `DIGITALOCEAN_ACCESS_TOKEN` against an account carrying App Platform apps. The reads below are ordinary `doctl apps list`/`get`/`list-deployments` calls (read-only); treat the observations as unconfirmed until that first live run.

This is the DigitalOcean analog of the kubernetes `K8SRT-` lane: a **parallel non-scored** section per the [findings schema](../../report-standard/findings-schema.md). Its IDs carry `area: live-runtime`, always severity `info` and `points_recoverable: 0`, and **never** appear in `score.categories` or `score.excluded`. It adds live blast-radius evidence without perturbing any scored weight. Snapshot facts are tagged `[live@<ISO8601>]`. The audit already pulls deployment history into inventory (section 4); this section surfaces a *currently* failed or wedged deployment as evidence, turning the DO-032 cascade from hypothetical into validated-live when it is happening this run.

| ID | Signal | Emit only when this exact field is observed |
| --- | --- | --- |
| DORT-001 | An app's active deployment is in a failed / non-live phase now | `active_deployment.phase` is `ERROR` or `CANCELED` (the app is serving old code or is down NOW) |
| DORT-002 | A deployment is wedged in an in-progress phase | `in_progress_deployment.id != null` with phase `BUILDING`/`DEPLOYING`/`PENDING_BUILD` (a rollout that never went live) |

```bash
set -eu
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# DORT-001: active deployment phase per app. ERROR/CANCELED = the app is serving old code or is down now.
doctl apps list -o json | jq -r '.[]
  | "\(.spec.name)\tactive_phase=\(.active_deployment.phase // "none")\tin_progress=\(.in_progress_deployment.id // "-")"'
# For any app whose active_phase is ERROR/CANCELED, pull its recent deployment history for the cause:
APP_ID="your-app-id"   # an app flagged above
doctl apps list-deployments "$APP_ID" -o json | jq -r '.[0:3][]
  | "\(.id)\tphase=\(.phase)\tcause=\(.cause)\tupdated=\(.updated_at)"'

# DORT-002: apps with a wedged in-progress deployment (never went live).
doctl apps list -o json | jq -r '.[] | select(.in_progress_deployment.id != null)
  | "\(.spec.name)\tin_progress=\(.in_progress_deployment.id)"'
doctl apps get "$APP_ID" -o json | jq '(if type=="array" then .[0] else . end)
  | {name: .spec.name, in_progress_phase: .in_progress_deployment.phase, in_progress_cause: .in_progress_deployment.cause}'
echo "snapshot taken [live@${NOW}]"
```

This section has no pass/fail. A probe that returns nothing, times out, or is `401`/`403`-blocked is recorded `skipped, reason: <exact error>` — verdict unknown, never healthy; never fabricate a phase you did not read. What the observations feed:

- **DORT-001** names any app whose `active_deployment.phase` is `ERROR`/`CANCELED` — the app is serving old code or is down NOW — rather than only checking that a `DEPLOYMENT_FAILED` alert rule exists (DO-020). When it coincides with **DO-032** (single instance), it upgrades that finding from hypothetical to **validated-live**: the outage the flagship cascade predicts is happening this run. Feeds DO-020 (was the `DEPLOYMENT_FAILED` alert supposed to fire?) and DO-032/DO-030.
- **DORT-002** surfaces an app stuck in `BUILDING`/`DEPLOYING`/`PENDING_BUILD` — a wedged rollout that never went live; on a single-instance app this can mean the new instance never comes up while the old one is torn down. Corroborates DO-020 and the DO-032 cascade; a wedged rollout beside a missing `DEPLOYMENT_FAILED` alert is a real, currently-live blind spot.

Remediation for both is `setup-digitalocean#add-app-platform-alerts` (add the App Platform lifecycle alert so the next failed/wedged deployment pages a human); the deployment itself is fixed by the app owner, not this toolkit.
