---
name: audit-datadog
description: Read-only scored audit of Datadog monitor health across notification delivery, monitor noise controls (recovery thresholds, no-data, renotify, auto-resolve), muting and downtimes, SLO and composite coverage, plus a separate non-scored Cost & Resource Optimization section from Datadog's own usage endpoints; writes findings.json and report.md and changes nothing. Use when the user mentions auditing or scoring Datadog, Datadog monitors, monitor noise or flapping, muted or downtimed monitors, dead notification handles, SLO alerting, or Datadog custom-metric cost. Do not use to change Datadog (no setup-datadog ships yet; the audit names each fix), for Datadog data shown in Grafana (use audit-grafana), or for the paging layer downstream of a monitor (use audit-pagerduty or audit-splunk-oncall).
---

# audit-datadog

Scored, read-only audit of the Datadog monitors that carry your alerting: whether each monitor has a usable configured destination, whether its noise controls are tuned, whether anything is muted or downtimed into a blind spot, whether SLOs and composite monitors are intact, and — as a separate non-scored section — where Datadog's own usage data says your spend is going. It identifies source-side delivery gaps, noise risks and coverage defects. A configured target or a healthy source API does not prove that a person received a page.

This skill audits the monitor layer inside Datadog. Whether the page that a monitor sends then reaches a human through PagerDuty or Splunk On-Call is the paging layer's job (`audit-pagerduty` or `audit-splunk-oncall`); Datadog data rendered in Grafana dashboards is `audit-grafana`. This audit stops at the monitor and its notification targets.

Every command is read-only: GET on monitors, downtimes, SLOs, integrations, usage, and dashboards. The fixed `events/search` POST is read-only by effect. Every mutating operation — muting, resolving, creating downtimes, test events — is forbidden; the full list is in [references/datadog-checks.md](references/datadog-checks.md) section 13. There is no `setup-datadog` yet, so every finding names its manual fix path instead of a setup anchor.

**Multiple Datadog targets, one run:** `datadog` may be a single block (one `site`/`api_key_env`/`app_key_env`) or a **list of labeled targets**, each with its own `site`, `api_key_env`, and `app_key_env`. The audit **iterates every target** — enumerate them with `sh "${CLAUDE_PLUGIN_ROOT}/report-standard/toolkit-targets.sh" <cfg> datadog labels` and run the full sequence below once per target with `SCOUTFLO_TARGET=<label>` set. Output goes to `datadog/<label>/<date>/` for a list, or the flat `datadog/<date>/` for a single block. Every API call resolves and uses the target's own `site` and key pair — `api_key_env`/`app_key_env` name the variables holding the secrets, sent as the `DD-API-KEY`/`DD-APPLICATION-KEY` headers; the selected variable names may resolve from the store or exported environment (store wins), with no fallback to another target or variable name, and a single-block config resolves to exactly one target whose label defaults to the block name (`datadog`), using the same target and flat output convention. All command blocks re-resolve the same selected target through `scripts/datadog-context.sh`; a missing list label stops before reads.

Run this standalone, from `/scoutflo:audit-all`, or on a schedule via `/scoutflo:schedule-audits`.

Outputs, per the [report standard](../../report-standard/README.md):

- `./scoutflo-audits/datadog/[<label>/]<YYYY-MM-DD>/findings.json` per the [findings schema](../../report-standard/findings-schema.md), finding IDs `DD-NNN` (scored) and `DDOPT-NNN` (non-scored cost)
- `./scoutflo-audits/datadog/[<label>/]<YYYY-MM-DD>/report.md` per the [report template](../../report-standard/report-template.md), including the `## Inventory` section (the `render-report-viz.sh inventory` output)
- `./scoutflo-audits/datadog/[<label>/]<YYYY-MM-DD>/inventory.json` per the [inventory schema](../../report-standard/inventory-schema.md) (`scoutflo-inventory/v1`): the complete Phase-2 catalog — one item per monitor, SLO, and downtime (`kind`: `monitor`, `slo`, `downtime`) — each with `kind`, `covers`, `enabled`, `severity`, and `routes_to` for alerting objects. Built from safe capture projections. An `@handle` alone keeps `routes_to: "unknown"`; never set `enabled: true` or a routed value when the relevant projection was omitted or source/destination evidence is incomplete.
- One appended line in `./scoutflo-audits/datadog/[<label>/]history.jsonl`
- One Slack brief, when `slack.webhook_env` is configured

## Doctor gate

