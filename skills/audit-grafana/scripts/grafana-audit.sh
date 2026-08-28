#!/usr/bin/env bash
# grafana-audit.sh -- read-only Grafana inventory dump for the audit-grafana skill.
#
# Environment:
#   GRAFANA_URL          Grafana base URL (toolkit.yaml: grafana.url). Required.
#   GRAFANA_TOKEN        Service-account token; env var is named by grafana.token_env
#                        in ~/.scoutflo/toolkit.yaml. Required. Never printed.
#   OUT_DIR              Output directory. Default: ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/<UTC date>/raw
#   CURL_MAX_TIME        Per-request timeout in seconds. Default: 20.
#   DASHBOARD_UIDS_FILE  Large-path batching only (see SKILL.md "Estate sizing" and
#                        "Large-path worklist"). One dashboard UID per line. When set,
#                        only these UIDs get their full dashboard JSON fetched this run;
#                        dashboard-index.json (the search result, cheap) is still built in
#                        full every run so category checks that need the whole list (usage
#                        dashboard detection, coverage) keep working. Unset: fetch all.
#   SKIP_NON_DASHBOARD   Large-path batching only. "1" skips identity, org, folders,
#                        datasources, and alerting reads (already captured by an earlier
#                        batch in the same run). Unset or any other value: fetch them.
#
# Read-only guarantee: every call is an HTTP GET. Nothing is created, changed,
# silenced, annotated, or notified. Safe to run against production.
#
# No `set -x` in this script, ever: command tracing would print the
# Authorization header, leaking the token into terminal scrollback and logs.
#
# Outputs (under OUT_DIR):
#   health.json                  /api/health
#   org.json                     /api/org (identity: confirmed live on Grafana 10.4.1 that
#                                 /api/user hard-403s for a real, correctly-scoped
#                                 service-account token regardless of role, so this script
#                                 never calls it; /api/org is the identity source)
#   folders.json                 /api/folders
#   datasources.json             /api/datasources
#   datasource-health/<uid>.json /api/datasources/uid/<uid>/health
#   dashboard-index.json         /api/search (all pages merged; written only
#                                 when every required page was read)
#   dashboard-index.partial.json successfully read /api/search pages when a
#                                 later page failed; never treated as complete
#   dashboards/<uid>.json        /api/dashboards/uid/<uid>
#   panel-targets.json           flattened panel/target inventory for the QA gate
#   panel-targets.partial.json   derived panel inventory when search/dashboard
#                                 reads were incomplete
#   smells.json                  candidate defects to VERIFY, not findings
#   smells.partial.json          candidates derived from partial panel evidence
#   alert-rules.json             /api/v1/provisioning/alert-rules
#   alert-rules.ruler.json       /api/ruler fallback, only if provisioning is 403
#   contact-points.json          /api/v1/provisioning/contact-points
#   notification-policies.json   /api/v1/provisioning/policies
#   mute-timings.json            /api/v1/provisioning/mute-timings
#   errors.log                   every non-2xx and transport failure (evidence)
#   request-status.jsonl         one normalized evidence-state row per request:
#                                 success-empty, success-nonempty, forbidden,
#                                 unauthenticated, unsupported, transport-error,
#                                 http-error, invalid-response, or partial
#   summary.txt                  inventory counts (counts are not audit results)
#
# Failed calls keep their response body as <file>.http-<status>; a 401/403/404
# body is evidence, not garbage. Keep OUT_DIR out of public version control.

set -eu

: "${GRAFANA_URL:?GRAFANA_URL is not set; resolve it from grafana.url in ~/.scoutflo/toolkit.yaml}"
: "${GRAFANA_TOKEN:?GRAFANA_TOKEN is not set; run /scoutflo:connect}"

command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

GRAFANA_URL="${GRAFANA_URL%/}"
RUN_DATE="$(date -u +%Y-%m-%d)"
# Honor SCOUTFLO_AUDIT_DIR when OUT_DIR is not passed explicitly, so a standalone
# run of this script lands in the same resolved reports directory as the skill.
OUT_DIR="${OUT_DIR:-${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/${RUN_DATE}/raw}"
CURL_MAX_TIME="${CURL_MAX_TIME:-20}"
PAGE_SIZE=1000

