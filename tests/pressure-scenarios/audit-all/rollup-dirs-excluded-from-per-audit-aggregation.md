# audit-all: the cost-analysis / all roll-up dirs must never enter the per-audit aggregation

**Failure mode:** Phase 3.6 writes `cost-analysis/<date>/findings.json`, whose
schema is deliberately different from a per-audit findings.json — `target` is
`null`, there is no `.score`, and its findings carry no `severity`/`lifecycle`.
Every Phase 3 and Phase 5 aggregation loop globs
`"$AUDITS_DIR"/*/"$RUN_DATE"/findings.json`, so the roll-up dir gets swept in
alongside `aws`, `lgtm`, etc. The consequences, all observed on a real
11-target run:
- the top-findings step (`jq -rs '[.[].findings[]] | map(... {rank: {...}[.severity]})'`)
  crashes `Cannot index object with null` (exit 5, no Top-findings output);
- the Phase 5 checks-passed roll-up (`[.score.categories[].checks_passed]`)
  crashes `Cannot iterate over null` and, under `/bin/sh set -e`, aborts the
  brief assembly — the Slack "checks passed" denominator goes missing;
- the Scores / Estate / Suppressed / Topology-readiness roll-ups leak a spurious
  `null:` row, and the Phase 4 verify step even fails looking for a
  `| null ` score row.

**Pressure prompt:** "run audit-all across everything and give me the combined
brief — scores, top findings, and how many checks passed."

**Expected behavior:**
1. Every aggregation loop skips a findings.json that is not the per-audit schema,
   mirroring the `render-report-viz.sh` guard: read `.target // "?"` and
   `continue` when it is `all` or `?` (the roll-up dirs — `cost-analysis/` has a
   `null` target → `?`, and `all/` is `all`).
2. The top-findings `jq -rs` filters the same way inline
   (`select(.target != null and .target != "all")`) before flattening
   `.findings[]`, so a severity-less roll-up finding never reaches the rank
   lookup.
3. Result: top findings render, `checks passed: <n>/<m>` computes a real
   denominator, and the Scores/Estate/Suppressed/Topology tables list only the
   real audit targets — no `null:` rows, exit 0.

**Must not:** crash or abort a combined run because the cost roll-up exists;
emit a `null:` row for any roll-up dir; or count the roll-up's findings as if they
were a scored audit target.
