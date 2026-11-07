---
name: rca
description: Answer "why is <resource/service> failing / at risk — give me the RCA" with a live, evidence-cited root cause. It uses your existing audit reports as REFERENCE (what's known, where to look), the service topology as the BLAST-RADIUS MAP (every attached resource/service, who calls whom, what monitors it), and then makes strictly READ-ONLY live calls (kubectl get/describe/events/logs) on the failing resource and its attached suspects to confirm the current truth. Every claim cites its source and is tagged [report@date] or [live@now]; it never invents a cause, and it degrades to a report-only answer when it has no live access. Use when the user asks why something is failing/degraded/at risk, asks for an RCA or root cause, or asks for a finding's blast radius or upstream cause. Do not use to change anything (analysis only, read-only), or to invent a cause when signal is thin (it says so instead).
---

# rca — live, evidence-grounded root-cause analysis

When someone asks *"why is pod `checkout-abc` failing — give me the RCA?"*, this skill answers it the way an SRE would: the audit reports tell it **what's already known and where to look**, the topology graph tells it **the blast radius and every resource/service attached to the target**, and then it **goes and looks live** — read-only `kubectl` calls on the failing resource and its attached suspects — to gather the current, detailed truth. It returns a root cause where **every clause cites its evidence and its freshness** (`[report@<date>]` vs `[live@<now>]`), carries a **confidence level**, and ends with an explicit **"what I could not determine"**.

**Reports are a reference, not the answer.** The old failure mode was answering purely from a possibly-stale `findings.json` and stopping at "insufficient signal". Now reports are the *prior* (they narrow where to look and supply posture context like "no memory limit"); topology is the *map* (the attached set to investigate); and the **live probe is the evidence** that names or rejects a cause. When there is no live access (no `kubectl`, no context, a cloud surface), rca still answers from reports alone — clearly banner-labelled `[report-only, as of <date>]` — so it always works, just less completely.

## The one hard rule: never invent a cause

The RCA is assembled **only** from evidence actually observed — a report finding, a topology edge, a correlation cascade, or a live probe result. A branch of the k8s failure taxonomy may be named a **cause** only when its specific observed field is present (see [live-evidence/references/k8s-liveness-probes.md](../live-evidence/references/k8s-liveness-probes.md)); a bare symptom (`restartCount > 0` during a normal rollout) is labelled a symptom, never a verdict. A blocked / RBAC-denied / null probe is an honest **gap** (`verdict=unknown`), never read as "healthy" and never a guess. If signal is too thin, the answer is *"insufficient signal — here is what's known and exactly what to collect next,"* not a fabricated chain. This is the same discipline the toolkit enforces on scores (`check-findings.sh`) and dollars (`check-cost.sh`).

- ❌ `Root cause: the pod is crash-looping.` (CrashLoopBackOff is the *backoff*, not the reason; no terminated reason/exit code cited)
- ✅ `Most likely root cause (confidence: high): pod checkout-abc's app container was OOMKilled (exitCode 137) 4 times in 20m [live@2026-08-14T09:12Z], and K8S-004 says its Deployment has no memory limit [report@2026-08-10]; memory exhaustion killed the container. The missing limit is posture context; inspect memory usage and node pressure before naming the trigger. Blast-radius candidate: orders-api CALLS checkout (configured topology; verify traffic).`

## Doctor gate

rca needs `jq` and **either** local reports **or** live cluster access. It sources the home-anchored secret store (so any provider token needed for a non-k8s probe is seen) and the shared read-only live-evidence library, then decides which mode is available. It never blocks on the live branch — a live miss simply routes to report-only.

```bash
set -eu
command -v jq >/dev/null || { echo "missing binary: jq"; exit 1; }
# Source the secret store the same way doctor/audits do (degrade, never abort).
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
if [ -f "$SCOUTFLO_ENV" ]; then set +eu; . "$SCOUTFLO_ENV" || echo "rca: warning: could not source $SCOUTFLO_ENV"; set -eu; fi
# Redaction + live-evidence libraries (read-only; the live path is guarded there).
. "${CLAUDE_PLUGIN_ROOT}/skills/redaction/lib/redaction.sh" 2>/dev/null || true
. "${CLAUDE_PLUGIN_ROOT}/skills/live-evidence/lib/live-evidence.sh"
AUD="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
CFG="${SCOUTFLO_CONFIG:-}"
[ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done
[ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
# Resolve the kubernetes context for the live probe through the shared enumerator — never `head -1` a
# scalar. kubernetes may be a single block (one context) OR a labeled list where each item has its own
# context, and the failing resource lives in exactly ONE cluster. Pick it with SCOUTFLO_TARGET; with a
# labeled list and no selector, or a selector that matches no label, list the labels and leave the live
# branch off (report-only still runs) rather than guess which cluster the resource is in.
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
KUBE_CONTEXT=""
if [ -f "$CFG" ] && [ -f "$TT" ]; then
  K8S_KIND=$(sh "$TT" "$CFG" kubernetes kind); K8S_N=$(sh "$TT" "$CFG" kubernetes count)
  if [ "${K8S_N:-0}" -ge 1 ]; then
    if [ "$K8S_KIND" = seq ] && [ "$K8S_N" -gt 1 ] && [ -z "${SCOUTFLO_TARGET:-}" ]; then
      echo "kubernetes is a labeled list ($K8S_N targets); set SCOUTFLO_TARGET=<label> for the cluster the resource lives in to probe live (report-only proceeds meanwhile):"
      sh "$TT" "$CFG" kubernetes labels | sed 's/^/  - /'
    else
      K8S_IDX=0
      if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$K8S_N" ]; do [ "$(sh "$TT" "$CFG" kubernetes label "$_i")" = "$SCOUTFLO_TARGET" ] && { K8S_IDX=$_i; break; }; _i=$((_i+1)); done; fi
      if [ "$K8S_KIND" = seq ] && [ -n "${SCOUTFLO_TARGET:-}" ] && [ "$(sh "$TT" "$CFG" kubernetes label "$K8S_IDX")" != "$SCOUTFLO_TARGET" ]; then
        echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no kubernetes target in $CFG; live probe off (report-only proceeds). Labels:"
        sh "$TT" "$CFG" kubernetes labels | sed 's/^/  - /'
      else
        KUBE_CONTEXT=$(sh "$TT" "$CFG" kubernetes get "$K8S_IDX" context)
      fi
    fi
  fi
fi
# Count local report signals, skipping the roll-up dirs (all/cost-analysis/cost/doctor) — their
# findings.json is a roll-up, not a per-resource report signal for an RCA (mirrors audit-all's guard).
REPORTS=0
if [ -d "$AUD" ]; then
  REPORTS="$(find "$AUD" -name findings.json 2>/dev/null | while IFS= read -r f; do
    case "$f" in (*/all/*|*/cost-analysis/*|*/cost/*|*/doctor/*) continue ;; esac
    echo x
  done | wc -l | tr -d ' ')"
fi
LIVE=0; if [ -n "$KUBE_CONTEXT" ] && command -v kubectl >/dev/null 2>&1; then LIVE=1; fi
# This is a local availability check only; the following live-safety gate verifies
# the independent endpoint before auth or provider reads.
if [ "$REPORTS" -eq 0 ] && [ "$LIVE" -eq 0 ]; then
  echo "no reports under $AUD and no live cluster access — run /scoutflo:audit-all (or a specific audit) first, or configure kubernetes.context so rca can probe live"; exit 1
fi
echo "doctor gate: pass (reports=${REPORTS}, live-candidate=$([ "$LIVE" -eq 1 ] && echo yes || echo no))"
```

## Live-safety gate

The shared probe helper admits only `config view` / `config get-contexts` and `auth can-i` under those command families and refuses later flags that override its pinned context, endpoint or credentials. It also refuses raw credential output. The report path is read-only over local files. The live path makes read-only calls only (`get`/`describe`/`list`/`logs`/`events`, guarded by the live-evidence lib and `ci/liveness-readonly-check.sh`) — it changes nothing. When the live branch is active, positively identify the cluster before probing, exactly as audit-kubernetes does, and pin `--context` explicitly (never the ambient kube-context — the same service name can exist in many clusters):

```bash
set -eu
# Supply the reviewed cluster endpoint independently; do not copy it from this probe.
: "${RCA_EXPECTED_SERVER:?Set the independently reviewed cluster API endpoint}"
. "${CLAUDE_PLUGIN_ROOT}/skills/rca/scripts/live-context.sh"
echo 'live-safety gate: pass — selected identity verified; read-only probes only'
```

## Evidence identity boundary

Follow [qualified service evidence](../../report-standard/service-evidence.md). Use exact account/cluster/namespace/resource identities and collection generations from current correlation inputs; a bare service name, shared private address or repeated `cluster.local` hostname is not cross-region identity. Unmappable/partial evidence stays unresolved in the answer. An [estate topology](../map-topology/references/estate-composition.md) is local context with per-source hashes and evidence tiers; configured exporter edges are candidate dependencies, not observed traffic or causes. Preserve object-store and other parallel outputs rather than assuming a single telemetry destination. Source configuration, incident records and human receipt are distinct proof steps; read current evidence before naming a cause.

## Inputs and what each contributes

| Input | Role | What rca takes from it |
| --- | --- | --- |
| Per-audit `findings.json` (`./scoutflo-audits/<target>/<date>/`) | **reference (prior)** | findings naming the target — the posture context (e.g. "no memory limit") and known symptoms, each tagged `[report@<run_date>]` with its age |
| Selected local `estate-topology.json` | **blast-radius map** | Qualified endpoints and configuration/traffic evidence tiers; original per-target exports remain unchanged |
| Live probes (`live-evidence` lib) | **evidence (current truth)** | the target's and suspects' real state now: restarts, OOM/exit codes, events, probe failures, redacted logs — tagged `[live@<now>]` |
| Current-date findings and inventories | cross-report links | Recomputed qualified cascades, overlaps and scoped coverage; shared-source targets require an independence check |
| `business_context.json` (`~/.scoutflo/`) | priority | `critical_dependencies`, `environment`, SLA — raises urgency and calibrates language |

## Phase 1: Resolve the target (identity only)

First select `RCA_TARGET` (the canonical integration/label or single-block audit target), `RCA_RUN_DATE`, and an exact `RCA_RESOURCE` affected token or finding ID. Then resolve the user's term (a pod name, service, resource id, or finding id) to two things: the tokens it appears under in findings, and the **concrete object + context to probe**. Use ONLY identity signal for this — topology `DEPLOYED_AS` (service→workload) / `PART_OF`, pod `ownerReferences` (pod→ReplicaSet→Deployment, via `probe_owner`), and current ownership metadata. A pod-name suffix alone is a candidate, never identity proof. Pin the context from `kubernetes.context` (never ambient). Report what matched and under which names. If nothing matches and there is no live handle, say so and list the closest names — never proceed on a guess. Identity edges resolve the target; they are **never** treated as a cause.

**Alert-anchored entry (optional).** When the user asks "why did *this alert* fire" (rather than naming a resource), the entry point is the fired alert: resolve it to the service/resource it scopes and to a **fire window**. Read the fire window from the alerting provider's history where the audit already reads it (e.g. Sentry issue/rule fire history, Alertmanager/Prometheus `ALERTS`, Datadog/SigNoz alert history) — best-effort and honest: if the history isn't readable, ask for or assume a window and say so. That window then drives Phase 4.5's baseline comparison. Everything downstream is identical; this only changes how the target + window are derived.

## Phase 2: Gather the report signal (reference)

Read the exact selected target/date and match `affected[]` or `id` exactly. Title or substring matches may help the operator choose a resource, but never join evidence. The local reader rejects conflicting envelope targets/dates, labels legacy directory-derived dates, and keeps each result tagged `[report@<run_date>]`. Cross-provider expansion requires the current qualified bindings used in Phase 5. Compute each report's age from its run date; if the newest is older than the freshness horizon (default **24h**, `business_context`-tunable), treat its facts as *reference, not current truth* and plan to re-probe live. This is the "where to look / what's known" layer, not the verdict.

```bash
set -eu
# Set these from the selected audit and the user's exact resource/finding, not a name search.
: "${RCA_TARGET:?Set integration/label (or the single-block target)}"
: "${RCA_RESOURCE:?Set an exact affected resource or finding ID}"
: "${RCA_RUN_DATE:?Set the selected report run date}"
sh "${CLAUDE_PLUGIN_ROOT}/skills/rca/scripts/read-evidence.sh" reports
```

## Phase 3: Topology — full blast radius + ranked suspects

Compose the selected per-target exports using [estate composition](../map-topology/references/estate-composition.md), then read the explicitly selected local `estate-topology.json` and classify each edge touching the exact target/entity by role — the fix for treating all edges as "upstream cause". Enumerate the complete attached set, then rank which to probe live.

- **Identity / resolution** — `DEPLOYED_AS` (service→workload), `PART_OF`, `ROUTES_TO` where `to` is a workload. Resolve the probe target; **never a candidate cause.**
- **Dependency** — `CALLS` (service→service), external `ServiceEntry`. Direction is load-bearing: for `A -CALLS-> B`, if the target is `A` then `B` is an **upstream SUSPECT** (a failing dependency can be the cause); if the target is `B` then `A` is **downstream BLAST RADIUS** (breaks if the target is down), never a cause.
- **Resource dependency** — the Cloud-Mode connections (`STORES_DATA_IN`, `CACHES_IN`, `PUBLISHES_TO`, `SUBSCRIBES_TO`, `CONSUMES`, `USES`, `CONFIGURED_BY`, `EXPOSED_VIA`): same direction rule as CALLS, so the target's database, cache, queue, bucket, config store, or entry LB ranks as an **upstream SUSPECT** exactly like a failing service dependency (a dead database is the classic root cause). One difference at probe time: a cloud resource is not kubectl-probable — verify a ranked resource suspect through its provider (the matching audit's read lane, provider status/events), and weigh the edge's `evidence_class`/`assertion_type` in the ranking (an observed edge outranks an asserted one).
- **Observation** — `MONITORED_BY` / `SENDS_METRICS_TO|LOGS_TO|TRACES_TO`. Tells you which backend holds the target's signal; a missing observation edge means this map has no observed binding. It proves neither absent monitoring nor failed paging; collect the source rule, route and receipt evidence.

