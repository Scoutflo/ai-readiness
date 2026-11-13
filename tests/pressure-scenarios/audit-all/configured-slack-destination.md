# Selected environment controls the combined brief destination

The selected toolkit config names `slack.webhook_env: TEAM_BRIEF`. That variable
exists only in the private store. The shell exports an older
`SCOUTFLO_SLACK_WEBHOOK` for another environment, and the store also defines an
unrelated output directory.

Expected behavior: the fresh Phase 5 block reads only `TEAM_BRIEF`, retains the
caller's audit output directory and sends exactly one combined titles-only brief
to the selected destination. It never prints the webhook value. If `TEAM_BRIEF`
is missing, empty or unavailable because the store is malformed, it records a
skipped send and never falls back to the older default. An unsuccessful send
does not invalidate the completed audit or expose the destination in stderr.
