---
name: checkpoint
description: Interactive inventory selection + batching for large estates. Before running audit-all, users select which services and regions to audit, saving the scope to topology.json for reuse. On large estates (1000+ resources), automatically batches queries to control token costs. Use when auditing multi-service environments with cost constraints.
---

# Checkpoint: Interactive Inventory Selection

Save service and region scope before running audits. For large estates, batch audit queries automatically to prevent token explosion.

## Prerequisites

| Requirement | Check |
| --- | --- |
| `jq` | Installed |
| `~/.scoutflo/topology.json` | Created on first checkpoint run |

## Phase 1: Interactive Scope Selection

List the services your estate actually has: the calling audit's inventory, or the topology export from `/scoutflo:map-topology`. Never offer a placeholder list. If neither exists, say so and offer to run `/scoutflo:map-topology` first. Ask which to audit:

```
=== Select Services to Audit ===
Available services: <discovered service names>
Enter services (comma-separated, or 'all' for all): 
```

Expected input: a comma-separated list of discovered names, or `all` to audit everything.

Save with `checkpoint_save_scope "<comma-separated names>"`. Whitespace around each name is trimmed and names are stored verbatim, so quotes and backslashes are safe. `all` or an empty answer clears the saved scope rather than freezing today's list, so the next audit also covers services added since.

The selection is saved to `~/.scoutflo/topology.json`:

```json
{
  "audit_scope": {
    "services": ["payment-svc", "checkout-svc"],
    "selected_at": "2026-07-30T17:15:30Z",
    "revision": 1
  }
}
```

## Phase 2: Batch Strategy

For large estates, calculate batch size and count:

- `< 100 resources` → one pass (batch_size = 1)
- `100–499 resources` → batch by 100
- `500–1999 resources` → batch by 200
- `2000+ resources` → batch by 500

Example: 1500 resources → `1500 / 200 = 8 batches of 200`

Output to the user: `[BATCH] Auditing 1500 resources in 8 batches of 200`

## Phase 3: Reload on Next Audit

Load the saved scope automatically on the next `/scoutflo:audit-all` run. If no scope set, default to `all` (audit everything).

Display when loading: `[CHECKPOINT] Auditing scope: payment-svc,checkout-svc`

## Standalone Usage

```bash
/scoutflo:checkpoint
```

Prompts for service selection, saves to topology.json.

## Reset

```bash
/scoutflo:checkpoint --reset-scope
```

Clears the saved scope; next audit will default to `all`.

## Integration

- **Called by each `audit-*` skill's estate-sizing phase** (via the shared [estate-scope-checkpoint](../../report-standard/estate-scope-checkpoint.md) block), not by `audit-all` directly — the pause/scope decision happens per audit as it sizes its estate. You can also run `/scoutflo:checkpoint` directly to set or reset the scope.
- **Output** `~/.scoutflo/topology.json` (persisted across sessions; the saved scope is reused on the next run)
- **Batching** Applied within each audit's large-estate path when the object count crosses its threshold

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Scope selected and saved successfully |
| 1 | User cancelled at prompt |

---

**v0.1.65+**
