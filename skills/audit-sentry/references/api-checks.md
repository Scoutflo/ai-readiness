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
| Metric alerts | GET | `/organizations/{org}/alert-rules/` | Paginated; threshold-based alerts, distinct from issue rules |
| Workflow-engine rules | GET | `/organizations/{org}/workflows/` | Feature-gated; a 404 means the feature is absent, not that the org is broken |
| Volume and outcomes | GET | `/organizations/{org}/stats_v2/` | `groupBy=category`, `groupBy=outcome`, `groupBy=project`; source for quota and privacy-telemetry checks |
| Project detail | GET | `/projects/{org}/{project}/` | Privacy flags, scrubbers, sensitive fields, source-scrape setting |
| Project issue rules | GET | `/projects/{org}/{project}/rules/` | The primary alerting surface; always list this per project regardless of workflow-engine availability |
| Project environments | GET | `/projects/{org}/{project}/environments/` | Environment inventory |
| Project client keys | GET | `/projects/{org}/{project}/keys/` | Keep only `name`, `isActive`, `rateLimit`; never store the DSN |
| Project uptime monitors | GET | `/projects/{org}/{project}/uptime/` | Tolerate 404 when the feature or the project has none; confirmed live that a real Sentry SaaS org can also answer this path with `405 Method Not Allowed` (`{"detail":"Method \"GET\" not allowed."}`) rather than 404 — the fallback (`|| echo '[]'`) already covers this shape too, so no behavior change, just don't be surprised by the status code |
| Issue list | GET | `/organizations/{org}/issues/` | Sample recent issues per project for the source-map minified-frame check; never use its length as a total |
| One event | GET | `/organizations/{org}/issues/{id}/events/latest/` | Requires `event:read`; source for the minified-frame check |

## Pagination and rate limits

Sentry paginates with an RFC 5988 `Link` header, not an offset parameter. Every listing call in Phase 1 goes through one helper that follows `rel="next"` until the header stops offering one:

```bash
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
| Issue rules, metric alerts, workflow rules | `alerts:read` |
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

**Step 3: pull the batch's raw data, then mark rows done.** A project is marked `done` only after every one of its pulls succeeds, so an interrupted batch resumes at the project that failed, not the start of the batch.

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
RUN_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/runs/20260717T140500Z"   # example; this run's resolved RUN_DIR
WORKLIST="${RUN_DIR}/worklist.tsv"
BATCH="checkout
payments"   # example; the batch claimed in step 2, one slug per line

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

echo "${BATCH}" | while IFS= read -r p; do
  [ -n "$p" ] || continue
  d="${RUN_DIR}/raw/projects/${p}"; mkdir -p "$d"
  ok=1
  curl -fsS --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    "${API}/projects/${SENTRY_ORG}/${p}/" > "${d}/detail.json" || ok=0
  fetch_all "${API}/projects/${SENTRY_ORG}/${p}/rules/"        > "${d}/rules.json"        || ok=0
  fetch_all "${API}/projects/${SENTRY_ORG}/${p}/environments/" > "${d}/environments.json" || ok=0
  fetch_all "${API}/projects/${SENTRY_ORG}/${p}/keys/" \
    | jq 'map({name, isActive, rateLimit})' > "${d}/keys.json" || ok=0
  [ -s "${d}/keys.json" ] || echo '[]' > "${d}/keys.json"
  fetch_all "${API}/projects/${SENTRY_ORG}/${p}/uptime/" > "${d}/uptime.json" 2>/dev/null || echo '[]' > "${d}/uptime.json"
  if [ "$ok" -eq 1 ]; then
    awk -F'\t' -v s="$p" 'BEGIN{OFS="\t"} $1==s{$2="done"} 1' "${WORKLIST}" > "${WORKLIST}.tmp" && mv "${WORKLIST}.tmp" "${WORKLIST}"
    echo "done: ${p}"
  else
    echo "failed: ${p}; stays pending, will retry on the next batch"
  fi
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
cp -R "${RUN_DIR}/raw/projects/." "${RAW_DIR}/projects/"
# Apply the same operator-PII redaction the small/medium path runs (SKILL.md Phase 1):
# null every `.email` key across the merged raw dump so a leak-scan of the audit dir
# stays clean. No check reads an email, so nothing a check needs is touched.
find "${RAW_DIR}" -name '*.json' -type f | while read -r rf; do
  jq 'walk(if type == "object" and has("email") then .email = null else . end)' "$rf" > "${rf}.red" 2>/dev/null \
    && mv "${rf}.red" "$rf" || rm -f "${rf}.red"
done
echo "merged $(find "${RAW_DIR}/projects" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ') project directories into ${RAW_DIR}"
```

Expect: `worklist incomplete` and a nonzero exit on a partial run; the merge only happens once `pending=0`. After merging, run the org-level fetches (`teams.json`, `integrations.json`, `releases.json`, `monitors.json`, `metric-alerts.json`, `org.json`, the stats calls) from the Phase 1 block in [SKILL.md](../SKILL.md#phase-1-inventory) exactly as written; they are cheap and were never batched.

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
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/" \
  | tee /dev/stderr \
  | jq -e '{ dataScrubber, dataScrubberDefaults, sensitiveFields,
             scrubIPAddresses, scrapeJavaScript } as $p
           | ($p.dataScrubber == true) and ($p.dataScrubberDefaults == true)
             and (($p.sensitiveFields | length) > 0) and ($p.scrapeJavaScript == false)' >/dev/null \
  && echo "SNTRY-002 pass: ${PROJECT}" || echo "SNTRY-002 fail: ${PROJECT}"
```

Expect: exit 0 and `SNTRY-002 pass: <project>`. The assertion requires `dataScrubber` and `dataScrubberDefaults` both `true`, a non-empty `sensitiveFields` array, and `scrapeJavaScript` `false`; treat `scrubIPAddresses: false` as a judgment call, not an automatic fail, only when your team has a recorded policy reason to keep IPs. Any production project the assertion fails is a high finding.

**Blast radius — quantify what is already stored, do not restate the principle.** "PII that reaches Sentry cannot be unsent" is a scanner line until you attach the volume already retained. Join the failing project's numeric id to `stats-projects.json` accepted-error count for the same window: *"this project accepted E error events in 14d with scrubbing off — E events of raw request bodies, headers, and user context are already retained and unrecoverable."* Reuse the numeric-id volume snippet from SNTRY-001 (same `stats-projects.json`, same `accepted` outcome). When SNTRY-010 shows accepted volume in the replay or profile categories for the same project, **escalate**: session replays carry DOM snapshots and keystrokes — far higher-fidelity PII than an error payload — so the same E is a worse breach. **Correlate:** SNTRY-010 (live replay/profile ingestion raises the PII fidelity), SNTRY-003 (an unlimited key removes the volume ceiling on the unscrubbed ingestion), and SNTRY-105 (no inbound filters means bot/extension junk also lands unscrubbed).

**SNTRY-003, client-key rate limits.** Every active key on every project needs a limit:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/keys/" \
  | tee /dev/stderr \
  | jq -e '[ .[] | select(.isActive) ] | all(.rateLimit != null)' >/dev/null \
  && echo "SNTRY-003 pass: ${PROJECT}" || echo "SNTRY-003 fail: ${PROJECT}"
```

Expect: exit 0 and `SNTRY-003 pass: <project>`. `rateLimit: null` on an active key means one crash loop or one leaked DSN can burn the whole project quota; a fail exit files per project with the key names (never the DSN) in `affected`.

**Blast radius — check whether the burn is already live, do not leave it hypothetical.** An unlimited key that is calm today scores the same as one actively dropping fatal events unless you join it to the org-wide drop outcomes the audit already pulled. Read `stats-outcomes.json` for org-wide `rate_limited`/`abuse`/`cardinality_limited` totals in the window:

```bash
set -eu
STATS="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/$(date -u +%Y-%m-%d)/raw/stats-outcomes.json"
jq -r '
  [ .groups[]? | select(.by.outcome == "rate_limited" or .by.outcome == "abuse" or .by.outcome == "cardinality_limited")
    | .totals["sum(quantity)"] ] | add // 0
  | "SNTRY-003 org-wide drops to rate_limited/abuse/cardinality in window: \(.) events"' "$STATS"
```

If that count D is nonzero, state the shared-quota mechanism: *"key `<name>` on `<project>` is unlimited AND the org already dropped D events to rate_limited/abuse in 14d — on a shared org quota, one noisy project's crash loop is already crowding out real fatal events from other projects."* If D is zero, state the ceiling honestly: *"unbounded, not yet firing."* Do **not** attribute the specific D drops to this specific key — the outcomes stats are org-wide and per-key attribution is not provable from `stats_v2`; D is the shared-quota pressure the unlimited key contributes to, not proof this key caused those drops. **Correlate:** SNTRY-008 (the live drop outcomes *are* the shared-quota evidence — same numbers, joined), SNTRY-002 (unlimited + unscrubbed = unbounded PII), SNTRY-105 (filters would relieve the same quota).

