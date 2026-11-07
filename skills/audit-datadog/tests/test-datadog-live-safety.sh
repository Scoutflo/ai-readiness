#!/bin/sh
# Execute the published live-safety block against isolated provider stand-ins.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
PYTHONDONTWRITEBYTECODE=1 exec python3 "$ROOT/skills/audit-datadog/tests/datadog-live-safety.py" "$ROOT"
