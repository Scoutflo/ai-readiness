# Scoutflo topology export: topology-export.json

Alongside the human-readable `topology.md`, Phase 3 writes `./scoutflo-audits/topology-export.json`: the same inventory in a machine-readable shape aligned to the Scoutflo platform's topology import contract (v1, 2026-07). If you use Scoutflo, this file is import-ready; if you do not, it is still the canonical machine-readable form of your service map and audits read it the same way.

Everything here is derived from the same read-only inventory as `topology.md`. Nothing is sent anywhere; the file stays on your machine.

## File shape

```json
{
  "version": "scoutflo-topology-export/v1",
  "generated_at": "2026-07-18T00:00:00Z",
  "cluster": { "context": "your-kube-context", "cluster_id": "your-cluster-name" },
  "services": [],
  "resources": [],
  "relationships": []
}
```

## services[] — one per discovered service

```json
{
  "name": "checkout",
  "display_name": "Checkout",
  "service_type": "api",
  "environment": "prod",
  "business_criticality": "high",
  "tags": ["team:payments"],
  "attributes": {
    "service_name": "checkout",
    "namespace": "shop",
    "cluster_id": "your-cluster-name",
    "app": "checkout"
  },
  "owner": { "team": "payments" }
}
```

- `name` must be unique across the export; it is the stable identifier relationships reference.
- `service_type` one of: `api, worker, frontend, backend, cron, gateway, batch, stream, function, webhook, notification, auth, analytics, search, email, sms, push_notification, reporting, admin, mobile, event_handler, library`. Derive from workload shape (Deployment behind an Ingress: `api` or `frontend`; CronJob: `cron`; queue consumer: `worker`); default `backend` when unclear and record the guess.
- `environment` one of `prod, staging, dev`; `business_criticality` one of `low, medium, high, critical`. Ask the user once per run for anything not derivable; do not invent criticality.
- `attributes` is the correlation DNA: `service_name`, `namespace`, `cluster_id`, and `app` (from `app.kubernetes.io/name` when present). Values lowercase, no URLs, no hostnames, no IPs, no secrets; matching engines drop such values.
- `tags` use `key:value` form for categorizable facts (`team:payments`).

## resources[] — clusters, namespaces, workloads, integration backends

```json
{
  "name": "prod-cluster",
  "resource_type": "kubernetes_cluster",
  "source": "manual",
  "attributes": { "cluster_id": "your-cluster-name", "region": "your-region" }
}
```

```json
{
  "name": "checkout-deploy",
  "resource_type": "kubernetes_deployment",
  "source": "manual",
  "attributes": {
    "cluster_id": "your-cluster-name",
    "namespace": "shop",
    "workload_name": "checkout",
    "workload_type": "deployment"
  }
}
```

```json
{
  "name": "team-sentry",
  "resource_type": "monitoring",
  "source": "manual",
  "attributes": { "provider": "sentry", "org": "your-org-slug" },
  "identity": { "provider": "sentry", "external_id": "your-org-slug" }
}
```

- Emit the cluster, every in-scope namespace (`kubernetes_namespace`), every workload, and one resource per observability backend named in the Integration watchpoints table.
- Workload `resource_type` one of `kubernetes_deployment, kubernetes_stateful_set, kubernetes_daemon_set, kubernetes_job, kubernetes_cron_job`. **The four workload attributes (`cluster_id`, `namespace`, `workload_name`, `workload_type`) are mandatory: the import contract rejects workload resources without all four.**
- Integration backends use `resource_type` `monitoring`, `alerting`, `vcs`, or `ci_cd`; `identity.provider` is one of `prometheus, grafana, sentry, loki, tempo, mimir, victoriametrics, victorialogs, victoriatraces, elk, datadog, groundcover, pagerduty, zenduty, github, gitlab, bitbucket, argocd, jira, confluence, jsm, k8s, aws, gcp, azure, custom`; `identity.external_id` is the provider-side identifier alerts will carry (org slug, integration id). Alert correlation looks this up; a backend without identity cannot resolve alerts to services.

