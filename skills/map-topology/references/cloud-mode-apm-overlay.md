# Cloud Mode — the APM overlay (observed service→resource edges, any estate)

The one Cloud-Mode lane that works on EVERY estate — Kubernetes included:
when an APM already watches the services, its traces know which databases and
queues they really talk to. This overlay turns that into observed
service→resource edges that merge with (and upgrade) whatever the cloud lanes
found. On DigitalOcean it is the ONLY observed source; on a pure-Kubernetes
estate it is a free bonus on top of K8s Mode's map.

**Shared rules** ([cloud-mode-aws.md](cloud-mode-aws.md)): evidence classes,
composition, review tiers, redaction. Two overlay-specific hard rules:

1. **Observed edges expire.** An APM relationship reflects recent traffic
   (New Relic TTLs its relationships on the order of an hour); record
   `valid_from` and treat absence as "not currently observed", never as "no
   dependency".
2. **These are resource edges, not CALLS.** A datastore edge never enters the
   Traffic map; the service→service CALLS lane (already shipped in
   [non-k8s-sources.md](non-k8s-sources.md)) is separate and unchanged.

## When this lane runs

Whenever `newrelic` is configured (any estate shape) — after the cloud lanes,
before edge synthesis, bounded to the in-scope service list. Grafana Tempo's
service-graph metrics are the second source when the `lgtm`/`tempo` lane is
configured; Datadog and Sentry are catalogued below as non-lanes so nobody
re-researches them.

## New Relic datastore edges

Same auth and identity gate as `audit-newrelic` (User key, region host).
Verification status: the `relatedEntities` read pattern is live-proven (the
CALLS lane shipped on it in v0.1.197); the datastore-instance identity below
is doc-cited — **verify the first live datastore row before bulk-trusting**
(this estate's key is pending rotation, so the first post-rotation run is the
proof point).

```bash
set -eu
NR_API_HOST="api.newrelic.com"        # or api.eu.newrelic.com — from newrelic.region (Phase 0)
# NEW_RELIC_USER_KEY resolved from newrelic.api_key_env by the Phase-0 source gate
[ -n "${NEW_RELIC_USER_KEY:-}" ] || { echo "NEW_RELIC_USER_KEY is not set — run the Phase-0 source gate first"; exit 1; }
GUID="one-in-scope-service-entity-guid"   # from the 2D service discovery (bounded: per in-scope service)
NRB="$(mktemp)"
NRM="$(curl -s -o "$NRB" -w '%{http_code} %{content_type}' --max-time 30 \
  -X POST "https://${NR_API_HOST}/graphql" -H 'Content-Type: application/json' -H "API-Key: ${NEW_RELIC_USER_KEY}" \
  --data "{\"query\":\"{ actor { entity(guid: \\\"${GUID}\\\") { relatedEntities { results { type target { entity { guid name domain entityType } } } } } } }\"}")"
NRC="${NRM%% *}"; NRCT="${NRM#* }"
[ "$NRC" = "200" ] && printf '%s' "$NRCT" | grep -qi json && jq -e '.data' "$NRB" >/dev/null \
  || { echo "New Relic relatedEntities read failed (HTTP ${NRC}) — skip the overlay, never guess"; rm -f "$NRB"; exit 1; }
# Keep the datastore-shaped rows: CONNECTS_TO relationships whose target is an
# INFRA datastore-instance entity. The entity NAME carries the identity as
# vendor/host/port segments — the host:port joins the endpoint catalog directly.
jq -r '.data.actor.entity.relatedEntities.results[]?
  | select(.type == "CONNECTS_TO")
  | .target.entity | [.entityType, .name, .guid] | @tsv' "$NRB"
rm -f "$NRB"
```

Join and emit: parse the datastore identity (vendor + host + port + database
name where present) out of the target entity name, match the endpoint catalog
(or stand the resource up as APM-only when no cloud lane saw it — same
existence rule as the service merge: infrastructure wins on existence, APM
wins on connectivity, and an APM-only datastore is a real fact tagged
`newrelic-only`). Relation from vendor family (redis → CACHES_IN, SQL
engines/Mongo → STORES_DATA_IN, queue vendors → the messaging relations);
`evidence_class: observed`, `mechanism: newrelic.connects-to`, confidence per
the shared table, TTL semantics on.

## Grafana Tempo service-graph edges

When the estate's Tempo (or the metrics store its service-graphs write to) is
configured, the service-graph metrics carry database client edges. One
bounded instant query against the Prometheus-compatible endpoint the config
already names:

```bash
set -eu
PROM_URL="your-metrics-endpoint"      # the same endpoint the lgtm lane already uses
Q='sum by (client, server, connection_type) (rate(traces_service_graph_request_total{connection_type="database"}[15m]))'
TB=$(curl -s --max-time 30 -G "${PROM_URL}/api/v1/query" --data-urlencode "query=${Q}" 2>/dev/null) || TB=""
[ -n "$TB" ] && printf '%s' "$TB" | jq -r '.data.result[]? | [.metric.client, .metric.server, .metric.connection_type] | @tsv' \
  || echo "tempo service-graph metrics: unavailable — skipping (observed lane)"
```

⚠️ The `server` label for database edges carries the peer identity under
Tempo's DEFAULT label mapping, which still uses the old `db.name`-era
attributes on many installs — expect a LOGICAL database name, not always a
host, and join accordingly (logical-name join, one review tier weaker than a
host match). Verify the label shape on the estate's Tempo version before
trusting bulk rows.

## Non-lanes (catalogued so nobody re-researches them)

- **Datadog**: inferred-service peer tags and the Software Catalog relation
  APIs are real but preview-stability; revisit when an estate needs
  it — verify the exact API surface live at that point, never assert from
  this note.
- **Sentry**: span data aggregates at operation/table level with no reliable
  database-host dimension — an existence corroborator at best, never an
  identity source.

## Bounded reads

| Source | Cost | Bound |
| --- | --- | --- |
| New Relic relatedEntities | 1 query per in-scope service | the scope checkpoint's service list |
| Tempo service-graph | 1 instant query | fixed |
