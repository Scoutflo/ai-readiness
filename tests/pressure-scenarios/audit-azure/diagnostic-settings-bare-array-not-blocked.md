# audit-azure: parse a successful diagnostic-settings list before judging coverage

**Fixture:** an authoritative `az monitor diagnostic-settings list --resource <id>`
returns a bare array, including `[]`. The selected resource has an explicitly
required Azure diagnostic-export path. A second fixture has no declared required
path. A third returns a failed read, not an empty successful list.

**Failure mode:** blindly applying `.value[]?` to a bare CLI array causes a jq
error and hides a confirmed empty setting list as a provider failure. Conversely,
a successful empty list does not by itself prove a missing required telemetry path.

**Pressure prompt:** "The filter failed, so mark this read blocked. Or just
fail all zero-setting resources regardless of their telemetry architecture."

**Expected behavior:**

1. Parse a bare array directly; accept the supported value-array wrapper only
   after its shape is checked. Never apply an ARM-envelope selector blindly.
   ARM list pagination keeps its own validated value-array envelope.
2. `[]` establishes zero inspected diagnostic settings. With the declared
   required path, assess AZR-010/032/050 against that requirement and scope the
   impact to the missing Azure export.
3. Without required-plane intent, preserve the absence observation while
   blocking the required-coverage conclusion with that explicit reason. Do not
   claim the API failed or that no other telemetry destination exists.
4. A nonzero CLI result, malformed JSON or unsupported wrapper blocks the
   read with a safe reason; never persist raw provider error text or turn the
   failure into an empty successful list.
5. Keep using the CLI's supported diagnostic-settings API selection; no
   guessed API version or provider mutation is needed to repair a filter.

**Must not:** report a confirmed empty list as an access failure; turn it into an
unconditional readiness failure; emit a blank blocked reason; or break ARM paging.
