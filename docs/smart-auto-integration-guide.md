# Smart Auto Integration Guide (v0.1.69+)

## Overview

v0.1.69 introduces the Smart Auto Integration Pipeline, a three-phase system that orchestrates all 12 audit skills with automatic correlation, lifecycle tracking, exemption filtering, and topology-guided remediation. This guide explains how it works and how to use it.

## Architecture

### Three-Layer Pipeline

```
Phase 0: Initialize Shared State
├── Load business_context.md (teams, critical services, SLAs)
├── Load exemptions.yaml (suppressed findings)
├── Load topology.json (service relationships)
└── Load computed_metadata.jsonl (team/environment/tier per service)
    ↓
Phase 1-12: Run Audits with Shared State
├── Each audit reads SCOUTFLO_* env vars from Phase 0
├── Each audit generates findings.json
├── Each audit calls apply_all_integration_logic()
├── All findings appended to shared log (not individual files)
└── History ledger records completion per audit
    ↓
Phase 13: Automatic Integration
├── Correlate findings (detect overlaps, cascades)
├── Redact sensitive data
├── Analyze cost and ROI
├── Guide topology-aware remediation sequencing
├── Generate combined report
└── Send Slack brief
```

## Key Concepts

### Shared State

All 12 audits share state through environment variables:

| Variable | Content | Source |
|---|---|---|
| `SCOUTFLO_SESSION_ID` | Unique session identifier | UUID or timestamp |
| `SCOUTFLO_BUSINESS_CONTEXT` | Teams, critical services, SLAs | business_context.md |
| `SCOUTFLO_EXEMPTIONS` | Suppressed findings (C4) | exemptions.yaml |
| `SCOUTFLO_TOPOLOGY` | Service relationships (G5) | topology.json |
| `SCOUTFLO_METADATA` | Computed metadata per service | computed_metadata.jsonl |
| `SCOUTFLO_FINDINGS_LOG` | Shared append-only findings log | JSONL file |
| `SCOUTFLO_HISTORY_LOG` | Audit completion history (C1) | JSONL file |
| `SCOUTFLO_SHARED_STATE_DIR` | Base directory for all shared files | ~/.scoutflo/sessions/<id> |

### Integration Layers

Each audit applies eight integration layers to its findings before appending to shared log:

| Layer | Code | Function | Input |
|---|---|---|---|
| C1 | `log_to_history()` | Record audit completion | history ledger |
| C3 | `classify_lifecycle()` | Mark new/unchanged/regressed/resolved | previous-findings.json |
| C4 | `apply_exemptions()` | Filter suppressed findings | exemptions.yaml |
| B | `escalate_severity()` | Bump severity for critical services | business_context.md |
| Red | (Phase 13) | Redact API keys, tokens, secrets | regex patterns |
| Cor | (Phase 13) | Detect overlaps and cascades | all findings |
| G3 | `add_remediation()` | Map findings to setup skills | finding-remediation-map.json |
| G5 | (Phase 13) | Sequence fixes by topology | topology.json |

## Usage

### 1. Prepare Configuration

Create three files in `~/.scoutflo/` (or specify `SCOUTFLO_CONFIG`):

**business_context.md:**
```markdown
# Scoutflo Business Context

## Teams
- payments (tier: critical)
- platform (tier: critical)
- data (tier: standard)

## Critical Services
- payment-svc
- api-gateway
- database-primary

## Environment
production

## Cost Sensitivity
high

## SLAs
- Critical: 99.99%
- Standard: 99.5%

## Regions
Excluded:
- eu-west-1
- us-west-1
```

**exemptions.yaml:**
```yaml
- finding_id: AWS-001
  resource_id: staging-bucket
  reason: "Approved for testing"
  expires: "2026-12-31"

- finding_id: K8S-001
  resource_id: test-namespace
  reason: "Air-gapped environment"
  expires: "2026-12-31"
```

**topology.json:**
```json
{
  "services": [
    {
      "id": "payment-svc",
      "team": "payments",
      "tier": "critical",
      "provides": ["payments"],
      "consumes": ["database-primary", "cache-layer"]
    },
    {
      "id": "api-gateway",
      "team": "platform",
      "tier": "critical",
      "provides": ["api"],
      "consumes": ["auth-svc", "payment-svc"]
    }
  ]
}
```

### 2. Run the Pipeline

```bash
/scoutflo:audit-all
```

