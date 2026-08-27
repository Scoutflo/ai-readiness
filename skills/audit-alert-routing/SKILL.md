---
name: audit-alert-routing
description: Read-only proof that the paging path works and is not drowning in noise; follows each alert rule through Alertmanager routes to a live receiver, scores delivery gaps, and scores alert-hygiene gaps (flapping, permanently-firing rules, missing `for` debounce, missing grouping or inhibition, duplicate delivery, resolve-noise) as findings. Use when the user asks whether alerts reach a human, or mentions the Prometheus/Alertmanager paging path, silent alerts, missed pages, dead receivers, routing trees, mute timings, notification delivery, alert noise, alert fatigue, flapping alerts, or noisy paging. Do not use for a full metrics/logs/traces audit (use audit-lgtm), Grafana-managed alerting (use audit-grafana), error-tracker depth (use audit-sentry), or to change routing (use setup-lgtm or setup-grafana).
---

# audit-alert-routing

Deep, read-only audit of the Prometheus-to-Alertmanager paging path. It answers one question: when a rule fires tonight, does a notification actually leave Alertmanager toward a receiver your team watches? A rule that fires into a dead or drifted receiver is silence with extra steps, and nothing on a dashboard tells you it happened.

The audit walks a fixed verification chain. Each link converts one assumption into evidence:

1. The alert rules you rely on exist live and are loaded by Prometheus.
2. The Alertmanager config you declared is the config that is live, rendered on disk, and running in memory.
3. Alerts are actually firing, with the labels you think they have.
4. The route tree resolves those alerts to the intended receiver.
5. Dispatch counters prove notifications leave on that receiver, with failure counters flat.
6. The alert payload carries enough metadata that a responder or automation can act on it without tribal knowledge.
7. The alert stream is signal, not noise: rules do not flap or fire forever, related alerts group into one page, and no single rule floods the receiver.

Every command in this audit is read-only: `kubectl get`, `kubectl logs`, GET requests, and query calls that execute reads and store nothing. `kubectl exec` (to read a rendered file) and `kubectl port-forward` (to reach an unexposed API) change no cluster state and are classified read-only by effect; both are declared in the doctor gate and each has a fallback. Firing a controlled test notification is a mutation and lives in the setup lane.

Scope boundaries: `/scoutflo:audit-lgtm` includes the broad routing checks inside the full stack audit; run this skill for the deep walk, typically after a routing incident, a channel migration, an Alertmanager upgrade, or before an on-call handover you need to trust. If your alerting is Grafana-managed, `/scoutflo:audit-grafana` covers that path. Error-tracking depth is `/scoutflo:audit-sentry`.

Fixes: receiver and noise repairs go to `/scoutflo:setup-lgtm`. A dedicated alert-rule setup skill that takes ALR finding IDs as input is planned; until it ships, [references/verification-chain.md](references/verification-chain.md) carries the target rule and metadata patterns.

Run standalone, from `/scoutflo:audit-all`, or on a schedule via `/scoutflo:schedule-audits`.

Outputs, per the [report standard](../../report-standard/README.md):

