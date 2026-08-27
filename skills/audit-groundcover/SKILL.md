---
name: audit-groundcover
description: Read-only scored audit of groundcover monitors and alerting hygiene across per-monitor firing controls (pendingFor, hysteresis resolve threshold, auto-resolve, no-data and execution-error state), notification noise (re-notification interval, status filters, route-bypass), monitor health and silence hygiene, and destination liveness via workflows; writes findings.json and report.md and changes nothing. Use when the user mentions auditing or scoring groundcover, groundcover monitors, groundcover alerts, flapping or no-data groundcover monitors, groundcover notification routes, or groundcover silences. Do not use to change groundcover (no setup-groundcover ships yet; the audit names each fix), or for the underlying metrics/traces/logs data groundcover queries (audit the monitors, not the telemetry).
---

# audit-groundcover

Scored, read-only audit of the groundcover monitors that watch your telemetry: whether each monitor's firing controls are tuned so it does not flap or fire on transient blips, whether its notification settings avoid repeat-page storms and resolve-churn, whether the monitor is actually evaluating rather than paused or silenced, and whether the destinations it routes to are live. It answers one question: when a condition trips in groundcover tonight, does a well-tuned monitor fire once to a reachable destination without drowning the responder in repeats?

This skill audits the groundcover **monitors and alerting layer**, not the metrics, traces, or logs the monitors query. The upstream data quality is out of scope; this audit picks up at the monitor definition.

groundcover's monitors and workflows are built on Keep, which means it is strong on per-monitor firing hygiene but deliberately thin on cross-alert controls: it has **no group-by alert bundling, no inhibition rules, and no native deduplication, throttling, or rate-limiting primitive** (any such logic is hand-coded in Workflow filter blocks). This audit scores what groundcover actually offers and states that ceiling plainly rather than filing findings for controls the platform does not have.

Every command is read-only: a list/read GET, plus two documented read-by-query POSTs (`POST /api/monitors/list` and `POST /api/workflows/list`, which return data and change nothing). Every mutating verb — creating or editing a monitor, silence, route, or workflow — is forbidden; the full list is in [references/groundcover-checks.md](references/groundcover-checks.md) section 13. There is no `setup-groundcover` yet, so every finding names its manual fix path in the groundcover UI instead of a setup anchor.

**Multiple groundcover targets, one run:** `groundcover` may be a single block (one optional `api_url`, one `token_env`, optional `backend_id`) or a **list of labeled targets**, each with its own `api_url`, `token_env`, and optional `backend_id`. The audit **iterates every target** — enumerate them with `sh "${CLAUDE_PLUGIN_ROOT}/report-standard/toolkit-targets.sh" <cfg> groundcover labels` and run the full sequence below once per target with `SCOUTFLO_TARGET=<label>` set. Output goes to `groundcover/<label>/<date>/` for a list, or the flat `groundcover/<date>/` for a single block. Every request resolves and uses the target's own API base, key, and backend id (`token_env` names the variable holding the secret); there is no ambient default, and the key plus host (and backend id) select the target.

Run this standalone, from `/scoutflo:audit-all`, or on a schedule via `/scoutflo:schedule-audits`.

Outputs, per the [report standard](../../report-standard/README.md):

- `./scoutflo-audits/groundcover/[<label>/]<YYYY-MM-DD>/findings.json` per the [findings schema](../../report-standard/findings-schema.md), finding IDs `GC-NNN`
- `./scoutflo-audits/groundcover/[<label>/]<YYYY-MM-DD>/report.md` per the [report template](../../report-standard/report-template.md), including the `## Inventory` section (the `render-report-viz.sh inventory` output)
- `./scoutflo-audits/groundcover/[<label>/]<YYYY-MM-DD>/inventory.json` per the [inventory schema](../../report-standard/inventory-schema.md) (`scoutflo-inventory/v1`): the complete Phase-2 catalog — one item per monitor, workflow, and recurring silence (`kind`: `monitor`, `workflow`, `silence`) — each with `kind`, `covers`, `enabled`, `severity`, and `routes_to` for alerting objects. Built from the raw pull, never invented; redacted at capture, never a secret value.
- One appended line in `./scoutflo-audits/groundcover/[<label>/]history.jsonl`
- One Slack brief, when `slack.webhook_env` is configured

## Doctor gate

| Integration | toolkit.yaml keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| groundcover | `groundcover.token_env`, optional `groundcover.backend_id`, `groundcover.api_url` | the variable named by `token_env` (`GROUNDCOVER_API_KEY`) | API key on a **Viewer**-role service account (recipe in `/scoutflo:connect`) | read-only |
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
# Resolve the CURRENT groundcover target from toolkit.yaml — a single block, or the
# SCOUTFLO_TARGET-selected item of a labeled list (the shared enumerator handles both; no yq
# required). Every request below names this target's own api_url/token/backend_id; ambient
# values are never assumed.
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GC_KIND=$(sh "$TT" "$CFG" groundcover kind); GC_N=$(sh "$TT" "$CFG" groundcover count)
[ "${GC_N:-0}" -ge 1 ] || { echo "no groundcover target configured in $CFG; run /scoutflo:connect"; exit 1; }
GC_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$GC_N" ]; do [ "$(sh "$TT" "$CFG" groundcover label "$_i")" = "$SCOUTFLO_TARGET" ] && { GC_IDX=$_i; break; }; _i=$((_i+1)); done; fi
GC_LABEL=$(sh "$TT" "$CFG" groundcover label "$GC_IDX")
if [ "$GC_KIND" = seq ]; then GC_SEG="groundcover/${GC_LABEL}"; else GC_SEG="groundcover"; fi
GC_API=$(sh "$TT" "$CFG" groundcover get "$GC_IDX" api_url); [ -n "$GC_API" ] || GC_API="https://api.groundcover.com"   # groundcover.api_url override if set
GC_API="${GC_API%/}"
GC_BACKEND_ID=$(sh "$TT" "$CFG" groundcover get "$GC_IDX" backend_id)   # groundcover.backend_id; X-Backend-Id header on multi-backend accounts
echo "groundcover target: ${GC_LABEL} (api ${GC_API}) -> ${GC_SEG}/"
# Load the home-anchored secret store so a token added to ~/.scoutflo/env (by connect,
# even mid-session) is seen here without re-exporting or opening a new terminal. It only
# sets *_env variables; no secret value is printed. A profile that already sources it makes
# this a no-op. This mirrors what /scoutflo:doctor does, so doctor and this audit agree.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
for bin in curl jq; do
  command -v "$bin" >/dev/null || { echo "missing binary: $bin"; exit 1; }
