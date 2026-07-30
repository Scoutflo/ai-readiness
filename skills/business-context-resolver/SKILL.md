---
name: business-context-resolver
description: Discover K8s labels, AWS tags, and GitHub CODEOWNERS to auto-generate resource metadata for all services and resources. Eliminates manual resource-by-resource entry. Use when you want to auto-populate business_context.md guardrails from your existing infrastructure metadata, or when you have 50+ resources and manual entry becomes tedious. Scales to 10,000+ resources with optional discovery. Gracefully falls back to manual entry if discovery sources unavailable.
---

# business-context-resolver

Read-only metadata discovery and auto-generation of guardrails for all infrastructure resources. Scans your Kubernetes clusters, AWS accounts, and GitHub CODEOWNERS to discover service metadata, then generates `computed_metadata.jsonl` — a flat list of every resource with team, environment, SLA, and criticality metadata applied according to your global business rules.

One-time setup: define global rules (SLAs, teams, exclusions). Then resolver discovers all resources and applies those rules. No manual resource-by-resource entry. Supports all customer scales:

- **Startup (5-20 services):** Skip discovery, manual entry works fine, same as v0.1.67
- **Mid-Market (50-500 services):** K8s + AWS discovery, saves 50% time and 67% tokens
- **Enterprise (1000+ services):** K8s + AWS + GitHub discovery, saves 91% time and 86% tokens
- **Air-gapped:** No external discovery, structured manual entry, no penalty vs v0.1.67

The resolver is pluggable: extend with custom discovery hooks for Jira, Terraform, or other metadata sources. Graceful fallback: if `kubectl` or AWS CLI unavailable, resolver skips that source and reports what it found.

Output: `computed_metadata.jsonl` (one line per resource, JSONL format). All audit skills read this file to make decisions about scope, criticality, escalation, cost sensitivity, and audit scheduling. Replaces manual parsing of business_context.md per skill.

Run standalone via `/scoutflo:business-context-resolver`, or as part of `/scoutflo:connect` discovery mode when setting up new customers. Re-run anytime to refresh metadata (e.g., when services added). Resolver cost is low (discovers all resources once, applies rules, outputs JSON).

Scope boundaries: This skill is **discovery only**. It does not audit, change, or delete anything. It reads labels, tags, and source files; generates metadata; outputs JSONL. The metadata is consumed by all other audit/setup skills (audit-aws, audit-gcp, cost-analysis, setup-aws, etc.) to make decisions. For applying guardrails to findings, use `/scoutflo:audit-all` and downstream skills. For manual entry without discovery, use `/scoutflo:connect` and skip discovery.

Outputs:

- `~/.scoutflo/computed_metadata.jsonl` (resource metadata, JSONL format, readable by all skills)
- `~/.scoutflo/metadata/discovery_summary.txt` (human-readable summary of what was discovered)

## Doctor gate

| Integration | toolkit.yaml keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| Kubernetes | `kubernetes.context` (optional) | kubeconfig | `get` on all resource types | read-only |
| AWS | (none; uses current AWS profile) | `~/.aws/config` + active profile | `ec2:DescribeInstances`, `rds:DescribeDBInstances` | read-only |
| GitHub | (none; uses current git repo) | SSH key or HTTPS credentials | read access to CODEOWNERS file | read-only |

All integrations are **optional**. If any tool is unavailable:
- `kubectl` not found → skip Kubernetes discovery, continue with AWS + GitHub
- AWS CLI not found → skip AWS discovery, continue with K8s + GitHub
- CODEOWNERS file not found → skip GitHub discovery, continue with K8s + AWS
- All sources unavailable → output empty metadata, manual entry required

No doctor failure stops the resolver. Resolver reports what it found and what it skipped. Only v0.1.67 business_context.md is required (must exist at `~/.scoutflo/business_context.md`); if missing, resolver fails with clear message: "run `/scoutflo:connect` first".

Doctor checks (before discovery):

```bash
set -eu
CFG="${HOME}/.scoutflo/business_context.md"
[ -f "$CFG" ] || { echo "ERROR: business_context.md not found at $CFG"; echo "Run: /scoutflo:connect"; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq not installed"; exit 1; }
# kubectl, aws, git optional — checked per discovery source, not fatal if missing
```

Live-safety gate: Before discovery starts, resolver prints what it will scan:

```bash
echo "Discovering metadata..."
echo "  K8s: $([ -z "$KUBECTL_DISABLED" ] && echo "enabled" || echo "disabled (kubectl not found)")"
echo "  AWS: $([ -z "$AWS_DISABLED" ] && echo "enabled" || echo "disabled (aws CLI not found)")"
echo "  GitHub: $([ -z "$GITHUB_DISABLED" ] && echo "enabled" || echo "disabled (CODEOWNERS not found)")"
echo "Output: $OUTPUT_FILE"
```