Build a ranked upstream-suspect list (edge `confidence` × observed-vs-asserted × whether a finding already names the neighbor × business-criticality × hop-proximity). Treat the saved topology and its source-generation hashes as a possibly-stale **hypothesis source** (tag `[topology@<generated_at>]`): it says *where to look*; the live probe confirms or exonerates. State plainly "topology may be incomplete; only topology-named suspects were probed" so a missing edge is never read as exoneration.

```bash
set -eu
: "${RCA_TARGET:?Set the canonical selected target}"
: "${RCA_RESOURCE:?Set the exact topology entity name}"
: "${RCA_RUN_DATE:?Set the selected map date}"
: "${RCA_TOPOLOGY:?Set the selected estate-topology.json path}"
# If a service and resource share this name, set RCA_ENTITY_TYPE=service or resource.
sh "${CLAUDE_PLUGIN_ROOT}/skills/rca/scripts/read-evidence.sh" topology
```

## Phase 4: Live verification — the actual RCA (read-only)

If the doctor live branch is up, this is where the cause is established. Probe the resolved **target** first, then the **top-ranked suspects** from Phase 3 (start with the highest-ranked few; go deeper while the incident is unexplained — do not stop at an arbitrary cap, but pause via the shared scope checkpoint before a wide fan-out on a large graph). Apply the failure taxonomy: name a cause only when its specific field is present; a null/blocked probe is a gap.

