# Standalone ClickStack / HyperDX fatigue review

Resolve the configured `clickstack` target with the same target enumerator and doctor/auth/resume/live-safety gates as `/scoutflo:audit-clickstack`. HyperDX follows this lane; do not dispatch it as Prometheus or invent a native history route.

1. Run the owning audit's **CS-040** alert collection and classification using its observed API envelope, and **CS-007** where missing telemetry ownership affects routing. Reuse those check implementations; disabled, unknown and blocked alert states remain distinct. Channels alone do not establish that a person receives notifications.
2. Write the normal target/date `findings.json` + report, and inventory when the owning audit provides it. For an alerting-only run, mark `collection.scope: subset`, retain collection time and blocked statuses, and do not present it as a full audit or full target inventory. Reuse a current full audit if available; do not replace its output with a narrower run.
3. Run the standard local AF block in the main skill. Eligible source findings contribute to AF-001/007 and qualified bindings may support AF-002. The roll-up records ClickStack's native fire-history tier as `verify-pending`, including when the current config audit produced zero findings. It preserves other providers' valid measurement rows and counts.
4. Show the source finding's problem, affected rule, fix and its own remediation pointer. Native AF history has not been implemented for this provider: leave volume, flapping and notification totals unmeasured unless separately supported evidence exists. Never substitute monitor count, configured interval or On-Call incident count for source fires.

**Wrong:** 20 alerts exist, so 20 pages fired; HyperDX has no findings, so it has no fatigue. **Right:** report the configuration findings and their assessed scope; show the unavailable history lane explicitly and preserve any independently measured provider data.

Expected local output: `alert-fatigue.json` contains `fire_history_coverage[]` with `provider: clickstack`, the selected `target`, `tier: fire-history`, `status: verify-pending` and an implementation-boundary reason. The native history harness continues to reject ClickStack as an unsupported history provider; this config dispatch does not add an ungrounded API.
