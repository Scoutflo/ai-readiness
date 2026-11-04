#!/bin/sh
# The two actual published source blocks must select identical configured auth.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT HUP INT TERM
mkdir -p "$WORK/bin" "$WORK/home"
awk '/^```bash$/{n++;f=1;next} /^```$/{f=0} n==1&&f' "$ROOT/skills/migration-plan/SKILL.md" > "$WORK/doctor.sh"
awk '/^```bash$/{n++;f=1;next} /^```$/{f=0} n==1&&f' "$ROOT/skills/migration-plan/references/datadog-to-signoz.md" > "$WORK/detail.sh"
cat > "$WORK/bin/curl" <<'CURL'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$CALLS"
case "$*" in *https://api.datadoghq.eu/*) ;; *) exit 90 ;; esac
case "$*" in *'DD-API-KEY: fixture-api'*) ;; *) exit 91 ;; esac
case "$*" in *'/validate'*) printf '{"valid":true}\n' ;; *)
  case "$*" in *'DD-APPLICATION-KEY: fixture-app'*) ;; *) exit 92 ;; esac
  printf '{}\n';;
esac
CURL
chmod +x "$WORK/bin/curl"
cat > "$WORK/env" <<'ENV'
CUSTOM_API=fixture-api
CUSTOM_APP=fixture-app
ENV
cat > "$WORK/map.yaml" <<'YAML'
datadog:
  site: datadoghq.eu
  api_key_env: CUSTOM_API
  app_key_env: CUSTOM_APP
YAML
cat > "$WORK/list.yaml" <<'YAML'
datadog:
  - label: eu
    site: datadoghq.eu
    api_key_env: CUSTOM_API
    app_key_env: CUSTOM_APP
  - label: other
    site: datadoghq.com
    api_key_env: UNSET_API
    app_key_env: UNSET_APP
YAML
run() { env -i HOME="$WORK/home" PATH="$WORK/bin:$PATH" CLAUDE_PLUGIN_ROOT="$ROOT" SCOUTFLO_CONFIG="$config" SCOUTFLO_ENV_FILE="$WORK/env" SCOUTFLO_TARGET="$label" DD_SITE=untrusted.example CALLS="$WORK/calls" sh "$WORK/$1.sh" > "$WORK/out" 2> "$WORK/err"; }
for layout in map list; do
  config="$WORK/$layout.yaml"; label=eu; [ "$layout" != map ] || label=''
  for block in doctor detail; do
    : > "$WORK/calls"; run "$block"
    [ -s "$WORK/calls" ]; ! grep -q untrusted.example "$WORK/calls"
    ! grep -Eq 'fixture-api|fixture-app' "$WORK/out"
    echo "PASS $block selects configured site and custom keys: $layout"
  done
done
config="$WORK/list.yaml"
for label in '' missing other; do
  : > "$WORK/calls"
  if run detail; then echo 'FAIL unknown/unset source accepted'; exit 1; fi
  [ ! -s "$WORK/calls" ]; echo 'PASS missing/unknown/unset source stops before HTTP'
done
config="$WORK/map.yaml"; label=''
sed 's/datadoghq.eu/untrusted.example/' "$config" > "$WORK/unsafe.yaml";config="$WORK/unsafe.yaml"
: > "$WORK/calls"; if run detail; then exit 1; fi
[ ! -s "$WORK/calls" ]
echo 'MIGRATION-DATADOG-CONTEXT-OK: 8 cases; exact published blocks; no provider calls'
