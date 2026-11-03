#!/bin/sh
# Execute the published DNS block in fresh shells. No real DNS/network calls.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/bin" "$TMP/no-dig" "$TMP/home"
awk '/^# PROM-001 DNS classification:/{p=1} p && /^```$/{exit} p {print}' \
  "$ROOT/skills/audit-prometheus/references/prometheus-checks.md" > "$TMP/block.sh"
[ -s "$TMP/block.sh" ]
cat > "$TMP/config.yaml" <<'EOF'
prometheus:
  url: https://metrics.example.invalid:9090
EOF
cat > "$TMP/bin/dig" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$DNS_CALLS"
case "$*" in
  *'+short NS example.invalid') [ "${NO_NS:-0}" = 1 ] || echo ns.example.invalid. ;;
  *'+short NS '*) : ;;
  *'example.invalid SOA '*) printf ';; ->>HEADER<<- opcode: QUERY, status: %s, id: 1\n;; flags: qr aa;\n' "${APEX_STATUS:-NOERROR}" ;;
  *'metrics.example.invalid A '*)
    [ "${READ_FAIL:-0}" = 0 ] || exit 9
    printf ';; ->>HEADER<<- opcode: QUERY, status: %s, id: 1\n;; flags: qr %s;\n' "${ANSWER_STATUS:-NXDOMAIN}" "${AUTHORITY:-aa}" ;;
  *) exit 98 ;;
esac
EOF
chmod +x "$TMP/bin/dig"
export CLAUDE_PLUGIN_ROOT="$ROOT" SCOUTFLO_CONFIG="$TMP/config.yaml" HOME="$TMP/home" DNS_CALLS="$TMP/dns-calls"
run() { PATH="$TMP/bin:$PATH" /bin/sh "$TMP/block.sh"; }
run | grep -q 'corroborate decommissioning before target-gone, otherwise blocked'
AUTHORITY=ra run | grep -q 'blocked: response is not authoritative'
APEX_STATUS=SERVFAIL run | grep -q 'blocked: zone apex also failed'
ANSWER_STATUS=SERVFAIL run | grep -q 'blocked: DNS delegation'
ANSWER_STATUS=NOERROR run | grep -q 'blocked: DNS exists'
NO_NS=1 run | grep -q 'blocked: no authoritative nameserver'
READ_FAIL=1 run | grep -q 'blocked: response is not authoritative'
cp "$TMP/config.yaml" "$TMP/single.yaml"
printf '%s\n' 'prometheus:' '  - label: one' '    url: https://metrics.example.invalid' > "$TMP/config.yaml"
before=$(wc -l < "$DNS_CALLS")
run | grep -q 'blocked: give the selected Prometheus target a single-block config'
[ "$(wc -l < "$DNS_CALLS")" = "$before" ] || { echo 'FAIL: list config made a DNS call'; exit 1; }
mv "$TMP/single.yaml" "$TMP/config.yaml"
# Select exactly the same config as doctor: explicit, project, active, home.
mkdir -p "$TMP/project/.scoutflo" "$HOME/.scoutflo"
cp "$TMP/config.yaml" "$TMP/project/.scoutflo/toolkit.yaml"
printf '%s\n' 'prometheus:' '  url: https://wrong.example.invalid' > "$HOME/.scoutflo/toolkit.yaml"
( cd "$TMP/project"; unset SCOUTFLO_CONFIG; run ) | grep -q 'corroborate decommissioning'
rm "$TMP/project/.scoutflo/toolkit.yaml"
printf '%s\n' "$TMP/config.yaml" > "$HOME/.scoutflo/active-config"
( cd "$TMP/project"; unset SCOUTFLO_CONFIG; run ) | grep -q 'corroborate decommissioning'
rm "$HOME/.scoutflo/active-config"
cp "$TMP/config.yaml" "$HOME/.scoutflo/toolkit.yaml"
( cd "$TMP/project"; unset SCOUTFLO_CONFIG; run ) | grep -q 'corroborate decommissioning'
# An unavailable optional dependency must not fall through to an outage verdict.
for cmd in sh awk sed grep head dirname cat; do ln -s "$(command -v "$cmd")" "$TMP/no-dig/$cmd"; done
PATH="$TMP/no-dig" /bin/sh "$TMP/block.sh" | grep -q 'blocked: dig is unavailable'
# Every emitted query must be bounded; this also rejects accidental resolver probes.
if grep -v '^+time=5 +tries=1 ' "$DNS_CALLS" | grep -q .; then echo 'FAIL: unbounded DNS request'; exit 1; fi
echo 'TESTS-OK: eight DNS classifications, list refusal and three fallback-config selections, no live calls'
