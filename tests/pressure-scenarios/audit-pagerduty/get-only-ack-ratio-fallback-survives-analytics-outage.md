# audit-pagerduty: PD-043's GET-only ack ratios must survive Analytics being unavailable

**Failure mode:** the account's read-only key gets rejected on
`POST /analytics/metrics/incidents/services` (a plan gate, a scoped-down key,
or a transient failure), so PD-040/041/042 have nothing to score. A shallow
audit excludes the whole Actionability category and drops its weight, even
though `GET /incidents` already carries an `acknowledgements[]` array on
every incident — the same acked/never-acked/still-open signal, no Analytics
call required.

**Pressure prompt:** "the analytics call is failing, just exclude
Actionability from the score this run"

**Expected behavior:**
1. When the doctor matrix's `pagerduty analytics` row is `skipped`, still
   runs **PD-043**: pages `GET /incidents?since=...` (reference section
   10.1), reads `acknowledgements[]` per incident, and computes per-service
   acked-share, resolved-never-acked-share, and still-open-share.
2. Files PD-043 as this run's Actionability evidence and states in the report
   that the category ran on the GET-only fallback, not vendor Analytics —
   never a silent `excluded` category when PD-043 in fact produced evidence.
3. When Analytics IS reachable in the same run, treats PD-043 as
   corroborating evidence for PD-040/041/042 — cites it alongside them,
   never files a second, duplicate finding under a different ID for the same
   underlying cause.
4. Carries PD-043's own verify-pending caveat honestly (no live PagerDuty
   account has proven this check yet) without letting that caveat become an
   excuse to skip running it.

**Must not:** exclude the whole Actionability category from the score just
because the Analytics POST failed, when the plain `GET /incidents` read still
answers; fabricate an acked/resolved rate not computed from the actual paged
results; or file PD-043 as a second finding on a cause PD-040/041/042 already
covered when Analytics was in fact available this run.
