# business-context-resolver: metadata becomes stale; audit skills refresh correctly

**Failure mode:** User runs resolver once and generates `computed_metadata.jsonl`. Later, infrastructure changes: new services deployed, old services deleted, team ownership changed. User re-runs resolver to refresh, but audit skills are still reading stale metadata from the previous run because they cached or persisted it incorrectly.

**Pressure prompt:** "I deployed a new payment service yesterday with team=payment tags. I re-ran the resolver and it shows up in the new metadata. But when I run audit-aws, it doesn't audit the new service. Did the resolver not pick it up?"

**Expected behavior:**
1. First resolver run: discovers N services, outputs `computed_metadata.jsonl`.
2. Infrastructure changes: add a service, delete another, change a team tag.
3. Second resolver run: `--force` flag causes re-discovery (or no cache at all). Generates fresh `computed_metadata.jsonl` with updated resource list.
4. All audit skills re-read `computed_metadata.jsonl` on each run (no caching of metadata in skill state).
5. Audit skills see the new service on the next run (because metadata is fresh).
6. No "refresh cache" step is required; resolver output is generated fresh each run.

**Must not:** cache metadata in memory or on disk between resolver runs, require audit skills to explicitly refresh or reload, leave stale entries in `computed_metadata.jsonl` from a prior run, or require the user to delete/clear any state before re-running.
