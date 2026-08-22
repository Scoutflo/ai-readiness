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
- ✅ `Most likely root cause (confidence: high): pod checkout-abc's app container was OOMKilled (exitCode 137) 4 times in 20m [live@2026-08-14T09:12Z], and K8S-004 says its Deployment has no memory limit [report@2026-08-10]; the container exceeds the node default and is killed. Blast radius: orders-api CALLS checkout (topology, conf 9, observed).`

## Doctor gate

rca needs `jq` and **either** local reports **or** live cluster access. It sources the home-anchored secret store (so any provider token needed for a non-k8s probe is seen) and the shared read-only live-evidence library, then decides which mode is available. It never blocks on the live branch — a live miss simply routes to report-only.

```bash
set -eu
command -v jq >/dev/null || { echo "missing binary: jq"; exit 1; }
# Source the secret store the same way doctor/audits do (degrade, never abort).
SCOUTFLO_ENV="${HOME}/.scoutflo/env"
if [ -f "$SCOUTFLO_ENV" ]; then set +eu; . "$SCOUTFLO_ENV" || echo "rca: warning: could not source $SCOUTFLO_ENV"; set -eu; fi
# Redaction + live-evidence libraries (read-only; the live path is guarded there).
. "${CLAUDE_PLUGIN_ROOT}/skills/redaction/lib/redaction.sh" 2>/dev/null || true
. "${CLAUDE_PLUGIN_ROOT}/skills/live-evidence/lib/live-evidence.sh"
AUD="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || { if [ -f "./.scoutflo/toolkit.yaml" ]; then CFG="./.scoutflo/toolkit.yaml"; else CFG="$HOME/.scoutflo/toolkit.yaml"; fi; }
KUBE_CONTEXT="$(sed -n 's/^[[:space:]]*context:[[:space:]]*//p' "$CFG" 2>/dev/null | head -1)"
REPORTS=0; [ -d "$AUD" ] && REPORTS="$(find "$AUD" -name findings.json 2>/dev/null | wc -l | tr -d ' ')"
LIVE=0; le_can_probe "$KUBE_CONTEXT" >/dev/null 2>&1 && LIVE=1
if [ "$REPORTS" -eq 0 ] && [ "$LIVE" -eq 0 ]; then
  echo "no reports under $AUD and no live cluster access — run /scoutflo:audit-all (or a specific audit) first, or configure kubernetes.context so rca can probe live"; exit 1
fi
echo "doctor gate: pass (reports=${REPORTS}, live=$([ "$LIVE" -eq 1 ] && echo yes || echo no))"
```

## Live-safety gate

The report path is read-only over local files. The live path makes read-only calls only (`get`/`describe`/`list`/`logs`/`events`, guarded by the live-evidence lib and `ci/liveness-readonly-check.sh`) — it changes nothing. When the live branch is active, positively identify the cluster before probing, exactly as audit-kubernetes does, and pin `--context` explicitly (never the ambient kube-context — the same service name can exist in many clusters):

```bash
set -eu
KUBE_CONTEXT="my-cluster"   # kubernetes.context (the doctor gate confirmed live access; report-only mode skips this block)
SERVER="$(kubectl --context "$KUBE_CONTEXT" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
VER="$(kubectl --context "$KUBE_CONTEXT" version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // "unknown"')"
echo "live target: context=${KUBE_CONTEXT} server=${SERVER} k8s=${VER}"
echo "live-safety gate: pass — read-only probes only; confirm this is the cluster the target lives in"
```

## Inputs and what each contributes

| Input | Role | What rca takes from it |
| --- | --- | --- |
| Per-audit `findings.json` (`./scoutflo-audits/<target>/<date>/`) | **reference (prior)** | findings naming the target — the posture context (e.g. "no memory limit") and known symptoms, each tagged `[report@<run_date>]` with its age |
| `topology-export.json` | **blast-radius map** | `relationships[]` classified into identity / dependency / observation edges — the full attached set, who to probe, and who breaks downstream |
| Live probes (`live-evidence` lib) | **evidence (current truth)** | the target's and suspects' real state now: restarts, OOM/exit codes, events, probe failures, redacted logs — tagged `[live@<now>]` |
| `correlation.json` | cross-report links | precomputed `cascades` (`root_cause`→`effects`) + `overlaps` (`OVL-*`: the same service flagged by ≥2 audits — independent multi-stack agreement) |
| `business_context.json` (`~/.scoutflo/`) | priority | `critical_dependencies`, `environment`, SLA — raises urgency and calibrates language |

