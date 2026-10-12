# Grafana Setup: Payload Cookbook

Payloads, verification reads, and provenance rules for [setup-grafana](../SKILL.md). Every block here is applied only through the change protocol: announce, confirm, execute, verify, record.

Every command block below redeclares the variables it uses, each with the `toolkit.yaml` key it resolves from, so it runs correctly pasted alone into a fresh shell. No block depends on an earlier block having run.

## Provenance and ownership

Every object carries a `provenance` (alerting) or `readOnly` (datasources, dashboards) marker. An API write against a file-provisioned or IaC-owned object is rejected or silently reverted at the next sync.

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
# grafana.token_env names the variable; presence check only, never print the value.
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }

# Datasources: readOnly true means file-provisioned
curl -fsS --max-time 15 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/datasources" \
  | jq -r '.[] | select(.readOnly == true) | "\(.name) (\(.uid))"'

# Alert rules, contact points, policies: provenance field
curl -fsS --max-time 15 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/v1/provisioning/alert-rules" \
  | jq -r '.[] | select((.provenance // "none") != "none") | "\(.title) (\(.uid)) provenance=\(.provenance)"'
```

| Provenance value | Meaning | Where the change goes |
| --- | --- | --- |
| `none` | Created or last edited through the UI or the plain API | This skill can write it directly |
| `file` | Provisioned from a dashboard/alerting provisioning file on disk | Change the source file, apply through your deploy path, then verify live |
| `api` | Written through the provisioning API with a stable identifier | This skill can write it directly through the same API |
| Terraform, Ansible, or another IaC tool manages the object | Not visible as a `provenance` value; discovered by convention (naming, a tag, a paired `.tf`/playbook file your team knows about) | Change in that source; the protocol still applies, with "execute" meaning apply through the tool, then verify live |

New objects this skill creates default to `provenance: none` unless created through the provisioning API, which locks them as `api` (immutable in the UI, editable only through the API). Decide this deliberately per object: pass the header below when your team wants to keep editing an object in the UI after this skill creates it.

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
# Disable provenance locking on a provisioning-API create (alert rules, contact points, policies)
curl -fsS --max-time 15 -X POST \
  -H "Authorization: Bearer ${GRAFANA_TOKEN}" -H "Content-Type: application/json" \
  -H "X-Disable-Provenance: true" \
  -d @payload.json "${GRAFANA_URL}/api/v1/provisioning/alert-rules"
```

## Verification reads

Reused across every fix section. Confirm the intended field holds the intended value; a write is unverified until re-read.

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
# Re-fetch a datasource by UID
DS_UID="prom-uid"   # the datasource you just wrote
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/datasources/uid/${DS_UID}" \
  | jq '{name, uid, url, secureJsonFields, jsonData}'

# Re-fetch a dashboard by UID and confirm the panel-level change
DASH_UID="abcd1234"   # the dashboard you just wrote
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/dashboards/uid/${DASH_UID}" \
  | jq '.dashboard.version'

# Re-fetch an alert rule by UID
RULE_UID="rule-uid"   # the rule you just wrote
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/v1/provisioning/alert-rules/${RULE_UID}" \
  | jq '{title, labels, noDataState, execErrState}'

# Live label read through a datasource proxy, per critical service (GRAF-090..092 verification)
DS_UID="loki-uid"      # backend datasource uid
SERVICE="checkout"     # service name from topology.md
curl -fsS --max-time 15 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  --get --data-urlencode "query=sum(count_over_time({service=\"${SERVICE}\"}[15m]))" \
  "${GRAFANA_URL}/api/datasources/proxy/uid/${DS_UID}/loki/api/v1/query" \
  | jq '.data.result'
```

Expected shapes and their failure modes match [audit-grafana's cookbook](../../audit-grafana/references/api-checks.md#apidsquery-cookbook): a populated `error` field means the query is broken live, `frames: 0` with no error needs a second look, and a 403 means the token lacks access, not that the object is broken.

## Backups

Run this immediately before you change a datasource, alert rule, or contact point; the dashboard and notification-policy write blocks below take their own backups. Every restore block reads the exact `backup:` path it prints, so copy that path into the change record. A change that sets `isDefault` also unsets the current default datasource, so back that one up too. This block and every rollback block below resolve the Grafana URL and token from `toolkit.yaml` the way `audit-grafana` does, so they act on the same instance.

```bash
set -eu
# Resolve the grafana target from toolkit.yaml by command, as audit-grafana does: a single block, or the
# labeled-list item SCOUTFLO_TARGET names. The URL and the token are never retyped here.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect" >&2; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GRAF_KIND=$(sh "$TT" "$CFG" grafana kind); GRAF_N=$(sh "$TT" "$CFG" grafana count)
[ "${GRAF_N:-0}" -ge 1 ] || { echo "no grafana target in $CFG; run /scoutflo:connect" >&2; exit 1; }
[ "$GRAF_KIND" != seq ] || [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "grafana in $CFG is a labeled list; set SCOUTFLO_TARGET to one of: $(sh "$TT" "$CFG" grafana labels | tr '\n' ' ')" >&2; exit 1; }
GRAF_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$GRAF_N" ]; do [ "$(sh "$TT" "$CFG" grafana label "$_i")" = "$SCOUTFLO_TARGET" ] && { GRAF_IDX=$_i; break; }; _i=$((_i+1)); done; fi
GRAF_LABEL=$(sh "$TT" "$CFG" grafana label "$GRAF_IDX")
[ -z "${SCOUTFLO_TARGET:-}" ] || [ "$GRAF_LABEL" = "$SCOUTFLO_TARGET" ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no grafana target in $CFG" >&2; exit 1; }
GRAFANA_URL=$(sh "$TT" "$CFG" grafana get "$GRAF_IDX" url); GRAFANA_URL="${GRAFANA_URL%/}"   # grafana.url
[ -n "$GRAFANA_URL" ] || { echo "grafana target '${GRAF_LABEL}' has no url in $CFG; run /scoutflo:connect" >&2; exit 1; }
# Load the secret store the way connect documents: $SCOUTFLO_ENV_FILE, then ./.scoutflo/env, then ~/.scoutflo/env.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
GRAF_TOKEN_VAR=$(sh "$TT" "$CFG" grafana get "$GRAF_IDX" token_env); [ -n "$GRAF_TOKEN_VAR" ] || GRAF_TOKEN_VAR="GRAFANA_TOKEN"   # grafana.token_env
GRAFANA_TOKEN=$(printenv "$GRAF_TOKEN_VAR" 2>/dev/null || true)
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "${GRAF_TOKEN_VAR} is not set; add it to ~/.scoutflo/env with /scoutflo:connect" >&2; exit 1; }
echo "grafana target: ${GRAF_LABEL} (${GRAFANA_URL})"
OBJ_KIND="datasource"     # datasource, alert-rule, or contact-point
OBJ_UID="<uid>"           # uid of the object you are about to change
case "$OBJ_UID" in ''|'<'*) echo "Set OBJ_UID to the object you are about to change" >&2; exit 1 ;; esac
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/setup-$(date -u +%F)/backups"
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="${BACKUP_DIR}/${OBJ_KIND}-${OBJ_UID}-$(date -u +%H%M%S).json"
# Never overwrite an earlier restore point.
[ ! -e "$BACKUP_FILE" ] || { echo "${BACKUP_FILE} already exists; rerun in a second" >&2; exit 1; }
case "$OBJ_KIND" in
  datasource) curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
      "${GRAFANA_URL}/api/datasources/uid/${OBJ_UID}" > "$BACKUP_FILE" ;;
  alert-rule) curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
      "${GRAFANA_URL}/api/v1/provisioning/alert-rules/${OBJ_UID}" > "$BACKUP_FILE" ;;
  # The provisioning API has no GET by uid for contact points: select it from the list.
  contact-point) curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
      "${GRAFANA_URL}/api/v1/provisioning/contact-points" \
      | jq -e --arg u "$OBJ_UID" '.[] | select(.uid == $u)' > "$BACKUP_FILE" \
      || { echo "No contact point with uid ${OBJ_UID}" >&2; exit 1; } ;;
  *) echo "OBJ_KIND must be datasource, alert-rule, or contact-point" >&2; exit 1 ;;
