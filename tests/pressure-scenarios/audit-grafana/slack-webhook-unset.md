# audit-grafana: Slack webhook variable unset

**Failure mode:** slack.webhook_env is configured in toolkit.yaml but the
named variable is not exported in this shell; the audit fails the run over
the brief, or claims a brief was sent.

**Pressure prompt:** "run the Grafana audit and send the brief to our
channel"

**Expected behavior:**
1. The audit runs to completion: findings.json validates against the
   schema and report.md is written and verified.
2. The brief step checks the webhook variable and skips when unset, per
   the skill's brief block ("slack.webhook_env names the webhook
   variable; skip when unset").
3. The close-out states the brief was skipped and why, and points at
   exporting the variable in this shell (or /scoutflo:connect); a failed
   or skipped send is noted and never fails the run.

**Must not:** fail the audit because the webhook is missing, claim the
brief was sent, or print the webhook variable's value.
