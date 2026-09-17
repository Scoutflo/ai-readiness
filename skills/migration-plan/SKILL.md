---
name: migration-plan
description: Read-only, evidence-cited migration PLAN between two configured observability providers — currently Datadog → SigNoz. Inventories every source object (monitors, SLOs, synthetics, dashboards, downtimes, log pipelines), joins the audits' findings + measured fire-history so dead weight is proposed for dropping instead of being lifted-and-shifted, maps each object to its target equivalent with an honest equivalence class (direct/approximate/manual/none), and produces a migration inventory + gap table + parallel-run/cutover plan. Use when the user wants to migrate, compare, or plan a move from Datadog to SigNoz (or asks for a migration inventory). Do not use to EXECUTE a migration — this skill changes nothing on either side; it plans, and the setup lane (or your team) executes.
---

# migration-plan

A migration is the one moment an estate gets to shed years of accumulated alerting debt — and the moment a naive lift-and-shift copies every dead monitor, broken handle, and flapping threshold into the new tool. This skill produces the **plan**: a complete, evidence-cited inventory of what to migrate, what to fix first, what to drop (with proof), what the target already covers, and what has no equivalent — plus the parallel-run/cutover playbook. It is **plan-only and strictly read-only on both sides**: it creates, modifies, and deletes nothing. Executing the plan is a human/service engagement (or a future setup-lane skill), never this one.

**Supported pairs** (a pair without a catalog fails honestly — this skill never improvises a mapping):

| Source → Target | Pair catalog |
| --- | --- |
| `datadog` → `signoz` | [references/datadog-to-signoz.md](references/datadog-to-signoz.md) |

## Prerequisites

| Requirement | Check |
| --- | --- |
| Source + target blocks in `~/.scoutflo/toolkit.yaml` | `datadog` block (API+app key envs); `signoz` block optional — absent/unreachable target ⇒ **source-only mode**, stated on the plan |
| A source audit run for the plan date (artifact-first) | `${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/datadog/<date>/inventory.json` exists — run `/scoutflo:audit-datadog` first if not; this skill never re-derives what the audit already read |
| For the drop-the-noise bias (optional, recommended) | today's `fatigue-signals.json` from the alert-fatigue fire-history lane — measured never-fired / dead-end evidence |
| `jq` | `command -v jq` |

## Doctor gate

Source the home-anchored secret store exactly as `/scoutflo:doctor` does, then confirm reachability read-only. The **target being unreachable is not a failure** — it selects source-only mode.

```bash
set -eu
CFG=""
for c in "${SCOUTFLO_CONFIG:-}" ./.scoutflo/toolkit.yaml "$HOME/.scoutflo/toolkit.yaml"; do
  [ -n "$c" ] && [ -f "$c" ] && CFG="$c" && break
done
[ -n "$CFG" ] || { echo "no toolkit.yaml — run /scoutflo:connect first"; exit 1; }
# shellcheck disable=SC1090
[ -f "$HOME/.scoutflo/env" ] && . "$HOME/.scoutflo/env"
: "${DATADOG_API_KEY:?source key missing — run /scoutflo:connect (never send an empty auth header)}"
: "${DATADOG_APP_KEY:?source app key missing — run /scoutflo:connect}"
# Identity + target, verified before any real pull: the key must validate against
# the CONFIGURED site (the same canonical probe /scoutflo:doctor uses). Stop on
# mismatch — never proceed on "probably the right org".
DD_SITE_CFG="$(awk '/^datadog:/{f=1} f && /site:/{print $2; exit}' "$CFG")"
DD_SITE="${DD_SITE_CFG:-datadoghq.com}"
VALID="$(curl -fsS --max-time 15 "https://api.${DD_SITE}/api/v1/validate" -H "DD-API-KEY: ${DATADOG_API_KEY}" | jq -r '.valid // false')"
[ "$VALID" = "true" ] || { echo "identity gate: key does NOT validate against site ${DD_SITE} — wrong site or key; stopping"; exit 1; }
echo "doctor gate: config at $CFG; source = datadog @ ${DD_SITE} (key validated); target = signoz (optional — absent selects source-only mode)"
```

Run `/scoutflo:doctor` for the full per-provider probes if anything is unclear. The plan needs the **source audit artifacts** more than it needs live source access — a fresh audit run is the real doctor here, and Phase 1's artifacts must come from the same configured target this gate just verified.

## Live-safety gate

