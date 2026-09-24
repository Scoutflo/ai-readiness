# Cloud Mode — DigitalOcean resources and service→resource edges

Command recipes for map-topology's **Cloud Mode** on DigitalOcean: managed
databases (Postgres/MySQL/Redis-family/Kafka/MongoDB/OpenSearch), the App
Platform declarations that wire apps to them, trusted-source firewalls, and
VPC membership. Service discovery is in
[non-k8s-sources.md](non-k8s-sources.md); the workflow and review protocol
live in [SKILL.md](../SKILL.md).

**Live-verified (2026-09-21) on a real estate**: identity gate, the catalog
(4 clusters incl. valkey→cache mapping, zero password leakage), app-spec read
(estate uses no spec attachments — the trusted-sources lane carried the real
edges instead, exactly as documented), trusted-source app-rule joins (2 real
app→database edges resolved by app ID), and the VPC-members API read (which
also caught and fixed a doctl gap — see the reachable lane).

**Shared rules** (identical across clouds, defined once in
[cloud-mode-aws.md](cloud-mode-aws.md)): the evidence classes and their
meanings ("Evidence classes"), the composition and confidence table
("Evidence composition and confidence"), the review tiers, and the redaction
discipline ("Redaction discipline for configuration values"). Everything
below is read-only; no lane requests or reads a secret value.

DigitalOcean is the **cheapest cloud to map honestly**: the App Platform spec
is a platform-enforced declaration (attaching a database both declares it AND
wires the firewall), so most edges here are `declared` at near-zero inference.
There is **no cloud-side observed lane** — DigitalOcean monitoring is
node-scoped; live-traffic evidence on DO comes only from the APM overlay
([cloud-mode-apm-overlay.md](cloud-mode-apm-overlay.md)).

## Identity and access gate

`doctl` resolves auth from `digitalocean.token_env`, exactly as
`audit-digitalocean` does. Verify the account before any read:

```bash
set -eu
[ -n "${DIGITALOCEAN_ACCESS_TOKEN:-}" ] || { echo "DIGITALOCEAN_ACCESS_TOKEN is not set — run /scoutflo:connect"; exit 1; }
doctl account get --output json | jq -e '.status == "active"' >/dev/null || { echo "DigitalOcean account check failed — fix the digitalocean block"; exit 1; }
doctl account get --output json | jq -r '"do account: " + .status + " (team scoping comes from the token itself)"'
```

There is no tier ladder here: one read-only token sees everything below or
nothing. A 401 is the whole answer.

## Resource endpoint catalog

One row per managed database cluster. **The raw `databases list` JSON
contains the connection PASSWORD — never print or store it raw**; select
fields in the same pipe, always:

```bash
set -eu
CAT="${TMPDIR:-/tmp}/cloudmode-do-catalog.tsv"; : > "$CAT"
# kind  id  endpoint_host  endpoint_port  engine  logical_names
doctl databases list --output json \
| jq -r '.[] | [
    (if .engine == "redis" or .engine == "valkey" then "cache"
     elif .engine == "kafka" then "message_queue" else "database" end),
    .id, (.connection.host // "-"), ((.connection.port // 0)|tostring),
    .engine, ((.db_names // []) | join(",") | if . == "" then "-" else . end),
    .name] | @tsv' >> "$CAT"
sort -u "$CAT" -o "$CAT"; echo "catalog rows: $(wc -l < "$CAT" | tr -d ' ')"
```

The private-network hostname variant (`private-<host>`) is the same cluster;
treat both as one identity when joining. Load balancers
(`doctl compute load-balancer list`) and Spaces buckets (S3-compatible;
listed via the Spaces keys when configured) join the catalog the same way
when the estate uses them.

## Declared configuration

The App Platform spec is the whole declared lane, and it is the strongest
declaration any cloud offers — attaching a database in the spec makes the
platform inject the connection env vars AND open the firewall:

```bash
set -eu
# One pass over every app: its declared databases + which component uses which bindable
doctl apps list --output json | jq -r '.[]
  | .spec.name as $app
  | (.spec.databases // [])[]
  | [$app, .name, (.cluster_name // "dev-database"), (.engine // "-"), ((.production // false)|tostring)] | @tsv'
# Per-component bindable references: ${<db-name>.HOSTNAME}-style env values name the
# exact spec database a component consumes (keys+bindables only — values that are not
# bindable templates follow the shared redaction discipline: host extraction only)
doctl apps list --output json | jq -r '.[]
  | .spec.name as $app
  | ((.spec.services // []) + (.spec.workers // []) + (.spec.jobs // []))[]
  | .name as $comp
  | (.envs // [])[]
  | select((.value // "") | test("\\$\\{[A-Za-z0-9_-]+\\.(HOSTNAME|PORT|DATABASE|USERNAME|CA_CERT)\\}"))
  | [$app, $comp, .key, ((.value // "") | capture("\\$\\{(?<db>[A-Za-z0-9_-]+)\\.") | .db)] | @tsv'
```