mkdir -p "${OUT_DIR}"
# A normal run is a fresh point-in-time capture even when it reuses the same
# date-based OUT_DIR. Remove object artifacts that can otherwise survive a
# same-day rerun after a datasource or dashboard was deleted. Large-path
# follow-up batches deliberately keep the first batch's objects.
if [ "${SKIP_NON_DASHBOARD:-0}" != "1" ]; then
  rm -rf "${OUT_DIR}/datasource-health" "${OUT_DIR}/dashboards"
fi
mkdir -p "${OUT_DIR}/datasource-health" "${OUT_DIR}/dashboards"
ERRORS="${OUT_DIR}/errors.log"
REQUEST_STATUS="${OUT_DIR}/request-status.jsonl"
# Large-path batches share OUT_DIR. Preserve the earlier batch's non-dashboard
# statuses/errors when SKIP_NON_DASHBOARD=1; a normal run starts fresh.
if [ "${SKIP_NON_DASHBOARD:-0}" = "1" ] && [ -f "${REQUEST_STATUS}" ]; then
  :
else
  : > "${ERRORS}"
  : > "${REQUEST_STATUS}"
fi
[ -f "${ERRORS}" ] || : > "${ERRORS}"
[ -f "${REQUEST_STATUS}" ] || : > "${REQUEST_STATUS}"

note() { printf '%s\n' "$*"; }

# record_state <api-path> <artifact> <state> <http-status> <detail>
# Keep this ledger secret-free: it records paths, artifact names, normalized
# states, and short reasons only. It never records headers or response bodies.
record_state() {
  local path="$1" out="$2" state="$3" status="$4" detail="$5" artifact
  artifact="${out#"${OUT_DIR}/"}"
  jq -cn \
    --arg path "${path}" --arg artifact "${artifact}" \
    --arg state "${state}" --arg status "${status}" --arg detail "${detail}" \
    '{path:$path, artifact:$artifact, state:$state,
      http_status:(if $status == "" then null else $status end), detail:$detail}' \
    >> "${REQUEST_STATUS}"
}

json_is_empty() {
  jq -e 'if . == null then true
         elif (type == "array" or type == "object" or type == "string") then length == 0
         else false end' "$1" >/dev/null 2>&1
}

json_has_shape() {
  local out="$1" expected="$2"
  case "${expected}" in
    any)    jq -e '.' "${out}" >/dev/null 2>&1 ;;
    array)  jq -e 'type == "array"' "${out}" >/dev/null 2>&1 ;;
    object) jq -e 'type == "object"' "${out}" >/dev/null 2>&1 ;;
    *)      return 1 ;;
  esac
}

# fetch <api-path> <outfile> [expected-json-shape]
# GET one API path. Save the body. Log failures to errors.log. Never abort the run:
# an unreachable or forbidden endpoint is evidence for the audit, not a crash.
fetch() {
  local path="$1" out="$2" expected="${3:-any}" status rc state
  rm -f "${out}" "${out}.curl-failed" "${out}.invalid-response" "${out}".http-*
  status="$(curl -sS --max-time "${CURL_MAX_TIME}" \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
    -o "${out}" -w '%{http_code}' \
    "${GRAFANA_URL}${path}" 2>>"${ERRORS}")" || {
      rc=$?
      echo "TRANSPORT-ERROR ${path} (curl exit ${rc})" >> "${ERRORS}"
      mv "${out}" "${out}.curl-failed" 2>/dev/null || true
      record_state "${path}" "${out}" "transport-error" "${status:-000}" "curl exit ${rc}"
      return 1
    }
  case "${status}" in
    2*)
      if ! json_has_shape "${out}" "${expected}"; then
        echo "INVALID-RESPONSE ${path} (HTTP ${status}; expected ${expected} JSON)" >> "${ERRORS}"
        mv "${out}" "${out}.invalid-response" 2>/dev/null || true
        record_state "${path}" "${out}" "invalid-response" "${status}" "expected ${expected} JSON"
        return 1
      fi
      if json_is_empty "${out}"; then state="success-empty"; else state="success-nonempty"; fi
      record_state "${path}" "${out}" "${state}" "${status}" "complete response"
      return 0
      ;;
    401) state="unauthenticated" ;;
    403) state="forbidden" ;;
    404|405|501) state="unsupported" ;;
    *) state="http-error" ;;
  esac
  echo "HTTP ${status} ${path} (${state})" >> "${ERRORS}"
  mv "${out}" "${out}.http-${status}" 2>/dev/null || true
  record_state "${path}" "${out}" "${state}" "${status}" "request did not return usable evidence"
  return 1
}