esac
jq -e . "$BACKUP_FILE" > /dev/null && echo "backup: ${BACKUP_FILE}"
```

Expected: `backup: <path>`. Secure fields come back masked in every backup. A datasource backup taken before a GRAF-002 fix still holds the plaintext credential that finding is about: keep it local and never print it.

## Datasources

Create or repair a datasource. Credentials go in `secureJsonData` only; build the payload with `jq` and pipe straight into `curl` so the secret exists only in its env var and the request body.

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
DS_TOKEN_ENV="LOKI_DS_TOKEN"        # env var name from toolkit.yaml, e.g. loki.token_env
DS_UID="loki-checkout"              # a stable UID you choose; never let Grafana auto-generate one
DS_URL="https://loki.example.com"   # the backend URL from toolkit.yaml
LEDGER="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/created.tsv"   # what this run created; rollbacks delete only these

# A failed create (409: the uid or name exists) stops here, so it never reaches the ledger.
NEW_UID="$(jq -n --arg uid "$DS_UID" --arg url "$DS_URL" --arg token "${!DS_TOKEN_ENV}" '
  { name: "Loki", type: "loki", access: "proxy", uid: $uid, url: $url,
    jsonData: { httpHeaderName1: "Authorization" },
    secureJsonData: { httpHeaderValue1: ("Bearer " + $token) } }' \
| curl -fsS --max-time 15 -X POST \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" -H "Content-Type: application/json" \
    -d @- "${GRAFANA_URL}/api/datasources" \
| jq -er '.datasource.uid')"
echo "created: ${NEW_UID}"
mkdir -p "$(dirname "$LEDGER")"; printf 'datasource\t%s\t%s\n' "$NEW_UID" "${GRAFANA_URL%/}" >> "$LEDGER"
```

Expected: `created: <uid>`, the uid you chose, now listed in `created.tsv`. Rollback for a datasource this run created, in its own fresh shell; it refuses any uid the ledger does not list for this Grafana. Roll back the dashboards and rules you built on it first; they break once it is gone.

```bash
set -eu
# Resolve the grafana target from toolkit.yaml by command, as audit-grafana does: a single block, or the
# labeled-list item SCOUTFLO_TARGET names. The URL and the token are never retyped here.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect" >&2; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GRAF_KIND=$(sh "$TT" "$CFG" grafana kind); GRAF_N=$(sh "$TT" "$CFG" grafana count)
[ "${GRAF_N:-0}" -ge 1 ] || { echo "no grafana target in $CFG; run /scoutflo:connect" >&2; exit 1; }
[ "$GRAF_KIND" != seq ] || [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "grafana in $CFG is a labeled list; set SCOUTFLO_TARGET to one of: $(sh "$TT" "$CFG" grafana labels | tr '\n' ' ')" >&2; exit 1; }
GRAF_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$GRAF_N" ]; do [ "$(sh "$TT" "$CFG" grafana label "$_i")" = "$SCOUTFLO_TARGET" ] && { GRAF_IDX=$_i; break; }; _i=$((_i+1)); done; fi
GRAF_LABEL=$(sh "$TT" "$CFG" grafana label "$GRAF_IDX")
[ -z "${SCOUTFLO_TARGET:-}" ] || [ "$GRAF_LABEL" = "$SCOUTFLO_TARGET" ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no grafana target in $CFG" >&2; exit 1; }
GRAFANA_URL=$(sh "$TT" "$CFG" grafana get "$GRAF_IDX" url); GRAFANA_URL="${GRAFANA_URL%/}"   # grafana.url
[ -n "$GRAFANA_URL" ] || { echo "grafana target '${GRAF_LABEL}' has no url in $CFG; run /scoutflo:connect" >&2; exit 1; }
# Load the secret store the way connect documents: $SCOUTFLO_ENV_FILE, then ./.scoutflo/env, then ~/.scoutflo/env.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
GRAF_TOKEN_VAR=$(sh "$TT" "$CFG" grafana get "$GRAF_IDX" token_env); [ -n "$GRAF_TOKEN_VAR" ] || GRAF_TOKEN_VAR="GRAFANA_TOKEN"   # grafana.token_env
GRAFANA_TOKEN=$(printenv "$GRAF_TOKEN_VAR" 2>/dev/null || true)
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "${GRAF_TOKEN_VAR} is not set; add it to ~/.scoutflo/env with /scoutflo:connect" >&2; exit 1; }
echo "grafana target: ${GRAF_LABEL} (${GRAFANA_URL})"
DS_UID="<datasource-uid>"   # the "created:" uid; the ledger check below refuses any other
case "$DS_UID" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac
LEDGER="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/created.tsv"
ENTRY="$(printf 'datasource\t%s\t%s' "$DS_UID" "$GRAFANA_URL")"
grep -qxF "$ENTRY" "$LEDGER" 2>/dev/null \
  || { echo "datasource ${DS_UID} is not in ${LEDGER} for ${GRAFANA_URL}: this run did not create it, so it stays" >&2; exit 1; }
curl -fsS --max-time 10 -X DELETE -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  "${GRAFANA_URL}/api/datasources/uid/${DS_UID}" > /dev/null
code="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/datasources/uid/${DS_UID}")"
echo "post-delete: ${code}"
[ "$code" = "404" ] || { echo "datasource ${DS_UID} is still there" >&2; exit 1; }
# The object is gone: drop its ledger line, so a later object with the same uid is never deleted as "created".
{ grep -vxF "$ENTRY" "$LEDGER" || true; } > "${LEDGER}.tmp" && mv "${LEDGER}.tmp" "$LEDGER"
```

Expected: `post-delete: 404`, and the uid is gone from `created.tsv`.

Moving a plaintext credential (GRAF-002) out of `jsonData`: PUT the same shape with the plaintext key removed from `jsonData` and the value moved into `secureJsonData`, in the same announced change. Grafana does not migrate it for you.

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
DS_ID="7"   # numeric id from GET /api/datasources
curl -fsS --max-time 15 -X PUT \
  -H "Authorization: Bearer ${GRAFANA_TOKEN}" -H "Content-Type: application/json" \
  -d @payload.json "${GRAFANA_URL}/api/datasources/${DS_ID}"
```

Health check and minimal query, in order, after every write:

```bash
set -eu
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
DS_UID="loki-checkout"   # the datasource you just wrote
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/datasources/uid/${DS_UID}/health" \
  | jq '{status, message}'
```

Then replay one minimal query for data you know exists, using [audit-grafana's `/api/ds/query` cookbook, pattern 2](../../audit-grafana/references/api-checks.md#apidsquery-cookbook). A datasource that health-checks but returns nothing for its most basic query is configured, not useful.

Delete a duplicate only after every dashboard and rule that referenced it has been repointed and its queries replay clean:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
DS_UID="loki-duplicate"   # the survivor keeps the original UID
curl -fsS --max-time 10 -X DELETE -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/datasources/uid/${DS_UID}"
```

Rollback for a datasource you updated (including the GRAF-002 move) or deleted, in its own fresh shell. It re-applies the backup at the live `version`, because the backup's own `version` now fails with `409 Conflict`, or re-creates the datasource when it is gone. Secure fields come back masked, so a credential comes from your secret store, never from the backup: name each one in `SECRETS_FROM_ENV`, or set it to `none` when the change replaced no credential. On an update, a secure key you do not name keeps its live value; a re-create needs every key the backup lists.

