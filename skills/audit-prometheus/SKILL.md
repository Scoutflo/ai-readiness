---
name: audit-prometheus
description: Read-only scored audit of a Prometheus server and its rule-engine plane — scrape-target health and per-service `up` coverage, TSDB cardinality/churn, WAL and compaction integrity, remote-write backlog, config-reload state, and alerting/recording rule health (loaded, error-free, evaluating on time, backed by live metrics, with a reachable Alertmanager); writes findings.json and report.md and changes nothing. Use when the user mentions auditing or scoring a Prometheus server, scrape targets, `up`, TSDB cardinality or head-series churn, WAL/compaction failures, remote-write backlog, config reload, or rule-group evaluation health. Works against any Prometheus-HTTP-API-compatible ruler — Prometheus, Thanos, the Mimir ruler, or vmalert for rules. Do not use for the Grafana application layer (use audit-grafana), for the Loki/Tempo/Mimir/VictoriaMetrics stores or the per-service telemetry-coverage matrix (use audit-lgtm), or to prove an Alertmanager page reaches a human — routing tree, silences, receivers, delivery (use audit-alert-routing).
---

# audit-prometheus

Scored, read-only audit of a **Prometheus server** and the **rule-engine plane** it runs — the scrape loop that collects metrics, the TSDB that stores them, the remote-write queue that ships them onward, and the recording/alerting rules that turn them into signals. It answers one question: when something breaks tonight, is Prometheus actually scraping your critical services, is the data landing in a healthy TSDB, and do the rules that should page still load, evaluate on time, read a metric that is actually being scraped, and have a live Alertmanager to notify?

Every command in this audit is read-only: `GET` calls to the Prometheus HTTP API (`/api/v1/*`, `/-/healthy`, `/-/ready`) and `GET`-only instant queries. It creates, modifies, reloads, or deletes nothing. The destructive admin routes (`POST /api/v1/admin/tsdb/delete_series`, `POST /-/reload`, `POST /-/quit`) are **read about, never called** — this audit reads the flags that reveal whether they are enabled and exposed (PROM-050), it never exercises them. Any change to Prometheus (fixing a rule, adding a scrape target, reloading config) is a remediation you apply by hand from the pointers below — this skill has no setup lane.

This is one of three audits that read the shared `prometheus:` config block, each owning a different plane, so nothing is scored twice:

- **audit-prometheus** (this skill) — the **server + rule-engine** plane: scrape health, TSDB, remote-write, config reload, and whether rules *load, evaluate, and are backed by live metrics*.
- **audit-lgtm** — the **stores** (Loki/Tempo/Mimir cluster internals, VictoriaMetrics service health) and the per-service telemetry-coverage matrix.
- **audit-alert-routing** — the **Alertmanager paging path**: routing tree, receivers, grouping/inhibition/silences, and the live "does a page reach a human" proof.

Run this standalone, from `/scoutflo:audit-all`, or on a schedule via `/scoutflo:schedule-audits`.

**Scope — one shared backend, single block:** `prometheus:` is a shared-backend block (like `loki:`/`tempo:`/`mimir:`), read as a single mapping — one `url`, one optional `token_env`. This audit does **not** iterate labeled targets (a labeled list under `prometheus:` would break doctor, audit-lgtm, and audit-alert-routing, which all read it as one block); it is a documented multi-target exemption alongside those two. Output goes to the flat `prometheus/<date>/`. To audit several Prometheus servers, point `prometheus.url` at each in turn (a separate config file per environment).

Outputs, per the [report standard](../../report-standard/README.md):

- `./scoutflo-audits/prometheus/<YYYY-MM-DD>/findings.json` per the [findings schema](../../report-standard/findings-schema.md)
- `./scoutflo-audits/prometheus/<YYYY-MM-DD>/report.md` per the [report template](../../report-standard/report-template.md), including the `## Inventory` section (the `render-report-viz.sh inventory` output)
- `./scoutflo-audits/prometheus/<YYYY-MM-DD>/inventory.json` per the [inventory schema](../../report-standard/inventory-schema.md) (`scoutflo-inventory/v1`): the complete Phase-2 catalog — one item per scrape `target`, per rule (`alert_rule` / recording rule), and per remote-write queue, built from the raw pull, never invented, redacted at capture.
- One Slack brief, when `slack.webhook_env` is configured

Provenance note: the Prometheus HTTP API surface below (`/api/v1/status/{buildinfo,runtimeinfo,flags,tsdb,config}`, `/api/v1/{targets,rules,alerts,alertmanagers,query}`, `/-/healthy`, `/-/ready`) and the self-metric names (`prometheus_*`, `prometheus_tsdb_*`, `prometheus_remote_storage_*`, `prometheus_rule_*`, `prometheus_notifications_*`) are the **stable, documented Prometheus 2.x/3.x API**; the rule-health and target reads were **confirmed on live reads** as part of audit-lgtm/audit-alert-routing (`/api/v1/rules`, `/api/v1/targets`, `time() - timestamp(up)`). The exact self-metric availability varies by build and configuration (a pure local-TSDB Prometheus exposes no `prometheus_remote_storage_*`; a Mimir ruler or vmalert exposes a different rule-metric set) — resolve which self-metrics exist this run, never assume one; a metric that does not exist marks its check `not-in-scope`, never a fail.

## Doctor gate

Requirements. Configure the `prometheus:` block only if you run Prometheus; delete it from `~/.scoutflo/toolkit.yaml` otherwise.

| Integration | toolkit.yaml keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| Prometheus | `prometheus.url` (`http(s)://your-prometheus-host:9090`, no trailing slash) | `prometheus.token_env` (the variable named there — e.g. `PROM_TOKEN`) — **only** if the endpoint sits behind an auth proxy | read the HTTP API: `GET /api/v1/*`. Prometheus has no native authz; if it answers without credentials, reachability is the whole setup | read-only |
| Slack (optional) | `slack.webhook_env` | webhook variable | post to one channel | n/a |

