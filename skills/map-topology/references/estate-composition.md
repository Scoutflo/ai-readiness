# Compose a selected estate from per-target maps

Use this after mapping each selected cluster or cloud target into its own audit directory. Keep each `topology-export.json` unchanged. The local composition helps review shared telemetry, cross-region dependencies and paging paths without collapsing repeated service names. It is **not** a server import and adds no provider or relationship enum to that contract.

## Inputs and evidence

Create a private `estate-manifest.json` beside the retained maps. Paths resolve relative to that manifest. `sources[].target` is the canonical configured audit target, not a guessed region. Select only the maps in this review; an unselected cluster remains outside the conclusion.

```json
{
  "schema": "scoutflo-estate-topology-manifest/v1",
  "audit_date": "2026-01-15",
  "sources": [
    {"target": "kubernetes/east", "path": "east/topology-export.json", "collection": {"status": "complete", "scope": "target", "observed_at": "2026-01-15T10:00:00Z"}},
    {"target": "kubernetes/west", "path": "west/topology-export.json", "collection": {"status": "partial", "scope": "subset", "observed_at": "2026-01-15T10:00:00Z"}}
  ],
  "links": [],
  "unresolved_links": [
    {"from": {"target": "kubernetes/east", "entity_type": "service", "name": "checkout"}, "reason": "Storage destination account is not established by the available configuration"}
  ]
}
```

Use the actual audit date and source generation timestamps. Every map must be current for that date; timestamps in the future fail. A source map's own collection and target metadata must agree with its manifest entry; contradictions fail. Duplicate JSON keys and non-finite numbers are rejected. Collection marked complete requires target scope and a matching map generation; absent collection metadata stays unknown. A map can remain useful with partial collection, but cannot establish estate-wide absence.

Run in a fresh shell after setting these operator-selected local paths:

```sh
: "${CLAUDE_PLUGIN_ROOT:?Set the installed plugin root}"
: "${ESTATE_MANIFEST:?Set the private composition manifest path}"
: "${SCOUTFLO_AUDIT_DIR:?Set the selected estate output directory}"
python3 "$CLAUDE_PLUGIN_ROOT/skills/map-topology/lib/compose-estate.py" \
  "$ESTATE_MANIFEST" "$SCOUTFLO_AUDIT_DIR/estate-topology.json"
```

Expected: `ESTATE-TOPOLOGY-OK maps=2 entities=... links=... completeness=partial-or-unknown`. Outputs are `estate-topology.json` and `estate-topology.md`. The helper reads local JSON only, bounds each file to 8 MiB, at most 50 maps and 50,000 entities, and validates before replacing output. A failure leaves earlier files intact as historical evidence; stop and do not present them as the failed run's result.

## Join deliberately

Every entity is keyed by **target + entity type + source name**. Equal service names, `cluster.local` addresses, private addresses or backend labels do not merge entities across clusters. Relationships inside each source map keep their original payload and source hash. Existing `assertion_type: observed` means an object was observed; its composed evidence is **configuration**, including VirtualService-derived `CALLS`. It does not prove that traffic flowed. Existing `inferred` stays inferred, `asserted` stays asserted, and a missing assertion type stays unknown. No tier is upgraded during composition.

For a reviewed cross-map link, add `from`, `to`, `relation` and `evidence_file` to `links[]`. The evidence file must be a retained, sanitized observation with this shape:

```json
{
  "schema": "scoutflo-topology-observation/v1",
  "audit_date": "2026-01-15",
  "target": "kubernetes/east",
  "observed_at": "2026-01-15T10:00:00Z",
  "kind": "configuration",
  "ref": "retained-config/checkout-exporter.json",
  "from": {"target": "kubernetes/east", "entity_type": "service", "name": "checkout"},
  "to": {"target": "kubernetes/west", "entity_type": "resource", "name": "logs-backend"},
  "relation": "SENDS_LOGS_TO"
}
```

`kind` is `configuration`, `asserted` or `observed-traffic`. For the last, also record `observation_type` as `trace`, `flow-log`, `request-log` or `delivery-receipt` and point `ref` to the retained observation that names these endpoints. The transform checks date, endpoint, target and relation consistency and preserves a SHA-256 receipt. The operator must verify the referenced observation; a typed record or a hash alone does not establish that the evidence is true. Never relabel configuration as traffic to fill a gap.

Before writing the observation, walk each configuration link:

1. Record the container/workload and namespace, then the effective setting. Explicit `env` overrides `envFrom`; among duplicate `envFrom` keys, the later source wins. Keep shadowed values as shadowed evidence. Record Secret/ConfigMap references as source target, namespace, object name and key name only; never copy values into the map. A reference proves the reference, not a successful connection.
2. Distinguish an inbound listener from an outbound destination. Bind addresses such as `0.0.0.0` describe listeners. Ports and paths help identify protocol; they do not identify the remote account.
3. Resolve endpoint host and port within the correct DNS/cluster scope. A private address or repeated hostname cannot identify one physical database across maps. Use provider account/resource identity or independently verified endpoint resolution.
4. Keep branch gaps explicit: unresolved storage account, redacted routing handle, unreadable service or missing region stays in `unresolved_links`. Do not replace unknown destinations with a plausible backend.
5. Preserve parallel outputs: a collector may send one stream to ClickHouse, another to object storage, and another to Elasticsearch. Draw each observed configured branch with its own status; do not let a visible ClickHouse destination erase an unresolved Blob/S3 account or an older Elasticsearch output.
6. For paging, distinguish source rule → inbound ingestion → management routing/policy → responder. A configured path, incident assignment, notification receipt and human acknowledgement are separate evidence classes. Preserve the evidence needed for each claim.

**Wrong:** both maps say `checkout`, so combine them; a VirtualService says `CALLS`, so mark live traffic. **Right:** keep two target-qualified entities, add a reviewed configuration link, and leave observed traffic unknown until a trace or equivalent receipt supports it.

## Common failure modes

| Failure | Handling |
| --- | --- |
| Same map labeled as two targets | Reject duplicate resolved source paths and identical canonical source content, including relabeled copies. |
| Source entity cluster contradicts its map | Reject; correct the original map from evidence. |
| Link names a missing target/entity | Reject; map or explicitly retain it as an unresolved destination. |
| Missing, stale or future generation | Reject the source; recollect or review it under its actual historical date. |
| Partial map presented as full estate | Keep source collection state and partial composition; declare the selected scope. |
| New local artifact passed to server importer | Use the unchanged per-target export for import; this composition is local only. |
