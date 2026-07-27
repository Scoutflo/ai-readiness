---
name: audit-all
description: Runs every audit configured in toolkit.yaml and writes one combined summary with per-target scores, estate sizes, score trends from each history ledger, and blocked audits, plus a single combined Slack brief. Use when the user asks to audit everything, run all audits, check overall observability health, or wants one combined report or brief across stacks. Do not use for a single stack (run its audit directly, such as audit-grafana) or to fix findings (use a setup-* skill).
---

# Combined Audit

Runs each configured `audit-*` skill in sequence, then rolls the results into one summary report and, when requested, one Slack brief. This skill orchestrates; it re-runs no checks and re-scores nothing. Each audit's own `findings.json` and `report.md` stay canonical. The whole run is read-only apart from the report files it writes locally.

## Prerequisites

| Requirement | Check |
| --- | --- |
| `~/.scoutflo/toolkit.yaml` | Exists and parses; at least one integration block present |
| `curl`, `jq` | Installed |
| Per-integration credentials | Checked by each audit's own doctor gate, not here |

If the config file is missing or empty, stop and point at `/scoutflo:connect`.

## Phase 1: Build the run plan

List the top-level integration keys in the config:

```bash
set -eu
CONFIG="$HOME/.scoutflo/toolkit.yaml"   # toolkit config location
[ -f "$CONFIG" ] || { echo "missing $CONFIG; run /scoutflo:connect"; exit 1; }
awk -F: '/^[a-z_]+:/{print $1}' "$CONFIG"
```

Expected output: one key per line, for example `grafana`, `sentry`, `prometheus`, `loki`, `slack`. Map keys to audits:

| Config keys present | Audit queued |
| --- | --- |
| `prometheus`, `loki`, `tempo`, `mimir`, or `victoriametrics` | `audit-lgtm` |
| `grafana` | `audit-grafana` |
| `sentry` | `audit-sentry` |
| `pagerduty` | `audit-pagerduty` |
| `datadog` | `audit-datadog` |
| `elk` | `audit-elk` |
| `jsm` | `audit-jsm` |
| `zenduty` | `audit-zenduty` |
| `groundcover` | `audit-groundcover` |
| `prometheus.alertmanager_url` or `victoriametrics.vmalert_url` | `audit-alert-routing` |
| `digitalocean` | `audit-digitalocean` |
| `gcp` | `audit-gcp` |
| `aws` | `audit-aws` |

Show the plan before running anything: every queued audit in order, and every skipped audit with the reason "not configured". If `./scoutflo-audits/topology.md` is missing, note that findings will use inferred service names and suggest `/scoutflo:map-topology`, but do not block.

## Phase 2: Run each audit

Run the queued audits one at a time, in the table's order, each exactly per its own `SKILL.md`: its doctor gate, its checks, its `findings.json` and `report.md`. Two overrides apply under orchestration:

1. Individual audits send no Slack brief. The combined brief in Phase 5 is the run's only message.
2. A failure in one audit never stops the others.

Partial-failure rules, per the report standard's blocked-section handling:

- An audit whose doctor gate fails is marked `blocked` in the run plan with the exact failing check and the fix, usually `/scoutflo:connect`. The remaining audits still run.
- An audit that starts but cannot finish is also marked `blocked`, with the last failing check as the reason. Note any partial artifacts it wrote; do not summarize them as a completed run.
- Blocked audits appear in the combined report and the brief with their reason. They are never silently dropped, and never scored as zero.
- If every queued audit is blocked, stop: print the failures, write no combined report, send no brief.

## Phase 3: Collect results

Collect three things per completed target: today's results, the estate size the audit recorded, and the score trend from its history ledger.

Aggregate today's `findings.json` files. Only files matching today's UTC date belong to this run:

```bash
set -eu
AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"   # report-standard output root
RUN_DATE="$(date -u +%F)"        # UTC run date; matches each audit's directory name

for f in "$AUDITS_DIR"/*/"$RUN_DATE"/findings.json; do
  [ -e "$f" ] || continue
  jq -r '"\(.target): \(.score.overall)/100 | critical=\(.severity_counts.critical) high=\(.severity_counts.high) medium=\(.severity_counts.medium) low=\(.severity_counts.low) info=\(.severity_counts.info)"' "$f"
done
```

Expected output: one line per completed audit, for example `lgtm: 68/100 | critical=1 high=2 medium=4 low=3 info=1`. No lines means no audit completed; go back to the Phase 2 failures.

Top findings across all targets, highest severity first:

```bash
set -eu
AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"   # report-standard output root
RUN_DATE="$(date -u +%F)"        # UTC run date; matches each audit's directory name

jq -rs '
  [.[].findings[]]
  | map(. + {rank: {"critical":0,"high":1,"medium":2,"low":3,"info":4}[.severity]})
  | sort_by(.rank) | .[:5][]
  | "\(.id) [\(.severity)] \(.title)"
' "$AUDITS_DIR"/*/"$RUN_DATE"/findings.json
```

Estate-size roll-up. Each audit's estate-sizing pre-check records its object counts and sizing path in its `findings.json`; surface them side by side so an oversized or truncated run is visible at a glance:

```bash
set -eu
AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"   # report-standard output root
RUN_DATE="$(date -u +%F)"        # UTC run date; matches each audit's directory name

for f in "$AUDITS_DIR"/*/"$RUN_DATE"/findings.json; do
  [ -e "$f" ] || continue
  jq -r '"\(.target): " + (if .estate then "\(.estate.objects) objects, \(.estate.path) path" else "estate not recorded" end)' "$f"
done
```

Expected output: one line per completed audit, for example `grafana: 214 objects, medium path`. An audit that did not record estate data reads `estate not recorded`; carry that phrase into the report, never guess a size.

Score trend per target, from each target's `history.jsonl`. The ledger is the only trend source; the two most recent `findings.json` files stay reserved for finding-level matching inside each audit:

```bash
set -eu
AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"   # report-standard output root

for h in "$AUDITS_DIR"/*/history.jsonl; do
  [ -e "$h" ] || continue
  target=$(basename "$(dirname "$h")")
  lines=$(tail -n 5 "$h" | wc -l | tr -d ' ')
  parsed=$(tail -n 5 "$h" | jq -Rr 'fromjson? | .overall' | wc -l | tr -d ' ')
  trend=$(tail -n 5 "$h" | jq -Rr 'fromjson? | .overall' \
    | awk '{printf "%s%s", s, $0; s=" -> "} END {print ""}')
  [ "$parsed" -eq "$lines" ] || echo "${target}: $((lines - parsed)) malformed history line(s) skipped"
  echo "${target}: ${trend} (last ${parsed} runs, oldest first)"
done
```

Expected output: one line per target with a ledger, for example `lgtm: 55 -> 61 -> 68 (last 3 runs, oldest first)`. A target with no `history.jsonl` gets no trend line; state "no history yet" for it in the report. Malformed ledger lines are skipped and reported, never guessed at.

The two history artifacts have two jobs; do not swap them:

- ❌ Read five old `findings.json` files across dates to compute the trend line.
- ✅ The trend renders from the last five `history.jsonl` lines; `findings.json` is read only for today's results here, and for finding-level matching inside each audit's own delta.

Regressions across all targets. `lifecycle` is computed inside each audit's own run per the [findings schema](../../report-standard/findings-schema.md); this step only reads that field, it never re-derives it:

```bash
set -eu
AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"   # report-standard output root
RUN_DATE="$(date -u +%F)"        # UTC run date; matches each audit's directory name

for f in "$AUDITS_DIR"/*/"$RUN_DATE"/findings.json; do
  [ -e "$f" ] || continue
  jq -r '.target as $t | .findings[] | select(.lifecycle == "regressed") | "\($t): \(.id) [\(.severity)] \(.title)"' "$f"
done
```

Expected output: one line per regressed finding, for example `lgtm: LGTM-014 [critical] Default Alertmanager receiver points to a dead webhook`. No lines means no regressions this run; the combined report and brief state that explicitly instead of omitting the line.

Suppressed findings across all targets, from the same `lifecycle` field:

```bash
set -eu
AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"   # report-standard output root
RUN_DATE="$(date -u +%F)"        # UTC run date; matches each audit's directory name

TOTAL=0
for f in "$AUDITS_DIR"/*/"$RUN_DATE"/findings.json; do
  [ -e "$f" ] || continue
  t=$(jq -r '.target' "$f")
  n=$(jq -r '[.findings[] | select(.lifecycle == "suppressed")] | length' "$f")
  echo "${t}: ${n} suppressed via exemptions"
  TOTAL=$((TOTAL + n))
done
echo "total suppressed across all targets: ${TOTAL}"
```

Expected output: one line per target plus a total, for example `lgtm: 2 suppressed via exemptions` then `total suppressed across all targets: 5`. A target with zero suppressed findings still gets its line, at `0`.

Topology readiness per target, read from each target's own `report.md` (the headline is not a `findings.json` field; [topology-readiness.md](../../report-standard/topology-readiness.md) defines it as the report's section headline `<r> of <n> critical services sync-ready`):

