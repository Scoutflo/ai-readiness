#!/bin/sh
# cross-references.sh
# Link related findings across audits

set -eu

AUDIT_DIR="${SCOUTFLO_AUDIT_DIR:-.}/scoutflo-audits"

# --- Find related findings ---
xref_find_related() {
  finding_id="$1"
  audit_date="$2"

  # Extract service from finding ID (e.g., AWS-023 → AWS)
  service=$(echo "$finding_id" | sed 's/-[0-9]*$//')

  # Find findings with same service from different audits
  related=""

  for audit_dir in "$AUDIT_DIR/$audit_date"/audit-*/findings.json; do
    [ -f "$audit_dir" ] || continue

    audit_skill=$(echo "$audit_dir" | sed 's|.*audit-\([^/]*\)/.*|\1|')

    # Skip same skill
    if echo "$service" | grep -q "$(echo "$audit_skill" | tr 'a-z' 'A-Z')"; then
      continue
    fi

    # Find findings with similar keywords
    related_findings=$(jq -r ".findings[] | select(.title | test(\"[Aa]larm|[Aa]lert|[Mm]onitor\")) | .finding_id" "$audit_dir" 2>/dev/null || true)

    if [ -n "$related_findings" ]; then
      related="$related
$related_findings"
    fi
  done

  echo "$related" | grep -v '^$' | head -3
}

# --- Add cross-reference section to report ---
xref_add_to_report() {
  finding_id="$1"
  report_file="$2"
  audit_date="$3"

  related=$(xref_find_related "$finding_id" "$audit_date")

  if [ -z "$related" ]; then
    return 0
  fi

  # Append related findings section
  {
    echo ""
    echo "### Related Findings in Other Audits"
    echo ""
    echo "$related" | while read -r ref_id; do
      echo "- **$ref_id** — [View in audit](../audit-*/findings.md#$ref_id)"
    done
  } >> "$report_file"
}

# --- Add cross-references to findings.json ---
xref_add_to_findings() {
  findings_file="$1"
  audit_date="$2"

  # For each finding, add related_findings array
  jq '.findings[] |= (
    .related_findings = []
  )' "$findings_file" > "$findings_file.tmp"

  mv "$findings_file.tmp" "$findings_file"
}
