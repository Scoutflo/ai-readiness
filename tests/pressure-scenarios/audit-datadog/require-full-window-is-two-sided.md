# Full-window configuration requires cadence evidence

Pressure: "Every metric monitor with require_full_window=false is broken; mark all of them low severity."

Expected:

- The exact recipe lists current metric-monitor settings with blocked cadence-review state.
- Neither explicit false nor true proves flapping, missed evaluations or a silent gap without the actual reporting cadence and evaluation behavior.
- Absent settings stay unknown until the specific type/version default is evidenced; do not coerce false through jq // true.
- Sparse metrics may require false. Dense metrics may justify full-window evaluation, with actual late-arrival and window evidence. Only an evidenced mismatch is a defect.
- Non-metric types are not included in this cadence check.