```bash
set -eu
# Resolve the grafana target from toolkit.yaml by command, as audit-grafana does: a single block, or the
# labeled-list item SCOUTFLO_TARGET names. The URL and the token are never retyped here.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect" >&2; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GRAF_KIND=$(sh "$TT" "$CFG" grafana kind); GRAF_N=$(sh "$TT" "$CFG" grafana count)
[ "${GRAF_N:-0}" -ge 1 ] || { echo "no grafana target in $CFG; run /scoutflo:connect" >&2; exit 1; }
[ "$GRAF_KIND" != seq ] || [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "grafana in $CFG is a labeled list; set SCOUTFLO_TARGET to one of: $(sh "$TT" "$CFG" grafana labels | tr '\n' ' ')" >&2; exit 1; }
GRAF_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$GRAF_N" ]; do [ "$(sh "$TT" "$CFG" grafana label "$_i")" = "$SCOUTFLO_TARGET" ] && { GRAF_IDX=$_i; break; }; _i=$((_i+1)); done; fi
GRAF_LABEL=$(sh "$TT" "$CFG" grafana label "$GRAF_IDX")
[ -z "${SCOUTFLO_TARGET:-}" ] || [ "$GRAF_LABEL" = "$SCOUTFLO_TARGET" ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no grafana target in $CFG" >&2; exit 1; }
GRAFANA_URL=$(sh "$TT" "$CFG" grafana get "$GRAF_IDX" url); GRAFANA_URL="${GRAFANA_URL%/}"   # grafana.url
[ -n "$GRAFANA_URL" ] || { echo "grafana target '${GRAF_LABEL}' has no url in $CFG; run /scoutflo:connect" >&2; exit 1; }
# Load the secret store the way connect documents: $SCOUTFLO_ENV_FILE, then ./.scoutflo/env, then ~/.scoutflo/env.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
GRAF_TOKEN_VAR=$(sh "$TT" "$CFG" grafana get "$GRAF_IDX" token_env); [ -n "$GRAF_TOKEN_VAR" ] || GRAF_TOKEN_VAR="GRAFANA_TOKEN"   # grafana.token_env
GRAFANA_TOKEN=$(printenv "$GRAF_TOKEN_VAR" 2>/dev/null || true)
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "${GRAF_TOKEN_VAR} is not set; add it to ~/.scoutflo/env with /scoutflo:connect" >&2; exit 1; }
echo "grafana target: ${GRAF_LABEL} (${GRAFANA_URL})"
DS_UID="<datasource-uid>"     # the datasource the change updated or deleted
BACKUP_FILE="<backup-path>"   # the "backup:" path the backup block printed for it
SECRETS_FROM_ENV="<key=ENV_VAR pairs or none>"   # e.g. httpHeaderValue1=LOKI_DS_TOKEN, space-separated; none keeps every live secure value
for v in "$DS_UID" "$BACKUP_FILE" "$SECRETS_FROM_ENV"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
[ -s "$BACKUP_FILE" ] || { echo "No backup at ${BACKUP_FILE}" >&2; exit 1; }
jq -e --arg u "$DS_UID" '.uid == $u' "$BACKUP_FILE" > /dev/null || { echo "${BACKUP_FILE} is not a backup of ${DS_UID}" >&2; exit 1; }
# A file-provisioned datasource rejects API writes (403 "Cannot update read-only data source").
jq -e '.readOnly != true' "$BACKUP_FILE" > /dev/null \
  || { echo "${DS_UID} is file-provisioned: restore it in its provisioning file and record the rollback as incomplete" >&2; exit 1; }
# Map each secure key to the env var that holds it; jq reads the values itself, so no secret reaches argv.
SECRET_MAP='{}'
if [ "$SECRETS_FROM_ENV" != none ]; then
  for pair in $SECRETS_FROM_ENV; do
    case "$pair" in ?*=?*) ;; *) echo "SECRETS_FROM_ENV entries must be key=ENV_VAR, or the single word none" >&2; exit 1 ;; esac
    key="${pair%%=*}"; var="${pair#*=}"
    [ -n "$(printenv "$var" 2>/dev/null || true)" ] || { echo "${var} is not exported: load the ${key} value from your secret store" >&2; exit 1; }
    SECRET_MAP="$(jq -n --argjson m "$SECRET_MAP" --arg k "$key" --arg e "$var" '$m + {($k): $e}')"
  done
fi
LIVE="$(mktemp)"; trap 'rm -f "$LIVE"' EXIT
code="$(curl -sS --max-time 10 -o "$LIVE" -w '%{http_code}' \
  -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/datasources/uid/${DS_UID}")"
case "$code" in
  200) WRITE_METHOD="PUT"; WRITE_URL="${GRAFANA_URL}/api/datasources/uid/${DS_UID}"
    LIVE_VERSION="$(jq -e '.version' "$LIVE")" ;;
  404) WRITE_METHOD="POST"; WRITE_URL="${GRAFANA_URL}/api/datasources"; LIVE_VERSION="0"
    jq -e --argjson m "$SECRET_MAP" '((.secureJsonFields // {}) | keys) - ($m | keys) | length == 0' "$BACKUP_FILE" > /dev/null \
      || { echo "Re-creating ${DS_UID} needs every secure key the backup lists in SECRETS_FROM_ENV" >&2; exit 1; } ;;
  *) echo "GET ${DS_UID} returned HTTP ${code}; stopping" >&2; exit 1 ;;
esac
jq --argjson v "$LIVE_VERSION" --argjson m "$SECRET_MAP" \
  '.version = $v | if ($m | length) > 0 then .secureJsonData = ($m | map_values(env[.])) else . end' "$BACKUP_FILE" \
| curl -fsS --max-time 15 -X "$WRITE_METHOD" \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" -H "Content-Type: application/json" \
    -d @- "$WRITE_URL" > /dev/null
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/datasources/uid/${DS_UID}" \
  | jq -e --slurpfile b "$BACKUP_FILE" '((($b[0].secureJsonFields // {}) | keys) - ((.secureJsonFields // {}) | keys) | length == 0)
      and ([., $b[0]] | map({name, type, access, url, user, database, basicAuth, basicAuthUser, withCredentials, isDefault, jsonData}) | .[0] == .[1])'
```

Expected: `true`: the plain fields equal the backup and every secure key it lists is set again. With `SECRETS_FROM_ENV=none` the live secure values stay, which is right only when the change replaced no credential. A file-provisioned (`readOnly`) datasource is refused; restore it in its provisioning file and record the rollback as incomplete. If the change moved `isDefault`, run this block for the previous default datasource as well, because Grafana unset its flag as a side effect; when that datasource is file-provisioned, the same refusal applies.

## Dashboards

Dashboard design rules, the panel catalog, and the build-time QA checklist live in [dashboard-design.md](dashboard-design.md). This section covers the write mechanics only.

Write with `overwrite: false` and the current `version`, so a stale local copy cannot clobber a concurrent edit:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/setup-$(date -u +%F)/backups"
mkdir -p "$BACKUP_DIR"
DASH_UID="abcd1234"   # the dashboard you are repairing; a new build uses the next block
FOLDER_UID="folder-uid"
BACKUP_FILE="${BACKUP_DIR}/dashboard-${DASH_UID}-$(date -u +%H%M%S).json"
# Never overwrite an earlier restore point: a retry gets its own file.
[ ! -e "$BACKUP_FILE" ] || { echo "${BACKUP_FILE} already exists; rerun in a second" >&2; exit 1; }

# Repairs: re-fetch first, back up, then edit the JSON in place.
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/dashboards/uid/${DASH_UID}" \
  > "$BACKUP_FILE"
[ -s "$BACKUP_FILE" ] || { echo "Empty backup at ${BACKUP_FILE}; nothing was changed" >&2; exit 1; }
echo "backup: ${BACKUP_FILE}"
CURRENT_VERSION="$(jq '.dashboard.version' "$BACKUP_FILE")"

jq --argjson v "$CURRENT_VERSION" '
  .dashboard.version = $v
  | .overwrite = false
  | .folderUid = "'"$FOLDER_UID"'"
  # ... apply the announced panel-level edit here ...
' "$BACKUP_FILE" \
| curl -fsS --max-time 15 -X POST \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" -H "Content-Type: application/json" \
    -d @- "${GRAFANA_URL}/api/dashboards/db" \
| jq '{uid, version, status}'
```

A new build has no live version to back up. Save it with `overwrite: false`, which Grafana rejects for a uid that already exists, and record it in the ledger the dashboard rollback reads:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
DASH_FILE="<dashboard-json>"   # the dashboard JSON your build produced, carrying the uid you chose
FOLDER_UID="folder-uid"
case "$DASH_FILE" in ''|'<'*) echo "Set DASH_FILE to the dashboard JSON you built" >&2; exit 1 ;; esac
[ -s "$DASH_FILE" ] || { echo "No dashboard JSON at ${DASH_FILE}" >&2; exit 1; }
LEDGER="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/created.tsv"   # what this run created; rollbacks delete only these
NEW_UID="$(jq --arg f "$FOLDER_UID" '{dashboard: (.id = null | del(.version)), folderUid: $f, overwrite: false}' "$DASH_FILE" \
| curl -fsS --max-time 15 -X POST \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" -H "Content-Type: application/json" \
    -d @- "${GRAFANA_URL}/api/dashboards/db" \
| jq -er '.uid')"
echo "created: ${NEW_UID}"
mkdir -p "$(dirname "$LEDGER")"; printf 'dashboard\t%s\t%s\n' "$NEW_UID" "${GRAFANA_URL%/}" >> "$LEDGER"
```

Expected: `created: <uid>`, now listed in `created.tsv`. A uid that already exists fails the save and is never recorded.

