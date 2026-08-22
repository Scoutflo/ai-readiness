---
name: audit-elk
description: Read-only scored audit of Kibana Alerting across rule notification delivery, dead connectors, rule execution health (error/warning states), alert noise controls (flapping detection, alert_delay, action throttling, snoozes), and rule-type coverage per Kibana space; writes findings.json and report.md and changes nothing. Use when the user mentions auditing or scoring ELK, Elastic, Kibana alerting, Kibana rules, Watcher, dead Kibana connectors, flapping rules, or snoozed rules. Do not use to change Kibana (no setup-elk ships yet; the audit names each fix), for Elasticsearch cluster or index health, or for Grafana-rendered Elastic data (use audit-grafana).
---

# audit-elk

Scored, read-only audit of the Kibana Alerting rules that watch your Elastic data: whether each rule reaches a live connector, whether the rule itself is executing cleanly, whether its noise controls are tuned, and whether the rule set actually covers your critical services — across every Kibana space you point it at. It answers one question: when a log or metric condition trips in Elastic tonight, does a healthy rule fire to a reachable connector without drowning the responder in repeats?

This skill audits **Kibana Alerting** (Stack Rules and their connectors), not Elasticsearch cluster health, index lifecycle, or the data the rules query. Elastic data rendered in Grafana is `audit-grafana`. Legacy Watcher watches live in Elasticsearch, not Kibana; this audit detects that a split exists (ELK-032) so a Kibana-only view does not silently imply Watcher-covered services are unmonitored, but it does not deeply audit Watcher itself.

Every command is read-only: GET on rules, connectors, rule types, health, and (on 9.2+) maintenance windows, plus a read-by-query on Elasticsearch `_watcher/stats` for the split check. Every mutating verb — enable, disable, mute, snooze, connector execute — is forbidden; the full list is in [references/elk-checks.md](references/elk-checks.md) section 12. There is no `setup-elk` yet, so every finding names its manual fix path in Kibana instead of a setup anchor.

Run this standalone, from `/scoutflo:audit-all`, or on a schedule via `/scoutflo:schedule-audits`.

Outputs, per the [report standard](../../report-standard/README.md):

- `./scoutflo-audits/elk/<YYYY-MM-DD>/findings.json` per the [findings schema](../../report-standard/findings-schema.md), finding IDs `ELK-NNN`
- `./scoutflo-audits/elk/<YYYY-MM-DD>/report.md` per the [report template](../../report-standard/report-template.md), including the `## Inventory` section (the `render-report-viz.sh inventory` output)
- `./scoutflo-audits/elk/<YYYY-MM-DD>/inventory.json` per the [inventory schema](../../report-standard/inventory-schema.md) (`scoutflo-inventory/v1`): the complete Phase-1 catalog — one item per Kibana alerting rule and connector, each with `kind`, `covers`, `enabled`, `severity`, and `routes_to` for alerting objects. Built from the raw pull, never invented; redacted at capture, never a secret value.
- One appended line in `./scoutflo-audits/elk/history.jsonl`
- One Slack brief, when `slack.webhook_env` is configured

## Doctor gate

| Integration | toolkit.yaml keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| ELK / Kibana | `elk.kibana_url`, `elk.token_env`, optional `elk.spaces` (a *restriction* on the auto-discovered set) | the variable named by `token_env` (`KIBANA_API_KEY`) | Elasticsearch API key whose role has Kibana Read on Stack Rules, Rules Settings, and Actions and Connectors, granted at **`spaces:["*"]`** so `GET /api/spaces/space` discovery is complete (recipe in `/scoutflo:connect`) — a narrower per-space scope hides spaces and recreates the empty-default bug | read-only |
| Slack (optional) | `slack.webhook_env` | webhook variable | post to one channel | n/a |

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || { if [ -f "./.scoutflo/toolkit.yaml" ]; then CFG="./.scoutflo/toolkit.yaml"; else CFG="$HOME/.scoutflo/toolkit.yaml"; fi; }
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
# Load the home-anchored secret store so a token added to ~/.scoutflo/env (by connect,
# even mid-session) is seen here without re-exporting or opening a new terminal. It only
# sets *_env variables; no secret value is printed. A profile that already sources it makes
# this a no-op. This mirrors what /scoutflo:doctor does, so doctor and this audit agree.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
for bin in curl jq; do
  command -v "$bin" >/dev/null || { echo "missing binary: $bin"; exit 1; }
