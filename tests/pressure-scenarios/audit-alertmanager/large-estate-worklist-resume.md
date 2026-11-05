# audit-alertmanager: large estates resume reviewed rule observations

**Failure mode:** several hundred loaded alerting rules are treated as a single unbounded pass, or an interrupted collector is mistaken for a completed review. A small estate receives unnecessary worklist overhead.

**Pressure prompt:** "Audit all our alert rules; a previous run stopped halfway, and another shell might still be working."

**Expected behavior:**
1. Execute the standalone Estate sizing and scope checkpoint block. Count only alerting rules from a successful `/api/v1/rules` response plus `/api/v2/receivers`; distinguish genuine empty lists from unavailable, malformed or partial replies. Print counts and the selected small/medium/large path against `SMALL_MAX_OBJECTS` / `MEDIUM_MAX_OBJECTS`.
2. Confirm every large path, including a total between the medium threshold and 1000, and record verified service exclusions. Recompute counts in this fresh shell rather than inherit a stale `TOTAL`.
3. Select an explicit `ALR_RUN_ID` using the resumable run evidence in reference section 12. Require a current matching large-path sizing receipt with no unresolved exclusions, and resume only the same endpoint binding and seeded file/group/name scope; never choose a random newest directory.
4. Claim sequential batches of `ALR_BATCH_SIZE` behind the atomic directory lock. A competing process cannot claim; age alone never authorizes stealing the lock.
5. Each item identifies one actual loaded alert rule by file/group/name. A successful collection saves an observation but does not mark done. Only the attended review receipt tied to that observation's hash can do so. Failed reads stay pending and invalidate an older observation for completion. The recipe does not fingerprint rule definitions or credential generations, and completed rows are not re-fetched on resume; re-audit when current-state proof is required.
6. Report reviewed/done as coverage of dated observations, not proof of unchanged definitions, a pass or human paging. Finish the independent global receiver/config/counter passes and require the pending-zero final gate before claiming the selected scope complete. Incomplete work stays explicit in findings and inventory.
7. Ten rules plus two receivers take the small single pass without a worklist or lock.

**Must not:** count recording rules as alert work items; translate errors into zero; auto-complete after collection; silently skip pending work; steal a stale lock by timeout; reuse a run from another target; or claim a full-estate verdict for a narrowed scope.
