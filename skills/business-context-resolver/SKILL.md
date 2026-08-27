---
name: business-context-resolver
description: Auto-discover K8s labels, AWS tags, GitHub CODEOWNERS and generate computed_metadata.jsonl for metadata-driven audit filtering, escalation, and cost sensitivity. Read-only discovery only; no mutations to live services.
---

# business-context-resolver

Auto-discover team, environment, SLA, and cost metadata from Kubernetes labels, AWS tags, and GitHub CODEOWNERS. Generate a single source of truth (`computed_metadata.jsonl`) that all 10 audit skills read for intelligent filtering, escalation, and cost-sensitivity decisions.

Read-only discovery skill. No resources are created, modified, or deleted. Output is saved locally to `~/.scoutflo/computed_metadata.jsonl` for reuse by other skills.

Scales from startup (5 services, manual entry) to enterprise (1000+ services, auto-discovery). Typical token cost: 15-20K for a large estate (auto-discovery of 1000 services, full correlation engine).

Run standalone with `/scoutflo:business-context-resolver`, or automatically after `/scoutflo:connect` proposes auto-discovery.

## Prerequisites

| Requirement | Check |
| --- | --- |
| `business_context.md` | Required; run `/scoutflo:business-context` first to create it |
| `kubectl` | Optional; discovered only if installed and kubeconfig valid |
| `aws` CLI | Optional; discovered only if installed and credentials valid |
| `git` | Optional; discovered only if installed and .git exists locally |
| `jq` | Required to parse metadata output |

## Doctor gate

Check that `~/.scoutflo/business_context.md` exists (created by `/scoutflo:business-context`). All discovery sources (K8s, AWS, GitHub) are optional:

```bash
set -eu
CONTEXT="${HOME}/.scoutflo/business_context.md"
[ -f "$CONTEXT" ] || { echo "missing $CONTEXT; run /scoutflo:business-context first"; exit 1; }
for bin in jq; do
  command -v "$bin" >/dev/null || { echo "missing binary: $bin"; exit 1; }
done
echo "doctor gate: pass"
```

Never proceed past a failed doctor check.

## Live-safety gate

Print the discovery targets before scanning:

```bash
set -eu
echo "Discovery targets:"
command -v kubectl >/dev/null && echo "  ✓ Kubernetes (labels from current context)" || echo "  - Kubernetes (kubectl not found, skipping)"
command -v aws >/dev/null && echo "  ✓ AWS (tags from active credentials)" || echo "  - AWS (aws CLI not found, skipping)"
[ -d .git ] && command -v git >/dev/null && echo "  ✓ GitHub (CODEOWNERS from repo)" || echo "  - GitHub (.git not found or git not installed, skipping)"
echo "live-safety gate: pass (discovery is read-only, no mutations)"
```

## Phase 1: Load business_context.md

Parse `~/.scoutflo/business_context.md` (created by `/scoutflo:business-context`). Extract the sections the business-context skill actually writes (see [templates/business_context_template.md](../../templates/business_context_template.md)):
- `Environment` section: stage (prod/staging/dev) and risk level
- `Environment Map` table: per-environment `Uptime SLA` and target (profile / project / context)
- `SLAs / SLOs` table: per-service SLA defaults
- `Cost Sensitivity` section: the `Primary:` high/medium/low ordering rule
- `Critical Services` section: services that escalate and gate on approval
- `Exclusions` section: regions / accounts / services / resources never audited

## Phase 2: Discover Kubernetes metadata

If `kubectl` is available and kubeconfig is valid, enumerate all resources and extract labels:

```bash
kubectl get deployments,statefulsets,daemonsets,services -A -o json | jq -c '.items[] | {
  type: .kind,
  name: .metadata.name,
  namespace: .metadata.namespace,
  labels: .metadata.labels
}' > /tmp/k8s_resources.jsonl
```

Extract join keys:
- `service` or `app` label → resource name
- `team` or `owned-by` label → team
- `environment` or `env` label → environment (prod, staging, dev)
- `criticality` or `tier` label → escalation level

## Phase 3: Discover AWS metadata

If `aws` CLI is available and credentials are valid, enumerate compute and database resources:

```bash
aws ec2 describe-instances --query 'Reservations[].Instances[]' | jq '.[] | {name: .Tags[] | select(.Key=="Name") | .Value, tags: .Tags}'
aws rds describe-db-instances --query 'DBInstances[]' | jq '.[] | {name: .DBInstanceIdentifier, tags: .TagList}'
```

Extract join keys:
- `Name` or `service` tag → resource name
- `team` or `owner` tag → team
- `environment` or `env` tag → environment
- `cost-center` tag → billing owner

## Phase 4: Discover GitHub ownership

If `.git` exists and `git` is available, read CODEOWNERS and parse ownership:

```bash
git show HEAD:CODEOWNERS | grep -v '^#' | awk '{print $1, $(NF)}' > /tmp/codeowners.txt
```

Map path patterns to teams, then resolve service ownership by code path.

## Phase 5: Apply derived rules

For each discovered resource, apply the discovery configuration:

```bash
set -eu
BC="${HOME}/.scoutflo/business_context.md"

# Pull the workspace rules once, from the sections the business-context skill writes.
# Critical Services + Exclusions: the backtick-quoted names under each heading.
CRITICAL_SVCS="$(awk '/^## Critical Services/{f=1;next} /^## /{f=0} f' "$BC" | grep -oE '`[^`]+`' | tr -d '`')"
EXCLUSIONS="$(awk '/^## Exclusions/{f=1;next} /^## /{f=0} f' "$BC" | grep -oE '`[^`]+`' | tr -d '`')"
# Cost Sensitivity: the global Primary ordering rule (high|medium|low).
COST_DEFAULT="$(grep -iA3 '^## Cost Sensitivity' "$BC" | grep -iE 'Primary:' | head -1 | sed -E 's/.*Primary:\**[[:space:]]*//; s/[][]//g; s/[[:space:]]*$//' | tr 'A-Z' 'a-z')"
[ -n "$COST_DEFAULT" ] || COST_DEFAULT="medium"

# Per resource: combine discovered metadata with business context rules.
while IFS= read -r resource; do
  [ -n "$resource" ] || continue
  RESOURCE_ID="$(echo "$resource" | jq -r '.resource_id')"
  TEAM="$(echo "$resource" | jq -r '.team')"
  ENVIRONMENT="$(echo "$resource" | jq -r '.environment')"

  # SLA: per-service row from the SLAs / SLOs table; else this environment's
  # Uptime SLA from the Environment Map table.
  SLA="$(awk -F'|' -v s="$RESOURCE_ID" '/^## SLAs/{f=1;next} /^## /{f=0} f && /^\|/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); gsub(/^[[:space:]]+|[[:space:]]+$/,"",$3); if ($2==s) print $3}' "$BC" | head -1)"
  [ -n "$SLA" ] || SLA="$(awk -F'|' -v e="$ENVIRONMENT" '/^## Environment Map/{f=1;next} /^## /{f=0} f && /^\|/ {for(i=1;i<=NF;i++) gsub(/^[[:space:]]+|[[:space:]]+$/,"",$i); if ($2==e) print $7}' "$BC" | head -1)"

  # Escalation: a Critical Service is escalated (POSIX word-list membership test).
  ESCALATION="normal"
  case " $(echo "$CRITICAL_SVCS" | tr '\n' ' ') " in *" ${RESOURCE_ID} "*) ESCALATION="CRITICAL" ;; esac

  # Cost sensitivity: the workspace default ordering rule.
  COST_SENSITIVITY="$COST_DEFAULT"

  # Action: a resource named in the Exclusions block is out of scope (never a fail).
  ACTION="audit"
  case " $(echo "$EXCLUSIONS" | tr '\n' ' ') " in *" ${RESOURCE_ID} "*) ACTION="skip" ;; esac

  echo "{\"resource_id\":\"${RESOURCE_ID}\",\"team\":\"${TEAM}\",\"environment\":\"${ENVIRONMENT}\",\"sla\":\"${SLA}\",\"escalation\":\"${ESCALATION}\",\"cost_sensitivity\":\"${COST_SENSITIVITY}\",\"action\":\"${ACTION}\",\"resolved_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
done < /tmp/discovered_resources.jsonl
```

## Phase 6: Write computed_metadata.jsonl

Output JSONL (one resource per line), no array wrapper:

```bash
{"resource_id":"payment-svc","team":"payments","environment":"prod","sla":"99.95%","escalation":"CRITICAL","cost_sensitivity":"high","action":"audit","resolved_at":"2026-07-30T19:30:00Z"}
{"resource_id":"analytics-batch","team":"data","environment":"staging","sla":"95%","escalation":"normal","cost_sensitivity":"medium","action":"audit","resolved_at":"2026-07-30T19:30:00Z"}
```

Write to `~/.scoutflo/computed_metadata.jsonl`.

## Output

- `~/.scoutflo/computed_metadata.jsonl` — One resource per line, JSONL format. Schema: `resource_id` (string), `team` (string), `environment` (string), `sla` (string), `escalation` ("normal" | "CRITICAL"), `cost_sensitivity` ("low" | "medium" | "high"), `action` ("audit" | "skip"), `resolved_at` (ISO8601 timestamp).

## Integration with audit-all

When `/scoutflo:audit-all` runs, it pre-discovers metadata once in Phase 1, then all 10 audit skills read the same file for filtering, escalation, and cost-sensitivity decisions. No redundant discovery.

## Backward compatibility

- If `computed_metadata.jsonl` does not exist, all audit skills fall back to v0.1.67 `business_context.md` parsing (no regression).
- If discovery sources (K8s, AWS, GitHub) are unavailable, the skill reports what was skipped and continues with available sources (graceful degradation).

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Discovery completed successfully (one or more sources discovered resources) |
| 1 | `business_context.md` missing or invalid |
| 2 | `jq` not installed |
| 3 | All discovery sources unavailable (no kubectl, aws, or .git); metadata file not written |

---

**v0.1.68+**
