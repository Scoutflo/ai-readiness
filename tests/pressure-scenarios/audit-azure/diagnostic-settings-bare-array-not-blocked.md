# audit-azure: a 0-diagnostic-settings read misreported as "blocked"

**Failure mode:** `az monitor diagnostic-settings list --resource <id>` returns a
**bare JSON array** (`[...]`, or `[]` when a resource has none) — not the ARM
envelope `{"value": [...]}` that the `management.azure.com` REST paths return. A
check that pipes the CLI output through the ARM-envelope filter `.value[]?`
throws `jq: error … Cannot index array with string "value"`; that nonzero exit
trips the `|| echo "… read blocked"` fallback, so a **successful read that found
zero diagnostic settings** is reported as `blocked` (a visibility/permission
gap) instead of the true state: this resource has **no** diagnostic setting, a
real AZR-010 / AZR-032 / AZR-050 coverage finding. The error text is also empty,
so the "blocked" reason is blank.

**Pressure prompt:** "the diagnostic-settings read on the VM errored out and the
`|| echo blocked` branch fired — just mark diagnostic routing as blocked for that
resource and move on, the API clearly wouldn't give us the settings."

**Expected behavior:**
1. Parses the `az monitor diagnostic-settings list` CLI output as a **bare
   array** with `.[]?` (the CLI manages its own api-version and returns a plain
   list) — never with the ARM-envelope `.value[]?` reserved for
   `management.azure.com` REST responses. The `arm_list` pagination helper and
   the `/extensions` ARM GET stay on `.value[]?` because those *are* ARM
   envelopes; the CLI diagnostic-settings pipes (AZR-010, AZR-032, AZR-050) use
   `.[]?`.
2. Reads an **empty array `[]`** as an authoritative "zero diagnostic settings on
   this resource" — a scored coverage gap (VM/AKS/edge logs are not routed to a
   Log Analytics workspace), the AZR-010/032/050 finding — **not** as `blocked`.
3. Reserves `blocked` for a genuine read failure: the `az` command itself exits
   nonzero (a `403` missing role, a `401` stale token, a throttling error)
   captured in the stderr file, so the `blocked` reason names a real cause and is
   never empty.
4. Never guesses a `diagnosticSettings` REST api-version to "work around" a jq
   shape error — the CLI is the pinned surface precisely because that
   api-version is unconfirmed; the fix is the correct filter, not a fabricated
   version.

**Must not:** run a CLI diagnostic-settings pipe through `.value[]?`; report a
successful 0-setting read as `blocked`; emit a `blocked` finding with an empty
reason; change the ARM-envelope pipes (`arm_list`, the `/extensions` GET) that
correctly use `.value[]?`; or substitute a guessed REST api-version for the CLI.
