---
name: audit-datadog
description: Read-only scored audit of Datadog monitor health across notification delivery, monitor noise controls (recovery thresholds, no-data, renotify, auto-resolve), muting and downtimes, SLO and composite coverage, plus a separate non-scored Cost & Resource Optimization section from Datadog's own usage endpoints; writes findings.json and report.md and changes nothing. Use when the user mentions auditing or scoring Datadog, Datadog monitors, monitor noise or flapping, muted or downtimed monitors, dead notification handles, SLO alerting, or Datadog custom-metric cost. Do not use to change Datadog (no setup-datadog ships yet; the audit names each fix), for Datadog data shown in Grafana (use audit-grafana), or for the paging layer downstream of a monitor (use audit-pagerduty).
---

# audit-datadog

Scored, read-only audit of the Datadog monitors that carry your alerting: whether each monitor reaches a live target, whether its noise controls are tuned, whether anything is muted or downtimed into a blind spot, whether SLOs and composite monitors are intact, and — as a separate non-scored section — where Datadog's own usage data says your spend is going. It answers one question: when a metric breaches tonight, does exactly one useful page reach the right team, and is Datadog itself telling you something the config does not?

This skill audits the monitor layer inside Datadog. Whether the page that a monitor sends then reaches a human through PagerDuty is the paging layer's job (`audit-pagerduty`); Datadog data rendered in Grafana dashboards is `audit-grafana`. This audit stops at the monitor and its notification targets.

Every command is read-only: GET on monitors, downtimes, SLOs, integrations, usage, and dashboards. Unlike the PagerDuty audit, Datadog exposes no read-by-effect POST, so every mutating verb — muting, resolving, creating downtimes, test events — is forbidden; the full list is in [references/datadog-checks.md](references/datadog-checks.md) section 13. There is no `setup-datadog` yet, so every finding names its manual fix path instead of a setup anchor.

**Multiple Datadog targets, one run:** `datadog` may be a single block (one `site`/`api_key_env`/`app_key_env`) or a **list of labeled targets**, each with its own `site`, `api_key_env`, and `app_key_env`. The audit **iterates every target** — enumerate them with `sh "${CLAUDE_PLUGIN_ROOT}/report-standard/toolkit-targets.sh" <cfg> datadog labels` and run the full sequence below once per target with `SCOUTFLO_TARGET=<label>` set. Output goes to `datadog/<label>/<date>/` for a list, or the flat `datadog/<date>/` for a single block. Every API call resolves and uses the target's own `site` and key pair — `api_key_env`/`app_key_env` name the variables holding the secrets, sent as the `DD-API-KEY`/`DD-APPLICATION-KEY` headers; there is no ambient default, and a single-block config resolves to exactly one target whose label defaults to the block name (`datadog`), byte-identical to today's read.

Run this standalone, from `/scoutflo:audit-all`, or on a schedule via `/scoutflo:schedule-audits`.

Outputs, per the [report standard](../../report-standard/README.md):

- `./scoutflo-audits/datadog/[<label>/]<YYYY-MM-DD>/findings.json` per the [findings schema](../../report-standard/findings-schema.md), finding IDs `DD-NNN` (scored) and `DDOPT-NNN` (non-scored cost)
- `./scoutflo-audits/datadog/[<label>/]<YYYY-MM-DD>/report.md` per the [report template](../../report-standard/report-template.md), including the `## Inventory` section (the `render-report-viz.sh inventory` output)
- `./scoutflo-audits/datadog/[<label>/]<YYYY-MM-DD>/inventory.json` per the [inventory schema](../../report-standard/inventory-schema.md) (`scoutflo-inventory/v1`): the complete Phase-2 catalog — one item per monitor, SLO, and downtime (`kind`: `monitor`, `slo`, `downtime`) — each with `kind`, `covers`, `enabled`, `severity`, and `routes_to` for alerting objects. Built from the raw pull, never invented; redacted at capture, never a secret value.
- One appended line in `./scoutflo-audits/datadog/[<label>/]history.jsonl`
- One Slack brief, when `slack.webhook_env` is configured

## Doctor gate

| Integration | toolkit.yaml keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| Datadog | `datadog.site`, `datadog.api_key_env`, `datadog.app_key_env`, optional `datadog.cost_checks` | the variables named by `api_key_env` (`DATADOG_API_KEY`) and `app_key_env` (`DATADOG_APP_KEY`) | scoped app key: `monitors_read`, `monitors_downtime`, `slos_read`, `events_read`, `synthetics_read` (+ `usage_read`, `billing_read` for the cost section) | read-only |
| Slack (optional) | `slack.webhook_env` | webhook variable | post to one channel | n/a |

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
for bin in curl jq; do
  command -v "$bin" >/dev/null || { echo "missing binary: $bin"; exit 1; }
done
# Resolve the CURRENT datadog target from toolkit.yaml — a single block, or the SCOUTFLO_TARGET-selected
# item of a labeled list (the shared enumerator handles both; no yq required). Every API call below uses
# this target's own site and key pair; a single-block config resolves to one target (label "datadog").
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
DD_KIND=$(sh "$TT" "$CFG" datadog kind); DD_N=$(sh "$TT" "$CFG" datadog count)
[ "${DD_N:-0}" -ge 1 ] || { echo "no datadog target configured in $CFG; run /scoutflo:connect"; exit 1; }
DD_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$DD_N" ]; do [ "$(sh "$TT" "$CFG" datadog label "$_i")" = "$SCOUTFLO_TARGET" ] && { DD_IDX=$_i; break; }; _i=$((_i+1)); done; fi
DD_LABEL=$(sh "$TT" "$CFG" datadog label "$DD_IDX")
if [ "$DD_KIND" = seq ]; then DD_SEG="datadog/${DD_LABEL}"; else DD_SEG="datadog"; fi
DD_SITE=$(sh "$TT" "$CFG" datadog get "$DD_IDX" site); DD_SITE="${DD_SITE:-datadoghq.com}"   # datadog.site: e.g. datadoghq.com, us5.datadoghq.com, datadoghq.eu
DD_HOST="api.${DD_SITE}"
echo "datadog target: ${DD_LABEL} (site ${DD_SITE}) -> ${DD_SEG}/"
# datadog.api_key_env / app_key_env name the VARIABLES holding this target's keys; read each by name so
# every target uses its own pair (defaults DATADOG_API_KEY / DATADOG_APP_KEY for a single block). Presence check only, never print.
DD_API_VAR=$(sh "$TT" "$CFG" datadog get "$DD_IDX" api_key_env); DD_API_VAR="${DD_API_VAR:-DATADOG_API_KEY}"
DD_APP_VAR=$(sh "$TT" "$CFG" datadog get "$DD_IDX" app_key_env); DD_APP_VAR="${DD_APP_VAR:-DATADOG_APP_KEY}"
DATADOG_API_KEY="$(printenv "$DD_API_VAR" 2>/dev/null || true)"; export DATADOG_API_KEY
DATADOG_APP_KEY="$(printenv "$DD_APP_VAR" 2>/dev/null || true)"; export DATADOG_APP_KEY
[ -n "${DATADOG_API_KEY:-}" ] || { echo "DATADOG_API_KEY is not set — add it to ~/.scoutflo/env (echo 'export DATADOG_API_KEY=\"<paste>\"' >> ~/.scoutflo/env; chmod 600 ~/.scoutflo/env), or run /scoutflo:connect. The plugin reads that file, not your interactive shell."; exit 1; }
[ -n "${DATADOG_APP_KEY:-}" ] || { echo "DATADOG_APP_KEY is not set (both keys are required) — add it to ~/.scoutflo/env (echo 'export DATADOG_APP_KEY=\"<paste>\"' >> ~/.scoutflo/env; chmod 600 ~/.scoutflo/env), or run /scoutflo:connect. The plugin reads that file, not your interactive shell."; exit 1; }
# Datadog is SaaS so the risk is low, but as defense-in-depth keep the body and content-type
# (do NOT discard to /dev/null) so a 200 that is really an HTML login/SPA/proxy page fails closed.
DDV_BODY="$(mktemp)"
VMETA="$(curl -s -o "$DDV_BODY" -w '%{http_code} %{content_type}' --max-time 10 \
  -H "DD-API-KEY: ${DATADOG_API_KEY}" "https://${DD_HOST}/api/v1/validate")" || true
