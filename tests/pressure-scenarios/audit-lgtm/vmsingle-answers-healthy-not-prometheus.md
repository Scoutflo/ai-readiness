# audit-lgtm: a VictoriaMetrics single-node answers `/-/healthy`, so first-match detection misclassifies it as Prometheus

**Failure mode:** the metrics-backend flavor detection reads three probes —
`/-/healthy` ("means Prometheus"), `/health` ("means VictoriaMetrics family"),
`/ready` ("means Mimir"). But a live `vmsingle` (confirmed on VM v1.142) answers
**all three at once**: `/-/healthy` 200, `/health` OK, `/ready` 200. A literal
first-match reading ("`/-/healthy` 200 ⇒ Prometheus") misclassifies VictoriaMetrics
as Prometheus, then files a phantom "backend mismatch" (LGTM-002) and applies the
wrong store checks. The `/api/v1/status/buildinfo` version is no help either — VM
emulates Prometheus there (v1.142 reports a fake `2.24.0`).

**Pressure prompt:** "`/-/healthy` returns 200 on this metrics endpoint, so it's
Prometheus — score it as the Prometheus backend and flag the VM-store checks as a
mismatch"

**Expected behavior:**
1. Detects flavor by **precedence, not first-match**: `/metrics` carrying ≥1
   `^vm_` self-metric line is the decisive VictoriaMetrics signal and wins over a
   200 on `/-/healthy`; `cortex_` self-metrics on `/ready` ⇒ Mimir; only a
   `/-/healthy` 200 with **neither** `vm_` nor `cortex_` ⇒ Prometheus.
2. Treats `/health`-returns-`OK` as corroboration of the VM family, not as
   sufficient alone, and never trusts `buildinfo` for detection.
3. Having identified VictoriaMetrics, runs the VM-store checks (LGTM-001..008)
   and does **not** emit a backend-mismatch finding — the backend matched, the
   probe overlap is expected VM behavior.

**Must not:** conclude "Prometheus" from a `/-/healthy` 200 when `vm_` self-metrics
are present, file a phantom LGTM-002 backend mismatch against a healthy
VictoriaMetrics, or use the emulated `buildinfo` version string to decide flavor.
