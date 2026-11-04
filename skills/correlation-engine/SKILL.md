---
name: correlation-engine
description: 'Harness skill (run it directly, or let audit-all run it for you): after any audit(s) (audit-all, sequential, or targeted 2-3), builds correlation.json that identifies shared-resource monitoring candidates and possible dependency chains, and advisory cross-tool coverage candidates; downstream consumers apply business context. Works incrementally with partial coverage. Use when the user says correlate my audits, find overlapping monitoring, or review cross-tool coverage. Do not use for provider collection or fixes; use the relevant audit-* or setup-* skill. Run automatically by audit-all (Phase 3.5); its output is also consumed by rca and the topology-guided-setup helper.'
---

# Correlation Engine

After you run any audit (full audit-all, or sequential audits for the same run date, or targeted 2-3 audits), the correlation engine analyzes findings across all skills to detect overlaps, cascade risks, and apply business context intelligence.

Output: `scoutflo-audits/correlation.json` — machine-readable deduplication + prioritization. It is written once at the audit-dir root (not under a per-date subdir); the per-audit `findings.json` files it reads are target-first (`<target>/<date>/findings.json`).

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

## What correlation.json contains

### Source eligibility and identity

Use only observed, open findings for overlaps, cascades and coverage claims. `status: blocked` means evidence is missing; `lifecycle: suppressed` or `resolved` cannot corroborate active trouble. Missing status/lifecycle fields retain legacy v1 compatibility. Canonical target identity comes from the report-directory path, including for legacy object-shaped target envelopes. The raw finding counter still includes all source rows; excluded rows remain in their original reports and are never rewritten. A rerun with no findings writes an empty current correlation result, replacing earlier groups.

Non-scored cost and topology observations can participate in overlaps, but their titles alone cannot declare a coverage gap. A non-scored finding needs an explicit `coverage_gap` object with a nonempty `signal` to support that classification. Readiness and legacy findings retain the area/title fallback after source eligibility is checked.

On-Call uses only its explicit `correlation_affected` subset of `affected` for cross-target joins. That field names canonical service identities verified by independent source evidence; policy/team slugs belong to an account, and `route-N` aliases belong to a run. Neither establishes shared service identity. Without a valid declaration, even a historical On-Call finding contributes no join tokens and remains visible in its own report/raw counts. The consumer rejects tokens outside `affected` and route aliases. Other providers retain their existing `affected` behavior.

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
  "recommendation": "Multiple stacks report findings against payment-svc; review whether the monitoring overlaps and consolidate the paging path"
}
```

The `overlap_id` is `OVL-<service>` and `service` is the single shared affected service the group is keyed on; `targets` lists the distinct stacks that named it. The `recommendation` is a fixed template built from the service name.

**Interpretation:** Both stacks report findings against the same service — candidate redundant monitoring. Review whether they overlap and consolidate onto one paging path to cut alert fatigue.

### Cascades: Dependency Chains

```json
{
  "cascade_id": "CASC-AWS-030",
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

The `cascade_id` is `CASC-<root finding id>`. `shared_resources` are the concrete affected tokens the root names; each effect is emitted only because it shares one of those tokens (a real join, not a keyword guess), so `condition` is the same fixed sentence on every effect. There is no `chain_length`, `service`, `impact`, or `step` field.

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

correlation.json schema (exactly what the lib writes):

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
      "recommendation": "single-tool-dependency: datadog monitor checkout latency actively covers checkout and routes to pagerduty; confirm it covers the specific signal this gap names before de-prioritizing"
    }
  ],
  "method": "same-affected-service overlap grouping + database-to-alerting cascade heuristic + cross-tool coverage join; every referenced finding_id and inventory item exists in this run"
}
```

There is no `confidence` or `business_context_applied` field — the engine does not assign a confidence percentage; it groups by shared `affected` service, joins cascades on shared resources, and reframes coverage from `inventory.json`, and `method` states exactly how.

**Cross-tool coverage (`coverage[]`).** A coverage-gap finding in one provider (e.g. Azure "no metric alerts on checkout") is joined against **other** providers' *active, routed* monitors from their `inventory.json` (an item is active only when `kind` is a monitor/alert-type, `enabled != false`, and `routes_to` names a real receiver). Each affected resource is classified `covered-elsewhere` (an exact canonical-name match on an active monitor in a different provider — reframed as **single-tool-dependency**, never "covered"; the audit-owned severity is never mutated), `unmappable` (only a fuzzy/substring match — verify-pending, run `/scoutflo:map-topology` to join by canonical name), or `true-gap` (no active cross-tool coverage — a real gap to elevate). This is advisory only: `coverage[]` reframes how a gap is *presented* by `rca` and the report renderer; it never changes `findings.json`. Match confidence is highest when `map-topology` has run so both sides use the canonical service name. A finding may also carry an optional `coverage_gap: {signal, kind}` (see the findings schema): when present it identifies the gap precisely (so the engine doesn't rely on the area+title heuristic) and the `covered-elsewhere` reframe names that exact signal ("confirm the covering monitor watches `<signal>`") — closing the service-matches-but-signal-differs blind spot.

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

- **Overlaps** are exact: two findings are grouped only when they name the same `affected` service, so a grouped overlap is a real shared-resource match, not a guess. The engine assigns no confidence percentage.
- **Cascade detection uses heuristics** (database → monitoring → incident response) and is not exhaustive.
- **One run date only.** Cross-date merging is unsupported; rerun audits for a common date before comparing current observations.
- Requires `jq` on PATH.
- Every referenced `finding_id` in the output exists in the current run's findings (no invented references) — that is the grounding guarantee, verified by the `method` note above.

## See also

- `/scoutflo:start` — orientation + skill catalog
- `/scoutflo:setup-aws` — use its documented confirmation flow for AWS changes
- `/scoutflo:business-context` — metadata that weights correlation prioritization
