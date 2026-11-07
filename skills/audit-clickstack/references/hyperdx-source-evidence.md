# HyperDX source evidence

This recipe reads configuration only. It does not test a receiver, fire an alert, or infer delivery from a URL. Use the selected target's doctor gate first; then run this in a fresh shell:

```bash
set -eu
sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/collect-hyperdx.sh"
```

For a labeled list, the orchestrator sets `SCOUTFLO_TARGET` to each label before the invocation. An ambiguous list, unknown label or missing explicit credential stops before a provider read. Output is under `${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/clickstack/[<label>/]<UTC-date>/raw/`:

- `hyperdx-configuration.json`: safe ID projections, activation state, per-resource counts/completeness, destination classes and source→connection joins.
- `alert-source-evidence.json` + `alert-source-capture.json`: [source evidence contract](../../audit-splunk-oncall/references/source-evidence.md). Each channel is a separate stable record. Capture verification proves the source read; route verification stays candidate or blocked until exact protected-route evidence is independently obtained. Handles and intermediate webhooks cannot certify SOC-007.

The official [API reference](https://clickhouse.com/docs/clickstack/api-reference), [alerts list](https://clickhouse.com/docs/clickstack/api-reference/alerts/list-alerts) and [webhooks list](https://clickhouse.com/docs/clickstack/api-reference/webhooks/list-webhooks) describe OSS Personal API Access Key Bearer auth, `/api/v2`, `limit`/`offset`/`meta.total` and `channel.webhookId`. Current multi-channel responses use `channels[]`; `channel` mirrors the first and is not counted twice. Managed ClickStack's Cloud API is a different product/auth surface; this recipe does not reinterpret it as OSS.

Bounds: 100 rows/page, 50 pages per paginated resource, 4 MiB/response, 20 seconds/request, 240 seconds/run and 110 requests/run. External alerts/webhooks must reconcile server totals, offset and limit without repeats/drift. Hitting a bound or a partial/denied page produces a current blocked receipt; it is not an estate-size restriction or a false empty success. Narrow the approved target/read scope or use an attended paginated read with equally explicit completeness. Do not label such a subset target-complete.

Sources, connections and dashboards currently return lists without server totals. Their returned objects support positive joins only; absent objects remain unknown. Connection `meta.skipped` is explicit incompleteness. Legacy session `/api/webhooks?service=slack|generic|incidentio` lists have no total and remain partial; do not mix that endpoint with external-v2 pagination. The session handshake is authentication only, once per invocation, with cookies held in memory. A configured API key's denial never silently switches credentials.

Raw response bodies, message/query templates, URLs, contact values, connection credentials and error bodies never reach disk/stdout. The projection keeps validated native IDs, booleans, fixed enums and host classes only. Unsupported shapes stop or block the affected resource. A public/private destination class is one configured hop, not proof of an accessible receiver. Source/table data freshness and downstream policy/coverage require separate reads in their owning lanes.

CS-040 uses exact per-channel receiver joins; CS-041 independently uses dashboard tile→source→connection references. An inline or saved-search alert whose source is absent from the list projection keeps its source join unknown; retrieve its detail in an attended read, project the authoritative ID before saving, and rerun the join. No raw query export is required. Zero alerts is judged against declared local-versus-external alerting ownership; it never blocks the independent CS-041 assessment.

## Source data binding

The projected source-to-connection ID join is configuration evidence. Endpoint, database and table are intentionally not persisted; `data_binding` requires an attended exact comparison before any selected ClickHouse read can establish source freshness. Record source/connection IDs, selected target, observation time and the comparison verdict only. Different regional connections must never share one target's freshness proof. A missing comparison is blocked, even if both databases have tables with the same name.
