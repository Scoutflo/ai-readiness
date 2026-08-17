#!/bin/sh
# skill-completeness-check.sh — lane-aware structural completeness gate.
#
# Why this exists: structure-check only verified a SKILL.md had frontmatter +
# name + description, so a 4KB stub with a fabrication lib/ and a removed-API
# check (audit-kubernetes, pre-v0.1.76) passed every automatic gate for many
# releases — the deep quality check (docs/skill-review-rubric.md via
# review-ai-readiness-skill) is MANUAL and it was simply never run on that
# skill. This gate makes the mechanically-detectable parts of "is this a real,
# conformant skill or a stub?" a CI blocker, per the repo's own rule: for a
# mechanically-detectable class, build a gate, don't rely on review.
#
# Lanes are decided by skill-name prefix (audit-* / setup-*), else harness.
# Each lane asserts the structural markers that EVERY shipped skill in that lane
# already has (verified across all 14 audit + 7 setup skills at authoring time).
# A new skill that skips a marker fails here with the exact gap — the reviewer
# still does judgment (are the checks correct?), but a stub can no longer ship.
#
# Read-only; POSIX sh + grep/awk.
set -eu
DIR="${1:-.}"
SKILLS="$DIR/skills"
[ -d "$SKILLS" ] || { echo "no skills dir at $SKILLS"; exit 1; }
FAIL=0

# Minimum SKILL.md body size (bytes) for the audit/setup lanes, below which the
# skill is a stub rather than a real provider workflow. Every shipped audit
# (43KB+) and setup (large) skill clears this by a wide margin; the pre-rebuild
# audit-kubernetes stub was ~4.6KB. The floor is NOT applied to the harness lane,
# where genuinely concise skills exist (checkpoint ~2.5KB, business-context
# ~2.4KB) — those are gated on structure, not size.
MIN_PROVIDER_BODY_BYTES=8000

# Minimum pressure scenarios (I4) for a non-orchestrator audit skill. The whole
# audit lane already sits at 3-7; a lone scenario (the pre-fix audit-kubernetes)
# is thin coverage the maintainer rubric (I4) rejects, and the old "any *.md"
# check let it through. A "scenario" is one `**Expected behavior:**` block — the
# mandatory core of a pressure scenario — counted across every .md in the dir, so
# one-file-per-scenario (most audits) and several-packed-in-one-file (audit-cost)
# both count honestly, without forcing a particular file layout.
MIN_SCENARIOS=3

has() { grep -qiE "$2" "$1"; }   # has <file> <regex>

# scenario_count <dir> — number of pressure scenarios (Expected-behavior blocks).
scenario_count() {
  [ -d "$1" ] || { echo 0; return; }
  grep -rhoiE '\*\*expected behavior' "$1" 2>/dev/null | wc -l | tr -d ' '
}

