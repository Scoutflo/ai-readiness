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
- `./scoutflo-audits/elk/<YYYY-MM-DD>/report.md` per the [report template](../../report-standard/report-template.md)
- One appended line in `./scoutflo-audits/elk/history.jsonl`
- One Slack brief, when `slack.webhook_env` is configured

## Doctor gate

| Integration | toolkit.yaml keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| ELK / Kibana | `elk.kibana_url`, `elk.token_env`, optional `elk.spaces` | the variable named by `token_env` (`KIBANA_API_KEY`) | Elasticsearch API key whose role has Kibana Read on Stack Rules, Rules Settings, and Actions and Connectors (recipe in `/scoutflo:connect`) | read-only |
| Slack (optional) | `slack.webhook_env` | webhook variable | post to one channel | n/a |

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-$HOME/.scoutflo/toolkit.yaml}"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
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
- Rules are space-isolated; coverage denominators name the spaces audited.
  - ❌ `Scored coverage 90: forty alerting rules exist.` (which space? one space's forty rules say nothing about another space)
  - ✅ `Scored coverage 55: the default and observability spaces were audited (elk.spaces); the security space was not and is named as uncovered; within the two audited spaces, six rules are in execution error.`
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
# Sum rule totals across the spaces in elk.spaces (default space shown; add /s/<space> per entry).
TOTAL="$(curl -fsS --max-time 30 -H "Authorization: ApiKey ${KIBANA_API_KEY}" \
  "${KIBANA_URL}/api/alerting/rules/_find?per_page=1&page=1" | jq -r '.total // 0')"
echo "rules_in_default_space=${TOTAL} scored_objects=${TOTAL} (sum across elk.spaces in the real run)"

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

## Phase 1: Service context and spaces

If `./scoutflo-audits/topology.md` exists, load it; its service list is the critical-service list and its names are canonical. Resolve the spaces to audit from `elk.spaces` (default: the `default` space alone) and state them in the report. If topology.md does not exist, infer critical services from rule names and tags, note the inference, and suggest `/scoutflo:map-topology`.

## Phase 2: Read-only inventory

Build the raw picture with the commands in [references/elk-checks.md](references/elk-checks.md) section 4: the Kibana version (drives the version gates), the alerting framework health, and per space the rules (with execution state, actions, flapping, alert_delay, snooze), connectors, and rule types. Judgment starts in Phase 3. A 401/403 on any space is a privilege finding naming the missing Kibana Read feature; a 404 means the URL is Elasticsearch, not Kibana.

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

Commands in section 8. Rule-type coverage — a space using only one rule type may have blind signal classes (`ELK-030`), critical services from topology each covered by at least one rule (`ELK-031`), and the legacy-Watcher-versus-Kibana-Alerting split identified so a Kibana-only view does not silently miss Watcher-covered services (`ELK-032` — needs `elk.es_url` and the `monitor_watcher` privilege; blocked with that reason when absent).

## Phase 7: Coverage matrix and topology readiness

Fill one row per critical service using the per-service mapping in section 10 and the check-result vocabulary (`pass`, `partial`, `fail`, `blocked`, `not-in-scope`):

| Service | Ready | Delivery | Health | Noise | Coverage | Space | Gap |
| --- | --- | --- | --- | --- | --- | --- | --- |

Every cell carries its `passed/total` denominator; the Space column names which Kibana space the rule lives in. Name affected services in findings.

Then render the Scoutflo Topology Readiness section per [topology-readiness.md](../../report-standard/topology-readiness.md): evaluate the six checks per critical service from `./scoutflo-audits/topology-export.json`, read-only. Gaps that map to an existing finding reference its ID; gaps with no finding get a `TOPO-` row pointing at `/scoutflo:map-topology`. Render check names and confidence per the standard: plain-English column headers, confidence as `n/10`, and — whenever any service is below ready — the ticket-ready readiness action plan table. If the export or topology.md is missing, or exists but describes a different target than this audit covers, the section renders the matching state from topology-readiness.md with its one-line unlock; it never guesses and never says a bare "unavailable". Readiness is reported, never folded into the 0-100 score.

**Provider-identity note, verified against the platform's current model:** ELK's identity on the Scoutflo platform is a **logging** provider (`logging.elk`), whose required schema fields describe the log index it correlates against (`indexPattern`, `timeField`, `serviceField`, `serviceValue`, `messageField`), not the alerting rules this audit scores. The schema does carry optional alert-correlation fields (`alertRuleId`, `watcherId`) that a Kibana alerting rule maps onto. So a `SENDS_LOGS_TO` connection to ELK reaches full confidence on the log-correlation fields; the alerting rules this audit checks populate the optional `alertRuleId`, which is a `MONITORED_BY`-style signal layered on top. State plainly which of the two roles a given connection is playing when it stalls at partial, rather than treating a healthy log-source connection as if it were an alerting gap.

## Phase 8: Score, write, brief

Score per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md): each check yields `pass` (1.0), `partial` (0.5), `fail`/`blocked` (0), `not-in-scope` leaves the denominator. Category score is the credit ratio times 100 rounded down; overall is the weight-normalized sum over included categories. Whole categories that could not be assessed (a space that 403'd; ELK-025 on a pre-9.2 version leaves that one check not-in-scope, not the whole category) are excluded, renormalized, and stated. Score conservatively. Assign each category a maturity value (`reactive`, `proactive`, `systematic`).

| Category | Weight | ID range |
| --- | ---: | --- |
| Rule delivery | 30 | ELK-001 to ELK-004 |
| Rule health | 25 | ELK-010 to ELK-013 |
| Alert noise | 25 | ELK-020 to ELK-025 |
| Coverage | 20 | ELK-030 to ELK-032 |

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
# ... write findings.json and report.md per the report standard, then verify:
jq -e '.schema == "scoutflo-findings/v1" and .target == "elk" and (.findings | type == "array")' \
  "$OUT/findings.json" >/dev/null && echo "findings.json valid"
grep -q '^# ' "$OUT/report.md" && echo "report.md present"
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
| Topology readiness gaps with no finding | `/scoutflo:map-topology` |

## Common Failure Modes

All thresholds and windows named in the checks are example values; tune them to your workloads before treating a miss as a failure.

| Failure | Prevention |
| --- | --- |
| `elk.kibana_url` set to the Elasticsearch host | Alerting is a Kibana API; a 404 on `/api/alerting/*` means the URL is Elasticsearch (`:9200`), not Kibana (`:5601`) |
| Only the default space audited, other spaces silently missed | Rules are space-isolated; iterate `elk.spaces` and name every space audited and skipped in the denominators |
| `flapping: null` flagged as flapping-disabled | null means "use the space default", which is ON; only an explicit `enabled:false` or a weak window is a finding |
| Maintenance-window check failed on Kibana 8.x/9.0/9.1 | The public maintenance-window API is 9.2+; version-gate ELK-025 to not-in-scope on older versions |
| Legacy `/api/alerts/*` used | Those routes were removed in 9.0; this audit uses `/api/alerting/rule(s)` only |
| Errored rule counted as coverage | A rule in execution error detects nothing; ELK-010 excludes it from the working set |
| Watcher-covered service reported as unmonitored | Detect the Watcher split (ELK-032); a Kibana-only view does not see Watcher watches |
| Rule count scored as coverage | Count rules that execute cleanly and reach a live connector, per service and per space |
| `onActiveAlert` with no throttle read as fine | It re-notifies every check interval on a stuck alert; the fix is a throttle or onActionGroupChange |
| Connector config or rule params written to evidence | Capture IDs, names, types, execution state, and noise-control fields; never a raw config that could carry a secret |
| ES API key sent as a Bearer token | Kibana takes the encoded key as `Authorization: ApiKey <encoded>`, not `Bearer` |

## v0.1.69 Smart Auto Pipeline Integration

This audit integrates into the unified audit orchestrator via the v0.1.69 smart auto pipeline. When invoked from `/scoutflo:audit-all`, it participates in Phases 0–13 for end-to-end observability scanning with intelligent automation.

### Phase 0: Shared State Initialization

Phase 0 initializes and exports six environment variables to all audits:

- `SCOUTFLO_SESSION_ID`: Unique run identifier for this audit session
- `SCOUTFLO_BUSINESS_CONTEXT`: JSON object with critical services, cost sensitivity, environment, and excluded regions
- `SCOUTFLO_EXEMPTIONS`: JSON array of findings to suppress (finding_id, resource_id, reason, expires)
- `SCOUTFLO_TOPOLOGY`: Current topology.json (K8s label + AWS tag metadata)
- `SCOUTFLO_METADATA`: Computed metadata array (K8s services, AWS resources, cost allocations)
- `SCOUTFLO_SHARED_STATE_DIR`: Directory for findings aggregation and integration state

These variables are readable by every audit script; Phase 0 is always complete before any audit Phase 1 runs.

### Phases 1–12: Audit Execution with Shared State

During `audit-elk` Phases 1–8 (service context → score/write/brief), the skill reads the shared state and:

1. **Exemption filtering**: Load `SCOUTFLO_EXEMPTIONS` and suppress findings that match `finding_id` or `resource_id` fields; move suppressed findings to an appendix and note the suppression reason.
2. **Lifecycle classification**: Consult `SCOUTFLO_SHARED_STATE_DIR/.history/previous-findings.json` (archived from the last run) to classify each finding as `new`, `unchanged`, `regressed`, or `improved`.
3. **Critical service escalation**: Load `SCOUTFLO_BUSINESS_CONTEXT` and escalate any finding affecting a resource in the critical services list to `critical` severity, appending an `escalation_reason`.
4. **Remediation mapping**: Load `./docs/finding-remediation-map.json` and attach `next_safe_action`, `remediation_anchor`, and `remediation_category` fields.
5. **Shared log append**: Instead of writing to `./scoutflo-audits/elk/<YYYY-MM-DD>/findings.json`, append each finding as a JSON line to `SCOUTFLO_FINDINGS_LOG` with metadata (`source_skill: "audit-elk"`, `audit_time`, `session_id`).
6. **History ledger**: Append one entry to `SCOUTFLO_HISTORY_LOG` recording the skill name, completion time, status, and finding count.

**Workflow:** After generating the raw `findings.json` in Phase 8, call the shared helper:

```bash
# After writing findings.json in Phase 8
source "${CLAUDE_PLUGIN_ROOT}/skills/audit-all/lib/integration-helpers.sh"
apply_all_integration_logic "findings.json" "audit-elk"
```

This function applies steps 1–6 above in order, writes the final result back to `findings.json` (for audit-elk's own Phase 8 output and report), and also appends to the shared log. The function guarantees idempotency and collision safety via append-only logs.

**When audit-elk runs standalone or via `/scoutflo:schedule-audits`:** The shared environment variables are not set, so `apply_all_integration_logic` becomes a no-op (returns early if env vars are unset). Exemptions, lifecycle, escalation, and remediation are skipped, and findings go directly to `./scoutflo-audits/elk/<YYYY-MM-DD>/findings.json` as before. History is still recorded.

### Phase 13: Integration Pipeline (after all audits)

Phase 13 runs only when invoked via `/scoutflo:audit-all`. It takes the shared findings log and orchestrates five stages:

1. **Phase 13a—Correlate**: Call `/scoutflo:correlation-engine` to detect overlaps and cascading failures across audits (e.g., a Grafana datasource pointing to a dead Prometheus feed).
2. **Phase 13b—Redact**: Call `/scoutflo:redaction` to scrub any leaked secrets from findings.
3. **Phase 13c—Cost-Analyze**: Call `/scoutflo:cost-analysis` to rank findings by ROI (cost to fix vs. cost of deferring).
4. **Phase 13d—Topology-Guided Setup**: Call `/scoutflo:topology-guided-setup` to sequence fixes according to critical-path dependencies (e.g., fix the API before the load balancer).
5. **Phase 13e—Generate Combined Report**: Consolidate all audits' findings into one `./scoutflo-audits/combined-report-${SCOUTFLO_SESSION_ID}.md` with summary, top findings by severity, and trend line from the history ledger.
6. **Phase 13f—Send Slack Brief**: Post a leak-safe summary (titles only, no evidence) to the configured Slack channel.

When a subprocess (e.g., `/scoutflo:correlation-engine`) is unavailable, Phase 13 logs a warning and continues with a stub result.

### Environment Variable Safety & Leakage

- Environment variables are visible to `ps` and shell history. The helper functions treat only the top-level findings count and IDs as safe to log; finding titles and evidence values are never echoed.
- When running standalone, shared variables are simply unset; audits degrade gracefully to Phase 1–8 only.
- Phase 13 is always skipped unless explicitly invoked from `/scoutflo:audit-all` (checked via `if [ -n "$SCOUTFLO_SESSION_ID" ]` in the Phase 13 entry point).

### Exemption File Format

Place an optional `./scoutflo-audits/exemptions.yaml` at the project root:

```yaml
exemptions:
  - finding_id: ELK-020
    resource_id: null
    reason: "Flapping detection disabled on log-ingest rules per SRE policy: noisy environment, team accepts transient alerts"
    expires: "2026-12-31"
  - finding_id: null
    resource_id: "oncall-slack-connector"
    reason: "Connector replacement in progress under [JIRA-1234]; target date 2026-09-15"
    expires: "2026-09-30"
```

- Entries with `finding_id` and/or `resource_id` + `reason` + `expires` all set and unexpired suppress their findings.
- Malformed or expired entries are reported as findings (never silently dropped).
- When no `exemptions.yaml` exists, all findings are reported.

### Topology Readiness (v0.1.68+)

When Phase 1 loads `./scoutflo-audits/topology.md` and Phase 7 evaluates the six readiness checks from `./scoutflo-audits/topology-export.json`, gaps are compared against this audit's findings. A gap with no matching finding gets a `TOPO-XXX` row pointing at `/scoutflo:map-topology`. See [topology-readiness.md](../../report-standard/topology-readiness.md) for the readiness schema and confidence scoring.

### When to Use Standalone vs. via `audit-all`

| Scenario | Invocation | Phase 0 | Phases 1–12 | Phase 13 | Exemptions | Lifecycle |
| --- | --- | --- | --- | --- | --- | --- |
| Quick audit of one Kibana instance | `/scoutflo:audit-elk` | no | yes | no | skipped | skipped |
| First-time audit with context | `/scoutflo:audit-elk` + manual review of findings | no | yes | no | apply manually | skipped |
| Scheduled audit (daily/weekly) | `/scoutflo:schedule-audits elk` | no | yes | no | skipped | skipped |
| Full multi-system health scan | `/scoutflo:audit-all` | yes | yes | yes | auto | auto |
| Audit run with exemptions already in place | `/scoutflo:audit-all` | yes | yes | yes | auto | auto |
