# Scoutflo Topology Readiness

Every audit report carries a Scoutflo Topology Readiness section. **Read this section as: "if you connect this service to the Scoutflo platform today, will Scoutflo be able to automatically tell which alerts, logs, and metrics belong to it?"** That's a different question from the report's 0-100 score. The score asks "is this service well-monitored?" This section asks "is it *labeled and wired clearly enough* that an automated system — not a human reading dashboards — can reliably match a signal to the right service?" A service can score well and still fail this section, and vice versa; the report shows both because they answer different questions.

This section is written for anyone reading the report, with no assumption they know anything about Scoutflo's internals. It never uses Scoutflo-internal terms, code names, or file paths in its customer-facing prose — see "Writing rules for this section" below for what that means in practice and why it matters if the reader hands this report to their own AI assistant.

Behind the scenes, this section is generated from a machine-readable map of the customer's services (built by a separate mapping step). If that map doesn't exist yet, or was built for a different part of the estate than this report covers, the section says so in plain terms and names the one command that fixes it — it never silently skips itself or says a bare "unavailable".

## The six checks per critical service

Each critical service is checked against six criteria. Report tables and prose use only the plain-English name in the left column below — the short codes are internal bookkeeping (see "Internal identifiers" below) and must never appear in anything the customer reads.

| Plain-English name (what the report shows) | What it checks, in plain terms | Internal code |
| --- | --- | --- |
| Service identity | Does the service have a clean, unique name and basic classification (type, environment, criticality) that a human and a machine would both read the same way — no stray URLs or IP addresses in the name fields, which automated matching silently ignores? | T1 |
| Workload mapping | Is the service actually linked to the real infrastructure object running it (its Kubernetes deployment, VM, or equivalent), with enough detail (cluster, namespace, workload name and type) that the platform can find it? | T2 |
| Telemetry connections | Has each kind of signal this service produces — metrics, logs, traces, and alerts — been explicitly connected to where that signal lives, rather than left to be guessed? | T3 |
| Connection details | For each of those connections, are the specific fields the monitoring tool needs (for example, which label identifies this service in Prometheus, or which project name identifies it in Sentry) filled in, not just "a connection exists"? | T4 |
| Tool identity | Is the monitoring tool itself (the specific Grafana, Prometheus, Sentry, etc. instance) clearly identified, so that when it produces an alert, the platform knows which tool it came from? | T5 |
| Match confidence | Given everything above, how sure can the platform actually be that a given alert or log line belongs to *this* service and not a different one with a similar name elsewhere in the estate? Scored 0-10; only 8 or higher is treated as reliable enough to act on automatically | T6 |

**Confidence is always shown with its scale**: write `5/10`, never a bare `5` — a bare number invites the reader (or their own LLM) to guess what scale it's on.

## Internal identifiers — never customer-facing

`T1`-`T6` are the internal, stable identifiers this document and the audit skills use to refer to each check unambiguously across reports and over time (the way `ALR-002` or `LGTM-039` identify a specific finding). They exist for people maintaining or extending this toolkit, not for readers of a customer report. Renders of this section:
- use the plain-English names as column headers, always;
- may include the codes once, in a small legend line below the table (`Checks T1-T6 per topology-readiness.md`), so a maintainer following a bug report can locate the exact check — but a customer never needs to read or understand that legend to understand the table itself;
- never use terms like "edge", "`MONITORED_BY`", "`SENDS_METRICS_TO`", "correlation attribute", or any internal file name (`topology-export.json`, `topology.md`) in prose sentences a customer reads. Those are the data model this toolkit uses internally to compute the table — say what was checked and what's missing in plain terms instead (see the rewritten examples under "Verdict per service" and the action-plan rules below).

This matters beyond politeness: a customer who cannot make sense of unfamiliar jargon is likely to paste the report into their own AI assistant and ask what it means. If the assistant has never seen Scoutflo's internal data model, undefined terms like "sync-ready" or "`MONITORED_BY` edge" give it nothing to ground an answer in — it will confidently invent one, and that invented explanation will look just as authoritative as the real content around it. Plain language closes that gap; jargon opens it.

### Internal note: Connection details vs. Match confidence are not the same pass

*(This subsection is for people maintaining the audit skills, not for report prose. Nothing below should appear in a customer-facing report — the plain-English equivalent is "having a connection isn't enough; the platform also needs to be confident it's connected to the right service," which is already covered by the two-row explanation in the table above.)*

T4 and T6 check different things internally, so a field that satisfies T4 does not automatically satisfy T6. T4 confirms a signal connection carries the provider's own identifying fields (for example Prometheus `jobLabel`/`namespace`/`metricsPath`, Sentry `project`). T6 confirms those values are carried in a form the platform can actually anchor a signal on: a service/workload/app identity plus a Kubernetes anchor (`namespace`, `pod`, or `container`) or, for Sentry, a `project`/`environment`. The practical rule for a clean export: carry the service identity on a plain snake_case `service` or `service_name` attribute, alongside a `namespace` (or `pod`/`container`). A camelCase or provider-specific field — for example `serviceName` on CloudWatch, VictoriaLogs, Tempo, or VictoriaTraces — can satisfy that provider's own schema (so it passes T4) while still not anchoring correlation (so it fails T6). When a provider's identity field is camelCase, also emit a literal `service_name` with the same value so the anchor is unambiguous.

## Verdict per service

- **ready** — all six checks pass.
- **partial** — Service identity and Workload mapping pass, but at least one of the other four checks fails. Name the exact gap in plain terms a reader can act on ("no logs connection declared for this service" rather than "logs edge missing").
- **not-ready** — Service identity or Workload mapping fails. These two are foundational; if the platform can't even identify or locate the service, nothing downstream can be evaluated, so say that first.

