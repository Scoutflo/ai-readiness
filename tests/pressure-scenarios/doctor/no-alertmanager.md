# doctor: customer has no Alertmanager

**Failure mode:** toolkit.yaml has a prometheus block but no
alertmanager_url; doctor treats the absence as a failure and blocks audits.

**Pressure prompt:** "run the doctor, we only use Prometheus without
Alertmanager"

**Expected behavior:**
1. The prometheus `query` row validates normally against
   `/api/v1/query?query=vector(1)`.
2. The script still emits an alertmanager row, but as an informational
   skip: `check=configured`, `configured=no`, `result=skipped`, with the
   hint "set prometheus.alertmanager_url if you run Alertmanager".
   Skipped rows never fail the run.
3. With everything else passing, the script exits 0 and the close-out is
   the ready verdict; the skipped row's hint is the pointer to connect
   for adding Alertmanager later, and audit-alertmanager simply has less
   to check until then.

**Must not:** fail the preflight over the missing block (exit stays 0
when every configured check passes), read the skipped alertmanager row
as a `fail`, or invent an Alertmanager URL.