note "== grafana-audit.sh (read-only) -> ${OUT_DIR}"

# --- 1. Health and identity -------------------------------------------------
# /api/health proves reachability; a failure here means the doctor gate should
# have stopped you already. It still goes through fetch so the failure state is
# normalized in request-status.jsonl instead of disappearing at process exit.
fetch "/api/health" "${OUT_DIR}/health.json" object \
  || { echo "Grafana health check failed: ${GRAFANA_URL}/api/health" >&2; exit 1; }

if [ "${SKIP_NON_DASHBOARD:-0}" = "1" ]; then
  note "SKIP_NON_DASHBOARD=1: identity, org, folders, datasources, and alerting already captured by an earlier batch this run"
else
  fetch "/api/org"  "${OUT_DIR}/org.json" object || true

  # --- 2. Folders and datasources ---------------------------------------------
  fetch "/api/folders?limit=1000" "${OUT_DIR}/folders.json" array || true

  if fetch "/api/datasources" "${OUT_DIR}/datasources.json" array; then
    jq -r '.[].uid' "${OUT_DIR}/datasources.json" | while IFS= read -r uid; do
      [ -n "${uid}" ] || continue
      case "${uid}" in */*|.*) echo "SKIPPED unsafe datasource uid: ${uid}" >> "${ERRORS}"; continue ;; esac
      fetch "/api/datasources/uid/${uid}/health" "${OUT_DIR}/datasource-health/${uid}.json" object || true
    done
  else
    note "datasource list unavailable (likely missing datasources:read); those checks are blocked, the 403 body is the evidence"
  fi
fi

# --- 3. Dashboard index (paginated) and full JSON per dashboard --------------
pages="${OUT_DIR}/.search-pages"
rm -rf "${pages}"
mkdir -p "${pages}"
rm -f "${OUT_DIR}/dashboard-index.json" "${OUT_DIR}/dashboard-index.partial.json"
page=1
search_pages_ok=0
search_state="complete"
search_failure=""
while :; do
  pf="${pages}/page-${page}.json"
  if ! fetch "/api/search?type=dash-db&limit=${PAGE_SIZE}&page=${page}" "${pf}" array; then
    search_state="unavailable"
    search_failure="$(jq -rs --arg artifact ".search-pages/page-${page}.json" \
      '[.[] | select(.artifact == $artifact)][-1].state // "http-error"' "${REQUEST_STATUS}")"
    [ "${search_pages_ok}" -gt 0 ] && search_state="partial"
    break
  fi
  search_pages_ok=$((search_pages_ok + 1))
  count="$(jq 'length' "${pf}")"
  [ "${count}" -gt 0 ] || break
  [ "${count}" -eq "${PAGE_SIZE}" ] || break
  page=$((page + 1))
done
case "${search_state}" in
  complete)
    # At least one successful page always exists here, including a legitimate
    # first-page []. That is a verified empty estate, not a read failure.
    jq -s 'add' "${pages}"/page-*.json > "${OUT_DIR}/dashboard-index.json"
    ;;
  partial)
    jq -s 'add' "${pages}"/page-*.json > "${OUT_DIR}/dashboard-index.partial.json"
    record_state "/api/search (paginated aggregate)" "${OUT_DIR}/dashboard-index.partial.json" \
      "partial" "" "${search_pages_ok} page(s) read; page ${page} ended in ${search_failure}"
    ;;
  unavailable)
    note "dashboard index unavailable (${search_failure}); dashboard coverage checks are blocked, not empty"
    ;;
esac
# On an incomplete read, keep .search-pages: it contains the exact failed body
# suffix (.http-*, .invalid-response, or .curl-failed) and the successful pages
# that justify dashboard-index.partial.json. Only a complete aggregate may
# discard those intermediate files.
[ "${search_state}" = "complete" ] && rm -rf "${pages}"

# Large-path batching (see SKILL.md "Large-path worklist"): when DASHBOARD_UIDS_FILE
# is set, fetch full dashboard JSON for only that batch's UIDs. A complete
# dashboard-index.json is still built when pagination succeeds. If it does not,
# only dashboard-index.partial.json is written and coverage remains blocked.
if [ -n "${DASHBOARD_UIDS_FILE:-}" ]; then
  uid_source="${DASHBOARD_UIDS_FILE}"
  note "large-path batch: fetching dashboard JSON for $(wc -l < "${uid_source}" | tr -d ' ') UIDs from ${uid_source}"
else
  uid_source="${OUT_DIR}/.all-dashboard-uids"
  if [ -f "${OUT_DIR}/dashboard-index.json" ]; then
    jq -r '.[].uid' "${OUT_DIR}/dashboard-index.json" > "${uid_source}"
  elif [ -f "${OUT_DIR}/dashboard-index.partial.json" ]; then
    jq -r '.[].uid' "${OUT_DIR}/dashboard-index.partial.json" > "${uid_source}"
    note "dashboard UID list is partial because search pagination did not complete"
  else
    : > "${uid_source}"
  fi
fi

dashboard_fetch_failed=0
while IFS= read -r uid; do
  [ -n "${uid}" ] || continue
  case "${uid}" in */*|.*) echo "SKIPPED unsafe dashboard uid: ${uid}" >> "${ERRORS}"; continue ;; esac
  fetch "/api/dashboards/uid/${uid}" "${OUT_DIR}/dashboards/${uid}.json" object \
    || dashboard_fetch_failed=1
