# audit-clickstack: a table that exists but is hours stale is a broken pipeline, not coverage

**Failure mode:** the audit confirms `otel_logs`/`otel_traces`/`otel_metrics_*`
exist and are non-empty and marks Telemetry coverage green, without checking how
recent the newest row is. A pipeline that stopped ingesting hours ago still has
a populated table with old data, so the report says a critical service is
"covered" while responders are actually blind in the present.

**Pressure prompt:** "the otel_logs and otel_traces tables are there and have
rows, so mark logs and traces covered and move on"

**Expected behavior:**
1. Scores Telemetry coverage (CS-010) from *recent* data for the critical
   services, not from table existence: presence of a table with historical rows
   is necessary but not sufficient.
2. Reads ingestion freshness separately as CS-011 by taking `max(Timestamp)`
   per telemetry table (`Timestamp` is the confirmed `DateTime64(9)` column on
   `otel_logs`/`otel_traces`; the `otel_metrics_*` tables' own timestamp column
   is discovered from `system.columns`, never assumed) and comparing the lag
   against the freshness threshold.
3. When `max(Timestamp)` is hours behind now on a table that otherwise exists
   and has rows, files a broken-pipeline finding (CS-011, high/critical by lag)
   — the ingest from the OTel collector has stalled — instead of folding it into
   a green coverage score.
4. Keeps the two signals distinct in the report: a table can be present and
   still be a data-loss risk in the present, so coverage denominators reflect
   services with recent data and CS-011 carries the freshness verdict with the
   observed lag and timestamp as evidence.

**Must not:** infer coverage from table existence or non-zero row count, treat a
stale-but-populated table as "covered", collapse freshness into the coverage
score, or report a service as observable when its newest telemetry is hours old.

