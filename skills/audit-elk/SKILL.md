---
name: audit-elk
description: Read-only scored audit of Kibana Alerting across rule notification delivery, dead connectors, rule execution health (error/warning states), alert noise controls (flapping detection, alert_delay, action throttling, snoozes), and rule-type coverage per Kibana space; writes findings.json and report.md and changes nothing. Use when the user mentions auditing or scoring ELK, Elastic, Kibana alerting, Kibana rules, Watcher, dead Kibana connectors, flapping rules, or snoozed rules. Do not use to change Kibana (no setup-elk ships yet; the audit names each fix), for Elasticsearch cluster or index health, or for Grafana-rendered Elastic data (use audit-grafana).
---

# audit-elk

Scored, read-only audit of the Kibana Alerting rules that watch your Elastic data: whether each rule reaches a live connector, whether the rule itself is executing cleanly, whether its noise controls are tuned, and whether the rule set actually covers your critical services — across every Kibana space you point it at. It answers one question: when a log or metric condition trips in Elastic tonight, does a healthy rule fire to a reachable connector without drowning the responder in repeats?

This skill audits **Kibana Alerting** (Stack Rules and their connectors), not Elasticsearch cluster health, index lifecycle, or the data the rules query. Elastic data rendered in Grafana is `audit-grafana`. Legacy Watcher watches live in Elasticsearch, not Kibana; this audit detects that a split exists (ELK-032) so a Kibana-only view does not silently imply Watcher-covered services are unmonitored, but it does not deeply audit Watcher itself.

Every command is read-only: GET on rules, connectors, rule types, health, and (on 9.2+) maintenance windows, plus a read-by-query on Elasticsearch `_watcher/stats` for the split check. Every mutating verb — enable, disable, mute, snooze, connector execute — is forbidden; the full list is in [references/elk-checks.md](references/elk-checks.md) section 12. There is no `setup-elk` yet, so every finding names its manual fix path in Kibana instead of a setup anchor.

**Multiple Kibana targets, one run.** `elk` may be a single block (one `kibana_url` + `token_env`) or a **list of labeled targets**, each with its own `kibana_url` and `token_env`. The audit **iterates every target** — enumerate them with `sh "${CLAUDE_PLUGIN_ROOT}/report-standard/toolkit-targets.sh" <cfg> elk labels` and run the full sequence below once per target with `SCOUTFLO_TARGET=<label>` set. Output goes to `elk/<label>/<date>/` for a list, or the flat `elk/<date>/` for a single block; the `findings.json` `.target` is that same per-target slug (`elk`, or `elk/<label>`). Every network call uses the target's own resolved `kibana_url` and token — there is no ambient default (the API key plus the Kibana URL select the target). This is distinct from Kibana **spaces**, which the audit still discovers and iterates *within* each target.

Run this standalone, from `/scoutflo:audit-all`, or on a schedule via `/scoutflo:schedule-audits`.

Outputs, per the [report standard](../../report-standard/README.md):

- `./scoutflo-audits/elk/[<label>/]<YYYY-MM-DD>/findings.json` per the [findings schema](../../report-standard/findings-schema.md), finding IDs `ELK-NNN`
- `./scoutflo-audits/elk/[<label>/]<YYYY-MM-DD>/report.md` per the [report template](../../report-standard/report-template.md), including the `## Inventory` section (the `render-report-viz.sh inventory` output)
- `./scoutflo-audits/elk/[<label>/]<YYYY-MM-DD>/inventory.json` per the [inventory schema](../../report-standard/inventory-schema.md) (`scoutflo-inventory/v1`): the complete Phase-1 catalog — one item per Kibana alerting rule and connector (`kind`: `alert_rule`, `connector`), each with `kind`, `covers`, `enabled`, `severity`, and `routes_to` for alerting objects. Built from the raw pull, never invented; redacted at capture, never a secret value.
- One appended line in `./scoutflo-audits/elk/[<label>/]history.jsonl`
- One Slack brief, when `slack.webhook_env` is configured

## Doctor gate

| Integration | toolkit.yaml keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| ELK / Kibana | `elk.kibana_url`, `elk.token_env`, optional `elk.spaces` (a *restriction* on the auto-discovered set) | the variable named by `token_env` (`KIBANA_API_KEY`) | Elasticsearch API key whose role has Kibana Read on Stack Rules, Rules Settings, and Actions and Connectors, granted at **`spaces:["*"]`** so `GET /api/spaces/space` discovery is complete (recipe in `/scoutflo:connect`) — a narrower per-space scope hides spaces and recreates the empty-default bug | read-only |
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
# Resolve the CURRENT elk target from toolkit.yaml — a single block, or the SCOUTFLO_TARGET-selected
# item of a labeled list (the shared enumerator handles both; no yq required). kibana_url and the
# token variable come from the resolved target; the ambient env is never assumed to be the target.
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
ELK_KIND=$(sh "$TT" "$CFG" elk kind); ELK_N=$(sh "$TT" "$CFG" elk count)
[ "${ELK_N:-0}" -ge 1 ] || { echo "no elk target configured in $CFG; run /scoutflo:connect"; exit 1; }
ELK_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$ELK_N" ]; do [ "$(sh "$TT" "$CFG" elk label "$_i")" = "$SCOUTFLO_TARGET" ] && { ELK_IDX=$_i; break; }; _i=$((_i+1)); done; fi
ELK_LABEL=$(sh "$TT" "$CFG" elk label "$ELK_IDX")
if [ "$ELK_KIND" = seq ]; then ELK_SEG="elk/${ELK_LABEL}"; else ELK_SEG="elk"; fi
KIBANA_URL=$(sh "$TT" "$CFG" elk get "$ELK_IDX" kibana_url)   # elk.kibana_url (Kibana, not Elasticsearch)
[ -n "$KIBANA_URL" ] || { echo "elk target '${ELK_LABEL:-?}' has no kibana_url in $CFG; run /scoutflo:connect"; exit 1; }
KIBANA_URL="${KIBANA_URL%/}"
# elk.token_env names the secret VARIABLE (default KIBANA_API_KEY); resolve the name, then read the
# value from the environment (the store sourced above). Presence check only, never print the value.
ELK_TOKEN_VAR=$(sh "$TT" "$CFG" elk get "$ELK_IDX" token_env); [ -n "$ELK_TOKEN_VAR" ] || ELK_TOKEN_VAR="KIBANA_API_KEY"
KIBANA_API_KEY=$(printenv "$ELK_TOKEN_VAR" 2>/dev/null || true)
[ -n "${KIBANA_API_KEY:-}" ] || { echo "\$${ELK_TOKEN_VAR} (elk.token_env) is not set — add it to ~/.scoutflo/env (echo 'export ${ELK_TOKEN_VAR}=\"<paste>\"' >> ~/.scoutflo/env; chmod 600 ~/.scoutflo/env), or run /scoutflo:connect. The plugin reads that file, not your interactive shell."; exit 1; }
echo "elk target: ${ELK_LABEL} (${KIBANA_URL}) -> ${ELK_SEG}/"
# Kibana is browser-facing behind SSO, so a 200 that returns an HTML login/SPA page is a
# false-green. Judge the body, not the status code alone: capture BOTH the status and the
# content-type, and pass ONLY on 200 + a JSON content-type + a version-robust body assertion
# (any JSON object/array from the alerting API — do NOT over-fit a Kibana field). This mirrors
# skills/doctor/scripts/doctor.sh so doctor and this audit agree.
BODY="$(mktemp)"; RC=0
META="$(curl -s -o "$BODY" -w '%{http_code} %{content_type}' --max-time 10 \
  -H "Authorization: ApiKey ${KIBANA_API_KEY}" "${KIBANA_URL}/api/alerting/_health")" || RC=$?
