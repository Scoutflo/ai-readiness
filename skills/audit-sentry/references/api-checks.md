# Sentry Audit: API Surface, Payloads, Check Catalog

Lookup material for the `audit-sentry` workflow. The workflow itself lives in [SKILL.md](../SKILL.md). Every call below is read-only; classify by effect, not verb, but this surface has no read-only POSTs: every write-shaped verb is genuinely a write and belongs to `setup-sentry`.

## Read-only API surface

All paths are relative to `${API}` (`https://${SENTRY_HOST}/api/0`, `sentry.host` from `~/.scoutflo/toolkit.yaml`).

| Purpose | Method | Path | Notes |
| --- | --- | --- | --- |
| Org identity | GET | `/organizations/{org}/` | Doctor gate and live-safety gate |
| Projects | GET | `/organizations/{org}/projects/` | Paginated |
| Teams | GET | `/organizations/{org}/teams/` | Paginated |
| Integrations | GET | `/organizations/{org}/integrations/` | Paginated; provider and status |
| Repositories | GET | `/organizations/{org}/repos/` | Paginated; tolerate 404 when VCS is not connected |
| Code mappings | GET | `/organizations/{org}/code-mappings/` | Paginated; requires a connected VCS integration |
| Releases | GET | `/organizations/{org}/releases/` | Paginated; `deployCount`, `commitCount` per release |
| Monitors (cron) | GET | `/organizations/{org}/monitors/` | Paginated; env-scoped check-in state |
| Alert API probe | GET | `/organizations/{org}/workflows/?per_page=1`, `/organizations/{org}/combined-rules/?per_page=1` | Doctor gate only: `200` JSON on workflows means the alerts API; a route-missing `404` (empty body, `Allow: OPTIONS`) on combined-rules means the legacy routes are gone |
| Alerts | GET | `/organizations/{org}/workflows/` | Paginated (`per_page` up to 100); `project` (id or slug), `detector`, and `id` filters. Every issue alert, and the notifying half of every metric alert |
| Monitors | GET | `/organizations/{org}/detectors/` | Paginated; `project` and `type` filters (`metric_issue`, `uptime_domain_failure`, `issue_stream`, `error`; aliases `metric`, `uptime`). Thresholds and windows live here, actions do not |
| Live action targets | GET | `/organizations/{org}/available-actions/` | The action types an alert can use and the installed integrations behind them (`.[].integrations[].id`); the integrations SNTRY-005 accepts as live |
| Alert fire stats | GET | `/organizations/{org}/workflows/{id}/stats/?statsPeriod=90d` | Hourly buckets at `timeSeries[0].values[].value`; Sentry marks it experimental |
| Metric alerts (legacy fallback) | GET | `/organizations/{org}/alert-rules/` | Self-hosted Sentry that still serves the legacy routes only; on SaaS it answers a route-missing 404 |
| Volume and outcomes | GET | `/organizations/{org}/stats_v2/` | `groupBy=category`, `groupBy=outcome`, `groupBy=project`; source for quota and privacy-telemetry checks |
| Project detail | GET | `/projects/{org}/{project}/` | Privacy flags, scrubbers, sensitive fields, source-scrape setting |
| Project issue rules (legacy fallback) | GET | `/projects/{org}/{project}/rules/` | Self-hosted Sentry that still serves the legacy routes only; on SaaS it answers a route-missing 404, so read the project's alerts from `/workflows/?project=` |
| Project environments | GET | `/projects/{org}/{project}/environments/` | Environment inventory |
| Project client keys | GET | `/projects/{org}/{project}/keys/` | Keep only `name`, `isActive`, `rateLimit`; never store the DSN |
| Project uptime monitors (legacy fallback) | GET | `/projects/{org}/{project}/uptime/` | Confirmed live: Sentry SaaS answers GET here with `405 Method Not Allowed` (`{"detail":"Method \"GET\" not allowed."}`), because uptime monitors are `uptime_domain_failure` detectors on the alerts API. On the legacy fallback a failed read is recorded in `blocked-reads.tsv`, never stored as an empty list |
| Issue list | GET | `/organizations/{org}/issues/` | Sample recent issues per project for the source-map minified-frame check; never use its length as a total |
| One event | GET | `/organizations/{org}/issues/{id}/events/latest/` | Requires `event:read`; source for the minified-frame check |

## Pagination and rate limits

Sentry paginates with an RFC 5988 `Link` header, not an offset parameter. Every listing call in Phase 1 goes through one helper that follows `rel="next"` until the header stops offering one:

```bash
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
fetch_all() { # $1: full API URL. Follows cursor pagination, prints one merged JSON array.
  url="$1"; hdr="$(mktemp)"; acc="$(mktemp)"
  while [ -n "$url" ]; do
    curl -fsS --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" -D "$hdr" "$url" >> "$acc" \
      || { rm -f "$hdr" "$acc"; return 1; }
    printf '\n' >> "$acc"
    url="$(tr -d '\r' < "$hdr" | sed -n 's/.*<\([^>]*\)>; rel="next"; results="true".*/\1/p')"
  done
  jq -s 'add // []' "$acc"; rm -f "$hdr" "$acc"
}
```

A first page read as the whole list undercounts silently on any org with more than one page of projects, rules, releases, or issues; this is why Phase 1 always calls `fetch_all`, never a bare `curl`.

Rate limits are per-token, replenishing on a rolling window; a `429` carries `Retry-After`. On a `429`, sleep for that many seconds once and retry the single call; if it repeats, record the endpoint as `blocked` with the `429` as evidence rather than looping indefinitely.

## Minimum permissions

Build a dedicated read-only auth token for auditing. Token scopes required per call group:

| Call group | Scope |
| --- | --- |
| Org, teams, members | `org:read` |
| Projects, project detail, environments | `project:read` |
| Client keys | `project:read` |
| Alerts, monitors, fire stats (legacy fallback: issue rules, metric alerts) | `alerts:read` |
| Live action targets (`available-actions`) | `org:read` |
| Issues, events (minified-frame check) | `event:read` |
| Releases, monitors | `project:read` |
| Repos, code mappings | `org:read` |

An `org:read` + `project:read` + `alerts:read` token runs the full audit. `event:read` is optional; without it the releases-and-source-context category loses its minified-frame check and, if that is the only check left standing in the category, the whole category is excluded per the scoring mechanics, stated in the report. Never request write scopes for this skill; a token that can write is still auditable, but the audit itself never uses the extra scope.

## Large orgs: worklist, batches, and resume

Runs on the large path only (see [SKILL.md#estate-sizing](../SKILL.md#estate-sizing)). Replaces the per-project loop at the end of Phase 1; the org-level fetches above the loop (`projects.json`, `teams.json`, `integrations.json`, and the rest) still run once, cluster-wide, before this procedure starts. All state lives under a run-ID-keyed run directory, not a calendar-date directory, so a batch that is still running when the date rolls over in UTC does not abandon its progress or fight the next day's directory.

**Multi-target:** the `sentry/...` output paths in the blocks below are the single-block (flat) form. For a labeled-list target, every `sentry/...` output path becomes `sentry/<label>/...`: resolve `SNTRY_SEG` (single block → `sentry`; labeled list → `sentry/<label>`) exactly as the SKILL.md doctor/estate blocks do, and substitute it for the leading `sentry` segment in `AUDIT_ROOT`, `RUN_DIR`, and `RAW_DIR`. Connection params and the token are the same per-target reads the SKILL.md uses — `SENTRY_HOST`/`SENTRY_ORG` from `sh "$TT" "$CFG" sentry get "$SNTRY_IDX" host|org`, and the token from the variable named by `... get "$SNTRY_IDX" token_env`.

**Step 0: find a resumable run, or mint a new run ID.**

```bash
set -eu
AUDIT_ROOT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry"
resumable=""
if [ -d "${AUDIT_ROOT}/runs" ]; then
  for d in "${AUDIT_ROOT}/runs"/*/; do
    [ -f "${d}worklist.tsv" ] || continue
    pending=$(awk -F'\t' '$2 == "pending"' "${d}worklist.tsv" | wc -l | tr -d ' ')
    [ "${pending}" -gt 0 ] || continue
    resumable="${d}"
    echo "resumable run found: ${d} (pending=${pending})"
  done
fi
if [ -n "${resumable}" ]; then
  echo "resume ${resumable} instead of starting a new run? offer this to the user before proceeding"
else
  echo "no resumable run found; safe to start a new one"
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"   # first-seen timestamp of this run; stable for its lifetime
  RUN_DIR="${AUDIT_ROOT}/runs/${RUN_ID}"
  mkdir -p "${RUN_DIR}/raw/projects"
  echo "${RUN_ID}" > "${RUN_DIR}/run-id"
  echo "run: ${RUN_ID}"
fi
```

**Step 1: build or resume the worklist.** One row per project slug, tab-separated `slug<TAB>status`, status `pending` or `done`. Never rebuild an existing worklist; rebuilding forgets progress.

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
RUN_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/runs/20260717T140500Z"   # example; this run's resolved RUN_DIR from step 0
WORKLIST="${RUN_DIR}/worklist.tsv"

if [ -f "${WORKLIST}" ]; then
  pending=$(awk -F'\t' '$2 == "pending"' "${WORKLIST}" | wc -l | tr -d ' ')
  done=$(awk -F'\t' '$2 == "done"' "${WORKLIST}" | wc -l | tr -d ' ')
  echo "worklist exists: done=${done} pending=${pending}"
else
  fetch_all() {
    url="$1"; hdr="$(mktemp)"; acc="$(mktemp)"
    while [ -n "$url" ]; do
      curl -fsS --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" -D "$hdr" "$url" >> "$acc" \
        || { rm -f "$hdr" "$acc"; return 1; }
      printf '\n' >> "$acc"
      url="$(tr -d '\r' < "$hdr" | sed -n 's/.*<\([^>]*\)>; rel="next"; results="true".*/\1/p')"
    done
    jq -s 'add // []' "$acc"; rm -f "$hdr" "$acc"
  }
  fetch_all "${API}/organizations/${SENTRY_ORG}/projects/" > "${RUN_DIR}/raw/projects.json"
  jq -r '.[].slug' "${RUN_DIR}/raw/projects.json" | awk '{print $0"\tpending"}' > "${WORKLIST}"
  echo "worklist built: $(wc -l < "${WORKLIST}" | tr -d ' ') projects, all pending"
fi
```

**Step 2: lock, then pull one batch.** Acquire `worklist.lock` before reading pending rows; a lock older than `LOCK_STALE_MINUTES` is abandoned and safe to reclaim.

```bash
set -eu
RUN_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/runs/20260717T140500Z"   # example; this run's resolved RUN_DIR
WORKLIST="${RUN_DIR}/worklist.tsv"
LOCK="${RUN_DIR}/worklist.lock"
LOCK_STALE_MINUTES="30"   # example, tune to your batch size and expected run length
BATCH_SIZE="10"           # example, tune it; matches the estate-sizing declaration

now_epoch=$(date -u +%s)
if [ -f "${LOCK}" ]; then
  lock_pid=$(awk -F'\t' 'NR==1{print $1}' "${LOCK}")
  lock_epoch=$(awk -F'\t' 'NR==1{print $2}' "${LOCK}")
  age_minutes=$(( (now_epoch - lock_epoch) / 60 ))
  if [ "${age_minutes}" -lt "${LOCK_STALE_MINUTES}" ]; then
    echo "worklist locked by pid ${lock_pid}, age ${age_minutes}m; stop, do not claim a batch"
    exit 1
  fi
  echo "existing lock is ${age_minutes}m old (>= ${LOCK_STALE_MINUTES}m); treating as abandoned and reclaiming"
fi
printf '%s\t%s\n' "$$" "${now_epoch}" > "${LOCK}"
echo "lock acquired: pid=$$ at ${now_epoch}"

BATCH="$(awk -F'\t' '$2 == "pending"' "${WORKLIST}" | head -n "${BATCH_SIZE}" | cut -f1)"
echo "batch claimed:"; printf '%s\n' "${BATCH}"
rm -f "${LOCK}"   # release once this batch's rows are marked in step 3, not before
```

**Step 3: pull the batch's raw data, then mark rows done.** A project is marked `done` once each of its pulls has either written its file or been recorded in that project's own `blocked-reads.tsv`, so an interrupted batch resumes at the project it was pulling, not the start of the batch. A refused read (a 403 on one project) is blocked evidence: it is never stored as an empty list and never holds the worklist open. The project's `blocked-reads.tsv` is cleared at the start of each pull, so a resumed pull that succeeds leaves no stale row.

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
RUN_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/runs/20260717T140500Z"   # example; this run's resolved RUN_DIR
WORKLIST="${RUN_DIR}/worklist.tsv"
BATCH="checkout
payments"   # example; the batch claimed in step 2, one slug per line
SENTRY_ALERT_API="workflows"   # the doctor gate's "alert api:" value: workflows, or legacy for the fallback

fetch_all() {
  url="$1"; hdr="$(mktemp)"; acc="$(mktemp)"
  while [ -n "$url" ]; do
    curl -fsS --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" -D "$hdr" "$url" >> "$acc" \
      || { rm -f "$hdr" "$acc"; return 1; }
    printf '\n' >> "$acc"
    url="$(tr -d '\r' < "$hdr" | sed -n 's/.*<\([^>]*\)>; rel="next"; results="true".*/\1/p')"
  done
  # A page that is not JSON (an SSO page) fails the merge: the raw pages are still removed.
  rc=0; jq -s 'add // []' "$acc" || rc=$?; rm -f "$hdr" "$acc"; return "$rc"
}
# A failed read writes no file. Its status goes to the project's blocked-reads.tsv (step 4 copies it
# into the merged raw dir) and the loop moves on; a read that failed is never stored as an empty list.
block_read() { # $1: surface label, $2: full API URL, $3: blocked-reads file
  bcode="$(curl -sS -o /dev/null -w '%{http_code} %{content_type}' --max-time 15 \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" "$2")" || bcode="curl-exit-$? ${bcode:-}"
  case "$bcode" in "200 application/json"*) bcode="${bcode}, but a later page or the body failed" ;; esac
  printf '%s\t%s\n' "$1" "${bcode:-000}" >> "$3"
  echo "BLOCKED: $1 read returned ${bcode:-no response}; record it as blocked evidence, not an empty list"
}
read_or_block() { # $1: surface label, $2: full API URL, $3: output file, $4: blocked-reads file
  if fetch_all "$2" > "$3" && [ -s "$3" ]; then return 0; fi
  rm -f "$3"
  block_read "$1" "$2" "$4"
}

echo "${BATCH}" | while IFS= read -r p; do
  [ -n "$p" ] || continue
  d="${RUN_DIR}/raw/projects/${p}"; mkdir -p "$d"
  bl="${d}/blocked-reads.tsv"; : > "$bl"   # each pull starts clean: a resumed pull that succeeds leaves no stale row
  # Project detail carries the project's securityToken: drop it before anything is written.
  detail="$(curl -fsS --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" "${API}/projects/${SENTRY_ORG}/${p}/")" \
    && printf '%s\n' "$detail" | jq 'del(.securityToken)' > "${d}/detail.json" \
    || { rm -f "${d}/detail.json"; block_read "detail:${p}" "${API}/projects/${SENTRY_ORG}/${p}/" "$bl"; }
  read_or_block "environments:${p}" "${API}/projects/${SENTRY_ORG}/${p}/environments/" "${d}/environments.json" "$bl"
  # Keys: keep only name, status, rate limit. Never store DSNs, and never store a failed read as [].
  keys="$(fetch_all "${API}/projects/${SENTRY_ORG}/${p}/keys/")" && [ -n "$keys" ] \
    && printf '%s\n' "$keys" | jq 'map({name, isActive, rateLimit})' > "${d}/keys.json" \
    || { rm -f "${d}/keys.json"; block_read "keys:${p}" "${API}/projects/${SENTRY_ORG}/${p}/keys/" "$bl"; }
  if [ "${SENTRY_ALERT_API}" = legacy ]; then
    # Legacy fallback: this project's issue rules and uptime monitors. On the alerts API the
    # project's alerts and monitors come from the org-wide reads in Phase 1, with no call here.
    read_or_block "rules:${p}" "${API}/projects/${SENTRY_ORG}/${p}/rules/" "${d}/rules.json" "$bl"
    read_or_block "uptime:${p}" "${API}/projects/${SENTRY_ORG}/${p}/uptime/" "${d}/uptime.json" "$bl"
  fi
  awk -F'\t' -v s="$p" 'BEGIN{OFS="\t"} $1==s{$2="done"} 1' "${WORKLIST}" > "${WORKLIST}.tmp" && mv "${WORKLIST}.tmp" "${WORKLIST}"
  echo "done: ${p}"
done

pending=$(awk -F'\t' '$2 == "pending"' "${WORKLIST}" | wc -l | tr -d ' ')
echo "batch complete; worklist pending=${pending}"
```

**Step 4: merge into the date-keyed `RAW_DIR` once the worklist is empty.** Repeat steps 2 and 3 until `pending=0`, then copy the run directory's per-project pulls into the layout Phases 2 through 8 read from:

```bash
set -eu
RUN_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/runs/20260717T140500Z"   # example; this run's resolved RUN_DIR
WORKLIST="${RUN_DIR}/worklist.tsv"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/$(date -u +%Y-%m-%d)/raw"

pending=$(awk -F'\t' '$2 == "pending"' "${WORKLIST}" | wc -l | tr -d ' ')
[ "${pending}" -eq 0 ] || { echo "worklist incomplete (pending=${pending}); do not merge yet, resume batching"; exit 1; }

mkdir -p "${RAW_DIR}/projects"
cp "${RUN_DIR}/raw/projects.json" "${RAW_DIR}/projects.json"
cp -R "${RUN_DIR}/raw/projects/." "${RAW_DIR}/projects/"   # each project's blocked-reads.tsv comes along
# Apply the same operator-PII redaction the small/medium path runs (SKILL.md Phase 1):
# null every `.email` key across the merged raw dump so a leak-scan of the audit dir
# stays clean. No check reads an email, so nothing a check needs is touched.
find "${RAW_DIR}" -name '*.json' -type f | while read -r rf; do
  jq 'walk(if type == "object" and has("email") then .email = null else . end)' "$rf" > "${rf}.red" 2>/dev/null \
    && mv "${rf}.red" "$rf" || rm -f "${rf}.red"
done
echo "merged $(find "${RAW_DIR}/projects" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ') project directories into ${RAW_DIR}"
```

Expect: `worklist incomplete` and a nonzero exit on a partial run; the merge only happens once `pending=0`. After merging, run the org-level fetches (`teams.json`, `integrations.json`, `releases.json`, `monitors.json`, `org.json`, the stats calls, and the alert reads: `workflows.json`, `detectors.json`, and `available-actions.json` on the alerts API, `metric-alerts.json` on the legacy fallback) from the Phase 1 block in [SKILL.md](../SKILL.md#phase-1-inventory) exactly as written, then everything after its per-project loop (the per-project alert views, the redaction pass, the step that adds each project's `blocked-reads.tsv` to this run's list, the counts); they are cheap, make no per-project call, and were never batched. Running the block that way keeps the merged per-project rows: nothing before the loop touches a project's directory.

Rules, same as the large-path map for clusters:

- Cluster-scoped, org-level fetches are never batched; pull each once per run.
- The shared `${RAW_DIR}` for the run's date is populated only once the worklist shows zero pending rows. Findings never claim coverage of a project whose pull is still `pending`.
- A lock covers one batch claim, not the whole run: acquire it right before reading pending rows, release it right after that batch's rows are marked.
- Reclaiming a stale lock is a normal, expected path, not an error: processes die, laptops sleep, sessions get killed. State it plainly and move on.

## Project configuration checks

Snippets for SNTRY-002, SNTRY-003, SNTRY-004.

**SNTRY-002, privacy scrubbing.** Re-fetch project detail and check the scrubber flags and sensitive-fields list:

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

# Project detail carries the project's securityToken: keep the response in memory, never in a file.
resp="$(curl -sS -w '\n%{http_code} %{content_type}' --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/")" || resp="curl-exit-$? $(printf '%s\n' "${resp:-}" | tail -n 1)"
code="$(printf '%s\n' "$resp" | tail -n 1)"
case "$code" in "200 application/json"*) ;; *) echo "SNTRY-002 blocked: ${PROJECT} project detail read returned ${code:-no response}"; exit 0 ;; esac
printf '%s\n' "$resp" | sed '$d' \
  | jq '{ slug, dataScrubber, dataScrubberDefaults, sensitiveFields, scrubIPAddresses, scrapeJavaScript }' \
  | tee /dev/stderr \
  | jq -e '{ dataScrubber, dataScrubberDefaults, sensitiveFields,
             scrubIPAddresses, scrapeJavaScript } as $p
           | ($p.dataScrubber == true) and ($p.dataScrubberDefaults == true)
             and (($p.sensitiveFields | length) > 0) and ($p.scrapeJavaScript == false)' >/dev/null \
  && echo "SNTRY-002 pass: ${PROJECT}" || echo "SNTRY-002 fail: ${PROJECT}"
