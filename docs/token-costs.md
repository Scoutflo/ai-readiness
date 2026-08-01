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

**Token consumption (same for all models):** ~702K tokens

**Cost by model:**

| Model | Cost | Time | Notes |
|---|---|---|---|
| **Haiku 4.5** | **$0.56** | ~60 min | ✓ Recommended |
| Sonnet 5 | $2.11 | ~120 min | 3.8× more expensive |
| Opus 5 | $10.53 | ~180 min | 18.8× more expensive |

**Cost range** (depending on estate complexity): 
- Haiku: $0.40–$0.80
- Sonnet: $1.50–$3.00
- Opus: $7.50–$15.00

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

## Model Selection Guide

### Which Model Should You Use?

**TL;DR:** Use Haiku 4.5 (default). Change only if you have a specific reason.

#### Haiku 4.5 (Default — Recommended)

**Best for:** All audits (this is what they're designed for).

- **Cost:** $0.80 per 1M input tokens
- **Speed:** 2–5 minutes per audit
- **Accuracy:** 100% for structured data tasks (audit configurations, JSON parsing, condition checking)
- **Trade-offs:** None for audits

**Why it's best:**
- Audits are **read-only, structured analysis** — no reasoning needed
- Haiku excels at parsing JSON, YAML, structured logs, and applying scoring rules
- Fast enough for interactive runs or scheduled audits
- Cheap enough for daily runs (full suite ~$0.56)

**Verified:** All 8 test audits in v0.1.64 passed conformance using Haiku with zero failures.

#### Sonnet 5 (Consider If...)

**Cost:** $3 per 1M input tokens (3.75× more than Haiku)  
**Speed:** 3–10 minutes per audit (slower)  
**Accuracy:** Same as Haiku for audits

**Use Sonnet only if you're:**
- Writing custom analysis on top of audit findings
- Generating runbooks or remediation advice
- Doing cross-audit reasoning (e.g., "which two services are most likely causing this incident?")
- Need slightly better performance on very complex estate analysis

**For standard audits:** Sonnet adds cost with no accuracy gain.

#### Opus 5 (Rarely Needed)

**Cost:** $15 per 1M input tokens (18.75× more than Haiku)  
**Speed:** 5–15 minutes per audit (much slower)  
**Accuracy:** Same as Haiku for audits

**Use Opus only if:**
- You're doing advanced AI reasoning over the audit findings
- You need to synthesize insights across 12 audits with complex logic
- Full suite cost is <$11 for you

**For audits alone:** Opus is overkill and too expensive.

---

### How to Override the Model

If you want to use Sonnet or Opus instead of Haiku:

**Option 1: Via Claude Code settings**
- Open Claude Code settings (Claude.app → Settings)
- Change the "Model" dropdown to Sonnet 5 or Opus 5
- Run `/scoutflo:audit-*` as normal

**Option 2: Per-audit override**
- Run `/scoutflo:audit-grafana` as usual
- Before Claude starts, select the model from the picker

**Note:** The plugin itself doesn't have a model-selection flag. You control it via Claude Code's global model setting.

---

### Cost Calculator: Pick Your Model

Use this table to estimate your costs:

```
Full suite (702K tokens):
  Haiku 4.5:    702K × $0.80/1M = $0.56
  Sonnet 5:     702K × $3/1M    = $2.11
  Opus 5:       702K × $15/1M   = $10.53

Single audit (~60K tokens, average):
  Haiku 4.5:    60K × $0.80/1M  = $0.048
  Sonnet 5:     60K × $3/1M     = $0.18
  Opus 5:       60K × $15/1M    = $0.90

Weekly recurring (52 weeks, 12 audits each):
  Haiku 4.5:    ~$29/year
  Sonnet 5:     ~$110/year
  Opus 5:       ~$548/year
```

---

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

### Option 3: Choose the Right Model

The toolkit defaults to **Haiku 4.5**, which is the best choice for audits. Here's why and when to consider alternatives:

#### Model Comparison

| Model | Speed | Accuracy | Cost | Use When |
|---|---|---|---|---|
| **Haiku 4.5** (default) | 2–5 min/audit | ★★★★★ | $0.80/1M | All structured audits (recommended) |
| Sonnet 5 | 3–10 min/audit | ★★★★★ | $3/1M | Complex custom analysis or reasoning |
| Opus 5 | 5–15 min/audit | ★★★★★ | $15/1M | Very rare edge cases (not needed here) |

#### Why Haiku for Audits?

Audits are **structured data tasks** — read config, parse JSON/YAML, check conditions, score findings. This doesn't need reasoning power:
- ✅ Haiku is fast enough (2–5 minutes per audit)
- ✅ Haiku is accurate enough (same scoring as larger models on audit-type work)
- ✅ Haiku is 3.75× cheaper than Sonnet, 18.75× cheaper than Opus

**Measured:** 8 completed audits all used Haiku and passed conformance with zero failures.

#### When NOT to Use Haiku

Only override to a larger model if you're doing:
- **Custom reasoning** over findings (e.g., "explain why this alert rule is noisy")
- **Creative synthesis** (e.g., writing runbooks from findings)
- **Complex decision trees** (rare)

For these, Sonnet 5 is a good middle ground (3–10× more reasoning power, 3.75× higher cost).

#### Cost Impact Examples

**Full suite (12 audits, all Haiku):**
- 702K tokens × $0.80/1M = **$0.56**
- Time: ~60 minutes

**Same suite, all Sonnet:**
- 702K tokens × $3/1M = **$2.11** (3.8× more expensive)
- Time: ~120 minutes (slower)

**Same suite, all Opus:**
- 702K tokens × $15/1M = **$10.53** (18.8× more expensive)
- Time: ~180 minutes (much slower)

---

**Recommendation:** Use Haiku (default). Don't override unless you have a specific reason.

## Real-World Example

**Large-estate production audit (Medium Estate)**
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
