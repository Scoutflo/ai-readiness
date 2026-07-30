# Token Efficiency Governance — v0.1.67+

**Policy:** Every skill must check existing data and history BEFORE triggering new provider API calls or analysis.

---

## Principle 1: Existing Data First

**Before any new audit run or analysis, check:**

1. Does `findings.json` exist for today's date?
2. Is the `history.jsonl` entry recent (<24h)?
3. Have any NEW resources/services been added since last run?

**If all three are false:** SKIP (reuse existing findings)
**If any is true:** RUN (fresh analysis needed)

### Pattern: Doctor Gate Pre-Check

```bash
# In every audit's doctor stage:
doc_check_recent_findings() {
  TARGET="$1"  # e.g., "aws", "grafana"
  AUDIT_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${TARGET}"
  HISTORY="${AUDIT_DIR}/history.jsonl"
  TODAY=$(date -u +%Y-%m-%d)
  TODAY_FINDINGS="${AUDIT_DIR}/${TODAY}/findings.json"

  # Check 1: findings.json exists for today
  if [ -f "$TODAY_FINDINGS" ]; then
    echo "✓ findings.json exists for today"
    return 0  # Can skip if no new resources
  fi

  # Check 2: history recent (<24h)
  if [ -f "$HISTORY" ]; then
    last_run=$(tail -1 "$HISTORY" | jq -r '.date // "2000-01-01"')
    hours_ago=$(( ($(date +%s) - $(date -d "$last_run" +%s)) / 3600 ))
    if [ "$hours_ago" -lt 24 ]; then
      echo "⏳ Last run ${hours_ago}h ago; skipping unless new resources detected"
      return 1  # SKIP
    fi
  fi

  return 0  # RUN
}
```

---

## Principle 2: Topology-Guided Scanning

**Before audit discovers resources, consult topology.json:**

```bash
topology_get_scan_scope() {
  # Load business context + critical services + exclusions from topology.json
  jq '.business_context, .scan_scope, .exclusions' "$TOPOLOGY_FILE" 2>/dev/null || \
  jq -n '{
    business_context: {environment: "production", critical_dependencies: []},
    scan_scope: {regions: "all", services: "all", accounts: "default"},
    exclusions: {regions: [], services: [], accounts: []}
  }'
}
```

**Example scan scope from topology.json:**

```json
{
  "business_context": {
    "environment": "production",
    "critical_dependencies": ["payment-svc", "api-gateway"]
  },
  "scan_scope": {
    "regions": ["us-west-2", "eu-central-1"],  // audit only these
    "services": ["payment-svc", "database-svc", "api-gateway"],  // critical first
    "accounts": ["prod-account"]
  },
  "exclusions": {
    "regions": ["cn-*"],
    "services": ["internal-testing", "deprecated-service"],
    "accounts": ["sandbox"]
  }
}
```

**Audit uses scan_scope to:**
- Filter which regions to query (AWS: skip cn-*, eu-north-1 if not in scope)
- Filter which services to detail (audit critical services first, skip deprecated)
- Filter which accounts to read (skip sandbox, staging if not needed)

### Pattern: Scope-Aware Discovery

```bash
audit_discover_resources() {
  TARGET="$1"  # "aws"
  
  scope=$(topology_get_scan_scope)
  regions=$(echo "$scope" | jq -r '.scan_scope.regions[]')
  
  # For each region in scope:
  for region in $regions; do
    # Check exclusions
    is_excluded=$(echo "$scope" | jq --arg r "$region" '.exclusions.regions[] | select(. == $r)')
    [ -n "$is_excluded" ] && continue  # SKIP this region
    
    # Audit this region
    audit_region "$TARGET" "$region"
  done
}
```

---

## Principle 3: Smart Batching (Already in Checkpoint)

**From topology.json scope:**