| Integration | toolkit.yaml keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| Datadog | `datadog.site`, `datadog.api_key_env`, `datadog.app_key_env`, optional `datadog.cost_checks` | the variables named by `api_key_env` (`DATADOG_API_KEY`) and `app_key_env` (`DATADOG_APP_KEY`) | scoped app key: `monitors_read`, `monitors_downtime`, `slos_read`, `events_read`, `synthetics_read` (+ `usage_read`, `billing_read` for the cost section) | read-only |
| Slack (optional) | `slack.webhook_env` | webhook variable | post to one channel | n/a |

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/datadog-context.sh"
# The resolver uses toolkit-targets.sh, DD_SEG, and only the selected key names.
# Secret-store ladder: SCOUTFLO_ENV_FILE -> ./.scoutflo/env -> ~/.scoutflo/env.
# dd_read captures %{content_type}; project-read.sh asserts JSON and endpoint shape
# before any response can be persisted or printed.
dd_prerequisites # Python >=3.8; curl >=8.4 bounds unknown-length responses; jq required
dd_read validate /api/v1/validate >/dev/null
dd_read monitors '/api/v1/monitor?page_size=1' >/dev/null
printf 'doctor gate: pass for %s on %s
' "$DD_SEG" "$DD_SITE"
```

Never proceed past a failed doctor check and never downgrade one into a finding. `/scoutflo:doctor` runs the same checks standalone, plus the non-failing cost-permission probe this audit's Cost & Resource Optimization section reads.

Datadog needs a key pair: the API key alone validates identity; the app key plus its scopes authorizes reads. The tier is scope-declared at key creation and cannot be introspected afterward, so if a broader app key is used the audit still runs, but record in the report that the audit credential can do more than read.

## Live-safety gate

Print what you are pointed at and compare it to the config before the first real check:

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/datadog-context.sh"
# Names are projected first; full messages, URLs and raw errors never reach stdout.
dd_read org /api/v1/org || echo 'Org metadata unavailable; use the selected site and safe monitor identities.'
dd_read monitors '/api/v1/monitor?page_size=3' | jq '[.[] | {id,name}]'
printf 'Compare this identity to the intended account: %s on %s
' "$DD_SEG" "$DD_SITE"
```

The key pair and the site together select the account; the selected variable names may resolve from the store or exported environment (store wins), with no fallback to another target or variable name. The `/api/v1/org` read is best-effort (some scoped keys cannot read org metadata — an `unreadable` there is fine); the safe monitor identities support your comparison. Record the accepted target, site and identity evidence in the report before judging checks. If they differ from the intended account, stop and correct the configuration. Captures additionally bind the selected variable names and credential generation with a private keyed digest; changed credentials require recapture, even on the same site and date.

## Ground rules

- Configuration is metadata; observed behavior is proof. A monitor with an `@handle` in its message is `configured`; a resolved integration/channel/webhook proves destination configuration exists. Source eligibility, destination resolution and human delivery are separate evidence levels; human delivery stays unverified without an observed delivery receipt.
- API errors are evidence. A `403` means the API key is wrong, the site is wrong, or the app key lacks the scope; record which, and never convert an error into empty success. On Datadog specifically, check the site before concluding a scope problem — a valid key on the wrong site returns 403.
- Never score from object counts.
  - ❌ `Scored monitor coverage 90: two hundred monitors exist.`
  - ✅ `Scored monitor coverage 45: two hundred monitors exist, but eleven are drafts, six target a deleted Slack channel, and thirty have no service tag; credit stops at partial.`
- Trust Datadog's own signals, and reconcile them. `GET /api/v1/monitor/search` returns a `quality_issues[]` array on each monitor object (top-level on the monitor, not under `.metadata`; verified live), flagging muted >60 days, missing recipients, stuck in alert, composite missing constituents. Report the vendor's flags alongside this audit's findings; where they disagree about a monitor, the disagreement is itself the finding (DD-015).
- Downtimes are v2 only. Every v1 downtime endpoint is deprecated including its reads; this audit reads `/api/v2/downtime` and never `/api/v1/downtime`.
- Never persist full monitor or downtime message bodies, API/app keys, raw query bodies or raw API errors. The fixed capture projects safe metadata before persistence. Unsupported query grammars are omitted with `query_state: omitted`; query-dependent checks are blocked for those objects, never passed from a blank string. Conditional notification templates carry unresolved condition semantics and cannot prove source eligibility from handle presence alone.

## Estate sizing

Count before judging, and declare the path in the terminal output:

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/datadog-context.sh"
SMALL_MAX_OBJECTS="25"    # example, tune to your environment
MEDIUM_MAX_OBJECTS="150"  # example, tune to your environment
BATCH_SIZE="50"           # monitors per batch on the large path; example, tune it
dd_capture counts '/api/v1/monitor/search?per_page=1' estate-count.json
MON_COUNT=$(jq -r .count "$RAW_DIR/estate-count.json")
TOTAL="$MON_COUNT"
echo "monitors=${MON_COUNT} scored_objects=${TOTAL}"

# Guided-walkthrough drift check, per report-standard/README.md: compare against the last run.
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${DD_SEG}"
PREV_RUN="$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -E "/[0-9]{4}-[0-9]{2}-[0-9]{2}$" | sort | tail -1)"
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
- **Large**: the bounded provider capture completes first and always recaptures from page zero. Judgment uses `scripts/assessment-worklist.sh`: `init` scans matching credential/digest-bound runs before creating a stable run ID, `claim 50` locks and returns a batch (or the interrupted claim), and `done <proof-file>` requires the exact claimed monitor IDs plus nonempty `{id,result}` check rows. Keep the safe proof JSON under this date directory. `check` requires zero pending rows before output. Worklists live under `<target>/runs/<run-id>/`; they do not promise resumable provider pagination. For a run crossing UTC midnight, set `SCOUTFLO_DATADOG_RUN_DATE` to its original reported date on every subsequent fresh-shell invocation, preserving the same capture and run ID. New credential generations or changed monitor digests require fresh assessment.