CODE="${META%% *}"; CT="${META#* }"
if [ "$RC" -ne 0 ]; then
  rm -f "$BODY"; echo "alerting health probe could not connect (curl exit ${RC}); check elk.kibana_url and network"; exit 1
elif [ "$CODE" = "200" ] && printf '%s' "$CT" | grep -qi json && jq -e 'type=="object" or type=="array"' "$BODY" >/dev/null 2>&1; then
  : # real JSON from the alerting API — pass
elif [ "$CODE" = "200" ]; then
  rm -f "$BODY"; echo "alerting health probe returned 200 but Content-Type='${CT}' — looks like an HTML login/SPA/proxy page, not the API: Kibana is likely behind an SSO/OAuth reverse proxy returning its login page (or elk.kibana_url is wrong); a 200 HTML page is not proof of API access"; exit 1
elif [ "$CODE" = "404" ]; then
  rm -f "$BODY"; echo "alerting health probe returned 404: elk.kibana_url points at Elasticsearch not Kibana (or a space/base-path prefix is wrong)"; exit 1
elif [ "$CODE" = "401" ] || [ "$CODE" = "403" ]; then
  rm -f "$BODY"; echo "alerting health probe returned ${CODE}: key invalid or role lacks Kibana Read on Stack Rules"; exit 1
else
  rm -f "$BODY"; echo "alerting health probe returned ${CODE}"; exit 1
fi
rm -f "$BODY"
echo "doctor gate: pass"
```

Never proceed past a failed doctor check and never downgrade one into a finding. `/scoutflo:doctor` runs the same probe standalone. The `/api/alerting/_health` response is also an audit input (ELK-004): its `is_sufficiently_secure` and `has_permanent_encryption_key` fields are read in Phase 3.

The tier is enforced by Kibana feature privileges on the key's role and cannot be introspected from the key itself; if a broader key is used the audit still runs, but record in the report that the audit credential can do more than read.

## Live-safety gate

Print what you are pointed at and compare it to the config before the first real check:

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"
[ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done
[ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
# Resolve the CURRENT elk target from config via the shared enumerator — a single block, or the
# SCOUTFLO_TARGET-selected item of a labeled list (no yq required). Never hand-typed.
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
ELK_N=$(sh "$TT" "$CFG" elk count)
ELK_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$ELK_N" ]; do [ "$(sh "$TT" "$CFG" elk label "$_i")" = "$SCOUTFLO_TARGET" ] && { ELK_IDX=$_i; break; }; _i=$((_i+1)); done; fi
ELK_LABEL=$(sh "$TT" "$CFG" elk label "$ELK_IDX")
KIBANA_URL=$(sh "$TT" "$CFG" elk get "$ELK_IDX" kibana_url); KIBANA_URL="${KIBANA_URL%/}"   # elk.kibana_url
ELK_TOKEN_VAR=$(sh "$TT" "$CFG" elk get "$ELK_IDX" token_env); [ -n "$ELK_TOKEN_VAR" ] || ELK_TOKEN_VAR="KIBANA_API_KEY"
KIBANA_API_KEY=$(printenv "$ELK_TOKEN_VAR" 2>/dev/null || true)
STATUS_JSON="$(curl -fsS --max-time 15 -H "Authorization: ApiKey ${KIBANA_API_KEY}" \
  "${KIBANA_URL}/api/status" 2>/dev/null || echo '{}')"
VER="$(printf '%s' "$STATUS_JSON" | jq -r '.version.number // "unknown"')"
NAME="$(printf '%s' "$STATUS_JSON" | jq -r '.name // "unknown"')"
echo "elk target: ${ELK_LABEL}; kibana_url=${KIBANA_URL} name=${NAME} version=${VER}"
printf '%s' "$STATUS_JSON" | jq -e '.version.number != null' >/dev/null \
  || { echo "no Kibana version in the status response; this URL is not a Kibana host — stop"; exit 1; }
echo "live-safety gate: pass — confirm this is the Kibana instance and version you intend to audit; the version drives the maintenance-window (9.2+) and legacy-route (9.0) gates"
```

