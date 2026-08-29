#!/bin/sh
# token-efficiency-audit.sh
# Verify every skill follows unified token-efficiency governance

set -eu

echo "=== Token Efficiency Governance Audit ==="
echo ""

SKILLS_DIR="./skills"
FAILURES=0

# Checks per skill
audit_skill() {
  skill_name="$1"
  skill_dir="$SKILLS_DIR/$skill_name"

  [ -d "$skill_dir" ] || { echo "SKIP: $skill_name (not found)"; return 0; }

  echo "▶ $skill_name"

  # Check 1: SKILL.md exists and is readable
  if [ -f "$skill_dir/SKILL.md" ]; then
    echo "  ✓ SKILL.md present"
  else
    echo "  ✗ SKILL.md missing"
    FAILURES=$((FAILURES + 1))
  fi

  # Check 2: history.jsonl pattern mentioned (for audits)
  if echo "$skill_name" | grep -q "^audit-\|cost-analysis\|correlation-engine"; then
    if grep -q "history.jsonl\|history ledger\|skip.*24h\|<24h.*old" "$skill_dir/SKILL.md" 2>/dev/null; then
      echo "  ✓ History ledger documented"
    else
      echo "  ⚠ History ledger not documented (check if skill maintains one)"
      # Not a hard failure; some skills may not need it
    fi
  fi

  # Check 3: Skip logic documented
  if echo "$skill_name" | grep -q "^audit-\|cost-analysis\|correlation-engine"; then
    if grep -q "skip.*<24h\|skip.*history\|current.*hours\|SKIP" "$skill_dir/SKILL.md" 2>/dev/null; then
      echo "  ✓ Skip logic documented"
    else
      echo "  ⚠ Skip logic not documented (verify in lib if present)"
    fi
  fi

  # Check 4: topology integration mentioned
  if echo "$skill_name" | grep -q "^audit-\|setup-\|topology-guided"; then
    if grep -q "topology\|scan_scope\|scope.*selection\|exclusions" "$skill_dir/SKILL.md" 2>/dev/null; then
      echo "  ✓ Topology integration documented"
    else
      echo "  ⚠ Topology integration not mentioned (verify if applicable)"
    fi
  fi

  # Check 5: --force flag support
  if echo "$skill_name" | grep -q "^audit-\|cost-analysis"; then
    if grep -q "\-\-force" "$skill_dir/SKILL.md" 2>/dev/null; then
      echo "  ✓ --force flag documented"
    else
      echo "  ⚠ --force flag not documented (should support skip bypass)"
    fi
  fi

  echo ""
}

# Audit all skills
echo "Auditing audit skills:"
audit_skill "audit-aws"
audit_skill "audit-gcp"
audit_skill "audit-grafana"
audit_skill "audit-sentry"
audit_skill "audit-lgtm"
audit_skill "audit-datadog"
audit_skill "audit-elk"
audit_skill "audit-jsm"
audit_skill "audit-zenduty"
audit_skill "audit-groundcover"
audit_skill "audit-alertmanager"
audit_skill "audit-digitalocean"
audit_skill "audit-kubernetes"

echo "Auditing analysis skills:"
audit_skill "cost-analysis"
audit_skill "correlation-engine"

echo "Auditing setup skills (sample):"
audit_skill "setup-aws"
audit_skill "topology-guided-setup"

echo "Auditing harness skills (sample):"
audit_skill "audit-all"

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "✓ Token Efficiency Audit: PASS (no blocking failures)"
  exit 0
else
  echo "✗ Token Efficiency Audit: FAIL ($FAILURES issues found)"
  exit 1
fi