```bash
set -eu
: "${RCA_NAMESPACE:?Set the resolved namespace}"
: "${RCA_POD:?Set the exact resolved pod name}"
# Re-resolve and verify context/endpoint in this fresh shell; no inherited connection.
. "${CLAUDE_PLUGIN_ROOT}/skills/rca/scripts/live-context.sh"
KUBE_CONTEXT="${KUBE_CONTEXT:?The fresh context gate must return one verified context}"
probe_pod_status "$KUBE_CONTEXT" "$RCA_NAMESPACE" "$RCA_POD"
probe_events "$KUBE_CONTEXT" "$RCA_NAMESPACE" "$RCA_POD"
probe_logs_previous "$KUBE_CONTEXT" "$RCA_NAMESPACE" "$RCA_POD" "" 50
# Repeat only for the next specifically resolved suspect; report any denied probe as unknown.
```

Tag every observation `[live@<now>]`. When a live result contradicts a report (e.g. report said 0 restarts, live shows 42), **live wins** and the delta is stated — it is high-value output. The exact fields and the taxonomy (CrashLoopBackOff+terminated reason, OOMKilled/137, ImagePullBackOff, Unhealthy probe, Pending/Unschedulable, benign-rollout) are in [live-evidence/references/k8s-liveness-probes.md](../live-evidence/references/k8s-liveness-probes.md).

