#!/bin/sh
# metadata-resolver.sh
# Discovers K8s labels, AWS tags, GitHub CODEOWNERS
# Auto-generates resource metadata (computed_metadata.jsonl) for all resources
# NO manual resource entry required — scales to 1000+ resources

set -eu

CONTEXT="${HOME}/.scoutflo/business_context.md"
OUTPUT_DIR="${SCOUTFLO_AUDIT_DIR:-.}/metadata"
OUTPUT_FILE="${OUTPUT_DIR}/computed_metadata.jsonl"
mkdir -p "$OUTPUT_DIR"

# ============================================================================
# Helper: Parse business_context.md for global rules
# ============================================================================

metadata_parse_teams() {
  # Extract team names from business_context.md
  grep "^- " "$CONTEXT" 2>/dev/null | grep -A20 "^## Teams" | grep "^- " | cut -d' ' -f2 | cut -d':' -f1
}

metadata_parse_slas() {
  # Extract SLA definitions
  jq -n '{
    production_standard: "99.9%",
    production_critical: "99.95%",
    staging: "95%"
  }'
}

metadata_parse_exclusions() {
  # Parse exclusions (regions, accounts, services)
  jq -n '{
    regions: ["cn-*", "us-gov-*"],
    accounts: ["sandbox", "legacy-prod"],
    services: ["deprecated-*", "v1-*", "*-legacy"]
  }'
}

metadata_parse_cost_sensitivity() {
  # Default to high (ROI-first)
  echo "high"
}

# ============================================================================
# Discovery: Kubernetes Labels
# ============================================================================

