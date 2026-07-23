# Scoutflo Topology Readiness

Every audit report carries a Scoutflo Topology Readiness section. It answers one question per critical service: **once the report's findings are fixed, will this service work with Scoutflo platform source sync and correlation sync?** A customer who reaches "ready" across their critical services can adopt the platform without a topology rebuild; that is the point of the section.

Input: `./scoutflo-audits/topology-export.json` (written by `/scoutflo:map-topology`, spec in the skill's `references/scoutflo-export.md`). If the file or `topology.md` is missing, the section says exactly that and points at `/scoutflo:map-topology`; it never guesses.

## The six checks per critical service

| # | Check | Pass condition |
| --- | --- | --- |
| T1 | Service identity | Unique `name`; valid `service_type`, `environment`, `business_criticality`; correlation attributes present: `service_name`, `namespace`, `cluster_id` (values lowercase, no URLs/hostnames/IPs — correlation engines drop such values) |
| T2 | Workload attributes | The service has a `DEPLOYED_AS` edge to a workload resource carrying all four mandatory attributes: `cluster_id`, `namespace`, `workload_name`, `workload_type` (import rejects workloads without them) |
| T3 | Observability edges | At least one edge per signal the service emits: `SENDS_METRICS_TO`, `SENDS_LOGS_TO`, `SENDS_TRACES_TO`, `MONITORED_BY` — sourced from the watchpoints table, not assumed |
| T4 | Edge attributes | Each observability edge carries its provider's required attributes (sentry: `project`; prometheus-family: `jobLabel`, `namespace`, `metricsPath`; loki: `namespace`, `app`; victorialogs: `serviceName`, `namespace`; tempo/victoriatraces: `serviceName`; vcs/ticketing per the export spec) |
| T5 | Integration identity | Each referenced backend resource has `identity.provider` and `identity.external_id`, so alerts from that backend can be resolved back to the service |
| T6 | Confidence | Every edge from T3 is at confidence >= 8 **and** carries an actionable anchor combination: a `service`-category identity attribute plus either a Kubernetes anchor (`namespace`, `pod`, or `container` category) or, for Sentry specifically, a `project` or `environment` category attribute. A confidence-8+ edge missing that anchor combination is not actionable on the real platform even though the number alone would suggest it is — do not pass T6 on the number by itself. Declared edges that an audit verified live count as 8+; declared-but-unverified stays below |

### Identity attributes must be correlation-ready, not just present

T4 and T6 check different things, so do not assume a field that satisfies T4 automatically satisfies T6. **T4** confirms an observability edge carries the provider's own identifying fields (for example Prometheus `jobLabel`/`namespace`/`metricsPath`, Sentry `project`). **T6** confirms those values are carried in a form the platform can actually anchor a signal on: a service/workload/app identity plus a Kubernetes anchor (`namespace`, `pod`, or `container`) or, for Sentry, a `project`/`environment`.

The practical rule for a clean export: carry the service identity on a plain snake_case `service` or `service_name` attribute, alongside a `namespace` (or `pod`/`container`). A camelCase or provider-specific field — for example `serviceName` on CloudWatch, VictoriaLogs, Tempo, or VictoriaTraces — can satisfy that provider's own schema (so it passes T4) while still not anchoring correlation (so it fails T6). When a provider's identity field is camelCase, also emit a literal `service_name` with the same value so the anchor is unambiguous. Scoutflo maintains the current, exact attribute and naming requirements; check your export against Scoutflo's topology documentation before an import.

## Verdict per service

- **ready** — all six pass.
- **partial** — T1 and T2 pass, at least one of T3-T6 fails. Name the exact gap ("logs edge missing", "sentry edge missing `project`").
- **not-ready** — T1 or T2 fails. Identity gaps block everything downstream; say so first.

Section headline: `<r> of <n> critical services sync-ready`. The Slack brief carries the same counts, no service names needed.

## How audits use this

- Audit skills evaluate T1-T6 read-only from `topology-export.json` plus their own live checks (an audit that just verified a Sentry project exists upgrades that edge's T6).
- Gaps that map to an existing finding reference the finding ID; gaps with no finding get a `TOPO-` prefixed row in the findings table with a remediation pointer to `/scoutflo:map-topology` (fill watchpoints, re-run) or the relevant setup skill.
- Readiness is reported, never scored into the 0-100 audit score. It is a parallel verdict with its own column, so a customer can be observability-healthy but not yet sync-ready, and see both truths.

## Why these checks

Platform correlation matches a signal to a service only when a service/workload/app name AND (a namespace/pod/container match, or, for Sentry, a project/environment match) both hold between topology and signal, with the integration identified by its provider and external id. T1-T6 are exactly the fields that make those matches possible. A high confidence number by itself is not the gate — the platform requires both the confidence and the identity/anchor combination before it treats a proposal as actionable, which is why T6 checks both. The precise attribute and confidence requirements are maintained by Scoutflo; verify your export against current Scoutflo topology documentation before an actual import.

## Two known boundaries of this per-service model

T1-T6 judge each critical service in isolation. Two real classes of gap sit outside that scope and are worth naming explicitly, because a customer can pass all six checks for every service and still have a broken graph in these two specific ways:

- **Multi-cluster identity bleed.** When the same service name repeats across two or more clusters, a workload-identity match that isn't cluster-scoped can resolve a service to a workload running in the *wrong* cluster. This is invisible from T1-T6 alone, since each check passes per-service without ever comparing across clusters. If the estate spans 2+ clusters with any repeated service names, explicitly verify each service's `DEPLOYED_AS` edge resolves to a workload in its own cluster, not a same-named one elsewhere — this is a real, confirmed platform-level failure mode, not a hypothetical.
- **Cross-service call edges are out of scope for T1-T6 by design**, since T1-T6 is a per-service check. A topology where every service individually passes T1-T6 can still have zero recorded `CALLS` relationships between services — meaning cross-service blast-radius reasoning has no data to work from, even though every individual service looks "sync-ready." `map-topology`'s traffic map is the place this gets captured (via Ingress/Service-selector/VirtualService/ServiceEntry-backed edges on the fallback and mesh paths respectively); a customer whose traffic map is sparse or empty should not be read as "topology ready" for cross-service investigation quality, only for per-service correlation. Note this distinction explicitly in any readiness conversation with a customer rather than letting a clean T1-T6 scorecard imply more than it proves.
