# Correlation Engine Specification

**Internal Spec Only — Local Development**

Location: `scoutflo-audits/<date>/correlation.json`

---

## Overview

After `audit-all` completes, correlation engine:
1. Analyzes all findings across 12 audit skills
2. Detects coverage overlaps (AWS + Grafana monitoring same service)
3. Detects cascade risks (A fails → B disabled → C fails)
4. Applies business context filters (staging gaps are intentional)
5. Maps service criticality

Output: `correlation.json` with deduplicated, prioritized findings.

---

## correlation.json Schema

```json
{
  "version": "1.0",
  "generated_at": "2026-07-30T14:30:00Z",
  "audit_date": "2026-07-30",
  "total_findings_raw": 87,
  "total_findings_deduplicated": 42,
  "total_overlaps_detected": 23,
  "total_cascades_detected": 5,
  
  "overlaps": [
    {
      "overlap_id": "OVL-001",
      "type": "redundant_monitoring",
      "services": ["payment-svc", "checkout-svc"],
      "findings": [
        {
          "skill": "audit-aws",
          "finding_id": "AWS-023",
          "title": "CloudWatch Alarms Not Configured",
          "severity": "high"
        },
        {
          "skill": "audit-grafana",
          "finding_id": "GRAFANA-018",
          "title": "Grafana Dashboard Missing Alert Rule",
          "severity": "high"
        }
      ],
      "redundancy_level": "full",
      "recommendation": "Remove CloudWatch alarm (Grafana is primary)"
    },
    {
      "overlap_id": "OVL-002",
      "type": "partial_coverage",
      "services": ["database-svc"],
      "findings": [
        {
          "skill": "audit-aws",
          "finding_id": "AWS-045",
          "title": "RDS Backup Not Enabled",
          "severity": "critical"
        },
        {
          "skill": "audit-kubernetes",
          "finding_id": "K8S-012",
          "title": "PersistentVolume Missing Backup Policy",
          "severity": "high"
        }
      ],
      "redundancy_level": "partial",
      "recommendation": "Both needed (RDS + K8s backups are complementary)"
    }
  ],
  
  "cascades": [
    {
      "cascade_id": "CASC-001",
      "chain_length": 4,
      "root_cause": {
        "finding_id": "AWS-055",
        "title": "MySQL Master Instance Unhealthy",
        "service": "database-svc",
        "impact": "Database unavailable"
      },
      "effects": [
        {
          "step": 1,
          "finding_id": "GRAFANA-022",
          "title": "Alert Rule Disabled (No Database Connection)",
          "service": "monitoring-svc",
          "condition": "if root_cause happens"
        },
        {
          "step": 2,
          "finding_id": "PAGERDUTY-008",
          "title": "Incident Cannot Be Created (No Alert Trigger)",
          "service": "incident-svc",
          "condition": "if step 1 happens"
        },
        {
          "step": 3,
          "finding_id": "AWS-089",
          "title": "Backup Job Fails Silently (Database Unavailable)",
          "service": "backup-svc",
          "condition": "if step 2 happens AND no manual intervention"
        }
      ],
      "fix_order": [
        {
          "priority": 1,
          "finding_id": "AWS-055",
          "action": "Fix MySQL master instance (enable ha, increase resources)",
          "tokens_to_fix": 8000,
          "estimated_time": "2-4 hours"
        },
        {
          "priority": 2,
          "finding_id": "GRAFANA-022",
          "action": "Enable alert rule with circuit-breaker (fail gracefully)",
          "tokens_to_fix": 2000,
          "estimated_time": "30 min"
        },
        {
          "priority": 3,
          "finding_id": "AWS-089",
          "action": "Add backup retry logic with exponential backoff",
          "tokens_to_fix": 3000,
          "estimated_time": "1 hour"
        }
      ],
      "token_cost_comparison": {
        "without_topology": 35000,
        "with_topology": 11000,
        "savings": "69%"
      }
    }
  ],
  
  "business_context_filters": {
    "staging_only_gaps": [
      {
        "finding_id": "AWS-012",
        "title": "CloudFront HTTPS Not Enforced",
        "environment": "staging",
        "severity_original": "high",
        "severity_adjusted": "low",
        "reason": "Intentional in staging (testing HTTP behavior)",
        "mark_as_wontfix": true
      }
    ],
    "production_gaps": [
      {
        "finding_id": "AWS-023",
        "title": "CloudWatch Alarms Not Configured",
        "environment": "production",
        "severity_original": "high",
        "severity_adjusted": "critical",
        "reason": "Production requires monitoring",
        "mark_as_wontfix": false
      }
    ],
    "environment_breakdown": {
      "staging": {
        "total_findings": 34,
        "filtered_to_low": 12,
        "actionable_findings": 22
      },
      "production": {
        "total_findings": 53,
        "filtered_to_low": 3,
        "actionable_findings": 50
      }
    }
  },
  
  "service_criticality": [
    {
      "service_name": "payment-svc",
      "criticality": "critical",
      "sla_uptime_percent": 99.99,
      "team": "payments-team",
      "findings_critical": 8,
      "findings_high": 12,
      "findings_medium": 5,
      "findings_low": 2,
      "total_findings": 27
    },
    {
      "service_name": "analytics-svc",
      "criticality": "low",
      "sla_uptime_percent": 95.0,
      "team": "data-team",
      "findings_critical": 0,
      "findings_high": 1,
      "findings_medium": 3,
      "findings_low": 8,
      "total_findings": 12
    }
  ],
  
  "deduplicated_findings": [
    {
      "dedup_id": "DEDUP-001",
      "master_finding": {
        "skill": "audit-aws",
        "finding_id": "AWS-023",
        "title": "CloudWatch Alarms Not Configured",
        "severity": "high",
        "services": ["payment-svc"],
        "description": "Payment service has no CloudWatch alarms for error rates."
      },
      "duplicates": [
        {
          "skill": "audit-grafana",
          "finding_id": "GRAFANA-018",
          "reason": "Same service, same issue, different tool"
        }
      ],
      "action": "Fix once (AWS CloudWatch alarm setup)"
    }
  ],
  
  "metadata": {
    "audit_scope": ["critical-services"],
    "environment": "production",
    "business_context": {
      "team": "platform-team",
      "cost_sensitivity": "high",
      "sla_requirement": "99.9%"
    },
    "skills_included": [
      "audit-aws",
      "audit-grafana",
      "audit-sentry",
      "audit-pagerduty",
      "audit-lgtm",
      "audit-gcp",
      "audit-digitalocean",
      "audit-datadog",
      "audit-kubernetes",
      "audit-github",
      "audit-jira",
      "audit-zenduty"
    ]
  }
}
```