**SNTRY-004, environments.** Confirm the environment your production traffic actually runs under exists:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
ENV_REQUIRED="production"   # example baseline; tune to your promotion flow

curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/environments/" \
  | tee /dev/stderr \
  | jq -e --arg env "$ENV_REQUIRED" '[ .[] | .name ] | index($env) != null' >/dev/null \
  && echo "SNTRY-004 pass: ${PROJECT}" || echo "SNTRY-004 fail: ${PROJECT}"
```

Expect: exit 0 and `SNTRY-004 pass: <project>`. A project with no matching environment cannot scope alert rules or releases to production, so every rule on it fires on every environment's traffic, dev noise included.

## Alert rule checks

Snippets for SNTRY-001, SNTRY-005, SNTRY-011, SNTRY-013, SNTRY-014. All read from `/projects/{org}/{project}/rules/`, re-fetched per project, cross-checked against `integrations.json` from Phase 1.

**Condition and filter reference**, needed to classify each rule into a tier and to catch the environment-scoping bug:

| Rule name | Condition ID | Tier signal |
| --- | --- | --- |
| Any event | `sentry.rules.conditions.every_event.EveryEventCondition` | immediate only when paired with a level filter; every-event with no filter and a paging action is noise (SNTRY-014) |
| New issue | `sentry.rules.conditions.first_seen_event.FirstSeenEventCondition` | review |
| Regression | `sentry.rules.conditions.regression_event.RegressionEventCondition` | immediate |
| Escalation | `sentry.rules.conditions.escalating_event.EscalatingEventCondition` | immediate |
| Event frequency > N in interval | `sentry.rules.conditions.event_frequency.EventFrequencyCondition` | immediate when interval is short and threshold is business-relevant |
| Unique users > N in interval | `sentry.rules.conditions.event_frequency.EventUniqueUserFrequencyCondition` | immediate |
| Session/event percent > N% | `sentry.rules.conditions.event_frequency.EventFrequencyPercentCondition` | immediate |
| High priority, new issue | `sentry.rules.conditions.high_priority_issue.NewHighPriorityIssueCondition` | immediate |
| High priority, existing issue | `sentry.rules.conditions.high_priority_issue.ExistingHighPriorityIssueCondition` | review |

| Filter name | Filter ID | Reading it correctly |
| --- | --- | --- |
| Level | `sentry.rules.filters.level.LevelFilter` | `level` plus `match: "eq"/"gte"/"lte"` |
| Error is unhandled | `sentry.rules.filters.event_attribute.EventAttributeFilter` | `attribute: "error.unhandled"`, `match: "is"`. A rule using `match: "eq"` here is misconfigured, not merely undocumented; file it as a noise or coverage defect depending on direction |
| HTTP status starts with 5 | `sentry.rules.filters.event_attribute.EventAttributeFilter` | `attribute: "http.status_code"`, `match: "sw"`, `value` as an integer; a string `value` silently never matches |
| Issue category | `sentry.rules.filters.issue_category.IssueCategoryFilter` | narrows by issue type, not environment |
| Release-adoption stage | `sentry.rules.filters.latest_adopted_release.LatestAdoptedReleaseFilter` | filters by whether the release has reached an adoption stage, **not** by environment. A rule using this filter with an `environment` field set is not environment-scoped by it; the only true environment scope on an issue rule is the rule object's own top-level `environment` field. Treat any rule that relies on `LatestAdoptedReleaseFilter` to mean "production only" as a coverage defect: it fires on every environment. |

**SNTRY-001, default auto-created rule.** Sentry auto-creates a "Send a notification for high priority issues" rule on projects created without `defaultRules: false`, and marks it `createdBy: null`:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
  | tee /dev/stderr \
  | jq -e '[ .[] | select(.createdBy == null and (.name | test("high priority"; "i"))) ] | length == 0' \
    >/dev/null \
  && echo "SNTRY-001 pass: ${PROJECT}" || echo "SNTRY-001 fail: ${PROJECT}"
```

Expect: exit 0 and `SNTRY-001 pass: <project>`. A nonzero-length match (exit 1, `SNTRY-001 fail`) is the finding: an unowned `createdBy == null` high-priority rule with a `NotifyEmailAction targetType=Members` action.

**Blast radius — compute the fan-out, never assert it.** The pass/fail above finds the unowned rule; the finding's blast radius is the fan-out it causes, and both numbers are already in the estate this run pulled. Join the org member count with this project's accepted-error volume: *"the unowned high-priority rule pages all N org members on every high-priority issue; this project accepted E error events in the 14d window, so it is E pages fanned to N inboxes — the mechanism that trains the whole org to filter Sentry to a folder."* The member count needs `member:read`, which is an **optional** ownership add-on in the doctor gate, not the base `org:read`+`project:read`+`alerts:read` recipe, so the fan-out quantifier degrades to `blocked` on a 403 while the `createdBy == null` finding still stands on its own — never emit a fabricated member count N:

```bash
set -eu
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

**SNTRY-005, receiver liveness.** Cross-check every rule action against the live integrations list. An action is proven only when its referenced integration exists and is active:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
# INTEGRATIONS_JSON: re-fetch or point at this run's raw dump, e.g.
# ./scoutflo-audits/sentry/$(date -u +%Y-%m-%d)/raw/integrations.json
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
```

Reading order for a fail:

- `email` actions are `configured`, a temporary path; credit them as present, never as a proven paging route on their own.
- `chat-with-channel-id` with a matching active integration is the strongest signal short of a delivered notification.
- `chat-name-only` (a channel name with no ID) cannot be resolved from this API alone; treat as unproven and note the gap.
- An action referencing an integration `id` absent from `integrations.json`, or present but not `active`, is a dead route: the rule looks configured and delivers nothing.

An org where every rule's only actions are email, or reference dead integrations, is critical: incidents fire and nobody finds out through a channel anyone actually watches.