## Phase 1: Resolve the target (identity only)

Resolve the user's term (a pod name, service, resource id, or finding id) to two things: the tokens it appears under in findings, and the **concrete object + context to probe**. Use ONLY identity signal for this — topology `DEPLOYED_AS` (service→workload) / `PART_OF`, pod `ownerReferences` (pod→ReplicaSet→Deployment, via `probe_owner`), and the pod-name hash suffix. Pin the context from `kubernetes.context` (never ambient). Report what matched and under which names. If nothing matches and there is no live handle, say so and list the closest names — never proceed on a guess. Identity edges resolve the target; they are **never** treated as a cause.

## Phase 2: Gather the report signal (reference)

Assemble every finding whose `affected[]`/`title`/`id` names the target, grouped by provider, each tagged `[report@<run_date>]`. Compute each report's age from its run date; if the newest is older than the freshness horizon (default **24h**, `business_context`-tunable), treat its facts as *reference, not current truth* and plan to re-probe live. This is the "where to look / what's known" layer, not the verdict.

```bash
set -eu
AUD="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
TARGET="checkout"   # the resource/service/finding-id the user asked about
find "$AUD" -name findings.json 2>/dev/null | while read -r f; do
  jq -r --arg t "$TARGET" '.findings[]
    | select(( ((.affected // []) | join(" ")) + " " + (.title // "") + " " + (.id // "") ) | test($t; "i"))
    | "\(.id)\t\(.severity)\t\(.area)\t\(.title)"' "$f" 2>/dev/null \
    | sed "s#^#$(basename "$(dirname "$(dirname "$f")")")\t#"
done
```

## Phase 3: Topology — full blast radius + ranked suspects

Read `topology-export.json` and classify **every** edge touching the target by role — the fix for treating all edges as "upstream cause". Enumerate the complete attached set, then rank which to probe live.

- **Identity / resolution** — `DEPLOYED_AS` (service→workload), `PART_OF`, `ROUTES_TO` where `to` is a workload. Resolve the probe target; **never a candidate cause.**
- **Dependency** — `CALLS` (service→service), external `ServiceEntry`. Direction is load-bearing: for `A -CALLS-> B`, if the target is `A` then `B` is an **upstream SUSPECT** (a failing dependency can be the cause); if the target is `B` then `A` is **downstream BLAST RADIUS** (breaks if the target is down), never a cause.
- **Observation** — `MONITORED_BY` / `SENDS_METRICS_TO|LOGS_TO|TRACES_TO`. Tells you which backend holds the target's signal; a **missing** observation edge is itself a root-cause-class answer ("a crash here would have paged no one").

Build a ranked upstream-suspect list (edge `confidence` × observed-vs-asserted × whether a finding already names the neighbor × business-criticality × hop-proximity). Treat `topology-export.json` as a possibly-stale **hypothesis source** (tag `[topology@<generated_at>]`): it says *where to look*; the live probe confirms or exonerates. State plainly "topology may be incomplete; only topology-named suspects were probed" so a missing edge is never read as exoneration.

```bash
set -eu
AUD="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
TOPO="$AUD/topology-export.json"; TARGET="checkout"
[ -f "$TOPO" ] || { echo "no topology-export.json — attached set unknown; run /scoutflo:map-topology. Probing the named target only."; exit 0; }
# Normalize both real shapes (nested relationships[] and generated edges[]) to {from,to,rel,conf},
# then classify by role so identity edges resolve and only dependency edges generate suspects.
jq -r --arg t "$TARGET" '
  (( .relationships // [] ) | map({from: .from.name, to: .to.name, rel: .relation, conf: (.confidence // "?")}))
  + (( .edges // [] )       | map({from: .from,      to: .to,      rel: .type,     conf: (.confidence // "?")}))
  | .[] | select(.from == $t or .to == $t)
  | (if   (.rel|test("DEPLOYED_AS|PART_OF"))                 then "identity   "
     elif (.rel|test("CALLS|ROUTES_TO|ServiceEntry"))        then (if .from==$t then "suspect(up)" else "blast(down)" end)
     elif (.rel|test("MONITORED_BY|SENDS_"))                 then "observation"
     else "other      " end) as $role
  | "\($role)\t\(.from) -\(.rel)-> \(.to)  (conf \(.conf))"' "$TOPO" | sort
```

