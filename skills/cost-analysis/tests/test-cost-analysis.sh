#!/bin/sh
# test-cost-analysis.sh - Cost analysis aggregation and scoring tests

set -eu

echo "=== Cost Analysis Tests ==="

COST_LIB="${BATS_TEST_DIRNAME}/../lib"
TEST_AUDIT_DIR="/tmp/cost-analysis-test-audits"
TEST_COST_HISTORY="$TEST_AUDIT_DIR/cost-analysis.jsonl"
TEST_TOPOLOGY="/tmp/cost-analysis-topology.json"
export SCOUTFLO_AUDIT_DIR="$TEST_AUDIT_DIR"
export TOPOLOGY_FILE="$TEST_TOPOLOGY"

setup() {
  mkdir -p "$TEST_AUDIT_DIR/aws/2026-07-30"
  mkdir -p "$TEST_AUDIT_DIR/gcp/2026-07-30"
  rm -f "$TEST_COST_HISTORY" "$TEST_TOPOLOGY"
}

teardown() {
  rm -rf "$TEST_AUDIT_DIR" "$TEST_TOPOLOGY"
}

@test "cost-analysis: skip logic detects current analysis" {
  . "${COST_LIB}/cost-analysis.sh"

  # Create old history entry (23h ago)
  yesterday=$(date -d "23 hours ago" +%Y-%m-%d)
  echo "{\"date\":\"$yesterday\",\"overall\":40,\"monthly_waste\":500}" > "$TEST_COST_HISTORY"

  should_skip=$(cost_analysis_should_skip && echo "1" || echo "0")
  [ "$should_skip" = "1" ] || { echo "FAIL: Expected to skip (23h old, no new findings)"; exit 1; }
}

@test "cost-analysis: skip logic detects >24h old" {
  . "${COST_LIB}/cost-analysis.sh"

  # Create old history entry (25h ago)
  old_date=$(date -d "25 hours ago" +%Y-%m-%d)
  echo "{\"date\":\"$old_date\",\"overall\":40,\"monthly_waste\":500}" > "$TEST_COST_HISTORY"

  should_skip=$(cost_analysis_should_skip && echo "1" || echo "0")
  [ "$should_skip" = "0" ] || { echo "FAIL: Expected to RUN (25h old > 24h threshold)"; exit 1; }
}

@test "cost-analysis: first run always runs (no history)" {
  . "${COST_LIB}/cost-analysis.sh"

  [ ! -f "$TEST_COST_HISTORY" ] || { echo "FAIL: History file should not exist"; exit 1; }

  should_skip=$(cost_analysis_should_skip && echo "1" || echo "0")
  [ "$should_skip" = "0" ] || { echo "FAIL: Expected to RUN (first run, no history)"; exit 1; }
}

@test "cost-analysis: aggregates findings from multiple audits" {
  . "${COST_LIB}/cost-analysis.sh"

  # Create AWS findings with cost_section
  aws_findings=$(jq -n '{
    target: "aws",
    findings: [],
    cost_section: {
      captured_at: "2026-07-30T14:00:00Z",
      data_source: "AWS Cost Explorer",
      findings: [
        {id: "COST-AWS-001", title: "Stopped instances", monthly_cost: 320},
        {id: "COST-AWS-002", title: "Underutilized RDS", monthly_cost: 120}
      ],
      total_identifiable_waste: 440
    }
  }')
  echo "$aws_findings" > "$TEST_AUDIT_DIR/aws/2026-07-30/findings.json"

  # Create GCP findings with cost_section
  gcp_findings=$(jq -n '{
    target: "gcp",
    findings: [],
    cost_section: {
      captured_at: "2026-07-30T14:10:00Z",
      data_source: "GCP Cost Management",
      findings: [
        {id: "COST-GCP-001", title: "Unused disks", monthly_cost: 85}
      ],
      total_identifiable_waste: 85
    }
  }')
  echo "$gcp_findings" > "$TEST_AUDIT_DIR/gcp/2026-07-30/findings.json"

  # Aggregate
  aggregated=$(cost_analysis_aggregate_findings "2026-07-30")
  count=$(echo "$aggregated" | jq 'length')

  [ "$count" = "2" ] || { echo "FAIL: Expected 2 cost sections (AWS + GCP), got $count"; exit 1; }

  # Verify AWS source metadata
  aws_source=$(echo "$aggregated" | jq -r '.[0].source_target')
  [ "$aws_source" = "aws" ] || { echo "FAIL: Expected aws source, got $aws_source"; exit 1; }
}

@test "cost-analysis: deduplicates overlapping findings" {
  . "${COST_LIB}/cost-analysis.sh"

  # Create findings
  findings=$(jq -n '[
    {
      source_target: "aws",
      findings: [{id: "COST-AWS-001", title: "CloudWatch alerts"}]
    },
    {
      source_target: "gcp",
      findings: [{id: "COST-GCP-001", title: "Same resource"}]
    }
  ]')

  # Create correlation showing AWS-001 overlaps with GCP-001
  correlation_file="$TEST_AUDIT_DIR/correlation.json"
  mkdir -p "$TEST_AUDIT_DIR"
  jq -n '{
    overlaps: [
      {
        findings: [
          {finding_id: "COST-AWS-001"},
          {finding_id: "COST-GCP-001"}
        ],
        recommendation: "AWS primary, GCP secondary"
      }
    ],
    cascades: []
  }' > "$correlation_file"

  deduped=$(cost_analysis_deduplicate "$findings")

  # Verify dedup flag set
  has_dedup=$(echo "$deduped" | jq '[.[] | select(.deduplicated == true)] | length')
  [ "$has_dedup" -ge 1 ] || { echo "FAIL: Expected deduplicated findings, got $has_dedup"; exit 1; }
}

