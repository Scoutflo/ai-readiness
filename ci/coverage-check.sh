#!/bin/sh
# Coverage sanity check: every audit-* skill must be surfaced consistently across
# the onboarding/reference surfaces, so a provider can never be auditable but
# invisible in connect's picker (the "only 9 shown" class of drift).
#
# For each skills/audit-<x>/ (except audit-all, the orchestrator), assert:
#   1. connect Step 1 "Pick your integrations" table references audit-<x>
#   2. start SKILL.md catalog lists /scoutflo:audit-<x>
# These are the two surfaces a user reads to discover what they can connect/run.
# Read-only, POSIX sh + grep/sed/awk.
set -eu
DIR="${1:-.}"
FAIL=0
CONNECT="$DIR/skills/connect/SKILL.md"
START="$DIR/skills/start/SKILL.md"

# Extract just the Step 1 picker table from connect (between the heading and Step 2).
PICKER="$(awk '/## Step 1: Pick your integrations/{f=1} /## Step 2/{f=0} f' "$CONNECT" 2>/dev/null)"

for d in "$DIR"/skills/audit-*/; do
  name="$(basename "$d")"            # e.g. audit-grafana
  [ "$name" = "audit-all" ] && continue
  # 1. connect picker must reference this audit skill by name
  if ! printf '%s' "$PICKER" | grep -q "$name"; then
    echo "COVERAGE: ${name} exists but is NOT offered in connect Step 1 'Pick your integrations' — a user can't discover/connect it"
    FAIL=1
  fi
  # 2. start catalog must list the slash command
  if ! grep -q "/scoutflo:${name}\b" "$START" 2>/dev/null; then
    echo "COVERAGE: ${name} exists but is NOT in the /scoutflo:start catalog — a user can't see it in the skill list"
    FAIL=1
  fi
done

# 3. Every top-level integration key in the toolkit template must have a
#    canonical `<key>:` YAML block in connect's providers.md. This is what a
#    session copies from when re-adding a block that was deleted earlier —
#    without it the model reconstructs key names from memory and invents
#    wrong ones (the CoinDCX re-add class).
TEMPLATE="$DIR/templates/toolkit.yaml.example"
PROVIDERS="$DIR/skills/connect/references/providers.md"
if [ -f "$TEMPLATE" ] && [ -f "$PROVIDERS" ]; then
  for key in $(grep '^[a-z_]*:' "$TEMPLATE" | sed 's/:.*//'); do
    if ! grep -q "^${key}:" "$PROVIDERS"; then
      echo "COVERAGE: template block '${key}:' has no canonical Config block in connect references/providers.md — a deleted block can't be re-added verbatim"
      FAIL=1
    fi
  done
fi

if [ "$FAIL" -eq 0 ]; then
  echo "COVERAGE-OK (every audit-* is surfaced in connect Step 1 and the start catalog; every template block has a canonical providers.md source)"
fi
exit "$FAIL"
