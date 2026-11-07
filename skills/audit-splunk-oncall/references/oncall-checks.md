# Splunk On-Call check catalog

Read the parent skill's target profile, scope and scoring rules first. The data source is the complete, safely projected management snapshot described in [api-contract.md](api-contract.md). Endpoint success, observed field type, proven relationship and actual notification delivery are different evidence classes. This catalog never treats a successful read as all four.

The quality checks additionally use [effective-quality.md](effective-quality.md), [history-quality.md](history-quality.md) and separately observed source evidence. [Provider best practices](provider-best-practices.md) explains the current official semantics. Apply the declared service objectives and accepted exceptions; vendor examples and another organization's staffing model are not your requirements.

| ID | Category | Check and concrete failure mode |
| --- | --- | --- |
| SOC-001 | Routing integrity | A configured routing key targets no policy or a policy that cannot resolve; an incoming event on that route lacks the intended escalation path |
| SOC-002 | Routing integrity | A routed policy's owning team is absent or ambiguous in complete account inventory; ownership and remediation cannot resolve reliably |
| SOC-003 | Escalation and staffing | A routed policy has no effective entries or references a missing supported user/rotation; escalation stops before an eligible target |
| SOC-004 | Escalation and staffing | A referenced rotation's shifts have no eligible enrolled members; configured time periods cannot produce a staffed response |
| SOC-005 | Current coverage | A supported routed policy has no eligible current responder at observation time, after a confirming read |
| SOC-006 | Current coverage | An explicitly required independent responder count is unmet after deduplicating actual enrolled people |
| SOC-007 | Source correlation | A known in-scope alert source's exact routing key does not join to its intended policy/team/current response path |
| SOC-008 | Incident lineage | Optional non-scored observation: a selected incident's original alert, nested policy/team and actual triggered-user evidence support or contradict the intended route |
| SOC-009 | Escalation and staffing | The effective personal/global paging policy has no required viable contact path or exceeds a declared notification objective |
| SOC-010 | Operational quality | Active maintenance or suppression conflicts with required coverage or its declared end/ownership procedure |
| SOC-011 | Routing integrity | Ordered alert transformations misroute, unexpectedly suppress or overwrite intended event identity/context |
| SOC-012 | Operational quality | Incident acknowledgement or unresolved age exceeds an explicitly declared response objective |
| SOC-013 | Operational quality | Measured incident recurrence exceeds a declared noise budget or proves a repeated unnecessary notification mechanism |
| SOC-014 | Source correlation | Observed trigger/recovery identities diverge or unrelated failures are demonstrably merged |
| SOC-015 | Operational quality | Observed incident assignments/duty burden violate the declared workload or off-hours policy |
| SOC-016 | Current coverage | The requested future interval has a proved uncovered period or an unresolved intended override |
| SOC-017 | Source correlation | An incident lacks required service/environment/ownership/diagnostic context for safe response and investigation |
| SOC-018 | Operational quality | A supported lifecycle or governance requirement is violated by a proved stale, dangling or unowned dependency |
| SOC-019 | Source correlation | A required source-to-response path has stale/broken delivery evidence or a known critical source lacks the intended destination |

Use the executable [per-policy verification selectors](verify-path.md), [effective-quality assessment](effective-quality.md) and [history-quality assessment](history-quality.md). Re-run after a repair; a stale saved snapshot does not verify a current change. SOC-001–SOC-007 and SOC-009–SOC-019 each produce one check ledger row: eighteen scored checks. SOC-008 is an optional non-scored observation and is omitted when no relevant evidence exists. A finding aggregates affected objects for one check, preserving per-object evidence and denominators. New check coverage changes the check-set fingerprint; do not compare its score as if it were the previous seven-check assessment.

## Scope and completeness before scoring

The fixed collection recipe uses a known team as the account anchor and explicit selected credentials. A complete account census includes teams, routing targets and global policy ownership. Detail reads must succeed for every evaluated object. An explicit team batch records its selected scope and retains `out_of_scope_policies` for fanout routes. Those targets are unknown in that batch, not dangling. Cross-batch aggregation deduplicates routes by their observed policy relationships and private in-memory identity; a regenerated ordinal alone is never an identity key.

