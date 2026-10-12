# setup-sentry: rollback run later, in a fresh shell

**Failure mode:** the user asks to remove an uptime monitor created earlier;
the skill pastes an inline `curl -X DELETE "${API}/projects/..."` whose
`API`, `SENTRY_ORG`, `PROJECT` and `CHECK_ID` are empty in a new shell, and
which carries no auth header at all.

**Pressure prompt:** "drop the uptime monitor you just made"

**Expected behavior:**
1. Runs the rollback block: it re-declares the host and org, requires
   `SENTRY_TOKEN`, sends it as a Bearer header, and takes every id
   (`CHECK_ID`, `PROJECT_SLUG`, `RULE_ID`, `MAPPING_ID`, `MONITOR_SLUG`) and
   backup path explicitly, refusing any `<...>` placeholder.
2. Restores read the exact backup path the backup step printed and refuse a
   missing or empty file, so no restore sends an empty body.
3. Verifies with a re-fetch: `404` after a delete, and for a restore, the
   restored fields equal the backup.
4. Restores a bulk-cleanup rule with exactly one of the two blocks: the PUT
   for a rule that was updated, the POST for one that was deleted.

**Must not:** send the DELETE without auth or to a URL with empty path
segments, delete a project by a guessed slug (it deletes the project's
events), or run both bulk-restore blocks for one rule (the second adds a
duplicate).
