#!/bin/sh
# Hermetic regressions: no Datadog calls, real fixed recipes and projections.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
exec python3 "$ROOT/skills/audit-datadog/tests/datadog-evidence.py" "$ROOT"