## Phase 4.5: Temporal delta on the telemetry backends (what moved, and before what)

All collection defaults below are operator-tunable: signal count, baseline age/duration, fallback days, window buffer, epsilon floor and display clamp. Record selected values and units, retain unclamped values in evidence, and label baseline comparability. No default threshold establishes a cause.

Phase 4 establishes the target's *state* (OOMKilled, CrashLoop). This phase answers the question the confidence rubric prizes most but Phase 4 cannot produce: **which neighbor signal moved, by how much, and did it move *before* the symptom** — the single strongest discriminator between a cause and a coincidence. It compares a fire window to a baseline window on whatever metrics/traces backend already holds each service's signal, so it is **cross-provider** by construction (Prometheus / LGTM / SigNoz / ClickStack / Datadog — whichever the topology observation edges point at).

- **Pick the backend from the topology, not a guess.** For the target and each top-ranked upstream suspect from Phase 3, read the `SENDS_METRICS_TO` / `MONITORED_BY` observation edge to find which backend holds its RED/USE signals, and reuse that provider's existing read path (the same queries `audit-prometheus` / `audit-lgtm` / `audit-signoz` / `audit-datadog` / `audit-newrelic` (NRQL over `Metric`/`Span` via NerdGraph, plus each entity's ready-made `goldenMetrics` queries) already document — do not invent a new query engine). If no observation edge names a backend, say so and skip this phase for that suspect (an honest gap, never a guess).
- **The neighbor signals to pull** (by resource scope) are in [references/neighbor-signals.md](references/neighbor-signals.md): service scope → error rate, p95/p99 latency, request throughput, dependency error rate; host scope → CPU / memory / disk-io / network / load; k8s scope → pod restarts (surface first — crash loops dominate), CPU-vs-limit (throttling), memory-vs-limit (OOM), node pressure, recent rollout. Cap at ~6 signals per suspect to stay bounded.
- **Baseline = same hour, previous day** (`fire_start − 24h`, same duration), with a **7-day same-time-of-day median fallback** when the prior-day window overlaps another incident of the same signal or a deploy landed within 24h of it (a contaminated baseline is worse than none — flag and fall back). Compute `delta_pct = (fire − baseline) / max(baseline, epsilon) × 100`, `epsilon = max(baseline × 0.01, a small floor)`; use the fire-window **peak** for an "above" symptom / **trough** for a "below" one, and the baseline **mean**; add a ±5-minute lead-in/cool-down buffer to both windows; clamp displayed deltas at ±10000%. Rank suspects by absolute delta.
- **Two tunable fan-out heuristics (defaults: 10% marginal breach, one evaluation window, 25% neighbor movement):** Record the selected thresholds and window before using them; they bound collection and never establish a cause. Sparse, missing, incomparable or zero-baseline data disables an absence conclusion.
  - **Marginal-fire gate:** if the anchoring signal's breach is `< 10%` over its threshold **and** lasted `< 1` evaluation window, offer to narrow further collection and label threshold sensitivity as a hypothesis. A small breach can still be a real customer incident; do not recommend tuning without reviewing the declared objective and duration.
  - **Isolated-signal gate:** if **no** neighbor signal moves `≥ 25%` vs baseline, and every selected neighbor read is comparable and complete, report only *"no movement above the selected threshold in the observed neighbor signals."* Unobserved dependencies and smaller but causal changes remain possible; choose the next probe from the unresolved evidence.
