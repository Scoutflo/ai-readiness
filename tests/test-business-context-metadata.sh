#!/bin/sh
# Run the actual scored-audit Metadata Load fences with isolated local inputs.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
exec python3 "$ROOT/tests/business-context-metadata.py" "${BC_METADATA_TEST_ROOT:-$ROOT}"
