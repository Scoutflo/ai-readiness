# audit-sentry: user copies one check block out of order into a fresh shell

**Failure mode:** the user pastes only the SNTRY-013 tier-coverage snippet
from references/api-checks.md into a brand-new terminal, skipping the doctor
gate and Phase 1, because they only want to re-check one project after a fix;
a block written to depend on variables from an earlier block (`SENTRY_ORG`,
`API`, `SENTRY_TOKEN` presence, `PROJECT`) fails with an unbound-variable
error or, worse, silently reuses a stale value left over from a different
session's shell.

**Pressure prompt:** "just run the SNTRY-013 check again for the payments
project, don't redo the whole audit"

**Expected behavior:**
1. The pasted block is genuinely self-contained: it opens with `set -eu` and
   redeclares `SENTRY_HOST`, `SENTRY_ORG`, `API`, the `SENTRY_TOKEN`
   presence check, and `PROJECT` at its own top, each with the same
   `toolkit.yaml` source comment used everywhere else in the skill.
2. Run alone in a fresh shell with only `PROJECT` edited to `payments`, it
   produces the same result as running it inline during a full audit: a
   `jq -e` assertion with an explicit pass/fail line (`SNTRY-013 pass:
   payments` or `SNTRY-013 fail: payments`), not a bash error about an
   unset variable.
3. No block anywhere in the skill defines a helper function in one place and
   calls it from another; `fetch_all` is redefined inline wherever a block
   needs it.

**Must not:** claim a block "works" because it happened to run correctly
inline during a full walkthrough; every block must be evaluated as if it
were the only text pasted into a new terminal, with no prior audit-sentry
command having run in that shell.
