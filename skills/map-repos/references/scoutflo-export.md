# repo-map.json schema

`"version": "scoutflo-repo-map/v1"`. One object with four top-level keys: `version`, `generated_at`, `mappings`, and `unresolved_services`.

```json
{
  "version": "scoutflo-repo-map/v1",
  "generated_at": "2026-08-19T00:00:00Z",
  "mappings": [
    {
      "service": "checkout",
      "namespace": "shop",
      "repository_id": "812345678",
      "owner": "your-org",
      "name": "checkout-api",
      "path": null,
      "evidence": [
        "name similarity: checkout ~ checkout-api",
        "package.json name: checkout-api"
      ],
      "confirmed_at": "2026-08-19T00:00:00Z"
    }
  ],
  "unresolved_services": ["billing"]
}
```

### `env_branch_convention` (optional, top-level)

One consolidated answer to "which branch deploys to which environment," captured **once** at global/team level by Phase 3's single branch question and propagated to every mapping — never asked per service, and branches are never enumerated (most are stale/temp noise):

```json
"env_branch_convention": { "prod": "main", "staging": "release/dev" }
```

A per-mapping `env_branch_convention` override is allowed for the rare repo that deviates; omit the field entirely when the user skips the question. All of this is additive — the schema stays `scoutflo-repo-map/v1` and existing readers parse existing files unchanged.

A **monorepo** is expressed as several mappings that share one `repository_id` and differ only by `path` — the per-service subdirectory inside that one repo (the topology-seed convention for the AI-SRE benchmark, where every service lives under `services/<name>/` of a single fixtures repo, is exactly this shape):

```json
{
  "service": "account-service",
  "namespace": "storefront",
  "repository_id": "1302787223",
  "owner": "Scoutflo-Testing",
  "name": "ai-sre-benchmark-fixtures",
  "path": "services/account-service",
  "evidence": ["monorepo subpath confirmed: services/account-service exists in ai-sre-benchmark-fixtures"],
  "confirmed_at": "2026-08-20T00:00:00Z"
}
```

Rules:

- `repository_id` is the repo's immutable numeric GitHub id as a string, captured from the listing call in the cookbook. It is the only identity field; a later rename or transfer changes `owner`/`name` but never this value, and this skill's re-run behavior (Phase 5) keys on it, never on the label.
- `evidence` is a plain-language list of what led to the match — never invent an entry that wasn't actually produced by Phase 2 (name similarity, README text, manifest name).
- A service with no confirmed repo (the user skipped it, or rejected every candidate) goes in `unresolved_services`, not into `mappings` with a null repo.
- `confirmed_at` is stamped once, at the moment the user confirms; a carried-forward mapping on re-run keeps its original `confirmed_at`, it does not reset.
- `default_branch` (optional) — the repo's default branch, captured free from the resolve/listing call that produced `repository_id` (GitHub returns it on the same response). Never asked, never guessed.
- `deployed_revision` (optional) — the exact live commit SHA, carried over from the verified `source_repo_evidence` entry that backed this mapping (ArgoCD synced revision or the OCI `org.opencontainers.image.revision` label). Only ever a real 40-hex SHA; a branch name never goes here. This is what lets RCA diff the right history at the right commit and name the culprit.
- `namespace` (optional) records the Kubernetes namespace the service came from in `topology.md`. Set it whenever a service name is not unique across namespaces (for example `api-gateway` existing in both `storefront` and `benchmark-workloads`) so the two do not collapse into one mapping; omit it or set null when the bare name is already unique.
- `path` (optional) is the per-service subdirectory inside a monorepo, for example `services/account-service`. Omit it or set null for a whole-repo mapping. Several services mapped into one monorepo share the same `repository_id`/`owner`/`name` and differ only by `path`; the Phase 5 re-run recheck still keys on `repository_id`, so a monorepo mapping is a contradiction only when that repo is archived/deleted/renamed, never because a sibling service's `path` differs. Both fields are additive and optional — a `v1` reader that ignores them still parses the file.