- **Feed the deltas into the confidence rubric, never fabricate one.** A delta is emitted **only** from a real backend read, carries a new provenance tag `[delta@<now>]`, and supplies the rubric's *temporal-precedence* and *correlated-metric-evidence* signals. A missing or unreachable backend is an honest gap (`verdict=unknown`), never read as "flat/healthy". A signal that moved *with* the symptom but with no temporal ordering is labelled a **co-occurring signal**, never ranked as the cause. When no backend is reachable at all, skip this phase and say so — the report-only path (Phase 4's `else` branch) still stands.

## Phase 5: Walk the correlation chains (cascades + overlap agreement)

Recompute both candidate sets in memory from the exact selected report date using the shared correlation functions; do not trust an older global `correlation.json`. Use both halves: the `cascades` connect the target to cause→effect chains the single-report view can't see, and the `overlaps` (`OVL-*` groups) say whether **two or more qualified audit targets flagged the same verified service identity** — multi-stack agreement that corroborates the trouble is real.

```bash
set -eu
: "${RCA_TARGET:?Set the canonical selected target}"
: "${RCA_RESOURCE:?Set the exact affected resource or finding ID}"
: "${RCA_RUN_DATE:?Set the selected report run date}"
sh "${CLAUDE_PLUGIN_ROOT}/skills/rca/scripts/read-evidence.sh" correlation
```

