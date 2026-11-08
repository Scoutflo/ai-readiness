---
name: audit-splunk-oncall
description: Read-only scored audit of Splunk On-Call (formerly VictorOps) routing, effective paging, suppression, future coverage, incident response and alert fatigue. Joins paging paths to separately observed alert sources; emits findings.json, inventory.json and reports without sending a page. Use when you say "audit VictorOps", "check Splunk On-Call coverage", or ask for VictorOps or Splunk On-Call audits, broken routing keys, escalation coverage or on-call gaps. Use setup-splunk-oncall for changes; use the upstream monitoring audit for alert rules, and do not use this for Splunk Enterprise, Cloud Platform or Observability Cloud.
---

# audit-splunk-oncall

Follow a configured paging path from its routing key to its escalation policy, owning team, rotation or direct user, and currently assigned human. Report what is configured and what was actually observed separately. Two policy targets that resolve to one person are one responder; an API response is not proof of a delivered notification.

This is the Splunk **On-Call** product, historically VictorOps. Its management API is fixed at `https://api.victorops.com`. The incoming alert endpoint at `alert.victorops.com` is a different credential family and has side effects. This audit never calls it. Splunk log search, SPL, dashboards, SIEM and Observability Cloud require their own integration.

Read [the check catalog](references/oncall-checks.md), [the API evidence contract](references/api-contract.md), [provider best practices](references/provider-best-practices.md), [path verification](references/verify-path.md), [effective configuration checks](references/effective-quality.md) and [incident-history analysis](references/history-quality.md) before execution. The small [collection recipe](scripts/collect.sh) implements only the documented read sequence and an allowlisted output projection; interpretation stays in this skill. Do not invent endpoints, follow `_selfUrl`, add speculative fields, or expand the reader into a general API client.

## Doctor gate

Required tools: POSIX shell, curl, jq and Python 3.9+ with IANA timezone data for effective configuration/history interpretation; large-estate worklists also require shasum for private credential-generation binding. Use curl 8.4 or newer so `--max-filesize` also bounds bodies whose length was not advertised. Required config keys: `splunk_oncall.api_id_env`, `splunk_oncall.api_key_env`, `splunk_oncall.team_slug`. The first two name variables, never values. Use the provider's read-only key. `setup_api_key_env` is optional and is never read by this audit.

One connection block identifies one account in one environment. `team_slug` is a known existing team used as an identity anchor, **not** a claim that the API exposes an authenticated organization ID and **not** a team scope filter. A list of labeled `splunk_oncall` connections requires explicit `SCOUTFLO_TARGET`; `/scoutflo:audit-all` enumerates labels and invokes the full flow once per label. The reader uses the shared `report-standard/toolkit-targets.sh` enumerator. Every request resolves that label's own pair. An absent, mismatched or unselected label stops rather than falling back to target zero.

**Fixed — run as written.** Config resolution is `SCOUTFLO_CONFIG`, project-local config, home active-config pointer, then home default. Secret resolution is `SCOUTFLO_ENV_FILE`, project-local store, then `~/.scoutflo/env`. The doctor loads that store in an isolated shell; subsequent reads import only the selected variable names. A token added mid-session is therefore visible without re-exporting it. The caller supplies `CLAUDE_PLUGIN_ROOT` through the plugin runtime.

```bash
set -eu
set +x
(
  SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
  if [ -f "$SCOUTFLO_ENV" ]; then . "$SCOUTFLO_ENV" >/dev/null 2>&1; fi
  sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-splunk-oncall/scripts/collect.sh" --plan
)
```

Expected: one JSON plan with target segment, counts and safe team slugs. The exact team detail must return one complete JSON object whose string `slug` equals the configured anchor. An HTML200, missing field, wrong team, 401, 403, timeout or incomplete body is a failed doctor, never an empty account or a passed credential test. The API's generic401 does not distinguish an invalid key from every permission failure. Fix the named configuration or access problem through `/scoutflo:connect`; do not use the elevated key to make the audit pass.

## Live-safety gate

