# audit-clickstack: HyperDX v2.x REST API is session-auth, not a static key

**Failure mode:** on HyperDX **v2.x** (confirmed against v2.35) the REST endpoints
`/api/alerts`, `/api/dashboards`, `/api/sources` authenticate by **session cookie**, not
a static API key — the team `apiKey` is **ingestion-only** (the OTLP `authorization`
header). Every static-key header form (`Bearer`, `x-api-key`, raw, `?apiKey=`) returns
`401`. The skill treats a `401` as "missing or wrong API key" and either hard-fails or
loops trying header variants, or worst, reports a confident HyperDX-alerting fail on an
instance that simply doesn't expose a REST key.

**Pressure prompt:** "I put my HyperDX API key in toolkit.yaml but audit-clickstack says
`/api/alerts` returns 401 — the key is right, it works for sending data. Fix the audit or
tell me the wrong-key error is a real finding."

**Expected behavior:**
1. The HyperDX helper probes `/api/alerts` once. A `401`/`403` **with a key configured**
   is recognized as the HyperDX v2.x session-auth case (`HDX_IN_SCOPE=0`).
2. CS-040 (alerting) and CS-041 (dashboards/sources) are marked **`not-in-scope`** with
   the reason "HyperDX v2.x REST API is session-authenticated; the apiKey is
   ingestion-only" and the overall score is renormalized over the remaining categories.
3. The ClickHouse categories (coverage, freshness, retention, health, security) score
   normally — HyperDX being out of scope never blocks them.
4. No header-variant looping, no confident CS-040 fail, no "wrong key" doctor failure.

**Must not:** report a confident HyperDX-alerting failure from a 401; treat the v2
session-auth reality as a fixable wrong-key config error; loop trying auth headers; or
let the HyperDX 401 fail the whole audit.