---

## Algorithm: Overlap Detection

### Input
- 87 raw findings from 12 audit skills
- topology.json (service metadata)

### Logic

```
for each finding F1:
    for each finding F2 where F1.skill != F2.skill:
        if F1.services overlap with F2.services:
            if F1.title_similarity > 0.8 (using fuzzy match):
                OVERLAP DETECTED
                
                classify:
                    if both findings describe the SAME gap:
                        redundancy_level = "full" (fix once)
                    else if findings are complementary:
                        redundancy_level = "partial" (fix both)
                    else if findings are independent:
                        redundancy_level = "none" (not an overlap)
                        
                if redundancy_level in [full, partial]:
                    add to overlaps array
                    recommendation = "fix primary, skip redundant"
```

### Example: AWS-023 & GRAFANA-018

```
F1 (AWS-023):
  title: "CloudWatch Alarms Not Configured"
  service: "payment-svc"
  
F2 (GRAFANA-018):
  title: "Grafana Alert Rule Missing"
  service: "payment-svc"

similarity("CloudWatch Alarms", "Grafana Alert") > 0.8? YES (both are alarms)
services overlap? YES (both payment-svc)

→ OVERLAP DETECTED: "redundant_monitoring"
→ redundancy_level: "full" (one service, one alarm, same effect)
→ recommendation: "Remove CloudWatch alarm, use Grafana only"
```

---

## Algorithm: Cascade Detection

### Input
- Deduplicated findings
- topology.json (service relationships)
- audit findings with dependencies

### Logic

```
for each finding F:
    if F.can_disable_monitoring or F.can_disable_alerting:
        FIND downstream effects:
            lookup services that depend on F.service
            for each dependent service S:
                if S has findings that assume monitoring works:
                    DEPENDENT FINDING FOUND
                    add to cascade chain
                    
        if cascade chain length >= 2:
            CASCADE RISK DETECTED
            compute fix_order (topological sort)
            estimate tokens (sum of all fixes)
```

### Example: MySQL Crash → Alert Disabled → Backup Fails