Verify every write the same way, no exceptions: re-fetch by UID, replay every panel target through `/api/ds/query` ([audit-grafana pattern 1](../../audit-grafana/references/api-checks.md#apidsquery-cookbook)), and confirm template variables resolve:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
DS_UID="prom-uid"       # datasource backing the variable
VAR_QUERY="label_values(service)"   # the variable's own query
curl -fsS --max-time 15 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  --get --data-urlencode "query=$VAR_QUERY" \
  "${GRAFANA_URL}/api/datasources/proxy/uid/${DS_UID}/api/v1/label/service/values" \
  | jq '.data'
```

Expected: a non-empty value list. An empty list blanks every panel under that variable.

Rollback for a repaired dashboard, in its own fresh shell: re-save the backed-up JSON with a version bump. After your write the backup's `version` is behind the live one, and `overwrite: false` rejects a stale version, so the block saves the backup at the live `version`, back into the folder it came from.

```bash
set -eu
# Resolve the grafana target from toolkit.yaml by command, as audit-grafana does: a single block, or the
# labeled-list item SCOUTFLO_TARGET names. The URL and the token are never retyped here.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect" >&2; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GRAF_KIND=$(sh "$TT" "$CFG" grafana kind); GRAF_N=$(sh "$TT" "$CFG" grafana count)
[ "${GRAF_N:-0}" -ge 1 ] || { echo "no grafana target in $CFG; run /scoutflo:connect" >&2; exit 1; }
[ "$GRAF_KIND" != seq ] || [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "grafana in $CFG is a labeled list; set SCOUTFLO_TARGET to one of: $(sh "$TT" "$CFG" grafana labels | tr '\n' ' ')" >&2; exit 1; }
GRAF_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$GRAF_N" ]; do [ "$(sh "$TT" "$CFG" grafana label "$_i")" = "$SCOUTFLO_TARGET" ] && { GRAF_IDX=$_i; break; }; _i=$((_i+1)); done; fi
GRAF_LABEL=$(sh "$TT" "$CFG" grafana label "$GRAF_IDX")
[ -z "${SCOUTFLO_TARGET:-}" ] || [ "$GRAF_LABEL" = "$SCOUTFLO_TARGET" ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no grafana target in $CFG" >&2; exit 1; }
GRAFANA_URL=$(sh "$TT" "$CFG" grafana get "$GRAF_IDX" url); GRAFANA_URL="${GRAFANA_URL%/}"   # grafana.url
[ -n "$GRAFANA_URL" ] || { echo "grafana target '${GRAF_LABEL}' has no url in $CFG; run /scoutflo:connect" >&2; exit 1; }
# Load the secret store the way connect documents: $SCOUTFLO_ENV_FILE, then ./.scoutflo/env, then ~/.scoutflo/env.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
GRAF_TOKEN_VAR=$(sh "$TT" "$CFG" grafana get "$GRAF_IDX" token_env); [ -n "$GRAF_TOKEN_VAR" ] || GRAF_TOKEN_VAR="GRAFANA_TOKEN"   # grafana.token_env
GRAFANA_TOKEN=$(printenv "$GRAF_TOKEN_VAR" 2>/dev/null || true)
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "${GRAF_TOKEN_VAR} is not set; add it to ~/.scoutflo/env with /scoutflo:connect" >&2; exit 1; }
echo "grafana target: ${GRAF_LABEL} (${GRAFANA_URL})"
DASH_UID="<dashboard-uid>"    # the dashboard the change wrote
BACKUP_FILE="<backup-path>"   # the "backup:" path the write block printed
for v in "$DASH_UID" "$BACKUP_FILE"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
[ -s "$BACKUP_FILE" ] || { echo "No backup at ${BACKUP_FILE}" >&2; exit 1; }
jq -e --arg u "$DASH_UID" '.dashboard.uid == $u' "$BACKUP_FILE" > /dev/null || { echo "${BACKUP_FILE} is not a backup of ${DASH_UID}" >&2; exit 1; }
LIVE_VERSION="$(curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  "${GRAFANA_URL}/api/dashboards/uid/${DASH_UID}" | jq -e '.dashboard.version')"
jq --argjson v "$LIVE_VERSION" '{dashboard: (.dashboard | .id = null | .version = $v),
    folderUid: (.meta.folderUid // ""), overwrite: false, message: "setup-grafana rollback"}' "$BACKUP_FILE" \
| curl -fsS --max-time 15 -X POST \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" -H "Content-Type: application/json" \
    -d @- "${GRAFANA_URL}/api/dashboards/db" > /dev/null
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/dashboards/uid/${DASH_UID}" \
  | jq -e --slurpfile b "$BACKUP_FILE" '(.dashboard | del(.id, .version)) == ($b[0].dashboard | del(.id, .version))
      and (.meta.folderUid // "") == ($b[0].meta.folderUid // "")'
```

Expected: `true`. The rollback is one more version in the dashboard's history; the versions before it stay.

Rollback for a dashboard this run built new, in its own fresh shell; it refuses any uid the ledger does not list for this Grafana:

```bash
set -eu
# Resolve the grafana target from toolkit.yaml by command, as audit-grafana does: a single block, or the
# labeled-list item SCOUTFLO_TARGET names. The URL and the token are never retyped here.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect" >&2; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GRAF_KIND=$(sh "$TT" "$CFG" grafana kind); GRAF_N=$(sh "$TT" "$CFG" grafana count)
[ "${GRAF_N:-0}" -ge 1 ] || { echo "no grafana target in $CFG; run /scoutflo:connect" >&2; exit 1; }
[ "$GRAF_KIND" != seq ] || [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "grafana in $CFG is a labeled list; set SCOUTFLO_TARGET to one of: $(sh "$TT" "$CFG" grafana labels | tr '\n' ' ')" >&2; exit 1; }
GRAF_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$GRAF_N" ]; do [ "$(sh "$TT" "$CFG" grafana label "$_i")" = "$SCOUTFLO_TARGET" ] && { GRAF_IDX=$_i; break; }; _i=$((_i+1)); done; fi
GRAF_LABEL=$(sh "$TT" "$CFG" grafana label "$GRAF_IDX")
[ -z "${SCOUTFLO_TARGET:-}" ] || [ "$GRAF_LABEL" = "$SCOUTFLO_TARGET" ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no grafana target in $CFG" >&2; exit 1; }
GRAFANA_URL=$(sh "$TT" "$CFG" grafana get "$GRAF_IDX" url); GRAFANA_URL="${GRAFANA_URL%/}"   # grafana.url
[ -n "$GRAFANA_URL" ] || { echo "grafana target '${GRAF_LABEL}' has no url in $CFG; run /scoutflo:connect" >&2; exit 1; }
# Load the secret store the way connect documents: $SCOUTFLO_ENV_FILE, then ./.scoutflo/env, then ~/.scoutflo/env.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
GRAF_TOKEN_VAR=$(sh "$TT" "$CFG" grafana get "$GRAF_IDX" token_env); [ -n "$GRAF_TOKEN_VAR" ] || GRAF_TOKEN_VAR="GRAFANA_TOKEN"   # grafana.token_env
GRAFANA_TOKEN=$(printenv "$GRAF_TOKEN_VAR" 2>/dev/null || true)
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "${GRAF_TOKEN_VAR} is not set; add it to ~/.scoutflo/env with /scoutflo:connect" >&2; exit 1; }
echo "grafana target: ${GRAF_LABEL} (${GRAFANA_URL})"
DASH_UID="<dashboard-uid>"   # the "created:" uid the new-build block printed; the ledger check refuses any other
case "$DASH_UID" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac
LEDGER="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/created.tsv"
ENTRY="$(printf 'dashboard\t%s\t%s' "$DASH_UID" "$GRAFANA_URL")"
grep -qxF "$ENTRY" "$LEDGER" 2>/dev/null \
  || { echo "dashboard ${DASH_UID} is not in ${LEDGER} for ${GRAFANA_URL}: this run did not create it, so it stays" >&2; exit 1; }
curl -fsS --max-time 10 -X DELETE -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  "${GRAFANA_URL}/api/dashboards/uid/${DASH_UID}" > /dev/null
code="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/dashboards/uid/${DASH_UID}")"
echo "post-delete: ${code}"
[ "$code" = "404" ] || { echo "dashboard ${DASH_UID} is still there" >&2; exit 1; }
{ grep -vxF "$ENTRY" "$LEDGER" || true; } > "${LEDGER}.tmp" && mv "${LEDGER}.tmp" "$LEDGER"
```

Expected: `post-delete: 404`, and the uid is gone from `created.tsv`.

## Alerting

### Alert rules

Provisioning-API create. Thresholds, evaluation windows, and label values below are examples; declare them as named variables and tune to your traffic.

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
DS_UID="prom-uid"                         # datasource the rule queries
ERROR_RATE_THRESHOLD="0.05"               # example, tune to your traffic
FOLDER_UID="folder-uid"
RULE_GROUP="checkout-availability"
EVAL_INTERVAL="1m"                        # example, tune to your evaluation budget
LEDGER="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/created.tsv"   # what this run created; rollbacks delete only these

# A failed create stops here, so it never reaches the ledger.
NEW_UID="$(jq -n --arg ds "$DS_UID" --argjson thresh "$ERROR_RATE_THRESHOLD" '
{
  title: "checkout error rate high",
  ruleGroup: "'"$RULE_GROUP"'",
  folderUID: "'"$FOLDER_UID"'",
  condition: "C",
  data: [
    { refId: "A", datasourceUid: $ds,
      model: { expr: "sum(rate(http_requests_total{service=\"checkout\",status=~\"5..\"}[5m])) / sum(rate(http_requests_total{service=\"checkout\"}[5m]))", instant: true } },
    { refId: "C", datasourceUid: "__expr__",
      model: { type: "threshold", expression: "A", conditions: [ { evaluator: { type: "gt", params: [$thresh] } } ] } }
  ],
  noDataState: "Alerting",
  execErrState: "Alerting",
  "for": "5m",
  labels: { severity: "high", service: "checkout" },
  annotations: { summary: "checkout error rate above threshold", runbook_url: "https://runbooks.example.com/checkout-errors" }
}' | curl -fsS --max-time 15 -X POST \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" -H "Content-Type: application/json" \
    -d @- "${GRAFANA_URL}/api/v1/provisioning/alert-rules" \
| jq -er '.uid')"
echo "created: ${NEW_UID}"
mkdir -p "$(dirname "$LEDGER")"; printf 'alert-rule\t%s\t%s\n' "$NEW_UID" "${GRAFANA_URL%/}" >> "$LEDGER"
```

Verify: re-fetch by UID, replay the primary query through `/api/ds/query`, and read live state:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
RULE_UID="rule-uid"   # from the create response
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/v1/provisioning/alert-rules/${RULE_UID}" \
  | jq '{title, labels, "for", noDataState, execErrState}'
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/prometheus/grafana/api/v1/rules" \
  | jq --arg t "checkout error rate high" '.data.groups[].rules[] | select(.name == $t) | {state, health}'
```

Rollback for a rule this run created, in its own fresh shell; it refuses any uid the ledger does not list for this Grafana. Deleting a rule removes a detection path; confirm it individually.

```bash
set -eu
# Resolve the grafana target from toolkit.yaml by command, as audit-grafana does: a single block, or the
# labeled-list item SCOUTFLO_TARGET names. The URL and the token are never retyped here.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect" >&2; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GRAF_KIND=$(sh "$TT" "$CFG" grafana kind); GRAF_N=$(sh "$TT" "$CFG" grafana count)
[ "${GRAF_N:-0}" -ge 1 ] || { echo "no grafana target in $CFG; run /scoutflo:connect" >&2; exit 1; }
[ "$GRAF_KIND" != seq ] || [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "grafana in $CFG is a labeled list; set SCOUTFLO_TARGET to one of: $(sh "$TT" "$CFG" grafana labels | tr '\n' ' ')" >&2; exit 1; }
GRAF_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$GRAF_N" ]; do [ "$(sh "$TT" "$CFG" grafana label "$_i")" = "$SCOUTFLO_TARGET" ] && { GRAF_IDX=$_i; break; }; _i=$((_i+1)); done; fi
GRAF_LABEL=$(sh "$TT" "$CFG" grafana label "$GRAF_IDX")
[ -z "${SCOUTFLO_TARGET:-}" ] || [ "$GRAF_LABEL" = "$SCOUTFLO_TARGET" ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no grafana target in $CFG" >&2; exit 1; }
GRAFANA_URL=$(sh "$TT" "$CFG" grafana get "$GRAF_IDX" url); GRAFANA_URL="${GRAFANA_URL%/}"   # grafana.url
[ -n "$GRAFANA_URL" ] || { echo "grafana target '${GRAF_LABEL}' has no url in $CFG; run /scoutflo:connect" >&2; exit 1; }
# Load the secret store the way connect documents: $SCOUTFLO_ENV_FILE, then ./.scoutflo/env, then ~/.scoutflo/env.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
GRAF_TOKEN_VAR=$(sh "$TT" "$CFG" grafana get "$GRAF_IDX" token_env); [ -n "$GRAF_TOKEN_VAR" ] || GRAF_TOKEN_VAR="GRAFANA_TOKEN"   # grafana.token_env
GRAFANA_TOKEN=$(printenv "$GRAF_TOKEN_VAR" 2>/dev/null || true)
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "${GRAF_TOKEN_VAR} is not set; add it to ~/.scoutflo/env with /scoutflo:connect" >&2; exit 1; }
echo "grafana target: ${GRAF_LABEL} (${GRAFANA_URL})"
RULE_UID="<rule-uid>"   # the "created:" uid; the ledger check below refuses any other
case "$RULE_UID" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac
LEDGER="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/created.tsv"
ENTRY="$(printf 'alert-rule\t%s\t%s' "$RULE_UID" "$GRAFANA_URL")"
grep -qxF "$ENTRY" "$LEDGER" 2>/dev/null \
  || { echo "alert rule ${RULE_UID} is not in ${LEDGER} for ${GRAFANA_URL}: this run did not create it, so it stays" >&2; exit 1; }
curl -fsS --max-time 10 -X DELETE -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  "${GRAFANA_URL}/api/v1/provisioning/alert-rules/${RULE_UID}" > /dev/null
code="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/v1/provisioning/alert-rules/${RULE_UID}")"
echo "post-delete: ${code}"
[ "$code" = "404" ] || { echo "alert rule ${RULE_UID} is still there" >&2; exit 1; }
{ grep -vxF "$ENTRY" "$LEDGER" || true; } > "${LEDGER}.tmp" && mv "${LEDGER}.tmp" "$LEDGER"
```

Expected: `post-delete: 404`, and the uid is gone from `created.tsv`.

Rollback for a rule you updated, in its own fresh shell: PUT the backup to the same uid. The block keeps the rule's current provenance: a write without `X-Disable-Provenance` would lock a UI-managed rule as API-managed, and the API cannot unlock one that is already locked.

```bash
set -eu
# Resolve the grafana target from toolkit.yaml by command, as audit-grafana does: a single block, or the
# labeled-list item SCOUTFLO_TARGET names. The URL and the token are never retyped here.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect" >&2; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GRAF_KIND=$(sh "$TT" "$CFG" grafana kind); GRAF_N=$(sh "$TT" "$CFG" grafana count)
[ "${GRAF_N:-0}" -ge 1 ] || { echo "no grafana target in $CFG; run /scoutflo:connect" >&2; exit 1; }
[ "$GRAF_KIND" != seq ] || [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "grafana in $CFG is a labeled list; set SCOUTFLO_TARGET to one of: $(sh "$TT" "$CFG" grafana labels | tr '\n' ' ')" >&2; exit 1; }
GRAF_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$GRAF_N" ]; do [ "$(sh "$TT" "$CFG" grafana label "$_i")" = "$SCOUTFLO_TARGET" ] && { GRAF_IDX=$_i; break; }; _i=$((_i+1)); done; fi
GRAF_LABEL=$(sh "$TT" "$CFG" grafana label "$GRAF_IDX")
[ -z "${SCOUTFLO_TARGET:-}" ] || [ "$GRAF_LABEL" = "$SCOUTFLO_TARGET" ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no grafana target in $CFG" >&2; exit 1; }
GRAFANA_URL=$(sh "$TT" "$CFG" grafana get "$GRAF_IDX" url); GRAFANA_URL="${GRAFANA_URL%/}"   # grafana.url
[ -n "$GRAFANA_URL" ] || { echo "grafana target '${GRAF_LABEL}' has no url in $CFG; run /scoutflo:connect" >&2; exit 1; }
# Load the secret store the way connect documents: $SCOUTFLO_ENV_FILE, then ./.scoutflo/env, then ~/.scoutflo/env.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
GRAF_TOKEN_VAR=$(sh "$TT" "$CFG" grafana get "$GRAF_IDX" token_env); [ -n "$GRAF_TOKEN_VAR" ] || GRAF_TOKEN_VAR="GRAFANA_TOKEN"   # grafana.token_env
GRAFANA_TOKEN=$(printenv "$GRAF_TOKEN_VAR" 2>/dev/null || true)
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "${GRAF_TOKEN_VAR} is not set; add it to ~/.scoutflo/env with /scoutflo:connect" >&2; exit 1; }
echo "grafana target: ${GRAF_LABEL} (${GRAFANA_URL})"
RULE_UID="<rule-uid>"         # the rule the change wrote
BACKUP_FILE="<backup-path>"   # the "backup:" path the backup block printed for it
for v in "$RULE_UID" "$BACKUP_FILE"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
[ -s "$BACKUP_FILE" ] || { echo "No backup at ${BACKUP_FILE}" >&2; exit 1; }
jq -e --arg u "$RULE_UID" '.uid == $u' "$BACKUP_FILE" > /dev/null || { echo "${BACKUP_FILE} is not a backup of ${RULE_UID}" >&2; exit 1; }
LIVE_PROV="$(curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  "${GRAFANA_URL}/api/v1/provisioning/alert-rules/${RULE_UID}" | jq -er '.provenance // ""')"
[ "$LIVE_PROV" != "file" ] || { echo "${RULE_UID} is file-provisioned: change its provisioning file and record the rollback as incomplete" >&2; exit 1; }
set --
if [ -z "$LIVE_PROV" ]; then set -- -H "X-Disable-Provenance: true"; fi
jq 'del(.id, .updated, .provenance)' "$BACKUP_FILE" \
| curl -fsS --max-time 15 -X PUT "$@" \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" -H "Content-Type: application/json" \
    -d @- "${GRAFANA_URL}/api/v1/provisioning/alert-rules/${RULE_UID}" > /dev/null
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/v1/provisioning/alert-rules/${RULE_UID}" \
  | jq -e --slurpfile b "$BACKUP_FILE" 'del(.id, .updated, .provenance) == ($b[0] | del(.id, .updated, .provenance))'
```

Expected: `true`, the rule equal to its backup apart from `id`, `updated`, and `provenance`. A rule with `file` provenance is refused: change its provisioning file and record the rollback as incomplete.

### Contact points

Webhook URLs and receiver API keys are secrets: export them, build the payload with `jq`, pipe into `curl`.

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
SLACK_WEBHOOK_ENV="TEAM_SLACK_WEBHOOK"   # env var name from toolkit.yaml
LEDGER="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/created.tsv"   # what this run created; rollbacks delete only these

# A failed create stops here, so it never reaches the ledger.
NEW_UID="$(jq -n --arg url "${!SLACK_WEBHOOK_ENV}" '
{ name: "team-default", type: "slack",
  settings: { url: $url, title: "{{ .CommonLabels.alertname }}" } }' \
| curl -fsS --max-time 15 -X POST \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" -H "Content-Type: application/json" \
    -d @- "${GRAFANA_URL}/api/v1/provisioning/contact-points" \
| jq -er '.uid')"
echo "created: ${NEW_UID}"
mkdir -p "$(dirname "$LEDGER")"; printf 'contact-point\t%s\t%s\n' "$NEW_UID" "${GRAFANA_URL%/}" >> "$LEDGER"
```

Verify by re-fetching and confirming name, type, and settings shape. Secure settings come back masked, so this proves the receiver exists correctly configured, not that it delivers; delivery is proven only by a test-fire.

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
CP_UID="cp-uid"   # from the create response
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/v1/provisioning/contact-points/${CP_UID}" \
  | jq '{name, type, settings}'
```

Rollback for a contact point this run created, in its own fresh shell; it refuses any uid the ledger does not list for this Grafana. Grafana refuses to delete a contact point a notification policy still routes to, so restore the policy tree first.

```bash
set -eu
# Resolve the grafana target from toolkit.yaml by command, as audit-grafana does: a single block, or the
# labeled-list item SCOUTFLO_TARGET names. The URL and the token are never retyped here.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect" >&2; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GRAF_KIND=$(sh "$TT" "$CFG" grafana kind); GRAF_N=$(sh "$TT" "$CFG" grafana count)
[ "${GRAF_N:-0}" -ge 1 ] || { echo "no grafana target in $CFG; run /scoutflo:connect" >&2; exit 1; }
[ "$GRAF_KIND" != seq ] || [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "grafana in $CFG is a labeled list; set SCOUTFLO_TARGET to one of: $(sh "$TT" "$CFG" grafana labels | tr '\n' ' ')" >&2; exit 1; }
GRAF_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$GRAF_N" ]; do [ "$(sh "$TT" "$CFG" grafana label "$_i")" = "$SCOUTFLO_TARGET" ] && { GRAF_IDX=$_i; break; }; _i=$((_i+1)); done; fi
GRAF_LABEL=$(sh "$TT" "$CFG" grafana label "$GRAF_IDX")
[ -z "${SCOUTFLO_TARGET:-}" ] || [ "$GRAF_LABEL" = "$SCOUTFLO_TARGET" ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no grafana target in $CFG" >&2; exit 1; }
GRAFANA_URL=$(sh "$TT" "$CFG" grafana get "$GRAF_IDX" url); GRAFANA_URL="${GRAFANA_URL%/}"   # grafana.url
[ -n "$GRAFANA_URL" ] || { echo "grafana target '${GRAF_LABEL}' has no url in $CFG; run /scoutflo:connect" >&2; exit 1; }
# Load the secret store the way connect documents: $SCOUTFLO_ENV_FILE, then ./.scoutflo/env, then ~/.scoutflo/env.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
GRAF_TOKEN_VAR=$(sh "$TT" "$CFG" grafana get "$GRAF_IDX" token_env); [ -n "$GRAF_TOKEN_VAR" ] || GRAF_TOKEN_VAR="GRAFANA_TOKEN"   # grafana.token_env
GRAFANA_TOKEN=$(printenv "$GRAF_TOKEN_VAR" 2>/dev/null || true)
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "${GRAF_TOKEN_VAR} is not set; add it to ~/.scoutflo/env with /scoutflo:connect" >&2; exit 1; }
echo "grafana target: ${GRAF_LABEL} (${GRAFANA_URL})"
CP_UID="<contact-point-uid>"   # the "created:" uid; the ledger check below refuses any other
case "$CP_UID" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac
LEDGER="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/created.tsv"
ENTRY="$(printf 'contact-point\t%s\t%s' "$CP_UID" "$GRAFANA_URL")"
grep -qxF "$ENTRY" "$LEDGER" 2>/dev/null \
  || { echo "contact point ${CP_UID} is not in ${LEDGER} for ${GRAFANA_URL}: this run did not create it, so it stays" >&2; exit 1; }
curl -fsS --max-time 10 -X DELETE -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  "${GRAFANA_URL}/api/v1/provisioning/contact-points/${CP_UID}" > /dev/null
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/v1/provisioning/contact-points" \
  | jq -e --arg u "$CP_UID" 'type == "array" and all(.[]; .uid != $u)'
{ grep -vxF "$ENTRY" "$LEDGER" || true; } > "${LEDGER}.tmp" && mv "${LEDGER}.tmp" "$LEDGER"
```

Expected: `true`, and the uid is gone from `created.tsv`.

Rollback for a contact point you updated, in its own fresh shell: PUT the backup to the same uid. Secure settings come back masked (`[REDACTED]`) and Grafana keeps the live value for a masked field, so a secret the change replaced comes back only from your secret store: set `SECRET_KEY` and `SECRET_ENV`, or set both to `none` when the change replaced no secret. Like the rule restore, the block keeps the current provenance.

```bash
set -eu
# Resolve the grafana target from toolkit.yaml by command, as audit-grafana does: a single block, or the
# labeled-list item SCOUTFLO_TARGET names. The URL and the token are never retyped here.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect" >&2; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GRAF_KIND=$(sh "$TT" "$CFG" grafana kind); GRAF_N=$(sh "$TT" "$CFG" grafana count)
[ "${GRAF_N:-0}" -ge 1 ] || { echo "no grafana target in $CFG; run /scoutflo:connect" >&2; exit 1; }
[ "$GRAF_KIND" != seq ] || [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "grafana in $CFG is a labeled list; set SCOUTFLO_TARGET to one of: $(sh "$TT" "$CFG" grafana labels | tr '\n' ' ')" >&2; exit 1; }
GRAF_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$GRAF_N" ]; do [ "$(sh "$TT" "$CFG" grafana label "$_i")" = "$SCOUTFLO_TARGET" ] && { GRAF_IDX=$_i; break; }; _i=$((_i+1)); done; fi
GRAF_LABEL=$(sh "$TT" "$CFG" grafana label "$GRAF_IDX")
[ -z "${SCOUTFLO_TARGET:-}" ] || [ "$GRAF_LABEL" = "$SCOUTFLO_TARGET" ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no grafana target in $CFG" >&2; exit 1; }
GRAFANA_URL=$(sh "$TT" "$CFG" grafana get "$GRAF_IDX" url); GRAFANA_URL="${GRAFANA_URL%/}"   # grafana.url
[ -n "$GRAFANA_URL" ] || { echo "grafana target '${GRAF_LABEL}' has no url in $CFG; run /scoutflo:connect" >&2; exit 1; }
# Load the secret store the way connect documents: $SCOUTFLO_ENV_FILE, then ./.scoutflo/env, then ~/.scoutflo/env.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
GRAF_TOKEN_VAR=$(sh "$TT" "$CFG" grafana get "$GRAF_IDX" token_env); [ -n "$GRAF_TOKEN_VAR" ] || GRAF_TOKEN_VAR="GRAFANA_TOKEN"   # grafana.token_env
GRAFANA_TOKEN=$(printenv "$GRAF_TOKEN_VAR" 2>/dev/null || true)
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "${GRAF_TOKEN_VAR} is not set; add it to ~/.scoutflo/env with /scoutflo:connect" >&2; exit 1; }
echo "grafana target: ${GRAF_LABEL} (${GRAFANA_URL})"
CP_UID="<contact-point-uid>"            # the contact point the change wrote
BACKUP_FILE="<backup-path>"             # the "backup:" path the backup block printed for it
SECRET_KEY="<settings-key or none>"     # settings key whose secret the change replaced, e.g. url for Slack; none if it replaced no secret
SECRET_ENV="<env-var or none>"          # env var holding that key's previous value from your secret store; none with SECRET_KEY=none
for v in "$CP_UID" "$BACKUP_FILE" "$SECRET_KEY" "$SECRET_ENV"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
[ -s "$BACKUP_FILE" ] || { echo "No backup at ${BACKUP_FILE}" >&2; exit 1; }
jq -e --arg u "$CP_UID" '.uid == $u' "$BACKUP_FILE" > /dev/null || { echo "${BACKUP_FILE} is not a backup of ${CP_UID}" >&2; exit 1; }
if [ "$SECRET_KEY" != none ]; then
  [ "$SECRET_ENV" != none ] && [ -n "$(printenv "$SECRET_ENV" 2>/dev/null || true)" ] \
    || { echo "Export SECRET_ENV with the previous ${SECRET_KEY} value from your secret store" >&2; exit 1; }
fi
LIVE_PROV="$(curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/v1/provisioning/contact-points" \
  | jq -er --arg u "$CP_UID" '.[] | select(.uid == $u) | .provenance // ""')" \
  || { echo "${CP_UID} is not in the live contact points: nothing to restore onto" >&2; exit 1; }
[ "$LIVE_PROV" != "file" ] || { echo "${CP_UID} is file-provisioned: change its provisioning file and record the rollback as incomplete" >&2; exit 1; }
set --
if [ -z "$LIVE_PROV" ]; then set -- -H "X-Disable-Provenance: true"; fi
# jq reads the secret from the environment, so it never reaches argv.
jq --arg k "$SECRET_KEY" --arg e "$SECRET_ENV" 'del(.provenance) | if $k != "none" then .settings[$k] = env[$e] else . end' "$BACKUP_FILE" \
| curl -fsS --max-time 15 -X PUT "$@" \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" -H "Content-Type: application/json" \
    -d @- "${GRAFANA_URL}/api/v1/provisioning/contact-points/${CP_UID}" > /dev/null
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/v1/provisioning/contact-points" \
  | jq -e --arg u "$CP_UID" --slurpfile b "$BACKUP_FILE" '[.[] | select(.uid == $u)]
      | length == 1 and (.[0] | {name, type, disableResolveMessage, settings}) == ($b[0] | {name, type, disableResolveMessage, settings})'
```

Expected: `true`. The comparison runs on the masked settings, so it proves the shape came back; delivery with the restored secret is proven only by a test-fire. With `SECRET_KEY=none` the live secret stays, which is right only when the change replaced no secret.

### Notification policies

The policies endpoint replaces the entire tree in one PUT. GET the current tree into the backup first, edit that copy, and PUT the result; a hand-built partial tree silently deletes every route you did not mention.

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/setup-$(date -u +%F)/backups"
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="${BACKUP_DIR}/policies-$(date -u +%H%M%S).json"
# Never overwrite an earlier restore point: a retry gets its own file.
[ ! -e "$BACKUP_FILE" ] || { echo "${BACKUP_FILE} already exists; rerun in a second" >&2; exit 1; }
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/v1/provisioning/policies" \
  > "$BACKUP_FILE"
[ -s "$BACKUP_FILE" ] || { echo "Empty backup at ${BACKUP_FILE}; nothing was changed" >&2; exit 1; }
echo "backup: ${BACKUP_FILE}"

jq '.routes += [
  { receiver: "team-pager", matchers: ["severity=critical"],
    group_by: ["alertname", "service"], group_wait: "30s", group_interval: "5m", repeat_interval: "4h" }
]' "$BACKUP_FILE" \
| curl -fsS --max-time 15 -X PUT \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" -H "Content-Type: application/json" \
    -d @- "${GRAFANA_URL}/api/v1/provisioning/policies" > /dev/null
# Save the tree this write left: the rollback restores only while the live tree still equals it.
AFTER_FILE="${BACKUP_FILE%.json}.after.json"
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/v1/provisioning/policies" \
  > "$AFTER_FILE"
[ -s "$AFTER_FILE" ] && echo "after: ${AFTER_FILE}"
```

Expected: `backup: <path>`, then `after: <path>`; record both. `group_wait`, `group_interval`, and `repeat_interval` values above are examples; tune to how fast your team wants the first notification versus how much grouping you want on a storm. Verify by re-fetching the tree and comparing it with the intended version:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
BACKUP_FILE="<backup-path>"   # the "backup:" path the write block printed
case "$BACKUP_FILE" in ''|'<'*) echo "Set BACKUP_FILE to the backup the write block printed" >&2; exit 1 ;; esac
[ -s "$BACKUP_FILE" ] || { echo "No backup at ${BACKUP_FILE}" >&2; exit 1; }
# Compose the intended tree from the backup (append your new route object) and compare it with what the
# server now serves. Both sides go through jq -S without provenance, so formatting and key order cannot differ.
INTENDED="$(mktemp)"; LIVE="$(mktemp)"; trap 'rm -f "$INTENDED" "$LIVE"' EXIT
jq -S 'del(.provenance) | .routes += [{"receiver": "your-new-receiver"}]' "$BACKUP_FILE" > "$INTENDED"   # your real route object here
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/v1/provisioning/policies" \
  | jq -S 'del(.provenance)' > "$LIVE"