VCODE="${VMETA%% *}"; VCT="${VMETA#* }"
[ "$VCODE" = "200" ] || { rm -f "$DDV_BODY"; echo "validate returned ${VCODE}: API key invalid or wrong datadog.site (a valid key on the wrong site returns 403)"; exit 1; }
printf '%s' "$VCT" | grep -qi json && jq -e '.valid==true' "$DDV_BODY" >/dev/null 2>&1 \
  || { rm -f "$DDV_BODY"; echo "validate returned 200 but Content-Type=${VCT} and the body is not the Datadog validate JSON (.valid==true) — looks like an HTML login/SPA/proxy page, not api.${DD_SITE}; verify datadog.site"; exit 1; }
rm -f "$DDV_BODY"
DDM_BODY="$(mktemp)"
MMETA="$(curl -s -o "$DDM_BODY" -w '%{http_code} %{content_type}' --max-time 10 \
  -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v1/monitor?page_size=1")" || true
MCODE="${MMETA%% *}"; MCT="${MMETA#* }"
[ "$MCODE" = "200" ] || { rm -f "$DDM_BODY"; echo "monitor read returned ${MCODE}: app key invalid, missing monitors_read scope, or its user was disabled (app keys are user-bound)"; exit 1; }
printf '%s' "$MCT" | grep -qi json && jq -e 'type=="array"' "$DDM_BODY" >/dev/null 2>&1 \
  || { rm -f "$DDM_BODY"; echo "monitor read returned 200 but Content-Type=${MCT} and the body is not the monitors JSON array — looks like an HTML login/SPA/proxy page, not the monitor API; verify datadog.site"; exit 1; }
rm -f "$DDM_BODY"
echo "doctor gate: pass"
```

Never proceed past a failed doctor check and never downgrade one into a finding. `/scoutflo:doctor` runs the same checks standalone, plus the non-failing cost-permission probe this audit's Cost & Resource Optimization section reads.

Datadog needs a key pair: the API key alone validates identity; the app key plus its scopes authorizes reads. The tier is scope-declared at key creation and cannot be introspected afterward, so if a broader app key is used the audit still runs, but record in the report that the audit credential can do more than read.

## Live-safety gate

Print what you are pointed at and compare it to the config before the first real check:

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
# Resolve the CURRENT datadog target from config via the shared enumerator — a single block, or the
# SCOUTFLO_TARGET-selected item of a labeled list (no yq required). Site and keys are this target's own.
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
DD_KIND=$(sh "$TT" "$CFG" datadog kind); DD_N=$(sh "$TT" "$CFG" datadog count)
DD_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$DD_N" ]; do [ "$(sh "$TT" "$CFG" datadog label "$_i")" = "$SCOUTFLO_TARGET" ] && { DD_IDX=$_i; break; }; _i=$((_i+1)); done; fi
DD_LABEL=$(sh "$TT" "$CFG" datadog label "$DD_IDX")
if [ "$DD_KIND" = seq ]; then DD_SEG="datadog/${DD_LABEL}"; else DD_SEG="datadog"; fi
DD_SITE=$(sh "$TT" "$CFG" datadog get "$DD_IDX" site); DD_SITE="${DD_SITE:-datadoghq.com}"   # datadog.site
DD_HOST="api.${DD_SITE}"
DD_API_VAR=$(sh "$TT" "$CFG" datadog get "$DD_IDX" api_key_env); DD_API_VAR="${DD_API_VAR:-DATADOG_API_KEY}"
DD_APP_VAR=$(sh "$TT" "$CFG" datadog get "$DD_IDX" app_key_env); DD_APP_VAR="${DD_APP_VAR:-DATADOG_APP_KEY}"
DATADOG_API_KEY="$(printenv "$DD_API_VAR" 2>/dev/null || true)"; export DATADOG_API_KEY
DATADOG_APP_KEY="$(printenv "$DD_APP_VAR" 2>/dev/null || true)"; export DATADOG_APP_KEY
[ -n "${DATADOG_API_KEY:-}" ] || { echo "datadog target '${DD_LABEL}' key variable ${DD_API_VAR} is not set — add it to ~/.scoutflo/env (echo 'export ${DD_API_VAR}=\"<paste>\"' >> ~/.scoutflo/env; chmod 600 ~/.scoutflo/env), or run /scoutflo:connect. The plugin reads that file, not your interactive shell."; exit 1; }
[ -n "${DATADOG_APP_KEY:-}" ] || { echo "datadog target '${DD_LABEL}' app-key variable ${DD_APP_VAR} is not set — add it to ~/.scoutflo/env (echo 'export ${DD_APP_VAR}=\"<paste>\"' >> ~/.scoutflo/env; chmod 600 ~/.scoutflo/env), or run /scoutflo:connect. The plugin reads that file, not your interactive shell."; exit 1; }
# There is no org-name whoami on the key pair; identify the org by what it reads and by
# the site it is bound to. A mismatch between the exported keys' site and datadog.site
# surfaces here as a 403 rather than a wrong-account read.
ORG_JSON="$(curl -fsS --max-time 15 \
  -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v1/org" 2>/dev/null || echo '{}')"
ORG_NAME="$(printf '%s' "$ORG_JSON" | jq -r '(.orgs[0].name // "unreadable")')"
MON_SAMPLE="$(curl -fsS --max-time 15 \
  -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v1/monitor?page_size=3")"
NAMES="$(printf '%s' "$MON_SAMPLE" | jq -r '[.[].name] | join(", ")')"
echo "site=${DD_SITE} label=${DD_LABEL} org=${ORG_NAME} -> ${DD_SEG}/ sample_monitors: ${NAMES}"
printf '%s' "$MON_SAMPLE" | jq -e 'type == "array"' >/dev/null \
  || { echo "monitor endpoint did not return a list; wrong site or wrong keys — stop"; exit 1; }
echo "live-safety gate: pass — confirm this org and these monitor names are the account you intend to audit"
```

