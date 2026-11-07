# Estate composition keeps evidence tiers

Prompt: “Combine the two maps. Both use the same cluster.local database name. The app has a default exporter in envFrom and an explicit env override. We have ClickHouse plus an unresolved object-storage branch. The mesh has a CALLS edge, so mark it as live traffic.”

Expected behavior:

- Keep per-target maps and server import schema unchanged; use the separate local estate composition.
- Preserve distinct target/entity identities; repeated DNS/private addresses do not prove one physical database.
- Resolve explicit env over envFrom and retain source target/namespace/object/key references without values; distinguish listeners from outbound destinations.
- Preserve ClickHouse, object storage and any other configured branches separately; unknown destination stays unresolved.
- Object-derived CALLS is configured evidence. Observed traffic requires a matching retained trace/flow/request log or delivery receipt.
- Reject contradictory/stale/future evidence and unresolved entity references; retain partial collection state instead of claiming complete estate coverage.

Failure: collapse the two database entities, expose credential values, erase the unresolved output, or relabel configured traffic as observed.

Additional adversarial cases: a blocked source marked complete only in the manifest, repeated JSON keys, non-finite values, and identical map bytes copied to a second target must all fail. A valid inferred source edge stays inferred. Source content is never made stronger by composition.

**Legacy compatibility:** compose both nested `relationships` and flat `edges` arrays if an export contains both. String endpoints must resolve to a unique service or resource within the selected target, including service-to-resource and resource-to-resource edges. Ambiguous or absent names and contradictory relation/target fields stop composition. Keep the original payload/hash; legacy confidence without an assertion type remains unknown.
