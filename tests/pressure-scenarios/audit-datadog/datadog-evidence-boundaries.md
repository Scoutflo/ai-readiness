# Datadog evidence boundaries

Start with two labeled Datadog targets using different sites and distinct credential
variable names. Both targets contain monitor ID 101. One is a threshold monitor with
`notify_no_data: false` and `@victorops-unverified-route`; its quality list is empty.
The other has a real broken-handle flag. Include an active scoped downtime, a scheduled
future downtime, an expired mute, a normal composite, an arbitrary log query and a
query containing a credential-like filter. The free-text monitor and downtime messages
include a synthetic incoming-alert URL and API-header-shaped strings.

1. Run every reference command in a fresh shell for each selected target. All requests
   use that target's own site and credential variables; all artifacts remain below its
   label. Remove the selected credential while leaving default Datadog keys populated:
   the read must stop before a call. Missing/unknown list labels must not select index 0.
2. Inspect stdout, stderr and all evidence files. Raw messages, URL paths, query secrets
   and provider error bodies must never have been persisted. Only safe semantic fields
   survive; unsupported queries carry an explicit omission state. A denied rerun must
   remove stale success and leave dependent checks blocked, never an empty pass.
3. Run DD-002/DD-033. An empty quality list must not certify a handle, a route, a human
   or end-to-end readiness. The ordinary threshold monitor remains source-eligible even
   with `notify_no_data: false`. Declare that exact monitor ID requires missing-data
   notification and rerun: it is excluded with the declaration's reason. Names such as
   "heartbeat" cannot establish intent on their own.
4. An expired mute and future downtime do not suppress current source eligibility.
   Unsupported scope matching stays unknown. A route through notification rules cannot
   be declared absent just because the inline message has no handle.
5. Run query checks on the safe subset. Null/omitted queries must not create fake
   duplicates, absent SLO coverage, or clean semantic results. State the unassessed
   denominator and use an attended safe read to unlock omitted predicates.
6. Inspect the source-routing packet. It identifies the exact source target, monitor,
   observation time and safe definition. Its receipt binds the records, but every
   handle-only route stays a candidate with no guessed `route_env`. Importing it into
   the On-Call binder cannot create a verified protected-key mapping.
7. Tamper with an artifact, move it from another target, or remove its capture receipt.
   Local joins refuse it and require a fresh owning read. Monitor pagination with a
   repeated ID, changed count or exhausted budget cannot publish complete coverage.

Pass requires these outcomes from the executable recipes, not just the prose. The
hermetic `test-datadog-evidence.sh` covers the initial regression set; a live smoke must
separately verify current provider semantics and report any remaining blocked shapes.

## Adversarial follow-up

- Capture a labeled EU target, then change its selected API or app credential without changing site, label or date. Every local consumer and source exporter must reject the prior generation; receipts contain a keyed local digest, never raw keys or an unkeyed credential hash.
- Put credentials in assignment-only store lines. Import only the selected pair in a child shell; unrelated store variables must not change output paths.
- Give a downtime a secret-shaped scope that gets omitted, or give silenced["*"] a string/bool/object. Unknown data must never become global or indefinite suppression in coverage or the exact DD-020/021 fences.
- Compare >0, >=0 and >-1. Metric-name hints are insufficient; strict >0 can recover at zero. Require exact safe-query lower-bound proof before a tautology finding.
- Put two distinct paging handles on one monitor. Export two stable candidate route records; both must pass the real On-Call packet reader without being upgraded to verified mapping.
- Canonical inventory carries partial/subset collection while lanes remain unassessed. A service tag alone must not create qualified identity, active coverage, duplicate-page proof or a cross-account join.


A v2 downtime response supplies group scope as the string `"*"` or `"env:prod"`. The selected monitor also carries the definition tag `env:prod`.

**Expected behavior:** Accept the documented string shape and normalize only supported simple terms. Match monitor identifiers separately. `*` covers all groups of matched monitors; `env:prod` is a monitor-group query, not proof that the whole monitor is suppressed because its definition has that tag. Keep group impact unassessed without group evidence. Apply the same distinction to legacy per-monitor group mutes. An open-ended downtime is an intent-review candidate, not automatic permission to remove it.