How overlap agreement is weighed — supporting evidence only, never a cause:

- **Cite it.** Each matched group goes into the Phase 7 Evidence list with a `[correlation]` tag: `[correlation] OVL-checkout: 2 audits independently flagged checkout: clickstack/TOPO-001 (info), lgtm/LGTM-035 (high)`.
- **Agreement raises confidence — bounded.** Distinct audit targets can consume the same source path, so target count alone is not independent corroboration. After checking source independence, a group with ≥2 distinct targets whose member findings support the cause already established by Phases 2–4 may raise confidence at most one step (low→medium, medium→high). An overlap says "flagged by many", never "why" — it can never substitute for the report/probe evidence that names the cause.
- **Weigh the members, not the raw count.** A member finding that names most of the estate (e.g. an info-severity "no service declares telemetry connections" finding that attaches to every group) is weak corroboration; what matters is the number of distinct audits (`targets | length`) and the member severities.
- **Absence changes nothing.** No overlap group naming the target neither lowers confidence nor exonerates anything — a single-audit finding is often the only coverage a service has.
- **Never invent.** Cite only `overlap_id`s and `finding_id`s returned by this target/date-qualified reader. A finding ID is still scoped to its audit target; the first same-named finding in a global file is not a valid fallback.

## Phase 5.5: Cross-tool coverage reframe

The local reader recomputes `coverage[]` from current-generation findings and other providers' `inventory.json` for the selected report date: when a **coverage gap** on the target service is actually covered by an **active, routed monitor in another tool**, it is classified `covered-elsewhere`. It is configuration evidence, not proof of paging or human receipt; preserve its recommendation and assessment scope verbatim.

