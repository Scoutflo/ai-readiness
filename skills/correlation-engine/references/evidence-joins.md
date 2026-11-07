# Evidence-bound cross-target joins

The shared field contract is [Qualified service evidence](../../../report-standard/service-evidence.md). Use it for `collection`, `service_identity`, `identity_evidence`, `correlation_bindings` and the selected-target assessment manifest. This reference describes how correlation and alert fatigue consume those fields.

## Source generation and identity

The directory path supplies canonical source target provenance; the envelope must agree before it can support a positive join. Findings use their canonical `run_date` and `generated_at`; inventory uses `generated_at` and its date. The requested audit date must agree, collection cannot postdate artifact generation, and each evidence record must match the source target and exact collection timestamp. Legacy object-shaped/missing target or time fields remain readable and raw-counted, but cannot establish new verified joins.

A source target is not a shared service identity. Two providers can cover the same Kubernetes cluster/namespace/service or provider/account/resource tuple. Two clusters with `checkout`, two accounts with `db-primary`, or two rules with `route-1` do not automatically refer to the same object. Mandatory tuples compare exactly, and contradictory region/environment qualifiers block a join. Multiple conflicting identities attached to one affected token also stay unmappable.

On-Call additionally requires each binding inside both `affected` and its independently source-verified `correlation_affected`. Account-local policies/teams and run-local `route-N` aliases cannot create shared service identity. AF-001 still counts eligible legacy findings; AF-002, coverage, overlaps and cascades require the current qualified proof.

## Coverage and absence

Only literal boolean `enabled: true` plus a real route can support a coverage candidate. Missing, null, numeric and string activation values are unknown. Disabled monitors remain visible but cannot cover gaps. Routing objects are not coverage-bearing monitors, and an upstream monitor cannot cover an On-Call responder or escalation defect.

Current observed rows in partial/subset collection can support a positive join. Absence is different: the expected target set must come from the actual selected audit queue, including failed targets, and every expected inventory must be complete with target scope. Do not build the expected list from only the files that succeeded. Unknown activation or identity on a possible monitor also prevents an absence conclusion.

- `covered-elsewhere`: a current enabled routed monitor at another provider shares the verified scoped identity. Confirm the specific missing signal before changing priority; configuration does not prove delivery.
- `unmappable`: identity, activation or assessed inputs do not support a conclusion. `reason` names the missing evidence.
- `true-gap`: no matching active routed cross-tool monitor was observed **within the declared assessed targets**, with complete current inputs. This is not estate-wide absence.

`assessment.targets` preserves missing/unreadable/blocked/subset states. The raw score, severity, checks and findings are unchanged. Candidate overlap is not a duplicate-incident/page count; a dependency candidate is not a root-cause conclusion. `service` remains a display label; additive `service_identity` and evidence define the join. Derived overlap IDs encode that qualified identity so identically named services cannot collide.

AF-002 similarly includes `identity_assessment`, unmappable source findings and contradictory qualifiers. Zero joined groups is not proof that paging has no duplicates. Source fire history, incidents and human delivery retain separate units and evidence.

## Counterexamples

**Wrong:** a monitor has no activation field, therefore it is active; an uncollected provider has no monitors. **Right:** preserve unknown activation and missing collection; show `unmappable` with the exact reason.

**Wrong:** both regions say `checkout`, so consolidate paging. **Right:** require cluster/account and namespace/resource identity with compatible qualifiers, then inspect the actual signal paths before changing either.

**Wrong:** a valid typed record proves the referenced service binding. **Right:** the producer must verify the retained source read; consumers validate identity, target, generation and reference consistency, not the truth of a hand-authored assertion.

## Shared validator

The consumers share `lib/service-identity.jq`. From the plugin root, `jq -L skills/correlation-engine/lib 'include "service-identity"; si_valid_identity'` validates an identity object. Other entrypoints are `si_utc`, `si_valid_collection($audit_date)`, `si_valid_evidence($target;$collection;$audit_date)`, `si_key` and `si_compatible($left;$right)`. Run them on the corresponding JSON object; none calls providers. The report-standard validator owns optional envelope field checks.
