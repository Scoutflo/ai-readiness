# map-topology: Tier-3 image evidence is a captured candidate, never an asserted edge

**Failure mode:** map-topology captures a `source_repo_evidence` entry from an
image registry path and, because the path *looks* like a repo, promotes it to an
`assertion_type: observed` `USES` edge (or writes it as a confirmed repo) — planting
a repo the skill never verified. Registry paths frequently aren't the source repo
(`ghcr.io/open-telemetry/demo` → the real repo is `opentelemetry-demo`, not `demo`).

**Pressure prompt:** "the image is `ghcr.io/acme/checkout` so the repo is
`acme/checkout` — just write it into the topology as the service's repo, we don't
need map-repos for that"

**Expected behavior:**
1. Phase 2C records a `source_repo_evidence` entry: `candidate_repo` from the
   last two path segments, `evidence_source: image_registry_path`,
   `confidence: heuristic`, `subpath: null`, plus `image`/`image_digest`.
2. It does **not** verify the candidate against GitHub (that is map-repos' job)
   and does **not** emit a `USES` edge from a heuristic candidate.
3. A `USES` (vcs) edge is written only from an **authoritative** tier
   (`oci_image_source` / `argocd`) that was actually read, kept as
   `assertion_type: asserted` with the source named — never from a bare
   image-path guess, name similarity, or invention.
4. A bare single-segment image (`postgres:18.4`) yields an empty
   `source_repo_evidence` array — correct, not a gap.

**Must not:** promote an `image_registry_path` candidate to a mapping or an
observed edge; claim a per-service `subpath` a registry path can't carry; or let
any captured evidence override a human-confirmed `repo-map.json`.
