# audit-clickstack: multiple ClickStack/HyperDX instances in one environment

**Failure mode:** a customer runs several HyperDX instances (e.g. per region) in one environment and
lists them under `clickstack:` as labeled targets, each with its own HyperDX URL + Personal API Access
Key and its own ClickHouse. Untrained behavior: audit only the first; reuse one target's token/URL for
all; or write every target to the same `clickstack/<date>/` dir so the second overwrites the first's
`findings.json`/`inventory.json`/`history.jsonl`.

```yaml
clickstack:
  - label: hdx-eu
    clickhouse_url: https://ch-eu:8123
    clickhouse_user: scoutflo_ro
    clickhouse_password_env: CH_EU_KEY
    hyperdx_url: https://hdx-eu:8080
    hyperdx_api_key_env: HDX_EU_KEY      # Personal API Access Key, not the ingestion key
  - label: hdx-us
    clickhouse_url: https://ch-us:8123
    clickhouse_user: scoutflo_ro
    clickhouse_password_env: CH_US_KEY
    hyperdx_url: https://hdx-us:8080
    hyperdx_api_key_env: HDX_US_KEY
```

**Pressure prompt A:** "We have HyperDX in three regions. Audit all of them — you only did one."

**Pressure prompt B:** "Why did the second region's report overwrite the first?"

**Expected behavior:**
1. The audit **enumerates every clickstack target** and runs the full sequence once per target with
   `SCOUTFLO_TARGET=<label>`, resolving that target's `clickhouse_url`/`clickhouse_user`/
   `clickhouse_password_env` **and** `hyperdx_url`/`hyperdx_api_key_env` (+ optional login) via the
   shared enumerator — each `*_env` read by `printenv` on that target's own variable name, never reusing
   another target's secret.
2. **Per-target output, no collision (Prompt B):** each target writes `clickstack/<label>/<date>/`
   (`clickstack/hdx-eu/…`, `clickstack/hdx-us/…`) with its own `history.jsonl`, and `.target` = the
   per-target slug (`clickstack/<label>`) so `audit-all`/correlation/render disambiguate them. A single
   `clickstack:` block still writes the flat `clickstack/<date>/` (zero migration).
3. **The v2 HyperDX auth is preserved per target:** each target reads the external API v2 with its own
   Personal API Access Key (Bearer), probing `/api/v2` then the app-proxy-doubled `/api/api/v2` and
   keeping the JSON one; the ingestion key is never used; internal `/api/*` stays session-only; the
   session-login legacy fallback still applies per target.
4. **ClickHouse per target:** the `scoutflo_ro`-style least-privilege read user + the `readonly=1` /
   Code-164 profile-readonly fallback + the `SELECT 1` body-assert are all applied with **this target's**
   url/user/password.
5. CS-007/CS-050 and every scored category are computed **per target** — one instance being out of scope
   (e.g. no working Personal API Access Key) never blocks the others.

**Must not:** audit only the first target; reuse one target's HyperDX/ClickHouse credential for another;
write two instances to the same dated dir (collision); regress the `/api/v2` Personal-API-Access-Key
path or the ClickHouse readonly fallback; or let one unreachable instance abort the whole run.
