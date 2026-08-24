# Verification chain: commands, contracts, and a worked example

Lookup material for [SKILL.md](../SKILL.md). Every block declares its placeholder variables at the top, resolved from `~/.scoutflo/toolkit.yaml` per the [config access rules](../../../docs/skill-authoring-conventions.md#config-access). Run blocks as pasted; nothing here is pseudo-code.

## 0. Auth header convention for every Prometheus and Alertmanager call

`prometheus.token_env` is optional: some deployments sit behind an open network boundary and need no bearer token at all, others require one for both Prometheus and Alertmanager (the doctor gate resolves one shared token for both, since they are typically fronted by the same auth layer). Every command in this reference that calls `PROM_URL` or `AM_URL` follows the same rule `doctor.sh`'s `http_get` helper uses: attach `Authorization: Bearer` only when the token is actually present and non-empty, never send the header empty.

```bash
set -eu
PROM_TOKEN="${PROM_TOKEN:-}"   # value of the var named by prometheus.token_env, if set; presence-checked, never printed, never logged
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"   # harmless placeholder header; never an empty bearer
```

Every block below re-declares `PROM_TOKEN` and `AUTH` this way (stateless blocks cannot share a prior block's variables) and passes `-H "$AUTH"` on every `curl` to `PROM_URL` or `AM_URL`.

- ❌ `curl -fsS --max-time 10 "${PROM_URL}/api/v1/rules"` against a token-gated Prometheus reads back `401`, gets logged as "no rules loaded", and the audit reports the paging path as broken.
- ✅ `curl -fsS --max-time 10 -H "$AUTH" "${PROM_URL}/api/v1/rules"` where `AUTH` resolves to the bearer header only when `PROM_TOKEN` is set; the same `401` on an authenticated deployment now means the token itself is missing or wrong (doctor gate should have caught it first), not that rules failed to load.

A `401` or `403` from any of the calls below is an auth-scope finding, not a routing or reachability finding: name it as such in evidence and stop trusting anything downstream of that call until the token is fixed. See section 2 for the reachability read that applies this distinction first.

## 1. Alertmanager reachability fallback

Some clusters expose the Alertmanager UI/API through an ingress; others keep it cluster-internal. Try the ingress first. If it is not reachable, port-forward instead of widening any permission or exposing the service publicly:

```bash
set -eu
KUBE_CONTEXT="your-kube-context"     # kubernetes.context
MON_NS="monitoring"                  # kubernetes.monitoring_namespace
AM_LOCAL_PORT="9093"                 # local port for the forward, example, tune to your environment
PROM_TOKEN="${PROM_TOKEN:-}"         # value of the var named by prometheus.token_env, if set
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"

kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" port-forward svc/alertmanager-operated "${AM_LOCAL_PORT}:9093" >/tmp/alertmanager-port-forward.log 2>&1 &
AM_PF_PID=$!
sleep 2
curl -fsS --max-time 10 -H "$AUTH" "http://127.0.0.1:${AM_LOCAL_PORT}/api/v2/status" \
  | jq -e -r '.cluster.status == "ready"' \
  && echo "alertmanager reachable via port-forward"
kill "$AM_PF_PID"
```

Expect: `true` printed by the `jq -e` assertion and the confirmation line. `jq -e` exits nonzero (and the `&&` short-circuits) when `.cluster.status` is anything other than `ready`, which is itself the failure signal, not a status a human has to eyeball. Note in evidence whether the run used the ingress URL or the port-forward path; both are read-only, but the choice explains why a later command targets `127.0.0.1` instead of the configured host. A `401`/`403` here means the token attached in `$AUTH` is wrong or missing scope, even though the network path itself is fine; do not read it as "port-forward failed".

## 2. Reachability (ALR-010)

```bash
set -eu
PROM_URL="https://prometheus.example.com"        # prometheus.url
AM_URL="https://alertmanager.example.com"         # prometheus.alertmanager_url
PROM_TOKEN="${PROM_TOKEN:-}"                      # value of the var named by prometheus.token_env, if set
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"

dig +short "$(printf '%s' "$PROM_URL" | sed -E 's#^https?://([^/]+).*#\1#')" || \
  nslookup "$(printf '%s' "$PROM_URL" | sed -E 's#^https?://([^/]+).*#\1#')"

PROM_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 -H "$AUTH" "${PROM_URL}/api/v1/status/buildinfo")
AM_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 -H "$AUTH" "${AM_URL}/api/v2/status")
echo "prometheus: ${PROM_CODE}"
echo "alertmanager: ${AM_CODE}"
[ "$PROM_CODE" = "200" ] && [ "$AM_CODE" = "200" ] && echo "ALR-010: pass"
```

Expect: a resolvable A/CNAME record, and both `PROM_CODE` and `AM_CODE` equal to `200` (the final assertion prints `ALR-010: pass` only then; anything else means the check failed and the reader must classify why, per this table:

| Observed code | Diagnosis | Not this |
| --- | --- | --- |
| `000` / connect refused / DNS failure | Reachability problem: DNS, ingress, or network path (ALR-010, high) | Not a routing or auth problem; nothing downstream can be trusted until this is fixed |
| `401` | Auth problem: the token attached in `$AUTH` is missing, wrong, or expired. Record it as an auth-scope finding, not as "unreachable" or "routing broken" | Never re-run the doctor token check as the fix; this is the live call itself failing auth |
| `403` | Auth problem: the token is valid but lacks the scope this endpoint needs | Never downgrade to "endpoint not exposed"; the endpoint answered |
| `200` | Reachable and authenticated (or auth not required); proceed to the next phase | — |

A `401`/`403` on a deployment where the doctor gate reported the token as present means the token's scope, not its existence, is the problem; say so explicitly in the finding text.

## 3. Rule presence (ALR-001)

Two-step discipline: try the names you expect, then fall back to live discovery by label. Never assume a name from a manifest survived renames.

Both `kubectl` calls below target the Prometheus Operator's `PrometheusRule` CRD; a cluster running Google Managed Prometheus (GMP) instead has no such CRD at all (it uses `rules.monitoring.googleapis.com`, `clusterrules`, `globalrules`), and `kubectl get prometheusrule` fails outright with "the server doesn't have a resource type" rather than returning zero rules. Both calls below redirect that error and degrade to the live-discovery fallback instead of crashing; the confirmation check right after this block (`/api/v1/rules`) works identically regardless of which CRD family, or none, backs the rules, so it stays the real source of truth either way.

```bash
set -eu
KUBE_CONTEXT="your-kube-context"     # kubernetes.context
MON_NS="monitoring"                  # kubernetes.monitoring_namespace
EXPECTED_RULE="your-rule-name"       # the name you expect, from your manifests or prior run

# Step 1: try the expected name.
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get prometheusrule "$EXPECTED_RULE" -o yaml 2>/dev/null \
  || echo "expected rule name not found (or this cluster has no PrometheusRule CRD at all - GMP-style deployments use rules.monitoring.googleapis.com instead); falling back to live inventory"

# Step 2: list the live inventory and select by owning labels, not by name guesswork.
kubectl --context "$KUBE_CONTEXT" get prometheusrule -A -o json 2>/dev/null \
  | jq -r '.items[]? | "\(.metadata.namespace)/\(.metadata.name)"' \
  || echo "no PrometheusRule CRD in this cluster; confirm rule presence via the live /api/v1/rules check below instead"
```

Then confirm the selected rule is actually loaded into Prometheus, not just present as a CRD:

```bash
set -eu
PROM_URL="https://prometheus.example.com"   # prometheus.url
RULE_GROUP="your-rule-group"                # spec.groups[].name from the selected PrometheusRule
PROM_TOKEN="${PROM_TOKEN:-}"                # value of the var named by prometheus.token_env, if set
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"

CODE=$(curl -s -o /tmp/alr-rules.json -w '%{http_code}' --max-time 10 -H "$AUTH" "${PROM_URL}/api/v1/rules")
echo "rules API: ${CODE}"
if [ "$CODE" = "401" ] || [ "$CODE" = "403" ]; then
  echo "auth problem, not a missing-rules problem: fix the token before judging ALR-001"
elif [ "$CODE" = "200" ]; then
  jq --arg g "$RULE_GROUP" -e '.data.groups[] | select(.name == $g) | (.rules | length) > 0' /tmp/alr-rules.json \
    && jq --arg g "$RULE_GROUP" -r '.data.groups[] | select(.name == $g) | {name, rules: [.rules[].name]}' /tmp/alr-rules.json
else
  echo "unexpected status ${CODE}: not an auth code and not 200; treat as a reachability or API-shape problem"
fi
```

Expect: `CODE` is `200` and the `jq -e` assertion prints `true`, followed by the group and its rule names. An empty result (assertion prints `false`, exits nonzero) with the CRD present in section 3's step 2 is usually a `ruleSelector` label mismatch between the CRD and the Prometheus or PrometheusOperator resource selector; that mismatch is the ALR-001 finding, not "Prometheus is broken." A `401`/`403` here is never read as "rules failed to load": it is an auth-scope finding, and everything downstream in this phase is blocked, not failed, until the token works.

## 4. Config drift across three layers (ALR-002, ALR-003)

Read the declared object, the rendered file, and the running config, in that order. Redact before you look at, log, or store any of them (section 5).

```bash
set -eu
KUBE_CONTEXT="your-kube-context"     # kubernetes.context
MON_NS="monitoring"                  # kubernetes.monitoring_namespace
AM_CONFIG_NAME="your-alertmanager-config"   # AlertmanagerConfig object name, or the base Secret name
AM_POD="alertmanager-0"              # a running Alertmanager pod name from `kubectl get pods`
AM_URL="https://alertmanager.example.com"   # prometheus.alertmanager_url
PROM_TOKEN="${PROM_TOKEN:-}"         # value of the var named by prometheus.token_env, if set
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"

# Layer 1: the declared object.
# NEVER pull .webhookConfigs[].url (or any *_url) into output — a webhook URL is
# credential-bearing (Slack/PagerDuty/generic tokens are embedded in the path), and
# once it lands in a field not named *url/key/token the section-5 redaction filter
# can no longer catch it. Emit only non-secret routing identifiers: slack channel
# names, email targets, and the PRESENCE/COUNT of webhook and PagerDuty targets.
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get alertmanagerconfig "$AM_CONFIG_NAME" -o json \
  | jq '.spec.receivers[] | {name,
      channels: [.slackConfigs[]?.channel, .emailConfigs[]?.to] | flatten | map(select(. != null)),
      webhook_targets: ([.webhookConfigs[]?] | length),
      pagerduty_targets: ([.pagerdutyConfigs[]?] | length),
      opsgenie_targets: ([.opsgenieConfigs[]?] | length)}'

# Layer 2: the rendered file the running process actually loaded.
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" exec "$AM_POD" -c alertmanager -- \
  cat /etc/alertmanager/config_out/alertmanager.env.yaml

# Layer 3: the running config as Alertmanager itself reports it.
AM_CODE=$(curl -s -o /tmp/alr-am-status.json -w '%{http_code}' --max-time 10 -H "$AUTH" "${AM_URL}/api/v2/status")
echo "alertmanager status: ${AM_CODE}"
if [ "$AM_CODE" = "401" ] || [ "$AM_CODE" = "403" ]; then
  echo "auth problem reading layer 3; layers 1 and 2 still stand, but the three-layer comparison is blocked, not a drift finding"
elif [ "$AM_CODE" = "200" ]; then
  jq -r '.config.original' /tmp/alr-am-status.json
else
  echo "unexpected status ${AM_CODE}: reachability or API-shape problem, not drift"
fi
```

If `kubectl exec` is denied in your cluster, use the port-forward path in section 1 for layer 3 and rely on layers 1 and 2; note the exec restriction in evidence and mark any check that strictly needs in-pod access `blocked` with that reason, never silently skipped.

Two rules keep the comparison honest:

- Operator-managed installs rewrite receiver names to `<namespace>/<config-name>/<receiver>` and add a namespace matcher to routes generated from an `AlertmanagerConfig` CRD. That transformation is expected; do not flag it as drift.
- Reload proof, not apply proof:

```bash
set -eu
PROM_URL="https://prometheus.example.com"   # prometheus.url
AM_URL="https://alertmanager.example.com"   # prometheus.alertmanager_url
PROM_TOKEN="${PROM_TOKEN:-}"                # value of the var named by prometheus.token_env, if set
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"

curl -fsS --max-time 10 -H "$AUTH" "${AM_URL}/api/v2/status" | jq -r '.cluster.status, .versionInfo.version'
curl -fsS --max-time 10 -H "$AUTH" "${PROM_URL}/api/v1/query?query=alertmanager_config_last_reload_successful" \
  | jq -r '.data.result[] | "\(.metric.instance // .metric.pod // "unknown"): \(.value[1])"'
curl -fsS --max-time 10 -H "$AUTH" "${PROM_URL}/api/v1/query?query=alertmanager_config_last_reload_success_timestamp_seconds" \
  | jq -r '.data.result[] | "\(.metric.instance // .metric.pod // "unknown"): \(.value[1] | tonumber | strftime("%Y-%m-%dT%H:%M:%SZ"))"'
```

A `1` on the first query and a recent timestamp on the second mean the reload succeeded and when. A `kubectl apply` that returns success with a `0` reload value or a stale timestamp means the running process still serves the old config (ALR-003, critical): the apply changed the object, not the behavior. If either `curl` call above returns `401`/`403` instead of a JSON body, that is a token problem on the query API, not evidence the reload failed; fix the token and re-run before drawing any ALR-003 conclusion.

## 5. Redaction filter

Apply this to every config blob before it enters terminal output, `findings.json`, or `report.md`:

```bash
set -eu
# Redacts values of keys ending in url, key, token, secret, password (case-insensitive);
# keeps receiver names, channel names, and structure intact.
jq 'walk(
  if type == "object" then
    with_entries(if (.key | ascii_downcase | test("(url|key|token|secret|password)$")) then .value = "[redacted]" else . end)
  else . end
)'
```

Receiver names and channel names are safe to keep; they are what you compare across layers. Webhook URLs, API keys, and any credential-bearing field are never safe, even truncated.

## 6. Active alerts and their resolved receiver (ALR-004)

```bash
set -eu
AM_URL="https://alertmanager.example.com"   # prometheus.alertmanager_url
PROM_URL="https://prometheus.example.com"   # prometheus.url
PROM_TOKEN="${PROM_TOKEN:-}"                # value of the var named by prometheus.token_env, if set
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"

curl -fsS --max-time 10 -H "$AUTH" "${AM_URL}/api/v2/alerts" \
  | jq -r '.[] | "\(.labels.alertname) ns=\(.labels.namespace // "-") severity=\(.labels.severity // "-") receivers=\([.receivers[]?.name] | join(","))"'

curl -fsS --max-time 10 -H "$AUTH" "${PROM_URL}/api/v1/query?query=count%20by%20(namespace)%20(ALERTS%7Balertstate%3D%22firing%22%7D)" \
  | jq -r '.data.result[] | "\(.metric.namespace): \(.value[1])"'
```

A `401`/`403` from either call means the active-alerts read is auth-blocked, not that no alerts are firing; report it as a blocked check, never as zero active alerts.

The `receivers` field on each `api/v2/alerts` entry is Alertmanager's own routing decision: the strongest proof of where an alert actually went, because it reflects what the route tree did, not what the route tree was written to do.

## 7. Route matcher coverage (ALR-004, ALR-011)

Compare the route tree's matchers (from the rendered config in section 4) against the firing-namespace distribution (section 6) and against `topology.md` when it exists:

```bash
set -eu
AM_URL="https://alertmanager.example.com"   # prometheus.alertmanager_url
LONG_FIRING_HOURS="24"   # example, tune to your environment: how long is "too long" for a firing alert in your stack
PROM_TOKEN="${PROM_TOKEN:-}"                # value of the var named by prometheus.token_env, if set
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"

curl -fsS --max-time 10 -H "$AUTH" "${AM_URL}/api/v2/alerts" \
  | jq --arg hrs "$LONG_FIRING_HOURS" -r '
      # startsAt from AM API v2 is an RFC3339 strfmt.DateTime and ALWAYS carries a
      # fractional-second part (e.g. 2020-01-01T00:00:00.000Z), which jq'"'"'s
      # fromdateiso8601 (strptime %Y-%m-%dT%H:%M:%SZ) refuses. Strip the fraction and
      # any numeric offset first, else this errors on every real Alertmanager and
      # ALR-011 silently reports "no long-firing alerts".
      def ts: sub("\\.[0-9]+";"") | sub("[+-][0-9:]+$";"Z") | fromdateiso8601;
      .[] | select((now - (.startsAt | ts)) > (($hrs | tonumber) * 3600)) |
      "\(.labels.alertname) ns=\(.labels.namespace // "-") receivers=\([.receivers[]?.name] | join(","))"
    '
```

Three comparisons, each producing findings when they disagree:

1. **Firing namespaces vs matcher scope.** A namespace that fires alerts but matches no route falls through to the default route. If the default receiver is null, a loopback, or an address nobody watches, that namespace pages no one (ALR-004, high).
2. **topology.md vs matcher coverage.** Every namespace or service `topology.md` lists must be covered by a matcher or by an explicit, stated default-route decision. List uncovered services by name in `affected`; do not summarize as a count.
3. **Long-firing alerts vs the receivers they occupy.** Alerts firing longer than `LONG_FIRING_HOURS` sharing a paging receiver with time-sensitive alerts bury real pages under old noise (ALR-011, medium).

## 8. Dispatch proof (ALR-005, ALR-006)

```bash
set -eu
PROM_URL="https://prometheus.example.com"   # prometheus.url
RECENT_WINDOW="1h"   # example, tune to your alert volume: window for judging "is this failing right now"
PROM_TOKEN="${PROM_TOKEN:-}"                # value of the var named by prometheus.token_env, if set
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"

# Lifetime total (context only — a cumulative counter's instant value is all-time, so a
# now-dead receiver keeps a large number long after it stopped delivering).
TOTAL_CODE=$(curl -s -o /tmp/alr-notif-total.json -w '%{http_code}' --max-time 10 -H "$AUTH" \
  "${PROM_URL}/api/v1/query?query=sum%20by%20(integration%2Creceiver)%20(alertmanager_notifications_total)")
# Windowed success — this is the series the ALR-006 climb-vs-flat verdict is judged from.
# Without it, a channel migration N days ago leaves the dead receiver's lifetime total high
# and the intended receiver's low, inverting which receiver reads as "active right now".
TOTAL_WIN_CODE=$(curl -s -o /tmp/alr-notif-total-win.json -w '%{http_code}' --max-time 10 -H "$AUTH" \
  "${PROM_URL}/api/v1/query?query=sum%20by%20(integration%2Creceiver)%20(increase(alertmanager_notifications_total%5B${RECENT_WINDOW}%5D))")
FAILED_CODE=$(curl -s -o /tmp/alr-notif-failed.json -w '%{http_code}' --max-time 10 -H "$AUTH" \
  "${PROM_URL}/api/v1/query?query=sum%20by%20(integration%2Creceiver)%20(increase(alertmanager_notifications_failed_total%5B${RECENT_WINDOW}%5D))")
echo "notifications_total (lifetime): ${TOTAL_CODE}"
echo "notifications_total (${RECENT_WINDOW}): ${TOTAL_WIN_CODE}"
echo "notifications_failed (${RECENT_WINDOW}): ${FAILED_CODE}"
if [ "$TOTAL_CODE" = "401" ] || [ "$TOTAL_CODE" = "403" ] \
  || [ "$TOTAL_WIN_CODE" = "401" ] || [ "$TOTAL_WIN_CODE" = "403" ] \
  || [ "$FAILED_CODE" = "401" ] || [ "$FAILED_CODE" = "403" ]; then
  echo "auth problem reading dispatch counters; ALR-005/ALR-006 are blocked, not failed, until the token works"
else
  echo "lifetime totals (context only):"
  jq -r '.data.result[] | "\(.metric.receiver)/\(.metric.integration): \(.value[1])"' /tmp/alr-notif-total.json
  echo "increase() over ${RECENT_WINDOW} — judge ALR-006 climb/flat from THIS:"
  jq -r '.data.result[] | "\(.metric.receiver)/\(.metric.integration): \(.value[1])"' /tmp/alr-notif-total-win.json
  jq -r '.data.result[] | "\(.metric.receiver)/\(.metric.integration): \(.value[1])"' /tmp/alr-notif-failed.json
fi
```

Verdicts, only once the queries above returned `200` and not an auth code:

- Any failure counter above zero inside `RECENT_WINDOW`: delivery is breaking right now (ALR-005, high). If your Alertmanager version exposes a `reason` label, group by it too.
- The receiver your routes point at stays flat at zero in the `increase()`-over-`RECENT_WINDOW` success series (`/tmp/alr-notif-total-win.json`) while a different receiver climbs on that same window: an integration or route mismatch (ALR-006, high). Judge this from the windowed series, not the lifetime instant total — the lifetime count reflects all-time deliveries and lets a now-dead receiver's historical volume masquerade as current traffic. This is the shape a silent channel migration leaves behind.
- A receiver with zero traffic and zero alerts routed to it in section 6 is unproven, not broken: status `configured`, never `pass`. The controlled test that forces one delivery and upgrades it to proven is a setup-lane action.
- A `401`/`403` on either query is never read as "flat at zero" or "no failures": an auth-blocked query proves nothing about dispatch, and reporting it as a passing or flat receiver is the exact false-diagnosis this phase exists to prevent.

## 9. Triage metadata contract (ALR-007)

A firing alert that reaches a responder with only its name starts every investigation from zero. Score every paging-severity rule against this contract. Field names here are this toolkit's example convention: map them to whatever identity your own runbooks, ticketing system, or agent tooling actually consume, and say so in the report when you remap them.

Required identity labels:

- `severity`
- `service`
- `namespace`
- `environment` — a real, commonly-missed label even when `severity`/`service`/`namespace` are all present; without it, every triaged alert's environment reads as unknown and prod-vs-staging blast-radius reasoning has nothing to key off

Required annotations, each a complete sentence or query a responder can act on without asking a follow-up question:

- `summary`: what is happening, in one line.
- `impact`: what breaks for users or downstream services if this stays true.
- `confirmation_query`: the exact query, against the same telemetry backend the rule uses, that a responder or an automated agent re-runs to confirm the condition still holds.
- `triage_scope`: the exact object scope to inspect next (namespace, workload, selector).
- `handoff_note`: one line stating the next tool and what to look for there, when a second signal (logs, traces, error tracker) is expected to help.

Check command, run per paging-severity rule found in section 3:

```bash
set -eu
KUBE_CONTEXT="your-kube-context"     # kubernetes.context
MON_NS="monitoring"                  # kubernetes.monitoring_namespace
RULE_NAME="your-rule-name"

kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get prometheusrule "$RULE_NAME" -o json \
  | jq -r '.spec.groups[].rules[] | select(.labels.severity == "critical" or .labels.severity == "warning") |
      "\(.alert): labels=\(.labels | keys | join(",")) annotations=\(.annotations | keys | join(","))"'
```

Known gap on clusters with no `PrometheusRule` CRD at all (GMP-style deployments, see section 3): section 3 finds zero rules to iterate this check over, so ALR-007 silently has nothing to assess rather than failing loudly. The live `/api/v1/rules` response does carry `labels` and `annotations` inline per rule (confirmed in a real GMP deployment), so a per-rule triage-metadata check driven from that response instead of the CRD is possible; not yet built. Until then, state the gap in the report rather than silently passing ALR-007 with zero rules checked.

A rule missing any required label or annotation key is an ALR-007 finding, `medium`, with the rule name and the missing keys in evidence. Then run each rule's `confirmation_query` annotation against its backend:

```bash
set -eu
PROM_URL="https://prometheus.example.com"   # prometheus.url
CONFIRMATION_QUERY="your-confirmation-query"   # from the rule's confirmation_query annotation
PROM_TOKEN="${PROM_TOKEN:-}"                # value of the var named by prometheus.token_env, if set
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"

CODE=$(curl -s -o /tmp/alr-confirm.json -w '%{http_code}' --max-time 10 -H "$AUTH" \
  --data-urlencode "query=${CONFIRMATION_QUERY}" "${PROM_URL}/api/v1/query")
if [ "$CODE" = "401" ] || [ "$CODE" = "403" ]; then
  echo "auth problem running the confirmation query; ALR-007 is blocked on this rule, not a dead-handoff finding"
elif [ "$CODE" = "200" ]; then
  jq -e '.data.result | length > 0' /tmp/alr-confirm.json && jq -r '.data.result' /tmp/alr-confirm.json
else
  echo "unexpected status ${CODE}: reachability problem, not a dead-handoff finding"
fi
```

An empty result (the `jq -e` assertion prints `false`, exits nonzero) with a `200` status is a dead handoff: the annotation points at telemetry that does not exist. This happens most often when a rule was written against an app-specific metric that was never actually emitted; prefer `kube_state_metrics` and kubelet-sourced signals (`kube_deployment_status_replicas_available`, `kube_pod_container_status_restarts_total`, `container_memory_working_set_bytes`, `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}`) when app metrics are unproven. A `401`/`403` is not an empty result and must never be scored as a dead handoff; it means the query never actually ran.

## 10. Error-tracker handoff verification (ALR-008)

Only run this section when a rule's annotations claim an error-tracker handoff. A DSN present in a workload secret proves the SDK was configured once; it does not prove an issue ever arrived. Verify with a read-only API call:

```bash
set -eu
SENTRY_HOST="sentry.io"              # sentry.host
SENTRY_ORG="your-org-slug"           # sentry.org
SENTRY_PROJECT="your-project-slug"   # from the rule's error-tracker project annotation
SENTRY_QUERY="your-issue-query"      # from the rule's error-tracker query annotation
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

curl -fsS --max-time 10 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "https://${SENTRY_HOST}/api/0/projects/${SENTRY_ORG}/${SENTRY_PROJECT}/issues/?query=$(printf '%s' "$SENTRY_QUERY" | jq -sRr @uri)" \
  | jq -r '.[] | "\(.shortId) \(.title) lastSeen=\(.lastSeen)"'
```

A non-empty result with recent `lastSeen` values proves the handoff is live: `validated-live`. An empty result is not automatically a failure; it can mean the query is too narrow or nothing has fired recently. A `401`/`403`/`404` means the project or org slug is wrong, or the token lacks project access; record the status code. Never write `pass` for this check from DSN presence alone (ALR-008, medium). The full error-tracking audit is `audit-sentry`.

## 11. Worked example: a receiver drifted live while the repo stayed correct

An anonymized pattern from a real routing audit, generalized because it recurs:

The declared manifest (layer 1) named a receiver channel that matched what the on-call team expected. The running config on disk (layer 2) still matched the manifest. But the notification-failure counters (section 8) showed a rising `alertmanager_notifications_failed_total` on the Slack integration, and the Alertmanager pod logs carried repeated `channel_not_found` errors.

The cause: someone had renamed the destination channel directly in the chat platform, outside of any manifest change. The three-layer read (section 4) could not have caught this alone, because layers 1 and 2 agreed with each other; only the counters and the log lines, cross-checked against the reload timestamp to rule out stale noise (section 4's reload-proof step), exposed the drift.

Lessons folded into the check catalog:

- Config-layer agreement is necessary but not sufficient. A receiver can be internally consistent across every layer this audit reads and still point at a destination that no longer exists on the receiving end. Only dispatch counters and logs catch that class of drift; that is why ALR-005/ALR-006 are separate checks from ALR-002/ALR-003, not folded into them.
- Log lines age out. The same `channel_not_found` error kept appearing in `kubectl logs` output well after the destination was fixed, because the tail window included pre-fix history. Always compare the error timestamp to the last successful reload (section 4) before citing a log line as current (ALR-009).
- Extract receiver targets by field name, not by array index. A one-liner like `.spec.receivers[1].slackConfigs[0].channel` breaks the moment a receiver list is reordered or a new receiver is inserted. Use `.spec.receivers[] | {name, channels: [.slackConfigs[]?.channel] }` (as in section 4) so the check survives reordering and still names which receiver each channel belongs to.

## 12. Large-path worklist: alert rule batches

Only runs on the large path from [SKILL.md's Estate sizing section](../SKILL.md#estate-sizing). Follows the run-ID keying, resume, and locking rules in [skill-authoring-conventions.md](../../../docs/skill-authoring-conventions.md#large-path-worklists-run-id-keying-resume-and-locking); this section is the alert-routing-specific application, batching alert rules (the unit Phase 3 and Phase 7 both process per-item).

Before minting a new run, scan for one to resume:

```bash
set -eu
TARGET="alert-routing"
AUDIT_ROOT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${TARGET}"

resumable=""
if [ -d "${AUDIT_ROOT}/runs" ]; then
  for d in "${AUDIT_ROOT}/runs"/*/; do
    [ -f "${d}worklist.tsv" ] || continue
    pending=$(awk -F'\t' '$2 == "pending"' "${d}worklist.tsv" | wc -l | tr -d ' ')
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

If nothing is resumable, mint a run and seed the worklist with one row per selected alert rule (from section 3's live inventory):

```bash
set -eu
TARGET="alert-routing"
AUDIT_ROOT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${TARGET}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="${AUDIT_ROOT}/runs/${RUN_ID}"
mkdir -p "${RUN_DIR}"
echo "${RUN_ID}" > "${RUN_DIR}/run-id"

# RULE_LIST: one "namespace/name" per line, from section 3's live PrometheusRule inventory.
RULE_LIST="/tmp/alr-rule-inventory.txt"
awk 'BEGIN{OFS="\t"} {print $0, "pending"}' "$RULE_LIST" > "${RUN_DIR}/worklist.tsv"
echo "seeded ${RUN_DIR}/worklist.tsv with $(wc -l < "${RUN_DIR}/worklist.tsv" | tr -d ' ') rules"
```

Claim and process one batch, with a lock so two invocations never double-claim:

```bash
set -eu
RUN_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/alert-routing/runs/20260717T140500Z"   # example; the resolved run directory
BATCH_SIZE="20"                # matches SKILL.md's Estate sizing default; tune to your environment
LOCK_STALE_MINUTES="30"        # example, tune to your batch size and expected run length
LOCK="${RUN_DIR}/worklist.lock"

now_epoch=$(date -u +%s)
if [ -f "${LOCK}" ]; then
  lock_epoch=$(awk -F'\t' 'NR==1{print $2}' "${LOCK}")
  age_minutes=$(( (now_epoch - lock_epoch) / 60 ))
  if [ "${age_minutes}" -lt "${LOCK_STALE_MINUTES}" ]; then
    echo "worklist locked, age ${age_minutes}m; stop, do not claim a batch"
    exit 1
  fi
  echo "lock is ${age_minutes}m old (>= ${LOCK_STALE_MINUTES}m); reclaiming as abandoned"
fi
printf '%s\t%s\n' "$$" "${now_epoch}" > "${LOCK}"

BATCH="$(awk -F'\t' '$2 == "pending"' "${RUN_DIR}/worklist.tsv" | head -n "${BATCH_SIZE}")"
echo "${BATCH}" | while IFS=$'\t' read -r rule _status; do
  [ -n "$rule" ] || continue
  echo "processing ${rule}: run Phase 3 rule-presence and Phase 7 triage-metadata checks for this rule"
  # ... run the section 3 and section 9 commands with RULE_NAME/RULE_GROUP set from "$rule" ...
done

TMP="${RUN_DIR}/worklist.tsv.tmp"
awk -F'\t' -v batch="${BATCH}" 'BEGIN{split(batch, done, "\n")} {
  matched = 0
  for (i in done) { if ($0 ~ done[i] && done[i] != "") matched = 1 }
  if (matched) print $1"\tdone"; else print $0
}' "${RUN_DIR}/worklist.tsv" > "${TMP}" && mv "${TMP}" "${RUN_DIR}/worklist.tsv"
rm -f "${LOCK}"
echo "batch complete; remaining: $(awk -F'\t' '$2 == "pending"' "${RUN_DIR}/worklist.tsv" | wc -l | tr -d ' ')"
```

Rules specific to this skill's large path:

- Receivers are almost never numerous enough to need batching on their own; process all of them in Phase 4 and Phase 6 in a single pass even on the large path, and batch only the alert-rule-scoped work (Phase 3, Phase 7).
- The report assembles incrementally: findings for `done` rules are written to `findings.json` as each batch completes, so a run interrupted at rule 140 of 300 has already banked 140 rules' worth of findings instead of losing them.
- State the batch progress in terminal output every time: `echo "batch complete; remaining: N"` above is not optional flavor text, it is how a human or the next invocation knows whether to resume.

❌ Started a fresh run directory every invocation without checking for a pending worklist, so a run interrupted at rule 140 of 300 restarts from rule 1 on the next invocation.
✅ Scanned `./scoutflo-audits/alert-routing/runs/*/worklist.tsv` first, found one with 160 rows still `pending`, and resumed it instead of minting a new `RUN_ID`.


## 13. Alert hygiene: range queries and config reads (ALR-012 to ALR-020)

Runs Phase 8. Every block is read-only and reuses endpoints the earlier phases already reach. Honest ceiling, repeated because it belongs in the evidence: these are structural noise signals, not an actionability rate; the flapping and volume windows are bounded by how far back Prometheus still holds the `ALERTS` series and by the continuity of `alertmanager_notifications_total` (a pod restart truncates it), so report the effective lookback the run actually had; and flapping faster than `STEP` is invisible. Every block surfaces evidence; apply the named thresholds (`FLAP_EPISODES`, `STUCK_FRACTION`, etc.) as the reader, exactly as the rest of this audit does. A `401`/`403` on any read here blocks its check; it is never a clean or passing result.

### 13.1 Flapping and stuck rules from the ALERTS range (ALR-012, ALR-013)

`ALERTS{alertstate="firing"}` exists only while a rule is firing, so its appear/disappear pattern over a range reconstructs firing episodes. Episodes count rising edges; firing fraction is present samples over total steps.

```bash
set -eu
PROM_URL="https://prometheus.example.com"   # prometheus.url
LOOKBACK="14d"        # example, tune to your Prometheus retention of the ALERTS series
STEP="300"            # seconds; resolution of the episode reconstruction, example, tune it
FLAP_EPISODES="6"     # example, tune it: firing episodes over LOOKBACK above which a paging rule is flapping
STUCK_FRACTION="90"   # example, tune it: firing percent of the window above which a rule is always-on
PROM_TOKEN="${PROM_TOKEN:-}"
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"

END="$(date -u +%s)"
case "$LOOKBACK" in
  *d) START=$(( END - ${LOOKBACK%d} * 86400 ));;
  *h) START=$(( END - ${LOOKBACK%h} * 3600 ));;
  *)  echo "set LOOKBACK as Nd or Nh"; exit 1;;
esac
TOTAL_STEPS=$(( (END - START) / STEP ))
echo "effective lookback: $(( (END - START) / 86400 ))d at ${STEP}s step (bounded by ALERTS retention)"

CODE=$(curl -s -o /tmp/alr-alerts-range.json -w '%{http_code}' --max-time 30 -H "$AUTH" -G \
  --data-urlencode 'query=ALERTS{alertstate="firing"}' \
  --data-urlencode "start=${START}" --data-urlencode "end=${END}" --data-urlencode "step=${STEP}s" \
  "${PROM_URL}/api/v1/query_range")
if [ "$CODE" = "401" ] || [ "$CODE" = "403" ]; then
  echo "auth problem on query_range; ALR-012/ALR-013 blocked, not clean"; exit 0
elif [ "$CODE" != "200" ]; then
  echo "query_range status ${CODE}: reachability/API-shape problem, not a clean result"; exit 0
fi

# episodes = 1 + gaps wider than 2 steps; firing_pct = present samples / total steps.
jq -r --argjson step "$STEP" --argjson total "$TOTAL_STEPS" '
  .data.result[]
  | (.values | map(.[0])) as $ts
  | ( [ range(1; ($ts | length)) | select($ts[.] - $ts[.-1] > ($step * 2)) ] | length ) as $gaps
  | { alert: (.metric.alertname // "?"), severity: (.metric.severity // "-"),
      episodes: (1 + $gaps),
      firing_pct: ((($ts | length) * 100) / (if $total > 0 then $total else 1 end) | floor) }
  | "\(.alert) severity=\(.severity) episodes=\(.episodes) firing_pct=\(.firing_pct)"
' /tmp/alr-alerts-range.json | sort
echo "flag: paging rules with episodes > ${FLAP_EPISODES} (ALR-012, confirm keep_firing_for==0 in 13.2), or firing_pct > ${STUCK_FRACTION} (ALR-013)"
```

A paging-severity rule over `FLAP_EPISODES` episodes is a flap candidate; confirm it has no `keep_firing_for` hold (13.2) before writing ALR-012. A rule over `STUCK_FRACTION` percent is always-on wallpaper (ALR-013). Sub-`STEP` flapping is invisible; say so in the finding rather than implying the rule is clean.

### 13.2 The `for` debounce and `keep_firing_for` hold (ALR-014, ALR-012)

```bash
set -eu
PROM_URL="https://prometheus.example.com"   # prometheus.url
PROM_TOKEN="${PROM_TOKEN:-}"
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"

CODE=$(curl -s -o /tmp/alr-rules-hygiene.json -w '%{http_code}' --max-time 15 -H "$AUTH" "${PROM_URL}/api/v1/rules")
[ "$CODE" = "200" ] || { echo "rules API ${CODE}: ALR-012/ALR-014 blocked, not clean"; exit 0; }

# duration == 0 -> no `for` debounce (ALR-014). keepFiringFor == 0/absent -> no anti-flap hold (ALR-012).
jq -r '
  .data.groups[].rules[]
  | select(.type == "alerting")
  | "\(.name) severity=\(.labels.severity // "-") for=\(.duration // 0)s keep_firing_for=\(.keepFiringFor // 0)s"
' /tmp/alr-rules-hygiene.json | sort
echo "flag: paging-severity rule with for=0s (ALR-014); with keep_firing_for=0s AND flapping in 13.1 (ALR-012)"
```

On a GMP-style cluster with no `PrometheusRule` CRD, `/api/v1/rules` still carries `duration`/`keepFiringFor` inline, so this check works from the live rules response regardless of the CRD family (same fallback as ALR-007).

### 13.3 Volume concentration and top-talkers (ALR-015)

```bash
set -eu
PROM_URL="https://prometheus.example.com"   # prometheus.url
LOOKBACK="14d"   # example, match 13.1
PROM_TOKEN="${PROM_TOKEN:-}"
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"

# Notification volume per receiver over the window (which receivers absorb the most pages).
curl -s -H "$AUTH" -G \
  --data-urlencode "query=sum by (receiver) (increase(alertmanager_notifications_total[${LOOKBACK}]))" \
  "${PROM_URL}/api/v1/query" \
  | jq -r '.data.result[]? | "\(.metric.receiver) \(.value[1] | tonumber | floor)"' | sort -k2 -nr

# Firing volume per rule over the window (the top-talker rules).
curl -s -H "$AUTH" -G \
  --data-urlencode "query=sum by (alertname) (count_over_time(ALERTS{alertstate=\"firing\"}[${LOOKBACK}]))" \
  "${PROM_URL}/api/v1/query" \
  | jq -r '.data.result[]? | "\(.metric.alertname) \(.value[1] | tonumber | floor)"' | sort -k2 -nr | head -20
echo "flag: when a few rules produce the bulk of a paging receiver's volume, name them (ALR-015). repeat_interval floor is checked in 13.4."
```

### 13.4 Grouping, inhibition, mute intervals, repeat_interval, resolve-noise (ALR-016, ALR-015, ALR-018)

All from the running config. Redact per section 5 before storing any of it.

```bash
set -eu
AM_URL="https://alertmanager.example.com"   # prometheus.alertmanager_url
PROM_TOKEN="${PROM_TOKEN:-}"
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"

CODE=$(curl -s -o /tmp/alr-am-status.json -w '%{http_code}' --max-time 15 -H "$AUTH" "${AM_URL}/api/v2/status")
[ "$CODE" = "200" ] || { echo "status ${CODE}: ALR-016/ALR-018 blocked, not clean"; exit 0; }
jq -r '.config.original' /tmp/alr-am-status.json > /tmp/alr-am-config.yaml

grep -nE 'group_by|repeat_interval|inhibit_rules|(mute|active)_time_intervals|time_intervals|send_resolved|resolve_timeout' \
  /tmp/alr-am-config.yaml \
  || echo "none of the grouping/inhibition/mute/resolve keys present in the rendered config"
```

Read the matched lines against these rules:

- **`group_by` (ALR-016):** absent on a paging route means one page per alert during a broad outage. The special value `['...']` also defeats aggregation — it means "group by every label", so each distinct alert becomes its own group. Both are findings; a real `group_by` names the few labels that define an incident (for example `['alertname','cluster','namespace']`).
- **`inhibit_rules` (ALR-016):** empty or absent means no correlation suppression, so a single root cause pages for every downstream symptom.
- **`time_intervals` + route `mute_time_intervals`/`active_time_intervals`:** every referenced interval name must resolve to a definition; a dangling reference is a config error.
- **`repeat_interval` (ALR-015):** a short value (minutes) on a paging route re-pages the same firing group repeatedly.
- **`send_resolved` (ALR-018):** `true` on a paging receiver emits a fire and a resolve per incident, roughly doubling its volume. Often deliberate — `info` unless it inflates a receiver already flagged by 13.3, then `medium`.
- **`resolve_timeout` (ALR-018):** global, default 5m; how fast an alert with no explicit resolve is treated as cleared.

### 13.5 Duplicate delivery and HA dedup health (ALR-017)

```bash
set -eu
AM_URL="https://alertmanager.example.com"   # prometheus.alertmanager_url
PROM_TOKEN="${PROM_TOKEN:-}"
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"

# Alertmanager dedup only holds while the HA cluster is healthy.
curl -s -H "$AUTH" "${AM_URL}/api/v2/status" \
  | jq -r '.cluster | "cluster.status=\(.status) peers=\((.peers // []) | length)"'

# Alerts currently resolved to more than one receiver: candidate duplicate delivery.
curl -s -H "$AUTH" "${AM_URL}/api/v2/alerts" \
  | jq -r '.[] | select(([.receivers[]?.name] | length) > 1)
      | "\(.labels.alertname // "?") -> \([.receivers[]?.name] | join(","))"' | sort -u
echo "flag: cluster.status != ready or fewer peers than expected defeats dedup (ALR-017); confirm multi-receiver alerts are intended vs an accidental continue:true"
```

### 13.6 Stale silences masking real alerts (ALR-013)

```bash
set -eu
AM_URL="https://alertmanager.example.com"   # prometheus.alertmanager_url
PROM_TOKEN="${PROM_TOKEN:-}"
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"

# List active silences with their window, author, and matchers; a very-far-future endsAt
# or a silence renewed for months is hiding real alerts, not managing noise.
curl -s -H "$AUTH" "${AM_URL}/api/v2/silences" \
  | jq -r '.[] | select(.status.state == "active")
      | "silence \(.id) starts=\(.startsAt) ends=\(.endsAt) by=\(.createdBy // "?") "
        + "matchers=\([.matchers[]? | "\(.name)=\(.value)"] | join(","))"'
echo "flag: an active silence with a far-future or perpetually-renewed endsAt is an ALR-013 finding — name its matcher and createdBy"
```

### 13.7 le/quantile matcher normalization on Prometheus 3.x (ALR-019)

Prometheus 3.0 normalizes `le` (classic histograms) and `quantile` (summaries) label values to a float form on ingestion: `le="1"` becomes `le="1.0"`. An exact-string route or inhibition matcher pinned to the integer form silently stops selecting those series after the upgrade. Gate the whole check on the target's Prometheus major version.

```bash
set -eu
PROM_URL="https://prometheus.example.com"   # prometheus.url
AM_URL="https://alertmanager.example.com"   # prometheus.alertmanager_url
PROM_TOKEN="${PROM_TOKEN:-}"
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"

# Version gate: this trap only bites on Prometheus 3.x. Capture the HTTP code — a 401/403
# is an auth finding (ALR-019 BLOCKED, scores 0, stays in the denominator), NEVER a silent
# not-in-scope. Bare `curl -s` here would turn an auth failure into version "0" -> "<3" ->
# not-in-scope, dropping your headline check with a bogus "Prometheus 0" message.
BI_CODE="$(curl -s -o /tmp/alr-buildinfo.json -w '%{http_code}' -H "$AUTH" "${PROM_URL}/api/v1/status/buildinfo")"
if [ "$BI_CODE" = "401" ] || [ "$BI_CODE" = "403" ]; then
  echo "ALR-019 BLOCKED: ${PROM_URL}/api/v1/status/buildinfo returned ${BI_CODE} — Prometheus read token lacks access; cannot determine version. Record as an auth-scope finding, not not-in-scope."
elif [ "$BI_CODE" != "200" ]; then
  echo "ALR-019 BLOCKED: buildinfo returned HTTP ${BI_CODE}; cannot determine Prometheus version. Record as blocked."
else
  PVER="$(jq -r '.data.version // "0"' /tmp/alr-buildinfo.json)"
  PVER="${PVER#v}"          # tolerate a leading v (v3.0.1 -> 3.0.1) before the integer compare
  PMAJOR="${PVER%%.*}"
  case "$PMAJOR" in ''|*[!0-9]*) PMAJOR=0 ;; esac   # non-numeric major -> treat as pre-3, never error under set -e
  echo "prometheus version: ${PVER}"
  if [ "$PMAJOR" -lt 3 ]; then
    echo "ALR-019 not-in-scope: Prometheus ${PVER} keeps the integer le/quantile form; no normalization trap"
  else
  # Scan the rendered route tree and inhibit rules for le/quantile pinned to a bare integer.
  # Read config.original from api/v2/status; catch BOTH matcher forms:
  #   inline matchers list:  le="1"  /  le=~"1"      (operator = or =~)
  #   classic map form:      match:/match_re:/source_match:/target_match: with  le: "1"
  # A grep for only the `=` form silently misses the map form, which is common in
  # hand-authored and Helm base configs — a false ALR-019 pass.
  curl -s -H "$AUTH" "${AM_URL}/api/v2/status" \
    | jq -r '.config.original // ""' \
    | grep -nE '\b(le|quantile)\b[[:space:]]*(=~?|:)[[:space:]]*"?[0-9]+"?([^.0-9]|$)' \
    || echo "no integer-pinned le/quantile matcher found"
    echo "flag (Prometheus 3.x): each hit is an ALR-019 finding — the series now carries the float form (le=\"1.0\"); rewrite the matcher to the normalized value or a decimal-tolerant regex. A regex matcher with a literal '.' (le=~\"1.0\") is under-anchored; escape it (le=~\"1\\.0\")."
  fi
fi
```

Note: the grep is a candidate finder over the rendered config text, not the verdict. Read each hit in context — a matcher like `le="1.0"` (already normalized) or `le=~"1\\.0"` (correctly escaped) is fine; only a bare integer (`le="1"`, `quantile="0"`) is the finding. UTF-8 strict matcher mode is still opt-in in Alertmanager (fallback mode is the default through 0.33.x), so the escaping note applies regardless of parser mode.

### 13.8 Deprecated msteams delivery path (ALR-020)

`msteams_configs` depends on the Office 365 connector Microsoft is retiring; Alertmanager 0.28.0 added `msteamsv2_configs` (adaptive-card Workflows format) as the replacement. A receiver still on the old block parses but is a dying delivery path.

```bash
set -eu
AM_URL="https://alertmanager.example.com"   # prometheus.alertmanager_url
PROM_TOKEN="${PROM_TOKEN:-}"
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"

# Receivers still carrying an msteams_configs block (the deprecated path).
curl -s -H "$AUTH" "${AM_URL}/api/v2/status" \
  | jq -r '.config.original // ""' \
  | grep -nE 'msteams_configs[[:space:]]*:' \
  || echo "no msteams_configs receiver found"
echo "flag: each hit is an ALR-020 finding (medium) — migrate that receiver to msteamsv2_configs; the Office 365 connector msteams_configs relies on is being retired"
```

## 14. Rule-evaluation health, live suppression, and page timing (ALR-021, ALR-022, ALR-023)

Three checks that everything above can pass while the page still never lands: a rule that is *loaded* (ALR-001) but errors every evaluation; a paging alert that is firing but *suppressed right now*; and a route that pages, but late or muted at this clock. All read-only, all proven live against the benchmark (Prometheus + vmalert + Alertmanager).

### 14.1 Rule-evaluation health (ALR-021)

`/api/v1/rules` `health`/`lastError` is the **primary, engine-agnostic** signal — both Prometheus and vmalert expose it. The self-metric confirmation is **engine-gated**, because the metric names differ:

```bash
# Primary (works on Prometheus AND vmalert): a loaded rule that never actually fires.
curl -s --max-time 15 -H "$AUTH" "${PROM_URL}/api/v1/rules" \
  | jq -r '.data.groups[].rules[] | select(.type=="alerting") | select((.health // "ok") != "ok" or ((.lastError // "") != "")) | "\(.name) health=\(.health) lastError=\(.lastError)"'

# Engine-gated self-metric confirmation. Detect the engine first (buildinfo/flags), then use ITS metrics:
#  - Prometheus:  prometheus_rule_evaluation_failures_total ; and group overrun
#                 prometheus_rule_group_last_duration_seconds > prometheus_rule_group_interval_seconds
#  - vmalert:     vmalert_execution_errors_total, vmalert_alerting_rules_errors_total (per-alertname),
#                 vmalert_recording_rules_errors_total ; vmalert has NO *_rule_group_interval_seconds
#                 analog, so DROP the overrun query there (use vmalert_iteration_duration_seconds only as
#                 an overrun proxy if wanted). Verified live: this benchmark's vmalert exposes
#                 vmalert_alerting_rules_errors_total{alertname=...} and vmalert_iteration_duration_seconds,
#                 and does NOT expose prometheus_rule_*.
# On Prometheus:
curl -s -G -H "$AUTH" --data-urlencode 'query=sum by (rule_group) (increase(prometheus_rule_evaluation_failures_total[1h]))' \
  "${PROM_URL}/api/v1/query" | jq -r '.data.result[] | select((.value[1]|tonumber)>0) | "\(.metric.rule_group): \(.value[1]) eval failures/1h"'
curl -s -G -H "$AUTH" --data-urlencode 'query=(prometheus_rule_group_last_duration_seconds > prometheus_rule_group_interval_seconds)' \
  "${PROM_URL}/api/v1/query" | jq -r '.data.result[] | "\(.metric.rule_group): eval overran its interval"'
# On vmalert (substitute the vmalert self-metrics; overrun query omitted — no interval-seconds analog):
curl -s "${VMALERT_URL}/metrics" | grep -E '^vmalert_(execution_errors_total|alerting_rules_errors_total|recording_rules_errors_total)' || true
```

Fail (ALR-021, high): a rule is loaded but `health!="ok"` or carries a `lastError` — it has fired zero times and never will until the expression is fixed. Join each to its topology service and read `.labels.severity`: "`CheckoutErrorBudgetBurn` is loaded but `health=err lastError=\"vector cannot contain metrics with the same labelset\"` — checkout has a paging rule that has fired zero times." Blast radius is the count of paging rules with `health!=ok` and the count of critical services thereby left with a dead rule. An empty self-metric result **on the wrong engine** is `not observable`, never `healthy` — state which engine was detected. Remediation: fix the named rule's expression (the planned alert-rule setup skill owns this; today, point at the rule and the error).

### 14.2 Live suppression of a paging alert (ALR-022)

```bash
curl -s --max-time 10 -H "$AUTH" "${AM_URL}/api/v2/alerts?active=true&silenced=true&inhibited=true" \
  | jq -r '.[] | select((.labels.severity=="critical" or .labels.severity=="warning") and (.status.state=="suppressed")) | "\(.labels.alertname) ns=\(.labels.namespace // "-") silencedBy=\([.status.silencedBy[]?]|join(",")) inhibitedBy=\([.status.inhibitedBy[]?]|join(","))"'
```

Fail (ALR-022, high): an alert is active AND paging-severity AND `.status.state=="suppressed"` — a page not reaching a human *at this moment*, swallowed by a silence (`silencedBy`) or an inhibition (`inhibitedBy`). "`PaymentsDown` (critical) is active but suppressed right now, `inhibitedBy` an over-broad `ClusterDown` inhibit rule — the payments page is eaten by a correlation rule meant to reduce noise." Blast radius is the count of currently-suppressed paging alerts and which silence/inhibit id owns each. Distinct from the config-side stale-silence check (ALR-013, section 13.6) which reads silence *definitions*; this reads live routing *state*. Remediation: `setup-lgtm#add-severity-routes-and-inhibition` for over-broad inhibit rules; an unintended silence expires through the Alertmanager UI/amtool (as in ALR-013).

### 14.3 Route timing and live-clock mute (ALR-023)

This adds only the **live-clock and latency** axis; the dangling/misconfigured mute-interval *definition* error is already owned by section 13.4 — cross-reference it, do not re-report it here.

```bash
curl -s --max-time 15 -H "$AUTH" "${AM_URL}/api/v2/status" | jq -r '.config.original' > /tmp/alr-am-config.yaml
grep -nE 'group_wait|group_interval|mute_time_intervals|active_time_intervals' /tmp/alr-am-config.yaml || echo 'no timing/mute keys in rendered config'
date -u '+now UTC: %Y-%m-%d %H:%M %A'   # compare against any mute/active interval whose route pages 24/7
```

Fail (ALR-023, medium): a paging route sets a large `group_wait` (minutes) — that latency is added to MTTA on every incident before the first page leaves ("severity=critical route sets `group_wait: 5m`, so every critical page is delayed 5 minutes by design"); OR a `mute_time_intervals` on a 24/7 paging route covers the current UTC time, so that route is paging nobody at this moment. Blast radius is the group_wait seconds added to MTTA and whether a paging route is muted at the current clock. Verified live: the benchmark's default route is `group_wait: 10s` (fine) with no mute intervals. Remediation: `setup-lgtm#add-severity-routes-and-inhibition`.