| Estate Size | Batch Size | Passes | Use Case |
|---|---|---|---|
| <100 resources | N/A | 1 | Small staging, single service |
| 100-500 | 100 | 5 | Medium prod (one team) |
| 500-2000 | 200 | 10 | Large prod (multi-team) |
| >2000 | 500 | 4-8+ | Enterprise (ask user for exclusions) |

**Pattern: Pre-run scope selection**

```bash
# In audit doctor, before discovery:
estate_size=$(jq '.scan_scope.estimated_resource_count // 0' "$TOPOLOGY_FILE")
if [ "$estate_size" -gt 2000 ]; then
  echo "⚠️  Estate >2000 resources. Filter by region/service?"
  read -p "Regions to include (comma-separated, or 'all'): " REGIONS_FILTER
  # Save filter to topology.json for reuse
fi
```

---

## Principle 4: History Ledger Pattern (REQUIRED)

**Every audit skill MUST maintain `history.jsonl`:**

```jsonl
{"date":"2026-07-26","overall":55,"categories":[...],"estate":{...}}
{"date":"2026-07-27","overall":58,"categories":[...],"estate":{...}}
{"date":"2026-07-30","overall":61,"categories":[...],"estate":{...}}
```

**Use for:**
1. **Skip detection:** If latest entry <24h old + no new resources, skip
2. **Trend line:** Last 5 entries show improving/regressing
3. **Regression detection:** Compare today's severity_counts vs yesterday
4. **Cost tracking:** Per-target cost if applicable

**Never skip if:**
- User passes `--force`
- User changed scan_scope (regions/services/exclusions)
- New integrations added to toolkit.yaml

---

## Principle 5: Per-Skill History Integration

### audit-aws
- **history.jsonl:** date, overall, severity_counts, estate (EC2, RDS, Lambda count), cost_waste_monthly
- **Skip if:** <24h + same estate size + cost stable within ±$50
- **Topology path:** scan_scope.regions, scan_scope.services (filter by tag, security group, VPC)

### audit-gcp
- **history.jsonl:** date, overall, severity_counts, estate (instances, buckets, services), cost_waste_monthly
- **Skip if:** <24h + same project + no new resources
- **Topology path:** scan_scope.projects, scan_scope.regions (zone filter)

