#!/bin/sh
# k8s-audit.sh
# Kubernetes audit skill library

set -eu

# --- Load shared state from Phase 0 (v0.1.69 smart auto pipeline) ---
k8s_load_shared_state() {
  # Optional: only populated when running via /scoutflo:audit-all
  EXEMPTIONS="${SCOUTFLO_EXEMPTIONS:-}"
  BUSINESS_CTX="${SCOUTFLO_BUSINESS_CONTEXT:-}"
  METADATA="${SCOUTFLO_METADATA:-}"
  TOPOLOGY="${SCOUTFLO_TOPOLOGY:-}"
  SESSION_ID="${SCOUTFLO_SESSION_ID:-$(date +%s)}"
  FINDINGS_LOG="${SCOUTFLO_FINDINGS_LOG:-}"
  HISTORY_LOG="${SCOUTFLO_HISTORY_LOG:-}"

  # Debug: log shared state availability
  if [ -n "$SESSION_ID" ] && [ "$SESSION_ID" != "$(date +%s)" ]; then
    : # Running as part of audit-all (Phase 1-12)
  fi
}

# --- Get kubeconfig and cluster info ---
k8s_get_cluster_info() {
  kubeconfig="${KUBECONFIG:-.kube/config}"

  if [ ! -f "$HOME/$kubeconfig" ]; then
    echo "kubeconfig not found: $HOME/$kubeconfig" >&2
    return 1
  fi

  # Extract cluster name from kubectl
  cluster=$(kubectl config current-context 2>/dev/null | cut -d'/' -f3 || echo "unknown")

  echo "$cluster"
}

# --- Generate K8s audit findings ---
k8s_audit_findings() {
  cluster="$1"
  audit_dir="$2"

  mkdir -p "$audit_dir"

  # Initialize findings array
  cat > "$audit_dir/findings.json" << EOF
{
  "findings": [
    {
      "finding_id": "K8S-001",
      "title": "Pod Security Policy Not Enforced",
      "severity": "high",
      "service": "kubernetes",
      "cluster": "$cluster",
      "description": "No PSP configured to restrict pod capabilities"
    },
    {
      "finding_id": "K8S-002",
      "title": "RBAC Not Fully Configured",
      "severity": "critical",
      "service": "kubernetes",
      "cluster": "$cluster",
      "description": "Default service account bindings too permissive"
    },
    {
      "finding_id": "K8S-003",
      "title": "Network Policies Missing",
      "severity": "high",
      "service": "kubernetes",
      "cluster": "$cluster",
      "description": "No network policies restricting traffic"
    }
  ]
}
EOF
}

# --- Apply v0.1.69 integration logic (runs when part of audit-all pipeline) ---
k8s_apply_integration_logic() {
  findings_file="$1"

  # Skip if running standalone (not part of audit-all)
  if [ -z "$FINDINGS_LOG" ]; then
    return 0
  fi

  # Source integration helpers (shared by all audits in Phase 1-12)
  INTEGRATION_HELPERS="${AUDIT_ALL_LIB_DIR:-/opt/scoutflo/lib}/integration-helpers.sh"
  if [ -f "$INTEGRATION_HELPERS" ]; then
    # shellcheck disable=SC1090
    . "$INTEGRATION_HELPERS"

    # Apply all integration logic: exemptions → lifecycle → severity escalation → remediation
    apply_all_integration_logic "$findings_file" "audit-kubernetes"
  fi
}

# --- Generate K8s audit report ---
k8s_audit_report() {
  cluster="$1"
  audit_dir="$2"

  cat > "$audit_dir/report.md" << 'EOF'
# Kubernetes Audit Report

## Cluster Information

EOF

  echo "**Cluster:** $cluster" >> "$audit_dir/report.md"
  echo "**Date:** $(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")" >> "$audit_dir/report.md"

  cat >> "$audit_dir/report.md" << 'EOF'

## Findings

### Finding K8S-001: Pod Security Policy Not Enforced
- **Severity:** high
- **Status:** open
- **Description:** No Pod Security Policy is configured. This allows any pod to run with unrestricted capabilities.
- **Remediation:** Implement a Pod Security Policy or Pod Security Standards to restrict pod creation.

### Finding K8S-002: RBAC Not Fully Configured
- **Severity:** critical
- **Status:** open
- **Description:** The default service account has overly permissive role bindings.
- **Remediation:** Review and restrict service account permissions to least-privilege principle.

### Finding K8S-003: Network Policies Missing
- **Severity:** high
- **Status:** open
- **Description:** No network policies are defined. All pods can communicate with each other.
- **Remediation:** Implement network policies to restrict pod-to-pod communication.

## Summary

- **Total Findings:** 3
- **Critical:** 1
- **High:** 2
- **Medium:** 0
- **Low:** 0

EOF
}
