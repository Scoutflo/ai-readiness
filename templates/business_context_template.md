# Business Context — [Your Company Name]

**This file defines guardrails, SLAs, SLOs, and custom rules for your Scoutflo audits.**

Save this as `~/.scoutflo/business_context.md` and customize for your environment.

---

## Environment

- **Name:** [e.g., Production]
- **Stage:** [prod/staging/dev]
- **Region Strategy:** [Single/Multi-region, which regions]
- **Risk Level:** [Low/Medium/High]
- **Approval Gate:** [Team/Manager approval required? Who?]

---

## Environment Map (per-environment access + SLA)

Define each environment you operate and how the toolkit reaches it, so a single
audit run targets the right account/profile/cluster per environment and applies
that environment's own SLA. One row per environment; add as many as you run.

| Environment | AWS profile | GCP project | K8s context / cluster | Region | Uptime SLA | Notes |
|---|---|---|---|---|---|---|
| production | [aws profile] | [gcp project] | [kube context] | [region] | 99.95% | [e.g. customer-facing] |
| staging | [aws profile] | [gcp project] | [kube context] | [region] | 99.5% | [e.g. lower priority] |
| dr | [aws profile] | [gcp project] | [kube context] | [region] | 99.9% | [warm standby] |

- Different environments may have **different SLAs** — state each per row above; a
  staging gap is judged against staging's SLA, not production's.
- Different environments may use **different cloud credentials** — the profile /
  project / context columns tell each audit which target to use for that
  environment, so you never audit staging with the production profile.

---

## SLAs / SLOs

| Service | SLA | SLO (Error Budget) |
|---|---|---|
| [Service A] | 99.9% | [Calculate error budget] |
| [Service B] | 99.95% | [Calculate error budget] |

---

## Cost Sensitivity

- **Primary:** [High/Medium/Low]
  - **High:** ROI-first (biggest annual savings recommendations first)
  - **Medium:** Balanced (mixed prioritization)
  - **Low:** Impact-first (customer-facing issues before cost)
- **Budget:** [e.g., $500/month waste acceptable; >$500 requires escalation]

---

## Critical Services (Never Auto-Fix Without Approval)

List services that MUST have explicit approval before ANY changes:

- `[Service A]` (reason: revenue impact / data risk / customer-facing)
- `[Service B]`

---

## Exclusions (Never Audit or Modify)

### Regions
```
- [Region A] (reason: legal/compliance/cost)
- [Region B]
```

### Accounts
```
- [Account name] (reason: sandbox/legacy/third-party)
```

### Services
```
- [Service name] (reason: sunset/vendor-managed/temporary)
```

### Resources (by tag or name)
```
- Resources matching tag [key:value] (reason: shared testing)
- [Resource name pattern] (reason: temporary)
```

---

## Risky Operations (Blocked by Default)

These require explicit approval before execution:

1. **[Operation 1]** → Approval from [who?]
2. **[Operation 2]** → Requires [what check?] first
3. **[Operation 3]** → Approval from [team]

---

## Token Consumption Rules

- **Max per audit cycle:** [e.g., 50K tokens/week for unchanged estates]
- **Threshold:** If approaching limit, audit skips [which services?]
- **Escalation:** Runs exceeding limit require [notification/approval?]

---

## Audit Strategy

### Scheduling
- **Frequency:** [Daily/Weekly/On-demand]
- **Skip Windows:** [When NOT to audit — deployments, maintenance windows]
- **On-Demand:** When can users run `/scoutflo:audit-all --force`?

### Scope Selection
- **Default:** [All regions? All services? Critical-only?]
- **Cost-focused:** [Special runs for cost optimization — when/what services?]
- **Compliance:** [Special runs for compliance — when/what services?]

### Approval Requirements
- **Findings in critical services:** [Approval required? From whom?]
- **Findings in staging:** [Team notification? Slack channel?]
- **Findings in deprecated services:** [Ignore? Document?]

---

## Notification Preferences

- **Success:** [Silent / Notification]
- **Skip (unchanged):** [Silent / Log]
- **New findings in prod:** [Slack #channel / Email team / Both]
- **Critical service findings:** [PagerDuty alert / Email with approval gate / Ticket in Jira]
- **Deprecated service findings:** [Ignore / Log only]

---

## Custom Runbooks (Team Procedures)

### Scenario: [Service Name] Outage

If [Service A] appears in findings with critical severity:

1. [First action — who to notify?]
2. [Second action — approval required?]
3. [Third action — validation step]
4. [Post-fix action — monitoring/audit]

### Scenario: Cascade Failure Detected

If correlation engine detects cascades (e.g., database crash → monitoring down):

1. [Priority — fix root cause first?]
2. [Escalation — who to notify?]
3. [Validation — time to wait before intervening?]

---

## Compliance & Audit

- **Audit trail:** Location of audit logs
- **Compliance:** Frequency of reviews
- **Retention:** How long to keep logs?
- **Reporting:** Who receives reports? How often?

---

## Custom Rules (free-form)

Anything the sections above do not capture. Write plain-language rules the
audits and setups should honor — the toolkit reads this section verbatim. For
example: "Never page on-call for staging between 22:00–07:00 IST", "treat any
finding on the payments namespace as critical regardless of environment",
"our retention policy for EBS snapshots is 14 days".

- [your rule]
- [your rule]

---

Save this file as `~/.scoutflo/business_context.md` to activate custom guardrails.
Re-run `/scoutflo:business-context` any time to update it interactively, or edit
it directly — the file is the source of truth.
