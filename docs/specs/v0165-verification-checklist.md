# v0.1.65 Verification Checklist — Expanded

**Internal Spec Only — Local Development**

Expanded verification items with exact pass/fail criteria, commands, and evidence requirements.

---

## Feature 1: Inventory Checkpoint (Interactive Selection)

### Acceptance Criteria

✓ **1.1 — Prompts correctly for service selection**

```bash
Test: /scoutflo:checkpoint --scope-select

Expected prompt flow:
  "Services discovered:"
  "  • payment-svc"
  "  • checkout-svc"
  "  • analytics-svc"
  "  (use space to toggle, enter to confirm)"

Evidence: User can type service name, press space to select/deselect, enter to confirm

Pass: User selects "payment-svc checkout-svc" and confirmation succeeds
Fail: Prompt doesn't appear OR doesn't accept input OR crashes
```

✓ **1.2 — Saves scope to topology.json**

```bash
Test: After checkpoint confirms, verify file contents

Command: jq '.audit_scope' topology.json

Expected output:
  {
    "services": ["payment-svc", "checkout-svc"],
    "selected_at": "2026-07-30T14:30:00Z",
    "revision": 1
  }

Pass: jq returns valid JSON with selected services + timestamp
Fail: jq returns null OR file doesn't exist OR structure wrong
```

✓ **1.3 — Loads scope on next audit run**

```bash
Test: Run checkpoint once (save scope), then audit-all again

Command 1: /scoutflo:checkpoint --scope-select
  (select "payment-svc checkout-svc")

Command 2: /scoutflo:audit-all

Expected in logs:
  "Loading audit scope from topology.json: payment-svc, checkout-svc"

Evidence: grep "Loading audit scope" audit-all.log

Pass: Log line present AND audit only runs on selected services
Fail: Log line absent OR audit runs on all services
```

✓ **1.4 — Batching works: 1000 objects → batches at 200 each**

```bash
Test: Create mock estate with 1000 EC2 instances, run checkpoint

Setup: 
  aws ec2 describe-instances --max-results 100 | jq '.Reservations | length' 
  (repeat to get to 1000)

Command: /scoutflo:checkpoint --auto-select-all --batch-strategy large

Expected in logs:
  "Batching 1000 resources..."
  "Batch 1/5: 0-199 resources"
  "Batch 2/5: 200-399 resources"
  ...
  "Batch 5/5: 800-999 resources"

Evidence: All 5 batches appear in logs with progress

Pass: All batches logged correctly, audit completes
Fail: Batching logic missing OR wrong batch sizes OR crash
```

✓ **1.5 — User can override with --reset-scope flag**

```bash
Test: Reset scope and run full audit

Command: /scoutflo:checkpoint --reset-scope

Expected: topology.json:audit_scope cleared

Command: /scoutflo:audit-all

Expected in logs:
  "No audit scope set. Running full estate audit."
  "Discovering all resources..."

Pass: Full audit runs (not scoped to previous selection)
Fail: Scoped audit runs OR error thrown
```

✓ **1.6 — Backward compatibility (no scope = audit all)**

```bash
Test: Run audit-all without ever calling checkpoint

Command: /scoutflo:audit-all
(no prior checkpoint calls)

Expected: Audit runs on all discovered resources

Evidence: No "audit scope" log line OR "Using default scope: all"

Pass: Full audit completes normally
Fail: Error about missing scope OR scoped to wrong services
```

---

## Feature 2: Doctor Persistence

### Acceptance Criteria

✓ **2.1 — doctor-state.json created on first run**

```bash
Test: Run doctor for first time

Command: /scoutflo:doctor

Expected file: ~/.scoutflo/doctor-state.json exists

Validate structure:
  jq '.version' ~/.scoutflo/doctor-state.json
  # Output: "1.0"
  
  jq '.checks | length' ~/.scoutflo/doctor-state.json
  # Output: number > 0

Pass: File exists, has version 1.0, checks array populated
Fail: File doesn't exist OR can't parse JSON OR no checks
```

✓ **2.2 — Check results saved with status + timestamp**

```bash
Test: Verify a single check entry in doctor-state.json

Command: jq '.checks[0]' ~/.scoutflo/doctor-state.json

Expected output:
  {
    "check_id": "aws-001",
    "check_name": "EC2 Security Groups",
    "status": "passed",
    "last_run": "2026-07-30T14:30:00Z",
    "skip_until": "2026-08-06T14:30:00Z",
    "last_failed": null,
    "failure_count": 0,
    "auto_fixed": false,
    "fix_timestamp": null
  }

Pass: All fields present and types correct
Fail: Fields missing OR invalid types OR null where shouldn't be
```

✓ **2.3 — Next run skips passing checks (verify in logs)**

