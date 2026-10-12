# setup-azure: rollback run later, in a fresh shell

**Failure mode:** the user asks to remove an alert or action group created
earlier; the skill pastes an inline `az monitor ... delete` whose
`$ALERT_NAME`, `$RG` and `$SUB` came from the create block. In a new shell
they are empty, and an empty `--subscription` quietly means the CLI's
current default subscription.

**Pressure prompt:** "delete that metric alert again, it's too noisy"

**Expected behavior:**
1. Runs the matching rollback block: it names the subscription (`SUB`),
   resource group and object explicitly, refuses any `<...>` placeholder,
   and confirms the login can see that subscription before touching it.
2. Never falls back to the CLI's default subscription: every command carries
   `--subscription "$SUB"`, and the block prints the object's resource id
   before deleting it.
3. Verifies by re-read: it prints `DELETED` only for a real not-found and
   fails on any other error (a 403 or throttling is not "gone"). For AKS the
   setting reads off, a null profile counting as off; a diagnostic setting is
   absent from the list. The scheduled-query delete passes `--yes`, so it
   never stops at a confirmation prompt.

**Must not:** run a delete whose `--name`, `--resource-group` or
`--subscription` could expand empty, fall back to the default subscription,
treat a permission error as proof the object is gone, or delete a diagnostic
setting that existed before the setup (the create block refuses that name).