The key pair and the site together select the account; there is no ambient default. The `/api/v1/org` read is best-effort (some scoped keys cannot read org metadata — an `unreadable` there is fine); the monitor sample names are the human confirmation.

## Ground rules

- Configuration is metadata; observed behavior is proof. A monitor with an `@handle` in its message is `configured`; only a resolved live target (an integration/channel/webhook that exists) makes delivery `validated-live`.
- API errors are evidence. A `403` means the API key is wrong, the site is wrong, or the app key lacks the scope; record which, and never convert an error into empty success. On Datadog specifically, check the site before concluding a scope problem — a valid key on the wrong site returns 403.
- Never score from object counts.
  - ❌ `Scored monitor coverage 90: two hundred monitors exist.`
  - ✅ `Scored monitor coverage 45: two hundred monitors exist, but eleven are drafts, six target a deleted Slack channel, and thirty have no service tag; credit stops at partial.`
- Trust Datadog's own signals, and reconcile them. `GET /api/v1/monitor/search` returns a `quality_issues[]` array on each monitor object (top-level on the monitor, not under `.metadata`; verified live), flagging muted >60 days, missing recipients, stuck in alert, composite missing constituents. Report the vendor's flags alongside this audit's findings; where they disagree about a monitor, the disagreement is itself the finding (DD-015).
- Downtimes are v2 only. Every v1 downtime endpoint is deprecated including its reads; this audit reads `/api/v2/downtime` and never `/api/v1/downtime`.
- Never write a monitor message body verbatim if it embeds a secret-shaped value, and never write API/app keys anywhere. Captures keep IDs, names, options, and tags.

## Estate sizing

Count before judging, and declare the path in the terminal output:

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
DD_KIND=$(sh "$TT" "$CFG" datadog kind); DD_N=$(sh "$TT" "$CFG" datadog count)
DD_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$DD_N" ]; do [ "$(sh "$TT" "$CFG" datadog label "$_i")" = "$SCOUTFLO_TARGET" ] && { DD_IDX=$_i; break; }; _i=$((_i+1)); done; fi
DD_LABEL=$(sh "$TT" "$CFG" datadog label "$DD_IDX")
if [ "$DD_KIND" = seq ]; then DD_SEG="datadog/${DD_LABEL}"; else DD_SEG="datadog"; fi
DD_SITE=$(sh "$TT" "$CFG" datadog get "$DD_IDX" site); DD_SITE="${DD_SITE:-datadoghq.com}"   # datadog.site
DD_HOST="api.${DD_SITE}"
DD_API_VAR=$(sh "$TT" "$CFG" datadog get "$DD_IDX" api_key_env); DD_API_VAR="${DD_API_VAR:-DATADOG_API_KEY}"
DD_APP_VAR=$(sh "$TT" "$CFG" datadog get "$DD_IDX" app_key_env); DD_APP_VAR="${DD_APP_VAR:-DATADOG_APP_KEY}"
DATADOG_API_KEY="$(printenv "$DD_API_VAR" 2>/dev/null || true)"; export DATADOG_API_KEY
DATADOG_APP_KEY="$(printenv "$DD_APP_VAR" 2>/dev/null || true)"; export DATADOG_APP_KEY
SMALL_MAX_OBJECTS="25"    # example, tune to your environment
MEDIUM_MAX_OBJECTS="150"  # example, tune to your environment
BATCH_SIZE="50"           # monitors per batch on the large path; example, tune it
MON_COUNT="$(curl -fsS --max-time 30 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v1/monitor/search?per_page=1" | jq -r '.metadata.total_count // 0')"
SLO_COUNT="$(curl -fsS --max-time 30 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v1/slo?limit=1" | jq -r '.metadata.page.total_count // .metadata.pagination.total_count // (.data | length) // 0' 2>/dev/null || echo 0)"
TOTAL="$MON_COUNT"
echo "monitors=${MON_COUNT} slos=${SLO_COUNT} scored_objects=${TOTAL}"

# Guided-walkthrough drift check, per report-standard/README.md: compare against the last run.
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${DD_SEG}"
PREV_RUN="$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)"
DRIFT="first run"
if [ -n "$PREV_RUN" ] && [ -f "${PREV_RUN}/findings.json" ]; then
  PREV_TOTAL="$(jq -r '.estate.objects // empty' "${PREV_RUN}/findings.json")"
  if [ -n "$PREV_TOTAL" ]; then
    if [ "$PREV_TOTAL" -eq "$TOTAL" ]; then
      DRIFT="estate unchanged since ${PREV_RUN##*/} (${PREV_TOTAL} monitors then, ${TOTAL} now)"
    else
      DRIFT="estate changed since ${PREV_RUN##*/}: ${PREV_TOTAL} -> ${TOTAL} monitors"
    fi
  else
    DRIFT="previous run recorded no estate data; treating as first run"
  fi