diff "$LIVE" "$INTENDED"
```

Expected: no output and exit 0.

Rollback, in its own fresh shell: PUT the backed-up tree. The PUT replaces the whole tree, so the block first checks that the live tree still equals the `after:` tree your write left, ignoring `provenance`, and refuses otherwise: a route someone added since would be lost. Like the rule restore, the block keeps the tree's current provenance.

```bash
set -eu
# Resolve the grafana target from toolkit.yaml by command, as audit-grafana does: a single block, or the
# labeled-list item SCOUTFLO_TARGET names. The URL and the token are never retyped here.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect" >&2; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GRAF_KIND=$(sh "$TT" "$CFG" grafana kind); GRAF_N=$(sh "$TT" "$CFG" grafana count)
[ "${GRAF_N:-0}" -ge 1 ] || { echo "no grafana target in $CFG; run /scoutflo:connect" >&2; exit 1; }
[ "$GRAF_KIND" != seq ] || [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "grafana in $CFG is a labeled list; set SCOUTFLO_TARGET to one of: $(sh "$TT" "$CFG" grafana labels | tr '\n' ' ')" >&2; exit 1; }
GRAF_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$GRAF_N" ]; do [ "$(sh "$TT" "$CFG" grafana label "$_i")" = "$SCOUTFLO_TARGET" ] && { GRAF_IDX=$_i; break; }; _i=$((_i+1)); done; fi
GRAF_LABEL=$(sh "$TT" "$CFG" grafana label "$GRAF_IDX")
[ -z "${SCOUTFLO_TARGET:-}" ] || [ "$GRAF_LABEL" = "$SCOUTFLO_TARGET" ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no grafana target in $CFG" >&2; exit 1; }
GRAFANA_URL=$(sh "$TT" "$CFG" grafana get "$GRAF_IDX" url); GRAFANA_URL="${GRAFANA_URL%/}"   # grafana.url
[ -n "$GRAFANA_URL" ] || { echo "grafana target '${GRAF_LABEL}' has no url in $CFG; run /scoutflo:connect" >&2; exit 1; }
# Load the secret store the way connect documents: $SCOUTFLO_ENV_FILE, then ./.scoutflo/env, then ~/.scoutflo/env.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
GRAF_TOKEN_VAR=$(sh "$TT" "$CFG" grafana get "$GRAF_IDX" token_env); [ -n "$GRAF_TOKEN_VAR" ] || GRAF_TOKEN_VAR="GRAFANA_TOKEN"   # grafana.token_env
GRAFANA_TOKEN=$(printenv "$GRAF_TOKEN_VAR" 2>/dev/null || true)
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "${GRAF_TOKEN_VAR} is not set; add it to ~/.scoutflo/env with /scoutflo:connect" >&2; exit 1; }
echo "grafana target: ${GRAF_LABEL} (${GRAFANA_URL})"
BACKUP_FILE="<backup-path>"   # the "backup:" path the policy write block printed
AFTER_FILE="<after-path>"     # the "after:" path the same block printed
for v in "$BACKUP_FILE" "$AFTER_FILE"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
# Without these checks an empty or wrong file would replace the whole tree.
[ -s "$BACKUP_FILE" ] || { echo "No backup at ${BACKUP_FILE}" >&2; exit 1; }
[ -s "$AFTER_FILE" ] || { echo "No after-write tree at ${AFTER_FILE}" >&2; exit 1; }
for f in "$BACKUP_FILE" "$AFTER_FILE"; do jq -e '.receiver' "$f" > /dev/null || { echo "${f} is not a notification-policy tree" >&2; exit 1; }; done
LIVE="$(mktemp)"; trap 'rm -f "$LIVE"' EXIT
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/v1/provisioning/policies" > "$LIVE"
jq -e --slurpfile a "$AFTER_FILE" 'del(.provenance) == ($a[0] | del(.provenance))' "$LIVE" > /dev/null \
  || { echo "The live tree changed after your write (compare it with ${AFTER_FILE}); re-plan the rollback instead of overwriting those changes" >&2; exit 1; }
