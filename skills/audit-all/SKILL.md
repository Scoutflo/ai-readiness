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
CONFIG="${SCOUTFLO_CONFIG:-}"
[ -n "$CONFIG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CONFIG="$_c"; break; }; done
[ -n "$CONFIG" ] || CONFIG="$HOME/.scoutflo/toolkit.yaml"   # toolkit config location
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
| `azure` | `audit-azure` |
| `kubernetes` | `audit-kubernetes` |
| `clickstack` | `audit-clickstack` |
| `signoz` | `audit-signoz` |

Show the plan before running anything: every queued audit in order, and every skipped audit with the reason "not configured". For each queued own-block audit, enumerate its targets with `sh "${CLAUDE_PLUGIN_ROOT}/report-standard/toolkit-targets.sh" "$CONFIG" <block> labels` and show one plan line per target when a block is a labeled list (e.g. `azure (prod-core)`, `azure (prod-data)`), so the plan makes the per-target fan-out visible rather than hiding N targets behind one row. If `./scoutflo-audits/topology.md` is missing, note that findings will use inferred service names and suggest `/scoutflo:map-topology`, but do not block.

## Phase 2: Run each audit

Run the queued audits one at a time, in the table's order, each exactly per its own `SKILL.md`: its doctor gate, its checks, its `findings.json` and `report.md`. An own-block audit whose integration is a labeled list iterates **every** target per its own SKILL.md (running its full sequence once per label with `SCOUTFLO_TARGET=<label>` set) — never collapse a labeled list to its first target; each target writes its own `<integration>/<label>/<date>/` directory, which the Phase 3 roll-ups and Phase 3.5 correlation already aggregate. Two overrides apply under orchestration:

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

for f in "$AUDITS_DIR"/*/"$RUN_DATE"/findings.json "$AUDITS_DIR"/*/*/"$RUN_DATE"/findings.json; do
  [ -e "$f" ] || continue
  # Skip the roll-up dirs (cost-analysis/, all/): their findings.json is not the
  # per-audit schema (no .target, no .score, severity-less findings). Mirrors the
  # render-report-viz.sh guard (case "$tgt" in all|"?").
  case "$(jq -r '.target // "?"' "$f" 2>/dev/null)" in (all|cost|cost-analysis|doctor|"?") continue ;; esac
  jq -r '"\(.target): \(.score.overall)/100 | critical=\(.severity_counts.critical) high=\(.severity_counts.high) medium=\(.severity_counts.medium) low=\(.severity_counts.low) info=\(.severity_counts.info)"' "$f"
done
```

Expected output: one line per completed audit, for example `lgtm: 68/100 | critical=1 high=2 medium=4 low=3 info=1`. No lines means no audit completed; go back to the Phase 2 failures.

Top findings across all targets, highest severity first:

```bash
set -eu
AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"   # report-standard output root
RUN_DATE="$(date -u +%F)"        # UTC run date; matches each audit's directory name

# Collect today's findings across BOTH one-level (<int>/<date>/) and two-level
# (<int>/<label>/<date>/, used by multi-target and by signoz/kubernetes) layouts;
# skip any glob that matched nothing so jq never sees a literal path.
_ff=""; for f in "$AUDITS_DIR"/*/"$RUN_DATE"/findings.json "$AUDITS_DIR"/*/*/"$RUN_DATE"/findings.json; do [ -e "$f" ] && _ff="$_ff $f"; done
[ -n "$_ff" ] || { echo "(no audit findings for $RUN_DATE)"; exit 0; }
jq -rs '
  # Skip the roll-up dirs (cost-analysis/, all/): their findings.json has no
  # .target and carries severity-less findings, which would make the rank lookup
  # index the object with null and crash. Same guard as the viz rollup (target
  # null/all → skip).
  [.[] | select(.target != null and .target != "all") | .findings[]]
  | map(. + {rank: {"critical":0,"high":1,"medium":2,"low":3,"info":4}[.severity]})
  | sort_by(.rank) | .[:5][]
  | "\(.id) [\(.severity)] \(.title)"
' $_ff
```

Estate-size roll-up. Each audit's estate-sizing pre-check records its object counts and sizing path in its `findings.json`; surface them side by side so an oversized or truncated run is visible at a glance:

```bash
set -eu
AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"   # report-standard output root
RUN_DATE="$(date -u +%F)"        # UTC run date; matches each audit's directory name

for f in "$AUDITS_DIR"/*/"$RUN_DATE"/findings.json "$AUDITS_DIR"/*/*/"$RUN_DATE"/findings.json; do
  [ -e "$f" ] || continue
  # Skip the roll-up dirs (cost-analysis/, all/): not the per-audit schema.
  case "$(jq -r '.target // "?"' "$f" 2>/dev/null)" in (all|cost|cost-analysis|doctor|"?") continue ;; esac
  jq -r '"\(.target): " + (if .estate then "\(.estate.objects) objects, \(.estate.path) path" else "estate not recorded" end)' "$f"
done
```

Expected output: one line per completed audit, for example `grafana: 214 objects, medium path`. An audit that did not record estate data reads `estate not recorded`; carry that phrase into the report, never guess a size.

Score trend per target, from each target's `history.jsonl`. The ledger is the only trend source; the two most recent `findings.json` files stay reserved for finding-level matching inside each audit:

```bash
set -eu
AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"   # report-standard output root

for h in "$AUDITS_DIR"/*/history.jsonl "$AUDITS_DIR"/*/*/history.jsonl; do
  [ -e "$h" ] || continue
  # target key = path relative to the reports root, so two-level targets read
  # "clickstack/hdx-eu" (not a bare "hdx-eu" that collides across integrations).
  target=$(dirname "$h"); target="${target#"$AUDITS_DIR"/}"
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

for f in "$AUDITS_DIR"/*/"$RUN_DATE"/findings.json "$AUDITS_DIR"/*/*/"$RUN_DATE"/findings.json; do
  [ -e "$f" ] || continue
  # Skip the roll-up dirs (cost-analysis/, all/): not the per-audit schema.
  case "$(jq -r '.target // "?"' "$f" 2>/dev/null)" in (all|cost|cost-analysis|doctor|"?") continue ;; esac
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
for f in "$AUDITS_DIR"/*/"$RUN_DATE"/findings.json "$AUDITS_DIR"/*/*/"$RUN_DATE"/findings.json; do
  [ -e "$f" ] || continue
  # Skip the roll-up dirs (cost-analysis/, all/): not the per-audit schema.
  case "$(jq -r '.target // "?"' "$f" 2>/dev/null)" in (all|cost|cost-analysis|doctor|"?") continue ;; esac
  t=$(jq -r '.target' "$f")
  n=$(jq -r '[.findings[] | select(.lifecycle == "suppressed")] | length' "$f")
  echo "${t}: ${n} suppressed via exemptions"
  TOTAL=$((TOTAL + n))
done
echo "total suppressed across all targets: ${TOTAL}"
```

Expected output: one line per target plus a total, for example `lgtm: 2 suppressed via exemptions` then `total suppressed across all targets: 5`. A target with zero suppressed findings still gets its line, at `0`.

Topology readiness per target, read from each target's own `report.md` (the headline is not a `findings.json` field; [topology-readiness.md](../../report-standard/topology-readiness.md) defines it as the report's plain-language section headline `<r> of <n> critical services are ready for automatic Scoutflo correlation` — the report standard forbids the old "sync-ready" jargon, so match the plain-language phrase):

```bash
set -eu
AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"   # report-standard output root
RUN_DATE="$(date -u +%F)"        # UTC run date; matches each audit's directory name

for f in "$AUDITS_DIR"/*/"$RUN_DATE"/findings.json "$AUDITS_DIR"/*/*/"$RUN_DATE"/findings.json; do
  [ -e "$f" ] || continue
  # Skip the roll-up dirs (cost-analysis/, all/): not the per-audit schema.
  case "$(jq -r '.target // "?"' "$f" 2>/dev/null)" in (all|cost|cost-analysis|doctor|"?") continue ;; esac
  t=$(jq -r '.target' "$f")
  REPORT="$(dirname "$f")/report.md"
  if [ -f "$REPORT" ]; then
    LINE="$(grep -m1 -o '[0-9]\+ of [0-9]\+ critical services are ready for automatic Scoutflo correlation' "$REPORT" || true)"
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

Expected output: one line per completed target, for example `lgtm: 4 of 6 critical services are ready for automatic Scoutflo correlation`. A target whose report has no readiness section (map-topology never run, or the audit skill predates the section) reads `readiness not recorded`; never guess a count.

## Phase 3.5: Correlation engine (v0.1.66+)

After all audits complete and all `findings.json` files are written, run the correlation engine to detect overlaps and cascades, reframe cross-tool coverage, and annotate business context. This step generates `correlation.json` at the audits root. Correlation reads the per-audit `findings.json` files (gaps) **and** their `inventory.json` files (active monitors, for the cross-tool coverage join) and only writes `correlation.json`; every per-audit artifact stays canonical and untouched, and no finding's severity is ever mutated.

```bash
set -eu
# ${CLAUDE_PLUGIN_ROOT} is set by the plugin runtime. Running from a repo
# checkout instead: export CLAUDE_PLUGIN_ROOT as the repo root first.
AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
RUN_DATE="$(date -u +%F)"

CORR_LIB="${CLAUDE_PLUGIN_ROOT}/skills/correlation-engine/lib/correlation-engine.sh"
if [ -f "$CORR_LIB" ]; then
  . "$CORR_LIB"
  correlation_run "$RUN_DATE"
else
  echo "[audit-all] Correlation engine not installed (v0.1.66+); skipping"
fi
```

Expected output: `[correlation] Written <audits-dir>/correlation.json` followed by a one-line count summary (`Raw findings: N | Overlaps: N | Cascades: N`). Zero completed audits means zero findings and the log states "No findings to correlate" — that is a clean skip, not an error.

**Outputs:**
- `<audits-dir>/correlation.json` — overlap groups (the same affected service flagged by two or more targets) and cascade chains (a database-family finding linked to this run's alert-delivery findings). Every `finding_id` it references exists in this run's `findings.json` files; the engine never invents findings or dollar figures.

**Use cases:**
- Surfaces candidate redundant monitoring (two stacks watching the same service) for consolidation review
- Flags cascade risk: a failing database resource paired with untested alert delivery paths
- Feeds cost-analysis deduplication (Phase 3.6) and `topology-guided-setup` fix sequencing

**Graceful degradation:** If the correlation library is absent (user on v0.1.65 or earlier), the log notes this and continues — correlation is optional but recommended for multi-stack estates.

## Phase 3.6: Cost roll-up (v0.1.67+)

After correlation completes, run the cost-analysis roll-up to aggregate every audit's cost-optimization findings (`area: cost-optimization` — `AWSOPT-*`, `DDOPT-*`) into one cross-provider view, deduplicated via `correlation.json`. This is a lightweight roll-up of findings the individual audits already produced; it makes no provider calls.

> For a **deep, live, per-resource cost analysis** (queries Compute Optimizer / Cost Explorer / GCP Recommender / Datadog usage / K8s requests-vs-usage / DO billing, ranked by provider-native savings), run [`/scoutflo:audit-cost`](../audit-cost/SKILL.md) directly. `audit-all` intentionally runs only the fast roll-up so a combined run stays bounded; the deep cost audit is its own explicitly-invoked run.

```bash
set -eu
# ${CLAUDE_PLUGIN_ROOT} is set by the plugin runtime. Running from a repo
# checkout instead: export CLAUDE_PLUGIN_ROOT as the repo root first.
AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
RUN_DATE="$(date -u +%F)"

COST_LIB="${CLAUDE_PLUGIN_ROOT}/skills/cost-analysis/lib/cost-analysis.sh"
if [ -f "$COST_LIB" ]; then
  . "$COST_LIB"
  cost_analysis_run "$RUN_DATE"
else
  echo "[audit-all] Cost analysis not installed (v0.1.67+); skipping"
fi
```

Expected output: `[cost-analysis] Report complete: <audits-dir>/cost-analysis/<date>/findings.json` plus a one-line totals summary, or `[cost-analysis] No cost findings available` when no audit emitted a cost-optimization section — both clean outcomes. The roll-up always regenerates from the current run's findings (no 24h skip); it makes zero API calls, so there is nothing to cache.

**Outputs:**
- `<audits-dir>/cost-analysis/<date>/findings.json` — aggregated cost findings sorted with provider-native savings figures first (largest first), presence facts after
- `<audits-dir>/cost-analysis.jsonl` — one appended history line per analyzed run

**Honesty rules (same as the per-audit cost sections):** savings totals sum only `estimated_monthly_savings_usd` values the audits copied verbatim from provider-native savings recommendations (Compute Optimizer, Cost Explorer, GCP Recommender). A Datadog usage figure is a monthly **spend** (`estimated_monthly_cost_usd`), not a saving, so it is reported on its DDOPT finding but never added into the savings total; presence-fact findings are counted but never given an invented dollar figure; no 0-100 cost score is computed — cost findings are a non-scored parallel section per the report standard.

**Use cases:**
- One cross-provider list of cost opportunities with real, provider-sourced savings totals
- Deduplicates via correlation.json (overlap-flagged entries annotated, kept visible)
- Always regenerates from the current run's findings (no cache, no 24h skip); it makes zero API calls, so re-running it is effectively free

**Graceful degradation:** If the cost-analysis library is absent (v0.1.66 or earlier), the log notes this and continues — cost analysis is optional. If no audit emitted cost-optimization findings, it exits cleanly with a note.

## Phase 3.7: Redaction pass (v0.1.71+)

Before the combined report is finalized and any brief is assembled, run the redaction guardrail over the combined artifacts. Each audit's own report already avoids secrets by construction; this pass is defense-in-depth for the roll-up files this skill writes.

```bash
set -eu
# ${CLAUDE_PLUGIN_ROOT} is set by the plugin runtime. Running from a repo
# checkout instead: export CLAUDE_PLUGIN_ROOT as the repo root first.
AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
RUN_DATE="$(date -u +%F)"

RED_LIB="${CLAUDE_PLUGIN_ROOT}/skills/redaction/lib/redaction.sh"
if [ -f "$RED_LIB" ]; then
  . "$RED_LIB"
  for f in "${AUDITS_DIR}/all/${RUN_DATE}/report.md" "${AUDITS_DIR}/all/${RUN_DATE}/brief.txt"; do
    [ -f "$f" ] || continue
    redact_file "$f"
    echo "[redaction] pass complete: $f"
  done
else
  echo "[audit-all] Redaction library not installed; skipping (reports still follow the no-secrets writing rules)"
fi
```

Expected output: one `[redaction] pass complete:` line per existing roll-up file. Run this after Phase 4 writes `report.md` and again after the Phase 5 brief file is assembled, before the send. Redaction masks AWS access keys, Stripe keys, long Bearer tokens, and GitHub PATs in place; a clean file passes through byte-identical.

## Phase 4: Combined summary report

Write `./scoutflo-audits/all/<YYYY-MM-DD>/report.md`. It summarizes and links; it does not restate evidence. Sections, in order:

1. **Header**: date (UTC), toolkit version, audits run as `<n> of <m> configured`.
2. **At a glance (all stacks)**: paste the output of `sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" rollup "<audits-dir>" "<run-date>"` — a gate-count meter (stacks passing the 85 gate / total) and a worst-first per-stack score-bar table, so a leader sees estate health and which stack to send the team to first at a glance. Never a combined average (that hides a failing stack behind a healthy one); this only visualizes the per-target scores.
3. **Scores**: one row per completed target: score, severity counts, estate size and sizing path (from the Phase 3 roll-up; `estate not recorded` when the audit did not emit one), delta versus that target's previous run (`+9`, `-3`, or `first run`), the score trend from its `history.jsonl` (last five runs, oldest first; `no history yet` when the ledger is missing), and the relative path to its full `report.md`. One score line per target, never a combined average: an average hides a failing stack behind a healthy one.
4. **Blocked audits**: one row per blocked audit with reason and fix pointer. Omit the section only when nothing was blocked, and then state "No audits blocked."
5. **Regressions**: the Phase 3 regressions list, one row per regressed finding with its target, ID, severity, and title, ordered highest severity first. State "No regressions this run." when the list is empty. This section always precedes Top findings; regressions are the highest-signal state in the lifecycle model and are named before anything else.
6. **Topology Readiness (combined)**: one row per completed target, its "`<r> of <n> critical services are ready for automatic Scoutflo correlation`" headline from the Phase 3 topology-readiness roll-up, and a link to that target's own Scoutflo Topology Readiness section for the per-service detail. A target whose roll-up line read `readiness not recorded` gets that exact phrase in its row, not a blank or a guess.

   | Target | Readiness | Detail |
   | --- | --- | --- |
   | `<target>` | `<r> of <n> critical services are ready for automatic Scoutflo correlation` or `readiness not recorded` | link to that target's `report.md#scoutflo-topology-readiness` |

7. **Cross-stack correlation**: paste the output of `sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" overlaps "<audits-dir>/correlation.json"` — the redundant-monitoring overlaps (one service flagged by two or more stacks), any cascade chains, and the **Cross-tool coverage** subsection: a coverage gap in one provider (e.g. Azure "no metric alerts on checkout") that another provider actively covers (e.g. a routed Datadog monitor) is reframed as **single-tool dependency**, not zero coverage, while true gaps nothing covers are surfaced for elevation — all computed by the Phase 3.5 engine into `correlation.json`. This is the only cross-stack synthesis in the run; it renders the engine's output verbatim and never re-derives or re-scores correlation. It degrades to "No cross-stack overlaps, cascades, or cross-tool coverage reframing detected this run" when the engine found none, and to a run-`/scoutflo:audit-all` note when `correlation.json` is absent.
8. **Estate inventory (all stacks)**: paste the output of `sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" inventory-rollup "<audits-dir>" "<run-date>"` — the cross-stack current-state catalog (each stack's object totals by kind), read from every audit's `inventory.json`. This is the estate-level AI Readiness inventory deliverable: what you actually have configured, next to what's failing. It renders the per-stack `inventory.json` verbatim and never re-derives it; it degrades to "No `inventory.json` for `<run-date>`" when no audit emitted one.
9. **Top findings**: the Phase 3 list with each finding's target added.
10. **Suppressed**: the Phase 3 suppressed-findings roll-up, one line per target plus the `total suppressed across all targets` line. State "No findings suppressed via exemptions this run." when the total is `0`.
11. **Next safe actions**: the highest-severity findings across all targets, each row pointing at its finding ID and its remediation pointer (a `setup-*` skill anchor), verification-only steps before mutating ones. No timelines, no effort estimates. When a finding's own `remediation` field is empty, look its ID up in [finding-remediation-map.json](../../docs/finding-remediation-map.json) (`.mappings["<ID>"]` → `setup_skill` + `anchor`); the map is generated from the setup skills' own fix sections and CI-validated, so every pointer resolves. An ID absent from both the finding and the map gets "no setup pointer; see the finding's recommendation" — never an invented anchor.

Render the three deterministic sections first (read-only; all derive only from artifacts already on disk — the per-target `findings.json` and `inventory.json` files and the Phase 3.5 `correlation.json`), then compose the report around them:

```bash
set -eu
AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"   # report-standard output root
RUN_DATE="$(date -u +%F)"        # UTC run date
VIZ="${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh"
sh "$VIZ" rollup           "$AUDITS_DIR" "$RUN_DATE"     # -> paste as the "At a glance (all stacks)" section
sh "$VIZ" overlaps         "$AUDITS_DIR/correlation.json" # -> paste as the "Cross-stack correlation" section
sh "$VIZ" inventory-rollup "$AUDITS_DIR" "$RUN_DATE"     # -> paste as the "Estate inventory (all stacks)" section
```

Verify the write with an asserted command, not a glance:

```bash
set -eu
AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"   # report-standard output root
RUN_DATE="$(date -u +%F)"        # UTC run date
REPORT="${AUDITS_DIR}/all/${RUN_DATE}/report.md"

[ -f "${REPORT}" ] || { echo "combined report not written"; exit 1; }
n=0
for f in "$AUDITS_DIR"/*/"$RUN_DATE"/findings.json "$AUDITS_DIR"/*/*/"$RUN_DATE"/findings.json; do
  [ -e "$f" ] || continue
  # Skip the roll-up dirs (cost-analysis/, all/): they have no per-target score row.
  case "$(jq -r '.target // "?"' "$f" 2>/dev/null)" in (all|cost|cost-analysis|doctor|"?") continue ;; esac
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

REGRESSIONS="$(for f in "$AUDITS_DIR"/*/"$RUN_DATE"/findings.json "$AUDITS_DIR"/*/*/"$RUN_DATE"/findings.json; do
  [ -e "$f" ] || continue
  # Skip the roll-up dirs (cost-analysis/, all/): not the per-audit schema.
  case "$(jq -r '.target // "?"' "$f" 2>/dev/null)" in (all|cost|cost-analysis|doctor|"?") continue ;; esac
  jq -r '.target as $t | .findings[] | select(.lifecycle == "regressed") | "\($t): \(.id) \(.title)"' "$f"
done)"
[ -n "$REGRESSIONS" ] || REGRESSIONS="none"

SUPPRESSED_TOTAL=0
for f in "$AUDITS_DIR"/*/"$RUN_DATE"/findings.json "$AUDITS_DIR"/*/*/"$RUN_DATE"/findings.json; do
  [ -e "$f" ] || continue
  # Skip the roll-up dirs (cost-analysis/, all/): not the per-audit schema.
  case "$(jq -r '.target // "?"' "$f" 2>/dev/null)" in (all|cost|cost-analysis|doctor|"?") continue ;; esac
  n=$(jq -r '[.findings[] | select(.lifecycle == "suppressed")] | length' "$f")
  SUPPRESSED_TOTAL=$((SUPPRESSED_TOTAL + n))
done

CHECKS_PASSED=0
CHECKS_TOTAL=0
for f in "$AUDITS_DIR"/*/"$RUN_DATE"/findings.json "$AUDITS_DIR"/*/*/"$RUN_DATE"/findings.json; do
  [ -e "$f" ] || continue
  # Skip the roll-up dirs (cost-analysis/, all/): no .score.categories to sum —
  # iterating .score.categories[] on the null-score roll-up crashes under set -e.
  case "$(jq -r '.target // "?"' "$f" 2>/dev/null)" in (all|cost|cost-analysis|doctor|"?") continue ;; esac
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

## Phase 6: Run-completion message

Close the run with the standard completion message (per [report-template.md](../../report-standard/report-template.md#run-completion-message-what-the-skill-says-in-chat-when-the-run-finishes)), adapted to a combined run:

1. **One-line headline per target:** each target's score with movement and label state, e.g. `grafana 72/100 (+9), lgtm 64/100 (first run), aws 81/100 (-2)` — plus any blocked audits named with their one-line reason.
2. **The biggest levers across the estate:** the two or three highest-`points_recoverable` finding titles, and regressions first if any.
3. **Where the combined report is — the resolved ABSOLUTE path:** `<abs>/all/<YYYY-MM-DD>/report.md`, plus a note that each target's own `report.md` sits under `<abs>/<target>/<YYYY-MM-DD>/`.
4. **How to open it** (OS-specific `open`/`xdg-open`/`Invoke-Item`, as in the report standard), noting it is plain Markdown.
5. **How to share it:** the full reports name hosts/namespaces/routes — share inside the team; the Slack brief (already sent if `slack.webhook_env` is set, else offer it) is the leak-safe summary.
6. **Next step:** re-run after fixes for the delta, or open the target report with the most recoverable points first.

Same hard rules as the per-audit close: absolute paths only, no evidence values or secrets in the chat message, and no completion message for a run that never wrote a combined report.

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
