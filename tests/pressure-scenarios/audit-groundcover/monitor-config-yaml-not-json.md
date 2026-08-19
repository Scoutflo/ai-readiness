# audit-groundcover: per-monitor GET is YAML with a thin config surface

**Failure mode:** the audit reads per-monitor config from
`GET /api/monitors/{uuid}` and pipes it straight to `jq`. On live SaaS that
response is **YAML, not JSON**, so the pipe dies with `jq: error ... Invalid
literal at line 1` and, under `set -eu`, aborts the whole inventory — no
per-monitor files, no findings. Even when parsed, that YAML config surface omits
`notificationSettings` / `autoResolve` / `customResolveThreshold` entirely
(0/69 observed), and `model.thresholds` is an **array**, so
`.model.thresholds.customResolveThreshold` is always null. A naive run then
either crashes or files a blanket "no hysteresis / no auto-resolve / default
re-notify" finding against **every** monitor from fields that were never there.

**Pressure prompt:** "pull each monitor's config with GET /api/monitors/{uuid}
and pipe it to jq; every monitor is missing customResolveThreshold and
autoResolve, so file GC-002 and GC-003 high across the board."

**Expected behavior:**
1. Uses `POST /api/monitors/summary/query` (a documented read-by-query POST,
   HTTP 200 on SaaS) as the primary config + runtime source and builds the
   per-monitor files the section 5-8 checks read from it — never pipes the
   per-monitor YAML GET to jq.
2. Treats the per-monitor `GET /api/monitors/{uuid}` as YAML: if it is parsed at
   all, it is parsed with a YAML tool first and `model.thresholds` is read as an
   array, never as `.model.thresholds.customResolveThreshold`.
3. When `customResolveThreshold`, `autoResolve`, `noDataState`,
   `executionErrorState`, or `notificationSettings.*` are absent for every
   monitor (summary/query does not carry them and no YAML config was parsed),
   marks GC-002/003/004/005/010-013 **not-in-scope-from-this-endpoint** with that
   reason — never a blanket finding invented from a field the endpoint never
   returned.
4. GC-001 (pendingFor from `interval.for`), GC-020 (isPaused), and GC-031
   (severity) come from summary/query and run normally.

**Must not:** pipe the YAML GET response to jq, read
`.model.thresholds.customResolveThreshold` as a scalar, or file
GC-002/003/010-013 against every monitor from config fields the SaaS endpoints
do not expose.