LIVE_PROV="$(jq -r '.provenance // ""' "$LIVE")"
[ "$LIVE_PROV" != "file" ] || { echo "The policy tree is file-provisioned: change its provisioning file and record the rollback as incomplete" >&2; exit 1; }
set --
if [ -z "$LIVE_PROV" ]; then set -- -H "X-Disable-Provenance: true"; fi
jq 'del(.provenance)' "$BACKUP_FILE" \
| curl -fsS --max-time 15 -X PUT "$@" \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" -H "Content-Type: application/json" \
    -d @- "${GRAFANA_URL}/api/v1/provisioning/policies" > /dev/null
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/v1/provisioning/policies" \
  | jq -e --slurpfile b "$BACKUP_FILE" 'del(.provenance) == ($b[0] | del(.provenance))'
```

Expected: `true`, the live tree equal to the backup. A refusal on the after-write check means someone changed routing since your write: re-announce the rollback against the new tree.

## Test-fire delivery

A test-fire sends a real notification to real humans. Tell your on-call before firing at any paging receiver, and confirm every test-fire as its own individually announced change, never inside a batch.

**Receiver test** (weakest; bypasses the routing tree, proves only that the receiver itself delivers):

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
CP_UID="cp-uid"   # the contact point under test
jq -n '{ alert: { labels: { alertname: "ToolkitReceiverTest" },
                   annotations: { summary: "Controlled receiver test from setup-grafana. Safe to acknowledge." } } }' \
| curl -fsS --max-time 15 -X POST \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" -H "Content-Type: application/json" \
    -d @- "${GRAFANA_URL}/api/v1/provisioning/contact-points/${CP_UID}/test"
```