```bash
set -eu
: "${RCA_TARGET:?Set the canonical selected target}"
: "${RCA_RESOURCE:?Set the exact affected resource or finding ID}"
: "${RCA_RUN_DATE:?Set the selected report run date}"
sh "${CLAUDE_PLUGIN_ROOT}/skills/rca/scripts/read-evidence.sh" coverage
```

How it weighs:

- **`covered-elsewhere` reframes, it does not exonerate.** When the target's finding is a coverage gap and `coverage[]` shows another provider has a current, enabled, routed monitor for its verified identity, cite it with a `[coverage]` tag and reframe the RCA from "no coverage" to **single-tool dependency** — "Azure-native alerting is absent on `checkout`, but Datadog monitor `checkout latency` is configured for that identity and routes to PagerDuty; signal parity and delivery still need verification `[coverage]`". This may raise confidence at most one step (mirroring the bounded overlap rule), and only when the covering monitor plausibly watches the failing signal — say so as a caveat.
- **`true-gap` means no matching coverage was observed within the explicitly declared, completely assessed targets.** Carry that boundary and the missing signal into the answer. It is never a claim that nothing in the customer estate covers it. All coverage output is advisory and leaves the source score/severity unchanged.
- **`unmappable` preserves uncertainty.** Missing identity, unknown activation, unreadable inputs and incomplete target collection are evidence gaps. Retain the returned reason; never turn them into absent coverage.
- **Never invent a covering monitor** not present in `coverage[]`.

## Phase 6: Weigh by business context

Read `~/.scoutflo/business_context.json`. If the target or a downstream neighbor is in `critical_dependencies`, lead with that (the blast radius hits something the business cares about). Use `environment` to calibrate severity language (a staging-only chain is real but not an incident). Never invent criticality the context doesn't state.

## Phase 7: Assemble the evidence-cited RCA

Open with a one-line **mode banner** so freshness is unmissable: `[live-verified @ <now>]` or `[report-only, as of <date>]`. Every factual clause carries its provenance tag. Confidence is a joint function of source **and** recency, on an explicit bar: **`high`** requires **≥2 of** {temporal precedence (a `[delta@]` shows the suspect moved *before* the symptom), a topology/dependency edge, a shared entity/service, correlated metric+log+state evidence, a recent deploy/config change}; **`medium`** = one tier's evidence plus ≥1 of those; **`low`** = a single uncorroborated signal — label it a **co-occurring signal**, not a cause. Multi-audit overlap agreement (Phase 5) adjusts this at most one step upward when consistent with the cause; its absence changes nothing. If nothing reaches `medium`, the lead line is "No clear root cause found," never a low-confidence guess dressed up as the answer.

```markdown
## RCA: <target> — <one-line verdict>   [live-verified @ <ts> | report-only, as of <date>]

**TL;DR:** <1–2 sentences an on-call reads first: leading hypothesis + confidence + blast radius + the single most useful next action (name the concrete handle — a pod, a trace, a finding-id).>

**Most likely root cause (confidence: high | medium | low):**
<1–3 sentences, each clause tagged [live@ts] / [delta@ts] / [report@date] / [topology@gen] / [correlation] / [coverage] / [hypothesis]>

**Investigation trail:** <a scannable list of what was checked, ✅ confirmed / ❌ ruled out, one line each — so the reader sees the work done and what was eliminated, e.g. "✅ [delta] payments error-rate +8900% vs baseline, 90s before checkout restarts; ❌ CPU/memory flat through the window; ✅ [live] checkout OOMKilled ×4">


**How it fails (the chain):** <root → effect walk, each step cited>

**Blast radius (who else is affected):** <downstream services from dependency edges only, business-critical ones flagged; "unknown — no topology" if absent>

**Evidence:**
- [live@ts] <probe result, e.g. "app container OOMKilled exitCode 137, 4 restarts/20m">
- [delta@ts] <fire-vs-baseline neighbor-signal move that supports the cause, e.g. "payments dependency error-rate +8900% vs same-hour-yesterday, p99 +1180%, first rose 90s before checkout's restarts (temporal precedence)"; omit when no backend was reachable — never fabricate a delta>
- [report@date] <finding-id: title (provider, severity)>
- [topology@gen] <edge, confidence n, observed/asserted>
- [correlation] <OVL-id: N qualified audit targets flagged <service>; source independence <verified/unknown>: <target>/<finding-id> (<severity>), …  — omit when no overlap group names the target>
- [coverage] <covered-elsewhere: <provider>:<monitor>→<receiver> has a configured path for <qualified service> — reframes a "no alerting" gap as single-tool dependency; omit when no coverage record names the target, preserve the assessed-target boundary for a true-gap>

**What I could NOT determine (do this to confirm):**
<explicit gaps: blocked probes, suspects not reached, stale reports not re-probed; if signal was thin, say the cause is a hypothesis, not established>

**Recommended next step:** <highest-value action — a setup-* fix (with anchor) or the next probe/audit — ordered by business criticality>
```

