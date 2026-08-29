# Report Standard

Every audit skill in the Scoutflo AI Readiness emits the same set of artifacts, in the same place, under the same rules. That is what makes runs comparable over time, deltas computable, scores meaningful across audits, and Slack briefs derivable without per-skill custom code.

## The artifacts

Each audit run writes the same set of files — `findings.json` and `report.md` always, plus `report.html` and `inventory.json` on every `audit-*` skill (`audit-cost` and the combined `audit-all` report are the documented inventory exemptions):

| File | Purpose |
| --- | --- |
| `findings.json` | Machine-readable result: score, severity counts, every finding with evidence. Contract in [findings-schema.md](findings-schema.md). |
| `report.md` | Human-readable report built from the same data: executive summary, scorecard, findings, coverage matrix, next safe actions, delta, evidence appendix. Skeleton in [report-template.md](report-template.md). |
| `report.html` | Standalone visual dashboard rendered from the same `findings.json` (At-a-glance block, scorecard bars, optional blast-radius graph) by [render-report-viz.sh](render-report-viz.sh); see [report-template.md](report-template.md). |
| `inventory.json` | Current-state asset/alert catalog — "everything you have," distinct from the gaps in `findings.json`. Contract in [inventory-schema.md](inventory-schema.md). `audit-cost` and the combined `audit-all` report are exempt (they carry no inventory). |

Both live under one reports directory, `<reports-dir>/`:

```
<reports-dir>/
  <target>/
    history.jsonl        # one line per run; see History ledger below
    <YYYY-MM-DD>/
      findings.json      # canonical machine result (findings-schema.md)
      report.md          # human report, derived (report-template.md)
      report.html        # standalone visual dashboard, derived (render-report-viz.sh)
      inventory.json     # current-state asset/alert catalog (inventory-schema.md); audit-cost/audit-all exempt
  all/<YYYY-MM-DD>/report.md   # combined audit-all summary (no findings.json/inventory.json; per-target files stay canonical)
  topology.md            # optional, written by /scoutflo:map-topology
  exemptions.yaml        # optional, owned by you; see Exemptions below
```

Layout rules:

- **`<reports-dir>` resolution.** Every command block runs in a fresh shell, so the only value that threads through all of them is an environment variable. The effective location is therefore `${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}` — the `SCOUTFLO_AUDIT_DIR` env var when exported, otherwise `./scoutflo-audits` relative to the launch directory. `reports_dir` in `~/.scoutflo/toolkit.yaml` is a *convenience, not a second live tier*: `doctor`/`start` read it only to print the exact `export SCOUTFLO_AUDIT_DIR=...` line to add to your shell profile (and flag the gap if it is set but not yet exported). Because the default is launch-directory-relative, all delta/history/topology/exemptions continuity depends on a *stable* location; a customer with one estate should export `SCOUTFLO_AUDIT_DIR` to one absolute path (and set `reports_dir` so doctor keeps surfacing that export line) so moving folders doesn't fork the history.
- `<target>` is the audit's target slug: the skill name minus its lane prefix. `audit-lgtm` writes to `lgtm/`, `audit-grafana` to `grafana/`.
- `<YYYY-MM-DD>` is the run date in UTC. A re-run on the same date overwrites that date's directory. The day is the run's identity.
- Keep the reports directory out of public version control. Reports contain infrastructure detail about your environment.

## Delta rules

Every run after the first computes a delta against the previous run:

1. Sort the date directories under `./scoutflo-audits/<target>/` and take the latest two. The newest is the current run; the other is the baseline.
2. Match findings by `id`. IDs are stable check identifiers, not per-run counters, so matching by `id` is exact:
   - **fixed**: in the baseline, absent from the current run
   - **new**: in the current run, absent from the baseline
   - **unchanged**: in both; if the finding's `affected` list grew or shrank, say so
3. Score movement: current overall score minus baseline score, plus per-category movement for every category that moved, **only when** both runs have the same `scoring_model` and `check_set`. Otherwise write `score delta not comparable: scoring model or check set changed`; finding lifecycle still compares by stable ID.
4. First run: state "first run, no delta". Never invent a baseline.
5. The delta reads `findings.json` files only: the most recent two are the reuse index for finding-level matching. The longer score trend comes from `history.jsonl` (below); never match findings against the ledger.

## History ledger

Beyond the two-run delta, each target keeps a long-lived trend file: `./scoutflo-audits/<target>/history.jsonl`. After `findings.json` and `report.md` are written, the run appends exactly one JSON line:

```json
{"run_date":"2026-07-17","skill":"audit-lgtm","overall":68,"gate":85,"end_to_end":false,"scoring_model":"assessed-only-v1","check_set":"cksum-v2:123456789:512","assessment_coverage_percent":92,"severity_counts":{"critical":1,"high":2,"medium":4,"low":3,"info":1},"lifecycle_counts":{"new":4,"unchanged":6,"resolved":3,"regressed":1,"suppressed":2}}
```