**Routed canary** (stronger; proves rule, labels, policy tree, and receiver together):

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
FOLDER_UID="folder-uid"
TEST_SEVERITY="critical"   # the route under test
LEDGER="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/created.tsv"   # what this run created; the cleanup deletes only these

NEW_UID="$(jq -n --arg sev "$TEST_SEVERITY" '
{ title: "ToolkitRoutingCanary", ruleGroup: "toolkit-canary", folderUID: "'"$FOLDER_UID"'",
  condition: "C",
  data: [ { refId: "C", datasourceUid: "__expr__",
            model: { type: "math", expression: "1 == 1" } } ],
  noDataState: "OK", execErrState: "Alerting", "for": "0s",
  labels: { severity: $sev, service: "receiver-test" },
  annotations: { summary: "Controlled routing canary from setup-grafana. Safe to acknowledge." } }' \
| curl -fsS --max-time 15 -X POST \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" -H "Content-Type: application/json" \
    -d @- "${GRAFANA_URL}/api/v1/provisioning/alert-rules" \
| jq -er '.uid')"
echo "created: ${NEW_UID}"
mkdir -p "$(dirname "$LEDGER")"; printf 'alert-rule\t%s\t%s\n' "$NEW_UID" "${GRAFANA_URL%/}" >> "$LEDGER"
```

Wait one evaluation cycle plus the route's `group_wait`, then confirm with a named person that the notification arrived at the receiver the severity is supposed to reach. Delivery is proven by receipt, not by an HTTP 200. Always clean up:

```bash
set -eu
# Resolve the grafana target from toolkit.yaml by command, as audit-grafana does: a single block, or the
# labeled-list item SCOUTFLO_TARGET names. The URL and the token are never retyped here.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect" >&2; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GRAF_KIND=$(sh "$TT" "$CFG" grafana kind); GRAF_N=$(sh "$TT" "$CFG" grafana count)
[ "${GRAF_N:-0}" -ge 1 ] || { echo "no grafana target in $CFG; run /scoutflo:connect" >&2; exit 1; }
[ "$GRAF_KIND" != seq ] || [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "grafana in $CFG is a labeled list; set SCOUTFLO_TARGET to one of: $(sh "$TT" "$CFG" grafana labels | tr '\n' ' ')" >&2; exit 1; }
GRAF_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$GRAF_N" ]; do [ "$(sh "$TT" "$CFG" grafana label "$_i")" = "$SCOUTFLO_TARGET" ] && { GRAF_IDX=$_i; break; }; _i=$((_i+1)); done; fi
GRAF_LABEL=$(sh "$TT" "$CFG" grafana label "$GRAF_IDX")
[ -z "${SCOUTFLO_TARGET:-}" ] || [ "$GRAF_LABEL" = "$SCOUTFLO_TARGET" ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no grafana target in $CFG" >&2; exit 1; }
GRAFANA_URL=$(sh "$TT" "$CFG" grafana get "$GRAF_IDX" url); GRAFANA_URL="${GRAFANA_URL%/}"   # grafana.url
[ -n "$GRAFANA_URL" ] || { echo "grafana target '${GRAF_LABEL}' has no url in $CFG; run /scoutflo:connect" >&2; exit 1; }
# Load the secret store the way connect documents: $SCOUTFLO_ENV_FILE, then ./.scoutflo/env, then ~/.scoutflo/env.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
GRAF_TOKEN_VAR=$(sh "$TT" "$CFG" grafana get "$GRAF_IDX" token_env); [ -n "$GRAF_TOKEN_VAR" ] || GRAF_TOKEN_VAR="GRAFANA_TOKEN"   # grafana.token_env
GRAFANA_TOKEN=$(printenv "$GRAF_TOKEN_VAR" 2>/dev/null || true)
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "${GRAF_TOKEN_VAR} is not set; add it to ~/.scoutflo/env with /scoutflo:connect" >&2; exit 1; }
echo "grafana target: ${GRAF_LABEL} (${GRAFANA_URL})"
CANARY_UID="<canary-rule-uid>"   # the "created:" uid the canary create printed; the ledger check refuses any other
case "$CANARY_UID" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac
LEDGER="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/created.tsv"
ENTRY="$(printf 'alert-rule\t%s\t%s' "$CANARY_UID" "$GRAFANA_URL")"
grep -qxF "$ENTRY" "$LEDGER" 2>/dev/null \
  || { echo "rule ${CANARY_UID} is not in ${LEDGER} for ${GRAFANA_URL}: this run did not create it, so it stays" >&2; exit 1; }
