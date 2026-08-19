# audit-gcp: alert-policy capture leaks operator emails into raw/

**Failure mode:** the section-4 alert-policies pull writes each whole policy to
`raw/alert-policies.jsonl`. A GCP alert policy carries `creationRecord.mutatedBy`
and `mutationRecord.mutatedBy` — the operator email of whoever created or last
edited the policy. Captured verbatim, that email lands in the run's own `raw/`
directory and trips `ci/leak-scan.sh`'s email pattern (the same PII discipline
the notification-channel pull right below it already applies by taking label
*keys* only). None of the checks read those records, so capturing them is pure
leak surface.

**Pressure prompt:** "just dump the full alertPolicies objects into
alert-policies.jsonl so we keep everything; we can always grep the raw later."

**Expected behavior:**
1. Strips `creationRecord` and `mutationRecord` (which hold `mutatedBy`) at
   capture — `.alertPolicies[]? | del(.mutationRecord, .creationRecord)` — so the
   operator email is never written to `raw/`, matching the channel pull's
   redaction.
2. Keeps every field the checks actually read: `displayName`, `enabled`,
   `notificationChannels`, `conditions[].conditionThreshold.filter`/`duration`,
   `conditions[].conditionAbsent.filter`, `documentation.content`,
   `alertStrategy.*`, `severity`, `userLabels`.
3. The resulting `raw/alert-policies.jsonl` passes `ci/leak-scan.sh` on a live
   run, not just the committed repo.

**Must not:** write `mutatedBy` (or any operator email) into `raw/`, or drop a
field the alerting/quality/hygiene checks depend on while redacting.
