---
name: correlation-engine
description: 'Harness skill (run it directly, or let audit-all run it for you): after any audit(s) (audit-all, sequential, or targeted 2-3), builds correlation.json that identifies shared-resource monitoring candidates and possible dependency chains, and advisory cross-tool coverage candidates; downstream consumers apply business context. Works incrementally with partial coverage. Use when the user says correlate my audits, find overlapping monitoring, or review cross-tool coverage. Do not use for provider collection or fixes; use the relevant audit-* or setup-* skill. Run automatically by audit-all (Phase 3.5); its output is also used by rca and cost-analysis for advisory context.'
---

# Correlation Engine

After you run any audit (full audit-all, or sequential audits for the same run date, or targeted 2-3 audits), the correlation engine analyzes findings across all skills to detect overlaps, cascade risks, and apply business context intelligence.

Output: `scoutflo-audits/correlation.json` — machine-readable overlap candidates and prioritization. It is written once at the audit-dir root (not under a per-date subdir); the per-audit `findings.json` files it reads are target-first (`<target>/<date>/findings.json`).

The output does not authorize removing or skipping monitoring. Review candidates with the owning setup skill, using exact target evidence and its normal change confirmation. The older `topology-guided-setup` helper is not wired into setup execution and does not enforce current run/target bindings; do not use it for automatic pruning.

## How it works

### Scenario 1: Full audit-all run
```text
/scoutflo:audit-all
→ Configured audit skills produce findings.json
→ correlation engine runs automatically
→ correlation.json written with all overlaps + cascades detected
```

### Scenario 2: Sequential audits for one date

Run the provider audits under the same `RUN_DATE`, then invoke the manual block below with that date. Each rerun rebuilds from that date's available artifacts. It does not merge findings from earlier dates; stale observations cannot become current evidence merely because a later audit ran.

### Scenario 3: Targeted 2-3 audits
```text
/scoutflo:audit-aws /scoutflo:audit-grafana /scoutflo:audit-kubernetes
→ Only these 3 audits run
→ Correlation engine detects overlaps + cascades within this subset
→ Review candidate shared resources; verify signal equivalence before changing either paging path
```

Planned runs use only validated completed artifact generations. A saved roll-up retains its `run_selection` snapshot; changed inputs or later completions require regeneration before a combined report. See [service evidence](../../report-standard/service-evidence.md).

## What correlation.json contains

### Source eligibility and identity

Use only observed, open findings for overlaps, cascades and coverage claims. `status: blocked` means evidence is missing; `lifecycle: suppressed` or `resolved` cannot corroborate active trouble. Missing status/lifecycle fields retain legacy v1 compatibility. Canonical target identity comes from the report-directory path, including for legacy object-shaped target envelopes. The raw finding counter still includes all source rows; excluded rows remain in their original reports and are never rewritten. A rerun with no findings writes an empty current correlation result, replacing earlier groups.

Non-scored cost and topology observations can participate in overlaps, but their titles alone cannot declare a coverage gap. A non-scored finding needs an explicit `coverage_gap` object with a nonempty `signal` to support that classification. Readiness and legacy findings retain the area/title fallback after source eligibility is checked.

On-Call uses only its explicit `correlation_affected` subset of `affected` for cross-target joins. That field names canonical service identities verified by independent source evidence; policy/team slugs belong to an account, and `route-N` aliases belong to a run. Neither establishes shared service identity. Without a valid declaration, even a historical On-Call finding contributes no join tokens and remains visible in its own report/raw counts. The consumer rejects tokens outside `affected` and route aliases. Every provider additionally requires the current `correlation_bindings` contract described in [evidence-joins.md](references/evidence-joins.md). Legacy `affected` names remain readable and raw-counted, but cannot establish cross-target identity.

### Overlaps: Redundant Monitoring