done
# elk.token_env names the variable; presence check only, never print the value.
[ -n "${KIBANA_API_KEY:-}" ] || { echo "KIBANA_API_KEY is not set; run /scoutflo:connect"; exit 1; }

KIBANA_URL="https://kibana.example.com"   # elk.kibana_url (Kibana, not Elasticsearch)
KIBANA_URL="${KIBANA_URL%/}"
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -H "Authorization: ApiKey ${KIBANA_API_KEY}" "${KIBANA_URL}/api/alerting/_health")"
[ "$CODE" = "200" ] || { echo "alerting health probe returned ${CODE}: 404 = elk.kibana_url points at Elasticsearch not Kibana (or a space/base-path prefix is wrong); 401/403 = key invalid or role lacks Kibana Read on Stack Rules"; exit 1; }
echo "doctor gate: pass"
```

Never proceed past a failed doctor check and never downgrade one into a finding. `/scoutflo:doctor` runs the same probe standalone. The `/api/alerting/_health` response is also an audit input (ELK-004): its `is_sufficiently_secure` and `has_permanent_encryption_key` fields are read in Phase 3.

The tier is enforced by Kibana feature privileges on the key's role and cannot be introspected from the key itself; if a broader key is used the audit still runs, but record in the report that the audit credential can do more than read.

## Live-safety gate

Print what you are pointed at and compare it to the config before the first real check:

```bash
set -eu
KIBANA_URL="https://kibana.example.com"   # elk.kibana_url
KIBANA_URL="${KIBANA_URL%/}"
STATUS_JSON="$(curl -fsS --max-time 15 -H "Authorization: ApiKey ${KIBANA_API_KEY}" \
  "${KIBANA_URL}/api/status" 2>/dev/null || echo '{}')"
VER="$(printf '%s' "$STATUS_JSON" | jq -r '.version.number // "unknown"')"
NAME="$(printf '%s' "$STATUS_JSON" | jq -r '.name // "unknown"')"
echo "kibana_url=${KIBANA_URL} name=${NAME} version=${VER}"
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
KIBANA_URL="https://kibana.example.com"   # elk.kibana_url
KIBANA_URL="${KIBANA_URL%/}"
SMALL_MAX_OBJECTS="30"    # example, tune to your environment
MEDIUM_MAX_OBJECTS="150"  # example, tune to your environment
BATCH_SIZE="50"           # rules per batch on the large path; example, tune it
AUTH="Authorization: ApiKey ${KIBANA_API_KEY}"
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/elk/${RUN_DATE}/raw"
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
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/elk"
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
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/elk/${RUN_DATE}/raw"
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

## Phase 3: Rule delivery (ELK-001 to ELK-004)

Commands in section 5. Every enabled rule has at least one action (`ELK-001`, critical — a rule with no connector detects but pages nobody), no rule targets a connector with missing secrets or a deprecated connector (`ELK-002`, high — the alert fires but cannot be delivered), no orphaned connectors referenced by zero rules (`ELK-003`, low drift), and the alerting framework itself is healthy (`ELK-004`, high — `is_sufficiently_secure` false or no permanent encryption key means alerting is not durably or securely wired).

- ❌ `Delivery pass: every rule has an action.`
- ✅ `Delivery partial: every enabled rule has an action, but four target the "oncall-slack" connector which reports is_missing_secrets (ELK-002), and the framework has no permanent encryption key so rules break across restarts (ELK-004); affected: checkout, payments.`

## Phase 4: Rule health (ELK-010 to ELK-013)

Commands in section 6. No rule stuck in `execution_status: error` — silent coverage that detects nothing (`ELK-010`, critical), no rule in `warning` from a timeout or a maxAlerts/maxQueuedActions cap that silently drops alerts (`ELK-011`, high), `last_run.outcome` succeeded on every enabled rule (`ELK-012`), and disabled rules judged against intent rather than flagged on the disabled flag alone (`ELK-013`).

## Phase 5: Alert noise (ELK-020 to ELK-025)

Commands in section 7. This is the alert-hygiene category. Flapping detection on where a rule can toggle — remembering that `null` means the healthy space default is in force, so only an explicit disable or weak window is a finding (`ELK-020`), `alert_delay.active` set where a spiky signal needs FOR-like debounce (`ELK-021`), actions throttled or set to `onActionGroupChange` rather than re-notifying every check interval (`ELK-022`), action summaries on high-cardinality rules instead of per-alert fan-out (`ELK-023`), no rule snoozed indefinitely or `mute_all` with no end — a stuck blind spot (`ELK-024`, high), and no permanent maintenance window (`ELK-025`, version-gated to Kibana 9.2+; on older versions it reports `not-in-scope` with the detected version, never a fail).