```bash
Test: Run doctor twice, verify skips on second run

Command 1: /scoutflo:doctor
Command 2: /scoutflo:doctor

Expected in second run logs:
  "Skipping aws-001 until 2026-08-06 (passed)"
  "Skipping k8s-001 until 2026-08-06 (passed)"
  ...
  "Running 2 checks, skipping 10 checks"

Evidence: Grep for "SKIP" count in logs >= 10

Pass: Most checks are skipped on second run
Fail: All checks re-run OR "SKIP" line absent
```

✓ **2.4 — Auto-detects fix and updates state**

```bash
Test: Manually fix an issue, run doctor again

Setup:
  1. Run doctor, note a failed check (e.g., "aws-001 failed")
  2. Manually fix the issue (e.g., add CloudWatch alarm)
  3. Run doctor again

Expected in doctor-state.json:
  jq '.checks[] | select(.check_id == "aws-001")' ~/.scoutflo/doctor-state.json
  
  Output:
  {
    "check_id": "aws-001",
    "status": "fixed",
    "auto_fixed": true,
    "fix_timestamp": "2026-07-30T15:00:00Z"
  }

Evidence: status changed from "failed" to "fixed", auto_fixed set to true

Pass: Status updated correctly, fix_timestamp set
Fail: Status not updated OR auto_fixed still false
```

✓ **2.5 — State survives across sessions**

```bash
Test: Exit terminal, restart, verify state persists

Command: cat ~/.scoutflo/doctor-state.json | jq '.checks[0].status'

Expected: "passed" (from prior session)

Pass: State file readable, data persists across sessions
Fail: File deleted OR data lost OR version mismatch error
```

---

## Feature 3: Business Context Skill

### Acceptance Criteria

✓ **3.1 — Skill prompts for team, environment, billing, SLA**

```bash
Test: Run business context skill

Command: /scoutflo:business-context

Expected prompts (in order):
  1. "Team/Department name?"
  2. "Environment (staging/production/dr/dev)?"
  3. "SLA Uptime Target (e.g., 99.9%)?"
  4. "Cost Sensitivity (low/medium/high)?"
  5. "Billing Owner Email?"

Evidence: All 5 prompts appear

Pass: All prompts shown, user can enter values
Fail: Prompt missing OR doesn't accept input
```

✓ **3.2 — Data saved to topology.json:business_context**

```bash
Test: Complete business context form, verify save

Command: jq '.business_context' topology.json

Expected output:
  {
    "team": "payments-team",
    "environment": "production",
    "sla": {
      "uptime_percent": 99.99,
      "response_time_ms": 200,
      "error_rate_percent": 0.001
    },
    "cost_sensitivity": "high",
    "billing_owner": "payments-lead@company",
    "updated_at": "2026-07-30T14:30:00Z"
  }

Pass: All fields saved correctly, types correct, updated_at set
Fail: Fields missing OR wrong structure OR invalid email not rejected
```

✓ **3.3 — Audit skills read and use context (staging gaps marked lower)**

```bash
Test: Run audit with staging context, verify severity adjustment

Setup:
  1. Set business_context.environment = "staging"
  2. Run audit-aws

Expected finding:
  Finding: "HTTPS Not Enforced on CloudFront"
  severity_original: "high"
  severity_adjusted: "low"
  reason: "Staging environment - intentional"
  wontfix: true

Evidence: Audit report shows severity_adjusted = low for staging-only gaps

Pass: Severity downgraded correctly, wontfix flag set
Fail: Severity unchanged OR reason absent
```

✓ **3.4 — Context persists across sessions**

```bash
Test: Exit, restart, verify business context loaded

Command: jq '.business_context.team' topology.json

Expected: "payments-team" (from prior session)

Pass: Context persists, same values readable
Fail: Context cleared OR file not readable
```

---

## Feature 4: Redaction Guardrail

### Acceptance Criteria

✓ **4.1 — 100+ sample logs redacted, 0 secrets exposed**

```bash
Test: Run audit and generate report, verify no secrets

Setup: Run full audit (audit-all) on real estate or mock
Generate report: scoutflo-audits/2026-07-30/report.md

Patterns to search (should be 0 matches):
  grep -E "AKIA[0-9A-Z]{16}" scoutflo-audits/*/report.md
  # AWS Access Key ID
  
  grep -E "sk_live_[A-Za-z0-9]{24,}" scoutflo-audits/*/report.md
  # Stripe key
  
  grep -E "Bearer [A-Za-z0-9\-_]{40,}" scoutflo-audits/*/report.md
  # Bearer token

Evidence: grep returns 0 results

Pass: No secrets found in report
Fail: Any secret pattern matched
```

✓ **4.2 — False positives minimized**