fi
echo "drift: ${DRIFT}"
```

- **Small** (`TOTAL <= SMALL_MAX_OBJECTS`): one pass over everything.
- **Medium** (`TOTAL <= MEDIUM_MAX_OBJECTS`): per-category passes (delivery, noise, muting, coverage), completed in one run.
- **Large**: work monitors in batches of `BATCH_SIZE` against a durable, run-ID-keyed worklist per the worklist rules in [skill-authoring-conventions.md](../../docs/skill-authoring-conventions.md): scan for a resumable run before minting a new run ID, one row per monitor ID, lock before claiming a batch, mark rows done only after their pulls succeed, and assert zero pending rows before Phase 8 writes anything.

Never silently truncate: if the run judged a subset, the report names what was skipped and the coverage denominators reflect it. The rate-limit retry rule in [references/datadog-checks.md](references/datadog-checks.md) section 9 applies to every call.

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

## Phase 1: Service context

If `./scoutflo-audits/topology.md` exists, load it. Its service list is the critical-service list and its names are canonical; map Datadog monitors to those names by their `service:` tag (fall back to name match, recorded). If it does not exist, infer critical services from monitor `service:` tags, note the inference, and suggest `/scoutflo:map-topology`.

## Phase 2: Read-only inventory

Build the raw picture with the commands in [references/datadog-checks.md](references/datadog-checks.md) section 4: all monitors with messages, options, tags, and state; Datadog's own `quality_issues[]` per monitor; v2 downtimes; and SLOs with their attached monitor IDs. Judgment starts in Phase 3. A 403 on any surface is an auth/scope note attached to the checks that need it, naming the missing scope.

## Phase 3: Monitor delivery (DD-001 to DD-008)

Commands in section 5. Judge whether a monitor reaches a live target: every monitor names at least one `@handle` (`DD-001`, critical when a monitor notifies nobody), no monitor targets a dead handle — a Slack channel, webhook, or PagerDuty service that no longer resolves (`DD-002`, high), no monitor left in `draft` status masquerading as coverage (`DD-003`, high — drafts never notify), org-level notification rules and config policies reviewed where the org uses them (`DD-004`, computing the routing fall-through set), and critical-service monitors carrying a `priority` so paging can be tiered rather than flat (`DD-005`, medium, **live-verified (read-only)** — section 5.1, no residual: `priority` observed present and `null` on real monitors, exactly the untiered case it flags). DD-001/DD-002/DD-003 do not stop at a count: each joins the failing monitor to its `service:` tag and criticality so the finding names which service goes blind, and each is one of the suppressors the Phase-6 DD-033 effective-coverage flagship subtracts.

- ❌ `Delivery pass: every monitor has a message.`
- ✅ `Delivery partial: every monitor has a message, but six target @slack-prod-alerts which is not in the Slack integration's channel list (DD-002), and two are drafts (DD-003); affected: checkout, payments.`

Three checks measure delivery Datadog's own config screens cannot show you, each **live-verified (read-only)** against a real Datadog org — section 5.2:

- **`DD-006` (high) — measured alert-event volume, not inferred.** `DD-001` to `DD-003` judge configuration; `DD-006` is the missing evidence layer, the same class as a Sentry rule's fire-history: count `sources=alert` events (`GET /api/v1/events`, corroborated with the v2 `source:alert` events-search query) per `monitor_id` over a trailing window. A monitor with the right config that has fired zero alert events while its `overall_state_modified` shows a real state transition inside the same window is a config/behavior gap this check catches and DD-001 cannot: the notify plane is configured but demonstrably silent. Also yields a noisiest-monitor ranking from the same pull, feeding DD-016.
- **`DD-007` (high) — placeholder and template artifacts left un-filled.** `DD-001`'s `test("@")` only checks that some `@`-shaped token exists in the message; a monitor whose only real target is a literal template placeholder (`@your-team-handle`, a `__..._placeholder__` fragment inside the query, or a tag value that is literally `$service`/`$env` because a template variable was never substituted) still contains an `@` and currently **passes DD-001 by accident**. `DD-007` closes that gap: it flags the placeholder shapes directly, independent of whether a real handle also happens to be present, and is one more suppressor the DD-033 flagship subtracts (a monitor whose only resolvable-looking handle is a placeholder does not deliver, exactly like the no-handle set).
- **`DD-008` (medium) — over-broad `@all`/`@everyone`.** A monitor that pages the whole org on every breach trades noise for reach; name it and let the team decide whether that breadth is deliberate (an incident-bridge monitor) or accidental scope creep from a copy-pasted message.

## Phase 4: Monitor noise (DD-010 to DD-019)

Commands in section 6. This is the alert-hygiene category. Recovery thresholds where a monitor has warning/critical thresholds and can flap (`DD-010`, joined to the notification handle so the finding names where the flap noise lands), deliberate no-data handling rather than a silent blind spot or a false page (`DD-011`, isolating the dangerous notify_no_data=false heartbeats), bounded renotification instead of forever (`DD-012`), evaluation and new-group delay where the query needs late data (`DD-013`), deliberate auto-resolve per type (`DD-014`), and Datadog's own `quality_issues[]` reviewed and reconciled with this audit (`DD-015`, info).