Section headline, written for the reader with no internal terms: `<r> of <n> critical services are ready for automatic Scoutflo correlation` (do not use "sync-ready" — spell out what readiness means each time it appears, since the phrase alone means nothing to someone seeing it for the first time). The Slack brief carries the same counts, no service names needed.

## Required: the readiness action plan

Whenever at least one service is below **ready**, the section ends with an action table — one row per blocking gap, written in plain language so a reader can paste any row into a ticket (Jira or otherwise) without rewording and without needing to know Scoutflo's internal terms. Vague rows ("improve connection attributes") are a conformance bug; each row names the exact, real-world object and the exact change — a config field, a command, a dashboard setting, a receiver name — never an internal data-model term like "edge" or a file path like `topology-export.json`:

| # | Service | Blocked on | Do this | Done when |
| --- | --- | --- | --- | --- |
| 1 | checkout | Connection details | In your Prometheus scrape config for checkout, confirm the `jobLabel` and `metricsPath` values, then add them to checkout's metrics connection so Scoutflo can query the right target | Re-run the audit: checkout's Connection details column reads pass |
| 2 | checkout | Match confidence | Fix the dead default alert receiver (finding ALR-002), then re-check that alerts for checkout actually reach it | The alert-connection confidence reads 8/10 or higher |

Rules: **Do this** is one concrete imperative naming the real object (a config field, a receiver, a dashboard, a command) and the exact change — referencing the finding ID when one exists, but describing the fix itself in plain infrastructure terms, not the internal data-model term for it. **Done when** is an observable condition a teammate can verify without any Scoutflo-specific context. Order rows by verdict severity (not-ready services first), then by check order. All services ready: state that in one line and omit the table.

## When the underlying service map is missing or doesn't match this report's target

Three distinct states, each rendered differently in plain language — never a bare "unavailable", and never naming the internal file (say "the service map for this environment" or similar, not `topology-export.json`):

1. **No map exists yet**: say that, and give the one-line fix: "Run `/scoutflo:map-topology` against the environment serving these services, then re-run this audit — this section will then be able to check each service."
2. **A map exists but covers a different environment** (e.g. it describes a Kubernetes cluster while this report audits a cloud account, or a different cluster than the one these services actually run on): say plainly which environment the existing map covers, that none of this report's services can be honestly checked against it, and the fix: map the environment this report actually covers, then re-run.
3. **This kind of estate has no service map concept at all** (a pure cloud/SaaS target with no Kubernetes layer): say the section will apply once services are modeled, and point at the mapping command as the way to do that.

In every state the section still renders (never silently dropped), and the Slack brief's readiness line reads "readiness not recorded" rather than a guessed count.

## How audits use this (internal)

*(Internal implementation notes for maintainers — none of this belongs in customer-facing report prose.)*

- Audit skills evaluate T1-T6 read-only from `topology-export.json` plus their own live checks (an audit that just verified a Sentry project exists upgrades that check's T6 confidence).
- Gaps that map to an existing finding reference the finding ID; gaps with no finding get a `TOPO-` prefixed row in the findings table with a remediation pointer to `/scoutflo:map-topology` (fill watchpoints, re-run) or the relevant setup skill. `TOPO-` and other internal prefixes never appear in the customer-facing prose of this section — only in the findings table, which is understood to be an internal-ID index.
- Readiness is reported, never scored into the 0-100 audit score. It is a parallel verdict with its own column, so a customer can be observability-healthy but not yet ready for automatic correlation, and see both truths without either one hiding the other.

## Why these checks (internal rationale)

*(Internal — explains the design to maintainers; do not surface this reasoning in customer report prose. The plain-English equivalent for a customer is already in the intro paragraph and the six-row table above.)*

Platform correlation matches a signal to a service only when a service/workload/app name AND (a namespace/pod/container match, or, for Sentry, a project/environment match) both hold between the service map and the signal, with the monitoring tool identified by its provider and external id. T1-T6 are exactly the fields that make those matches possible. A high confidence number by itself is not the gate — the platform requires both the confidence and the identity/anchor combination before it treats a proposal as actionable, which is why the Match confidence check verifies both.

## Two things this section cannot see, even when every service passes

The six checks above look at each critical service on its own. Two real gaps sit outside that scope, and it's worth stating both plainly in any report — a customer can pass every check for every service and still have these two problems, so a clean table should never be read as "the whole picture is fine":

- **A service name that repeats across more than one cluster can get matched to the wrong one.** If two different clusters both run something called, say, `checkout`, an identity match that isn't scoped to a specific cluster can resolve alerts or logs to the wrong `checkout` — the one in the other cluster. This is invisible to the six checks, because each one is evaluated per service without ever comparing across clusters. If an estate spans more than one cluster and any service name repeats between them, this is worth verifying by hand: confirm each service's real workload link points at a workload in its own cluster, not a same-named one elsewhere. This is a confirmed real failure mode, not a hypothetical edge case. *(Internal: this corresponds to checking that the `DEPLOYED_AS` connection resolves within the declared `cluster_id`.)*
- **These checks don't cover whether services can see each other.** Passing all six checks proves the platform can identify and connect to each service individually — it says nothing about whether the platform has any record of which services call which other services. A customer whose services all pass individually can still have zero recorded traffic relationships between them, which means investigating "what else might this outage affect" has no data to work from, even though every service on its own looks fully ready. This is a separate, additional thing to map (the traffic/call-graph step), and a report should say so explicitly rather than letting a clean per-service table imply that cross-service investigation is also covered — it is not, unless that traffic map has separately been built and populated.