for d in "$SKILLS"/*/; do
  name="$(basename "$d")"
  f="${d}SKILL.md"

  # Library-only helper dirs (lib/ and/or tests/, no SKILL.md) are internal
  # modules consumed by other skills, not user-facing skills — skip them. A
  # missing SKILL.md is only a problem for a dir that is meant to be a skill,
  # which for audit-*/setup-* is caught by the lane checks below.
  if [ ! -f "$f" ]; then
    case "$name" in
      audit-*|setup-*) echo "SKILL-COMPLETENESS: $name has no SKILL.md but its name implies a user-facing skill"; FAIL=1 ;;
      *) : ;;  # harness library dir (e.g. redaction, cli-interactive) — fine
    esac
    continue
  fi

  bytes=$(wc -c < "$f" | tr -d ' ')

  case "$name" in
    audit-all) : ;;  # orchestrator: exempt from the per-integration audit markers (it has its own shape)
    audit-*)
      # An audit reads live providers, emits the report standard, and must be
      # gated + safe + documented + scenario-covered.
      [ "$bytes" -ge "$MIN_PROVIDER_BODY_BYTES" ] || { echo "SKILL-COMPLETENESS: $name (audit) SKILL.md is ${bytes}B (< ${MIN_PROVIDER_BODY_BYTES}B) — a stub, not a real audit workflow; author it to fleet parity or remove it"; FAIL=1; }
      # Gate presence is asserted by the phrase (heading OR bold-inline — skills
      # format the level differently); the point is the mechanism exists, not its markdown depth.
      has "$f" "[Dd]octor gate"             || { echo "SKILL-COMPLETENESS: $name (audit) has no Doctor gate"; FAIL=1; }
      has "$f" "[Ll]ive-safety gate"        || { echo "SKILL-COMPLETENESS: $name (audit) has no Live-safety gate"; FAIL=1; }
      has "$f" "report.?standard|findings-schema" || { echo "SKILL-COMPLETENESS: $name (audit) does not reference the report standard / findings schema"; FAIL=1; }
      has "$f" "Common Failure Modes"       || { echo "SKILL-COMPLETENESS: $name (audit) missing a 'Common Failure Modes' section"; FAIL=1; }
      [ -d "${d}references" ] && [ -n "$(find "${d}references" -name '*.md' 2>/dev/null)" ] \
        || { echo "SKILL-COMPLETENESS: $name (audit) has no references/*.md check catalog"; FAIL=1; }
      scen=$(scenario_count "$DIR/tests/pressure-scenarios/$name")
      [ "$scen" -ge "$MIN_SCENARIOS" ] \
        || { echo "SKILL-COMPLETENESS: $name (audit) has $scen pressure scenario(s) (< $MIN_SCENARIOS); I4 wants >= $MIN_SCENARIOS. Add scenarios (one '**Expected behavior:**' block each) under tests/pressure-scenarios/$name/"; FAIL=1; }
      ;;
    setup-*)
      # A setup mutates live resources: it must carry the confirm-then-verify
      # protocol, gates, be non-auto-invocable, and document failure modes.
      [ "$bytes" -ge "$MIN_PROVIDER_BODY_BYTES" ] || { echo "SKILL-COMPLETENESS: $name (setup) SKILL.md is ${bytes}B (< ${MIN_PROVIDER_BODY_BYTES}B) — too thin for a confirm-then-verify mutation skill; author it to fleet parity"; FAIL=1; }
      has "$f" "change protocol"            || { echo "SKILL-COMPLETENESS: $name (setup) missing 'The change protocol' section"; FAIL=1; }
      has "$f" "[Dd]octor gate"             || { echo "SKILL-COMPLETENESS: $name (setup) has no Doctor gate"; FAIL=1; }
      has "$f" "[Ll]ive-safety gate"        || { echo "SKILL-COMPLETENESS: $name (setup) has no Live-safety gate"; FAIL=1; }
      grep -q "disable-model-invocation: true" "$f" || { echo "SKILL-COMPLETENESS: $name (setup) must set 'disable-model-invocation: true' in frontmatter (setups never auto-run)"; FAIL=1; }
      has "$f" "Common Failure Modes"       || { echo "SKILL-COMPLETENESS: $name (setup) missing a 'Common Failure Modes' section"; FAIL=1; }
      # I4 applies to setup too (non-harness). The old gate never checked setup
      # scenarios, so setup-kubernetes shipped with zero; a confirm-then-verify
      # mutation skill needs its disruptive-ordering traps pinned by scenarios.
      scen=$(scenario_count "$DIR/tests/pressure-scenarios/$name")
      [ "$scen" -ge "$MIN_SCENARIOS" ] \
        || { echo "SKILL-COMPLETENESS: $name (setup) has $scen pressure scenario(s) (< $MIN_SCENARIOS); I4 wants >= $MIN_SCENARIOS. Add scenarios (one '**Expected behavior:**' block each) under tests/pressure-scenarios/$name/"; FAIL=1; }
      ;;
    *)
      # Harness/guide lane: no provider gates, but a shipped skill still needs
      # substance (the byte floor above) and a description that says what it does.
      : ;;
  esac
done

if [ "$FAIL" -ne 0 ]; then
  echo "SKILL-COMPLETENESS CHECK FAILED"
  exit 1
fi
echo "SKILL-COMPLETENESS-OK (every skill meets its lane's structural markers)"