Interpretation: a `databases[]` entry with `production: true` and a
`cluster_name` is a **zero-inference declared edge** from every component of
that app to the managed cluster (`mechanism: do.appspec.databases`) —
narrowed to the specific component when a bindable env names the same spec
database. `production: false` (a dev database) is still an edge, flagged as a
dev dependency. A non-bindable env value gets the same host-extraction
treatment as every other cloud (shared redaction rules; secret-named keys
skipped; extractions are join probes, never output).

## Permitted and reachable lane: trusted sources

DigitalOcean fuses "who may" and "who can" into the database firewall — a
typed allowlist. This is the corroboration lane AND the discovery lane for
droplet-based (non-App-Platform) services:

```bash
set -eu
DBID="your-database-cluster-id"     # one catalog row per pass
doctl databases firewalls list "$DBID" --output json \
| jq -r '.[] | [.type, .value] | @tsv'
```

`type` is one of `app` / `droplet` / `k8s` / `tag` / `ip`. An `app` rule's
`value` is the app **ID** — join it to the app name through `doctl apps list`
(`.id` → `.spec.name`, live-verified); the resolved rule is a
platform-maintained wiring edge from that app to the cluster
(`mechanism: do.trusted-source.app`) and, where a spec `databases[]`
declaration also exists, corroborates it to near-certain. On estates that
skip spec attachments entirely (live-confirmed shape), these app rules ARE
the primary edge lane. A `droplet` rule is a `permitted+reachable` edge
candidate to that droplet's service row; a `tag` rule fans out ONLY to droplets carrying
the tag at read time (record the tag in the edge's `join_key`); an `ip` rule
is recorded as an unattributed opening (a finding-shaped fact when it is
`0.0.0.0/0`), never an edge to a guessed host. When another cloud is also
configured, a host `/32` `ip` rule is handed to the cross-cloud attribution
pass, which may resolve it to a service in that other cloud (shared rules,
cookbook: "Cross-cloud IP attribution" in the AWS cookbook — live-proven here:
DO managed-DB allowlist IPs resolved to GCP VM public IPs). `k8s` rules point at DOKS
clusters — the cluster's services stay in K8s Mode; note the edge at cluster
granularity only.

## Reachable lane: VPC membership

Weak co-location corroboration only — never an edge by itself. ⚠️ `doctl` has
no members subcommand (live-caught) — read the API directly, fail-closed:

```bash
set -eu
[ -n "${DIGITALOCEAN_ACCESS_TOKEN:-}" ] || { echo "DIGITALOCEAN_ACCESS_TOKEN is not set — run the Phase-0 source gate first"; exit 1; }
for v in $(doctl vpcs list --output json | jq -r '.[].id'); do
  VB="$(mktemp)"
  VM="$(curl -s -o "$VB" -w '%{http_code} %{content_type}' --max-time 30 \
    -H "Authorization: Bearer ${DIGITALOCEAN_ACCESS_TOKEN}" \
    "https://api.digitalocean.com/v2/vpcs/${v}/members?per_page=100")"
  VC="${VM%% *}"; VCT="${VM#* }"
  [ "$VC" = "200" ] && printf '%s' "$VCT" | grep -qi json \
    && jq -r --arg v "$v" '.members[]? | [$v, ((.urn // "::") | split(":")[1]), (.name // "-")] | @tsv' "$VB" \
    || echo "vpc ${v}: members read failed (HTTP ${VC}) — skipping this VPC"
  rm -f "$VB"
done
```

Member type comes from the `urn` prefix (`do:dbaas:…`, `do:droplet:…`) — the
`resource_type` field is not populated on this endpoint (live-verified).

## Observed lane

None exists on the DigitalOcean side (monitoring is per-node metrics, not
per-connection). Say so in the map header. The APM overlay
([cloud-mode-apm-overlay.md](cloud-mode-apm-overlay.md)) is the only
traffic-level evidence source on DO estates.

## Traps

- **`doctl databases list -o json` includes `connection.password`** (and a
  full connection URI). Every recipe pipes to a jq field selection in the
  same command; a raw dump to screen, file, or transcript is a leak. The same
  applies to `doctl databases connection` — never call it without a field
  selection, and prefer the list's already-selected fields.
- App spec envs may hold literal values (type unset) alongside `SECRET`-typed
  ones; SECRET-typed values come back encrypted (`EV[…]`) — treat any
  encrypted blob as opaque, never decode, never store.
- The `dev-database` shorthand (a `databases[]` entry with no
  `cluster_name`) is an app-embedded dev DB, not a managed cluster — edge to
  a synthetic per-app resource, flagged dev.
- Droplet services have **no config API** — tags are the only grouping
  (INTENT ceiling), so droplet edges come from trusted-source rules, not from
  imagination.

## Bounded reads

| Lane | Cost | Bound |
| --- | --- | --- |
| Catalog | 1 call | fixed |
| App specs | 1 call (list returns full specs) | fixed |
| Trusted sources | 1 call per catalog cluster | catalog size; checkpoint-scoped |
| VPC members | 1 call per VPC | VPC count (small) |