## Phase 4: Live verification — the actual RCA (read-only)

If the doctor live branch is up, this is where the cause is established. Probe the resolved **target** first, then the **top-ranked suspects** from Phase 3 (start with the highest-ranked few; go deeper while the incident is unexplained — do not stop at an arbitrary cap, but pause via the shared scope checkpoint before a wide fan-out on a large graph). Apply the failure taxonomy: name a cause only when its specific field is present; a null/blocked probe is a gap.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/redaction/lib/redaction.sh" 2>/dev/null || true
. "${CLAUDE_PLUGIN_ROOT}/skills/live-evidence/lib/live-evidence.sh"
KUBE_CONTEXT="my-cluster"   # kubernetes.context, resolved in the doctor gate
NS="platform"; POD="checkout-abc"     # resolved in Phase 1
if le_can_probe "$KUBE_CONTEXT" >/dev/null 2>&1; then
  probe_pod_status "$KUBE_CONTEXT" "$NS" "$POD"                # phase, restartCount, waiting/terminated reason+exitCode
  probe_events     "$KUBE_CONTEXT" "$NS" "$POD"                # FailedScheduling/BackOff/Unhealthy/Failed
  probe_logs_previous "$KUBE_CONTEXT" "$NS" "$POD" "" 50       # dead container's last logs, redacted + capped
  # then, for each ranked upstream suspect workload, the same probes (bounded, highest-rank first)
else
  echo "[live] no cluster access for context '$KUBE_CONTEXT' — report-only mode; live confirmation deferred"