```bash
set -eu
AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"   # report-standard output root
RUN_DATE="$(date -u +%F)"        # UTC run date; matches each audit's directory name

for f in "$AUDITS_DIR"/*/"$RUN_DATE"/findings.json; do
  [ -e "$f" ] || continue
  t=$(jq -r '.target' "$f")
  REPORT="$(dirname "$f")/report.md"
  if [ -f "$REPORT" ]; then
    LINE="$(grep -m1 -o '[0-9]\+ of [0-9]\+ critical services sync-ready' "$REPORT" || true)"
    if [ -n "$LINE" ]; then
      echo "${t}: ${LINE}"
    else
      echo "${t}: readiness not recorded"
    fi
  else
    echo "${t}: report.md missing"
  fi
done
```

Expected output: one line per completed target, for example `lgtm: 4 of 6 critical services sync-ready`. A target whose report has no readiness section (map-topology never run, or the audit skill predates the section) reads `readiness not recorded`; never guess a count.

## Phase 4: Combined summary report

Write `./scoutflo-audits/all/<YYYY-MM-DD>/report.md`. It summarizes and links; it does not restate evidence. Sections, in order:

1. **Header**: date (UTC), toolkit version, audits run as `<n> of <m> configured`.
2. **Scores**: one row per completed target: score, severity counts, estate size and sizing path (from the Phase 3 roll-up; `estate not recorded` when the audit did not emit one), delta versus that target's previous run (`+9`, `-3`, or `first run`), the score trend from its `history.jsonl` (last five runs, oldest first; `no history yet` when the ledger is missing), and the relative path to its full `report.md`. One score line per target, never a combined average: an average hides a failing stack behind a healthy one.
3. **Blocked audits**: one row per blocked audit with reason and fix pointer. Omit the section only when nothing was blocked, and then state "No audits blocked."
4. **Regressions**: the Phase 3 regressions list, one row per regressed finding with its target, ID, severity, and title, ordered highest severity first. State "No regressions this run." when the list is empty. This section always precedes Top findings; regressions are the highest-signal state in the lifecycle model and are named before anything else.
5. **Topology Readiness (combined)**: one row per completed target, its "`<r> of <n> critical services sync-ready`" headline from the Phase 3 topology-readiness roll-up, and a link to that target's own Scoutflo Topology Readiness section for the per-service detail. A target whose roll-up line read `readiness not recorded` gets that exact phrase in its row, not a blank or a guess.

   | Target | Sync-ready | Detail |
   | --- | --- | --- |
   | `<target>` | `<r> of <n> critical services sync-ready` or `readiness not recorded` | link to that target's `report.md#scoutflo-topology-readiness` |

6. **Top findings**: the Phase 3 list with each finding's target added.
7. **Suppressed**: the Phase 3 suppressed-findings roll-up, one line per target plus the `total suppressed across all targets` line. State "No findings suppressed via exemptions this run." when the total is `0`.
8. **Next safe actions**: the highest-severity findings across all targets, each row pointing at its finding ID and its remediation pointer (a `setup-*` skill anchor), verification-only steps before mutating ones. No timelines, no effort estimates.

Verify the write with an asserted command, not a glance:

```bash
set -eu
AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"   # report-standard output root
RUN_DATE="$(date -u +%F)"        # UTC run date
REPORT="${AUDITS_DIR}/all/${RUN_DATE}/report.md"

[ -f "${REPORT}" ] || { echo "combined report not written"; exit 1; }
n=0
for f in "$AUDITS_DIR"/*/"$RUN_DATE"/findings.json; do
  [ -e "$f" ] || continue
  t=$(jq -r '.target' "$f")
  grep -q "| ${t} " "${REPORT}" || { echo "score row missing for ${t}"; exit 1; }
  n=$((n + 1))
done
echo "verified: ${n} completed target row(s) present"
```

Expected: exit 0 and one `verified:` line whose count equals the number of completed audits. A missing row exits 1 naming the target; fix the report before sending any brief.

The combined brief includes total check denominators across targets
("87/104 checks passed"), lists regressions before anything else, and
sums suppressed counts ("5 suppressed via exemptions"). Every one of
those three numbers is read straight from the Phase 3 roll-ups above
(the regressions list, the suppressed-count total) or the Phase 5
checks-passed roll-up below (`score.categories[].checks_passed` and
`.checks_total`, summed first within each target's categories, then
across all targets), never asserted in prose without a command backing
it.

## Phase 5: Combined Slack brief

