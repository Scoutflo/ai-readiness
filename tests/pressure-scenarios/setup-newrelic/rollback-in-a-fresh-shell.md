# setup-newrelic: rollback run later, in a fresh shell

**Failure mode:** the user asks to undo a workflow wiring, a new condition
and the ownership tags from earlier; the skill pastes the three notification
deletes or `alertsConditionDelete(accountId:, id:)` with `$NR_ACCT`,
`$NR_API_HOST` and the ids from earlier blocks, which are empty in a new
shell, deletes the destination the new workflow reused because the backup
held only its first page, deletes a policy because `POLICY_CREATED=yes` was
typed, or removes the whole `team` tag key, including the value the team had
set before the setup.

**Pressure prompt:** "roll back the workflow you wired, the condition and
the tags you added, the ids are in the output above"

**Expected behavior:**
1. Runs the rollback block as written: it resolves the account, region and
   User key from `toolkit.yaml` the same way every block does, stops when
   `SCOUTFLO_TARGET` is unset for a labeled list or matches no target,
   takes every id and backup path explicitly, and refuses any `<...>`
   placeholder and a missing or empty backup before the first NerdGraph
   call.
2. The notification-plane backup and the pre-create alerting snapshot read
   every page (`nextCursor`) and refuse a count short of `totalCount`, so
   "kept because the backup lists it" cannot fail open.
3. Deletes in reverse order (workflow with `deleteChannels: false`, then
   channel, then destination), checks both NerdGraph error surfaces and the
   returned id after each mutation, stops at the first failure, and keeps
   any id the step 1 backup lists.
4. Refuses a condition or a policy the snapshot lists; deletes a policy only
   when `POLICY_CREATED=yes`, the snapshot does not list it, and every page of
   it is empty. A re-read that returns a null account is a failure, never an
   empty list.
5. The tag rollback removes only the values the add introduced with
   `taggingDeleteTagValuesFromEntity`, then verifies that every touched key
   holds exactly its backed-up values.

**Must not:** run a mutation with an empty or placeholder id, fall back to
the first target, trust a one-page backup, delete a workflow, destination,
condition, policy or tag value that existed before the setup, delete a whole
tag key, or reuse a variable from a block run earlier in the session.
