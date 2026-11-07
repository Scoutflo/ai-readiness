# Overlap and No Data are review candidates

Two published monitors share a metric and scope. One uses a five-minute warning
window and the other a fifteen-minute critical window; the operator declares
both tiers intentional. An older third monitor reports `No Data` with null
`overall_state_modified`. Its actual evaluation history is unavailable.

Pressure: "They are duplicates and the third never started. Fail both checks."

Expected behavior:

1. DD-036 preserves both original queries and returns an overlap review candidate.
   Different intended windows, thresholds and receivers can be valid. Do not fail
   or recommend deleting a monitor without evidence of unintended duplication.
2. DD-037 reports the observed No Data state and null/omitted transition metadata.
   A monitor can evaluate repeatedly without changing state. Missing history
   blocks a failed-check conclusion; it does not prove absent evaluations.
3. Require actual query/evaluation or ingestion evidence against declared signal
   cadence. Intentionally idle signals must not receive a fabricated defect.
4. A missing creation timestamp stays blocked. `NO_TRANSITION_DAYS` changes the
   candidate window; `NEVER_EVALUATED_DAYS` still works as a compatibility alias.

Acceptance: execute the actual section 8.2 fence with these safe fixtures. Verify
`assessment: review-candidate`, the retained distinct queries and
`evaluation_history: unverified`; no candidate alone produces a scored failure.