Never silently truncate: if the run judged a subset, the report names what was skipped and the coverage denominators reflect it. The rate-limit retry rule in [references/datadog-checks.md](references/datadog-checks.md) section 9 applies to every call.

### Scope checkpoint

On a large estate this audit pauses to let you scope before spending tokens, per the shared [estate-sizing scope checkpoint](../../report-standard/estate-scope-checkpoint.md). After the sizing step above computes the object count, run the shared checkpoint block:

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/datadog-context.sh"
dd_require estate-count.json
TOTAL=$(jq -r .count "$RAW_DIR/estate-count.json")
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

Build the raw picture with the commands in [references/datadog-checks.md](references/datadog-checks.md) section 4: all monitors with safe notification predicates, options, tags, and state; Datadog's own `quality_issues[]` per monitor; v2 downtimes; and SLOs with their attached monitor IDs. Judgment starts in Phase 3. A 403 on any surface is an auth/scope note attached to the checks that need it, naming the missing scope.

### Source routing evidence and semantic limits

The inventory recipe exports `raw/source-routing-evidence.json` and its capture receipt for the [Splunk On-Call source-evidence protocol](../audit-splunk-oncall/references/source-evidence.md). Each distinct safe observed paging handle gets its own stable record, even when one monitor has multiple handles. Each source record binds the resolved target, stable monitor ID, observation time and safe notification metadata. VictorOps handle references are **candidates**: neither the spelling nor a successful Datadog read proves the protected route key, receiving account, policy, team or person. The On-Call binder must independently verify that mapping; imported metadata cannot promote itself. Keep the receipt beside its source evidence and never hash a credential-bearing query or URL.

Read `query_state`, `handles_complete` and `omitted_fields` before each predicate. For omitted query/tag/mute semantics, affected DD-007, DD-018/019, DD-031/032 and DD-035/036 rows are `blocked` for the affected subset, with a specific attended safe-read unlock; do not treat null/empty projections as absent objects, duplicate queries or matching coverage. A malformed/denied read removes the stale same-day input and leaves a blocked marker, never `[]`. Older raw captures without the current target/site/date/digest/credential-generation receipt must be recaptured. Configuration-based concentration is a fatigue candidate; measured page counts and interruptions still come from the separate alert-fatigue history lane.

### Canonical collection and qualified service evidence

The fixed capture writes `inventory.json` plus `raw/collection.json`. Its catalog collection is `partial/subset`: monitors have an independently reconciled total, while SLO/downtime page termination has no separately captured total. A complete monitor list alone cannot establish target-complete catalog absence. Copy that same collection into `findings.json`; narrow its status further if judgment omitted objects. Readiness, history-window completeness and destination proof remain separate assessments; they do not define inventory collection status.

Follow [service-evidence.md](../../report-standard/service-evidence.md). A `service:` tag is a display label, never proof that another account or cluster contains the same service. The default inventory therefore emits no fabricated `service_identity`; unresolved active coverage remains unknown. Once an owning safe source read proves a stable account/resource tuple or selected-control-plane cluster/namespace/service tuple, add `service_identity` and `identity_evidence` to that inventory row. On findings add `correlation_bindings: [{affected, service_identity, evidence}]` only for affected entries that share that proof. Bind evidence to the exact target, collection timestamp and relative safe source reference. Missing identity stays unmappable, with a verification action. Run `check-correlation-evidence.sh` on both artifacts; a valid shape is not independent proof of identity.

## Phase 3: Monitor delivery (DD-001 to DD-008)

Commands in section 5. Judge source notification configuration and separately resolve destinations: every monitor names at least one `@handle` (`DD-001`, critical when a monitor notifies nobody), no monitor targets a dead handle — a Slack channel, webhook, or PagerDuty service that no longer resolves (`DD-002`, high), no monitor left in `draft` status masquerading as coverage (`DD-003`, high — drafts never notify), org-level notification rules and config policies reviewed where the org uses them (`DD-004`, computing the routing fall-through set), and critical-service monitors carrying a `priority` so paging can be tiered rather than flat (`DD-005`, medium, **live-verified (read-only)** — section 5.1, no residual: `priority` observed present and `null` on real monitors, exactly the untiered case it flags). DD-001/DD-002/DD-003 do not stop at a count: each joins the failing monitor to its `service:` tag and criticality so the finding names which service goes blind, and each is one of the suppressors the Phase-6 DD-033 effective-coverage flagship subtracts.

- ❌ `Delivery pass: every monitor has a message.`
- ✅ `Delivery partial: every monitor has a message, but six target @slack-prod-alerts which is not in the Slack integration's channel list (DD-002), and two are drafts (DD-003); affected: checkout, payments.`