```

Expect: exit 0 and `SNTRY-002 pass: <project>`. The assertion requires `dataScrubber` and `dataScrubberDefaults` both `true`, a non-empty `sensitiveFields` array, and `scrapeJavaScript` `false`; treat `scrubIPAddresses: false` as a judgment call, not an automatic fail, only when your team has a recorded policy reason to keep IPs. Any production project the assertion fails is a high finding. A refused read (a non-200 or non-JSON response, or no response) prints `SNTRY-002 blocked: <project> project detail read returned <status>`: the project is unassessed, never a pass or a fail.

**Blast radius — quantify what is already stored, do not restate the principle.** "PII that reaches Sentry cannot be unsent" is a scanner line until you attach the volume already retained. Join the failing project's numeric id to `stats-projects.json` accepted-error count for the same window: *"this project accepted E error events in 14d with scrubbing off — E events of raw request bodies, headers, and user context are already retained and unrecoverable."* Reuse the numeric-id volume snippet from SNTRY-001 (same `stats-projects.json`, same `accepted` outcome). When SNTRY-010 shows accepted volume in the replay or profile categories for the same project, **escalate**: session replays carry DOM snapshots and keystrokes — far higher-fidelity PII than an error payload — so the same E is a worse breach. **Correlate:** SNTRY-010 (live replay/profile ingestion raises the PII fidelity), SNTRY-003 (an unlimited key removes the volume ceiling on the unscrubbed ingestion), and SNTRY-105 (no inbound filters means bot/extension junk also lands unscrubbed).

**SNTRY-003, client-key rate limits.** Every active key on every project needs a limit:

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

# Keys carry each key's secret and DSNs: keep the response in memory, never in a file.
resp="$(curl -sS -w '\n%{http_code} %{content_type}' --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/keys/")" || resp="curl-exit-$? $(printf '%s\n' "${resp:-}" | tail -n 1)"
code="$(printf '%s\n' "$resp" | tail -n 1)"
case "$code" in "200 application/json"*) ;; *) echo "SNTRY-003 blocked: ${PROJECT} client keys read returned ${code:-no response}"; exit 0 ;; esac
printf '%s\n' "$resp" | sed '$d' \
  | jq 'map({ name, isActive, rateLimit })' \
  | tee /dev/stderr \
  | jq -e '[ .[] | select(.isActive) ] | all(.rateLimit != null)' >/dev/null \
  && echo "SNTRY-003 pass: ${PROJECT}" || echo "SNTRY-003 fail: ${PROJECT}"
```

Expect: exit 0 and `SNTRY-003 pass: <project>`. `rateLimit: null` on an active key means one crash loop or one leaked DSN can burn the whole project quota; a fail exit files per project with the key names (never the DSN) in `affected`. A refused keys read prints `SNTRY-003 blocked: <project> client keys read returned <status>`: unassessed, never "no unlimited key".

**Blast radius — check whether the burn is already live, do not leave it hypothetical.** An unlimited key that is calm today scores the same as one actively dropping fatal events unless you join it to the org-wide drop outcomes the audit already pulled. Read `stats-outcomes.json` for org-wide `rate_limited`/`abuse`/`cardinality_limited` totals in the window:

```bash
set -eu
STATS="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/$(date -u +%Y-%m-%d)/raw/stats-outcomes.json"
[ -f "$STATS" ] || { echo "SNTRY-003 drop count blocked: org stats-outcomes.json is missing from this run's raw dump (see blocked-reads.tsv); never read as zero drops"; exit 0; }
jq -r '
  [ .groups[]? | select(.by.outcome == "rate_limited" or .by.outcome == "abuse" or .by.outcome == "cardinality_limited")
    | .totals["sum(quantity)"] ] | add // 0
  | "SNTRY-003 org-wide drops to rate_limited/abuse/cardinality in window: \(.) events"' "$STATS"
```

If that count D is nonzero, state the shared-quota mechanism: *"key `<name>` on `<project>` is unlimited AND the org already dropped D events to rate_limited/abuse in 14d — on a shared org quota, one noisy project's crash loop is already crowding out real fatal events from other projects."* If D is zero, state the ceiling honestly: *"unbounded, not yet firing."* A missing `stats-outcomes.json` (its Phase 1 read failed) prints `SNTRY-003 drop count blocked`: D is unknown, never zero. Do **not** attribute the specific D drops to this specific key — the outcomes stats are org-wide and per-key attribution is not provable from `stats_v2`; D is the shared-quota pressure the unlimited key contributes to, not proof this key caused those drops. **Correlate:** SNTRY-008 (the live drop outcomes *are* the shared-quota evidence — same numbers, joined), SNTRY-002 (unlimited + unscrubbed = unbounded PII), SNTRY-105 (filters would relieve the same quota).

**SNTRY-004, environments.** Confirm the environment your production traffic actually runs under exists:

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
ENV_REQUIRED="production"   # example baseline; tune to your promotion flow

envs="$(mktemp)"; trap 'rm -f "$envs"' EXIT
code="$(curl -sS -o "$envs" -w '%{http_code} %{content_type}' --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/environments/")" || code="curl-exit-$? ${code:-}"
case "$code" in "200 application/json"*) ;; *) echo "SNTRY-004 blocked: ${PROJECT} environments read returned ${code:-no response}"; exit 0 ;; esac
tee /dev/stderr < "$envs" \
  | jq -e --arg env "$ENV_REQUIRED" '[ .[] | .name ] | index($env) != null' >/dev/null \
  && echo "SNTRY-004 pass: ${PROJECT}" || echo "SNTRY-004 fail: ${PROJECT}"
```

Expect: exit 0 and `SNTRY-004 pass: <project>`. A project with no matching environment cannot scope alert rules or releases to production, so every rule on it fires on every environment's traffic, dev noise included. A refused read prints `SNTRY-004 blocked: <project> environments read returned <status>`: unassessed, never a missing environment.

## Alert rule checks

Snippets for SNTRY-001, SNTRY-005, SNTRY-011, SNTRY-013, SNTRY-014, and SNTRY-015. Each per-project check re-reads the project's alerts live from `/organizations/{org}/workflows/?project={project}` and, where it must tell issue alerts from metric ones, the project's monitors from `/organizations/{org}/detectors/?project={project}`; SNTRY-005 also reads the live action targets. Set `SENTRY_ALERT_API` at the top of each block to the doctor gate's `alert api:` value: every block reads the alerts API by default and runs its labeled legacy branch (`/projects/{org}/{project}/rules/`, cross-checked against `integrations.json`) only for self-hosted Sentry that still serves it. A read that does not return `200` JSON prints a `blocked` line with its status and stops the block: a project whose alerts could not be read is never judged as a project with no alerts.

**Reading an alert on the alerts API.** An alert (workflow) carries `triggers` (when it evaluates: `triggers.conditions`, or `triggers: null`; empty conditions mean every event), `actionFilters[]` (each holds the `conditions` that gate it and the `actions` it sends), `config.frequency` (re-notify minutes), `environment` (null means every environment), `owner` (`team:<id>` or null), `enabled`, `lastTriggered`, `createdBy` (null when Sentry created it), and `detectorIds` (the monitors it listens to). An issue alert is attached to an issue-stream detector: the project's own, or the org-wide one that `?project=` also returns. A workflow attached only to the project's `metric_issue` or `uptime_domain_failure` monitor is the notifying half of a metric or uptime alert; its triggers are empty by design, so the issue-alert checks below leave it out. Rules Sentry migrated from the legacy API keep frequency conditions in `triggers` (logic `all`), while alerts made in the new UI put them in `actionFilters`, so every check reads conditions from both places. An org-wide alert appears in every project's list, so when one fails a per-project check it fails that check on every project: file it once, naming the alert in `affected`, not once per project.

**Condition and filter reference**, needed to classify each alert into a tier and to catch the environment-scoping bug:

| Signal | Alerts API `type` (where it sits) | Legacy fallback id | Tier signal |
| --- | --- | --- | --- |
| Any event | empty `triggers.conditions`, or `every_event` (trigger) | `sentry.rules.conditions.every_event.EveryEventCondition` | immediate only when paired with a level filter; every-event with no filter and a paging action is noise (SNTRY-014) |
| New issue | `first_seen_event` (trigger) | `sentry.rules.conditions.first_seen_event.FirstSeenEventCondition` | review |
| Regression | `regression_event` (trigger) | `sentry.rules.conditions.regression_event.RegressionEventCondition` | immediate |
| Escalation (an archived issue escalates) | `reappeared_event` (trigger) | `sentry.rules.conditions.reappeared_event.ReappearedEventCondition` | immediate |
| Event frequency > N in interval | `event_frequency_count`, `event_frequency_percent` (filter; trigger on migrated rules) | `sentry.rules.conditions.event_frequency.EventFrequencyCondition` | immediate when interval is short and threshold is business-relevant |
| Unique users > N in interval | `event_unique_user_frequency_count`, `event_unique_user_frequency_percent` (same) | `sentry.rules.conditions.event_frequency.EventUniqueUserFrequencyCondition` | immediate |
| Session/event percent > N% | `percent_sessions_count`, `percent_sessions_percent` (same) | `sentry.rules.conditions.event_frequency.EventFrequencyPercentCondition` | immediate |
| High priority, new issue | `new_high_priority_issue` (trigger; migrated rules only, new alerts cannot use it) | `sentry.rules.conditions.high_priority_issue.NewHighPriorityIssueCondition` | immediate |
| High priority, existing issue | `existing_high_priority_issue` (trigger; migrated rules only) | `sentry.rules.conditions.high_priority_issue.ExistingHighPriorityIssueCondition` | review |

Escalation is `reappeared_event` (legacy `ReappearedEventCondition`). Sentry has no `EscalatingEventCondition`, so a check that matches that name never matches anything.

| Filter | Alerts API condition (`actionFilters[].conditions[]`) | Legacy fallback | Reading it correctly |
| --- | --- | --- | --- |
| Level | `level` with `comparison: {level, match}`: `level` is an integer (50 fatal, 40 error, 30 warning, 20 info, 10 debug), `match` is `eq`, `gte`, or `lte` | `sentry.rules.filters.level.LevelFilter` with `level` and `match` | A level gate is what turns an every-event trigger into a fatal-only page |
| Error is unhandled | `event_attribute` with `comparison: {attribute: "error.unhandled", match: "is"}`; `is` and `ns` take no `value` | `sentry.rules.filters.event_attribute.EventAttributeFilter`, `attribute: "error.unhandled"`, `match: "is"` | A rule using `match: "eq"` here is misconfigured, not merely undocumented; file it as a noise or coverage defect depending on direction |
| HTTP status starts with 5 | `event_attribute` with `comparison: {attribute: "http.status_code", match: "sw", value: "5"}` | `EventAttributeFilter`, `attribute: "http.status_code"`, `match: "sw"`, `value` as an integer | On the alerts API `value` is always a string; only the legacy API wanted an integer, where a string `value` silently never matched |
| Issue category | `issue_category` with `comparison: {value, include}` | `sentry.rules.filters.issue_category.IssueCategoryFilter` | narrows by issue type, not environment |
| Release-adoption stage | `latest_adopted_release` | `sentry.rules.filters.latest_adopted_release.LatestAdoptedReleaseFilter` | filters by whether the release has reached an adoption stage, **not** by environment. A rule using this filter with an `environment` field set is not environment-scoped by it; the only true environment scope on an issue rule is the rule object's own top-level `environment` field. Treat any rule that relies on this filter to mean "production only" as a coverage defect: it fires on every environment. |

**SNTRY-001, default auto-created rule.** Sentry auto-creates a "Send a notification for high priority issues" alert on projects created without `defaultRules: false`, and marks it `createdBy: null`. On the alerts API its triggers are the migrated `new_high_priority_issue` and `existing_high_priority_issue`, and its one action emails issue owners:

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
SENTRY_ALERT_API="workflows" # the doctor gate's "alert api:" value
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

if [ "${SENTRY_ALERT_API}" = workflows ]; then
  wf="$(mktemp)"; trap 'rm -f "$wf"' EXIT
  code="$(curl -sS -o "$wf" -w '%{http_code} %{content_type}' --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    "${API}/organizations/${SENTRY_ORG}/workflows/?project=${PROJECT}&per_page=100" || true)"
  case "$code" in "200 application/json"*) ;; *) echo "SNTRY-001 blocked: ${PROJECT} alerts read returned ${code:-no response}"; exit 0 ;; esac
  [ "$(jq 'length' "$wf")" -lt 100 ] || { echo "SNTRY-001 blocked: ${PROJECT} has 100+ alerts; judge raw/projects/${PROJECT}/workflows.json instead"; exit 0; }
  tee /dev/stderr < "$wf" \
    | jq -e '[ .[] | [(.triggers.conditions // [])[].type] as $t | [(.actionFilters // [])[].actions[]] as $a
        | select(.createdBy == null and ((.name | test("high priority"; "i"))
            or (($t | length) > 0 and ($t - ["new_high_priority_issue", "existing_high_priority_issue"] | length) == 0
                and ($a | length) == 1 and $a[0].type == "email" and $a[0].config.targetType == "issue_owners"))) ]
        | length == 0' >/dev/null \
    && echo "SNTRY-001 pass: ${PROJECT}" || echo "SNTRY-001 fail: ${PROJECT}"
else
  # Legacy fallback (self-hosted Sentry that still serves /rules/):
  curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
    | tee /dev/stderr \
    | jq -e '[ .[] | select(.createdBy == null and (.name | test("high priority"; "i"))) ] | length == 0' \
      >/dev/null \
    && echo "SNTRY-001 pass: ${PROJECT}" || echo "SNTRY-001 fail: ${PROJECT}"
fi
```

Expect: exit 0 and `SNTRY-001 pass: <project>`. A nonzero-length match (`SNTRY-001 fail`) is the finding: an unowned `createdBy == null` high-priority alert whose email action goes to issue owners and falls through to every active member (`data.fallthroughType`; legacy: a `NotifyEmailAction`). `SNTRY-001 blocked` means the project's alerts could not be read: record the status as evidence, never a pass.

**Blast radius — compute the fan-out, never assert it.** The pass/fail above finds the unowned rule; the finding's blast radius is the fan-out it causes, and both numbers are already in the estate this run pulled. Join the org member count with this project's accepted-error volume: *"the unowned high-priority rule pages all N org members on every high-priority issue; this project accepted E error events in the 14d window, so it is E pages fanned to N inboxes — the mechanism that trains the whole org to filter Sentry to a folder."* The member count needs `member:read`, which is an **optional** ownership add-on in the doctor gate, not the base `org:read`+`project:read`+`alerts:read` recipe, so the fan-out quantifier degrades to `blocked` on a 403 while the `createdBy == null` finding still stands on its own — never emit a fabricated member count N:

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

