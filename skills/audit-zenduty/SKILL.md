---
name: audit-zenduty
description: Read-only scored audit of Zenduty (Xurrent IMR) paging health across escalation and on-call, alert-rule and service-level noise controls (collation dedup, suppress rules, correlation, delay, maintenance windows), integration and routing hygiene, and a server-side-analytics-backed actionability section (MTTA, MTTR, acked and resolved share); writes findings.json and report.md and changes nothing. Use when the user mentions auditing or scoring Zenduty or Xurrent IMR, escalation policies, on-call gaps, alert rules or suppress rules, alert collation or correlation, dead Zenduty integrations, global alert routing, or unacknowledged Zenduty incidents. Do not use to change Zenduty (no setup-zenduty ships yet; the audit names each fix), or for the monitoring tools that send events to Zenduty (use their own audits).
---

# audit-zenduty

Scored, read-only audit of the Zenduty (Xurrent IMR) account that carries your paging: teams and their escalation policies and on-call schedules, per-service noise controls and per-integration alert rules, global alert routing, maintenance windows, and the vendor's own analytics on what happened to the incidents it raised. It answers one question: when a monitoring tool sends Zenduty an alert tonight, does a reachable human get paged exactly once, and did anyone act on it?

This skill audits the Zenduty paging layer, not the monitoring tools that *send* events into it. The `for` durations, recovery thresholds, and grouping of those upstream tools belong to their own audits (`audit-lgtm`, `audit-grafana`, `audit-sentry`, `audit-datadog`, `audit-alert-routing`); this audit picks up where an event has already arrived at Zenduty.

Zenduty was acquired by Xurrent and rebranded **Xurrent IMR** (a branding change, not a sunset); the API and product are alive and everything still runs through `https://www.zenduty.com/api/...`. Every command is read-only: GET, plus two documented read-by-POST calls (the incident filter and the analytics endpoints, which aggregate server-side and change nothing). Every mutating verb is forbidden; the full list is in [references/zenduty-checks.md](references/zenduty-checks.md) section 13. There is no `setup-zenduty` yet, so every finding names its manual fix path in the Zenduty UI or API instead of a setup anchor.

Run this standalone, from `/scoutflo:audit-all`, or on a schedule via `/scoutflo:schedule-audits`.

Outputs, per the [report standard](../../report-standard/README.md):

- `./scoutflo-audits/zenduty/<YYYY-MM-DD>/findings.json` per the [findings schema](../../report-standard/findings-schema.md), finding IDs `ZD-NNN`
- `./scoutflo-audits/zenduty/<YYYY-MM-DD>/report.md` per the [report template](../../report-standard/report-template.md)
- One appended line in `./scoutflo-audits/zenduty/history.jsonl`
- One Slack brief, when `slack.webhook_env` is configured

## Doctor gate

| Integration | toolkit.yaml keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| Zenduty | `zenduty.token_env`, optional `zenduty.teams` | the variable named by `token_env` (`ZENDUTY_TOKEN`) | API key sent as `Authorization: Token <key>`; a Bot Token (Beta) with view-only permissions is the least-privilege path (recipe in `/scoutflo:connect`) | read-only |
| Slack (optional) | `slack.webhook_env` | webhook variable | post to one channel | n/a |

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-$HOME/.scoutflo/toolkit.yaml}"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
for bin in curl jq; do
  command -v "$bin" >/dev/null || { echo "missing binary: $bin"; exit 1; }
