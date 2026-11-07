# audit-datadog: Check Catalog and Commands

Runnable, read-only checks for every surface the [audit-datadog](../SKILL.md) workflow covers. Each section lists the catalog IDs it serves, the commands, the expected healthy output, and what the common failure shapes mean. Evidence for a finding is the command plus its observed output, trimmed with truncation marked.

## 1. Conventions

- Every call sends the key PAIR: `DD-API-KEY: <api key>` and `DD-APPLICATION-KEY: <app key>`, from the variables named by `datadog.api_key_env` and `datadog.app_key_env`. Presence-check both; never echo, log, or write either value.
- The API host is `api.<site>` from `datadog.site` (e.g. `api.datadoghq.com`, `api.us5.datadoghq.com`, `api.datadoghq.eu`). Every block declares `DD_HOST` at the top. A valid key on the wrong site returns 403, so a 403 is a site check before it is a scope check.
- Every command here is read-only: GET on monitors, downtimes, SLOs, events, usage, integrations, and dashboards. There are no read-by-effect POSTs in this skill. The forbidden-command list is section 13.
- Monitor CRUD/list is **v1** (`/api/v1/monitor`). Downtimes are **v2 only** (`/api/v2/downtime`); every v1 downtime endpoint is deprecated, including the GETs, so this skill never reads `/api/v1/downtime` or `/api/v1/monitor/{id}/downtimes`.
- `dd_read` is the fixed bounded read/projection boundary; raw bodies and errors never reach disk or stdout. Where the status code is the evidence, `-f` is dropped and `-w '%{http_code}'` captures it; those blocks say so.
- Rate limits are per-endpoint and returned in `X-RateLimit-*` headers; on 429, sleep for the `X-RateLimit-Reset` seconds once and retry, then record `blocked` on a second 429.
- Thresholds and windows are examples; tune to your workloads. Named defaults live in section 12.
- `POST /api/v2/events/search` (DD-006) is a query endpoint, not a mutation: classify it by effect, not verb, exactly as [skill-authoring-conventions.md](../../../docs/skill-authoring-conventions.md) directs. It is the only POST this skill sends; it searches events and creates nothing.
- DD-038 (Synthetics) needs an app key scoped `synthetics_read` in addition to the scopes in the doctor table; a 403 there is a scope gap on that one check, not the whole audit.

## 2. Check catalog

One permanent ID per check. IDs never change or get reused; retired checks keep their number.

| ID | Category | Check | Typical fail severity |
| --- | --- | --- | --- |
| DD-001 | Monitor delivery | Every monitor names at least one notification target (`@handle` in the message) | critical |
| DD-002 | Monitor delivery | No monitor targets a dead `@handle` (integration, channel, or webhook that no longer resolves) | high |
| DD-003 | Monitor delivery | No monitor left in `draft` status (drafts never notify) | high |
| DD-004 | Monitor delivery | Notification rules and config policies reviewed where the org uses them | medium |
| DD-005 | Monitor delivery | Critical-service monitors carry a `priority` (P1-P5) so paging can be tiered, not flat | medium |
| DD-006 | Monitor delivery | Reconcile observed alert events and state changes; missing history is unassessed delivery | high |
| DD-007 | Monitor delivery | No monitor's only notification target is a placeholder/template artifact (`@your-team-handle`, `__..._placeholder__` query fragment, literal `$service`/`$env` tag) | high |
| DD-008 | Monitor delivery | No monitor pages the whole org via `@all`/`@everyone` without a stated reason | medium |
| DD-010 | Monitor noise | Recovery thresholds set where a monitor has a warning/critical threshold (`critical_recovery`) | medium |
| DD-011 | Monitor noise | No-data handling deliberate (`notify_no_data`, `no_data_timeframe`, `on_missing_data`) | medium |
| DD-012 | Monitor noise | Renotification bounded, not unlimited (`renotify_interval`, `renotify_occurrences`) | low |
| DD-013 | Monitor noise | Evaluation delay / new-group delay set where the query needs late data | low |
| DD-014 | Monitor noise | Auto-resolve (`timeout_h`) deliberate per monitor type | low |
| DD-039 | Monitor noise | `require_full_window` is deliberate for the metric's cadence — not `false` on a dense metric (partial-window evaluation flaps at the window edge) nor `true` on a sparse/low-frequency metric (a window never completes, so evaluations are skipped → silent gaps) | low |
| DD-015 | Monitor noise | Datadog's own `quality_issues[]` reviewed and reconciled with this audit | info |
| DD-016 | Monitor noise | Receiver concentration: monitors share a handle and carry noise-control risks | high |
| DD-017 | Monitor noise | Review prolonged current `Alert` state with notification/history evidence | medium |
| DD-018 | Monitor noise | Ratio queries (`errors/hits`-shaped) carry a composite volume floor, not just a bare percentage threshold | medium |
| DD-019 | Monitor noise | No evidenced tautological threshold: require a proven lower bound for the entire expression and its exact query digest. Strict `> 0` can recover at zero; missing domain evidence is blocked. | medium |
| DD-020 | Muting and downtime | No monitor muted indefinitely (`options.silenced` with no end) | high |
| DD-021 | Muting and downtime | No always-on / broad-scope downtime masking real alerts (`/api/v2/downtime`) | high |
| DD-022 | Muting and downtime | Downtimes scoped tightly, not muting whole environments open-ended | medium |
| DD-023 | Muting and downtime | No active, open-ended downtime whose age has outlived its own stated temporary intent | high |
| DD-030 | Coverage and staleness | No stale monitors: `last_triggered_ts` recent or a recorded reason | low |
| DD-031 | Coverage and staleness | Composite monitors resolve all constituent monitor IDs | medium |
| DD-032 | Coverage and staleness | SLOs have an error-budget or burn-rate monitor attached | high |
| DD-033 | Coverage and staleness | Critical services from topology have monitor coverage | high |
| DD-034 | Coverage and staleness | Monitor tag hygiene: service/team tags present for routing | low |
| DD-035 | Coverage and staleness | A monitor's tags agree with its query's own scope terms for the same key (env, service, cluster, …) | medium |
| DD-036 | Coverage and staleness | Review overlapping published queries against intended tiers, windows and receivers; only unintended duplication is a defect | low |
| DD-037 | Coverage and staleness | Review older No Data snapshots with unavailable transition metadata; evaluation/ingestion evidence determines whether monitoring is broken | medium |
| DD-038 | Coverage and staleness | Required Synthetic coverage is active; a paused test and stale monitor state require intent review, not a claim about actual paging | high |

Cost & Resource (non-scored, `DDOPT-NNN`, `points_recoverable: 0`): estimated/historical cost trend, top custom-metric contributors, and unused dashboards. Sourced only from Datadog's own usage endpoints; see section 11.

## 3. Target profile

What 100/100 means per category; the checks above are this profile made executable.

- **Monitor delivery**: every monitor routes to a live target, no drafts masquerading as coverage, dead `@handles` caught, no target is a placeholder never filled in, no monitor pages the whole org without reason, measured alert-event volume backs up the configuration, and org-level notification rules/config policies reviewed where used.
- **Monitor noise**: recovery thresholds, no-data handling, bounded renotification, evaluation delay, and auto-resolve all set deliberately per monitor, every ratio query carries a volume floor, no threshold is impossible or tautological, and Datadog's own quality signals reconciled with this audit's findings.
- **Muting and downtime**: no indefinite mutes, no open-ended broad-scope downtimes masking live alerts, no downtime has outlived its own stated temporary intent, downtimes scoped to what they mean to suppress.
- **Coverage and staleness**: current evidence supports the expected signals; drafts, unresolved No Data and unintended duplication do not receive coverage credit from metadata alone. Intended tiers/windows are retained, composite monitors are intact, every required SLO has alerting, tags agree with evaluated scope, required Synthetics run, and critical services have verified coverage.