- `./scoutflo-audits/alert-routing/<YYYY-MM-DD>/findings.json` per the [findings schema](../../report-standard/findings-schema.md)
- `./scoutflo-audits/alert-routing/<YYYY-MM-DD>/report.md` per the [report template](../../report-standard/report-template.md), including the `## Inventory` section (the `render-report-viz.sh inventory` output)
- `./scoutflo-audits/alert-routing/<YYYY-MM-DD>/inventory.json` per the [inventory schema](../../report-standard/inventory-schema.md) (`scoutflo-inventory/v1`): the complete Phase-1 catalog — one item per alert rule, Alertmanager receiver, route, and silence — each with its `kind` (`alert_rule`, `receiver`, `route`, `silence`), `covers` (the topology service the alert maps to), `enabled`, `severity` (the object's own, or null), and `routes_to` for alerting objects. Built from the raw pull, never invented; redacted at capture, never a secret value.
- One Slack brief, when `slack.webhook_env` is configured

## Doctor gate

| Integration | toolkit.yaml keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| Prometheus | `prometheus.url` | `prometheus.token_env` (`PROM_TOKEN`), if set | query and rules APIs | read-only |
| Alertmanager | `prometheus.alertmanager_url` | shares `prometheus.token_env` (`PROM_TOKEN`), if set | status and alerts APIs | read-only |
| Kubernetes | `kubernetes.context`, `kubernetes.monitoring_namespace` | kubeconfig | get, list, logs; exec or port-forward into the monitoring namespace (either one is enough) | read-only |
| Sentry (optional) | `sentry.host`, `sentry.org` | `sentry.token_env` (`SENTRY_TOKEN`) | project read | read-only |
| Slack (optional) | `slack.webhook_env` | webhook variable | post to one channel | n/a |

Sentry is required only when your alerts claim an error-tracker handoff (ALR-008); otherwise mark that check `not-in-scope`. A failed doctor check stops the audit with the exact failure and the fix, usually `/scoutflo:connect`. Never downgrade a doctor failure into a finding.

`prometheus.token_env` is optional: many deployments need no bearer token at all. When it is set, every call to `PROM_URL` or `AM_URL` in this audit attaches it the same presence-checked way `doctor.sh`'s `http_get` does: `Authorization: Bearer` only when the token is non-empty, never an empty bearer header. See [references/verification-chain.md](references/verification-chain.md) section 0 for the exact pattern every command block below reuses.

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"
[ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done
[ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
if [ ! -f "$CFG" ]; then
  # Multi-environment setup: a customer running prod+nonprod often has no default
  # toolkit.yaml but named variants (toolkit-prod.yaml, toolkit-nonprod.yaml). List
  # them so the choice is directed, not a dead stall — but NEVER auto-pick an
  # environment (auditing the wrong one is worse than asking).
  ENVCFGS=$(for d in "./.scoutflo" "$HOME/.scoutflo"; do ls "$d"/toolkit-*.yaml 2>/dev/null; done)
  if [ -n "$ENVCFGS" ]; then
    echo "no default config at $CFG, but found environment-specific configs:"
    printf '%s\n' "$ENVCFGS" | sed 's/^/  - /'
    echo "re-run with SCOUTFLO_CONFIG=<one of the above> for the environment you want (never auto-picked), or run /scoutflo:connect to create a default"
  else
    echo "missing $CFG; run /scoutflo:connect"
  fi
  exit 1
fi
# Load the home-anchored secret store so a token added to ~/.scoutflo/env (by connect,
# even mid-session) is seen here without re-exporting or opening a new terminal. It only
# sets *_env variables; no secret value is printed. A profile that already sources it makes
# this a no-op. This mirrors what /scoutflo:doctor does, so doctor and this audit agree.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
command -v curl >/dev/null || { echo "curl not installed"; exit 1; }
command -v jq   >/dev/null || { echo "jq not installed"; exit 1; }
command -v kubectl >/dev/null || echo "WARN: kubectl missing; only the cluster-side chain links (Alertmanager-in-cluster, port-forward fallback) are blocked — the Prometheus/Alertmanager HTTP checks still run. ALR-010 reachability decides what is actually blocked."
# For every configured *_env key: presence only, never the value.
# PROM_TOKEN is optional for open endpoints; SENTRY_TOKEN only if sentry.* is configured.
```

Then one cheap live call per integration: `GET /api/v1/status/buildinfo` on Prometheus, `GET /api/v2/status` on Alertmanager (commands in [references/verification-chain.md](references/verification-chain.md) section 2). `/scoutflo:doctor` runs the same checks standalone.

Live-safety gate. Print what you are pointed at and compare it to the config before the first real check:

```bash
set -eu
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
kubectl config current-context
kubectl --context "$KUBE_CONTEXT" auth whoami 2>/dev/null || kubectl --context "$KUBE_CONTEXT" version
```

If the resolved context or API identity differs from what `toolkit.yaml` names, stop and report the mismatch. Never proceed on "probably the right cluster". Every command names its target explicitly: `kubectl --context "$KUBE_CONTEXT"`, `curl` against a URL resolved from the config.

## Ground rules

- A manifest in Git is a claim. A CRD in the cluster is a claim. Only the rendered file, the running config, and the counters are evidence. Walk all layers before concluding anything.
- Evidence is real command output. An assertion without the command and its observed output is a suspicion, not a finding.
- API errors are evidence. A `401`, `403`, `404`, or timeout tells you: wrong path, missing auth, wrong ingress, blocked network. Never convert an upstream error into empty success.
- A `401`/`403` on a Prometheus or Alertmanager call is an auth-scope finding, never a routing or reachability finding. Name it as such and treat every check downstream of that call as `blocked`, not `fail`, until the token works. Confusing an auth failure for "unreachable" or "routing broken" is the single most damaging misread this audit can make, because it tells you to go fix the wrong layer.
- Notification counters prove dispatch attempts and downstream acceptance, not human receipt. Say exactly which of those you proved.
- A receiver with zero traffic is `configured`, not working. Only observed dispatch upgrades it, and the controlled test that forces dispatch is a setup-lane action.
- Log lines are history until their timestamps are compared to the last config reload. Old errors are not current failures.
- Never print, log, or write a secret: no webhook URLs, tokens, auth headers, or unredacted rendered configs, in terminal output or in any output file. Receiver names and channel names are safe; URLs are not.

## Check catalog

One permanent ID per check. IDs never change or get reused; retired checks keep their number. Severity listed is the typical severity when the check fails; judge the real impact in your environment.

| ID | Category | Check | Typical fail severity |
| --- | --- | --- | --- |
| ALR-001 | Rule presence | Expected alert rules exist live and are loaded by Prometheus | high |
| ALR-002 | Config integrity | Live Alertmanager receivers and routes match the declared source of truth | critical |
| ALR-003 | Config integrity | Rendered and running config match the live objects; last reload succeeded | critical |
| ALR-004 | Route matching | Route matchers cover every namespace and service where alerts fire | high |
| ALR-005 | Dispatch proof | Notification failure counters flat at zero per integration and receiver | high |
| ALR-006 | Dispatch proof | Dispatch counters climb on the expected receiver, not a different one | high |
| ALR-007 | Triage metadata | Paging alerts carry machine-actionable triage metadata | medium |
| ALR-008 | Triage metadata | Error-tracker handoff proven by API evidence, not DSN presence | medium |
| ALR-009 | Dispatch proof | Delivery-error log noise distinguished from current failure by reload timestamp | info |
| ALR-010 | Reachability | Prometheus and Alertmanager hosts resolve and their APIs answer | high |
| ALR-011 | Route matching | Paging receivers not flooded by unrelated long-firing alerts | medium |
| ALR-012 | Alert hygiene | Paging rules do not flap; flapping rules carry an anti-flap hold (`keep_firing_for`) | medium |
| ALR-013 | Alert hygiene | No paging rule fires permanently; no stale silence hides real alerts | medium |
| ALR-014 | Alert hygiene | Paging rules carry a `for` debounce, not fire on a single scrape blip | medium |
| ALR-015 | Alert hygiene | Notification volume is not dominated by a few noisy rules; no re-page storm | medium |
| ALR-016 | Alert hygiene | Paging routes group related alerts and inhibit redundant ones | medium |
| ALR-017 | Alert hygiene | No unintended duplicate delivery; Alertmanager HA dedup is healthy | medium |
| ALR-018 | Alert hygiene | Resolve-notification volume on paging receivers is deliberate, not accidental | info |
| ALR-019 | Route matching | No route/inhibition matcher pins `le`/`quantile` to an integer value that Prometheus 3.x normalizes to a float | high |
| ALR-020 | Config integrity | No receiver on the deprecated `msteams_configs` delivery path (retired Office 365 connector) | medium |
| ALR-021 | Rule presence | Loaded alert rules actually evaluate — `health==ok`, no `lastError`, no evaluation overrun (engine-gated) | high |
| ALR-022 | Dispatch proof | No paging-severity alert is silently suppressed right now (a silence or inhibition swallowing a live page) | high |
| ALR-023 | Route matching | Paging routes do not delay or mute the first page (large `group_wait`, or a mute interval active at the current clock) | medium |

Category weights for scoring:

| Category | Weight | IDs |
| --- | ---: | --- |
| Config integrity | 20 | ALR-002, ALR-003, ALR-020 |
| Dispatch proof | 20 | ALR-005, ALR-006, ALR-009, ALR-022 |
| Route matching | 15 | ALR-004, ALR-011, ALR-019, ALR-023 |
| Rule presence | 15 | ALR-001, ALR-021 |
| Alert hygiene | 15 | ALR-012, ALR-013, ALR-014, ALR-015, ALR-016, ALR-017, ALR-018 |
| Triage metadata | 10 | ALR-007, ALR-008 |
| Reachability | 5 | ALR-010 |

## Estate sizing

Count before judging, and declare the path in the terminal output. The natural batch unit here is the alert rule: Phase 3 (rule presence) and Phase 7 (triage metadata) both do per-rule work, and receiver counts almost never dominate rule counts in practice.

```bash
set -eu
SMALL_MAX_OBJECTS="20"    # example, tune to your environment
MEDIUM_MAX_OBJECTS="80"   # example, tune to your environment
BATCH_SIZE="20"           # alert rules per batch on the large path; example, tune it
KUBE_CONTEXT="your-kube-context"            # kubernetes.context
AM_URL="https://alertmanager.example.com"   # prometheus.alertmanager_url
PROM_TOKEN="${PROM_TOKEN:-}"                # value of the var named by prometheus.token_env, if set
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"

RULES="$(kubectl --context "$KUBE_CONTEXT" get prometheusrule -A -o json 2>/dev/null \
  | jq '[.items[]?.spec.groups[]?.rules[]?] | length' 2>/dev/null || echo 0)"
# Capture the HTTP code — a 401/403 on /api/v2/receivers is an auth finding, not a zero
# estate. Bare `curl -s | jq length` would return the key-count of a JSON error body
# (e.g. 2 for {"error":...,"code":401}) or, on a plain-text 401 body, make jq error and
# abort the whole sizing block under set -eu. Neither is the "stop and report auth" behavior.
REC_CODE="$(curl -s -o /tmp/alr-receivers.json -w '%{http_code}' -H "$AUTH" --max-time 10 "${AM_URL}/api/v2/receivers")"
if [ "$REC_CODE" = "401" ] || [ "$REC_CODE" = "403" ]; then
  echo "BLOCKED: ${AM_URL}/api/v2/receivers returned ${REC_CODE} — Alertmanager read token lacks access. Stop and report an auth-scope finding; do NOT size the estate from an empty count."
  exit 1
elif [ "$REC_CODE" != "200" ]; then
  echo "BLOCKED: /api/v2/receivers returned HTTP ${REC_CODE}; cannot size the estate. Record as blocked."
  exit 1
fi
RECEIVERS="$(jq 'if type=="array" then length else 0 end' /tmp/alr-receivers.json)"
TOTAL=$((RULES + RECEIVERS))
echo "alert_rules=${RULES} receivers=${RECEIVERS} scored_objects=${TOTAL}"

# Guided-walkthrough drift check, per report-standard/README.md#using-topology-and-prior-runs-as-a-guided-walkthrough:
# compare against the last run rather than a blank slate. State the result in the executive summary;
# never silently omit it. This never skips a live check - every check in later phases still runs fresh.
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/alert-routing"
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

`kubectl get prometheusrule` reads 0 rules, not an error, on any cluster that doesn't run the Prometheus Operator's CRD — Google Managed Prometheus (GMP) uses its own family (`rules.monitoring.googleapis.com`, `clusterrules`, `globalrules`) instead. When `alert_rules=0` but the cluster clearly has alerting (Alertmanager has receivers, or `/api/v1/rules` in Phase 3 returns real groups), treat the count as a floor, not the truth, and size from the live `/api/v1/rules` response instead. This only affects the sizing pre-check; Phase 3's own live-rules check (below) already reads from `/api/v1/rules` and is unaffected either way.

- **Small** (`TOTAL <= SMALL_MAX_OBJECTS`): one pass over everything. No worklist, no batching; a dozen rules do not need bookkeeping.
- **Medium** (`TOTAL <= MEDIUM_MAX_OBJECTS`): per-category passes (rule presence, config drift, route matching, dispatch proof, triage metadata), completed in one run.
- **Large**: work alert rules in batches of `BATCH_SIZE` against a run-ID-keyed worklist with a lock, so an interrupted run resumes instead of restarting, and the report is assembled incrementally as batches complete. Commands, resume scan, and lock mechanics are in [references/verification-chain.md section 12](references/verification-chain.md#12-large-path-worklist-alert-rule-batches).

Record the chosen path and counts in `findings.json` as `estate: {objects, path}` (per the [findings schema](../../report-standard/findings-schema.md)); the guided-walkthrough drift check above reads `.estate.objects` from the previous run, and `audit-all` reads them to roll up this target's size. Never silently truncate: if the run judged a subset, the report names what was skipped and the coverage denominators reflect it. A `401`/`403` on either count call is an auth problem, not a zero-object estate; stop and report it per the auth-header discipline above rather than declaring a small path from an empty count.

### Scope checkpoint

On a large estate this audit pauses to let you scope before spending tokens, per the shared [estate-sizing scope checkpoint](../../report-standard/estate-scope-checkpoint.md). After the sizing step above computes the object count, run the shared checkpoint block:

```bash
set -eu
# The Estate sizing step above sets TOTAL to this audit's object count.
TOTAL="${TOTAL:?estate sizing must set TOTAL before the scope checkpoint}"
. "${CLAUDE_PLUGIN_ROOT}/skills/cli-interactive/lib/cli-interactive.sh"
. "${CLAUDE_PLUGIN_ROOT}/skills/checkpoint/lib/checkpoint.sh"
SCOPE="$(checkpoint_load_scope)"                # reuse a saved scope, or "all"
[ "$SCOPE" = "all" ] || echo "[checkpoint] reusing saved audit scope: ${SCOPE}"
if [ "${TOTAL}" -ge 501 ]; then
  echo "estate: ${TOTAL} objects (large path) — pausing to let you scope before spending tokens"
  cli_pause_before_audit "${TOTAL}"             # confirm before a large run
  cli_prompt_exclude_services                   # offer service/region exclusions
  echo "[checkpoint] narrow scope any time with /scoutflo:checkpoint; reset with /scoutflo:checkpoint --reset-scope"
fi
```

The large-path phases then run against the scoped set; the report names anything scoped out.

## Phase 1: Service context and alert-to-service mapping

If `./scoutflo-audits/topology.md` exists, load it. Its service list is your critical-service list and its names are the canonical names in findings, the coverage matrix, and `affected` arrays. If it does not exist, discover services live from workload inventory and alert labels, note in the report that the list was inferred, and suggest `/scoutflo:map-topology`.

Resolve every alert to a service and keep the mapping for the rest of the run:

- An alert's `service` and `namespace` labels map to a topology.md entry. That entry's name is the canonical name everywhere.
- When those labels are missing, fall back to the selectors inside the rule expression (`namespace=`, `deployment=`, `job=`) and record that the mapping was inferred, which is itself input to ALR-007.
- Alerts that resolve to no known service are listed as `unmapped` in the coverage matrix, and the report proposes a topology.md update. Only the mapping skill and you edit that file.

## Phase 2: Reachability (ALR-010)

Verify DNS and API health for the Prometheus and Alertmanager hosts before analyzing routing; a stale ingress record or a moved endpoint produces false routing conclusions downstream. Commands in [references/verification-chain.md](references/verification-chain.md) section 2. If the Alertmanager API is not exposed, use the port-forward path defined there for every Alertmanager API call in later phases and note it in evidence.

## Phase 3: Rule presence (ALR-001)

Two-step discipline, commands in section 3 of the reference:

1. Try the rule names you expect. Missing expected names is name drift, worth recording, not the end of the check.
2. List the live `PrometheusRule` inventory and select the rules that actually own your target alerts by their labels. Never assume legacy names survived; clusters accumulate renames.

Then confirm the selected rules are loaded into Prometheus via `api/v1/rules`. A CRD that exists but never reaches the rules API is a silent gap, usually a `ruleSelector` label mismatch; that is an ALR-001 failure with the rule object named in evidence.

## Phase 4: Config drift across three layers (ALR-002, ALR-003, ALR-009)

Alertmanager config exists in three places that can disagree: the declared objects (`AlertmanagerConfig` CRDs plus the base config, or a plain Secret/ConfigMap), the rendered file on disk (`/etc/alertmanager/config_out/alertmanager.env.yaml` in operator-managed installs), and the running config in memory (`api/v2/status`, `.config.original`). Read all three, redacting secret values, and compare receivers, channels, and the route block. Commands and the redaction filter are in sections 4 and 5 of the reference.

Two rules keep this phase honest:

- Operator-managed installs rename receivers to `<namespace>/<config-name>/<receiver>` and add namespace matchers to routes generated from `AlertmanagerConfig` CRDs. That transformation is expected, not drift.
- Check `alertmanager_config_last_reload_successful` and the reload timestamp. A successful `kubectl apply` with a failed or absent reload means the pod is still running the old config (ALR-003). Any delivery-error log line older than the last successful reload is history; record its exclusion (ALR-009) and never cite it as current failure.

An anonymized worked example of exactly this failure pattern, a receiver drifted live while the repo stayed correct, is in section 11 of the reference.

**ALR-020 (deprecated msteams delivery path).** While reading the rendered receivers, flag any receiver that carries an `msteams_configs` block. Microsoft is retiring the Office 365 connector that integration depends on, and Alertmanager 0.28.0 added `msteamsv2_configs` (adaptive-card Workflows format) as its replacement; the old block still parses but the delivery path is dying, so a receiver still on `msteams_configs` is an at-risk delivery path (medium). The read-only signal is the presence of the `msteams_configs:` key in `config.original`; the fix is migrating that receiver to `msteamsv2_configs`.

## Phase 5: Active alerts and route matching (ALR-004, ALR-011)

Query `api/v2/alerts` and capture, for every active alert: name, namespace, severity, and the receiver Alertmanager resolved it to. The resolved receiver is the strongest matcher proof available, because it is what the route tree did, not what it should do. Commands in sections 6 and 7 of the reference.

Then compare three sets:

1. Firing-alert namespace distribution (from Prometheus `ALERTS`) against route matcher scope. A namespace that fires alerts but is covered by no matcher lands on the default route; if the default receiver is null or unwatched, that namespace pages nobody (ALR-004).
2. topology.md against matcher coverage: every namespace and service topology.md names must be covered by a matcher or by a deliberate, stated default-route decision. Uncovered topology services are an ALR-004 finding with each service named in `affected`.
3. Alerts firing longer than `LONG_FIRING_HOURS` (example value, tune to your environment) against the receivers they resolve to. Unrelated long-firing alerts sharing a paging receiver bury real pages (ALR-011).

**ALR-019 (le/quantile matcher normalization — a silent-correctness trap on Prometheus 3.x).** Prometheus 3.0 normalizes the values of the `le` label (classic histograms) and the `quantile` label (summaries) to a float representation on ingestion: a series formerly carrying `le="1"` now carries `le="1.0"`. Any Alertmanager route matcher or inhibition matcher that pins one of these labels to an integer-looking value silently stops selecting those series after the upgrade, so a route that used to catch the alert now sends it to the default route and an inhibition that used to suppress a downstream alert no longer fires. Scan the rendered `config.original` route tree (`match`, `matchers`) and every `inhibit_rule` (`equal`, `source_matchers`, `target_matchers`) for `le` or `quantile` pinned to a bare integer — the read-only signal is a matcher value matching `^(le|quantile)\s*=~?\s*"?\d+"?$` with no decimal point. On a Prometheus-3.x target that is an ALR-019 finding (high): rewrite the matcher to the normalized value (`le="1.0"`) or a decimal-tolerant regex. Gate this on the target's Prometheus major version (read from `api/v1/status/buildinfo`); on 2.x the integer form still matches, so report it as not-in-scope with the detected version rather than a fail. Note also that Alertmanager's UTF-8 strict matcher mode is still opt-in (fallback mode is the default through 0.33.x), so a regex matcher whose value contains a literal `.` (`le=~"1.0"`) is under-anchored — the `.` matches any character and should be escaped (`le=~"1\.0"`); flag that as the same finding's secondary note, not a separate check.

## Phase 6: Dispatch proof and receiver liveness (ALR-005, ALR-006)

Query `alertmanager_notifications_total` and `alertmanager_notifications_failed_total` grouped by integration and by receiver, both lifetime and as `increase()` over `RECENT_WINDOW` (example value, tune to your alert volume). Commands in section 8 of the reference. Verdicts:

- Failure counters above zero inside the recent window: delivery is breaking right now (ALR-005). Group by `reason` where your Alertmanager version exposes it.
- The receiver your routes point at flat at zero while another receiver climbs: an integration or route mismatch (ALR-006), and the classic shape of a silent migration gone wrong.
- A receiver with no traffic and no firing alerts routed to it is unproven: status `configured`, never `pass`.
- Classify receivers from the redacted config: a null receiver or a placeholder host class (loopback, `example.com`) on any route that paging severities can reach is an ALR-002 finding at critical.

State plainly in the report which link was proven: dispatch attempted, accepted downstream, or neither. Human receipt is beyond read-only reach; the controlled test that proves it lives in the setup lane.

## Phase 7: Triage metadata quality (ALR-007, ALR-008)

A firing alert that reaches a human with only a name is a page that starts an investigation from zero. Check every paging-severity rule against a metadata contract: identity labels (`severity`, `service`, `namespace`, `environment`), a `summary` and `impact` a responder can read, and machine-actionable next steps: the exact metric query that confirms the condition, the exact workload scope to inspect, the error-tracker query if you run one, and a one-line handoff order. `environment` matters as its own labeled identity, not an inferred one: an alert whose environment can't be read off its own labels makes prod-vs-staging blast-radius reasoning impossible during triage, even when every other label is correct. The full contract, the check command, and the neutral-naming rule (annotation keys are the toolkit's example convention; map them to whatever identities your own runbooks or agent tooling consume) are in section 9 of the reference.

Two deeper checks:

- Run each rule's confirmation-query annotation against Prometheus. A triage query that returns nothing is a dead handoff, and an app-metric query against telemetry that does not exist fails here too; prefer kube-state and kubelet signals when app metrics are absent.
- If annotations claim an error-tracker handoff, verify the named project and query with a read-only API call using `SENTRY_TOKEN` (section 10 of the reference). A DSN in a workload secret proves the SDK was configured once, not that issues arrive (ALR-008). The full error-tracking audit is `/scoutflo:audit-sentry`.

Then render the Scoutflo Topology Readiness section per [topology-readiness.md](../../report-standard/topology-readiness.md): evaluate T1 to T6 per critical service from `./scoutflo-audits/topology-export.json`, read-only. An edge this audit verified live (for example a `MONITORED_BY` edge to an Alertmanager receiver Phase 6 confirmed actually dispatches, not just a configured route) counts toward T6. Gaps that map to an existing finding reference its ID; gaps with no finding get a `TOPO-` row pointing at `/scoutflo:map-topology`. Render check names and confidence per the standard: plain-English column headers (T-codes only in the legend line), confidence as `n/10`, and — whenever any service is below ready — the ticket-ready sync-readiness action plan table from [topology-readiness.md](../../report-standard/topology-readiness.md). If the export or topology.md is missing, or exists but describes a different target than this audit covers (wrong `cluster_id`, non-overlapping services), the section renders the matching state from topology-readiness.md with its one-line unlock (run `/scoutflo:map-topology` against the right estate, or hand-author the export per `scoutflo-export.md` for non-Kubernetes estates); it never guesses and never says a bare "unavailable". Readiness is reported, never folded into the 0-100 score.

## Phase 8: Alert hygiene (ALR-012 to ALR-018)

The prior phases prove a page can reach a human. This phase asks the opposite: is the volume and quality of what reaches them sustainable, or has the alert stream become noise that buries the real page? Every check here is read-only and reuses data the earlier phases already reach — the range-query form of the `ALERTS` series, the notification counters, and the rendered Alertmanager config. Full commands are in [references/verification-chain.md](references/verification-chain.md) section 13.

Honest ceiling, stated in the report every run:

- These are **structural** noise signals (flapping, stuck-firing, missing debounce, missing grouping), not an alert-to-incident actionability rate. This audit has no incident feed, so it never reports a fabricated "N% of alerts are actionable" number; it reports which rules and config are structurally noisy.
- Alertmanager keeps no alert history. The flapping and volume windows come from Prometheus retention of the `ALERTS` series and the continuity of the `alertmanager_notifications_total` counter (a pod restart truncates it). Report the effective lookback the run actually had, not the one requested.
- Flapping faster than the scrape or query step is invisible; a clean result at a five-minute step is not proof there is no sub-five-minute flapping. Say so.

Checks:

- **ALR-012 (flapping / churn).** Reconstruct each rule's firing episodes from a `query_range` over `ALERTS{alertstate="firing"}` across `LOOKBACK`. A paging-severity rule with more than `FLAP_EPISODES` (example value, tune it) firing episodes and `keepFiringFor == 0` on its definition is a strobe with no damping — it trains responders to ignore it.
- **ALR-013 (permanently-firing / stale silences).** The same range read gives each rule's firing fraction; a paging rule firing more than `STUCK_FRACTION` of the window (example value) is always-on wallpaper. Also read `GET /api/v2/silences`: a silence with a very long or effectively permanent `endsAt` is hiding real alerts, not managing noise — flag it with its matcher and `createdBy`.
- **ALR-014 (missing `for`).** `GET /api/v1/rules` carries `duration` per rule. A paging-severity rule with `duration == 0` fires on a single scrape blip that may self-correct before anyone looks. A `for` matched to the signal's volatility is the fix.
- **ALR-015 (volume concentration).** Rank rules by notification volume: `increase(alertmanager_notifications_total[LOOKBACK])` by receiver, and `count_over_time(ALERTS{alertstate="firing"}[LOOKBACK])` by alertname. When a few rules generate the bulk of a paging receiver's traffic, name them — they are the highest-leverage tuning targets. A very short `route.repeat_interval` on a paging route is a re-page storm and belongs here too.
- **ALR-016 (grouping and inhibition).** From the rendered config (`config.original`), a paging route with no meaningful `group_by` pages once per alert during a broad outage. Note the semantics exactly: an absent `group_by` **and** the special value `['...']` both defeat aggregation — `['...']` means "group by every label", which yields one group per distinct alert, the opposite of grouping. At least one `inhibit_rule` should suppress the redundant downstream alerts a single root cause fans out into.
- **ALR-017 (duplicate delivery / dedup health).** A route with `continue: true` that reaches more than one paging receiver delivers the same alert twice. And Alertmanager's own dedup only holds while its HA cluster is healthy — `GET /api/v2/status` `cluster.status` must be `ready` with the expected peer count; a split-brain cluster re-introduces the duplicates dedup exists to remove.
- **ALR-018 (resolve-noise).** A paging receiver with `send_resolved: true` emits two notifications per incident — the fire and the resolve — roughly doubling its volume. That is often deliberate, so this is `info` unless the resolved traffic is materially inflating a receiver already flagged by ALR-015, where it rises to `medium`. The global `resolve_timeout` (default 5m) governs how quickly an alert with no explicit resolve is considered cleared.

Per-rule hygiene (ALR-012, ALR-014) batches with the same alert-rule worklist as Phase 3 and Phase 7 on the large path; the config and counter reads (ALR-015 to ALR-018) are single cheap calls done once per run. As everywhere in this audit, a `401`/`403` on any read here is an auth-scope finding that blocks the check, never a passing or "clean" result.

## Phase 9: Score, write, brief

Score per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md): each check yields `pass` (1.0), `partial` (0.5), `fail`/`blocked` (0), with `not-in-scope` removed from the denominator; category score is the credit ratio times 100, rounded down; overall is the weight-normalized sum over included categories. Whole categories that could not be assessed are excluded, renormalized, and stated. Score conservatively: when unsure between two results, pick the lower and say why.

- ❌ `Scored ALR-005 fail: "the expected receiver stayed flat at zero" (the query actually 403'd; the audit never saw a real counter value).`
- ✅ `Marked ALR-005 blocked, not fail: the query returned 403 on a missing token scope, so dispatch was never actually observed either way. Per the scoring model a blocked check still scores 0 unless the whole Dispatch proof category is blocked, but the finding text and remediation point at the token, not at the receiver, so the fix effort lands in the right place.`

Coverage matrix, one row per critical service:

| Service | Ready | Rule | Route | Dispatch | Metadata | Owner | Gap |
| --- | --- | --- | --- | --- | --- | --- | --- |
| checkout | 3/4 | pass | pass | pass | partial | Known | no confirmation query on 2 rules |

End-to-end gate: claim end-to-end only when the overall score is at or above 85, every critical service passes every applicable row, and no category was excluded. Below the gate, write "good base coverage", never "end to end".

Emit and verify:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/alert-routing/${RUN_DATE}"
mkdir -p "$OUT"
# ... write findings.json, inventory.json, and report.md per the report standard, then verify:
jq -e '.schema == "scoutflo-findings/v1" and (.findings | type == "array")' \
  "$OUT/findings.json" >/dev/null && echo "findings.json valid"
grep -q '^# ' "$OUT/report.md" && echo "report.md present"
# Output conformance: the emitted report.md must match report-standard/report-template.md.
# This catches header/score-line/section drift before the run is declared done.
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-findings.sh" "$OUT/findings.json"
# Inventory (scoutflo-inventory/v1): the complete Phase-1 catalog of what exists,
# built from the raw pull (never invented, redacted). counts.total must reconcile
# with items; the ## Inventory section of report.md IS this render.
jq -e '.schema == "scoutflo-inventory/v1" and (.items | type == "array") and (.counts.total == (.items | length))' "$OUT/inventory.json" >/dev/null && echo "inventory.json valid"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" inventory "$OUT/inventory.json" >/dev/null && echo "inventory section renders"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" html "$OUT/findings.json" "$OUT/report.html" "$(dirname "$OUT")/history.jsonl"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-report.sh" "$OUT/report.md"
ls -l "$OUT"
```

Compute the delta against the previous run date per the [report standard](../../report-standard/README.md); on the first run state "first run, no delta". After the report is written, close with the run-completion message per the report standard ([report-template.md](../../report-standard/report-template.md#run-completion-message-what-the-skill-says-in-chat-when-the-run-finishes)): the one-line score headline, the top fixes by points_recoverable, the **absolute** report path, the OS-specific open command, and the leak-safe share pointer (Slack brief). Then send the Slack brief, titles only, never evidence values:

```bash
set -eu
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/alert-routing/$(date -u +%Y-%m-%d)"
# slack.webhook_env names the webhook variable; skip when unset.
if [ -n "${SCOUTFLO_SLACK_WEBHOOK:-}" ]; then
  OUT_ABS="$(cd "$OUT" && pwd)"   # absolute path: the brief must be openable from anywhere
  TARGET_DIR="$(dirname "$OUT")"
  SCORE="$(jq -r '.score.overall' "$OUT/findings.json")"
  E2E="$(jq -r 'if .score.end_to_end then "end-to-end" else "not end-to-end" end' "$OUT/findings.json")"
  COUNTS="$(jq -r '.severity_counts | "\(.critical) critical, \(.high) high, \(.medium) medium, \(.low) low"' "$OUT/findings.json")"
  TOP="$(jq -r '[.findings[] | "\(.id) \(.title)"] | .[0:5] | join("\n")' "$OUT/findings.json")"
  PREV="$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*-[0-9]*-[0-9]*' | sort | tail -2 | head -1)"
  MOVE=""; DELTA="first run"
  if [ -n "$PREV" ] && [ "$PREV" != "$OUT" ]; then
    MOVE="$(jq -rn --argjson prev "$(jq '.score.overall' "$PREV/findings.json")" --argjson cur "$SCORE" \
      '(($cur - $prev) | if . >= 0 then "(+\(.))" else "(\(.))" end)')"
    DELTA="$(jq -rn --slurpfile p "$PREV/findings.json" --slurpfile c "$OUT/findings.json" '
      [$p[0].findings[].id] as $b | [$c[0].findings[].id] as $n |
      "\(($b - $n) | length) fixed, \(($n - $b) | length) new, \(($n - ($n - $b)) | length) unchanged"')"
  fi
  jq -n --arg head "audit-alert-routing ${RUN_DATE:-$(date -u +%Y-%m-%d)}: ${SCORE}/100${MOVE:+ $MOVE}, ${E2E}. ${COUNTS}." \
        --arg top "$TOP" --arg delta "$DELTA" --arg path "$OUT_ABS/report.md" \
        '{text: ($head + "\nTop findings:\n" + $top + "\nDelta: " + $delta + "\nReport: " + $path)}' \
    | curl -fsS --max-time 10 -H 'Content-Type: application/json' -d @- "$SCOUTFLO_SLACK_WEBHOOK" \
    || echo "Slack brief failed to send; audit result unaffected"
fi
```

When invoked by `audit-all`, skip the Slack brief; the orchestrator
sends exactly one combined message.

Keep `./scoutflo-audits/` out of public version control; reports describe your infrastructure.

### Lifecycle, exemptions, and totals

Before rendering the report:

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

## Metadata Load (v0.1.68+)

This skill reads the optional business-context SSOT to honor your guardrails:

```bash
set -eu
BC_JSON="${HOME}/.scoutflo/business_context.json"      # workspace projection, derived from the SSOT
BC_MD="${HOME}/.scoutflo/business_context.md"          # the SSOT itself (authoritative)
METADATA="${HOME}/.scoutflo/computed_metadata.jsonl"   # per-resource cache from business-context-resolver

# The workspace layer and the per-resource layer load TOGETHER, not either/or.
HAVE_PER_RESOURCE=0; HAVE_WORKSPACE=0
[ -f "$METADATA" ] && jq -e '.' "$METADATA" >/dev/null 2>&1 && HAVE_PER_RESOURCE=1
[ -f "$BC_JSON" ]  && jq -e '.' "$BC_JSON"  >/dev/null 2>&1 && HAVE_WORKSPACE=1
# Workspace source: the derived json, else the markdown SSOT directly (ssot-md fallback).
BC_SRC=""
if [ "$HAVE_WORKSPACE" -eq 1 ]; then BC_SRC="$BC_JSON"; elif [ -f "$BC_MD" ]; then BC_SRC="$BC_MD"; fi
if   [ "$HAVE_PER_RESOURCE" -eq 1 ] && [ "$HAVE_WORKSPACE" -eq 1 ]; then LOAD_METADATA_MODE="per-resource+workspace"
elif [ "$HAVE_PER_RESOURCE" -eq 1 ];                                then LOAD_METADATA_MODE="per-resource"
elif [ "$HAVE_WORKSPACE" -eq 1 ];                                   then LOAD_METADATA_MODE="workspace"
elif [ -n "$BC_SRC" ];                                              then LOAD_METADATA_MODE="ssot-md"
else                                                                     LOAD_METADATA_MODE="none"; fi
echo "metadata mode: $LOAD_METADATA_MODE"

# Load the workspace rules the apply step below honors. All fields optional; absence = neutral default.
if [ "$HAVE_WORKSPACE" -eq 1 ]; then
  ENVIRONMENT="$(jq -r '.environment // "production"' "$BC_JSON" 2>/dev/null || echo production)"
  COST_SENSITIVITY="$(jq -r '.cost_sensitivity // "medium"' "$BC_JSON" 2>/dev/null || echo medium)"
  CRITICAL="$(jq -r '.critical_dependencies[]? // empty' "$BC_JSON" 2>/dev/null || true)"
  EXCLUSIONS="$(jq -r '.exclusions // {} | [.accounts?, .regions?, .services?, .resources?] | add // [] | .[]? // empty' "$BC_JSON" 2>/dev/null || true)"
  jq -r --arg e "$ENVIRONMENT" '.environment_map[]? | select(.environment==$e)' "$BC_JSON" 2>/dev/null || true  # per-env profile/project/context + uptime_sla
  jq -r '.service_slas[]? | "\(.service)=\(.sla)"' "$BC_JSON" 2>/dev/null || true                               # per-service SLA (wins over the env default)
elif [ "$LOAD_METADATA_MODE" = "ssot-md" ]; then
  # Only business_context.md exists (json not derived): read the same rules from the SSOT directly.
  ENVIRONMENT="$(grep -iA5 '^## Environment' "$BC_MD" | grep -iE 'Stage:' | head -1 | sed -E 's/.*Stage:\**[[:space:]]*//; s/[][]//g; s/[[:space:]]*$//' | tr 'A-Z' 'a-z')"; [ -n "$ENVIRONMENT" ] || ENVIRONMENT="production"
  COST_SENSITIVITY="$(grep -iA3 '^## Cost Sensitivity' "$BC_MD" | grep -iE 'Primary:' | head -1 | sed -E 's/.*Primary:\**[[:space:]]*//; s/[][]//g; s/[[:space:]]*$//' | tr 'A-Z' 'a-z')"; [ -n "$COST_SENSITIVITY" ] || COST_SENSITIVITY="medium"
  CRITICAL="$(awk '/^## Critical Services/{f=1;next} /^## /{f=0} f' "$BC_MD" | grep -oE '`[^`]+`' | tr -d '`')"
  EXCLUSIONS="$(awk '/^## Exclusions/{f=1;next} /^## /{f=0} f' "$BC_MD" | grep -oE '`[^`]+`' | tr -d '`')"
fi
# When HAVE_PER_RESOURCE=1, look each finding's affected resource up in computed_metadata.jsonl and let
# its per-resource action/escalation/sla refine (never weaken) the workspace rule for that one resource.
```

When context is available, apply it per [BUSINESS-CONTEXT-INTEGRATION-v0168.md](../../docs/BUSINESS-CONTEXT-INTEGRATION-v0168.md): **exclude** resources matched by an exclusion (record them `not-in-scope` with the reason, never a fail); **escalate** findings on a `critical_dependencies` service; reduce severity for a gap that exists only in a non-production `environment`; and apply `cost_sensitivity` to ordering. With no context, run neutral defaults and say so — never invent a business rule.

## Remediation pointers

Every finding's `remediation` field points at the fix, so "Next safe actions" in the report starts at row 1 with no preparation:

| Finding area | Pointer |
| --- | --- |
| ALR-002, ALR-003: live config drift, stale reload | `setup-lgtm#fix-default-receiver` for receiver repairs; re-applying your declared manifest is a mutation and belongs in the setup lane |
| ALR-004: matcher gaps; ALR-011: receiver flooding | `setup-lgtm#add-severity-routes-and-inhibition` for matcher gaps, `setup-lgtm#quiet-noisy-rules` for receiver flooding; route additions follow the confirm-then-verify setup loop |
| ALR-005, ALR-006: delivery failures, integration mismatch | `setup-lgtm#fix-default-receiver` |
| ALR-001, ALR-007: missing rules, missing triage metadata | `references/verification-chain.md#9-triage-metadata-contract-alr-007`; a dedicated alert-rule setup skill taking these IDs as input is planned |
| ALR-021: loaded rule that errors/overruns | `references/verification-chain.md#141-rule-evaluation-health-alr-021` for the engine-gated evidence; the rule-expression fix belongs to the planned alert-rule setup skill (point at the named rule and its `lastError`) |
| ALR-022: paging alert suppressed live; ALR-023: page delayed/muted | `setup-lgtm#add-severity-routes-and-inhibition` for over-broad inhibit rules and route-timing; an unintended silence expires through the Alertmanager UI (as in ALR-013) |
| ALR-008: unproven error-tracker handoff | `/scoutflo:audit-sentry` to audit the tracker side; `/scoutflo:setup-sentry` to fix it |
| ALR-010: DNS or ingress drift | Fix through your ingress change process, then re-run `/scoutflo:doctor` |
| ALR-012, ALR-014: flapping, missing `for`/`keep_firing_for` | `references/verification-chain.md` section 13 for the target `for` and `keep_firing_for` shapes; the planned alert-rule setup skill takes these IDs as input |
| ALR-013: stuck rules, stale silences | `setup-lgtm#quiet-noisy-rules` for always-on rules; expire the stale silence through your Alertmanager UI |
| ALR-015: volume concentration, short `repeat_interval` | `setup-lgtm#quiet-noisy-rules` for top-talkers; `setup-lgtm#add-severity-routes-and-inhibition` for `repeat_interval` |
| ALR-016: missing grouping or inhibition | `setup-lgtm#add-severity-routes-and-inhibition` |
| ALR-017: duplicate routes, split-brain dedup | `setup-lgtm#add-severity-routes-and-inhibition` for `continue` fan-out; fix HA clustering through your Alertmanager deployment |
| ALR-018: resolve-noise on paging receivers | `setup-lgtm#fix-default-receiver` to set `send_resolved: false` on high-volume paging receivers |

## Common Failure Modes

All windows and thresholds named in this skill (`RECENT_WINDOW`, `LONG_FIRING_HOURS`, `LOG_TAIL`) are example values; tune them to your alert volume before treating a miss as a failure.

| Failure | Prevention |
| --- | --- |
| Repo manifest correct, live cluster drifted | Read the live object, the rendered file, and the running config; never conclude from the manifest alone |
| `kubectl apply` success treated as reload success | Check `alertmanager_config_last_reload_successful` and the reload timestamp after any change |
| Old delivery-error log lines read as current failure | Compare every error timestamp to the last successful reload before concluding |
| Operator receiver-name prefixing flagged as drift | Expect `<namespace>/<config>/<receiver>` naming and auto-added namespace matchers in rendered config |
| Route matcher scope excludes app namespaces | Compare matchers against the live firing-namespace distribution, not against intentions |
| Expected receiver silent while another climbs | Group notification counters by receiver and integration; check `increase()` over a recent window, not lifetime totals |
| Configured receiver counted as working | Zero-traffic receivers stay `configured`; only observed dispatch upgrades them, and test-firing is a setup-lane action |
| Alert rules reference nonexistent app metrics | Run the confirmation query before crediting the rule; prefer kube-state and kubelet signals when app metrics are absent |
| Legacy rule names assumed present | Discover the live PrometheusRule inventory and select rules by owning labels |
| Error-tracker handoff claimed from DSN presence | Require a read of the exact project and query named in the annotation |
| Webhook URLs leaked into evidence | Redact values of keys ending in url, key, token, secret, password; record receiver and channel names only |
| Exec into the monitoring namespace denied | Use the port-forward fallback or the Alertmanager status API; never widen permissions mid-audit |
| Authenticated Prometheus/Alertmanager 401/403 read as "unreachable" or "routing broken" | Attach `Authorization: Bearer` only when `PROM_TOKEN` is non-empty on every call, and treat any `401`/`403` as an auth-scope finding, blocking downstream checks rather than failing them |
| Large rule estate audited with no worklist, run dies partway and restarts from rule 1 | Run the Estate sizing pre-check first; on the large path, scan for a resumable worklist before minting a new run |