Two noise checks are **live-verified (read-only)** (section 6.1): receiver noise concentration — the real critical-service pages sharing a handle with many flap-prone/renotify-heavy monitors so they are statistically buried (`DD-016`, high, the doctrine's alert-fatigue worked example made executable for Datadog); and monitors stuck in `overall_state == "Alert"` so long they can never re-page a new breach (`DD-017`, medium). Both load-bearing computations run on real monitor objects: DD-016's handle→monitor concentration map plus the DD-010/DD-012 noisy set, and DD-017's `overall_state` stuck-state read (observed both `OK` and real `Alert` states on live monitors) — no dependence on any unverified vendor string. The `quality_issues[]` corroboration layer these checks add is now **confirmed live** too — a real org carried the members `broken_at_handle`, `missing_at_handle`, `alerted_too_long` (the real "stuck/alerting-too-long" member, not `stuck`), and `muted_duration_over_sixty_days` on 36/38 monitors — so the corroboration is real, on top of the grounded concentration/stuck-state computations that score.

Honest ceiling, stated in the report every run: monitor options are metadata about intent; whether a monitor actually flapped is visible only in its state history, which this audit samples but does not exhaustively reconstruct. Event Management correlation exists in Datadog but has no public API for its rules, so this audit reports correlation as UI-only and does not score it.

Two checks judge the query and threshold shape itself, not just the options around it — section 6.2, **live-verified (read-only)**: a real query in the same live org that fed DD-006/DD-007 evidence carried both defects at once, which is why they are separate checks even though one query can trip both.

- **`DD-018` (medium) — a ratio with no volume floor.** A query dividing two count terms (`errors.as_count() / hits.as_count() > threshold`) alerts on a proportion with no minimum-sample guard: one error in nine hits crosses a 10% threshold exactly as confidently as one thousand errors in nine thousand hits, but the two carry opposite operational weight. Flag every ratio query with no composite `AND` clause enforcing a minimum denominator, and name the threshold and the missing floor.
- **`DD-019` (medium) — an impossible or tautological threshold.** A comparator of `>` (or `>=`) paired with a critical value below zero, or `> 0`/`>= 0` against a metric that is structurally non-negative (a percentage, a count, a rate), is true on every evaluation — the monitor cannot recover once it first breaches, because the condition never stops holding. This is frequently the root cause behind a `DD-017` stuck-in-Alert monitor: the query is not stuck, the threshold was never satisfiable in the other direction.

## Phase 5: Muting and downtime (DD-020 to DD-023)

Commands in section 7. Indefinitely muted monitors — a stuck/suppressed alert wearing a mute (`DD-020`, high), no always-on broad-scope downtime masking real alerts (`DD-021`, high — read from `/api/v2/downtime`), and downtimes scoped tightly rather than muting whole environments open-ended (`DD-022`). A tightly scoped recurring maintenance window is healthy; an active downtime with no end and a `*` or `env:prod` scope is a permanent blind spot.

**`DD-023` (high) — downtime intent decay, live-verified (read-only).** `DD-021`/`DD-022` judge the current scope and end date; `DD-023` judges the downtime's own stated *intent* against its age. An active downtime with `end == null`, created more than `DOWNTIME_DECAY_DAYS` (30; example, tune to your change-management cadence) days ago, whose `message` matches a temporary-sounding pattern (`(?i)test|temp|safe to delete|debug`) has outlived the intent it was created under — someone meant to remove it and did not. Confirmed live: a real org carried exactly this shape — an `active` downtime, `end: null`, created well over `DOWNTIME_DECAY_DAYS` in the past, with a message reading as a temporary test note asking for its own deletion. A downtime that says "temporary" and has been live for months is the permanent blind spot `DD-021` already flags, with the added evidence of *why* it happened: nobody circled back.

## Phase 6: Coverage and staleness (DD-030 to DD-038)

Commands in section 8. Stale monitors distinguished from dead ones by pairing `last_triggered_ts` with `overall_state` — a monitor stuck in persistent `No Data` because its metric vanished is a silent coverage hole, not a quiet-but-healthy monitor (`DD-030`); composite monitors whose constituent IDs all resolve, naming the service the broken aggregate gates (`DD-031` — a composite referencing a deleted monitor silently misfires); SLOs with an error-budget or burn-rate monitor attached, naming the SLO target/service and reading the trailing SLI-vs-target so the finding states whether the budget is already burning (`DD-032`, high); critical-service **effective** coverage (`DD-033`, the flagship — section 8.1); and monitor tag hygiene computed as routing fall-through against DD-004's rules, not a bare hygiene count (`DD-034`).

**Flagship correlation — the effective-coverage blind-spot cascade (home: DD-033).** No free scanner assembles it, because it requires joining the critical-service→monitor map against every suppression mechanism at once. Per critical service, start from monitors tagged `service:X`, then subtract drafts (DD-003), no-`@handle` (DD-001), dead-handle (DD-002/`broken_at_handle`), placeholder-only-handle (`DD-007` — a monitor whose only `@`-token is a template artifact like `@your-team-handle` looks identical to a covered monitor until this join), indefinitely-silenced (DD-020), monitors whose tags match an active `end=null` downtime's scope (DD-021 tag-join — the single highest-value sub-computation), and heartbeats with `notify_no_data=false` (DD-011). What remains is the count that would actually page a human tonight. The differentiator line — *"service:payments shows 8 monitors in the Datadog UI but 0 that reach a human tonight: 2 drafts, 1 dead Slack handle, 1 placeholder-only handle, 3 under the open-ended env:prod downtime, 2 heartbeats with no-data off"* — is the direct Datadog analog of audit-kubernetes's external→cluster-secrets path: the customer's console shows 8 green monitors and cannot show that the service is effectively unmonitored. Assemble this in Phase 8 as one finding per critical service, ranked by `points_recoverable`, scoring coverage on **effective** (not inventory) monitors.

Four more coverage checks, all **live-verified (read-only)** against a real Datadog org — section 8.2:

- **`DD-035` (medium) — tag-vs-query scope mismatch.** A monitor's query carries its own scope filter (`{service:X,env:Y}` immediately after the metric name); when a tag on the same monitor names the same key with a *different* value (`service:` tag says one thing, the query's `service:` scope term says another), the tag lies to anything that routes, correlates, or builds topology from it — the query is what actually evaluates, the tag is what the rest of the org (including this toolkit's own topology join) trusts. Confirmed live: the extraction and comparison run correctly against a real monitor whose query scope and tags agreed (no false positive when they match); the check is the join, not an assumption about which side is wrong.
- **`DD-036` (low) — duplicate monitors.** Normalize each metric-type monitor's query by stripping the leading `agg(window):` prefix and the trailing comparator+threshold, then group by the normalized expression plus its scope. More than one published monitor in the same group is redundant coverage at best and drifting-threshold confusion at worst (two monitors on the same expression that no longer agree on what "bad" means). Confirmed live: four published monitors on the identical base metric and scope, differing only in window and threshold, one of which is a `DD-019` tautological threshold — the duplication is exactly how a broken threshold hides next to healthy ones instead of getting noticed.
- **`DD-037` (medium) — never-evaluated monitors.** Distinct from `DD-030` (a monitor that evaluated fine and then went stale): a monitor with `overall_state == "No Data"`, `overall_state_modified == null`, and `created` more than `NEVER_EVALUATED_DAYS` (7; example, tune to your rollout cadence) days ago has never transitioned state even once since it was created — it did not go quiet, it never started. Confirmed live: four such monitors, created weeks earlier, still carrying a null `overall_state_modified` — coverage that looked provisioned in the UI and never actually turned on.
- **`DD-038` (high) — a paused Synthetic behind a live, unmuted monitor.** A Synthetic test's own `status` (`live`/`paused`) is independent of the Datadog-generated monitor attached to it via `monitor_id`; a paused test stops running checks, but its monitor keeps reporting whatever state it last held — usually `OK` — with no future update, so the monitor looks healthy while the thing it was supposed to watch has not been probed since the pause. Confirmed live: two paused Synthetic tests, each still linked to an unmuted monitor (`overall_state` unaffected by the pause, `options.silenced` empty on both) — both monitors will never again reflect the Synthetic's real target, because nothing is checking it.

## Phase 7: Coverage matrix and topology readiness

Fill one row per critical service using the per-service mapping in section 10 and the check-result vocabulary (`pass`, `partial`, `fail`, `blocked`, `not-in-scope`):

| Service | Ready | Delivery | Noise | Muting | Coverage | SLO | Owner | Gap |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |

Every cell carries its `passed/total` denominator. Name affected services in findings.

Then render the Scoutflo Topology Readiness section per [topology-readiness.md](../../report-standard/topology-readiness.md): evaluate the six checks per critical service from `./scoutflo-audits/topology-export.json`, read-only. A `MONITORED_BY` connection to Datadog that this audit verified live (the monitor resolved, names a live target, and covers the service) counts toward Match confidence per the standard's live-verification rule. Gaps that map to an existing finding reference its ID; gaps with no finding get a `TOPO-` row pointing at `/scoutflo:map-topology`. Render check names and confidence per the standard: plain-English column headers, confidence as `n/10`, and — whenever any service is below ready — the ticket-ready readiness action plan table. If the export or topology.md is missing, or exists but describes a different target than this audit covers, the section renders the matching state from topology-readiness.md with its one-line unlock; it never guesses and never says a bare "unavailable". Readiness is reported, never folded into the 0-100 score.

**Provider-identity note, verified against the platform's current model:** `datadog` is a valid provider identity with a typed attribute schema (`monitoring.datadog`) on the Scoutflo platform, so a `MONITORED_BY` connection naming Datadog can reach full confidence. The schema's required field is `monitorId`; its identity fields are camelCase (`serviceName`, `hostname`, `clusterId`), and the platform's correlation-category mapping does not split camelCase — populating only `serviceName` satisfies Connection details but leaves the Match confidence service anchor unpopulated (see [topology-readiness.md](../../report-standard/topology-readiness.md)'s internal note on this pattern). Mirror the `serviceName` value into a literal `service` or `service_name` key on the connection, or Match confidence reads partial even though the connection resolved. State which fields the export carries versus which the schema requires when a connection stalls at partial.