Honest ceiling, stated in the report every run: rule configuration is intent; whether a rule actually flapped or fanned out lives in its alert history, which this audit reads at the summary level (`alerts_count`, execution state) but does not fully reconstruct. Space-level flapping settings are read-only via an internal Kibana API in 9.x, so this audit judges flapping per rule and states that the space-level default was assumed ON rather than read.

## Phase 6: Coverage (ELK-030 to ELK-032)

Commands in section 8. Rule-type coverage — a space using only one rule type may have blind signal classes (`ELK-030`), critical services from topology each covered by at least one rule (`ELK-031`), the legacy-Watcher-versus-Kibana-Alerting split identified so a Kibana-only view does not silently miss Watcher-covered services (`ELK-032` — needs `elk.es_url` and the `monitor_watcher` privilege; blocked with that reason when absent), and rules visible in at least one discovered space (`ELK-033`, high — zero rules across every space this key can see is `blocked` with the visibility-gap reason from the Phase-1 guardrail, not a plain fail; it points at widening the key to `spaces:["*"]` read).

## Phase 7: Coverage matrix and topology readiness

Fill one row per critical service using the per-service mapping in section 10 and the check-result vocabulary (`pass`, `partial`, `fail`, `blocked`, `not-in-scope`):

| Service | Ready | Delivery | Health | Noise | Coverage | Space | Gap |
| --- | --- | --- | --- | --- | --- | --- | --- |

Every cell carries its `passed/total` denominator; the Space column names which Kibana space the rule lives in. Name affected services in findings.

Then render the Scoutflo Topology Readiness section per [topology-readiness.md](../../report-standard/topology-readiness.md): evaluate the six checks per critical service from `./scoutflo-audits/topology-export.json`, read-only. Gaps that map to an existing finding reference its ID; gaps with no finding get a `TOPO-` row pointing at `/scoutflo:map-topology`. Render check names and confidence per the standard: plain-English column headers, confidence as `n/10`, and — whenever any service is below ready — the ticket-ready readiness action plan table. If the export or topology.md is missing, or exists but describes a different target than this audit covers, the section renders the matching state from topology-readiness.md with its one-line unlock; it never guesses and never says a bare "unavailable". Readiness is reported, never folded into the 0-100 score.

**Provider-identity note, verified against the platform's current model:** ELK's identity on the Scoutflo platform is a **logging** provider (`logging.elk`), whose required schema fields describe the log index it correlates against (`indexPattern`, `timeField`, `serviceField`, `serviceValue`, `messageField`), not the alerting rules this audit scores. The schema does carry optional alert-correlation fields (`alertRuleId`, `watcherId`) that a Kibana alerting rule maps onto. So a `SENDS_LOGS_TO` connection to ELK reaches full confidence on the log-correlation fields; the alerting rules this audit checks populate the optional `alertRuleId`, which is a `MONITORED_BY`-style signal layered on top. State plainly which of the two roles a given connection is playing when it stalls at partial, rather than treating a healthy log-source connection as if it were an alerting gap.

## Phase 8: Score, write, brief