**SNTRY-013, tier coverage.** For each production project, bucket its rules by the condition table above into immediate versus review, and check environment scope using the rule's own `environment` field, not any filter:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
# Condition IDs mapped from the tier table above; immediate first, review second.
IMMEDIATE_RE='RegressionEventCondition|EscalatingEventCondition|EventFrequencyCondition|EventUniqueUserFrequencyCondition|EventFrequencyPercentCondition|NewHighPriorityIssueCondition'
REVIEW_RE='FirstSeenEventCondition|ExistingHighPriorityIssueCondition'

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
```

Expect: exit 0 and `SNTRY-013 pass: <project>`. The assertion checks tier presence only; still confirm by eye that each tier's `environment` is set to your production environment name or intentionally `all` on a single-environment project. A project with only review-tier conditions, or with every rule scoped to `all` on a multi-environment project, is a coverage gap.

**Tier presence excludes non-active rules (gated by SNTRY-016).** The `select((.status // "active") == "active")` filter above is load-bearing: without it a `status: disabled` immediate rule would still satisfy tier presence, so a project reads as covered while the rule that is supposed to page fires nothing. SNTRY-013 and SNTRY-016 must agree on the same estate — a disabled immediate rule that this filter drops from tier coverage is exactly what SNTRY-016 files as a finding. If you ever loosen this filter, SNTRY-016 and SNTRY-013 disagree and a switched-off rule silently credits coverage again.

**SNTRY-014, noise posture.** From the same rule dump:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
FREQ_FLOOR_MIN="30"   # example, tune to your event volume

curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
  | tee /dev/stderr \
  | jq -e --argjson floor "$FREQ_FLOOR_MIN" '
    [ .[] | select(
        (.conditions | any(.id | test("EveryEventCondition"))) and (.filters | length == 0)
        or (.frequency // 999999) < $floor
      ) ] | length == 0' >/dev/null \
  && echo "SNTRY-014 pass: ${PROJECT}" || echo "SNTRY-014 fail: ${PROJECT}"
```

Expect: exit 0 and `SNTRY-014 pass: <project>`. A fail is either an unfiltered every-event condition with a paging action (pages on every single error at any level) or a re-page frequency below your floor (repeatedly re-pages the same open issue). Both train responders to mute the channel.

A rule migrated to Sentry's newer workflow-engine model can come back from `/rules/` with both `conditions: []` and `filters: []` yet carry a non-empty `errors` array (for example `"Filter not supported: issue_priority_greater_or_equal"`) — confirmed live. Read as literally empty conditions/filters, this jq would flag it as an unconditioned catch-all every time; check for a populated `errors` array first and treat that case as "condition present but not representable in this API view," not proven noise, before scoring SNTRY-014 fail on it.

**SNTRY-015, orphaned detectors (workflow-engine orgs, capability-gated).** Probe the org-level detectors endpoint once. It 404s on classic-model orgs — that is `not-in-scope`, not a fail. On a 200, a *non-built-in* detector with an empty `workflowIds` array detects a condition but drives no automation, so it notifies nobody (the new-model equivalent of SNTRY-001/SNTRY-005's no-receiver case). **Exclude the built-in `error` and `issue_stream` detector types (grounded live):** every org carries ~6 `error` and ~6 `issue_stream` detectors whose empty `workflowIds` is *by design* (they pair with the issue-stream/metric automation, not their own workflowIds) — counting them flags ~7 phantom orphans against the one real orphan (e.g. an enabled `uptime_domain_failure` with no workflow). Capture `config.mode` (3 = auto-detected) for remediation framing:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

det="$(mktemp)"
code=$(curl -s -o "$det" -w '%{http_code}' --max-time 30 \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" "${API}/organizations/${SENTRY_ORG}/detectors/")
if [ "$code" = "404" ]; then
  echo "SNTRY-015 not-in-scope: workflow-engine detectors endpoint absent (classic-model org); SNTRY-001/005 cover the no-receiver case"
elif [ "$code" = "200" ]; then
  jq -r '[.[]
       # exclude built-in per-project detectors whose empty workflowIds is BY DESIGN:
       # every org carries 6 `error` + N `issue_stream` detectors that pair with the
       # issue-stream/metric automation, not their own workflowIds. Counting them flags
       # ~7 phantom orphans against the 1 real one (e.g. an enabled uptime_domain_failure).
       | select(.type != "error" and .type != "issue_stream")
       | select(((.workflowIds // []) | length) == 0)
       | {id, name, type, mode: (.config.mode // null)}]' "$det"
  echo "SNTRY-015: each listed detector (built-in error/issue_stream types excluded) has workflowIds == [] — connected to no automation, notifies nobody (high); config.mode 3 = auto-detected, frame remediation accordingly"
else
  echo "SNTRY-015 blocked: detectors read returned ${code}; record as blocked evidence, not a pass"
fi
rm -f "$det"
```

Expect: on a classic org, the `not-in-scope` line and nothing scored. On a workflow-engine org, an empty array (`[]`) is the healthy result; any listed detector is an orphaned-detector finding named in `affected`. A non-200/404 status blocks the check with the code as evidence. Uptime lives here as a detector `type` of `uptime_domain_failure`, not a separate endpoint.

**SNTRY-011, duplicate paths.** Compare condition sets across a project's own rules, and compare its issue rules against any metric alert on the same signal from `metric-alerts.json`:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
  | tee /dev/stderr \
  | jq -e '[ .[] | { id, name,
      key: ([ .conditions[].id ] | sort | join(",")) } ]
    | group_by(.key) | map(select(length > 1)) | length == 0' >/dev/null \
  && echo "SNTRY-011 pass: ${PROJECT}" || echo "SNTRY-011 fail: ${PROJECT}"
```

Expect: exit 0 and `SNTRY-011 pass: <project>`. A fail means two rules share the exact same condition set and both page on the same trigger.

**Blast radius — name the receiver being doubled, do not stop at "double-page."** "Two rules share a condition set" does not tell the reader whether it doubles one on-call's pages or is harmless. Resolve both duplicate rules' actions to their integration ids in `integrations.json` (the SNTRY-005 join above already extracts `integration_id` per action) and name the shared target: *"rules R1 and R2 on `<project>` carry the same condition set and both route to Slack integration id X / PagerDuty service Y — one incident fires two pages to the same on-call."* For an issue-rule-versus-metric-alert overlap (a `/rules/` rule and an `alert-rules/` metric alert on the same signal), note that the two pages **cannot be deduplicated**: they originate from different object types with no shared fingerprint, so grouping never collapses them. **Correlate:** SNTRY-005 (the shared receiver is the join key), SNTRY-014 (contributes to the same responder-fatigue story), SNTRY-103 (a metric alert is the other half of an issue/metric overlap). Also check `uptime.json` for the project: a Sentry uptime monitor duplicating an external synthetic tool your team already treats as the source of truth is the same class of defect; record which tool wins in the finding.

### Disabled/muted rules and owner-routing gaps (SNTRY-016, SNTRY-017)

> **Live-verified (read-only).** Both checks below were run read-only against a live Sentry org: alert rules carry the `status` field (observed value `active`; SNTRY-016 flags anything other than `active` — disabled/muted), and the project ownership endpoint returns 200 with an ownership document (SNTRY-017). The mechanisms are proven on a real tenant; the findings themselves still reflect that org's actual state each run.

**SNTRY-016, disabled or muted rules that make tier coverage falsely pass.** SNTRY-013 credits tier coverage from any rule carrying the right condition — and, until the `status`-filter added to it in this wave, it counted a switched-off rule too. This check surfaces the rules SNTRY-013 must now exclude, so the two agree on the same estate. The issue-rule half (command 1) is the load-bearing gate; the metric-alert half (command 2) is verify-pending on the field shape:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

# Command 1 (load-bearing): issue rules whose status is not active. `status` on an issue
# rule is the string "active"/"disabled"; default to active when the key is absent.
curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
  | tee /dev/stderr \
  | jq -r '.[] | select((.status // "active") != "active")
      | "\(.id)\t\(.name)\tstatus=\(.status)\tactions=\((.actions|length))\tconditions=\([.conditions[]?.id]|join(","))"'
# Any row is a rule that is present (so SNTRY-013 could once credit it) but switched off:
# it fires nothing. Cross-check the row's conditions against the SNTRY-013 immediate/review
# tiers — a disabled immediate-tier rule on a production project is the finding.

# Command 2 (metric-alert half — status confirmed numeric, disabled-enum residual): do NOT assert
# a string `status` on metric alerts. Confirmed live: the metric-alert (AlertRule) `status` is a
# numeric enum (observed `0` on active rules), so a string compare never matches. The guard below
# only compares when `status` is a string, so on real (numeric) data it reports nothing rather
# than a wrong result. Fixed the ASCII pipe here.
curl -fsS --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/organizations/${SENTRY_ORG}/alert-rules/" \
  | jq -r '.[] | select((.status | type) == "string" and (.status | ascii_downcase) != "active")
      | "\(.name)\tstatus=\(.status)"'
# `status` is confirmed a numeric enum on live data; once a disabled metric alert is observed,
# replace the string guard with the observed disabled-enum value before scoring the metric-alert
# half. Until then it reports nothing rather than a wrong result.
```

Healthy: command 1 prints no rows (every rule is active). Fail (SNTRY-016, high): a disabled/muted rule whose conditions match an immediate or review tier — quantify with the SNTRY-001 accepted-error volume snippet for the project (*"checkout's only regression rule is `status=disabled`, so a fatal regression matches a switched-off rule and pages nobody; this project accepted E errors in the window and the coverage matrix currently scores it green"*). **Correlate:** SNTRY-016 directly gates SNTRY-013 (tier presence now excludes non-active rules) and SNTRY-012 (a disabled immediate rule is functionally no coverage); it chains with SNTRY-005 into the silent-incident flagship. Remediation `setup-sentry#alert-rule-taxonomy`; verification: re-GET `/projects/{org}/{project}/rules/` → the rule crediting the tier has `status == "active"`.

**SNTRY-017, rules route to issue owners but the project has no ownership rules.** A notify action with `targetType: IssueOwners` delegates delivery to whoever owns the matching code path; with no ownership rules, delivery falls through per the project's fallthrough setting — to every member (noise, mirrors SNTRY-001) or, with fallthrough off, to nobody (silent):

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

# Rules that route to issue owners.
curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
  | tee /dev/stderr \
  | jq -r '.[] | . as $r | .actions[]? | select((.targetType // "") == "IssueOwners")
      | "\($r.id)\t\($r.name)\ttargetType=IssueOwners"'

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

Healthy: no owner-routed rule, or owner-routed rules with a non-empty `raw` ownership set. Fail (SNTRY-017, medium): an owner-routed rule with empty ownership `raw` — name the direction, *"the immediate rule on `<project>` routes to issue owners, but ownership raw is empty and fallthrough is off — matched issues notify nobody"* (or fallthrough on → pages everyone, mirroring SNTRY-001). A 403 on `/ownership/` blocks the check with the code as evidence, never a clean pass. **Correlate:** SNTRY-005 (owner-routed actions are a receiver-liveness blind spot the current SNTRY-005 chat/email classifier does not cover) and SNTRY-001 (fallthrough-to-all is the same over-paging failure). Remediation `setup-sentry#receiver-wiring`; verification: re-GET `/projects/{org}/{project}/ownership/` → non-empty `raw` for the owner-routed rule's paths, or the rule re-pointed at a concrete team/integration target.

**live_verify_plan — confirmed live (read-only GETs); one residual remains:**

1. `GET /organizations/{org}/alert-rules/` → `jq '.[0].status, (.[0].status|type)'` — **confirmed:** metric-alert `status` is a number (observed `0` on active rules). **Residual:** the disabled-enum value, which needs a disabled metric alert to observe before command 2 can score the metric-alert half.
2. `GET /projects/{org}/{project}/rules/` → `jq '.[0].status'` — **confirmed:** issue-rule `status` is the string `active` that command 1 relies on.
3. `GET /projects/{org}/{project}/ownership/` → `jq '{raw, fallthrough, fallthroughChoice, autoAssignment}'` — **confirmed:** `/ownership/` returns 200 with `raw` and a boolean `fallthrough` (SNTRY-017 live-verified).
4. `GET /projects/{org}/{project}/rules/` → `jq '[.[].actions[]?|select(.targetType=="IssueOwners")]'` — confirm `NotifyEmailAction targetType=IssueOwners` for SNTRY-017.
5. `curl -o /dev/null -w '%{http_code}' GET /organizations/{org}/members/` — confirm `member:read` is present (200) before SNTRY-001 computes a member count; a 403 means SNTRY-001 files the fan-out sub-part blocked, never a fabricated N.

All five are GETs; nothing here mutates the org.

## Integration and source context checks

Snippet and reading order for SNTRY-009. Judge the VCS chain as a chain: a repo integration alone resolves nothing.

```bash
set -eu
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

gh_tmp="$(mktemp)"
curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/organizations/${SENTRY_ORG}/integrations/?provider_key=github" \
  | tee /dev/stderr | jq '[ .[] | {id, name, status} ]' > "${gh_tmp}"
jq -e '[ .[] | select(.status == "active") ] | length > 0' "${gh_tmp}" >/dev/null \
  && echo "SNTRY-009 step 1 pass: an active GitHub integration exists" \
  || echo "SNTRY-009 step 1 fail: no active GitHub integration (link 1 broken)"
rm -f "${gh_tmp}"

cm_tmp="$(mktemp)"
curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/organizations/${SENTRY_ORG}/code-mappings/" \
  | tee /dev/stderr | jq '[ .[] | {projectId, repoId, defaultBranch, stackRoot, sourceRoot} ]' > "${cm_tmp}"
jq -e 'length > 0' "${cm_tmp}" >/dev/null \
  && echo "SNTRY-009 step 2 pass: at least one code mapping exists" \
  || echo "SNTRY-009 step 2 fail: no code mappings (link 2 broken)"
rm -f "${cm_tmp}"
```

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
| SNTRY-015 | Alert rules and routing | high | Workflow-engine orgs (capability-gated): no *non-built-in* detector with an empty `workflowIds` array — a detector connected to no automation notifies nobody. Excludes the built-in `error`/`issue_stream` detectors every org carries (their empty `workflowIds` is by design); `not-in-scope` on classic-model orgs where the endpoint 404s |
| SNTRY-016 | Alert rules and routing | high | No disabled or muted alert rule is silently crediting tier coverage: a `status != active` issue rule still satisfies SNTRY-013 today, so a service reads covered while its immediate-tier rule fires nothing *(issue-rule half live-verified; metric-alert half verify-pending on the disabled-enum value)* |
| SNTRY-017 | Alert rules and routing | medium | Rules that route to issue owners (`targetType: IssueOwners`) have real ownership rules behind them; empty ownership with fallthrough off notifies nobody, fallthrough on pages everyone |
| SNTRY-101 | Alert rules and routing | medium | Every notifying issue rule gates with a non-empty `filters` set; a broad trigger with an empty `filters` array fires un-tuned (every-event/frequency subset stays owned by SNTRY-014) |
| SNTRY-102 | Alert rules and routing | medium | On a multi-environment project, every notifying issue rule sets its own `environment`; a null `environment` runs the rule across all environments and pages on dev/staging noise |
| SNTRY-103 | Alert rules and routing | medium | Every metric alert sets `resolveThreshold` (and not hugging the trigger, e.g. 0.5 vs 1.0), pairs a `warning` trigger with `critical`, uses a flap-safe `timeWindow`; a percent/rate aggregate also needs a minimum-volume guard (else it reads 100% on a tiny overnight denominator), and `warning`+`critical` must not resolve to the *same* channel (double-post) |
| SNTRY-104 | Alert rules and routing | low | Spike Protection is live per production project; readable only indirectly from a `spike_protection` drop reason in stats outcomes, and OFF by default per project on new orgs |
| SNTRY-105 | Alert rules and routing | low | Inbound Data Filters are active on production projects, discarding known-junk events (bots, extensions, localhost) at ingest before they create issues |
| SNTRY-106 | Alert rules and routing | low | Rule fire-history inventory: each notifying rule's measured fire count (`/rules/{id}/stats/`) and last-fired (`lastTriggered`), so every noise finding quotes real blast radius and never-fired rules surface — bounded by the ~90d stats window, so "never fired" means "not in the observable window" |
| SNTRY-107 | Alert rules and routing | high | No chronically-open issue can legally re-page without bound: an `ongoing` issue older than the age floor, matched by an un-gated frequency/every-event notifying rule, yields a re-page ceiling (`matching_rules × 1440/frequency_min` pages/day) — the "why is my channel unusable" join |
| SNTRY-108 | Alert rules and routing | medium | Rule-name and receiver-channel environment claims agree with the rule's actual `environment`: a `- Dev`/`- Prod`-named or `*-pp-*`-channel rule whose `environment` is null or contradicts the claim is silent mis-scoping name-trusting humans never question |
| SNTRY-109 | Alert rules and routing | low | No dead-weight rules: never-fired (per SNTRY-106) AND (snoozed OR a hair-trigger generic-keyword condition — `message contains <generic>` with a sub-floor frequency); on, dead, and pointless — distinct from SNTRY-016 (switched off *while* crediting coverage) |
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

Snippets for SNTRY-101 through SNTRY-110 (Phase 9). Every call is read-only. SNTRY-101, 102, 105, 106, 108, 109 read per project; SNTRY-103, 104, 110 read once at the org level; SNTRY-107 joins per-project issues with per-project rules. Each block redeclares `SENTRY_HOST`, `SENTRY_ORG`, `API`, and the token check at its own top and relies on no earlier block. These join the Alert rules and routing category and grow its denominator; they never re-weight it, and they never re-check the re-page `frequency` floor (SNTRY-014) or DSN client-key rate limits (SNTRY-003).

**Fire-history is the shared data source for SNTRY-106/107/109 (grounded live).** The project rules list (`/projects/{org}/{proj}/rules/`) already returns `lastTriggered` (an ISO timestamp, or `null` = never fired in the observable window) and `owner` on each rule — so never-fired and ownerless are FREE from the inventory the audit already fetched, no extra call. The *magnitude* (fire count) needs one more GET per rule: `/projects/{org}/{proj}/rules/{ruleId}/stats/` returns an array of `{date, count}` buckets (confirmed live: ~2160 hourly buckets over ~90d); the fire count is `[.[].count] | add`. Cost discipline: fetch `/stats/` only for rules that already tripped a structural check (SNTRY-011/014/101/102) or that you are ranking as noisiest — never for every rule on the large path (respect the estate scope checkpoint).

**SNTRY-101, un-tuned issue rules.** A notifying rule with an empty `filters` array fires on every event its trigger matches. The every-event and frequency subset is owned by SNTRY-014, so exclude `EveryEventCondition` here:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

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
```

Expect: exit 0 and `SNTRY-101 pass: <project>`. A fail lists rules that carry an action but no `filters` and no every-event condition: they fire on every trigger match with nothing narrowing them by issue age, times-seen, level, or assignment. `filterMatch` (`all`/`any`/`none`) is only meaningful once `filters` is non-empty; an empty `filters` makes `filterMatch` moot. Name the rules in `affected`; the fix is to add gating filters, not to delete the rule.

**SNTRY-102, all-environment scope.** An issue rule's `environment` is null by default and then evaluates across every environment. Only score this on a project with more than one environment; a single-environment project has nothing to scope and passes trivially:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

ENV_COUNT="$(curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/environments/" | jq 'length')"
[ "${ENV_COUNT}" -gt 1 ] || { echo "SNTRY-102 n/a: ${PROJECT} has ${ENV_COUNT} environment(s); null scope is not noise here"; exit 0; }

curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
  | tee /dev/stderr \
  | jq -e '[ .[]
        | select((.actions // []) | length > 0)
        | select(.environment == null) ]
      | length == 0' >/dev/null \
  && echo "SNTRY-102 pass: ${PROJECT}" \
  || echo "SNTRY-102 fail: ${PROJECT} (rule(s) run across all environments)"
```

Expect: exit 0 and `SNTRY-102 pass: <project>`, or the `n/a` line on a single-environment project. The rule-level `environment` field is the only true environment scope (a `LatestAdoptedReleaseFilter` does not scope by environment — see the filter table above); a null value on a multi-environment project pages on dev and staging traffic too. This is the noise axis; SNTRY-013 separately owns whether both alert tiers exist, so a rule can pass one and fail the other.

**SNTRY-103, flap-prone metric alerts.** From the org metric-alerts endpoint. Read null `resolveThreshold` as the core flap defect; the missing warning tier and short window are contributing signals:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
TIMEWINDOW_FLOOR_MIN="5"   # example, tune it: metric-alert window below which a fixed-threshold rule flaps on transients

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
```

Expect: exit 0 and `SNTRY-103 pass`. A `resolveThreshold` of null means recovery falls back to the inverse of the critical threshold and the alert flaps across the boundary; a `triggers` array with no `warning` label means single-threshold paging with no severity tiering; a `timeWindow` below the floor on a fixed static threshold fires on transient spikes. `comparisonDelta` (percent-vs-previous mode) or a non-static `detectionType` (dynamic anomaly, with `sensitivity`) each count as flap resistance and satisfy `flap_safe`. Name each failing rule and which of the three it missed.

Two further flap modes a live estate showed (extend the same read, don't add an ID): (a) **percent/rate aggregate with no throughput floor** — a `failure_rate()`/`percentage(...)` aggregate on a static threshold reads `100%` on a 2-transaction overnight hour; flag a percent-aggregate rule whose `timeWindow` is under a wider floor (e.g. 120 min) or that carries no minimum-volume guard, using org overnight volume from `stats_v2` as supporting evidence. (b) **warning + critical posting to the same target** — when both triggers' actions resolve to the *same* channel/integration id, every incident double-posts; flag identical trigger targets. Also treat a `resolveThreshold` that hugs the trigger (e.g. resolve 0.5 vs trigger 1.0) as flap-prone, not just a null one.

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
PCT_WINDOW_FLOOR_MIN="120"   # example, tune: percent/rate aggregate below this flaps on tiny overnight denominators
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
# No rows printed = pass on both extended modes. A row names the rule and which mode; for (a) join
# org overnight sum(quantity) from stats_v2 as the "reads 100% on N transactions" evidence.
```

**SNTRY-104, Spike Protection posture.** The weakest read here, stated plainly: project detail exposes no per-project enabled flag, so infer live activity from stats drop outcomes. A `spike_protection` drop reason proves protection is on and firing:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

# 14d/1d is an example window, tune it. groupBy=reason surfaces the spike_protection drop reason.
SPIKE_DROPS="$(curl -fsS --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/organizations/${SENTRY_ORG}/stats_v2/?statsPeriod=14d&interval=1d&field=sum(quantity)&groupBy=reason&groupBy=outcome&category=error" \
  | tee /dev/stderr \
  | jq '[ .groups[]? | select(.by.reason == "spike_protection") | .totals["sum(quantity)"] ] | add // 0')"