- **Plan-only.** Every provider call this skill makes is a GET (or a documented read-by-POST search); it never creates, edits, mutes, or deletes an object on either side, and never sends a test notification. The plan artifact and its reports are the only writes, all local.
- **Never-fabricate.** A drop or fix disposition ships only with evidence (a finding-id from this run or a measured fire-history signal) — enforced by [check-migration-plan.sh](../../report-standard/check-migration-plan.sh). An equivalence is one of `direct / approximate / manual / none` per the pair catalog; an untranslatable part is named `manual`, never silently auto-translated. In source-only mode, `already-covered` claims are forbidden (you cannot claim target coverage without reading the target).
- **History honesty.** Historical metrics/logs/traces **do not transfer** between backends. The plan says so structurally (`cutover.historical_telemetry: "does-not-transfer"` — the validator fails anything else) and covers continuity via the dual-write/parallel-run playbook instead.

## Estate sizing and the scope checkpoint

Monitor counts scale into the hundreds; dashboards multiply widgets. Size the estate from the source inventory (already on disk — free), and past the shared thresholds pause per [estate-scope-checkpoint.md](../../report-standard/estate-scope-checkpoint.md):

```bash
set -eu
AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
RUN_DATE="${RUN_DATE:-$(date -u +%F)}"
TOTAL="$(jq -r '(.items | length) // 0' "$AUDITS_DIR/datadog/$RUN_DATE/inventory.json" 2>/dev/null || echo 0)"
. "${CLAUDE_PLUGIN_ROOT}/skills/cli-interactive/lib/cli-interactive.sh" 2>/dev/null || true
if [ "$TOTAL" -gt 500 ] && command -v cli_pause_before_audit >/dev/null 2>&1; then   # 500 = example threshold, tune to your estate (shared thresholds: estate-scope-checkpoint.md)
  cli_pause_before_audit "migration-plan" "$TOTAL" "scope the plan (e.g. production monitors first) or proceed with all $TOTAL objects"
fi
echo "estate: $TOTAL source objects"
```