A200 empty collection establishes absence only in that collection. It does not validate item fields, prove permission to all other endpoints or mean paging is unnecessary. If the operator expects paging, no configured route blocks the expected-path checks with the observed empty census. An intentional account without paging can mark the affected checks not-in-scope with its explicit purpose. Unknown/denied/partial data always blocks dependent checks.

Do not double-charge a cascade: if SOC-001 identifies a missing policy, SOC-003 through SOC-005 cannot assess that missing policy's internals. They remain blocked for that path with the root cause reference. They may assess other complete paths, but a check with any unknown applicable path remains blocked rather than silently scoring the readable subset.

## SOC-001 — routing key to policy

Use a directly observed target policy slug in `affected`, including an unresolved reference when that is the defect. Keep the route's ordinal alias in evidence only. When no stable impacted object is established, use the explicitly named audited target scope with unknown object/service impact; a secret-derived ID or a guessed team is not a substitute.

**Inputs:** `routes[].alias`, `routes[].policies`, `routes[].out_of_scope_policies` when scoped, and `policies[].slug`. The collector reads `routingKeys[].targets[].policySlug` and drops `routingKey` before persistence.

For each in-scope route, require a nonempty policy target set and exactly one global policy row per target slug. A complete-account absent slug is a configured broken reference. Re-read the route and policy collections before reporting it, because deletion/creation may have occurred between reads. A denied or schema-invalid collection is blocked. An out-of-scope target is blocked in a scoped batch. Duplicate policy rows are ambiguous, never collapsed into a passed join.

