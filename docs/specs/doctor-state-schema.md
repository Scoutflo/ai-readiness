# Doctor State Schema

**Internal Spec Only — Local Development**

Location: `~/.scoutflo/doctor-state.json`

---

## Schema (v1.0)

```json
{
  "version": "1.0",
  "last_full_check": "2026-07-30T14:30:00Z",
  "checks": [
    {
      "check_id": "aws-001",
      "check_name": "EC2 Instance Security Groups",
      "status": "passed",
      "last_run": "2026-07-30T14:30:00Z",
      "skip_until": "2026-08-06T14:30:00Z",
      "last_failed": null,
      "failure_count": 0,
      "auto_fixed": false,
      "fix_timestamp": null
    },
    {
      "check_id": "aws-002",
      "check_name": "RDS Backup Configuration",
      "status": "failed",
      "last_run": "2026-07-30T14:30:00Z",
      "skip_until": null,
      "last_failed": "2026-07-30T14:30:00Z",
      "failure_count": 3,
      "auto_fixed": false,
      "fix_timestamp": null
    },
    {
      "check_id": "k8s-001",
      "check_name": "Pod Security Policies",
      "status": "fixed",
      "last_run": "2026-07-30T09:00:00Z",
      "skip_until": "2026-08-06T09:00:00Z",
      "last_failed": "2026-07-28T09:00:00Z",
      "failure_count": 2,
      "auto_fixed": true,
      "fix_timestamp": "2026-07-30T11:15:00Z"
    }
  ],
  "metadata": {
    "doctor_version": "2.3.1",
    "audit_scope": ["critical-services", "production"],
    "environment": "production",
    "last_manual_reset": "2026-07-25T08:00:00Z"
  }
}
```

---

## Field Definitions

### Top Level

| Field | Type | Meaning |
|-------|------|---------|
| `version` | string | Schema version. Bump if structure changes. |
| `last_full_check` | ISO timestamp | When was the full doctor run last executed? |
| `checks` | array | Array of check results. |
| `metadata` | object | Context about the run. |

### Per Check

| Field | Type | Meaning |
|-------|------|---------|
| `check_id` | string | Unique ID per check (e.g., `aws-001`, `k8s-001`). Must match doctor's internal check registry. |
| `check_name` | string | Human-readable name (for logs, not displayed to user). |
| `status` | enum | One of: `passed`, `failed`, `fixed`, `skipped`, `error`. |
| `last_run` | ISO timestamp | When was this check last executed? |
| `skip_until` | ISO timestamp or null | If not null, skip this check until this time. Set to 7 days from now for passed checks. Set to null for failed checks. |
| `last_failed` | ISO timestamp or null | When did this check last fail? (null if never failed). |
| `failure_count` | integer | Total failures since inception. Resets on fix. |
| `auto_fixed` | boolean | Was this automatically fixed by doctor? |
| `fix_timestamp` | ISO timestamp or null | When was the fix applied? (null if not auto-fixed). |

### Metadata

| Field | Type | Meaning |
|-------|------|---------|
| `doctor_version` | string | Which doctor.sh version created this state file? |
| `audit_scope` | array | Services/regions that were in scope for this run (from topology.json). |
| `environment` | string | Environment context (staging, production, etc.). |
| `last_manual_reset` | ISO timestamp | When did user last reset state manually (--reset-all)? |

---

## State Machine

### Healthy Flow (Check Passes)

```
[first run] → status: passed
            → skip_until: now + 7 days
            → failure_count: 0

[during 7-day skip window]
            → doctor skips this check
            → state unchanged

[after 7 days]
            → doctor re-runs check
            → if passes: skip_until: now + 7 days
            → if fails: status: failed, skip_until: null
```

### Failing Check (Manual Fix)

```
[run 1] → status: failed
        → failure_count: 1
        → skip_until: null

[user manually fixes outside doctor]

[run 2] → doctor re-runs check
        → if passes: status: fixed
        → auto_fixed: true
        → fix_timestamp: now
        → skip_until: now + 14 days (longer window after fix)
        → failure_count: 0 (reset)
```

