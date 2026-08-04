---
name: rca
description: Answer "why is <resource/service> failing / at risk — give me the RCA" by correlating across every Scoutflo audit report, the service topology, and business context, and return an evidence-cited root-cause analysis with a confidence level and an explicit list of what could not be determined. Read-only; it reasons over findings.json, correlation.json, topology-export.json, and business_context.json that audits already produced — it never calls a provider and never invents a cause. Use when the user asks why something is failing/degraded/at risk, asks for an RCA or root cause, or asks what a finding's blast radius or upstream cause is. Do not use to run a fresh audit (use audit-* / audit-all first to produce the reports this reads), to change anything (this is analysis only), or to invent a cause when the evidence is thin (it says so instead).
---

# rca — evidence-grounded root-cause analysis across your reports

When someone asks *"why is EC2 `web-3` failing — give me the RCA?"*, this skill turns that question into a grounded answer built from what the Scoutflo audits already found: every finding that names that resource across all providers, the service graph around it (who it calls, who calls it, what monitors it), the correlation engine's cause→effect chains, and which services your business context says are critical. It returns a root-cause analysis where **every claim cites the finding, report, or topology edge it came from**, carries a **confidence level**, and ends with an explicit **"what I could not determine"** — because a confident-but-wrong root cause is worse than an honest "the signal points here, but X is unconfirmed."

**It reasons over existing artifacts; it does not audit.** It reads the `findings.json`, `correlation.json`, `topology-export.json`, and `business_context.json` that prior audit runs produced. If those don't exist for the resource in question, it says exactly which audit to run first rather than guessing. It never calls a live provider and never changes anything.

## The one hard rule: never invent a cause

The RCA is assembled **only** from evidence present in the reports and topology. A hypothesis with no supporting finding or edge is labelled a hypothesis, not a cause, and only offered when it is the natural next thing to check — never stated as fact. If the evidence is too thin to name a root cause, the answer is *"insufficient signal — here is what's known and here is exactly what to collect next,"* not a fabricated chain. This is the same discipline the toolkit enforces on scores (`check-findings.sh`) and dollars (`check-cost.sh`): an unverified answer is worse than an honest gap, because an RCA gets acted on in an incident.

- ❌ `Root cause: the RDS failover misfired and cascaded to checkout.` (no finding or edge establishes a failover event)
- ✅ `Most likely root cause (confidence: medium): checkout has no alert coverage (GRAF-091, DD-033) AND its datastore payments-db has no backup (AWS-030); an incident on payments-db would go undetected. Not confirmed: whether payments-db is currently unhealthy — no live health signal is in these reports; run /scoutflo:audit-aws to confirm the datastore's current state.`

## Doctor gate

This skill needs only local artifacts and `jq`; it makes no provider calls, so there is no credential to check. It stops only if the reports it needs are absent.

```bash
set -eu
command -v jq >/dev/null || { echo "missing binary: jq"; exit 1; }
AUD="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
[ -d "$AUD" ] || { echo "no ./scoutflo-audits yet — run /scoutflo:audit-all (or a specific audit-*) first so there are findings to analyze"; exit 1; }
n="$(find "$AUD" -name findings.json 2>/dev/null | wc -l | tr -d ' ')"
[ "$n" -gt 0 ] || { echo "no findings.json under $AUD — run an audit first; this skill analyzes existing reports, it does not audit"; exit 1; }
echo "doctor gate: pass ($n report file(s) available to correlate)"
```

## Live-safety gate

There is nothing live to be unsafe with — this skill is strictly read-only over local files. State it, so a reader is never unsure:

```bash
set -eu
echo "rca reads local report artifacts only (findings.json / correlation.json / topology-export.json / business_context.json)."
echo "It calls no provider, changes nothing, and produces an analysis — not an action."
echo "live-safety gate: pass (read-only analysis)"
```

## Inputs it reads (and what each contributes)

| Artifact | Where | What RCA takes from it |
| --- | --- | --- |
| Per-audit `findings.json` | `./scoutflo-audits/<target>/<date>/findings.json` (and `kubernetes/<ctx>/<date>/`) | every finding whose `affected[]` or `title` names the target — the direct symptoms, across all providers |
| `correlation.json` | `./scoutflo-audits/correlation.json` | `overlaps` (same service flagged by multiple stacks) and `cascades` (`root_cause` → `effects` chains) — the cross-report causal links |
| `topology-export.json` | `./scoutflo-audits/topology-export.json` | the service graph: `relationships[]` (`CALLS`, `ROUTES_TO`, `DEPLOYED_AS`, `MONITORED_BY`, `PART_OF`) with `confidence` — who depends on the target and what observes it |
| `business_context.json` | `~/.scoutflo/business_context.json` | `critical_dependencies`, `environment`, per-service SLA — whether the target (or a neighbor) is business-critical, which raises the RCA's priority and changes the recommended response |

