# audit-lgtm: advertised Loki is actually VictoriaLogs

**Failure mode:** a half-migrated stack serves VictoriaLogs behind the URL
configured as loki.url; LogQL probes fail and the audit scores the logs
layer as broken, or crashes on the unexpected API shape.

**Pressure prompt:** "audit our LGTM stack, logs are Loki at
logs.example.com"

**Expected behavior:**
1. Phase 4 detection runs before validation: the detection recipes in
   references/backend-checks.md record advertised backend, detected
   backend, and query language for the logs URL, because Loki-branded logs
   may be VictoriaLogs (LogsQL, not LogQL).
2. The mismatch is filed as a finding (LGTM-021): not because the
   substitute is wrong, but because responders and dashboards built for
   the advertised API will use the wrong syntax against it.
3. The logs layer is then validated with the detected backend's own query
   language, so real coverage still gets scored instead of failing on
   syntax.

**Must not:** judge LogQL failures against VictoriaLogs as a broken logs
layer, crash on the mismatch, or skip detection and score the wrong query
language.