Score per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md): each check yields `pass` (1.0), `partial` (0.5), `fail`/`blocked` (0), `not-in-scope` leaves the denominator. Category score is the credit ratio times 100 rounded down; overall is the weight-normalized sum over included categories. Whole categories that could not be assessed (a space that 403'd; ELK-025 on a pre-9.2 version leaves that one check not-in-scope, not the whole category) are excluded, renormalized, and stated. Score conservatively. Assign each category a maturity value (`reactive`, `proactive`, `systematic`).

**Empty / hidden estate (ELK-033, from the Phase-1 guardrail):** when zero rules are visible across every discoverable space, do not emit a confident `0/100` — nor a vacuously-high score from checks that pass on an empty set. Exclude the three rule-dependent categories — **Rule health, Alert noise, Coverage** — by authoring them into `score.excluded` with the reason ("no alerting rules visible to this credential; rules may live in a space this key cannot see — widen to `spaces:[\"*\"]` read", or "space discovery unavailable" on the 4a 404 fallback), and renormalize over what remains. **Keep Rule delivery included** and score it from its rule-independent checks (ELK-004 framework health, ELK-002/003 connectors); do **not** exclude all four categories — an all-excluded scorecard has no denominator and `check-findings.sh` rejects it. Emit ELK-033 (Coverage) with evidence (the discovered-vs-audited space sets) and a remediation pointer. The overall then reconciles as Rule delivery's score over the one remaining weight.

| Category | Weight | ID range |
| --- | ---: | --- |
| Rule delivery | 30 | ELK-001 to ELK-004 |
| Rule health | 25 | ELK-010 to ELK-013 |
| Alert noise | 25 | ELK-020 to ELK-025 |
| Coverage | 20 | ELK-030 to ELK-033 |

The full check catalog and the target profile (what 100 means per category) are at the top of [references/elk-checks.md](references/elk-checks.md). IDs are stable: the same defect gets the same ID every run, one finding per failed check, affected objects and their space enumerated. Compute `points_recoverable` per finding by re-running the scoring model with that check at full credit; `info` findings and excluded categories carry 0. The executive summary states the gap to target and the two or three findings with the highest `points_recoverable` as the biggest levers.

End-to-end gate: claim end-to-end coverage only when the overall score is at or above 85, every critical service passes every applicable coverage row, and no category or space was excluded. Below the gate, write "good base coverage", never "end to end". A run that audited only some spaces cannot claim end-to-end; say which spaces the claim rests on.

Lifecycle, exemptions, and totals, before rendering the report:

1. Load the previous run's `findings.json` when one exists; classify every finding per the lifecycle table in the [findings schema](../../report-standard/findings-schema.md) (`new`, `unchanged`, `regressed`; resolved IDs go to the delta, and the executive summary names regressions first).
2. Load `./scoutflo-audits/exemptions.yaml` when present. Entries with `id`, `reason`, and `expires` all set and unexpired suppress their finding into the Suppressed appendix; malformed or expired entries are reported, never honored.
3. Every findings area and coverage cell carries its denominator (`passed/total`).

Emit and verify:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/elk/${RUN_DATE}"
mkdir -p "$OUT"
# ... write findings.json, inventory.json, and report.md per the report standard, then verify:
jq -e '.schema == "scoutflo-findings/v1" and .target == "elk" and (.findings | type == "array")' \
  "$OUT/findings.json" >/dev/null && echo "findings.json valid"
grep -q '^# ' "$OUT/report.md" && echo "report.md present"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-findings.sh" "$OUT/findings.json"
# Inventory (scoutflo-inventory/v1): the complete Phase-1 catalog of what exists,
# built from the raw pull (never invented, redacted). counts.total must reconcile
# with items; the ## Inventory section of report.md IS this render.
jq -e '.schema == "scoutflo-inventory/v1" and .target == "elk"
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
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/elk"
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
BC_JSON="${HOME}/.scoutflo/business_context.json"      # derived from business_context.md (the SSOT)
METADATA="${HOME}/.scoutflo/computed_metadata.jsonl"   # per-resource cache from business-context-resolver
LOAD_METADATA_MODE="none"
if [ -f "$METADATA" ] && jq -e '.' "$METADATA" >/dev/null 2>&1; then
  LOAD_METADATA_MODE="per-resource"
elif [ -f "$BC_JSON" ] && jq -e '.' "$BC_JSON" >/dev/null 2>&1; then
  LOAD_METADATA_MODE="workspace"
fi
echo "metadata mode: $LOAD_METADATA_MODE"
```

When context is available, apply it per [BUSINESS-CONTEXT-INTEGRATION-v0168.md](../../docs/BUSINESS-CONTEXT-INTEGRATION-v0168.md): **exclude** resources matched by an exclusion (record them `not-in-scope` with the reason, never a fail); **escalate** findings on a `critical_dependencies` service; reduce severity for a gap that exists only in a non-production `environment`; and apply `cost_sensitivity` to ordering. With no context, run neutral defaults and say so — never invent a business rule.

## Remediation pointers

No `setup-elk` ships yet, so every finding's `remediation` field names the concrete manual fix location. When a setup skill lands, these become anchors without the finding IDs changing:

| Finding area | Fix location today |
| --- | --- |
| Rule with no action, or a dead/deprecated connector (ELK-001, ELK-002) | Kibana > Stack Management > Rules — add an action; Connectors — fix missing secrets or replace the deprecated connector |
| Orphaned connectors (ELK-003) | Connectors list — remove connectors referenced by no rule |
| Alerting framework insecure or no encryption key (ELK-004) | Put Kibana behind TLS and set `xpack.encryptedSavedObjects.encryptionKey` in kibana.yml |
| Rules in error or warning, failed last run (ELK-010 to ELK-012) | Rule details > execution log — fix the query, timeout, or maxAlerts cap |
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
