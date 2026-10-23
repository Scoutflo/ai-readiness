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

## Resource Intent (why something that looks idle is meant to be idle)

Some resources are **supposed** to look wasteful. A warm standby sized for
failover, a DR replica, a backup target, and a deliberately pre-scaled cluster
are indistinguishable from gross over-provisioning by every signal an audit can
read — low CPU, low request rate, big instance. The difference is *intent*, and
intent is a fact about your plans that exists nowhere in telemetry.

Declare them here and audits will stop recommending you shrink the thing whose
purpose is to be big before it is needed. Leave it blank and those resources
will be reported — which is deliberate: an audit that silently assumed "probably
intentional" would also silence the genuinely forgotten resources you are paying
for.

```yaml
resource_intent:
  # - match:    how to recognise the resource. One of:
  #               cluster / namespace / workload / instance_id / resource_name
  #   intent:   standby | dr | backup | pre-scaled | accepted-tradeoff
  #   why:      one line in your words — this is quoted back in the report
  #   review_by: optional YYYY-MM-DD; after this date the audit asks you to
  #              re-confirm instead of staying silent forever
  #
  # - cluster: <cluster-name>
  #   intent: standby
  #   why: warm standby for the primary region; sized to take full production load on failover
  #   review_by: 2027-01-01
```

- **`standby` / `dr`** — capacity held ready for failover. Idle is the point.
- **`backup`** — a destination for backups; low utilisation is expected.
- **`pre-scaled`** — deliberately over-provisioned ahead of known demand.
- **`accepted-tradeoff`** — you know, you have decided, and you do not want to
  be asked again (give a `review_by` so "do not ask again" has an end date).

What a declaration does **not** do: it does not hide the observation. The report
still states the resource and its utilisation, with your `why` beside it — so a
standby that has drifted to three times the capacity its purpose needs is still
visible. It removes the *verdict*, not the *fact*.

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

## Unit of Delivered Value

**What does your business count?** This is the one input nobody can infer for you, and it is what
turns a cost report into cost *per unit* — the number that tells you whether spending more is a
problem or just growth. A bill up 12% while volume is up 20% means your unit cost **fell**.

Name the metric you already graph; if it is on a dashboard your team trusts, it is the right one.
Leave this out and the audit reports per-namespace and per-project spend instead, which is useful
but is not unit economics.

```yaml
unit_metrics:
  - name: "<what you count, in your words>"   # sessions · minutes · participants · recordings ·
                                              # requests · conversations · documents · orders
    query: '<your own metric query>'          # e.g. sum(increase(app_sessions_total[30d]))
    source: prometheus                        # prometheus | victoriametrics | thanos | cloud-monitoring
    scope: all                                # all | project:<id> | cluster:<name> | namespace:<ns>
    per: 1000                                 # report cost per 1000 units; use 1 for expensive units
```

Declare more than one if your product has more than one — a platform billing both conversations and
recordings has two, and each is reported on its own. They are never added together.

**Scope must match the spend it will be divided by.** Whole-product volume against one cluster's
spend understates the unit cost by however much of the product runs elsewhere; the audit excludes a
unit rather than publish that. See `audit-cost/references/unit-economics.md` §5.

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