Rules:

- One line per run date. A re-run on the same date replaces that date's line, matching the directory rule: the day is the run's identity.
- Every value is copied or computed from that run's `findings.json` and its delta. The ledger is derived: never hand-edited, and regenerable from the date directories if lost or corrupted. A malformed line is skipped and reported, never guessed at.
- `lifecycle_counts` counts the run's findings per lifecycle value, plus `resolved` taken from the delta.
- Reports render the last five rows whose `scoring_model` and `check_set` match the current run, oldest first. Incompatible rows stay in the ledger but are not plotted as one numerical trend. With fewer than five compatible runs, render what exists.

### Rotation

`history.jsonl` grows by one line per run forever unless something bounds it. Once it passes `HISTORY_MAX_LINES` (200 lines; example, tune to your run cadence), the audit skill rotates it as the last step after the line for the current run is appended:

1. Keep the most recent 30 lines (including the run just appended) in `history.jsonl`.
2. Compact everything older than those 30 lines into monthly summary rows, one line per calendar month, each carrying that month's `min`, `max`, and `last` overall score, plus that month's total findings by severity summed across its runs.
3. Append the summary rows to `./scoutflo-audits/<target>/history.summary.jsonl`, a second ledger that never gets trimmed.

This is a pure `jq`/`awk` operation on the two files already on disk: no new infra, no database, no cron job. It never touches the trend read: reports still read the last five lines of `history.jsonl` with `tail -n 5`, and that pattern is untouched by rotation because the 30 most recent lines always stay in `history.jsonl`.

```bash
set -eu
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm"        # example; your target's directory
HISTORY="${TARGET_DIR}/history.jsonl"
SUMMARY="${TARGET_DIR}/history.summary.jsonl"
HISTORY_MAX_LINES="200"   # example, tune to your run cadence
KEEP_RECENT="30"          # lines left in history.jsonl after rotation; matches the trend read window

total_lines=$(wc -l < "${HISTORY}" | tr -d ' ')
if [ "${total_lines}" -gt "${HISTORY_MAX_LINES}" ]; then
  to_compact=$((total_lines - KEEP_RECENT))

  # Compact the older lines into one row per calendar month: min/max/last overall
  # score, and total findings by severity that month, summed across that month's runs.
  head -n "${to_compact}" "${HISTORY}" \
  | jq -sc '
      group_by(.run_date[0:7])
      | map({
          month: (.[0].run_date[0:7]),
          runs: length,
          score_min: (map(.overall) | min),
          score_max: (map(.overall) | max),
          score_last: (sort_by(.run_date) | last | .overall),
          severity_counts: (
            reduce .[] as $r
              ({critical:0,high:0,medium:0,low:0,info:0};
               reduce ($r.severity_counts | to_entries[]) as $e (.; .[$e.key] += $e.value))
          )
        })
      | .[]
    ' >> "${SUMMARY}"

  # Keep only the most recent KEEP_RECENT lines in history.jsonl.
  tail -n "${KEEP_RECENT}" "${HISTORY}" > "${HISTORY}.tmp" && mv "${HISTORY}.tmp" "${HISTORY}"
  echo "rotated: compacted ${to_compact} lines into monthly rows, kept ${KEEP_RECENT} in history.jsonl"
else
  echo "no rotation needed: ${total_lines}/${HISTORY_MAX_LINES} lines"
fi
```

Expected: below the threshold, `no rotation needed: N/200 lines` and both files untouched apart from the run's own append. Above it, one or more new lines in `history.summary.jsonl` (one per calendar month compacted) and `history.jsonl` trimmed to exactly `KEEP_RECENT` lines. The `tail -n 5` trend read in [report-template.md](report-template.md) and in `audit-all` (`skills/audit-all/SKILL.md`) keeps working unmodified, because rotation only ever removes lines older than the most recent 30, well past what any five-line trend read touches.

Rules:

- Rotation runs once, as the last step of the run, after the current run's line is already in `history.jsonl`.
- `history.summary.jsonl` is derived and regenerable from the date directories the same way `history.jsonl` is; never hand-edit it.
- A rotation that would compact zero full months (fewer than `KEEP_RECENT` lines exist beyond the threshold) does nothing; there is nothing yet to summarize.

## Using topology and prior runs as a guided walkthrough

An audit re-run is not a blank slate. Two things already on disk exist specifically so the next run doesn't have to rediscover the world from scratch:

