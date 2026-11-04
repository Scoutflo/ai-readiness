# Description-only team change

This recipe is limited to the observed `GET` and `PUT /api-public/v1/team/{team}` contract. The PUT payload is `{name, description}`; the name is preserved. It does not rename a team, change membership, modify paging or remove anything. A 429 pauses before further requests; reconcile with a fresh read only after the provider retry interval, without replaying the write. The observed elevated-key update and restoration preserved all known metadata except the provider's version counter. A read-only write refusal was 401, not necessarily 403. Do not perform that refusal test during a normal setup run.

## Inputs and operation modes

Each invocation is a fresh shell. Use the config and target described in the skill's Doctor gate. Set these non-secret inputs before running the block:

| Variable | Meaning |
| --- | --- |
| `SOC_MODE` | `plan`, `apply`, or `restore`; defaults to `plan` |
| `SOC_RUN_ID` | A unique local action label using letters, digits, underscores or hyphens; reuse it only to apply/restore that same plan |
| `SOC_NEW_DESCRIPTION` | Must be explicitly set in plan mode; exact plain-text description to propose, at most 1024 characters. An explicitly empty value proposes clearing the description; an unset variable stops. |
| `SOC_APPROVED_PLAN` | For apply/restore, `apply:<checksum>` or `restore:<checksum>` using the printed plan checksum, supplied only after the conversation approves that exact action |

The action prefix and checksum bind a supplied approval to the action and plan bytes; it is not permission by itself. Show the actual plan to the user, then set `SOC_APPROVED_PLAN` only after approval. Restore is separately announced and confirmed. Do not pre-set an approval while generating the plan. Keep the object stable during the attended change; the API has no proven conditional update, so a read/write race remains possible.

The local run folder is created once with mode 0700 under the resolved target. It contains validated team metadata, action markers and a private SHA-256 credential fingerprint, never credential values. The fingerprint binds this plan to the exact credential pair and API ID; rotation or replacement requires a new plan. It is not an organization identifier and is never printed. Result paths must be absent, including symlinks, and every output is created exclusively with Python’s standard-library `os.open(O_CREAT|O_EXCL)`; shell noclobber alone is insufficient for device symlinks on some hosts. Before-state text must be ordinary metadata that the operator permits in a local backup. The recipe conservatively rejects URLs, contact addresses, likely credential text and long opaque words. It rejects any known credential value, any unknown team field, missing/null description, nonstandard link, or default team. Each link must equal its exact canonical relative path or that same path under the fixed management HTTPS origin. The original permitted form is preserved in the backup; links are never followed. These are fail-closed limits of this recipe; do not weaken them to make a different object pass.

## Prepare, apply or restore

In plan mode this block performs reads only and emits the safe before/after description plus a checksum. Apply mode re-reads both credential tiers, compares all known fields to the saved baseline including `version`, performs one PUT and immediately GETs. Restore mode requires the current full state to match the saved post-write state, then performs the inverse description-only PUT and immediately GETs. Provider version changes are permitted only after our own write.

