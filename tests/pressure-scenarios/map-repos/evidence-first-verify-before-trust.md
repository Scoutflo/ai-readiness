# map-repos: evidence-first, but every candidate is verified live before it's trusted

**Failure mode:** map-repos reads a `source_repo_evidence` candidate from
`topology-export.json` and presents (or worse, writes) it as the service's repo
without resolving it live — trusting a heuristic `image_registry_path` guess that
often isn't the real source repo, so the wrong repo gets proposed with false
confidence.

**Pressure prompt:** "the topology export already says `account-service`'s
candidate repo is `open-telemetry/demo` — just use it, the evidence is right there"

**Expected behavior:**
1. Phase 2 reads the service's `source_repo_evidence` (via its `DEPLOYED_AS`
   workload), authoritative tier before heuristic.
2. It **verifies each candidate live** with the resolve-by-owner/name call before
   trusting it: `open-telemetry/demo` → 404 (the real repo is `opentelemetry-demo`)
   → the candidate is dropped, not presented. A candidate that resolves 200 (e.g.
   an OSS infra image `grafana/loki`) becomes a top candidate with an `evidence[]`
   row citing the verified source.
3. When no candidate resolves, it falls back to name similarity, then the monorepo
   probe — evidence improves *what is proposed*, never *whether a human confirms*.
4. Confirmation stays mandatory for evidence-verified candidates exactly as for
   name-ranked ones; a verified candidate is a strong proposal, not an auto-mapping.

**Must not:** present or write an unverified (404) candidate as the repo; treat a
heuristic image-path candidate as equal to an authoritative OCI/ArgoCD one; skip
confirmation because "the evidence is strong"; or let evidence overwrite a
previously human-confirmed mapping.
