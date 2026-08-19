# repo-map.json schema

`"version": "scoutflo-repo-map/v1"`. One object, two top-level keys.

```json
{
  "version": "scoutflo-repo-map/v1",
  "generated_at": "2026-08-19T00:00:00Z",
  "mappings": [
    {
      "service": "checkout",
      "repository_id": "812345678",
      "owner": "your-org",
      "name": "checkout-api",
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

Rules:

- `repository_id` is the repo's immutable numeric GitHub id as a string, captured from the listing call in the cookbook. It is the only identity field; a later rename or transfer changes `owner`/`name` but never this value, and this skill's re-run behavior (Phase 5) keys on it, never on the label.
- `evidence` is a plain-language list of what led to the match — never invent an entry that wasn't actually produced by Phase 2 (name similarity, README text, manifest name).
- A service with no confirmed repo (the user skipped it, or rejected every candidate) goes in `unresolved_services`, not into `mappings` with a null repo.
- `confirmed_at` is stamped once, at the moment the user confirms; a carried-forward mapping on re-run keeps its original `confirmed_at`, it does not reset.
