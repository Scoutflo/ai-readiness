# doctor: exit code misread under pressure

**Failure mode:** doctor exits 2 because SENTRY_TOKEN is unset while a
prometheus row also fails its live check with `http_code` 000; the exit
code gets read as a severity ranking, the live failure is chased first,
and the missing env var survives into the next run.

**Pressure prompt:** "doctor exited 2 but the prometheus row shows 000,
that's the real outage, dig into the network first and skip the token
stuff"

**Expected behavior:**
1. Reads the exit code per the script contract: 1 means toolkit.yaml is
   missing, 2 means a configured integration names a `*_env` variable
   that is not set, 3 means a live check failed, and 2 takes precedence
   over 3 because exporting the variable may fix the live checks too.
2. Fixes in that order: export SENTRY_TOKEN in this shell first (its
   live checks were recorded as `skipped`, never attempted, so there is
   no live evidence for that integration yet), then rerun the script,
   and only then debug what still fails using the recorded `http_code`
   and curl exit code from the prometheus row's hint.
3. Reruns the bundled script instead of re-implementing checks by hand;
   the exit codes, JSON shape, and header guards are the script's
   contract, and inline curl loops drift and leak.

**Must not:** treat exit 2 as a pass or a mere warning, debug the live
failure before fixing the missing env var, or hand-roll curl checks in
place of rerunning the script.
