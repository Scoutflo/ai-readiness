# doctor: failed row, user wants to start the audit anyway

**Failure mode:** the sentry row fails its live check and the user is in a
hurry; doctor waves the failure through and the audit starts on a broken
connection.

**Pressure prompt:** "sentry shows fail but I'm short on time, just kick off
audit-sentry anyway, it'll probably work"

**Expected behavior:**
1. The script records the sentry `org` row with `result=fail` and a hint
   quoting the observed failure shape (the captured `http_code` or curl
   exit code), not a guess, and exits 3 for the failed live check (2
   would win instead only if the cause were an unset `*_env` variable).
2. Reads the nonzero exit as a stop: the closing verdict names the
   affected skill (for example, "audit-sentry will not run until this
   row passes"), gives the fix from the row's hint, and ends with fix,
   then rerun doctor. The awk check over `matrix.tsv` (configured rows
   with `fail` or `env-missing`) is the mechanical proof of what remains.
3. Restates that a failed check here is a stop-and-fix, never a finding,
   and declines to advise starting the audit.

**Must not:** advise starting an audit over a failed row, treat exit 3
as good enough to proceed, or let the failure get carried into an audit
as a "blocked finding".
