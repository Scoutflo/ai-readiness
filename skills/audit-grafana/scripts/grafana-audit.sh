#!/usr/bin/env bash
# grafana-audit.sh -- read-only Grafana inventory dump for the audit-grafana skill.
#
# Environment:
#   GRAFANA_URL          Grafana base URL (toolkit.yaml: grafana.url). Required.
#   GRAFANA_TOKEN        Service-account token; env var is named by grafana.token_env
#                        in ~/.scoutflo/toolkit.yaml. Required. Never printed.
#   OUT_DIR              Output directory. Default: ./scoutflo-audits/grafana/<UTC date>/raw
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
#   dashboard-index.json         /api/search (all pages merged)
#   dashboards/<uid>.json        /api/dashboards/uid/<uid>
#   panel-targets.json           flattened panel/target inventory for the QA gate
#   smells.json                  candidate defects to VERIFY, not findings
#   alert-rules.json             /api/v1/provisioning/alert-rules
#   alert-rules.ruler.json       /api/ruler fallback, only if provisioning is 403
#   contact-points.json          /api/v1/provisioning/contact-points
#   notification-policies.json   /api/v1/provisioning/policies
#   mute-timings.json            /api/v1/provisioning/mute-timings
#   errors.log                   every non-2xx and transport failure (evidence)
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
OUT_DIR="${OUT_DIR:-./scoutflo-audits/grafana/${RUN_DATE}/raw}"
CURL_MAX_TIME="${CURL_MAX_TIME:-20}"
PAGE_SIZE=1000

mkdir -p "${OUT_DIR}/datasource-health" "${OUT_DIR}/dashboards"
ERRORS="${OUT_DIR}/errors.log"
: > "${ERRORS}"

note() { printf '%s\n' "$*"; }

# fetch <api-path> <outfile>
# GET one API path. Save the body. Log failures to errors.log. Never abort the run:
# an unreachable or forbidden endpoint is evidence for the audit, not a crash.
fetch() {
  local path="$1" out="$2" status
  status="$(curl -sS --max-time "${CURL_MAX_TIME}" \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
    -o "${out}" -w '%{http_code}' \
    "${GRAFANA_URL}${path}" 2>>"${ERRORS}")" || {
      echo "TRANSPORT-FAILED ${path} (curl exit $?)" >> "${ERRORS}"
      mv "${out}" "${out}.curl-failed" 2>/dev/null || true
      return 1
    }
  case "${status}" in
    2*) return 0 ;;
    *)  echo "HTTP ${status} ${path}" >> "${ERRORS}"
        mv "${out}" "${out}.http-${status}" 2>/dev/null || true
        return 1 ;;
  esac
}

note "== grafana-audit.sh (read-only) -> ${OUT_DIR}"

# --- 1. Health and identity -------------------------------------------------
# /api/health needs no auth and proves reachability; a failure here means the
# doctor gate should have stopped you already. Always runs, even on a batched
# large-path call, as a cheap liveness check for that batch.
curl -fsS --max-time "${CURL_MAX_TIME}" -o "${OUT_DIR}/health.json" "${GRAFANA_URL}/api/health" \
  || { echo "Grafana health check failed: ${GRAFANA_URL}/api/health" >&2; exit 1; }

if [ "${SKIP_NON_DASHBOARD:-0}" = "1" ]; then
  note "SKIP_NON_DASHBOARD=1: identity, org, folders, datasources, and alerting already captured by an earlier batch this run"
