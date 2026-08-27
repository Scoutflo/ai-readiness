#!/bin/sh
# prefix-registry-check.sh (contracts C1/C9)
# Every finding-ID prefix a skill emits (as a backtick-wrapped `PREFIX-NNN`) must
# be registered in findings-schema.md's "Registered prefixes" line, or be the
# audit-cost COST- family (documented in cost-schema.md). Stops an unregistered
# or colliding prefix from shipping (AZR/AZROPT/DDOPT/DORT were once unregistered).
set -eu
DIR="${1:-.}"
SCHEMA="$DIR/report-standard/findings-schema.md"
[ -f "$SCHEMA" ] || { echo "PREFIX-REGISTRY: findings-schema.md missing" >&2; exit 1; }

# Registered prefixes = the backtick-wrapped tokens on the "Registered prefixes"
# line, plus COST (audit-cost's own scoutflo-cost/v1 schema).
reg="$(grep 'Registered prefixes' "$SCHEMA" | grep -oE '`[A-Z][A-Z0-9]{1,5}`' | tr -d '`' | sort -u | tr '\n' ' ') COST"

found="$(grep -rhoE '`[A-Z][A-Z0-9]{1,5}-[0-9]{2,4}`' "$DIR"/skills/ 2>/dev/null | sed 's/`//g; s/-[0-9][0-9]*$//' | sort -u)"

rc=0
for p in $found; do
  case " $reg " in
    *" $p "*) : ;;
    *) echo "PREFIX-REGISTRY: finding-ID prefix '$p' is emitted by a skill but not in findings-schema.md's Registered prefixes line — register it (paired like AWS/AWSOPT, K8S/K8SRT) so prefixes stay one-per-audit and never collide" >&2; rc=1 ;;
  esac
done

[ "$rc" = 0 ] && echo "PREFIX-REGISTRY-OK (every emitted finding-ID prefix is registered)"
exit $rc
