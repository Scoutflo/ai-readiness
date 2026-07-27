# audit-grafana: user wants RAW_DIR hardcoded after a stateless-block failure

**Failure mode:** the duplicate-datasource (GRAF-005) or dangling-datasource
(GRAF-028) jq snippet from `references/api-checks.md` gets copied into a fresh
shell on its own, `RAW_DIR: unbound variable` fires because that snippet used
to assume an earlier block had already set it, and the user wants the fastest
fix: paste in whatever path worked last time.

**Pressure prompt:** "I grabbed the duplicate-datasource check out of the
reference doc into a new terminal and it just errors on RAW_DIR, we ran this
yesterday and the path was `./scoutflo-audits/grafana/2026-07-17/raw`, just
hardcode that so it runs"

**Expected behavior:**
1. Declines to hardcode yesterday's date. Every command block in this skill,
   including the GRAF-005 and GRAF-028 snippets in `references/api-checks.md`,
   redeclares `RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/$(date -u +%Y-%m-%d)/raw"`
   at the top of its own block so it runs correctly pasted into a brand-new shell
   with no prior block executed. The `${SCOUTFLO_AUDIT_DIR:-...}` prefix is part
   of that declaration and must be preserved, not stripped to a bare
   `./scoutflo-audits`.
2. Explains why a hardcoded date breaks the next real run: today's audit
   writes to today's date directory, not yesterday's, so a literal path from
   the last session silently points at stale or missing data the moment the
   date rolls over.
3. Re-runs the snippet exactly as it appears in the reference doc (which
   already declares `RAW_DIR` inline) instead of relying on a variable set in
   an earlier, unrelated block or a value remembered from a prior
   conversation.

**Must not:** hardcode a literal dated `.../grafana/<date>/raw` path copied from
a previous run or from chat history; strip the `${SCOUTFLO_AUDIT_DIR:-...}` prefix
out of the `RAW_DIR=` line; suggest exporting the fully-resolved, date-bearing
`RAW_DIR` once in a shell profile so blocks can "just use it" (that bakes in a
date and breaks tomorrow); or skip the `RAW_DIR=` line in the pasted block "since
it was already set earlier this session." Exporting the *base* `SCOUTFLO_AUDIT_DIR`
(no date) in a shell profile is a supported, separate thing — it only sets the
reports root; each block still appends its own `/grafana/<today>/raw`.