done
# groundcover.token_env names the variable holding THIS target's key; read that variable by name so
# each target uses its own key. Presence check only, never print the value.
GC_TOKVAR=$(sh "$TT" "$CFG" groundcover get "$GC_IDX" token_env); [ -n "$GC_TOKVAR" ] || GC_TOKVAR=GROUNDCOVER_API_KEY
GROUNDCOVER_API_KEY=$(printenv "$GC_TOKVAR" 2>/dev/null || true)
[ -n "${GROUNDCOVER_API_KEY:-}" ] || { echo "GROUNDCOVER_API_KEY is not set — add it to ~/.scoutflo/env (echo 'export GROUNDCOVER_API_KEY=\"<paste>\"' >> ~/.scoutflo/env; chmod 600 ~/.scoutflo/env), or run /scoutflo:connect. The plugin reads that file, not your interactive shell."; exit 1; }

# There is no whoami endpoint; listing monitors is the auth probe. The X-Backend-Id header
# (from groundcover.backend_id) is sent on multi-backend accounts. This POST lists, it does not mutate.
# Do NOT discard the body: a self-hosted groundcover behind an in-cluster ingress can answer 200
# with an HTML SPA/login/proxy page, which a status-only check would read as success. Capture the
# status AND the content-type, and record pass ONLY on 200 + JSON + a monitors-list shape assertion.
GC_BODY="$(mktemp)"
if [ -n "$GC_BACKEND_ID" ]; then
  META="$(curl -s -o "$GC_BODY" -w '%{http_code} %{content_type}' --max-time 10 \
    -H "Authorization: Bearer ${GROUNDCOVER_API_KEY}" -H "X-Backend-Id: ${GC_BACKEND_ID}" -H "Content-Type: application/json" \
    -X POST "${GC_API}/api/monitors/list" --data '{"sources":[]}')" || META="000 -"
else
  META="$(curl -s -o "$GC_BODY" -w '%{http_code} %{content_type}' --max-time 10 \
    -H "Authorization: Bearer ${GROUNDCOVER_API_KEY}" -H "Content-Type: application/json" \
    -X POST "${GC_API}/api/monitors/list" --data '{"sources":[]}')" || META="000 -"
fi
CODE="${META%% *}"; CT="${META#* }"
if [ "$CODE" = "200" ] && printf '%s' "$CT" | grep -qi json && jq -e 'type=="array" or type=="object"' "$GC_BODY" >/dev/null 2>&1; then
  rm -f "$GC_BODY"; echo "doctor gate: pass"
elif [ "$CODE" = "200" ]; then
  rm -f "$GC_BODY"; echo "monitors/list probe returned 200 but Content-Type='${CT}' / non-JSON body — on a self-hosted groundcover (non-api.groundcover.com) host this usually means the monitors API is not exposed there (an ingress/UI/proxy answered); a 200 HTML page is not proof of the monitors API"; exit 1
else
  rm -f "$GC_BODY"; echo "monitors/list probe returned ${CODE}: 401 = key invalid; 403 = key lacks Viewer access, or a multi-backend account is missing groundcover.backend_id (X-Backend-Id)"; exit 1
fi
```

Never proceed past a failed doctor check and never downgrade one into a finding. `/scoutflo:doctor` runs the same probe standalone.

Read-only is a real tier here: a Viewer-role service account cannot mutate, so binding the audit key to Viewer makes the read-only guarantee structural, not just convention. If a broader-role key is used the audit still runs, but record in the report that the audit credential can write.

## Live-safety gate

Print what you are pointed at and compare it to the config before the first real check:

```bash
set -eu
# Resolve the CURRENT groundcover target (single block, or the SCOUTFLO_TARGET-selected item of a
# labeled list) via the shared enumerator; no yq required. Re-resolved here because each block runs
# in a fresh shell. $CFG resolved the standard way (override -> project-local -> home).
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GC_KIND=$(sh "$TT" "$CFG" groundcover kind); GC_N=$(sh "$TT" "$CFG" groundcover count)
GC_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$GC_N" ]; do [ "$(sh "$TT" "$CFG" groundcover label "$_i")" = "$SCOUTFLO_TARGET" ] && { GC_IDX=$_i; break; }; _i=$((_i+1)); done; fi
GC_LABEL=$(sh "$TT" "$CFG" groundcover label "$GC_IDX")
if [ "$GC_KIND" = seq ]; then GC_SEG="groundcover/${GC_LABEL}"; else GC_SEG="groundcover"; fi
GC_API=$(sh "$TT" "$CFG" groundcover get "$GC_IDX" api_url); [ -n "$GC_API" ] || GC_API="https://api.groundcover.com"   # groundcover.api_url
GC_API="${GC_API%/}"
GC_BACKEND_ID=$(sh "$TT" "$CFG" groundcover get "$GC_IDX" backend_id)   # groundcover.backend_id; X-Backend-Id on multi-backend accounts
GC_TOKVAR=$(sh "$TT" "$CFG" groundcover get "$GC_IDX" token_env); [ -n "$GC_TOKVAR" ] || GC_TOKVAR=GROUNDCOVER_API_KEY
GROUNDCOVER_API_KEY=$(printenv "$GC_TOKVAR" 2>/dev/null || true)   # token_env names the variable; never a hardcoded name
[ -n "${GROUNDCOVER_API_KEY:-}" ] || { echo "GROUNDCOVER_API_KEY is not set — add it to ~/.scoutflo/env (echo 'export GROUNDCOVER_API_KEY=\"<paste>\"' >> ~/.scoutflo/env; chmod 600 ~/.scoutflo/env), or run /scoutflo:connect. The plugin reads that file, not your interactive shell."; exit 1; }
# groundcover has no whoami; the account is identified by the monitors the key reads.
if [ -n "$GC_BACKEND_ID" ]; then
  MON_SAMPLE="$(curl -fsS --max-time 15 -H "Authorization: Bearer ${GROUNDCOVER_API_KEY}" -H "X-Backend-Id: ${GC_BACKEND_ID}" \
    -H "Content-Type: application/json" -X POST "${GC_API}/api/monitors/list" --data '{"sources":[]}')"