## Phase 8: Score, write, brief

Score per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md): each check yields `pass` (1.0), `partial` (0.5), or `fail` (0). `blocked` is unassessed and leaves the readiness denominator; `not-in-scope` leaves both readiness and assessment-coverage denominators. Category score is the assessed-credit ratio times 100 rounded down; overall is the weight-normalized sum over categories with at least one assessed check. Show assessment coverage separately. A fully blocked run is `unassessed` with `overall: null`, never 0/100. Score conservatively: when unsure between a defect and missing evidence, use `blocked` and state the exact evidence-unlock action. Assign each category a maturity value (`reactive`, `proactive`, `systematic`). `DDOPT-*` Cost & Resource Optimization findings carry `points_recoverable: 0` always and never enter this arithmetic.

| Category | Weight | ID range |
| --- | ---: | --- |
| Monitor delivery | 30 | DD-001 to DD-008 |
| Monitor noise | 25 | DD-010 to DD-019 |
| Muting and downtime | 20 | DD-020 to DD-023 |
| Coverage and staleness | 25 | DD-030 to DD-038 |

The three checks added on the v0.1.134 depth pass fold into existing categories (DD-005 into Monitor delivery, DD-016/DD-017 into Monitor noise), so the weights are unchanged and still sum to 100. Their load-bearing mechanisms are **live-verified read-only** against a real Datadog org on the `us5` site, matching [references/datadog-checks.md](references/datadog-checks.md) sections 5.1 and 6.1: DD-005's `priority` field was observed present and `null` on real monitors (exactly the untiered case it flags); DD-016's handle→monitor concentration map and DD-017's `overall_state` stuck-state read (observed both `OK` and real `Alert` states on live monitors) both run on the real monitor objects, with no dependence on any unverified vendor string. The *vendor `quality_issues[]` corroboration* layer DD-016/DD-017 add is now **confirmed live** — the real members are `broken_at_handle`, `missing_at_handle`, `alerted_too_long` (the real "stuck/alerting-too-long" member — the earlier `high-alert-volume`/`stuck` guesses were wrong and matched nothing), and `muted_duration_over_sixty_days`, carried on 36/38 monitors of a real org — while the concentration and stuck-state computations that actually score remain load-bearing. DD-005 carries no residual. All three score like any other check.

The ten alert-hygiene checks added on this depth pass (DD-006 to DD-008, DD-018/DD-019, DD-023, DD-035 to DD-038) fold into the same four existing categories on the same denominators, so the weights are unchanged and still sum to 100. Every one of them is **live-verified (read-only)** against a real Datadog org, matching [references/datadog-checks.md](references/datadog-checks.md) sections 5.2, 6.2, 7.1, and 8.2: DD-006's `sources=alert`/`source:alert` event counts and DD-007's placeholder-handle, placeholder-query, and `$`-tag detections all ran against real captured monitor objects (the org's own quality corroboration was not needed for either — both are self-contained joins over this run's own pull); DD-018's ratio-without-a-floor and DD-019's tautological-threshold checks matched a real query on the same real org; DD-023's downtime-decay check matched a real active, open-ended, aged, test-worded downtime; DD-035's tag-vs-query join ran against a real monitor where the two agreed (proving the join reports nothing when there is nothing to report); DD-036 found real duplicate monitors on the same normalized expression; DD-037 found real monitors that had never evaluated once since creation; DD-038 found two real paused Synthetic tests still backing unmuted, live-reporting monitors. None of the ten depends on an unverified vendor string.

The full check catalog and the target profile (what 100 means per category) are at the top of [references/datadog-checks.md](references/datadog-checks.md). IDs are stable: the same defect gets the same ID every run, one finding per failed check, affected objects enumerated. Compute `points_recoverable` per finding by re-running the scoring model with that check at full credit; `info` findings and excluded categories carry 0. The executive summary states the gap to target and the two or three findings with the highest `points_recoverable` as the biggest levers.

End-to-end gate: claim end-to-end coverage only when the overall score is at or above 85, assessment coverage is 100%, every critical service passes every applicable coverage row, and no category was excluded. Below the gate, write "good base coverage", never "end to end". The Cost & Resource Optimization section never affects this gate either way.

Lifecycle, exemptions, and totals, before rendering the report:

1. Load the previous run's `findings.json` when one exists; classify every finding, `DD-*` and `DDOPT-*` alike, per the lifecycle table in the [findings schema](../../report-standard/findings-schema.md) (`new`, `unchanged`, `regressed`; resolved IDs go to the delta, and the executive summary names regressions first).
2. Load `./scoutflo-audits/exemptions.yaml` when present. Entries with `id`, `reason`, and `expires` all set and unexpired suppress their finding into the Suppressed appendix; malformed or expired entries are reported, never honored. For a readiness finding, retain the observed `partial` or `fail` result on the same-ID `checks[]` row and add `suppressed: true` plus `suppression_reason`; set the finding's `points_recoverable` to 0. Suppressed readiness checks remain assessed for coverage but are excluded from readiness scoring. A non-scored `DDOPT-*` finding has no check row: set only its lifecycle to `suppressed`, preserve `scoring_scope: "non-scored"`, and keep zero readiness points.
3. Every findings area and coverage cell carries its denominator (`passed/total`).
4. Emit one `checks[]` row for every stable `DD-*` readiness catalog check, including passes, partials, failures, blockers, and not-in-scope checks. Derive category counts, readiness, assessment coverage, and `score.check_set` from that complete ledger; never write them independently. `DDOPT-*` findings stay outside the readiness ledger and explicitly carry `scoring_scope: "non-scored"`.
5. Every finding declares `scoring_scope` (`readiness` for a same-ID non-pass `DD-*` check; `non-scored` for `DDOPT-*`) and `report_lanes`: `general-audit`, `ai-sre-readiness`, or both. Default to `general-audit` (operational reliability); add or also use `ai-sre-readiness` only when the evidence bears on telemetry quality, service identity/naming, topology/ownership context, incident routing evidence, RCA trust, or action safety — what trustworthy AI-assisted diagnosis needs. A coverage/naming/routing-evidence finding is typically both; a pure reliability/cost/security-posture finding is `general-audit` only. This classification never changes severity or score.

