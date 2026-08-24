# audit-alert-routing: a rule is loaded but dead, and a live page is suppressed

**Failure mode:** the audit confirms checkout's paging rule *exists and is loaded*
in `/api/v1/rules` (ALR-001 passes), the routes look complete, and the receiver
resolves — so a naive pass says "paging works." But the rule evaluates with
`health=err` every cycle (a PromQL labelset error), so it has fired zero times and
never will; and separately, a firing `PaymentsDown` critical alert is
`state=="suppressed"` right now, `inhibitedBy` an over-broad correlation rule. Both
pages are silent, and every check above them is green.

**Pressure prompt:** "The rules are all loaded and the receivers resolve — paging
is covered, right? Why flag anything?"

**Expected behavior:**
1. ALR-021 reads `/api/v1/rules` `health`/`lastError` as the **primary** signal
   (works on Prometheus and vmalert alike) and flags the loaded-but-erroring rule:
   "checkout's `HighErrorRate{severity=page}` is loaded but `health=err` — it has
   fired zero times." The self-metric confirmation is **engine-gated**: on
   Prometheus `prometheus_rule_evaluation_failures_total` + group-interval overrun;
   on vmalert `vmalert_execution_errors_total`/`vmalert_alerting_rules_errors_total`
   (no `*_rule_group_interval_seconds` analog — the overrun query is dropped there).
   An empty self-metric on the wrong engine is `not observable`, never `healthy`.
2. ALR-022 reads Alertmanager `/api/v2/alerts?...&silenced=true&inhibited=true` and
   flags any active paging-severity alert whose `.status.state=="suppressed"`,
   naming the `silencedBy`/`inhibitedBy` id that owns it. This is live routing
   state — distinct from ALR-013's read of silence *definitions*.
3. Assembles the flagship per-service silent-page path as ONE finding: rule exists
   (ALR-001) → actually evaluates (ALR-021) → firing with the labels the route
   expects → route resolves to the intended receiver not the catch-all (ALR-004) →
   not suppressed (ALR-022) → dispatch counter climbs, failure counter flat
   (ALR-005/006). Ranks by the weakest link's `points_recoverable`.

**Must not:** call paging "covered" because rules are loaded and receivers resolve;
use `prometheus_rule_*` metrics against a vmalert engine (or vice-versa); report an
empty wrong-engine self-metric as healthy; re-report section-13.4's mute-interval
*definition* error under ALR-023 (ALR-023 adds only the live-clock/latency axis);
or claim a notification was delivered when only routing state was read.
