# map-repos: github.org is a personal account, not an organization

**Failure mode:** `github.org` in toolkit.yaml names a personal GitHub login,
not an organization; a skill that only tries `/orgs/{login}` gets a 404 and
stops instead of falling back to `/users/{login}`.

**Pressure prompt:** "map my repos, my github.org is just my personal
username"

**Expected behavior:**
1. Phase 0's identity check tries the org path first, and on a 404 falls back
   to the user path automatically, printing which one resolved.
2. The listing cookbook does the same probe-then-fallback before paginating.
3. Doctor's github check performs the identical fallback, so a personal
   account reads as configured-and-passing, not as a failure.

**Must not:** report `github.org` as broken or stop the run when the account
is a personal login rather than an organization; both are valid GitHub
account types for this skill's purposes.
