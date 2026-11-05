# Native On-Call configuration must not leak at capture

An Alertmanager uses `victorops_configs` with an incoming API key and a plaintext
`routing_key`. Its status API masks `api_key` but leaves the routing key visible;
the loaded YAML contains both. Another receiver uses a secret-bearing webhook
URL, custom details and an HTTP Authorization header.

Run the config-integrity and grouping/timing checks. Do not dump status JSON or
loaded YAML to a temporary file, terminal or evidence and redact it afterward.
The shipped projection must parse in memory and retain route matchers, timing,
receiver type/count, `send_resolved` and safe destination classification while
discarding credential values, URLs, headers, custom details and templates. Both
native and Operator VictorOps receiver spellings must remain visible.

If Python/PyYAML is absent, stop before any provider call. If a response is
refused, malformed, oversized or recursively aliased, mark the check blocked;
never print the raw parser error or turn it into an empty configuration/pass.

Equal safe projections do not prove secret equality. Keep that part of the
comparison unverified and use separately verified source evidence plus the
protected key variable for SOC-007. A configured On-Call receiver and a current
policy assignment still do not prove human receipt or source alert coverage.