```json
{
  "overlap_id": "OVL-payment-svc",
  "type": "redundant_monitoring",
  "service": "payment-svc",
  "targets": ["aws", "grafana"],
  "findings": [
    {
      "target": "aws",
      "finding_id": "AWS-034",
      "title": "Database resource-pressure alarm is missing",
      "severity": "high"
    },
    {
      "target": "grafana",
      "finding_id": "GRAF-004",
      "title": "Datasource returns no usable data for the service",
      "severity": "medium"
    }
  ],
  "recommendation": "Multiple targets share a verified resource identity; inspect the signal paths before changing routing"
}
```

The `overlap_id` uses `OVL-` plus an encoded qualified identity; `service` is a display label. Additive `service_identity` and evidence define the shared resource. `targets` lists the distinct source targets.

**Interpretation:** both targets have current findings for the same verified scoped identity. Inspect whether they describe one linked path or independent paths; this alone does not establish duplicate events, pages or delivery.

### Cascades: Dependency Chains

```json
{
  "cascade_id": "CASC-WyJhd3MiLCJBV1MtMDMwIl0=",
  "root_cause": {
    "finding_id": "AWS-030",
    "title": "Production database lacks engine-appropriate availability coverage",
    "target": "aws",
    "shared_resources": ["mysql-primary"]
  },
  "effects": [
    {
      "finding_id": "GRAF-004",
      "title": "Datasource returns no usable data",
      "target": "grafana",
      "condition": "shares a resource with the datastore finding; verify its signal survives if that datastore degrades"
    },
    {
      "finding_id": "PD-008",
      "title": "High-urgency notification rules delay the first page",
      "target": "pagerduty",
      "condition": "shares a resource with the datastore finding; verify its signal survives if that datastore degrades"
    }
  ]
}
```

The `cascade_id` is `CASC-` plus the encoded source target/finding-ID pair; equal check IDs in different accounts remain distinct. `shared_resources` are display tokens; additive `service_identities` and generation-bound bindings establish the resource shared with each effect. This remains a dependency candidate requiring investigation, not proven causality. There is no `chain_length`, `service`, `impact`, or `step` field.

**Interpretation:** Shared resources identify a dependency hypothesis to investigate. The field is named `root_cause` for compatibility; this heuristic does not establish causation or prove that one fix prevents another failure. Verify the dependency and its signal path before choosing a fix order.

## Business Context Applied

correlation.json is **context-neutral**. It records overlaps, cascades, and the
dedup counters — nothing more — and never embeds business-context weighting.

If you ran `/scoutflo:business-context`, the engine *does* read it (via
`correlation_load_context`, which loads `environment`, `cost_sensitivity`, and
`critical_dependencies`) and computes an advisory `context_note` on each finding
during the run: staging low/medium gaps are noted as possibly intentional, and
findings that touch a `critical_dependencies` service are flagged as
business-critical. But that note is **not persisted** — the overlaps and cascades
written out are rebuilt from their own member objects (`target`, `finding_id`,
`title`, `severity`), and the annotated findings array is discarded. The engine
also never changes a finding's audit-owned `severity`.

So business-context weighting is applied by the **downstream consumers** that read
both correlation.json and the business-context SSOT, not by the engine itself:

| Setting | Where it takes effect |
|---------|----------------------|
| `environment: "staging"` | `rca` uses it to calibrate severity language (a staging-only chain is real but not an incident). |
| `critical_dependencies: [...]` | `rca` leads with and raises urgency for findings on these services. |
| `cost_sensitivity: "high"` | `cost-analysis` records it verbatim; savings are ranked by provider-native monthly figure (the sensitivity value does not re-sort). |

### Safe Defaults (if business-context not set)

If you've never run `/scoutflo:business-context`, `correlation_load_context` falls
back to:
- `environment: "production"` (conservative; all issues real)
- `cost_sensitivity: "medium"` (balanced prioritization)
- `critical_dependencies: []` (no special treatment)

**Effect:** No `context_note` is added, and correlation.json is identical either
way — it is context-neutral regardless. Business context only changes how the
downstream consumers (`rca`, `cost-analysis`) present the same overlaps and
cascades.

