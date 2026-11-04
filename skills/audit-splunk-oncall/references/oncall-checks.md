# Splunk On-Call check catalog

Read the parent skill's target profile, scope and scoring rules first. The data source is the complete, safely projected management snapshot described in [api-contract.md](api-contract.md). Endpoint success, observed field type, proven relationship and actual notification delivery are different evidence classes. This catalog never treats a successful read as all four.

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

Use the executable [per-policy verification selectors](verify-path.md) for the exact read-and-assert form of SOC-001–SOC-007 done-when checks. Re-run after a repair; a stale saved snapshot does not verify a current change. SOC-001 through SOC-007 each produce one check ledger row. SOC-008 is an optional non-scored observation and is omitted when no relevant evidence exists. It is not a hidden eighth scored check. A finding aggregates affected objects for one check, preserving per-object evidence and denominators.

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
- **Fix:** select the exact key privately, review its complete target set and acknowledgment behavior in the [setup routing plan](../../setup-splunk-oncall/SKILL.md#routing-keys). Never rewrite the default route automatically or treat absent `isMultiResponder` as false.
- **Done when:** fresh routing inventory matches the approved target set, every target resolves uniquely, and unrelated/default route mappings are unchanged. Restoring only a key string is not a full rollback.

## SOC-002 — policy ownership

**Inputs:** global `policies[].slug` and `.team`, joined to `teams[].slug`. Policy detail does not carry the owning-team join. The team-policy list has a different response shape and must not substitute for the global wrapper without its own parser.

Assess only policies referenced by selected routes. Require exactly one owner mapping and one real team. If the team disappeared, re-read global policy and team inventories. A complete, repeated absent owner is a broken ownership reference;403 is unknown, not absence. Do not infer ownership from policy names, routing key text or URLs.

Pass/partial/fail follow all/some/none of the fully assessed referenced policies resolving. `affected` includes the concrete policy slug and known team slug, with actual dependent services only when mapped. Repair through the [setup policy plan](../../setup-splunk-oncall/SKILL.md#escalation-policies) after reading current consumers. Verify the global ownership join again; a successful team rename does not repair a foreign-key problem.

## SOC-003 — supported escalation targets resolve

**Inputs:** `policy_details[].steps[].entries[]`, membership and rotation identifiers. `type` is projected from `executionType`; a user entry retains its username and a rotation entry retains `rotationGroup.slug`. Only `user` and `rotation_group` have populated field grounding. Other types remain visible by type but their private payloads are omitted.

Require at least one step with at least one understood eligible target. Resolve user identities against the owning team's complete verified membership; a pending invitation is not eligible merely because its email resembles an existing user. Resolve a rotation slug to exactly one v1 group whose `teamSlug` matches the owner, then to its numeric v2 group ID. Numeric IDs and slugs are different identifier families.

Unknown execution type, missing typed identifier, unsupported later-step/timing semantics or ambiguous ID join blocks interpretation of that path. Do not call an empty ignored entry a valid escalation step. A supported target proven missing in complete reads is a failure. Preserve `timeout` values as observed; no unit conversion or estimated time-to-human until timing semantics are independently proven.

Name the exact policy and failed target; count affected route-policy paths. Repair an escalation entry through the [setup policy plan](../../setup-splunk-oncall/SKILL.md#escalation-policies) with full replacement semantics, existing personal-paging behavior and all consumers reviewed. Done when a fresh policy detail matches the intended entries and their referenced user/rotation identities resolve. Do not delete a policy to repair it: deletion may remove routing keys that target only that policy.

## SOC-004 — referenced rotation has eligible staff

**Inputs:** v1 `rotationGroups[].slug/groupId/teamSlug`, v2 `rotations[].groupId`, shifts' `shiftId`, `shifttype`, `members` projected from `shiftMembers[].username`, and team `members[].verified` boolean.

Only judge rotations referenced by a routed, otherwise resolvable policy. A deliberately unused empty rotation is an inventory observation, not an active paging outage. For each referenced rotation, resolve every relevant shift roster and require enrolled team members. `std` and `pho` have observed types; unfamiliar modes block schedule interpretation. Do not derive staffing from `periods`, current/next time objects, a total count or an empty scheduled-user response.

An empty roster proven by complete data means no assigned person in that shift. Which effective paging windows it affects is a separate schedule semantic; absent that proof, phrase the finding as an unstaffed configured shift, not a fabricated week-long outage. A policy with a staffed alternate path must be described accurately. Re-read at current boundaries before escalating severity.

The [rotations and shifts plan](../../setup-splunk-oncall/SKILL.md#rotations-and-shifts) identifies the exact rotation group and shift and the intended eligible members. Adding a shift member can also change team membership; confirm that side effect in setup. Done when the roster readback matches the approved users, eligibility is verified and the effective current assignment agrees. Future continuity/DST and notification delivery remain separate tests.

## SOC-005 — current assigned responder

**Inputs:** current `teamsOnCall[].oncallNow[].escalationPolicy.slug`, nested `users[].onCalluser.username`, the ownership join and verified membership. The uppercase `onCallUser` used in schedule APIs is not accepted as a guessed alias in the current endpoint.

For each supported routed policy, require one unambiguous current policy row for the correct owning team and at least one eligible username. Cross-check supported rotation roster/current assignment where applicable. A current user outside the selected roster may reflect an override; do not automatically fail the user as invalid. Establish the override or block the discrepancy. The audit never changes an override to simplify its evidence.

If no current person is reported, repeat the relevant current/roster reads after at least one second and record both observation times. Repeated complete empty current data with an expected active supported path is a gap at those times. A refused read, unknown override or unsupported target is blocked. One current person says nothing about tomorrow, repeated escalation or mobile receipt.

Plan the exact policy/shift/eligible assignment through the [escalation policy plan](../../setup-splunk-oncall/SKILL.md#escalation-policies) and [rotation plan](../../setup-splunk-oncall/SKILL.md#rotations-and-shifts). Done when fresh current data returns the intended eligible user for the same policy/team and the supporting roster or approved override resolves. Do not send a test page from this audit.

## SOC-006 — declared independent responders

**Inputs:** an explicit operator/business-context requirement and the unique enrolled usernames in the actual current response paths. Policy count, route fanout count, roster size and invited users are not independent responders.

If the operator explicitly declares that no redundancy requirement applies, first record that policy-scoped declaration in the business-context SSOT and its `resource_intent` projection. Only that captured, attributable intent permits not-in-scope (`by-design`, citing the source and affected policy set). An uncaptured conversation or verification selector returning `inapplicable` does not authorize this scored verdict; keep it blocked until provenance is recorded. An unspecified requirement is blocked pending target-profile clarification, never a failed universal two-person rule. If the requirement exists but supported current joins are incomplete, block. When complete, deduplicate usernames across the required policies and compare with the declared minimum; do not add different users who would only appear at unsupported later steps.

Name the required count, observed distinct count, shared user and affected policies. Severity follows the explicitly critical service/coverage need, not the word “production” alone. Plan a genuinely independent eligible path through the [team membership plan](../../setup-splunk-oncall/SKILL.md#teams-and-membership), with the user's approval for membership/contact effects. Done when the supported current join contains the required distinct people. Actual independent device delivery is still unverified.

## SOC-007 — source to response-path join

When this evidence proves a canonical service identity, include it in both `affected` and `correlation_affected`, citing the source mapping. The latter is an optional subset used for cross-target joins. Policy/team slugs and route aliases never substitute for that service proof; absent mapping means no correlation declaration.

**Inputs:** a source-side audit's current evidence for a concrete alert/monitor, an explicit expected team/policy or service mapping, and an exact routing-key comparison performed only in memory. Management reads alone supply none of these source-side facts.

If there is an expected source but the key/evidence is unavailable, block with that dependency. If the operator explicitly declares no sender integration in scope, capture the declaration in the business-context SSOT and its `resource_intent` projection before using not-in-scope (`by-design`); cite that source and scope. Do not treat missing evidence as by-design. A complete exact match to the expected valid response path passes the configuration join; mismatch or an observed missing key fails it. This is configuration correlation, not proof an event fired or reached a device.

Keep safe source evidence IDs, check times, expected/actual policy and team slugs, boolean exact-key match, and concrete affected service IDs. Do not persist the key, inbound URL, raw monitor configuration or secret-derived hash. Never assume a `victorops` contact-point type or `@` handle can be transformed into a key. A generic receiver type proves only its type.

Repair source routing through the source's owning setup workflow and policy/routing configuration through [setup-splunk-oncall](../../setup-splunk-oncall/SKILL.md#incoming-alert-sources). Avoid assigning monitoring-rule ownership to this paging audit. Done when fresh source and management reads establish the exact expected configuration join. An optional separately authorized delivery test can add evidence, but cannot run inside the audit.

## SOC-008 — optional incident lineage, non-scored

Use already authorized, safely projected evidence when investigating a selected real incident. This version consumes only already projected evidence with known identity and provenance; it does not perform a fresh alert-detail read. Do not collect every alert “for completeness.”

Observed incident `pagedPolicies[]` nests `policy` and `team`; `incidentNumber` is a string. The originally triggered `pagedUsers` may disappear after acknowledgment/resolution. Keep the original alert relationship and trigger-time evidence rather than using a later empty array to conclude nobody was paged. The latest event may be a recovery event and is not necessarily the original source.

One incident can establish a selected source/policy/recipient lineage. It cannot prove MTTA/MTTR population statistics, missed-event rates, recurrence behavior, populated history pagination or actual phone/email receipt. Alert timestamp strings require proven units/value semantics before conversion. Provider-side resolution while the source remains firing is explicit cleanup, not source recovery. Record these limits beside the observation, with zero readiness credit.

## Forbidden mutations

Every provider operation in this audit is a GET on the management API. No incoming-alert POST, team update, routing edit, policy creation/deletion, invitation, acknowledgment, resolution, maintenance, shift change, credential activation or test notification is permitted. A refused read does not justify a write probe or switching to an elevated credential.

Setup sections for team membership, rotations, policies and routing currently prepare plans only; their execution/readback/rollback gates remain pending. The executable setup action in this version is description-only team metadata. Do not imply these plans automatically repair a paging finding.
