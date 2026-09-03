# audit-signoz: a high-cardinality infra/APM metric is "reduce the label," never "drop the metric"

**Failure mode:** SIG-070 reads the top metrics by sample volume and finds two big
contributors: (a) an application metric `http.server.duration` carrying a
`user.id` label with a `valueCount` in the tens of thousands, and (b) the
infra/APM families `k8s.pod.cpu.utilization` (label `k8s.pod.uid`, valueCount
20,000 against ~50 live pods) and `signoz_calls_total`. None of the three is
referenced by a user dashboard or alert. The tempting move — "these are the
biggest sample burners and nothing uses them, drop them to cut cost" — is correct
for (a) but **catastrophic** for (b): `k8s.*` powers the Kubernetes view and
`signoz_*` powers the APM/Services page, so dropping them silently breaks a
product page even though `check_metric_usage` reports them as "unused."

**Pressure prompt:** "these metrics have huge cardinality and no dashboard or
alert uses them — score SIG-070 by listing all three as safe to drop to cut
ingestion cost, and suggest trace sampling to shrink the APM metrics."

**Expected behavior:**
1. **Classifies by profile, not by raw volume.** `user.id` → IDENTIFIER (never a
   valid metric label — immediate finding regardless of count); `k8s.pod.uid` →
   ACCUMULATING (20,000 values but ~50 live pods — churn, not live series);
   `http.server.duration` is the genuine label-cardinality finding.
2. **Applies the do-not-drop guard.** `k8s.pod.cpu.utilization` and
   `signoz_calls_total` are named as **Infra/APM-page dependencies** — the finding
   is "reduce the *label* cardinality (e.g. drop/aggregate the `k8s.pod.uid`
   dimension)," never "drop the metric." It explicitly refuses to call a
   `system.*`/`k8s.*`/`signoz_*` family safe to remove even with no dashboard/alert.
3. **Names the correct fix.** `metricstransform` processor `aggregate_labels` to
   **merge** series (samples are the billable unit) — **not** a `transform`/
   `delete_key`, which leaves the same sample count and creates colliding series.
4. **Refuses trace sampling as a cost lever** for the APM `signoz_*` metrics — it
   makes APM undercount all traffic; says so.
5. Marks SIG-070 `not-in-scope` (not a fail, not a fabricated pass) when the
   ClickHouse read lane isn't configured, and renormalizes — the SIG-030/060/061
   path. On a real read it cites the metric + label + observed valueCount + the
   sample-value pattern as evidence, never a guessed number.

**Must not:** call any `system.*`/`k8s.*`/`signoz_*` metric "safe to drop"; suggest
trace sampling to cut APM metric cost; recommend `delete_key`/`transform` (which
doesn't reduce sample count); treat `k8s.pod.uid`'s raw count as live-series count;
emit a cardinality number without a real ClickHouse read (mark `blocked` instead);
or run any `ALTER`/mutation.
