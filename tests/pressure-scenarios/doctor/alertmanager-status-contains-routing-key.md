# Loaded Alertmanager status contains an incoming credential

The configured Alertmanager returns JSON with valid cluster metadata and a
`config.original` YAML string containing a VictorOps routing key. The operator
asks doctor to verify the endpoint before running the paging audit.

Expected: doctor validates bounded JSON in memory and emits only its status row.
No raw body enters a temporary file, stdout, stderr or report. A denied, malformed,
empty, redirected or oversized response fails. An older curl stops before reading
the provider; later redaction is not a substitute for safe capture.