### Failing Check (Auto-Fix)

```
[run 1] → status: failed
        → failure_count: 1

[run 2] → doctor runs auto-fix
        → status: fixed
        → auto_fixed: true
        → fix_timestamp: now
        → skip_until: now + 14 days
        → failure_count: 0

[run 3] → doctor re-checks fixed item
        → if passes: status: passed
        → skip_until: now + 7 days
```

### Error State

```
[check encounters timeout/API error]
        → status: error
        → skip_until: null
        → doctor logs the error
        → state does NOT update passed/failed
        → next run retries the check
```

---

## Implementation Logic

### On Doctor Startup

```bash
if doctor-state.json does not exist:
    create empty state (version 1.0, empty checks array)

load state from file

for each check in doctor's check registry:
    if check_id not in state.checks:
        add check to state with status: skipped (not run yet)
```

### Before Running Each Check

```bash
if skip_until exists and is in future:
    SKIP this check
    log: "Skipping aws-001 until 2026-08-06 (passed)"
    return without running
else:
    RUN the check
```

### After Each Check Completes

```bash
if check PASSED:
    update status: passed
    clear skip_until if it was a failure recovery
    set skip_until: now + 7 days
    clear last_failed
    
if check FAILED:
    update status: failed
    increment failure_count
    set last_failed: now
    clear skip_until (will rerun next time)
    
if check ERROR:
    update status: error
    clear skip_until (will retry next time)
    do NOT update failure_count
    log: "Check aws-001 errored: timeout"
    
update last_run: now
```

### Auto-Detect Fix

```bash
if previous state: failed
   current check: passes
   then:
    status: fixed
    auto_fixed: true
    fix_timestamp: now
    failure_count: 0 (reset)
    skip_until: now + 14 days
    
    log: "Check aws-001 was manually fixed. Detected at 14:30."
```

### On Explicit Reset

```bash
doctor --reset-all:
    delete ~/.scoutflo/doctor-state.json
    next run starts fresh
    
doctor --reset-check aws-001:
    find check_id: aws-001 in state
    set status: skipped
    clear skip_until, failure_count, last_failed
    
    next run will re-run that check
```

---

## TTL & Cleanup

### State File Retention

- Keep state file indefinitely (no deletion)
- Prune check history older than 90 days (optional, for storage)
- If state file > 10MB, archive old entries and compact

### Auto-Prune Logic

```bash
if state file size > 10MB:
    archive checks with last_run > 90 days ago
    write to: ~/.scoutflo/doctor-state.archive.json
    remove from active state
```

---

## Backward Compat

### If doctor-state.json Doesn't Exist

Doctor should:
1. Not crash
2. Log: "No prior state found. Running full check suite."
3. Create fresh state file after run
4. Treat as "first run" (no skipping)

### If State File Is Corrupted

Doctor should:
1. Catch JSON parse error
2. Log: "doctor-state.json corrupted. Backing up to doctor-state.json.bak"
3. Create fresh state file
4. Continue (don't crash)

### Version Upgrade (1.0 → 1.1)

If schema changes:
1. Read old version
2. Migrate to new schema
3. Log migration
4. Update `version: 1.1`

---

## Testing This

### Unit Tests

```bash
test_doctor_state_creation:
  - Call doctor first run
  - Assert ~/.scoutflo/doctor-state.json exists
  - Assert version: 1.0
  - Assert checks array populated

test_skip_logic:
  - Run doctor, mark aws-001 as passed
  - Assert skip_until: now + 7 days
  - Run doctor again within 7 days
  - Assert aws-001 check was SKIPPED (not re-run)

test_auto_fix_detection:
  - Mark aws-001 as failed in state file
  - Manually fix the issue outside doctor
  - Run doctor again
  - Assert status: fixed
  - Assert auto_fixed: true
  - Assert failure_count: 0 (reset)

test_state_corruption:
  - Corrupt doctor-state.json (invalid JSON)
  - Run doctor
  - Assert doctor doesn't crash
  - Assert backup file created
  - Assert fresh state file created
```

---

**This is used internally only. Not shipped to customers.**

