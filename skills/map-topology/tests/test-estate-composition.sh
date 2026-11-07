#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$ROOT"
python3 "$ROOT/skills/map-topology/tests/estate-composition.py"