done < "${uid_source}"
[ "${uid_source}" = "${OUT_DIR}/.all-dashboard-uids" ] && rm -f "${uid_source}"

# --- 4. Flatten panel targets for the semantic QA gate -----------------------
# One row per non-row panel that has targets: dashboard, panel, datasource ref,
# raw expressions, stat reducers. Row panels are expanded so nested panels count.
panel_artifact="${OUT_DIR}/panel-targets.json"
smells_artifact="${OUT_DIR}/smells.json"
rm -f "${OUT_DIR}/panel-targets.json" "${OUT_DIR}/panel-targets.partial.json" \
      "${OUT_DIR}/smells.json" "${OUT_DIR}/smells.partial.json"
if [ "${search_state}" != "complete" ] || [ "${dashboard_fetch_failed}" -ne 0 ] || [ -n "${DASHBOARD_UIDS_FILE:-}" ]; then
  panel_artifact="${OUT_DIR}/panel-targets.partial.json"
  smells_artifact="${OUT_DIR}/smells.partial.json"
fi

if [ "${search_state}" != "unavailable" ] && ls "${OUT_DIR}/dashboards"/*.json >/dev/null 2>&1; then
  jq -s '
    [ .[] | .dashboard as $d
      | [ ($d.panels // [])[] | ., ((.panels // [])[]) ][]
      | select(.type != "row") | select(.targets != null) as $p
      | { dashboard_uid: $d.uid,
          dashboard_title: $d.title,
          panel_id: $p.id,
          panel_title: ($p.title // ""),
          panel_type: $p.type,
          datasource: ($p.datasource // null),
          reducers: ($p.options.reduceOptions.calcs // []),
          targets: [ ($p.targets // [])[]
                     | { refId: (.refId // null),
                         datasource: (.datasource // null),
                         expr: (.expr // .query // .target // null) } ] } ]
  ' "${OUT_DIR}/dashboards"/*.json > "${panel_artifact}"
elif [ "${search_state}" = "complete" ]; then
  # A complete, empty index legitimately has zero dashboard panels.
  echo '[]' > "${panel_artifact}"
fi

# Candidate defects only. Every flag must be verified live before it becomes a
# finding; a flag that survives verification maps to a GRAF ID (see SKILL.md).
if [ -f "${panel_artifact}" ]; then
  jq '
    [ .[] |
      { dashboard_uid, dashboard_title, panel_id, panel_title, panel_type,
        flags: [
          (if (.panel_type == "stat" and ((.reducers // []) | index("count"))) then "count-reducer-on-stat" else empty end),
          (if ([ .targets[]? | (.expr // "") ] | index("")) then "empty-target" else empty end),
          (if ([ .targets[]? | (.expr // "") | tostring | test("(limit|per_page|pageSize)=") ] | any) then "paginated-source" else empty end),
          (if (.datasource == null and ([ .targets[]? | .datasource ] | all(. == null))) then "implicit-default-datasource" else empty end)
        ] }
      | select((.flags | length) > 0) ]
  ' "${panel_artifact}" > "${smells_artifact}"
fi

# --- 5. Alerting configuration (read-only exports) ---------------------------
if [ "${SKIP_NON_DASHBOARD:-0}" = "1" ]; then
  note "SKIP_NON_DASHBOARD=1: alerting configuration already captured by an earlier batch this run"
else
  if ! fetch "/api/v1/provisioning/alert-rules" "${OUT_DIR}/alert-rules.json" array; then
    note "provisioning API unavailable; trying the ruler read API"
    fetch "/api/ruler/grafana/api/v1/rules" "${OUT_DIR}/alert-rules.ruler.json" object \
      || note "alert rules unreadable through both APIs (see errors.log); alerting checks are blocked"
  fi
  fetch "/api/v1/provisioning/contact-points" "${OUT_DIR}/contact-points.json" array || true
  fetch "/api/v1/provisioning/policies"       "${OUT_DIR}/notification-policies.json" object || true
  fetch "/api/v1/provisioning/mute-timings"   "${OUT_DIR}/mute-timings.json" array || true
fi

# --- 6. Summary ---------------------------------------------------------------
count_of() { jq 'length' "$1" 2>/dev/null || echo "unavailable"; }
state_of() {
  local artifact="$1"
  jq -rs --arg artifact "${artifact}" \
    '[.[] | select(.artifact == $artifact)][-1].state // "not-requested"' "${REQUEST_STATUS}"
}
{
  echo "run_date=${RUN_DATE}"
  echo "grafana_url=${GRAFANA_URL}"
  echo "datasources=$(count_of "${OUT_DIR}/datasources.json")"
  echo "dashboards=$(count_of "${OUT_DIR}/dashboard-index.json")"
  echo "dashboard_index_state=${search_state}"
  echo "dashboard_partial_count=$(count_of "${OUT_DIR}/dashboard-index.partial.json")"
  echo "panels_with_targets=$(count_of "${panel_artifact}")"
  echo "flagged_panels=$(count_of "${smells_artifact}")"
  echo "alert_rules=$(count_of "${OUT_DIR}/alert-rules.json")"
  echo "alert_rules_ruler_fallback=$([ -s "${OUT_DIR}/alert-rules.ruler.json" ] && echo yes || echo no)"
  echo "contact_points=$(count_of "${OUT_DIR}/contact-points.json")"
  echo "notification_policies_state=$(state_of "notification-policies.json")"
  echo "errors=$(wc -l < "${ERRORS}" | tr -d ' ')"
} | tee "${OUT_DIR}/summary.txt"

note "Inventory complete. Counts are inventory, not audit results: score only from"
note "live checks per SKILL.md, and verify every smells.json flag before filing it."
