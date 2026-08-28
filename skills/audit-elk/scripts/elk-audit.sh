#!/usr/bin/env bash
# elk-audit.sh -- read-only Kibana Alerting evidence collector.
#
# Environment:
#   KIBANA_URL         Kibana base URL (toolkit.yaml: elk.kibana_url). Required.
#   KIBANA_API_KEY     Encoded Elasticsearch API key named by elk.token_env. Required.
#   OUT_DIR            Raw output directory. Defaults to
#                      ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/elk/<UTC date>/raw.
#   ELK_SPACES_FILE    Optional file containing the configured elk.spaces, one ID per line.
#   ELK_SPACES         Optional comma-separated or JSON-array form of elk.spaces when a file
#                      is inconvenient. ELK_SPACES_FILE takes precedence.
#   CURL_MAX_TIME      Per-request timeout in seconds. Default: 30.
#
# Every network call is a GET. The collector never enables, disables, mutes,
# snoozes, executes, or changes a Kibana object. Failed response bodies are
# retained with .http-<status>, .invalid-response, or .curl-failed suffixes.
# Complete aggregates have their normal name. Later-page failures create only a
# *.partial.json aggregate, which is object-level evidence and never a complete
# estate denominator.

set -eu

: "${KIBANA_URL:?KIBANA_URL is not set; resolve elk.kibana_url for the current target}"
: "${KIBANA_API_KEY:?KIBANA_API_KEY is not set; run /scoutflo:connect}"

command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

KIBANA_URL="${KIBANA_URL%/}"
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT_DIR="${OUT_DIR:-${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/elk/${RUN_DATE}/raw}"
CURL_MAX_TIME="${CURL_MAX_TIME:-30}"
PAGE_SIZE=100
MAX_PAGES=10000

mkdir -p "${OUT_DIR}"
ERRORS="${OUT_DIR}/errors.log"
REQUEST_STATUS="${OUT_DIR}/request-status.jsonl"
: > "${ERRORS}"
: > "${REQUEST_STATUS}"

note() { printf '%s\n' "$*"; }

# record_state <api-path> <artifact> <state> <http-status> <detail>
# The ledger is deliberately secret-free: no headers or response bodies.
record_state() {
  local path="$1" out="$2" state="$3" status="$4" detail="$5" artifact
  artifact="${out#"${OUT_DIR}/"}"
  jq -cn \
    --arg path "${path}" --arg artifact "${artifact}" \
    --arg state "${state}" --arg status "${status}" --arg detail "${detail}" \
    '{path:$path,artifact:$artifact,state:$state,
      http_status:(if $status == "" then null else $status end),detail:$detail}' \
    >> "${REQUEST_STATUS}"
}

json_is_empty() {
  jq -e 'if . == null then true
         elif type == "array" or type == "object" or type == "string" then length == 0
         else false end' "$1" >/dev/null 2>&1
}

