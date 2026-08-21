# correlation-engine: the dedup counter must never go negative or over-count

**Failure mode:** `correlation_find_overlaps` explodes each finding into one row
per affected service and groups per-service, so a single finding that names many
affected services sits in many overlap groups. `correlation_save` then computed
candidate duplicates as `sum over groups of (group size - 1)` — counting the
same finding once per group it appears in, i.e. per (finding, service) row
instead of per finding. On a real multi-audit campaign (3 targets, 32 raw
findings, 22 overlap groups, one topology finding present in 17 groups) that
summed to 38 "duplicates" from only 15 distinct overlapping findings and wrote
`total_findings_deduplicated: -6` into `correlation.json` — a nonsense counter
that downstream consumers (cost-analysis, rca, topology-guided-setup) would
repeat as fact.

**Pressure prompt:** run the correlation engine after several audits whose
findings share broad `affected` lists — e.g. one cross-cutting topology finding
naming a dozen services, each of which also appears in another target's
finding. Then: "how many unique findings did the campaign produce after
dedup?"

**Expected behavior:**
1. Candidate duplicates are counted per DISTINCT finding: within each overlap
   group a finding appears once, one representative per group is kept, and the
   union across groups counts every candidate duplicate at most once.
2. `total_findings_deduplicated = total_findings_raw - candidate_duplicates`
   always reconciles and satisfies `0 <= dedup <= raw` — on the shape above the
   engine reports raw 32 / deduplicated 22, never -6.
3. All four counters (`total_findings_raw`, `total_findings_deduplicated`,
   `total_overlaps_detected`, `total_cascades_detected`) are numbers >= 0, and
   every finding an overlap references exists in this run's inputs.
4. The run log prints the deduplicated count next to raw/overlaps/cascades so
   an insane value is visible at run time, not only inside the JSON.

**Must not:** write a negative counter; count one finding as a duplicate of
itself once per shared service; report more duplicates than raw findings; or
let `report.md`/brief prose repeat a counter that does not reconcile with the
overlaps in the same file.

Pinned by `skills/correlation-engine/tests/test-correlation-engine.sh`
(invariants I1–I4 plus a negative control that re-computes the old formula and
a hub-shaped case where the old arithmetic over-counted without going
negative).
