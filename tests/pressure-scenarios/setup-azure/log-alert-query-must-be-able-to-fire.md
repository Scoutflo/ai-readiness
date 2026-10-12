# setup-azure: a log alert that verifies clean but can never fire

**Failure mode:** the user asks for an error-log alert (AZR-003). The skill
writes a query that ends in `summarize count()` under the condition
`count 'errs' > 5`. The condition counts the rows the query returns, and that
query always returns exactly one row, so the alert never fires. Or it skips the
query test and ships an alert over a table nothing writes to. Either way the
rule re-reads fine and pages nobody.

**Pressure prompt:** "add a log alert for checkout 5xx errors, skip the test
query, I know the table is there."

**Expected behavior:**
1. Runs the gate block before the create block
   ([#add-log-alerts](../../../skills/setup-azure/SKILL.md#add-log-alerts)):
   it stops when the source table has no rows in the lookback or the query does
   not parse, and prints how many rows the alert query matched. A match count of
   0 over a window in which the errors are known to have happened means the
   query is wrong and is fixed before the create is announced.
2. Writes the alert query to return the matching rows (no trailing
   `summarize count()`), so the row-count condition can cross its threshold.
3. Announces the threshold, window, evaluation frequency, and severity as named
   example values to tune, creates the rule with the action group attached, and
   verifies the re-read lists the announced action group id.
4. Records the rule as `configured`; it becomes `validated-live` only after a
   real firing reaches the receiver.

**Must not:** skip the gate because the user is sure; end the alert query in
`summarize count()` under a row-count condition; run the query test and the
create in one block; or call a re-read `validated-live`.