## relationships[] — where all meaning lives

```json
{
  "from": { "entity_type": "service", "name": "checkout" },
  "to": { "entity_type": "resource", "name": "checkout-deploy" },
  "relation": "DEPLOYED_AS",
  "assertion_type": "observed",
  "confidence": 9
}
```

```json
{
  "from": { "entity_type": "service", "name": "checkout" },
  "to": { "entity_type": "resource", "name": "team-sentry" },
  "relation": "MONITORED_BY",
  "assertion_type": "asserted",
  "confidence": 8,
  "attributes": { "project": "checkout", "environment": "prod" }
}
```

Emit these edge families:

| Edge | Relation | Source of truth |
| --- | --- | --- |
| service -> its workload | `DEPLOYED_AS` | Service selector join (observed) |
| namespace -> cluster, workload -> namespace | `PART_OF` | inventory (observed) |
| k8s Service -> workload | `ROUTES_TO` | selector join (observed) |
| service -> service | `CALLS` | VirtualService routes only; never guessed from names (observed) |
| service -> metrics backend | `SENDS_METRICS_TO` | watchpoints row (asserted) |
| service -> logs backend | `SENDS_LOGS_TO` | watchpoints row (asserted) |
| service -> traces backend | `SENDS_TRACES_TO` | watchpoints row (asserted) |
| service -> errors/monitoring/alerting backend | `MONITORED_BY` | watchpoints row (asserted) |
| service -> vcs/ci/ticketing | `USES` | watchpoints or user (asserted) |

- `assertion_type`: `observed` for edges derived from live cluster objects, `asserted` for edges declared by the watchpoints table or the user.
- `confidence` 0-10. Use 9 for object-backed edges, 8 for user-declared watchpoints, lower when uncertain. 8 is the actionable threshold downstream, but the number alone is not sufficient: the platform also needs a service/workload/app identity attribute plus either a Kubernetes anchor (`namespace`/`pod`/`container`) or, for Sentry, a `project`/`environment` attribute before it treats the edge as actionable. Populate the identity and anchor attributes together, not just a high confidence number on its own.
- `diagnostic_criticality`: an accepted field on every relationship in the real bulk-import contract, not shown in the examples above because it has no bearing on T1-T6 scoring, but real and worth setting. A relationship missing it can be silently dropped from an investigation's topology slice on the live platform even though the edge exists in the graph — a quiet, invisible degradation, not a rejected import. Set it per edge when the source data supports a judgment (for example `"stable"` for a long-observed, unchanged edge vs `"degrading"` for one recently added or showing drift); when there's no real signal to judge it from, omit the field rather than defaulting every edge to the same value, since a uniform default carries no information either.
- Per-provider required `attributes` on observability edges (import validates these): sentry `project`; prometheus/mimir/victoriametrics `jobLabel`, `namespace`, `metricsPath`; loki `namespace`, `app`; victorialogs `serviceName`, `namespace`; tempo/victoriatraces `serviceName`; elk index pattern under `index`; github `owner`, `repo`; gitlab `projectId`, `projectPath`; jira/jsm `projectKey`; confluence `spaceKey`; argocd `applicationName`. Fill from the watchpoints row when the user provided it; otherwise emit the edge without attributes and let the readiness check flag it.

## What makes the export sync-ready (the readiness bar)

The Scoutflo platform correlates a signal (alert, error, log line) to a service only when a service/workload/app name AND a namespace (or pod/container) can be string-matched between the topology and the signal. The non-negotiable minimum per service is therefore: `service_name` + `namespace` + `cluster_id` on the service, the four mandatory attributes on its workload, and at least one attribute-complete observability edge at confidence >= 8. The report standard's Scoutflo Topology Readiness section scores exactly this.

Contract note: the import contract fields and enums are maintained by Scoutflo and are strict on import; verify against current Scoutflo topology documentation before running an actual import.
