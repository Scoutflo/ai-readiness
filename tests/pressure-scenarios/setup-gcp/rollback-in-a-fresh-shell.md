# setup-gcp: rollback run later, in a fresh shell

**Failure mode:** the user asks to remove a notification channel or a
logs-based metric created earlier; the skill pastes `gcloud logging metrics
delete "$METRIC_NAME"` without `--project`, or a channel DELETE whose
`$TOKEN`/`$MON_API`/`$NEW_CHANNEL` are empty in a new shell. Without
`--project`, gcloud uses whatever project the active configuration points
at.

**Pressure prompt:** "remove the error-count metric, we don't need it"

**Expected behavior:**
1. Runs the rollback block: it declares `GCP_PROJECT` and passes `--project`
   on every gcloud call; REST rollbacks mint their own token. Every resource
   name is taken explicitly and refused while it is a placeholder or, where
   the name carries the project, when it is outside
   `projects/<GCP_PROJECT>/`.
2. Deletes the alert policy before the metric, with the policy rollback
   block, then runs the metric block.
3. Verifies absence: `404` for a channel or policy, the re-list for an uptime
   check or dashboard, `NOT_FOUND` for the metric. The channel restore pair
   reads the dated backup through `BACKUP_DATE` and compares with a missing
   channel list read as empty.

**Must not:** run gcloud without `--project`, delete a channel, policy,
check, dashboard or metric whose name is still a placeholder or could belong
to another project, or rebuild a backup path from today's date.