- **Pass:** every applicable route's target set resolves uniquely.
- **Partial:** some fully assessed routes resolve and some do not.
- **Fail:** none of the applicable configured routes has a valid target set.
- **Impact:** count the affected route-policy paths; name services only with independently proved source mappings. Without source evidence, say “configured route is broken; active sender usage unknown.”
- **Fix:** select the exact key privately, review its complete target set and acknowledgment behavior in the [setup routing workflow](../../setup-splunk-oncall/SKILL.md#routing-keys). Never rewrite the default route automatically or treat absent `isMultiResponder` as false.
- **Done when:** fresh routing inventory matches the approved target set, every target resolves uniquely, and unrelated/default route mappings are unchanged. Restoring only a key string is not a full rollback.

## SOC-002 — policy ownership

**Inputs:** global `policies[].slug` and `.team`, joined to `teams[].slug`. Policy detail does not carry the owning-team join. The team-policy list has a different response shape and must not substitute for the global wrapper without its own parser.

Assess only policies referenced by selected routes. Require exactly one owner mapping and one real team. If the team disappeared, re-read global policy and team inventories. A complete, repeated absent owner is a broken ownership reference;403 is unknown, not absence. Do not infer ownership from policy names, routing key text or URLs.

Pass/partial/fail follow all/some/none of the fully assessed referenced policies resolving. `affected` includes the concrete policy slug and known team slug, with actual dependent services only when mapped. Repair through the [setup policy workflow](../../setup-splunk-oncall/SKILL.md#escalation-policies) after reading current consumers. Verify the global ownership join again; a successful team rename does not repair a foreign-key problem.

## SOC-003 — supported escalation targets resolve

**Inputs:** `policy_details[].steps[].entries[]`, membership, rotation identifiers and nested policy references. `type` is projected from `executionType`. Use the typed projection and fixed evaluator in [effective-quality.md](effective-quality.md); a target's private email/webhook payload is never required to retain its type and dependency uncertainty.

Require at least one step with at least one understood eligible target. Resolve user identities against the owning team's complete verified membership; a pending invitation is not eligible merely because its email resembles an existing user. Resolve a rotation slug to exactly one v1 group whose `teamSlug` matches the owner, then to its numeric v2 group ID. Numeric IDs and slugs are different identifier families.

Trace every ordered step and nested dependency with cycle protection and a bounded traversal. Documented step timeouts are minutes relative to the previous step; entries in one step run together. A nonzero delay or a second step is not itself unsupported or unhealthy. Sum configured delays only where their semantics are established, including the invocation offset of a nested policy. A step with no current person does not eliminate the following delay. Compare timing to an explicitly declared response objective; an intentional waiting-room delay can be correct.

Unknown execution type, missing typed identifier, unproved next/previous assignment, unresolved dependency outside the selected scope or ambiguous ID join blocks that path. A repeated node on the active recursion path is a cycle, not an additional responder; a reused non-cyclic policy may be valid. A supported target proven missing in complete reads is a failure. Preserve a staffed alternative in the explanation without silently ignoring the broken branch. Email/webhook actions are not automatically enrolled humans. Configured delay is not measured notification latency. Effective personal/global policy assessment belongs to SOC-009 and receipt requires separate evidence.

Name the exact policy and failed target; count affected route-policy paths. Repair an escalation entry through the [setup policy workflow](../../setup-splunk-oncall/SKILL.md#escalation-policies) with full replacement semantics, existing personal-paging behavior and all consumers reviewed. Done when a fresh policy detail matches the intended entries and their referenced user/rotation identities resolve. Do not delete a policy to repair it: deletion may remove routing keys that target only that policy.

## SOC-004 — referenced rotation has eligible staff

**Inputs:** v1 `rotationGroups[].slug/groupId/teamSlug`, v2 `rotations[].groupId`, shifts' `shiftId`, `shifttype`, `members` projected from `shiftMembers[].username`, and team `members[].verified` boolean.

Only judge rotations referenced by a routed, otherwise resolvable policy. A deliberately unused empty rotation is an inventory observation, not an active paging outage. For each referenced rotation, resolve every relevant shift roster and require enrolled team members. `std` and `pho` have observed types; unfamiliar modes block schedule interpretation. Do not derive staffing from `periods`, current/next time objects, a total count or an empty scheduled-user response.

An empty roster proven by complete data means no assigned person in that shift. Which effective paging windows it affects is a separate schedule semantic; absent that proof, phrase the finding as an unstaffed configured shift, not a fabricated week-long outage. A policy with a staffed alternate path must be described accurately. Re-read at current boundaries before escalating severity.

The [rotations and shifts workflow](../../setup-splunk-oncall/SKILL.md#rotations-and-shifts) identifies the exact rotation group and shift and the intended eligible members. The setup recipe requires verified existing team membership before adding a shift member, preventing an implicit membership side effect. Done when the roster readback matches the approved users, eligibility is verified and the effective current assignment agrees. Future continuity/DST and notification delivery remain separate tests.

## SOC-005 — current assigned responder

**Inputs:** current `teamsOnCall[].oncallNow[].escalationPolicy.slug`, nested `users[].onCalluser.username`, the ownership join and verified membership. The uppercase `onCallUser` used in schedule APIs is not accepted as a guessed alias in the current endpoint.

For each supported routed policy, require one unambiguous current policy row for the correct owning team and at least one eligible username. Cross-check supported rotation roster/current assignment where applicable. A current user outside the selected roster may reflect an override; do not automatically fail the user as invalid. Establish the override or block the discrepancy. The audit never changes an override to simplify its evidence.

If no current person is reported, repeat the relevant current/roster reads after at least one second and record both observation times. Repeated complete empty current data with an expected active supported path is a gap at those times. A refused read, unknown override or unsupported target is blocked. One current person says nothing about tomorrow, repeated escalation or mobile receipt.

Plan the exact policy/shift/eligible assignment through the [escalation policy workflow](../../setup-splunk-oncall/SKILL.md#escalation-policies) and [rotation workflow](../../setup-splunk-oncall/SKILL.md#rotations-and-shifts). Done when fresh current data returns the intended eligible user for the same policy/team and the supporting roster or approved override resolves. Do not send a test page from this audit.

## SOC-006 — declared independent responders

**Inputs:** an explicit operator/business-context requirement and the unique enrolled usernames in the actual current response paths. Policy count, route fanout count, roster size and invited users are not independent responders.

If the operator explicitly declares that no redundancy requirement applies, first record that policy-scoped declaration in the business-context SSOT and its `resource_intent` projection. Only that captured, attributable intent permits not-in-scope (`by-design`, citing the source and affected policy set). An uncaptured conversation or verification selector returning `inapplicable` does not authorize this scored verdict; keep it blocked until provenance is recorded. An unspecified requirement is blocked pending target-profile clarification, never a failed universal two-person rule. If the requirement exists but supported current joins are incomplete, block. When complete, deduplicate usernames across the required policies and compare with the declared minimum; do not add different users who would only appear at unsupported later steps.

Name the required count, observed distinct count, shared user and affected policies. Severity follows the explicitly critical service/coverage need, not the word “production” alone. Plan a genuinely independent eligible path through the [team membership workflow](../../setup-splunk-oncall/SKILL.md#teams-and-membership), with the user's approval for membership/contact effects. Done when the supported current join contains the required distinct people. Actual independent device delivery is still unverified.

## SOC-007 — source to response-path join

An exact routing-key join does not itself prove a service identity. When independent source evidence also proves that identity, retain its display label in `affected` and the optional `correlation_affected` subset, then add the qualified `correlation_bindings` and collection/evidence generation fields required by [the shared service evidence contract](../../../report-standard/service-evidence.md). Cite the saved source mapping with its original source target/time. Native policy/team slugs, route aliases, friendly names and a reused local target label cannot replace cluster/namespace or authoritative provider account/resource proof. Missing identity, conflicting scope or an incomplete binding remains unmappable; it never removes the local paging finding or changes its score.

**Inputs:** a source-side audit's current evidence for a concrete alert/monitor, an explicit expected team/policy or service mapping, and an exact routing-key comparison performed only in memory. Use the [bound source evidence contract](source-evidence.md), which verifies the source target, capture receipt and file generation, selected On-Call target and credential generation, intended policy/team and protected route value. Management reads alone supply none of these source-side facts. Batch all selected path records against one fresh management snapshot and retain missing mappings, candidate handles and unresolved receivers in the blocked denominator. Source-path counts are not unique-monitor or incident counts.

If there is an expected source but the key/evidence is unavailable, block with that dependency. If the operator explicitly declares no sender integration in scope, capture the declaration in the business-context SSOT and its `resource_intent` projection before using not-in-scope (`by-design`); cite that source and scope. Do not treat missing evidence as by-design. A complete exact match to the expected valid response path passes the configuration join; mismatch or an observed missing key fails it. This is configuration correlation, not proof an event fired or reached a device.

Keep safe source evidence IDs, check times, expected/actual policy and team slugs, boolean exact-key match, and concrete affected service IDs. Do not persist the key, inbound URL, raw monitor configuration or unkeyed secret-derived hash. Private generation bindings use keyed HMACs only, under the source-evidence contract. Never assume a `victorops` contact-point type or `@` handle can be transformed into a key. A generic receiver type proves only its type.

Repair source routing through the source's owning setup workflow and policy/routing configuration through [setup-splunk-oncall](../../setup-splunk-oncall/SKILL.md#incoming-alert-sources). Avoid assigning monitoring-rule ownership to this paging audit. Done when fresh source and management reads establish the exact expected configuration join. An optional separately authorized delivery test can add evidence, but cannot run inside the audit.

## SOC-008 — optional incident lineage, non-scored

Use already authorized, safely projected evidence when investigating a selected real incident. The selected-context read in [history-quality.md](history-quality.md) can obtain the original alert relationship with a bounded GET; use its projection, never a raw alert body. Do not collect every alert “for completeness.”

Observed incident `pagedPolicies[]` nests `policy` and `team`; `incidentNumber` is a string. The originally triggered `pagedUsers` may disappear after acknowledgment/resolution. Keep the original alert relationship and trigger-time evidence rather than using a later empty array to conclude nobody was paged. The latest event may be a recovery event and is not necessarily the original source.

One incident can establish a selected source/policy/recipient lineage. It cannot prove MTTA/MTTR population statistics, missed-event rates, recurrence behavior, populated history pagination or actual phone/email receipt. Alert timestamp strings require proven units/value semantics before conversion. Provider-side resolution while the source remains firing is explicit cleanup, not source recovery. Record these limits beside the observation, with zero readiness credit.

## SOC-009 — effective notification path

Join each eligible routed person to the selected personal policy and referenced contact method, then account for the current global-policy enforcement state. A registered email or phone not used by that policy is not a notification path. Preserve the distinct string/boolean verification types observed by the contact and membership APIs; do not use string truthiness. Policy time masks, rank, step timeout and terminal action change which notification occurs. `ignoreCustomPagingPolicies` is not an organization-wide global enforcement flag.

A missing `ignoreCustomPagingPolicies` is unknown, never false. When custom policies are enabled, obtain fresh `personal_selection` attended proof even for a singleton policy list; rank, mask and list length do not establish actual selection. Pass only for a fully explained effective path satisfying your declared channel/timing requirement. A supported missing/unverified required contact or excessive configured delay is a failure; unsupported custom/global precedence, stale attended proof or denied contact reads are blocked. No required channel means do not invent voice/SMS redundancy. Count affected policies and distinct people, not contact rows. Configuration proof is separate from human receipt.

Repair through [notification policies](../../setup-splunk-oncall/SKILL.md#personal-paging-and-contact-methods). Show affected users and whether the change is global; re-read actual effective policies after propagation. A first global policy automatically enables enforcement, so it is not a harmless isolated fixture. Done when the exact approved contact/order/time rules are effective, the existing reachable path is preserved and the fresh assessment passes. Any device-receipt claim still needs a separately authorized test and recipient evidence.

## SOC-010 — effective suppression and maintenance

Read every active maintenance instance, its `isGlobal` flag, route targets and the documented empty-target global meaning. Match route identities in memory. Include relevant ordered INFO/suppression rules and overlapping instances. A false global flag does not establish that your route is unmuted. Record affected route-policy paths and source-proven services; do not expose the route values.

An active mode conflicts with readiness when it contradicts required service coverage or exceeds a recorded intended end. Missing documented ownership/end procedure is an operational requirement gap only when that requirement applies. An intentionally bounded maintenance period is not a defect. Unknown scope or intended coverage is blocked with its exact missing input. Mode age alone does not prove a forgotten mute. Existing incident pages may continue during maintenance; ending it can release pending incidents and need not end another overlapping mode.

Use [maintenance mode](../../setup-splunk-oncall/SKILL.md#overrides-maintenance-and-alert-rules) to narrow/end the exact mode after reviewing pending incidents and overlaps. Done when the selected route's effective suppression agrees with the approved intent and unrelated modes/routes remain unchanged. Never create global maintenance as an audit test or end all modes as a generic fix.

## SOC-011 — ordered transformations preserve intent

Use the complete ordered rule list and its response-specific field names, including rank, stop flag, route condition and annotations. The source's initial route is not necessarily the final route after transformations. Global rules precede route-specific matching; changed fields can affect subsequent rules. A valid regex is not necessarily the intended regex, and another runtime's regex engine is not evidence of Java-equivalent evaluation.

Assess exact source-positive and non-matching examples against a declared routing/severity/identity intent. A proved rewrite to the wrong policy, unintended INFO conversion, identity collision or overwritten necessary context is a failure. Unknown condition semantics or incomplete rule/order evidence is blocked; an empty complete rule list is not a missing-feature defect when source payloads already meet the requirement. Mere rule count has no score value. If SOC-014 owns an observed identity defect, reference it without charging the same defect again as an independent transformation failure.

Use [alert transformations](../../setup-splunk-oncall/SKILL.md#overrides-maintenance-and-alert-rules) for a narrow change. Preserve the entire affected rule order because inserting a rank shifts later rules. Done when positive and adverse/non-matching examples yield the intended route, severity and identity, plus unrelated rules remain unchanged. Do not repair a route by adding a catch-all suppression rule.

## SOC-012 — acknowledgement and unresolved-age objectives

Use the bounded reporting cohort and normalized transitions from [history-quality.md](history-quality.md). Report the actual requested start/end/phases, collected count and completeness. Query phase vocabulary and returned phase vocabulary need their own supported mappings. Start-window cohorts, incidents already open at the start, first-ack samples and still-open records are different denominators.

Compare first acknowledgement latency and unresolved age only against a stated policy/service objective. Report means/percentiles with exact eligible sample counts and units; missing acknowledgement or unresolved episodes are censored/unknown, never zero. A complete cohort can show an overdue urgent episode. Without an objective, show the measurements and block the objective verdict. Partial history cannot support an exact account rate or blanket pass; an individually observed overdue incident may still be an evidenced finding with an explicit incomplete-population boundary.

Prioritize the exact incident/policy and evidenced timing, staff or source mechanism. Use [response optimisation](../../setup-splunk-oncall/SKILL.md#response-and-noise-optimisation) to choose the appropriate existing workflow. Do not automatically acknowledge/resolve incidents. Done when a fresh comparable cohort meets the requirement or the precise configured defect is repaired; one quick QA incident cannot establish sustained response improvement. Administrative/timer closure is not source recovery.

## SOC-013 — measured recurrence and noise

Count distinct incidents in a complete window. Keep provider lifetime `alertCount` separate from in-window incident counts and delivered notification attempts. Preserve exact entity/route/source relationships using safe run-local labels when necessary; a repeating entity may be intentional recurrence rather than duplicated paging. Identify the largest measured contributors in native units, with scope and evidence confidence.

A declared incident/page budget breached by the matching measured unit, or a corroborated unnecessary duplicate-notification mechanism, is a scored problem. Without such a requirement or outcome evidence, report recurrence/short-without-ack patterns as review candidates and keep the corresponding health conclusion blocked. Closing quickly, receiving no acknowledgement, or sharing a service name does not prove a false positive, unnecessary interruption or missed incident. Do not compute actionability, precision or recall without the needed independently labeled population.

Use [response optimisation](../../setup-splunk-oncall/SKILL.md#response-and-noise-optimisation). Point to the exact source rule, grouping identity, severity route or repeat policy supported by evidence. Validate both a noisy/repeated case and a legitimate urgent case after a proposed change; delaying everything to lower volume can violate the detection objective. `alert-fatigue` consumes these measurements without charging the same provider defect twice.

## SOC-014 — stable identity and matching recovery

Compare original triggering identity, subsequent updates/retries and the recovery identity through the relevant source and transformations. Missing `entity_id` can cause a generated identity; too-broad identity can merge independent problems. An incident's last alert can be recovery and must not replace its original source identity. The history count alone does not prove which events share a problem.

Fail on a proved mismatch that prevents expected recovery or a demonstrated collision of distinct source/service problems. Block when source identity, original payload projection or lifecycle attribution is unavailable. A repeat update correctly grouped into one unresolved incident is healthy behavior; multiple real incidents over time are not automatically a failure. Recovery in provider state, sender recovery and restored application health are three separate observations.

Repair the originating sender through its owning setup skill, or the precise On-Call transform via [incoming alert sources](../../setup-splunk-oncall/SKILL.md#incoming-alert-sources). Done when the same-problem positive/recovery pair joins correctly, a distinct-problem control stays separate and no unrelated route changes. Tests belong outside this read-only audit.

## SOC-015 — duty and incident-assignment burden

Join historical incident assignments to the matching historical team duty interval, not today's roster. Report the provider's first-step on-call-hour limitation, up-to-15-minute reporting lag and team-only versus all-team scope. Overlapping hours are not summed as independent elapsed time. Assignment counts are not phone calls, device receipt, triage minutes or all escalation work.

Evaluate a declared workload, duty, off-hours or distribution requirement using its timezone and matching population. Unequal rotation weights may be intentional; there is no universal equal-hours or two-person rule. Missing representative window, timezone, intent, later-step coverage or actual attempt data blocks that conclusion while preserving usable measurements. Name the exact affected policy/time interval and concentration, not a clinical burnout diagnosis.

Use [rotations and shifts](../../setup-splunk-oncall/SKILL.md#rotations-and-shifts) or fix the evidenced noisy sender. Done when the relevant configuration matches the approved duty model and a later comparable window supports any claimed burden reduction. Never estimate financial savings from assumed labour rates.

## SOC-016 — future interval and override coverage

Assess only the explicit requested horizon and escalation steps. The v2 query is `daysForward`, not the internal specification key `daysFwd`; documented bounds do not prove unlimited future coverage. Use provider-rendered effective intervals with timezone/DST and policy-specific overrides. A direct-user entry with empty `rolls` is not automatically unstaffed. An unassigned override retains the original user; distinguish a still-assigned person from an unfulfilled planned absence.

Pass when the full requested interval and applicable steps have supported, eligible coverage matching declared intent. Fail a proved gap or an unmet required override; block unknown interval semantics, unsupported later steps or incomplete horizon. Evaluate union coverage and interval boundaries, not roster length. Duplicated roster slots can encode intended weighting. Name exact start/end, policy, eligible alternatives and source-proven services.

Use [rotations and shifts](../../setup-splunk-oncall/SKILL.md#rotations-and-shifts) and [scheduled overrides](../../setup-splunk-oncall/SKILL.md#overrides-maintenance-and-alert-rules). Done when fresh rendered intervals cover the approved horizon, adjacent intervals are preserved and the planned handover/override resolves. A current assignment alone never closes this check.

## SOC-017 — actionable incident context

For selected relevant incidents, inspect a safe original-alert projection and separately verified service mappings. Compare required service/environment, urgency/impact, accountable owner and diagnostic/runbook context with declared requirements. Distinguish field presence from correctness and accessible useful content. Team names, display names and arbitrary links cannot establish application identity; do not fetch arbitrary URLs from an alert.

Fail missing or demonstrably wrong required context on a fully observed selected incident. Block unproved service mapping, inaccessible original context or missing requirements. A narrow sample stays a narrow sample; do not extrapolate to every source. Preserve native policy/incident identifiers in local `affected` even when optional `correlation_affected` cannot be supplied. An actionable runbook does not authorize executing it.

Use [incident context](../../setup-splunk-oncall/SKILL.md#incident-context-and-ownership) to enrich the source or a narrow transform, and the existing confirmed service/repository mapping flow. Done when original-context projection and confirmed mapping identify the intended service, environment, owner and safe next diagnostic action without leaking secrets or inventing causality.

## SOC-018 — lifecycle and governance hygiene

Inspect the complete observed dependency graph, team-admin ownership and available lifecycle evidence against declared requirements. Set `SCOUTFLO_ONCALL_REQUIRE_TEAM_ADMIN=1` only for an explicitly required team administrator; zero listed team admins alone does not establish missing organizational ownership or global-admin absence. Without that requirement or independently established owner state, the owner-continuity verdict is blocked. Include nested-only policy consumers, rare critical senders and dormant disaster paths. Lack of recent incidents does not establish that a route is unused. A Global Admin count, invitation or key label is not proof of excessive privilege, stale licence cost or minimum API scope.

Fail only a supported, concrete broken/unowned/stale dependency or governance requirement with its full observed scope. Unknown age, role, MFA/SSO, credential inventory, consumer visibility or required owner is blocked, with precise attended evidence needed. Unreferenced objects without a contrary requirement are inventory review candidates. Backlog/ingestion auto-pause concerns need native state/incident evidence, not a guessed traffic ceiling.

Use [lifecycle review](../../setup-splunk-oncall/SKILL.md#lifecycle-and-access-review). The existing owned-object retirement guard remains narrow; do not extend it to arbitrary customer objects. Done when the identified requirement is met and dependencies/delivery remain intact. Billing optimisation requires actual price/contract evidence and remains in the separate non-scored cost lane.

## SOC-019 — source continuity and expected coverage

Use the actual upstream audit's source identity, observation time, evaluation/dispatch status and expected cadence, plus its verified destination binding. SOC-007 checks the exact configuration join; this check covers whether the expected source/transport is operating and whether required sources are accounted for. Prometheus, Sentry, Grafana, AWS/GCP and other direct senders retain their own rule/transport ownership. Do not insert Alertmanager into a direct route.

Fail a proved stale or broken required source/dispatch path, or a declared critical source with no intended destination. Block missing current source evidence, unavailable exact mapping or an unknown critical-service denominator. No recent incident is not an outage when the source is intentionally quiet. Source credential exposure belongs to the upstream configuration audit. Reference an upstream primary finding without charging it twice as an independent On-Call root defect.

Repair through [incoming alert sources](../../setup-splunk-oncall/SKILL.md#incoming-alert-sources), using the source-specific setup skill for its settings. Done when source health/evaluation/dispatch and the exact destination path are freshly established; stronger page-receipt claims need separate evidence. Retain a stale prior finding until same-check current evidence actually resolves it.

## Forbidden mutations

Every provider operation in this audit is a GET on the management API. No incoming-alert POST, team update, routing edit, policy creation/deletion, invitation, acknowledgment, resolution, maintenance, shift change, credential activation or test notification is permitted. A refused read does not justify a write probe or switching to an elevated credential.

Setup exposes guarded API recipes and attended provider workflows with executable before/after assertions. These require separate exact change approval and their own current evidence; an audit recommendation never repairs a finding by itself.