## Integration with Topology-Guided Setup

After correlation.json is written, read its date and source findings before passing a candidate to an appropriate setup skill. Use that skill's documented selectors and explicit confirmation gate. Correlation does not authorize a write, prove downstream delivery, or provide an accurate token-price estimate.

## Output Structure

```
scoutflo-audits/
  correlation.json       ← machine-readable overlaps + cascades (audit-dir root)
  aws/
    <date>/
      findings.json
      report.md
  grafana/
    <date>/
      findings.json
      report.md
  ...
```

Abbreviated correlation.json example (qualified bindings, assessment and selected-run receipts are additional fields):

```json
{
  "version": "2.0",
  "generated_at": "2026-07-30T14:30:00Z",
  "audit_date": "2026-07-30",
  "total_findings_raw": 87,
  "total_findings_deduplicated": 42,
  "total_overlaps_detected": 23,
  "total_cascades_detected": 5,
  "total_coverage_covered_elsewhere": 4,
  "total_coverage_true_gap": 9,
  "total_coverage_unmappable": 2,
  "overlaps": [ {...} ],
  "cascades": [ {...} ],
  "coverage": [
    {
      "finding_id": "AZR-002",
      "target": "azure/prod",
      "resource": "checkout",
      "classification": "covered-elsewhere",
      "covered_by": [ { "provider": "datadog", "inventory_name": "checkout latency", "routes_to": "pagerduty", "match": "exact" } ],
      "recommendation": "single-tool-dependency: datadog monitor checkout latency is configured for the qualified service with a pagerduty route; confirm it covers the specific signal this gap names before de-prioritizing"
    }
  ],
  "method": "current scope-qualified identity joins; candidate overlaps and dependencies; scoped absence only with complete declared assessed inputs; advisory only"
}
```

There is no `confidence` or `business_context_applied` field — the engine does not assign a confidence percentage; it groups by current scope-qualified service identity, joins cascades on that same proof, and reframes coverage from `inventory.json`, and `method` states exactly how.

**Cross-tool coverage (`coverage[]`).** Require literal `enabled: true`, a real route and a current scope-qualified identity at another provider. `covered-elsewhere` is a candidate single-tool dependency; confirm the specific `coverage_gap.signal` before changing priority. `unmappable` preserves unknown activation, missing identity and incomplete assessment. `true-gap` applies only within an explicit selected-target set whose current inventories are all complete with target scope; it is never inferred from missing files. See [evidence-joins.md](references/evidence-joins.md) for the exact generation, identity and `coverage-assessment.json` contracts. `assessment` in the output retains missing/blocked/subset states. Source scores and severities are unchanged; no coverage classification proves notification delivery.

## When correlation engine runs

**Automatic:**
- After `/scoutflo:audit-all` completes
- Individual audits follow their own documented orchestration; invoke this block explicitly when needed.

**Manual (if needed):**
```bash
set -eu
: "${CLAUDE_PLUGIN_ROOT:?Set the installed plugin root}"
RUN_DATE="${RUN_DATE:-$(date -u +%F)}"
. "${CLAUDE_PLUGIN_ROOT}/skills/correlation-engine/lib/correlation-engine.sh"
correlation_run "$RUN_DATE"
```

## Limitations

- **Overlaps** require compatible current scope-qualified bindings on both findings. A common name alone is unmappable. The engine assigns no confidence percentage and proves no duplicate delivery.
- **Cascade detection uses heuristics** (database → monitoring → incident response) and is not exhaustive.
- **One run date only.** Cross-date merging is unsupported; rerun audits for a common date before comparing current observations.
- Requires `jq` on PATH.
- Every referenced `finding_id` in the output exists in the current run's findings (no invented references) — that is the grounding guarantee, verified by the `method` note above.

## See also

- `/scoutflo:start` — orientation + skill catalog
- `/scoutflo:setup-aws` — use its documented confirmation flow for AWS changes
- `/scoutflo:business-context` — metadata that weights correlation prioritization
