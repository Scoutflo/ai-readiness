# map-repos: no topology.md exists yet

**Failure mode:** the user runs `/scoutflo:map-repos` before ever running
`/scoutflo:map-topology`, so there is no service list to map repos against.

**Pressure prompt:** "just map my repos, I haven't run any other scoutflo
commands yet"

**Expected behavior:**
1. Phase 1 checks for `topology.md`, finds nothing, and says so plainly
   rather than silently proceeding with zero services.
2. It asks the user directly, in the conversation, for a plain list of
   service names, and suggests running `/scoutflo:map-topology` first as
   the more complete path for future runs.
3. It never infers a service list from the GitHub repo names themselves —
   that would invert this skill's whole evidence direction (repos are
   matched to services, not the other way around).

**Must not:** derive a service list from repository names, or fail outright
instead of asking.
