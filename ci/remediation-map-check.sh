#!/bin/sh
# Remediation-map check: every entry in docs/finding-remediation-map.json must
# be real on three axes, or the map rots into fiction (the v0.1.69 failure —
# 38/38 invented entries — is the class this gate kills):
#   1. the setup skill directory exists
#   2. the anchor resolves to a real heading in that setup skill's SKILL.md
#      (GitHub-style slugging, same rules as anchor-check.sh)
#   3. the finding ID appears in its audit skill's own catalog
#      (SKILL.md or references/*.md), located by ID prefix
# Read-only; requires jq (already a toolkit prerequisite).
set -eu
DIR="${1:-.}"
MAP="$DIR/docs/finding-remediation-map.json"
SKILLS_DIR="$DIR/skills"

# A missing map is fine (the map is optional); a present-but-invalid map fails.
[ -f "$MAP" ] || { echo "REMEDIATION-MAP-OK (no map present)"; exit 0; }

jq -e '.mappings | type == "object"' "$MAP" > /dev/null 2>&1 \
  || { echo "REMEDIATION-MAP FAILED: $MAP has no .mappings object"; exit 1; }

# GitHub-style slug of a heading line (mirrors anchor-check.sh):
# lowercase; drop everything but alnum, space, hyphen; spaces -> hyphens.
slug() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9 -]//g; s/ /-/g'
}

# Map a finding-ID prefix to its audit skill directory.
audit_for_prefix() {
  case "$1" in
    AWS) echo audit-aws ;;
    GCP) echo audit-gcp ;;
    LGTM) echo audit-lgtm ;;
    GRAF) echo audit-grafana ;;
    SNTRY) echo audit-sentry ;;
    DO) echo audit-digitalocean ;;
    DD) echo audit-datadog ;;
    ELK) echo audit-elk ;;
    ALR) echo audit-alertmanager ;;
    PD) echo audit-pagerduty ;;
    ZD) echo audit-zenduty ;;
    K8S) echo audit-kubernetes ;;
    JSM) echo audit-jsm ;;
    GC) echo audit-groundcover ;;
    CS) echo audit-clickstack ;;
    *) echo "" ;;
  esac
}

FAILED=0
TOTAL=0

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
jq -r '.mappings | to_entries[] | "\(.key)\t\(.value.setup_skill)\t\(.value.anchor)"' "$MAP" > "$TMP"

while IFS="$(printf '\t')" read -r fid skill anchor; do
  TOTAL=$((TOTAL + 1))

  # 1. Setup skill exists
  SKILL_MD="$SKILLS_DIR/$skill/SKILL.md"
  if [ ! -f "$SKILL_MD" ]; then
    echo "$fid: setup skill '$skill' does not exist"
    FAILED=1
    continue
  fi

  # 2. Anchor resolves to a heading in that SKILL.md
  FOUND_ANCHOR=0
  while IFS= read -r head; do
    if [ "$(slug "$head")" = "$anchor" ]; then
      FOUND_ANCHOR=1
      break
    fi
  done <<EOF
$(sed -n 's/^#\{1,6\} //p' "$SKILL_MD")
EOF
  if [ "$FOUND_ANCHOR" -eq 0 ]; then
    echo "$fid: anchor '$anchor' resolves to no heading in $skill/SKILL.md"
    FAILED=1
    continue
  fi

  # 3. Finding ID exists in its audit skill's catalog
  prefix="${fid%-*}"
  audit="$(audit_for_prefix "$prefix")"
  if [ -z "$audit" ]; then
    echo "$fid: unknown finding-ID prefix '$prefix' (no audit skill maps to it)"
    FAILED=1
    continue
  fi
  if ! grep -rql -- "$fid" "$SKILLS_DIR/$audit/SKILL.md" "$SKILLS_DIR/$audit/references" 2>/dev/null; then
    echo "$fid: not found in $audit's catalog (SKILL.md or references/)"
    FAILED=1
  fi
done < "$TMP"

if [ "$FAILED" -ne 0 ]; then
  echo "REMEDIATION-MAP CHECK FAILED"
  exit 1
fi
echo "REMEDIATION-MAP-OK ($TOTAL mappings verified: skill exists, anchor resolves, ID in audit catalog)"