@test "cost-analysis: calculates score based on waste percentage" {
  . "${COST_LIB}/cost-analysis.sh"

  findings=$(jq -n '[
    {total_identifiable_waste: 440, findings: [{monthly_cost: 320}, {monthly_cost: 120}]},
    {total_identifiable_waste: 85, findings: [{monthly_cost: 85}]}
  ]')

  context=$(jq -n '{
    environment: "production",
    cost_sensitivity: "medium"
  }')

  score=$(cost_analysis_calculate_score "$findings" "$context")
  [ "$score" -ge 0 ] && [ "$score" -le 100 ] || { echo "FAIL: Score out of range: $score"; exit 1; }
}

@test "cost-analysis: builds report with findings sorted by priority" {
  . "${COST_LIB}/cost-analysis.sh"

  findings=$(jq -n '[
    {source_target: "aws", findings: [
      {id: "COST-AWS-001", title: "Stopped instances", monthly_cost: 320},
      {id: "COST-AWS-002", title: "Underutilized RDS", monthly_cost: 120}
    ]},
    {source_target: "gcp", findings: [
      {id: "COST-GCP-001", title: "Unused disks", monthly_cost: 85}
    ]}
  ]')

  context=$(jq -n '{
    environment: "production",
    cost_sensitivity: "medium"
  }')

  report=$(cost_analysis_build_report "2026-07-30" "$findings" "$context")

  # Verify structure
  report_date=$(echo "$report" | jq -r '.audit_date')
  [ "$report_date" = "2026-07-30" ] || { echo "FAIL: Expected date 2026-07-30, got $report_date"; exit 1; }

  # Verify findings sorted by cost (highest first)
  first_cost=$(echo "$report" | jq '.findings[0].monthly_cost')
  second_cost=$(echo "$report" | jq '.findings[1].monthly_cost')
  [ "$first_cost" -ge "$second_cost" ] || { echo "FAIL: Findings not sorted by cost"; exit 1; }

  # Verify summary
  total=$(echo "$report" | jq '.summary.total_findings')
  [ "$total" = "3" ] || { echo "FAIL: Expected 3 findings in summary, got $total"; exit 1; }
}

@test "cost-analysis: sorts by ROI when cost_sensitivity=high" {
  . "${COST_LIB}/cost-analysis.sh"

  findings=$(jq -n '[
    {source_target: "aws", findings: [
      {id: "COST-AWS-001", type: "stopped_instances", monthly_cost: 320},
      {id: "COST-AWS-002", type: "underutilized_rds", monthly_cost: 50}
    ]}
  ]')

  context=$(jq -n '{
    environment: "production",
    cost_sensitivity: "high"
  }')

  report=$(cost_analysis_build_report "2026-07-30" "$findings" "$context")

  # With high sensitivity, should still sort by monthly_cost in this case
  # (ROI = monthly * 12, so ranking is same)
  first_id=$(echo "$report" | jq -r '.findings[0].id')
  [ "$first_id" = "COST-AWS-001" ] || { echo "FAIL: Expected COST-AWS-001 first (highest cost), got $first_id"; exit 1; }
}

@test "cost-analysis: appends to history on run" {
  . "${COST_LIB}/cost-analysis.sh"

  # Create minimal audit findings
  aws_findings=$(jq -n '{
    target: "aws",
    findings: [],
    cost_section: {
      findings: [{id: "COST-AWS-001", monthly_cost: 100}],
      total_identifiable_waste: 100
    }
  }')
  echo "$aws_findings" > "$TEST_AUDIT_DIR/aws/2026-07-30/findings.json"

  # Run cost-analysis
  cost_analysis_run "2026-07-30" 2>/dev/null || true

  # Verify history appended
  [ -f "$TEST_COST_HISTORY" ] || { echo "FAIL: History file not created"; exit 1; }

  history_lines=$(wc -l < "$TEST_COST_HISTORY")
  [ "$history_lines" -ge 1 ] || { echo "FAIL: History not appended"; exit 1; }

  # Verify entry structure
  entry=$(tail -1 "$TEST_COST_HISTORY")
  date=$(echo "$entry" | jq -r '.date')
  [ "$date" = "2026-07-30" ] || { echo "FAIL: History date mismatch: $date"; exit 1; }
}

@test "cost-analysis: handles missing correlation.json gracefully" {
  . "${COST_LIB}/cost-analysis.sh"

  findings=$(jq -n '[{source_target: "aws", findings: [{id: "COST-AWS-001", monthly_cost: 100}]}]')

  # No correlation file exists
  [ ! -f "$TEST_AUDIT_DIR/correlation.json" ] || { echo "FAIL: Correlation should not exist"; exit 1; }

  # Deduplicate should return findings as-is
  deduped=$(cost_analysis_deduplicate "$findings")
  count=$(echo "$deduped" | jq 'length')
  [ "$count" = "1" ] || { echo "FAIL: Expected 1 finding (no dedup), got $count"; exit 1; }
}

echo "=== All cost-analysis tests passed ==="