The API key plus the Kibana URL select the target; there is no ambient default. The detected version is load-bearing: it gates ELK-025 (maintenance windows, public API 9.2+) and confirms the legacy `/api/alerts/*` routes removed in 9.0 are not in play.

## Ground rules

- Configuration is metadata; execution state is proof. A rule that exists is `configured`; only a rule whose `last_run.outcome` is `succeeded` and whose actions target a live connector is `validated-live`.
- API errors are evidence. A `404` on `/api/alerting/*` means `elk.kibana_url` points at Elasticsearch or a space prefix is wrong; a `401`/`403` means the key's role lacks the Kibana Read privilege on Stack Rules or Connectors. Record which, never convert an error into empty success.
- Rules are space-isolated, and spaces are **discovered** (`GET /api/spaces/space`), never assumed. Coverage denominators name the spaces discovered, audited, and skipped. Zero rules in the audited set never scores as an empty estate — it trips the Phase-1 guardrail (ELK-033), because the rules may live in a space this run did not see.
  - ❌ `Scored coverage 90: forty alerting rules exist.` (which space? one space's forty rules say nothing about another space)
  - ❌ `Score 0/100: no alerting rules.` (only the default space was checked; the rules were in a space the run never enumerated — the exact bug this fix prevents)
  - ✅ `Scored coverage 55: discovered five spaces; audited default and observability; security was discovered but skipped (out of scope) and named as uncovered; within the two audited spaces, six rules are in execution error.`
- Never score from rule counts. A rule in `execution_status: error` detects nothing; a rule with no actions notifies nobody; a draft-equivalent disabled rule is not coverage. Count what actually works.
- Flapping `null` on a rule means "use the space default", and the space default is ON — that is healthy, not a finding. Only an explicit per-rule `flapping.enabled: false`, or a weak `look_back_window`/`status_change_threshold`, is the finding.
- Respect the version gates: this audit uses `/api/alerting/rule(s)` only (legacy `/api/alerts/*` removed in 9.0), and version-gates the maintenance-window check (public API 9.2+) to `not-in-scope` on older versions rather than failing it.
- Never write a connector config or a rule's raw params to evidence if they could embed a secret; capture IDs, names, types, execution state, and the noise-control fields only.

## Estate sizing

Count before judging, and declare the path in the terminal output. The unit here is rules across the audited spaces:

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
ELK_KIND=$(sh "$TT" "$CFG" elk kind); ELK_N=$(sh "$TT" "$CFG" elk count)
ELK_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$ELK_N" ]; do [ "$(sh "$TT" "$CFG" elk label "$_i")" = "$SCOUTFLO_TARGET" ] && { ELK_IDX=$_i; break; }; _i=$((_i+1)); done; fi
ELK_LABEL=$(sh "$TT" "$CFG" elk label "$ELK_IDX")
if [ "$ELK_KIND" = seq ]; then ELK_SEG="elk/${ELK_LABEL}"; else ELK_SEG="elk"; fi
KIBANA_URL=$(sh "$TT" "$CFG" elk get "$ELK_IDX" kibana_url); KIBANA_URL="${KIBANA_URL%/}"   # elk.kibana_url
ELK_TOKEN_VAR=$(sh "$TT" "$CFG" elk get "$ELK_IDX" token_env); [ -n "$ELK_TOKEN_VAR" ] || ELK_TOKEN_VAR="KIBANA_API_KEY"
KIBANA_API_KEY=$(printenv "$ELK_TOKEN_VAR" 2>/dev/null || true)
SMALL_MAX_OBJECTS="30"    # example, tune to your environment
MEDIUM_MAX_OBJECTS="150"  # example, tune to your environment
BATCH_SIZE="50"           # rules per batch on the large path; example, tune it
AUTH="Authorization: ApiKey ${KIBANA_API_KEY}"
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${ELK_SEG}/${RUN_DATE}/raw"
# Sum rule totals across the AUDITED spaces (spaces.txt, materialized by elk-checks.md
# section 4a from live enumeration — NOT a bare default-space call). Per-space breakdown.
[ -s "${RAW_DIR}/spaces.txt" ] || { echo "run space enumeration (elk-checks.md 4a) before sizing"; exit 1; }
TOTAL=0
while read -r space; do
  [ -n "$space" ] || continue
  if [ "$space" = "default" ]; then base="${KIBANA_URL}"; else base="${KIBANA_URL}/s/${space}"; fi
  n="$(curl -fsS --max-time 30 -H "$AUTH" "${base}/api/alerting/rules/_find?per_page=1&page=1" | jq -r '.total // 0')"
  echo "  rules_in_space[${space}]=${n}"
  TOTAL=$((TOTAL + n))
done < "${RAW_DIR}/spaces.txt"
ZERO_RULES=0; [ "$TOTAL" -eq 0 ] && ZERO_RULES=1
echo "scored_objects=${TOTAL} (summed across audited spaces) zero_rules=${ZERO_RULES}"

# Guided-walkthrough drift check, per report-standard/README.md.
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${ELK_SEG}"
PREV_RUN="$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)"
DRIFT="first run"
if [ -n "$PREV_RUN" ] && [ -f "${PREV_RUN}/findings.json" ]; then
  PREV_TOTAL="$(jq -r '.estate.objects // empty' "${PREV_RUN}/findings.json")"
  if [ -n "$PREV_TOTAL" ]; then
    if [ "$PREV_TOTAL" -eq "$TOTAL" ]; then
      DRIFT="estate unchanged since ${PREV_RUN##*/} (${PREV_TOTAL} rules then, ${TOTAL} now)"
    else
      DRIFT="estate changed since ${PREV_RUN##*/}: ${PREV_TOTAL} -> ${TOTAL} rules"
    fi
  else
    DRIFT="previous run recorded no estate data; treating as first run"
  fi
fi
echo "drift: ${DRIFT}"
```

- **Small** (`TOTAL <= SMALL_MAX_OBJECTS`): one pass over everything.
- **Medium** (`TOTAL <= MEDIUM_MAX_OBJECTS`): per-category passes (delivery, health, noise, coverage), completed in one run.
- **Large**: work rules in batches of `BATCH_SIZE` against a durable, run-ID-keyed worklist per the worklist rules in [skill-authoring-conventions.md](../../docs/skill-authoring-conventions.md): scan for a resumable run before minting a new run ID, one row per rule id per space, lock before claiming a batch, mark rows done only after their pulls succeed, assert zero pending before Phase 8 writes.

Never silently truncate: name the spaces audited and any space skipped, and reflect it in the coverage denominators. The rate-limit retry rule in [references/elk-checks.md](references/elk-checks.md) section 9 applies to every call.

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

### Empty / hidden-rules guardrail

The scope checkpoint above narrows a *large* estate. This guardrail catches the opposite and more dangerous case — an estate that looks **empty** because the rules are in a space this run did not (or could not) see. It is the fix for the customer bug where auditing only `default` reported a confident, wrong `0/100`. After sizing sets `ZERO_RULES`:

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
ELK_KIND=$(sh "$TT" "$CFG" elk kind); ELK_N=$(sh "$TT" "$CFG" elk count)
ELK_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$ELK_N" ]; do [ "$(sh "$TT" "$CFG" elk label "$_i")" = "$SCOUTFLO_TARGET" ] && { ELK_IDX=$_i; break; }; _i=$((_i+1)); done; fi
ELK_LABEL=$(sh "$TT" "$CFG" elk label "$ELK_IDX")
if [ "$ELK_KIND" = seq ]; then ELK_SEG="elk/${ELK_LABEL}"; else ELK_SEG="elk"; fi
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${ELK_SEG}/${RUN_DATE}/raw"
# Spaces discovered (4a) vs audited (this run). Are there rules-bearing spaces we did NOT audit?
UNAUDITED="$(comm -23 "${RAW_DIR}/spaces-discovered.txt" "${RAW_DIR}/spaces.txt" 2>/dev/null | tr '\n' ' ')"
UNAUDITED_TRIM="$(printf '%s' "$UNAUDITED" | tr -d '[:space:]')"
if [ "${ZERO_RULES:-0}" -eq 1 ]; then
  if [ -n "$UNAUDITED_TRIM" ]; then
    # Case A: zero rules in the audited set, but other spaces exist — the rules are likely there.
    echo "[guard] 0 rules in the audited spaces, but these spaces were discovered and not audited: ${UNAUDITED}"
    echo "[guard] pausing to re-scope rather than reporting an empty estate"
    # Interactive: offer to add them; non-interactive/scheduled: audit all discovered by default.
  else
    # Case B: zero rules and NO other space is even visible to this key. Either the estate is
    # truly empty, or the key cannot see the space that holds the rules. Do NOT score a
    # confident 0/100 or a vacuous-high — this is the ELK-033 visibility trip-wire.
    echo "[guard] 0 rules visible across every discoverable space — possible key-visibility gap (ELK-033)"
    echo "[guard] widen the key to spaces:[\"*\"] read (see /scoutflo:connect) if rules live elsewhere"
  fi
fi
```

Behavior this enforces (Phase 8 honors it):

- **Case A** (zero in audited set, other spaces discovered): in an interactive run, present the discovered spaces (id, name, per-space rule count) as a numbered pick-list, validate the choice against the discovered list, write it into the audit scope (`elk.spaces` / `checkpoint_save_scope`), and re-size against the chosen space(s). In a non-interactive or scheduled run (`audit-all`, `schedule-audits`), take the safe default — audit **all discovered** spaces — so the picker never hangs.
- **Case B** (zero visible anywhere): exclude the three categories that genuinely need rules — **Rule health, Alert noise, Coverage** — as `blocked`, and renormalize per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md); emit finding **ELK-033** with the visibility-gap reason, and **never** write a confident `0/100`, a vacuously-high score, or an end-to-end claim. Keep **Rule delivery** *included*: ELK-004 (framework health from `/api/alerting/_health`) and the connector checks (ELK-002/003) do not depend on any rule existing, so delivery is still assessable — and keeping it in means at least one scored category remains, which is required (excluding all four leaves nothing to score and `check-findings.sh` rejects an all-excluded scorecard). If space discovery itself was `unavailable` (the 4a 404 fallback), say so as the reason.