else
  MON_SAMPLE="$(curl -fsS --max-time 15 -H "Authorization: Bearer ${GROUNDCOVER_API_KEY}" \
    -H "Content-Type: application/json" -X POST "${GC_API}/api/monitors/list" --data '{"sources":[]}')"
fi
COUNT="$(printf '%s' "$MON_SAMPLE" | jq 'if type=="array" then length else (.monitors // .results // []) | length end')"
TITLES="$(printf '%s' "$MON_SAMPLE" | jq -r 'if type=="array" then . else (.monitors // .results // []) end | [.[0:3][].title] | join(", ")')"
echo "groundcover target: ${GC_LABEL} api=${GC_API} monitors=${COUNT} -> ${GC_SEG}/ sample: ${TITLES}"
printf '%s' "$MON_SAMPLE" | jq -e 'if type=="array" then . else (.monitors // .results // []) end | type == "array"' >/dev/null \
  || { echo "monitors/list did not return a monitor list; wrong key, host, or backend_id — stop"; exit 1; }
echo "live-safety gate: pass — confirm these monitor titles belong to the account you intend to audit"
```

The key plus the API host (and backend id, if multi-backend) select the target; a labeled-list estate audits each target in turn (the runner sets `SCOUTFLO_TARGET=<label>`), so the account is the one the current `SCOUTFLO_TARGET` resolved, never an ambient default. The printed sample monitor titles are the human check: if they belong to a different environment than intended, stop and fix the exported key or `groundcover.backend_id` before any further read.

## Ground rules

- Configuration is metadata; execution state is proof. A monitor that exists is `configured`; a monitor whose config is tuned (a real `pendingFor`, resolve threshold, and re-notification setting) and that is actually evaluating is closer to `validated-live`. Where runtime state is readable (see the capability note below), a monitor observed firing-and-resolving is the strongest signal.
- API errors are evidence. A `401` means the key is invalid; a `403` means the key lacks Viewer access or a multi-backend account is missing `groundcover.backend_id`. Record which, never convert an error into empty success.
- Score what groundcover actually has. It has no group-by bundling, no inhibition, and no native dedup/throttle — those are Keep-hand-coded at best. Never file a finding for a missing control the platform does not offer; state the ceiling instead.
  - ❌ `GC fail: no alert grouping or inhibition configured.`
  - ✅ `Noise ceiling stated: groundcover has no group-by bundling or inhibition (it is built on Keep); this audit scores per-monitor firing hygiene and destination routing, which is what the platform offers.`
- Never score from monitor counts.
  - ❌ `Scored hygiene 90: eighty monitors exist.`
  - ✅ `Scored hygiene 45: sixty monitors evaluate, but forty have pendingFor 0s (fire on the first blip) and twelve set executionErrorState Alerting (broken queries page); credit stops at partial.`
- The runtime monitor-state source (per-monitor firing state, last error, silence flags) is **not confirmed in groundcover's public docs**. This audit probes for it once and, if it is absent or errors, marks the health checks that depend on it `not-in-scope` with that reason rather than guessing a monitor's live state. The config checks never depend on it.
- Silences: groundcover has one-time silences (no list endpoint) and recurring silences (`GET /api/monitors/recurring-silences`). This audit reads recurring silences for open-ended-suppression hygiene and states that one-time silences are not enumerable via the API, so a currently-silenced monitor may not be visible; it never claims a clean silence bill it cannot prove.
- Never write a monitor's raw query, a destination config, or a webhook to disk, evidence, or the report. Captures keep monitor UUIDs, titles, the tuning fields, and workflow/route metadata only.

## Version and shape traps

Current API-shape facts, all handled in the reference commands; do not "simplify" them away:

- **Auth is `Authorization: Bearer <key>` plus `X-Backend-Id` on multi-backend accounts.** A multi-backend account with no backend id 403s; that is a config gap, not an empty account.
- **Listing is a read-by-POST**: `POST /api/monitors/list` with `{"sources":[]}` (empty returns all). There is no whoami and no GET list; the POST is a query, not a mutation.
- **The dedup/grouping controls do not exist.** `category` groups the Monitor List UI only, not notifications. Do not read it as alert bundling.
- **`noDataState` defaults to `NoData` and `executionErrorState` defaults to `OK`.** So a no-data result does not page by default (quiet), but a monitor that sets `executionErrorState: Alerting` pages on its own broken query. Judge each against intent.
- **The runtime monitor-summary endpoint is unconfirmed in public docs.** Treat any per-monitor live state (firing history, last evaluation error, silence flags) as capability-gated: probe once, and if it is not there, the health checks are `not-in-scope`, never a fabricated pass or fail.
- **SaaS vs self-hosted are different API surfaces — detect which you are on.** On SaaS (`api.groundcover.com`) the `/api/monitors/*` paths in this skill are correct. On a **self-hosted** deployment (`api_url` set to any non-`api.groundcover.com` host — often an in-cluster service reached through a proxy) those same paths can `404` even with a valid token, because the self-hosted monitors component does not always expose the cloud monitors API at that base. Verified live (2026-07-26): a self-hosted `host_endpoint` authenticated the token but returned `404` on `/api/monitors/list` and `/api/monitors/summary/query`. When `api_url` is non-cloud and the monitors paths `404` after a `200`-authenticating base, do not report "no monitors": fall back to the **Alertmanager-compatible firing surface** `GET /api/alertmanager/grafana/api/v2/alerts` (the same fallback the platform itself uses for self-hosted Groundcover) for the firing-state signal, and mark the config-level monitor checks (`GC-001` to `GC-023`) `not-in-scope` with the reason "self-hosted monitors API not exposed at this host", never a fabricated pass. State plainly in the report which mode was detected.
- **Recurring silences are a first-class resource** (`GET /api/monitors/recurring-silences`); one-time silences have no list endpoint. There is no Terraform `groundcover_silence` resource, so silences are API/UI state, not declarative IaC.

## Estate sizing

Count before judging, and declare the path in the terminal output. The unit here is monitors:

```bash
set -eu
# Resolve the CURRENT groundcover target (single block, or the SCOUTFLO_TARGET-selected item of a
# labeled list) via the shared enumerator; no yq required. $CFG resolved the standard way.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GC_KIND=$(sh "$TT" "$CFG" groundcover kind); GC_N=$(sh "$TT" "$CFG" groundcover count)
GC_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$GC_N" ]; do [ "$(sh "$TT" "$CFG" groundcover label "$_i")" = "$SCOUTFLO_TARGET" ] && { GC_IDX=$_i; break; }; _i=$((_i+1)); done; fi
GC_LABEL=$(sh "$TT" "$CFG" groundcover label "$GC_IDX")
if [ "$GC_KIND" = seq ]; then GC_SEG="groundcover/${GC_LABEL}"; else GC_SEG="groundcover"; fi
GC_API=$(sh "$TT" "$CFG" groundcover get "$GC_IDX" api_url); [ -n "$GC_API" ] || GC_API="https://api.groundcover.com"   # groundcover.api_url
GC_API="${GC_API%/}"
GC_BACKEND_ID=$(sh "$TT" "$CFG" groundcover get "$GC_IDX" backend_id)   # groundcover.backend_id; X-Backend-Id on multi-backend accounts
GC_TOKVAR=$(sh "$TT" "$CFG" groundcover get "$GC_IDX" token_env); [ -n "$GC_TOKVAR" ] || GC_TOKVAR=GROUNDCOVER_API_KEY
GROUNDCOVER_API_KEY=$(printenv "$GC_TOKVAR" 2>/dev/null || true)   # token_env names the variable; never a hardcoded name
[ -n "${GROUNDCOVER_API_KEY:-}" ] || { echo "GROUNDCOVER_API_KEY is not set — add it to ~/.scoutflo/env (echo 'export GROUNDCOVER_API_KEY=\"<paste>\"' >> ~/.scoutflo/env; chmod 600 ~/.scoutflo/env), or run /scoutflo:connect. The plugin reads that file, not your interactive shell."; exit 1; }
SMALL_MAX_OBJECTS="30"    # example, tune to your environment
MEDIUM_MAX_OBJECTS="150"  # example, tune to your environment
BATCH_SIZE="50"           # monitors per batch on the large path; example, tune it
if [ -n "$GC_BACKEND_ID" ]; then
  MON_JSON="$(curl -fsS --max-time 30 -H "Authorization: Bearer ${GROUNDCOVER_API_KEY}" -H "X-Backend-Id: ${GC_BACKEND_ID}" \
    -H "Content-Type: application/json" -X POST "${GC_API}/api/monitors/list" --data '{"sources":[]}')"
else
  MON_JSON="$(curl -fsS --max-time 30 -H "Authorization: Bearer ${GROUNDCOVER_API_KEY}" \
    -H "Content-Type: application/json" -X POST "${GC_API}/api/monitors/list" --data '{"sources":[]}')"
fi
TOTAL="$(printf '%s' "$MON_JSON" | jq 'if type=="array" then length else (.monitors // .results // []) | length end')"
echo "groundcover target: ${GC_LABEL} monitors=${TOTAL} scored_objects=${TOTAL} -> ${GC_SEG}/"

# Guided-walkthrough drift check, per report-standard/README.md.
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${GC_SEG}"
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

- **Small** (`TOTAL <= SMALL_MAX_OBJECTS`): one pass over everything. No worklist, no batching.
- **Medium** (`TOTAL <= MEDIUM_MAX_OBJECTS`): per-category passes (firing hygiene, notification noise, health, coverage), completed in one run.
- **Large**: work monitors in batches of `BATCH_SIZE` against a durable, run-ID-keyed worklist per the worklist rules in [skill-authoring-conventions.md](../../docs/skill-authoring-conventions.md): scan for a resumable run before minting a new run ID, one row per monitor uuid, lock before claiming a batch, mark rows done only after their per-monitor reads succeed, and assert zero pending rows before Phase 8 writes anything.

Never silently truncate: name the monitor count audited and any batch skipped, and reflect it in the coverage denominators. Rate limits are not documented, so throttle defensively on the per-monitor read path per [references/groundcover-checks.md](references/groundcover-checks.md) section 9.

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

If `./scoutflo-audits/topology.md` exists, load it; its service list is the critical-service list and its names are canonical. Map monitors to services by the monitor's `labels`/`title` and the k8s fields groundcover monitors carry (namespace, workload). If topology.md does not exist, infer critical services from monitor titles and labels, note the inference, and suggest `/scoutflo:map-topology`.

## Phase 2: Read-only inventory

Build the raw picture with the commands in [references/groundcover-checks.md](references/groundcover-checks.md) section 4: the monitor list, then per monitor the full config (`GET /api/monitors/{uuid}`) capturing the tuning fields; the workflows list (`POST /api/workflows/list`) for destination liveness; and the recurring silences (`GET /api/monitors/recurring-silences`). Probe the runtime monitor-state endpoint once and record whether it is available. Judgment starts in Phase 3. A 403 is an auth/backend note; a 401 is a bad key.

## Phase 3: Monitor firing hygiene (GC-001 to GC-005)

Commands in section 5. These are the per-monitor quality controls, groundcover's real strength. Do not stop at "field X is unset" — that is a Prometheus-`for` linter line. Compute the consequence for each:

- **GC-001 (`evaluationInterval.pendingFor`)** — two failure modes, not one. *Too small:* `pendingFor` `0s`/empty fires on the first blip; do not report the count of such monitors, report the page volume — join each `pendingFor=0` monitor to its re-notify cadence (GC-010) and its destination, so the finding reads "the 12 `pendingFor=0` monitors routing to the same connectedApp each re-page every re-notify cycle; at that cadence the responder takes ~N repeats/day for transient blips". *Too large (the MTTD side this catalog historically missed):* an over-large `pendingFor` or coarse `evaluationInterval.interval` on a monitor that watches a topology critical service delays detection — compute worst-case detect time = `interval` + `pendingFor` and compare it to the service's stated detection SLO. `pendingFor` comes from `interval.for` in `summary/query`; verify against that, not `monitors/list` (which carries only `{uuid,title,type}`).
- **GC-002 (`customResolveThreshold`, hysteresis)** — name the boundary and the churn it produces, never the bare adjective "flaps". State the operator and value, and *where `summary/query` returned 200* cite the observed `state`/`alertingCount` transitions as the flap count; where runtime is unavailable or the field was not in the YAML enrichment, mark it `configured`/`not-in-scope-from-this-endpoint` and say the flap count could not be read — never assert "flaps" as fact. Chains with GC-001 (a monitor with neither `pendingFor` nor hysteresis is doubly flap-prone) and GC-010/GC-011 (each flap cycle is one page, two with `Resolved`).
- **GC-003 (`autoResolve`)** — a monitor that never auto-resolves pins a stale alert in the active list forever, masking the next real page for the same service. Join the flagged monitors to whether they watch a critical service and count how many; "checkout-error-rate never auto-resolves, so a transient spike stays active and hides the next real checkout page". Chains with GC-022 (a stuck-firing monitor in the runtime source is the live proof).
- **GC-004 (`noDataState`)** — for each `Alerting`-on-no-data monitor, state whether its target signal is sampled/intermittent (a low-traffic endpoint predictably goes no-data off-hours and pages every empty scrape overnight) versus a true heartbeat monitor (where `Alerting` is correct). Count intermittent vs heartbeat; the finding is the intermittent set, not the default `NoData`.
- **GC-005 (`executionErrorState`)** — report the distribution, because both sides fail: `Alerting`-on-error pages on the monitor's OWN broken query (a self-inflicted page — name the monitors and the destination the false page lands on), while `OK`-at-scale silently hides a monitor whose query is permanently broken and will never fire. Chains with GC-022 (`lastEvaluationError` is the live evidence a query is actually erroring) and GC-030 (an error-state page into a dead workflow is doubly wasted).

- ❌ `Hygiene pass: monitors have thresholds.`
- ✅ `Hygiene partial: sixty monitors evaluate, but forty have pendingFor 0s (GC-001) routing to the #oncall connectedApp — each re-pages every cycle — and eight set executionErrorState Alerting on queries that error intermittently (GC-005), pages fired by the monitor's own breakage; affected: checkout-latency, payments-error-rate.`

## Phase 4: Notification noise (GC-010 to GC-014)

Commands in sections 6 and 6.1. **These checks all key off `notificationSettings` (`renotificationInterval`, `statusFilters`, `method`, `connectedApps`), which `POST /api/monitors/summary/query` does NOT return — the only carrier is the per-monitor YAML enrichment in section 4, observed thin live (0/69).** When those fields were not captured this run, `notif_present()` is false and GC-010 to GC-014 are `not-in-scope-from-this-endpoint`, and any finding below that says the join could not be computed — never a fabricated pass or a blast radius you did not derive.

- **GC-010 (re-notify cadence)** — this is the noise *multiplier*; compute it, do not restate the field. Sum over currently/recently firing monitors of their re-notify cadence to state pages/day into each destination: "34 firing monitors x default re-notify = the responder's one channel receives ~N repeats/day, burying the 3 monitors that page a human" — the direct groundcover analogue of the doctrine's "47 noisy rules bury the 3 real pages". It is also two-sided: separately flag `disableRenotification: true` on a monitor that maps to a critical service, because there a single missed page is unrecoverable. Multiplies every firing event GC-001/GC-002/GC-011 supply.
- **GC-011 (`Resolved` in `statusFilters`)** — only meaningful on high-churn monitors: intersect the `Resolved`-filter set with the GC-001/GC-002 flap-prone set and (where `summary/query` is 200) the highest-`alertingCount` monitors — "the 6 flappiest monitors also emit `Resolved`, so each flap cycle sends 2 messages". A `Resolved` filter on a stable monitor is fine; say so, do not flag it universally.
- **GC-012 (`method`/route-bypass)** — compute the route-bypass *share* (`connectedApps` monitors / total paging monitors) against `ROUTE_BYPASS_SHARE=0.30` and state the operational cost: "N% of monitors page via ad-hoc `connectedApps`, so when a destination breaks there is no central route to fix once — every monitor must be edited individually". For `method: noNotifications`, join to critical services: a should-page monitor set silent is a coverage hole that feeds the flagship.
- **GC-013 (paging monitor with no destination)** — do not stop at "empty `connectedApps`"; resolve the destination-less monitor to the critical service it silently fails to protect (by `labels`/`namespace`/`workloadName`, from the section 4 enrichment): "checkout-error-rate is the ONLY monitor for checkout and it resolves to no destination — checkout has zero working paging path tonight". When it is the sole monitor for a critical service, escalate to **critical** (the severity table's "a critical service is invisible, nobody finds out"). This is a core leg of the flagship silent-paging-path; gate the service join behind the label fields being present (see the flagship note in Phase 6).
- **GC-014 (duplicate/overlapping monitors — verify-pending, new)** — section 6.1. groundcover has no native dedup, so N monitors on the same `(namespace, workloadName, type)` routing to the same destination fire N simultaneous pages for one condition. Report the group's `duplicate_count` and named monitors, multiplied by GC-010's cadence for redundant pages/day. **Verify-pending and gated:** it computes only when the dedup-key fields were captured (section 4); otherwise `not-in-scope-from-this-endpoint`, and its status stays unproven until a first live run.

## Phase 5: Monitor health and silences (GC-020 to GC-023)

Commands in section 7.

- **GC-020 (`isPaused`)** — a paused monitor is defined but never evaluates. Do not just list paused monitors; join each to the topology critical-service list (by title/labels/namespace/workloadName) and count paused-on-critical vs paused-scratch: "payments-latency is paused, so payments has no evaluating latency monitor — the SLO is unwatched". A paused scratch monitor is not a finding; a paused monitor named for a live SLO is a coverage gap and a fourth way a service that "has a monitor" is actually blind (feeds the flagship). `isPaused` comes from `summary/query`, so this runs whenever that call was 200.
- **GC-021 (open-ended/blanket recurring silence, high)** — do not stop at `matcher_count == 0`; resolve the silence matcher against the monitor set to name the monitors and services it blacks out: "the recurring silence with empty matchers on a permanent daily schedule suppresses ALL N monitors 24/7, including checkout-error-rate and payments-latency — every one is silently blacked out during the window". Even a narrow matcher is a finding when it permanently covers a critical-service monitor. Chains with GC-032 (coverage would falsely read green) and is the fourth leg of the flagship.
- **GC-022 / GC-023 (runtime-state-gated)** — **only when `summary/query` returned 200 in Phase 2**: monitors stuck permanently firing or in an evaluation-error state (`GC-022`), and monitors fully silenced with no end in sight (`GC-023`). When the runtime endpoint is unavailable, both are `not-in-scope` with that reason, and the report states that live monitor state could not be read, so one-time-silenced or stuck monitors may not be visible — never a fabricated pass or invented state.

## Phase 6: Coverage and destination liveness (GC-030 to GC-032)

Commands in section 8.

- **GC-030 (dead workflow-backed destination, high)** — do not stop at the workflow object; follow the dead destination *forward* to the monitors and critical services whose pages vanish through it. For each workflow with `invalid: true` / `last_execution_status == "error"` / any provider `installed: false`, join back to the monitors routing to that workflow/provider and forward to their services: "the Slack workflow is `installed:false` and is the destination for 8 monitors covering checkout, payments and search — all three fire alerts into the void tonight". The count is what makes it **critical** rather than high when a sole critical-service path is dead. This is the keystone of the flagship. `workflows/list` is confirmed; the monitor->workflow join needs the per-monitor `connectedApps`/route fields, so gate it on their presence (see the flagship note).
- **GC-031 (severity distribution)** — the histogram alone proves nothing (that is the "never score from counts" anti-pattern). Make it operational by joining to routing: if `TOP_SEVERITY_SHARE > 0.80` AND the notification routes/workflows do not branch on severity, then "every monitor pages the same destination at the same priority, so a P4 disk nudge and a P1 checkout-down page land identically — the responder cannot triage by signal". If routes are unreadable (BYOC, no REST list), state that and keep GC-031 `configured`/best-effort — do not assert the impact.
- **GC-032 (critical-service coverage, high — the flagship assembly point)** — redefine coverage to a *working paging path*, not monitor-presence. A critical service is covered only when a monitor for it (by labels/namespace/workloadName) is **not paused** (GC-020), **not blanket-silenced** (GC-021), **routes to a destination** (not GC-013 empty / not GC-012 `noNotifications`), and **that destination is a live workflow provider** (not GC-030 `installed:false`/invalid/error). State per uncovered service which leg fails: "search has a monitor, but it routes to an `installed:false` Slack provider — search is uncovered at the paging layer despite a green monitor count".

Notification-route overlap is best-effort: the routes list has no confirmed REST endpoint and is BYOC-only, so when routes cannot be read the report says so rather than asserting a clean routing bill.

> **Flagship correlation — the silent paging path (verify-pending assembly).** The single most valuable line this audit produces: *a critical service that reads "monitored" in the coverage matrix but whose alert cannot reach a human tonight.* Assemble it at GC-032 by joining, per critical service (resolved via monitor labels/namespace/workloadName to `topology-export.json`): does a monitor exist AND is it evaluating (not GC-020 paused) AND not blanket-silenced (GC-021) AND does it route to a destination (not GC-013 empty / not GC-012 `noNotifications`) AND is that destination a live workflow provider (not GC-030 `installed:false`/invalid/error)? If any leg fails, the service is uncovered at the paging layer despite a green monitor count, and the finding escalates to **critical**. No free scanner assembles monitor -> `notificationSettings.method`/`connectedApps` -> `workflow.providers[].installed` -> topology critical service; groundcover's own UI shows a green monitor and never tells you the Slack provider behind it is uninstalled. **Honesty gate (non-negotiable):** every leg past monitor-existence keys off `method`/`connectedApps`/`labels`/`namespace`/`workloadName`, which `summary/query` does not carry and the per-monitor YAML enrichment supplied 0/69 on the only estate seen so far. When those fields are absent this run, do NOT present the cascade as computed — state per service that the destination/label join could not be read from this endpoint and mark the coverage leg `not-in-scope-from-this-endpoint`, exactly as section 6's `notif_present()` gate does. The cascade is real only when the join fields are; this is unproven until a first live run with a read-only token confirms they populate.

## Phase 7: Coverage matrix and topology readiness

Fill one row per critical service using the per-service mapping in section 10 and the check-result vocabulary (`pass`, `partial`, `fail`, `blocked`, `not-in-scope`):

| Service | Ready | Firing hygiene | Notification | Health | Liveness | Gap |
| --- | --- | --- | --- | --- | --- | --- |

Every cell carries its `passed/total` denominator. Runtime-gated cells read `not-in-scope` when the state endpoint was unavailable, not `fail`. Name affected services in findings.

Then render the Scoutflo Topology Readiness section per [topology-readiness.md](../../report-standard/topology-readiness.md): evaluate the six checks per critical service from `./scoutflo-audits/topology-export.json`, read-only. A `MONITORED_BY` connection to groundcover that this audit verified live (the monitor evaluates and its destination is a live workflow) counts toward Match confidence per the standard's live-verification rule. Gaps that map to an existing finding reference its ID; gaps with no finding get a `TOPO-` row pointing at `/scoutflo:map-topology`. Render check names and confidence per the standard: plain-English column headers, confidence as `n/10`, and — whenever any service is below ready — the ticket-ready readiness action plan table. If the export or topology.md is missing, or exists but describes a different target than this audit covers, the section renders the matching state from topology-readiness.md with its one-line unlock; it never guesses and never says a bare "unavailable". Readiness is reported, never folded into the 0-100 score.

**Provider-identity note, verified against the platform's current model:** `groundcover` is a valid provider identity with a typed attribute schema on the Scoutflo platform (`monitoring.groundcover`), an alerting provider like PagerDuty (a `MONITORED_BY` connection can reach full confidence when its fields are present and this audit verified the path live). Unlike most providers in this toolkit, its schema **requires `namespace` and `workloadName`** (plus optional `serviceName`, `clusterId`, `deploymentName`, `podPattern`, `containerName`), which gives a groundcover connection a strong Kubernetes-anchored identity when those are populated. The identity fields are camelCase (`workloadName`, `serviceName`), and the platform's correlation-category mapping does not split camelCase, so populating only `workloadName`/`serviceName` satisfies Connection details but leaves the Match confidence anchor unpopulated (see [topology-readiness.md](../../report-standard/topology-readiness.md)'s internal note on this exact pattern). Mirror those values into literal `workload_name`/`service_name` keys on the same connection's attributes, or Match confidence reads partial even though the connection genuinely resolved. State which fields the export carries versus which the schema requires when a connection stalls at partial.

## Phase 8: Score, write, brief

Score per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md): each check yields `pass` (1.0), `partial` (0.5), `fail`/`blocked` (0), `not-in-scope` leaves the denominator. Category score is the credit ratio times 100 rounded down; overall is the weight-normalized sum over included categories. Whole categories or checks that could not be assessed (the runtime-state-gated health checks when that endpoint is absent; routes when they cannot be read) are excluded, renormalized, and stated; blocked checks inside an assessable category score 0. Score conservatively: when unsure between two results, pick the lower and say why. Assign each category a maturity value (`reactive`, `proactive`, `systematic`).

| Category | Weight | ID range |
| --- | ---: | --- |
| Monitor firing hygiene | 35 | GC-001 to GC-005 |
| Notification noise | 25 | GC-010 to GC-014 |
| Monitor health and silences | 15 | GC-020 to GC-023 |
| Coverage and destination liveness | 25 | GC-030 to GC-032 |

Weights sum to 100 and are unchanged this increment: the new GC-014 folds into the existing **Notification noise** category (still weight 25), so no rebasing of historical scores. The proposed shift of 5 points toward Coverage/liveness is **deferred** until a live run proves the destination/coverage join fields (`method`/`connectedApps`/labels) actually populate — reweighting onto legs that today rest on fields observed absent would not be honest.

The full check catalog and the target profile (what 100 means per category) are at the top of [references/groundcover-checks.md](references/groundcover-checks.md). IDs are stable: the same defect gets the same ID every run, one finding per failed check, affected monitors enumerated. Compute `points_recoverable` per finding by re-running the scoring model with that check at full credit; `info` findings and excluded categories carry 0. The executive summary states the gap to target and the two or three findings with the highest `points_recoverable` as the biggest levers.

End-to-end gate: claim end-to-end coverage only when the overall score is at or above 85, every critical service passes every applicable coverage row, and no category was excluded. Below the gate, write "good base coverage", never "end to end". A run whose monitor-health category was runtime-gated out cannot claim end-to-end monitor health; say which categories the claim rests on.

Lifecycle, exemptions, and totals, before rendering the report:

1. Load the previous run's `findings.json` when one exists; classify every finding per the lifecycle table in the [findings schema](../../report-standard/findings-schema.md) (`new`, `unchanged`, `regressed`; resolved IDs go to the delta, and the executive summary names regressions first).
2. Load `./scoutflo-audits/exemptions.yaml` when present. Entries with `id`, `reason`, and `expires` all set and unexpired suppress their finding into the Suppressed appendix; malformed or expired entries are reported, never honored.
3. Every findings area and coverage cell carries its denominator (`passed/total`).

Emit and verify:

```bash
set -eu
# Resolve the CURRENT groundcover target (single block, or the SCOUTFLO_TARGET-selected item of a
# labeled list) via the shared enumerator; no yq required. $CFG resolved the standard way.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GC_KIND=$(sh "$TT" "$CFG" groundcover kind); GC_N=$(sh "$TT" "$CFG" groundcover count)
GC_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$GC_N" ]; do [ "$(sh "$TT" "$CFG" groundcover label "$_i")" = "$SCOUTFLO_TARGET" ] && { GC_IDX=$_i; break; }; _i=$((_i+1)); done; fi
GC_LABEL=$(sh "$TT" "$CFG" groundcover label "$GC_IDX")
if [ "$GC_KIND" = seq ]; then GC_SEG="groundcover/${GC_LABEL}"; else GC_SEG="groundcover"; fi
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${GC_SEG}/${RUN_DATE}"
mkdir -p "$OUT"
# ... write findings.json, inventory.json, and report.md per the report standard. The findings.json
# ".target" is the per-target slug (equal to $GC_SEG: "groundcover" for a single block,
# "groundcover/<label>" for a labeled list target), so audit-all/correlation/render disambiguate
# multiple targets. Verify:
jq -e --arg seg "$GC_SEG" '.schema == "scoutflo-findings/v1" and .target == $seg and (.findings | type == "array")' \
  "$OUT/findings.json" >/dev/null && echo "findings.json valid"
grep -q '^# ' "$OUT/report.md" && echo "report.md present"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-findings.sh" "$OUT/findings.json"
# Inventory (scoutflo-inventory/v1): the complete Phase-2 catalog of what exists,
# built from the raw pull (never invented, redacted). counts.total must reconcile
# with items; the ## Inventory section of report.md IS this render.
jq -e --arg seg "$GC_SEG" '.schema == "scoutflo-inventory/v1" and .target == $seg and (.items | type == "array") and (.counts.total == (.items | length))' "$OUT/inventory.json" >/dev/null && echo "inventory.json valid"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" inventory "$OUT/inventory.json" >/dev/null && echo "inventory section renders"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" html "$OUT/findings.json" "$OUT/report.html" "$(dirname "$OUT")/history.jsonl"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-report.sh" "$OUT/report.md"
```

Compute the delta against the previous run's `findings.json` (the latest two date directories; first run states "first run, no delta"), then append one line to the history ledger, replacing any line for the same date:

```bash
set -eu
# Resolve the CURRENT groundcover target (single block, or the SCOUTFLO_TARGET-selected item of a
# labeled list) via the shared enumerator; no yq required. $CFG resolved the standard way.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GC_KIND=$(sh "$TT" "$CFG" groundcover kind); GC_N=$(sh "$TT" "$CFG" groundcover count)
GC_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$GC_N" ]; do [ "$(sh "$TT" "$CFG" groundcover label "$_i")" = "$SCOUTFLO_TARGET" ] && { GC_IDX=$_i; break; }; _i=$((_i+1)); done; fi
GC_LABEL=$(sh "$TT" "$CFG" groundcover label "$GC_IDX")
if [ "$GC_KIND" = seq ]; then GC_SEG="groundcover/${GC_LABEL}"; else GC_SEG="groundcover"; fi
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${GC_SEG}"
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${TARGET_DIR}/${RUN_DATE}"
RESOLVED="0"   # fixed count from this run's delta; 0 on the first run
LINE="$(jq -c --arg d "$RUN_DATE" --argjson resolved "$RESOLVED" \
  '{run_date:$d, skill:"audit-groundcover", overall:.score.overall, gate:.score.gate,
    end_to_end:.score.end_to_end, severity_counts:.severity_counts,
    lifecycle_counts:((reduce .findings[].lifecycle as $l ({}; .[$l] = (.[$l] // 0) + 1)) + {resolved:$resolved})}' \
  "$OUT/findings.json")"
TMP="$(mktemp)"
[ -f "${TARGET_DIR}/history.jsonl" ] && grep -v "\"run_date\":\"${RUN_DATE}\"" "${TARGET_DIR}/history.jsonl" > "$TMP" || true
printf '%s\n' "$LINE" >> "$TMP"
mv "$TMP" "${TARGET_DIR}/history.jsonl"
tail -1 "${TARGET_DIR}/history.jsonl" | jq -e '.run_date and (.overall >= 0)' >/dev/null && echo "history.jsonl updated"
```

The report's trend line renders the last five history.jsonl entries, oldest first. After the report is written, close with the run-completion message per the report standard ([report-template.md](../../report-standard/report-template.md#run-completion-message-what-the-skill-says-in-chat-when-the-run-finishes)): the one-line score headline, the top fixes by points_recoverable, the **absolute** report path, the OS-specific open command, and the leak-safe share pointer (Slack brief). Then send the Slack brief exactly as [report-template.md](../../report-standard/report-template.md) specifies: score, severity counts, top finding titles, delta line, topology readiness line, report path — titles only, never evidence values, monitor titles allowed. When invoked by `audit-all`, skip the brief; the orchestrator sends exactly one combined message per run. Keep `./scoutflo-audits/` out of public version control; reports describe your alerting setup.

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

No `setup-groundcover` ships yet, so every finding's `remediation` field names the concrete manual fix location. When a setup skill lands, these become anchors without the finding IDs changing:

| Finding area | Fix location today |
| --- | --- |
| Fire-on-first-blip, no hysteresis, no auto-resolve (GC-001 to GC-003) | Monitor edit > Evaluation / Thresholds — set `pendingFor`, add a `customResolveThreshold`, enable `autoResolve` |
| No-data and execution-error state (GC-004, GC-005) | Monitor edit > Advanced — set `noDataState`/`executionErrorState` deliberately, not paging on empty or broken queries at scale |
| Repeat-page storms, resolve-noise, route-bypass, no destination (GC-010 to GC-013) | Monitor edit > Notifications — set `renotificationInterval` or `disableRenotification`, trim `statusFilters`, prefer notification routes over `connectedApps`, wire a destination |
| Duplicate/overlapping monitors on the same target (GC-014) | Monitors > (the duplicate set) — consolidate into one monitor keeping the best-tuned one, or differentiate them deliberately (distinct conditions/severities) and record why |
| Paused live monitor, open-ended recurring silence (GC-020, GC-021) | Monitor List — unpause the monitor; Silences > Recurring — bound or narrow the recurring silence |
| Stuck-firing / error-state / fully-silenced monitors (GC-022, GC-023) | Monitor details — fix the query or condition; clear the silence (only assessable when the runtime state endpoint is available) |
| Dead workflow destination (GC-030) | Workflows / Integrations > Destinations — reinstall the provider or fix the failing workflow |
| Severity not used, uncovered critical service (GC-031, GC-032) | Set monitor `severity` deliberately; add a monitor for the uncovered service |
| Topology readiness gaps with no finding | `/scoutflo:map-topology` |

## Common Failure Modes

All thresholds and windows named in the checks are example values; tune them to your workloads before treating a miss as a failure.

| Failure | Prevention |
| --- | --- |
| Filing findings for missing grouping/inhibition/dedup | groundcover has none of these (it is built on Keep); state the ceiling, never file a finding for a control the platform lacks |
| Runtime monitor state assumed readable | The monitor-summary endpoint is not confirmed in public docs; probe once, mark GC-022/GC-023 `not-in-scope` if absent, never guess a monitor's live state |
| Multi-backend 403 read as an empty account | A multi-backend account needs `groundcover.backend_id` (the `X-Backend-Id` header); a 403 there is a config gap, not "no monitors" |
| `category` read as alert grouping | `category` groups the Monitor List UI only; it does not bundle notifications |
| No-data default misread | `noDataState` defaults to `NoData` (quiet); the finding is a monitor set to `Alerting` on no-data, not the default |
| One-time silence assumed visible | One-time silences have no list endpoint; the report states a silenced monitor may not be visible rather than claiming a clean silence bill |
| Recurring silence with a broad matcher passed as fine | An open-ended recurring silence with a broad matcher is a standing blackout (GC-021) |
| Monitor count scored as coverage | Count monitors that actually evaluate and route to a live destination, per service |
| `connectedApps` route-bypass ignored at scale | Many monitors bypassing notification routes via `connectedApps` fragments delivery control (GC-012) |
| Dead workflow destination missed | A workflow with `invalid: true` / error status / `installed: false` is a dead delivery path (GC-030); the monitor fires but pages nobody |
| Duplicate monitors on one target read as extra coverage | groundcover has no native dedup, so N monitors on the same `(namespace, workloadName, type)` and destination page N times for one condition (GC-014); it is noise, not coverage — and GC-014 only computes when the dedup-key fields were captured, else `not-in-scope-from-this-endpoint`, never a fabricated "no duplicates" |
| Destination/coverage join asserted when only `summary/query` was read | `method`/`connectedApps`/labels/namespace/workloadName come only from the per-monitor YAML enrichment (0/69 observed live); GC-011/012/013/030/032 and the flagship gate on their presence and read `not-in-scope-from-this-endpoint` when absent — never present the silent-paging cascade as computed without the join fields |
| Monitor query or destination config written to evidence | Captures keep UUIDs, titles, tuning fields, and workflow/route metadata only |
| Toolkit brief webhook conflated with groundcover destinations | Two different systems; the Slack brief webhook is the toolkit's own reporting channel |