done
# zenduty.token_env names the variable; presence check only, never print the value.
[ -n "${ZENDUTY_TOKEN:-}" ] || { echo "ZENDUTY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

ZD_API="https://www.zenduty.com/api"
# Teams is the cheapest list read. Auth is "Token <key>", the literal word Token, not Bearer.
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -H "Authorization: Token ${ZENDUTY_TOKEN}" "${ZD_API}/account/teams/")"
[ "$CODE" = "200" ] || { echo "teams probe returned ${CODE}: 401/403 = key invalid or not 'Token'-prefixed (not Bearer); 429 = rate-limited, wait a minute"; exit 1; }
echo "doctor gate: pass"
```

Never proceed past a failed doctor check and never downgrade one into a finding. `/scoutflo:doctor` runs the same probe standalone.

Zenduty has no read-only key scope: a standard API key inherits full account access. Read-only is enforced by this skill using GET only (plus the two read-by-POST calls above). The tier is therefore declared, not proven; a Bot Token with view-only permissions is the least-privilege credential, and if a full-access key is used the audit still runs, but record in the report that the audit credential can write.

## Live-safety gate

Print what you are pointed at and compare it to the config before the first real check:

```bash
set -eu
ZD_API="https://www.zenduty.com/api"
# Zenduty has no whoami; the account is identified by the teams the key reads.
TEAMS_SAMPLE="$(curl -fsS --max-time 15 -H "Authorization: Token ${ZENDUTY_TOKEN}" "${ZD_API}/account/teams/")"
COUNT="$(printf '%s' "$TEAMS_SAMPLE" | jq 'if type=="array" then length else (.results // []) | length end')"
NAMES="$(printf '%s' "$TEAMS_SAMPLE" | jq -r 'if type=="array" then . else (.results // []) end | [.[].name] | join(", ")')"
echo "api=${ZD_API} sample_teams=${COUNT}: ${NAMES}"
printf '%s' "$TEAMS_SAMPLE" | jq -e 'if type=="array" then . else (.results // []) end | type == "array"' >/dev/null \
  || { echo "teams endpoint did not return a team list; wrong key or wrong host — stop"; exit 1; }
echo "live-safety gate: pass — confirm these team names belong to the account you intend to audit"
```

The key in the environment is the account selector; there is no ambient default beyond it. The printed sample team names are the human check: if they belong to a different org than intended, stop and fix the exported key before any further read.

## Ground rules

- Configuration is metadata; observed behavior is proof. An escalation policy in the list is `configured`; only rendered on-call, a service with `collation` actually on, or an analytics-observed acknowledgement makes the paging path `validated-live`.
- API errors are evidence. A `401`/`403` means the key is invalid or not `Token`-prefixed; a `429` is the rate limiter, not an outage. Record the code and what it implies; never convert an error into empty success.
- **Rate limits are the defining constraint and are tight, per endpoint class.** Zenduty publishes per-class limits (for example incident GET 3/second, 30/minute; alert GET 1/second, 20/minute; list GETs 5/second, 40/minute). This audit throttles by design and paces a large account rather than racing it; see [references/zenduty-checks.md](references/zenduty-checks.md) section 9. A run that gets throttled records the affected checks as `blocked` with the reason, never a fabricated pass.
- Never score from object counts.
  - ❌ `Scored escalation 90: eleven escalation policies exist.`
  - ✅ `Scored escalation 45: every team has a policy, but two are single-target with repeat_policy 0, and one service has collation off; credit stops at partial.`
- Paging config is team-scoped; coverage denominators name the teams audited.
  - ❌ `Scored coverage 90: correlation is on.` (which team? which service?)
  - ✅ `Scored coverage 55: the payments and platform teams were audited (zenduty.teams); the data team was not and is named as uncovered; within the two audited teams, three services have collation off.`
- The `collation` field is the only reliably-readable dedup signal (`0` off, `1` time-based, with `collation_time` minutes); content-based and AI correlation are not exposed as distinct `collation` values in the API, so this audit judges time-based-dedup-vs-off per service and states that content-based correlation is not API-readable rather than guessing.
- Actionability is the vendor's own measured statistic, never fabricated. `mtta_seconds`/`mttr_seconds` and the acked/resolved counts come from the analytics API; an invented "N% of your alerts are actionable" figure is banned, consistent with every other skill in this toolkit.
- Never write a raw integration config, webhook, or contact value to disk, evidence, or the report. Captures keep IDs (`unique_id`), names, types, states, and timestamps only.

## Version and shape traps

Current API-shape facts, all handled in the reference commands; do not "simplify" them away:

- **Auth is `Authorization: Token <key>`** — the literal word `Token`, not `Bearer`, even though the scheme is HTTP-bearer under the hood. A `Bearer`-prefixed call 401s.
- **Incident listing is a read-by-POST**: `POST /api/incidents/filter/` with a filter body. There is no `GET /api/incidents/` list (that path is create-only). Ack state is derived from the incident `status` integer (`1` triggered/unacked, `2` acknowledged, `3` resolved; `-1` open), not a boolean field.
- **The dedup field is `collation`, not `correlation`.** `collation: 0` is off, `1` is time-based; `collation_time` is the window in minutes (valid 2 to 1439 when on). The API does not expose content-based or AI correlation as `collation` values.
- **Escalation repeat is `repeat_policy`** (an integer), and a target is `{target_type, target_id}`. A single rule with one target and `repeat_policy: 0` is the single-point-of-failure shape.
- **The legacy "API-Integration" ingestion type stopped working 2025-05-15.** Any integration still on it is migration debt, not a working path; the replacement is the Generic Integration.
- **Maintenance windows are `{repeat_interval, repeat_until (nullable), services[]}`.** A window with `repeat_interval` non-zero and `repeat_until: null` is an open-ended recurring suppression.

## Estate sizing

Count before judging, and declare the path in the terminal output:

```bash
set -eu
ZD_API="https://www.zenduty.com/api"
SMALL_MAX_OBJECTS="15"    # example, tune to your environment
MEDIUM_MAX_OBJECTS="60"   # example, tune to your environment
BATCH_SIZE="10"           # teams per batch on the large path; example, tune it
# Teams is one list read; services/escalations are per-team, so the team count sets the path.
TEAMS_JSON="$(curl -fsS --max-time 15 -H "Authorization: Token ${ZENDUTY_TOKEN}" "${ZD_API}/account/teams/")"
TEAMS="$(printf '%s' "$TEAMS_JSON" | jq 'if type=="array" then length else (.results // []) | length end')"
# Sum services across teams for the scored-object estimate (bounded; one list per team).
SERVICES=0
for TID in $(printf '%s' "$TEAMS_JSON" | jq -r 'if type=="array" then . else (.results // []) end | [.[].unique_id] | .[]'); do
  N="$(curl -fsS --max-time 15 -H "Authorization: Token ${ZENDUTY_TOKEN}" "${ZD_API}/account/teams/${TID}/services/" \
    | jq 'if type=="array" then length else (.results // []) | length end')"
  SERVICES=$((SERVICES + N))
  sleep 1   # respect the tight list-GET rate limit; see references section 9