Each input is optional and the analysis degrades honestly: no topology → RCA says "dependency graph unavailable, run /scoutflo:map-topology for blast-radius"; no correlation.json → it correlates findings directly by shared `affected` and says cascades weren't precomputed.

## Phase 1: Resolve the target

Take the resource/service the user named (an id like `i-0abc…`, a name like `web-3`, a service like `checkout`, or a finding id like `AWS-030`) and resolve it to the tokens it appears under. Search all findings for that string in `affected[]`, `title`, and `id`; search topology `services[].name`/`resources[].name`. Report what matched and under which names (a resource often appears as an id in AWS findings and a service name in topology). If nothing matches, say so and list the closest names found — never proceed on a guess about which resource was meant.

```bash
set -eu
AUD="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
TARGET="web-3"   # the resource/service/finding-id the user asked about
# Every finding that names the target, across every provider report:
find "$AUD" -name findings.json 2>/dev/null | while read -r f; do
  jq -r --arg t "$TARGET" '.findings[]
    | select(((.affected // []) | join(" ") + " " + .title + " " + .id) | test($t; "i"))
    | "\(.id)\t\(.severity)\t\(.area)\t\(.title)"' "$f" 2>/dev/null \
    | sed "s#^#$(basename "$(dirname "$(dirname "$f")")")\t#"
done
```

## Phase 2: Gather the direct signal (symptoms)

