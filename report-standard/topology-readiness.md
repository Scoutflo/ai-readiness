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

### T6's category mapping is stricter than a provider's field names suggest

T4 and T6 check different things and use different rules — do not assume a field that satisfies T4 automatically satisfies T6. T4 checks presence of a provider's own schema fields (`alarmArn`, `serviceName`, `jobLabel`, ...). T6 checks whether those field values land in one of the correlation engine's signal categories (`service`, `namespace`, `pod`, `container`, `cluster`, `workload`, `app`, `environment`, `team`, `project`, `repository`, `space`), and that mapping is driven by literal field-name matching, not by a provider's own schema:

- Exact-match category fields (case-sensitive, snake_case only): `service`, `service_name` -> `service`; `app`, `application`, `application_name` -> `app`; `deployment_name`, `workload_name`, `statefulset_name`, `daemonset_name` -> `workload`; `cluster_name`, `cluster_id`, `kubernetes_cluster_name` -> `cluster`; `project`, `project_key`, `project_slug`, `project_name` -> `project`; `team`, `team_name`, `owner_team` -> `team`; `repo`, `repository`, `repo_slug` -> `repository`.
- Substring-match category fields (any field whose name contains this substring, camelCase included): `namespace` -> `namespace`; `container` -> `container`; `environment`/`env`/`stage` -> `environment` (exact match only for the short forms, substring for `environment`).
- **camelCase is not split.** A field literally named `serviceName` (one token, capital S) does not match the `service`/`service_name` exact-match list and has no substring rule to fall back on — it does **not** populate the `service` category, even though it is a valid, required-or-optional field on several providers' own attribute schemas (CloudWatch's `serviceName`, VictoriaLogs' `serviceName`, Tempo/VictoriaTraces' `serviceName`). This is a real, confirmed platform behavior, not a toolkit assumption.
- Practical consequence for T6: when a provider's own schema field for the service identity is camelCase (`serviceName`, `functionName`, `clusterName`, `instanceId` on CloudWatch; `serviceName` on VictoriaLogs/Tempo/VictoriaTraces), populating only that field satisfies T4 but not T6's `service` anchor. Also emit a literal `service` (or `service_name`) key with the same value, or place the value under the export's `attributes.service_name` field per T1, so the anchor category is actually populated. `containerName`-style fields are the one exception that still works, because that rule is a substring match, not exact-match.

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

Platform correlation matches a signal to a service only when a service/workload/app name AND (a namespace/pod/container match, or, for Sentry, a project/environment match) both hold between topology and signal, with the integration identified by its provider and external id. T1-T6 are exactly the fields that make those matches possible. The confidence number by itself is not the gate — the real correlation engine (`ACTIONABLE_CORRELATION_CONFIDENCE = 8`, `hasActionableAttributeDNA()`) requires both the number and the anchor combination before treating a proposal as actionable; a proposal missing the anchor combination is downgraded to `warning_only` regardless of its confidence score, which is why T6 checks both. Contract aligned as of 2026-07; enums are strict on import, so re-verify against current Scoutflo documentation before an actual import.

## Two known boundaries of this per-service model

T1-T6 judge each critical service in isolation. Two real classes of gap sit outside that scope and are worth naming explicitly, because a customer can pass all six checks for every service and still have a broken graph in these two specific ways:

- **Multi-cluster identity bleed.** When the same service name repeats across two or more clusters, a workload-identity match that isn't cluster-scoped can resolve a service to a workload running in the *wrong* cluster. This is invisible from T1-T6 alone, since each check passes per-service without ever comparing across clusters. If the estate spans 2+ clusters with any repeated service names, explicitly verify each service's `DEPLOYED_AS` edge resolves to a workload in its own cluster, not a same-named one elsewhere — this is a real, confirmed platform-level failure mode, not a hypothetical.
- **Cross-service call edges are out of scope for T1-T6 by design**, since T1-T6 is a per-service check. A topology where every service individually passes T1-T6 can still have zero recorded `CALLS` relationships between services — meaning cross-service blast-radius reasoning has no data to work from, even though every individual service looks "sync-ready." `map-topology`'s traffic map is the place this gets captured (via Ingress/Service-selector/VirtualService/ServiceEntry-backed edges on the fallback and mesh paths respectively); a customer whose traffic map is sparse or empty should not be read as "topology ready" for cross-service investigation quality, only for per-service correlation. Note this distinction explicitly in any readiness conversation with a customer rather than letting a clean T1-T6 scorecard imply more than it proves.