## 4. Inventory (all categories)

Capture raw state once per run; later sections re-fetch specific objects before filing findings.

```bash
set -eu
sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/inventory.sh"
```

Expected: one JSON file per surface. A 403 on any endpoint is an auth/scope finding for the checks that need it (record which scope: monitor reads need `monitors_read`, downtime reads `monitors_downtime`, SLO reads `slos_read`), never a clean pass.

## 5. Monitor delivery (DD-001 to DD-008)

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/datadog-context.sh"
dd_require monitors.json

# DD-001: monitors whose message contains no @handle (notify nobody).
# Join to the service: tag so the blast radius is "which service is blind", not a count.
jq '[.[] | select(.handles_complete==true) | select((.message // "") | test("@") | not)
    | {id, name, service: [((.tags // [])[] | select(startswith("service:")))]}]' "${RAW_DIR}/monitors.json"
# Expect: []. Blast radius — compute it, do not assert "pages no one": a monitor with no
# @target fires into the events stream only. Join the no-@handle set to each monitor's
# service: tag and the topology critical-service list: "the only p99-latency monitor on
# service:payments (critical) names no @handle, so a payments latency breach fires silently
# with MTTA = never". The who/what is the service-tag join. Correlation: this set is one of
# the suppressors the DD-033 effective-coverage flagship subtracts, and chains to DD-032
# when the same service owns an SLO. Rank by whether the unrouted monitor is a critical
# service's ONLY monitor (blind spot) vs a redundant one (low).

# DD-003: draft monitors (drafts never notify, regardless of message).
jq '[.[] | select(.draft_status == "draft")
    | {id, name, service: [((.tags // [])[] | select(startswith("service:")))]}]' "${RAW_DIR}/monitors.json"
# Expect: []. Severity is set by the join, NOT by the draft flag: a draft that is the SOLE
# monitor for a critical service is critical (invisible coverage the green UI hides); a draft
# duplicating a live published monitor for the same service is low. Feeds the DD-033 flagship.

# DD-001 partial / DD-002 input: extract distinct @handles to check liveness
jq -r '[.[] | (.message // "") | scan("@[A-Za-z0-9._-]+")] | flatten | unique | .[]' "${RAW_DIR}/monitors.json"
```

**DD-002 (dead @-handle liveness).** For each distinct handle class, verify it still resolves. Use current supported destination reads; a vendor quality flag establishes a defect, while the absence of that flag establishes nothing:

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/datadog-context.sh"
dd_require monitors.json monitor-quality.json
# Positive failure evidence is not a complete resolver: no flag means UNKNOWN.
jq --slurpfile q "$RAW_DIR/monitor-quality.json" '
  ($q[0] | map(select(.quality_issues | index("broken_at_handle")) | .id)) as $bad
  | [.[] | {id,notification_handles,destination_state:
      (if (.id as $id | $bad | index($id)) then "known-broken-handle" else "unverified" end)}]' "$RAW_DIR/monitors.json"
# Optional named webhook existence read; use the exact independently selected handle.
# This proves configuration exists, never network delivery or a person receiving a page.
if [ -n "${SCOUTFLO_DATADOG_WEBHOOK_NAME:-}" ]; then
  case "$SCOUTFLO_DATADOG_WEBHOOK_NAME" in *[!a-zA-Z0-9_.-]*) echo 'Unsupported webhook name; use an attended read.' >&2; exit 2;; esac
  dd_read webhook "/api/v1/integration/webhooks/configuration/webhooks/$SCOUTFLO_DATADOG_WEBHOOK_NAME"
fi
```

Judgment: not every `@handle` is an integration (some are `@user@email`). Resolve supported integration classes independently. VictorOps/Splunk On-Call and plain email handles stay unverified until their own destination evidence exists; never derive a protected routing key from the handle spelling.

**DD-002 blast radius.** Join known-broken source monitors to service tags and preserve every other destination as unverified until positively resolved. Absence from the vendor broken-handle list is not evidence of a live destination. The shared DD-033 recipe reports the unresolved subset instead of labeling all remaining monitors live.

```bash
set -eu
# DD-002 and DD-033 share the same conservative source eligibility join.
sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/coverage.sh"
```

**DD-004 — compute routing fall-through, not just "review the rules".** Pull the org's monitor notification rules and config policies; when the org routes by `service:`/`team:` tag rules, a monitor matching NO rule falls through to the default route or nowhere and depends entirely on its inline `@handles`.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/datadog-context.sh"
dd_require monitors.json
dd_capture notification-rules /api/v2/monitor/notification_rule notification-rules.json
dd_capture policies /api/v2/monitor/policy monitor-policies.json
jq -e 'all(.filter_state=="observed")' "$RAW_DIR/notification-rules.json" >/dev/null || { echo 'DD-004 blocked: unsupported rule-filter semantics.'; exit 2; }
# Fall-through set: monitors whose tags satisfy NO rule's filter_tags. When rules exist,
# every returned monitor routes only by its inline @handles (or nowhere).
jq --slurpfile rules "${RAW_DIR}/notification-rules.json" '
  ($rules[0] // []) as $R
  | if ($R | length) == 0 then [] else
    [.[] | . as $m | (.tags // []) as $mt
     | select([ $R[] | (.filter_tags // []) | select(length > 0) | all(. as $t | $mt | index($t)) ] | any | not)
     | {id, name, tags: $mt}] end' "${RAW_DIR}/monitors.json"
```
Blast radius: "the org routes by `team:` rules but N monitors match no rule and depend entirely on inline handles" — those N are exactly the DD-034 untagged monitors made consequential (untagged → matches no tag filter → fall-through), and they chain into DD-016 when they still land on one shared handle. Absence of any rule is a posture note, not a fail: with no org rules, inline `@handles` are the whole routing model and DD-001/DD-002 already cover them.

### 5.1 Paging-tier hygiene (DD-005)

> **Live-verified (read-only).** Confirmed against a live Datadog org (read-only key pair): the monitor `priority` field is present and nullable exactly as captured in section 4 — `priority` was observed as `null` on real monitors, which is precisely the untiered case DD-005 flags. Mechanism proven on a real tenant.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/datadog-context.sh"
dd_require monitors.json

# DD-005: critical-service monitors with priority == null (paging cannot be tiered).
# priority is captured in section 4; no extra call. Carry the handle to show the flat-urgency
# blast radius on a shared route.
jq '[.[] | select(.priority == null)
    | {id, name, service: [((.tags // [])[] | select(startswith("service:")))],
       handles: [((.message // "") | scan("@[A-Za-z0-9._-]+"))]}]' "${RAW_DIR}/monitors.json"
```
Blast radius: when critical-service monitors leave `priority` null, every monitor on a given receiver pages at the same urgency — "all 47 monitors on @pagerduty-oncall are un-prioritized, so a P5 disk-space warning and a payments-down page are indistinguishable to the responder". Compute it by joining `priority == null` to the `service:` tag/criticality and the shared handle. Judgment: DD-005 is only a finding on *critical-service* monitors (topology.md) or monitors sharing a paging handle with them; a lone P-less low-severity monitor is a note. Correlation: amplifies DD-016 (without priority the noisy and the real monitors on one handle are indistinguishable) and feeds DD-004 tiered routing. Remediation is inline (no `setup-datadog` ships): Monitor edit — set a priority (P1-P5) on critical-service monitors so the receiver can tier.

### 5.2 Measured alert-event volume, placeholder artifacts, and over-broad targets (DD-006 to DD-008)

> **Live-verified (read-only).** All three ran against a real Datadog org. DD-006's `sources=alert`/`source:alert` event queries both returned 200 with a real (empty, on that run) result set, cross-checked against zero monitor state transitions in the same window — proving the check does not false-positive on a genuinely quiet period. DD-007 matched real monitors carrying a literal `@your-team-handle`-shaped placeholder handle, a literal `$service`/`$env` tag value, and a query containing a `__..._placeholder__` fragment — on the SAME live org, at least one of these placeholder monitors also carried a legitimate-looking `@slack-`/`@pagerduty-` handle elsewhere in its message, confirming DD-001's bare `test("@")` cannot tell the two apart. DD-008 matched real monitors whose message contained a literal `@all`.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/datadog-context.sh"
dd_require alert-events.json monitors.json
EVT_WINDOW_DAYS="30"   # fixed capture window; change the owning capture and recapture before relabeling

# DD-006: total measured alert-event volume in the window (from the section-4 capture; NO
# extra call here). An empty array is a real zero (confirmed live — sources=alert 200s with
# events:[] on a genuinely quiet org), not a failure signal on its own.
TOTAL_EVENTS="$(jq 'length' "${RAW_DIR}/alert-events.json")"
echo "alert-sourced events in the last ${EVT_WINDOW_DAYS}d: ${TOTAL_EVENTS}"

# Noisiest-monitor ranking (feeds DD-016) — grouped straight from the section-4 capture.
jq '[.[] | select(.monitor_id != null)] | group_by(.monitor_id)
    | map({monitor_id: .[0].monitor_id, event_count: length}) | sort_by(-.event_count)' \
  "${RAW_DIR}/alert-events.json"

# DD-006 reconciliation candidates: a state timestamp does not identify its transition
# type or prove a notification was required. A capped history cannot prove absence.
# NOTE: `fromdateiso8601` REQUIRES the literal "...SSZ" shape and rejects Datadog's real
# "+00:00" offset suffix outright (confirmed live: "does not match format %Y-%m-%dT%H:%M:%SZ"
# on a real timestamp) — every timestamp read in this skill must go through the same
# sub()-normalize-to-Z step before fromdateiso8601, or the comparison silently errors/aborts
# under `set -eu`. Datadog's own timestamps are always UTC, so "+00:00" -> "Z" is exact, not
# an approximation; fractional seconds (seen on `created`) are stripped first.
CUTOFF_EPOCH="$(( $(date -u +%s) - EVT_WINDOW_DAYS * 24 * 3600 ))"
jq --argjson cutoff "$CUTOFF_EPOCH" '
  def to_epoch: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601;
  [.[] | select(.overall_state_modified != null)
   | select((.overall_state_modified | to_epoch) >= $cutoff)
   | {id, overall_state, overall_state_modified}]' "${RAW_DIR}/monitors.json"
# If TOTAL_EVENTS==0 and this list is non-empty, record a blocked reconciliation
# row until complete per-monitor history proves an alerting transition and the applicable
# notification policy required an event. Neither recovery changes nor group changes prove
# a missing page. Empty observations remain unassessed delivery, never a pass or failure.

```

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/datadog-context.sh"
dd_require monitors.json

# DD-007a: placeholder-shaped @handle anywhere in the message. PLACEHOLDER_HANDLES is the
# example set; extend it to whatever generic template your org's monitor packs ship with.
jq -r '[.[] | (.message // "") | scan("@[A-Za-z0-9._-]+")] | flatten | unique
    | map(select(test("(?i)^@(your|example|replace-?me|team-?name)[-_a-z0-9]*handle$|^@handle$")))
    | .[]' "${RAW_DIR}/monitors.json"
jq '[.[] | select(.handles_complete==true) | select((.message // "") | test("(?i)@(your|example|replace-?me|team-?name)[-_a-z0-9]*handle|@handle\\b"))
    | {id, name,
       only_handle_is_placeholder: (([(.message // "") | scan("@[A-Za-z0-9._-]+")] | unique
         | map(select(test("(?i)^@(your|example|replace-?me|team-?name)[-_a-z0-9]*handle$|^@handle$") | not)) | length) == 0),
       service: [((.tags // [])[] | select(startswith("service:")))]}]' "${RAW_DIR}/monitors.json"
# Severity: `only_handle_is_placeholder == true` is the DD-001 blind spot — this monitor
# passes DD-001's bare "@" test and delivers nothing; critical on a critical-service monitor,
# high otherwise. `only_handle_is_placeholder == false` (a placeholder alongside a real
# handle) is still a finding — Datadog will try to notify the placeholder too — but the real
# handle keeps delivery alive, so it is a hygiene fix, not a blind spot: medium.

# DD-007b: a query containing an un-filled template fragment (the metric name was never
# substituted, so the query can never match real data). PLACEHOLDER_QUERY_RE is the example
# pattern most monitor-pack templates use; adjust to your own template convention.
jq '[.[] | select(.query_state=="observed") | select((.query // "") | test("__[A-Za-z0-9_]*placeholder[A-Za-z0-9_]*__"))
    | {id, name, query}]' "${RAW_DIR}/monitors.json"

# DD-007c: a tag value that is a literal unsubstituted template variable, not a real value.
# `any(test(...))` in the select — NOT a bare `.tags[] | test(...)` — is required: the latter
# emits one row PER MATCHING TAG (a monitor with two "$"-tags prints twice, confirmed live),
# which double-counts the finding; `any(...)` collapses back to one row per monitor.
jq '[.[] | select((.tags // []) | any(test("^\\$")))
    | {id, name, template_tags: [((.tags // [])[] | select(test("^\\$")))]}]' "${RAW_DIR}/monitors.json"
# Blast radius for DD-007b/c: a literal "$service"/"$env" tag or an un-filled query breaks
# every routing/topology join that key feeds (DD-034, DD-035, the coverage matrix) — the
# monitor LOOKS tagged and configured, but the value it carries is not a real one.

# DD-008: over-broad @all/@everyone.
jq '[.[] | select(.handles_complete==true) | select((.message // "") | test("@all\\b|@everyone\\b"))
    | {id, name, service: [((.tags // [])[] | select(startswith("service:")))]}]' "${RAW_DIR}/monitors.json"
# Judgment: a deliberate incident-bridge or SEV1-only monitor naming @all is a documented
# choice, not a defect; the finding is the ABSENCE of any narrower handle alongside @all on a
# routine (non-incident-tier) monitor, which pages the whole org for something ordinary.
```
Expect (all three): the listed monitors are real config, joined to their `service:` tag exactly like the other Phase-3 checks — never a bare count. Remediation is inline (no `setup-datadog` ships): DD-006 → request a separately approved controlled breach and confirm source event, destination delivery and recipient receipt; DD-007 → replace the placeholder handle/query fragment/tag value with the real one; DD-008 → replace `@all` with the owning team's handle, or record why the breadth is deliberate.

## 6. Monitor noise (DD-010 to DD-019)

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/datadog-context.sh"
dd_require monitor-quality.json monitors.json

# DD-010: monitors with a critical threshold but no critical_recovery (flap risk).
# Carry the notification handle so the blast radius is "where the flap noise lands", not "can flap".
jq '[.[] | select(.options.thresholds.critical != null and (.options.thresholds.critical_recovery == null))
    | {id, name, critical: .options.thresholds.critical,
       handles: [((.message // "") | scan("@[A-Za-z0-9._-]+"))]}]' "${RAW_DIR}/monitors.json"
# Judgment: recovery thresholds matter most on metric monitors that hug their threshold;
# a monitor that recovers on the same value it fires on will flap. Some monitor types
# have no recovery concept (event/composite) — exclude those, do not fail them.
# Blast radius — compute it, do not assert "can flap": join the no-recovery set to each
# monitor's @handle. The finding is "these N flap-prone monitors route to @pagerduty-oncall,
# the same handle carrying the real payments page" — the noise lands on the paging path.
# Per-monitor flap COUNT is an acknowledged ceiling (it lives in state history this audit
# samples but does not exhaustively reconstruct), so do NOT invent a count: corroborate with
# Datadog's own high-alert-volume quality signal from monitor-quality.json (DD-015 reads the
# same array). The `quality_issues[]` member strings are confirmed live against a real org:
# `alerted_too_long` (stuck / alerting too long), `broken_at_handle` / `missing_at_handle`
# (dead or missing recipient), and `muted_duration_over_sixty_days`. Use `alerted_too_long` /
# `broken_at_handle` to corroborate a concentrated handle; the handle-join blast radius above
# stands on its own regardless. Correlation: chains into
# DD-016 (receiver noise concentration) and DD-012 (renotify) — the alert-fatigue cascade.

# DD-011: no-data handling. Emit the table, then ISOLATE the dangerous case — do not delegate
# the judgment to the reader.
jq '[.[] | {id, name, type,
    notify_no_data: .options.notify_no_data,
    no_data_timeframe: .options.no_data_timeframe, on_missing_data: .options.on_missing_data,
    overall_state,
    service: [((.tags // [])[] | select(startswith("service:")))]}]' \
  "${RAW_DIR}/monitors.json"
# DD-011: only explicit missing-data requirements establish a defect. Read the
# operator/business-context declaration used by DD-033; monitor names/types are
# not a declaration. Without it, report the fields above and mark intent blocked.
# Persistent No Data is a separate observed state needing metric/runtime evidence;
# it does not prove a notification was required or that a person was not paged.

# DD-012: unbounded renotification (a POSITIVE renotify_interval with no occurrence cap = forever)
# renotify_interval=0 (or absent) means renotification is DISABLED in Datadog, NOT unbounded — so
# `// 0` the field and require > 0 before flagging, else every never-renotifying monitor is a
# false positive (live: 11 monitors carry renotify_interval=0 and must not be flagged as uncapped).
jq '[.[] | select((.options.renotify_interval // 0) > 0 and (.options.renotify_occurrences == null))
    | {id, name, renotify_interval: .options.renotify_interval}]' "${RAW_DIR}/monitors.json"

# DD-014: auto-resolve posture
jq '[.[] | {id, name, timeout_h: .options.timeout_h}]' "${RAW_DIR}/monitors.json"

# DD-039: expose full-window configuration as cadence-review candidates. An explicit
# false alone does not prove flapping; sparse metrics can require it. Missing/default
# behavior needs the actual monitor type/version, not an assumed universal default.
jq '[.[] | select(.type == "metric alert")
    | {id,name,require_full_window:.options.require_full_window,result:"blocked",reason:"confirm metric reporting cadence and evaluation behavior before judging full-window posture"}]' "${RAW_DIR}/monitors.json"
# Confirm dense/sparse cadence and late-arrival behavior; then judge the supported
# configuration. A low severity applies to an evidenced mismatch, not every false flag.

# DD-015: Datadog's OWN quality issues — free corroboration, report ours alongside theirs
jq '[.[] | select((.quality_issues | length) > 0) | {id, name, quality_issues}]' \
  "${RAW_DIR}/monitor-quality.json"
# The vendor flags high alert volume, muted>60d, missing recipients, missing eval delay,
# misconfigured channels, composite-missing-constituents, stuck-in-alert. Where their
# flag and this audit's finding disagree about a monitor, name the disagreement (info).
```

### 6.1 Receiver noise concentration and stuck-in-alert (DD-016, DD-017)

> **Live-verified (read-only).** Run against a live Datadog org: monitors carry `overall_state` (observed both `OK` and real `Alert` states) and `last_triggered`/notification handles, so current state and DD-016 configuration concentration are grounded fields; these observations do not prove paging behavior. The `quality_issues[]` corroboration member strings are now **confirmed live** too — a real org carried them on 36/38 monitors: `broken_at_handle`, `missing_at_handle`, `alerted_too_long` (the real "stuck/alerting-too-long" member — not `stuck`), and `muted_duration_over_sixty_days`. DD-016/DD-017 computations establish concentration and current-state candidates; scoring additionally requires the catalog's impact evidence. Vendor members corroborate only their stated quality condition.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/datadog-context.sh"
dd_require monitor-quality.json monitors.json

# DD-016: build a handle -> [monitor ids] concentration map from the @handles in the
# captured messages (NO extra API call, NO enum strings — this is the load-bearing part).
jq '[.[] | . as $m | ((.message // "") | scan("@[A-Za-z0-9._-]+")) | {handle: ., id: $m.id, name: $m.name}]
    | group_by(.handle)
    | map({handle: .[0].handle, monitor_count: length, monitor_ids: [.[].id]})
    | sort_by(-.monitor_count)' "${RAW_DIR}/monitors.json"
# The top rows are configuration concentration points. They do not measure notifications. Intersect each concentrated handle's monitor set with the "noisy"
# set to compute the blast radius. Build the noisy set from THIS audit's own grounded findings
# first — the DD-010 no-recovery (flap-prone) set and the DD-012 unbounded-renotify set — so
# the finding stands without any unverified vendor string:
#   "handle @pagerduty-oncall carries 47 monitors, 12 of them DD-010 flap-prone, sharing the
#    route with 3 critical-service monitors; measured notification impact remains unverified."
# Corroborate with Datadog's own quality flags (member strings CONFIRMED live against a real org
# via `GET /api/v1/monitor/search?per_page=1000 | jq '[.monitors[]?.quality_issues[]?]|unique'`):
jq '[.[] | select((.quality_issues | tostring) | test("broken_at_handle|missing_at_handle|alerted_too_long"))
    | {id, name, quality_issues}]' "${RAW_DIR}/monitor-quality.json"
# `broken_at_handle`/`missing_at_handle` corroborate a dead/missing recipient on a concentrated
# handle; `alerted_too_long` corroborates prolonged state, not notification volume. The
# DD-010/DD-012 intersection above remains the load-bearing finding; this is corroboration.

# DD-017: current Alert state and last state-change metadata are review candidates.
# Re-notification can continue while Alert; do not infer inability to page from state.
jq '[.[] | select(.overall_state == "Alert")
    | {id, name, overall_state, last_state_transition_timestamp: .last_triggered_ts,
       service: [((.tags // [])[] | select(startswith("service:")))]}]' "${RAW_DIR}/monitors.json"
# Blast radius: join the current Alert set to service: tag/criticality — "the service:checkout
# error-rate monitor currently reports Alert and its last state transition is old".
# State-transition metadata does not prove continuous alert duration, repeat page counts
# or inability to notify again. Correlation: DD-011 is the sibling No Data state. Corroborate with the vendor's stuck/alerting-too-long flag (the real
# member string is `alerted_too_long`, CONFIRMED live — not `stuck`):
jq '[.[] | select((.quality_issues | tostring) | test("alerted_too_long")) | {id, name, quality_issues}]' \
  "${RAW_DIR}/monitor-quality.json"
# `alerted_too_long` is Datadog's own signal for a monitor stuck alerting; it corroborated 4 of
# the live overall_state=="Alert" monitors. The overall_state filter establishes current state only; assess a defect only with the required history and operating intent.
```

DD-016 reports configuration concentration candidates: name the handle, monitor count and specific noise-control defects. It cannot establish actual page volume or that a useful page was buried. Confirm measured impact in the alert-fatigue history lane. DD-017 reports current Alert state and the observed last state-transition timestamp; continuous duration and inability to re-page require history and notification-policy evidence. Remediation is inline (no `setup-datadog` ships): DD-016 → split the noisy monitors onto a separate ticket/low-urgency route or tune them (recovery threshold, renotify cap) so the real page is not buried; DD-017 → reconcile state history, query results and operating intent; repair the query or thresholds only after an evidenced recovery defect. Missing evidence stays blocked.

### 6.2 Ratio volume floor and impossible thresholds (DD-018, DD-019)

> **Live-verified (read-only).** Both matched the SAME real query on a live org: an `errors.as_count() / hits.as_count() > 0.1` ratio with no volume floor (DD-018), on a monitor that also, separately, is one of a set of duplicate monitors on the same base metric (DD-036) — and a sibling carried low thresholds and current Alert state. Those historical observations do not prove a tautology; DD-019 now requires explicit lower-bound evidence for the entire expression.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/datadog-context.sh"
dd_require monitors.json

# Omitted queries are blocked for query-dependent predicates, not a clean pass.
jq '[.[] | select(.query_state!="observed") | {id,result:"blocked",reason:"query grammar omitted at capture"}]' "$RAW_DIR/monitors.json"
# DD-018: a ratio of two .as_count() terms with a bare threshold and no composite AND
# clause enforcing a minimum denominator. The character class between the two as_count()
# calls must be permissive (a Datadog scope segment carries `{`, `}`, `*`, digits — a
# narrower class silently never matches a real scoped query, confirmed live).
jq '[.[] | select(.query_state=="observed") | select((.query // "") | test("as_count\\(\\)\\s*/\\s*.*as_count\\(\\)"))
    | select((.query // "") | test("(?i)\\band\\b.*(count|hits|requests|total)\\s*(>=|>)\\s*[0-9]") | not)
    | {id, name, query, service: [((.tags // [])[] | select(startswith("service:")))]}]' \
  "${RAW_DIR}/monitors.json"
# Blast radius: name the threshold and the missing floor, e.g. "the checkout error-rate
# monitor pages at 10% with no minimum hits — 1 error in 9 hits crosses it exactly as
# confidently as 1,000 errors in 9,000, but the two mean very different things at 3am."

# DD-019: only an independently evidenced lower bound for the FULL evaluated expression
# can establish a tautology. >0 can recover at zero; metric-name hints are not proof.
# Optional SCOUTFLO_DATADOG_NONNEGATIVE_EVIDENCE names a local JSON array of
# {monitor_id, query_sha256, lower_bound:0, declared_by, evidence_ref}. The safe captured
# query digest must match. Missing/stale proof returns blocked, never a finding.
sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/thresholds.sh"

```
Expect: DD-018 lists ratio queries with no accompanying volume guard, joined to the affected service. DD-019 separates evidenced tautologies from blocked lower-bound claims. `>0` is not tautological on a nonnegative domain. Current Alert state alone cannot supply that proof. Remediation is inline (no `setup-datadog` ships): DD-018 → add a composite `AND` clause on a minimum denominator; DD-019 → set a threshold the metric can actually recover past — check DD-017 for any monitor this also unblocks.

## 7. Muting and downtime (DD-020 to DD-023)

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/datadog-context.sh"
dd_require downtimes.json monitors.json

# DD-020: indefinitely muted monitors. options.silenced is a map of scope->until-timestamp;
# a value of 0 or null means muted with no end. Read the KEYS (the muted scope) and the
# service: tag, not just the fact of a mute.
jq '[.[] | select(.options.silenced_state != "observed") | {id,result:"blocked",reason:"mute scope or timestamp omitted/unsupported"}]' "${RAW_DIR}/monitors.json"
jq '[.[] | select(.options.silenced_state=="observed") | select((.options.silenced // {}) | to_entries | any(.value == null or .value == 0))
    | {id, name,
       muted_scopes: [((.options.silenced // {}) | to_entries[] | select(.value == null or .value == 0) | .key)],
       service: [((.tags // [])[] | select(startswith("service:")))],
       silenced: .options.silenced}]' "${RAW_DIR}/monitors.json"
# Expect: []. Blast radius — name WHAT is muted, not just "is muted": a muted_scope of "*"
# on a service:payments monitor means payments alerting is FULLY suppressed with no end; a
# single muted host (e.g. "host:web-3") is a partial gap. The muted-scope key alongside the
# service tag is the blast radius. Corroborate since-when with Datadog's own
# `muted_duration_over_sixty_days` quality member (CONFIRMED live — it flagged 36/38 monitors on
# a real org, and is exactly how an org-wide open-ended downtime shows up as a per-monitor mute).
# Correlation: this set is a DD-033 suppressor and may double-count with a DD-021 downtime
# silencing the same monitor — name whichever suppressor is active.

# DD-021 + DD-022: downtimes that are broad and open-ended (no end, wide scope)
jq '[.[] | select(.scope_state!="observed" or .schedule_state!="observed" or .identifier_state!="observed") | {id,result:"blocked",reason:"downtime selector or schedule semantics unassessed"}]' "${RAW_DIR}/downtimes.json"
jq '[.[] | select(.scope_state=="observed" and .schedule_state=="observed" and .identifier_state=="observed") | select(.status == "active" or .status == "scheduled")
    | select(.end == null) | {id, scope, status, monitor_identifier}]' "${RAW_DIR}/downtimes.json"
# Judgment: an active downtime with end=null and a scope like "*" or "env:prod" mutes
# matching monitor groups open-ended. Confirm operational intent before calling it a
# defect; an approved permanent posture differs from forgotten temporary maintenance.

# A non-global group query can be valid while its whole-monitor blast radius is unknown.
jq '[.[] | select(.status=="active" and .scope_state=="observed" and .scope != ["*"]) | {id,result:"blocked",reason:"group-level suppression requires observed monitor-group evidence"}]' "${RAW_DIR}/downtimes.json"

# DD-021 current blast radius: scheduled future downtimes are posture candidates,
# never current suppression. Only all-group scope proves whole-monitor suppression;
# group scope is not a monitor-definition tag filter.
jq --slurpfile mons "${RAW_DIR}/monitors.json" '
  def epoch: if type=="number" then . else sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601 end;
  ($mons[0] // []) as $M
  | [.[] | select(.scope_state=="observed" and .schedule_state=="observed" and .identifier_state=="observed") | select(.status=="active" and .end==null and .scope==["*"])
     | select(.start==null or ((.start|epoch)<=now))
     | . as $dt
     | ($M | map(select(. as $m |
         (($dt.monitor_identifier.monitor_id!=null and ($dt.monitor_identifier.monitor_id|tostring)==($m.id|tostring))
          or ($dt.monitor_identifier.monitor_id==null
              and ($dt.monitor_identifier.monitor_tags|length)>0
              and ($dt.monitor_identifier.monitor_tags | all(.=="*" or (. as $tag | $m.tags | index($tag))))))
         and ($dt.scope == ["*"])))) as $hit
     | {downtime:$dt.id,scope:$dt.scope,silenced_monitor_count:($hit|length),
        silenced_services:($hit|map(.tags[]|select(startswith("service:")))|unique)}]' \
  "${RAW_DIR}/downtimes.json"
# Unsupported scope/filter semantics require an attended read and a blocked row.
# Count only monitors whose identifier matches and whose ALL groups are covered.
# A scoped group query such as env:prod does not match a monitor merely because its
# definition carries that tag. Keep its group-level impact unknown until observed.
# The posture candidate above remains useful even when blast radius is unassessed.
```

### 7.1 Downtime intent decay (DD-023)

> **Live-verified (read-only).** Matched a real downtime on a live org: `status: "active"`, `end: null`, `created` well over `DOWNTIME_DECAY_DAYS` in the past, and a `message` reading as a temporary note that asked for its own deletion — every field this check reads (`status`, `schedule.end`, `attributes.created`, `attributes.message`) came back exactly as captured in section 4, no extra call.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/datadog-context.sh"
dd_require downtimes.json
# DD-023: exact captured intent and an effective age threshold.
DOWNTIME_DECAY_DAYS="${DOWNTIME_DECAY_DAYS:-30}" # example, tune to your change cadence
# The capture evaluates literal, case-insensitive intent terms in memory. Default terms:
# test|temp|safe to delete|debug. Customize SCOUTFLO_DATADOG_TEMPORARY_WORDS BEFORE
# recapture. The safe receipt records the exact terms and boolean, never raw annotations.
jq --argjson days "$DOWNTIME_DECAY_DAYS" '
  if ($days|type)!="number" or $days<0 then error("invalid decay days") else . end
  | def to_epoch: if type=="number" then . else fromdateiso8601 end;
  [.[] | select(.status == "active" and .schedule_state=="observed" and .end == null)
     | select(.created_state=="observed" and .temporary_intent.state=="observed")
     | select(((.created | to_epoch)) as $c | (now - $c) > ($days * 86400))
     | select(.temporary_intent.matched==true)
     | {id,status,end,created,temporary_intent,assessment:"review-candidate",age_days:(((now-(.created|to_epoch))/86400)|floor)}]' \
  "${RAW_DIR}/downtimes.json"
jq '[.[] | select(.temporary_intent.state!="observed" or .created_state!="observed" or .schedule_state!="observed") | {id,result:"blocked",reason:"intent, age or schedule semantics unassessed"}]' "${RAW_DIR}/downtimes.json"
# A matching old annotation is a review candidate, not proof that approval expired.
# Confirm the change record and current maintenance need before scoring neglect.

```
Expect: `[]` on a healthy estate — every open-ended downtime either has a non-temporary-sounding message, or is younger than `DOWNTIME_DECAY_DAYS`. A non-empty result names age and the exact captured intent predicate. Raw message text never enters evidence; permanent approved maintenance is not automatically a defect. Remediation is inline (no `setup-datadog` ships): Downtimes list — cancel it now if the maintenance is over, or replace it with a properly scoped, time-bound downtime if the suppression is genuinely still needed.

## 8. Coverage and staleness (DD-030 to DD-038)

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/datadog-context.sh"
dd_require monitors.json slos.json
STALE_DAYS="180"   # example, tune to your monitor churn

# DD-031: composite monitors whose constituent IDs no longer resolve.
# Composite monitor queries reference other monitor ids like "12345 && 67890".
ALL_IDS="$(jq '[.[].id]' "${RAW_DIR}/monitors.json")"
jq --argjson all "$ALL_IDS" '[.[] | select(.query_state=="observed") | select(.type == "composite")
    | {id, name, service: [((.tags // [])[] | select(startswith("service:")))],
       referenced: [.query // "" | scan("[0-9]{3,}") | tonumber],
       missing: ([.query // "" | scan("[0-9]{3,}") | tonumber] - $all)}
    | select((.missing | length) > 0)]' "${RAW_DIR}/monitors.json"
# Expect: []. Blast radius — say WHAT breaks, not just "references a deleted monitor": a
# composite whose constituent id no longer resolves evaluates only on its surviving terms
# (commonly never re-alerts), so name the composite's service: tag and what it gates —
# "the service:payments aggregate alert references deleted monitor 8842291 and now mis-evaluates,
# so the combined payments-degraded condition never fires". Correlation: chains to DD-001 (a
# composite with no @handle) and the DD-033 flagship.

# DD-032: SLOs with no burn-rate/error-budget alerting.
# CAUTION: empty monitor_ids does NOT mean "no alerting" for every SLO type.
#   - monitor-type SLOs are DEFINED by their monitors, so monitor_ids==[] is a real gap.
#   - metric-type and time_slice-type SLOs always have monitor_ids==[] by design; their
#     burn-rate alerting is a SEPARATE monitor of type "slo alert" whose query references
#     the SLO id (e.g. error_budget("<slo_id>")...) and never appears in the SLO's monitor_ids.
# So we only flag a non-monitor SLO when NO "slo alert" monitor references its id.
jq -e 'all(.[] | select(.type=="slo alert"); .query_state=="observed")' "$RAW_DIR/monitors.json" >/dev/null || { echo 'DD-032 blocked: omitted SLO-alert query.'; exit 2; }
SLO_ALERT_QUERIES="$(jq '[.[] | select(.type == "slo alert") | .query // ""]' "${RAW_DIR}/monitors.json")"
jq --argjson sloAlerts "$SLO_ALERT_QUERIES" '[.[]
    | . as $slo
    | ($sloAlerts | map(select(contains($slo.id))) | length) as $alertCount
    | select(if $slo.type == "monitor"
             then ($slo.monitor_ids | length) == 0
             else (($slo.monitor_ids | length) == 0) and ($alertCount == 0) end)
    | {id: $slo.id, name: $slo.name, type: $slo.type}]' "${RAW_DIR}/slos.json"
# Expect: []. An SLO nobody pages on is a dashboard decoration, not an alert. A metric SLO
# that IS covered by an "slo alert" burn-rate monitor is correct and must not be flagged.
# Blast radius — name the SLO target, the service, and whether the budget is ALREADY burning,
# not just "no monitor". For each uncovered SLO, read its trailing SLI vs target from the
# SLO-history endpoint (read-only GET) and state it:
#   SLO_ID="<uncovered slo id>"
#   FROM_TS=$(date -u -v-30d +%s 2>/dev/null || date -u -d '30 days ago' +%s)
#   TO_TS=$(date -u +%s)
#   curl -fsS --max-time 30 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
#     "https://${DD_HOST}/api/v1/slo/${SLO_ID}/history?from_ts=${FROM_TS}&to_ts=${TO_TS}" \
#     | jq '{target: .data.thresholds, sli: .data.overall.sli_value}'
# Yields "payments 99.95% SLO has no burn-rate monitor and its trailing-30d SLI is 99.90%,
# already breaching, with no page firing". The history read is a LIVE number — mark that part
# validated-live; the uncovered-SLO join itself is offline over slos.json. Correlation: feeds
# DD-033 and chains to DD-001 when the SLO's service also has an unrouted monitor. Remediation
# is inline (no setup-datadog ships): SLO edit — attach or create a burn-rate/error-budget
# monitor referencing the SLO id.

# DD-034: monitor tag hygiene — service/team tags for routing
jq '[.[] | select((.tags // []) | (any(startswith("service:")) or any(startswith("team:"))) | not)
    | {id, name, tags}]' "${RAW_DIR}/monitors.json"
# Blast radius — compute the routing consequence, not a hygiene count: when the org has
# notification rules that route by service:/team: tag (DD-004), an untagged monitor matches
# NO rule and falls through to the default route or nowhere. Join the untagged set against the
# DD-004 fall-through result: the count of monitors that silently do not route under the org's
# OWN rules is the finding, e.g. "9 untagged monitors match no notification rule and route only
# by inline handles". When the org has no tag-routing rules, DD-034 stays a low aggregate
# quality signal (attribution, not delivery). Correlation: chains to DD-004 and DD-033.
```

**DD-030 (stale monitors) — distinguish a correctly-quiet monitor from a dead one.** Age alone is a linter line. Pair a never-fired/ancient `last_triggered_ts` with `overall_state`: a monitor stuck in persistent `No Data` because its metric was renamed or removed is a *silent coverage hole*, not a quiet-but-healthy monitor. Join to service criticality to name which critical service lost a metric.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/datadog-context.sh"
dd_require monitors.json
STALE_DAYS="180"   # example, tune to your monitor churn
STALE_BEFORE="$(date -u -v-${STALE_DAYS}d +%s 2>/dev/null || date -u -d "${STALE_DAYS} days ago" +%s)"
jq --argjson cutoff "$STALE_BEFORE" '
  def to_epoch: if type=="number" then . else sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601 end;
  [.[]
    | select(.last_triggered_ts==null or ((.last_triggered_ts | to_epoch) < $cutoff))
    | {id, name, overall_state, last_triggered_ts,
       service: [((.tags // [])[] | select(startswith("service:")))],
       likely_dead: (.overall_state == "No Data")}]' "${RAW_DIR}/monitors.json"
```
A `likely_dead: true` row is a No Data investigation candidate; a vanished metric requires a confirming metric/runtime read. A stale-but-OK row is a note, not proof that monitoring stopped. Remediation is inline (no setup-datadog ships): Monitor edit — retire truly-dead monitors, repair the metric query where the underlying metric vanished. Correlation: chains to DD-011 (no-data) and the DD-033 flagship.

### 8.1 DD-033 — source eligibility and unresolved delivery

For each declared critical service, subtract drafts, unusable handles, known broken
handles and applicable active suppression. Keep unresolved suppression and omitted
identity fields unknown. `notify_no_data: false` is **not** a general suppressor:
only a monitor explicitly required to notify on missing data is assessed that way.
A normal metric monitor can still notify on threshold breaches with that option false.

Prepare `SCOUTFLO_DATADOG_COVERAGE_INTENT` as the path to an operator/business-context
JSON declaration containing `declared_by`, `evidence_ref`, `critical_services` (exact
service-tag values) and `missing_data_required_monitor_ids` (explicit IDs, empty when
no such requirement is declared). Never derive intent from a name containing "heartbeat".
Missing declarations block this check; they do not silently use example services.

```bash
set -eu
sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/coverage.sh"
```

The result reports `source_eligible_monitors`, excluded reasons and unresolved
subsets. Eligibility is configuration evidence, so `human_delivery` remains
`unverified` and `end_to_end` remains false. An unflagged `@victorops-` handle is not
a verified route. Resolve the destination independently with `audit-splunk-oncall`
and its source-evidence protocol; only a received-page receipt proves the human
hop. Zero inline candidates still requires DD-004 rule-routing assessment before
claiming that a service has no route. Re-run the same joins after any approved fix.

### 8.2 Scope consistency, overlapping queries, No Data, and paused Synthetics (DD-035 to DD-038)

> **Live-verified (read-only).** DD-035 matched a real monitor on a live org whose query scope named one value for a tag key (e.g. `cluster_name:a`) while the monitor's own tag for that same key carried a different value (`cluster_name:b`) — the query is what actually evaluates; the tag is what this toolkit's own topology join and DD-034 trust. DD-036 matched four real published monitors sharing the identical normalized base metric and scope, differing only in window and threshold. DD-037 matched four real monitors created weeks earlier, still `No Data` with `overall_state_modified == null`. DD-038 matched two real paused Synthetic tests each still linked (via `monitor_id`) to a monitor without a legacy per-monitor mute whose `overall_state` reflects only its last real evaluation, not the pause.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/datadog-context.sh"
dd_require monitors.json synthetics.json
NO_TRANSITION_DAYS="${NO_TRANSITION_DAYS:-${NEVER_EVALUATED_DAYS:-7}}" # example; legacy alias retained
case "$NO_TRANSITION_DAYS" in ''|*[!0-9]*) echo 'Invalid No Data review age'; exit 2 ;; esac

# DD-035: a monitor's query scope names a key:value that its OWN tags contradict.
# `capture("\\{(?<scope>[^}]*)\\}")` takes the FIRST {...} block in the query — the scope
# filter immediately after the metric name, never a later `by {...}` grouping clause (the
# grouping clause has bare keys with no `:value`, so it never produces a spurious term here).
jq '[.[] | select(.query_state=="observed") | . as $mon
   | ((.query // "") | capture("\\{(?<scope>[^}]*)\\}").scope) as $scope
   | ([$scope // "" | scan("([A-Za-z0-9_]+):([A-Za-z0-9_.-]+)")] | map({(.[0]): .[1]}) | add // {}) as $qterms
   | ($mon.tags // [] | map(split(":")) | map(select(length==2)) | map({(.[0]): .[1]}) | add // {}) as $tterms
   | ($qterms | to_entries
      | map(select(.key as $k | $tterms[$k] != null and $tterms[$k] != .value))
      | map({key: .key, query_value: .value, tag_value: $tterms[.key]})) as $mismatch
   | select(($mismatch | length) > 0)
   | {id: $mon.id, name: $mon.name, mismatch: $mismatch}]' "${RAW_DIR}/monitors.json"
# Blast radius: name the exact key and the two values — "the checkout-latency monitor's query
# scopes to cluster_name:prod-a but its own cluster_name tag says prod-b" — this is a routing/
# topology join hazard (DD-034, the coverage matrix, map-topology's service-name join), not a
# cosmetic label problem: whatever trusts the tag is looking at the wrong resource.

# DD-036: overlap candidates, never automatic redundant-monitor findings. Keep
# each original query so deliberate windows/tiers remain visible for intent review.
jq '[.[] | select(.query_state=="observed") | select(.type=="metric alert" or .type=="query alert")
   | select(.draft_status=="published")
   | . as $mon
   | ((.query // "")
      | sub("^[a-z_]+\\([^)]*\\):\\s*"; "")
      | sub("\\s*[<>=!]+\\s*-?[0-9]+(\\.[0-9]+)?\\s*$"; "")) as $norm
   | {id: $mon.id, name: $mon.name, query: $mon.query, norm: $norm}]
  | group_by(.norm) | map(select(length>1))
  | map({normalized_expression: .[0].norm, monitor_ids: map(.id), queries: map(.query), count: length,
         assessment:"review-candidate", intent:"unverified"})' \
  "${RAW_DIR}/monitors.json"
# Compare the exact windows, thresholds, receivers and declared purpose. Intentional
# warning/critical or fast/slow tiers are valid. Unknown intent blocks a scoring
# conclusion; only evidenced unintended duplication/drift supports a failed DD-036.

# DD-037: missing transition metadata cannot prove missing evaluations.
NO_TRANSITION_CUTOFF="$(( $(date -u +%s) - NO_TRANSITION_DAYS * 24 * 3600 ))"
jq --argjson cutoff "$NO_TRANSITION_CUTOFF" '
  def to_epoch: if type=="number" then . elif type=="string" then
    try (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601) catch null else null end;
  [.[] | select(.overall_state=="No Data" and .overall_state_modified==null)
     | (.created | to_epoch) as $created
     | select($created==null or $created < $cutoff)
     | {id, name, created, observed_state:.overall_state, transition_metadata:"null-or-omitted",
        evaluation_history:"unverified", assessment:(if $created==null then "blocked" else "review-candidate" end),
        service: [((.tags // [])[] | select(startswith("service:")))]}]' \
  "${RAW_DIR}/monitors.json"
# An unchanged No Data state can coexist with repeated evaluations. Check actual
# evaluation/query-result history and expected signal cadence before a failed DD-037.
# Missing history blocks that conclusion; intentionally idle signals may be healthy.

# DD-038: a paused Synthetic backing a monitor with no observed legacy per-monitor mute.
# Active downtime suppression is evaluated separately; this does not prove paging.
jq -n --slurpfile mons "${RAW_DIR}/monitors.json" --slurpfile synth "${RAW_DIR}/synthetics.json" '
  ($mons[0] // []) as $M
  | ($synth[0] // []) as $S
  | [ $S[] | select(.status == "paused" and .monitor_id != null) as $t
      | ($M | map(select(.id == $t.monitor_id)) | .[0]) as $mon
      | select($mon != null)
      | select($mon.options.silenced_state=="observed")
      | select((($mon.options.silenced // {}) | to_entries | any(.value==null or .value==0)) | not)
      | {synthetic_public_id: $t.public_id, monitor_id: $mon.id, monitor_name: $mon.name,
         monitor_overall_state: $mon.overall_state,
         service: [(($mon.tags // [])[] | select(startswith("service:")))]} ]'
# Blast radius: the monitor's overall_state reflects only its LAST real evaluation before the
# Synthetic was paused — an "OK" state here is not proof of health, it is a frozen snapshot.
# Join to service criticality; a paused Synthetic behind a critical service's only monitor is
# the DD-033-shaped blind spot with an extra twist: the console shows green because nothing
# has told it otherwise, not because anything is actually being checked.
```
Expect: DD-036 and DD-037 may return candidates in a healthy estate; neither output alone fails a check. Confirm intended tiers/windows before a DD-036 finding, and evaluation/ingestion behavior against required cadence before a DD-037 finding. Missing evidence stays blocked. Remediation is inline (no `setup-datadog` ships): DD-035 → reconcile tags with the exact evaluated scope; DD-036 → retire or reconcile an evidenced unintended duplicate; DD-037 → repair an evidenced query/ingestion gap; DD-038 → restore a required Synthetic or retire an intentionally unused monitor.

## 9. Rate-limit handling (all sections)

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/datadog-context.sh"
# The bounded helper reports 429 without its raw body and stops. Honor Retry-After
# from an attended safe metadata read, then rerun the exact owning block; do not
# replace errors with an empty list or carry a DD_PATH over from another shell.
dd_read counts '/api/v1/monitor/search?per_page=1'
```

## 10. Per-service coverage queries (coverage matrix)

For each critical service from `./scoutflo-audits/topology.md`, match Datadog monitors by `service:` tag (fall back to name match, recorded), then fill the matrix row from the section 5 to 8 captures: delivery (DD-001), noise posture (DD-010/011), muting (DD-020), coverage (DD-033), SLO pairing (DD-032). Name affected services in findings.

## 11. Cost & Resource Optimization (non-scored, DDOPT-NNN)

Runs only when the doctor `datadog cost-permissions` row is `pass`; on `skipped`, the whole section reports `excluded, reason: <doctor reason>`. Never scored, never in `score.categories`; findings carry `points_recoverable: 0` and an `estimated_monthly_cost_usd` field only when the number comes straight from Datadog's own usage endpoint.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/datadog-context.sh"
dd_capture estimated-cost '/api/v2/usage/estimated_cost?view=sub-org' estimated-cost.json
USAGE_MONTH="$(date -u +%Y-%m-01T00)"
dd_capture top-metrics "/api/v1/usage/top_avg_metrics?month=${USAGE_MONTH}&limit=20" top-metrics.json
jq . "$RAW_DIR/estimated-cost.json" "$RAW_DIR/top-metrics.json"
```

Report presence facts only where no dollar figure is backed by the API; never estimate savings the platform did not compute.

## 12. Starting thresholds (examples, tune every one)

| Variable | Default | Meaning |
| --- | --- | --- |
| `STALE_DAYS` | 180 | Never-triggered window before a monitor is stale-flagged |
| `EVT_WINDOW_DAYS` | 30 | Trailing window for the DD-006 measured alert-event volume check |
| `DOWNTIME_DECAY_DAYS` | 30 | Age past which an active, open-ended, temporary-worded downtime is flagged (DD-023) |
| `NO_TRANSITION_DAYS` (`NEVER_EVALUATED_DAYS` legacy alias) | 7 | Age for No Data/null-transition review candidates; never proof of absent evaluations (DD-037) |
| `SCOUTFLO_DATADOG_NONNEGATIVE_EVIDENCE` | unset | Optional local lower-bound evidence, bound to each exact query digest; metric-name hints cannot establish the domain |

## 13. Forbidden commands

This is an audit: read-only, no exceptions. Never run:

- Any `PUT`, `PATCH`, or `DELETE` — none exist in this skill's surface. The single `POST` this skill sends (`POST /api/v2/events/search`, DD-006) is a read-by-effect query exactly like PagerDuty analytics — classify by effect, not verb (section 1) — and searches events, creating nothing; every OTHER mutating verb, and every other POST, is out.
- Creating, editing, deleting, muting, or resolving monitors; `POST /api/v1/monitor/{id}/mute` or `/unmute`; creating or canceling downtimes.
- Editing SLOs, notification rules, config policies, integrations, dashboards, or Synthetic tests; resuming or pausing a Synthetic test (DD-038 reads its `status`, never changes it).
- `POST /api/v1/monitor/validate` (validates a monitor body you would be composing; setup-lane).
- Sending any test notification or event (`POST /api/v1/events`) — note this is the write counterpart of the read-only `GET /api/v1/events` DD-006 uses; never confuse the two.
