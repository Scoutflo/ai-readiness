# audit-all: same-run regression in one target, suppression in another

**Failure mode:** In the same run, `lgtm`'s `findings.json` has a finding
whose `lifecycle` is `regressed` (an ID that was resolved in an earlier
run and is failing again), while `grafana`'s `findings.json` has a
different finding whose `lifecycle` is `suppressed` (matched by a live
`exemptions.yaml` entry). Both are real, independent per-target facts
about the same UTC run date. A naive combined roll-up could conflate
the two lifecycle states, double-count one of them, or let one target's
count bleed into the other's line.

**Pressure prompt:** "run all the audits and give me the combined
report and Slack brief"

**Expected behavior:**
1. Phase 3's regressions roll-up selects only `lifecycle == "regressed"`
   findings and prints `lgtm: <id> [critical] <title>`. It does not
   surface grafana's suppressed finding here — `suppressed` is a
   distinct lifecycle value, never treated as a regression.
2. Phase 3's suppressed roll-up selects only `lifecycle == "suppressed"`
   findings, separately, per target: `lgtm: 0 suppressed via
   exemptions` and `grafana: 1 suppressed via exemptions`, plus `total
   suppressed across all targets: 1`. lgtm's suppressed count stays `0`
   even though lgtm has a regression; the two counters never share a
   variable.
3. The combined report's Regressions section lists lgtm's regressed
   finding first (per the rule that regressions precede Top findings),
   and its Suppressed section lists grafana's one suppressed finding
   with the `total suppressed across all targets: 1` line — the
   regressed finding from lgtm never appears in the Suppressed section,
   and the suppressed finding from grafana never appears in the
   Regressions section.
4. The combined Slack brief's regressions line names lgtm's finding
   only, and its suppressed line reads the same total (`1`) computed by
   the Phase 5 compute block, matching the report exactly.
5. Both targets' `score.categories[].checks_passed`/`checks_total`
   still sum correctly into the brief's combined checks-passed total
   regardless of which target holds the regression or the suppression —
   the checks-passed roll-up is independent of lifecycle state.

**Must not:** merge lgtm's regression into grafana's suppressed count
or vice versa, report a combined suppressed total that includes the
regressed finding, report a regressions list that includes the
suppressed finding, or let one target's zero count for a lifecycle
state suppress the other target's non-zero count for that same state.
