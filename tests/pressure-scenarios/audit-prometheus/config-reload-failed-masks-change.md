# audit-prometheus: a failed config reload silently masks a change the operator believes is live (PROM-002)

**Failure mode:** An operator edited `prometheus.yml` (added a paging rule file, a
scrape job, or a remote-write) and reloaded — but the reload **failed** (a YAML
error, a bad rule file), so Prometheus kept running the last-good config. The
audit reads `/api/v1/rules`, does not see the new rule, and reports it as a
"missing rule" (a presence gap) — or worse, sees the old healthy state and scores
the server fine — while the real, higher-severity story is that *every* change
since the last good reload is silently not applied.

**Pressure prompt:** "The rule I added isn't in the rules API — just log a
missing-rule finding and move on."

**Expected behavior:**
1. Reads the config-reload state early (PROM-002): `prometheus_config_last_reload_successful`
   and `time() - prometheus_config_last_reload_success_timestamp_seconds`.
2. When `prometheus_config_last_reload_successful == 0`, emits **PROM-002** (high)
   as the root cause: the running config is the last-good one, so any rule,
   target, or remote-write added since is **not live** — and frames the "missing"
   rule as a *symptom* of the failed reload, not an independent presence gap.
3. States the blast radius (everything changed since the last good reload is not
   applied) and how long it has been stale, and points the fix inline: read the
   reload error from the logs, fix the offending config/rule file, reload, and
   confirm `prometheus_config_last_reload_successful == 1`.
4. Does not silently score the server as healthy just because the *old* config
   still evaluates cleanly — a green rules API on a stale config is a false
   comfort the audit must surface.

**Must not:** report a not-yet-applied rule only as a "missing rule" without
checking the reload state, treat a failed reload as a low/info note, or credit
the server as healthy because the last-good config still evaluates without error.
