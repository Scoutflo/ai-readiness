---
name: audit-grafana
description: 'Read-only scored audit of the Grafana application layer: datasource health and credentials, dashboard panel semantics (scope-leak and stale-datasource checks), alert rule wiring and receiver delivery, query hygiene, usage and cost visibility; writes findings.json and report.md and changes nothing. Use when the user mentions auditing or scoring Grafana, Grafana dashboards, Grafana alert rules, contact points, notification policies, or panel queries. Do not use for Loki, Tempo, Mimir, or VictoriaMetrics backend health (use audit-lgtm), for proving a page reaches a human (use audit-alert-routing), for Sentry (use audit-sentry), for DigitalOcean (use audit-digitalocean), or for Google Cloud (use audit-gcp).'
---

# Audit Grafana

Score how much your Grafana would actually help during an incident. Inventory everything through the API, then prove behavior live: replay panel queries, hunt scope leaks, walk the notification policy tree to a real receiver, and check every critical service for dashboards, alerts, and ingestion. Output is `findings.json` and `report.md` per the report standard, with stable `GRAF-NNN` finding IDs.

## Scope and boundaries

This audit owns the Grafana application layer: datasources, dashboards, Grafana-managed alert rules, contact points, notification policies, query and label hygiene as visible from Grafana, and usage surfaces.

- Backend store internals (Loki, Tempo, Mimir, VictoriaMetrics ingestion health, retention config, HA) belong to `audit-lgtm`. This audit reads backends only through Grafana datasources.
- Proving that a page actually reaches a human end to end belongs to `audit-alert-routing`. Here you inspect wiring and flag unproven routes.
- Error-tracker health belongs to `audit-sentry`.
- Every fix points at `setup-grafana`.

**Read-only, absolutely.** Every call is a GET except `POST /api/ds/query`, which executes a read-only query (POST by transport, read by effect). No test notifications, no silences, no annotations, no dashboard saves, no state creation of any kind. If a check seems to need a write, it belongs in `setup-grafana`.

## Doctor gate