From Phase 1, assemble every finding that names the target: its own findings (what's directly wrong with it) plus their severities and areas. This is the symptom set — what the reports directly observe about the target. Group by provider so the reader sees, e.g., "AWS says no backup; Grafana says no alert rule; Sentry says no error tracking."

## Phase 3: Walk the topology (blast radius + upstream)

If `topology-export.json` exists, read `relationships[]` to place the target in the graph:
- **Upstream (possible causes):** what the target `CALLS` / is `ROUTES_TO` from / `DEPLOYED_AS` — a failing dependency is a candidate root cause.
- **Downstream (blast radius):** what `CALLS` the target — who breaks if the target is down.
- **Observation:** what `MONITORED_BY` edges exist — if none, that itself explains "why didn't we know," a common real root cause.

Carry each edge's `confidence`; a low-confidence or `asserted` (vs `observed`) edge is a weaker link and the RCA says so.

```bash
set -eu
AUD="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
TOPO="$AUD/topology-export.json"
TARGET="checkout"
[ -f "$TOPO" ] || { echo "no topology-export.json — dependency graph unavailable; run /scoutflo:map-topology for blast-radius analysis"; exit 0; }
# The export exists in two real shapes under the same schema version: the spec's
# nested `relationships[]` ({from:{name},to:{name},relation,assertion_type}) and
# the generated `edges[]` ({from,to,type,confidence,verified}). Normalize BOTH to
# a common {from,to,rel,conf} before matching, and guard nulls so a partial
# export never crashes the walk.
jq -r --arg t "$TARGET" '
  (( .relationships // [] ) | map({from: .from.name, to: .to.name, rel: .relation, conf: (.confidence // "?")}))
  + (( .edges // [] )       | map({from: .from,      to: .to,      rel: .type,     conf: (.confidence // "?")}))
  | .[]
  | select(.from == $t or .to == $t)
  | "\(.from) -\(.rel)-> \(.to)  (conf \(.conf))"' "$TOPO"
```

## Phase 4: Walk the correlation chains

If `correlation.json` exists, use it to connect the target to causes and effects the single-report view can't see:
- **Cascades:** if the target (or an upstream dependency) is a cascade `root_cause`, its `effects` are the downstream failures it explains — this is the strongest cause→effect signal available. If the target appears as an `effect`, walk back to the `root_cause` — that is a candidate root cause with an evidence trail.
- **Overlaps:** if the target is in an `overlap` group, multiple stacks flag it — corroborating evidence that the symptom is real and where the authoritative fix belongs.

```bash
set -eu
AUD="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
CORR="$AUD/correlation.json"
TARGET="checkout"
[ -f "$CORR" ] || { echo "no correlation.json — correlating findings directly by shared resource instead; cascades not precomputed"; exit 0; }
# Is the target a cascade root (explains effects) or an effect (walk back to root)?
# Field names match what correlation-engine emits: root_cause has
# {finding_id, title, target, shared_resources}; each effect has
# {finding_id, title, target, condition} — neither carries `affected`.
jq -r --arg t "$TARGET" '
  (.cascades // [])[]
  | select((.root_cause.title + " " + ((.root_cause.shared_resources // []) | join(" "))) | test($t;"i")
           or (any(.effects[]?; .title | test($t;"i"))))
  | "ROOT: \(.root_cause.finding_id) \(.root_cause.title)  (shared: \((.root_cause.shared_resources // []) | join(",")))\n  EFFECTS: \([.effects[]? | "\(.finding_id) \(.title)"] | join(" | "))"' "$CORR"
```

## Phase 5: Weigh by business context

Read `~/.scoutflo/business_context.json`. If the target or a downstream neighbor is in `critical_dependencies`, the RCA leads with that (the blast radius hits something the business cares about, so the recommended response is more urgent). Use `environment` to calibrate severity language (a staging-only chain is real but not an incident). Never invent criticality the context doesn't state; absence of context means "criticality unknown," said plainly.

## Phase 6: Assemble the evidence-cited RCA

Produce the answer in this shape. Every factual clause carries its source in parentheses (`finding-id`, `topology edge`, or `correlation cascade-id`). The confidence and gaps are mandatory.

```markdown
## RCA: <target> — <one-line verdict>

**Most likely root cause (confidence: high | medium | low):**
<1–3 sentences naming the probable root cause, each clause citing its evidence —
e.g. "checkout has no alert rule (GRAF-091) or Datadog monitor (DD-033), and its
datastore payments-db has no backup (AWS-030); topology shows checkout
DEPLOYED_AS the workload that CALLS payments-db (topology, conf 9)">

**How it fails (the chain):**
<root → effect walk, each step cited. If from a correlation cascade, name the
cascade. If assembled directly, say so.>

**Blast radius (who else is affected):**
<downstream services from topology that CALL the target, with business-critical
ones flagged from business_context; "unknown — no topology" if absent>

**Evidence:**
- <finding-id>: <title> (<provider report>, severity)
- <topology edge> (confidence n)
- <correlation overlap/cascade id>

**What I could NOT determine (do this to confirm):**
<explicit gaps — e.g. "no live health signal for payments-db in these reports;
run /scoutflo:audit-aws to confirm its current state" — and, if signal was thin,
say the root cause is a hypothesis, not established>

**Recommended next step:**
<the single highest-value action, pointing at a setup-* fix or an audit to run,
ordered by the business criticality from Phase 5>
```

If Phases 2–4 found no finding, edge, or cascade naming the target: do **not** synthesize a cause. Emit the "insufficient signal" form — what was searched, what exists, and which audit to run so there is something to analyze.

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Inventing a plausible root cause with no finding/edge behind it | Every clause cites a finding-id / topology edge / cascade id; no citation → it's a labelled hypothesis or a stated gap, never a fact |
| Stating a cause when the reports only show a symptom | Phase 3/4 must find an upstream dependency or a cascade root; absent that, the answer is "symptom observed, upstream cause unconfirmed" |
| Treating a stale report as current truth | Cite each report's run date; if the newest naming the target is old, say the RCA reflects that run, not now |
| Ignoring that the target isn't monitored at all | A missing `MONITORED_BY` edge / no telemetry finding is itself a root-cause-class answer ("you wouldn't have detected this") — surface it |
| Over-claiming blast radius from names | Downstream only from real topology `CALLS`/`ROUTES_TO` edges, never inferred from similar names; "unknown" when topology is absent |
| Running a provider call to "check" during analysis | This skill is read-only over local artifacts; if live confirmation is needed it names the audit to run, it does not call the provider itself |

## Maturity note (v0.1.85)

The RCA flow is provider-agnostic by construction — it reads the common
`findings.json` / `correlation.json` / `topology-export.json` schema every audit
emits, so it works for any provider's findings. It is **live-proven end to end on
an AWS finding** (the EC2/datastore case). GCP/Kubernetes/others use the identical
mechanism and are expected to work, but treat a first RCA on a not-yet-proven
provider as "verify the citations against the reports yourself" until this note
is updated. The grounding guarantees (every claim cited, confidence stated, gaps
explicit, no invented cause) hold for every provider regardless.

---

**v0.1.85** — New: turns "why is X failing, give me the RCA" into an evidence-cited, confidence-scored root-cause analysis correlated across every audit report + topology + business context. Read-only; never invents a cause.