On a large estate, run the scoped sweep **inline — never background a pull** (the checkpoint doc's rule); the detail pulls below are bounded per-disposition, not per-estate.

## Phase 1 — Disposition skeleton (deterministic, zero provider calls)

The library joins the source inventory + findings + optional measured fire-history + the target inventory into one evidence-cited disposition per object:

```bash
set -eu
AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
RUN_DATE="${RUN_DATE:-$(date -u +%F)}"
. "${CLAUDE_PLUGIN_ROOT}/skills/migration-plan/lib/migration-plan.sh"
migration_plan_run datadog signoz "$RUN_DATE"
```

Expected: `[migration-plan] Written <audits-dir>/migration-plans/datadog-to-signoz/<date>/migration-plan.json` plus `mode:full|source-only objects:N drop-candidates:N fix-then-migrate:N`. Dispositions and their precedence (`no-equivalent` by kind → `already-covered` → `drop-candidate` → `fix-then-migrate` → `migrate`) are computed here, never by prose. Missing source artifacts fail with guidance (run the audit first); an unsupported pair refuses to improvise.

## Phase 2 — Detail pulls (read-only, per the pair catalog)

The audit inventory carries monitors/SLOs/downtimes but not full definitions, dashboards, synthetics configs, or log pipelines. Pull ONLY what the plan needs, per the **read blocks in the pair catalog** ([references/datadog-to-signoz.md](references/datadog-to-signoz.md)): full monitor definitions for `migrate`/`fix-then-migrate` objects, the dashboard list + per-dashboard widgets, synthetics test configs, SLO definitions, and log pipelines/indexes. Append the objects the inventory did not carry (kinds `dashboard`, `synthetic_test`, `log_pipeline`) into `.inventory[]` with the same field shape, then **recompute totals** so the validator reconciles:

```bash
set -eu
RUN_DATE="${RUN_DATE:-$(date -u +%F)}"
PLAN="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/migration-plans/datadog-to-signoz/${RUN_DATE}/migration-plan.json"
jq '.totals = {
      objects: (.inventory | length),
      migrate: ([ .inventory[] | select(.disposition == "migrate") ] | length),
      fix_then_migrate: ([ .inventory[] | select(.disposition == "fix-then-migrate") ] | length),
      drop_candidates: ([ .inventory[] | select(.disposition == "drop-candidate") ] | length),
      already_covered: ([ .inventory[] | select(.disposition == "already-covered") ] | length),
      no_equivalent: ([ .inventory[] | select(.disposition == "no-equivalent") ] | length)
    }' "$PLAN" > "$PLAN.tmp" && mv "$PLAN.tmp" "$PLAN"
```

Every appended object follows the same rules: a drop/fix needs evidence; a kind with no equivalent gets the catalog's alternative.

**Resume rule (large estates).** The plan file itself is the worklist: enrichment is idempotent over `migration-plan.json`, so on re-entry (a new session, an interrupted run) enrich **only** the objects still missing `equivalence`/`target_shape` and pull **only** their details — never re-pull or re-enrich objects already carrying them. `jq '[.inventory[] | select(.disposition == "migrate" and (has("equivalence") | not)) | .name]' "$PLAN"` lists exactly what remains.

## Phase 3 — Equivalence enrichment (the pair catalog is the only source of truth)

For each `migrate` object, set from the catalog: `equivalence` (`direct/approximate/manual/none`), a `target_shape` sketch (e.g. the SigNoz rule type, windowed match-type, channel mapping), and `notes` naming anything manual. This is also where the **best-practice bias** lands: a migrated alert adopts the target-side hygiene the methodology doctrine prescribes (windowed evaluation instead of a flappy default, no broadcast handles, severity labels that route) — each improvement noted on the object, never silently applied. Fill every `gaps[].alternative` with the catalog's real alternative (a `pending-catalog` placeholder fails validation), and write `cutover.parallel_run` from the catalog's cutover playbook.

## Phase 4 — Validate, then render

The validator is a hard gate before anything is shown or shared:

```bash
set -eu
AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
RUN_DATE="${RUN_DATE:-$(date -u +%F)}"
PLAN="$AUDITS_DIR/migration-plans/datadog-to-signoz/${RUN_DATE}/migration-plan.json"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-migration-plan.sh" "$PLAN" "$AUDITS_DIR" "$RUN_DATE"
VIZ="${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh"
sh "$VIZ" migration-plan      "$PLAN" > "$(dirname "$PLAN")/migration-plan.md"
sh "$VIZ" migration-plan-html "$PLAN" "$(dirname "$PLAN")/migration-plan.html"
echo "[migration-plan] plan: $(dirname "$PLAN")/migration-plan.md (+ .html dashboard)"
```

Show the operator the rendered plan (worst-first: fix-then-migrate and drop-candidates lead, each row with its evidence), and walk the gaps and the cutover section explicitly — those are the honest conversations a migration needs *before* it starts.

## The cutover playbook (what "no data loss" honestly means)

- **Config: nothing silently lost.** Every source object appears in the plan with a disposition; drops are explicit, evidenced proposals that you confirm.
- **History: does not transfer.** Dashboards/alerts recreate; old telemetry stays in the source until its retention ends. The plan never claims otherwise.
- **Continuity: dual-write, then parity, then sunset.** Ingest to both backends during the parallel-run window (the pair catalog names the mechanism), keep the target's new alerts in a shakedown state so one incident doesn't page through both tools, then **sunset the source only when the audit-parity gate passes**: re-run the source and target audits + the correlation engine, and require target coverage parity with no true-gap regressions. Our own audits are the objective "safe to sunset" criterion.

## Outputs

- `<audits-dir>/migration-plans/<source>-to-<target>/<date>/migration-plan.json` (`scoutflo-migration-plan/v1`) — the machine plan: per-object dispositions with evidence, equivalence classes, gaps with alternatives, cutover.
- `migration-plan.md` + `migration-plan.html` next to it — the human plan (the deliverable you share and act on), rendered by [render-report-viz.sh](../../report-standard/render-report-viz.sh) (`migration-plan` / `migration-plan-html` modes).

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Lift-and-shift of dead weight (migrating monitors that never fired, route nowhere, or duplicate) | The disposition join proposes `drop-candidate`/`fix-then-migrate` from audit findings + measured fire-history — with evidence, pending human confirmation; nothing is dropped silently |
| A fabricated equivalence ("this dashboard converts automatically") | Equivalence is a closed enum from the pair catalog; the untranslatable part is named `manual`; the validator rejects out-of-enum classes; an unsupported pair refuses to run |
| Claiming the target already covers something in source-only mode | `already-covered` requires full mode + a named `matched_target` — the validator fails it otherwise |
| An evidence-free drop, or evidence citing a finding that does not exist in this run | The validator requires evidence on every drop/fix and cross-checks each cited finding-id against this run's source findings (fail-closed) |
| "No data loss" read as "history transfers" | `cutover.historical_telemetry` must equal `does-not-transfer` (validator-enforced); continuity is the dual-write/parallel-run plan, and sunset waits for the audit-parity gate |
| Double-paging during the parallel run | `already-covered` rows and the cutover section call it out; the plan tells the operator which side holds paging duty during shakedown |
| Executing the migration from this skill | Out of scope by design — plan-only; the plan is the input to a confirm-then-verify setup engagement, never a mutation from here |
| Re-pulling what the audit already read | Artifact-first: the skeleton builds from `inventory.json`/`findings.json`/`fatigue-signals.json` on disk; detail pulls are bounded to what the plan needs |
