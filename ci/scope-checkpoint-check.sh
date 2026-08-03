#!/bin/sh
# scope-checkpoint-check.sh — behavioral-parity gate for the estate-sizing scope
# checkpoint. Every audit-* skill (except audit-all, the orchestrator) must wire
# the shared pause+scope mechanism into its run, so a large estate is never
# ground unbounded with no scoping question.
#
# Why this exists: the cli_pause_before_audit / cli_prompt_exclude_services
# helpers and the checkpoint skill shipped in v0.1.65, but NO audit actually
# called them — so audit-grafana (4,017 objects) and audit-aws (1,336) ground
# through the whole estate with no pause. Structural gates (skill-completeness)
# check that a skill HAS an estate-sizing section; they do not check that it
# ACTS on it. This gate closes that behavioral gap and stops it re-rotting.
#
# A skill passes when it calls cli_pause_before_audit (the confirm-before-large
# helper). That call is the observable proof the pause is wired; a skill that
# only mentions it in prose without the call fails.
#
# Read-only. POSIX sh + grep.
set -eu
DIR="${1:-.}"
FAIL=0

for d in "$DIR"/skills/audit-*/; do
  name="$(basename "$d")"
  [ "$name" = "audit-all" ] && continue     # orchestrator; delegates to each audit's own pause
  f="${d}SKILL.md"
  [ -f "$f" ] || continue

  # The observable proof: the skill invokes the confirm-before-large helper.
  if ! grep -q 'cli_pause_before_audit' "$f"; then
    echo "SCOPE-CHECKPOINT: ${name} never calls cli_pause_before_audit — a large estate would grind unbounded with no scoping pause (wire the shared checkpoint from report-standard/estate-scope-checkpoint.md into its Estate sizing phase)"
    FAIL=1
    continue
  fi
  # Guard against a bare mention with no real threshold gate around it.
  if ! grep -qE 'ge 501|-ge 501|>= *501|1000' "$f"; then
    echo "SCOPE-CHECKPOINT: ${name} calls cli_pause_before_audit but has no large-estate threshold gate (>=501/1000) around it — the pause must actually trigger on a large estate"
    FAIL=1
  fi
done

if [ "$FAIL" -ne 0 ]; then
  echo "SCOPE-CHECKPOINT CHECK FAILED"
  exit 1
fi
echo "SCOPE-CHECKPOINT-OK (every audit-* wires the estate-sizing scope pause)"
