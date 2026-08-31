# audit-cost: DigitalOcean Cost & Resource Optimization Check Catalog

Runnable, read-only checks for the DigitalOcean provider phase of [audit-cost](../SKILL.md). This whole catalog is a **parallel non-scored section** per [report-standard/severity-and-scoring.md](../../../report-standard/severity-and-scoring.md#parallel-non-scored-sections): every finding carries `area: cost-optimization`, `points_recoverable: 0`, and never enters `score.categories` or `score.excluded`. IDs are `COST-DO-NNN`, a permanent registered prefix distinct from the reliability catalog's `DO-NNN` in [audit-digitalocean/references/do-checks.md](../../audit-digitalocean/references/do-checks.md), so a reader can tell at a glance which axis a finding belongs to.

**Maturity (v1 honesty).** Authored to the same depth as the live-proven AWS/GCP catalogs, but **not yet live-proven end to end** against a real DigitalOcean account. Treat the command output shapes as expected-form, not field-verified, until the first proving run annotates them.

## 1. The one hard rule (and why DigitalOcean is the strict case)

`estimated_monthly_savings_usd` appears on a finding **only** when the number is copied verbatim from a provider-native recommendation API response. **DigitalOcean publishes no rightsizing, idle-resource, or savings-recommendation API of any kind** — there is no Compute Optimizer, no Cost Explorer coverage figure, no Recommender `costProjection`. Therefore, in this entire catalog, **`estimated_monthly_savings_usd` never appears on any finding.** Every check here is a presence / absence / ratio fact, reported with no savings dollar figure. Recomputing a saving from raw metrics against a price table is forbidden; an unverified number is worse than no number, because it lands in a budget conversation.

There is exactly one dollar figure DigitalOcean *does* publish per resource, and it is **not** a saving: the **list price of a size slug** (`price_monthly` from `doctl compute size list`, or the tier `monthly_price_in_cents` from the registry subscription). You **may** cite that as a clearly-labeled `list_price_monthly_usd` context field — it is a provider-published price looked up verbatim, not a recomputed estimate — but it is the *spend that stops if the resource is eliminated*, never a provider-computed saving. It is **never** written to `estimated_monthly_savings_usd`, and it is **never** summed into the report's savings-total line (§11). Keep the two ideas physically separate on the finding.

- ❌ `COST-DO-001: droplet web-03 (s-4vcpu-8gb) sits at 3% CPU over 14 days; at its $48/mo list price that is ~$48/mo wasted — estimated_monthly_savings_usd: 48.`
- ✅ `COST-DO-001: droplet web-03 (id 349920134, s-4vcpu-8gb, nyc3) averaged 3% CPU over 14 days (DO Monitoring, 5-min step). DigitalOcean publishes no idle/rightsizing savings figure, so the finding carries no estimated_monthly_savings_usd. Its DO list price is list_price_monthly_usd: 48.00 (from doctl compute size list, matched on size_slug) — the ceiling of what decommissioning would stop billing, shown as context, not summed into any savings total.`

## 2. Check catalog

One permanent ID per check; IDs never change or get reused. "Savings figure" is `native $` only when a provider recommendation API returns one — which, for DigitalOcean, is **never**. Every row is a presence fact; the "list-price citable" note marks the checks where a DO-published `list_price_monthly_usd` may accompany the fact as labeled context.

| ID | Signal | Source (read-only) | Savings figure |
| --- | --- | --- | --- |
| COST-DO-001 | Idle / low-CPU droplets (avg CPU below threshold over N days) | `doctl compute droplet list` + DO Monitoring metrics API (`GET /v2/monitoring/metrics/droplet/cpu`) | None (presence fact); slug list-price citable |
| COST-DO-002 | Powered-off / archived droplets still billing (`status` = `off`/`archive`) | `doctl compute droplet list` | None (presence fact); slug list-price citable |
| COST-DO-003 | Unattached block-storage volumes (no `droplet_ids`) | `doctl compute volume list` | None (presence fact) |
| COST-DO-004 | Aged Droplet & volume snapshots vs the team's stated retention | `doctl compute snapshot list` | None (presence fact) |
| COST-DO-005 | Over-provisioned managed DB cluster vs observed usage | `doctl databases list`/`get` + observed-usage source | None (presence fact); DB slug list-price citable |
| COST-DO-006 | Unassigned reserved IPs (billed while detached) | `doctl compute reserved-ip list` | None (presence fact) |
| COST-DO-007 | Idle load balancers (zero backend Droplets, no tag) / oversized node count | `doctl compute load-balancer list`/`get` | None (presence fact) |
| COST-DO-008 | Container-registry storage over included tier / garbage collection never run | `curl GET /v2/registry` + `/v2/registry/subscription` + `doctl registry garbage-collection list` | None (presence fact); tier list-price citable |
| COST-DO-009 | Droplet backup add-on enabled on idle/decommissioned Droplets | `doctl compute droplet list` (`features` includes `backups`) | None (presence fact) |

## 3. Doctor-gate dependency

Every check here depends on the audit-cost doctor gate's DigitalOcean cost-permission probe. The probe makes one cheap read (`doctl account get`, then `doctl balance get` for the billing scope) and **never fails the main run**: a missing or denied scope EXCLUDES only the dependent check(s) with the doctor's own reason, never guesses, and never aborts the DigitalOcean phase. Read the result the same way audit-aws reads its matrix:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
MATRIX="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/doctor/${RUN_DATE}/matrix.tsv"   # written by the doctor gate this run, or the most recent doctor run
[ -f "$MATRIX" ] || { echo "no doctor matrix found; run the doctor gate before the DigitalOcean cost phase"; exit 1; }
awk -F'\t' '$1 == "digitalocean" && $2 == "cost-permissions" {print $5, $7}' "$MATRIX"
```

Expected: `pass -` when the DigitalOcean cost checks can run, or `skipped <reason>` when the token is absent. DigitalOcean personal-access tokens can be scoped (custom read scopes) or full-access; the check-to-scope map below means a partially-scoped token blocks only part of the catalog, not all of it. State the split explicitly rather than excluding the whole provider when only one scope is missing:

| Check | Scope needed beyond a basic read token | If the scope is missing |
| --- | --- | --- |
| COST-DO-002, 003, 004, 006, 007, 009 | the resource `*:read` scopes the audit-digitalocean reliability probe already covers (droplet, block_storage, block_storage_snapshot, reserved_ip, load_balancer) | run as normal |
| COST-DO-001 (CPU), COST-DO-005 (usage) | `monitoring:read` **and** the target having the DO metrics agent installed | report the check `excluded, reason: "monitoring:read scope or metrics agent absent"`; still list the resource's provisioned shape as a fact |
| COST-DO-008 | `registry:read` | report `excluded, reason: "registry:read scope missing"` |

A `401`/`403` on any single list is `blocked` evidence for that check with the exact scope named — never silently reinterpreted as "nothing found".

## 4. Conventions (shared by every block below)

- `doctl` authenticates from the `DIGITALOCEAN_ACCESS_TOKEN` environment variable (named by `digitalocean.token_env` in `~/.scoutflo/toolkit.yaml`). Presence-check it only; never echo, log, or write the value.
- `doctl ... -o json` emits a JSON array for list commands; a get returns an object on some versions and a single-element array on others, so gets use the defensive `(if type=="array" then .[0] else . end)` filter.
- Every command here is read-only: `doctl` `list`/`get` subcommands and `curl` GET. The forbidden mutating verbs are §12.
- `curl -fsS --max-time 15` is the default; the DigitalOcean REST base is `https://api.digitalocean.com`. No cost endpoint returns a Slack webhook, so no redaction filter is needed here (unlike the alert-policy reads in the reliability catalog).
- Thresholds and windows below are **example config placeholders** — tune to the estate. Named defaults are collected in §11.

## 5. Idle and powered-off Droplets (COST-DO-001, COST-DO-002, COST-DO-009)

Inventory every Droplet once, keeping the fields the three Droplet checks need. `status`, `size_slug`, `features`, and `created_at` come straight from the list:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/cost/digitalocean/${RUN_DATE}/raw"
mkdir -p "$RAW_DIR"
doctl compute droplet list -o json | jq '[.[] | {
  id, name, status,                       # status: active | off | new | archive
  size_slug, vcpus, memory_mb: .memory, disk_gb: .disk,
  region: .region.slug,
  created_at,
  features: (.features // []),            # includes "backups", "monitoring", "ipv6", ...
  volume_ids: (.volume_ids // []),
  list_price_monthly_usd: (.size.price_monthly // null)   # DO-published list price embedded in the resource
}]' > "${RAW_DIR}/droplets.json"
```

**COST-DO-002 (powered-off / archived Droplets still billing).** Unlike a stopped AWS EC2 instance (which bills only its EBS), a DigitalOcean Droplet in `off` or `archive` status **still incurs its full monthly charge** — the slot stays reserved. So a powered-off Droplet is pure spend with zero utility, and it needs no metrics call to prove:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/cost/digitalocean/${RUN_DATE}/raw"
jq -r '.[] | select(.status == "off" or .status == "archive")
  | "\(.id)\t\(.name)\t\(.size_slug)\t\(.region)\tstatus=\(.status)\tlist_price_monthly_usd=\(.list_price_monthly_usd // "unknown")"' \
  "${RAW_DIR}/droplets.json"
```

Expected: no output on a clean estate. Each line is one presence-fact finding, named per Droplet ID. `list_price_monthly_usd` is shown as labeled context (the spend that stops if it is destroyed), never as `estimated_monthly_savings_usd`.

**COST-DO-001 (idle / low-CPU Droplets).** CPU utilization is **not** in `doctl` — `doctl monitoring` exposes only `alert` and `uptime`, so utilization comes from the DO Monitoring metrics REST API, which requires the Droplet to have the metrics agent (the `monitoring` feature) installed. A Droplet without the agent cannot be assessed for idle CPU: EXCLUDE it from this check with that reason, never assume it is busy or idle.

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/cost/digitalocean/${RUN_DATE}/raw"
IDLE_DAYS="14"          # example, tune to your workload cadence
CPU_IDLE_PCT="5"        # example, avg utilization at/below this over the window = idle candidate
END="$(date -u +%s)"
START="$(( END - IDLE_DAYS*86400 ))"

# Only Droplets carrying the metrics agent can be queried; the rest are excluded with a reason.
jq -r '.[] | select(.features | index("monitoring")) | "\(.id)\t\(.name)"' "${RAW_DIR}/droplets.json" \
| while IFS=$'\t' read -r droplet_id name; do
  # CPU is a per-mode cumulative counter (seconds); utilization over the window is
  # 100 * (1 - Δidle / Δtotal). Fetch raw range data; interpret with the window stated.
  curl -fsS --max-time 15 -H "Authorization: Bearer ${DIGITALOCEAN_ACCESS_TOKEN}" \
    "https://api.digitalocean.com/v2/monitoring/metrics/droplet/cpu?host_id=${droplet_id}&start=${START}&end=${END}" \
    | jq -r --arg id "$droplet_id" --arg n "$name" '
        (.data.result // []) as $r
        | if ($r | length) == 0 then "\($id)\t\($n)\tno-datapoints (agent installed but no data in window)"
          else
            ([$r[] | select(.metric.mode=="idle") | (.values[-1][1]|tonumber) - (.values[0][1]|tonumber)] | add // 0) as $idle
            | ([$r[] | (.values[-1][1]|tonumber) - (.values[0][1]|tonumber)] | add // 0) as $total
            | if $total > 0 then "\($id)\t\($n)\tutil_pct=\(((1 - $idle/$total)*100)|floor)"
              else "\($id)\t\($n)\tundetermined (zero total delta)" end
          end'
done
```

Expected: one line per agent-carrying Droplet with an observed `util_pct` over the window. A Droplet whose `util_pct` is at or below `CPU_IDLE_PCT` over `IDLE_DAYS` is the COST-DO-001 finding — reported with the window, step, and method stated as evidence, and with `list_price_monthly_usd` (looked up in §10) as labeled context. **No savings dollar is computed**; the ratio and the list price are separate facts. A `no-datapoints` or `undetermined` line is `blocked` evidence, not a pass.

**COST-DO-009 (backup add-on on an idle / decommissioned Droplet).** DigitalOcean's Droplet backup add-on is a percentage-of-Droplet-cost line item; enabled on a Droplet already flagged idle (COST-DO-001) or powered-off (COST-DO-002), it compounds the waste. This is a presence fact from `features`, cross-referenced against the other two checks:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/cost/digitalocean/${RUN_DATE}/raw"
jq -r '.[] | select(.features | index("backups"))
  | "\(.id)\t\(.name)\t\(.size_slug)\tstatus=\(.status)\tbackups=on"' \
  "${RAW_DIR}/droplets.json"
```

Expected: a list of Droplets with the backup add-on. File COST-DO-009 only for those whose ID also appears in COST-DO-001 or COST-DO-002 output; note the cross-reference in the finding rather than flagging every backed-up Droplet (backups on a busy production Droplet are correct, not waste).

## 6. Unattached block-storage volumes (COST-DO-003)

A DigitalOcean volume is billed whether or not it is attached; a volume with an empty `droplet_ids` list is orphaned storage. Attachment in the API is the `droplet_ids` array, not a status field:

```bash
set -eu
doctl compute volume list -o json | jq -r '.[]
  | select((.droplet_ids // []) | length == 0)
  | "\(.id)\t\(.name)\t\(.size_gigabytes)GiB\t\(.region.slug)\tcreated=\(.created_at)"'
```

Expected: no output on a clean estate. Each line is one presence-fact finding, named per volume ID with its size, region, and age. **No dollar figure**: DigitalOcean's volume price is a per-GiB rate, not a per-resource published price, so multiplying size × rate would be a forbidden recompute — report the size as the fact and stop there.

## 7. Aged Droplet & volume snapshots (COST-DO-004)

Snapshots (Droplet images and volume snapshots) are billed per GiB stored and accumulate silently. `doctl compute snapshot list` returns both kinds; distinguish them by `resource_type` and age each against the **team's own stated retention policy** — never an assumed default:

```bash
set -eu
RETENTION_DAYS="30"     # example ONLY — replace with the team's stated retention; if none is stated, say so in the finding
NOW="$(date -u +%s)"
doctl compute snapshot list -o json | jq -r --argjson now "$NOW" --argjson keep "$RETENTION_DAYS" '
  .[]
  | ((.created_at | sub("\\..*";"") | strptime("%Y-%m-%dT%H:%M:%S") | mktime)) as $ts
  | (($now - $ts) / 86400 | floor) as $age
  | select($age > $keep)
  | "\(.id)\t\(.name)\t\(.resource_type)\t\(.size_gigabytes)GiB\tage=\($age)d\tregions=\((.regions // []) | join(","))"'
```

Expected: no output when snapshots are within retention. Each line names a snapshot older than the stated policy, with its resource type, size, age, and regions. **No dollar figure** (per-GiB rate again). If the team has stated no retention policy, the finding says exactly that — "no retention policy stated; N snapshots older than 30 days listed for review" — rather than inventing a threshold or a cost for them.

## 8. Managed databases and reserved IPs (COST-DO-005, COST-DO-006)

**COST-DO-005 (over-provisioned managed DB cluster).** Provisioned shape (node count, size slug, storage) is a fact from the API; "oversized" is a judgment that requires an observed-usage source. Read the shape first:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/cost/digitalocean/${RUN_DATE}/raw"
mkdir -p "$RAW_DIR"
doctl databases list -o json | jq '[.[] | {
  id, name, engine, version,
  num_nodes, size,                 # size is the node slug, e.g. db-s-2vcpu-4gb
  storage_mib: (.storage_size_mib // null),
  region, status
}]' > "${RAW_DIR}/databases.json"
cat "${RAW_DIR}/databases.json"
```

Expected: one entry per cluster. A `num_nodes` above what the workload needs, or a large `size` slug, is only a **candidate** — do not file "oversized" from the slug alone. Credit the finding only against an observed-usage source: the DigitalOcean control-panel database Insights, the cluster's Prometheus-compatible metrics endpoint if the team has it wired, or the team's stated peak utilization. Record the provisioned shape as the fact and name the usage source you used (or state that none was available and the check is `blocked`). Configuration is metadata; live usage is proof. The DB node slug's DO-published `list_price_monthly_usd` may be looked up (§10) as labeled context, never as a saving.

**COST-DO-006 (unassigned reserved IPs).** A DigitalOcean reserved IP is **free while assigned to an active Droplet and billed while it is not** — the exact inverse intuition of "an unused IP is free". An unassigned reserved IP is `droplet == null`:

```bash
set -eu
doctl compute reserved-ip list -o json | jq -r '.[]
  | select(.droplet == null)
  | "\(.ip)\t\(.region.slug)\tunassigned"'
```

Expected: no output on a clean estate. Each line is one presence-fact finding — an IP that is billing precisely because nothing uses it. **No dollar figure** (per-hour published rate, not a per-resource price); the fact is "reserved but unassigned", which is the actionable signal.

## 9. Idle load balancers and registry storage (COST-DO-007, COST-DO-008)

**COST-DO-007 (idle / oversized load balancers).** A regional load balancer is billed per node (`size_unit`). A load balancer with zero backend Droplets and no backend tag is serving nothing:

```bash
set -eu
doctl compute load-balancer list -o json | jq -r '.[]
  | { id, name, region: .region.slug, size_unit,
      droplet_count: ((.droplet_ids // []) | length),
      tag: (.tag // ""), status }
  | select(.droplet_count == 0 and .tag == "")
  | "\(.id)\t\(.name)\t\(.region)\tnodes=\(.size_unit)\tbackends=0\tstatus=\(.status)"'
```

Expected: no output on a clean estate. Each line is an idle load balancer (no direct Droplets, no tag-based backend pool). A load balancer with backends but a `size_unit` above 1 and no traffic to justify the extra nodes is the *oversized* variant — that one needs a traffic source to prove, so record `size_unit` as the fact and mark it `blocked` for the traffic dimension rather than guessing. **No dollar figure**: load-balancer node price is a per-node published rate, so report the node count, not a computed cost.

**COST-DO-008 (container-registry storage over tier / garbage collection never run).** Registry storage usage and the subscription tier are not in `doctl registry get` (which returns only Name/Endpoint/Region), so read the REST endpoints directly. Deleted image manifests keep billing as untagged blobs until garbage collection runs, so "GC never run" is itself a cost signal:

```bash
set -eu
# Registry storage used vs the tier's included storage.
curl -fsS --max-time 15 -H "Authorization: Bearer ${DIGITALOCEAN_ACCESS_TOKEN}" \
  "https://api.digitalocean.com/v2/registry" \
  | jq '{name: .registry.name, storage_usage_bytes: .registry.storage_usage_bytes,
         usage_updated_at: .registry.storage_usage_bytes_updated_at}'
curl -fsS --max-time 15 -H "Authorization: Bearer ${DIGITALOCEAN_ACCESS_TOKEN}" \
  "https://api.digitalocean.com/v2/registry/subscription" \
  | jq '{tier: .subscription.tier.name, tier_slug: .subscription.tier.slug,
         included_storage_bytes: .subscription.tier.included_storage_bytes,
         allow_storage_overage: .subscription.tier.allow_storage_overage,
         list_price_monthly_usd: ((.subscription.tier.monthly_price_in_cents // 0) / 100)}'
```

Then confirm whether garbage collection has ever run (the registry name comes from the first call):

```bash
set -eu
REGISTRY_NAME="your-registry"   # from the /v2/registry call above
doctl registry garbage-collection list "$REGISTRY_NAME" -o json \
  | jq -r 'if length == 0 then "no garbage collection has ever run — untagged blobs from deleted manifests still bill"
           else "last GC: \(max_by(.created_at) | {status, created_at, blobs_deleted, freed_bytes})" end'
```

Expected: a `storage_usage_bytes` at or above `included_storage_bytes` on a tier with `allow_storage_overage: true` is the overage finding; a registry where GC has never run is the reclaimable-blob finding. Report bytes used vs included, and the GC state, as the facts. The tier's `list_price_monthly_usd` (from `monthly_price_in_cents / 100`) is DO-published context; the **overage** dollar amount is a per-GB rate applied to the excess, so it is a forbidden recompute — do not state it, report the byte gap instead.

## 10. Looking up a size slug's DO-published list price

For the checks that may carry a `list_price_monthly_usd` context field (COST-DO-001, 002, 005, and the node slug behind 007), the price is a verbatim lookup from DigitalOcean's public catalog, matched on the resource's `size_slug`. This is a published price, not a recompute, and it is the only price this catalog reads for a compute/DB resource. **Droplet/node slugs come from `doctl compute size list`; managed-DB slugs (`db-s-*`, `gd-*`) are NOT in that catalog — they live in `doctl databases options` (confirmed live). Look up a DB cluster's (COST-DO-005) list price there, not in `compute size list`, or the context is silently omitted:**

```bash
set -eu
SIZE_SLUG="s-4vcpu-8gb"   # the resource's size_slug from its inventory row
doctl compute size list --format Slug,PriceMonthly,PriceHourly --no-header \
  | awk -v s="$SIZE_SLUG" '$1==s {printf "list_price_monthly_usd=%s (hourly %s)\n", $2, $3}'
```

Expected: one line with the slug's published monthly price. Attach it to the finding as `list_price_monthly_usd` context only; it is never written to `estimated_monthly_savings_usd` and never summed into the savings-total line (§11). If the slug is not in the catalog output (custom/legacy slug), omit the field rather than guessing.

## 11. Rendering the DigitalOcean section

Every finding here uses `area: cost-optimization`, `points_recoverable: 0`, a concrete resource in `affected` (Droplet ID, volume ID, snapshot ID, DB cluster ID, reserved IP, load-balancer ID, or registry name — never "the account"), and is **report-only**: the `recommendation` names the concrete action and the DigitalOcean console / `doctl` path, and carries no `setup-*` remediation pointer — acting on a cost signal (resizing or deleting live infrastructure) is materially riskier than a reliability fix and stays a human decision (v1 never automates a resize or a deletion from a cost signal).

**Open the section with the savings-summary line** per [report-template.md](../../../report-standard/report-template.md)'s cost/savings rule. Because DigitalOcean returns **no** provider-native savings figure for any check, the DigitalOcean summary line **always** takes the no-figure form — never `$0`, which would falsely imply nothing to save:

> **N cost opportunities found on DigitalOcean; no provider-sourced dollar figures available — DigitalOcean publishes no savings API, so each item is a presence fact to review.** Largest by DO list price: `<resource>` (list_price_monthly_usd: `<X>`, shown as context, not a provider-computed saving).

Then render the per-row table, columns `Finding | Resource | Region | Signal | DO list price (context) | Action`. The `DO list price (context)` column shows `list_price_monthly_usd` where §10 supplied one, and `—` otherwise — it is explicitly labeled *context, not savings*, so no reader mistakes the column for a savings total. A row with no list price prints `—`, reading as "checked, no DO-published price" rather than "forgot to fill in". **Do not** add a savings-total column and **do not** sum the list-price column: `check-cost.sh` enforces that the savings summary sums only provider-native figures, of which DigitalOcean has none.

## 12. Commands this audit must never run

Any of these in a cost-audit transcript is a lane violation, whatever the justification. Cost analysis is strictly read-only; not one Droplet is resized, powered off, or deleted, and no snapshot, volume, IP, or registry blob is removed:

- `doctl compute droplet create|delete`, `doctl compute droplet-action <power-off|power-on|reboot|resize|snapshot|rebuild|...>`
- `doctl compute volume create|delete|resize`, `doctl compute volume-action <attach|detach|resize>`, `doctl compute volume snapshot`
- `doctl compute snapshot delete`
- `doctl compute reserved-ip create|delete`, `doctl compute reserved-ip-action <assign|unassign>`
- `doctl compute load-balancer create|update|delete|add-droplets|remove-droplets|add-forwarding-rules|remove-forwarding-rules|purge-cache`
- `doctl databases create|delete|resize|migrate`, and any `doctl databases <firewalls|user|pool|replica|db> create|update|delete|append|replace|remove`
- `doctl registry create|delete`, `doctl registry garbage-collection start|cancel`, `doctl registry repository delete-manifest|delete-tag`
- Any `curl` POST, PUT, PATCH, or DELETE against `api.digitalocean.com`
- Any POST to any webhook, including a smoke test; the toolkit Slack brief in the skill's final phase is the single exception and posts only to the brief webhook from `slack.webhook_env`