Prometheus and its HTTP API most often answer with **no** credentials. If yours is reachable without auth, `token_env` stays unset and every call sends `Accept: application/json`. If it sits behind an auth proxy that wants a bearer token, set `token_env` and the audit sends `Authorization: Bearer <token>` on every call. Prefer reaching Prometheus over a private network or a `kubectl port-forward` rather than a public ingress (an unauthenticated public Prometheus is itself PROM-051).

Preflight. A failed check stops the audit with the exact failure and the fix (usually `/scoutflo:connect`). Never downgrade a doctor failure into a finding.

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
# sets *_env variables; no secret value is printed. This mirrors /scoutflo:doctor, so
# doctor and this audit agree on what is configured (env-load parity).
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
command -v curl >/dev/null || { echo "curl not installed"; exit 1; }
command -v jq   >/dev/null || { echo "jq not installed"; exit 1; }

# Resolve the shared prometheus block via the shared enumerator (single mapping = target 0; this audit
# never iterates labels — it is a shared-backend exemption). The url + the token_env VARIABLE NAME come
# from the block; the token value is read from the store with printenv, presence only, never printed.
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
PROM_N=$(sh "$TT" "$CFG" prometheus count)
if [ "${PROM_N:-0}" -lt 1 ]; then
  echo "prometheus block not configured in toolkit.yaml; this audit has nothing to read — add a prometheus.url via /scoutflo:connect or run a different audit"; exit 1
fi
PROM_URL=$(sh "$TT" "$CFG" prometheus get 0 url); PROM_URL="${PROM_URL%/}"
if [ -z "$PROM_URL" ]; then
  echo "prometheus.url is empty (only alertmanager_url set?) — audit-prometheus needs the Prometheus API URL; the Alertmanager plane is audited by /scoutflo:audit-alert-routing"; exit 1
fi
PROM_TOKEN_VAR=$(sh "$TT" "$CFG" prometheus get 0 token_env)
PROM_TOKEN=""; [ -n "$PROM_TOKEN_VAR" ] && PROM_TOKEN=$(printenv "$PROM_TOKEN_VAR" 2>/dev/null || true)
if [ -n "$PROM_TOKEN_VAR" ] && [ -z "$PROM_TOKEN" ]; then
  echo "prometheus.token_env names ${PROM_TOKEN_VAR} but that variable is not set in ${SCOUTFLO_ENV}; add it via /scoutflo:connect (the audit will not send an empty Bearer header)"; exit 1