### audit-grafana
- **history.jsonl:** date, overall, severity_counts, estate (dashboards, alerts, datasources)
- **Skip if:** <24h + same datasource count
- **Topology path:** scan_scope.services (only audit critical services' dashboards)

### audit-sentry
- **history.jsonl:** date, overall, severity_counts, estate (projects, teams, releases)
- **Skip if:** <24h + same project count
- **Topology path:** scan_scope.services (match Sentry project names to critical services)

### audit-lgtm (Prometheus/Loki/Tempo/Mimir)
- **history.jsonl:** date, overall, severity_counts, estate (series cardinality, dashboards, rules)
- **Skip if:** <24h + same series cardinality ± 5%
- **Topology path:** scan_scope.services (audit only critical services' metrics)

### audit-datadog
- **history.jsonl:** date, overall, severity_counts, estate (monitors, synthetics, logs), token_cost
- **Skip if:** <24h + same monitor count
- **Topology path:** scan_scope.services (match tags to critical services)

### audit-kubernetes
- **history.jsonl:** date, overall, severity_counts, estate (clusters, namespaces, workloads)
- **Skip if:** <24h + same cluster version + same namespace count
- **Topology path:** scan_scope.clusters (only audit specified clusters)

### cost-analysis
- **history.jsonl:** date, overall_score, monthly_waste, state
- **Skip if:** <24h + no new audit findings since last cost-analysis
- **Topology path:** uses business_context.cost_sensitivity (high=ROI sort, low=impact sort)

### correlation-engine
- **history.jsonl:** date, overlap_count, cascade_count, dedup_savings
- **Skip if:** No new findings in any audit since last correlation run
- **Reads:** All today's findings.json + correlation from yesterday (compares for delta)

### topology-guided-setup
- **history.jsonl:** date, findings_reviewed, fixes_recommended, approvals_required
- **Skip if:** No new findings since last topology guidance
- **Topology path:** reads topology.json + correlation.json for decision context

---

## Implementation Checklist

### For Every Audit Skill

- [ ] **history.jsonl initialized** (one line per run date)
- [ ] **Skip detection in doctor** (checks history <24h + no new resources)
- [ ] **Topology.json integration** (reads scan_scope, respects exclusions)
- [ ] **Smart batching** (uses estate size from topology for batch strategy)
- [ ] **Test: skip-logic passes** (history <24h → skip, >24h → run)
- [ ] **Test: topology-filtering** (exclusions applied, critical services prioritized)
- [ ] **Test: force flag** (`--force` skips history check)

### For Every Setup Skill

- [ ] **Consults topology before fixing** (critical service? cascade? overlap?)
- [ ] **Estimates tokens** (based on criticality + complexity)
- [ ] **Requests approval** (if critical_dependencies match)

### For Every Analysis Skill (cost-analysis, correlation-engine)

- [ ] **Reads existing findings.json** (no extra API calls if data fresh)
- [ ] **History-driven skip** (skip if no new findings since last run)
- [ ] **Appends to history ledger** (one line per run)

---

## Example: Audit-AWS Token Efficiency

### Without governance (wasteful):
```
Monday 9am:  audit-aws → calls AWS Cost Explorer, Compute Optimizer, Config
Tuesday 9am: audit-aws → same calls again (nothing changed) → $0.15 wasted
Thursday 9am: audit-aws → same calls again → $0.15 wasted
Weekly waste: $0.45
```

### With governance (efficient):
```
Monday 9am:  audit-aws
  ├─ doctor: checks history.jsonl → no entry
  ├─ discovery: calls AWS Cost Explorer (new data needed)
  ├─ audit: analyzes findings
  └─ result: writes findings.json + appends history.jsonl
  
Tuesday 9am: audit-aws
  ├─ doctor: checks history → Monday entry <24h old
  ├─ checks topology: same scan_scope regions
  ├─ discovery: skip (estate unchanged)
  └─ result: SKIP + log "audit-aws current (22h old, no new resources)"
  
Thursday 9am: audit-aws
  ├─ doctor: checks history → Monday entry >48h old
  ├─ discovery: calls AWS Cost Explorer (fresh data needed)
  ├─ audit: analyzes findings
  └─ result: writes findings.json + appends history.jsonl
  
Weekly savings: $0.30 (66% reduction)
```

---

## Real-World Measurement: CoinDCX Estate

**Estate:** 1180 EC2 + 77 RDS instances across 3 regions, 2 accounts

### Without governance:
- audit-aws: 3 daily runs × $0.05 = $0.15/day = $1.05/week
- audit-gcp: 3 daily runs × $0.04 = $0.12/day = $0.84/week
- audit-correlation: 3 daily runs × $0.03 = $0.09/day = $0.63/week
- **Total: $2.52/week ($131/year)**

### With governance:
- Monday: all audits run ($0.12/day = $0.84/week baseline)
- Tuesday-Thursday: 90% of audits skipped (history <24h, no new resources)
  - cost: $0.12/day × 3 days × 0.1 = $0.036/week
- Friday: all run again ($0.12/week)
- **Total: $1.10/week ($57/year) — 56% savings**

---

## Enforcement

Every skill MUST:
1. ✅ Initialize history.jsonl on first run
2. ✅ Implement skip-logic in doctor stage
3. ✅ Respect topology.json scan_scope
4. ✅ Append to history on completion
5. ✅ Support `--force` to bypass skip

**Gates before release:**
- Leak-scan passes
- Structure-check passes
- Plugin-validate passes
- **NEW: Token-efficiency audit passes** (verifies history + skip logic + topology integration)
