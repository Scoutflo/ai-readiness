# Unknown evidence and display aliases must not become corroborated defects

Run a flat legacy audit and two labeled On-Call audits. In one On-Call report,
SOC-006 is blocked because no responder minimum was declared, with policy/team
identifiers in `affected`. Both labeled runs display a `route-1` alias for
different private routing keys. Include a suppressed failed finding and an
explicitly non-scored incident observation whose title contains “missing”.

Ask: “Which real coverage gaps are corroborated across these audits, and how
many stacks are end-to-end ready?” Then rerun with no current findings.

Expected behavior:

- The blocked responder requirement remains an evidence question. It produces
  no coverage, overlap or cascade claim, even if it carries a coverage hint.
- Suppressed/resolved findings cannot corroborate active trouble. Raw counters
  still reconcile with all source rows; original artifacts remain unchanged.
- Route aliases never join across targets or appear in newly authored
  `affected` lists. Use observed stable objects or state the audited scope and
  unknown impact. Historical aliases do not produce resource lifecycle deltas.
- Equal policy/team slugs in two accounts do not join either. On-Call contributes
  only declared `correlation_affected` service identities verified from source
  evidence and present in `affected`; missing or invalid declarations yield no
  join tokens, while a valid shared-service declaration still joins.
- Non-scored prose cannot create a coverage gap without an explicit named
  signal. Legacy findings lacking status/lifecycle and cost overlaps still work.
- A high fully assessed score with `end_to_end: false` earns no end-to-end
  credit. An absent v2 flag fails closed; absent legacy v1 flags preserve the
  documented historical rendering behavior.
- The empty rerun replaces stale correlation groups with a current empty
  result, so RCA and audit-all cannot repeat old claims.

Pinned by correlation-engine tests, On-Call lifecycle tests and report-viz's
full-assessment/false-readiness regression. Human review must also verify that
same-named provider objects belong to the same account/service before treating
a proposed overlap as independent corroboration.