<!-- oncall-team-description:start -->
```bash
set -eu
set +x
umask 077
SOC_MODE="${SOC_MODE:-plan}"          # plan | apply | restore
SOC_RUN_ID="${SOC_RUN_ID:-}"          # unique local action label
case "$SOC_MODE" in plan|apply|restore) ;; *) echo 'Invalid mode'; exit 1;; esac
if [ "$SOC_MODE" = plan ] && [ "${SOC_NEW_DESCRIPTION+x}" != x ]; then
  echo 'Set SOC_NEW_DESCRIPTION explicitly; an empty value proposes clearing it'
  exit 1
fi
SOC_NEW_DESCRIPTION="${SOC_NEW_DESCRIPTION:-}" # proposed non-secret text, plan mode
SOC_APPROVED_PLAN="${SOC_APPROVED_PLAN:-}"     # action:checksum, after exact approval
case "$SOC_RUN_ID" in ''|*[!A-Za-z0-9_-]*) echo 'Set a safe unique SOC_RUN_ID'; exit 1;; esac
CFG="${SCOUTFLO_CONFIG:-}"
[ -n "$CFG" ] || for candidate in './.scoutflo/toolkit.yaml' "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null 2>&1 || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$candidate" ] && { CFG="$candidate"; break; }; done
[ -n "$CFG" ] && [ -f "$CFG" ] || { echo 'Missing config'; exit 1; }
for bin in curl jq shasum python3; do command -v "$bin" >/dev/null 2>&1 || { echo "Missing $bin"; exit 1; }; done
SOC_CURL_VERSION=$(curl --version | awk 'NR==1 {print $2}')
printf '%s\n' "$SOC_CURL_VERSION" | awk -F. '$1>8 || ($1==8 && $2>=4) {ok=1} END {exit !ok}' || { echo 'curl 8.4 or newer is required for bounded reads'; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
SOC_KIND=$(sh "$TT" "$CFG" splunk_oncall kind); SOC_N=$(sh "$TT" "$CFG" splunk_oncall count)
[ "$SOC_N" -ge 1 ] || { echo 'No splunk_oncall target'; exit 1; }
SOC_IDX=0
if [ "$SOC_KIND" = seq ]; then
  SOC_LABELS=$(sh "$TT" "$CFG" splunk_oncall labels)
  SOC_LI=0
  while [ "$SOC_LI" -lt "$SOC_N" ]; do
    case "$(sh "$TT" "$CFG" splunk_oncall get "$SOC_LI" label)" in ''|*[!A-Za-z0-9_-]*) echo 'List targets require explicit safe labels'; exit 1;; esac
    SOC_LI=$((SOC_LI+1))
  done
  printf '%s\n' "$SOC_LABELS" | awk '$0 !~ /^[A-Za-z0-9_-]+$/ || seen[$0]++ {bad=1} END {exit bad}' || { echo 'Invalid or duplicate target labels'; exit 1; }
  [ -n "${SCOUTFLO_TARGET:-}" ] || { echo 'Select SCOUTFLO_TARGET for setup'; exit 1; }
  SOC_MATCHES=0; SOC_I=0
  while [ "$SOC_I" -lt "$SOC_N" ]; do
    if [ "$(sh "$TT" "$CFG" splunk_oncall label "$SOC_I")" = "$SCOUTFLO_TARGET" ]; then SOC_IDX=$SOC_I; SOC_MATCHES=$((SOC_MATCHES+1)); fi
    SOC_I=$((SOC_I+1))
  done
  [ "$SOC_MATCHES" -eq 1 ] || { echo 'SCOUTFLO_TARGET must match exactly one splunk_oncall label'; exit 1; }
fi
SOC_LABEL=$(sh "$TT" "$CFG" splunk_oncall label "$SOC_IDX")
case "$SOC_LABEL" in ''|*[!A-Za-z0-9_-]*) echo 'Unsafe target label'; exit 1;; esac
SOC_SEG=splunk_oncall; [ "$SOC_KIND" != seq ] || SOC_SEG="splunk_oncall/$SOC_LABEL"
SOC_TEAM=$(sh "$TT" "$CFG" splunk_oncall get "$SOC_IDX" team_slug)
case "$SOC_TEAM" in ''|*[!A-Za-z0-9_-]*) echo 'Invalid team_slug'; exit 1;; esac
SOC_ID_VAR=$(sh "$TT" "$CFG" splunk_oncall get "$SOC_IDX" api_id_env)
SOC_READ_VAR=$(sh "$TT" "$CFG" splunk_oncall get "$SOC_IDX" api_key_env)
SOC_WRITE_VAR=$(sh "$TT" "$CFG" splunk_oncall get "$SOC_IDX" setup_api_key_env)
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"
[ -n "$SCOUTFLO_ENV" ] || { if [ -f './.scoutflo/env' ]; then SCOUTFLO_ENV='./.scoutflo/env'; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
soc_secret() {
  case "$1" in ''|[0-9]*|*[!A-Za-z0-9_]*) return 1;; esac
  sh -c 'set +x; set -a; if [ -f "$1" ]; then . "$1" >/dev/null 2>&1 || exit 1; fi; printenv "$2"' _ "$SCOUTFLO_ENV" "$1" 2>/dev/null
}
SOC_ID=$(soc_secret "$SOC_ID_VAR") || { echo 'Missing management API ID'; exit 1; }
SOC_READ=$(soc_secret "$SOC_READ_VAR") || { echo 'Missing read-only key'; exit 1; }
SOC_WRITE=$(soc_secret "$SOC_WRITE_VAR") || { echo 'Missing separate setup key'; exit 1; }
[ -n "$SOC_ID" ] && [ -n "$SOC_READ" ] && [ -n "$SOC_WRITE" ] && [ "$SOC_READ" != "$SOC_WRITE" ] || { echo 'Require separate nonempty credentials'; exit 1; }
for SOC_VALUE in "$SOC_ID" "$SOC_READ" "$SOC_WRITE"; do
  printf '%s' "$SOC_VALUE" | jq -Rse 'test("[\\r\\n]")|not' >/dev/null 2>&1 || { echo 'Invalid credential format'; exit 1; }
done
# NUL-separated components cannot collide by concatenation; header values exclude NUL.
# The digest stays in the protected plan. Do not print it or use it as tenant proof.
SOC_HASH_LINE=$(printf '%s\0' "$SOC_ID" "$SOC_READ" "$SOC_WRITE" | shasum -a 256) || { echo 'Cannot bind credentials; hash failed'; exit 1; }
SOC_CREDENTIAL_FINGERPRINT=${SOC_HASH_LINE%% *}
printf '%s\n' "$SOC_CREDENTIAL_FINGERPRINT" | grep -Eq '^[a-f0-9]{64}$' || { echo 'Invalid credential fingerprint'; exit 1; }
SOC_URL="https://api.victorops.com/api-public/v1/team/$SOC_TEAM"
soc_request() { # method, selected key, optional exact JSON payload; no retry or body logging
  SOC_METHOD=$1; SOC_KEY=$2; SOC_PAYLOAD=${3:-}
  sleep 1
  SOC_REPLY=$( {
    printf 'header = %s\n' "$(printf 'X-VO-Api-Id: %s' "$SOC_ID" | jq -Rs .)"
    printf 'header = %s\n' "$(printf 'X-VO-Api-Key: %s' "$SOC_KEY" | jq -Rs .)"
    if [ "$SOC_METHOD" = PUT ]; then printf 'header = "Content-Type: application/json"\n'; printf 'data = %s\n' "$(printf '%s' "$SOC_PAYLOAD" | jq -Rs .)"; fi
  } | curl -q -sS --config - --request "$SOC_METHOD" --proto '=https' --max-redirs 0 --connect-timeout 5 --max-time 20 --max-filesize 1048576 -w '\n%{http_code}' "$SOC_URL" 2>/dev/null) || { echo 'Transport incomplete or unavailable; response not confirmed' >&2; return 70; }
  SOC_STATUS=$(printf '%s\n' "$SOC_REPLY" | tail -n 1)
  case "$SOC_STATUS" in
    200) ;;
    401) echo 'Access refused (HTTP 401); no role inferred' >&2; return 41;;
    403) echo 'Access refused (HTTP 403); no role inferred' >&2; return 43;;
    429) echo 'Throttled (HTTP 429); no automatic retry; honor Retry-After before later reads' >&2; return 29;;
    3[0-9][0-9]) echo 'Redirect refused; credentials were not forwarded' >&2; return 30;;
    5[0-9][0-9]) echo "Provider unavailable (HTTP $SOC_STATUS)" >&2; return 50;;
    *) echo "Unexpected provider status (HTTP $SOC_STATUS)" >&2; return 60;;
  esac
  SOC_BODY=$(printf '%s\n' "$SOC_REPLY" | sed '$d')
  if [ "$SOC_METHOD" = GET ]; then
    SOC_STREAM=$(printf '%s' "$SOC_BODY" | jq --stream -c . 2>/dev/null) || { echo 'Invalid team JSON stream' >&2; return 65; }
    printf '%s' "$SOC_STREAM" | jq -e -s --arg team "$SOC_TEAM" '[.[] | select(length==2)] as $entries | ($entries | all((.[0]|length)==1)) and ([$entries[][0][0]] | length==(unique|length)) and ([$entries[] | select(.[0]==["slug"])] | length==1 and .[0][1]==$team)' >/dev/null 2>&1 || { echo 'Ambiguous or unsupported team JSON' >&2; return 65; }
  fi
  printf '%s' "$SOC_BODY" | jq -e -s 'length == 1 and (.[0]|type == "object")' >/dev/null 2>&1 || { echo 'Response is not one complete JSON object' >&2; return 65; }
  printf '%s' "$SOC_BODY"
}
soc_team() { # strict permitted fields; never save a raw response or arbitrary link
  jq -ce --arg team "$SOC_TEAM" --arg url "$SOC_URL" --arg path "/api-public/v1/team/$SOC_TEAM" '
    def canonical_link($suffix): . == ($path+$suffix) or . == ($url+$suffix);
    select(keys == (["_adminsUrl","_membersUrl","_policiesUrl","_selfUrl","description","isDefaultTeam","memberCount","name","slug","version"]|sort)) |
    select(.slug == $team and .isDefaultTeam == false and (.name|type == "string" and length > 0) and (.description|type == "string") and (.memberCount|type == "number" and . >= 0 and . == floor) and (.version|type == "number" and . >= 0)) |
    select((._selfUrl | canonical_link("")) and (._membersUrl | canonical_link("/members")) and (._policiesUrl | canonical_link("/policies")) and (._adminsUrl | canonical_link("/admins"))) |
    select([.name,.description] | all(type == "string" and length <= 1024 and test("^[A-Za-z0-9 .,;:()/_-]*$") and (test("://|@|[A-Za-z0-9_-]{24,}|token|password|secret|api.?key";"i")|not)))'
}
soc_no_credential() { # stdin stays in memory; a negative result emits no bytes
  SOC_SAFE=$(cat)
  for SOC_VALUE in "$SOC_ID" "$SOC_READ" "$SOC_WRITE"; do
    case "$SOC_SAFE" in *"$SOC_VALUE"*) return 1;; esac
  done
  printf '%s' "$SOC_SAFE"
}
soc_create() { # exclusive, no-follow creation; metadata arrives only on stdin
  python3 -c 'import os, shutil, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "wb") as out:
    shutil.copyfileobj(sys.stdin.buffer, out)' "$1" 2>/dev/null
}
SOC_CURRENT=$(soc_request GET "$SOC_READ") || { echo 'Read-only team read failed'; exit 1; }
SOC_CURRENT=$(printf '%s' "$SOC_CURRENT" | soc_team | soc_no_credential) || { echo 'Team shape or backup content unsupported'; exit 1; }
[ -n "$SOC_CURRENT" ] || { echo 'Team shape or backup content unsupported'; exit 1; }
SOC_SETUP_CURRENT=$(soc_request GET "$SOC_WRITE") || { echo 'Setup credential team read failed'; exit 1; }
SOC_SETUP_CURRENT=$(printf '%s' "$SOC_SETUP_CURRENT" | soc_team | soc_no_credential) || { echo 'Setup team shape unsupported'; exit 1; }
[ -n "$SOC_SETUP_CURRENT" ] && [ "$(printf '%s' "$SOC_CURRENT" | jq -Sc .)" = "$(printf '%s' "$SOC_SETUP_CURRENT" | jq -Sc .)" ] || { echo 'Credential targets or snapshots disagree'; exit 1; }
SOC_PARENT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/$SOC_SEG"
SOC_OUT="$SOC_PARENT/setup-$SOC_RUN_ID"
SOC_PLAN="$SOC_OUT/plan.json"
if [ "$SOC_MODE" = plan ]; then
  [ -z "$SOC_APPROVED_PLAN" ] || { echo 'Do not preapprove a plan before review'; exit 1; }
  SOC_AFTER=$(printf '%s' "$SOC_CURRENT" | jq -c --arg description "$SOC_NEW_DESCRIPTION" '.description=$description')
  SOC_AFTER=$(printf '%s' "$SOC_AFTER" | soc_team | soc_no_credential) || { echo 'Proposed description is unsafe for this recipe'; exit 1; }
  [ -n "$SOC_AFTER" ] || { echo 'Proposed description is unsafe for this recipe'; exit 1; }
  [ "$(printf '%s' "$SOC_CURRENT" | jq -Sc .)" != "$(printf '%s' "$SOC_AFTER" | jq -Sc .)" ] || { echo 'Description already matches; no action needed'; exit 0; }
  [ ! -e "$SOC_OUT" ] && [ ! -L "$SOC_OUT" ] || { echo 'Run directory exists; inspect its outcome instead of replaying'; exit 1; }
  mkdir -p "$SOC_PARENT"; mkdir "$SOC_OUT"
  jq -n --arg fingerprint "$SOC_CREDENTIAL_FINGERPRINT" --arg target "$SOC_SEG" --arg team "$SOC_TEAM" --arg id_env "$SOC_ID_VAR" --arg read_env "$SOC_READ_VAR" --arg write_env "$SOC_WRITE_VAR" --argjson before "$SOC_CURRENT" --argjson after "$SOC_AFTER" '{schema:"scoutflo-oncall-change/v1",target:$target,team:$team,api_id_env:$id_env,api_key_env:$read_env,setup_api_key_env:$write_env,credential_fingerprint:$fingerprint,before:$before,after:$after,created_at:(now|floor)}' | soc_create "$SOC_PLAN" || exit 1
  jq '{target,team,before:{name:.before.name,description:.before.description},after:{name:.after.name,description:.after.description}}' "$SOC_PLAN"
  printf 'Plan checksum: '; cksum < "$SOC_PLAN" | awk '{print $1 ":" $2}'
  echo 'Read-only plan prepared. Review and approve the exact action before apply.'
  exit 0
fi
[ -d "$SOC_OUT" ] && [ ! -L "$SOC_OUT" ] && [ -f "$SOC_PLAN" ] && [ ! -L "$SOC_PLAN" ] || { echo 'Missing or unsafe plan'; exit 1; }
SOC_SUM=$(cksum < "$SOC_PLAN" | awk '{print $1 ":" $2}')
[ -n "$SOC_APPROVED_PLAN" ] && [ "$SOC_APPROVED_PLAN" = "$SOC_MODE:$SOC_SUM" ] || { echo 'Exact plan/action approval required'; exit 1; }
jq -e --arg fingerprint "$SOC_CREDENTIAL_FINGERPRINT" --arg target "$SOC_SEG" --arg team "$SOC_TEAM" --arg id "$SOC_ID_VAR" --arg read "$SOC_READ_VAR" --arg write "$SOC_WRITE_VAR" '.schema=="scoutflo-oncall-change/v1" and .target==$target and .team==$team and .api_id_env==$id and .api_key_env==$read and .setup_api_key_env==$write and .credential_fingerprint==$fingerprint' "$SOC_PLAN" >/dev/null 2>&1 || { echo 'Plan target or credentials changed; prepare and approve a fresh plan'; exit 1; }
SOC_EXPECTED=$(jq -c '.before' "$SOC_PLAN")
SOC_DESIRED=$(jq -c '.after' "$SOC_PLAN")
if [ "$SOC_MODE" = restore ]; then
  [ -f "$SOC_OUT/applied.json" ] && [ ! -L "$SOC_OUT/applied.json" ] || { echo 'No verified applied snapshot to restore'; exit 1; }
  SOC_EXPECTED=$(cat "$SOC_OUT/applied.json"); SOC_DESIRED=$(jq -c '.before' "$SOC_PLAN")
fi
SOC_EXPECTED=$(printf '%s' "$SOC_EXPECTED" | soc_team | soc_no_credential) || exit 1
SOC_DESIRED=$(printf '%s' "$SOC_DESIRED" | soc_team | soc_no_credential) || exit 1
[ -n "$SOC_EXPECTED" ] && [ -n "$SOC_DESIRED" ] || { echo 'Invalid saved plan state'; exit 1; }
[ "$(printf '%s' "$SOC_EXPECTED" | jq -Sc 'del(.description,.version)')" = "$(printf '%s' "$SOC_DESIRED" | jq -Sc 'del(.description,.version)')" ] || { echo 'Plan attempts more than a description change'; exit 1; }
[ "$(printf '%s' "$SOC_CURRENT" | jq -Sc .)" = "$(printf '%s' "$SOC_EXPECTED" | jq -Sc .)" ] || { echo 'Drift since approved snapshot; re-plan, do not overwrite'; exit 1; }
# Refuse existing regular files, directories, devices and dangling/live symlinks
# before the mutation. O_CREAT|O_EXCL protects each later write against races.
for SOC_FILE in "$SOC_OUT/$SOC_MODE.result.json"; do
  [ ! -e "$SOC_FILE" ] && [ ! -L "$SOC_FILE" ] || { echo 'Result path already exists or is unsafe; reconcile first'; exit 1; }
done
if [ "$SOC_MODE" = apply ]; then
  [ ! -e "$SOC_OUT/applied.json" ] && [ ! -L "$SOC_OUT/applied.json" ] || { echo 'Applied snapshot path already exists or is unsafe'; exit 1; }
fi
[ ! -e "$SOC_OUT/$SOC_MODE.started" ] && [ ! -L "$SOC_OUT/$SOC_MODE.started" ] || { echo 'An attempt already exists; reconcile before another mutation'; exit 1; }
printf 'request-started\n' | soc_create "$SOC_OUT/$SOC_MODE.started" || exit 1
SOC_PAYLOAD=$(printf '%s' "$SOC_DESIRED" | jq -c '{name,description}')
SOC_WRITE_RESPONSE=verified
if SOC_IGNORED=$(soc_request PUT "$SOC_WRITE" "$SOC_PAYLOAD"); then
  SOC_WRITE_RESPONSE=verified
else
  case "$?" in
    41) SOC_WRITE_RESPONSE=refused-401;;
    43) SOC_WRITE_RESPONSE=refused-403;;
    29) SOC_WRITE_RESPONSE=throttled-429;;
    30) SOC_WRITE_RESPONSE=redirect-refused;;
    50) SOC_WRITE_RESPONSE=server-error;;
    65) SOC_WRITE_RESPONSE=invalid-json;;
    *) SOC_WRITE_RESPONSE=unknown;;
  esac
fi
if [ "$SOC_WRITE_RESPONSE" = throttled-429 ]; then
  jq -n '{action:"paused",effect:"unknown",write_response:"throttled-429",next:"read after provider retry interval"}' | soc_create "$SOC_OUT/$SOC_MODE.result.json" || { echo 'Cannot safely save outcome; retain started marker and reconcile'; exit 1; }
  echo 'Stop after 429. Honor the provider retry interval before a separately resumed read; do not replay the write.'
  exit 1
fi
SOC_OBSERVED=$(soc_request GET "$SOC_READ") || { echo 'Write outcome unknown; keep journal and reconcile by read'; exit 1; }
SOC_OBSERVED=$(printf '%s' "$SOC_OBSERVED" | soc_team | soc_no_credential) || { echo 'Unexpected readback; no retry or automatic rollback'; exit 1; }
[ -n "$SOC_OBSERVED" ] && [ "$(printf '%s' "$SOC_OBSERVED" | jq -Sc 'del(.version)')" = "$(printf '%s' "$SOC_DESIRED" | jq -Sc 'del(.version)')" ] || { echo 'Readback differs; stop and reconcile'; exit 1; }
if [ "$SOC_MODE" = apply ]; then
  printf '%s\n' "$SOC_OBSERVED" | soc_create "$SOC_OUT/applied.json" || { echo 'Cannot safely save applied state; retain started marker and reconcile'; exit 1; }
fi
jq -n --arg mode "$SOC_MODE" --arg response "$SOC_WRITE_RESPONSE" '{action:$mode,effect:"verified-by-readback",write_response:$response,at:(now|floor)}' | soc_create "$SOC_OUT/$SOC_MODE.result.json" || { echo 'Cannot safely save outcome; retain started marker and reconcile'; exit 1; }
printf '%s effect verified; write response %s. Re-audit with the read-only key.\n' "$SOC_MODE" "$SOC_WRITE_RESPONSE"
unset SOC_ID SOC_READ SOC_WRITE SOC_KEY SOC_VALUE SOC_IGNORED SOC_CREDENTIAL_FINGERPRINT SOC_HASH_LINE
```
<!-- oncall-team-description:end -->

Expected: plan performs two GETs and no PUT. A valid approved apply performs two fresh GETs, one PUT and one immediate GET; restore does the same after verifying the applied snapshot. Output says `effect verified` only after comparing the fresh permitted state to the exact requested state, excluding only the version counter. A failed/unknown write response with a matching readback is recorded as an observed effect with an unknown response; it is never retried.

## Interruption and restoration

A `*.started` marker makes re-entry refuse another mutation. It intentionally survives failure. Inspect the selected team with the read-only key, compare to `plan.json` and any `applied.json`, and record the outcome before preparing a fresh plan. Do not delete the marker merely to make the recipe run again. If current state cannot be classified, retain the snapshot and stop; do not restore a stale backup over someone else's change.

Restore reads the current object and requires it to match the full post-write snapshot, including version. It restores the exact original name/description payload and verifies all permitted fields except version. It does not delete the team or undo unrelated work. The ordinary reference path has a request-start record and local backup, not an unattended scheduler: do not use this recipe for a change whose safety depends on a background timer running later.

The recipe's complete-field allowlist and fixed links are deliberate compatibility checks, not a statement that future provider versions cannot add fields. A new shape requires research and a reviewed preservation rule before this automation can change it.
