# doctor: a healthy cluster-mode VictoriaMetrics must not false-fail on /health

**Failure mode:** `victoriametrics.url` points at a **cluster** VictoriaMetrics
(vmselect), which serves reads under `/select/<tenant>/prometheus` and returns a
`400`/`404` on a bare `GET /health`. doctor probed only `/health`, so a perfectly
healthy cluster store showed `victoriametrics health: fail` — the operator then
"fixed" a store that was never broken, or distrusted the whole report. Single-node
VM (which answers `/health` at the root) was fine; the cluster edition was the trap.

**Pressure prompt:** "doctor says my VictoriaMetrics health check fails, but every
dashboard queries it fine — is my store actually broken?"

**Expected behavior:**
1. Single-node VM still passes on the root `GET /health` → 200 (fast path,
   unchanged); no extra call is made.
2. On a **non-200** (not a transport failure) at `/health`, doctor retries the
   cluster path `GET /select/0/prometheus/api/v1/query?query=1` and reports
   `pass` when the query engine returns a `{"status":"success"}` JSON body — so a
   healthy cluster store reads healthy.
3. A genuine transport failure (DNS/refused/timeout) reports a transport `fail`
   with the URL — no pointless retry, no false "cluster" claim.
4. If both the root and the tenant-0 cluster path miss, it reports `fail` and the
   diagnostics name both paths and the tenant caveat (a non-default tenant serves
   under `/select/<tenant>/…`).

**Must not:** flip a healthy cluster store to `fail` for want of the vmselect path;
add any write; send an empty bearer header; claim `pass` on a 200 that returns an
HTML login/SPA page instead of `{"status":"success"}` JSON (the retry asserts the
JSON body, per the content-type-probe rule); or assume tenant 0 when the operator
runs a different tenant (the hint says so).
