#!/bin/sh
# ci/validate-business-context.sh
# Validate business_context.md structure and required sections

set -eu

CONTEXT="${1:-$HOME/.scoutflo/business_context.md}"

echo "Validating business_context.md..."
echo ""

# Check if file exists
if [ ! -f "$CONTEXT" ]; then
  echo "ℹ️  No business_context.md found at $CONTEXT"
  echo "   Create one with: /scoutflo:connect"
  exit 0
fi

ERRORS=0

# Required sections
for section in "Environment" "Cost Sensitivity"; do
  if ! grep -q "^## $section" "$CONTEXT"; then
    echo "✗ Missing required section: ## $section"
    ERRORS=$((ERRORS + 1))
  else
    echo "✓ Found section: ## $section"
  fi
done

# Recommended sections
for section in "Critical Services" "Exclusions" "Risky Operations" "Audit Strategy"; do
  if ! grep -q "^## $section" "$CONTEXT"; then
    echo "⚠ Consider adding: ## $section"
  fi
done

echo ""

# Check environment section
if grep -A5 "^## Environment" "$CONTEXT" | grep -q "Stage:"; then
  echo "✓ Environment section has Stage field"
else
  echo "⚠ Environment section missing Stage field"
fi

# Check cost sensitivity
if grep -A3 "^## Cost Sensitivity" "$CONTEXT" | grep -q "Primary:"; then
  echo "✓ Cost Sensitivity section has Primary field"
else
  echo "✗ Cost Sensitivity section missing Primary field"
  ERRORS=$((ERRORS + 1))
fi

echo ""

if [ "$ERRORS" -eq 0 ]; then
  echo "✅ business_context.md is valid"
  exit 0
else
  echo "❌ business_context.md has $ERRORS error(s)"
  echo "   Review: docs/specs/business-context-ssot.md"
  exit 1
fi