| Integration | Config keys | Env var | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| Grafana | `grafana.url`, `grafana.token_env` | named by `grafana.token_env` | Service account: Viewer basic role plus `datasources:read` and `alert.provisioning:read` (details in [references/api-checks.md](references/api-checks.md#minimum-permissions)) | read-only |
| Slack (optional) | `slack.webhook_env` | named by `slack.webhook_env` | Post to one incoming webhook | optional |

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
# grafana.token_env names the variable; presence check only, never print the value.
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
command -v curl >/dev/null || { echo "curl is required"; exit 1; }
command -v jq   >/dev/null || { echo "jq is required"; exit 1; }

curl -fsS --max-time 10 "${GRAFANA_URL}/api/health" | jq -e '.database == "ok"' >/dev/null \
  || { echo "Grafana health check failed at ${GRAFANA_URL}/api/health"; exit 1; }
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  "${GRAFANA_URL}/api/org" | jq '{org: .name, id: .id}'
```

Expected: health passes silently, then the org name and id print. A 401 means the token is wrong for this instance; a 403 here (health passing) means the token exists but lacks even the Viewer basic role; a connection failure means the URL is wrong or unreachable. Either way, stop and run `/scoutflo:connect`. Never proceed past a failed doctor check, and never downgrade one into a finding.

`GET /api/user` is not used here or anywhere in this skill: on modern Grafana (confirmed live on 10.4.1), a real, correctly-scoped service-account token gets a hard `403 "Endpoint only available for users"` from `/api/user` regardless of its assigned role, because that endpoint identifies an interactively logged-in user, not a service account. Under `curl -fsS` and `set -eu`, that 403 crashes the whole doctor gate before the audit ever starts, even though the token is perfectly healthy. `/api/org` identifies the token's org correctly for both service-account tokens and legacy API keys, so it is the only identity check used throughout this skill.

Also run the least-privilege probe from [references/api-checks.md](references/api-checks.md#minimum-permissions). A 403 on org administration is the healthy result; a 200 becomes finding GRAF-006.

## Live-safety gate

Before any real check, confirm what you are pointed at:

```bash
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/org" \
  | jq '{org: .name, id: .id}'
echo "target: ${GRAFANA_URL}"
```

Compare the printed URL and org against `grafana.url` in `~/.scoutflo/toolkit.yaml`. If they differ, or the org name is not the one you expect (staging token against production, or the reverse), stop and report the mismatch. Never proceed on "probably the right instance".

Load `./scoutflo-audits/topology.md` if it exists; its service list is your critical-service list and its names are canonical in findings and the coverage matrix. If it does not exist, infer services live from datasource labels, note the inference in the report, and suggest `/scoutflo:map-topology`.

## Estate sizing

Count before judging, and declare the path in the terminal output:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }

SMALL_MAX_OBJECTS="40"    # dashboards + alert rules + datasources combined; example, tune to your environment
MEDIUM_MAX_OBJECTS="200"  # example, tune to your environment
BATCH_SIZE="15"           # dashboards per batch on the large path; example, tune it

DASHBOARDS="$(curl -fsS --max-time 15 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  "${GRAFANA_URL}/api/search?type=dash-db&limit=5000" | jq 'length')"
# Recording rules (rules carrying a `record` block, GA since Grafana 11.3) are not alert
# rules; exclude them from the alert-rule count so coverage is judged against alerting only.
RULES="$(curl -fsS --max-time 15 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  "${GRAFANA_URL}/api/v1/provisioning/alert-rules" 2>/dev/null \
  | jq '[.[] | select((.record // null) == null)] | length' 2>/dev/null || echo 0)"
DATASOURCES="$(curl -fsS --max-time 15 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  "${GRAFANA_URL}/api/datasources" | jq 'length')"
TOTAL=$((DASHBOARDS + RULES + DATASOURCES))
echo "dashboards=${DASHBOARDS} alert_rules=${RULES} datasources=${DATASOURCES} scored_objects=${TOTAL}"

# Guided-walkthrough drift check, per report-standard/README.md#using-topology-and-prior-runs-as-a-guided-walkthrough:
# compare against the last run rather than a blank slate. State the result in the executive summary;
# never silently omit it. This never skips a live check - every check in later phases still runs fresh.
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana"
PREV_RUN="$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)"
DRIFT="first run"
if [ -n "$PREV_RUN" ] && [ -f "${PREV_RUN}/findings.json" ]; then
  PREV_TOTAL="$(jq -r '.estate.objects // empty' "${PREV_RUN}/findings.json")"
  if [ -n "$PREV_TOTAL" ]; then
    if [ "$PREV_TOTAL" -eq "$TOTAL" ]; then
      DRIFT="estate unchanged since ${PREV_RUN##*/} (${PREV_TOTAL} objects then, ${TOTAL} now)"
    else
      DRIFT="estate changed since ${PREV_RUN##*/}: ${PREV_TOTAL} -> ${TOTAL} objects"
    fi
  else
    DRIFT="previous run recorded no estate data; treating as first run"
  fi
fi
echo "drift: ${DRIFT}"

if [ "${TOTAL}" -le "${SMALL_MAX_OBJECTS}" ]; then
  echo "path: small (<= ${SMALL_MAX_OBJECTS} objects) -- single pass, no worklist"
elif [ "${TOTAL}" -le "${MEDIUM_MAX_OBJECTS}" ]; then
  echo "path: medium (<= ${MEDIUM_MAX_OBJECTS} objects) -- per-phase passes, one run, no worklist"
else
  echo "path: large (> ${MEDIUM_MAX_OBJECTS} objects) -- dashboard batches of ${BATCH_SIZE} against a worklist; see Large-path worklist below"
fi
```

- **Small** (`TOTAL <= SMALL_MAX_OBJECTS`): Phases 1-7 run exactly as written, one pass, no worklist. A handful of dashboards and rules do not need bookkeeping.
- **Medium** (`TOTAL <= MEDIUM_MAX_OBJECTS`): the same phases, still completed in one run; no worklist file.
- **Large** (`TOTAL > MEDIUM_MAX_OBJECTS`): dashboards, the object Phase 3's semantic QA gate judges one at a time and the one that dominates cost at scale, are worked in batches of `BATCH_SIZE` against a durable worklist under a run-ID-keyed run directory; see [Large-path worklist: dashboard batches and resume](#large-path-worklist-dashboard-batches-and-resume). Datasources, alert rules, contact points, and policies stay cheap enough at Grafana-typical ratios to inventory in one pass even when dashboards are batched.

Never silently truncate a large estate: if the run judged a subset of dashboards, the report names what was skipped and the coverage denominators reflect it.

## Large-path worklist: dashboard batches and resume

Runs on the large path only. State lives under a run-ID-keyed run directory, `./scoutflo-audits/grafana/runs/<RUN_ID>/`, not a calendar-date directory: a run that is still batching when the UTC date rolls over would otherwise abandon its worklist or have to guess which date directory is still its own. This directory holds only the worklist, the lock, and per-batch UID files; the dashboard, datasource, and rule data itself still lands in the standard dated raw directory every other phase in this skill reads from, so nothing else in the skill changes when the large path is active.

0. **Find a resumable run, or start a new one.**

   ```bash
   set -eu
   AUDIT_ROOT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana"
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
   fi
   ```

   Only mint a fresh `RUN_ID` when nothing resumable is found:

   ```bash
   set -eu
   AUDIT_ROOT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana"
   RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"   # first-seen timestamp of this run; stable for its lifetime
   RUN_DIR="${AUDIT_ROOT}/runs/${RUN_ID}"
   mkdir -p "${RUN_DIR}/batches"
   echo "${RUN_ID}" > "${RUN_DIR}/run-id"
   echo "run: ${RUN_ID}"
   ```

1. **Build or resume the worklist.** One row per dashboard UID, tab-separated status `pending` or `done`. If the resumed run's `worklist.tsv` already exists, continue from it; never rebuild an existing worklist, that forgets progress.

   ```bash
   set -eu
   # Resolved from ~/.scoutflo/toolkit.yaml
   GRAFANA_URL="https://grafana.example.com"   # grafana.url
   [ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
   RUN_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/runs/20260717T140500Z"   # example; this run's resolved RUN_DIR
   WORKLIST="${RUN_DIR}/worklist.tsv"

   if [ -s "${WORKLIST}" ]; then
     done_n=$(awk -F'\t' '$2 == "done"' "${WORKLIST}" | wc -l | tr -d ' ')
     pending_n=$(awk -F'\t' '$2 == "pending"' "${WORKLIST}" | wc -l | tr -d ' ')
     echo "resuming existing worklist: done=${done_n} pending=${pending_n}"
   else
     curl -fsS --max-time 15 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
       "${GRAFANA_URL}/api/search?type=dash-db&limit=5000" \
       | jq -r '.[].uid' | awk '{print $0"\tpending"}' > "${WORKLIST}"
     total=$(wc -l < "${WORKLIST}" | tr -d ' ')
     echo "worklist built: ${total} dashboards, all pending"
   fi
   ```

2. **Lock, then claim one batch.** Acquire `worklist.lock` before reading pending rows; a lock older than `LOCK_STALE_MINUTES` is abandoned and safe to reclaim.

   ```bash
   set -eu
   RUN_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/runs/20260717T140500Z"   # example; this run's resolved RUN_DIR
   LOCK="${RUN_DIR}/worklist.lock"
   LOCK_STALE_MINUTES="30"   # example, tune to your batch size and expected run length

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
   ```

3. **Pull and judge the batch, then mark it done.** `DASHBOARD_UIDS_FILE` and `SKIP_NON_DASHBOARD` (documented at the top of `scripts/grafana-audit.sh`) scope the script to this batch's dashboards only, after the first batch has already captured datasources, alert rules, and contact points once:

   ```bash
   set -eu
   RUN_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/runs/20260717T140500Z"   # example; this run's resolved RUN_DIR
   WORKLIST="${RUN_DIR}/worklist.tsv"
   BATCH_SIZE="15"   # dashboards per batch on the large path; example, tune it
   export GRAFANA_URL="https://grafana.example.com"   # grafana.url
   # GRAFANA_TOKEN must already be exported in this shell; see the doctor gate.
   export OUT_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/$(date -u +%Y-%m-%d)/raw"   # same raw dir every other phase reads
   export SKIP_NON_DASHBOARD="1"   # "0" or unset on this run's first batch only

   BATCH_FILE="${RUN_DIR}/batches/$(date -u +%s).uids"
   awk -F'\t' '$2 == "pending"' "${WORKLIST}" | head -n "${BATCH_SIZE}" | cut -f1 > "${BATCH_FILE}"
   if [ ! -s "${BATCH_FILE}" ]; then
     echo "no pending dashboards; worklist complete"
     rm -f "${RUN_DIR}/worklist.lock"
     exit 0
   fi

   export DASHBOARD_UIDS_FILE="${BATCH_FILE}"
   bash scripts/grafana-audit.sh
   # ... run Phase 3's checks (GRAF-020 to GRAF-028) against this batch's dashboards now ...

   while IFS= read -r uid; do
     if [ -f "${OUT_DIR}/dashboards/${uid}.json" ]; then
       sed -i.bak "s/^${uid}	pending/${uid}	done/" "${WORKLIST}"
     else
       echo "batch item ${uid} did not complete; left pending for the next batch"
     fi
   done < "${BATCH_FILE}"
   rm -f "${WORKLIST}.bak"

   rm -f "${RUN_DIR}/worklist.lock"   # release once this batch's rows are marked, not the whole run
   pending_left=$(awk -F'\t' '$2 == "pending"' "${WORKLIST}" | wc -l | tr -d ' ')
   echo "batch done: $(wc -l < "${BATCH_FILE}" | tr -d ' ') dashboards attempted, pending=${pending_left}"
   ```

4. **Repeat step 2 and 3** until `pending_left` is `0`, setting `SKIP_NON_DASHBOARD="1"` on every batch after the first. Assemble the Phase 3 findings incrementally as batches complete rather than holding them all in memory for one final pass.

Before writing `findings.json` and `report.md`, assert the worklist finished:

```bash
set -eu
AUDIT_ROOT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana"
RUN_DIR="${RUN_DIR:-$(ls -dt "${AUDIT_ROOT}"/runs/*/ 2>/dev/null | head -n 1 | sed 's:/$::')}"
if [ -n "${RUN_DIR}" ] && [ -f "${RUN_DIR}/worklist.tsv" ]; then
  pending=$(awk -F'\t' '$2 == "pending"' "${RUN_DIR}/worklist.tsv" | wc -l | tr -d ' ')
  echo "worklist pending: ${pending}"
  [ "${pending}" -eq 0 ] || { echo "worklist incomplete; do not publish findings.json yet, resume the run instead"; exit 1; }
else
  echo "no worklist (small or medium path); nothing to assert"
fi
```

Expected: `worklist pending: 0` and exit 0 on a completed large run. A nonzero pending count means resume the run per step 0, never publish a partial score as final.

❌ Started a fresh run directory every invocation without checking for a pending worklist, so a run interrupted at dashboard 80 of 300 restarts from dashboard 1 on the next invocation.
✅ Scanned `${AUDIT_ROOT}/runs/*/worklist.tsv` first, found one with 220 rows still `pending`, and resumed it instead of minting a new `RUN_ID`.

## Phase 1: Inventory

On the small and medium paths, run the bundled read-only inventory script once, unscoped. It only issues GETs and records every failure as evidence:

```bash
set -eu
export GRAFANA_URL="https://grafana.example.com"   # grafana.url from ~/.scoutflo/toolkit.yaml
# GRAFANA_TOKEN must already be exported in this shell; see the doctor gate.
bash scripts/grafana-audit.sh
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/$(date -u +%Y-%m-%d)/raw"
cat "${RAW_DIR}/summary.txt"
```

On the large path, this phase runs incrementally as part of the batch loop in [Large-path worklist: dashboard batches and resume](#large-path-worklist-dashboard-batches-and-resume); do not also run the unscoped call above, it defeats the batching.

Expected: a summary of datasource, dashboard, panel, rule, and contact-point counts plus an error count. Failed calls are kept as `<file>.http-<status>` because a 403 or 404 body is evidence. Counts are inventory, not results: forty dashboards and two hundred rules prove nothing yet. `smells.json` holds candidate defects that must be verified live before any becomes a finding.

## Phase 2: Datasource checks

Checks GRAF-001 to GRAF-006 (catalog and jq snippets in [references/api-checks.md](references/api-checks.md)):

1. **Health (GRAF-001).** The script already fetched `/api/datasources/uid/{uid}/health` per datasource. Plugins that do not implement health return 400; for those, fall back to the minimal query in step 3 rather than scoring the 400 as failure.
2. **Plaintext credentials (GRAF-002).** Run the plaintext-secret jq against `datasources.json`. Any secret-shaped key visible in `jsonData` or credentials embedded in the URL is a critical finding; secrets belong in secure fields. Report key names only, never values.
3. **Usable data (GRAF-004).** For each datasource, run one minimal domain query via `/api/ds/query` (cookbook pattern 2) or a proxy label read. A datasource that connects but returns no data for its most basic query is configured, not useful.
4. **Implicit default (GRAF-003), duplicates (GRAF-005), over-privilege (GRAF-006).** From `smells.json` (`implicit-default-datasource`), the duplicates jq, and the doctor-gate probe.

## Phase 3: Semantic dashboard QA gate

The core of this audit. A dashboard is not done because it renders; it is done when every panel answers its intended question, at the intended scope, live. On large installations, inspect at minimum every dashboard covering a topology.md service plus anything your team treats as an incident view; list the inspected set in the report and score only what you inspected.

For every user-facing stat panel, first write down: the intended question, the source query or API, the expected scope, the reducer, the unit, and the acceptable no-data state. The checks below judge reality against that record.

1. **Live replay (GRAF-020).** Replay every panel target through `/api/ds/query` using the panel's own target object (cookbook pattern 1). A populated `error` field is a broken panel. `frames: 0` with no error needs a second look: intentional no-data or label drift?
2. **Scope-leak hunt (GRAF-021).** Read each target's selectors and any generated URLs in the panel JSON. A panel titled for one service, environment, or project must carry a matching filter. A dashboard for three services that silently queries the whole org is a high finding, and the panel looks completely normal while doing it.

   - ❌ `Panel "checkout error rate" passes: it renders a live number with no query error.`
   - ✅ `Panel "checkout error rate" fails GRAF-021: the target expression has no service or namespace selector at all, so it is silently summing every service's errors org-wide; the number looks plausible and is wrong.`
3. **Stable IDs over slugs (GRAF-022).** External-system panels must filter by stable IDs (project ID, zone ID, namespace) rather than text or slug matching. Text filters silently match nothing, or the wrong thing, after a rename.
4. **Pagination and caps (GRAF-023).** Any target with `limit`, `per_page`, or `pageSize` parameters returns an investigation list, not a total. The script flags these as `paginated-source`. Presenting a capped list's length as a total is a lie the panel tells confidently.
5. **Reducer validity (GRAF-024).** The `count` reducer is valid only when source rows are the intended unit. The script flags `count-reducer-on-stat`; verify each against the source shape. Numeric sources need `sum`, `lastNotNull`, or an explicit transformation.
6. **Source-count parity (GRAF-027).** Cross-check each key stat against the provider-native source of truth: an issues panel against the tracker's own count endpoint, a Prometheus stat against the raw instant query value (cookbook pattern 2). A mismatch is a high finding even when the panel "works".
7. **Variables (GRAF-025).** Every template variable must resolve to at least one real value; check via proxy label-values reads. A variable resolving empty blanks every panel beneath it.
8. **Link scope (GRAF-026).** Data links and inspect links must preserve the panel's scope. A service-scoped panel linking to an org-wide list breaks the responder's context mid-incident.
9. **Dangling datasources (GRAF-028).** Run the dangling-reference jq: panels pointing at datasource UIDs that no longer exist.

Judge only live JSON. `dashboards/<uid>.json` came from the API this run; if you re-check anything later, re-fetch by UID first. Never audit a local export or an old copy.

## Phase 4: Alert configuration checks

Inspection only. Do not send test notifications, create silences, or touch state; a routed live test pages real humans and belongs in `setup-grafana` behind its confirmation gate, or in `audit-alert-routing`.

Checks GRAF-050 to GRAF-056, against `alert-rules.json`, `contact-points.json`, and `notification-policies.json` from the raw dump.

Two version-awareness notes before judging, both confirmed against current Grafana:

- **Recording rules are not alert rules.** Since Grafana 11.3 a Grafana-managed rule may carry a `record` block (with `metric`, `from`, and `target_datasource_uid`) instead of alerting semantics. Exclude any rule where `.record != null` from the alert-rule checks and the coverage denominator, count it separately, and for a recording rule check only that `record.target_datasource_uid` resolves to a live datasource; scoring it as an alert rule with no receiver is a false finding.
- **The provisioning API is deprecated but still functional.** On Grafana 12.x the alerting provisioning endpoints (`/api/v1/provisioning/{alert-rules,contact-points,policies,mute-timings,templates}`) are deprecated in favor of the App Platform APIs at `/apis/notifications.alerting.grafana.app/v1beta1/namespaces/{ns}/{receivers,routingtrees,templategroups,timeintervals}`; the old endpoints keep working "until a future release". This audit still reads the provisioning API and that is correct for now. Gate any future switch on the new endpoint responding, not a hardcoded version number; if a provisioning read returns 404/410 on a newer Grafana, fall forward to the App Platform path rather than recording an empty result.

The checks:

1. **Receiver wiring (GRAF-050).** Walk the policy tree and list every referenced receiver, then confirm each exists among contact points and is not a placeholder:

   ```bash
   RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/$(date -u +%Y-%m-%d)/raw"   # this run's raw dir
   jq -r '[.. | objects | select(has("receiver")) | .receiver] | unique[]' \
     "${RAW_DIR}/notification-policies.json"
   jq -r '.[] | "\(.name)\t\(.type)"' "${RAW_DIR}/contact-points.json"

   # Assert every routed receiver actually exists as a contact point.
   jq -e --slurpfile cp "${RAW_DIR}/contact-points.json" '
     ([$cp[0][].name]) as $known
     | ([.. | objects | select(has("receiver")) | .receiver] | unique) as $routed
     | ($routed - $known) | length == 0
   ' "${RAW_DIR}/notification-policies.json"
   ```

   Expect: exit 0, prints `true`. A `false` means the receiver diff is nonempty; re-run with `- $known` removed from the filter to print the missing names. A route to a missing, empty, or obviously fake receiver (a webhook to localhost, an example.com email) is critical: alerts fire and nobody finds out. Secure settings are masked by the API, so a syntactically valid receiver is at best `configured` here, even when the assertion passes.
2. **Rule query replay (GRAF-051).** For every active rule, replay its data queries through `/api/ds/query`, skipping refs whose datasource is the expression engine (`__expr__`). A rule whose primary query fails live cannot fire correctly no matter what the rule list says.
3. **State handling (GRAF-052).** `noDataState` and `execErrState` must look deliberate. Everything at defaults across all rules means nobody decided what silence means.
4. **Labels (GRAF-053).** Every rule carries `severity` and `service` labels; without them routing and the coverage matrix cannot work:

   ```bash
   RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/$(date -u +%Y-%m-%d)/raw"   # this run's raw dir
   # Exclude recording rules (.record != null): they route nothing and carry no severity/service.
   jq '[ .[] | select((.record // null) == null)
         | select(((.labels.severity // "") == "") or ((.labels.service // "") == ""))
         | {uid, title} ]' "${RAW_DIR}/alert-rules.json"
   ```

5. **Annotations (GRAF-054).** Paging rules need `summary` and `runbook_url` annotations; a page without a runbook link slows the responder at the worst moment.
6. **Delivery proof (GRAF-055).** A route with no evidence of a live delivery is `configured`, never working. Flag it and point at `audit-alert-routing` for end-to-end proof or `setup-grafana` for a confirmed routed test.
7. **Noise controls (GRAF-056).** Grouping, group wait, and repeat interval left at defaults on high-volume routes predict alert fatigue.

## Phase 4b: Alert hygiene (noise signals)

Phase 4 proved rules evaluate and route to a real receiver. This phase asks the opposite: is what those rules produce sustainable, or is the paging stream structurally noisy? Every check here is read-only and reads the same provisioning objects Phase 4 already pulled (`alert-rules.json`, `notification-policies.json`, `contact-points.json`) plus two cheap live reads (mute timings and Grafana silences). These checks join the Alerting category and grow its denominator; they are not a new category and do not reweight. Commands are in [references/api-checks.md](references/api-checks.md#alert-hygiene-noise-signals-graf-100-to-graf-103).

Honest ceiling, stated in the report every run:

- These are **structural config signals** read from the rule and policy definitions — a paging rule with no `for` debounce, no flap hold, a noisy no-data state, a route with no meaningful grouping, a stale silence. They are **not** an observed flapping rate, a per-receiver page volume, or an alert-to-incident actionability number; never report a fabricated "N% actionable".
- Grafana-managed alerting is **shallow for runtime hygiene**: the provisioning API exposes rule and policy *config*, but no firing-episode history and no per-receiver notification counters. So unlike a Prometheus/Alertmanager path, this audit cannot reconstruct how often a rule actually flapped or which receiver absorbed the most pages — it reports the config that *predicts* noise and says so. Observed firing/volume behavior lives outside what Grafana-managed alerting exposes.
- **Inhibition is not a lever here.** The built-in Grafana Alertmanager does not support inhibition rules (only Mimir/Cortex or an external Alertmanager do), so there is no inhibition check to run; do not invent one.
- Thresholds below are tunable example variables, not gospel. Judge each candidate against your signal's volatility before filing.

Checks:

- **GRAF-100 (missing `for`).** From `alert-rules.json`, `for` per rule. A paging-severity rule with `for: 0s` fires on a single evaluation and pages on a transient breach that may self-correct before anyone looks. A `for` matched to the signal's volatility is the fix.
- **GRAF-101 (flap protection).** Two resolve-damping controls, both absent by default. `keep_firing_for` (the Recovering state) holds an alert firing for a set duration after its condition clears, so a metric oscillating around the threshold does not emit repeated firing/resolved/firing cycles; `keep_firing_for: 0s` or absent is no hold. A recovery-threshold (a distinct bound for returning to Normal, separate from the firing bound) is the config form of hysteresis. Read the rule's threshold condition for a recovery bound versus a single evaluator — the internal field naming varies by Grafana version, so read the condition, do not pattern-match one field name. A flap-prone paging rule with `keep_firing_for: 0s` and a single-threshold condition has no anti-flap damping.
- **GRAF-102 (muting hygiene).** Every mute timing a route references via `mute_time_intervals` must resolve to a definition in `GET /api/v1/provisioning/mute-timings`; a dangling reference is a config error. (Grafana 12.1 renamed "Mute Timings" to "Active Time Intervals" in the UI; the provisioning resource is still `mute-timings` and the App Platform resource is `timeintervals`. Use the "Active Time Intervals" wording in the report when the target is 12.1 or newer, "Mute Timings" otherwise; the check itself is unchanged.) Then list active silences via the Grafana Alertmanager silences API: an active silence with a far-future or perpetually-renewed `endsAt` is hiding real alerts, not managing noise — flag it with its matcher and `createdBy`. (Grafana auto-deletes expired silences after 5 days, so a lingering active one is a deliberate act.)
- **GRAF-103 (resolve-noise).** From `contact-points.json`, `disableResolveMessage`. A paging contact point with `disableResolveMessage: false` emits both a fire and a resolve per incident, roughly doubling its volume. Often deliberate, so this is `low`; the provisioning API carries no per-receiver counter, so name it as a config signal, never as measured volume.

Two folds into the existing checks, no new IDs:

- **`no_data_state` / `exec_err_state` = `Alerting` (folds into GRAF-052).** GRAF-052 already flags whether these fields are set deliberately. The noise-specific reading: `no_data_state: Alerting` or `exec_err_state: Alerting` (especially paired with a short `for`) pages via a synthetic `DatasourceNoData` / `DatasourceError` instance on a transient gap or query error. Also confirm whether a policy deliberately routes `alertname=DatasourceNoData` / `DatasourceError`; an unrouted synthetic alert is silent noise.
- **`group_by` semantics (folds into GRAF-056).** GRAF-056 already covers grouping and repeat interval. State the semantics exactly when you read a policy's `group_by`: an **empty list `[]` collapses everything into one group**, while the special value **`['...']` means "group by every label", which DISABLES aggregation** and yields one group per distinct alert — the opposite of grouping. A meaningful `group_by` names the few labels that define an incident.

Every GRAF-100 to GRAF-103 finding points at `setup-grafana`, anchored to the section that fixes that class: `setup-grafana#alert-rules` for `for` and `keep_firing_for`/recovery threshold, `setup-grafana#notification-policies` for mute-timing references and silences, `setup-grafana#contact-points` for `disableResolveMessage`. A `401`/`403` on any read here is an auth-scope `blocked` result, never a clean or passing one.

## Phase 5: Query and cardinality hygiene

Checks GRAF-070 to GRAF-072. These start from heuristics over `panel-targets.json`; verify each hit before filing.

```bash
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/$(date -u +%Y-%m-%d)/raw"   # this run's raw dir
# Counter-style metrics queried without rate/increase (candidates for GRAF-070)
jq '[ .[] | { dashboard_uid, panel_id, raw_counters:
      [ .targets[]? | (.expr // "") | tostring
        | select(test("_total|_count") and (test("rate\\(|increase\\(|irate\\(") | not)) ] }
    | select((.raw_counters | length) > 0) ]' "${RAW_DIR}/panel-targets.json"

# Identical expressions repeated across panels (candidates for GRAF-071)
jq -r '[ .[] | .targets[]? | (.expr // "") | tostring | select(length > 0) ]
       | group_by(.) | map(select(length > 3) | {expr: .[0], uses: length}) | .[]
       | "\(.uses)x \(.expr)"' "${RAW_DIR}/panel-targets.json"
```

A raw counter on a graph shows a meaningless ever-growing line; an expensive expression repeated across many panels wants a recording rule. For log labels (GRAF-072), list Loki labels through the proxy (cookbook pattern 3) and flag ID-shaped label names (user, request, session, trace IDs) and any label whose value count is far beyond your norm. `CARDINALITY_LIMIT="100"` values per label is an example starting point, tune to your environment. Deeper cardinality analysis inside the backends belongs to `audit-lgtm`.

## Phase 6: Usage, cost, and retention

Checks GRAF-080 to GRAF-082:

```bash
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/$(date -u +%Y-%m-%d)/raw"   # this run's raw dir
# Is there any usage / ingestion-health dashboard at all?
jq '[ .[] | select(.title | test("usage|billing|ingest|monitoring health"; "i"))
      | {uid, title} ]' "${RAW_DIR}/dashboard-index.json"
```

1. **Usage visibility (GRAF-080).** On managed Grafana Cloud, a usage datasource is provisioned for you; confirm a dashboard actually queries it and returns data. Self-hosted, look for an ingestion-health dashboard fed by your backend metrics. No usage view means the first cost signal is the invoice.
2. **Cost alerts (GRAF-081).** At least one rule should watch ingestion volume or spend movement (active series, log bytes per day, span volume). Thresholds are yours to pick; alerting on a week-over-week jump is an example starting point, tune to your billing model.
3. **Retention (GRAF-082).** Retention must be a documented decision with an owner, not an inherited default. Whatever period your compliance and debugging needs justify is correct; the finding is the absence of the decision, not any particular number.

## Phase 7: Coverage matrix

Judge coverage per critical service from topology.md, using its canonical names. For each service, three checks:

1. **Dashboard exists (GRAF-090).** At least one inspected dashboard is scoped to this service (by variable, selector, or title backed by a matching filter).
2. **Alert rule exists (GRAF-091).** At least one severity-labeled rule filters on this service's label.
3. **Ingestion visible (GRAF-092).** A live probe returns recent data for this service's label on the metrics or logs side (cookbook pattern 3).

Report one matrix row per service: `Service | Ready | Dashboard | Alerts | Ingestion | Owner | Gap`, using `pass` / `partial` / `fail` / `blocked` / `not-in-scope`. Name services in findings: "checkout and payments have no alert rules" is a finding, "two services lack alerts" is not. When live discovery contradicts topology.md, propose an update in the report; only the mapping skill and you edit that file.

Then render the Scoutflo Topology Readiness section per [topology-readiness.md](../../report-standard/topology-readiness.md): evaluate T1 to T6 per critical service from `./scoutflo-audits/topology-export.json`, read-only. An edge this audit verified live (for example a `MONITORED_BY` edge to a Grafana alert rule this audit confirmed replays its query live with no error via `/api/ds/query`, GRAF-051, and carries the service's label, GRAF-053) counts toward T6. Gaps that map to an existing finding reference its ID; gaps with no finding get a `TOPO-` row pointing at `/scoutflo:map-topology`. Render check names and confidence per the standard: plain-English column headers (T-codes only in the legend line), confidence as `n/10`, and — whenever any service is below ready — the ticket-ready sync-readiness action plan table from [topology-readiness.md](../../report-standard/topology-readiness.md). If the export or topology.md is missing, or exists but describes a different target than this audit covers (wrong `cluster_id`, non-overlapping services), the section renders the matching state from topology-readiness.md with its one-line unlock (run `/scoutflo:map-topology` against the right estate, or hand-author the export per `scoutflo-export.md` for non-Kubernetes estates); it never guesses and never says a bare "unavailable". Readiness is reported, never folded into the 0-100 score.

## Scoring and outputs

| Category | Weight | What it measures |
| --- | ---: | --- |
| Datasources and access | 15 | Health, usable data, credential handling, least privilege |
| Dashboard semantics | 25 | Panels answer their intended question live, correctly scoped |
| Alerting | 25 | Rules evaluate and route to real receivers with labels and runbooks |
| Query hygiene | 10 | Counter handling, recording rules, label cardinality |
| Usage and cost | 10 | Ingestion visibility, cost alerts, deliberate retention |
| Service coverage | 15 | Dashboards, alerts, and ingestion per critical service |

Mechanics follow [severity-and-scoring.md](../../report-standard/severity-and-scoring.md). Apply each catalog check across its objects: `pass` when every inspected object passes; `partial` when failures are confined to non-critical objects or the state is present but unproven live; `fail` when a critical service is affected or failure is widespread; `blocked` with the blocker as evidence. Unsure between two results, pick the lower and say why. A whole category blocked (for example, all provisioning reads 403) is excluded from scoring and stated everywhere the score appears.

- ❌ `Scored dashboard semantics 100: forty dashboards render with no query errors.`
- ✅ `Scored dashboard semantics 60: panels render, but three key stats mismatch the provider-native source (GRAF-027) and one dashboard silently queries org-wide scope (GRAF-021), so credit stops at partial.`

Write both artifacts to `./scoutflo-audits/grafana/<YYYY-MM-DD>/`:

- `findings.json` per the [schema](../../report-standard/findings-schema.md): prefix `GRAF`, IDs from the [check catalog](references/api-checks.md#check-catalog), evidence quoting real command output, every finding with a `remediation` pointer into `setup-grafana`, and `estate.objects`/`estate.path` set to the count and path chosen in [Estate sizing](#estate-sizing).
- `report.md` per the [template](../../report-standard/report-template.md): executive summary, scorecard, findings table, the Phase 7 coverage matrix, next safe actions ordered severity-then-safety, delta against the previous run (or "first run, no delta"), evidence appendix.

Emit, verify, brief:

```bash
set -eu
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/$(date -u +%Y-%m-%d)"
mkdir -p "$OUT"
# ... write findings.json and report.md per the report standard, then verify:
jq -e '.schema == "scoutflo-findings/v1" and .target == "grafana"
       and (.findings | type == "array")' "$OUT/findings.json" >/dev/null \
  && echo "findings.json valid"
jq -e '.estate.path == "small" or .estate.path == "medium" or .estate.path == "large"' \
  "$OUT/findings.json" >/dev/null && echo "estate sizing recorded"
grep -q '^# ' "$OUT/report.md" && echo "report.md present"
# Output conformance: the emitted report.md must match report-standard/report-template.md.
# This catches header/score-line/section drift before the run is declared done.
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-report.sh" "$OUT/report.md"

# One Slack brief per run: titles only, never evidence values, no hostnames.
# slack.webhook_env names the webhook variable; skip when unset.
if [ -n "${SCOUTFLO_SLACK_WEBHOOK:-}" ]; then
  SCORE="$(jq -r '.score.overall' "$OUT/findings.json")"
  COUNTS="$(jq -r '.severity_counts
    | "\(.critical) critical, \(.high) high, \(.medium) medium, \(.low) low"' \
    "$OUT/findings.json")"
  TOP="$(jq -r '[.findings[] | "\(.id) \(.title)"] | .[0:3] | join("\n")' "$OUT/findings.json")"
  jq -n --arg head "audit-grafana $(date -u +%Y-%m-%d): ${SCORE}/100. ${COUNTS}." \
        --arg top "$TOP" --arg path "$OUT/report.md" \
        '{text: ($head + "\nTop findings:\n" + $top + "\nReport: " + $path)}' \
    | curl -fsS --max-time 10 -H 'Content-Type: application/json' -d @- "$SCOUTFLO_SLACK_WEBHOOK" \
    || echo "Slack brief failed to send; audit result unaffected"
fi
```

Compute the delta against the previous run date per the [report standard](../../report-standard/README.md) and include the score movement and delta line in the brief text when a baseline exists. The end-to-end gate is 85 with zero exclusions and every critical service passing every coverage row. Below it, write "good base coverage", never "end to end". A failed brief send is noted and never fails the run. Keep `./scoutflo-audits/` out of public version control.

When invoked by `audit-all`, skip the Slack brief; the orchestrator
sends exactly one combined message.

To fix what you found, run `setup-grafana` with the finding IDs. To re-check after fixes, run this audit again; the delta computes itself. To schedule recurring runs, see `schedule-audits`.

### Lifecycle, exemptions, and totals

Before rendering the report:

1. Load the previous run's findings.json when one exists; classify every
   finding per the lifecycle table in report-standard/findings-schema.md
   (`new`, `unchanged`, `regressed`; resolved IDs go to the delta).
2. Load `./scoutflo-audits/exemptions.yaml` when present. Entries with
   `id`, `reason`, and `expires` all set and unexpired suppress their
   finding into the Suppressed appendix; malformed or expired entries are
   reported, never honored.
3. Every findings area and coverage cell carries its denominator
   (`passed/total checks`). The score excludes suppressed findings and
   the scorecard states the suppressed count.

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Panel query returns 200 with plausible data and gets credited | Treat query success as syntax evidence only; verify scope, reducer, and pagination before crediting the number shown |
| Stat presents a capped list's length as a total | Check targets for `limit`/`per_page` parameters; require a native count endpoint or a server-side aggregation |
| Dashboard for one service silently queries the whole org | Compare every selector and generated URL against the scope the panel title claims |
| Alerts exist but route nowhere | Walk the policy tree to a real, non-placeholder receiver; missing or fake receivers are critical findings |
| Audit "tests" a route and pages the on-call | Audits never send notifications; delivery tests live in `setup-grafana` behind confirmation, proof in `audit-alert-routing` |
| Score inflated by object counts | Forty dashboards prove nothing; credit only meaningful queries returning data a responder could act on |
| Judging a stale export instead of the live object | Re-fetch dashboard JSON by UID this run and judge only that |
| Blocked reads silently skipped or scored as pass | Record the 403 or timeout as `blocked` evidence; exclude and state whole-category blockage |
| Backend internals audited from Grafana | Stay on the app layer; Loki, Tempo, Mimir, and VictoriaMetrics internals belong to `audit-lgtm` |
| Token upgraded to Admin to avoid blocked rows | Run degraded and report the tradeoff; least privilege is itself under audit (GRAF-006) |
| Worklist and batches run against a small install | Size the estate first; at or below `SMALL_MAX_OBJECTS` the small path runs one pass with no worklist file |
| Interrupted large run restarted from dashboard one, re-pulling everything | Resume from `worklist.tsv` in the run directory; only pending dashboards get pulled again |
| Command block assumes a variable declared in an earlier block | Every block, including reference-file snippets, redeclares `RAW_DIR` and every other input it uses; blocks run correctly pasted into a fresh shell |
