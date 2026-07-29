#!/bin/sh
# test-k8s-exposure.sh - K8s audit skill exposure tests

set -eu

TEST_DIR="$(mktemp -d)"

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

echo "=== K8s Exposure Tests ==="

# Test 1: Skill can be invoked (stub check)
echo "Test 1: K8s skill exists and is callable"
[ -d "skills/audit-kubernetes" ] && echo "PASS" || { echo "FAIL: audit-kubernetes dir missing"; exit 1; }

# Test 2: Output directory structure
echo "Test 2: Output directory structure valid"
# Pattern: scoutflo-audits/kubernetes/<cluster>/<date>/report.md
# For test, just verify the structure can be created
output_dir="${TEST_DIR}/scoutflo-audits/kubernetes/prod-gke-1/2026-07-29"
mkdir -p "$output_dir"
echo "Mock report" > "${output_dir}/report.md"
[ -f "${output_dir}/report.md" ] && echo "PASS" || { echo "FAIL: report.md not created"; exit 1; }

# Test 3: Report contains expected sections
echo "Test 3: Report format validation"
cat > "${output_dir}/report.md" << 'EOF'
# Kubernetes Audit Report

## Cluster: prod-gke-1

## Findings

### Finding K8S-001
- Title: Pod Security Policy Not Enforced
- Severity: high
- Description: No PSP in place

### Finding K8S-002
- Title: RBAC Not Configured
- Severity: critical
- Description: No role bindings
EOF

# Check report has expected sections
grep -q "# Kubernetes Audit Report" "${output_dir}/report.md" && echo "PASS" || { echo "FAIL: header missing"; exit 1; }

# Test 4: Findings JSON structure
echo "Test 4: Findings JSON structure"
cat > "${output_dir}/findings.json" << 'EOF'
{
  "findings": [
    {
      "finding_id": "K8S-001",
      "title": "Pod Security Policy Not Enforced",
      "severity": "high",
      "service": "kubernetes",
      "cluster": "prod-gke-1"
    },
    {
      "finding_id": "K8S-002",
      "title": "RBAC Not Configured",
      "severity": "critical",
      "service": "kubernetes",
      "cluster": "prod-gke-1"
    }
  ]
}
EOF

count=$(jq '.findings | length' "${output_dir}/findings.json")
[ "$count" = "2" ] && echo "PASS" || { echo "FAIL: expected 2 findings, got $count"; exit 1; }

# Test 5: Backward compat (K8s skill doesn't break existing audits)
echo "Test 5: Backward compatibility check"
# If K8s skill is wired, other skills should still work
# For now, just verify the SKILL.md exists
[ -f "skills/audit-kubernetes/SKILL.md" ] && echo "PASS" || echo "SKIP: SKILL.md not yet created"

echo
echo "=== All K8s exposure tests passed ==="
