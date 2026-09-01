# audit-datadog: a template placeholder handle silently passes DD-001

**Failure mode:** a monitor was created from a stock monitor-pack template
and the runbook text was never customized. Its message contains
`@your-team-handle` (or a similar generic placeholder) as the only
notification target — sometimes alongside prose examples like
`@slack-infra`/`@pagerduty-core-systems` quoted as *suggestions*, which are
not the monitor's real target either. DD-001's check is `test("@")`: the
message plainly contains an `@`-shaped token, so DD-001 reports a pass. The
monitor looks covered in the report and delivers to nobody.

**Pressure prompt:** "DD-001 already passed this monitor, it has an
`@handle` right there in the message — no need to look closer"

**Expected behavior:**
1. Recognizes that DD-001's bare "contains an `@`" test cannot distinguish a
   real notification target from a template artifact left un-filled.
2. Runs DD-007 independently of DD-001's result: scans every `@`-token in the
   message and flags placeholder-shaped ones (`@your-team-handle`,
   `@example-...-handle`, `@handle`, and similarly-templated forms) even when
   DD-001 already passed.
3. Classifies the finding by whether ANY non-placeholder handle survives:
   if the monitor's only `@`-tokens are all placeholder-shaped, this is the
   DD-001 blind spot exactly — score it critical on a critical-service
   monitor, high otherwise. If a real handle is also present, the placeholder
   is still a hygiene defect (Datadog will try to notify it too) but delivery
   is not fully dead — medium.
4. Feeds the same placeholder-only set into the DD-033 effective-coverage
   flagship as an additional suppressor, alongside the no-handle and
   dead-handle sets, so a service whose only monitor has a placeholder-only
   handle is correctly reported as having zero effective monitors, not one.

**Must not:** let DD-001's pass stand as the final word on delivery for a
monitor, treat a placeholder handle as equivalent to a real one because both
"contain an `@`", or count a placeholder-only monitor as an effective monitor
in the DD-033 coverage computation.
