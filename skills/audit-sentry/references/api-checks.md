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

**SNTRY-015, orphaned detectors (workflow-engine orgs, capability-gated).** Probe the org-level detectors endpoint once. It 404s on classic-model orgs — that is `not-in-scope`, not a fail. On a 200, a detector with an empty `workflowIds` array detects a condition but drives no automation, so it notifies nobody (the new-model equivalent of SNTRY-001/SNTRY-005's no-receiver case):

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
  jq -r '[.[] | select(((.workflowIds // []) | length) == 0) | {id, name, type}]' "$det"
  echo "SNTRY-015: each listed detector has workflowIds == [] — connected to no automation, notifies nobody (high)"
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

# Command 2 (VERIFY-PENDING metric-alert half): do NOT assert a string `status` on metric
# alerts. Sentry's metric-alert (AlertRule) serializer is documented to return `status` as an
# integer enum, so a string compare would be wrong. Gate on the OBSERVED type until a live run
# confirms the shape: only compare when it actually is a string. Fixed the ASCII pipe here.
curl -fsS --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/organizations/${SENTRY_ORG}/alert-rules/" \
  | jq -r '.[] | select((.status | type) == "string" and (.status | ascii_downcase) != "active")
      | "\(.name)\tstatus=\(.status)"'
# On a live tenant, if `status` proves to be an integer enum, replace the guard with the
# documented enum value for "disabled" (confirm via the live_verify_plan) before scoring the
# metric-alert half; until then it reports nothing rather than a wrong result.
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

# Ownership raw rules + fallthrough posture. VERIFY-PENDING: confirm the /ownership/ shape and
# the exact fallthrough field name against a live org before scoring (see live_verify_plan).
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

**live_verify_plan (read-only GETs that lift verify-pending on SNTRY-016/017):**

1. `GET /organizations/{org}/alert-rules/` → `jq '.[0].status, (.[0].status|type)'` — confirm whether metric-alert `status` is int or string, then fix SNTRY-016 command 2 accordingly.
2. `GET /projects/{org}/{project}/rules/` → `jq '.[0].status'` — confirm issue-rule `status` is the string `active`/`disabled` command 1 relies on.
3. `GET /projects/{org}/{project}/ownership/` → `jq '{raw, fallthrough, fallthroughChoice, autoAssignment}'` — confirm the `/ownership/` shape and the exact fallthrough field name for SNTRY-017.
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
  | tee /dev/stderr | jq '[ .[] | {projectId, repositoryId, defaultBranch, stackRoot, sourceRoot} ]' > "${cm_tmp}"
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
        | .data.values[]?.stacktrace.frames[]? | select(.in_app == true)
        | (.context != null and (.context | length) > 0) ] as $ctx
      | ($ctx | length) > 0 and ($ctx | all)' >/dev/null \
  && echo "SNTRY-006 pass: ${PROJECT} (every in_app frame carries context)" \
  || echo "SNTRY-006 fail-or-blocked: ${PROJECT} (see failure shapes below; confirm filenames are source paths by eye)"