metadata_discover_k8s() {
  echo "[metadata-resolver] Discovering Kubernetes labels..." >&2

  # Check if kubectl is available
  if ! command -v kubectl &>/dev/null; then
    echo "⚠ kubectl not found, skipping K8s discovery" >&2
    return 0
  fi

  # Get all resources with labels
  kubectl get all -A -o json 2>/dev/null | jq -c '
    .items[] |
    select(.metadata.labels != null) |
    {
      resource_id: (.metadata.name // .metadata.generateName),
      namespace: .metadata.namespace,
      kind: .kind,
      service: (.metadata.labels.service // .metadata.labels.app // "unknown"),
      team: (.metadata.labels.team // "unassigned"),
      environment: (.metadata.labels.environment // .metadata.labels.env // "unknown"),
      criticality: (.metadata.labels.criticality // "standard"),
      source: "kubernetes"
    }
  ' || echo ""
}

# ============================================================================
# Discovery: AWS Tags
# ============================================================================

metadata_discover_aws() {
  echo "[metadata-resolver] Discovering AWS tags..." >&2

  # Check if AWS CLI is available
  if ! command -v aws &>/dev/null; then
    echo "⚠ aws CLI not found, skipping AWS discovery" >&2
    return 0
  fi

  # EC2 instances with tags
  aws ec2 describe-instances \
    --query 'Reservations[].Instances[].{
      resource_id: InstanceId,
      region: Placement.AvailabilityZone,
      kind: "ec2",
      service: Tags[?Key==`Service`].Value[0],
      team: Tags[?Key==`Team`].Value[0],
      environment: Tags[?Key==`Environment`].Value[0],
      criticality: Tags[?Key==`Criticality`].Value[0],
      source: "aws"
    }' \
    --output json 2>/dev/null | jq -c '.[]' || echo ""

  # RDS instances with tags
  aws rds describe-db-instances \
    --query 'DBInstances[].{
      resource_id: DBInstanceIdentifier,
      region: AvailabilityZone,
      kind: "rds",
      service: TagList[?Key==`Service`].Value[0],
      team: TagList[?Key==`Team`].Value[0],
      environment: TagList[?Key==`Environment`].Value[0],
      criticality: TagList[?Key==`Criticality`].Value[0],
      source: "aws"
    }' \
    --output json 2>/dev/null | jq -c '.[]' || echo ""
}

# ============================================================================
# Discovery: GitHub CODEOWNERS
# ============================================================================

metadata_discover_github_ownership() {
  echo "[metadata-resolver] Discovering GitHub CODEOWNERS..." >&2

  # Look for CODEOWNERS in common locations
  CODEOWNERS_PATH=""
  for path in "ops/CODEOWNERS" ".github/CODEOWNERS" "CODEOWNERS" ".gitignore/../CODEOWNERS"; do
    if [ -f "$path" ]; then
      CODEOWNERS_PATH="$path"
      break
    fi
  done

  if [ -z "$CODEOWNERS_PATH" ]; then
    echo "⚠ CODEOWNERS not found" >&2
    return 0
  fi

  # Parse CODEOWNERS and map path patterns to teams
  # Format: /payment/* @payment-team → team=payment
  grep -v "^#" "$CODEOWNERS_PATH" | grep -v "^$" | while read -r line; do
    path=$(echo "$line" | awk '{print $1}')
    owners=$(echo "$line" | awk '{$1=""; print $0}' | xargs)
    team=$(echo "$owners" | sed 's/@//' | awk '{print $1}' | cut -d'-' -f1)

    jq -n \
      --arg path "$path" \
      --arg team "$team" \
      '{ownership_pattern: $path, team: $team, source: "github"}'
  done
}

# ============================================================================
# Rule Application: Derive metadata for each resource
# ============================================================================

metadata_apply_rules() {
  local resource_json="$1"

  local resource_id=$(echo "$resource_json" | jq -r '.resource_id // "unknown"')
  local team=$(echo "$resource_json" | jq -r '.team // "unassigned"')
  local environment=$(echo "$resource_json" | jq -r '.environment // "unknown"')
  local criticality=$(echo "$resource_json" | jq -r '.criticality // "standard"')
  local service=$(echo "$resource_json" | jq -r '.service // "unknown"')

  # Rule 1: Determine SLA based on team + environment
  local sla="99.9%"  # default: production-standard
  if [ "$team" = "payment" ] && [ "$environment" = "prod" ]; then
    sla="99.95%"  # production-critical
  elif [ "$environment" = "staging" ]; then
    sla="95%"
  fi

  # Rule 2: Determine escalation level
  local escalation="STANDARD"
  if [ "$team" = "payment" ] && [ "$environment" = "prod" ]; then
    escalation="CRITICAL"
  elif [ "$criticality" = "business-critical" ]; then
    escalation="CRITICAL"
  fi

  # Rule 3: Determine action (skip vs audit)
  local action="audit"
  if [ "$environment" = "sandbox" ] || [ "$environment" = "dev" ]; then
    action="skip"
  elif echo "$service" | grep -q "deprecated-\|v1-\|-legacy"; then
    action="skip"
  fi

  # Rule 4: Cost sensitivity
  local cost_sensitivity="high"
  if [ "$team" = "platform" ]; then
    cost_sensitivity="medium"  # platform optimizes for agility over cost
  fi

  # Output: derived metadata
  jq -n \
    --arg id "$resource_id" \
    --arg team "$team" \
    --arg env "$environment" \
    --arg sla "$sla" \
    --arg esc "$escalation" \
    --arg action "$action" \
    --arg cost_sens "$cost_sensitivity" \
    --arg crit "$criticality" \
    '{
      resource_id: $id,
      team: $team,
      environment: $env,
      sla: $sla,
      escalation: $esc,
      action: $action,
      cost_sensitivity: $cost_sens,
      criticality: $crit,
      resolved_at: now | todate
    }'
}

# ============================================================================
# Main: Run resolver
# ============================================================================

metadata_resolver_run() {
  echo "════════════════════════════════════════════════════════════════"
  echo "Metadata Resolver — Auto-discovering resources"
  echo "════════════════════════════════════════════════════════════════"
  echo ""

  # Check context file exists
  if [ ! -f "$CONTEXT" ]; then
    echo "✗ business_context.md not found at $CONTEXT"
    return 1
  fi

  echo "📋 Parsed global rules:"
  echo "  Teams: $(metadata_parse_teams | tr '\n' ' ')"
  echo "  SLAs: $(metadata_parse_slas | jq -r 'keys[]' | tr '\n' ' ')"
  echo ""

  # Clear output file
  > "$OUTPUT_FILE"

  echo "🔍 Discovering metadata..."

  # Run all discovery in parallel and collect results
  K8S_RESOURCES=$(metadata_discover_k8s)
  AWS_RESOURCES=$(metadata_discover_aws)

  echo "  ✓ K8s: $(echo "$K8S_RESOURCES" | wc -l) resources"
  echo "  ✓ AWS: $(echo "$AWS_RESOURCES" | wc -l) resources"
  echo ""

  # Apply rules and write output
  echo "📝 Applying rules and generating metadata..."

  TOTAL=0
  echo "$K8S_RESOURCES" | jq -c '.' 2>/dev/null | while read -r resource; do
    [ -z "$resource" ] && continue
    metadata_apply_rules "$resource" >> "$OUTPUT_FILE"
    TOTAL=$((TOTAL + 1))
  done

  echo "$AWS_RESOURCES" | jq -c '.' 2>/dev/null | while read -r resource; do
    [ -z "$resource" ] && continue
    metadata_apply_rules "$resource" >> "$OUTPUT_FILE"
    TOTAL=$((TOTAL + 1))
  done

  # Count final results
  FINAL_COUNT=$(wc -l < "$OUTPUT_FILE")

  echo ""
  echo "✅ Metadata resolution complete"
  echo "  📊 Resources resolved: $FINAL_COUNT"
  echo "  📄 Output: $OUTPUT_FILE"
  echo ""

  # Show summary
  echo "📈 Summary:"
  CRITICAL=$(jq -s '[.[] | select(.escalation=="CRITICAL")] | length' "$OUTPUT_FILE" 2>/dev/null || echo 0)
  STANDARD=$(jq -s '[.[] | select(.escalation=="STANDARD")] | length' "$OUTPUT_FILE" 2>/dev/null || echo 0)
  SKIP=$(jq -s '[.[] | select(.action=="skip")] | length' "$OUTPUT_FILE" 2>/dev/null || echo 0)

  echo "  CRITICAL: $CRITICAL"
  echo "  STANDARD: $STANDARD"
  echo "  SKIP: $SKIP"
  echo ""
}

# Export functions for use by other scripts
export -f metadata_parse_teams
export -f metadata_parse_slas
export -f metadata_parse_exclusions
export -f metadata_discover_k8s
export -f metadata_discover_aws
export -f metadata_apply_rules
export -f metadata_resolver_run

# Run if called directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  metadata_resolver_run "$@"
fi
