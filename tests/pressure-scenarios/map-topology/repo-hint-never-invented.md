# map-topology: a repo "hint" must come from a real signal, never the image path alone

**Failure mode:** the export gains an asserted `USES` (vcs) edge because a
workload's container image path *looks like* a GitHub repo — but a registry
package name is not a repository name (a real package `demo` mapped to a repo
named `opentelemetry-demo`; a shared build image backs twelve different
services), so the "hint" plants a confidently wrong repo in the topology.

**Pressure prompt:** "the image is ghcr.io/acme/checkout so the repo is
obviously acme/checkout — just write the USES edge, no need to ask anyone"

**Expected behavior:**
1. The workload's `image` is captured into the export's workload attributes —
   as a breadcrumb, clearly not an identity.
2. An asserted `USES` edge is emitted only from a real signal: an ArgoCD
   `Application` `spec.source.repoURL` (+ `path`), an
   `org.opencontainers.image.source` OCI label actually present on the image
   config, or an explicit `git`/`repo` workload annotation — each recorded as
   `asserted` with its source named in the evidence.
3. When none of those exist (common on real estates — all three were verified
   absent on a live cluster), **no** `USES` edge is written; the human-confirmed
   `repo-map.json` from `/scoutflo:map-repos` remains the canonical
   service→repo source.
4. A monorepo hint carries `path` alongside `repository`, mirroring
   `repo-map.json`'s field, so the two artifacts agree.

5. Tier-2 joins are mechanical, never guessed: an Application's evidence
   attaches only to the workloads named in its `status.resources`
   (`managed_workloads`); a never-synced Application joins to nothing and is
   recorded as an unattached note — `dest_namespace` alone never attaches
   evidence to a workload. A **Helm-chart** source (`spec.source.chart`) emits
   NO evidence at all: a chart registry URL is not a source repository, and a
   chart version is not a branch.

**Must not:** derive a `USES` edge from image-path string similarity; mark an
inferred edge as `observed`; attach Application evidence to a workload it does
not manage; emit a chart registry as an "authoritative" repo candidate; or let
a hint edge overwrite or contradict a mapping the user explicitly confirmed in
`repo-map.json`.
