# Estate-sizing scope checkpoint (shared across every audit)

Every audit sizes the estate with cheap list calls before spending tokens on
per-object judgment. On a large estate that count can be thousands of objects —
so past the size thresholds the audit **pauses and lets you scope** instead of
grinding the whole estate unbounded. This is the shared mechanism; each audit's
own **Estate sizing** phase computes its `TOTAL` its own way (dashboards, alarms,
services, namespaces, …) and then calls into this one checkpoint. It is
**mandatory** on the large/xlarge paths: an unbounded grind over a huge estate
with no scoping question is a bug, not a feature.

## The shared thresholds (tune-this examples, consistent across audits)

| Path | Object count | Behavior |
| --- | --- | --- |
| small | ≤ 100 | one pass, no checkpoint |
| medium | 101–500 | one pass; print the scope, proceed |
| large | 501–2000 | **PAUSE** — confirm, offer scope/exclusions, save to `topology.json`, then batch |
| xlarge | > 2000 | **PAUSE** — scope selection required before proceeding, then batch |

Thresholds are examples; an audit may tune them to its object kind, but the
pause-on-large behavior is the same everywhere.

## The checkpoint block every audit runs after computing `TOTAL`

Each audit computes `TOTAL` in its Estate sizing phase (its own cheap count),
then runs this exact block. It reuses any scope saved by a prior run or by
`/scoutflo:checkpoint`, and on a large/xlarge estate pauses to let the user
confirm or narrow scope before the expensive phases:

```bash
set -eu
# TOTAL is computed by this skill's Estate sizing step (its own object count).
: "${TOTAL:?estate sizing must set TOTAL before the scope checkpoint}"
. "${CLAUDE_PLUGIN_ROOT}/skills/cli-interactive/lib/cli-interactive.sh"
. "${CLAUDE_PLUGIN_ROOT}/skills/checkpoint/lib/checkpoint.sh"

# Reuse a scope saved by a prior run or /scoutflo:checkpoint (returns "all" if none).
SCOPE="$(checkpoint_load_scope)"
[ "$SCOPE" = "all" ] || echo "[checkpoint] reusing saved audit scope: ${SCOPE}"

# Large/xlarge: pause, confirm, and offer to scope/exclude before the costly phases.
# cli_pause_before_audit confirms at >=1000; the 501 gate below adds the toolkit's
# large-path pause so a 501-2000 estate is also scoped, not silently ground.
if [ "${TOTAL}" -ge 501 ]; then
  echo "estate: ${TOTAL} objects (large path) — pausing to let you scope before spending tokens"
  cli_pause_before_audit "${TOTAL}"       # confirm before a large run (cancels cleanly on 'no')
  cli_prompt_exclude_services             # offer service/region exclusions
  echo "[checkpoint] narrow scope any time with /scoutflo:checkpoint; reset with /scoutflo:checkpoint --reset-scope"
fi
```

On the large/xlarge path, run the per-object phases against the **scoped** set in
the audit's own bounded, resumable batches (the skill's Large-path worklist).
Never silently truncate: the report names anything the user scoped out and the
coverage denominators reflect it.

## Why this is shared, not copied per skill

Before this reference, the pause/scope helpers (`cli-interactive`) and the
scope-persistence skill (`checkpoint`) existed but **no audit called them** — so
large audits ground through thousands of objects with no scoping question. This
one reference is the single mechanism; `ci/scope-checkpoint-check.sh` enforces
that every `audit-*` (except `audit-all`, which orchestrates) actually wires it,
so the feature cannot silently rot again.
