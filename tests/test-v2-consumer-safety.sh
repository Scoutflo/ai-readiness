#!/bin/sh
# Locks the prompt-level consumers that assemble combined and Slack output.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }

ALL="$ROOT/skills/audit-all/SKILL.md"

grep -q 'score.overall == null then "unassessed"' "$ALL" \
  || fail "audit-all does not render null readiness as unassessed"
grep -q 'select((.lifecycle // "new") != "suppressed")' "$ALL" \
  || fail "audit-all top findings do not exclude suppressed findings"
grep -q '.scoring_model == $model and .check_set == $set' "$ALL" \
  || fail "audit-all history does not require a compatible scoring model and check set"
grep -q 'v2 assessment coverage:' "$ALL" \
  || fail "audit-all brief does not expose v2 assessment coverage"

for skill in audit-aws audit-lgtm audit-grafana; do
  file="$ROOT/skills/$skill/SKILL.md"
  grep -q 'select((.lifecycle // "new") != "suppressed")' "$file" \
    || fail "$skill Slack top findings include suppressed findings"
  grep -q '\.suppressed_checks) suppressed' "$file" \
    || fail "$skill Slack assessment line omits suppressed checks"
  grep -q 'scoring_scope' "$file" \
    || fail "$skill does not require explicit v2 finding scoring scope"
done
grep -q 'scoring_scope' "$ROOT/skills/audit-elk/SKILL.md" \
  || fail "audit-elk does not require explicit v2 finding scoring scope"

AWS_SKILL="$ROOT/skills/audit-aws/SKILL.md"
AWS_REF="$ROOT/skills/audit-aws/references/aws-checks.md"
PROVIDERS="$ROOT/skills/connect/references/providers.md"
for file in "$AWS_SKILL" "$PROVIDERS"; do
  grep -q 'application-signals:ListServiceLevelObjectives' "$file" \
    || fail "AWS documented read scope omits Application Signals list access in $file"
  grep -q 'docdb:Describe\*' "$file" \
    || fail "AWS documented read scope omits DocumentDB access in $file"
  grep -Fq 'logs:Describe*`/`List*' "$file" \
    || fail "AWS documented read scope omits CloudWatch Logs list access in $file"
done
grep -q 'AWS-007 blocked: Application Signals list failed' "$AWS_REF" \
  || fail "AWS-007 does not classify a failed Application Signals read as blocked"
grep -q 'AWS-056 blocked: detector list failed' "$AWS_REF" \
  || fail "AWS-056 does not classify a failed anomaly-detector read as blocked"
grep -q 'list-service-level-objectives --output json 2>/dev/null' "$AWS_REF" \
  && fail "AWS-007 still discards permission errors"
grep -q 'list-log-anomaly-detectors --output json 2>/dev/null' "$AWS_REF" \
  && fail "AWS-056 still discards permission errors"

echo "V2-CONSUMER-SAFETY-OK"