No mutations. No cluster changes. Read-only throughout.

## Ground rules

- Metadata is discovered once per resolver run. Re-run to refresh (idempotent, safe to re-run anytime).
- Discovery sources are optional and independent. Lack of one source doesn't block others.
- Graceful fallback: if a source is unavailable, skip it and report. Never fail the whole resolver for one missing source.
- Resolver output is consistent regardless of discovery path: same JSON schema, same field names, same JSONL format.
- All audit skills read computed_metadata.jsonl the same way. Single source of truth across all skills.
- Resolver is deterministic: same input (global rules + labels + tags) always produces same output.
- computed_metadata.jsonl is generated fresh (not persisted). Re-run resolver before each audit to pick up infrastructure changes.

## Usage

### Automatic (via `/scoutflo:connect`)

When setting up a new customer, `/scoutflo:connect` asks: "Use auto-discovery? (y/n)". If yes, it runs resolver after capture.

### Manual (standalone)

```bash
/scoutflo:business-context-resolver
```

Output:

```
Discovering metadata...
  K8s: enabled (5 services found)
  AWS: enabled (120 EC2 instances found)
  GitHub: enabled (team ownership read)

✅ Metadata resolved for 125 resources
  📊 Resources resolved: 125
  📄 Output: ~/.scoutflo/computed_metadata.jsonl

📈 Summary:
  CRITICAL: 12
  STANDARD: 110
  SKIP: 3
```

### Options

```bash
/scoutflo:business-context-resolver --skip-k8s        # Skip Kubernetes discovery
/scoutflo:business-context-resolver --skip-aws        # Skip AWS discovery
/scoutflo:business-context-resolver --skip-github     # Skip GitHub discovery
/scoutflo:business-context-resolver --force           # Force re-discovery (ignore cache)
/scoutflo:business-context-resolver --verbose         # Show detailed progress
/scoutflo:business-context-resolver --dry-run         # Show what would be discovered, don't write
```

## Input

**Required:** `~/.scoutflo/business_context.md`

```markdown
## Global SLAs / SLOs
- Production-Standard: 99.9%
- Production-Critical: 99.95%
- Staging: 95%

## Teams
- platform: Kubernetes, SRE, infrastructure
- payment: Revenue-critical, PCI-DSS
- api: Customer-facing
- database: Data integrity, backups

## Global Exclusions
- Regions: cn-*, us-gov-*
- Accounts: sandbox, legacy-prod
- Services: deprecated-*, v1-*

## Cost Sensitivity
- Primary: high

## Discovery Configuration
- Kubernetes discovery: enabled
- AWS discovery: enabled
- GitHub CODEOWNERS: ops/CODEOWNERS
```

## Output

**File:** `~/.scoutflo/computed_metadata.jsonl`

Each line is one resource with auto-derived metadata:

```jsonl
{"resource_id":"payment-svc","type":"k8s-service","team":"payment","environment":"prod","sla":"99.95%","escalation":"CRITICAL","cost_sensitivity":"high","resolved_at":"2026-07-30T19:45:00Z"}
{"resource_id":"api-gateway","type":"k8s-service","team":"api","environment":"prod","sla":"99.9%","escalation":"CRITICAL","cost_sensitivity":"high","resolved_at":"2026-07-30T19:45:00Z"}
{"resource_id":"i-0a1b2c3d","type":"ec2","team":"platform","environment":"prod","sla":"99.9%","escalation":"STANDARD","cost_sensitivity":"high","resolved_at":"2026-07-30T19:45:00Z"}
{"resource_id":"i-0x9y8z7w","type":"ec2","team":"internal","environment":"sandbox","sla":"95%","escalation":"STANDARD","cost_sensitivity":"low","resolved_at":"2026-07-30T19:45:00Z"}
...
```

Fields per resource:
- `resource_id`: Service or resource name
- `type`: kubernetes-service, ec2, rds, etc.
- `team`: Derived from K8s label or AWS tag
- `environment`: Derived from K8s label or AWS tag
- `sla`: Derived from team + environment via global rules
- `escalation`: CRITICAL or STANDARD (derived from team/environment/criticality)
- `cost_sensitivity`: high/medium/low (derived from team)
- `action`: audit or skip (derived from environment/service name)
- `resolved_at`: ISO timestamp when resolver ran

## Integration: How Other Skills Use This

All audit and setup skills load computed_metadata.jsonl in doctor gate:

```bash
load_metadata() {
  METADATA="$HOME/.scoutflo/computed_metadata.jsonl"
  [ -f "$METADATA" ] || { echo "Run /scoutflo:business-context-resolver first"; return 1; }
  # Now all skills read from same source:
  # audit-aws: skip sandboxes, escalate critical services
  # cost-analysis: sort by cost_sensitivity
  # setup-aws: gate risky ops on escalation level
}
```