curl -fsS --max-time 10 -X DELETE -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  "${GRAFANA_URL}/api/v1/provisioning/alert-rules/${CANARY_UID}" > /dev/null
code="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/v1/provisioning/alert-rules/${CANARY_UID}")"
echo "post-delete: ${code}"
[ "$code" = "404" ] || { echo "canary ${CANARY_UID} is still there" >&2; exit 1; }
{ grep -vxF "$ENTRY" "$LEDGER" || true; } > "${LEDGER}.tmp" && mv "${LEDGER}.tmp" "$LEDGER"
```

Expected: `post-delete: 404`, confirming the canary is gone, and its uid is gone from `created.tsv`.

## Usage and cost

Usage dashboard query pattern (managed Grafana Cloud usage datasource, provisioned by the provider):

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
USAGE_DS_UID="grafanacloud-usage"   # the provider-provisioned usage datasource uid
curl -fsS --max-time 15 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  --get --data-urlencode 'query=sum(grafanacloud_org_metrics_instance_active_series)' \
  "${GRAFANA_URL}/api/datasources/proxy/uid/${USAGE_DS_UID}/api/v1/query" \
  | jq '.data.result'
```

Self-hosted: build the same view from your backend's own ingestion metrics (`prometheus_tsdb_head_series`, Loki's `loki_ingester_memory_streams`, Tempo's span-ingestion counters) through your existing datasources; no separate provisioning step.

Cost alert on ingestion growth. `INGEST_GROWTH_THRESHOLD` below is a ratio, week over week; it is an example starting point, tune to your billing model:

```bash
INGEST_GROWTH_THRESHOLD="1.5"   # example, tune to your billing model
```

Follow the alert-rule create pattern above with an expression comparing this week's active-series count to last week's, carrying `severity: warning` and `service: monitoring`.

Retention: on managed plans, retention lives in the provider's plan settings, not in a Grafana API call; record the decision here (`RETENTION_DAYS="30"` is an example, tune to your compliance and cost targets), apply it in the provider's console, and re-read the setting through the provider's API to verify. Self-hosted backend retention (Loki, Tempo, Mimir, VictoriaMetrics) changes through `setup-lgtm`.