```bash
Test: Redaction shouldn't over-match

Create test finding with text: "password reset required"

Expected: Text NOT redacted (doesn't match secret patterns)

Pass: Test string appears unchanged in report
Fail: Text redacted OR disappeared
```

✓ **4.3 — Redacted in report.md AND Slack briefs**

```bash
Test: Generate report and send to Slack

Run: /scoutflo:audit-all && /scoutflo:send-to-slack

Check:
  1. scoutflo-audits/*/report.md — no secrets
  2. Slack message text — no secrets

Evidence: Both contain "[REDACTED]" for secrets, original secrets absent

Pass: Secrets redacted in both places
Fail: Secrets appear in either location
```

✓ **4.4 — API keys, tokens, AWS secrets all handled**

```bash
Test: Inject multiple secret types, verify all redacted

Inject in mock finding:
  API Key: "api_key_12345abcde"
  Token: "github_pat_11AAAAA222BBBBB333CCCC"
  AWS Secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

Expected in report:
  "api_key_[REDACTED]"
  "github_pat_[REDACTED]"
  "wJalrXU[REDACTED]"

Pass: All 3 redacted
Fail: Any secret visible
```

---

## Feature 5: K8s Skill Exposure

### Acceptance Criteria

✓ **5.1 — /scoutflo:audit-kubernetes appears in /scoutflo:start catalog**

```bash
Test: List available skills

Command: /scoutflo:start

Expected output:
  Available skills:
    • /scoutflo:audit-aws
    • /scoutflo:audit-grafana
    ...
    • /scoutflo:audit-kubernetes  ← Must appear
    ...

Evidence: grep "audit-kubernetes" appears in start output

Pass: Skill listed
Fail: Skill missing from list
```

✓ **5.2 — Audit runs without errors**

```bash
Test: Execute K8s audit

Command: /scoutflo:audit-kubernetes

Expected: No errors, audit completes

Evidence: Exit code 0, no error logs

Pass: Audit completes successfully
Fail: Exit code non-zero OR error messages
```

✓ **5.3 — Output in scoutflo-audits/kubernetes/<cluster>/<date>/report.md**

```bash
Test: Verify output location

Command: ls scoutflo-audits/kubernetes/<cluster>/*/report.md

Expected: File exists with findings

Example: scoutflo-audits/kubernetes/prod-gke-1/2026-07-30/report.md

Evidence: File readable, contains findings

Pass: Report file in correct location with content
Fail: File not found OR wrong path
```

---

## Feature 6: Interactive CLI Confirmations

### Acceptance Criteria

✓ **6.1 — Checkpoint pauses before big operations**

```bash
Test: Run checkpoint before audit

Command: /scoutflo:checkpoint

Expected prompt:
  "About to audit 1000+ resources. Continue? (y/n)"

Evidence: User is prompted and can answer

Pass: Prompt appears, audit continues after confirmation
Fail: Prompt missing OR audit starts immediately
```

✓ **6.2 — User can exclude services**

```bash
Test: Exclude specific services from audit

Command: /scoutflo:checkpoint --scope-select

Prompt: "Services to exclude? (comma-separated or enter to skip)"
Answer: "lambda,s3,dynamodb"

Expected: These services excluded from scope

Evidence: topology.json shows excluded services

Pass: Excluded services not in audit scope
Fail: Excluded services still audited
```

✓ **6.3 — User can exclude regions**

```bash
Test: Exclude specific regions

Command: /scoutflo:checkpoint --scope-select --show-regions

Prompt: "Regions to exclude? (comma-separated)"
Answer: "ap-southeast-1,eu-west-1"

Expected: Only other regions audited

Evidence: Audit logs show only selected regions

Pass: Excluded regions not audited
Fail: All regions audited
```

✓ **6.4 — User can exclude statuses**

```bash
Test: Exclude instances by status

Command: /scoutflo:checkpoint --exclude-statuses "stopped,terminated"

Expected: Only running/other instances audited

Evidence: Audit findings don't include stopped/terminated instances

Pass: Stopped/terminated instances skipped
Fail: All instances audited
```

---

## Feature 7: Finding Cross-References

### Acceptance Criteria

✓ **7.1 — AWS-023 finding links to GRAFANA-018**

```bash
Test: Generate findings and verify cross-references

Run: /scoutflo:audit-all

Check report:
  Finding: AWS-023 "CloudWatch Alarms Not Configured"
  
  Expected section:
    Related findings in other audits:
      • GRAFANA-018 (audit-grafana)
      • [link to GRAFANA-018 in report]

Evidence: Cross-reference section appears with GRAFANA-018

Pass: Related finding linked correctly
Fail: Cross-reference section missing OR link broken
```

✓ **7.2 — Each finding shows "Related findings in other audits" section**

