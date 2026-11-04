#!/bin/sh
# A provider object may exist without exposing an activation state.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RENDERER=${SCOUTFLO_REPORT_VIZ:-$ROOT/report-standard/render-report-viz.sh}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
cat > "$WORK/inventory.json" <<'JSON'
{"schema":"scoutflo-inventory/v1","target":"example","counts":{"total":5},"items":[{"kind":"route","name":"absent"},{"kind":"route","name":"null","enabled":null},{"kind":"route","name":"active","enabled":true},{"kind":"route","name":"disabled","enabled":false},{"kind":"route","name":"untyped","enabled":"true"}]}
JSON
sh "$RENDERER" inventory "$WORK/inventory.json" > "$WORK/report.md"
for name in absent null untyped; do
  awk -F '|' -v item="\`$name\`" '$2 ~ item && $6 ~ /unknown/ {found=1} END {exit !found}' "$WORK/report.md" || { echo "FAIL $name was presented as a known activation state"; exit 1; }
done
awk -F '|' '$2 ~ /`active`/ && $6 ~ /yes/ {found=1} END {exit !found}' "$WORK/report.md"
awk -F '|' '$2 ~ /`disabled`/ && $6 ~ /no/ {found=1} END {exit !found}' "$WORK/report.md"
echo 'inventory state: 5 passed (unknown states preserved; observed booleans unchanged)'