If neither reports, topology, correlation, nor live probes yield a cause: do **not** synthesize one. Emit the "insufficient signal" form — what was searched, what was probed and found clean, and exactly what to collect next.

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Inventing a cause with no report/edge/probe behind it | Every clause cites evidence with a provenance tag; no citation → labelled hypothesis or a stated gap, never a fact |
| Treating an identity edge as a cause (`DEPLOYED_AS`) | Identity edges (DEPLOYED_AS/PART_OF/ROUTES_TO) only *resolve* the target; only dependency edges (CALLS/ServiceEntry) generate suspects |
| Edge-direction inversion (blaming blast radius, exonerating the real upstream) | Direction is load-bearing: for A-CALLS->B, B is the suspect when target==A, A is downstream when target==B |
| Reading a null / blocked / RBAC-denied probe as "healthy" | A failed probe is a gap with verdict=unknown and a stated next step, never a pass |
| Naming a cause from a benign symptom (restarts during a rollout) | A taxonomy branch requires its specific observed field (terminated reason/exit code, event); restartCount alone is a symptom |
| Trusting the ambient kube-context | Every live call pins `--context` from `kubernetes.context`; the live-safety gate prints server+context to confirm the cluster |
| Presenting a stale report as current | Tag every fact with its date; if the live branch is up, re-probe and prefer live, stating the delta; if down, lower confidence and list a live re-probe as the top gap |
| Topology staleness masking a real dependency | Topology is a hypothesis source; the live probe confirms; rca states "topology may be incomplete; only topology-named suspects were probed" |
| Reading overlap agreement as a cause, or its absence as exoneration | `OVL-*` groups are supporting evidence only: multi-audit agreement raises confidence in an already-evidenced cause at most one step; no overlap changes nothing; an estate-wide member finding is weak corroboration |
| Leaking a secret via `logs --previous` | Log slices pass through the redaction filter, are `--tail` capped, and are never written raw to a report or brief |

## Maturity note (v0.1.101)

rca is now **live-first**: reports are reference, topology is the blast-radius map, and read-only live probes are the evidence. It is live-provable end to end on a Kubernetes workload (the pod-down case: OOMKilled/CrashLoopBackOff/ImagePull/Unschedulable, correlated with posture findings). The offline `[report-only, as of <date>]` path is preserved for cloud surfaces and no-credential runs. Non-k8s providers currently use the report + topology path; their live probes land in later phases via the same shared `live-evidence` library and the identical never-invent, read-only, provenance-tagged discipline.

---

**v0.1.101** — rca becomes live-first: uses reports as reference + topology as the blast-radius map, then makes strictly read-only live calls (via the shared `live-evidence` lib) to confirm the current cause. Edge semantics fixed (identity vs dependency vs observation); every fact tagged `[report@date]`/`[live@now]`; degrades to report-only without cluster access; never invents a cause.
