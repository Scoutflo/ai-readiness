#!/bin/sh
# Count prior findings whose checks are positively passed now. An omitted,
# blocked, not-in-scope or suppressed finding is not proof of resolution.
set -eu
current=${1:?current findings.json required}
previous=${2:-}
if [ -z "$previous" ] || [ ! -f "$previous" ]; then printf '0\n'; exit 0; fi
jq -nr --slurpfile prior "$previous" --slurpfile current "$current" '
  [$prior[0].findings[]?.id] | unique as $old
  | [$current[0].checks[]? | select(.result=="pass" and (.suppressed != true)) | .id] | unique as $passed
  | [$old[] | select(. as $id | $passed | index($id))] | length'