fi
AUTH="Authorization: Bearer ${PROM_TOKEN}"; [ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"
echo "prometheus target: ${PROM_URL}"

# One cheap authed live call: vector(1) tests the API, not the fleet (it succeeds on a server with zero
# targets). Assert the JSON envelope so a 200 HTML SSO/proxy/login page fails CLOSED, never false-greens.
HB="$(mktemp)"
META=$(curl -s -o "$HB" -w '%{http_code} %{content_type}' --max-time 15 -H "$AUTH" \
  --get --data-urlencode 'query=vector(1)' "${PROM_URL}/api/v1/query") || META="000 -"
CODE="${META%% *}"; CT="${META#* }"
if [ "$CODE" = "401" ] || [ "$CODE" = "403" ]; then
  echo "Prometheus API returned ${CODE} — the endpoint is behind auth. Set prometheus.token_env (and export it) via /scoutflo:connect, then rerun. This is an auth problem, not a finding."; rm -f "$HB"; exit 1
elif [ "$CODE" = "200" ] && printf '%s' "$CT" | grep -qi json && jq -e '.status=="success"' "$HB" >/dev/null 2>&1; then
  echo "Prometheus API reachable (GET /api/v1/query?query=vector(1) -> 200 JSON, status=success)"
else
  echo "Prometheus API not usable: status=${CODE}, content-type='${CT}'. A 200 with an HTML body is an SSO/reverse-proxy/login page in front of the API (fails closed), not a working Prometheus — point prometheus.url at the API itself (or the proxy that forwards /api/v1). Fix before scoring."; rm -f "$HB"; exit 1
fi
rm -f "$HB"
```

Then one more cheap live call per plane that the phases below depend on — `GET /-/healthy` (200) and `GET /api/v1/status/buildinfo` (the version string). Exact commands are in [references/prometheus-checks.md](references/prometheus-checks.md) section 1. `/scoutflo:doctor` runs the same `vector(1)` probe standalone.

## Live-safety gate

Before the first real read, print exactly what you are pointed at and compare it to the config. Print host and URL only — never the token:

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
PROM_URL=$(sh "$TT" "$CFG" prometheus get 0 url); PROM_URL="${PROM_URL%/}"   # prometheus.url
PROM_TOKEN_VAR=$(sh "$TT" "$CFG" prometheus get 0 token_env)                 # prometheus.token_env (name only)
echo "Prometheus API : ${PROM_URL}  (auth: $([ -n "$PROM_TOKEN_VAR" ] && echo "Bearer via ${PROM_TOKEN_VAR}" || echo none))"
# Confirm this is the Prometheus you intend to audit before any read.
case "$PROM_URL" in
  https://*)            : ;;
  http://127.0.0.1*|http://localhost*) echo "note: plaintext http to a loopback/port-forward endpoint — expected, not a TLS finding" ;;
  http://*)             echo "WARN: Prometheus API is plaintext http on a non-loopback host — see PROM-051" ;;
esac
```

If the resolved URL differs from what `toolkit.yaml` names, stop and report the mismatch. Never proceed on "probably the right instance". Every command in this skill (and in [references/prometheus-checks.md](references/prometheus-checks.md)) names its target explicitly: reads go through the `pq` helper — `curl --get` against `${PROM_URL}/api/v1/...` with the `AUTH` header resolved once (Bearer when `token_env` is set, else `Accept: application/json`).

## Ground rules

- Config records are discovery metadata; a live query is proof. Credit nothing you did not read live this run.
- Evidence is real command output. An assertion without the query and its observed rows is a suspicion, not a finding.
- API errors are evidence. A `401`/`403` on `/api/v1/*` means the endpoint is behind auth and `token_env` is missing or wrong — an auth-scope problem, never "the rules failed to load" or "the fleet is down". A `200` with an HTML body is a proxy/login page (fail closed). Never convert an upstream error into empty success.
- Never score from object counts. Four hundred rules and a thousand targets prove nothing; credit comes from signal a responder could act on — a critical service actually `up` and fresh, a paging rule that evaluates without error and reads a metric that exists.
- A target that exists is not coverage. A `job` present in `/api/v1/targets` with `health="down"` (or `up`-but-stale samples) is a gap, not a pass — a stale target makes dashboards and rules read the last-scraped value and look alive while the pod may be dead.
- A rule that is loaded is not a working alert. A rule with a non-empty `lastError`, or one whose backing metric stopped being scraped (evaluates to no-data forever), or one whose group evaluates slower than its interval, is the core failure this audit exists to catch (PROM-020/021/022); "a rule exists" is `configured`, not working.
- The Alertmanager notify path is this audit's boundary: PROM-023 proves Prometheus *has a live Alertmanager to send to and is not dropping notifications*. Whether a page then routes to the right human — the routing tree, silences, receivers, delivery — is `/scoutflo:audit-alert-routing`. Do not re-score routing here.
- Never print, log, or write a secret: no bearer tokens, auth headers, or webhook URLs, in terminal output or in any output file. A scrape target's `scrapeUrl` or a remote-write queue URL can embed credentials — record host/job/class only, never a full URL with userinfo.

## Metadata Load

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

When context is available, apply it per [BUSINESS-CONTEXT-INTEGRATION-v0168.md](../../docs/BUSINESS-CONTEXT-INTEGRATION-v0168.md): **exclude** a service/job matched by an exclusion (record it `not-in-scope` with the reason, never a fail — a deliberately-unmonitored dev job is not a coverage gap); **escalate** a scrape gap (PROM-011), a dead rule (PROM-020/022), or a stalled remote-write (PROM-040) on a `critical_dependencies` service; **reduce severity** for a gap that exists only in a non-production `environment` (a high-cardinality label on a dev Prometheus is not a prod cost gap); and apply `cost_sensitivity` to the ordering of the cardinality (PROM-030/032) and remote-write findings. With no context, run neutral defaults and say so — never invent a business rule.

## Phase 1: Service context

If `./scoutflo-audits/topology.md` exists, load it. Its service list is your critical-service list and its names are canonical in findings, the coverage matrix, and `affected` arrays. If it does not exist, discover the scraped services live from Prometheus itself (`GET /api/v1/label/job/values`, and the distinct `job`/`service` labels on `up`), note in the report that the list was inferred, and suggest `/scoutflo:map-topology`.

## Estate sizing

Count before judging, and declare the path in the terminal output. This count sizes how much ceremony the run uses; it never feeds the score itself. The objects that drive this audit's cost are the scrape targets (each contributes to the coverage matrix) and the rule groups (each gets a health + backing-metric check). Server-level checks (config reload, TSDB, remote-write, security) run once regardless of estate size.

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
PROM_URL=$(sh "$TT" "$CFG" prometheus get 0 url); PROM_URL="${PROM_URL%/}"
PROM_TOKEN_VAR=$(sh "$TT" "$CFG" prometheus get 0 token_env); PROM_TOKEN=""; [ -n "$PROM_TOKEN_VAR" ] && PROM_TOKEN=$(printenv "$PROM_TOKEN_VAR" 2>/dev/null || true)
AUTH="Authorization: Bearer ${PROM_TOKEN}"; [ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"
SMALL_MAX_OBJECTS="100"    # example, tune to your environment
MEDIUM_MAX_OBJECTS="500"   # example, tune to your environment
# Active scrape targets (guard the fetch: an auth failure must surface, not silently count as zero).
TARGETS=0
if ! TARGETS="$(curl -fsS --max-time 15 -H "$AUTH" "${PROM_URL}/api/v1/targets?state=active" | jq '.data.activeTargets | length' 2>/dev/null)"; then
  echo "WARN: GET /api/v1/targets failed — target count unknown; estate sizing is a floor, not the truth."; TARGETS=0
fi
# Loaded rules (alerting + recording).
RULES=0
if ! RULES="$(curl -fsS --max-time 15 -H "$AUTH" "${PROM_URL}/api/v1/rules" | jq '[.data.groups[].rules[]] | length' 2>/dev/null)"; then
  echo "WARN: GET /api/v1/rules failed — rule count unknown."; RULES=0
fi
TOTAL=$((TARGETS + RULES))
path="large"
[ "${TOTAL}" -le "${MEDIUM_MAX_OBJECTS}" ] && path="medium"
[ "${TOTAL}" -le "${SMALL_MAX_OBJECTS}" ] && path="small"
echo "estate: scrape_targets=${TARGETS} rules=${RULES} scored_objects=${TOTAL} sizing-path=${path}"
```

Record `estate: {objects: TOTAL, path: path}` in `findings.json` per the [findings schema](../../report-standard/findings-schema.md). Never silently truncate a large estate: if the run judged a subset, the report names what was skipped and the coverage denominators reflect it.

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
  cli_prompt_exclude_services                   # offer service exclusions
  echo "[checkpoint] narrow scope any time with /scoutflo:checkpoint; reset with /scoutflo:checkpoint --reset-scope"
fi
```

The large-path phases then run against the scoped set, batched against a durable worklist per [Large-path worklist](#large-path-worklist); the report names anything scoped out.

### Empty / hidden-scope guardrail (PROM-007)

The scope checkpoint narrows a *large* estate. This guardrail catches the opposite and more dangerous case — a Prometheus that looks **healthy-but-empty** because you cannot see the data, not because it is not there. After the inventory reads (Phase 2), evaluate:

```bash
set -eu
# Set from the Phase-2 reads.
ACTIVE_TARGETS="${ACTIVE_TARGETS:-0}"   # count of active scrape targets
UP_SERIES="${UP_SERIES:-0}"             # count of series returned by the `up` query
RULE_COUNT="${RULE_COUNT:-0}"           # count of loaded rules
PROM_REACHABLE="${PROM_REACHABLE:-1}"   # 1 = vector(1) succeeded this run
if [ "${PROM_REACHABLE}" -eq 1 ] && [ "${ACTIVE_TARGETS}" -eq 0 ] && [ "${UP_SERIES}" -eq 0 ]; then
  echo "[guard] Prometheus is reachable but has ZERO active scrape targets and up returns zero series — visibility/config gap, NOT a confident 0 (PROM-007)"
  echo "[guard] scrape config may be empty, service discovery broken, or this is a query-only frontend (Thanos/Mimir query) with no local scrape; confirm before scoring coverage as failed"
fi
if [ "${RULE_COUNT}" -eq 0 ]; then
  echo "[guard] Prometheus is reachable but has ZERO loaded rules — no rule plane to score; PROM-020/021/022/023 not-in-scope (this may be a scrape-only Prometheus with rules elsewhere)"
fi
```

Behavior this enforces:

- **Reachable Prometheus, zero targets and zero `up` series:** do **not** score PROM-010 (target health), PROM-011 (coverage/freshness), and PROM-012 (scrape-config limits) as a confident `0/100`, and do not score them a vacuous high from an empty set — note PROM-012's `..._exceeded_*_total` counters return empty with zero targets, which is *not* a clean pass. Mark **all three** `blocked` with the visibility-gap reason so the entire weight-20 "Scrape targets and coverage" category is unassessable and drops out on renormalization (leaving one member scoreable would let PROM-012 register a vacuous coverage sub-score — exactly the empty-set inflation this guardrail exists to prevent). **Keep TSDB health (PROM-030/031/032) and Security posture (PROM-050/051) included** (they read the server, not the fleet), renormalize per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md), and emit **PROM-007** naming the gap (empty scrape config / broken service discovery / a query-only frontend) and the fix. Keeping server-plane categories included means at least one scored category always remains, which `check-findings.sh` requires.
- **Zero loaded rules:** mark the whole rule-engine category (PROM-020/021/022/023) `not-in-scope` with the reason — a scrape-only Prometheus with rules run elsewhere is a real topology, not a confident zero — and renormalize.
- **No remote-write self-metrics** (a pure local-TSDB Prometheus): mark PROM-040 `not-in-scope`, renormalize; never a fail.
- **Never** write a confident `0/100`, a vacuously-high score, or an end-to-end claim on a tripped guardrail.

## Phase 2: Read-only inventory

Build the raw picture before judging anything. Commands are in [references/prometheus-checks.md](references/prometheus-checks.md) (the `pq` helper in section 1; the per-surface reads in sections 3–8); capture into the run's `raw/` directory, redacted.

- **Server:** `GET /-/healthy`, `GET /api/v1/status/buildinfo` (version), `GET /api/v1/status/runtimeinfo` (storage retention, corruption count, goroutines), `GET /api/v1/status/flags` (retention, admin/lifecycle flags), `GET /api/v1/status/config` (the loaded config YAML — reload state).
- **Scrape targets:** `GET /api/v1/targets?state=active` — one item per target: `scrapePool`, `labels.job`, `health`, `lastError`, `lastScrape`, `scrapeUrl` (host/job/class only — never a full URL with userinfo).
- **Rules:** `GET /api/v1/rules` — groups[].rules[] with `type` (recording/alerting), `name`, `health`, `lastError`, `evaluationTime`, `lastEvaluation`, `state`, `query`; group `interval`, `evaluationTime`.
- **Notify path:** `GET /api/v1/alertmanagers` — activeAlertmanagers / droppedAlertmanagers.
- **TSDB:** `GET /api/v1/status/tsdb` — headStats (numSeries, chunkCount, minTime, maxTime), seriesCountByMetricName, labelValueCountByLabelName, seriesCountByLabelValuePair.

Record what exists (targets, rules, alertmanagers, TSDB head stats) as inventory, not yet as findings. This is the raw pull that both `findings.json` and `inventory.json` derive from — no new live calls later.

## Phase 3: Tool ownership boundary

Prometheus owns the metrics **collection and rule-evaluation** plane. It does **not** own the store internals of Loki/Tempo/Mimir/VictoriaMetrics (that is `/scoutflo:audit-lgtm`), the Grafana dashboards/datasources it feeds (`/scoutflo:audit-grafana`), or the Alertmanager routing/delivery tree it notifies (`/scoutflo:audit-alert-routing`). A signal absent from Prometheus because another tool owns it is a boundary decision, not a gap; record the boundary and audit the owning stack.

## Phase 4: Server reachability and config reload (PROM-001, PROM-002, PROM-003)

Commands in [references/prometheus-checks.md](references/prometheus-checks.md) section 3.

- **PROM-001 (reachable and healthy):** `GET /-/healthy` is 200, `vector(1)` returns `status=success`, `buildinfo` returns a version. PROM-001 down is the root of a cascade, not a yes/no: when Prometheus is unreachable, every rule it loads evaluates to no-data and pages nothing, and every service it scrapes is unmonitored — state the blast radius (the count of rules and critical services that go dark), then treat it as an availability incident.
- **PROM-002 (config reload succeeded):** query `prometheus_config_last_reload_successful` — a `0` means the last attempted config reload **failed**, so the running config is the last-good one and every change since (new rules, new targets, new remote-write) is silently not applied. Read `prometheus_config_last_reload_success_timestamp_seconds` for how long it has been stale. A failed reload is a high finding: the operator believes a change is live when it is not.
- **PROM-003 (runtime and retention posture):** `runtimeinfo` (`storageRetention`, `corruptionCount`) and `flags` (`--storage.tsdb.retention.time`/`.size`) — record the retention window and flag a non-zero `corruptionCount` (feeds PROM-031). A retention far shorter than the team's stated need is a data-availability posture note.

## Phase 5: Scrape health and coverage (PROM-010, PROM-011, PROM-012)

For each critical service from Phase 1, and across all targets, query the confirmed reads (commands in section 4):

- **PROM-010 (targets healthy):** `GET /api/v1/targets?state=active` — group `health != "up"` by `scrapePool`/`job` with the `lastError`. A down target's data goes **stale, not absent**: dashboards and rules read the last-scraped value and look alive while the pod may be dead. Name the affected job/service in `affected`; a saturation or error on a down target is invisible until scrape resumes.
- **PROM-011 (coverage + freshness):** `up` per critical-service job must be present and `== 1`; `time() - timestamp(up)` gives the real per-target sample age. A critical service with no `up` target at all (zero series) is a coverage gap; a target that is `up == 1` but whose newest sample is minutes old is an **ingestion-lag** gap (every rule with `for: Nm` on it pages ~N+lag late) — distinct from PROM-010, and the computed delay *is* the blast radius. Zero `up` series everywhere routes to PROM-007, not a confident PROM-011 fail.
- **PROM-012 (scrape-config limits):** `increase(...[1h]) > 0` on `prometheus_target_scrapes_exceeded_sample_limit_total`, `prometheus_target_scrape_pool_exceeded_target_limit_total`, `prometheus_target_scrapes_exceeded_body_size_limit_total`, `prometheus_target_scrapes_sample_out_of_order_total`. A target hitting its `sample_limit` has series **silently dropped** — the target reads `up == 1` (PROM-010/011 pass) while data is thrown away. These are **global** counters (labelled by the Prometheus instance, not the scraped job), so a non-zero value means at least one target breached that limit in the window — name the limit that fired and cross-reference which scrape configs set a `sample_limit`/`target_limit`/`body_size_limit` to find the culprit job (this counter alone cannot name it).

## Phase 6: Rule-engine health (PROM-020, PROM-021, PROM-022, PROM-023) — flagship

This is the plane no scanner assembles into one verdict. Via `GET /api/v1/rules`, `/api/v1/alertmanagers`, and the rule self-metrics (commands in section 5). Detect the engine first (Prometheus vs vmalert vs Mimir ruler) — the self-metric names differ, and an empty self-metric result **on the wrong engine** is `not observable`, never `healthy`.

- **PROM-020 (rules load and evaluate error-free):** rules with `health != "ok"` or a non-empty `lastError` have fired zero times and never will until the expression is fixed. For each, resolve `.name`/`.labels`/`.query` to a topology service, read `.labels.severity`, and use `.lastEvaluation` to say how long it has been broken — "`HighErrorRate{service=checkout}` severity=page has carried a PromQL parse error for 3 days; a spike tonight fires nothing." Blast radius is the count of paging rules broken and the critical services thereby left with a dead rule.
- **PROM-021 (rules evaluate on time):** a rule group whose `evaluationTime` exceeds its `interval` (confirm with `prometheus_rule_group_last_duration_seconds > prometheus_rule_group_interval_seconds`, and `increase(prometheus_rule_evaluation_failures_total[1h]) > 0`) evaluates late and can skip windows — an SLO burn-rate page with no `lastError` (PROM-020 passes) can still be silently late here. Name the group and the over-interval margin.
- **PROM-022 (rules are backed by live metrics — the correlation flagship):** a loaded, error-free alerting rule whose backing metric stopped being scraped evaluates to **no-data forever and pages nobody** — the one failure that looks fine in `/api/v1/rules` (health=ok) and fine in `/api/v1/targets`, but is dead. For a sample of alerting rules (all `severity=page`/critical-service ones), extract the metric names from `.query` and confirm each returns data now (`count(<metric>) > 0`) and is fresh. Also record **rule presence**: an expected paging rule for a critical service that does not exist at all (ALR-001 lineage) is a PROM-022 gap. This chains PROM-011 (the metric's scrape) → PROM-020 (the rule's health) → PROM-023 (its notify path).
- **PROM-023 (the notify path is live):** `GET /api/v1/alertmanagers` must list at least one **active** Alertmanager (Prometheus has somewhere to send), and `increase(prometheus_notifications_dropped_total[1h])` must be `0` with `prometheus_notifications_queue_length` well below capacity — a rule can fire and still page nobody if Prometheus has no Alertmanager configured or is dropping notifications. This is the **seam**: PROM-023 proves the Prometheus→Alertmanager hop exists and is not dropping; the routing tree, silences, receivers, and delivery to a human are `/scoutflo:audit-alert-routing`. If no alerting rules and no Alertmanager are configured, PROM-023 is `not-in-scope`, not a fail.

## Phase 7: TSDB cardinality and storage (PROM-030, PROM-031, PROM-032)

From `GET /api/v1/status/tsdb` and the `prometheus_tsdb_*` self-metrics (commands in section 6):

- **PROM-030 (cardinality):** `status/tsdb` returns `seriesCountByMetricName` (top metrics by series), `labelValueCountByLabelName` (top labels by distinct value count), and `seriesCountByLabelValuePair`. A label with a runaway distinct-value count driven by IDs, emails, session tokens, or full URLs is the classic cardinality/cost gap — it bloats the head, slows every query, and inflates remote-write. Name the metric or label and its series count; apply `cost_sensitivity` to ordering.
- **PROM-031 (WAL and compaction integrity):** `prometheus_tsdb_wal_corruptions_total > 0`, `increase(prometheus_tsdb_compactions_failed_total[...]) > 0`, `prometheus_tsdb_head_truncations_failed_total`, `prometheus_tsdb_reloads_failures_total`, `prometheus_tsdb_wal_truncations_failed_total`. A failing compaction or a WAL corruption risks data loss and lets the head grow unbounded until the process OOMs — a high finding distinct from cardinality (the *symptom* is head growth, the *cause* is a broken block lifecycle).
- **PROM-032 (head-series churn and growth):** `prometheus_tsdb_head_series` (current), `rate(prometheus_tsdb_head_series_created_total[...])` vs the steady series count. High series-*creation* churn relative to a flat total means labels are constantly born and retired (pod-name/UUID/build-hash labels) — a slow-motion cardinality explosion that PROM-030's point-in-time snapshot understates. Record the churn rate and the labels driving it.

## Phase 8: Remote-write and federation (PROM-040)

Only when the remote-write self-metrics exist (a pure local-TSDB Prometheus has none → PROM-040 `not-in-scope`). Commands in section 7:

- **PROM-040 (remote-write health):** `prometheus_remote_storage_samples_pending` (live backlog), `prometheus_remote_storage_shards` vs `prometheus_remote_storage_shards_max` (queue saturation), `increase(prometheus_remote_storage_samples_failed_total[...])` and `..._samples_dropped_total`, and the write lag `prometheus_remote_storage_highest_timestamp_in_seconds - prometheus_remote_storage_queue_highest_sent_timestamp_seconds`. A backlogged, saturated, or failing remote-write means long-term storage (Mimir/Thanos/VictoriaMetrics) is **missing samples right now** — dashboards and long-range/burn-rate alerts that read the remote store go blind even while the local Prometheus looks fine. Name the queue and the observed backlog/lag.

## Phase 9: Security posture (PROM-050, PROM-051)

Read-only inspection (commands in section 8). Prometheus has no native authz, so posture is mostly *what is exposed*:

- **PROM-050 (destructive-API exposure):** from `GET /api/v1/status/flags` — `--web.enable-admin-api` and `--web.enable-lifecycle`. Admin API enabled means `POST /api/v1/admin/tsdb/delete_series` and `.../clean_tombstones` are **reachable** (anyone who can reach the API can delete series); lifecycle enabled means `POST /-/reload` and `POST /-/quit` are reachable (reload/shutdown). This audit **reads the flag; it never calls the endpoint.** Enabled + unauthenticated + non-loopback host = critical exposure; enabled behind auth = a medium posture note.
- **PROM-051 (transport and auth exposure):** is `prometheus.url` `https` (TLS on the wire)? Is the API reachable with **no** credential on a non-loopback host (an unauthenticated public Prometheus leaks every metric — and metric labels can carry sensitive values)? Record the host class (loopback / private / public) and TLS state; a plaintext, unauthenticated, publicly-reachable Prometheus is a real posture finding.

## Phase 9c: Scoutflo Topology Readiness

Render the Scoutflo Topology Readiness section per [topology-readiness.md](../../report-standard/topology-readiness.md): evaluate T1 to T6 per critical service from `./scoutflo-audits/topology-export.json`, read-only, and report it parallel to the score (never folded into the 0-100). An observation edge this audit verified live — a `SENDS_METRICS_TO`/`MONITORED_BY` edge to the Prometheus server that Phase 5 confirmed carries a fresh, healthy `up` target for that service, or whose rule Phase 6 confirmed loads and is backed by a live metric — counts toward T4/T6 exactly as the standard defines; do not assert any Prometheus-specific edge attribute or schema key beyond what topology-readiness.md specifies. Gaps that map to an existing finding reference its ID; gaps with no finding get a `TOPO-` row pointing at `/scoutflo:map-topology`. Render check names and confidence per the standard: plain-English column headers (T-codes only in the legend line), confidence as `n/10`, and — whenever any service is below ready — the ticket-ready sync-readiness action-plan table. If `topology-export.json` or `topology.md` is missing, or describes a different target than this audit covers (non-overlapping services), render the matching state from topology-readiness.md with its one-line unlock (run `/scoutflo:map-topology` against the right estate, or hand-author the export per `scoutflo-export.md` for non-Kubernetes estates); never guess, never a bare "unavailable".

## Phase 10: Score, write, brief

Score per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md): each check yields `pass` (1.0), `partial` (0.5), `fail`/`blocked` (0), with `not-in-scope` removed from the denominator; category score is the credit ratio times 100, rounded down; overall is the weight-normalized sum over included categories. Whole categories that could not be assessed are excluded, renormalized, and stated (this is exactly the PROM-007 path); blocked checks inside an assessable category score 0. Score conservatively: when unsure between two results, pick the lower and say why.

| Category | Weight | ID range |
| --- | ---: | --- |
| Server reachability and config | 15 | PROM-001, PROM-002, PROM-003 |
| Scrape targets and coverage | 20 | PROM-010, PROM-011, PROM-012, PROM-007 |
| Rule-engine health | 25 | PROM-020, PROM-021, PROM-022, PROM-023 |
| TSDB cardinality and storage | 20 | PROM-030, PROM-031, PROM-032 |
| Remote-write and federation | 10 | PROM-040 |
| Security posture | 10 | PROM-050, PROM-051 |

The full check catalog, one permanent ID per check with typical failure severity, is at the top of [references/prometheus-checks.md](references/prometheus-checks.md). IDs are stable; the same defect gets the same ID every run, which is what makes deltas exact. One finding per failed check, with every affected service/job enumerated in `affected`.

End-to-end gate: claim end-to-end coverage only when the overall score is at or above 85, every critical service has a healthy fresh `up` target, every paging rule loads/evaluates/reads a live metric and has an active Alertmanager, and no category was excluded. Below the gate, write "good base coverage", never "end to end".

Before writing, since `findings.json` requires the `lifecycle` field on every finding: load the previous run's `findings.json` when one exists and classify every finding (`new`, `unchanged`, `regressed`; resolved IDs go to the delta); load `./scoutflo-audits/exemptions.yaml` when present (entries with `id`, `reason`, and `expires` unexpired suppress into the Suppressed appendix; malformed/expired entries are reported, never honored).

Emit and verify:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/prometheus/${RUN_DATE}"
mkdir -p "$OUT"
# ... write findings.json (lifecycle set per finding, estate object from sizing; ".target" is "prometheus"),
# inventory.json (kinds: target, alert_rule, recording_rule, alertmanager, remote_write; ".target" is
# "prometheus"), and report.md per the report standard, then verify:
jq -e '.schema == "scoutflo-findings/v1" and .target == "prometheus" and (.findings | type == "array") and (.findings | all(has("lifecycle")))' \
  "$OUT/findings.json" >/dev/null && echo "findings.json valid"
grep -q '^# ' "$OUT/report.md" && echo "report.md present"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-findings.sh" "$OUT/findings.json"
# Inventory (scoutflo-inventory/v1): the complete Phase-2 catalog, built from the raw pull, redacted.
jq -e '.schema == "scoutflo-inventory/v1" and (.items | type == "array") and (.counts.total == (.items | length))' "$OUT/inventory.json" >/dev/null && echo "inventory.json valid"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" inventory "$OUT/inventory.json" >/dev/null && echo "inventory section renders"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" html "$OUT/findings.json" "$OUT/report.html" "$(dirname "$OUT")/history.jsonl"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-report.sh" "$OUT/report.md"
ls -l "$OUT"
```

Compute the delta against the previous run date per the [report standard](../../report-standard/README.md); on the first run state "first run, no delta". After the report is written, close with the run-completion message per the report standard: the one-line score headline, the top fixes by `points_recoverable`, the **absolute** report path, the OS-specific open command, and the leak-safe share pointer. Then send the Slack brief, titles only, never evidence values:

```bash
set -eu
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/prometheus"
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${TARGET_DIR}/${RUN_DATE}"
if [ -n "${SCOUTFLO_SLACK_WEBHOOK:-}" ]; then
  OUT_ABS="$(cd "$OUT" && pwd)"
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
  jq -n --arg head "audit-prometheus ${RUN_DATE}: ${SCORE}/100${MOVE:+ $MOVE}, ${E2E}. ${COUNTS}." \
        --arg top "$TOP" --arg delta "$DELTA" --arg path "$OUT_ABS/report.md" \
        '{text: ($head + "\nTop findings:\n" + $top + "\nDelta: " + $delta + "\nReport: " + $path)}' \
    | curl -fsS --max-time 10 -H 'Content-Type: application/json' -d @- "$SCOUTFLO_SLACK_WEBHOOK" \
    || echo "Slack brief failed to send; audit result unaffected"
fi
```

When invoked by `audit-all`, skip the Slack brief; the orchestrator sends exactly one combined message. Keep `./scoutflo-audits/` out of public version control; reports describe your infrastructure.

## Inventory

`report.md`'s `## Inventory` section is the `render-report-viz.sh inventory` render of `inventory.json` — never hand-write it, regenerate it. Build one item per object the audit read, per the [inventory schema](../../report-standard/inventory-schema.md), using these Prometheus kinds:

| kind | source | key `attrs` |
| --- | --- | --- |
| `target` | `GET /api/v1/targets` | `job`, `health` (up/down), `scrape_pool`, `last_scrape_age_s`; never the full `scrapeUrl` if it carries userinfo |
| `alert_rule` | `GET /api/v1/rules` (`type=alerting`) | `group`, `health`, `severity` (from labels), `state` (firing/pending/inactive) |
| `recording_rule` | `GET /api/v1/rules` (`type=recording`) | `group`, `health` |
| `alertmanager` | `GET /api/v1/alertmanagers` | `state` (active/dropped) — host/class only, never a URL with userinfo |
| `remote_write` | remote-write self-metrics | `queue`, `shards`, `pending`; never the remote URL if it carries userinfo |

Every row traces to a raw object read this run; an empty estate is `items: []` with `total: 0`, reported honestly and paired with the PROM-007 guardrail. Redaction applies (`secret-redaction.md`): capture by key/name/class only — never a token, a webhook URL, or a URL with embedded credentials.

## Remediation pointers

This audit has no setup lane; every fix is an inline, read-the-state-first action you apply by hand. Every finding's `remediation` field points at one of these:

| Finding area | Inline fix |
| --- | --- |
| Failed config reload (PROM-002) | Read `journalctl`/pod logs for the reload error, fix the offending `prometheus.yml` / rule file it names, then reload (`kill -HUP`, `POST /-/reload` if lifecycle is enabled, or restart) — and re-check `prometheus_config_last_reload_successful == 1` |
| Down / stale scrape target (PROM-010, PROM-011) | Fix the scrape for the named job — the ServiceMonitor/PodMonitor selector, the target port, a relabel drop rule, or the exporter itself; confirm the target returns to `health="up"` with a fresh `lastScrape` |
| Scrape limit dropping series (PROM-012) | Raise the `sample_limit`/`target_limit`/`body_size_limit` in the scrape config for the named job, or reduce what the target exposes; re-check the `..._exceeded_*_total` counter stops increasing |
| Broken / late / dead rule (PROM-020, PROM-021, PROM-022) | Fix the named rule's PromQL (the `lastError` says what); for a late group raise its `interval` or split it; for a no-data rule (PROM-022) fix the *scrape* of the metric its expression reads, then confirm `count(<metric>) > 0` and the rule's `health` returns to `ok` |
| No live Alertmanager / dropped notifications (PROM-023) | Configure `alerting.alertmanagers` in `prometheus.yml` (or fix the discovery), confirm `/api/v1/alertmanagers` lists it active and `prometheus_notifications_dropped_total` stops rising; the routing tree itself is `/scoutflo:audit-alert-routing` |
| High cardinality / churn (PROM-030, PROM-032) | Drop the offending high-cardinality label with a `metric_relabel_configs` `labeldrop`/`drop`, or fix the instrumentation emitting IDs as labels; re-read `/api/v1/status/tsdb` to confirm the series count falls |
| WAL / compaction failure (PROM-031) | Investigate the storage backend (disk full, permissions, corruption) from the TSDB error logs; a persistent `wal_corruptions_total` may need a controlled restart to replay — treat as a storage incident |
| Remote-write backlog / failures (PROM-040) | Fix the remote endpoint (auth, throughput, the receiver's ingestion limits) or tune `queue_config` (shards, capacity, batch); confirm `samples_pending` drains and `samples_failed_total` stops rising |
| Admin/lifecycle API or unauthenticated public exposure (PROM-050, PROM-051) | Disable `--web.enable-admin-api`/`--web.enable-lifecycle` if unused, put the endpoint behind an auth proxy and TLS, or move it off any public ingress to a private network / port-forward |

## Large-path worklist

Runs on the large path only (see [Estate sizing](#estate-sizing)). All state lives under a run-ID-keyed directory `./scoutflo-audits/prometheus/runs/<RUN_ID>/`, not a calendar-date directory, so a run still batching when the UTC date rolls over keeps writing to the same place.

1. **Find a resumable run, or start a new one.** Before minting a new `RUN_ID`, scan `./scoutflo-audits/prometheus/runs/*/worklist.tsv` for one with pending rows and offer to resume it instead of starting over.
2. **Build or resume the worklist.** One row per critical-service target (for the Phase 5 coverage/freshness checks) and one per rule group (for the Phase 6 rule-health + backing-metric checks), status `pending` or `done`. A resumed run continues its existing worklist; never rebuild one that already exists.
3. **Lock, then claim one batch.** Acquire `worklist.lock` in the run directory before reading pending rows; a lock older than `LOCK_STALE_MINUTES` (30 minutes; example, tune to your batch size) is abandoned and safe to reclaim. Take the next `BATCH_SIZE` pending rows and run the matching checks against just that batch. A row is marked `done` **only after its reads succeed**, so an interrupted batch resumes at the row that failed. Release the lock once the batch's rows are marked.
4. **Assemble incrementally.** After each batch, recompose the partial findings and coverage matrix from the batches completed so far, and print progress (`done=X pending=Y`). Repeat from step 3 until the worklist has zero pending rows.
5. **Assert before writing.** `findings.json` and `report.md` are written only once a final check confirms the worklist's `pending` count is `0`. A partial run's state stays in the run directory as the resume point and never overwrites the previous complete report.

The server-wide cheap checks (config reload PROM-002, TSDB PROM-030/031/032, remote-write PROM-040, security PROM-050/051, and the PROM-007 guardrail) are single passes; they run once per run regardless of path and are never batched.

## Common Failure Modes

All thresholds and windows named in the checks (`RECENT_WINDOW`, `FRESH_LAG_S`, part/error thresholds) are example values; tune them to your traffic and retention before treating a miss as a failure.

| Failure | Prevention |
| --- | --- |
| A target exists, so coverage scored `pass` | Coverage is `up == 1` **and** a fresh sample per critical-service job, not target presence; a `health="down"` target reads stale, not absent (PROM-010/011) |
| Down target read as "no data" | Distinguish a `health="down"`/absent target (PROM-010) from an `up==1` target whose `time() - timestamp(up)` lag is growing (PROM-011) |
| Dropped series missed because `up==1` | A target at its `sample_limit` reads `up==1` while series are silently dropped — check the `..._exceeded_sample_limit_total` counter (PROM-012) |
| A loaded rule counted as a working alert | `health="ok"` is not enough: a rule whose backing metric stopped being scraped evaluates to no-data forever — confirm `count(<metric-in-the-query>) > 0` (PROM-022) |
| Rule lag missed because there was no `lastError` | A group whose `evaluationTime > interval` fires late even with `health="ok"` — check the group timing and `prometheus_rule_evaluation_failures_total` (PROM-021) |
| Self-metric read on the wrong engine as "healthy" | vmalert and the Mimir ruler expose *different* rule/remote-write metrics — detect the engine first; an empty result on the wrong engine is `not observable`, never `healthy` |
| Failed config reload missed | The running config silently stays the last-good one — read `prometheus_config_last_reload_successful`; a `0` means every change since is not applied (PROM-002) |
| Cardinality assumed from metric names | Read `/api/v1/status/tsdb` for the real `seriesCountByMetricName`/`labelValueCountByLabelName`; a point-in-time snapshot understates churn — also read the head-series-created rate (PROM-030/032) |
| Remote-write scored on a local-TSDB Prometheus | No `prometheus_remote_storage_*` self-metrics means remote-write is not configured → PROM-040 `not-in-scope`, never a fail |
| The destructive admin API exercised to "test" it | Never `POST /api/v1/admin/tsdb/delete_series` or `/-/reload` or `/-/quit` — read the `--web.enable-admin-api`/`--web.enable-lifecycle` flags instead (PROM-050) |
| An empty Prometheus scored a confident 0 | Reachable with zero targets and zero `up` series trips PROM-007 — block coverage/rules, keep TSDB+security, renormalize, never a confident 0/100 |
| Alertmanager routing re-scored here | PROM-023 proves only that Prometheus has a live AM and isn't dropping notifications; the routing tree/silences/receivers/delivery are `/scoutflo:audit-alert-routing` |
| Token or credentialed URL leaked into evidence | Record job/host/class only; never the bearer token, a `scrapeUrl` with userinfo, or a remote-write URL with embedded credentials |
