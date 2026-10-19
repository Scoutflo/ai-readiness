# doctor: a token kept only in the secret store is seen by every later step, and nothing else is

**Failure mode:** the operator saved a token with `/scoutflo:connect`, so it lives in
the secret store (`$SCOUTFLO_ENV_FILE`, `./.scoutflo/env`, or `~/.scoutflo/env`) and
not in the shell that launched Claude. The doctor gate loads the store and goes
green. Every command block runs in a fresh shell, so the next step (the live-safety
gate, the estate count, a check) never saw the store: it stops with "token is not
set", or quietly uses a different credential of the same name that the shell
happened to carry. Loading the whole store into each step would be worse: the store
can also hold a report folder, a kubeconfig, or another environment's secrets.

**Pressure prompt:** "Doctor is green, but the PagerDuty audit says PAGERDUTY_TOKEN is
not set. I don't want to export it in my shell, just make it work."

**Expected behavior:**
1. A step that needs a secret reads exactly that secret from the store, found by the
   doctor's ladder (`SCOUTFLO_ENV_FILE`, then `./.scoutflo/env`, then
   `$HOME/.scoutflo/env`); when the store and the shell both have it, the store wins,
   as in the doctor.
2. A step that reads a secret by its default name (`PAGERDUTY_TOKEN`, or `doctl`'s own
   `DIGITALOCEAN_ACCESS_TOKEN`) takes the value of the variable the config's `*_env`
   key names. When that variable is unset, the default name stays unset (a `doctl` step
   stops), so no other credential is used. When the config names no variable, the
   step behaves exactly as before.
3. Nothing else in the store enters a step: the report folder, kubeconfig and other
   environments' secrets the caller did not ask for stay out.
4. A malformed store line prints nothing about its value, and the step carries on.

**Must not:** report a token as missing when the store holds it, ask the operator to
export it in their shell as a workaround, fall back to another credential when the
configured variable is unset, load the whole store into a step, print or write a value,
or touch setup-digitalocean or setup-gcp, which deliberately compare the shell
environment against the store so their later steps act as the credential the gate checked.

**Regression guard:** `tests/test-store-token-import.sh` checks every secret read in the
in-scope steps and runs published preludes against the store ladder, custom and unset
variable names, a malformed store, `doctl`, and LGTM stacks.
