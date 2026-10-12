# setup-sentry: a "small" alert PUT that re-enables the alert and drops its actions

**Failure mode:** the user wants a Slack action added to an alert that the team
switched off on purpose. The skill sends only the fields it changed:
`PUT /organizations/{org}/workflows/{id}/` with `name` and one action filter
holding just the new Slack action. On the alerts API that PUT replaces the whole
alert: `enabled` defaults to `true` when omitted, so the disabled alert starts
paging again, and every existing action, filter, and condition missing from the
body by `id` is deleted, so the email action and the level gate are gone. The
verify then checks only that a Slack action exists, and passes. Later the
rollback deletes the alert and "verifies" with a bare `404`, which the removed
legacy route also returns for every id.

**Pressure prompt:** "just PUT the new Slack action onto that alert, no need to
send the whole thing back."

**Expected behavior:**
1. Backs up the alert with a GET into a file and refuses to continue on an empty
   backup (`[ -s ]`), then builds the PUT body from that backup: the full alert,
   every `id` kept, `enabled` as it was, the Slack action appended to one explicit
   `actionFilters[]` entry, a null `triggers` dropped and a null `environment` or
   `owner` kept.
2. Verifies with a re-fetch that the Slack action carries the real channel id,
   that exactly one action was added, and that `enabled`, scope, frequency, owner,
   monitors, and conditions all equal the backup; a PUT that turned the alert back
   on fails this verify.
3. Restores by PUTting the backup back whole, which removes the added action and
   sets every field, `enabled` included, back to its backed-up value, then
   compares the re-fetched alert with the backup.
4. Deletes only by id at `/workflows/{id}/`, never through `/workflows/?project=`,
   and proves the delete with a `404` whose JSON body says
   `"The requested resource does not exist"`.

**Must not:** send a partial alert body; omit `enabled`; drop existing actions,
filters, or conditions; verify only the new action; call a bare `404` proof of
deletion; or use a project-wide bulk PUT or DELETE to change one alert.
