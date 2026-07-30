# Business Context — [Your Company Name]

**v0.1.68 Simplified Template — Metadata is auto-discovered, you only define global rules**

Save this as `~/.scoutflo/business_context.md`. Scoutflo will auto-discover your K8s labels, AWS tags, and team ownership — you just tell us how to interpret them.

---

## Global SLAs / SLOs

- **Production-Standard:** 99.9% (43.2 min/month error budget)
- **Production-Critical:** 99.95% (21.6 min/month error budget)
- **Staging:** 95%

---

## Teams

List your team names (e.g., from K8s team labels, AWS Team tags):

- **platform** — Kubernetes, SRE, infrastructure
- **payment** — Revenue-critical, PCI-DSS
- **api** — Customer-facing
- **database** — Data integrity, backups
- **internal** — Internal tooling

---

## Cost Sensitivity

- **Primary:** [High | Medium | Low]
  - **High:** ROI-first (biggest annual savings first)
  - **Medium:** Balanced
  - **Low:** Impact-first

---

## Global Exclusions

### Regions (never audit or modify)
```
- cn-* (legal/compliance)
- us-gov-* (government)
```

### Accounts (never audit or modify)
```
- sandbox (development)
- legacy-prod (being decommissioned)
```

### Services (never audit or modify)
```
- deprecated-* (sunset)
- v1-* (old versions)
- *-legacy (legacy)
```

---

## Risky Operations (require approval)

- Terminate EC2 instances → Approval required
- Delete RDS snapshots → Audit trail check first
- Modify IAM roles → Security team approval

---

## Metadata Mapping

**Scoutflo will use these to auto-discover your resources:**

### Kubernetes Labels
- Service label name: `service` (what field in your pod labels?)
- Team label name: `team` (what field in your pod labels?)
- Environment label name: `env` or `environment` (what field?)

### AWS Tags
- Service tag name: `Service` (what tag key on your EC2/RDS?)
- Team tag name: `Team` (what tag key?)
- Environment tag name: `Environment` (what tag key?)

### GitHub
- CODEOWNERS location: `ops/CODEOWNERS` (relative to repo root)

---

## Done!

Scoutflo will now:
1. Discover all your K8s/AWS/GitHub metadata
2. Apply global rules to all 1000+ resources
3. Generate computed_metadata.jsonl automatically
4. Respect guardrails on every audit

**No need to manually list services — Scoutflo does it.**
