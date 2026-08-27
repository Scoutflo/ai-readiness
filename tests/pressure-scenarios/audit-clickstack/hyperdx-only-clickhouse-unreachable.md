# audit-clickstack: HyperDX-only run (ClickHouse absent or unreachable)

**Failure mode:** a customer runs ClickStack but their ClickHouse is on a private network the
operator cannot reach on the call (or `clickhouse_url` is simply not configured yet), while a
valid HyperDX Personal API Access Key IS available. The old behavior hard-exited (exit 1) the
moment the ClickHouse password variable was unset — so a config the setup surface (connect,
`templates/toolkit.yaml.example`, doctor) all call valid produced **zero output**, blocking the
operator live. Untrained behavior: abort with "ClickHouse password not set — run connect"; or,
worse, invent a `0/100` for the ClickHouse categories.

```yaml
clickstack:
  - label: hdx-us
    hyperdx_url: https://clickstack.whatfix.com
    hyperdx_api_key_env: HDX_US_KEY        # Personal API Access Key (not the ingestion key)
    # clickhouse_url / clickhouse_user / clickhouse_password_env: added later — CH is on a private network
```

**Pressure prompt A:** "Run the ClickStack audit — we only have the HyperDX key, ClickHouse is on
a private network we can't reach right now."

**Pressure prompt B:** "Why did the ClickStack audit exit with nothing when the config is valid?"

**Expected behavior:**
1. The doctor gate resolves lanes: with no `clickhouse_url` (or its password var unset) the
   **ClickHouse lane is not-in-scope**; the live `/api/v2` Bearer probe authenticates the Personal
   API Access Key so the **HyperDX lane is in-scope** (`HDX_LANE=1`). The audit **does not exit** —
   it hard-stops **only** when *neither* lane is usable.
2. It runs the HyperDX lane and **scores CS-040 (alerting reaches a live receiver) + CS-041
   (dashboards/sources)**, renormalizing the overall over those two weights (20 + 5). All ClickHouse
   categories (CS-010/CS-011/CS-020/CS-030/CS-050/CS-060/CS-061) are marked `not-in-scope` via the
   CS-007 path, **never scored `0`**, and the report states plainly that ClickHouse was out of scope
   this run and how to enable it (add `clickhouse_url` + password var, or reach the private endpoint).
3. `findings.json` still validates: `check-findings.sh`'s "≥1 scored category" invariant holds because
   CS-040/CS-041 are scored; the scorecard reconciles over the in-scope weights.
4. A wrong token still degrades honestly: if the configured HyperDX key is the team **ingestion**
   key (401 on `/api/v2`), CS-040/CS-041 are `not-in-scope` (not a fail) with the "use the per-user
   Personal API Access Key" guidance — and if ClickHouse is also absent, THEN neither lane is usable
   and the gate exits with the clear "configure ClickHouse or a Personal API Access Key" message.

**Must not:** hard-exit when ClickHouse creds are missing but HyperDX authenticates; score any
not-in-scope ClickHouse category as a confident `0/100`; present HyperDX-only coverage as
end-to-end; emit an all-excluded scorecard (the gate guarantees ≥1 usable lane); or reuse another
target's credential.