Three checks measure delivery Datadog's own config screens cannot show you, each **live-verified (read-only)** against a real Datadog org — section 5.2:

- **`DD-006` (high) — measured alert-event volume, not inferred.** `DD-001` to `DD-003` judge configuration; `DD-006` is the missing evidence layer, the same class as a Sentry rule's fire-history: count `sources=alert` events (`GET /api/v1/events`, corroborated with the v2 `source:alert` events-search query) per `monitor_id` over a trailing window. Zero observed events plus a state timestamp is a reconciliation question. The transition may be recovery or a group change, and the event API may be capped; require complete history and applicable notification-policy evidence before asserting a missed notification. Also yields a noisiest-monitor ranking from the same pull, feeding DD-016.
- **`DD-007` (high) — placeholder and template artifacts left un-filled.** `DD-001`'s `test("@")` only checks that some `@`-shaped token exists in the message; a monitor whose only real target is a literal template placeholder (`@your-team-handle`, a `__..._placeholder__` fragment inside the query, or a tag value that is literally `$service`/`$env` because a template variable was never substituted) still contains an `@` and currently **passes DD-001 by accident**. `DD-007` closes that gap: it flags the placeholder shapes directly, independent of whether a real handle also happens to be present, and is one more suppressor the DD-033 flagship subtracts (a monitor whose only resolvable-looking handle is a placeholder does not deliver, exactly like the no-handle set).
- **`DD-008` (medium) — over-broad `@all`/`@everyone`.** A monitor that pages the whole org on every breach trades noise for reach; name it and let the team decide whether that breadth is deliberate (an incident-bridge monitor) or accidental scope creep from a copy-pasted message.

## Phase 4: Monitor noise (DD-010 to DD-019, DD-039)

Commands in section 6. This is the alert-hygiene category. Recovery thresholds where a monitor has warning/critical thresholds and can flap (`DD-010`, joined to the notification handle so the finding names where the flap noise lands), deliberate no-data handling rather than a silent blind spot or a false page (`DD-011`, isolating the dangerous notify_no_data=false heartbeats), bounded renotification instead of forever (`DD-012`), evaluation and new-group delay where the query needs late data (`DD-013`), deliberate auto-resolve per type (`DD-014`), full-window evaluation posture on metric monitors — `require_full_window == false` exposes partial-window configuration (`DD-039`, low); actual cadence and observed evaluation behavior determine whether either true or false is a defect, and Datadog's own `quality_issues[]` reviewed and reconciled with this audit (`DD-015`, info).

