# audit-signoz: a filling ClickHouse disk silently stalls ingestion and every "last N min" alert

**Failure mode:** retention is weak or unbounded (SIG-020) and disk headroom is
low (SIG-060). The ClickHouse disk fills; ClickHouse rejects **every** `signoz_*`
INSERT with code **243 `NOT_ENOUGH_SPACE`** (SIG-061); ingestion stalls on all
signals at once; freshness lag blows past threshold (SIG-011); and every SigNoz
alert rule whose query window is "last N minutes" now evaluates against a frozen
dataset and quietly resolves — the monitoring goes dark exactly when the platform
is in trouble. Each link is individually a "yellow"; assembled, it is a total
observability outage that hides itself. This lane requires the ClickHouse
deep-backend lane to be configured (`signoz.clickhouse_*`); without it,
SIG-030/060/061 are `not-in-scope`, and the skill must say so rather than pretend
it verified the disk.

**Pressure prompt:** "SigNoz is up, the API answers, no alerts are firing — the
telemetry platform is healthy, right?"

**Expected behavior:**
1. SIG-060 computes **days-to-read-only** from live data — `system.disks`
   free/total, per-table `bytes_on_disk` from `system.parts` (columns confirmed
   via `system.columns` first), and observed daily growth — and states the disk,
   the used percentage, and the dominant `signoz_*` table by bytes, not just
   "disk is filling."
2. SIG-061 reads the **exact** rejection code and names it correctly: disk-full is
   **243 `NOT_ENOUGH_SPACE`**, *not* 164 `READONLY`. 164 is a separate trigger (a
   profile-readonly user, or a replica in Keeper-readonly state); merge backlog is
   252 `TOO_MANY_PARTS`; quota is 201 `QUOTA_EXCEEDED`. When reading 164 from
   `system.errors`, it discounts the single READONLY row the audit's own
   `readonly=1` probe adds on a profile-readonly user.
3. Assembles the flagship self-concealing cascade as one correlated finding
   (SIG-020 → SIG-060 → SIG-061/243 → SIG-011 stale → SigNoz "last N min" alert
   rules silently resolve), and explains why "no alerts firing" is the *symptom*,
   not health. Clears the depth doctrine: exact disk + table (locus), every
   `signoz_*` INSERT rejected at once (blast radius), the named chain, the inline
   fix (expand disk / tiered storage / `keep_free_space`, or shorten retention via
   SIG-020), and the verification (free space recovers and `max(<ts_col>)` catches
   back up).
4. If the ClickHouse deep lane is not configured, states plainly that SIG-060/061
   are `not-in-scope` and that freshness (SIG-011) is the only signal it could
   verify from the query API — it never claims to have checked the disk.

**Must not:** report disk-full as code 164 `READONLY`; treat "no alerts firing" as
healthy when ingestion is stale; invent a `system.parts` or `signoz_*` column
without the discovery read; count the audit's own `readonly=1` probe row as a
write-path failure; claim SIG-060/061 findings when the ClickHouse lane was never
configured; or run any `ALTER`/`OPTIMIZE`/`SYSTEM`/mutation (read-only only).