- **`topology.md`/`topology-export.json`** (written by `/scoutflo:map-topology`) name the critical services and, per [topology-readiness.md](topology-readiness.md), already carry the T1/T2 structural verdict for each one (map-topology computes this itself, read-only, the moment it writes the export). An audit that loads topology.md is not just borrowing service names — it is inheriting a pre-checked scope: services already failing T1/T2 there will fail the same way in this audit's own Topology Readiness section, so there is no need to re-derive that verdict independently; cite it.
- **The previous run's `findings.json`** (used for the delta, above) also names the estate this target has: `estate.objects`, `estate.path`, and which resource IDs were in scope last time. When today's estate-sizing pre-check returns materially the same object count and `topology.md`'s `generated_at` is not newer than the previous run's `generated_at`, the estate has not meaningfully changed since the last run, and full re-enumeration of *what exists* is redundant work, not more rigor.

What this changes, and what it never changes:

- **Discovery/enumeration may reuse the prior run's scope.** If the estate is unchanged, skip re-listing every RDS instance, every log group, every alarm from zero; use the previous run's object list as the starting point and confirm it with the cheap estate-sizing count, not a full re-walk.
- **Every live check still runs fresh, always.** An alarm's current state, a subscription's confirmation status, a dashboard's live query result — none of that is ever read from a prior run. "Configuration is metadata, live validation is proof" (every audit skill's own ground rule) does not bend for efficiency. Incremental reuse applies to *what to check*, never to *whether a check's result is still true*.
- **State which mode ran.** The report says "estate unchanged since 2026-07-18, reused scope" or "estate changed (14 -> 19 objects), full re-discovery" — never silently. A customer reading two reports back to back should be able to tell which happened.
- **A missing or stale `topology.md` is not an error, just a worse starting point.** Audits already handle this (infer services, note the inference, suggest `/scoutflo:map-topology`); the guided-walkthrough behavior above is additive on top of that existing fallback, not a new requirement to build.

This is why `map-topology`'s own T1/T2 pre-check (in its own SKILL.md) exists: it is the first, cheapest checkpoint in the whole walkthrough, and every audit that follows inherits its result instead of re-asking the same structural question.

## The documents

| Doc | Contents |
| --- | --- |
| [findings-schema.md](findings-schema.md) | The findings.json contract: envelope, finding object, ID rules, evidence rules |
| [severity-and-scoring.md](severity-and-scoring.md) | Severity definitions, status values, the weighted scoring model, the end-to-end gate, the coverage definition |
| [report-template.md](report-template.md) | The report.md skeleton and the Slack brief derivation |
| [inventory-schema.md](inventory-schema.md) | The `scoutflo-inventory/v1` contract for `inventory.json`: the current-state asset/alert catalog every audit writes beside its findings (`audit-cost`/`audit-all` exempt) |
| [cost-schema.md](cost-schema.md) | The separate `scoutflo-cost/v1` ranked-savings contract emitted by `audit-cost` (non-scored, `COST-<PROVIDER>` IDs, validated by `check-cost.sh`) |
| [estate-scope-checkpoint.md](estate-scope-checkpoint.md) | The shared estate-sizing thresholds (small/medium/large/xlarge) and the large-estate scope-pause every audit wires in |
| [secret-redaction.md](secret-redaction.md) | The secret-redaction discipline: capture credentials by key/name only, never print or write a value |
| [topology-readiness.md](topology-readiness.md) | The optional Scoutflo Topology Readiness section: the six per-service checks and how to render them |
| [depth-doctrine.md](depth-doctrine.md) | The depth bar every scored finding must clear — precise locus, live-derived blast radius, correlation chains, exact fix + verification — so a finding is worth more than a free scanner's "X is missing" |

Every audit must conform to the findings, scoring, and report-template contracts; `audit-cost` also conforms to cost-schema; every audit carries the estate-scope and secret-redaction disciplines; and every scored finding must clear the [depth doctrine](depth-doctrine.md). Topology Readiness is optional (rendered when a topology export exists). Authoring rules for the skills themselves live in [../docs/skill-authoring-conventions.md](../docs/skill-authoring-conventions.md).

## Exemptions

You silence accepted-risk findings without losing sight of them. The file is `./scoutflo-audits/exemptions.yaml`, owned by you:

```yaml
exemptions:
  - id: LGTM-014
    reason: "single-node Loki is accepted for the dev cluster"
    approved_by: "name or ticket"
    expires: 2026-10-01
```

Rules:

- `id`, `reason`, and `expires` are mandatory; an exemptions.yaml entry missing any of them is ignored and reported as malformed.
- A live exemption moves the finding to the report's Suppressed appendix with its reason and expiry. In a v2 artifact, its original partial/fail check row also carries `suppressed: true` and `suppression_reason`, so the validator can prove it left the readiness denominator. It never deletes the finding and never affects other findings.
- Past `expires`, the exemption is dead: the finding returns to the open findings table flagged "exemption expired".
- Suppressed findings are excluded from the score and severity counts; the scorecard states how many were suppressed so the score is never silently flattered.
