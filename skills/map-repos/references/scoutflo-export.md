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
- `namespace` (optional) records the Kubernetes namespace the service came from in `topology.md`. Set it whenever a service name is not unique across namespaces (for example `api-gateway` existing in both `storefront` and `benchmark-workloads`) so the two do not collapse into one mapping; omit it or set null when the bare name is already unique.
- `path` (optional) is the per-service subdirectory inside a monorepo, for example `services/account-service`. Omit it or set null for a whole-repo mapping. Several services mapped into one monorepo share the same `repository_id`/`owner`/`name` and differ only by `path`; the Phase 5 re-run recheck still keys on `repository_id`, so a monorepo mapping is a contradiction only when that repo is archived/deleted/renamed, never because a sibling service's `path` differs. Both fields are additive and optional — a `v1` reader that ignores them still parses the file.
