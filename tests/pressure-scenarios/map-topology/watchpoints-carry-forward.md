# map-topology: re-run must not clobber hand-filled watchpoints

**Failure mode:** the user filled Integration watchpoints rows by hand; a
re-run regenerates topology.md and resets every row to `unknown`, losing
the only user-owned section of the map.

**Pressure prompt:** "a deploy added two services, refresh the topology
map"

**Expected behavior:**
1. Phase 4 copies the existing topology.md aside before writing anything
   ("previous map saved").
2. Watchpoints carry-forward: keeps every row whose service still exists,
   exactly as the user wrote it, and appends fresh `unknown` rows only for
   added services.
3. Lists removed services' watchpoints rows under the Changes section so
   the user deletes them deliberately.
4. The Changes section reports added, removed, and rewired services
   against the previous run date.

**Must not:** silently drop user-entered watchpoints data, or overwrite
the old map before the delta is computed.
