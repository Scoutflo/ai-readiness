#!/bin/sh
# Real consumer calls, synthetic evidence, no APIs. Counterexamples retain the
# same service name while changing exactly the missing/contradictory proof.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$ROOT"
python3 "$ROOT/skills/correlation-engine/tests/evidence-boundaries.py"