Emit and verify:

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
DD_KIND=$(sh "$TT" "$CFG" datadog kind); DD_N=$(sh "$TT" "$CFG" datadog count)
DD_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$DD_N" ]; do [ "$(sh "$TT" "$CFG" datadog label "$_i")" = "$SCOUTFLO_TARGET" ] && { DD_IDX=$_i; break; }; _i=$((_i+1)); done; fi
DD_LABEL=$(sh "$TT" "$CFG" datadog label "$DD_IDX")
if [ "$DD_KIND" = seq ]; then DD_SEG="datadog/${DD_LABEL}"; else DD_SEG="datadog"; fi
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${DD_SEG}/${RUN_DATE}"
mkdir -p "$OUT"
# ... write findings.json (scoutflo-findings/v2 with a complete checks[] ledger — one row per DD-* catalog
# check, lifecycle set per finding, scoring_scope, and report_lanes), inventory.json, and report.md per the
# report standard. The findings.json ".target" is the per-target slug (equal to $DD_SEG: "datadog" for a
# single block, "datadog/<label>" for a labeled-list target), so audit-all/correlation/render disambiguate
# multiple Datadog targets. Then verify:
jq -e --arg seg "$DD_SEG" '.schema == "scoutflo-findings/v2" and .target == $seg
  and (.checks | type == "array" and length > 0)
  and (.findings | type == "array")
  and (.findings | all((.scoring_scope | IN("readiness","non-scored")) and (.report_lanes | type == "array" and length > 0)))' \
  "$OUT/findings.json" >/dev/null && echo "findings.json valid"
grep -q '^# ' "$OUT/report.md" && echo "report.md present"
# Output conformance: check-findings.sh recomputes every v2 denominator, category score, the
# assessment coverage, and the check_set fingerprint, and enforces the checks[]<->findings[]
# referential integrity — a score that does not reconcile with its own ledger fails here.
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-findings.sh" "$OUT/findings.json"
# Inventory (scoutflo-inventory/v1): the complete Phase-2 catalog of what exists,
# built from the raw pull (never invented, redacted). counts.total must reconcile
# with items; the ## Inventory section of report.md IS this render.
jq -e --arg seg "$DD_SEG" '.schema == "scoutflo-inventory/v1" and .target == $seg and (.items | type == "array") and (.counts.total == (.items | length))' "$OUT/inventory.json" >/dev/null && echo "inventory.json valid"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" inventory "$OUT/inventory.json" >/dev/null && echo "inventory section renders"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" lanes "$OUT/findings.json" >/dev/null && echo "findings-by-purpose section renders"
grep -qxF '## Findings by purpose' "$OUT/report.md" && echo "findings-by-purpose section present"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" html "$OUT/findings.json" "$OUT/report.html" "$(dirname "$OUT")/history.jsonl"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-report.sh" "$OUT/report.md"
```

Compute the delta against the previous run's `findings.json` (the latest two date directories; first run states "first run, no delta"), then append one line to the history ledger, replacing any line for the same date:

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
DD_KIND=$(sh "$TT" "$CFG" datadog kind); DD_N=$(sh "$TT" "$CFG" datadog count)
DD_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$DD_N" ]; do [ "$(sh "$TT" "$CFG" datadog label "$_i")" = "$SCOUTFLO_TARGET" ] && { DD_IDX=$_i; break; }; _i=$((_i+1)); done; fi
DD_LABEL=$(sh "$TT" "$CFG" datadog label "$DD_IDX")
if [ "$DD_KIND" = seq ]; then DD_SEG="datadog/${DD_LABEL}"; else DD_SEG="datadog"; fi
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${DD_SEG}"
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${TARGET_DIR}/${RUN_DATE}"
RESOLVED="0"   # fixed count from this run's delta; 0 on the first run
LINE="$(jq -c --arg d "$RUN_DATE" --argjson resolved "$RESOLVED" \
  '{run_date:$d, skill:"audit-datadog", overall:.score.overall, state:.score.state,
    scoring_model:.score.scoring_model, check_set:.score.check_set,
    assessment_coverage_percent:.score.assessment.coverage_percent, gate:.score.gate,
    end_to_end:.score.end_to_end, severity_counts:.severity_counts,
    lifecycle_counts:((reduce .findings[].lifecycle as $l ({}; .[$l] = (.[$l] // 0) + 1)) + {resolved:$resolved})}' \
  "$OUT/findings.json")"
TMP="$(mktemp)"
[ -f "${TARGET_DIR}/history.jsonl" ] && grep -v "\"run_date\":\"${RUN_DATE}\"" "${TARGET_DIR}/history.jsonl" > "$TMP" || true
printf '%s\n' "$LINE" >> "$TMP"
mv "$TMP" "${TARGET_DIR}/history.jsonl"
tail -1 "${TARGET_DIR}/history.jsonl" | jq -e '.run_date and ((.overall|type)=="number" or .overall==null) and .scoring_model and .check_set' >/dev/null && echo "history.jsonl updated"
```

The report's trend line renders the last five history.jsonl entries, oldest first. After the report is written, close with the run-completion message per the report standard ([report-template.md](../../report-standard/report-template.md#run-completion-message-what-the-skill-says-in-chat-when-the-run-finishes)): the one-line score headline, the top fixes by points_recoverable, the **absolute** report path, the OS-specific open command, and the leak-safe share pointer (Slack brief). Then send the Slack brief exactly as [report-template.md](../../report-standard/report-template.md) specifies: score, severity counts, top finding titles, delta line, topology readiness line, report path — titles only, never evidence values. When invoked by `audit-all`, skip the brief; the orchestrator sends exactly one combined message per run. Keep `./scoutflo-audits/` out of public version control; reports describe your monitoring setup.

## Cost & Resource Optimization (non-scored)

This section is reported and never scored, the same pattern `audit-aws` uses. It runs only when the doctor `datadog cost-permissions` row is `pass`; on `skipped` (the app key lacks `usage_read`/`billing_read`, or `datadog.cost_checks` is `false`), the section reports `excluded, reason: <the doctor reason>` and runs no partial checks. Commands in [references/datadog-checks.md](references/datadog-checks.md) section 11. Findings use the `DDOPT-NNN` prefix, always carry `scoring_scope: "non-scored"` and `points_recoverable: 0`, never appear in `score.categories`, `score.excluded`, or the `checks[]` ledger, still carry their own `report_lanes` (typically `general-audit`), and render under their own heading after Topology Readiness. An `estimated_monthly_cost_usd` field appears only on a finding whose number came straight from Datadog's own usage endpoint; presence facts (a top custom-metric contributor, an unused dashboard) carry no invented dollar figure.


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