if [ "${SPIKE_DROPS:-0}" -gt 0 ]; then
  echo "SNTRY-104 pass: spike protection is live (dropped ${SPIKE_DROPS} events by spike_protection in window)"
else
  echo "SNTRY-104 inconclusive: no spike_protection drops in window; on a NEW org (default OFF per project) confirm enablement in Project Settings"
fi
```

Expect: `SNTRY-104 pass` when the window shows any `spike_protection` drops, otherwise `SNTRY-104 inconclusive`. Do not score the inconclusive branch as a fail: on an existing org there may simply have been no spike, and Spike Protection was enabled by default for existing/migrated orgs. On a **new** org it is OFF by default per project, so the absence of drops there is a prompt to confirm enablement, recorded as `partial` with the ceiling stated, never a proven gap. Spike *notifications* are off by default on purpose and are not a finding.

**SNTRY-105, Inbound Data Filters.** From the project filters endpoint. A production project with no active inbound filter ingests known-junk events that create issues and feed alerts:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

# The project platform decides which junk filters even apply: browser-only filters
# (browser-extensions, legacy-browsers) are N/A on backend platforms, so their absence
# there is not a finding and their presence must not credit a pass on a backend.
PLATFORM="$(curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/" | jq -r '.platform // "unknown"')"

curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/filters/" \
  | tee /dev/stderr \
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

Expect: exit 0 and `SNTRY-105 pass: <project>`. The `/filters/` list carries one entry per inbound filter (web crawlers, browser-extension errors, localhost, legacy browsers, `filtered-transaction`, and filters by error message, release, or IP). **Two corrections that prevent a false pass and a false fail (grounded live):** (1) `filtered-transaction` is **default-on on every modern project** — it is a transaction sampler, not junk-error filtering, so crediting it makes the check pass vacuously on essentially every org; the jq **excludes it** and only a *real* junk filter (web-crawlers, localhost, browser-extensions, legacy-browsers, or a custom message/release/IP filter) can credit a pass. (2) `browser-extensions` and `legacy-browsers` only apply to **browser platforms** — flagging a `python`/`go`/`node` backend for lacking browser filters is a false positive, so those two count toward a pass (and toward the finding) only when the project `platform` is browser-family; on a backend the applicable filters are web-crawlers, localhost, and custom filters. `active` is a boolean for most filters and a non-empty subfilter array for legacy browsers; treat either shape as active. Filtered events do not consume quota, so a fail here also feeds the quota-pressure reading in SNTRY-008; cross-reference rather than double-file the same dropped-event story.

**SNTRY-106, rule fire-history inventory.** The fire-count blast radius behind every noise finding, and never-fired detection. `lastTriggered` and `owner` are already on the rules list (no extra call); the fire *count* is one GET per rule against `/rules/{id}/stats/` — run it only for rules a structural check already flagged, never the whole estate:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

# never-fired is FREE from the rules list (lastTriggered null == not fired in the observable window):
curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
  | tee /dev/stderr \
  | jq -r '.[] | "\(.id)\t\(.name)\tlastTriggered=\(.lastTriggered // "never-in-window")"'

# fire COUNT for one rule (run ONLY for a rule already flagged by SNTRY-011/014/101/102, or the
# noisiest you are ranking): /stats/ returns [{date,count}] hourly buckets over the ~90d window.
RULE_ID="16700000"   # a rule id from a tripped structural finding
curl -fsS --max-time 20 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/stats/" \
  | jq '[ .[].count ] | add // 0'   # total fires in the stats window — the number to quote as blast radius
```

