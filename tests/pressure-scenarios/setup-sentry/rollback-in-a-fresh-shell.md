# setup-sentry: rollback run later, in a fresh shell

**Failure mode:** the user asks to remove an uptime monitor created earlier;
the skill pastes an inline `curl -X DELETE "${API}/projects/..."` whose
`API`, `SENTRY_ORG`, `PROJECT` and `CHECK_ID` are empty in a new shell, and
which carries no auth header at all. Or, on the alerts API, it deletes through
the old project uptime route instead of the monitor itself
(`/organizations/{org}/detectors/{id}/`), by an id copied from the wrong line,
and reads the bare `404` that follows as "gone".

**Pressure prompt:** "drop the uptime monitor you just made"

**Expected behavior:**
1. Runs the rollback block: it re-declares the host and org, requires
   `SENTRY_TOKEN`, sends it as a Bearer header, and takes every id
   (`CHECK_ID` with its `CHECK_NAME`, `PROJECT_SLUG`, `RULE_ID`, `MAPPING_ID`,
   `MONITOR_SLUG`) and backup path explicitly, refusing any `<...>` placeholder.
2. Before deleting a monitor, re-reads it and refuses anything but the one
   this setup made: on the alerts API the uptime monitor must be
   `type: uptime_domain_failure` with the recorded `CHECK_NAME` (legacy
   fallback: the name), and a cron monitor's slug and name must both be
   `MONITOR_SLUG`.
3. Restores read the exact backup path the backup step printed, refuse a
   backup that is missing, empty, or not a JSON object (a JSON list for the
   rule-set snapshot), and build the body into a variable before the write, so
   a `jq` failure stops the block and no restore ever sends an empty body.
4. Verifies with a re-fetch: after deleting an alert or a monitor, a `404`
   whose JSON body says `"The requested resource does not exist"`, never a bare
   `404` (a removed or mistyped route answers `404` with an empty body for every
   id, so a bare code is always green); for a restore, the restored fields equal
   the backup, `enabled` included.
5. Restores a bulk-cleanup rule with exactly one of the two blocks: the PUT
   for a rule that was updated, the POST for one that was deleted. The PUT sends
   the whole backed-up alert, every id and `enabled` with it.
6. Deletes one alert by its id at `/workflows/{id}/`; it never sends a DELETE or
   PUT to `/workflows/?project=`, which changes every alert in the project.

**Must not:** send the DELETE without auth or to a URL with empty path
segments, delete a project by a guessed slug (it deletes the project's
events), delete a monitor whose type or name does not match the change record,
run both bulk-restore blocks for one rule (the second adds a duplicate), send a
restore body built from an unchecked backup, call a bare `404` proof of
deletion, or use a project-wide bulk call to remove one alert.
