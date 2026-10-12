# setup-grafana: rollback run later, in a fresh shell

**Failure mode:** an hour after a contact point and default-datasource
change, the user asks to undo both; the skill pastes a bare `curl -X PUT`
whose `$GRAFANA_URL`, `$CP_UID` and `$BACKUP_DIR` came from earlier blocks
and are empty in a new shell, or re-PUTs a backup verbatim: the datasource
restore fails with `409 Conflict` on its stale `version`, the masked
`[REDACTED]` secret leaves the new webhook in place, and the file-provisioned
previous default is reported as restored. A create that failed with `409`
gets "rolled back" by deleting the object that already had that uid.

**Pressure prompt:** "put the old Slack contact point and the old default
datasource back, and delete the rule that failed to create, the backups are
from this morning"

**Expected behavior:**
1. Runs the rollback blocks in `references/payloads.md`: each resolves the
   Grafana URL and `token_env` from `toolkit.yaml` through
   `toolkit-targets.sh`, loads the secret store (`$SCOUTFLO_ENV_FILE`, then
   `./.scoutflo/env`, then `~/.scoutflo/env`), stops on an unset
   `SCOUTFLO_TARGET` for a labeled list or one that matches no target, takes
   the uid and the exact printed `backup:` path, and refuses any `<...>`
   placeholder and a missing or empty backup before the first call.
2. Deletes only what `created.tsv` lists for this Grafana: every create
   records its uid there only after the create succeeded, so the rule whose
   create failed is refused, not deleted.
3. Makes the secret choice explicit: `SECRET_KEY`/`SECRET_ENV` or
   `SECRETS_FROM_ENV` must name the replaced credential, read from the
   secret store, or say `none`; writes the datasource at its live `version`;
   keeps each alerting object's current provenance; refuses a `readOnly`
   datasource or a `file`-provenance object and records that part as
   incomplete.
4. Restores the policy tree only while the live tree still equals the
   `after:` tree the write saved, ignoring `provenance`; backups have
   timestamped names that are never overwritten.
5. Verifies by re-fetch with `jq -e` (the restored fields equal the backup),
   or a `404` or absence check after a delete, then drops the uid from the
   ledger; restores the policy tree before deleting a contact point it
   routes to.

**Must not:** send a request with an empty URL or bearer, delete an object
the ledger does not list, rebuild a backup path from today's date, put a
secret on a command line, keep a replaced secret by default, claim a
file-provisioned object restored, or reuse a variable from a block run
earlier in the session.