```bash
Test: Verify all findings have potential cross-references

Check each finding in report for:
  "Related findings in other audits:" section

Expected: High-overlap findings (e.g., monitoring, backup) have related findings

Pass: Cross-reference section appears on relevant findings
Fail: Section missing on findings that should have it
```

✓ **7.3 — Links resolve to actual audit reports**

```bash
Test: Click/follow cross-reference link

Example link from AWS-023:
  "GRAFANA-018 (audit-grafana)"
  
Expected: Link points to scoutflo-audits/2026-07-30/audit-grafana/report.md#GRAFANA-018

Evidence: Clicked link opens correct report at correct section

Pass: Link resolves to valid report
Fail: Link broken OR points to wrong file
```

---

## Integration Tests (All Features Together)

### **8.1 — Checkpoint → Audit → Doctor → Report workflow**

```bash
Test: Full v0.1.65 workflow

Step 1: /scoutflo:checkpoint --scope-select
  Action: Select "payment-svc", "checkout-svc"
  Verify: topology.json has audit_scope set

Step 2: /scoutflo:audit-all
  Action: Run audit with scope
  Verify: Only selected services audited
  
Step 3: /scoutflo:doctor
  Action: Run doctor checks
  Verify: doctor-state.json created, checks saved

Step 4: Verify report
  Action: Read scoutflo-audits/*/report.md
  Verify: No secrets exposed (redaction works)
           Business context applied (staging gaps low severity)
           Cross-references present

Expected: Full workflow completes without errors

Pass: All 4 steps complete, outputs verified
Fail: Any step fails OR verification fails
```

### **8.2 — No regressions in prior version features**

```bash
Test: Verify all 12 audit skills still work

For each skill in [aws, grafana, sentry, pagerduty, lgtm, gcp, digitalocean, 
                     datadog, kubernetes, github, jira, zenduty]:
  
  Run: /scoutflo:audit-<skill>
  Expected: Audit completes, findings generated
  
Result: All 12 skills should complete without error

Pass: All 12 skills work
Fail: Any skill broken OR findings missing
```

### **8.3 — Unit tests pass**

```bash
Test: Run full test suite

Command: npm test || python -m pytest || equivalent

Expected output:
  ✓ checkpoint logic tests
  ✓ doctor persistence tests
  ✓ business context tests
  ✓ redaction guardrail tests
  ✓ cross-reference tests
  [All tests passing]

Evidence: Test suite shows 0 failures

Pass: All unit tests pass
Fail: Any test fails
```

---

## Reporting

After completing verification, fill in this template for the SSOT:

```markdown
[2026-08-05 v0.1.65 VERIFICATION COMPLETE]

Checkpoint Logic:
  [✓] 1.1 — Prompts for service selection
  [✓] 1.2 — Saves scope to topology.json
  [✓] 1.3 — Loads scope on next run
  [✓] 1.4 — Batching: 1000 → 5 batches of 200
  [✓] 1.5 — --reset-scope flag works
  [✓] 1.6 — Backward compat (no scope = all)

Doctor Persistence:
  [✓] 2.1 — doctor-state.json created
  [✓] 2.2 — Check results saved with status + timestamp
  [✓] 2.3 — Next run skips passing checks
  [✓] 2.4 — Auto-detects fixes
  [✓] 2.5 — State survives sessions

Business Context:
  [✓] 3.1 — Skill prompts for all fields
  [✓] 3.2 — Data saved to topology.json
  [✓] 3.3 — Audit skills use context (staging gaps marked low)
  [✓] 3.4 — Context persists across sessions

Redaction Guardrail:
  [✓] 4.1 — 100+ logs redacted, 0 secrets exposed
  [✓] 4.2 — False positives minimized
  [✓] 4.3 — Redacted in report.md AND Slack
  [✓] 4.4 — API keys, tokens, AWS secrets handled

K8s Exposure:
  [✓] 5.1 — Skill in /scoutflo:start catalog
  [✓] 5.2 — Audit runs without errors
  [✓] 5.3 — Output in kubernetes/<cluster>/<date>/report.md

Interactive CLI:
  [✓] 6.1 — Checkpoint pauses before big operations
  [✓] 6.2 — User can exclude services
  [✓] 6.3 — User can exclude regions
  [✓] 6.4 — User can exclude statuses

Cross-References:
  [✓] 7.1 — AWS-023 links to GRAFANA-018
  [✓] 7.2 — All findings show related findings section
  [✓] 7.3 — Links resolve to actual reports

Integration:
  [✓] 8.1 — Checkpoint → Audit → Doctor → Report workflow
  [✓] 8.2 — No regressions in 12 audit skills
  [✓] 8.3 — All unit tests pass

STATUS: v0.1.65 READY FOR PRODUCTION

Go/No-Go Decision: GO
Next Phase: v0.1.66 (Correlation Engine)
```

---

**This is internal verification spec. Not shipped to customers.**

