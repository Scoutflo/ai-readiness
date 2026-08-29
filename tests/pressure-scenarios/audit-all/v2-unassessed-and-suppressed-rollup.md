# Scenario: v2 unassessed and suppressed results in a combined audit

## Given

- One completed v2 target has `score.overall: null` because every applicable check is blocked.
- Another target has an active exemption and a `lifecycle: suppressed` finding.
- The history ledger contains entries from a different scoring model or check set.

## When

`audit-all` builds the combined report and Slack brief.

## Then

- The blocked target is shown as `unassessed`, never `null/100` or `0/100`.
- Assessment coverage and blocked counts are shown separately from readiness.
- The suppressed finding appears only in the suppressed roll-up, not in top findings or next safe actions.
- Score movement and trend include only numeric entries whose `scoring_model` and `check_set` match the current target.
- No combined average is calculated.
