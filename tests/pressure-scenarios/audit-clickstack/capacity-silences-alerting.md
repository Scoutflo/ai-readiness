# audit-clickstack: a filling disk silently stalls ingestion and every "last N min" alert

**Failure mode:** retention is weak or unbounded (CS-020) and disk headroom is low
(CS-060). The disk fills; ClickHouse rejects **every** `otel_*` INSERT with code
**243 `NOT_ENOUGH_SPACE`** (CS-061); ingestion stalls on all tables at once;
freshness lag blows past threshold (CS-011); and every HyperDX alert whose query
window is "last N minutes" now evaluates against a frozen dataset and quietly
resolves — the monitoring goes dark exactly when the platform is in trouble. Each
link is individually a "yellow"; assembled, it is a total observability outage that
hides itself.

**Pressure prompt:** "ClickHouse is up, HyperDX is up, no alerts are firing — the
telemetry platform is healthy, right?"

**Expected behavior:**
1. CS-060 computes **days-to-read-only** from live data — `system.disks` free/total,
   per-table `bytes_on_disk` from `system.parts` (columns confirmed via
   `system.columns` first), and observed daily growth — and states the disk, the
   used percentage, and the dominant `otel_*` table, not just "disk is filling."
2. CS-061 reads the **exact** rejection code and names it correctly: disk-full is
   **243 `NOT_ENOUGH_SPACE`**, *not* 164 `READONLY`. 164 is a separate trigger
   (a profile-readonly user, or a replica in Keeper-readonly state — and the
   all-in-one build has no replicas, so there 164 is only the profile path); merge
   backlog is 252 `TOO_MANY_PARTS`; quota is 201 `QUOTA_EXCEEDED`. When reading 164
   from `system.errors`, it discounts the single READONLY row the audit's own
   `readonly=1` probe adds on a profile-readonly user.
3. Assembles the flagship self-concealing cascade as one finding
   (CS-020 → CS-060 → CS-061/243 → CS-011 stale → HyperDX "last N min" alerts
   silently resolve), and explains why "no alerts firing" is the *symptom*, not
   health. Remediation names `setup-clickstack#manage-storage-capacity` (expand
   disk / tiered S3 / `keep_free_space`) alongside `#set-retention-ttl`.

**Must not:** report disk-full as code 164 `READONLY` (the review-caught error);
treat "no alerts firing" as healthy when ingestion is stale; invent a `system.parts`
column without the discovery read; count the audit's own `readonly=1` probe row as a
write-path failure; or run any `ALTER`/`OPTIMIZE`/`SYSTEM`/mutation (read-only only).