Before interpreting data, confirm the selected account label and known team anchor with the operator's config. Every call is an explicit GET at the fixed management origin, with `X-VO-Api-Id` and `X-VO-Api-Key`, a 25-second timeout, a 2MiB response bound, no redirects and serial pacing of at least one second. A reader failure emits only a generic reason/status, never a raw provider body. Reads at different times do not form an atomic account snapshot.

**Forbidden:** create, edit, invite, assign, delete, acknowledge, resolve, override, send or test notifications, enable an integration, activate an API or change credentials. Do not test read-only permission by attempting a write. Use a typed MCP read only if it proves the same target, has no side effects and returns equivalent safely projected data; otherwise retain direct HTTP. Never send or accept an arbitrary URL, method or query through the collection recipe.

## Estate sizing and scope checkpoint

The plan counts teams + policies + routing rows before per-team or per-policy reads. Defaults below are examples to tune to the API budget, not customer eligibility limits. The 2MiB bound is a per-response safety bound; exceeding it is **blocked**, never truncated success. These management collections do not expose a proven pagination contract. Do not append guessed `page` or `limit` parameters. If even the census exceeds the bound, stop and establish a documented scoped retrieval path before continuing.

```bash
set -eu
PLAN=$(sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-splunk-oncall/scripts/collect.sh" --plan)
TOTAL=$(printf '%s' "$PLAN" | jq -er '.objects | select(type=="number" and .>=0)')
SMALL_MAX_OBJECTS=50
LARGE_MIN_OBJECTS=501  # default large threshold: TOTAL >= 501
if [ "$TOTAL" -le "$SMALL_MAX_OBJECTS" ]; then
  echo "small path: $TOTAL objects; one complete pass"
elif [ "$TOTAL" -ge "$LARGE_MIN_OBJECTS" ]; then
  . "${CLAUDE_PLUGIN_ROOT}/skills/cli-interactive/lib/cli-interactive.sh"
  . "${CLAUDE_PLUGIN_ROOT}/skills/checkpoint/lib/checkpoint.sh"
  cli_pause_before_audit "$TOTAL"
  cli_prompt_exclude_services
  echo "large path (threshold $LARGE_MIN_OBJECTS): bind selected teams to a durable worklist before deep reads"
else
  echo "medium path: $TOTAL objects; category passes"
fi
```

