#!/bin/sh
# content-type-probe-check.sh — an AUTHENTICATED HTTP doctor/verify probe must not judge
# success on the HTTP status code alone. A 200 that returns an HTML SSO/login/SPA page — a
# moved path, a POST-only route hit with GET, or a reverse proxy fronting auth — is a
# false green: the request never reached the API. This gate makes the anti-false-green
# discipline mechanical.
#
# Why this exists: caught live on SigNoz v0.138 — a `curl -s -o /dev/null -w '%{http_code}'`
# probe against /api/v1/rules would report "authed ok" on a 200 even when the body was the
# SPA index.html (a path moved / a proxy answered), because `-o /dev/null` threw the body
# away. The fix pattern (already in doctor.sh and audit-signoz): drop `-o /dev/null`, add
# `%{content_type}` to `-w`, and require a JSON content-type (or a jq body assertion) before
# crediting a pass.
#
# What it flags: a curl invocation that
#   (1) uses `-o /dev/null` together with `-w '%{http_code}'` (a status-only probe), AND
#   (2) carries an authentication header/credential, AND
#   (3) does NOT also capture `%{content_type}` on that same -w, AND
#   (4) is not explicitly marked `status-probe-ok` in a comment within the 8 lines above.
#
# Scope: the doctor/verify surfaces where a false green gates a whole audit —
#   skills/doctor/scripts/doctor.sh, skills/connect/SKILL.md, skills/connect/references/providers.md,
#   and every skills/audit-*/SKILL.md + skills/audit-*/references/*.md (except audit-all).
#
# Escape hatch: a deliberately status-only probe (an UNauthenticated reachability ping, or
# an informational probe whose body shape is irrelevant) carries a `status-probe-ok` comment
# within 8 lines above the curl, with a one-line justification. Use it sparingly.
#
# Read-only. POSIX sh + awk.
set -eu
DIR="${1:-.}"
FAIL=0

scan() {
  f="$1"
  [ -f "$f" ] || return 0
  awk -v FN="$f" '
    { L[NR]=$0 }
    END {
      for (i=1;i<=NR;i++) {
        line=L[i]
        # (1) a status-only probe line: -o /dev/null AND %{http_code} in the -w
        if (line !~ /-o \/dev\/null/) continue
        if (line !~ /%\{http_code\}/) continue
        # (3) already captures content-type on this same line -> compliant, skip
        if (line ~ /%\{content_type\}/) continue
        # (2) an auth header/credential within the curl command (this line .. +6)
        auth=0
        for (j=i; j<=i+6 && j<=NR; j++) {
          w=L[j]
          if (w ~ /SIGNOZ-API-KEY/ || w ~ /Authorization:/ || w ~ /DD-API-KEY/ || w ~ /DD-APPLICATION-KEY/ || w ~ /ApiKey / || w ~ /x-api-key/ || w ~ /Token / || w ~ /-u "/ || w ~ /-b "\$/) auth=1
        }
        if (!auth) continue
        # (4) status-probe-ok marker in the 8 lines above (or on the line)
        ok=0
        for (j=i-8; j<=i; j++) { if (j>=1 && L[j] ~ /status-probe-ok/) ok=1 }
        if (ok) continue
        printf "%s:%d: authenticated status-only probe (-o /dev/null + %%{http_code}) without a %%{content_type} capture, a JSON-body assertion, or a `status-probe-ok` marker — a 200 HTML login/SPA/proxy page would false-green here\n", FN, i
        bad++
      }
      exit (bad>0)?1:0
    }
  ' "$f" || return 1
  return 0
}

for f in \
  "$DIR/skills/doctor/scripts/doctor.sh" \
  "$DIR/skills/connect/SKILL.md" \
  "$DIR/skills/connect/references/providers.md"; do
  scan "$f" || FAIL=1
done

for d in "$DIR"/skills/audit-*/; do
  name="$(basename "$d")"
  [ "$name" = "audit-all" ] && continue
  [ -f "${d}SKILL.md" ] && { scan "${d}SKILL.md" || FAIL=1; }
  if [ -d "${d}references" ]; then
    for r in "${d}references"/*.md; do
      [ -f "$r" ] && { scan "$r" || FAIL=1; }
    done
  fi
done

if [ "$FAIL" -ne 0 ]; then
  echo "CONTENT-TYPE-PROBE CHECK FAILED — harden the probe (drop -o /dev/null, add %{content_type} + a jq body assertion) or mark an intentional status-only probe with a status-probe-ok comment"
  exit 1
fi
echo "CONTENT-TYPE-PROBE-OK (every authenticated status probe captures content-type / asserts JSON, or is marked status-probe-ok)"