Two noise checks are **live-verified (read-only)** (section 6.1): receiver configuration concentration: critical-service monitors sharing a handle with monitors that carry noise-control risks (`DD-016`, high, the doctrine's alert-fatigue worked example made executable for Datadog); and monitors currently in `overall_state == "Alert"` whose age and notification policy need review; current state does not prove continuous duration or inability to re-page (`DD-017`, medium). Both load-bearing computations run on real monitor objects: DD-016's configuration handle→monitor concentration map plus the DD-010/DD-012 noisy set, and DD-017's `overall_state` stuck-state read (observed both `OK` and real `Alert` states on live monitors) — no dependence on any unverified vendor string. The `quality_issues[]` corroboration layer these checks add is now **confirmed live** too — a real org carried the members `broken_at_handle`, `missing_at_handle`, `alerted_too_long` (the real "stuck/alerting-too-long" member, not `stuck`), and `muted_duration_over_sixty_days` on 36/38 monitors — so the corroboration is real, on top of the observed concentration/current-state candidates, whose impact still needs separate evidence.

Honest ceiling, stated in the report every run: monitor options are metadata about intent; whether a monitor actually flapped is visible only in its state history, which this audit samples but does not exhaustively reconstruct. Event Management correlation exists in Datadog but has no public API for its rules, so this audit reports correlation as UI-only and does not score it.

Two checks judge the query and threshold shape itself, not just the options around it — section 6.2, **live-verified (read-only)**: a real query in the same live org that fed DD-006/DD-007 evidence carried both defects at once, which is why they are separate checks even though one query can trip both.

- **`DD-018` (medium) — a ratio with no volume floor.** A query dividing two count terms (`errors.as_count() / hits.as_count() > threshold`) alerts on a proportion with no minimum-sample guard: one error in nine hits crosses a 10% threshold exactly as confidently as one thousand errors in nine thousand hits, but the two carry opposite operational weight. Flag every ratio query with no composite `AND` clause enforcing a minimum denominator, and name the threshold and the missing floor.
- **`DD-019` (medium): evidenced tautological thresholds.** Strict `>0` can recover at zero. Only a proven lower bound for the entire evaluated expression makes `>=0` or a negative threshold unconditional. Name fragments and current Alert state cannot supply that proof; use the exact safe-query digest and a domain-evidence reference, otherwise report blocked.

## Phase 5: Muting and downtime (DD-020 to DD-023)

Commands in section 7. Indefinitely muted monitors — a stuck/suppressed alert wearing a mute (`DD-020`, high), no always-on broad-scope downtime masking real alerts (`DD-021`, high — read from `/api/v2/downtime`), and downtimes scoped tightly rather than muting whole environments open-ended (`DD-022`). A tightly scoped recurring maintenance window is healthy; an active downtime with no end and a `*` or `env:prod` scope is a permanent blind spot.

**`DD-023` (high): review aged temporary intent.** The capture evaluates the named literal predicate (`test|temp|safe to delete|debug` by default) before persistence and retains its boolean and terms, never raw annotations. The actual `DOWNTIME_DECAY_DAYS` value controls the recipe. An old matching open-ended downtime is a review candidate: confirm its change record and current approval before calling it neglect. Ordinary permanent maintenance is not rewritten as temporary. Tune `SCOUTFLO_DATADOG_TEMPORARY_WORDS` before recapture when your team uses other terms.

## Phase 6: Coverage and staleness (DD-030 to DD-038)

Commands in section 8. Stale monitors distinguished from dead ones by pairing `last_triggered_ts` with `overall_state` — a monitor stuck in persistent `No Data` because its metric vanished is a silent coverage hole, not a quiet-but-healthy monitor (`DD-030`); composite monitors whose constituent IDs all resolve, naming the service the broken aggregate gates (`DD-031` — a composite referencing a deleted monitor silently misfires); SLOs with an error-budget or burn-rate monitor attached, naming the SLO target/service and reading the trailing SLI-vs-target so the finding states whether the budget is already burning (`DD-032`, high); critical-service **effective** coverage (`DD-033`, the flagship — section 8.1); and monitor tag hygiene computed as routing fall-through against DD-004's rules, not a bare hygiene count (`DD-034`).

**DD-033 source eligibility.** Join each declared service to published monitors, usable handle references, vendor-reported broken handles and applicable active suppression. Apply missing-data notification requirements only to explicitly declared monitor IDs. Report source eligibility and unresolved destinations separately: a remaining `@victorops-` monitor has not proved a route or a page reaching a person. Unknown routing, unsupported scope matching or omitted identity fields stay blocked. Use `audit-splunk-oncall` for an independent protected-route/account/policy/team join and a received-page receipt for the human hop.

Four more coverage checks, all **live-verified (read-only)** against a real Datadog org — section 8.2:

- **`DD-035` (medium) — tag-vs-query scope mismatch.** A monitor's query carries its own scope filter (`{service:X,env:Y}` immediately after the metric name); when a tag on the same monitor names the same key with a *different* value (`service:` tag says one thing, the query's `service:` scope term says another), the tag lies to anything that routes, correlates, or builds topology from it — the query is what actually evaluates, the tag is what the rest of the org (including this toolkit's own topology join) trusts. Confirmed live: the extraction and comparison run correctly against a real monitor whose query scope and tags agreed (no false positive when they match); the check is the join, not an assumption about which side is wrong.
- **`DD-036` (low): overlapping query candidates.** Group published metric monitors by normalized expression and scope while retaining each original query. Deliberate warning/critical tiers or fast/slow windows can share that expression. The group is a review candidate, not a failed check. Confirm the intended window, threshold, receiver and purpose for every member; only evidenced unintended duplication or drift supports a finding. Unknown intent stays blocked. Historical reads found four such overlapping monitors; that observation did not establish redundant coverage.
- **`DD-037` (medium): No Data with unavailable transition history.** An older monitor reporting `No Data` with null or absent `overall_state_modified` needs evaluation/ingestion evidence. It may have evaluated repeatedly without changing state; the snapshot cannot prove that it never started. `NO_TRANSITION_DAYS` (7 by default, with `NEVER_EVALUATED_DAYS` retained as a compatibility alias) controls which observations are review candidates. Require current query-result/evaluation history and the declared signal cadence before a failed check. Missing history stays blocked; deliberately idle signals may be healthy.
- **`DD-038` (high) — a paused Synthetic behind a live, unmuted monitor.** A Synthetic test's own `status` (`live`/`paused`) is independent of the Datadog-generated monitor attached to it via `monitor_id`; a paused test stops running checks, but its monitor keeps reporting whatever state it last held — usually `OK` — with no future update, so the monitor looks healthy while the thing it was supposed to watch has not been probed since the pause. Confirmed live: two paused Synthetic tests, each still linked to an unmuted monitor (`overall_state` unaffected by the pause, `options.silenced` empty on both) — both monitors will never again reflect the Synthetic's real target, because nothing is checking it.

## Phase 7: Coverage matrix and topology readiness

Fill one row per critical service using the per-service mapping in section 10 and the check-result vocabulary (`pass`, `partial`, `fail`, `blocked`, `not-in-scope`):

| Service | Ready | Delivery | Noise | Muting | Coverage | SLO | Owner | Gap |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |

Every cell carries its `passed/total` denominator. Name affected services in findings.

Then render the Scoutflo Topology Readiness section per [topology-readiness.md](../../report-standard/topology-readiness.md): evaluate the six checks per critical service from `./scoutflo-audits/topology-export.json`, read-only. A `MONITORED_BY` connection to Datadog that this audit verified live (the monitor resolved, names a live target, and covers the service) counts toward Match confidence per the standard's live-verification rule. Gaps that map to an existing finding reference its ID; gaps with no finding get a `TOPO-` row pointing at `/scoutflo:map-topology`. Render check names and confidence per the standard: plain-English column headers, confidence as `n/10`, and — whenever any service is below ready — the ticket-ready readiness action plan table. If the export or topology.md is missing, or exists but describes a different target than this audit covers, the section renders the matching state from topology-readiness.md with its one-line unlock; it never guesses and never says a bare "unavailable". Readiness is reported, never folded into the 0-100 score.

**Provider-identity note, verified against the platform's current model:** `datadog` is a valid provider identity with a typed attribute schema (`monitoring.datadog`) on the Scoutflo platform, so a `MONITORED_BY` connection naming Datadog can reach full confidence. The schema's required field is `monitorId`; its identity fields are camelCase (`serviceName`, `hostname`, `clusterId`), and exported raw-attribute paths and normalized-key extraction treat camelCase differently. In the raw-path case, populating only `serviceName` can satisfy Connection details while leaving the Match confidence service anchor unpopulated (see [topology-readiness.md](../../report-standard/topology-readiness.md)'s internal note on this pattern). For that raw-path extraction, a literal `service` or `service_name` anchor may be needed. Inspect which extractor and fields the actual export uses; do not generalize this rule to every live key extraction or rewrite connections without the owning workflow. State which fields the export carries versus which the schema requires when a connection stalls at partial.

## Phase 8: Score, write, brief

Score per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md): each check yields `pass` (1.0), `partial` (0.5), or `fail` (0). `blocked` is unassessed and leaves the readiness denominator; `not-in-scope` leaves both readiness and assessment-coverage denominators. Category score is the assessed-credit ratio times 100 rounded down; overall is the weight-normalized sum over categories with at least one assessed check. Show assessment coverage separately. A fully blocked run is `unassessed` with `overall: null`, never 0/100. Score conservatively: when unsure between a defect and missing evidence, use `blocked` and state the exact evidence-unlock action. Assign each category a maturity value (`reactive`, `proactive`, `systematic`). `DDOPT-*` Cost & Resource Optimization findings carry `points_recoverable: 0` always and never enter this arithmetic.

| Category | Weight | ID range |
| --- | ---: | --- |
| Monitor delivery | 30 | DD-001 to DD-008 |
| Monitor noise | 25 | DD-010 to DD-019, DD-039 |
| Muting and downtime | 20 | DD-020 to DD-023 |
| Coverage and staleness | 25 | DD-030 to DD-038 |

The three checks added on the v0.1.134 depth pass fold into existing categories (DD-005 into Monitor delivery, DD-016/DD-017 into Monitor noise), so the weights are unchanged and still sum to 100. Their load-bearing mechanisms are **live-verified read-only** against a real Datadog org on the `us5` site, matching [references/datadog-checks.md](references/datadog-checks.md) sections 5.1 and 6.1: DD-005's `priority` field was observed present and `null` on real monitors (exactly the untiered case it flags); DD-016's configuration handle→monitor concentration map and DD-017's `overall_state` stuck-state read (observed both `OK` and real `Alert` states on live monitors) both run on the real monitor objects, with no dependence on any unverified vendor string. The *vendor `quality_issues[]` corroboration* layer DD-016/DD-017 add is now **confirmed live** — the real members are `broken_at_handle`, `missing_at_handle`, `alerted_too_long` (the real "stuck/alerting-too-long" member — the earlier `high-alert-volume`/`stuck` guesses were wrong and matched nothing), and `muted_duration_over_sixty_days`, carried on 36/38 monitors of a real org — while the concentration and current-state computations supply review candidates. A scored DD-016/DD-017 defect requires the evidence specified in the current catalog; historical observations do not establish current impact.

The ten alert-hygiene checks added on this depth pass (DD-006 to DD-008, DD-018/DD-019, DD-023, DD-035 to DD-038) fold into the same four existing categories on the same denominators, so the weights are unchanged and still sum to 100. Every one of them is **live-verified (read-only)** against a real Datadog org, matching [references/datadog-checks.md](references/datadog-checks.md) sections 5.2, 6.2, 7.1, and 8.2: DD-006's `sources=alert`/`source:alert` event counts and DD-007's placeholder-handle, placeholder-query, and `$`-tag detections all ran against real captured monitor objects (the org's own quality corroboration was not needed for either — both are self-contained joins over this run's own pull); DD-018 ratio candidates and low-threshold DD-019 candidates matched observed queries; a match alone did not prove a tautology; DD-023's downtime-decay check matched a real active, open-ended, aged, test-worded downtime; DD-035's tag-vs-query join ran against a real monitor where the two agreed (proving the join reports nothing when there is nothing to report); DD-036 found overlapping normalized expressions, without proving unintended duplication; DD-037 found older No Data/null-transition snapshots, without proving absent evaluations; DD-038 found two real paused Synthetic tests still backing monitors with no legacy per-monitor mute (effective downtime suppression is a separate check). None of the ten depends on an unverified vendor string.

The full check catalog and the target profile (what 100 means per category) are at the top of [references/datadog-checks.md](references/datadog-checks.md). IDs are stable: the same defect gets the same ID every run, one finding per failed check, affected objects enumerated. Compute `points_recoverable` per finding by re-running the scoring model with that check at full credit; `info` findings and excluded categories carry 0. The executive summary states the gap to target and the two or three findings with the highest `points_recoverable` as the biggest levers.

Source-assessment gate: describe the source checks as complete only when assessment coverage is 100%, every critical service passes every applicable coverage row, and no category was excluded. Set `end_to_end: false` for a source-only audit even at 100/100. Human delivery requires separate destination and received-page proof. The Cost & Resource Optimization section never affects this gate either way.

Lifecycle, exemptions, and totals, before rendering the report:

1. Load the previous run's `findings.json` when one exists; classify every finding, `DD-*` and `DDOPT-*` alike, per the lifecycle table in the [findings schema](../../report-standard/findings-schema.md) (`new`, `unchanged`, `regressed`; resolved IDs go to the delta, and the executive summary names regressions first).
2. Load `./scoutflo-audits/exemptions.yaml` when present. Entries with `id`, `reason`, and `expires` all set and unexpired suppress their finding into the Suppressed appendix; malformed or expired entries are reported, never honored. For a readiness finding, retain the observed `partial` or `fail` result on the same-ID `checks[]` row and add `suppressed: true` plus `suppression_reason`; set the finding's `points_recoverable` to 0. Suppressed readiness checks remain assessed for coverage but are excluded from readiness scoring. A non-scored `DDOPT-*` finding has no check row: set only its lifecycle to `suppressed`, preserve `scoring_scope: "non-scored"`, and keep zero readiness points.
3. Every findings area and coverage cell carries its denominator (`passed/total`).
4. Emit one `checks[]` row for every stable `DD-*` readiness catalog check, including passes, partials, failures, blockers, and not-in-scope checks. Derive category counts, readiness, assessment coverage, and `score.check_set` from that complete ledger; never write them independently. `DDOPT-*` findings stay outside the readiness ledger and explicitly carry `scoring_scope: "non-scored"`. Every `not-in-scope` row additionally carries `not_in_scope_reason` — one of `inapplicable` (nothing of the kind exists on this target), `target-gone` (proven decommissioned), `by-design` (you declared it) or `covered-elsewhere` (verified on the plane that owns it) — per [not-in-scope-reasons.md](../../report-standard/not-in-scope-reasons.md). A row you cannot evidence is `blocked`, not `not-in-scope`.
5. Every finding declares `scoring_scope` (`readiness` for a same-ID non-pass `DD-*` check; `non-scored` for `DDOPT-*`) and `report_lanes`: `general-audit`, `ai-sre-readiness`, or both. Default to `general-audit` (operational reliability); add or also use `ai-sre-readiness` only when the evidence bears on telemetry quality, service identity/naming, topology/ownership context, incident routing evidence, RCA trust, or action safety — what trustworthy AI-assisted diagnosis needs. A coverage/naming/routing-evidence finding is typically both; a pure reliability/cost/security-posture finding is `general-audit` only. This classification never changes severity or score.

Emit and verify:

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/datadog-context.sh"
mkdir -p "$OUT"
dd_require collection.json
sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/assessment-worklist.sh" check
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
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-correlation-evidence.sh" "$OUT/findings.json"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-correlation-evidence.sh" "$OUT/inventory.json"
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

Compute the delta against the most recent earlier date (never the same-day report). The history recipe resolves prior readiness findings only when the current same-ID check passes. Disappearance from partial scope or a missing cost finding is not proof of resolution; record such unknowns in the delta. It replaces the same-date history line:

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/datadog-context.sh"
sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/history.sh"
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

When context is available, apply it per [BUSINESS-CONTEXT-INTEGRATION-v0168.md](../../docs/BUSINESS-CONTEXT-INTEGRATION-v0168.md): **exclude** resources matched by an exclusion (record them `not-in-scope` with `not_in_scope_reason: "by-design"` (the exclusion is your declaration) and the exclusion as the `reason`, never a fail); **escalate** findings on a `critical_dependencies` service; reduce severity for a gap that exists only in a non-production `environment`; and apply `cost_sensitivity` to ordering. With no context, run neutral defaults and say so — never invent a business rule.

## Remediation pointers

No `setup-datadog` ships yet, so every finding's `remediation` field names the concrete manual fix location. When a setup skill lands, these become anchors without the finding IDs changing:

| Finding area | Fix location today |
| --- | --- |
| Monitors with no target or a dead handle (DD-001, DD-002) | Monitor's Notify section — add or repair the `@handle`; fix the Slack/webhook/PagerDuty integration it points at |
| Draft monitors (DD-003) | Monitor edit — publish the draft or delete it |
| Un-prioritized critical-service monitors (DD-005) | Monitor edit — set a `priority` (P1-P5) so the receiver can tier a real page above a warning |
| No measured alert-event volume (DD-006) | Reconcile the observation window, event collection limits and applicable notification policy. A separately approved controlled breach can verify the source event, destination delivery and recipient receipt independently; a missing event alone does not prove a broken notification path. |
| Placeholder or template artifacts left un-filled (DD-007) | Monitor edit — replace the placeholder `@handle`, fill in the real APM operation name in the query, or replace the literal `$service`/`$env` tag value with the real one |
| Over-broad `@all`/`@everyone` (DD-008) | Monitor's Notify section — replace the broadcast handle with the owning team's handle, or confirm the breadth is deliberate and record why |
| Missing recovery/no-data/renotify/auto-resolve/full-window (DD-010 to DD-014, DD-039) | Monitor edit > Advanced options — set recovery thresholds, no-data handling, renotify caps, and "require a full window" for dense metrics |
| Receiver noise concentration (DD-016) | Split the noisy monitors onto a separate ticket/low-urgency route, or tune them (recovery threshold, renotify cap), so the real page is not buried on the shared handle |
| Current Alert state needing review (DD-017) | Reconcile state history, query results and operational intent first. Change a query or threshold only when evidence proves it prevents required recovery; a current state snapshot cannot establish continuous duration or an inability to re-page. |
| Ratio with no volume floor (DD-018) | Monitor edit — add a composite `AND` clause requiring a minimum denominator (hit/request count) alongside the ratio |
| Evidenced tautological threshold (DD-019) | Confirm the entire expression's domain and intended behavior, then set a threshold it can recover past. Missing domain evidence stays blocked; a low threshold or current Alert state alone does not authorize removal. |
| Vendor quality issues (DD-015) | Datadog's own Monitor quality view lists each issue with its fix |
| Indefinite mutes and broad downtimes (DD-020 to DD-022) | Monitor > unmute, or Downtimes list — scope and time-bound the downtime |
| Downtime intent decay (DD-023) | Downtimes list — cancel the downtime now, or replace it with a properly scoped, time-bound one if the suppression is still needed |
| Stale, composite-broken, untagged monitors (DD-030, DD-031, DD-034) | Monitor edit — retire stale monitors, repair composite references, add service/team tags |
| SLOs without a monitor (DD-032) | SLO edit — attach or create a burn-rate/error-budget monitor |
| Tag-vs-query scope mismatch (DD-035) | Monitor edit — set the tag to match the value the query scope actually evaluates against |
| Overlapping queries (DD-036) | Confirm tier/window/receiver intent first; retain deliberate tiers. Retire or reconcile only an evidenced unintended duplicate |
| No Data with unavailable transition history (DD-037) | Inspect query results/evaluation history against the expected signal cadence; repair ingestion or query only when that evidence proves the gap |
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
| Dead-handle check asserted on plain email handles | Resolve integration handles where a current read proves the destination; `@victorops-` / `@splunk-oncall-` references and email stay unverified without independent mapping |
| Datadog's own quality_issues ignored | Read `monitor/search` quality_issues; report vendor flags alongside findings, name disagreements |
| Cost section scored into the number | DDOPT findings are non-scored, `points_recoverable: 0`, excluded when the probe is skipped |
| Cost savings invented | Only quote a dollar figure Datadog's usage endpoint computed; presence facts carry no estimate |
| App key created under a personal login | App keys die with their user; create the audit key under a service account |
| Monitor message with a secret written to evidence | Capture IDs, names, options, tags; never a raw message body carrying a secret |
| A placeholder handle counted as real coverage | `test("@")` alone is not liveness; DD-007 flags `@your-team-handle`-shaped, `__..._placeholder__`, and literal `$service`/`$env` template artifacts even when DD-001 sees an `@` and passes |
| A ratio monitor's threshold judged on the percentage alone | DD-018 checks for a volume floor on the denominator, not just the ratio's threshold; a scary-looking percentage on a tiny sample is not the same defect as one on real traffic |
| A current Alert snapshot (DD-017) treated as continuous alerting or failed notification | Check actual state history and policy evidence. DD-019 needs an independently proved expression domain; do not infer the cause, recommend deletion, or report repeated pages from current state alone. |
| Zero alert events over the window read as "no monitor fires" | Reconcile collection completeness, transition kind and applicable notification policy. Zero observed events alone cannot prove a quiet system or a broken notification path, even when a recent state timestamp exists |
| A stale-looking downtime message trusted at face value | A downtime that says "temporary" is not evidence it stayed temporary; DD-023 checks the age against the intent, not the wording alone |
| A paused Synthetic's monitor read as healthy because `overall_state` is `OK` | `overall_state` reflects the last real evaluation, not the Synthetic's current run status; join `monitor_id` against the Synthetic's own `status` (DD-038) before trusting the state |