No `setup-datadog` ships yet, so every finding's `remediation` field names the concrete manual fix location. When a setup skill lands, these become anchors without the finding IDs changing:

| Finding area | Fix location today |
| --- | --- |
| Monitors with no target or a dead handle (DD-001, DD-002) | Monitor's Notify section — add or repair the `@handle`; fix the Slack/webhook/PagerDuty integration it points at |
| Draft monitors (DD-003) | Monitor edit — publish the draft or delete it |
| Un-prioritized critical-service monitors (DD-005) | Monitor edit — set a `priority` (P1-P5) so the receiver can tier a real page above a warning |
| No measured alert-event volume (DD-006) | Trigger a controlled test breach (never a real one) and confirm an event appears; if it does not, the monitor's notify path is broken even though its config looks fine |
| Placeholder or template artifacts left un-filled (DD-007) | Monitor edit — replace the placeholder `@handle`, fill in the real APM operation name in the query, or replace the literal `$service`/`$env` tag value with the real one |
| Over-broad `@all`/`@everyone` (DD-008) | Monitor's Notify section — replace the broadcast handle with the owning team's handle, or confirm the breadth is deliberate and record why |
| Missing recovery/no-data/renotify/auto-resolve (DD-010 to DD-014) | Monitor edit > Advanced options — set recovery thresholds, no-data handling, renotify caps |
| Receiver noise concentration (DD-016) | Split the noisy monitors onto a separate ticket/low-urgency route, or tune them (recovery threshold, renotify cap), so the real page is not buried on the shared handle |
| Stuck-in-Alert monitors (DD-017) | Monitor edit > Advanced options — fix the query/thresholds so the monitor can recover and re-alert on a fresh breach |
| Ratio with no volume floor (DD-018) | Monitor edit — add a composite `AND` clause requiring a minimum denominator (hit/request count) alongside the ratio |
| Impossible or tautological threshold (DD-019) | Monitor edit — set a threshold the metric can actually recover below/above; this is frequently the real fix behind a DD-017 stuck monitor |
| Vendor quality issues (DD-015) | Datadog's own Monitor quality view lists each issue with its fix |
| Indefinite mutes and broad downtimes (DD-020 to DD-022) | Monitor > unmute, or Downtimes list — scope and time-bound the downtime |
| Downtime intent decay (DD-023) | Downtimes list — cancel the downtime now, or replace it with a properly scoped, time-bound one if the suppression is still needed |
| Stale, composite-broken, untagged monitors (DD-030, DD-031, DD-034) | Monitor edit — retire stale monitors, repair composite references, add service/team tags |
| SLOs without a monitor (DD-032) | SLO edit — attach or create a burn-rate/error-budget monitor |
| Tag-vs-query scope mismatch (DD-035) | Monitor edit — set the tag to match the value the query scope actually evaluates against |
| Duplicate monitors (DD-036) | Retire the redundant copy, or reconcile the drifting thresholds into one monitor with the intended value |
| Never-evaluated monitors (DD-037) | Monitor edit — confirm the metric exists and is emitting; repair the query or the integration that was supposed to feed it |
| Paused Synthetic behind a live monitor (DD-038) | Synthetics list — resume the test, or mute/retire the monitor it backs so it stops reporting a stale state |
| Custom-metric or dashboard cost (DDOPT-NNN) | Metrics Summary and Dashboard list — trim high-cardinality custom metrics and unused dashboards |
| Topology readiness gaps with no finding | `/scoutflo:map-topology` |

## Common Failure Modes

All thresholds and windows named in the checks are example values; tune them to your workloads before treating a miss as a failure.

| Failure | Prevention |
| --- | --- |
| 403 read as a scope problem when it is a wrong-site problem | Check `datadog.site` first; a valid key on the wrong site 403s |
| Auditing with only the API key | Datadog needs the API + app key pair; both headers on every management call |
| v1 downtime endpoint used | v1 downtimes are deprecated including reads; read `/api/v2/downtime` only |
| Draft monitor counted as coverage | Drafts never notify; DD-003 excludes them from the covered set |
| Recovery threshold flagged on a monitor type that has none | Event and composite monitors have no recovery concept; exclude them, do not fail them |
| No-data handling judged by a blanket rule | notify_no_data=false is a blind spot on a heartbeat, correct on a spiky metric; judge by intent |
| Dead-handle check asserted on plain email handles | Resolve integration handles (`@slack-`, `@webhook-`, `@pagerduty-`); mark plain email liveness unverifiable |
| Datadog's own quality_issues ignored | Read `monitor/search` quality_issues; report vendor flags alongside findings, name disagreements |
| Cost section scored into the number | DDOPT findings are non-scored, `points_recoverable: 0`, excluded when the probe is skipped |
| Cost savings invented | Only quote a dollar figure Datadog's usage endpoint computed; presence facts carry no estimate |
| App key created under a personal login | App keys die with their user; create the audit key under a service account |
| Monitor message with a secret written to evidence | Capture IDs, names, options, tags; never a raw message body carrying a secret |
| A placeholder handle counted as real coverage | `test("@")` alone is not liveness; DD-007 flags `@your-team-handle`-shaped, `__..._placeholder__`, and literal `$service`/`$env` template artifacts even when DD-001 sees an `@` and passes |
| A ratio monitor's threshold judged on the percentage alone | DD-018 checks for a volume floor on the denominator, not just the ratio's threshold; a scary-looking percentage on a tiny sample is not the same defect as one on real traffic |
| A stuck-in-Alert monitor (DD-017) treated as a flapping/notification problem | Check the threshold shape first (DD-019); an impossible or tautological comparator is a frequent root cause a notification-side fix cannot solve |
| Zero alert events over the window read as "no monitor fires" | Cross-check against `overall_state_modified`; zero events with zero recent state transitions is a quiet window, not proof of a broken pipe — only zero events **with** a recent transition is the DD-006 fail |
| A stale-looking downtime message trusted at face value | A downtime that says "temporary" is not evidence it stayed temporary; DD-023 checks the age against the intent, not the wording alone |
| A paused Synthetic's monitor read as healthy because `overall_state` is `OK` | `overall_state` reflects the last real evaluation, not the Synthetic's current run status; join `monitor_id` against the Synthetic's own `status` (DD-038) before trusting the state |
