#!/bin/sh
# business-context-parity-check.sh — every audit-* (except audit-all) must carry
# a Metadata Load block that reads the business-context SSOT projection and
# states the concrete apply behavior, so business context is honored uniformly
# rather than in an inconsistent subset of audits.
#
# Why this exists: 11 of 14 audits had a Metadata Load block and 3 had none, and
# the ones that had it mostly set a mode flag without reading the derived
# projection or naming the apply behavior. This gate requires (a) the block
# exists, (b) it references the SSOT projection (business_context.json) or the
# per-resource cache (computed_metadata.jsonl), and (c) it names at least one
# concrete apply behavior (exclude / escalate critical / cost sensitivity /
# per-environment SLA) — so the context actually changes the audit, not just a
# flag that is read and ignored.
#
# Read-only. POSIX sh + grep.
set -eu
DIR="${1:-.}"
FAIL=0

for d in "$DIR"/skills/audit-*/; do
  name="$(basename "$d")"
  [ "$name" = "audit-all" ] && continue   # orchestrator: pre-loads metadata once, each audit reads it
  f="${d}SKILL.md"
  [ -f "$f" ] || continue

  # (a) the block exists
  if ! grep -qiE 'Metadata Load|LOAD_METADATA_MODE' "$f"; then
    echo "BUSINESS-CONTEXT: ${name} has no Metadata Load block — it cannot honor business context (SLAs, exclusions, critical services); add the block per docs/BUSINESS-CONTEXT-INTEGRATION-v0168.md"
    FAIL=1
    continue
  fi
  # (b) it reads the SSOT projection or the per-resource cache
  if ! grep -qE 'business_context\.json|business_context\.md|computed_metadata\.jsonl' "$f"; then
    echo "BUSINESS-CONTEXT: ${name} Metadata Load does not read the SSOT (business_context.json / computed_metadata.jsonl) — it sets a mode but has no source to apply"
    FAIL=1
  fi
  # (c) it names at least one concrete apply behavior
  if ! grep -qiE 'exclud|escalat|critical service|cost.sensitiv|per-environment|environment.*SLA|reduce.*severity|staging.*sever' "$f"; then
    echo "BUSINESS-CONTEXT: ${name} Metadata Load reads context but names no apply behavior (exclude excluded resources / escalate critical services / cost sensitivity / per-env SLA) — a flag that is read and ignored"
    FAIL=1
  fi
done

if [ "$FAIL" -ne 0 ]; then
  echo "BUSINESS-CONTEXT CHECK FAILED"
  exit 1
fi
echo "BUSINESS-CONTEXT-OK (every audit-* reads the business-context SSOT and states its apply behavior)"