```

Expect: exit 0 and `SNTRY-006 pass: <project>`. The assertion checks that every `in_app: true` frame has non-empty `context`; still confirm by eye that `filename` values are readable source paths, not bundle output, since a hashed chunk name can carry `context` from an unrelated map. Failure shapes:

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
| SNTRY-001 | alert-rules-and-routing | high | No project carries the auto-created, unowned "high priority" default rule |
| SNTRY-002 | privacy-and-data-protection | high | Every production project has data scrubbing, default scrubbers, and a non-empty sensitive-fields list |
| SNTRY-003 | project-configuration | medium | Every active client key on every project has a rate limit |
| SNTRY-004 | project-configuration | medium | Every active project has the environment your production traffic runs under |
| SNTRY-005 | alert-rules-and-routing | high | Every non-email rule action references a live, active integration; email-only routing is recorded as temporary |
| SNTRY-006 | releases-and-source-context | high | Recent releases exist, carry commit data, and minified frames resolve to readable source on a sampled recent event |
| SNTRY-007 | monitors | medium | Every active cron or uptime monitor has an observed check-in; no silently unproven active monitor |
| SNTRY-008 | volume-and-quota | medium | Dropped-event share (rate-limited, cardinality-limited, abuse) stays under your declared threshold |
| SNTRY-009 | releases-and-source-context | low | The VCS chain resolves end to end: integration active, code mapping present, default branch matches the deployed branch, commit data present |
| SNTRY-010 | privacy-and-data-protection | high | Replay, profiling, or log ingestion volume that is live has a recorded masking, consent, and retention decision |
| SNTRY-011 | alert-rules-and-routing | medium | No duplicate alerting path: identical condition sets, issue-rule and metric-alert overlap, or Sentry uptime duplicating an external synthetic tool |
| SNTRY-012 | service-coverage | medium | Every critical service maps to a project with recent accepted events, or the mapping is explicitly `not-in-scope` by decision |
| SNTRY-013 | alert-rules-and-routing | high | Every production project has at least one immediate-tier and one review-tier rule, correctly environment-scoped by the rule's own `environment` field |
| SNTRY-014 | alert-rules-and-routing | medium | No rule pages on unfiltered every-event conditions or re-pages below your frequency floor |
| SNTRY-015 | alert-rules-and-routing | high | Workflow-engine orgs (capability-gated): no detector with an empty `workflowIds` array — a detector connected to no automation notifies nobody; `not-in-scope` on classic-model orgs where the endpoint 404s |
| SNTRY-016 | alert-rules-and-routing | high | *(verify-pending)* No disabled or muted alert rule is silently crediting tier coverage: a `status != active` issue rule still satisfies SNTRY-013 today, so a service reads covered while its immediate-tier rule fires nothing |
| SNTRY-017 | alert-rules-and-routing | medium | *(verify-pending)* Rules that route to issue owners (`targetType: IssueOwners`) have real ownership rules behind them; empty ownership with fallthrough off notifies nobody, fallthrough on pages everyone |
| SNTRY-101 | alert-rules-and-routing | medium | Every notifying issue rule gates with a non-empty `filters` set; a broad trigger with an empty `filters` array fires un-tuned (every-event/frequency subset stays owned by SNTRY-014) |
| SNTRY-102 | alert-rules-and-routing | medium | On a multi-environment project, every notifying issue rule sets its own `environment`; a null `environment` runs the rule across all environments and pages on dev/staging noise |
| SNTRY-103 | alert-rules-and-routing | medium | Every metric alert sets `resolveThreshold`, pairs a `warning` trigger with `critical`, and uses a `timeWindow` (or `comparisonDelta`/`detectionType`) wide enough not to flap on transients |
| SNTRY-104 | alert-rules-and-routing | low | Spike Protection is live per production project; readable only indirectly from a `spike_protection` drop reason in stats outcomes, and OFF by default per project on new orgs |
| SNTRY-105 | alert-rules-and-routing | low | Inbound Data Filters are active on production projects, discarding known-junk events (bots, extensions, localhost) at ingest before they create issues |

Remediation pointers: every SNTRY finding points at `setup-sentry`, anchored to the section that fixes that class of defect (for example `setup-sentry#alert-rule-taxonomy` for SNTRY-001, SNTRY-013, SNTRY-014; `setup-sentry#privacy-gates` for SNTRY-002 and SNTRY-010). SNTRY-005 may alternatively point at `audit-alert-routing` when the receiver in question is Alertmanager-routed rather than a Sentry-native integration.

## Alert hygiene noise-control checks

Snippets for SNTRY-101, SNTRY-102, SNTRY-103, SNTRY-104, SNTRY-105 (Phase 9). Every call is read-only. SNTRY-101, 102, 105 read per project; SNTRY-103, 104 read once at the org level. Each block redeclares `SENTRY_HOST`, `SENTRY_ORG`, `API`, and the token check at its own top and relies on no earlier block. These join the Alert rules and routing category and grow its denominator; they never re-weight it, and they never re-check the re-page `frequency` floor (SNTRY-014) or DSN client-key rate limits (SNTRY-003).

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

curl -fsS --max-time 15 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/projects/${SENTRY_ORG}/${PROJECT}/filters/" \
  | tee /dev/stderr \
  | jq -e '[ .[] | select((.active == true)
        or (((.active | type) == "array") and ((.active | length) > 0))) ] | length > 0' >/dev/null \
  && echo "SNTRY-105 pass: ${PROJECT} (at least one inbound data filter active)" \
  || echo "SNTRY-105 fail: ${PROJECT} (no inbound data filters active; bot/localhost/extension noise ingests unfiltered)"
```

Expect: exit 0 and `SNTRY-105 pass: <project>`. The `/filters/` list carries one entry per inbound filter (web crawlers, browser-extension errors, localhost, legacy browsers, health-check transactions, and filters by error message, release, or IP). Most are opt-in and off by default, so an un-configured project fails. `active` is a boolean for most filters and a non-empty subfilter array for legacy browsers; treat either shape as active. Filtered events do not consume quota, so a fail here also feeds the quota-pressure reading in SNTRY-008; cross-reference rather than double-file the same dropped-event story.