done
TOTAL=$((TEAMS + SERVICES))
echo "teams=${TEAMS} services=${SERVICES} scored_objects=${TOTAL}"

# Guided-walkthrough drift check, per report-standard/README.md.
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/zenduty"
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

- **Small** (`TOTAL <= SMALL_MAX_OBJECTS`): one pass over everything. No worklist, no batching.
- **Medium** (`TOTAL <= MEDIUM_MAX_OBJECTS`): per-category passes (escalation/on-call, noise, coverage, actionability), completed in one run.
- **Large**: work teams in batches of `BATCH_SIZE` against a durable, run-ID-keyed worklist per the worklist rules in [skill-authoring-conventions.md](../../docs/skill-authoring-conventions.md): scan for a resumable run before minting a new run ID, one row per team id, lock before claiming a batch, mark rows done only after their pulls succeed, and assert zero pending rows before Phase 8 writes anything.

Never silently truncate: name the teams audited and any team skipped, and reflect it in the coverage denominators. The tight per-endpoint rate limits make pacing mandatory; the retry rule in [references/zenduty-checks.md](references/zenduty-checks.md) section 9 applies to every call.

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

## Phase 1: Service context and teams

If `./scoutflo-audits/topology.md` exists, load it; its service list is the critical-service list and its names are canonical. Resolve the teams to audit from `zenduty.teams` (discover from `GET /api/account/teams/` when omitted, using each team's `unique_id` to scope later calls) and state them in the report. If topology.md does not exist, infer critical services from team and service names, note the inference, and suggest `/scoutflo:map-topology`.

## Phase 2: Read-only inventory

Build the raw picture with the commands in [references/zenduty-checks.md](references/zenduty-checks.md) section 4, pacing per the rate-limit rule: the audited teams, and per team the escalation policies (with rule and target shapes), on-call, schedules, services (with `collation`/`collation_time` and status), per-service integrations (with `is_enabled` and ingestion type) and their alert rules, and maintenance windows; plus the global alert routers. Judgment starts in Phase 3. A 403 on any surface is an auth-scope note; a 429 is a pacing signal, not a finding.

## Phase 3: Escalation and on-call (ZD-001 to ZD-005)

Commands in section 5. Judge whether a page reaches a reachable human: every audited team has an escalation policy and no production team's policy is a single rule with one target and `repeat_policy: 0` (`ZD-001`, critical when missing, high on the SPOF shape), escalation levels and repeat deliberate rather than a one-shot (`ZD-002`), every escalation policy's on-call resolves to a staffed rotation now — an empty `oncalls` user array pages nobody (`ZD-003`, high), schedules referenced are non-empty and cover the window (`ZD-004`), and no integration on a live ingestion path sits `is_enabled: false` so nothing can create alerts (`ZD-005`, critical).

- ❌ `Escalation pass: every team names a policy.`
- ✅ `Escalation partial: every team has a policy, but the payments team's is one rule, one user, repeat_policy 0 (ZD-001), and its primary escalation has an empty on-call now (ZD-003); affected: payments.`

## Phase 4: Alert noise (ZD-010 to ZD-016)

Commands in section 6. This is the alert-hygiene category. Per-service `collation` on where a service is chatty — remembering the API reads time-based-vs-off, and content-based correlation is not API-readable (`ZD-010`), suppress alert rules present for known-noisy sources and reviewed for over-broad matchers that silently drop real alerts (`ZD-011`, high — a suppress rule with an always-true condition is an accidental drop-all), the "Seconds Since Last Similar Incident" condition used to guard flapping where a source re-fires after resolution (`ZD-012`), delay-notification rules deliberate rather than blanket off-hours muting (`ZD-013`), a stable, non-blank `entity_id` so the default dedup collapses repeats — a rule that blanks or randomizes `entity_id` disables dedup (`ZD-014`), auto-acknowledge/auto-resolve working because sources emit resolve `alert_type`s rather than only ever firing (`ZD-015`), and no maintenance window that is an open-ended recurring suppression — `repeat_interval` set with `repeat_until: null` (`ZD-016`, high).

Honest ceiling, stated in the report every run: alert-rule and collation config is metadata about intent; whether alerts actually deduplicated lives in the incident and alert stream, which this audit reads at the summary level but does not fully reconstruct, and the tight alert-GET rate limit (1/second) means the stream is sampled, not exhaustively pulled. Content-based and AI correlation are not exposed in the API, so their absence is reported as "not API-readable", never as a fail.

## Phase 5: Coverage and hygiene (ZD-020 to ZD-023)

Commands in section 7. Global alert routing has no overlapping or duplicate routes that fan one alert to multiple services, and a default route exists (`ZD-020`), critical services from topology each covered by a team, a service, and an escalation path (`ZD-021`, high), the audited teams named and any team not audited named as uncovered rather than silently dropped (`ZD-022`), and no integration still on the deprecated "API-Integration" ingestion type that stopped working 2025-05-15 (`ZD-023`, migration debt).

## Phase 6: Actionability (ZD-030 to ZD-032)

Commands in section 8. Zenduty exposes **server-side analytics**, so — unlike some paging providers in this toolkit — this category rests on the vendor's own measured statistics, not a client-side reconstruction. Unacknowledged incidents older than the aging threshold from the incident filter, with ack state read from `status` (`ZD-030`, high — every one is a page nobody took), MTTA against target from the analytics `mtta_seconds` per service where humans acked (`ZD-031`), and MTTR against target from `mttr_seconds` alongside the acked/resolved share (`ZD-032`). All figures carry the analytics window in evidence.

- ❌ `Actionability: roughly 3% of pages appear actionable (industry benchmark).`
- ✅ `ZD-031 fail for checkout: mtta_seconds 2140 (36 min) over the last 30 days against a 15-min target (vendor analytics), on 88 acknowledged incidents; affected: checkout.`

## Phase 7: Coverage matrix and topology readiness

Fill one row per critical service using the per-service mapping in section 10 and the check-result vocabulary (`pass`, `partial`, `fail`, `blocked`, `not-in-scope`):

| Service | Ready | Escalation | On-call | Noise | Actionability | Team | Gap |
| --- | --- | --- | --- | --- | --- | --- | --- |

Every cell carries its `passed/total` denominator; the Team column names which Zenduty team the paging path lives in. Plan/pacing-blocked cells read `blocked` with the reason, not `fail`. Name affected services in findings.

Then render the Scoutflo Topology Readiness section per [topology-readiness.md](../../report-standard/topology-readiness.md): evaluate the six checks per critical service from `./scoutflo-audits/topology-export.json`, read-only. A `MONITORED_BY` connection to Zenduty that this audit verified live (the service resolved, its escalation staffed, and an analytics-observed acknowledgement in the window) counts toward Match confidence per the standard's live-verification rule. Gaps that map to an existing finding reference its ID; gaps with no finding get a `TOPO-` row pointing at `/scoutflo:map-topology`. Render check names and confidence per the standard: plain-English column headers, confidence as `n/10`, and — whenever any service is below ready — the ticket-ready readiness action plan table. If the export or topology.md is missing, or exists but describes a different target than this audit covers, the section renders the matching state from topology-readiness.md with its one-line unlock; it never guesses and never says a bare "unavailable". Readiness is reported, never folded into the 0-100 score.

**Provider-identity note, verified against the platform's current model:** `zenduty` is a valid provider identity with a typed attribute schema on the Scoutflo platform (`monitoring.zenduty`), so — like PagerDuty and unlike JSM's ticketing sink — a `MONITORED_BY` connection naming Zenduty can genuinely reach full confidence when its fields are present and this audit verified the path live. The schema's identity fields are camelCase (`serviceName`, `serviceId`, `escalationPolicyId`), and the platform's correlation-category mapping does not split camelCase, so populating only `serviceName` satisfies Connection details but leaves the Match confidence service anchor unpopulated (see [topology-readiness.md](../../report-standard/topology-readiness.md)'s internal note on this exact pattern). Mirror the `serviceName` value into a literal `service` or `service_name` key on the same connection's attributes, or Match confidence reads partial even though the connection genuinely resolved. State which fields the export carries versus which the schema requires when a connection stalls at partial.

## Phase 8: Score, write, brief

Score per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md): each check yields `pass` (1.0), `partial` (0.5), `fail`/`blocked` (0), `not-in-scope` leaves the denominator. Category score is the credit ratio times 100 rounded down; overall is the weight-normalized sum over included categories. Whole categories or teams that could not be assessed (a team that 403'd; a category the rate limiter blocked mid-run) are excluded, renormalized, and stated; blocked checks inside an assessable category score 0. Score conservatively: when unsure between two results, pick the lower and say why. Assign each category a maturity value (`reactive`, `proactive`, `systematic`).

| Category | Weight | ID range |
| --- | ---: | --- |
| Escalation and on-call | 30 | ZD-001 to ZD-005 |
| Alert noise | 25 | ZD-010 to ZD-016 |
| Coverage and hygiene | 20 | ZD-020 to ZD-023 |
| Actionability | 25 | ZD-030 to ZD-032 |

The full check catalog and the target profile (what 100 means per category) are at the top of [references/zenduty-checks.md](references/zenduty-checks.md). IDs are stable: the same defect gets the same ID every run, one finding per failed check, affected objects and their team enumerated. Compute `points_recoverable` per finding by re-running the scoring model with that check at full credit; `info` findings and excluded categories carry 0. The executive summary states the gap to target and the two or three findings with the highest `points_recoverable` as the biggest levers.

End-to-end gate: claim end-to-end coverage only when the overall score is at or above 85, every critical service passes every applicable coverage row, and no category or team was excluded. Below the gate, write "good base coverage", never "end to end". A run the rate limiter forced to skip some teams cannot claim end-to-end; say which teams the claim rests on.

Lifecycle, exemptions, and totals, before rendering the report:

1. Load the previous run's `findings.json` when one exists; classify every finding per the lifecycle table in the [findings schema](../../report-standard/findings-schema.md) (`new`, `unchanged`, `regressed`; resolved IDs go to the delta, and the executive summary names regressions first).
2. Load `./scoutflo-audits/exemptions.yaml` when present. Entries with `id`, `reason`, and `expires` all set and unexpired suppress their finding into the Suppressed appendix; malformed or expired entries are reported, never honored.
3. Every findings area and coverage cell carries its denominator (`passed/total`).

Emit and verify:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/zenduty/${RUN_DATE}"
mkdir -p "$OUT"
# ... write findings.json and report.md per the report standard, then verify:
jq -e '.schema == "scoutflo-findings/v1" and .target == "zenduty" and (.findings | type == "array")' \
  "$OUT/findings.json" >/dev/null && echo "findings.json valid"
grep -q '^# ' "$OUT/report.md" && echo "report.md present"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-findings.sh" "$OUT/findings.json"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-report.sh" "$OUT/report.md"
```

Compute the delta against the previous run's `findings.json` (the latest two date directories; first run states "first run, no delta"), then append one line to the history ledger, replacing any line for the same date:

```bash
set -eu
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/zenduty"
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${TARGET_DIR}/${RUN_DATE}"
RESOLVED="0"   # fixed count from this run's delta; 0 on the first run
LINE="$(jq -c --arg d "$RUN_DATE" --argjson resolved "$RESOLVED" \
  '{run_date:$d, skill:"audit-zenduty", overall:.score.overall, gate:.score.gate,
    end_to_end:.score.end_to_end, severity_counts:.severity_counts,
    lifecycle_counts:((reduce .findings[].lifecycle as $l ({}; .[$l] = (.[$l] // 0) + 1)) + {resolved:$resolved})}' \
  "$OUT/findings.json")"
TMP="$(mktemp)"
[ -f "${TARGET_DIR}/history.jsonl" ] && grep -v "\"run_date\":\"${RUN_DATE}\"" "${TARGET_DIR}/history.jsonl" > "$TMP" || true
printf '%s\n' "$LINE" >> "$TMP"
mv "$TMP" "${TARGET_DIR}/history.jsonl"
tail -1 "${TARGET_DIR}/history.jsonl" | jq -e '.run_date and (.overall >= 0)' >/dev/null && echo "history.jsonl updated"
```

The report's trend line renders the last five history.jsonl entries, oldest first. After the report is written, close with the run-completion message per the report standard ([report-template.md](../../report-standard/report-template.md#run-completion-message-what-the-skill-says-in-chat-when-the-run-finishes)): the one-line score headline, the top fixes by points_recoverable, the **absolute** report path, the OS-specific open command, and the leak-safe share pointer (Slack brief). Then send the Slack brief exactly as [report-template.md](../../report-standard/report-template.md) specifies: score, severity counts, top finding titles, delta line, topology readiness line, report path — titles only, never evidence values, service names allowed. When invoked by `audit-all`, skip the brief; the orchestrator sends exactly one combined message per run. Keep `./scoutflo-audits/` out of public version control; reports describe your paging setup.


## Metadata Load (v0.1.68+)

This skill reads optional business context metadata to apply intelligent filtering:

```bash
METADATA="${HOME}/.scoutflo/computed_metadata.jsonl"
CONTEXT="${HOME}/.scoutflo/business_context.md"
LOAD_METADATA_MODE="none"

if [ -f "$METADATA" ] && jq -e '.' "$METADATA" >/dev/null 2>&1; then
  LOAD_METADATA_MODE="v0168"
elif [ -f "$CONTEXT" ]; then
  LOAD_METADATA_MODE="v0167"
fi
```

When metadata is available: skip excluded resources, escalate critical services, apply cost sensitivity. See [BUSINESS-CONTEXT-INTEGRATION-v0168.md](../../docs/BUSINESS-CONTEXT-INTEGRATION-v0168.md) for patterns.

## Remediation pointers

No `setup-zenduty` ships yet, so every finding's `remediation` field names the concrete manual fix location. When a setup skill lands, these become anchors without the finding IDs changing:

| Finding area | Fix location today |
| --- | --- |
| Missing or SPOF escalation (ZD-001, ZD-002) | Zenduty > Teams > (team) > Escalation Policies — add a second target, a level, or a repeat |
| Empty or unstaffed on-call, dead schedule (ZD-003, ZD-004) | Team > On-Call Schedules — fill the rotation or re-point the escalation at a staffed schedule |
| Disabled integration on a live path (ZD-005) | Service > Integrations — re-enable the integration or record why it is off |
| Collation off, missing suppress/flapping guard, blanket delay (ZD-010 to ZD-013) | Service > Noise Reduction (collation); Integration > Alert Rules — add suppress with a narrow condition, a Seconds-Since-Last-Similar guard, or a scoped delay |
| entity_id dedup disabled, sources never resolve (ZD-014, ZD-015) | Integration > Alert Rules (stop blanking entity_id); fix the sending tool to emit resolve alert_types (its own audit names it) |
| Open-ended recurring maintenance window (ZD-016) | Team > Maintenance — set a `repeat_until` or remove the recurrence |
| Overlapping/missing global routes (ZD-020) | Account > Global Alert Routing — deduplicate ruleset conditions; add a default route |
| Uncovered critical service or team (ZD-021, ZD-022) | Add a team/service/escalation path for the service; audit the missing team |
| Deprecated API-Integration ingestion (ZD-023) | Migrate the integration to a Generic Integration (`events.zenduty.com`); the API-Integration type stopped working 2025-05-15 |
| Unacked aging, slow MTTA/MTTR per analytics (ZD-030 to ZD-032) | On-call process review; fix the noisy sending tool (its own audit names it) or this account's collation/routing |
| Topology readiness gaps with no finding | `/scoutflo:map-topology` |

## Common Failure Modes

All thresholds and windows named in the checks are example values; tune them to your workloads before treating a miss as a failure.

| Failure | Prevention |
| --- | --- |
| Auth sent as `Bearer <key>` | Zenduty takes `Authorization: Token <key>` — the literal word `Token`, not `Bearer`; a Bearer call 401s |
| Zenduty treated as sunset because of the Xurrent rebrand | Xurrent IMR is a branding change, not a shutdown; the API still runs at `www.zenduty.com/api` |
| Rate limit hit and retried in a tight loop | Limits are tight and per-class (alert GET 1/s, incident GET 3/s); pace by design, back off on 429, mark blocked rather than hammering |
| Incident list fetched with a GET | There is no `GET /api/incidents/` list; use `POST /api/incidents/filter/` (a read-by-filter) |
| Ack state read from a boolean | Ack state is the incident `status` integer (1 triggered, 2 acked, 3 resolved), not a boolean field |
| `collation` confused with a `correlation` field | The dedup field is `collation` (0 off, 1 time-based) with `collation_time`; content-based/AI correlation is not API-readable |
| Content-based correlation absence filed as a fail | The API only exposes time-based-vs-off; report content-based as not API-readable, never a fail |
| Escalation judged by policy count | Judge the shape: one rule, one target, `repeat_policy: 0` is a SPOF regardless of how many policies exist |
| Suppress rule assumed to be tidy noise reduction | An always-true or over-broad suppress condition silently drops real alerts; review each rule's condition |
| Actionability fabricated | MTTA/MTTR come from the analytics API's `mtta_seconds`/`mttr_seconds`; never invent a rate |
| Remaining API-Integration ingestion passed as healthy | That ingestion type stopped working 2025-05-15; flag it as migration debt (ZD-023) |
| Integration config or contact values written into evidence | Captures keep IDs, names, types, states, and timestamps only |
| Toolkit brief webhook conflated with Zenduty notification channels | Two different systems; the Slack brief webhook is the toolkit's own reporting channel |