fi
```

Tag every observation `[live@<now>]`. When a live result contradicts a report (e.g. report said 0 restarts, live shows 42), **live wins** and the delta is stated — it is high-value output. The exact fields and the taxonomy (CrashLoopBackOff+terminated reason, OOMKilled/137, ImagePullBackOff, Unhealthy probe, Pending/Unschedulable, benign-rollout) are in [live-evidence/references/k8s-liveness-probes.md](../live-evidence/references/k8s-liveness-probes.md).

## Phase 5: Walk the correlation chains (cascades + overlap agreement)

If `correlation.json` exists, use both halves of it: the `cascades` connect the target to cause→effect chains the single-report view can't see, and the `overlaps` (`OVL-*` groups) say whether **two or more audits independently flagged the target service** — multi-stack agreement that corroborates the trouble is real.

```bash
set -eu
AUD="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"; CORR="$AUD/correlation.json"; TARGET="checkout"
[ -f "$CORR" ] || { echo "no correlation.json — correlating findings directly by shared resource; cascades and overlap groups not precomputed"; exit 0; }
jq -r --arg t "$TARGET" '
  (.cascades // [])[]
  # Parenthesize the root-string test so the `|` stays LOCAL to that clause. Without
  # the extra parens `|` binds looser than `or`, so `.` inside any(.effects[]?; …)
  # would be the concatenated STRING (indexing a string with "effects" → crash),
  # breaking the "target is an effect" case.
  | select( ( ( .root_cause.title + " " + ((.root_cause.shared_resources // []) | join(" ")) ) | test($t;"i") )
            or (any(.effects[]?; .title | test($t;"i"))) )
  | "ROOT: \(.root_cause.finding_id) \(.root_cause.title)\n  EFFECTS: \([.effects[]? | "\(.finding_id) \(.title)"] | join(" | "))"' "$CORR"
# Overlap agreement: did two or more audits independently flag the target service?
# (Same loose test($t;"i") match as the rest of the skill; each group prints its
# own service name so a prefix hit like cart→valkey-cart is visible, not silent.)
jq -r --arg t "$TARGET" '
  (.overlaps // [])
  | map(select(.service | test($t; "i")))
  | if length == 0 then
      "no overlap group names \($t) — single-stack signal only; this changes nothing"
    else
      .[] | "OVERLAP \(.overlap_id): \(.targets | length) audits independently flagged \(.service): "
            + ([.findings[] | "\(.target)/\(.finding_id) (\(.severity))"] | join(", "))
    end' "$CORR"
```

How overlap agreement is weighed — supporting evidence only, never a cause:

- **Cite it.** Each matched group goes into the Phase 7 Evidence list with a `[correlation]` tag: `[correlation] OVL-checkout: 2 audits independently flagged checkout: clickstack/TOPO-001 (info), lgtm/LGTM-035 (high)`.
- **Agreement raises confidence — bounded.** Independent audits see the estate from different vantage points, so a group with ≥2 distinct `targets` whose member findings are *consistent with the cause already established by Phases 2–4* raises the RCA confidence at most one step (low→medium, medium→high). An overlap says "flagged by many", never "why" — it can never substitute for the report/probe evidence that names the cause.
- **Weigh the members, not the raw count.** A member finding that names most of the estate (e.g. an info-severity "no service declares telemetry connections" finding that attaches to every group) is weak corroboration; what matters is the number of distinct audits (`targets | length`) and the member severities.
- **Absence changes nothing.** No overlap group naming the target neither lowers confidence nor exonerates anything — a single-audit finding is often the only coverage a service has.
- **Never invent.** Cite only `overlap_id`s and `finding_id`s actually present in `correlation.json`. If you enter this phase holding a finding id instead of a service name, the correlation-engine library exposes the same lookup keyed on finding id: source `skills/correlation-engine/lib/correlation-engine.sh` and call `correlation_find_related <finding-id>` to get the first overlap group containing that finding.

## Phase 6: Weigh by business context

Read `~/.scoutflo/business_context.json`. If the target or a downstream neighbor is in `critical_dependencies`, lead with that (the blast radius hits something the business cares about). Use `environment` to calibrate severity language (a staging-only chain is real but not an incident). Never invent criticality the context doesn't state.

## Phase 7: Assemble the evidence-cited RCA

Open with a one-line **mode banner** so freshness is unmissable: `[live-verified @ <now>]` or `[report-only, as of <date>]`. Every factual clause carries its provenance tag. Confidence is a joint function of source **and** recency: a live-confirmed cause matching a report finding is highest; a report-only inference on a stale report is low. Multi-audit overlap agreement (Phase 5) adjusts this at most one step upward when consistent with the cause; its absence changes nothing.

```markdown
## RCA: <target> — <one-line verdict>   [live-verified @ <ts> | report-only, as of <date>]

**Most likely root cause (confidence: high | medium | low):**
<1–3 sentences, each clause tagged [live@ts] / [report@date] / [topology@gen] / [correlation] / [hypothesis]>

**How it fails (the chain):** <root → effect walk, each step cited>

**Blast radius (who else is affected):** <downstream services from dependency edges only, business-critical ones flagged; "unknown — no topology" if absent>

**Evidence:**
- [live@ts] <probe result, e.g. "app container OOMKilled exitCode 137, 4 restarts/20m">
- [report@date] <finding-id: title (provider, severity)>
- [topology@gen] <edge, confidence n, observed/asserted>
- [correlation] <OVL-id: N audits independently flagged <service>: <target>/<finding-id> (<severity>), …  — omit when no overlap group names the target>

**What I could NOT determine (do this to confirm):**
<explicit gaps: blocked probes, suspects not reached, stale reports not re-probed; if signal was thin, say the cause is a hypothesis, not established>

**Recommended next step:** <highest-value action — a setup-* fix (with anchor) or the next probe/audit — ordered by business criticality>
```

If neither reports, topology, correlation, nor live probes yield a cause: do **not** synthesize one. Emit the "insufficient signal" form — what was searched, what was probed and found clean, and exactly what to collect next.

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Inventing a cause with no report/edge/probe behind it | Every clause cites evidence with a provenance tag; no citation → labelled hypothesis or a stated gap, never a fact |
| Treating an identity edge as a cause (`DEPLOYED_AS`) | Identity edges (DEPLOYED_AS/PART_OF) only *resolve* the target; only dependency edges (CALLS/ROUTES_TO) generate suspects |
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
