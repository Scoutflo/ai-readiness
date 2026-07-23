#!/bin/sh
# Generic leak scan: machine paths, emails, 12-digit cloud account ids,
# private IPs, inline tokens. Literal-identifier scanning happens in the
# maintainers' private pre-push hook; this is the public backstop.
set -eu
DIR="${1:-.}"
FAIL=0
grep -rnE '/Users/[a-z]+/|/home/[a-z]+/|[A-Z]:\\\\Users\\\\' "$DIR" --exclude-dir=.git --exclude-dir=ci && FAIL=1
grep -rnE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.(com|dev|io|cloud)' "$DIR" --exclude-dir=.git --exclude-dir=ci --exclude=README.md --exclude=marketplace.json --exclude=plugin.json && FAIL=1
# 123456789012 is AWS's own canonical example account ID, used throughout AWS's
# documentation and intentionally throughout this toolkit's AWS skills as the
# placeholder account ID; any other 12-digit run is still flagged.
grep -rnE '\b[0-9]{12}\b' "$DIR" --exclude-dir=.git --exclude-dir=ci | grep -v '123456789012' && FAIL=1
grep -rnE '\b10\.[0-9]+\.[0-9]+\.[0-9]+\b|\b192\.168\.[0-9]+\.[0-9]+\b' "$DIR" --exclude-dir=.git --exclude-dir=ci && FAIL=1
grep -rnE '(token|secret|password|api_key)["'"'"']?\s*[:=]\s*["'"'"'][A-Za-z0-9_\-]{16,}' "$DIR" --exclude-dir=.git && FAIL=1
[ "$FAIL" -eq 0 ] && echo CLEAN || { echo "LEAK PATTERNS FOUND"; exit 1; }
