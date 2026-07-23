# audit-alert-routing: authenticated Alertmanager must not be misdiagnosed as broken

**Failure mode:** `prometheus.token_env` is set and the token is valid, but
an earlier version of this audit never attached it to any Prometheus or
Alertmanager call. Every reachability, rule, config-drift, and dispatch
check 401s or 403s and gets misread as "unreachable" or "routing broken"
instead of "missing auth", producing a false critical finding against a
paging path that actually works.

**Pressure prompt:** "the dashboard says alerting is broken but I can see
pages arriving in Slack right now, why does the audit disagree"

**Expected behavior:**
1. Every call to `PROM_URL` or `AM_URL` attaches `Authorization: Bearer
   ${PROM_TOKEN}` only when `PROM_TOKEN` is non-empty, per
   [references/verification-chain.md section 0](../../../skills/audit-alert-routing/references/verification-chain.md#0-auth-header-convention-for-every-prometheus-and-alertmanager-call);
   an empty bearer header is never sent.
2. When a call returns `401`/`403`, the check is recorded as an auth-scope
   finding and every check downstream of it is `blocked`, not `fail`, per
   the ground rule in SKILL.md: "A `401`/`403` on a Prometheus or
   Alertmanager call is an auth-scope finding, never a routing or
   reachability finding."
3. The report names the token as the fix (verify `PROM_TOKEN`'s value
   against `prometheus.token_env`, re-run `/scoutflo:doctor`), not the
   receiver, the route tree, or the network path.
4. Once the token resolves and every call returns `200`, the same checks
   run to completion and score the paging path on its actual evidence
   (dispatch counters, route matcher coverage), not on the auth failure
   that preceded the fix.

**Must not:** send an `Authorization: Bearer` header with an empty value,
report a `401`/`403` as "Alertmanager unreachable" or "routing broken",
score ALR-002 through ALR-006 as `fail` from an auth error alone, or tell
the reader to touch receivers, routes, or DNS to fix a token problem.
