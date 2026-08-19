# Inventory schema (`scoutflo-inventory/v1`)

The **inventory** is the complete current-state catalog of what a target has
configured — "here is everything you have," distinct from `findings.json`, which
is "here are the gaps." It is the AI Readiness POC's **alert / asset inventory**
deliverable (customers ask for it alongside topology, cost, and findings).

Every audit writes one `inventory.json` next to its `findings.json`, built from
the raw pull it already captures in Phase 2 — no new live calls. `report.md`'s
`## Inventory` section and `/scoutflo:audit-all`'s estate rollup are **derived**
from it via `render-report-viz.sh inventory` / `inventory-rollup`; never
hand-write the section, regenerate it (same rule as `findings.json`).

## File

`./scoutflo-audits/<target>/<YYYY-MM-DD>/inventory.json`

## Shape

```json
{
  "schema": "scoutflo-inventory/v1",
  "target": "grafana",
  "generated_at": "2026-08-18T12:00:00Z",
  "counts": { "total": 12, "by_kind": { "alert_rule": 7, "contact_point": 3, "dashboard": 2 } },
  "items": [
    {
      "name": "checkout-p95-latency",
      "kind": "alert_rule",
      "covers": "checkout-edge-api",
      "enabled": true,
      "severity": "high",
      "routes_to": "pagerduty-payments",
      "attrs": { "folder": "payments", "datasource": "prometheus" }
    }
  ]
}
```

## Field rules

- **`schema`** — literal `scoutflo-inventory/v1`.
- **`target`** — the audit target slug (`grafana`, `azure`, `aws`, …); matches `findings.json`'s `target`.
- **`generated_at`** — ISO-8601 UTC.
- **`counts.total`** — MUST equal `items | length`. **`counts.by_kind`** — a histogram over `items[].kind`; every kind present in `items` appears, and the values sum to `total`. `check-report.sh` reconciles this; a mismatch is a bug.
- **`items[]`** — one row per configured object the audit read:
  - **`name`** (required) — the object's name/id as the provider shows it.
  - **`kind`** (required) — a lower-snake type from the target's vocabulary: observability audits use `alert_rule`, `log_alert`, `activity_log_alert`, `action_group`, `contact_point`, `notification_policy`, `monitor`, `dashboard`, `datasource`, `receiver`, `silence`, `escalation_policy`, `schedule`, `team`; cloud audits use `vm`, `vmss`, `cluster`, `database`, `load_balancer`, `app_gateway`, `workspace`, `bucket`, `function`. Add a kind rather than overloading one.
  - **`covers`** — the resource/service/scope it applies to (or `"-"` if not applicable). Use the canonical `topology.md` service name when known, so the inventory joins to topology and to `findings[].affected`.
  - **`enabled`** — boolean; `true` when the object is active. A disabled object still appears in the inventory (that it exists but is off is exactly the kind of fact the inventory surfaces).
  - **`severity`** — the object's own configured severity when it has one (`critical|high|medium|low|info`), else `null`. This is the object's setting, NOT a finding severity.
  - **`routes_to`** — for alerting objects, the receiver/target it notifies (`"none"` when nothing is wired — a real inventory fact), else omit.
  - **`attrs`** — a small map of provider-specific facts worth showing in the table's detail (folder, datasource, region, SKU, retention days). **Redaction applies** (`secret-redaction.md`): capture by key/name only; never a secret value, webhook URL, phone number, or email address.

## Relationship to `findings.json`

Independent artifacts from the same raw pull. The inventory is the full list;
findings are the subset that scored a gap. An item may have zero findings (it is
healthy) or several. Never derive the inventory from findings (it would drop
every healthy object) and never fold inventory rows into the score.

## Never

- Never invent an item, a `covers`, or a `routes_to` — every row traces to a raw
  object the audit read. An empty estate is `items: []` with `total: 0`, reported
  honestly (and it pairs with the empty/hidden-scope guardrail, which distinguishes
  "genuinely empty" from "can't see it").
- Never emit a secret value in `attrs` or anywhere in `inventory.json`.