json_has_shape() {
  local file="$1" expected="$2"
  case "${expected}" in
    object) jq -e 'type == "object"' "${file}" >/dev/null 2>&1 ;;
    array) jq -e 'type == "array"' "${file}" >/dev/null 2>&1 ;;
    kibana-status)
      jq -e 'type == "object" and ((.version.number | type) == "string") and (.version.number | length > 0)' \
        "${file}" >/dev/null 2>&1
      ;;
    alerting-health)
      jq -e 'type == "object" and has("is_sufficiently_secure")
             and has("has_permanent_encryption_key")' "${file}" >/dev/null 2>&1
      ;;
    rules-page)
      jq -e 'type == "object" and ((.data | type) == "array")
             and ((.total | type) == "number")
             and all(.data[]; ((.id | type) == "string"))' "${file}" >/dev/null 2>&1
      ;;
    spaces-page)
      jq -e '(type == "array" and all(.[]; ((.id | type) == "string")))
             or (type == "object"
                 and (((.spaces // .data) | type) == "array")
                 and ((.total == null) or ((.total | type) == "number"))
                 and all((.spaces // .data)[]; ((.id | type) == "string")))' \
        "${file}" >/dev/null 2>&1
      ;;
    connectors-page)
      jq -e '(type == "array" and all(.[]; ((.id | type) == "string")))
             or (type == "object"
                 and (((.connectors // .data) | type) == "array")
                 and ((.total == null) or ((.total | type) == "number"))
                 and all((.connectors // .data)[]; ((.id | type) == "string")))' \
        "${file}" >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

# fetch <api-path> <outfile> <expected-json-shape>
# Sets FETCH_STATE and FETCH_STATUS. A failure never leaves a normal-name JSON
# artifact that downstream jq could mistake for a successful empty response.
fetch() {
  local path="$1" out="$2" expected="$3" status rc state
  FETCH_STATE="http-error"
  FETCH_STATUS=""
  rm -f "${out}" "${out}.curl-failed" "${out}.invalid-response" "${out}".http-*
  status="$(curl -sS --max-time "${CURL_MAX_TIME}" \
    -H "Authorization: ApiKey ${KIBANA_API_KEY}" \
    -o "${out}" -w '%{http_code}' "${KIBANA_URL}${path}" 2>>"${ERRORS}")" || {
      rc=$?
      FETCH_STATE="transport-error"
      FETCH_STATUS="${status:-000}"
      echo "TRANSPORT-ERROR ${path} (curl exit ${rc})" >> "${ERRORS}"
      mv "${out}" "${out}.curl-failed" 2>/dev/null || true
      record_state "${path}" "${out}" "${FETCH_STATE}" "${FETCH_STATUS}" "curl exit ${rc}"
      return 1
    }
  FETCH_STATUS="${status}"
  case "${status}" in
    2*)
      if ! json_has_shape "${out}" "${expected}"; then
        FETCH_STATE="invalid-response"
        echo "INVALID-RESPONSE ${path} (HTTP ${status}; expected ${expected} JSON)" >> "${ERRORS}"
        mv "${out}" "${out}.invalid-response" 2>/dev/null || true
        record_state "${path}" "${out}" "${FETCH_STATE}" "${status}" "expected ${expected} JSON"
        return 1
      fi
      if json_is_empty "${out}"; then FETCH_STATE="success-empty"; else FETCH_STATE="success-nonempty"; fi
      record_state "${path}" "${out}" "${FETCH_STATE}" "${status}" "complete response"
      return 0
      ;;
    401) state="unauthenticated" ;;
    403) state="forbidden" ;;
    404|405|501) state="unsupported" ;;
    *) state="http-error" ;;
  esac
  FETCH_STATE="${state}"
  echo "HTTP ${status} ${path} (${state})" >> "${ERRORS}"
  mv "${out}" "${out}.http-${status}" 2>/dev/null || true
  record_state "${path}" "${out}" "${state}" "${status}" "request did not return usable evidence"
  return 1
}

sanitize_page() {
  local kind="$1" input="$2" output="$3"
  case "${kind}" in
    spaces)
      jq 'if type == "array" then . else (.spaces // .data) end
          | map({id,name,disabled:(.disabled // false)})' "${input}" > "${output}"
      ;;
    connectors)
      jq 'if type == "array" then . else (.connectors // .data) end
          | map({id,name,connector_type_id,is_missing_secrets,is_deprecated,
                 referenced_by_count:(.referenced_by_count // 0)})' \
        "${input}" > "${output}"
      ;;
    rules)
      jq '[.data[] | {id,name,rule_type_id,enabled,mute_all,muted_alert_ids,
          snooze_schedule,execution_status:(.execution_status.status // null),
          last_execution_date:(.execution_status.last_execution_date // null),
          schedule_interval:(.schedule.interval // null),
          last_run_outcome:(.last_run.outcome // null),
          last_run_warning:(.last_run.warning // null),
          alerts_count:(.last_run.alerts_count // null),flapping,
          alert_delay:(.alert_delay // null),
          actions:[.actions[]? | {
            connector_type_id:(.connector_type_id // .params.connector_type_id // null),
            id:.id,group,notify_when:(.frequency.notify_when // null),
            throttle:(.frequency.throttle // null),summary:(.frequency.summary // null)}]}]' \
        "${input}" > "${output}"
      ;;
  esac
}

write_aggregate() {
  local kind="$1" merged="$2" out="$3"
  case "${kind}" in
    rules) jq '{total:length,rules:.}' "${merged}" > "${out}" ;;
    *) cp "${merged}" "${out}" ;;
  esac
}

write_partial() {
  local kind="$1" merged="$2" out="$3" expected="$4"
  jq --arg kind "${kind}" --arg expected "${expected}" \
    '{state:"partial",collected:length,
      expected_total:(if $expected == "" then null else ($expected | tonumber) end),
      ($kind):.}' "${merged}" > "${out}"
}

# collect_paginated <kind> <space-prefix> <complete-file> <partial-file> <pages-dir>
# Sets PAGED_STATE, PAGED_COUNT, and PAGED_EXPECTED. Supported response shapes:
# rules use {data,total}; spaces/connectors accept either their paginated object
# envelope or the legacy unpaginated array returned by older Kibana versions.
collect_paginated() {
  local kind="$1" prefix="$2" complete="$3" partial="$4" pages="$5"
  local page=1 pages_ok=0 accumulated=0 expected_total="" failure="" complete_flag=0 legacy_used=0
  local path legacy_path legacy_pf pf safe count page_total merged unique_count raw_shape
  PAGED_STATE="unavailable"
  PAGED_COUNT=0
  PAGED_EXPECTED=""
  rm -rf "${pages}"
  mkdir -p "${pages}"
  rm -f "${complete}" "${partial}"

  while [ "${page}" -le "${MAX_PAGES}" ]; do
    case "${kind}" in
      spaces) path="/api/spaces/space?per_page=${PAGE_SIZE}&page=${page}" ;;
      connectors) path="${prefix}/api/actions/connectors?per_page=${PAGE_SIZE}&page=${page}" ;;
      rules) path="${prefix}/api/alerting/rules/_find?per_page=${PAGE_SIZE}&page=${page}" ;;
    esac
    pf="${pages}/page-${page}.json"
    if ! fetch "${path}" "${pf}" "${kind}-page"; then
      # Older Kibana spaces/connectors routes return one unpaginated array and
      # may reject page/per_page as unknown query keys. Retry that documented
      # legacy shape once on a first-page HTTP 400; the failed body remains.
      if [ "${page}" -eq 1 ] && [ "${FETCH_STATUS}" = "400" ] && [ "${kind}" != "rules" ]; then
        case "${kind}" in
          spaces) legacy_path="/api/spaces/space" ;;
          connectors) legacy_path="${prefix}/api/actions/connectors" ;;
        esac
        legacy_pf="${pages}/legacy.json"
        if fetch "${legacy_path}" "${legacy_pf}" "${kind}-page"; then
          raw_shape="$(jq -r 'type' "${legacy_pf}")"
          page_total="$(jq -r 'if type == "object" and ((.total | type) == "number") then .total else empty end' "${legacy_pf}")"
          safe="${legacy_pf}.safe"
          sanitize_page "${kind}" "${legacy_pf}" "${safe}"
          mv "${safe}" "${legacy_pf}"
          cp "${legacy_pf}" "${pf}"
          legacy_used=1
        else
          failure="${FETCH_STATE}"
          PAGED_STATE="${FETCH_STATE}"
          break
        fi
      else
        failure="${FETCH_STATE}"
        if [ "${pages_ok}" -eq 0 ]; then PAGED_STATE="${FETCH_STATE}"; else PAGED_STATE="partial"; fi
        break
      fi
    fi

    if [ "${legacy_used}" -eq 0 ]; then
      raw_shape="$(jq -r 'type' "${pf}")"
      page_total="$(jq -r 'if type == "object" and ((.total | type) == "number") then .total else empty end' "${pf}")"
      safe="${pf}.safe"
      sanitize_page "${kind}" "${pf}" "${safe}"
      mv "${safe}" "${pf}"
    fi
    count="$(jq 'length' "${pf}")"

    if [ -n "${page_total}" ]; then
      if [ -z "${expected_total}" ]; then
        expected_total="${page_total}"
      elif [ "${expected_total}" -ne "${page_total}" ]; then
        failure="total changed from ${expected_total} to ${page_total} on page ${page}"
        PAGED_STATE="partial"
        pages_ok=$((pages_ok + 1))
        accumulated=$((accumulated + count))
        break
      fi
    fi

    if [ "${page}" -gt 1 ] && cmp -s "${pages}/page-1.json" "${pf}"; then
      failure="page ${page} repeated page 1; pagination made no progress"
      PAGED_STATE="partial"
      pages_ok=$((pages_ok + 1))
      accumulated=$((accumulated + count))
      break
    fi

    pages_ok=$((pages_ok + 1))
    accumulated=$((accumulated + count))
    if [ "${legacy_used}" -eq 1 ]; then
      # The legacy array endpoint is unpaginated by contract, so its one array
      # is complete even when its length is exactly PAGE_SIZE.
      if [ "${raw_shape}" = "array" ] \
        || { [ -n "${expected_total}" ] && [ "${accumulated}" -eq "${expected_total}" ]; }; then
        complete_flag=1
      else
        failure="legacy response did not prove a complete collection"
        PAGED_STATE="partial"
      fi
      break
    fi
    if [ -n "${expected_total}" ] && [ "${accumulated}" -ge "${expected_total}" ]; then
      complete_flag=1
      break
    fi
    if [ "${count}" -lt "${PAGE_SIZE}" ]; then
      if [ -n "${expected_total}" ] && [ "${accumulated}" -lt "${expected_total}" ]; then
        failure="short page ${page}: collected ${accumulated} of declared ${expected_total}"
        PAGED_STATE="partial"
      else
        complete_flag=1
      fi
      break
    fi
    # A legacy array endpoint can ignore per_page and return its entire list.
    # More than PAGE_SIZE objects proves that happened; retain the whole response.
    if [ "${raw_shape}" = "array" ] && [ "${count}" -gt "${PAGE_SIZE}" ]; then
      complete_flag=1
      break
    fi
    page=$((page + 1))
  done

  if [ "${page}" -gt "${MAX_PAGES}" ]; then
    failure="pagination exceeded safety limit ${MAX_PAGES}"
    PAGED_STATE="partial"
  fi

  if [ "${pages_ok}" -gt 0 ]; then
    merged="${pages}/aggregate.tmp"
    jq -s 'add | unique_by(.id)' "${pages}"/page-*.json > "${merged}"
    unique_count="$(jq 'length' "${merged}")"
    if [ "${unique_count}" -ne "${accumulated}" ]; then
      failure="pagination returned duplicate object IDs (${accumulated} rows, ${unique_count} unique)"
      complete_flag=0
      PAGED_STATE="partial"
    fi
    if [ "${complete_flag}" -eq 1 ] && [ -n "${expected_total}" ] \
       && [ "${unique_count}" -ne "${expected_total}" ]; then
      failure="collected ${unique_count} unique objects but API declared ${expected_total}"
      complete_flag=0
      PAGED_STATE="partial"
    fi

    if [ "${complete_flag}" -eq 1 ]; then
      write_aggregate "${kind}" "${merged}" "${complete}"
      PAGED_COUNT="${unique_count}"
      if [ "${unique_count}" -eq 0 ]; then PAGED_STATE="success-empty"; else PAGED_STATE="success-nonempty"; fi
      record_state "${path%%\?*} (paginated aggregate)" "${complete}" "${PAGED_STATE}" "" \
        "${pages_ok} page(s) read; ${unique_count} unique object(s)"
      [ "${legacy_used}" -eq 1 ] || rm -rf "${pages}"
    else
      write_partial "${kind}" "${merged}" "${partial}" "${expected_total}"
      PAGED_COUNT="${unique_count}"
      PAGED_STATE="partial"
      record_state "${path%%\?*} (paginated aggregate)" "${partial}" "partial" "" \
        "${pages_ok} page(s) read; ${unique_count} unique object(s); ${failure:-incomplete pagination}"
      rm -f "${merged}"
      echo "PARTIAL ${kind}: ${failure:-incomplete pagination}" >> "${ERRORS}"
    fi
  fi
  PAGED_EXPECTED="${expected_total}"
  [ "${PAGED_STATE}" = "success-empty" ] || [ "${PAGED_STATE}" = "success-nonempty" ]
}

normalize_configured_spaces() {
  local destination="$1" candidate
  candidate="${destination}.tmp"
  : > "${candidate}"
  if [ -n "${ELK_SPACES_FILE:-}" ] && [ -s "${ELK_SPACES_FILE}" ]; then
    awk 'NF {print $1}' "${ELK_SPACES_FILE}" > "${candidate}"
  elif [ -n "${ELK_SPACES:-}" ]; then
    if printf '%s' "${ELK_SPACES}" | jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1; then
      printf '%s' "${ELK_SPACES}" | jq -r '.[]' > "${candidate}"
    else
      printf '%s\n' "${ELK_SPACES}" | tr ',' '\n' \
        | sed -e 's/[][]//g' -e 's/["'"'"']//g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        | awk 'NF' > "${candidate}"
    fi
  fi
  sort -u "${candidate}" > "${destination}"
  rm -f "${candidate}"
}

note "== elk-audit.sh (read-only) -> ${OUT_DIR}"

# Identity is the only fail-closed request. Later permission-dependent failures
# remain evidence and the collector continues across other readable surfaces.
if ! fetch "/api/status" "${OUT_DIR}/kibana-status.json" kibana-status; then
  echo "Kibana identity could not be verified; inspect request-status.jsonl and errors.log" >&2
  exit 1
fi
jq -r '.version.number' "${OUT_DIR}/kibana-status.json" > "${OUT_DIR}/kibana-version.txt"
note "Kibana identity: version $(cat "${OUT_DIR}/kibana-version.txt")"

rm -f "${OUT_DIR}/spaces.json" "${OUT_DIR}/spaces.partial.json" \
      "${OUT_DIR}/spaces-discovered.txt" "${OUT_DIR}/spaces-discovered.partial.txt" \
      "${OUT_DIR}/spaces.txt" "${OUT_DIR}/spaces-skipped.txt"
if collect_paginated spaces "" "${OUT_DIR}/spaces.json" "${OUT_DIR}/spaces.partial.json" \
   "${OUT_DIR}/.spaces-pages"; then
  SPACES_STATE="${PAGED_STATE}"
  jq -r '.[].id' "${OUT_DIR}/spaces.json" | sort -u > "${OUT_DIR}/spaces-discovered.txt"
else
  SPACES_STATE="${PAGED_STATE}"
  if [ -f "${OUT_DIR}/spaces.partial.json" ]; then
    jq -r '.spaces[].id' "${OUT_DIR}/spaces.partial.json" | sort -u \
      > "${OUT_DIR}/spaces-discovered.partial.txt"
  fi
fi

normalize_configured_spaces "${OUT_DIR}/spaces-configured.txt"
: > "${OUT_DIR}/spaces.txt"
: > "${OUT_DIR}/spaces-skipped.txt"
if [ -f "${OUT_DIR}/spaces-discovered.txt" ]; then
  if [ -s "${OUT_DIR}/spaces-configured.txt" ]; then
    while IFS= read -r space; do
      [ -n "${space}" ] || continue
      if grep -qxF "${space}" "${OUT_DIR}/spaces-discovered.txt"; then
        printf '%s\n' "${space}" >> "${OUT_DIR}/spaces.txt"
      else
        printf '%s\tconfigured-but-not-visible-to-this-key\n' "${space}" >> "${OUT_DIR}/spaces-skipped.txt"
      fi
    done < "${OUT_DIR}/spaces-configured.txt"
    SCOPE_STATE="configured-intersection"
  else
    cp "${OUT_DIR}/spaces-discovered.txt" "${OUT_DIR}/spaces.txt"
    SCOPE_STATE="all-discovered"
  fi
else
  if [ -s "${OUT_DIR}/spaces-configured.txt" ]; then
    cp "${OUT_DIR}/spaces-configured.txt" "${OUT_DIR}/spaces.txt"
    SCOPE_STATE="configured-fallback-after-${SPACES_STATE}"
  else
    printf '%s\n' default > "${OUT_DIR}/spaces.txt"
    SCOPE_STATE="default-fallback-after-${SPACES_STATE}"
  fi
fi
jq -n --arg state "${SPACES_STATE}" --arg scope "${SCOPE_STATE}" \
  '{collection_state:$state,audit_scope_state:$scope}' > "${OUT_DIR}/space-discovery-state.json"
note "space discovery: ${SPACES_STATE}; audit scope: ${SCOPE_STATE}"

if fetch "/api/alerting/_health" "${OUT_DIR}/alerting-health.json" alerting-health; then
  ah_tmp="${OUT_DIR}/alerting-health.json.safe"
  jq '{is_sufficiently_secure,has_permanent_encryption_key,alerting_framework_health}' \
    "${OUT_DIR}/alerting-health.json" > "${ah_tmp}"
  mv "${ah_tmp}" "${OUT_DIR}/alerting-health.json"
fi
AH_STATE="${FETCH_STATE}"
AH_STATUS="${FETCH_STATUS}"
jq -n --arg state "${AH_STATE}" --arg code "${AH_STATUS}" \
  '{state:$state,http_code:(if $code == "" then null else $code end)}' \
  > "${OUT_DIR}/alerting-health-state.json"

rm -rf "${OUT_DIR}/spaces"
mkdir -p "${OUT_DIR}/spaces"
while IFS= read -r space; do
  [ -n "${space}" ] || continue
  if ! printf '%s' "${space}" | grep -Eq '^[A-Za-z0-9_-]+$'; then
    printf '%s\tunsafe-space-id\n' "${space}" >> "${OUT_DIR}/spaces-skipped.txt"
    continue
  fi
  if [ "${space}" = "default" ]; then prefix=""; else prefix="/s/${space}"; fi
  sdir="${OUT_DIR}/spaces/${space}"
  mkdir -p "${sdir}"

  collect_paginated rules "${prefix}" "${sdir}/rules.json" "${sdir}/rules.partial.json" \
    "${sdir}/.rules-pages" || true
  rules_state="${PAGED_STATE}"
  rules_count="${PAGED_COUNT}"
  rules_expected="${PAGED_EXPECTED}"

  collect_paginated connectors "${prefix}" "${sdir}/connectors.json" \
    "${sdir}/connectors.partial.json" "${sdir}/.connectors-pages" || true
  connectors_state="${PAGED_STATE}"
  connectors_count="${PAGED_COUNT}"
  connectors_expected="${PAGED_EXPECTED}"

  if fetch "${prefix}/api/alerting/rule_types" "${sdir}/rule-types.json" array; then :; fi
  rule_types_state="${FETCH_STATE}"

  jq -n --arg rules "${rules_state}" --argjson rules_count "${rules_count}" \
    --arg rules_expected "${rules_expected}" \
    --arg connectors "${connectors_state}" --argjson connectors_count "${connectors_count}" \
    --arg connectors_expected "${connectors_expected}" --arg rule_types "${rule_types_state}" \
    '{rules:{state:$rules,collected:$rules_count,
             expected_total:(if $rules_expected == "" then null else ($rules_expected|tonumber) end)},
      connectors:{state:$connectors,collected:$connectors_count,
                  expected_total:(if $connectors_expected == "" then null else ($connectors_expected|tonumber) end)},
      rule_types:{state:$rule_types}}' > "${sdir}/collection-state.json"
done < "${OUT_DIR}/spaces.txt"

rules_total=0
rules_partial=0
rules_all_complete=1
connectors_total=0
connectors_partial=0
connectors_all_complete=1
while IFS= read -r space; do
  [ -n "${space}" ] || continue
  sdir="${OUT_DIR}/spaces/${space}"
  if [ -f "${sdir}/rules.json" ]; then
    rules_total=$((rules_total + $(jq '.rules | length' "${sdir}/rules.json")))
  else
    rules_all_complete=0
    [ -f "${sdir}/rules.partial.json" ] \
      && rules_partial=$((rules_partial + $(jq '.collected' "${sdir}/rules.partial.json")))
  fi
  if [ -f "${sdir}/connectors.json" ]; then
    connectors_total=$((connectors_total + $(jq 'length' "${sdir}/connectors.json")))
  else
    connectors_all_complete=0
    [ -f "${sdir}/connectors.partial.json" ] \
      && connectors_partial=$((connectors_partial + $(jq '.collected' "${sdir}/connectors.partial.json")))
  fi
done < "${OUT_DIR}/spaces.txt"

{
  echo "run_date=${RUN_DATE}"
  echo "kibana_url=${KIBANA_URL}"
  echo "space_discovery_state=${SPACES_STATE}"
  echo "space_scope_state=${SCOPE_STATE}"
  echo "spaces_audited=$(wc -l < "${OUT_DIR}/spaces.txt" | tr -d ' ')"
  if [ "${rules_all_complete}" -eq 1 ]; then echo "rules=${rules_total}"; else echo "rules=unavailable"; fi
  echo "rules_partial_count=${rules_partial}"
  if [ "${connectors_all_complete}" -eq 1 ]; then echo "connectors=${connectors_total}"; else echo "connectors=unavailable"; fi
  echo "connectors_partial_count=${connectors_partial}"
  echo "alerting_health_state=${AH_STATE}"
  echo "errors=$(wc -l < "${ERRORS}" | tr -d ' ')"
} | tee "${OUT_DIR}/summary.txt"

note "Inventory collection complete. Only normal-name aggregates are complete evidence."
note "Use *.partial.json for object-level investigation only; block estate-wide conclusions."