Send only when the user passed `--slack` or asked for Slack delivery. Exactly one message per run, assembled per the report standard: header with date, one score line per target with movement, aggregate severity counts, total check denominators across targets, regressions listed first (from the Phase 3 regressions roll-up), top 3 to 5 remaining finding titles with IDs, per-target delta or `first run`, the suppressed-findings total (from the Phase 3 suppressed roll-up), blocked audits with a one-line reason, the topology readiness line per target, and the local combined report path. Titles and scores only; never evidence values, hostnames, or endpoints. The webhook posts to a chat system you do not fully control, so the brief must be safe to leak.

Compute the regressions and suppressed lines the brief needs, redeclaring every variable since this runs in its own shell:

```bash
set -eu
AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"   # report-standard output root
RUN_DATE="$(date -u +%F)"        # UTC run date

REGRESSIONS="$(for f in "$AUDITS_DIR"/*/"$RUN_DATE"/findings.json; do
  [ -e "$f" ] || continue
  jq -r '.target as $t | .findings[] | select(.lifecycle == "regressed") | "\($t): \(.id) \(.title)"' "$f"
done)"
[ -n "$REGRESSIONS" ] || REGRESSIONS="none"

SUPPRESSED_TOTAL=0
for f in "$AUDITS_DIR"/*/"$RUN_DATE"/findings.json; do
  [ -e "$f" ] || continue
  n=$(jq -r '[.findings[] | select(.lifecycle == "suppressed")] | length' "$f")
  SUPPRESSED_TOTAL=$((SUPPRESSED_TOTAL + n))
done

CHECKS_PASSED=0
CHECKS_TOTAL=0
for f in "$AUDITS_DIR"/*/"$RUN_DATE"/findings.json; do
  [ -e "$f" ] || continue
  p=$(jq -r '[.score.categories[].checks_passed] | add // 0' "$f")
  t=$(jq -r '[.score.categories[].checks_total] | add // 0' "$f")
  CHECKS_PASSED=$((CHECKS_PASSED + p))
  CHECKS_TOTAL=$((CHECKS_TOTAL + t))
done

echo "regressions: ${REGRESSIONS}"
echo "suppressed via exemptions: ${SUPPRESSED_TOTAL}"
echo "checks passed: ${CHECKS_PASSED}/${CHECKS_TOTAL}"
```

Expected output: `regressions: none` (or the target-prefixed list), followed by `suppressed via exemptions: <n>`, followed by `checks passed: <n>/<m>`. These are the exact strings the brief template below quotes; nothing in the brief states a regression, suppression, or checks-passed number that was not printed here first. `checks_passed` and `checks_total` live per category under `score.categories[]` in each target's `findings.json` (see [findings-schema.md](../../report-standard/findings-schema.md)); this sums both across every category, then across every target.

```bash
set -eu
RUN_DATE="$(date -u +%F)"        # UTC run date
BRIEF_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/all/${RUN_DATE}/brief.txt"   # brief assembled per the rules above
# slack.webhook_env in toolkit.yaml names the webhook variable. Never print its value.
if [ -z "${SCOUTFLO_SLACK_WEBHOOK:-}" ]; then
  echo "Slack webhook variable not set; skipping brief"
else
  jq -Rs '{text: .}' < "$BRIEF_FILE" \
    | curl -fsS --max-time 10 -X POST -H "Content-Type: application/json" --data @- "$SCOUTFLO_SLACK_WEBHOOK" \
    || echo "Slack send failed; brief not delivered. The audit run itself is complete."
fi
```

Expected output: Slack webhooks return `ok` on success. A failed send is noted in the terminal and never fails the run.

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| A blocked audit silently missing from the summary | The run plan lists every configured audit; blocked ones carry a reason all the way into the report and brief |
| Yesterday's findings mixed into today's summary | Aggregate only `findings.json` files under today's UTC date directory |
| Combined brief leaks evidence values | The brief carries titles, IDs, and scores only; evidence stays in the local reports |
| Multiple Slack messages for one run | Individual audits are muted under orchestration; Phase 5 sends the single combined message |
| One average score presented for the whole estate | Report one score line per target; never average across targets |
| Partial audit artifacts summarized as a completed run | An audit that did not finish is blocked, whatever files it managed to write |
| Trend computed by re-reading old findings.json files | The score trend reads `history.jsonl` only; findings.json files serve today's results and each audit's own delta |
| Estate size invented for an audit that never recorded one | Missing estate data reads `estate not recorded` in the summary; never guess counts |
| Regressions or suppressed counts stated in prose with no command behind them | Both are computed by the Phase 3 roll-up commands from each target's `lifecycle` field; the report and brief only ever quote those printed values |
| Topology readiness guessed or left out of the combined report | Each target's headline is read from its own `report.md` in Phase 3; a target with no readiness section reads `readiness not recorded`, never a guessed count |
