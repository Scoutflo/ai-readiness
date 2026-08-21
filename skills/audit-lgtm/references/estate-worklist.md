# audit-lgtm: Large-Path Worklist, Resume, and Locking

Runnable commands for the large path named in [SKILL.md's Estate sizing](../SKILL.md#estate-sizing) and worked through in [Large-path worklist: services in batches](../SKILL.md#large-path-worklist-services-in-batches). Every block here is stateless and redeclares its own inputs, per the stateless-command-block rule; nothing here depends on a prior block having run in the same shell.

## 1. Find a resumable run, or start a new one

Scan for an interrupted run before minting a new `RUN_ID`. Never start fresh when a worklist with pending rows already exists; that throws away completed batches.

```bash
set -eu
AUDIT_ROOT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm"

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

## 2. Mint the run ID

Only after step 1 finds nothing resumable. The run ID is a UTC second-precision timestamp, generated once and reused by every later block in the same run; it is what keeps the run directory stable across a midnight UTC rollover mid-batch.

```bash
set -eu
AUDIT_ROOT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"   # first-seen timestamp of this run; stable for its lifetime
RUN_DIR="${AUDIT_ROOT}/runs/${RUN_ID}"
mkdir -p "${RUN_DIR}"
echo "${RUN_ID}" > "${RUN_DIR}/run-id"
echo "run: ${RUN_ID}"
```

## 3. Build or resume the worklist

One row per critical service (from `./scoutflo-audits/topology.md`) and one row per Grafana dashboard, tab-separated: `kind`, `name`, `status` (`pending` or `done`). Service rows are keyed `namespace/service` (the table's Namespace and Service columns), never the bare name — the same service name in two namespaces is two rows with independent coverage. Never rebuild a worklist that already exists in the resumed run directory; that forgets progress.

```bash
set -eu
RUN_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm/runs/20260717T140500Z"   # example; the resolved run directory from step 1 or 2
WORKLIST="${RUN_DIR}/worklist.tsv"
GRAFANA_URL="https://grafana.example.com"   # grafana.url
GRAFANA_TOKEN="${GRAFANA_TOKEN:-}"          # grafana.token_env, set only if the grafana block is configured

if [ -f "${WORKLIST}" ]; then
  done=$(awk -F'\t' '$3 == "done"' "${WORKLIST}" | wc -l | tr -d ' ')
  pending=$(awk -F'\t' '$3 == "pending"' "${WORKLIST}" | wc -l | tr -d ' ')
  echo "resuming existing worklist: done=${done} pending=${pending}"
else
  : > "${WORKLIST}"
  if [ -f "${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/topology.md" ]; then
    # Enqueue ONLY the rows of the `## Services` table (deduped). A bare `grep '^| ... |'`
    # also matches the metadata / Traffic-map / Entry-points / Integration-watchpoints
    # tables and header/`---` rows, so it would enqueue phantom "services" named `---`,
    # `Mesh`, `Service`, and double-enqueue every real service (each also appears in the
    # Integration-watchpoints table) — corrupting per-service coverage on the large path.
    # Rows are keyed namespace/service (columns 3 and 2): a bare-name key would collapse
    # two same-named services in different namespaces into one row.
    awk '/^## Services$/{f=1;next} /^## /{f=0} f' ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/topology.md \
      | grep -E '^\| ' \
      | grep -vE '^\| *Service *\||^\| *-{2,}' \
      | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $3); if($2!="") print ($3!="" ? $3"/"$2 : $2)}' \
      | sort -u \
      | while read -r svc; do printf 'service\t%s\tpending\n' "${svc}" >> "${WORKLIST}"; done
  fi
  if [ -n "${GRAFANA_TOKEN}" ]; then
    curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
      "${GRAFANA_URL}/api/search?type=dash-db&limit=500" \
      | jq -r '.[].uid' \
      | while read -r uid; do printf 'dashboard\t%s\tpending\n' "${uid}" >> "${WORKLIST}"; done
  fi
  total=$(wc -l < "${WORKLIST}" | tr -d ' ')
  echo "built worklist: ${total} rows, all pending"
fi
```

## 4. Lock the worklist before claiming a batch

Two invocations of this skill running at once would otherwise race on the same worklist file and double-claim rows. A lock older than `LOCK_STALE_MINUTES` is treated as abandoned; processes die, laptops sleep, sessions get killed, so reclaiming a stale lock is a normal path, not an error.

```bash
set -eu
RUN_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm/runs/20260717T140500Z"   # example; the resolved run directory
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

## 5. Claim a batch, run its checks, mark done, release the lock

Claim happens while the lock (step 4) is held; release happens right after the batch's rows are marked, so another process can claim the next batch. Run Phase 6 (coverage), Phase 9 (dashboard checks), and section 12 of [backend-checks.md](backend-checks.md) against only the claimed rows, using the commands already declared there. A row is marked `done` only after its checks complete without error, so a batch that fails partway resumes at the row that failed rather than replaying the whole batch.

```bash
set -eu
RUN_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm/runs/20260717T140500Z"   # example; the resolved run directory
WORKLIST="${RUN_DIR}/worklist.tsv"
LOCK="${RUN_DIR}/worklist.lock"
BATCH_SIZE="15"   # example, tune it; matches the value declared in Estate sizing

BATCH_FILE="${RUN_DIR}/batch-$(date -u +%s).tsv"
awk -F'\t' '$3 == "pending"' "${WORKLIST}" | head -n "${BATCH_SIZE}" > "${BATCH_FILE}"
count=$(wc -l < "${BATCH_FILE}" | tr -d ' ')
echo "claimed batch: ${count} rows -> ${BATCH_FILE}"

# ... for each row in "${BATCH_FILE}", run the Phase 6 / Phase 9 / section 12
# checks for that service or dashboard, appending results to the run's
# incremental findings file. A service row's name is `namespace/service`; split it
# for the section 12 variables with SERVICE_NS="${name%%/*}" SERVICE="${name#*/}".
# Only after every row's checks succeed:

while IFS=$'\t' read -r kind name _status; do
  # mark this row done in place; a real run does this after its checks pass
  awk -F'\t' -v k="${kind}" -v n="${name}" 'BEGIN{OFS="\t"} $1==k && $2==n {$3="done"} {print}' \
    "${WORKLIST}" > "${WORKLIST}.tmp" && mv "${WORKLIST}.tmp" "${WORKLIST}"
done < "${BATCH_FILE}"

rm -f "${LOCK}"   # release once this batch (not the whole run) completes
done=$(awk -F'\t' '$3 == "done"' "${WORKLIST}" | wc -l | tr -d ' ')
pending=$(awk -F'\t' '$3 == "pending"' "${WORKLIST}" | wc -l | tr -d ' ')
echo "batch marked done: done=${done} pending=${pending}"
```

Expected: `pending` drops by the batch size (or less, on the final partial batch) after each pass through steps 4 and 5. Repeat steps 4 and 5 until `pending` reaches 0, then proceed to Phase 10 to score, write, and brief from the full accumulated findings.

## Rules

- The lock covers one batch claim, not the whole run: acquire it right before reading pending rows, release it right after marking them done.
- A lock file holds exactly two tab-separated fields: the PID that holds it, and its UTC epoch start timestamp. Nothing else.
- `findings.json` and `report.md` are written only once `pending` is 0. A run stopped mid-batch leaves its worklist and partial findings in the run directory as the resume point; it never overwrites the previous complete report.
- Delete the run directory after `findings.json` and `report.md` are written; it is working state, not a report. Deleting it early forces a fresh start on the next invocation.
