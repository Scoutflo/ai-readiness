#!/bin/sh
# Generic leak scan: machine paths, emails, 12-digit cloud account ids,
# private IPs, inline tokens. Literal-identifier scanning happens in the
# maintainers' private pre-push hook; this is the public backstop.
# ci/ is excluded because it is the scanners' own scaffolding and legitimately
# embeds leak-shaped TEST VECTORS (this pattern's example strings). A directory
# named selftest is also excluded: the maintainer's LOCAL test harness (kept
# outside this repo) writes fabricated leak vectors to temp dirs, so excluding an
# adjacent selftest/ keeps a scan clean. These vectors are never real secrets.
set -eu
DIR="${1:-.}"
FAIL=0
grep -rnE '/Users/[a-z]+/|/home/[a-z]+/|[A-Z]:\\\\Users\\\\' "$DIR" --exclude-dir=.git --exclude-dir=ci --exclude-dir=selftest && FAIL=1
grep -rnE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.(com|dev|io|cloud)' "$DIR" --exclude-dir=.git --exclude-dir=ci --exclude-dir=selftest --exclude=README.md --exclude=marketplace.json --exclude=plugin.json && FAIL=1
# 123456789012 is AWS's own canonical example account ID, used throughout AWS's
# documentation and intentionally throughout this toolkit's AWS skills as the
# placeholder account ID; any other 12-digit run is still flagged.
# The boundary is tightened past \b so a 12-digit run that is really part of a
# longer decimal (e.g. the fractional 317542016506 in 4899.317542016506) or a
# hyphenated hex UUID segment (e.g. 850781672742 in dbcf88af-...-850781672742)
# is NOT matched — those appear in audits' own raw/ output and are not secrets.
# A period, hyphen, or hex digit on either side disqualifies the run; a real AWS
# account id standalone or in an ARN (arn:aws:iam::987654321098:role/x, bounded
# by ':') still matches. POSIX ERE only — no PCRE lookaround (Linux CI + /bin/sh).
grep -rnE '(^|[^-.0-9A-Fa-f])[0-9]{12}([^-.0-9A-Fa-f]|$)' "$DIR" --exclude-dir=.git --exclude-dir=ci --exclude-dir=selftest | grep -v '123456789012' && FAIL=1
grep -rnE '\b10\.[0-9]+\.[0-9]+\.[0-9]+\b|\b192\.168\.[0-9]+\.[0-9]+\b' "$DIR" --exclude-dir=.git --exclude-dir=ci --exclude-dir=selftest && FAIL=1
grep -rnE '(token|secret|password|api_key)["'"'"']?\s*[:=]\s*["'"'"'][A-Za-z0-9_\-]{16,}' "$DIR" --exclude-dir=.git --exclude-dir=selftest && FAIL=1
[ "$FAIL" -eq 0 ] && echo CLEAN || { echo "LEAK PATTERNS FOUND"; exit 1; }
