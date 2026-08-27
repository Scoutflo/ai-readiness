#!/bin/sh
# config-key-agreement-check.sh (contract C9)
# The set of provider blocks `doctor` probes must equal the set of top-level
# blocks a user can configure in the template. Prevents drift where a provider
# is probed-but-unconfigurable or configurable-but-unprobed (the "Azure block
# read by doctor+audit but absent from the template/providers reference" class).
# coverage-check.sh already ties the template to providers.md + connect + start,
# so together the three sources (doctor <-> template <-> providers.md) agree.
set -eu
DIR="${1:-.}"
DOCTOR="$DIR/skills/doctor/scripts/doctor.sh"
TEMPLATE="$DIR/templates/toolkit.yaml.example"
# Sub-keys doctor's KNOWN_BLOCKS scanner recognizes that are intentionally NOT
# top-level template blocks (they live nested: prometheus.alertmanager_url,
# victoriametrics.vmalert_url). Extend only with a documented reason.
EXEMPT="alertmanager vmalert"

[ -f "$DOCTOR" ] && [ -f "$TEMPLATE" ] || { echo "CONFIG-KEY-AGREEMENT: doctor.sh or toolkit.yaml.example missing" >&2; exit 1; }

kb="$(grep 'KNOWN_BLOCKS=' "$DOCTOR" | head -1 | sed 's/.*="//; s/"$//')"
[ -n "$kb" ] || { echo "CONFIG-KEY-AGREEMENT: could not read KNOWN_BLOCKS from doctor.sh" >&2; exit 1; }

exempt_re="$(printf '%s' "$EXEMPT" | tr ' ' '|')"
doctor_set="$(printf '%s\n' $kb | grep -vxE "$exempt_re" | sort -u)"
tmpl_set="$(grep -oE '^[a-z_][a-z_0-9]*:' "$TEMPLATE" | sed 's/:$//' | sort -u)"

rc=0
for b in $tmpl_set; do
  printf '%s\n' "$doctor_set" | grep -qx "$b" || { echo "CONFIG-KEY-AGREEMENT: template block '$b:' is not in doctor KNOWN_BLOCKS — a user can configure it but doctor will report it 'not-checked-by-doctor'" >&2; rc=1; }
done
for b in $doctor_set; do
  printf '%s\n' "$tmpl_set" | grep -qx "$b" || { echo "CONFIG-KEY-AGREEMENT: doctor probes '$b' but templates/toolkit.yaml.example has no top-level '$b:' block (no scaffold for a user to copy; add it or add '$b' to EXEMPT with a reason)" >&2; rc=1; }
done

[ "$rc" = 0 ] && echo "CONFIG-KEY-AGREEMENT-OK (doctor KNOWN_BLOCKS == configurable template blocks, modulo alertmanager/vmalert sub-keys)"
exit $rc