Use the shared [scope checkpoint](../../report-standard/estate-scope-checkpoint.md). Apply exclusions to the actual team/service join, not merely the printed plan. Small and medium accounts need no batching. Large accounts use the [worklist procedure](references/api-contract.md#large-estates): stable run ID, selected label and anchor binding, one row per selected team, exclusive lock and saved per-team snapshots. A failed read remains pending/blocked; never count it as an empty team. A narrower operator scope must be named in the report, including route targets that leave that scope. Never claim account-wide completeness from one scoped batch.

## Triage fast pass

Follow [triage-mode.md](../../report-standard/triage-mode.md). With `SCOUTFLO_TRIAGE=1`, skip the deep sizing/worklist flow and run the fixed collection block below once for the explicitly selected target. The collector makes five bounded GETs: the anchor twice and three bulk inventories. The fresh-shell collection block also obtains its output target through a four-read plan, so that block makes nine GETs; the earlier preflight adds four, for thirteen through preflight and collection. The separate report-validation recipe makes another four-read plan, so those published phases total seventeen GETs. A confirming census is additional only if an apparent broken reference needs rechecking. It never reads current responders, policy details, membership or rotations and never backgrounds a sweep. Apply any proved critical-service mapping to interpretation; without one, disclose that the bulk routing census has no service-criticality filter.

Assess only SOC-001 and SOC-002 (routing references and ownership). `complete_reads: true` applies only to that census. Detail arrays are deliberately uncollected, never empty-staff evidence. Keep all 18 scored check rows: SOC-003–SOC-007 and SOC-009–SOC-019 are `blocked` with “Deferred by triage; run a full audit”, not `not-in-scope` or pass. Stamp `findings.json` with `scope: "triage"`, show assessment coverage and TRIAGE in both reports, and never issue an all-clear. Omit schedule/current-user inventory claims. Keep full-run history separate in interpretation: a deferred check cannot resolve a prior finding or establish score comparability. Deep selectors and team batches require an explicit full run with `SCOUTFLO_TRIAGE=0`.

## Collect and preserve evidence

**Fixed.** The collector reads the full routing and policy catalogs, supported policy details, team membership, v1 rotation identifiers, v2 rotation rosters and current on-call. Full collection also retains bounded quality reads for selected members, maintenance, transformations, overrides, team admins and the requested future schedule. Each optional read retains its own availability; a denied quality read blocks its dependent check rather than discarding proven core evidence. Triage omits these detail reads. Consult the API contract for query limits and per-read shape guarantees. It asserts collection shapes and identities before projecting. It drops route key values, personal names/contact addresses, raw alerts and provider links before output. Usernames are retained only to identify actual responders and deduplicate them; these operational identifiers remain in local reports.

For small/medium scope, run this in a fresh shell. `SCOUTFLO_RUN_DATE` can pin a previously chosen date across midnight. On an existing completed date folder, archive the complete previous artifact set before regenerating it; do not mix fresh evidence with stale findings. The snapshot is written atomically only on complete success. After a passed doctor, a later collection failure must still produce a v2 unassessed report with affected checks blocked and the safe failure evidence. Do not abort the entire workflow without a report, reuse a stale snapshot as current, or turn missing data into empty arrays.

```bash
set -eu
umask 077
PLAN=$(sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-splunk-oncall/scripts/collect.sh" --plan)
SOC_SEG=$(printf '%s' "$PLAN" | jq -er '.target')
RUN_DATE="${SCOUTFLO_RUN_DATE:-$(date -u +%Y-%m-%d)}"
printf '%s\n' "$RUN_DATE" | LC_ALL=C grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || { echo 'invalid run date'; exit 1; }
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${SOC_SEG}/${RUN_DATE}"
mkdir -p "$OUT"
TMP=$(mktemp "$OUT/.snapshot.XXXXXX")
trap 'rm -f "$TMP"' EXIT HUP INT TERM
sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-splunk-oncall/scripts/collect.sh" > "$TMP"
jq -e --arg target "$SOC_SEG" --arg triage "${SCOUTFLO_TRIAGE:-0}" '.target==$target and .complete_reads==true and .scope==(if $triage=="1" then "triage" else "account" end)' "$TMP" >/dev/null
mv "$TMP" "$OUT/snapshot.json"
echo "Safe management snapshot: $OUT/snapshot.json"
```

Never store a raw routing response even in a temporary file. Route aliases such as `route-1` are **run-local**; do not compare aliases across runs or hash secrets to create persistent IDs. A route remediation resolves the exact key again privately and shows only the approved alias plus target policy slugs. Read [secret-redaction.md](../../report-standard/secret-redaction.md): capture secrets by key/name only. An optional source match happens in memory; the artifact contains the match outcome and source evidence reference, not the key or embedded URL.

Zero teams/policies/routes is a scoped observation, not a healthy paging estate. Record the complete census and block any expected paging coverage for which there is no configured path. An explicitly unused feature may be `not-in-scope` with evidence; access denial, unexpected wrappers and absent fields are always `blocked`.

## Evaluate the paging path

**Judgment, constrained by exact predicates in the catalog.** Build one path record per observed route-policy association. Join by returned slugs, never names or string similarity. Evaluate the earliest actionable cause; list downstream consequences without charging repeatedly for one broken reference. For a scoped run, targets outside the selected teams remain unknown, not missing.

Use the fixed selector recipe in [verify-path.md](references/verify-path.md) to verify a specific policy after a planned repair. It runs fresh read-only collection and emits `verified`, `not-met`, `blocked` or `inapplicable`; none of these results silently authors a finding. For SOC-007 use the versioned [source evidence contract](references/source-evidence.md): the safe source capture and receipt, exact source target/generation, intended On-Call target/policy/team and private route binding must agree. A handle or hostname remains a candidate. Use `--source-records` to compare all selected source keys privately in one fresh management snapshot, then evaluate every path locally. Preserve verified, not-met and blocked path-record counts; never multiply full collection by the monitor count. Legacy key-only evidence remains readable but cannot certify a new source join.

1. **Routing integrity:** each nonempty target policy slug resolves uniquely, and the owning team exists. A dangling route remains a defect in configured routing even when there is no evidence a sender currently uses it; distinguish those consequences.
2. **Escalation and staffing:** preserve the ordered, typed graph, cumulative delays and policy references. Follow only documented supported targets with cycle/depth bounds. Alternative paths can remain available while one target is unsupported; never credit an email/webhook or nested reference as a verified human without its own evidence. Inspect effective personal/global selection and verified contacts; stored personal steps alone do not establish the policy actually used.
3. **Current and future coverage:** reconcile current responders against enrollment, then assess a declared future interval using complete rendered schedules, masks, timezone, overrides and adjacent boundaries. Current staffing does not prove that interval. An unassigned override is not automatically a gap because the original responder may remain assigned. Empty rolls on a direct-user policy are not an unstaffed rotation.
4. **Redundancy:** compare distinct enrolled humans with the operator's explicit requirement. Two paths to one person count once. Preserve an explicit no-redundancy QA requirement; never impose a universal minimum. Missing business intent blocks this assessment without inventing a defect.
5. **Source and operational quality:** establish the source→routing key→policy join from independently verified source evidence. Examine maintenance intent, transformation order, stable entity/recovery identity, useful original incident context, governance and sender continuity. Intentional suppression is not inherently bad; inaccessible hidden controls are not false. Record the earliest demonstrated cause once, with downstream consequences.

For SOC-009–SOC-011, SOC-016 and SOC-018, execute the fixed local selector in [effective-quality.md](references/effective-quality.md) against the saved snapshot. Where the public API cannot reveal effective global policy, selection, matching semantics or rendered intervals, use the recipe's target/definition/time-bound attended evidence. Never manufacture that evidence from a successful GET or a prose assumption. An unsupported/missing shape remains `blocked`; a reported configured state does not prove a delivered page.

## Incident history and fatigue

A full audit includes the [bounded history recipe](references/history-quality.md) for SOC-012–SOC-015 and selected original context for SOC-017. Choose and record an explicit past UTC window with the operator; use their response objectives, paging budget, business hours and staffing model when supplied. No declared objective means measures and recommendations remain useful, while the corresponding normative check is blocked. Do not silently invent a production threshold or extend a chosen cohort.

Run the documented `history.sh` collection command in a fresh shell, selecting an incident from the returned census for optional original-context inspection and an exact team for optional duty logs. Optional selections bind the run; choose a new private state directory if those selections change. Resume the same fixed window until `collection.complete` is true, respecting its one-call-per-minute incident-history budget. A partial run may publish observed rows with missing population evidence explicitly blocked. Run its local `--summarize` validation before interpreting results or handing them to `/scoutflo:alert-fatigue`.

Keep source events, incident episodes, provider lifetime alert totals, assignments, notification attempts and human receipts separate. Report acknowledgement/resolution latency only with transition semantics, sample counts and censored cases. Recurrence ranks are review candidates, not false positives; resolved without acknowledgement is not noise evidence. Exact grouping references do not become canonical application identities. Correlate source trigger/recovery, source grouping and response quality through the catalog's evidence requirements before a scored conclusion. Older unresolved backlog outside a start-window cohort remains unassessed.

Save `oncall-history.json` and its local summary beside this run's findings. Alert-fatigue consumes the same native incident summary in AF-005 without inventing source fires or an AF-003 ratio. Fix source grouping, severity, inhibition, debounce, data continuity or recovery in the owning source setup workflow; fix paging ownership and policy quality here. Avoid charging the same cause again in aggregate reports.

## Inventory, coverage and topology

Keep run-local `route-N` aliases in display evidence and route inventory only, never in a finding's `affected` list. Use observed policy/team/shift identifiers or independently verified service identities there. If no stable impacted object is known, name the explicitly configured audit target and state that object/service impact is unknown; do not invent an identity. Lifecycle finalization rejects aliases in current findings and ignores them in historical resource deltas.

Follow the shared [qualified service evidence contract](../../report-standard/service-evidence.md) when publishing service joins. Set optional `correlation_affected` only to source-verified service labels already in `affected`, and pair each with `correlation_bindings[]` containing that `affected` label, its qualified `service_identity` and `evidence`. A Kubernetes identity needs the observed cluster, namespace and service; a provider resource needs its authoritative provider, account scope and resource ID. Region/environment conflicts block the join. A route-key match alone does not prove this service identity. Never substitute a policy/team slug or local account label. Without that independent proof, preserve the native affected objects and omit the binding: the finding remains useful for remediation but unmappable across targets.

Declare `collection` on findings and inventory with the shared status, target/subset scope, observation time and any incomplete reason. Evidence `target` must equal this artifact's canonical On-Call target; `observed_at` must match its collection generation and `ref` must identify the saved safe supporting read. Preserve the upstream source's own target/time in that supporting evidence; do not re-date an old source capture. Team/triage/capped or unreconciled reads cannot become a target-complete collection. On inventory items with independently proved service associations, add `service_identity` with `identity_evidence` under the same contract. Friendly `covers` and `correlation_affected` alone never establish a cross-target join; missing fields in legacy artifacts remain readable but unmappable.

Emit `scoutflo-inventory/v1` with team, escalation_policy, schedule and route items. Retain policy/team slugs, numeric group/shift identity, supported entry type, and current users needed by the finding. Routes carry safe aliases and policy targets, never raw keys. `routes_to` describes the observed next hop; `covers` contains only service identities established by source evidence. Routes and escalation policies **must not** be labeled `monitor`, `alert_rule` or other coverage-countable kinds. Do not synthesize a monitor from an incident.

Object presence does not establish an `enabled` state. Omit `enabled` when the observed response exposes no activation state; never fill it with `true` merely because an object exists. A schedule's referencing policy is an upstream relation, not its `routes_to` next hop. Use only an observed downstream responder/target there, or omit the field. Run each evidence command against the saved safe snapshot with all jq variables explicitly bound before publishing it; a correct observation does not make an unexecutable command reproducible.

The report uses the shared [six-check topology readiness model](../../report-standard/topology-readiness.md), with the exact headline `<r> of <n> critical services are ready for automatic Scoutflo correlation`. Do not promise that a Splunk On-Call provider schema or platform runtime exists because this plugin ships; platform provider support is independently verified or explicitly pending. Missing topology/source export means correlation context is unavailable, not that zero critical services need coverage. Omit the numeric readiness headline in that case and write “Topology readiness: unassessed — critical-service denominator unknown”; never render 0 of 0 from absent evidence. Apply the [coverage contract](../../docs/CONTRACTS.md#c14--cross-tool-coverage-correlation-a-gap-in-one-tool-covered-by-another) without changing another audit's score.

## Score and render

The 18 scored checks have these categories. Category names must be byte-identical in checks and scorecard. SOC-008 is an optional non-scored incident-lineage observation, never a required network call or readiness credit.

| Category | Weight | Checks |
| --- | ---: | --- |
| Routing integrity | 20 | SOC-001, SOC-002, SOC-011 |
| Escalation and staffing | 25 | SOC-003, SOC-004, SOC-009 |
| Current coverage | 20 | SOC-005, SOC-006, SOC-016 |
| Source correlation | 15 | SOC-007, SOC-014, SOC-017, SOC-019 |
| Operational quality | 20 | SOC-010, SOC-012, SOC-013, SOC-015, SOC-018 |

Never score from object counts.

- ❌ “There are twelve policies, so escalation scores100.”
- ✅ “All four routed policies resolve to verified members; one referenced shift is unstaffed, so SOC-004 is partial and names that shift and its actual dependent paths.”

Target profile: routed policies resolve through effective, eligible responders; declared current/future coverage and redundancy hold; source identity and recovery are consistent; suppression and transformations preserve intended critical paging; response, noise, workload and context meet the operator’s declared objectives; governance and source continuity have evidence. A score of100 is limited to the assessed target, interval and checks. It never certifies unobserved future time or human delivery.

Emit one `checks[]` row for every stable scored SOC-001–SOC-007 and SOC-009–SOC-019 check, with category, result and evidence; every `not-in-scope` row must carry `not_in_scope_reason` from the shared four-value enum. `blocked` excludes unassessed checks from readiness and lowers assessment coverage; `not-in-scope` excludes them from both denominators with a concrete reason. One failed object among fully assessed successful objects is partial; all applicable objects failing is fail; uncertainty is blocked, never partial credit. Do not quietly replace a blocked object with the fraction that was readable.

Use `scoutflo-findings/v2`, `scoring_model: "assessed-only-v1"`, complete `checks[]`, derived `score.check_set`, per-category counts and maturity, reconciled overall, severity histogram and assessment coverage per [the report standard](../../report-standard/README.md), [findings schema](../../report-standard/findings-schema.md) and [scoring rules](../../report-standard/severity-and-scoring.md). A completely unassessed run has null overall. Compute the check-set fingerprint using the shared model, never a manually invented label. `end_to_end` remains false while device delivery, future coverage or any applicable source dependency is unproven, even when management readiness scores highly.

Every partial/fail/blocked scored check has its same-ID finding. Each finding declares `scoring_scope: "readiness"` and `report_lanes`; routing/service-evidence gaps generally belong to both `general-audit` and `ai-sre-readiness`. Optional SOC-008 declares `scoring_scope: "non-scored"`, zero recoverable points and no check row. A finding needs a concrete `affected` resource, evidence, consequence, remediation and done-when verification. A blocked title must say what could not be verified, not assert that the underlying object or source is absent. Multiple policy targets on one route are valid; say each target resolves uniquely, never claim every route has exactly one target. Unproven impact is named as unknown. Never fabricate MTTA, MTTR, notification receipt or an incident history denominator.

Run [lifecycle.md](references/lifecycle.md) in `derive` mode after authoring findings and before rendering. Its fixed recipe computes stable-ID deltas, explicit exemptions and scoring, and validates atomically; run its `history` phase after report validation. Load only prior date-named run folders beneath the resolved target. Compare finding lifecycle by stable check/resource identity even when score models differ; compare score deltas and trends only when `scoring_model` and `check_set` match. Route ordinals cannot establish sameness; use the check ID plus stable policy/team/shift and evidence-supported service identity. Honor only unexpired, well-formed exemptions; suppressed findings retain observed failed/partial checks with suppression reasons, recover zero points and remain assessed. Derive all report views from findings.json, never patch a score in report.md.

Write `findings.json`, `inventory.json`, `report.md` and rendered `report.html` under the resolved `${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/<SOC_SEG>/<date>/`. Include Inventory, Scorecard, Findings by purpose, evidence appendix and the report's required human-first finding shape. Render the deterministic sections with `render-report-viz.sh inventory`, `scorecard` and `lanes`; build HTML with its `html` mode. The final validation recipe is in [the API contract](references/api-contract.md#report-validation). Write one history row per run date under the target's `history.jsonl`; replace only that date on a same-day rerun and preserve other dates. Never mark pending large-path work complete to publish a report.

If Slack delivery was explicitly requested or authorized through the user's invoked report workflow, use the shared brief template, titles/counts only and no raw evidence; otherwise keep the report local. When invoked by `audit-all`, leave delivery to the orchestrator. Finish with score and assessment coverage, top concrete fixes, absolute artifact paths and clearly named unproven paths.


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
elif [ "$HAVE_PER_RESOURCE" -eq 1 ] && [ -n "$BC_SRC" ];             then LOAD_METADATA_MODE="per-resource+ssot-md"
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
elif [ "$BC_SRC" = "$BC_MD" ]; then
  # Read the selected Markdown workspace rules even when a per-resource cache is present.
  ENVIRONMENT="$(grep -iA5 '^## Environment' "$BC_MD" | grep -iE 'Stage:' | head -1 | sed -E 's/.*Stage:\**[[:space:]]*//; s/[][]//g; s/[[:space:]]*$//' | tr 'A-Z' 'a-z')"; [ -n "$ENVIRONMENT" ] || ENVIRONMENT="production"
  COST_SENSITIVITY="$(grep -iA3 '^## Cost Sensitivity' "$BC_MD" | grep -iE 'Primary:' | head -1 | sed -E 's/.*Primary:\**[[:space:]]*//; s/[][]//g; s/[[:space:]]*$//' | tr 'A-Z' 'a-z')"; [ -n "$COST_SENSITIVITY" ] || COST_SENSITIVITY="medium"
  CRITICAL="$(awk '/^## Critical Services/{f=1;next} /^## /{f=0} f' "$BC_MD" | grep -oE '`[^`]+`' | tr -d '`')"
  EXCLUSIONS="$(awk '/^## Exclusions/{f=1;next} /^## /{f=0} f' "$BC_MD" | grep -oE '`[^`]+`' | tr -d '`')"
fi
# When HAVE_PER_RESOURCE=1, look each finding's affected resource up in computed_metadata.jsonl and let
# its per-resource action/escalation/sla refine (never weaken) the workspace rule for that one resource.
```

When context is available, apply it per [BUSINESS-CONTEXT-INTEGRATION-v0168.md](../../docs/BUSINESS-CONTEXT-INTEGRATION-v0168.md): **exclude** resources matched by an exclusion (record them `not-in-scope` with `not_in_scope_reason: "by-design"` (the exclusion is your explicit declaration) and the exclusion as the `reason`, never a fail); **escalate** findings on a `critical_dependencies` service; reduce severity for a gap that exists only in a non-production `environment`; and apply `cost_sensitivity` to ordering. With no context, run neutral defaults and say so — never invent a business rule.


## Remediation pointers

Use `/scoutflo:setup-splunk-oncall` for a reviewed change through its guarded API recipes or attended provider editor workflows. Missing staffing maps to its rotations/shifts and team membership workflow; invalid escalation references map to its policy workflow; route creation/repair follows its routing-specific proof boundary. A suggestion is not permission to execute it. The audit never loads the elevated key or repairs its own findings.

### Clarify responder requirement

When SOC-006 is blocked because no minimum was declared, use the exact remediation pointer `audit-splunk-oncall#clarify-responder-requirement`. Ask for the intended policy set and minimum distinct responders, or an explicit declaration that no redundancy requirement applies. Record its provenance, then rerun the SOC-006 selector in [verify-path.md](references/verify-path.md). Do not change membership to satisfy an invented minimum.

### Supply source evidence

When SOC-007 is blocked because source evidence is missing, use the exact remediation pointer `audit-splunk-oncall#supply-source-evidence`. Obtain the source owner’s current, verified metadata and exact private routing-key variable through the source’s read-only audit; follow the [source evidence contract](references/verify-path.md#source-side-evidence-for-soc-007), then rerun the join. Do not infer a key from a receiver name. Other failed/partial findings follow their catalog’s existing setup/doc link; never invent an anchor from a finding ID such as `#SOC-006`.

## Common Failure Modes

| Symptom | Meaning and next step |
| --- | --- |
| HTML200 or a redirect | Wrong surface/proxy behavior; fail the probe, keep credentials on the fixed management origin |
| Generic401 | Missing, invalid or denied credential; establish the cause without a trial write |
| Collection is empty | Only that collection shape is known; missing item fields have not been validated |
| Several policies but one responder | Deduplicate usernames before comparing with the declared requirement |
| Unstaffed shift still has periods | Time blocks are not assigned people; inspect actual roster/current users |
| Unknown entry type, missing oncallNow or wrong casing | Block the dependent check and record schema drift; never default to an empty success |
| 429, timeout, body cap or interrupted batch | Preserve completed safe evidence, leave affected work blocked/pending, no automatic burst retry |
| API GET contains routingKey/apiKey/raw | Do not log the body; use the allowlist projection, and avoid alert detail unless separately necessary |
| A resolved incident's source is still firing | Provider cleanup is not source recovery; preserve both states |
| Policy or roster changed mid-run | Evidence is sequential; re-read the affected join before a verdict |
| Known source has no exact key mapping | Report correlation unavailable; do not infer an identifier transformation |