Expect: a rule→last-fired list, and for a flagged rule its summed fire count. `lastTriggered == null` means *never fired in the observable window* — state it that way, never "dead forever" (the window is bounded, ~90d). This is inventory, not a scored pass/fail on its own; its value is that SNTRY-011/014/101/102 findings now read "rule X fired N times / 0 times" instead of "rule X is structurally noisy". Cap the per-rule `/stats/` calls under the estate scope checkpoint.

**SNTRY-107, chronic-issue re-page ceiling (the flagship noise join).** Joins two surfaces the audit already touches separately: long-open `ongoing` issues × un-gated notifying rules that still match them. It answers "why is my channel unusable", not "which field is null":

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # a production project from projects.json
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
AGE_FLOOR_DAYS="30"   # example, tune it: an ongoing issue older than this that still re-pages is chronic

# 1) chronic issues: unresolved + ongoing + older than the age floor, most events first.
#    The age floor is applied server-side via the `age:+Nd` search token (grounded live:
#    `age:+30d` = older than 30d). Do NOT pass `statsPeriod=90d` here — the issues endpoint
#    only accepts '', '24h', '14d' for stats_period and 400s on 90d; the `age:` token is
#    what filters for chronic issues. URL-encoding: `:` = %3A, the leading `+` = %2B.
curl -fsS --max-time 20 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/issues/?query=is%3Aunresolved+is%3Aongoing+age%3A%2B${AGE_FLOOR_DAYS}d&sort=freq" \
  | tee /dev/stderr \
  | jq -r '.[] | "\(.shortId)\tevents=\(.count)\tfirstSeen=\(.firstSeen)\tsubstatus=\(.substatus // "?")"' | head

# 2) un-gated re-paging rules: a frequency/every-event condition, an action, and NO age /
#    times-seen / new-issue gate in filters (so a permanently-open issue keeps matching)
curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
  | jq -r '[ .[]
      | select((.actions // []) | length > 0)
      | select([ .conditions[]?.id ] | any(test("EventFrequencyCondition|EventFrequencyPercentCondition|EveryEventCondition")))
      | select([ .filters[]?.id ] | any(test("AgeComparison|IssueOccurrences|FirstSeenEvent|latest")) | not)
      | { name, freq: (.frequency // 30) } ]
      | "un-gated re-paging rules: \(length); re-page ceiling/day per matching issue = sum over rules of (1440 / freq_min)"'
```

Expect: the chronic-issue list and the count of un-gated re-paging rules. The finding (high) is the **legal re-page ceiling**: for one permanently-`ongoing` issue matched by those rules, `Σ (1440 / rule.frequency_min)` pages/day/channel (the classic result: one 117-day-old issue × two 15-min burst rules ≈ 96 pages/day). Quote it as a *ceiling*, not an observed count — and when SNTRY-106 stats exist, quote both ("ceiling 96/day; observed 278 last week"). Name the issue(s) and the rules in `affected`. This is the check that explains an unusable channel; it degrades to a structural finding (un-gated rules exist) when the issues endpoint is not readable.

**SNTRY-108, name / scope / receiver coherence.** A rule whose *name* or *receiver channel* claims an environment while its actual `environment` field is null or contradicts the claim is silent mis-scoping — name-trusting humans never question a "- Prod" rule that is really firing on everything:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
  | tee /dev/stderr \
  | jq -r '.[]
      | (.name | ascii_downcase) as $nm
      | ([ .actions[]? | (.channel // .targetIdentifier // "") ] | join(",") | ascii_downcase) as $chan
      | (if ($nm|test("prod")) or ($chan|test("-prod|_prod|prod-")) then "production"
         elif ($nm|test("- ?dev|staging|pre-?prod|-pp|_pp|pp-")) or ($chan|test("-pp-|pre-?prod|staging|dev")) then "non-prod"
         else null end) as $claim
      | select($claim != null and ((.environment == null) or ((.environment|ascii_downcase|test($claim[0:4])) | not)))
      | "SNTRY-108: \(.name) claims \($claim) (name/channel) but environment=\(.environment // "null")"'
```

Expect: no rows on a coherent estate. A row is a rule whose stated env (from its name or the channel it posts to) disagrees with its `environment` field — the clearest case being a claim with `environment: null` (fires on all envs while looking scoped). This is deliberately conservative: it only fires when there is an explicit claim to contradict. SNTRY-102 owns the plain "env is null" gap; SNTRY-108 owns the *lie in the name* and the set-but-contradicting case. Regex is heuristic — record the claimed-vs-actual pair as the evidence and let the reader judge non-standard names.

**SNTRY-109, dead-weight rules.** Never-fired AND (snoozed OR a hair-trigger generic-keyword condition) — on, dead, and safe to delete. Distinct from SNTRY-016 (switched off *while crediting* coverage):

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
  | tee /dev/stderr \
  | jq -r '.[]
      | select(.lastTriggered == null)                                   # never fired in window (SNTRY-106)
      | select((.snooze != null)                                         # snoozed, OR ...
        or ([ .conditions[]? | select(.id|test("EventFrequencyCondition")) | (.value // 999) ] | any(. < 60))  # hair-trigger freq
        or ([ .filters[]?.value // .filters[]?.key // empty ] | any(test("timeout|memory|error|exception";"i"))))  # generic keyword
      | "SNTRY-109 dead-weight: \(.name) (never fired; snoozed or hair-trigger keyword)"'
```

Expect: no rows on a lean estate. Rows are rules that never fired in the window AND are either snoozed or gated only by a generic keyword with a sub-60 frequency — review surface that inflates coverage counts and deletes with no loss. Cross-reference SNTRY-106 (the never-fired signal) and honor its window ceiling; a rule "never fired" only within the observable window is a review candidate, not an automatic delete — the fix is a confirmed deletion via `setup-sentry`, never by this read-only audit.

**SNTRY-110, ownerless rules.** Maintenance accountability across the whole rule estate — issue rules and metric alerts. An estate where no rule has an `owner` has no one accountable for tuning, which is how a rule set rots:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

# issue rules (per project) + metric alerts (org-level) with no owner
ISSUE_UNOWNED="$(curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" | jq '[ .[] | select(.owner == null) ] | length')"
METRIC_UNOWNED="$(curl -fsS --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/organizations/${SENTRY_ORG}/alert-rules/" | jq '[ .[] | select(.owner == null) ] | length')"
echo "SNTRY-110: ${PROJECT} unowned issue rules=${ISSUE_UNOWNED}; org unowned metric alerts=${METRIC_UNOWNED}"
[ "${ISSUE_UNOWNED}" -eq 0 ] && [ "${METRIC_UNOWNED}" -eq 0 ] \
  && echo "SNTRY-110 pass" || echo "SNTRY-110 fail (ownerless rules: no one accountable for tuning)"
```

Expect: `SNTRY-110 pass` when every rule carries `owner: team:<id>` or `member:<id>`. Ownerless rules are low severity but high explanatory value — an all-ownerless estate is the root of alert rot. This is distinct from SNTRY-017 (which is about delivery routing to issue owners); SNTRY-110 is about who maintains the rule. The fix (assign owners) is a `setup-sentry` mutation, not this audit's job.

### Honest ceiling for the fire-history checks (SNTRY-106/107/109)

Fire counts measure **emission, not annoyance** — the audit still has no incident/ack feed, so it must never claim an actionability rate from them (the existing Phase-9 ceiling text applies; extend it to cover these numbers). "Never fired" is bounded by the stats retention window (~90d) — say "not in the observable window", never "dead". Re-page ceilings (SNTRY-107) are **legal maxima**, not observed counts; when SNTRY-106 stats exist, quote both the ceiling and the observed count.

## Depth checks: per-project quota attribution, deterministic source-map verdicts, VCS/code-mapping integrity, monitor posture, coverage split, environment sprawl (SNTRY-018 through SNTRY-025)

Snippets for SNTRY-018 through SNTRY-025. Every call is read-only. All eight were confirmed live against a real Sentry SaaS org during this wave — the shapes below are the observed shapes, not guessed ones; each subsection states what was actually observed. SNTRY-018/019 reuse `stats-projects.json`/`stats-outcomes.json` from Phase 1 or re-fetch with the same query; SNTRY-020 reuses the Phase 5 event fetch; SNTRY-021/022 reuse `repos.json`/`code-mappings.json`; SNTRY-023 reuses `monitors.json`; SNTRY-024 reuses `projects.json` project-detail fields already fetched in Phase 1; SNTRY-025 reuses each project's `environments.json`. None of these add a new per-project call the audit was not already making, except SNTRY-020's per-event and `artifact-bundles` reads (bounded exactly like the existing SNTRY-006 sample).

**SNTRY-018, per-project drop ratio.** SNTRY-008 reads `stats-outcomes.json` **org-wide** — a single hot project can breach a drop-ratio floor while the org-wide average stays comfortably under it, because the other projects' accepted volume dilutes the average. Re-read the same window grouped by project instead of summed org-wide:

```bash
set -eu
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
  [ .groups[]? | .by.project ] | unique as $pids
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
'
```

**Confirmed live** on a real org: the org-wide SNTRY-008 read showed a modest aggregate drop share, but re-grouped by project this query surfaced one project whose `rate_limited` share of its own `accepted + rate_limited` total exceeded the 5% example floor while every other project in the same org was comfortably under it — proving the exact masking failure mode this check exists to catch: the org-wide average alone would have scored SNTRY-008 clean while one project was already losing events to quota. Expect: no rows on a healthy org; a row names the numeric project id (resolve it to a slug from `projects.json` before writing the finding) and the exact ratio. `affected` names the project by slug, not the numeric id. **Correlate:** SNTRY-008 (the org-wide reading this check is scoped underneath), SNTRY-003 (an unlimited key on the same project is the mechanism), SNTRY-019 (the reason split below explains *why* it is dropping).

**SNTRY-019, rate-limit reason split.** `stats_v2` supports a `reason` groupBy/filter dimension distinct from `outcome`; `outcome=rate_limited` is the effect, `reason` is the cause, and the two causes need different fixes (Spike Protection is a burst-shape control tuned in `setup-sentry#quota-spike-protection-and-privacy-sensitive-ingestion`; a per-key or cardinality quota breach is fixed by raising or removing the key's `rateLimit`, SNTRY-003's object). Never attribute a specific drop to a specific key — the stats are org- or project-wide, not per-key:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

# groupBy=reason is confirmed live to require groupBy=outcome alongside it (the API accepts the
# combination; reason alone with no outcome groupBy was not tried and is not the supported shape
# used here). category=error narrows to the same window SNTRY-008 already reads.
curl -fsS --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/organizations/${SENTRY_ORG}/stats_v2/?statsPeriod=14d&interval=1d&field=sum(quantity)&groupBy=reason&groupBy=outcome&category=error" \
  | tee /dev/stderr \
  | jq -r '
      ( [ .groups[]? | select(.by.outcome == "rate_limited" and .by.reason == "spike_protection") | .totals["sum(quantity)"] ] | add // 0 ) as $spike
    | ( [ .groups[]? | select(.by.outcome == "rate_limited" and .by.reason != "spike_protection") | .totals["sum(quantity)"] ] | add // 0 ) as $keyquota
    | "SNTRY-019: rate_limited drops in window — spike_protection=\($spike), other (key/cardinality quota)=\($keyquota)"
'
```

Note the jq above has a deliberate structural fix versus a naive one-liner: `outcome == "rate_limited"` alone conflates the two causes, so the reason equality split is the load-bearing part of the check, not an optional refinement. **Confirmed live** on a real org: every `rate_limited` drop in the 14-day window carried `reason: "spike_protection"` (291 events, matching the SNTRY-104 spike-protection evidence exactly) and zero carried any other reason — a clean, unambiguous attribution in this org. A live response also showed `reason: "network_error"` and `reason: "ratelimit_backoff"` paired with `outcome: "client_discard"` (client-side SDK backoff, never server-side `rate_limited`) and `reason: "react-hydration-errors"` paired with `outcome: "filtered"` — confirming `reason` is a general dimension across every outcome, not specific to quota drops, so the query must filter on `outcome == "rate_limited"` before reading `reason`, never read `reason` alone. Expect: two numbers; when `keyquota` is nonzero, file the finding pointing at SNTRY-003 (raise or remove the unlimited key's rate limit); when only `spike` is nonzero, point at Spike Protection tuning instead of the key-quota remediation. Zero on both is a pass. **Correlate:** SNTRY-008 (the same drops, unsplit), SNTRY-104 (spike-protection liveness — a nonzero `spike` figure here is the same live proof SNTRY-104 uses), SNTRY-003 (the key-quota remediation target).

**SNTRY-020, deterministic source-map verdict via event `errors[]`, plus independent upload-pipeline proof.** SNTRY-006 infers broken source maps from a *heuristic* — sampling one event's in-app frames and checking for `context`. Sentry's own event payload carries a **top-level `errors[]` array** that states symbolication failure explicitly and needs no frame heuristic:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-js-project-slug"   # a JavaScript/TypeScript project from projects.json
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

ISSUE_ID="$(curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/issues/?statsPeriod=14d&query=is:unresolved&limit=1" \
  | jq -r '.[0].id // empty')"
[ -n "$ISSUE_ID" ] || { echo "SNTRY-020 blocked: no recent issue in ${PROJECT}"; exit 0; }

curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/organizations/${SENTRY_ORG}/issues/${ISSUE_ID}/events/latest/" \
  | tee /dev/stderr \
  | jq -r '
      [ .errors[]? | select(.type == "js_no_source" or (.type | test("no_source|missing_source|symbolic"; "i"))) ] as $symerrs
      | if ($symerrs | length) > 0
        then "SNTRY-020 fail: \($symerrs[0].type) — \($symerrs[0].message) (deterministic, from event.errors[])"
        else "SNTRY-020 pass: event.errors[] carries no symbolication-error entry" end
'
```

**Confirmed live** on a real org: a sampled event's top-level `errors[]` returned exactly `[{"type": "js_no_source", "message": "Source code was not found", "data": {"symbolicator_type": "missing_source", "url": "app:///"}}]` — proving the field, the exact `type` string, and the deterministic verdict path all exist and fire on real (non-synthetic) data. A second sampled event on the same project returned `errors: []`, confirming the healthy shape too. Read the verdict as independent of, and stronger than, SNTRY-006's frame-context heuristic: a non-empty `errors[]` with a symbolication-type entry is Sentry's own server-side statement that resolution failed, not an inference from frame shape.

Second half — probe the upload pipeline independently of event sampling, so a project with no recent unresolved issue (SNTRY-006/020 blocked) can still be judged on whether artifacts were even uploaded:

```bash
set -eu
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-js-project-slug"
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/files/artifact-bundles/" \
  | tee /dev/stderr \
  | jq -r 'if length == 0
      then "SNTRY-020 upload-pipeline fail: no artifact bundles uploaded for '"${PROJECT}"'"
      else "SNTRY-020 upload-pipeline pass: \(length) artifact bundle(s), most recent \(map(.dateModified) | max)" end'
```

**Confirmed live:** the endpoint returns 200 with a JSON array of `{bundleId, associations: [{release, dist}], fileCount, dateModified, date}`. On the sampled org, bundles existed with a **non-null** `release` in every `associations[]` entry — do not read that as evidence a null `release` means broken; the schema documents `release: null` as the normal shape for a debug-ID bundle that resolves independently of any release association, so score only on bundle *presence*, never on whether `release` is populated. A project with artifact bundles present but its sampled event still showing `errors[].type == "js_no_source"` is not a contradiction — name it as its own finding: the upload pipeline works, but resolution is still failing (wrong `dist`, wrong URL prefix, or a bundle that does not cover the failing file), which is a more specific, more actionable defect than "source maps are broken." **Correlate:** SNTRY-006 (same VCS/release surface, heuristic half), SNTRY-009 (a broken code-mapping chain is one of the reasons resolution can fail even with bundles present).

**SNTRY-021, repo integrity.** `/organizations/{org}/repos/` can carry entries created by a misconfigured `sentry-cli set-commits` run: a generic `origin` repo with no real VCS provider behind it. Once release commits bind to that repo, the release looks like it has commit data, but nothing resolves through it — no PR link, no blame, no code-mapping can attach to it:

```bash
set -eu
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/organizations/${SENTRY_ORG}/repos/" \
  | tee /dev/stderr \
  | jq -r '.[] | select(.provider.id != null and (.provider.id | startswith("integrations:")) | not)
      | "SNTRY-021 fail: repo \(.name) (id=\(.id)) has provider.id=\(.provider.id // "null") — not a real VCS integration"'
```

**Confirmed live** on a real org: this exact query returned one row — a repo named `origin`, `provider.id: "unknown"`, `url: null`, `integrationId: null` — sitting alongside several dozen legitimate `provider.id: "integrations:github"` repos with real GitHub URLs and integration ids. This is precisely the `sentry-cli set-commits` junk-repo pattern the check targets, caught on the first live read. Expect: no rows on a clean estate; a row names the repo (never the org's real repo names in this skill's own text — that is customer data, not a schema fact) and its `provider.id`. Escalate when `releases.json` shows this repo's `id` referenced by a release with nonzero `commitCount`: those commits are bound to a repo that cannot resolve anything. **Correlate:** SNTRY-009 (this is the "link 1 broken" case stated precisely instead of "no active GitHub integration" — a junk `origin` repo can coexist with a real, separately-connected GitHub integration, so SNTRY-009's step 1 can pass while this still fails), SNTRY-022 (a code mapping pointing at this repo id is doubly broken).

**SNTRY-022, code-mapping plausibility.** `/organizations/{org}/code-mappings/` (or the per-project stacktrace-link config) can carry mappings that are syntactically valid but structurally implausible: two mappings for the same `{projectId, repoId}` pair whose `stackRoot` differs only by a `./` segment (both resolve the same tree, so one is redundant and their precedence order is unproven), a `stackRoot` rooted under a build-host path that never survives past the CI runner, or one project routing an unusually large number of mappings into a single repo:

```bash
set -eu
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
MAX_MAPPINGS_PER_REPO="5"   # example, tune to your monorepo layout

curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/organizations/${SENTRY_ORG}/code-mappings/" \
  | tee /dev/stderr \
  | jq -r --argjson maxper "${MAX_MAPPINGS_PER_REPO}" '
      # normalize: strip a trailing or leading "./" segment so "foo/" and "foo/./" (or "./foo/")
      # compare equal — confirmed live shape uses a trailing "./", the check tolerates a leading one too.
      def norm: gsub("^\\./"; "") | gsub("/\\./$"; "/") | gsub("/\\.$"; "/");
      ( [ .[] | {id, projectId, repoId, stackRoot, key: ((.projectId|tostring) + "|" + (.repoId|tostring) + "|" + (.stackRoot|norm))} ] ) as $rows
      | ($rows | group_by(.key) | map(select(length > 1))) as $dupes
      | ( $rows[] | select(.stackRoot | test("^/(tmp|home|Users)(/|$)")) ) as $buildhost
      | ( $rows | group_by(.projectId + "|" + .repoId) | map(select(length > $maxper))) as $overrouted
      | (($dupes | length) > 0), (($overrouted | length) > 0)
      | if . then "SNTRY-022: see duplicate/build-host/over-routed rows above" else empty end
' 2>/dev/null || true
echo "SNTRY-022: inspect duplicate stackRoot pairs, build-host stackRoots, and per-repo mapping counts from the code-mappings.json dump above"
```

**Confirmed live** on a real org: this endpoint returned 16 code mappings, and among them two rows shared the *same* `{projectId, repoId}` pair with `stackRoot` values differing only by a trailing `./` segment (the general shape this check normalizes away before grouping) — a real duplicate, not a constructed one. The same read also showed one project routing mappings into a single repo well past the example `MAX_MAPPINGS_PER_REPO` default of 5 (into the high single digits), confirming the over-routed case fires on real data too. Also confirmed: `code-mappings.json` field types are `id`/`projectId`/`repoId` as **JSON strings** (observed as numeric-looking string values, e.g. `"921900"`) whereas `stats_v2`'s `by.project` is a JSON **number** — never compare these across endpoints without an explicit `tostring`/`tonumber` normalization; the jq above stays within one endpoint's own string-typed ids and never mixes them with `stats_v2`. A pre-existing display-only snippet earlier in this file (`## Integration and source context checks`, the SNTRY-009 step 2 dump) named this same field `repositoryId`; the real field is `repoId` — fixed there too as part of this live-verification pass, since a display-only `jq` selecting a field that does not exist silently prints `null` instead of the value. Expect: no duplicate-key groups, no build-host `stackRoot`, and no repo receiving more than `MAX_MAPPINGS_PER_REPO` mappings from one project. A duplicate pair is `low` (redundant, not broken); a build-host `stackRoot` is the finding to escalate (it means the mapping was generated from a local dev machine or an ephemeral CI path, not the checked-out repo root, and will never resolve in production). **Correlate:** SNTRY-009 (a broken or implausible mapping is "link 2" or "link 3" of the same VCS chain), SNTRY-021 (a mapping pointing at a non-integration repo is doubly broken).

**SNTRY-023, zero-monitor posture.** `/organizations/{org}/monitors/` returning an empty list is not itself a finding — many estates genuinely have no scheduled jobs — but on an org with backend projects that carry real accepted-event volume, zero monitors means no cron/uptime coverage exists to be audited at all, and that absence deserves an explicit line in the report rather than silently vanishing from the Monitors category:

```bash
set -eu
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

MON_COUNT="$(curl -fsS --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/organizations/${SENTRY_ORG}/monitors/" | tee /dev/stderr | jq 'length')"
if [ "${MON_COUNT}" -gt 0 ]; then
  echo "SNTRY-023 not-in-scope: ${MON_COUNT} monitor(s) exist; SNTRY-007 judges them"
  exit 0
fi
# Zero monitors: check whether any non-browser (backend) project carries recent accepted volume,
# using the same numeric-id join SNTRY-001/012 already use against stats-projects.json.
STATS="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/$(date -u +%Y-%m-%d)/raw/stats-projects.json"
curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" "${API}/organizations/${SENTRY_ORG}/projects/" \
  | jq -r '.[] | select(.platform | test("^(javascript|electron|cordova|react-native|unity|flutter)") | not) | "\(.id)\t\(.slug)"' \
  | while IFS="$(printf '\t')" read -r pid pslug; do
      acc=$(jq -r --arg pid "$pid" '[ .groups[]? | select((.by.project|tostring) == $pid) | select(.by.outcome=="accepted") | .totals["sum(quantity)"] ] | add // 0' "${STATS}")
      [ "${acc:-0}" -gt 0 ] && echo "SNTRY-023 info: 0 monitors exist; backend project ${pslug} accepted ${acc} events in the window with no cron/uptime monitor to audit"
    done
```

**Confirmed live** on a real org: `/organizations/{org}/monitors/` returned `[]` (zero monitors), and the org's backend (non-browser-platform) projects included one that accepted several thousand error events in the 14-day window per `stats-projects.json` — the exact condition this check targets, found on the first live read. Expect: `not-in-scope` when monitors exist (SNTRY-007 owns them from there); otherwise one `info` line per backend project with live volume, or nothing when every backend project is also silent (in which case SNTRY-012's coverage row already names the deeper problem). This finding is deliberately `info` severity with `points_recoverable: 0` — it is a prompt to decide whether monitors belong here, not a proven gap, since the absence of monitors could equally mean no scheduled jobs exist to watch. **Correlate:** SNTRY-007 (owns any monitor that does exist), SNTRY-012 (a backend project with volume and zero monitors is a different gap than the same project with zero *events*).

**SNTRY-024, `firstEvent: null` split in the coverage check.** SNTRY-012 currently reads a mapped project's **recent** accepted-event count from `stats-projects.json` and calls a zero-count project "dead." Project detail also carries `firstEvent`, which distinguishes two differently-remediated cases that a bare recent-volume-of-zero reading conflates: a project that has **never** received a single event (`firstEvent: null` — the SDK was never wired up, or never fired) versus a project that received events at some point and then went quiet (`firstEvent` is a real timestamp, but `stats-projects.json` shows zero *recent* accepted events):

```bash
set -eu
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # a project mapped to a critical service (SNTRY-012)
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/" \
  | tee /dev/stderr \
  | jq -r 'if .firstEvent == null
      then "SNTRY-024: \(.slug) never instrumented (firstEvent is null) — wire the SDK, this is not a drop-off"
      else "SNTRY-024: \(.slug) firstEvent=\(.firstEvent) — instrumented at some point; cross-check stats-projects.json recent-volume for a drop-off" end'
```

**Confirmed live** on a real org: one project (a Python backend) returned `firstEvent: null` while five sibling projects on the same org all returned real ISO timestamps — proving both branches of this check occur on the same estate and that the field reliably distinguishes them. Expect: every project mapped to a critical service resolves one of the two branches; feed the branch into SNTRY-012's finding wording — "never instrumented, wire the SDK" is a setup gap (`setup-sentry#projects`), "instrumented, now silent" is an investigate-the-drop gap (check the deploy that removed instrumentation, or a DSN rotation that broke ingestion). Do not merge the two into one "dead project" sentence; they point the reader at opposite next actions. **Correlate:** SNTRY-012 (this check refines that finding's wording, it does not replace it), SNTRY-004 (a project that was never instrumented also has no real environment traffic to require an environment for).

**SNTRY-025, environment-name sprawl.** Every environment-scoped check (SNTRY-102, SNTRY-013, and SNTRY-004's own baseline match) trusts that a project's environment list has one canonical name per real environment. A project that accumulated both `prod` and `production` — usually from two SDK configs written at different times, or a staging config copy-pasted into a new service — makes every environment-scoped rule only ever see half the traffic, silently, because Sentry treats them as two unrelated environments:

```bash
set -eu
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
PROJECT="your-project-slug"  # from projects.json
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/environments/" \
  | tee /dev/stderr \
  | jq -r '
      [ .[].name | ascii_downcase ] as $names
      | [ ["prod","production"], ["pp","preprod","pre-prod"], ["stage","staging"] ] as $groups
      | [ $groups[] | . as $g | select( ([ $names[] | select(. as $n | $g | index($n)) ] | length) > 1 ) | $g ] as $hits
      | if ($hits | length) > 0
        then "SNTRY-025 fail: synonym collision in environment names — \($hits | map(join("/")) | join(", ")) all present"
        else "SNTRY-025 pass: no synonym collision among \($names | join(","))" end'
```

**Confirmed live** on a real org: one project's environment list (ten names, mixing cloud-provider tags, promotion stages, and ad hoc variants) carried a real, live synonym collision on **two** of the three declared families at once — both a `prod`-family pair and a `pp`/`preprod`-family pair present together on the same project — plus additional prod-like variant names outside all three declared families, which the canonical-map heuristic does not attempt to catch and states as its honest limit. A sibling project on the same org returned a small, clean environment list with no collision, confirming the check reads healthy and unhealthy estates correctly on the same org. Expect: no rows on a clean project; a row names the colliding family. This check's canonical map is deliberately narrow (three example families) — extend it in your own fork of this check for house-specific synonyms, and never treat a name outside the three groups as a false pass; it is simply not covered by this pass, not proven clean. **Correlate:** SNTRY-102 (a rule scoped to `environment: "production"` on a project that also ingests under `prod` silently misses that half of the traffic — this is the root cause SNTRY-102 cannot see from its own read), SNTRY-013 (the same half-match risk applies to tier-coverage environment scoping), SNTRY-004 (the baseline single-name match has the same blind spot at a smaller scale).
