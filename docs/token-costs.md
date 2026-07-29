# Token Costs and Pricing

## Overview

Scoutflo AI Readiness audit runs use Claude models via Claude Code on your machine. **All model invocations are billed to your Claude subscription or API account — nothing is sent to or billed by Scoutflo.** This page helps you understand and estimate the token consumption for your audit suite.

## Measured Costs (v0.1.63, Haiku 4.5)

### Per-Audit Token Consumption

| Audit Skill | Estate Size | Input Tokens | Output Tokens | Total | Cost (Haiku) |
|---|---|---|---|---|---|
| `audit-datadog` | Medium | ~45K | ~20K | ~65K | ~$0.052 |
| `audit-pagerduty` | Medium | ~40K | ~18K | ~58K | ~$0.046 |
| `audit-elk` | Medium | ~35K | ~17K | ~52K | ~$0.042 |
| `audit-jsm` | Small | ~32K | ~16K | ~48K | ~$0.038 |
| `audit-zenduty` | Small | ~35K | ~16K | ~51K | ~$0.041 |
| `audit-groundcover` | Small | ~30K | ~15K | ~45K | ~$0.036 |
| `audit-grafana` | Medium | ~28K | ~14K | ~42K | ~$0.034 |
| `audit-sentry` | Small | ~25K | ~13K | ~38K | ~$0.030 |
| **Average** | **~45K per audit** | — | — | — | **~$0.047** |

### Full Suite (12 Audits, All Configured)

- **Projected total tokens:** ~702K (mix of small and medium estates)
- **Projected total cost:** ~$0.56 at Haiku pricing
- **Cost range:** $0.40–$0.80 depending on estate complexity

### Factors That Affect Token Count

1. **Estate size** (number of services/resources, hosts, integrations):
   - Small estate (1–5 clusters, <50 services): ~40–50K tokens per audit
   - Medium estate (5–15 clusters, 50–200 services): ~55–70K tokens per audit
   - Large estate (>15 clusters, >200 services): ~100K+ tokens per audit

2. **Configuration complexity**:
   - Simple configs (few rules, dashboards, monitors): lower token count
   - Complex setups (hundreds of alert rules, many integrations): higher token count

3. **Model choice**:
   - Haiku 4.5: $0.80 per 1M input tokens (recommended, fast, sufficient)
   - Sonnet 5: $3 per 1M input tokens
   - Opus 5: $15 per 1M input tokens

4. **Audit scope**:
   - Running a single audit: 40–70K tokens
   - Running all 12 audits (`/scoutflo:audit-all`): ~700K tokens
   - Running a subset: proportional to audits included

## How to Control Costs

### Option 1: Run Targeted Audits
Instead of `/scoutflo:audit-all`, run only the audits you need:

```bash
# Run only the audits you care about:
/scoutflo:audit-grafana
/scoutflo:audit-prometheus-alerting
/scoutflo:audit-sentry
```

This keeps costs low while you validate one stack at a time.

### Option 2: Schedule Recurring Audits with Cost Caps
Use `/scoutflo:schedule-audits` to run audits weekly or monthly instead of on-demand. This lets you spread costs over time and catch drift early.

### Option 3: Use Smaller Model (Haiku)
Haiku 4.5 is the default and recommended choice:
- **Fast:** ~2–5 minutes per audit (vs. 3–10 min for Sonnet)
- **Accurate:** Performs equally well for structured data analysis
- **Cheap:** ~$0.80 per 1M input tokens

Do not override the model unless you have a specific need for a larger model (e.g., complex custom analysis).

## Real-World Example

**CoinDCX Production Audit (Medium Estate)**
- 12 integrations, ~80 services, 3 clusters
- Full suite run: `/scoutflo:audit-all`
- **Tokens consumed:** ~720K
- **Cost:** ~$0.58 at Haiku pricing
- **Time:** ~40 minutes (wall-clock, ~5 min per audit, parallel runs possible)
- **Output:** 12 reports with findings, scores, remediation advice

**Cost amortized over 6 months (monthly audits):** ~$3.50 / month, or $0.07 per integration.

## Billing

- **Claude subscription users:** Token costs count against your subscription quota
- **Claude API users:** Token costs are billed to your Anthropic API account
- **No separate Scoutflo billing:** All costs go to your Claude account, not to Scoutflo

Verify token consumption in:
- Claude Code: Hover over the model name in the top-right to see the turn's token count
- Claude API: Check your usage dashboard at console.anthropic.com

## Estimating Your Estate

To estimate your own costs:

1. **Count your resources:**
   - Number of Kubernetes clusters
   - Number of services/workloads
   - Number of alert rules, dashboards, monitors
   - Number of integrations (Grafana, Prometheus, Sentry, etc.)

2. **Apply the baseline:**
   - Small estate (1 cluster, <50 resources): ~45K tokens per audit
   - Medium estate (3–5 clusters, 50–200 resources): ~60K tokens per audit
   - Large estate (>5 clusters, >200 resources): ~80K+ tokens per audit

3. **Calculate:**
   - Pick your audits: e.g., Grafana, LGTM, PagerDuty, Sentry = 4 audits
   - Multiply baseline × number of audits: e.g., 60K × 4 = 240K tokens
   - Multiply by per-million cost: 240K × ($0.80 / 1M) = ~$0.19

## Frequently Asked Questions

**Q: Why does a full audit run cost more than a single audit?**
A: Each audit independently discovers and analyzes your entire estate. Costs don't compound, but they also don't get cheaper when you run multiple audits together — each audit is a separate analysis pass over the same resources.

**Q: Can I reduce token usage by pre-filtering my resources?**
A: Not directly. Audits are read-only and don't reduce their queries based on resource count — they aim for breadth (full coverage). You can reduce costs by running fewer audits or smaller subsets of audits, not by filtering within an audit.

**Q: What if my estate is very large (>500 services)?**
A: Token consumption will scale. A very large estate might consume 150–250K tokens per audit. Consider running audits in batches (e.g., one audit per day on a schedule) to spread costs and track drift over time rather than all at once.

**Q: Can I use a cached audit result to avoid re-running?**
A: Yes. The audit reports are saved to `./scoutflo-audits/<target>/history.jsonl` and re-runs compute the delta (what changed since last time). Running the same audit within a few days is cheaper because the state hasn't changed much. Leverage this for rapid iteration: run once, fix issues, run again to verify the delta.

**Q: Does Scoutflo get a copy of my estate data for analysis?**
A: No. All analysis happens on your machine in Claude Code. Your credentials stay in `~/.scoutflo/` and your reports stay in `./scoutflo-audits/` — nothing is sent to Scoutflo's servers. See [docs/install.md](install.md) for the full data-residency guarantee.