# Member count for the fan-out. 403 => member:read absent: file the fan-out sub-part
# blocked, never invent N. The createdBy==null finding above does not depend on this.
mem="$(mktemp)"
code=$(curl -s -o "$mem" -w '%{http_code}' --max-time 15 \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" "${API}/organizations/${SENTRY_ORG}/members/")
if [ "$code" = "200" ]; then
  echo "org members: $(jq 'length' "$mem")"
elif [ "$code" = "403" ]; then
  echo "SNTRY-001 fan-out sub-part blocked: member:read absent (http 403); report the unowned rule without a member count"
else
  echo "SNTRY-001 member count blocked: members read returned ${code}"
fi
rm -f "$mem"

# Accepted-error volume for THIS project, by NUMERIC id (never a slug search), from stats-projects.json.
PROJECT_ID="42"   # resolve from projects.json by slug; stats_v2 groups by numeric project id
STATS="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/$(date -u +%Y-%m-%d)/raw/stats-projects.json"
jq -r --arg pid "$PROJECT_ID" '
  [ .groups[]? | select((.by.project | tostring) == $pid) | select(.by.outcome == "accepted")
    | .totals["sum(quantity)"] ] | add // 0
  | "SNTRY-001 accepted-error volume for project \($pid): \(.) events in window"' "$STATS"
```

**Correlate:** SNTRY-001 chains with SNTRY-014 (it is the canonical un-tuned noise source) and with SNTRY-005/SNTRY-013 — if this default rule is the *only* rule on the project, the noise finding and the "no immediate tier reaching a live receiver" finding are the same gap seen twice; say so and rank them as one story.

**SNTRY-005, receiver liveness.** Cross-check every alert action against the integrations Sentry offers as live action targets. An action is proven only when its integration is among them (`/organizations/{org}/available-actions/` lists only installed, usable integrations, per action type):

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
SENTRY_ALERT_API="workflows" # the doctor gate's "alert api:" value
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

if [ "${SENTRY_ALERT_API}" = workflows ]; then
  TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
  # The project's alerts, and the integrations each action type can reach right now.
  for r in "workflows/?project=${PROJECT}&per_page=100" "available-actions/"; do
    code="$(curl -sS -o "${TMPD}/${r%%/*}.json" -w '%{http_code} %{content_type}' --max-time 30 \
      -H "Authorization: Bearer ${SENTRY_TOKEN}" "${API}/organizations/${SENTRY_ORG}/${r}" || true)"
    case "$code" in "200 application/json"*) ;; *) echo "SNTRY-005 blocked: ${PROJECT} ${r%%/*} read returned ${code:-no response}"; exit 0 ;; esac
  done
  [ "$(jq 'length' "${TMPD}/workflows.json")" -lt 100 ] || { echo "SNTRY-005 blocked: ${PROJECT} has 100+ alerts; judge raw/projects/${PROJECT}/workflows.json instead"; exit 0; }
  tee /dev/stderr < "${TMPD}/workflows.json" \
    | jq --slurpfile aa "${TMPD}/available-actions.json" '
        ($aa[0] | map({key: .type, value: [(.integrations // [])[].id | tostring]}) | from_entries) as $live
        | [ .[] | . as $w | (.actionFilters // [])[].actions[]
            | .type as $t | ((.integrationId // "") | tostring) as $i
            | { alert: $w.id, name: $w.name, type: $t, integration_id: .integrationId,
                live_target: (
                  if $t == "email" then "email"
                  elif ($t | IN("slack", "msteams", "discord")) and ((.config.targetIdentifier // "") != "") then "chat-with-channel-id"
                  elif ($t | IN("slack", "msteams", "discord")) then "chat-name-only"
                  else "other" end),
                live: ([($live[$t] // [])[] | select(. == $i)] | length > 0) } ]' > "${TMPD}/actions.json"
  jq -e '[ .[] | select(.live_target == "chat-with-channel-id" or .live_target == "other") | select(.live | not) ]
      | length == 0' "${TMPD}/actions.json" >/dev/null \
    && echo "SNTRY-005 pass: ${PROJECT} (every non-email action resolves to a live integration)" \
    || echo "SNTRY-005 fail: ${PROJECT} (one or more actions reference a missing or inactive integration)"
else
  # Legacy fallback (self-hosted Sentry that still serves /rules/). INTEGRATIONS_JSON: re-fetch
  # or point at this run's raw dump, e.g. ./scoutflo-audits/sentry/$(date -u +%Y-%m-%d)/raw/integrations.json
  INTEGRATIONS_JSON="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/$(date -u +%Y-%m-%d)/raw/integrations.json"
  [ -s "${INTEGRATIONS_JSON}" ] || curl -fsS --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    "${API}/organizations/${SENTRY_ORG}/integrations/" > "${INTEGRATIONS_JSON}"

  rules_tmp="$(mktemp)"
  curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
    | tee /dev/stderr \
    | jq '[ .[] | { id, name,
          actions: [ .actions[] | {
            id, kind: (.id | split(".") | .[2] // .id),
            integration_id: (.workspace // .account // null),
            live_target: (
              if (.id | test("mail\\.")) then "email"
              elif has("channel_id") and (.channel_id != null) then "chat-with-channel-id"
              elif has("channel") then "chat-name-only"
              else "other" end
            ) } ] } ]' > "${rules_tmp}"

  jq -e --slurpfile ints "${INTEGRATIONS_JSON}" '
    (($ints[0] // []) | map(select(.status == "active") | .id)) as $active
    | [ .[] | .actions[] | select(.live_target == "chat-with-channel-id" or .live_target == "other")
        | select(.integration_id as $id | ($id == null or ($active | index($id)) == null)) ] as $dead
    | ($dead | length == 0)' "${rules_tmp}" >/dev/null \
    && echo "SNTRY-005 pass: ${PROJECT} (every non-email action resolves to an active integration)" \
    || echo "SNTRY-005 fail: ${PROJECT} (one or more actions reference a missing or inactive integration)"
  rm -f "${rules_tmp}"
fi
```

Reading order for a fail:

- `email` actions are `configured`, a temporary path; credit them as present, never as a proven paging route on their own.
- `chat-with-channel-id` with a live integration is the strongest signal short of a delivered notification. On the alerts API the channel id is `config.targetIdentifier` and the display name `config.targetDisplay`.
- `chat-name-only` (a channel name with no ID) cannot be resolved from this API alone; treat as unproven and note the gap.
- An action whose integration is not among the live action targets for its type (legacy fallback: an integration `id` absent from `integrations.json`, or present but not `active`) is a dead route: the rule looks configured and delivers nothing.

An org where every rule's only actions are email, or reference dead integrations, is critical: incidents fire and nobody finds out through a channel anyone actually watches.

**SNTRY-013, tier coverage.** For each production project, bucket its enabled issue alerts by the condition table above into immediate versus review, and check environment scope using the alert's own `environment` field, not any filter:

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
SENTRY_ALERT_API="workflows" # the doctor gate's "alert api:" value
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
# Tier signals from the condition table above; immediate first, review second.
IMMEDIATE_TYPES='["regression_event","reappeared_event","new_high_priority_issue","event_frequency_count","event_frequency_percent","event_unique_user_frequency_count","event_unique_user_frequency_percent","percent_sessions_count","percent_sessions_percent"]'
REVIEW_TYPES='["first_seen_event","existing_high_priority_issue"]'
IMMEDIATE_RE='RegressionEventCondition|ReappearedEventCondition|EventFrequencyCondition|EventUniqueUserFrequencyCondition|EventFrequencyPercentCondition|NewHighPriorityIssueCondition'   # legacy fallback ids
REVIEW_RE='FirstSeenEventCondition|ExistingHighPriorityIssueCondition'                                                                                                  # legacy fallback ids

if [ "${SENTRY_ALERT_API}" = workflows ]; then
  TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
  for r in workflows detectors; do
    code="$(curl -sS -o "${TMPD}/${r}.json" -w '%{http_code} %{content_type}' --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
      "${API}/organizations/${SENTRY_ORG}/${r}/?project=${PROJECT}&per_page=100" || true)"
    case "$code" in "200 application/json"*) ;; *) echo "SNTRY-013 blocked: ${PROJECT} ${r} read returned ${code:-no response}"; exit 0 ;; esac
    [ "$(jq 'length' "${TMPD}/${r}.json")" -lt 100 ] || { echo "SNTRY-013 blocked: ${PROJECT} has 100+ ${r}; judge raw/projects/${PROJECT}/${r}.json instead"; exit 0; }
  done
  tee /dev/stderr < "${TMPD}/workflows.json" \
    | jq -e --slurpfile det "${TMPD}/detectors.json" --argjson imm "$IMMEDIATE_TYPES" --argjson rev "$REVIEW_TYPES" '
        [$det[0][] | select(.type != "issue_stream") | .id] as $monitors
        | [ .[] | select(.enabled == true)
                | select(any((.detectorIds // [])[]; IN($monitors[]) | not))
                | [((.triggers.conditions // [])[], ((.actionFilters // [])[].conditions[])) | .type] ] as $alerts
        | ($alerts | any(any(.[]; IN($imm[])))) and ($alerts | any(any(.[]; IN($rev[]))))' >/dev/null \
    && echo "SNTRY-013 pass: ${PROJECT} (has immediate-tier and review-tier rules)" \
    || echo "SNTRY-013 fail: ${PROJECT} (missing at least one tier)"
else
  # Legacy fallback (self-hosted Sentry that still serves /rules/):
  curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
    | tee /dev/stderr \
    | jq -e --arg imm "$IMMEDIATE_RE" --arg rev "$REVIEW_RE" '
        [ .[] | select((.status // "active") == "active")
              | { environment: (.environment // "all"), conditions: [ .conditions[].id ] } ] as $rules
        | ($rules | any(.conditions | any(test($imm)))) as $has_immediate
        | ($rules | any(.conditions | any(test($rev)))) as $has_review
        | $has_immediate and $has_review' >/dev/null \
    && echo "SNTRY-013 pass: ${PROJECT} (has immediate-tier and review-tier rules)" \
    || echo "SNTRY-013 fail: ${PROJECT} (missing at least one tier)"
fi
```

Expect: exit 0 and `SNTRY-013 pass: <project>`. The assertion checks tier presence only; still confirm by eye that each tier's `environment` is set to your production environment name or intentionally `all` on a single-environment project. A project with only review-tier conditions, or with every rule scoped to `all` on a multi-environment project, is a coverage gap. `SNTRY-013 blocked` means the read failed: the project is unassessed, not uncovered.

**Tier presence excludes disabled alerts (gated by SNTRY-016).** The `select(.enabled == true)` filter above (legacy fallback: `select((.status // "active") == "active")`) is load-bearing: without it a disabled immediate alert would still satisfy tier presence, so a project reads as covered while the alert that is supposed to page fires nothing. SNTRY-013 and SNTRY-016 must agree on the same estate — a disabled immediate alert that this filter drops from tier coverage is exactly what SNTRY-016 files as a finding. If you ever loosen this filter, SNTRY-016 and SNTRY-013 disagree and a switched-off alert silently credits coverage again.

**SNTRY-014, noise posture.** From the same alert read, issue alerts only:

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
SENTRY_ALERT_API="workflows" # the doctor gate's "alert api:" value
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
FREQ_FLOOR_MIN="30"   # example, tune to your event volume

if [ "${SENTRY_ALERT_API}" = workflows ]; then
  TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
  for r in workflows detectors; do
    code="$(curl -sS -o "${TMPD}/${r}.json" -w '%{http_code} %{content_type}' --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
      "${API}/organizations/${SENTRY_ORG}/${r}/?project=${PROJECT}&per_page=100" || true)"
    case "$code" in "200 application/json"*) ;; *) echo "SNTRY-014 blocked: ${PROJECT} ${r} read returned ${code:-no response}"; exit 0 ;; esac
    [ "$(jq 'length' "${TMPD}/${r}.json")" -lt 100 ] || { echo "SNTRY-014 blocked: ${PROJECT} has 100+ ${r}; judge raw/projects/${PROJECT}/${r}.json instead"; exit 0; }
  done
  # Every-event = no trigger conditions (or an every_event trigger); frequency is config.frequency, in minutes.
  tee /dev/stderr < "${TMPD}/workflows.json" \
    | jq -e --slurpfile det "${TMPD}/detectors.json" --argjson floor "$FREQ_FLOOR_MIN" '
        [$det[0][] | select(.type != "issue_stream") | .id] as $monitors
        | [ .[] | select(.enabled == true)
                | select(any((.detectorIds // [])[]; IN($monitors[]) | not))
                | select(
                    (((((.triggers.conditions // []) | length) == 0) or any((.triggers.conditions // [])[]; .type == "every_event"))
                      and (([(.actionFilters // [])[].conditions[]] | length) == 0))
                    or ((.config.frequency // 30) < $floor)) ]
        | length == 0' >/dev/null \
    && echo "SNTRY-014 pass: ${PROJECT}" || echo "SNTRY-014 fail: ${PROJECT}"
else
  # Legacy fallback (self-hosted Sentry that still serves /rules/):
  curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
    | tee /dev/stderr \
    | jq -e --argjson floor "$FREQ_FLOOR_MIN" '
      [ .[] | select(
          (.conditions | any(.id | test("EveryEventCondition"))) and (.filters | length == 0)
          or (.frequency // 999999) < $floor
        ) ] | length == 0' >/dev/null \
    && echo "SNTRY-014 pass: ${PROJECT}" || echo "SNTRY-014 fail: ${PROJECT}"
fi
```

Expect: exit 0 and `SNTRY-014 pass: <project>`. A fail is either an unfiltered every-event condition with a paging action (pages on every single error at any level) or a re-page frequency below your floor (repeatedly re-pages the same open issue). Both train responders to mute the channel. A `frequency` of `0` re-notifies on every match.

Legacy fallback only: a rule migrated to Sentry's workflow model can come back from `/rules/` with both `conditions: []` and `filters: []` yet carry a non-empty `errors` array (for example `"Filter not supported: issue_priority_greater_or_equal"`) — confirmed live. Read as literally empty conditions/filters, the legacy jq would flag it as an unconditioned catch-all every time; check for a populated `errors` array first and treat that case as "condition present but not representable in this API view," not proven noise, before scoring SNTRY-014 fail on it. The alerts API returns the real conditions, so this case does not arise there.

**SNTRY-015, monitor-to-alert wiring.** On the alerts API a monitor (detector) notifies only through the alerts (workflows) connected to it, so read both org-wide lists once. **Exclude the built-in `error` and `issue_stream` detector types (grounded live):** every project carries one of each, and issue alerts attach to the issue-stream one; an empty `workflowIds` on them is by design. A remaining enabled monitor with `workflowIds == []` has no alert of its own, but Sentry also runs a project's issue alerts on the issues a monitor opens (unless Sentry has turned that off for the issue type, which the API does not show), so join those before calling it silent. Then list the mirror image: an enabled alert with `detectorIds == []` listens to no monitor and never fires (live: migrated metric alerts whose monitor is gone). Capture `config.mode` where present (3 = auto-detected) for remediation framing:

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
SENTRY_ALERT_API="workflows" # the doctor gate's "alert api:" value
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

if [ "${SENTRY_ALERT_API}" = legacy ]; then
  echo "SNTRY-015 not-in-scope: the legacy alert API has no monitors to wire; SNTRY-001/005 cover the no-receiver case"
  exit 0
fi
fetch_all() { # $1: full API URL. Follows cursor pagination, prints one merged JSON array.
  url="$1"; hdr="$(mktemp)"; acc="$(mktemp)"
  while [ -n "$url" ]; do
    curl -fsS --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" -D "$hdr" "$url" >> "$acc" \
      || { rm -f "$hdr" "$acc"; return 1; }
    printf '\n' >> "$acc"
    url="$(tr -d '\r' < "$hdr" | sed -n 's/.*<\([^>]*\)>; rel="next"; results="true".*/\1/p')"
  done
  jq -s 'add // []' "$acc"; rm -f "$hdr" "$acc"
}
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
for r in detectors workflows; do
  fetch_all "${API}/organizations/${SENTRY_ORG}/${r}/" > "${TMPD}/${r}.json" \
    || { echo "SNTRY-015 blocked: ${r} read failed (status in the curl error above); not a pass"; exit 0; }
done
# Monitors with no alert of their own. "silent" when their project (and the org) has no enabled
# issue alert with an action; "unproven" when one exists that may still match their issues.
jq -r --slurpfile wf "${TMPD}/workflows.json" '
  ([.[] | select(.type == "issue_stream") | {key: .id, value: (.projectId // "org")}] | from_entries) as $stream
  | ([$wf[0][] | select(.enabled == true and ([(.actionFilters // [])[].actions[]] | length) > 0)
      | (.detectorIds // [])[] | $stream[.] // empty] | unique) as $notified
  | .[] | select(.type != "error" and .type != "issue_stream")
  | select(.enabled == true and ((.workflowIds // []) | length) == 0)
  | (.projectId // "org") as $p
  | if ([$notified[] | select(. == $p or . == "org")] | length) > 0
    then "SNTRY-015 unproven: monitor \(.id) (\(.type), mode \(.config.mode // "n/a")) has no alert of its own; only an issue alert on its project that matches its issues reaches anyone"
    else "SNTRY-015 silent: monitor \(.id) (\(.type), mode \(.config.mode // "n/a")) has no alert and its project has no enabled issue alert with an action: it notifies nobody" end' \
  "${TMPD}/detectors.json"
# The mirror image: enabled alerts connected to no monitor never fire.
jq -r '.[] | select(.enabled == true and ((.detectorIds // []) | length) == 0)
  | "SNTRY-015 detached: alert \(.id) is enabled but listens to no monitor, so it never fires"' "${TMPD}/workflows.json"
```

Expect: no rows on a well-wired org. A `silent` row is a fail object (high): the monitor detects and nobody hears. An `unproven` row is partial: it reaches people only if one of its project's issue alerts happens to match its issues, which nothing guarantees. A `detached` row is a fail object: an alert that looks configured and can never fire. Name every monitor and alert in `affected`. `blocked` means a read failed and the check is unassessed; on the legacy fallback the check is `not-in-scope`. Uptime lives here as a detector `type` of `uptime_domain_failure`, not a separate endpoint.

**SNTRY-011, duplicate paths.** Compare condition sets across a project's own enabled issue alerts, and compare its issue alerts against any metric monitor on the same signal (the project's `metric_issue` detectors; legacy fallback `metric-alerts.json`):

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
SENTRY_ALERT_API="workflows" # the doctor gate's "alert api:" value
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

if [ "${SENTRY_ALERT_API}" = workflows ]; then
  TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
  for r in workflows detectors; do
    code="$(curl -sS -o "${TMPD}/${r}.json" -w '%{http_code} %{content_type}' --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
      "${API}/organizations/${SENTRY_ORG}/${r}/?project=${PROJECT}&per_page=100" || true)"
    case "$code" in "200 application/json"*) ;; *) echo "SNTRY-011 blocked: ${PROJECT} ${r} read returned ${code:-no response}"; exit 0 ;; esac
    [ "$(jq 'length' "${TMPD}/${r}.json")" -lt 100 ] || { echo "SNTRY-011 blocked: ${PROJECT} has 100+ ${r}; judge raw/projects/${PROJECT}/${r}.json instead"; exit 0; }
  done
  # Key: every trigger and filter condition with its comparison, sorted, plus the environment.
  tee /dev/stderr < "${TMPD}/workflows.json" \
    | jq -e --slurpfile det "${TMPD}/detectors.json" '
        [$det[0][] | select(.type != "issue_stream") | .id] as $monitors
        | [ .[] | select(.enabled == true)
                | select(any((.detectorIds // [])[]; IN($monitors[]) | not))
                | { id, name,
                    key: (([((.triggers.conditions // [])[], ((.actionFilters // [])[].conditions[]))
                            | "\(.type):\(.comparison | tojson)"] | sort | join("|")) + "@" + (.environment // "all")) } ]
        | group_by(.key) | map(select(length > 1)) | length == 0' >/dev/null \
    && echo "SNTRY-011 pass: ${PROJECT}" || echo "SNTRY-011 fail: ${PROJECT}"
else
  # Legacy fallback (self-hosted Sentry that still serves /rules/):
  curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
    | tee /dev/stderr \
    | jq -e '[ .[] | { id, name,
        key: ([ .conditions[].id ] | sort | join(",")) } ]
      | group_by(.key) | map(select(length > 1)) | length == 0' >/dev/null \
    && echo "SNTRY-011 pass: ${PROJECT}" || echo "SNTRY-011 fail: ${PROJECT}"
fi
```

Expect: exit 0 and `SNTRY-011 pass: <project>`. A fail means two alerts share the exact same condition set in the same environment and both page on the same trigger.

**Blast radius — name the receiver being doubled, do not stop at "double-page."** "Two rules share a condition set" does not tell the reader whether it doubles one on-call's pages or is harmless. Resolve both duplicate alerts' actions to their integration ids (the SNTRY-005 join above extracts `integration_id` per action) and name the shared target: *"rules R1 and R2 on `<project>` carry the same condition set and both route to Slack integration id X / PagerDuty service Y — one incident fires two pages to the same on-call."* For an issue-alert-versus-metric-alert overlap (an issue alert and a `metric_issue` monitor's alert on the same signal), note that the two pages **cannot be deduplicated**: they originate from different object types with no shared fingerprint, so grouping never collapses them. **Correlate:** SNTRY-005 (the shared receiver is the join key), SNTRY-014 (contributes to the same responder-fatigue story), SNTRY-103 (a metric alert is the other half of an issue/metric overlap). Also check the project's uptime monitors (`uptime_domain_failure` detectors; legacy fallback `uptime.json`): a Sentry uptime monitor duplicating an external synthetic tool your team already treats as the source of truth is the same class of defect; record which tool wins in the finding.

### Disabled/muted rules and owner-routing gaps (SNTRY-016, SNTRY-017)

> **Live-verified (read-only).** Both checks below were run read-only against a live Sentry org: every alert and monitor carries a boolean `enabled` (SNTRY-016 flags `enabled: false`), and the project ownership endpoint returns 200 with an ownership document (SNTRY-017). The mechanisms are proven on a real tenant; the findings themselves still reflect that org's actual state each run.

**SNTRY-016, disabled or muted rules that make tier coverage falsely pass.** SNTRY-013 credits tier coverage only from enabled alerts. This check surfaces the disabled ones it excludes, so the two agree on the same estate. The issue-alert half (command 1) is the load-bearing gate; the metric half (command 2) reads `enabled` on the project's `metric_issue` monitors:

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
SENTRY_ALERT_API="workflows" # the doctor gate's "alert api:" value
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

if [ "${SENTRY_ALERT_API}" = workflows ]; then
  TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
  for r in workflows detectors; do
    code="$(curl -sS -o "${TMPD}/${r}.json" -w '%{http_code} %{content_type}' --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
      "${API}/organizations/${SENTRY_ORG}/${r}/?project=${PROJECT}&per_page=100" || true)"
    case "$code" in "200 application/json"*) ;; *) echo "SNTRY-016 blocked: ${PROJECT} ${r} read returned ${code:-no response}"; exit 0 ;; esac
    [ "$(jq 'length' "${TMPD}/${r}.json")" -lt 100 ] || { echo "SNTRY-016 blocked: ${PROJECT} has 100+ ${r}; judge raw/projects/${PROJECT}/${r}.json instead"; exit 0; }
  done
  # Command 1 (load-bearing): disabled issue alerts.
  tee /dev/stderr < "${TMPD}/workflows.json" \
    | jq -r --slurpfile det "${TMPD}/detectors.json" '
        [$det[0][] | select(.type != "issue_stream") | .id] as $monitors
        | .[] | select(any((.detectorIds // [])[]; IN($monitors[]) | not))
        | select(.enabled == false)
        | "\(.id)\t\(.name)\tenabled=false\tactions=\([(.actionFilters // [])[].actions[]] | length)\tconditions=\([((.triggers.conditions // [])[], ((.actionFilters // [])[].conditions[])) | .type] | join(","))"'
  # Command 2 (metric half): disabled metric monitors on this project.
  jq -r '.[] | select(.type == "metric_issue" and .enabled == false) | "\(.id)\t\(.name)\tmetric monitor enabled=false"' \
    "${TMPD}/detectors.json"
else
  # Legacy fallback (self-hosted Sentry that still serves the legacy routes). Each half is judged
  # right after its own read; a refused read blocks only its own half.
  TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
  code="$(curl -sS -o "${TMPD}/rules.json" -w '%{http_code} %{content_type}' --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/")" || code="curl-exit-$? ${code:-}"
  case "$code" in
    "200 application/json"*)
      # Command 1 (load-bearing): issue rules whose status is not active. `status` on an issue
      # rule is the string "active"/"disabled"; default to active when the key is absent.
      tee /dev/stderr < "${TMPD}/rules.json" \
        | jq -r '.[] | select((.status // "active") != "active")
            | "\(.id)\t\(.name)\tstatus=\(.status)\tactions=\((.actions|length))\tconditions=\([.conditions[]?.id]|join(","))"' ;;
    *) echo "SNTRY-016 blocked: ${PROJECT} rules read returned ${code:-no response}" ;;
  esac
  code="$(curl -sS -o "${TMPD}/metric-alerts.json" -w '%{http_code} %{content_type}' --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    "${API}/organizations/${SENTRY_ORG}/alert-rules/")" || code="curl-exit-$? ${code:-}"
  case "$code" in
    "200 application/json"*)
      # Command 2 (metric-alert half): the legacy metric-alert `status` is a numeric enum (observed
      # `0` on active rules), so this guard only compares a string `status` and reports nothing on
      # numeric data rather than a wrong result; the disabled-enum value stays verify-pending.
      jq -r '.[] | select((.status | type) == "string" and (.status | ascii_downcase) != "active")
          | "\(.name)\tstatus=\(.status)"' "${TMPD}/metric-alerts.json" ;;
    *) echo "SNTRY-016 metric half blocked: org metric alert rules read returned ${code:-no response}" ;;
  esac
fi
# Any row is an alert that is present but switched off: it fires nothing. Cross-check the
# row's conditions against the SNTRY-013 immediate/review tiers; a disabled immediate-tier
# alert on a production project is the finding.
```

Healthy: both commands print no rows (every alert and metric monitor is enabled). Fail (SNTRY-016, high): a disabled alert whose conditions match an immediate or review tier — quantify with the SNTRY-001 accepted-error volume snippet for the project (*"checkout's only regression rule is disabled, so a fatal regression matches a switched-off rule and pages nobody; this project accepted E errors in the window and the coverage matrix currently scores it green"*). `SNTRY-016 blocked` means the alerts read (legacy fallback: the issue-rules read) failed (a non-200 or non-JSON response, a transfer that failed, or no response), never "nothing is disabled". On the legacy fallback a refused metric-alert read prints `SNTRY-016 metric half blocked` and the issue-rule rows still stand. **Correlate:** SNTRY-016 directly gates SNTRY-013 (tier presence excludes disabled alerts) and SNTRY-012 (a disabled immediate rule is functionally no coverage); it chains with SNTRY-005 into the silent-incident flagship. Remediation `setup-sentry#alert-rule-taxonomy`; verification: re-GET `/organizations/{org}/workflows/{id}/` → the alert crediting the tier has `enabled == true` (legacy fallback: re-GET `/projects/{org}/{project}/rules/` → `status == "active"`).

**SNTRY-017, rules route to issue owners but the project has no ownership rules.** An email action to issue owners (`config.targetType: issue_owners`; legacy `targetType: IssueOwners`) delegates delivery to whoever owns the matching code path; with no ownership rules, delivery falls through per the action's fallthrough setting — to every member (noise, mirrors SNTRY-001) or, with fallthrough off, to nobody (silent):

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
SENTRY_ALERT_API="workflows" # the doctor gate's "alert api:" value
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

# Rules that route to issue owners.
if [ "${SENTRY_ALERT_API}" = workflows ]; then
  wf="$(mktemp)"; trap 'rm -f "$wf"' EXIT
  code="$(curl -sS -o "$wf" -w '%{http_code} %{content_type}' --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    "${API}/organizations/${SENTRY_ORG}/workflows/?project=${PROJECT}&per_page=100" || true)"
  case "$code" in "200 application/json"*) ;; *) echo "SNTRY-017 blocked: ${PROJECT} alerts read returned ${code:-no response}"; exit 0 ;; esac
  [ "$(jq 'length' "$wf")" -lt 100 ] || { echo "SNTRY-017 blocked: ${PROJECT} has 100+ alerts; judge raw/projects/${PROJECT}/workflows.json instead"; exit 0; }
  tee /dev/stderr < "$wf" \
    | jq -r '.[] | . as $r | (.actionFilters // [])[].actions[]
        | select(.type == "email" and .config.targetType == "issue_owners")
        | "\($r.id)\t\($r.name)\ttargetType=issue_owners\tfallthrough=\(.data.fallthroughType // "unset")"'
else
  # Legacy fallback (self-hosted Sentry that still serves /rules/):
  rl="$(mktemp)"; trap 'rm -f "$rl"' EXIT
  code="$(curl -sS -o "$rl" -w '%{http_code} %{content_type}' --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/")" || code="curl-exit-$? ${code:-}"
  case "$code" in "200 application/json"*) ;; *) echo "SNTRY-017 blocked: ${PROJECT} rules read returned ${code:-no response}"; exit 0 ;; esac
  tee /dev/stderr < "$rl" \
    | jq -r '.[] | . as $r | .actions[]? | select((.targetType // "") == "IssueOwners")
        | "\($r.id)\t\($r.name)\ttargetType=IssueOwners"'
fi

# Ownership raw rules + fallthrough posture. Live-verified: /ownership/ returns 200 with `raw`
# and a boolean `fallthrough` (the `fallthroughChoice` fallback below is kept for older orgs).
own="$(mktemp)"
code=$(curl -s -o "$own" -w '%{http_code}' --max-time 15 \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" "${API}/projects/${SENTRY_ORG}/${PROJECT}/ownership/")
if [ "$code" = "200" ]; then
  jq -r '{raw_empty: ((.raw // "") | length == 0), fallthrough: (.fallthrough // .fallthroughChoice // null), autoAssignment: (.autoAssignment // null)}' "$own"
elif [ "$code" = "403" ]; then
  echo "SNTRY-017 blocked: /ownership/ returned 403 (scope); a 403 is NOT a clean pass"
else
  echo "SNTRY-017 blocked: /ownership/ returned ${code}; record the code as evidence"
fi
rm -f "$own"
```

Healthy: no owner-routed rule, or owner-routed rules with a non-empty `raw` ownership set. Fail (SNTRY-017, medium): an owner-routed rule with empty ownership `raw` — name the direction, *"the immediate rule on `<project>` routes to issue owners, but ownership raw is empty and fallthrough is off — matched issues notify nobody"* (or fallthrough on → pages everyone, mirroring SNTRY-001). The action's own `data.fallthroughType` (`AllMembers`, `ActiveMembers`, or `NoOne`) names where its fallthrough goes. A refused alerts or rules read prints `SNTRY-017 blocked: <project> ... read returned <status>` on either branch, never "no owner-routed rule", and a 403 on `/ownership/` blocks the check with the code as evidence, never a clean pass. **Correlate:** SNTRY-005 (owner-routed actions are a receiver-liveness blind spot the current SNTRY-005 chat/email classifier does not cover) and SNTRY-001 (fallthrough-to-all is the same over-paging failure). Remediation `setup-sentry#receiver-wiring`; verification: re-GET `/projects/{org}/{project}/ownership/` → non-empty `raw` for the owner-routed rule's paths, or the rule re-pointed at a concrete team/integration target.

**live_verify_plan — confirmed live (read-only GETs):**

1. `GET /organizations/{org}/workflows/` → `jq '[.[].enabled | type] | unique'`: **confirmed:** `enabled` is a boolean on every alert; disabled alerts carry `false`. Per Sentry's source, self-hosted 26.x's legacy view of the same alerts shows `status: "active"` with `snooze: true`, so a `status` check there never sees them.
2. `GET /organizations/{org}/detectors/?type=metric_issue` → `jq '[.[].enabled | type] | unique'`: **confirmed:** `enabled` is a boolean on every metric monitor, which settles the old numeric-`status` residual for the metric half.
3. `GET /projects/{org}/{project}/ownership/` → `jq '{raw, fallthrough, fallthroughChoice, autoAssignment}'` — **confirmed:** `/ownership/` returns 200 with `raw` and a boolean `fallthrough` (SNTRY-017 live-verified).
4. `GET /organizations/{org}/workflows/?project={project}` → `jq '[.[].actionFilters[].actions[] | select(.type == "email") | .config.targetType]'`: **confirmed:** an owner-routed email action reads `targetType: "issue_owners"` with `data.fallthroughType` for SNTRY-017.
5. `curl -o /dev/null -w '%{http_code}' GET /organizations/{org}/members/` — confirm `member:read` is present (200) before SNTRY-001 computes a member count; a 403 means SNTRY-001 files the fan-out sub-part blocked, never a fabricated N.

All five are GETs; nothing here mutates the org. Legacy fallback residual: the legacy metric-alert `status` is a numeric enum (observed `0` on active rules) whose disabled value was never observed.

## Integration and source context checks

Snippet and reading order for SNTRY-009. Judge the VCS chain as a chain: a repo integration alone resolves nothing.

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
# Each step is judged right after its own read; a refused read blocks only its own step.
code="$(curl -sS -o "${TMPD}/github.json" -w '%{http_code} %{content_type}' --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/organizations/${SENTRY_ORG}/integrations/?provider_key=github")" || code="curl-exit-$? ${code:-}"
case "$code" in
  "200 application/json"*)
    tee /dev/stderr < "${TMPD}/github.json" | jq '[ .[] | {id, name, status} ]' > "${TMPD}/gh.json"
    jq -e '[ .[] | select(.status == "active") ] | length > 0' "${TMPD}/gh.json" >/dev/null \
      && echo "SNTRY-009 step 1 pass: an active GitHub integration exists" \
      || echo "SNTRY-009 step 1 fail: no active GitHub integration (link 1 broken)" ;;
  *) echo "SNTRY-009 step 1 blocked: org GitHub integrations read returned ${code:-no response}" ;;
esac

code="$(curl -sS -o "${TMPD}/code-mappings.json" -w '%{http_code} %{content_type}' --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/organizations/${SENTRY_ORG}/code-mappings/")" || code="curl-exit-$? ${code:-}"
case "$code" in
  "200 application/json"*)
    tee /dev/stderr < "${TMPD}/code-mappings.json" | jq '[ .[] | {projectId, repoId, defaultBranch, stackRoot, sourceRoot} ]' > "${TMPD}/cm.json"
    jq -e 'length > 0' "${TMPD}/cm.json" >/dev/null \
      && echo "SNTRY-009 step 2 pass: at least one code mapping exists" \
      || echo "SNTRY-009 step 2 fail: no code mappings (link 2 broken)" ;;
  *) echo "SNTRY-009 step 2 blocked: org code-mappings read returned ${code:-no response}" ;;
esac
```

A refused integrations or code-mappings read (a non-200 or non-JSON response, a transfer that failed, or no response) prints `SNTRY-009 step 1 blocked:` or `SNTRY-009 step 2 blocked: org ... read returned <status>` for that step only: the other step still gives its verdict, and a blocked step is unassessed, never a broken link.

Reading order, each link the finding:

1. **No VCS integration connected.** Nothing downstream can work; file once at the integration level, not per project.
2. **Integration connected, no code mappings.** Suspect commits and stack-frame links have no path from a Sentry issue to a file; the integration alone proves nothing.
3. **Code mapping exists, `defaultBranch` does not match your deployed branch.** The mapping resolves files against the wrong branch's tree, so links point at code that may never have run in production. This is a correctness defect, not a missing-feature gap: it looks configured and resolves the wrong thing silently.
4. **Release exists with `commitCount: 0`.** Suspect commits have no data for that release even though deploys are recorded; check `releases.json` `deployCount` versus `commitCount` per release (also feeds SNTRY-006).

Report the specific broken link per project or per repo, not "GitHub is connected."

## Releases and source-map checks

Snippet for SNTRY-006, the minified-frame check, which needs `event:read`:

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-js-project-slug"   # a JavaScript/TypeScript project from projects.json
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

ISSUE_ID="$(curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/issues/?statsPeriod=14d&query=is:unresolved&limit=1" \
  | jq -r '.[0].id // empty')"
[ -n "$ISSUE_ID" ] || { echo "no recent issue in ${PROJECT}; source-map check skipped, mark blocked"; exit 0; }

curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/organizations/${SENTRY_ORG}/issues/${ISSUE_ID}/events/latest/" \
  | tee /dev/stderr \
  | jq -e '[ .entries[]? | select(.type == "exception")
        | .data.values[]?.stacktrace.frames[]? | select((.inApp // .in_app) == true)
        | (.context != null and (.context | length) > 0) ] as $ctx
      | ($ctx | length) > 0 and ($ctx | all)' >/dev/null \
  && echo "SNTRY-006 pass: ${PROJECT} (every in_app frame carries context)" \
  || echo "SNTRY-006 fail-or-blocked: ${PROJECT} (see failure shapes below; confirm filenames are source paths by eye)"
```

Expect: exit 0 and `SNTRY-006 pass: <project>`. The assertion checks that every in-app frame has non-empty `context`. **Field-name note (grounded live):** `/organizations/{org}/issues/{id}/events/latest/` returns the frame flag as camelCase **`inApp`**, not snake_case `in_app` — selecting on `.in_app` alone matches zero frames and the check can never pass (it fails closed on every org). The select reads `(.inApp // .in_app)` so both shapes work; do not narrow it back to `.in_app`. Still confirm by eye that `filename` values are readable source paths, not bundle output, since a hashed chunk name can carry `context` from an unrelated map. Failure shapes:

| Shape | Meaning |
| --- | --- |
| `filename` matches `bundle.js`, `index.js`, or a hashed chunk name with no `context` | Source maps are not resolving for this event, whatever the upload pipeline reports elsewhere |
| No unresolved issue in the last 14 days | Mark the check `blocked` with the reason, not `fail`; there is nothing to sample |
| `event:read` missing (403) | Mark `blocked`; if it is the only check left in the releases category, exclude the category and state why |

Also check `releases.json` directly: `deployCount > 0` with `commitCount == 0` on a release means CI creates and deploys releases but never attaches commit data, so suspect commits have nothing to show even though the release pipeline looks complete.

## Check catalog

Permanent IDs. Never renumber, never reuse a retired ID; deltas depend on stability. One finding per failed check, with every affected project, rule, or service in `affected`.

| ID | Area | Default severity | Check |
| --- | --- | --- | --- |
| SNTRY-001 | Alert rules and routing | high | No project carries the auto-created, unowned "high priority" default rule |
| SNTRY-002 | Privacy and data protection | high | Every production project has data scrubbing, default scrubbers, and a non-empty sensitive-fields list |
| SNTRY-003 | Project configuration | medium | Every active client key on every project has a rate limit |
| SNTRY-004 | Project configuration | medium | Every active project has the environment your production traffic runs under |
| SNTRY-005 | Alert rules and routing | high | Every non-email rule action references a live, active integration; email-only routing is recorded as temporary |
| SNTRY-006 | Releases and source context | high | Recent releases exist, carry commit data, and minified frames resolve to readable source on a sampled recent event |
| SNTRY-007 | Monitors | medium | Every active cron or uptime monitor has an observed check-in; no silently unproven active monitor |
| SNTRY-008 | Volume and quota | medium | Dropped-event share (rate-limited, cardinality-limited, abuse) stays under your declared threshold |
| SNTRY-009 | Releases and source context | low | The VCS chain resolves end to end: integration active, code mapping present, default branch matches the deployed branch, commit data present |
| SNTRY-010 | Privacy and data protection | high | Replay, profiling, or log ingestion volume that is live has a recorded masking, consent, and retention decision |
| SNTRY-011 | Alert rules and routing | medium | No duplicate alerting path: identical condition sets, issue-rule and metric-alert overlap, or Sentry uptime duplicating an external synthetic tool |
| SNTRY-012 | Service coverage | medium | Every critical service maps to a project with recent accepted events, or the mapping is explicitly `not-in-scope` by decision |
| SNTRY-013 | Alert rules and routing | high | Every production project has at least one immediate-tier and one review-tier rule, correctly environment-scoped by the rule's own `environment` field |
| SNTRY-014 | Alert rules and routing | medium | No rule pages on unfiltered every-event conditions or re-pages below your frequency floor |
| SNTRY-015 | Alert rules and routing | high | No monitor is wired to nothing: no enabled *non-built-in* detector with an empty `workflowIds` array is left silent (silent when its project also has no enabled issue alert with an action; unproven when one exists that may match its issues), and no enabled alert has an empty `detectorIds` (it never fires). Excludes the built-in `error`/`issue_stream` detectors every project carries (their empty `workflowIds` is by design); `not-in-scope` on the legacy alert API fallback |
| SNTRY-016 | Alert rules and routing | high | No disabled or muted alert rule is silently crediting tier coverage: a disabled issue alert (`enabled: false`; legacy `status != active`) would still satisfy a tier test that ignores the flag, so a service reads covered while its immediate-tier rule fires nothing; the metric half reads `enabled` on `metric_issue` monitors *(both halves live-verified; legacy metric-alert half verify-pending on its disabled-enum value)* |
| SNTRY-017 | Alert rules and routing | medium | Rules that route to issue owners (`targetType: IssueOwners`) have real ownership rules behind them; empty ownership with fallthrough off notifies nobody, fallthrough on pages everyone |
| SNTRY-101 | Alert rules and routing | medium | Every notifying issue rule gates with at least one filter (an action-filter condition other than a frequency threshold; legacy: a non-empty `filters` array); a broad trigger with no gate fires un-tuned (every-event/frequency subset stays owned by SNTRY-014) |
| SNTRY-102 | Alert rules and routing | medium | On a multi-environment project, every notifying issue rule sets its own `environment`; a null `environment` runs the rule across all environments and pages on dev/staging noise |
| SNTRY-103 | Alert rules and routing | medium | Every metric alert sets a resolve threshold of its own (a `conditionResult` 0 condition not sitting on, or hugging, the trigger threshold, e.g. 0.5 vs 1.0; legacy: a non-null `resolveThreshold`), pairs a warning tier (`conditionResult` 50) with critical (75), uses a flap-safe window (`timeWindow` is in seconds on the alerts API); a percent/rate aggregate also needs a minimum-volume guard (else it reads 100% on a tiny overnight denominator), and warning and critical must not resolve to the *same* channel (double-post) |
| SNTRY-104 | Alert rules and routing | low | Spike Protection is live per production project; readable only indirectly from a `spike_protection` drop reason in stats outcomes, and OFF by default per project on new orgs |
| SNTRY-105 | Alert rules and routing | low | Inbound Data Filters are active on production projects, discarding known-junk events (bots, extensions, localhost) at ingest before they create issues |
| SNTRY-106 | Alert rules and routing | low | Rule fire-history inventory: each notifying rule's measured fire count (`/workflows/{id}/stats/`; legacy `/rules/{id}/stats/`) and last-fired (`lastTriggered`), so every noise finding quotes real blast radius and never-fired rules surface — bounded by the ~90d stats window, so "never fired" means "not in the observable window" |
| SNTRY-107 | Alert rules and routing | high | No chronically-open issue can legally re-page without bound: an `ongoing` issue older than the age floor, matched by an un-gated frequency/every-event notifying rule, yields a re-page ceiling (`matching_rules × 1440/frequency_min` pages/day) — the "why is my channel unusable" join |
| SNTRY-108 | Alert rules and routing | medium | Rule-name and receiver-channel environment claims agree with the rule's actual `environment`: a `- Dev`/`- Prod`-named or `*-pp-*`-channel rule whose `environment` is null or contradicts the claim is silent mis-scoping name-trusting humans never question |
| SNTRY-109 | Alert rules and routing | low | No dead-weight rules: an enabled rule that never fired (per SNTRY-106) AND is snoozed/muted OR carries a generic-keyword condition (an attribute or tag value naming `error`, `exception`, `timeout`, or `memory`) with a re-notify frequency below `FREQ_FLOOR_MIN`; on, dead, and pointless. Disabled rules are excluded: SNTRY-016 owns them (switched off *while* crediting coverage) |
| SNTRY-110 | Alert rules and routing | low | Every alert rule (issue + metric) has an `owner`; an estate where no rule is owned has no one accountable for tuning — maintenance accountability, distinct from SNTRY-017 (delivery routing) |
| SNTRY-018 | Volume and quota | medium | Per-project dropped/accepted ratio stays under your declared floor; a hot project's drops are invisible in the org-wide average SNTRY-008 reads |
| SNTRY-019 | Volume and quota | low | Rate-limit drops are split by `reason` (Spike Protection versus per-key/cardinality quota) so the two distinct remediations are never conflated; a drop is never attributed to a specific key |
| SNTRY-020 | Releases and source context | high | A sampled event's top-level `errors[]` carries a `js_no_source` (or other symbolication-error) entry — a deterministic broken-source-map verdict independent of frame heuristics; the upload pipeline is checked independently via `artifact-bundles`, where a null `release` on a debug-ID bundle is not treated as missing |
| SNTRY-021 | Releases and source context | medium | Every repo bound to release commits has a real `integrations:*` `provider.id`; a repo with an `unknown`/generic provider is a `sentry-cli set-commits` misconfiguration, not a working VCS link |
| SNTRY-022 | Releases and source context | low | Code mappings are structurally plausible: no duplicate `{project, repo}` stack roots differing only by a `./` segment, no `stackRoot` under a build-host path (`/tmp`, `/home`, `/Users`), and no single project routing more mappings into one repo than your declared ceiling |
| SNTRY-023 | Monitors | info | Zero cron/uptime monitors on an org with backend projects carrying real event volume is recorded as an explicit informational finding, never a silent pass |
| SNTRY-024 | Service coverage | medium | A mapped project's `firstEvent == null` (never received an event) is a distinct, differently-worded finding from a mapped project that received events once and then went quiet |
| SNTRY-025 | Project configuration | medium | A project's environment list carries no synonym collision (`prod`/`production`, `pp`/`preprod`/`pre-prod`, `stage`/`staging`); an uncaught collision half-matches the environment-scoped checks (SNTRY-102, SNTRY-013) silently |

Remediation pointers: every SNTRY finding points at `setup-sentry`, anchored to the section that fixes that class of defect (for example `setup-sentry#alert-rule-taxonomy` for SNTRY-001, SNTRY-013, SNTRY-014; `setup-sentry#privacy-gates` for SNTRY-002 and SNTRY-010). SNTRY-005 may alternatively point at `audit-alertmanager` when the receiver in question is Alertmanager-routed rather than a Sentry-native integration. SNTRY-018 and SNTRY-019 point at `setup-sentry#quota-spike-protection-and-privacy-sensitive-ingestion`; SNTRY-020, SNTRY-021, and SNTRY-022 point at `setup-sentry#releases-and-source-maps` and `setup-sentry#github-integration-and-code-mappings` respectively (SNTRY-020 at the former, SNTRY-021/022 at the latter); SNTRY-023 points at `setup-sentry#cron-and-uptime-monitors`; SNTRY-024 points at `setup-sentry#projects`; SNTRY-025 points at `setup-sentry#environment-seeding`.

## Alert hygiene noise-control checks

Snippets for SNTRY-101 through SNTRY-110 (Phase 9). Every call is read-only. SNTRY-101, 102, 105, 106, 108, 109, 110 read per project (SNTRY-110's legacy fallback adds one org-level metric-alert read); SNTRY-103 and 104 read once at the org level; SNTRY-107 joins per-project issues with per-project alerts. Each block redeclares `SENTRY_HOST`, `SENTRY_ORG`, `API`, the token check, and `SENTRY_ALERT_API` (the doctor gate's `alert api:` value) at its own top and relies on no earlier block. Each alert read follows the rules in [Alert rule checks](#alert-rule-checks): a read that fails prints `blocked` with its status, never a pass, and issue-alert checks skip the alerts that only notify for a metric or uptime monitor. These join the Alert rules and routing category and grow its denominator; they never re-weight it, and they never re-check the re-page `frequency` floor (SNTRY-014) or DSN client-key rate limits (SNTRY-003).

**Fire-history is the shared data source for SNTRY-106/107/109 (grounded live).** The alerts list (`/organizations/{org}/workflows/?project={project}`) already returns `lastTriggered` (an ISO timestamp, or `null` = never fired in the observable window) and `owner` on each alert — so never-fired and ownerless are FREE from the inventory the audit already fetched, no extra call. The *magnitude* (fire count) needs one more GET per alert: `/organizations/{org}/workflows/{id}/stats/?statsPeriod=90d` returns `timeSeries[0].values[]` hourly buckets (confirmed live: 2160 buckets over 90 days); the fire count is `[.timeSeries[0].values[].value] | add`. Legacy fallback: the project rules list carries the same two fields, and `/projects/{org}/{proj}/rules/{ruleId}/stats/` returns `[{date, count}]` buckets whose fire count is `[.[].count] | add`. Cost discipline: fetch stats only for alerts that already tripped a structural check (SNTRY-011/014/101/102) or that you are ranking as noisiest — never for every alert on the large path (respect the estate scope checkpoint).

**SNTRY-101, un-tuned issue rules.** A notifying alert with no gating filter fires on every event its trigger matches. On the alerts API a gate is any action-filter condition other than a frequency threshold, since new alerts keep their frequency thresholds in `actionFilters` and migrated rules keep them in `triggers`; on the legacy fallback a gate is any entry in `filters`. The every-event and frequency subset is owned by SNTRY-014, so exclude every-event alerts here:

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
SENTRY_ALERT_API="workflows" # the doctor gate's "alert api:" value
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
FREQ_TYPES='["event_frequency_count","event_frequency_percent","event_unique_user_frequency_count","event_unique_user_frequency_percent","percent_sessions_count","percent_sessions_percent"]'

if [ "${SENTRY_ALERT_API}" = workflows ]; then
  TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
  for r in workflows detectors; do
    code="$(curl -sS -o "${TMPD}/${r}.json" -w '%{http_code} %{content_type}' --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
      "${API}/organizations/${SENTRY_ORG}/${r}/?project=${PROJECT}&per_page=100" || true)"
    case "$code" in "200 application/json"*) ;; *) echo "SNTRY-101 blocked: ${PROJECT} ${r} read returned ${code:-no response}"; exit 0 ;; esac
    [ "$(jq 'length' "${TMPD}/${r}.json")" -lt 100 ] || { echo "SNTRY-101 blocked: ${PROJECT} has 100+ ${r}; judge raw/projects/${PROJECT}/${r}.json instead"; exit 0; }
  done
  tee /dev/stderr < "${TMPD}/workflows.json" \
    | jq -e --slurpfile det "${TMPD}/detectors.json" --argjson freq "$FREQ_TYPES" '
        [$det[0][] | select(.type != "issue_stream") | .id] as $monitors
        | [ .[] | select(.enabled == true)
                | select(any((.detectorIds // [])[]; IN($monitors[]) | not))
                | select(([(.actionFilters // [])[].actions[]] | length) > 0)
                | select(((((.triggers.conditions // []) | length) == 0)
                          or any((.triggers.conditions // [])[]; .type == "every_event")) | not)
                | select([(.actionFilters // [])[].conditions[].type | select(IN($freq[]) | not)] | length == 0) ]
        | length == 0' >/dev/null \
    && echo "SNTRY-101 pass: ${PROJECT}" \
    || echo "SNTRY-101 fail: ${PROJECT} (rule(s) notify with no filters gating them)"
else
  # Legacy fallback (self-hosted Sentry that still serves /rules/):
  curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
    | tee /dev/stderr \
    | jq -e '[ .[]
          | select((.actions // []) | length > 0)
          | select((.filters // []) | length == 0)
          | select([ .conditions[]?.id ] | any(test("EveryEventCondition")) | not) ]
        | length == 0' >/dev/null \
    && echo "SNTRY-101 pass: ${PROJECT}" \
    || echo "SNTRY-101 fail: ${PROJECT} (rule(s) notify with no filters gating them)"
fi
```

Expect: exit 0 and `SNTRY-101 pass: <project>`. A fail lists rules that carry an action but no gate and no every-event condition: they fire on every trigger match with nothing narrowing them by issue age, times-seen, level, or assignment. The filter's `logicType` (legacy `filterMatch`: `all`/`any`/`none`) is only meaningful once a gate exists. Name the rules in `affected`; the fix is to add gating filters, not to delete the rule.

**SNTRY-102, all-environment scope.** An issue rule's `environment` is null by default and then evaluates across every environment. Only score this on a project with more than one environment; a single-environment project has nothing to scope and passes trivially:

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
SENTRY_ALERT_API="workflows" # the doctor gate's "alert api:" value
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
code="$(curl -sS -o "${TMPD}/environments.json" -w '%{http_code} %{content_type}' --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/environments/")" || code="curl-exit-$? ${code:-}"
case "$code" in "200 application/json"*) ;; *) echo "SNTRY-102 blocked: ${PROJECT} environments read returned ${code:-no response}"; exit 0 ;; esac
ENV_COUNT="$(jq 'length' "${TMPD}/environments.json")"
[ "${ENV_COUNT}" -gt 1 ] || { echo "SNTRY-102 n/a: ${PROJECT} has ${ENV_COUNT} environment(s); null scope is not noise here"; exit 0; }

if [ "${SENTRY_ALERT_API}" = workflows ]; then
  for r in workflows detectors; do
    code="$(curl -sS -o "${TMPD}/${r}.json" -w '%{http_code} %{content_type}' --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
      "${API}/organizations/${SENTRY_ORG}/${r}/?project=${PROJECT}&per_page=100" || true)"
    case "$code" in "200 application/json"*) ;; *) echo "SNTRY-102 blocked: ${PROJECT} ${r} read returned ${code:-no response}"; exit 0 ;; esac
    [ "$(jq 'length' "${TMPD}/${r}.json")" -lt 100 ] || { echo "SNTRY-102 blocked: ${PROJECT} has 100+ ${r}; judge raw/projects/${PROJECT}/${r}.json instead"; exit 0; }
  done
  tee /dev/stderr < "${TMPD}/workflows.json" \
    | jq -e --slurpfile det "${TMPD}/detectors.json" '
        [$det[0][] | select(.type != "issue_stream") | .id] as $monitors
        | [ .[] | select(.enabled == true)
                | select(any((.detectorIds // [])[]; IN($monitors[]) | not))
                | select(([(.actionFilters // [])[].actions[]] | length) > 0)
                | select(.environment == null) ]
        | length == 0' >/dev/null \
    && echo "SNTRY-102 pass: ${PROJECT}" \
    || echo "SNTRY-102 fail: ${PROJECT} (rule(s) run across all environments)"
else
  # Legacy fallback (self-hosted Sentry that still serves /rules/):
  code="$(curl -sS -o "${TMPD}/rules.json" -w '%{http_code} %{content_type}' --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/")" || code="curl-exit-$? ${code:-}"
  case "$code" in "200 application/json"*) ;; *) echo "SNTRY-102 blocked: ${PROJECT} rules read returned ${code:-no response}"; exit 0 ;; esac
  tee /dev/stderr < "${TMPD}/rules.json" \
    | jq -e '[ .[]
          | select((.actions // []) | length > 0)
          | select(.environment == null) ]
        | length == 0' >/dev/null \
    && echo "SNTRY-102 pass: ${PROJECT}" \
    || echo "SNTRY-102 fail: ${PROJECT} (rule(s) run across all environments)"
fi
```

Expect: exit 0 and `SNTRY-102 pass: <project>`, or the `n/a` line on a single-environment project. A refused environments, alerts, or rules read prints `SNTRY-102 blocked: <project> ... read returned <status>`, never the `n/a` line or a verdict: the `n/a` line needs an environments list that was actually read. The rule-level `environment` field is the only true environment scope (a `latest_adopted_release` filter does not scope by environment — see the filter table above); a null value on a multi-environment project pages on dev and staging traffic too. This is the noise axis; SNTRY-013 separately owns whether both alert tiers exist, so a rule can pass one and fail the other.

**SNTRY-103, flap-prone metric alerts.** From the org's metric monitors. Each holds its thresholds as `conditionGroup.conditions` (`conditionResult` 75 = critical, 50 = warning, 0 = resolve) and its window in **seconds** at `dataSources[0].queryObj.snubaQuery.timeWindow`. A resolve condition that sits on a trigger threshold is how Sentry migrated a null legacy `resolveThreshold`, so read it as the core flap defect; the missing warning tier and short window are contributing signals:

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
SENTRY_ALERT_API="workflows" # the doctor gate's "alert api:" value
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
TIMEWINDOW_FLOOR_MIN="5"   # example, tune it: metric-alert window (minutes) below which a fixed-threshold rule flaps on transients

if [ "${SENTRY_ALERT_API}" = workflows ]; then
  fetch_all() { # $1: full API URL. Follows cursor pagination, prints one merged JSON array.
    url="$1"; hdr="$(mktemp)"; acc="$(mktemp)"
    while [ -n "$url" ]; do
      curl -fsS --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" -D "$hdr" "$url" >> "$acc" \
        || { rm -f "$hdr" "$acc"; return 1; }
      printf '\n' >> "$acc"
      url="$(tr -d '\r' < "$hdr" | sed -n 's/.*<\([^>]*\)>; rel="next"; results="true".*/\1/p')"
    done
    jq -s 'add // []' "$acc"; rm -f "$hdr" "$acc"
  }
  det="$(mktemp)"; trap 'rm -f "$det"' EXIT
  fetch_all "${API}/organizations/${SENTRY_ORG}/detectors/?type=metric_issue" > "$det" \
    || { echo "SNTRY-103 blocked: metric monitors read failed (status in the curl error above)"; exit 0; }
  # timeWindow is seconds: divide by 60 before comparing with the minute floor.
  tee /dev/stderr < "$det" \
    | jq -e --argjson floor "$TIMEWINDOW_FLOOR_MIN" '[ .[] | select(.type == "metric_issue")
          | [(.conditionGroup.conditions // [])[] | select(.conditionResult > 0) | .comparison] as $trig
          | [(.conditionGroup.conditions // [])[] | select(.conditionResult == 0) | .comparison] as $res
          | { name,
              has_resolve: (($res | length) > 0 and ([$res[] | IN($trig[])] | any | not)),
              has_warning: ([(.conditionGroup.conditions // [])[] | select(.conditionResult == 50)] | length > 0),
              flap_safe:  ((((.dataSources[0].queryObj.snubaQuery.timeWindow // 0) / 60) >= $floor)
                           or (.config.comparisonDelta != null)
                           or ((.config.detectionType // "static") != "static")) }
          | select((.has_resolve and .has_warning and .flap_safe) | not) ]
        | length == 0' >/dev/null \
    && echo "SNTRY-103 pass" \
    || echo "SNTRY-103 fail (metric alert(s) missing a resolve threshold of their own, a warning tier, or a flap-safe window)"
else
  # Legacy fallback (self-hosted Sentry that still serves /alert-rules/; timeWindow in minutes there):
  curl -fsS --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    "${API}/organizations/${SENTRY_ORG}/alert-rules/" \
    | tee /dev/stderr \
    | jq -e --argjson floor "$TIMEWINDOW_FLOOR_MIN" '[ .[]
          | { name,
              has_resolve: (.resolveThreshold != null),
              has_warning: ([ .triggers[]?.label ] | index("warning") != null),
              flap_safe:  (((.timeWindow // 0) >= $floor)
                           or (.comparisonDelta != null)
                           or ((.detectionType // "static") != "static")) }
          | select((.has_resolve and .has_warning and .flap_safe) | not) ]
        | length == 0' >/dev/null \
    && echo "SNTRY-103 pass" \
    || echo "SNTRY-103 fail (metric alert(s) missing resolveThreshold, a warning tier, or a flap-safe window)"
fi
```

Expect: exit 0 and `SNTRY-103 pass`. A resolve condition on the trigger threshold (legacy: `resolveThreshold` null) means recovery falls back to the inverse of the critical threshold and the alert flaps across the boundary; no warning condition (legacy: no `warning` trigger label) means single-threshold paging with no severity tiering; a window below the floor on a fixed static threshold fires on transient spikes. `config.comparisonDelta` (percent-vs-previous mode; seconds, legacy minutes) or a non-static `config.detectionType` (dynamic anomaly, with `sensitivity`) each count as flap resistance and satisfy `flap_safe`. Name each failing rule and which of the three it missed. `SNTRY-103 blocked` means the monitors read failed: the check is unassessed, never "no metric alerts".

Two further flap modes a live estate showed (extend the same read, don't add an ID): (a) **percent/rate aggregate with no throughput floor** — a `failure_rate()`/`percentage(...)` aggregate on a static threshold reads `100%` on a 2-transaction overnight hour; flag a percent-aggregate rule whose window is under a wider floor (e.g. 120 min) or that carries no minimum-volume guard, using org overnight volume from `stats_v2` as supporting evidence. (b) **warning + critical posting to the same target** — when both tiers' actions resolve to the *same* channel/integration id, every incident double-posts; flag identical targets. On the alerts API the tiers live in the alerts connected to the monitor: Sentry migrated a warning and a critical trigger into two action filters (issue priority at least 50, and at least 75), and an issue at high priority passes both, so the same target in both filters posts twice. An alert with one unconditioned filter sends every priority to the same actions by design and is not this defect. Also treat a resolve threshold that hugs the trigger (e.g. resolve 0.5 vs trigger 1.0) as flap-prone, not just one that sits on it.

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
SENTRY_ALERT_API="workflows" # the doctor gate's "alert api:" value
PCT_WINDOW_FLOOR_MIN="120"   # example, tune: percent/rate aggregate below this (minutes) flaps on tiny overnight denominators
if [ "${SENTRY_ALERT_API}" = workflows ]; then
  fetch_all() { # $1: full API URL. Follows cursor pagination, prints one merged JSON array.
    url="$1"; hdr="$(mktemp)"; acc="$(mktemp)"
    while [ -n "$url" ]; do
      curl -fsS --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" -D "$hdr" "$url" >> "$acc" \
        || { rm -f "$hdr" "$acc"; return 1; }
      printf '\n' >> "$acc"
      url="$(tr -d '\r' < "$hdr" | sed -n 's/.*<\([^>]*\)>; rel="next"; results="true".*/\1/p')"
    done
    jq -s 'add // []' "$acc"; rm -f "$hdr" "$acc"
  }
  TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
  fetch_all "${API}/organizations/${SENTRY_ORG}/detectors/?type=metric_issue" > "${TMPD}/detectors.json" \
    || { echo "SNTRY-103 blocked: metric monitors read failed (status in the curl error above)"; exit 0; }
  fetch_all "${API}/organizations/${SENTRY_ORG}/workflows/" > "${TMPD}/workflows.json" \
    || { echo "SNTRY-103 blocked: alerts read failed (status in the curl error above)"; exit 0; }
  jq -r --argjson pf "$PCT_WINDOW_FLOOR_MIN" --slurpfile wf "${TMPD}/workflows.json" '
      ($wf[0] | map({key: .id, value: .}) | from_entries) as $alerts
      | .[] | select(.type == "metric_issue")
      | (.dataSources[0].queryObj.snubaQuery // {}) as $q
      | (($q.aggregate // "") | test("failure_rate|percentage|percent"; "i")) as $is_pct
      | (($q.timeWindow // 0) / 60) as $window
      | ([ (.workflowIds // [])[] | $alerts[.] // empty
           | select(((.actionFilters // []) | length) > 1)
           | [ .actionFilters[] | [ .actions[] | "\(.type):\(.integrationId // ""):\(.config.targetIdentifier // .config.targetType // "?")" ] | unique ]
           | add | (length > (unique | length)) ] | any) as $shared
      | select(($is_pct and $window < $pf) or $shared)
      | "SNTRY-103 flap-risk: \(.name) (\(if $is_pct and $window < $pf then "percent aggregate, \($window)m window, no throughput floor" else "warning and critical notify the same target" end))"' \
    "${TMPD}/detectors.json"
else
  # Legacy fallback (self-hosted Sentry that still serves /alert-rules/; timeWindow in minutes there):
  curl -fsS --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    "${API}/organizations/${SENTRY_ORG}/alert-rules/" \
    | jq -r --argjson pf "$PCT_WINDOW_FLOOR_MIN" '.[]
        | { name, aggregate,
            is_pct: ((.aggregate // "") | test("failure_rate|percentage|percent";"i")),
            window: (.timeWindow // 0),
            targets: [ .triggers[]?.actions[]? | (.targetIdentifier // .targetType // "?") ] }
        | select(
            (.is_pct and .window < $pf)                                  # (a) percent aggregate, sub-floor window
            or ((.targets | length) > (.targets | unique | length))      # (b) warning+critical share a target
          )
        | "SNTRY-103 flap-risk: \(.name) — \(if .is_pct and .window < $pf then "percent aggregate, \(.window)m window (no throughput floor)" else "warning+critical share a channel target" end)"'
fi
# No rows printed = pass on both extended modes. A row names the rule and which mode; for (a) join
# org overnight sum(quantity) from stats_v2 as the "reads 100% on N transactions" evidence.
```

**SNTRY-104, Spike Protection posture.** The weakest read here, stated plainly: project detail exposes no per-project enabled flag, so infer live activity from stats drop outcomes. A `spike_protection` drop reason proves protection is on and firing:

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

# 14d/1d is an example window, tune it. groupBy=reason surfaces the spike_protection drop reason.
st="$(mktemp)"; trap 'rm -f "$st"' EXIT
code="$(curl -sS -o "$st" -w '%{http_code} %{content_type}' --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/organizations/${SENTRY_ORG}/stats_v2/?statsPeriod=14d&interval=1d&field=sum(quantity)&groupBy=reason&groupBy=outcome&category=error")" || code="curl-exit-$? ${code:-}"
case "$code" in "200 application/json"*) ;; *) echo "SNTRY-104 blocked: org stats (by reason) read returned ${code:-no response}"; exit 0 ;; esac
SPIKE_DROPS="$(tee /dev/stderr < "$st" \
  | jq '[ .groups[]? | select(.by.reason == "spike_protection") | .totals["sum(quantity)"] ] | add // 0')"
if [ "${SPIKE_DROPS:-0}" -gt 0 ]; then
  echo "SNTRY-104 pass: spike protection is live (dropped ${SPIKE_DROPS} events by spike_protection in window)"
else
  echo "SNTRY-104 inconclusive: no spike_protection drops in window; on a NEW org (default OFF per project) confirm enablement in Project Settings"
fi
```

Expect: `SNTRY-104 pass` when the window shows any `spike_protection` drops, otherwise `SNTRY-104 inconclusive`. A refused stats read prints `SNTRY-104 blocked: org stats (by reason) read returned <status>`, never `inconclusive`: zero drops is only a reading when the stats were actually read. Do not score the inconclusive branch as a fail: on an existing org there may simply have been no spike, and Spike Protection was enabled by default for existing/migrated orgs. On a **new** org it is OFF by default per project, so the absence of drops there is a prompt to confirm enablement, recorded as `partial` with the ceiling stated, never a proven gap. Spike *notifications* are off by default on purpose and are not a finding.

**SNTRY-105, Inbound Data Filters.** From the project filters endpoint. A production project with no active inbound filter ingests known-junk events that create issues and feed alerts:

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

# The project platform decides which junk filters even apply: browser-only filters
# (browser-extensions, legacy-browsers) are N/A on backend platforms, so their absence
# there is not a finding and their presence must not credit a pass on a backend.
# Project detail carries the project's securityToken: keep the response in memory, never in a file.
resp="$(curl -sS -w '\n%{http_code} %{content_type}' --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/")" || resp="curl-exit-$? $(printf '%s\n' "${resp:-}" | tail -n 1)"
code="$(printf '%s\n' "$resp" | tail -n 1)"
case "$code" in "200 application/json"*) ;; *) echo "SNTRY-105 blocked: ${PROJECT} project detail read returned ${code:-no response}"; exit 0 ;; esac
PLATFORM="$(printf '%s\n' "$resp" | sed '$d' | jq -r '.platform // "unknown"')"

flt="$(mktemp)"; trap 'rm -f "$flt"' EXIT
code="$(curl -sS -o "$flt" -w '%{http_code} %{content_type}' --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/filters/")" || code="curl-exit-$? ${code:-}"
case "$code" in "200 application/json"*) ;; *) echo "SNTRY-105 blocked: ${PROJECT} inbound filters read returned ${code:-no response}"; exit 0 ;; esac
tee /dev/stderr < "$flt" \
  | jq -e --arg platform "$PLATFORM" '
      def is_active: (.active == true)
        or (((.active | type) == "array") and ((.active | length) > 0));
      def is_browser_only: (.id == "browser-extensions" or .id == "legacy-browsers");
      ($platform | test("^(javascript|electron|cordova|react-native|unity|flutter)")) as $browser
      | [ .[]
          # filtered-transaction is a default-on transaction sampler present on every modern
          # project — it is NOT junk-error filtering, so it must never credit a pass:
          | select(.id != "filtered-transaction")
          # browser-only filters count toward a pass only on browser platforms:
          | select($browser or (is_browser_only | not))
          | select(is_active) ]
      | length > 0' >/dev/null \
  && echo "SNTRY-105 pass: ${PROJECT} (a real junk-event inbound filter is active for platform=${PLATFORM})" \
  || echo "SNTRY-105 fail: ${PROJECT} (only the default-on filtered-transaction is active; no applicable bot/crawler/localhost/extension filtering — platform=${PLATFORM})"
```

Expect: exit 0 and `SNTRY-105 pass: <project>`. A refused project detail or filters read prints `SNTRY-105 blocked: <project> ... read returned <status>`, never a fail. The `/filters/` list carries one entry per inbound filter (web crawlers, browser-extension errors, localhost, legacy browsers, `filtered-transaction`, and filters by error message, release, or IP). **Two corrections that prevent a false pass and a false fail (grounded live):** (1) `filtered-transaction` is **default-on on every modern project** — it is a transaction sampler, not junk-error filtering, so crediting it makes the check pass vacuously on essentially every org; the jq **excludes it** and only a *real* junk filter (web-crawlers, localhost, browser-extensions, legacy-browsers, or a custom message/release/IP filter) can credit a pass. (2) `browser-extensions` and `legacy-browsers` only apply to **browser platforms** — flagging a `python`/`go`/`node` backend for lacking browser filters is a false positive, so those two count toward a pass (and toward the finding) only when the project `platform` is browser-family; on a backend the applicable filters are web-crawlers, localhost, and custom filters. `active` is a boolean for most filters and a non-empty subfilter array for legacy browsers; treat either shape as active. Filtered events do not consume quota, so a fail here also feeds the quota-pressure reading in SNTRY-008; cross-reference rather than double-file the same dropped-event story.

**SNTRY-106, rule fire-history inventory.** The fire-count blast radius behind every noise finding, and never-fired detection. `lastTriggered` and `owner` are already on the alerts list (no extra call); the fire *count* is one GET per alert against its stats endpoint — run it only for alerts a structural check already flagged, never the whole estate:

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
SENTRY_ALERT_API="workflows" # the doctor gate's "alert api:" value
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
RULE_ID="16700000"   # an alert (legacy: rule) id from a tripped structural finding

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
if [ "${SENTRY_ALERT_API}" = workflows ]; then
  # never-fired is FREE from the alerts list (lastTriggered null == not fired in the observable window):
  code="$(curl -sS -o "${TMPD}/workflows.json" -w '%{http_code} %{content_type}' --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    "${API}/organizations/${SENTRY_ORG}/workflows/?project=${PROJECT}&per_page=100" || true)"
  case "$code" in "200 application/json"*) ;; *) echo "SNTRY-106 blocked: ${PROJECT} alerts read returned ${code:-no response}"; exit 0 ;; esac
  [ "$(jq 'length' "${TMPD}/workflows.json")" -lt 100 ] || echo "SNTRY-106 note: ${PROJECT} has 100+ alerts; the list below is the first page, read raw/projects/${PROJECT}/workflows.json for the rest"
  tee /dev/stderr < "${TMPD}/workflows.json" \
    | jq -r '.[] | "\(.id)\t\(.name)\tlastTriggered=\(.lastTriggered // "never-in-window")"'
  # fire COUNT for one alert (run ONLY for an alert already flagged by SNTRY-011/014/101/102, or the
  # noisiest you are ranking): hourly buckets over the 90-day window. A failed read is blocked, not 0 fires.
  code="$(curl -sS -o "${TMPD}/stats.json" -w '%{http_code} %{content_type}' --max-time 20 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    "${API}/organizations/${SENTRY_ORG}/workflows/${RULE_ID}/stats/?statsPeriod=90d" || true)"
  case "$code" in
    "200 application/json"*) jq '[ .timeSeries[0].values[]?.value ] | add // 0' "${TMPD}/stats.json" ;;   # total fires in the window
    *) echo "SNTRY-106 fire count blocked: stats read returned ${code:-no response}; never read as zero fires" ;;
  esac
else
  # Legacy fallback (self-hosted Sentry that still serves /rules/):
  curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
    | tee /dev/stderr \
    | jq -r '.[] | "\(.id)\t\(.name)\tlastTriggered=\(.lastTriggered // "never-in-window")"'
  # /stats/ returns [{date,count}] hourly buckets over the ~90d window.
  curl -fsS --max-time 20 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/stats/" \
    | jq '[ .[].count ] | add // 0'   # total fires in the stats window — the number to quote as blast radius
fi
```

Expect: an alert→last-fired list, and for a flagged alert its summed fire count. `lastTriggered == null` means *never fired in the observable window* — state it that way, never "dead forever" (the window is bounded, 90 days). This is inventory, not a scored pass/fail on its own; its value is that SNTRY-011/014/101/102 findings now read "rule X fired N times / 0 times" instead of "rule X is structurally noisy". Cap the per-alert stats calls under the estate scope checkpoint; Sentry marks the stats endpoint experimental, so a non-`200` blocks the fire-count sub-part rather than changing the verdict.

**SNTRY-107, chronic-issue re-page ceiling (the flagship noise join).** Joins two surfaces the audit already touches separately: long-open `ongoing` issues × un-gated notifying rules that still match them. It answers "why is my channel unusable", not "which field is null":

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # a production project from projects.json
SENTRY_ALERT_API="workflows" # the doctor gate's "alert api:" value
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
AGE_FLOOR_DAYS="30"   # example, tune it: an ongoing issue older than this that still re-pages is chronic
FREQ_TYPES='["event_frequency_count","event_frequency_percent","event_unique_user_frequency_count","event_unique_user_frequency_percent","percent_sessions_count","percent_sessions_percent"]'

# 1) chronic issues: unresolved + ongoing + older than the age floor, most events first.
#    The age floor is applied server-side via the `age:+Nd` search token (grounded live:
#    `age:+30d` = older than 30d). Do NOT pass `statsPeriod=90d` here — the issues endpoint
#    only accepts '', '24h', '14d' for stats_period and 400s on 90d; the `age:` token is
#    what filters for chronic issues. URL-encoding: `:` = %3A, the leading `+` = %2B.
#    A refused issues read is blocked: never an empty list read as "no chronic issue".
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
code="$(curl -sS -o "${TMPD}/issues.json" -w '%{http_code} %{content_type}' --max-time 20 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/issues/?query=is%3Aunresolved+is%3Aongoing+age%3A%2B${AGE_FLOOR_DAYS}d&sort=freq")" || code="curl-exit-$? ${code:-}"
case "$code" in "200 application/json"*) ;; *) echo "SNTRY-107 blocked: ${PROJECT} issues read returned ${code:-no response}"; exit 0 ;; esac
tee /dev/stderr < "${TMPD}/issues.json" \
  | jq -r '.[] | "\(.shortId)\tevents=\(.count)\tfirstSeen=\(.firstSeen)\tsubstatus=\(.substatus // "?")"' | head

# 2) un-gated re-paging rules: a frequency/every-event condition, an action, and NO age /
#    times-seen / new-issue gate (so a permanently-open issue keeps matching)
if [ "${SENTRY_ALERT_API}" = workflows ]; then
  for r in workflows detectors; do
    code="$(curl -sS -o "${TMPD}/${r}.json" -w '%{http_code} %{content_type}' --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
      "${API}/organizations/${SENTRY_ORG}/${r}/?project=${PROJECT}&per_page=100" || true)"
    case "$code" in "200 application/json"*) ;; *) echo "SNTRY-107 blocked: ${PROJECT} ${r} read returned ${code:-no response}"; exit 0 ;; esac
    [ "$(jq 'length' "${TMPD}/${r}.json")" -lt 100 ] || { echo "SNTRY-107 blocked: ${PROJECT} has 100+ ${r}; judge raw/projects/${PROJECT}/${r}.json instead"; exit 0; }
  done
  jq -r --slurpfile det "${TMPD}/detectors.json" --argjson freq "$FREQ_TYPES" '
      [$det[0][] | select(.type != "issue_stream") | .id] as $monitors
      | [ .[] | select(.enabled == true)
          | select(any((.detectorIds // [])[]; IN($monitors[]) | not))
          | select(([(.actionFilters // [])[].actions[]] | length) > 0)
          | [(.triggers.conditions // [])[].type] as $tt
          | [(.actionFilters // [])[].conditions[].type] as $ft
          | select((($tt | length) == 0) or any($tt[]; . == "every_event") or any(($tt + $ft)[]; IN($freq[])))
          | select(any($ft[]; IN("age_comparison", "issue_occurrences", "latest_release", "latest_adopted_release")) | not)
          | select(any($tt[]; . == "first_seen_event") | not)
          | { name, freq: (.config.frequency // 30) } ]
      | "un-gated re-paging rules: \(length); re-page ceiling/day per matching issue = sum over rules of (1440 / freq_min)"' \
    "${TMPD}/workflows.json"
else
  # Legacy fallback (self-hosted Sentry that still serves /rules/):
  curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
    | jq -r '[ .[]
        | select((.actions // []) | length > 0)
        | select([ .conditions[]?.id ] | any(test("EventFrequencyCondition|EventFrequencyPercentCondition|EveryEventCondition")))
        | select([ .filters[]?.id ] | any(test("AgeComparison|IssueOccurrences|FirstSeenEvent|latest")) | not)
        | { name, freq: (.frequency // 30) } ]
        | "un-gated re-paging rules: \(length); re-page ceiling/day per matching issue = sum over rules of (1440 / freq_min)"'
fi
```

Expect: the chronic-issue list and the count of un-gated re-paging rules. The finding (high) is the **legal re-page ceiling**: for one permanently-`ongoing` issue matched by those rules, `Σ (1440 / rule.frequency_min)` pages/day/channel (the classic result: one 117-day-old issue × two 15-min burst rules ≈ 96 pages/day). A rule with `frequency` 0 re-notifies on every match, so its ceiling is the issue's own event rate, not a number of minutes. Quote it as a *ceiling*, not an observed count — and when SNTRY-106 stats exist, quote both ("ceiling 96/day; observed 278 last week"). Name the issue(s) and the rules in `affected`. This is the check that explains an unusable channel. A refused issues read (a non-200 or non-JSON response, or no response) prints `SNTRY-107 blocked: <project> issues read returned <status>` and the project is unassessed, never "no chronic issue"; on the alerts API a refused alerts read prints `SNTRY-107 blocked` the same way. The un-gated rules themselves stay with SNTRY-101 and SNTRY-014.

**SNTRY-108, name / scope / receiver coherence.** A rule whose *name* or *receiver channel* claims an environment while its actual `environment` field is null or contradicts the claim is silent mis-scoping — name-trusting humans never question a "- Prod" rule that is really firing on everything:

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
SENTRY_ALERT_API="workflows" # the doctor gate's "alert api:" value
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
# Claims are whole words of the rule name plus its channel names. Production: prod or production
# (never preprod, pre-prod, non-prod, or product). Non-prod: dev, development, staging, stage, qa,
# test, pp, preprod or pre-prod, pre-production, and non-prod or non-production. A rule contradicts
# its claim when environment is null, or when a production claim sits on a non-production
# environment, or a non-prod claim on a production one.
CLAIM_JQ='def words: ascii_downcase | gsub("(?<p>pre|non)[-_ ]?prod"; "\(.p)prod") | [splits("[^a-z0-9]+")];
  def prod_word: any(.[]; IN("prod", "production"));
  def nonprod_word: any(.[]; IN("dev", "development", "staging", "stage", "qa", "test", "pp",
    "preprod", "preproduction", "nonprod", "nonproduction"));
  def claim: if prod_word then "production" elif nonprod_word then "non-prod" else null end;
  def contradicts($claim): (.environment == null)
    or ($claim == "production" and ((.environment | tostring | words | prod_word) | not))
    or ($claim == "non-prod" and (.environment | tostring | words | prod_word));'

if [ "${SENTRY_ALERT_API}" = workflows ]; then
  TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
  for r in workflows detectors; do
    code="$(curl -sS -o "${TMPD}/${r}.json" -w '%{http_code} %{content_type}' --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
      "${API}/organizations/${SENTRY_ORG}/${r}/?project=${PROJECT}&per_page=100" || true)"
    case "$code" in "200 application/json"*) ;; *) echo "SNTRY-108 blocked: ${PROJECT} ${r} read returned ${code:-no response}"; exit 0 ;; esac
    [ "$(jq 'length' "${TMPD}/${r}.json")" -lt 100 ] || { echo "SNTRY-108 blocked: ${PROJECT} has 100+ ${r}; judge raw/projects/${PROJECT}/${r}.json instead"; exit 0; }
  done
  # The channel claim reads each action's display name (config.targetDisplay), else its target id.
  tee /dev/stderr < "${TMPD}/workflows.json" \
    | jq -r --slurpfile det "${TMPD}/detectors.json" "${CLAIM_JQ}"'
        [$det[0][] | select(.type != "issue_stream") | .id] as $monitors
        | .[] | select(any((.detectorIds // [])[]; IN($monitors[]) | not))
        | (((.name // "") + " " + ([ (.actionFilters // [])[].actions[]
             | (.config.targetDisplay // .config.targetIdentifier // "") | tostring ] | join(" "))) | words | claim) as $claim
        | select($claim != null and contradicts($claim))
        | "SNTRY-108: \(.name) claims \($claim) (name/channel) but environment=\(.environment // "null")"'
else
  # Legacy fallback (self-hosted Sentry that still serves /rules/):
  rl="$(mktemp)"; trap 'rm -f "$rl"' EXIT
  code="$(curl -sS -o "$rl" -w '%{http_code} %{content_type}' --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/")" || code="curl-exit-$? ${code:-}"
  case "$code" in "200 application/json"*) ;; *) echo "SNTRY-108 blocked: ${PROJECT} rules read returned ${code:-no response}"; exit 0 ;; esac
  tee /dev/stderr < "$rl" \
    | jq -r "${CLAIM_JQ}"'.[]
        | (((.name // "") + " " + ([ .actions[]? | (.channel // .targetIdentifier // "") | tostring ] | join(" "))) | words | claim) as $claim
        | select($claim != null and contradicts($claim))
        | "SNTRY-108: \(.name) claims \($claim) (name/channel) but environment=\(.environment // "null")"'
fi
```

Expect: no rows on a coherent estate. A row is a rule whose stated env (from its name or the channel it posts to) disagrees with its `environment` field — the clearest case being a claim with `environment: null` (fires on all envs while looking scoped). Claims are whole words: `prod` or `production` claims production, while `preprod`, `pre-prod`, `non-prod`, and `product` do not; `dev`, `development`, `staging`, `stage`, `qa`, `test`, `pp`, `preprod` or `pre-prod`, `pre-production`, and `non-prod` or `non-production` claim non-prod; a name or channel carrying both reads as production. A non-prod claim passes on any non-production environment and fails on a production one (`prod`, `production`); a production claim fails on any environment that is not a production one. This is deliberately conservative: it only fires when there is an explicit claim to contradict. SNTRY-102 owns the plain "env is null" gap; SNTRY-108 owns the *lie in the name* and the set-but-contradicting case. A refused read prints `SNTRY-108 blocked: <project> ... read returned <status>` on either branch, never "no rows". Word matching is heuristic: record the claimed-vs-actual pair as the evidence and let the reader judge non-standard names.

**SNTRY-109, dead-weight rules.** An enabled rule that never fired AND is either snoozed (muted) or carries a generic-keyword condition while re-notifying more often than `FREQ_FLOOR_MIN` minutes: on, dead, and safe to delete. Disabled rules are left out, because SNTRY-016 owns them (switched off *while crediting* coverage):

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
SENTRY_ALERT_API="workflows" # the doctor gate's "alert api:" value
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
FREQ_FLOOR_MIN="30"   # example, tune to your volume

if [ "${SENTRY_ALERT_API}" = workflows ]; then
  TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
  for r in workflows detectors; do
    code="$(curl -sS -o "${TMPD}/${r}.json" -w '%{http_code} %{content_type}' --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
      "${API}/organizations/${SENTRY_ORG}/${r}/?project=${PROJECT}&per_page=100" || true)"
    case "$code" in "200 application/json"*) ;; *) echo "SNTRY-109 blocked: ${PROJECT} ${r} read returned ${code:-no response}"; exit 0 ;; esac
    [ "$(jq 'length' "${TMPD}/${r}.json")" -lt 100 ] || { echo "SNTRY-109 blocked: ${PROJECT} has 100+ ${r}; judge raw/projects/${PROJECT}/${r}.json instead"; exit 0; }
  done
  # The alerts API has no snooze flag: a snoozed rule reads enabled: false here, and disabled
  # alerts are SNTRY-016's. Keyword values are strings; frequency is config.frequency, in minutes.
  tee /dev/stderr < "${TMPD}/workflows.json" \
    | jq -r --slurpfile det "${TMPD}/detectors.json" --argjson floor "$FREQ_FLOOR_MIN" '
        [$det[0][] | select(.type != "issue_stream") | .id] as $monitors
        | .[] | select(any((.detectorIds // [])[]; IN($monitors[]) | not))
        | select(.enabled == true)                                           # disabled alerts belong to SNTRY-016
        | [((.triggers.conditions // [])[], ((.actionFilters // [])[].conditions[]))] as $c
        | select(.lastTriggered == null)                                     # never fired in window (SNTRY-106)
        | select(any($c[]; (.type == "event_attribute" or .type == "tagged_event")
                   and ((.comparison.value // "") | tostring | test("timeout|memory|error|exception"; "i")))   # generic keyword
                 and ((.config.frequency // 30) < $floor))                   # re-notifies below the floor
        | "SNTRY-109 dead-weight: \(.name) (never fired; generic-keyword condition re-notifying every \(.config.frequency // 30) min)"'
else
  # Legacy fallback (self-hosted Sentry that still serves /rules/):
  rl="$(mktemp)"; trap 'rm -f "$rl"' EXIT
  code="$(curl -sS -o "$rl" -w '%{http_code} %{content_type}' --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/")" || code="curl-exit-$? ${code:-}"
  case "$code" in "200 application/json"*) ;; *) echo "SNTRY-109 blocked: ${PROJECT} rules read returned ${code:-no response}"; exit 0 ;; esac
  tee /dev/stderr < "$rl" \
    | jq -r --argjson floor "$FREQ_FLOOR_MIN" '.[]
        | select((.status // "active") == "active")                         # disabled rules belong to SNTRY-016
        | select(.lastTriggered == null)                                   # never fired in window (SNTRY-106)
        | select(((.snooze // false) != false)                             # snoozed, OR ...
          or (([ .filters[]? | (.value // .key // empty) | tostring ] | any(test("timeout|memory|error|exception"; "i")))
              and ((.frequency // 999999) < $floor)))                      # generic keyword, re-notifying below the floor
        | "SNTRY-109 dead-weight: \(.name) (never fired; \(if (.snooze // false) != false then "snoozed" else "generic-keyword filter re-notifying every \(.frequency) min" end))"'
fi
```

Expect: no rows on a lean estate. Rows are enabled rules that never fired in the window AND are either snoozed (legacy fallback `snooze`; the alerts API has no snooze flag, so a snoozed rule reads `enabled: false` there and belongs to SNTRY-016) or carry a generic-keyword condition (an attribute or tag value naming `error`, `exception`, `timeout`, or `memory`) while re-notifying more often than `FREQ_FLOOR_MIN` minutes (example value, tune to your volume): review surface that inflates coverage counts and deletes with no loss. Disabled rules (`enabled: false`; legacy `status` other than `active`) never appear here. A refused read prints `SNTRY-109 blocked: <project> ... read returned <status>` on either branch, never "no dead weight". Cross-reference SNTRY-106 (the never-fired signal) and honor its window ceiling; a rule "never fired" only within the observable window is a review candidate, not an automatic delete — the fix is a confirmed deletion via `setup-sentry`, never by this read-only audit.

**SNTRY-110, ownerless rules.** Maintenance accountability across the whole rule estate — issue alerts and metric alerts (their `metric_issue` monitors on the alerts API). An estate where no rule has an `owner` has no one accountable for tuning, which is how a rule set rots:

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
SENTRY_ALERT_API="workflows" # the doctor gate's "alert api:" value
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

if [ "${SENTRY_ALERT_API}" = workflows ]; then
  TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
  for r in workflows detectors; do
    code="$(curl -sS -o "${TMPD}/${r}.json" -w '%{http_code} %{content_type}' --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
      "${API}/organizations/${SENTRY_ORG}/${r}/?project=${PROJECT}&per_page=100" || true)"
    case "$code" in "200 application/json"*) ;; *) echo "SNTRY-110 blocked: ${PROJECT} ${r} read returned ${code:-no response}"; exit 0 ;; esac
    [ "$(jq 'length' "${TMPD}/${r}.json")" -lt 100 ] || { echo "SNTRY-110 blocked: ${PROJECT} has 100+ ${r}; judge raw/projects/${PROJECT}/${r}.json instead"; exit 0; }
  done
  # issue alerts (owner is a "team:<id>" string) + this project's metric monitors (owner is an object)
  ISSUE_UNOWNED="$(jq --slurpfile det "${TMPD}/detectors.json" '
      [$det[0][] | select(.type != "issue_stream") | .id] as $monitors
      | [ .[] | select(any((.detectorIds // [])[]; IN($monitors[]) | not)) | select(.owner == null) ] | length' \
    "${TMPD}/workflows.json")"
  METRIC_UNOWNED="$(jq '[ .[] | select(.type == "metric_issue" and .owner == null) ] | length' "${TMPD}/detectors.json")"
  echo "SNTRY-110: ${PROJECT} unowned issue rules=${ISSUE_UNOWNED}; unowned metric monitors=${METRIC_UNOWNED}"
else
  # Legacy fallback: issue rules (per project) + metric alerts (org-level) with no owner. Each half
  # is counted right after its own read; a refused half stays "blocked".
  TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
  ISSUE_UNOWNED="blocked"; METRIC_UNOWNED="blocked"
  code="$(curl -sS -o "${TMPD}/rules.json" -w '%{http_code} %{content_type}' --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/")" || code="curl-exit-$? ${code:-}"
  case "$code" in
    "200 application/json"*) ISSUE_UNOWNED="$(jq '[ .[] | select(.owner == null) ] | length' "${TMPD}/rules.json")" ;;
    *) echo "SNTRY-110 issue half blocked: ${PROJECT} rules read returned ${code:-no response}" ;;
  esac
  code="$(curl -sS -o "${TMPD}/metric-alerts.json" -w '%{http_code} %{content_type}' --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    "${API}/organizations/${SENTRY_ORG}/alert-rules/")" || code="curl-exit-$? ${code:-}"
  case "$code" in
    "200 application/json"*) METRIC_UNOWNED="$(jq '[ .[] | select(.owner == null) ] | length' "${TMPD}/metric-alerts.json")" ;;
    *) echo "SNTRY-110 metric half blocked: org metric alert rules read returned ${code:-no response}" ;;
  esac
  if [ "${ISSUE_UNOWNED}" != blocked ] || [ "${METRIC_UNOWNED}" != blocked ]; then
    echo "SNTRY-110: ${PROJECT} unowned issue rules=${ISSUE_UNOWNED}; org unowned metric alerts=${METRIC_UNOWNED}"
  fi
fi
# One ownerless rule in either half is a fail even when the other half was refused; a pass needs
# both halves read. A count above zero is the only value holding a digit 1-9.
case "${ISSUE_UNOWNED}:${METRIC_UNOWNED}" in
  0:0) echo "SNTRY-110 pass" ;;
  *[1-9]*) echo "SNTRY-110 fail (ownerless rules: no one accountable for tuning)" ;;
  *) echo "SNTRY-110 blocked: ${PROJECT} rule ownership is unknown (a read was refused, and what was read shows no ownerless rule)" ;;
esac
```

Expect: `SNTRY-110 pass` when every rule carries an owner (an issue alert's `owner` reads `team:<id>` or `user:<id>`; a metric monitor's `owner` is an object with `type` and `id`). On the alerts API a refused read prints `SNTRY-110 blocked: <project> ... read returned <status>`, never a count or a verdict. On the legacy fallback each half is read and counted on its own: a refused half prints `SNTRY-110 issue half blocked` or `SNTRY-110 metric half blocked`, an ownerless rule in the half that was read is still a fail, and the verdict is `SNTRY-110 blocked` only when a half was refused and no half that was read shows an ownerless rule. Ownerless rules are low severity but high explanatory value — an all-ownerless estate is the root of alert rot. This is distinct from SNTRY-017 (which is about delivery routing to issue owners); SNTRY-110 is about who maintains the rule. The fix (assign owners) is a `setup-sentry` mutation, not this audit's job.

### Honest ceiling for the fire-history checks (SNTRY-106/107/109)

Fire counts measure **emission, not annoyance** — the audit still has no incident/ack feed, so it must never claim an actionability rate from them (the existing Phase-9 ceiling text applies; extend it to cover these numbers). "Never fired" is bounded by the stats retention window (~90d) — say "not in the observable window", never "dead". Re-page ceilings (SNTRY-107) are **legal maxima**, not observed counts; when SNTRY-106 stats exist, quote both the ceiling and the observed count.

## Depth checks: per-project quota attribution, deterministic source-map verdicts, VCS/code-mapping integrity, monitor posture, coverage split, environment sprawl (SNTRY-018 through SNTRY-025)

Snippets for SNTRY-018 through SNTRY-025. Every call is read-only. All eight were confirmed live against a real Sentry SaaS org during this wave — the shapes below are the observed shapes, not guessed ones; each subsection states what was actually observed. SNTRY-018/019 reuse `stats-projects.json`/`stats-outcomes.json` from Phase 1 or re-fetch with the same query; SNTRY-020 reuses the Phase 5 event fetch; SNTRY-021/022 reuse `repos.json`/`code-mappings.json`; SNTRY-023 reuses `monitors.json`; SNTRY-024 reuses `projects.json` project-detail fields already fetched in Phase 1; SNTRY-025 reuses each project's `environments.json`. None of these add a new per-project call the audit was not already making, except SNTRY-020's per-event and `artifact-bundles` reads (bounded exactly like the existing SNTRY-006 sample).

**SNTRY-018, per-project drop ratio.** SNTRY-008 reads `stats-outcomes.json` **org-wide** — a single hot project can breach a drop-ratio floor while the org-wide average stays comfortably under it, because the other projects' accepted volume dilutes the average. Re-read the same window grouped by project instead of summed org-wide:

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
DROP_RATIO="0.05"   # example, tune to your quota; same default as the org-wide SNTRY-008 floor

# groupBy=project + groupBy=outcome (confirmed live: numeric project id, numeric sum(quantity) —
# both come back as JSON numbers on this endpoint, not strings; do not add a tostring guard here).
STATS="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/$(date -u +%Y-%m-%d)/raw/stats-projects.json"
[ -s "${STATS}" ] || curl -fsS --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/organizations/${SENTRY_ORG}/stats_v2/?statsPeriod=14d&interval=1d&field=sum(quantity)&groupBy=project&groupBy=outcome&category=error" \
  > "${STATS}"

jq -r --argjson floor "${DROP_RATIO}" '
  ( [ .groups[]? | .by.project ] | unique ) as $pids
  | $pids[] as $pid
  | ( [ .groups[]? | select(.by.project == $pid) ] ) as $rows
  | ( [ $rows[] | select(.by.outcome == "accepted") | .totals["sum(quantity)"] ] | add // 0 ) as $accepted
  | ( [ $rows[] | select(.by.outcome == "rate_limited" or .by.outcome == "abuse" or .by.outcome == "cardinality_limited")
        | .totals["sum(quantity)"] ] | add // 0 ) as $dropped
  | ( $accepted + $dropped ) as $total
  | select($total > 0)
  | ( $dropped / $total ) as $ratio
  | select($ratio > $floor)
  | "SNTRY-018 fail: project \($pid) drop ratio \(($ratio*100)|floor)% (\($dropped)/\($total)) exceeds floor \(($floor*100)|floor)%"
' "${STATS}"
```

**Confirmed live** on a real org: the org-wide SNTRY-008 read showed a modest aggregate drop share, but re-grouped by project this query surfaced one project whose `rate_limited` share of its own `accepted + rate_limited` total exceeded the 5% example floor while every other project in the same org was comfortably under it — proving the exact masking failure mode this check exists to catch: the org-wide average alone would have scored SNTRY-008 clean while one project was already losing events to quota. Expect: no rows on a healthy org; a row names the numeric project id (resolve it to a slug from `projects.json` before writing the finding) and the exact ratio. `affected` names the project by slug, not the numeric id. **Correlate:** SNTRY-008 (the org-wide reading this check is scoped underneath), SNTRY-003 (an unlimited key on the same project is the mechanism), SNTRY-019 (the reason split below explains *why* it is dropping).

**SNTRY-019, rate-limit reason split.** `stats_v2` supports a `reason` groupBy/filter dimension distinct from `outcome`; `outcome=rate_limited` is the effect, `reason` is the cause, and the two causes need different fixes (Spike Protection is a burst-shape control tuned in `setup-sentry#quota-spike-protection-and-privacy-sensitive-ingestion`; a per-key or cardinality quota breach is fixed by raising or removing the key's `rateLimit`, SNTRY-003's object). Never attribute a specific drop to a specific key — the stats are org- or project-wide, not per-key:

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

# groupBy=reason is confirmed live to require groupBy=outcome alongside it (the API accepts the
# combination; reason alone with no outcome groupBy was not tried and is not the supported shape
# used here). category=error narrows to the same window SNTRY-008 already reads.
st="$(mktemp)"; trap 'rm -f "$st"' EXIT
code="$(curl -sS -o "$st" -w '%{http_code} %{content_type}' --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/organizations/${SENTRY_ORG}/stats_v2/?statsPeriod=14d&interval=1d&field=sum(quantity)&groupBy=reason&groupBy=outcome&category=error")" || code="curl-exit-$? ${code:-}"
case "$code" in "200 application/json"*) ;; *) echo "SNTRY-019 blocked: org stats (by reason) read returned ${code:-no response}"; exit 0 ;; esac
tee /dev/stderr < "$st" \
  | jq -r '
      ( [ .groups[]? | select(.by.outcome == "rate_limited" and .by.reason == "spike_protection") | .totals["sum(quantity)"] ] | add // 0 ) as $spike
    | ( [ .groups[]? | select(.by.outcome == "rate_limited" and .by.reason != "spike_protection") | .totals["sum(quantity)"] ] | add // 0 ) as $keyquota
    | "SNTRY-019: rate_limited drops in window — spike_protection=\($spike), other (key/cardinality quota)=\($keyquota)"
'
```

Note the jq above has a deliberate structural fix versus a naive one-liner: `outcome == "rate_limited"` alone conflates the two causes, so the reason equality split is the load-bearing part of the check, not an optional refinement. **Confirmed live** on a real org: every `rate_limited` drop in the 14-day window carried `reason: "spike_protection"` (291 events, matching the SNTRY-104 spike-protection evidence exactly) and zero carried any other reason — a clean, unambiguous attribution in this org. A live response also showed `reason: "network_error"` and `reason: "ratelimit_backoff"` paired with `outcome: "client_discard"` (client-side SDK backoff, never server-side `rate_limited`) and `reason: "react-hydration-errors"` paired with `outcome: "filtered"` — confirming `reason` is a general dimension across every outcome, not specific to quota drops, so the query must filter on `outcome == "rate_limited"` before reading `reason`, never read `reason` alone. Expect: two numbers; when `keyquota` is nonzero, file the finding pointing at SNTRY-003 (raise or remove the unlimited key's rate limit); when only `spike` is nonzero, point at Spike Protection tuning instead of the key-quota remediation. Zero on both is a pass. A refused stats read prints `SNTRY-019 blocked: org stats (by reason) read returned <status>`: no numbers, never a pass. **Correlate:** SNTRY-008 (the same drops, unsplit), SNTRY-104 (spike-protection liveness — a nonzero `spike` figure here is the same live proof SNTRY-104 uses), SNTRY-003 (the key-quota remediation target).

**SNTRY-020, deterministic source-map verdict via event `errors[]`, plus independent upload-pipeline proof.** SNTRY-006 infers broken source maps from a *heuristic* — sampling one event's in-app frames and checking for `context`. Sentry's own event payload carries a **top-level `errors[]` array** that states symbolication failure explicitly and needs no frame heuristic:

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-js-project-slug"   # a JavaScript/TypeScript project from projects.json
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
code="$(curl -sS -o "${TMPD}/issues.json" -w '%{http_code} %{content_type}' --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/issues/?statsPeriod=14d&query=is:unresolved&limit=1")" || code="curl-exit-$? ${code:-}"
case "$code" in "200 application/json"*) ;; *) echo "SNTRY-020 blocked: ${PROJECT} issues read returned ${code:-no response}"; exit 0 ;; esac
ISSUE_ID="$(jq -r '.[0].id // empty' "${TMPD}/issues.json")"
[ -n "$ISSUE_ID" ] || { echo "SNTRY-020 blocked: no recent issue in ${PROJECT}"; exit 0; }

code="$(curl -sS -o "${TMPD}/event.json" -w '%{http_code} %{content_type}' --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/organizations/${SENTRY_ORG}/issues/${ISSUE_ID}/events/latest/")" || code="curl-exit-$? ${code:-}"
case "$code" in "200 application/json"*) ;; *) echo "SNTRY-020 blocked: ${PROJECT} latest event read returned ${code:-no response}"; exit 0 ;; esac
tee /dev/stderr < "${TMPD}/event.json" \
  | jq -r '
      [ .errors[]? | select(.type == "js_no_source" or (.type | test("no_source|missing_source|symbolic"; "i"))) ] as $symerrs
      | if ($symerrs | length) > 0
        then "SNTRY-020 fail: \($symerrs[0].type) — \($symerrs[0].message) (deterministic, from event.errors[])"
        else "SNTRY-020 pass: event.errors[] carries no symbolication-error entry" end
'
```

**Confirmed live** on a real org: a sampled event's top-level `errors[]` returned exactly `[{"type": "js_no_source", "message": "Source code was not found", "data": {"symbolicator_type": "missing_source", "url": "app:///"}}]` — proving the field, the exact `type` string, and the deterministic verdict path all exist and fire on real (non-synthetic) data. A second sampled event on the same project returned `errors: []`, confirming the healthy shape too. Read the verdict as independent of, and stronger than, SNTRY-006's frame-context heuristic: a non-empty `errors[]` with a symbolication-type entry is Sentry's own server-side statement that resolution failed, not an inference from frame shape. A refused issues or event read (a non-200 or non-JSON response, or no response) prints `SNTRY-020 blocked: <project> ... read returned <status>`, never a pass.

Second half — probe the upload pipeline independently of event sampling, so a project with no recent unresolved issue (SNTRY-006/020 blocked) can still be judged on whether artifacts were even uploaded:

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-js-project-slug"
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

ab="$(mktemp)"; trap 'rm -f "$ab"' EXIT
code="$(curl -sS -o "$ab" -w '%{http_code} %{content_type}' --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/files/artifact-bundles/")" || code="curl-exit-$? ${code:-}"
case "$code" in "200 application/json"*) ;; *) echo "SNTRY-020 blocked: ${PROJECT} artifact bundles read returned ${code:-no response}"; exit 0 ;; esac
tee /dev/stderr < "$ab" \
  | jq -r 'if length == 0
      then "SNTRY-020 upload-pipeline fail: no artifact bundles uploaded for '"${PROJECT}"'"
      else "SNTRY-020 upload-pipeline pass: \(length) artifact bundle(s), most recent \(map(.dateModified) | max)" end'
```

**Confirmed live:** the endpoint returns 200 with a JSON array of `{bundleId, associations: [{release, dist}], fileCount, dateModified, date}`. On the sampled org, bundles existed with a **non-null** `release` in every `associations[]` entry — do not read that as evidence a null `release` means broken; the schema documents `release: null` as the normal shape for a debug-ID bundle that resolves independently of any release association, so score only on bundle *presence*, never on whether `release` is populated. A refused artifact-bundles read prints `SNTRY-020 blocked: <project> artifact bundles read returned <status>`, never an upload-pipeline pass or fail. A project with artifact bundles present but its sampled event still showing `errors[].type == "js_no_source"` is not a contradiction — name it as its own finding: the upload pipeline works, but resolution is still failing (wrong `dist`, wrong URL prefix, or a bundle that does not cover the failing file), which is a more specific, more actionable defect than "source maps are broken." **Correlate:** SNTRY-006 (same VCS/release surface, heuristic half), SNTRY-009 (a broken code-mapping chain is one of the reasons resolution can fail even with bundles present).

**SNTRY-021, repo integrity.** `/organizations/{org}/repos/` can carry entries created by a misconfigured `sentry-cli set-commits` run: a generic `origin` repo with no real VCS provider behind it. Once release commits bind to that repo, the release looks like it has commit data, but nothing resolves through it — no PR link, no blame, no code-mapping can attach to it:

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

rp="$(mktemp)"; trap 'rm -f "$rp"' EXIT
code="$(curl -sS -o "$rp" -w '%{http_code} %{content_type}' --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/organizations/${SENTRY_ORG}/repos/")" || code="curl-exit-$? ${code:-}"
case "$code" in "200 application/json"*) ;; *) echo "SNTRY-021 blocked: org repos read returned ${code:-no response}"; exit 0 ;; esac
tee /dev/stderr < "$rp" \
  | jq -r '.[] | select(.provider.id != null and (.provider.id | startswith("integrations:")) | not)
      | "SNTRY-021 fail: repo \(.name) (id=\(.id)) has provider.id=\(.provider.id // "null") — not a real VCS integration"'
```

**Confirmed live** on a real org: this exact query returned one row — a repo named `origin`, `provider.id: "unknown"`, `url: null`, `integrationId: null` — sitting alongside several dozen legitimate `provider.id: "integrations:github"` repos with real GitHub URLs and integration ids. This is precisely the `sentry-cli set-commits` junk-repo pattern the check targets, caught on the first live read. Expect: no rows on a clean estate; a row names the repo (never the org's real repo names in this skill's own text — that is customer data, not a schema fact) and its `provider.id`. A refused read prints `SNTRY-021 blocked: org repos read returned <status>`, never "no rows". Escalate when `releases.json` shows this repo's `id` referenced by a release with nonzero `commitCount`: those commits are bound to a repo that cannot resolve anything. **Correlate:** SNTRY-009 (this is the "link 1 broken" case stated precisely instead of "no active GitHub integration" — a junk `origin` repo can coexist with a real, separately-connected GitHub integration, so SNTRY-009's step 1 can pass while this still fails), SNTRY-022 (a code mapping pointing at this repo id is doubly broken).

**SNTRY-022, code-mapping plausibility.** `/organizations/{org}/code-mappings/` (or the per-project stacktrace-link config) can carry mappings that are syntactically valid but structurally implausible: two mappings for the same `{projectId, repoId}` pair whose `stackRoot` differs only by a `./` segment (both resolve the same tree, so one is redundant and their precedence order is unproven), a `stackRoot` rooted under a build-host path that never survives past the CI runner, or one project routing an unusually large number of mappings into a single repo:

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
MAX_MAPPINGS_PER_REPO="5"   # example, tune to your monorepo layout

cm="$(mktemp)"; trap 'rm -f "$cm"' EXIT
code="$(curl -sS -o "$cm" -w '%{http_code} %{content_type}' --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/organizations/${SENTRY_ORG}/code-mappings/?per_page=100")" || code="curl-exit-$? ${code:-}"
case "$code" in "200 application/json"*) ;; *) echo "SNTRY-022 blocked: org code-mappings read returned ${code:-no response}"; exit 0 ;; esac
# The verdict needs every mapping: a full page means more pages, so judge Phase 1's paged copy instead.
CM_COUNT="$(jq 'length' "$cm")"
[ "${CM_COUNT}" -lt 100 ] || { echo "SNTRY-022 blocked: org has 100+ code mappings; judge raw/code-mappings.json instead"; exit 0; }
[ "${CM_COUNT}" -gt 0 ] || { echo "SNTRY-022 n/a: no code mappings to judge; SNTRY-009 step 2 owns the missing mappings"; exit 0; }
# One row per offending mapping or project/repo pair, then the verdict: pass only when none offends.
tee /dev/stderr < "$cm" \
  | jq -r --argjson maxper "${MAX_MAPPINGS_PER_REPO}" '
      # normalize: strip a trailing or leading "./" segment so "foo/" and "foo/./" (or "./foo/")
      # compare equal — confirmed live shape uses a trailing "./", the check tolerates a leading one too.
      def norm: gsub("^\\./"; "") | gsub("/\\./$"; "/") | gsub("/\\.$"; "/");
      [ .[] | {id, projectId, repoId, stackRoot: (.stackRoot // ""),
               pair: ((.projectId|tostring) + "|" + (.repoId|tostring))}
            | .key = (.pair + "|" + (.stackRoot|norm)) ] as $rows
      | [ $rows | group_by(.key)[] | select(length > 1) ] as $dupes
      | [ $rows[] | select(.stackRoot | test("^/(tmp|home|Users)(/|$)")) ] as $buildhost
      | [ $rows | group_by(.pair)[] | select(length > $maxper) ] as $overrouted
      | ( $dupes[][] | "SNTRY-022 duplicate: mapping \(.id) project \(.projectId) repo \(.repoId) stackRoot \(.stackRoot | tojson)" ),
        ( $buildhost[] | "SNTRY-022 build-host: mapping \(.id) project \(.projectId) repo \(.repoId) stackRoot \(.stackRoot | tojson)" ),
        ( $overrouted[] | "SNTRY-022 over-routed: project \(.[0].projectId) routes \(length) mappings into repo \(.[0].repoId) (ceiling \($maxper)): mappings \(map(.id | tostring) | join(","))" ),
        ( if ($dupes | length) + ($buildhost | length) + ($overrouted | length) == 0
          then "SNTRY-022 pass: \($rows | length) code mapping(s); none duplicated, under a build-host path, or over the per-repo ceiling"
          else "SNTRY-022 fail: \($dupes | length) duplicate group(s), \($buildhost | length) build-host stackRoot(s), \($overrouted | length) over-routed project/repo pair(s)" end )'
```

**Confirmed live** on a real org: this endpoint returned 16 code mappings, and among them two rows shared the *same* `{projectId, repoId}` pair with `stackRoot` values differing only by a trailing `./` segment (the general shape this check normalizes away before grouping) — a real duplicate, not a constructed one. The same read also showed one project routing mappings into a single repo well past the example `MAX_MAPPINGS_PER_REPO` default of 5 (into the high single digits), confirming the over-routed case fires on real data too. Re-run with this command, the same org printed the duplicate pair, the over-routed project and eight build-host `stackRoot`s, then `SNTRY-022 fail`. Also confirmed: `code-mappings.json` field types are `id`/`projectId`/`repoId` as **JSON strings** (observed as numeric-looking string values, e.g. `"921900"`) whereas `stats_v2`'s `by.project` is a JSON **number** — never compare these across endpoints without an explicit `tostring`/`tonumber` normalization; the jq above stays within one endpoint's own string-typed ids and never mixes them with `stats_v2`. A pre-existing display-only snippet earlier in this file (`## Integration and source context checks`, the SNTRY-009 step 2 dump) named this same field `repositoryId`; the real field is `repoId` — fixed there too as part of this live-verification pass, since a display-only `jq` selecting a field that does not exist silently prints `null` instead of the value. Expect: `SNTRY-022 pass: <n> code mapping(s); ...` when there are no duplicate-key groups, no build-host `stackRoot`, and no repo receiving more than `MAX_MAPPINGS_PER_REPO` mappings from one project. Otherwise each offending mapping prints a `SNTRY-022 duplicate:` or `SNTRY-022 build-host:` row and each over-routed project/repo pair a `SNTRY-022 over-routed:` row, then `SNTRY-022 fail:` with the three counts; quote those rows as the evidence. A refused read prints `SNTRY-022 blocked: org code-mappings read returned <status>`, never a pass. The read asks for 100 mappings: a full page means more pages exist, so the block prints `SNTRY-022 blocked: org has 100+ code mappings` instead of judging a part of the set (judge Phase 1's paged `raw/code-mappings.json` instead), and an empty list prints `SNTRY-022 n/a`, because SNTRY-009 step 2 owns the missing mappings. A duplicate pair is `low` (redundant, not broken); a build-host `stackRoot` is the finding to escalate (it means the mapping was generated from a local dev machine or an ephemeral CI path, not the checked-out repo root, and will never resolve in production). **Correlate:** SNTRY-009 (a broken or implausible mapping is "link 2" or "link 3" of the same VCS chain), SNTRY-021 (a mapping pointing at a non-integration repo is doubly broken).

**SNTRY-023, zero-monitor posture.** `/organizations/{org}/monitors/` returning an empty list is not itself a finding — many estates genuinely have no scheduled jobs — but on an org with backend projects that carry real accepted-event volume, zero monitors means no cron/uptime coverage exists to be audited at all, and that absence deserves an explicit line in the report rather than silently vanishing from the Monitors category:

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
code="$(curl -sS -o "${TMPD}/monitors.json" -w '%{http_code} %{content_type}' --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/organizations/${SENTRY_ORG}/monitors/")" || code="curl-exit-$? ${code:-}"
case "$code" in "200 application/json"*) ;; *) echo "SNTRY-023 blocked: org monitors read returned ${code:-no response}"; exit 0 ;; esac
MON_COUNT="$(tee /dev/stderr < "${TMPD}/monitors.json" | jq 'length')"
if [ "${MON_COUNT}" -gt 0 ]; then
  echo "SNTRY-023 not-in-scope: ${MON_COUNT} monitor(s) exist; SNTRY-007 judges them"
  exit 0
fi
# Zero monitors: check whether any non-browser (backend) project carries recent accepted volume,
# using the same numeric-id join SNTRY-001/012 already use against stats-projects.json.
STATS="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/$(date -u +%Y-%m-%d)/raw/stats-projects.json"
[ -f "${STATS}" ] || { echo "SNTRY-023 blocked: org stats-projects.json is missing from this run's raw dump (see blocked-reads.tsv)"; exit 0; }
code="$(curl -sS -o "${TMPD}/projects.json" -w '%{http_code} %{content_type}' --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/organizations/${SENTRY_ORG}/projects/")" || code="curl-exit-$? ${code:-}"
case "$code" in "200 application/json"*) ;; *) echo "SNTRY-023 blocked: org projects read returned ${code:-no response}"; exit 0 ;; esac
jq -r '.[] | select(.platform | test("^(javascript|electron|cordova|react-native|unity|flutter)") | not) | "\(.id)\t\(.slug)"' "${TMPD}/projects.json" \
  | while IFS="$(printf '\t')" read -r pid pslug; do
      acc=$(jq -r --arg pid "$pid" '[ .groups[]? | select((.by.project|tostring) == $pid) | select(.by.outcome=="accepted") | .totals["sum(quantity)"] ] | add // 0' "${STATS}")
      if [ "${acc:-0}" -gt 0 ]; then echo "SNTRY-023 info: 0 monitors exist; backend project ${pslug} accepted ${acc} events in the window with no cron/uptime monitor to audit"; fi
    done
```

**Confirmed live** on a real org: `/organizations/{org}/monitors/` returned `[]` (zero monitors), and the org's backend (non-browser-platform) projects included one that accepted several thousand error events in the 14-day window per `stats-projects.json` — the exact condition this check targets, found on the first live read. Expect: `not-in-scope` when monitors exist (SNTRY-007 owns them from there); otherwise one `info` line per backend project with live volume, or nothing when every backend project is also silent (in which case SNTRY-012's coverage row already names the deeper problem). A refused monitors or projects read, or a missing `stats-projects.json`, prints `SNTRY-023 blocked: ...`: a monitors read that failed is never "0 monitors". This finding is deliberately `info` severity with `points_recoverable: 0` — it is a prompt to decide whether monitors belong here, not a proven gap, since the absence of monitors could equally mean no scheduled jobs exist to watch. **Correlate:** SNTRY-007 (owns any monitor that does exist), SNTRY-012 (a backend project with volume and zero monitors is a different gap than the same project with zero *events*).

**SNTRY-024, `firstEvent: null` split in the coverage check.** SNTRY-012 currently reads a mapped project's **recent** accepted-event count from `stats-projects.json` and calls a zero-count project "dead." Project detail also carries `firstEvent`, which distinguishes two differently-remediated cases that a bare recent-volume-of-zero reading conflates: a project that has **never** received a single event (`firstEvent: null` — the SDK was never wired up, or never fired) versus a project that received events at some point and then went quiet (`firstEvent` is a real timestamp, but `stats-projects.json` shows zero *recent* accepted events):

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # a project mapped to a critical service (SNTRY-012)
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

# Project detail carries the project's securityToken: keep the response in memory, never in a file.
resp="$(curl -sS -w '\n%{http_code} %{content_type}' --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/")" || resp="curl-exit-$? $(printf '%s\n' "${resp:-}" | tail -n 1)"
code="$(printf '%s\n' "$resp" | tail -n 1)"
case "$code" in "200 application/json"*) ;; *) echo "SNTRY-024 blocked: ${PROJECT} project detail read returned ${code:-no response}"; exit 0 ;; esac
printf '%s\n' "$resp" | sed '$d' \
  | jq '{ slug, firstEvent }' \
  | tee /dev/stderr \
  | jq -r 'if .firstEvent == null
      then "SNTRY-024: \(.slug) never instrumented (firstEvent is null) — wire the SDK, this is not a drop-off"
      else "SNTRY-024: \(.slug) firstEvent=\(.firstEvent) — instrumented at some point; cross-check stats-projects.json recent-volume for a drop-off" end'
```

**Confirmed live** on a real org: one project (a Python backend) returned `firstEvent: null` while five sibling projects on the same org all returned real ISO timestamps — proving both branches of this check occur on the same estate and that the field reliably distinguishes them. Expect: every project mapped to a critical service resolves one of the two branches, or prints `SNTRY-024 blocked: <project> project detail read returned <status>` when the read is refused (never read as "never instrumented"); feed the branch into SNTRY-012's finding wording — "never instrumented, wire the SDK" is a setup gap (`setup-sentry#projects`), "instrumented, now silent" is an investigate-the-drop gap (check the deploy that removed instrumentation, or a DSN rotation that broke ingestion). Do not merge the two into one "dead project" sentence; they point the reader at opposite next actions. **Correlate:** SNTRY-012 (this check refines that finding's wording, it does not replace it), SNTRY-004 (a project that was never instrumented also has no real environment traffic to require an environment for).

**SNTRY-025, environment-name sprawl.** Every environment-scoped check (SNTRY-102, SNTRY-013, and SNTRY-004's own baseline match) trusts that a project's environment list has one canonical name per real environment. A project that accumulated both `prod` and `production` — usually from two SDK configs written at different times, or a staging config copy-pasted into a new service — makes every environment-scoped rule only ever see half the traffic, silently, because Sentry treats them as two unrelated environments:

```bash
set -eu
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '[ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; fi; fi
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

envs="$(mktemp)"; trap 'rm -f "$envs"' EXIT
code="$(curl -sS -o "$envs" -w '%{http_code} %{content_type}' --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/environments/")" || code="curl-exit-$? ${code:-}"
case "$code" in "200 application/json"*) ;; *) echo "SNTRY-025 blocked: ${PROJECT} environments read returned ${code:-no response}"; exit 0 ;; esac
tee /dev/stderr < "$envs" \
  | jq -r '
      [ .[].name | ascii_downcase ] as $names
      | [ ["prod","production"], ["pp","preprod","pre-prod"], ["stage","staging"] ] as $groups
      | [ $groups[] | . as $g | select( ([ $names[] | select(. as $n | $g | index($n)) ] | length) > 1 ) | $g ] as $hits
      | if ($hits | length) > 0
        then "SNTRY-025 fail: synonym collision in environment names — \($hits | map(join("/")) | join(", ")) all present"
        else "SNTRY-025 pass: no synonym collision among \($names | join(","))" end'
```

**Confirmed live** on a real org: one project's environment list (ten names, mixing cloud-provider tags, promotion stages, and ad hoc variants) carried a real, live synonym collision on **two** of the three declared families at once — both a `prod`-family pair and a `pp`/`preprod`-family pair present together on the same project — plus additional prod-like variant names outside all three declared families, which the canonical-map heuristic does not attempt to catch and states as its honest limit. A sibling project on the same org returned a small, clean environment list with no collision, confirming the check reads healthy and unhealthy estates correctly on the same org. Expect: `SNTRY-025 pass` on a clean project; a `SNTRY-025 fail` row names the colliding family. A refused read prints `SNTRY-025 blocked: <project> environments read returned <status>`, never a pass. This check's canonical map is deliberately narrow (three example families) — extend it in your own fork of this check for house-specific synonyms, and never treat a name outside the three groups as a false pass; it is simply not covered by this pass, not proven clean. **Correlate:** SNTRY-102 (a rule scoped to `environment: "production"` on a project that also ingests under `prod` silently misses that half of the traffic — this is the root cause SNTRY-102 cannot see from its own read), SNTRY-013 (the same half-match risk applies to tier-coverage environment scoping), SNTRY-004 (the baseline single-name match has the same blind spot at a smaller scale).