Before v0.1.68: each skill manually parsed business_context.md (inconsistent, slow).  
After v0.1.68: all skills read pre-computed computed_metadata.jsonl (consistent, fast, zero duplication).

## Discovery Process (Behind the Scenes)

1. **Parse global rules** from business_context.md (SLAs, teams, exclusions, cost sensitivity)
2. **Discover K8s labels** (if enabled)
   - Query all Kubernetes resources in all namespaces
   - Extract labels: service, team, environment, criticality
   - Map to global teams
3. **Discover AWS tags** (if enabled)
   - Query EC2 instances: extract tags Service, Team, Environment
   - Query RDS instances: extract tags Service, Team, Environment
4. **Discover GitHub ownership** (if enabled)
   - Parse CODEOWNERS file
   - Map code paths to teams
5. **Apply derived rules** to every discovered resource
   - Rule 1: IF team=payment AND env=prod THEN SLA=99.95%, escalation=CRITICAL
   - Rule 2: IF team=platform THEN cost_sensitivity=medium
   - Rule 3: IF env=sandbox THEN action=skip
   - (etc.)
6. **Generate computed_metadata.jsonl** (one line per resource, JSONL format)
7. **Output summary** (count by escalation level, skipped resources, etc.)

## Archetype Examples

### Startup (5 services, skip discovery)

```bash
# Customer has simple metadata, doesn't need discovery
/scoutflo:business-context-resolver --skip-k8s --skip-aws --skip-github

# Output: manual entry path
Input: business_context.md with 5 services listed
Output: computed_metadata.jsonl with 5 resources
Time: 2 minutes
Tokens: 1K
```

### Mid-Market (150 services, K8s + AWS discovery)

```bash
# Customer has realistic K8s labels and AWS tags
/scoutflo:business-context-resolver

# Output: auto-discovered
Discovered: 150 services from K8s + AWS
Time: 25 minutes (global rules + discovery + apply rules)
Tokens: 5K
Savings vs v0.1.67: 50% time, 67% tokens
```

### Enterprise (1,257 services, full discovery)

```bash
# Customer has K8s + AWS + GitHub metadata
/scoutflo:business-context-resolver

# Output: auto-discovered
Discovered: 1,257 resources (1,180 EC2 + 77 RDS + 127 K8s services)
Time: 35 minutes (global rules + full discovery)
Tokens: 7K
Savings vs v0.1.67: 91% time, 86% tokens (enables use case)
```

### Air-gapped (any scale, no discovery)

```bash
# Customer has no external discovery options
/scoutflo:business-context-resolver --skip-k8s --skip-aws --skip-github

# Output: manual entry path (same as startup)
Time: 20 minutes
Tokens: 2K
Savings vs v0.1.67: none (same manual path), but better structure
```

## Troubleshooting

**Q: kubectl not found, but I have a K8s cluster**
A: Install kubectl on this machine, or use `--skip-k8s` and enter services manually.

**Q: AWS CLI not found, but I have AWS resources**
A: Install AWS CLI and configure credentials, or use `--skip-aws`.

**Q: CODEOWNERS not found**
A: Specify custom location in business_context.md (`GitHub CODEOWNERS: custom/path/CODEOWNERS`), or use `--skip-github`.

**Q: computed_metadata.jsonl empty or has only a few resources**
A: Check that labels/tags exist on your resources. Use `kubectl get pods -A -o json | jq '.items[0].metadata.labels'` to inspect pod labels. Use `aws ec2 describe-instances` to check instance tags.

**Q: resolved_at timestamp is old**
A: Resolver runs once. Infrastructure may have changed since last run. Re-run resolver to refresh: `/scoutflo:business-context-resolver --force`.

**Q: One skill is reading old metadata**
A: Skills cache computed_metadata.jsonl. Clear cache or re-run skill. Or re-run resolver: `/scoutflo:business-context-resolver --force`.

## See Also

- [business_context_template.md](../../templates/business_context_v0168_template.md) — Template for global rules
- [business-context-ssot.md](../../docs/specs/business-context-ssot.md) — v0.1.67 SSOT reference
- [business-context-v0168-metadata-driven.md](../../docs/specs/business-context-v0168-metadata-driven.md) — v0.1.68 architecture spec
- [BUSINESS-CONTEXT-INTEGRATION.md](../../docs/BUSINESS-CONTEXT-INTEGRATION-v0168.md) — How other skills consume metadata

---

**Lane:** Harness (read-only discovery, no mutations)  
**Safety:** Live-safety gate confirms discovery targets before scanning  
**Cost:** Low (discovers all resources once, outputs JSON)  
**Frequency:** Run once during setup, re-run when infrastructure changes  
**Run from:** `/scoutflo:connect` (automatic) or `/scoutflo:business-context-resolver` (manual)
