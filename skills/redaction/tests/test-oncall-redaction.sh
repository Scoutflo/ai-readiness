#!/bin/sh
# Synthetic provider credential cases; tests the shared filter and all adapters.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "${REDACTION_LIB:-$ROOT/skills/redaction/lib/redaction.sh}"
. "${REDACTION_ADAPTER:-$ROOT/skills/redaction/lib/redaction-integration.sh}"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT HUP INT TERM
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf 'ok %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }
# No valid provider key or secret-shaped URL literal is stored in the source.
vo_id=$(printf 'fixture-%s' 'identifier')
vo_key=$(printf 'fixture-%s' 'management+value/with=padding._-')
vo_ingestion=$(printf 'fixture-%s' 'ingestion')
vo_route=$(printf 'fixture-%s' 'routing%2Fvalue')
prefix=$(printf '%s/%s/%s/%s/%s/' 'https://alert.victorops.com' integrations generic 20131114 alert)
incoming="$prefix$vo_ingestion/$vo_route"
check() {
  label=$1; input=$2; expected=$3
  output=$(printf '%s' "$input" | redact_content)
  [ "$output" = "$expected" ] && ok "$label masks complete values and preserves delimiters" || bad "$label masking"
  if has_secrets "$input"; then ok "$label detected"; else bad "$label detection"; fi
  output_again=$(printf '%s' "$output" | redact_content)
  [ "$output_again" = "$output" ] && ok "$label idempotent" || bad "$label idempotence"
  if has_secrets "$output"; then bad "$label masked content still detected"; else ok "$label masked content clean"; fi
}
check 'management id header' "X-VO-Api-Id: $vo_id" 'X-VO-Api-Id: [REDACTED]'
check 'management key mixed case' "x-Vo-aPI-kEY = $vo_key" 'x-Vo-aPI-kEY = [REDACTED]'
check 'quoted header' "curl -H \"X-VO-Api-Key: $vo_key\"" 'curl -H "X-VO-Api-Key: [REDACTED]"'
check 'single quoted header' "'X-VO-Api-Id': '$vo_id'" "'X-VO-Api-Id': '[REDACTED]'"
check 'JSON headers' "{\"X-VO-Api-Id\":\"$vo_id\",\"X-VO-Api-Key\":\"$vo_key\",\"keep\":true}" '{"X-VO-Api-Id":"[REDACTED]","X-VO-Api-Key":"[REDACTED]","keep":true}'
check 'routing field' "{\"routingKey\":\"$vo_route\",\"keep\":true}" '{"routingKey":"[REDACTED]","keep":true}'
check 'routing snake field' "routing_key = '$vo_route'" "routing_key = '[REDACTED]'"
check 'routing hyphen field' "ROUTING-KEY: $vo_route" 'ROUTING-KEY: [REDACTED]'
check 'quoted multiword routing value' "{\"routingKey\":\"$vo_route private suffix\"}" '{"routingKey":"[REDACTED]"}'
check 'complete raw header value' "X-VO-Api-Key: $vo_key private suffix" 'X-VO-Api-Key: [REDACTED]'
check 'both inbound path credentials' "$incoming" "${prefix}[REDACTED]"
check 'single inbound path credential' "$prefix$vo_ingestion" "${prefix}[REDACTED]"
check 'incoming Markdown plus safe query' "[incoming]($incoming?keep=yes#section)" "[incoming](${prefix}[REDACTED]?keep=yes#section)"
upper=$(printf '%s' "$incoming" | sed 's/alert.victorops.com/ALERT.VICTOROPS.COM/')
check 'case insensitive incoming host' "$upper" "$(printf '%s' "$prefix" | sed 's/alert.victorops.com/ALERT.VICTOROPS.COM/')[REDACTED]"
escaped=$(printf '%s' "$incoming" | sed 's@/@\\/@g')
escaped_prefix=$(printf '%s' "$prefix" | sed 's@/@\\/@g')
check 'JSON escaped URL' "\"$escaped\"" "\"${escaped_prefix}[REDACTED]\""
nested=$(jq -cn --arg text "\"X-VO-Api-Key\": \"$vo_key\"" '{description:$text}')
nested_expected=$(jq -cn --arg text '"X-VO-Api-Key": "[REDACTED]"' '{description:$text}')
check 'JSON encoded header string' "$nested" "$nested_expected"
for clean in 'https://api.victorops.com/api-public/v1/team/example' "$prefix" 'routing_key_env: ONCALL_ROUTE_REFERENCE' 'X-VO-Api-Key is a header name' 'https://alert.victorops.com.example.test/integrations/generic/20131114/alert/ordinary/path'; do
 output=$(printf '%s' "$clean" | redact_content)
 [ "$output" = "$clean" ] && ok 'safe context remains unchanged' || bad 'safe context modified'
done
content="X-VO-Api-Id: $vo_id
X-VO-Api-Key: $vo_key
$incoming"
printf '%s\n' "$content" > "$work/report.md"
has_secrets_file "$work/report.md" && ok 'file detection sees On-Call credentials' || bad 'file detection missed On-Call'
redaction_integration_report "$work/report.md" > "$work/report.stdout" 2> "$work/report.stderr"
if grep -F -e "$vo_id" -e "$vo_key" -e "$vo_ingestion" -e "$vo_route" "$work/report.md" >/dev/null; then bad 'report adapter leaked'; else ok 'report adapter masks all credential families'; fi
brief=$(redaction_integration_slack_brief "$content")
if printf '%s' "$brief" | grep -F -e "$vo_id" -e "$vo_key" -e "$vo_ingestion" -e "$vo_route" >/dev/null; then bad 'brief adapter leaked'; else ok 'brief adapter masks all credential families'; fi
jq -n --arg description "$nested" --arg url "$incoming" --arg value "$vo_key" '{findings:[{id:"SOC-001",description:$description,evidence:{url:$url,headers:{"X-VO-Api-Key":$value}},safe_count:7}]}' > "$work/findings.json"
redaction_integration_findings "$work/findings.json"
if grep -F -e "$vo_id" -e "$vo_key" -e "$vo_ingestion" -e "$vo_route" "$work/findings.json" >/dev/null; then bad 'findings adapter leaked'; else ok 'findings adapter shares all canonical masks'; fi
jq -e '.findings[0].id=="SOC-001" and .findings[0].safe_count==7 and .findings[0].evidence.headers["X-VO-Api-Key"]=="[REDACTED]"' "$work/findings.json" >/dev/null && ok 'findings JSON remains valid and safe fields preserved' || bad 'findings JSON or safe fields damaged'
printf '{invalid' > "$work/invalid.json"; cp "$work/invalid.json" "$work/before.json"
if redaction_integration_findings "$work/invalid.json" 2>/dev/null; then bad 'invalid JSON accepted'; else ok 'invalid JSON refused'; fi
cmp -s "$work/invalid.json" "$work/before.json" && ok 'invalid JSON unchanged' || bad 'invalid JSON overwritten'
cp "$work/findings.json" "$work/before.json"
if ( redact_content() { printf '{broken'; }; redaction_integration_findings "$work/findings.json" ) 2>/dev/null; then bad 'invalid filter output accepted'; else ok 'invalid filter output refused'; fi
cmp -s "$work/findings.json" "$work/before.json" && ok 'failed filter preserves original findings' || bad 'failed filter overwrote findings'
printf 'oncall-redaction: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
