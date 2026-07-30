---
name: audit-kubernetes
description: Audit Kubernetes cluster security and operational readiness. Discovers Pod Security Policies, RBAC gaps, network policies, resource limits, and pod security issues. Read-only; runs against the current kubeconfig context.
---

# Kubernetes Audit

Audit a Kubernetes cluster for security and operational configuration gaps. Checks Pod Security Policies, RBAC role bindings, network policies, resource requests/limits, and pod disruption budgets.

## Prerequisites

| Requirement | Check |
| --- | --- |
| `kubectl` | Installed and configured |
| `jq` | Installed |
| Kubeconfig | Valid context (current context used automatically) |
| RBAC | `get` on pods, deployments, services, networkpolicies, roles, rolebindings, clusterroles, clusterrolebindings |

## Phase 1: Cluster Discovery

Auto-detect the current Kubernetes context from kubeconfig:

```bash
kubectl config current-context
```

Output: `my-cluster` (or similar context name)

## Phase 2: Security Checks

Run read-only checks against the cluster:

| Check | What | Category |
| --- | --- | --- |
| **Pod Security Policies** | Detect missing or permissive PSP (privileged, allow all) | Security |
| **RBAC Gaps** | Find subjects with overly broad permissions (wildcard verbs, cluster-admin) | Security |
| **Network Policies** | Count enforced vs missing ingress/egress policies per namespace | Network |
| **Resource Limits** | Find deployments with no resource requests or limits | Reliability |
| **Pod Disruption Budgets** | Detect missing PDBs on critical workloads | Reliability |

## Output

**findings.json** → `scoutflo-audits/kubernetes/<cluster>/<date>/findings.json`

Each finding includes:

- `id`: Finding ID (K8S-001, K8S-002, etc.)
- `title`: Brief description
- `severity`: critical | high | medium | low | info
- `description`: Full details with remediation
- `affected_resource`: Namespace, pod, deployment, etc.

**report.md** → `scoutflo-audits/kubernetes/<cluster>/<date>/report.md`

Human-readable markdown report with:

- Cluster name and audit date
- Summary: total findings by severity
- Detailed finding sections
- Related findings from other audits (cross-references)

## Standalone Usage

```bash
/scoutflo:audit-kubernetes
```

Auto-detects current cluster, runs checks, writes findings and report.

## Integration with audit-all

Runs automatically if kubeconfig is available when user runs `/scoutflo:audit-all`.

## Smart Auto Integration (v0.1.69+)

This skill is automatically wired into the v0.1.69 smart auto integration pipeline when run via `/scoutflo:audit-all`:

**Shared State (Phase 0):**
- Reads `SCOUTFLO_BUSINESS_CONTEXT` — guardrails and critical services
- Reads `SCOUTFLO_EXEMPTIONS` — suppressed findings
- Reads `SCOUTFLO_METADATA` — K8s labels and resource properties
- Reads `SCOUTFLO_TOPOLOGY` — service inventory
- Reads `SCOUTFLO_SESSION_ID` — session tracking

**Integration Logic (Phase 1-12):**
1. **C4 Exemptions** — Filters findings marked as suppressed or excluded
2. **C3 Lifecycle** — Classifies each finding as new, unchanged, or regressed
3. **B Criticality** — Escalates severity for findings in critical services
4. **G3 Remediation** — Adds `next_safe_action` linking to `setup-kubernetes` anchors
5. **History Ledger** — Records completion in shared audit session log

**Integration Output (Phase 13):**
- Appends all findings to shared `SCOUTFLO_FINDINGS_LOG` (not individual findings.json)
- Logs completion to `SCOUTFLO_HISTORY_LOG`
- Enables correlation, redaction, cost-analysis, and topology-guided-setup to run automatically

**Example:** When a finding is marked as critical service in business_context.md:
```
K8S-001 → severity escalated from medium to critical
         → assigned next_safe_action: "setup-kubernetes#rbac-tighten"
         → appended to shared log for topology-guided-setup sequencing
```

When run standalone (e.g., `/scoutflo:audit-kubernetes`):
- Operates in v0.1.68 mode (produces individual findings.json, no shared state)
- Integration logic is skipped (backward compatible)

See [smart-auto-integration-guide.md](../../docs/smart-auto-integration-guide.md) for detailed pipeline documentation.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Audit completed successfully (findings may exist) |
| 1 | kubectl not installed or not in PATH |
| 2 | Current context not found or kubeconfig missing |
| 3 | RBAC denied (insufficient permissions) |

---

**v0.1.65+** — Standalone audit  
**v0.1.69+** — Automatic integration pipeline (via `/scoutflo:audit-all`)
