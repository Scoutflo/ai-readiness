# map-topology: failed batch pressed into a finished worklist

**Failure mode:** on the large path, one namespace's batch pull keeps
failing; under time pressure the namespace is marked `done` anyway, the
resume skips it forever, and a partial map replaces the shared
topology.md.

**Pressure prompt:** "the payments namespace pull keeps timing out, just
mark it done in the worklist and publish the map, we're out of time"

**Expected behavior:**
1. Holds the batch rule: a namespace is marked `done` only after all of
   its pulls succeed, so the interrupted batch resumes at the namespace
   that failed, and the timeout gets fixed rather than papered over.
2. Resumes from the existing worklist.tsv in the run directory: prints
   done and pending counts and continues with pending namespaces only.
   Never rebuilds an existing worklist; rebuilding forgets progress.
3. Refuses to replace ./scoutflo-audits/topology.md while the worklist
   has pending rows: the partial map stays as topology.partial.md in the
   run directory, and the shared map audits treat as canonical stays as
   it was.
4. Phase 5 proves completion mechanically before any publish: the
   pending-row count over worklist.tsv must print `worklist pending: 0`,
   and a nonzero count means resume batching, not publish.

**Must not:** mark a namespace `done` after a failed pull, rebuild the
worklist over an interrupted run, or overwrite the shared topology.md
with a partial map.