**Output:**
```
╔════════════════════════════════════════════════════════════════╗
║ PHASE 0: INITIALIZE SHARED STATE                              ║
╚════════════════════════════════════════════════════════════════╝

Session: session-1234567890
State dir: ~/.scoutflo/sessions/session-1234567890
Env vars exported:
  - SCOUTFLO_SESSION_ID
  - SCOUTFLO_BUSINESS_CONTEXT
  - SCOUTFLO_EXEMPTIONS
  - SCOUTFLO_TOPOLOGY
  - SCOUTFLO_METADATA
  - SCOUTFLO_FINDINGS_LOG
  - SCOUTFLO_HISTORY_LOG
  - SCOUTFLO_SHARED_STATE_DIR

╔════════════════════════════════════════════════════════════════╗
║ PHASE 1-12: RUN AUDITS WITH SHARED STATE                      ║
╚════════════════════════════════════════════════════════════════╝

Queued audits: audit-aws audit-gcp audit-lgtm audit-grafana ...

Phase 1: /scoutflo:audit-aws
  ✅ 23 findings, 18 applicable (5 exempted)
  ✅ Lifecycle: 5 new, 10 unchanged, 3 regressed
  ✅ Severity escalated: 4 findings (critical services)
  ✅ Remediation links: 18 → setup skills

Phase 2: /scoutflo:audit-gcp
  ✅ 12 findings, 11 applicable
  ...

╔════════════════════════════════════════════════════════════════╗
║ PHASE 13: INTEGRATION PIPELINE                                ║
╚════════════════════════════════════════════════════════════════╝

Phase 13a: Correlate
  ✅ 152 total findings
  ⚠ 8 overlaps detected (AWS-001 + GCP-001 = redundant)
  ⚠ 3 cascades detected (K8s-001 → ELK-002 → Grafana-001)

Phase 13b: Redact
  ✅ Scrubbed 12 API keys, 3 tokens, 15 AWS secrets

Phase 13c: Cost Analysis
  ✅ ROI top 5: fix stopped instances (-$200/mo), enable auto-scaling (-$150/mo), ...

Phase 13d: Topology Guide
  ✅ Fix sequence: payment-svc (critical first), cache-layer, data services

Phase 13e: Generate Report
  ✅ Combined report: combined-report.md

Phase 13f: Send Slack Brief
  ✅ Brief sent to #cloud-readiness

════════════════════════════════════════════════════════════════
COMPLETE
════════════════════════════════════════════════════════════════

All phases complete.
Session: session-1234567890
Results: ~/.scoutflo/sessions/session-1234567890
```

### 3. Review Results

**Shared findings log:**
```bash
cat ~/.scoutflo/sessions/<SESSION_ID>/findings.jsonl
```

**Combined report:**
```bash
cat ~/.scoutflo/sessions/<SESSION_ID>/combined-report.md
```

**History ledger:**
```bash
cat ~/.scoutflo/sessions/<SESSION_ID>/history.jsonl
```

## Troubleshooting

### No findings produced

**Symptom:** All audits run but combined report shows 0 findings.

**Causes:**
1. Business context not loaded — check `business_context.md` exists and `jq` can parse it
2. All findings exempted — check `exemptions.yaml` is not too broad
3. Configuration path wrong — verify `SCOUTFLO_CONFIG` or `~/.scoutflo/`

**Fix:**
```bash
# Check Phase 0 env vars
echo $SCOUTFLO_BUSINESS_CONTEXT | jq .
echo $SCOUTFLO_EXEMPTIONS | jq .

# Re-run Phase 0 only
source ~/.scoutflo/sessions/<SESSION_ID>/phase-0-init.sh
```

### Findings not escalated

**Symptom:** Critical service findings show normal severity instead of `critical`.

**Cause:** Service name mismatch between findings and `business_context.md`.

**Fix:**
```bash
# Check what services were marked critical
grep "critical" business_context.md

# Check finding affected_resource
jq '.affected_resource' ~/.scoutflo/sessions/<SESSION_ID>/findings.jsonl | sort -u

# Match them — fix capitalization/naming
```

### Remediation links missing

**Symptom:** Findings lack `next_safe_action` or `remediation_anchor`.

**Cause:** Finding ID not in `finding-remediation-map.json`.

**Fix:**
```bash
# Check your finding IDs
jq '.id' ~/.scoutflo/sessions/<SESSION_ID>/findings.jsonl | sort -u

# Add missing mappings to docs/finding-remediation-map.json
# Re-run audit skill only (Phase 1-12 skips unchanged audits if implemented)
```

## Integration with Individual Audits

When using a single audit skill outside the full pipeline, shared state is optional:

```bash
# Individual audit (shared state not needed)
/scoutflo:audit-aws
cat scoutflo-audits/aws/<date>/findings.json

# Individual audit with shared state (if business context matters)
export SCOUTFLO_BUSINESS_CONTEXT='{"critical_services":["payment-svc"]}'
/scoutflo:audit-aws
# Findings will be escalated for payment-svc
```

## Version Compatibility

- **v0.1.68 and earlier:** No smart auto integration. Run audits individually.
- **v0.1.69+:** All audits support shared state. Use `/scoutflo:audit-all` for full pipeline.
- **Backward compatible:** Individual audit commands still work. They ignore `SCOUTFLO_*` if not set.

## Next Steps

1. Set up `business_context.md` for your organization
2. Create `exemptions.yaml` for known findings to suppress
3. Define `topology.json` for service relationships
4. Run `/scoutflo:audit-all` to execute the full pipeline
5. Review `combined-report.md` and take action on findings
