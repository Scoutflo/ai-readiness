#!/bin/sh
# topology-guided-setup.sh
# Uses correlation.json + business-context to make smart fix decisions
# Integrates with /scoutflo:setup-* skills to avoid cascading failures & wasted tokens

set -eu

CORRELATION_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/correlation.json"
TOPOLOGY_FILE="${TOPOLOGY_FILE:-$HOME/.scoutflo/topology.json}"
# Derived projection of the business_context.md SSOT (authoritative when present).
BC_JSON="${BC_JSON:-$HOME/.scoutflo/business_context.json}"

# Load business context (with safe defaults).
# Precedence: business_context.json (derived from the SSOT) is authoritative;
# legacy topology.json:.business_context is the migration fallback.
_load_context() {
  if [ -f "$BC_JSON" ]; then
    jq '{
      environment: (.environment // "production"),
      cost_sensitivity: (.cost_sensitivity // "medium"),
      critical_dependencies: (.critical_dependencies // []),
      environment_map: (.environment_map // [])
    }' "$BC_JSON"
  elif [ -f "$TOPOLOGY_FILE" ]; then
    jq '.business_context // {
      environment: "production",
      cost_sensitivity: "medium",
      sla: 99.9,
      team: "platform",
      critical_dependencies: []
    }' "$TOPOLOGY_FILE"
  else
    jq -n '{
      environment: "production",
      cost_sensitivity: "medium",
      sla: 99.9,
      team: "platform",
      critical_dependencies: []
    }'
  fi
}

# Load correlation data
_load_correlation() {
  if [ -f "$CORRELATION_FILE" ]; then
    jq '.' "$CORRELATION_FILE" 2>/dev/null || jq -n '{overlaps:[], cascades:[]}'
  else
    jq -n '{overlaps:[], cascades:[]}'
  fi
}

# Check if finding is in an overlap (redundant monitoring)
topology_guided_check_overlap() {
  finding_id="$1"
  correlation="$2"

  printf '%s\n' "$correlation" | jq -c \
    --arg id "$finding_id" \
    'first(
      .overlaps[] |
      select(.findings[].finding_id == $id) |
      {
        overlap_id,
        is_redundant: true,
        related_findings: [.findings[] | select(.finding_id != $id)],
        recommendation
      }
    ) // empty'
}

# Check if finding is root cause of cascades
topology_guided_check_cascade_root() {
  finding_id="$1"
  correlation="$2"

  printf '%s\n' "$correlation" | jq -c \
    --arg id "$finding_id" \
    'first(
      .cascades[] |
      select(.root_cause.finding_id == $id) |
      {
        cascade_id,
        is_root_cause: true,
        effects: [.effects[] | {finding_id, title, target}],
        effect_count: (.effects | length)
      }
    ) // empty'
}

# Check if finding is affected by cascades (impact if not fixed)
topology_guided_check_cascade_impact() {
  finding_id="$1"
  correlation="$2"

  printf '%s\n' "$correlation" | jq -c \
    --arg id "$finding_id" \
    'first(
      .cascades[] |
      select(.effects[].finding_id == $id) |
      {
        cascade_id,
        is_cascade_impact: true,
        root_cause: (.root_cause | {finding_id, title, target}),
        fix_sequence: "fix root cause first"
      }
    ) // empty'
}

# Determine if finding is on critical service
topology_guided_is_critical() {
  service="$1"
  context="$2"

  critical_deps=$(printf '%s\n' "$context" | jq '.critical_dependencies // []')

  if printf '%s\n' "$critical_deps" | jq -e --arg svc "$service" 'index($svc)' >/dev/null 2>&1; then
    echo "true"
  else
    echo "false"
  fi
}

# Calculate token estimate for fix
topology_guided_estimate_tokens() {
  finding_id="$1"
  service="$2"
  context="$3"

  # Simple heuristic: critical services need more validation
  is_critical=$(topology_guided_is_critical "$service" "$context")
  env=$(printf '%s\n' "$context" | jq -r '.environment // "production"')

  if [ "$is_critical" = "true" ]; then
    if [ "$env" = "production" ]; then
      echo "20000"  # Critical prod: full validation + dry-run
    else
      echo "10000"  # Critical non-prod: less validation
    fi
  else
    if [ "$env" = "production" ]; then
      echo "10000"  # Non-critical prod: standard fix
    else
      echo "5000"   # Non-critical non-prod: minimal
    fi
  fi
}

