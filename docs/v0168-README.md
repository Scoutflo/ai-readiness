# v0.1.68: Metadata-Driven Business Context Discovery

**Status:** ✅ Ready to implement  
**Target Release:** 2026-08-20  
**Phase:** Implementation (Week 3)

---

## What's New

**Metadata-driven resource discovery** — Auto-discover K8s labels, AWS tags, and GitHub CODEOWNERS to generate business context metadata automatically. No more manual resource-by-resource entry.

- ✅ **Auto-discovers** K8s services, AWS instances, GitHub code ownership
- ✅ **Generates** `computed_metadata.jsonl` with team, environment, SLA, escalation per resource
- ✅ **Scales** from manual (5 services) to enterprise (1000+) without code changes
- ✅ **Backward compatible** — v0.1.67 `business_context.md` still works
- ✅ **Optional** — Choose auto-discovery or manual entry based on your environment

## Impact

| Scenario | Setup Time | Token Cost | Savings |
|----------|-----------|-----------|---------|
| **Startup (5 services)** | 15 min | 1K | none (manual entry, same as v0.1.67) |
| **Mid-Market (150 services)** | 30 min | 5K | 50% time, 67% tokens |
| **Enterprise (1,000+ services)** | 35 min | 7K | 91% time, 86% tokens |
| **Air-gapped** | 20 min | 2K | none (manual, same as v0.1.67) |

## How It Works

**Layer 1: Global Rules** (define once)
- SLAs: Production-Standard (99.9%), Production-Critical (99.95%), Staging (95%)
- Teams: payment, platform, api, database, etc.
- Exclusions: sandbox-*, deprecated-*, etc.
- Cost sensitivity: high/medium/low

**Layer 2: Discovery Config** (configure sources)
- Enable K8s discovery? (read labels: service, team, environment)
- Enable AWS discovery? (read tags: Service, Team, Environment)
- Enable GitHub discovery? (read CODEOWNERS for team ownership)

**Layer 3: Auto-Generated Metadata**
- Output: `computed_metadata.jsonl` (one resource per line)
- Fields: resource_id, type, team, environment, sla, escalation, cost_sensitivity, resolved_at

**All audit skills read from one source** — consistent enforcement, no duplication.

## Getting Started

### 1. Define Global Rules (First Time)

Run `/scoutflo:connect` to create `~/.scoutflo/business_context.md`:

```markdown
## Global SLAs / SLOs
- Production-Standard: 99.9%
- Production-Critical: 99.95%
- Staging: 95%

## Teams
- payment: Revenue-critical, PCI-DSS
- platform: Kubernetes, SRE, infrastructure
- api: Customer-facing
- database: Data integrity, backups

## Global Exclusions
- Regions: cn-*, us-gov-*
- Services: deprecated-*, v1-*

## Cost Sensitivity
- Primary: high

## Discovery Configuration
- Kubernetes discovery: enabled
- AWS discovery: enabled
- GitHub CODEOWNERS: ops/CODEOWNERS
```

### 2. Run Discovery

```bash
/scoutflo:business-context-resolver
```

Output:

```
Discovering metadata...
  K8s: enabled (127 services found)
  AWS: enabled (1,180 instances found)
  GitHub: enabled (team ownership read)

✅ Metadata resolved for 1,307 resources
  📊 Resources resolved: 1,307
  📄 Output: ~/.scoutflo/computed_metadata.jsonl

📈 Summary:
  CRITICAL: 42
  STANDARD: 1,265
```

### 3. Audit Everything

All audit skills now read from `computed_metadata.jsonl`:

```bash
/scoutflo:audit-aws
/scoutflo:audit-gcp
/scoutflo:audit-all
```

Each skill:
- Skips excluded resources (sandbox, deprecated, etc.)
- Escalates critical services (higher severity, faster remediation)
- Respects cost sensitivity (prioritizes high-cost findings)

## Supported Customer Architectures

- **Kubernetes** (GKE, EKS, self-hosted) — discovers services + pod labels
- **AWS** (native + multi-account) — discovers EC2 + RDS with tags
- **GitHub** (public/private repos) — discovers CODEOWNERS file
- **Air-gapped** (no external access) — supports manual entry, no regression

## Integration Guide

See [BUSINESS-CONTEXT-INTEGRATION-v0168.md](BUSINESS-CONTEXT-INTEGRATION-v0168.md) for:
- Code patterns for all 10 audit/setup skills
- Backward compatibility approach
- Testing procedures

## Implementation Reference

See [v0168-IMPLEMENTATION.md](v0168-IMPLEMENTATION.md) for:
- Task-by-task implementation checklist
- Copy-paste code templates
- Testing + release procedure

## Technical Details

Resolver SKILL.md: [skills/business-context-resolver/SKILL.md](../skills/business-context-resolver/SKILL.md)  
Specification: [specs/business-context-v0168-metadata-driven.md](specs/business-context-v0168-metadata-driven.md)  
Template: [templates/business_context_v0168_template.md](../templates/business_context_v0168_template.md)

---

**Release date:** 2026-08-20  
**Backward compatible:** YES  
**Breaking changes:** None