## Phase 1: Service context and space discovery

If `./scoutflo-audits/topology.md` exists, load it; its service list is the critical-service list and its names are canonical. If topology.md does not exist, infer critical services from rule names and tags, note the inference, and suggest `/scoutflo:map-topology`.

**Discover the spaces — never assume `default`.** Run the space-enumeration step in [references/elk-checks.md](references/elk-checks.md#4a-space-enumeration-do-this-first--never-assume-default): call `GET /api/spaces/space` (a global endpoint, no `/s/` prefix, no admin privilege needed) to enumerate the spaces this key can see. Then resolve the audited set: `elk.spaces` when it is set (each entry validated against the discovered list — a configured space the key cannot see is a scope gap, reported `skipped`, never silently dropped), else **every discovered space**. State three distinct sets in the report and in every coverage denominator: **discovered**, **audited**, **skipped**. If `GET /api/spaces/space` returns 404 (Spaces feature or the Security plugin is off, or a Serverless difference), fall back to `elk.spaces`/`default` and **state that discovery was unavailable** — never silently treat the default space as the whole estate.

This replaces the old blind `["default"]`-only default: a customer's alerting rules commonly live in a non-default space, and auditing only `default` reports an empty estate — the wrong `0/100` (or a vacuously-high score) that this fix exists to prevent.

## Phase 2: Read-only inventory

Build the raw picture with the commands in [references/elk-checks.md](references/elk-checks.md): section 4a already enumerated the spaces (`GET /api/spaces/space`) and resolved the audited set; section 4 then captures the Kibana version (drives the version gates), the alerting framework health, and per audited space the rules (with execution state, actions, flapping, alert_delay, snooze), connectors, and rule types. Judgment starts in Phase 3. A 401/403 on any space is a privilege finding naming the missing Kibana Read feature; a 404 on `/api/alerting/*` means the URL is Elasticsearch, not Kibana.

## Phase 3: Rule delivery (ELK-001 to ELK-006)

Commands in sections 5 and 5.1. Every enabled rule has at least one action (`ELK-001`, critical — a rule with no connector detects but pages nobody), no rule targets a connector with missing secrets or a deprecated connector (`ELK-002`, high — the alert fires but cannot be delivered), no orphaned connectors referenced by zero rules (`ELK-003`, low drift), and the alerting framework itself is healthy (`ELK-004`, high — `is_sufficiently_secure` false or no permanent encryption key means alerting is not durably or securely wired).

Do not stop at the linter line. For each delivery finding, compute the **per-estate blast radius** by joining the failing rule to the critical services it is the detector for (name/tags/query vs the topology-export.json service list) and state the *named* set — "checkout and payments each have exactly one enabled rule and it has no connector" — not a raw rule count. `ELK-004` is estate-wide: when `has_permanent_encryption_key` is false, count the *enabled* rules across the audited spaces (`jq '[.rules[]|select(.enabled)]|length'`, summed — **not** the estate-sizing `TOTAL`, which counts disabled rules too) that silently stop notifying on the next Kibana restart. Every delivery finding names the read-only re-check that proves the fix landed (re-GET the rule / connector / `_health`).

Two verify-pending checks close the hole ELK-001/ELK-002 leave — *is the connector TYPE able to reach a human, and does every critical rule lean on the same connector?*: no critical rule delivers only to a non-paging sink connector (`.server-log`/`.index`) (`ELK-005`, high), and no single connector is the sole delivery path for the whole critical-rule set (`ELK-006`, high, connector fan-in SPOF — the inverse of the orphaned-connector `ELK-003`). Both are **verify-pending** (see section 5.1's banner): drafted against Kibana's documented API and reviewed, not yet run against a live tenant. Their remediation is the inline Kibana UI path in the "Fix location today" table, never a fabricated live observation.

- ❌ `Delivery pass: every rule has an action.`
- ✅ `Delivery partial: every enabled rule has an action, but four target the "oncall-slack" connector which reports is_missing_secrets (ELK-002) — and oncall-slack is the sole action on 9 rules (ELK-006), so one broken connector darks checkout, payments, and search at once; the framework has no permanent encryption key so all 42 enabled rules break across the next restart (ELK-004); affected: checkout, payments, search.`

## Phase 4: Rule health (ELK-010 to ELK-014)

Commands in sections 6 and 6.1. No rule stuck in `execution_status: error` — silent coverage that detects nothing (`ELK-010`, critical), no rule in `warning` from a timeout or a maxAlerts/maxQueuedActions cap that silently drops alerts (`ELK-011`, high), `last_run.outcome` succeeded on every enabled rule (`ELK-012`), and disabled rules judged against intent rather than flagged on the disabled flag alone (`ELK-013`).

`ELK-010` is only as important as the service it was the sole detector for: resolve each errored rule to its critical service(s) and rank by whether it is the *only* enabled rule watching that service — "payments-error-rate is in error and is the only enabled rule watching payments, so payments has had zero working detection since it started erroring" — and name ELK-031 in evidence, since presence passes while the paging path is broken. Verify by re-GET (`execution_status=='ok'`, `last_run.outcome=='succeeded'`).

One verify-pending check adds the distinct failure class ELK-010 cannot reach: an enabled rule that has simply **stopped executing** — `execution_status.last_execution_date` gone stale relative to `schedule.interval` because the Kibana task manager saturated (`ELK-014`, high). It is *not* an error state (ELK-010) and *not* disabled (ELK-013); it is a rule that presence-passes and delivery-passes but never fires because it never runs. When every rule is stale together, correlate it with `ELK-004` as one task-manager problem, not per-rule. **Verify-pending** (section 6.1 banner): the `last_execution_date` staleness signal is drafted from Kibana's documented API and not yet proven on a live tenant; remediation is the inline Kibana execution-log / task-manager-health path in the "Fix location today" table.

## Phase 5: Alert noise (ELK-020 to ELK-025)

Commands in section 7. This is the alert-hygiene category. Flapping detection on where a rule can toggle — remembering that `null` means the healthy space default is in force, so only an explicit disable or weak window is a finding (`ELK-020`), `alert_delay.active` set where a spiky signal needs FOR-like debounce (`ELK-021`), actions throttled or set to `onActionGroupChange` rather than re-notifying every check interval (`ELK-022`), action summaries on high-cardinality rules instead of per-alert fan-out (`ELK-023`), no rule snoozed indefinitely or `mute_all` with no end (`ELK-024`, high), and no permanent maintenance window (`ELK-025`, version-gated to Kibana 9.2+; on older versions it reports `not-in-scope` with the detected version, never a fail).

Suppression findings carry the same blast-radius bar. For `ELK-024`, name the critical service(s) a mute blinds and the muted-instance count — but do **not** state a mute duration: `mute_all` is a boolean with no start timestamp in the rules API, so "muted since <date>" would be fabricated; compute a bounded duration only for `snooze_schedule[]` entries and say "suppressed with no end (indefinite)" for `mute_all`. `ELK-025` is estate-wide and higher-radius: an always-on maintenance window suppresses *every rule in its scope*, so capture `scoped_query`/`category_ids` and only claim "all N enabled rules" when the window is **unscoped**; a scoped window suppresses only the intersected set. When a permanent unscoped window is present it is the top lever — it can dark every critical service at once. Both verify by re-GET (`mute_all==false` / no window with an unbounded `r_rule.until` while `enabled==true`).

Honest ceiling, stated in the report every run: rule configuration is intent; whether a rule actually flapped or fanned out lives in its alert history, which this audit reads at the summary level (`alerts_count`, execution state) but does not fully reconstruct. Space-level flapping settings are read-only via an internal Kibana API in 9.x, so this audit judges flapping per rule and states that the space-level default was assumed ON rather than read.

## Phase 6: Coverage (ELK-030 to ELK-032)

Commands in section 8. Rule-type coverage (`ELK-030`), critical services from topology each covered by at least one rule (`ELK-031`), the legacy-Watcher-versus-Kibana-Alerting split identified so a Kibana-only view does not silently miss Watcher-covered services (`ELK-032` — needs `elk.es_url` and the `monitor_watcher` privilege; blocked with that reason when absent), and rules visible in at least one discovered space (`ELK-033`, high — zero rules across every space this key can see is `blocked` with the visibility-gap reason from the Phase-1 guardrail, not a plain fail; it points at widening the key to `spaces:["*"]` read).

`ELK-030` must name the *service × missing-signal-class* pair, not the hypothetical "may have blind signal classes": map each critical service's expected signal classes (logs threshold, metric threshold, APM latency/error, uptime) against the rule types actually present for that service, and state "checkout is covered only by index-threshold rules — it has no APM latency rule, so a latency regression that does not spike log volume trips nothing." It complements `ELK-031` (which asks "any rule?"): a service can pass ELK-031 and still be blind to a whole failure mode. This is also where the flagship correlation lands — see Phase 7.

## Phase 7: Coverage matrix and topology readiness

Fill one row per critical service using the per-service mapping in section 10 and the check-result vocabulary (`pass`, `partial`, `fail`, `blocked`, `not-in-scope`):

| Service | Ready | Delivery | Health | Noise | Coverage | Space | Gap |
| --- | --- | --- | --- | --- | --- | --- | --- |

Every cell carries its `passed/total` denominator; the Space column names which Kibana space the rule lives in. Name affected services in findings.

**Flagship correlation — the DARK CRITICAL SERVICE path.** This is the one chain no free scanner and no Kibana screen assembles, because each surfaces rule status in isolation: Kibana shows a rule *exists* for checkout; it never says the paging path is broken end to end. For each critical service resolved from `topology-export.json`, follow the whole path and return one verdict — presence → delivery-type → connector-health → execution → suppression: `ELK-031` shows a rule exists (looks monitored) AND (`ELK-001` it has no action) OR (`ELK-005` its only action is a `.server-log`/`.index` sink that reaches no human) OR (`ELK-002` its only connector is missing secrets) OR (`ELK-006` it shares the one connector that is dead) OR (`ELK-010` it is in execution error) OR (`ELK-014` it is enabled but the task manager stopped running it) OR (`ELK-024` it is `mute_all`/indefinitely snoozed) OR (`ELK-025` an always-on maintenance window suppresses it). Any single link means: "checkout LOOKS monitored — a rule is green in the list — but no page will ever reach a human when it trips." Assemble it as **one finding per service** naming the contributing IDs in evidence, e.g. "payments has exactly one enabled rule; it is in `execution_status: error` and its only connector is missing secrets, so payments has had zero working alerting while the Rules page shows a rule present." That gap between a rule existing and a page actually firing-and-delivering, computed per named critical service across all four categories, is the single most valuable line audit-elk produces — and it drives the Coverage score down for presence-without-delivery. Never credit `ELK-031` as covered just because a rule object exists.

Then render the Scoutflo Topology Readiness section per [topology-readiness.md](../../report-standard/topology-readiness.md): evaluate the six checks per critical service from `./scoutflo-audits/topology-export.json`, read-only. Gaps that map to an existing finding reference its ID; gaps with no finding get a `TOPO-` row pointing at `/scoutflo:map-topology`. Render check names and confidence per the standard: plain-English column headers, confidence as `n/10`, and — whenever any service is below ready — the ticket-ready readiness action plan table. If the export or topology.md is missing, or exists but describes a different target than this audit covers, the section renders the matching state from topology-readiness.md with its one-line unlock; it never guesses and never says a bare "unavailable". Readiness is reported, never folded into the 0-100 score.

**Provider-identity note, verified against the platform's current model:** ELK's identity on the Scoutflo platform is a **logging** provider (`logging.elk`), whose required schema fields describe the log index it correlates against (`indexPattern`, `timeField`, `serviceField`, `serviceValue`, `messageField`), not the alerting rules this audit scores. The schema does carry optional alert-correlation fields (`alertRuleId`, `watcherId`) that a Kibana alerting rule maps onto. So a `SENDS_LOGS_TO` connection to ELK reaches full confidence on the log-correlation fields; the alerting rules this audit checks populate the optional `alertRuleId`, which is a `MONITORED_BY`-style signal layered on top. State plainly which of the two roles a given connection is playing when it stalls at partial, rather than treating a healthy log-source connection as if it were an alerting gap.

## Phase 8: Score, write, brief

Score per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md): each check yields `pass` (1.0), `partial` (0.5), `fail`/`blocked` (0), `not-in-scope` leaves the denominator. Category score is the credit ratio times 100 rounded down; overall is the weight-normalized sum over included categories. Whole categories that could not be assessed (a space that 403'd; ELK-025 on a pre-9.2 version leaves that one check not-in-scope, not the whole category) are excluded, renormalized, and stated. Score conservatively. Assign each category a maturity value (`reactive`, `proactive`, `systematic`).

**Empty / hidden estate (ELK-033, from the Phase-1 guardrail):** when zero rules are visible across every discoverable space, do not emit a confident `0/100` — nor a vacuously-high score from checks that pass on an empty set. Exclude the three rule-dependent categories — **Rule health, Alert noise, Coverage** — by authoring them into `score.excluded` with the reason ("no alerting rules visible to this credential; rules may live in a space this key cannot see — widen to `spaces:[\"*\"]` read", or "space discovery unavailable" on the 4a 404 fallback), and renormalize over what remains. **Keep Rule delivery included** and score it from its rule-independent checks (ELK-004 framework health, ELK-002/003 connectors); do **not** exclude all four categories — an all-excluded scorecard has no denominator and `check-findings.sh` rejects it. Emit ELK-033 (Coverage) with evidence (the discovered-vs-audited space sets) and a remediation pointer. The overall then reconciles as Rule delivery's score over the one remaining weight.

| Category | Weight | ID range |
| --- | ---: | --- |
| Rule delivery | 30 | ELK-001 to ELK-006 |
| Rule health | 25 | ELK-010 to ELK-014 |
| Alert noise | 20 | ELK-020 to ELK-025 |
| Coverage | 25 | ELK-030 to ELK-033 |

Weights sum to 100. The rebalance (noise 25 → 20, coverage 20 → 25) reflects the doctrine severity ranking: a *dark critical service* means nobody responds at all (coverage blast radius, where the flagship per-service verdict lands), which strictly outranks a *noisy* page that degrades response quality but still reaches a human. The new checks fold into existing categories (ELK-005/006 → Rule delivery, ELK-014 → Rule health); no new category is added.

The full check catalog and the target profile (what 100 means per category) are at the top of [references/elk-checks.md](references/elk-checks.md). IDs are stable: the same defect gets the same ID every run, one finding per failed check, affected objects and their space enumerated. Compute `points_recoverable` per finding by re-running the scoring model with that check at full credit; `info` findings and excluded categories carry 0. The executive summary states the gap to target and the two or three findings with the highest `points_recoverable` as the biggest levers.

End-to-end gate: claim end-to-end coverage only when the overall score is at or above 85, every critical service passes every applicable coverage row, and no category or space was excluded. Below the gate, write "good base coverage", never "end to end". A run that audited only some spaces cannot claim end-to-end; say which spaces the claim rests on.

Lifecycle, exemptions, and totals, before rendering the report:

1. Load the previous run's `findings.json` when one exists; classify every finding per the lifecycle table in the [findings schema](../../report-standard/findings-schema.md) (`new`, `unchanged`, `regressed`; resolved IDs go to the delta, and the executive summary names regressions first).
2. Load `./scoutflo-audits/exemptions.yaml` when present. Entries with `id`, `reason`, and `expires` all set and unexpired suppress their finding into the Suppressed appendix; malformed or expired entries are reported, never honored.
3. Every findings area and coverage cell carries its denominator (`passed/total`).

Emit and verify:

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
ELK_KIND=$(sh "$TT" "$CFG" elk kind); ELK_N=$(sh "$TT" "$CFG" elk count)
ELK_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$ELK_N" ]; do [ "$(sh "$TT" "$CFG" elk label "$_i")" = "$SCOUTFLO_TARGET" ] && { ELK_IDX=$_i; break; }; _i=$((_i+1)); done; fi
ELK_LABEL=$(sh "$TT" "$CFG" elk label "$ELK_IDX")
if [ "$ELK_KIND" = seq ]; then ELK_SEG="elk/${ELK_LABEL}"; else ELK_SEG="elk"; fi
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${ELK_SEG}/${RUN_DATE}"
mkdir -p "$OUT"
# ... write findings.json, inventory.json, and report.md per the report standard. The findings.json
# ".target" is the per-target slug (equal to $ELK_SEG: "elk" for a single block, "elk/<label>" for a
# labeled-list target), so audit-all/correlation/render disambiguate multiple Kibana targets. Verify:
jq -e --arg seg "$ELK_SEG" '.schema == "scoutflo-findings/v1" and .target == $seg and (.findings | type == "array")' \
  "$OUT/findings.json" >/dev/null && echo "findings.json valid"
grep -q '^# ' "$OUT/report.md" && echo "report.md present"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-findings.sh" "$OUT/findings.json"
# Inventory (scoutflo-inventory/v1): the complete Phase-1 catalog of what exists,
# built from the raw pull (never invented, redacted). counts.total must reconcile
# with items; the ## Inventory section of report.md IS this render.
jq -e --arg seg "$ELK_SEG" '.schema == "scoutflo-inventory/v1" and .target == $seg
       and (.items | type == "array") and (.counts.total == (.items | length))' \
  "$OUT/inventory.json" >/dev/null && echo "inventory.json valid"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" inventory "$OUT/inventory.json" >/dev/null \
  && echo "inventory section renders"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" html "$OUT/findings.json" "$OUT/report.html" "$(dirname "$OUT")/history.jsonl"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-report.sh" "$OUT/report.md"
```

Compute the delta against the previous run's `findings.json` (the latest two date directories; first run states "first run, no delta"), then append one line to the history ledger, replacing any line for the same date:

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
ELK_KIND=$(sh "$TT" "$CFG" elk kind); ELK_N=$(sh "$TT" "$CFG" elk count)
ELK_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$ELK_N" ]; do [ "$(sh "$TT" "$CFG" elk label "$_i")" = "$SCOUTFLO_TARGET" ] && { ELK_IDX=$_i; break; }; _i=$((_i+1)); done; fi
ELK_LABEL=$(sh "$TT" "$CFG" elk label "$ELK_IDX")
if [ "$ELK_KIND" = seq ]; then ELK_SEG="elk/${ELK_LABEL}"; else ELK_SEG="elk"; fi
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${ELK_SEG}"
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${TARGET_DIR}/${RUN_DATE}"
RESOLVED="0"   # fixed count from this run's delta; 0 on the first run
LINE="$(jq -c --arg d "$RUN_DATE" --argjson resolved "$RESOLVED" \
  '{run_date:$d, skill:"audit-elk", overall:.score.overall, gate:.score.gate,
    end_to_end:.score.end_to_end, severity_counts:.severity_counts,
    lifecycle_counts:((reduce .findings[].lifecycle as $l ({}; .[$l] = (.[$l] // 0) + 1)) + {resolved:$resolved})}' \
  "$OUT/findings.json")"
TMP="$(mktemp)"
[ -f "${TARGET_DIR}/history.jsonl" ] && grep -v "\"run_date\":\"${RUN_DATE}\"" "${TARGET_DIR}/history.jsonl" > "$TMP" || true
printf '%s\n' "$LINE" >> "$TMP"
mv "$TMP" "${TARGET_DIR}/history.jsonl"
tail -1 "${TARGET_DIR}/history.jsonl" | jq -e '.run_date and (.overall >= 0)' >/dev/null && echo "history.jsonl updated"
```

The report's trend line renders the last five history.jsonl entries, oldest first. After the report is written, close with the run-completion message per the report standard ([report-template.md](../../report-standard/report-template.md#run-completion-message-what-the-skill-says-in-chat-when-the-run-finishes)): the one-line score headline, the top fixes by points_recoverable, the **absolute** report path, the OS-specific open command, and the leak-safe share pointer (Slack brief). Then send the Slack brief exactly as [report-template.md](../../report-standard/report-template.md) specifies: score, severity counts, top finding titles, delta line, topology readiness line, report path — titles only, never evidence values. When invoked by `audit-all`, skip the brief; the orchestrator sends exactly one combined message per run. Keep `./scoutflo-audits/` out of public version control; reports describe your alerting setup.


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

No `setup-elk` ships yet, so every finding's `remediation` field names the concrete manual fix location. When a setup skill lands, these become anchors without the finding IDs changing:

| Finding area | Fix location today |
| --- | --- |
| Rule with no action, or a dead/deprecated connector (ELK-001, ELK-002) | Kibana > Stack Management > Rules — add an action; Connectors — fix missing secrets or replace the deprecated connector |
| Orphaned connectors (ELK-003) | Connectors list — remove connectors referenced by no rule |
| Alerting framework insecure or no encryption key (ELK-004) | Put Kibana behind TLS and set `xpack.encryptedSavedObjects.encryptionKey` in kibana.yml |
| Critical rule delivers only to a sink connector (ELK-005) | Kibana > Stack Management > Rules > the rule > Actions — add an action targeting a live paging connector (PagerDuty/Opsgenie/Slack) alongside or instead of the `.server-log`/`.index` sink |
| Connector fan-in single point of failure (ELK-006) | Kibana > Connectors + the critical rules' Actions tabs — add a second independent paging connector so one connector failure cannot dark every critical service |
| Rules in error or warning, failed last run (ELK-010 to ELK-012) | Rule details > execution log — fix the query, timeout, or maxAlerts cap |
| Enabled rule stopped executing / stale last-run (ELK-014) | Rule details > execution log to confirm the gap, then check Kibana task-manager health/capacity (`xpack.task_manager` settings, task-manager health API) — a fleet-wide stall is a capacity problem, a single stale rule is usually a stuck task |
| Deliberately-off rule that should be live (ELK-013) | Rule details — enable it, or record why it is off |
| Flapping off, no debounce, re-notify spam, per-alert fan-out (ELK-020 to ELK-023) | Rule edit > Advanced — enable flapping, set alert_delay, throttle actions or use onActionGroupChange, enable action summary |
| Indefinite snooze or mute_all (ELK-024) | Rule details — unsnooze or time-bound the snooze |
| Permanent maintenance window (ELK-025) | Stack Management > Maintenance Windows — time-bound or remove it |
| Signal-class or service coverage gaps, Watcher split (ELK-030 to ELK-032) | Add the missing rule types/rules; migrate legacy Watcher watches to Kibana Alerting |
| No rules visible in any discovered space (ELK-033) | Confirm which Kibana space holds the rules (`GET /api/spaces/space`); if the key sees only some spaces, widen its role to grant the three Read feature privileges at `spaces:["*"]` (`/scoutflo:connect`), or set `elk.spaces` to the space that holds the rules |
| Topology readiness gaps with no finding | `/scoutflo:map-topology` |

## Common Failure Modes

All thresholds and windows named in the checks are example values; tune them to your workloads before treating a miss as a failure.

| Failure | Prevention |
| --- | --- |
| `elk.kibana_url` set to the Elasticsearch host | Alerting is a Kibana API; a 404 on `/api/alerting/*` means the URL is Elasticsearch (`:9200`), not Kibana (`:5601`) |
| Only the default space audited, other spaces silently missed (the customer 0/100 bug) | Discover spaces via `GET /api/spaces/space` (Phase 1 / elk-checks.md 4a), audit all visible or the `elk.spaces` subset, and treat a single visible space with 0 rules as the ELK-033 visibility trip-wire — never a confident 0/100 or a vacuous-high score |
| Space discovery returns only `default` even though rules exist elsewhere | The key sees only spaces where it holds a privilege; a single-space key enumerates one space. Widen the key to `spaces:["*"]` read (see `/scoutflo:connect`); the report states discovery may be incomplete |
| `flapping: null` flagged as flapping-disabled | null means "use the space default", which is ON; only an explicit `enabled:false` or a weak window is a finding |
| Maintenance-window check failed on Kibana 8.x/9.0/9.1 | The public maintenance-window API is 9.2+; version-gate ELK-025 to not-in-scope on older versions |
| Legacy `/api/alerts/*` used | Those routes were removed in 9.0; this audit uses `/api/alerting/rule(s)` only |
| Errored rule counted as coverage | A rule in execution error detects nothing; ELK-010 excludes it from the working set |
| Watcher-covered service reported as unmonitored | Detect the Watcher split (ELK-032); a Kibana-only view does not see Watcher watches |
| Rule count scored as coverage | Count rules that execute cleanly and reach a live connector, per service and per space |
| `onActiveAlert` with no throttle read as fine | It re-notifies every check interval on a stuck alert; the fix is a throttle or onActionGroupChange |
| Connector config or rule params written to evidence | Capture IDs, names, types, execution state, and noise-control fields; never a raw config that could carry a secret |
| ES API key sent as a Bearer token | Kibana takes the encoded key as `Authorization: ApiKey <encoded>`, not `Bearer` |
