# Dashboard Design Guide

Design rules, the dashboard catalog, panel-type guidance, and the build-time QA checklist for the Dashboards section of [setup-grafana](../SKILL.md). Write mechanics (the API calls) are in [payloads.md](payloads.md#dashboards).

## Build for incident decisions

Every dashboard exists to answer a question a responder actually has during an incident, not to display what data happens to be available. Before adding a panel, write down the question it answers. If you cannot state the question, do not build the panel.

Split by audience:

- **Engineering dashboards**: dense, technical, full RED signals, one panel per decision. Built for the person on call.
- **Executive or status views**: a handful of stat panels showing current state, traffic, error budget, and alert health. Built for someone who needs the headline, not the query. Demote any campaign- or launch-specific view to one example among several status-dashboard shapes; the pattern generalizes to any product launch or traffic event your team runs.

Never publish an empty dashboard backed by no real datasource. Adapt panels from any imported or example dashboard to your own datasources, labels, and routes before it ships; blind imports show plausible-looking panels that query nothing real.

## Dashboard catalog

A starting set. Not every environment needs every row; build what your incident questions require.

| Dashboard | Purpose |
| --- | --- |
| Status / command center | Current status, traffic, error rate, alert health, ingestion budget, at a glance |
| Application | RED signals per route, business-critical flows, scheduled-job outcomes, dependency failures |
| Runtime / infrastructure | Workload health, log volume, resource limits, restarts, retries |
| Logs | Searchable application, runtime, and provider logs with useful filters |
| Traces | Trace search, slow and error traces, service dependency view |
| Edge / network | CDN, load balancer, WAF, status codes, TLS, domains, where applicable |
| Providers | Database, cache, queue, email, payment, and AI-provider error and latency views |
| Monitoring health | Ingestion health, exporter health, alert evaluation, usage and cost |

## Dashboard requirements

Every dashboard this skill provisions or repairs meets these, checked live after every write:

- Stable UID and folder, chosen deliberately, never left to auto-generation.
- Template variables for service, environment, route, and any other dimension a responder filters by; every variable resolves to at least one real value.
- Stat panels for current state, time series for trends, tables for active issues, logs panels for investigation, trace panels for request-level debugging, matched to the question each answers.
- Correct units set per panel: `reqps`, `ms`, `s`, `bytes`, `percentunit`, `short`, and currency or data-volume units where cost is shown.
- No panel with an invalid or failing query target.
- Data links between metrics, logs, traces, and any incident or runbook tooling you use, where they help a responder move fast.
- Annotations for deploys, incidents, and maintenance windows, so a graph inflection has an explanation attached.
- Transformations only where they simplify the panel; a heavy client-side transformation hiding a bad source query is a defect, not a feature.

## Panel-type guidance

| Panel type | Use |
| --- | --- |
| Stat | Current KPIs: uptime, error rate, request rate, alert health, budget burn |
| Gauge / bar gauge | Capacity, quota, saturation, per-service comparison |
| Time series | Trends: RED metrics, ingestion, latency, error rate over time |
| Heatmap | Latency distribution or high-volume histograms |
| Table | Active issues, failing endpoints, firing alerts, top errors, provider failures |
| Logs | Log investigation with filters and parsed fields |
| Traces | Trace search and exemplar drilldown |
| Node graph | Service map, dependency flow, edge and error relationships |

## Build-time QA checklist

The same bar `audit-grafana`'s Semantic Dashboard QA Gate scores against ([audit-grafana check catalog](../../audit-grafana/references/api-checks.md#check-catalog), GRAF-020 through GRAF-028). Run this against the live dashboard JSON immediately after every write, not against the local file you built it from:

1. **Live replay.** Every panel target succeeds when replayed through `/api/ds/query`. A populated `error` field is a broken panel; `frames: 0` with no error needs a second look to distinguish intentional no-data from label drift.
2. **Scope match.** A panel titled for one service, environment, or namespace carries a filter that actually restricts to it. Check the generated query and any URL the panel links to, not just the panel title; a dashboard for three services silently querying the whole organization looks completely normal while doing it.
3. **Stable IDs over slugs.** External-system panels filter by stable identifiers (project ID, zone ID, namespace, service label) rather than text or slug matching, which silently matches nothing, or the wrong thing, after a rename.
4. **Pagination and caps.** Any panel target using `limit`, `per_page`, or default pagination is an investigation list, not a total. Use a native count endpoint or a server-side aggregation when the panel claims to show "how many".
5. **Reducer validity.** The `count` reducer is correct only when source rows are the intended unit. Numeric sources need `sum`, `lastNotNull`, or an explicit transformation instead.
6. **Source-count parity.** Cross-check every key stat against the provider-native source of truth: an error-tracker panel against the tracker's own count endpoint, a metrics stat against the raw instant query value ([audit-grafana pattern 2](../../audit-grafana/references/api-checks.md#apidsquery-cookbook)).
7. **Variable resolution.** Every template variable resolves to at least one real value against live label data.
8. **Link scope.** Data links and inspect links preserve the panel's scope; a service-scoped panel linking to an organization-wide list breaks the responder's context mid-incident.
9. **No dangling datasource references.** Every panel target points at a datasource UID that currently exists.

A dashboard is not done because it renders. It is done when every panel answers its intended question, at its intended scope, against the live object, not the local file you uploaded from.
