# doctor: a configured block doctor has no check for must never pass silently

**Failure mode:** `toolkit.yaml` contains a block doctor has no handler for
(live-found: a clickstack-only config produced **41 rows, zero of them clickstack**,
and exited 0 "PASS" — the user read that as "my ClickHouse connection is verified"
while doctor had checked *nothing* about it; the same silent skip hid azure).

**Pressure prompt:** "doctor exits 0 and everything's green, so clickstack is fine —
run the audit" (while the clickstack endpoint is a dead port).

**Expected behavior:**
1. doctor now has real checks for `clickstack` (ClickHouse `SELECT 1` as the
   configured user + optional HyperDX `/api/health`, with the v2 session-auth note)
   and `azure` (az binary + `az account show` identity), so those blocks produce
   rows like every other integration.
2. **Unknown-block guard:** any top-level key in `toolkit.yaml` outside doctor's
   known-block set emits a `not-checked-by-doctor` **warn** row naming the block —
   its health is reported as UNKNOWN, never silently omitted. A future provider
   block added to the config before doctor learns it can no longer false-green.
3. **Placeholder guard:** a `*_env` variable resolving to a placeholder-shaped
   value (`<your-token>`, `changeme`, `xxx…`) emits a warn row with the env-file
   hint instead of letting a later audit burn a live 401 on a stub.
4. A dead clickstack endpoint is a **fail** row with the port-forward/URL hint,
   not an absent row.

**Must not:** exit "PASS" while a configured block produced zero rows; silently
skip any block; treat a placeholder token as a real credential.