```
Root cause: AWS-055 "MySQL Master Unhealthy"
  can_disable_monitoring? YES (database down = no metrics)
  
Dependent finding: GRAFANA-022 "Alert Rule Disabled"
  reason: monitoring queries fail
  
Dependent finding: AWS-089 "Backup Job Fails"
  reason: backup queries the database
  
Cascade chain:
  [AWS-055] → [GRAFANA-022] → [AWS-089]
  
Fix order:
  1. AWS-055 (fix root, 8000 tokens)
  2. GRAFANA-022 (enable with failover, 2000 tokens)
  3. AWS-089 (add retry logic, 3000 tokens)
  
Total with topology: 11K tokens
Total without topology: 35K tokens (would try all three independently)
Savings: 69%
```

---

## Algorithm: Business Context Filtering

### Input
- All findings
- topology.json:business_context (team, environment, sla)

### Logic

```
for each finding F:
    if topology.business_context.environment == "staging":
        if F.title matches known_staging_only_patterns:
            # Known intentional gaps in staging
            severity_adjusted = "low"
            mark_as_wontfix = true
        else:
            # Assess if this is staging-specific
            if F.description mentions "staging" or "testing":
                severity_adjusted = downgrade_one_level(F.severity)
                
    if topology.business_context.environment == "production":
        if F.severity == "low":
            # Production = more strict
            severity_adjusted = "medium"
            
    if topology.business_context.sla_requirement == "99.99%":
        if F.impacts_availability:
            severity_adjusted = upgrade_one_level(F.severity)
```

### Known Staging-Only Patterns

```
"HTTPS Not Enforced" (testing HTTP)
"Self-Signed Certificates" (testing only)
"Basic Auth Enabled" (testing, not production)
"Debug Logging Enabled" (testing, not production)
"Rate Limiting Disabled" (testing high load)
```

---

## Algorithm: Service Criticality Mapping

### Input
- topology.json:services (with criticality, sla, team)
- findings per service

### Logic

```
for each service S:
    read criticality from topology.json
    
    count findings by severity:
        findings_critical = count(severity == critical)
        findings_high = count(severity == high)
        findings_medium = count(severity == medium)
        findings_low = count(severity == low)
        
    weight by criticality:
        if S.criticality == "critical":
            findings_critical *= 2
            findings_high *= 1.5
            
        if S.criticality == "low":
            findings_critical *= 0.5
            findings_high *= 0.8
```

---

## Performance Targets

| Scenario | Input | Max Time | Max JSON Size |
|----------|-------|----------|---------------|
| Small estate | 100 findings | 2 sec | 50 KB |
| Medium estate | 500 findings | 10 sec | 250 KB |
| Large estate (CoinDCX) | 1000+ findings | 30 sec | 1 MB |

---

## Storage & Caching

### Location

```
scoutflo-audits/
├── 2026-07-30/
│   ├── audit-aws/
│   ├── audit-grafana/
│   ├── ...
│   └── correlation.json  ← Generated here
```

### Generation Trigger

```
after audit-all completes:
    if all 12 audits are in scoutflo-audits/<date>/:
        run correlation engine
        generate correlation.json
        
if re-running correlation (user asks for refresh):
    correlation --refresh 2026-07-30
    regenerate correlation.json (overwrites)
```

### Cache

```
Cache correlation.json if:
  - Generated in last 24 hours AND
  - No new audits added since generation
  
Invalidate cache if:
  - topology.json changed
  - New audit results added
  - User calls --refresh
```

---

## Testing

### Unit Tests

```bash
test_overlap_detection:
  - AWS-023 (CloudWatch) + GRAFANA-018 (Grafana)
  - Assert overlap_id generated
  - Assert redundancy_level: full
  - Assert recommendation provided

test_cascade_detection:
  - MySQL crash finding
  - Assert downstream effects found
  - Assert fix_order: [AWS-055, GRAFANA-022, AWS-089]
  - Assert token_cost_comparison calculated

test_business_context_filtering:
  - Finding in staging environment
  - Assert severity downgraded
  - Assert mark_as_wontfix: true
  - Finding in production
  - Assert severity unchanged or upgraded

test_service_criticality:
  - Critical service with high finding
  - Assert weighted correctly
  - Low service with high finding
  - Assert weighted lower
```

### Integration Test

```bash
test_full_correlation:
  - Run audit-all (mock 100 findings from 12 skills)
  - Call correlation engine
  - Assert correlation.json generated
  - Assert overlaps >= 5
  - Assert cascades >= 1
  - Assert deduplicated_findings count < raw findings count
```

---

**This is internal spec. Not shipped to customers.**

