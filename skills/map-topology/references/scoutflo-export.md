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
- **Duplicate service names across namespaces:** when the same Service name exists in more than one namespace (live-real: `api-gateway` in both `storefront` and `benchmark-workloads`), name **every** colliding service `<service>.<namespace>` — none of them keeps the bare name, so no reader can mistake one for the other. `attributes.service_name` keeps the bare name and `attributes.namespace` disambiguates; relationships reference the qualified `name`. This mirrors `map-repos`' rule that same-named services in different namespaces never collapse into one row.
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
    "workload_type": "deployment",
    "image": "ghcr.io/acme/checkout:3.0.0",
    "image_digest": "sha256:abcd1234",
    "source_repo_evidence": [
      {
        "candidate_repo": "acme/checkout",
        "evidence_source": "image_registry_path",
        "confidence": "heuristic",
        "subpath": null,
        "raw": "ghcr.io/acme/checkout:3.0.0"
      }
    ]
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
- Workload `resource_type` one of `kubernetes_deployment, kubernetes_stateful_set, kubernetes_daemon_set, kubernetes_job, kubernetes_cron_job`. **The four workload attributes (`cluster_id`, `namespace`, `workload_name`, `workload_type`) are mandatory: the import contract rejects workload resources without all four.** `image` (full ref) and `image_digest` are optional but capture them when known (the first container's image + resolved digest from the pod spec): the image is the one always-present breadcrumb toward the workload's build origin, even though a registry path alone never identifies a source repository (a package name can differ from the repo name, and a shared build image says nothing per-service).

### `source_repo_evidence[]` — tiered, typed service→repo evidence (optional, additive)

A workload may carry `source_repo_evidence`: an array of typed candidates for the source repository, each tagged with where it came from and how authoritative that source is. This is the shared contract read by both `map-repos` (candidate ranking) and the platform's future automation resolver — one captured evidence set, two consumers. Each entry:

```json
{
  "candidate_repo": "acme/checkout",
  "evidence_source": "image_registry_path",
  "confidence": "heuristic",
  "subpath": "services/checkout",
  "raw": "ghcr.io/acme/checkout:3.0.0"
}
```

- `candidate_repo` — the proposed `owner/name`. A candidate, never a confirmed mapping.
- `evidence_source` — one of `oci_image_source | argocd | image_registry_path | pod_annotation`.
- `confidence` — `authoritative` (the publisher's own declaration: OCI `org.opencontainers.image.source`, or an ArgoCD Application spec) or `heuristic` (a registry-path parse, or an annotation that isn't a declared source). Name similarity is not evidence and never appears here — it is the last-resort fallback in the consumer, carrying no `source_repo_evidence` entry.
- `subpath` — the service's subdirectory inside a monorepo, present **only** for sources that actually carry it (ArgoCD `spec.source.path`, a repo descriptor, or human confirmation downstream). A registry-path/OCI candidate is repo-level and leaves `subpath: null` — it must never claim a per-service subpath it did not observe.
- `deployed_revision` (optional) — the exact commit SHA that is **live**, when a source actually carries it: ArgoCD's `status.sync.revision` (only when it is a 40-hex SHA — a never-synced Application echoes the target ref instead, which is NOT a revision), or the OCI `org.opencontainers.image.revision` label (the standard companion to `image.source`, same registry fetch). This is the field that lets RCA name the culprit commit; never populate it with a branch name.
- `branch_ref` (optional) — the branch/tag the source deploys from when the source states it (ArgoCD `spec.source.targetRevision` when it is a ref like `main`, not a SHA). Branch context for diffing history — distinct from `deployed_revision` and never a substitute for it.
- `raw` — the exact source string the candidate was derived from, for auditability.

**The four-tier model** (capture what's available; a workload may carry entries from several tiers, and the consumer ranks by tier):

| Tier | `evidence_source` | Authority | How obtained |
| --- | --- | --- | --- |
| 1 | `oci_image_source` | authoritative | `org.opencontainers.image.source` label — registry manifest/config fetch (not `kubectl`) |
| 2 | `argocd` | authoritative (repo, `subpath`, `branch_ref`, and — when synced — `deployed_revision`) | ArgoCD Application CRs read via `kubectl` (`spec.source.repoURL` + `path` + `targetRevision`, `status.sync.revision`) |
| 3 | `image_registry_path` | heuristic — must be live-verified | parse of the already-captured `image` ref (free) |
| — | *(name similarity)* | fallback only | consumer-side; never written here |

An `image_registry_path` candidate is a *guess that must be verified live against GitHub before use* — a registry path often mirrors the repo (`ghcr.io/open-telemetry/demo` → `open-telemetry/demo`) but frequently doesn't (`gcr.io/my-proj/checkout` ≠ source repo). map-topology only captures the candidate; the consumer verifies it. Never promote a heuristic candidate to a confirmed mapping, and never let any evidence override a human-confirmed `repo-map.json`.
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

A `USES` edge to a `vcs` resource should carry, in `attributes`, the repo label (`repository` as `owner/name`) and — when the service lives inside a monorepo — a `subpath` (its subdirectory, e.g. `services/checkout`). Emit a `USES` edge only from evidence that actually resolved: an authoritative-tier `source_repo_evidence` entry (OCI/ArgoCD) whose candidate was live-verified, kept as `assertion_type: asserted` with the evidence source named. Do **not** emit a `USES` edge from a bare heuristic (`image_registry_path`) candidate that hasn't been verified, from name similarity, or by inventing one — on real estates the authoritative tiers are commonly absent, in which case the workload still carries its `source_repo_evidence` candidates (for the consumer to verify) but no `USES` edge is written. A human-confirmed `repo-map.json` remains the canonical source of service→repo truth and is never overridden by an asserted edge. (`subpath` here is the same concept `repo-map.json` records as `path` on a confirmed monorepo mapping — the evidence/export layer and the confirmed-mapping layer name the same subdirectory string.)

- `assertion_type`: `observed` for edges derived from live cluster objects, `asserted` for edges declared by the watchpoints table or the user.
- `confidence` 0-10. Use 9 for object-backed edges, 8 for user-declared watchpoints, lower when uncertain. 8 is the actionable threshold downstream, but the number alone is not sufficient: the platform also needs a service/workload/app identity attribute plus either a Kubernetes anchor (`namespace`/`pod`/`container`) or, for Sentry, a `project`/`environment` attribute before it treats the edge as actionable. Populate the identity and anchor attributes together, not just a high confidence number on its own.
- `diagnostic_criticality`: an accepted field on every relationship in the real bulk-import contract, not shown in the examples above because it has no bearing on T1-T6 scoring, but real and worth setting. A relationship missing it can be silently dropped from an investigation's topology slice on the live platform even though the edge exists in the graph — a quiet, invisible degradation, not a rejected import. Set it per edge when the source data supports a judgment (for example `"stable"` for a long-observed, unchanged edge vs `"degrading"` for one recently added or showing drift); when there's no real signal to judge it from, omit the field rather than defaulting every edge to the same value, since a uniform default carries no information either.
- Per-provider required `attributes` on observability edges (import validates these): sentry `project`; prometheus/mimir/victoriametrics `jobLabel`, `namespace`, `metricsPath`; loki `namespace`, `app`; victorialogs `serviceName`, `namespace`; tempo/victoriatraces `serviceName`; elk index pattern under `index`; github `owner`, `repo`; gitlab `projectId`, `projectPath`; jira/jsm `projectKey`; confluence `spaceKey`; argocd `applicationName`. Fill from the watchpoints row when the user provided it; otherwise emit the edge without attributes and let the readiness check flag it.

## What makes the export sync-ready (the readiness bar)

The Scoutflo platform correlates a signal (alert, error, log line) to a service only when a service/workload/app name AND a namespace (or pod/container) can be string-matched between the topology and the signal. The non-negotiable minimum per service is therefore: `service_name` + `namespace` + `cluster_id` on the service, the four mandatory attributes on its workload, and at least one attribute-complete observability edge at confidence >= 8. The report standard's Scoutflo Topology Readiness section scores exactly this.

Contract note: the import contract fields and enums are maintained by Scoutflo and are strict on import; verify against current Scoutflo topology documentation before running an actual import.
