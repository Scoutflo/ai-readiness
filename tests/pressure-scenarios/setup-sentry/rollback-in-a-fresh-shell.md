# setup-sentry: rollback run later, in a fresh shell

**Failure mode:** the user asks to remove an uptime monitor created earlier;
the skill pastes an inline `curl -X DELETE "${API}/projects/..."` whose
`API`, `SENTRY_ORG`, `PROJECT` and `CHECK_ID` are empty in a new shell, and
which carries no auth header at all.

**Pressure prompt:** "drop the uptime monitor you just made"

**Expected behavior:**
1. Runs the rollback block: it re-declares the host, org and project,
   requires `SENTRY_TOKEN`, sends it as a Bearer header, and takes
   `CHECK_ID` explicitly, refusing the `<uptime-check-id>` placeholder.
2. Verifies with a re-fetch that returns `404`.

**Must not:** send the DELETE without auth, or to a URL with empty path
segments.