else
  fetch "/api/org"  "${OUT_DIR}/org.json"      || true

  # --- 2. Folders and datasources ---------------------------------------------
  fetch "/api/folders?limit=1000" "${OUT_DIR}/folders.json" || true

  if fetch "/api/datasources" "${OUT_DIR}/datasources.json"; then
    jq -r '.[].uid' "${OUT_DIR}/datasources.json" | while IFS= read -r uid; do
      [ -n "${uid}" ] || continue
      case "${uid}" in */*|.*) echo "SKIPPED unsafe datasource uid: ${uid}" >> "${ERRORS}"; continue ;; esac
      fetch "/api/datasources/uid/${uid}/health" "${OUT_DIR}/datasource-health/${uid}.json" || true
    done
  else
    note "datasource list unavailable (likely missing datasources:read); those checks are blocked, the 403 body is the evidence"
  fi
fi

# --- 3. Dashboard index (paginated) and full JSON per dashboard --------------
pages="${OUT_DIR}/.search-pages"
mkdir -p "${pages}"
page=1
while :; do
  pf="${pages}/page-${page}.json"
  fetch "/api/search?type=dash-db&limit=${PAGE_SIZE}&page=${page}" "${pf}" || break
  count="$(jq 'length' "${pf}")"
  [ "${count}" -gt 0 ] || { rm -f "${pf}"; break; }
  [ "${count}" -eq "${PAGE_SIZE}" ] || break
  page=$((page + 1))
done
if ls "${pages}"/page-*.json >/dev/null 2>&1; then
  jq -s 'add' "${pages}"/page-*.json > "${OUT_DIR}/dashboard-index.json"
else
  echo '[]' > "${OUT_DIR}/dashboard-index.json"
fi
rm -rf "${pages}"

# Large-path batching (see SKILL.md "Large-path worklist"): when DASHBOARD_UIDS_FILE
# is set, fetch full dashboard JSON for only that batch's UIDs. dashboard-index.json
# above is always the complete search result, regardless of batching, because other
# checks (usage-dashboard detection, coverage) need the whole list.
if [ -n "${DASHBOARD_UIDS_FILE:-}" ]; then
  uid_source="${DASHBOARD_UIDS_FILE}"
  note "large-path batch: fetching dashboard JSON for $(wc -l < "${uid_source}" | tr -d ' ') UIDs from ${uid_source}"
else
  uid_source="${OUT_DIR}/.all-dashboard-uids"
  jq -r '.[].uid' "${OUT_DIR}/dashboard-index.json" > "${uid_source}"
fi

while IFS= read -r uid; do
  [ -n "${uid}" ] || continue
  case "${uid}" in */*|.*) echo "SKIPPED unsafe dashboard uid: ${uid}" >> "${ERRORS}"; continue ;; esac
  fetch "/api/dashboards/uid/${uid}" "${OUT_DIR}/dashboards/${uid}.json" || true
done < "${uid_source}"
[ "${uid_source}" = "${OUT_DIR}/.all-dashboard-uids" ] && rm -f "${uid_source}"

# --- 4. Flatten panel targets for the semantic QA gate -----------------------
# One row per non-row panel that has targets: dashboard, panel, datasource ref,
# raw expressions, stat reducers. Row panels are expanded so nested panels count.
if ls "${OUT_DIR}/dashboards"/*.json >/dev/null 2>&1; then
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
  ' "${OUT_DIR}/dashboards"/*.json > "${OUT_DIR}/panel-targets.json"
else
  echo '[]' > "${OUT_DIR}/panel-targets.json"
fi

# Candidate defects only. Every flag must be verified live before it becomes a
# finding; a flag that survives verification maps to a GRAF ID (see SKILL.md).
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
' "${OUT_DIR}/panel-targets.json" > "${OUT_DIR}/smells.json"

# --- 5. Alerting configuration (read-only exports) ---------------------------
if [ "${SKIP_NON_DASHBOARD:-0}" = "1" ]; then
  note "SKIP_NON_DASHBOARD=1: alerting configuration already captured by an earlier batch this run"
else
  if ! fetch "/api/v1/provisioning/alert-rules" "${OUT_DIR}/alert-rules.json"; then
    note "provisioning API unavailable; trying the ruler read API"
    fetch "/api/ruler/grafana/api/v1/rules" "${OUT_DIR}/alert-rules.ruler.json" \
      || note "alert rules unreadable through both APIs (see errors.log); alerting checks are blocked"
  fi
  fetch "/api/v1/provisioning/contact-points" "${OUT_DIR}/contact-points.json" || true
  fetch "/api/v1/provisioning/policies"       "${OUT_DIR}/notification-policies.json" || true
  fetch "/api/v1/provisioning/mute-timings"   "${OUT_DIR}/mute-timings.json" || true
fi

# --- 6. Summary ---------------------------------------------------------------
count_of() { jq 'length' "$1" 2>/dev/null || echo "unavailable"; }
{
  echo "run_date=${RUN_DATE}"
  echo "grafana_url=${GRAFANA_URL}"
  echo "datasources=$(count_of "${OUT_DIR}/datasources.json")"
  echo "dashboards=$(count_of "${OUT_DIR}/dashboard-index.json")"
  echo "panels_with_targets=$(count_of "${OUT_DIR}/panel-targets.json")"
  echo "flagged_panels=$(count_of "${OUT_DIR}/smells.json")"
  echo "alert_rules=$(count_of "${OUT_DIR}/alert-rules.json")"
  echo "alert_rules_ruler_fallback=$([ -s "${OUT_DIR}/alert-rules.ruler.json" ] && echo yes || echo no)"
  echo "contact_points=$(count_of "${OUT_DIR}/contact-points.json")"
  echo "notification_policies_present=$([ -s "${OUT_DIR}/notification-policies.json" ] && echo yes || echo no)"
  echo "errors=$(wc -l < "${ERRORS}" | tr -d ' ')"
} | tee "${OUT_DIR}/summary.txt"

note "Inventory complete. Counts are inventory, not audit results: score only from"
note "live checks per SKILL.md, and verify every smells.json flag before filing it."