# Get fix recommendation (what to do with this finding)
topology_guided_get_recommendation() {
  finding_id="$1"
  service="$2"
  title="$3"

  context=$(_load_context)
  correlation=$(_load_correlation)

  # Check overlap
  overlap=$(topology_guided_check_overlap "$finding_id" "$correlation")
  if [ -n "$overlap" ] && [ "$overlap" != "null" ]; then
    printf '%s\n' "$overlap" | jq -n --slurpfile data /dev/stdin '
      {
        recommendation_type: "OVERLAP_DETECTED",
        action: "SKIP_OR_DEDUP",
        rationale: ($data[0].recommendation // "Overlapping monitoring detected"),
        related: $data[0].related_findings,
        tokens_saved: "50%+"
      }
    '
    return 0
  fi

  # Check if root cause of cascade
  cascade_root=$(topology_guided_check_cascade_root "$finding_id" "$correlation")
  if [ -n "$cascade_root" ] && [ "$cascade_root" != "null" ]; then
    printf '%s\n' "$cascade_root" | jq -n --slurpfile data /dev/stdin '
      {
        recommendation_type: "CASCADE_ROOT",
        action: "FIX_FIRST_PRIORITY",
        rationale: ("Fix root cause prevents " + ($data[0].chain_length | tostring) + "-step cascade"),
        prevents_failures: $data[0].effects | length,
        tokens_saved: "30%+"
      }
    '
    return 0
  fi

  # Check if impacted by cascade
  cascade_impact=$(topology_guided_check_cascade_impact "$finding_id" "$correlation")
  if [ -n "$cascade_impact" ] && [ "$cascade_impact" != "null" ]; then
    printf '%s\n' "$cascade_impact" | jq -n --slurpfile data /dev/stdin '
      {
        recommendation_type: "CASCADE_IMPACT",
        action: "WAIT_FOR_ROOT_FIX",
        rationale: ("This is cascading from " + ($data[0].root_cause.title // "root cause")),
        root_cause_to_fix: $data[0].root_cause,
        fix_order: 2
      }
    '
    return 0
  fi

  # Standard case: check criticality
  is_critical=$(topology_guided_is_critical "$service" "$context")
  env=$(printf '%s\n' "$context" | jq -r '.environment // "production"')

  if [ "$is_critical" = "true" ]; then
    echo "{
      \"recommendation_type\": \"CRITICAL_SERVICE\",
      \"action\": \"REQUIRE_APPROVAL\",
      \"rationale\": \"Service is marked as business-critical\",
      \"approval_required\": true,
      \"suggested_flow\": \"1. Dry-run, 2. Show changes, 3. Get approval, 4. Apply\"
    }" | jq '.'
  else
    tokens=$(topology_guided_estimate_tokens "$finding_id" "$service" "$context")
    echo "{
      \"recommendation_type\": \"STANDARD\",
      \"action\": \"CAN_PROCEED\",
      \"rationale\": \"Non-critical service, standard fix flow\",
      \"tokens_estimated\": $tokens,
      \"environment\": \"$env\"
    }" | jq '.'
  fi
}

# Interactive decision flow for setup skill
topology_guided_should_fix() {
  finding_id="$1"
  service="$2"
  title="$3"

  recommendation=$(topology_guided_get_recommendation "$finding_id" "$service" "$title")
  action=$(printf '%s\n' "$recommendation" | jq -r '.action // "UNKNOWN"')
  context=$(_load_context)
  cost_sensitivity=$(printf '%s\n' "$context" | jq -r '.cost_sensitivity // "medium"')

  case "$action" in
    SKIP_OR_DEDUP)
      echo "ℹ️  This finding overlaps with another. Recommend skipping to reduce alert noise."
      return 1
      ;;
    FIX_FIRST_PRIORITY)
      echo "🔴 This is the root cause of a cascade. Fix this first to prevent 2+ downstream failures."
      return 0
      ;;
    WAIT_FOR_ROOT_FIX)
      echo "⏳ This finding is cascading from another. Wait for root cause fix first."
      return 1
      ;;
    REQUIRE_APPROVAL)
      echo "⚠️  Service is marked as business-critical. Require approval before fixing."
      echo "   Suggested: dry-run → show changes → get approval → apply"
      return 1
      ;;
    CAN_PROCEED)
      tokens=$(printf '%s\n' "$recommendation" | jq -r '.tokens_estimated // "10000"')
      if [ "$cost_sensitivity" = "high" ]; then
        echo "✓ Can proceed. Estimated cost: $tokens tokens ≈ \$0.$(((tokens / 1000) * 5))."
      else
        echo "✓ Can proceed."
      fi
      return 0
      ;;
  esac
}

# Print detailed guidance for setup flow
topology_guided_show_guidance() {
  finding_id="$1"
  service="$2"
  title="$3"

  recommendation=$(topology_guided_get_recommendation "$finding_id" "$service" "$title")

  echo ""
  echo "━━━ TOPOLOGY-GUIDED FIX RECOMMENDATION ━━━"
  echo "Finding: $finding_id — $title"
  echo "Service: $service"
  echo ""
  printf '%s\n' "$recommendation" | jq '
    "Recommendation: \(.recommendation_type)\n" +
    "Action: \(.action)\n" +
    "Rationale: \(.rationale)\n" +
    (if .tokens_estimated then "Estimated tokens: \(.tokens_estimated)\n" else "" end) +
    (if .approval_required then "⚠️  Requires approval before proceeding\n" else "" end) +
    (if .related then "Related findings: \(.related | length) overlaps\n" else "" end) +
    (if .prevents_failures then "Prevents: \(.prevents_failures) cascade failures\n" else "" end)
  ' -r
  echo ""
}

# Exports for integration with setup skills
topology_guided_get_fix_order() {
  finding_id="$1"

  correlation=$(_load_correlation)

  # Root causes = priority 1
  root=$(printf '%s\n' "$correlation" | jq --arg id "$finding_id" '.cascades[] | select(.root_cause.finding_id == $id) | .cascade_id' | head -1)
  if [ -n "$root" ]; then
    echo "1"
    return 0
  fi

  # Impacted by cascade = priority 2
  impact=$(printf '%s\n' "$correlation" | jq --arg id "$finding_id" '.cascades[] | select(.effects[].finding_id == $id) | .cascade_id' | head -1)
  if [ -n "$impact" ]; then
    echo "2"
    return 0
  fi

  # Everything else = priority 3
  echo "3"
}
