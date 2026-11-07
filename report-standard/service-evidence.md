# Qualified service evidence

A service name is a display label, not proof that two targets describe the same service. New audits can attach these optional fields without changing existing findings/inventory schema versions. Older artifacts remain readable; correlation treats absent evidence as unmappable instead of making a confident cross-account match.

## Identity and collection

Use `service_identity` on an inventory item, paired with `identity_evidence`. On a finding, use `correlation_bindings[]` with `{affected, service_identity, evidence}`; each `affected` must already belong to that finding. On-Call additionally retains its source-verified `correlation_affected` subset: policy/team names and route aliases cannot create a service binding.

Identity is a case-sensitive tuple:

- Kubernetes: `{kind: "kubernetes", cluster_id, namespace, service_name}`. Confirm the cluster identity from the selected control plane; neither a kube-context nickname nor a repeated private endpoint proves identity across clusters.
- Provider resource: `{kind: "provider-resource", provider, account_scope, resource_id}`. Use the owning provider's stable account/resource identity. Never infer account scope from a local target label.

Optional authoritative `region` and `environment` must agree when both observations supply them. Conflicts block a join. Friendly `covers`, `affected`, `attrs.region` and names remain useful in the report but are insufficient substitutes for this evidence.

Both envelopes may carry `collection: {status, scope, observed_at, reason}`. Status is `complete`, `partial` or `blocked`; scope is `target` or `subset`; time is a real, non-future UTC timestamp with seconds (`YYYY-MM-DDTHH:MM:SSZ`) on the audit date. Non-complete states require a reason. Target-complete means the entire selected target collection is reconciled, including pagination and permissions. A narrowed query, capped API or partial lane stays subset/partial. A whole-target empty collection requires the same proof as a nonempty one.

Evidence is `{target, observed_at, ref}`: the exact canonical artifact target, the exact collection timestamp and a safe relative source reference (optionally `#record-id`). It contains no endpoint, credential, query or contact value. Resolve the referenced safe source read before emitting the binding; the validator checks shape/generation agreement, not the truth of a claim. Do not infer identities merely to populate these fields. A missing binding creates a useful verification task, not a reason to hide an inventory object.

## Coverage conclusions

Only literal `enabled: true` objects support active coverage. Disabled or unknown activation remains visible but cannot cover a gap. Matching identity is necessary; confirm the actual signal/query and destination semantics before accepting the suggested cross-tool reframe. A source monitor cannot exonerate an On-Call staffing, escalation or routing defect.

`audit-all` records the actual selected queue before execution in `run-plan.json`:

```json
{"schema":"scoutflo-audit-plan/v1","audit_date":"2026-11-07","started_at":"2026-11-07T09:00:00Z","targets":["datadog/region-a","clickstack/region-b"],"completed_targets":[],"completion_receipts":{}}
```

The example is illustrative; create the actual targets and current UTC start time for every run. Never paste these values into a real run. `write-coverage-assessment.sh` derives `coverage-assessment.json` from that plan. Keep blocked/missing targets in the expected set. After each target produces validated, current `findings.json`, `inventory.json` and `report.md`, call `run-selection.py complete <audit-root> <date> <target>`. It serializes completion updates and binds SHA-256 hashes of those artifacts (and native On-Call history when present). Generation and collection timestamps must not precede the run start. A legacy artifact without optional collection metadata can complete, but does not prove collection completeness. Aggregation, cost, fatigue and visual renderers consume only these completed target generations while the plan applies. Stale same-day files, unselected targets and unfinished targets cannot enter a new roll-up. Malformed plans and hash drift fail closed; fix/revalidate the run instead of erasing the plan to bypass it. Without a current plan, explicitly selected historical/standalone reads retain legacy behavior. Completion receipts prove local validation and stable bytes, not live API truth. The correlation engine may classify a gap as `true-gap` only within that declared set when every expected target has a same-date target-complete inventory. Otherwise it reports `unmappable` and the missing proof. This is scoped absence evidence, not proof that no unconfigured tool exists anywhere.

Cross-tool overlap and fatigue joins use the same bindings. They identify configuration review candidates, not measured duplicate notifications, false positives or human interruptions. Native incident history, source fire history, delivery and recipient receipt keep their independent units and windows. Cost and migration consumers must not turn a candidate match into confirmed savings or equivalence.

## Validation and display

`check-correlation-evidence.sh` validates optional field structure when present and is called by findings/report validation. Consumer collection also binds the target and audit date to the actual path. Same-day timestamps do not promise an atomic estate snapshot; preserve each collection time and report observed drift.

Qualified identity/collection fields do not change scores, severity, lifecycle IDs or raw evidence. The canonical per-target reports remain the authority. [Estate topology composition](../skills/map-topology/references/estate-composition.md) can combine their evidence for local review, while server import keeps its separate supported schema and confirmation boundary.
