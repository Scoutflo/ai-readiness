---
name: map-repos
description: Builds a read-only, human-confirmed map from your services to their GitHub repositories and writes repo-map.md plus a machine-readable repo-map.json keyed on each repo's immutable numeric id. Use when the user asks to map services to repos, find which repo backs a service, link code to services, or build a service-to-repository map. Never auto-accepts a match; every service is confirmed by the user. Do not use for cluster/traffic topology (use map-topology) or to score anything (use an audit-* skill).
---

# map-repos

Maps which GitHub repository backs each of your services and writes the result to `./scoutflo-audits/repo-map.md` and `./scoutflo-audits/repo-map.json`. Every GitHub call is read-only (`GET` only); the only writes are those two local files. No mapping is ever written without your explicit confirmation, even when a match looks obvious — a repo with a similar name is inference, not proof it's the right one.

Full GitHub API call recipes live in [references/github-queries.md](references/github-queries.md). This file holds the workflow; go to the cookbook for the exact `curl` and `jq` blocks each phase names. The export schema lives in [references/scoutflo-export.md](references/scoutflo-export.md).

## What repo-map.json is used for

`repo-map.json` is an independent artifact from `topology.md`/`topology-export.json` — this skill never writes those, and `map-topology` never writes `repo-map.json`. It exists so any downstream tool that needs a service-to-repository mapping (this toolkit or your own automation) has one place to read it, keyed on the repo's immutable numeric GitHub id rather than its owner/name (which changes on rename or transfer).

Refresh cadence (example, tune to your release rhythm):

- Re-run when you add or retire a service or a repository.
- Re-run after any repo rename, transfer, or archive that might affect a confirmed mapping.
- Re-run before you rely on the mapping for anything downstream.

Keep `./scoutflo-audits/` out of public version control. The map names your org, your repos, and your services.

## Prerequisites

| Requirement | Why | Required |
| --- | --- | --- |
| `curl` | every GitHub API call | yes |
| `jq` | JSON parsing | yes |
| `github.org` and `github.token_env` in `~/.scoutflo/toolkit.yaml` | names the org/user and token to read repos from | yes |
| `./scoutflo-audits/topology-export.json` (preferred) or `topology.md` | source of the canonical service list, with each service's namespace | no; the skill asks for a plain list directly when both are missing, and suggests running `/scoutflo:map-topology` first |

Credentials: a read-only GitHub personal access token (classic `repo` read scope on private repos, or fine-grained `Contents:Read` + `Metadata:Read`). This is the read-only tier; no elevated access, no write scopes, no `*_env` variable ever printed.

If `/scoutflo:doctor` is set up, run it first; it validates the same `github` config this skill depends on.

## Phase 0: Preflight and live-safety gate

Never map repos in the wrong org. Every command in this skill names its target explicitly; the ambient `gh` CLI config or any cached credential is never trusted.

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GITHUB_ORG="your-org"          # github.org
# github.token_env names the variable; the secret stays in the environment.

command -v curl >/dev/null || { echo "curl not installed"; exit 1; }
command -v jq >/dev/null    || { echo "jq not installed"; exit 1; }

# Presence check only. Never print, log, or echo the value.
[ -n "${GITHUB_TOKEN:-}" ] || { echo "GITHUB_TOKEN is not set; run /scoutflo:connect"; exit 1; }

echo "config org/user: ${GITHUB_ORG}"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Authorization: Bearer ${GITHUB_TOKEN}" "https://api.github.com/orgs/${GITHUB_ORG}")
if [ "$code" = "200" ]; then
  echo "resolved as: org"
elif [ "$code" = "404" ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Authorization: Bearer ${GITHUB_TOKEN}" "https://api.github.com/users/${GITHUB_ORG}")
  if [ "$code" = "200" ]; then
    echo "resolved as: user (org lookup 404'd)"
  fi
fi
echo "identity check: ${code}"
```

Expected: `identity check: 200`. A 401 means the token is wrong or expired; fix per `/scoutflo:connect` before continuing. A 404 on both the org and user path means `github.org` is misspelled or the token cannot see that account at all — stop and fix the config before scanning anything.

## Phase 1: Load the service list

Prefer the machine-readable `topology-export.json` (a versioned contract) over scraping the human `topology.md` table — a table-shape change silently corrupts a positional parse, while the JSON either parses or fails loudly. Fall back to the table only when the export is absent. Either way, keep the **namespace** with each service: two services with the same name in different namespaces are different services and must never collapse into one row.

```bash
set -eu
AUDIT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
EXPORT="${AUDIT}/topology-export.json"
TOPOLOGY="${AUDIT}/topology.md"
OUT="${TMPDIR:-/tmp}/map-repos-services.tsv"   # namespace<TAB>service, one per line

if [ -f "$EXPORT" ] && jq -e '.version == "scoutflo-topology-export/v1"' "$EXPORT" >/dev/null 2>&1; then
  echo "loading service list from: ${EXPORT}"
  jq -r '.services[] | [(.attributes.namespace // "unknown"), .name] | @tsv' "$EXPORT" | sort -u > "$OUT"
elif [ -f "$TOPOLOGY" ]; then
  echo "loading service list from: ${TOPOLOGY} (export not found; table fallback)"
  awk -F'|' '/^## Services/{f=1;next} /^## /{f=0} f && /^\|/ && $2 !~ /^[ \t]*Service[ \t]*$/ && $2 !~ /---/ {
    gsub(/^[ \t]+|[ \t]+$/,"",$2); gsub(/^[ \t]+|[ \t]+$/,"",$3);
    if ($2 != "") print ($3 != "" ? $3 : "unknown") "\t" $2 }' "$TOPOLOGY" | sort -u > "$OUT"
else
  echo "no topology map found at ${EXPORT} or ${TOPOLOGY}"
  echo "ask the user directly for their service list now, and suggest running /scoutflo:map-topology first for the more complete path"
fi
[ -s "$OUT" ] && { echo "services loaded: $(wc -l < "$OUT" | tr -d ' ')"; awk -F'\t' '{seen[$2]++} END{for (s in seen) if (seen[s]>1) print "duplicate name across namespaces: " s " (" seen[s] " namespaces) — keep both, qualified by namespace"}' "$OUT"; }
```

Expected: one `namespace<TAB>service` row per service, a total count, and an explicit callout for any service name that appears in more than one namespace (both rows are kept and confirmed separately in Phase 3; the mapping records each one's `namespace`).

**Scope before ranking (proportionality):** when the list is large (more than ~20 services, example threshold — tune to the estate), do not march into a per-service confirmation grind across the whole table. Show the namespace breakdown and ask the user which namespaces or services to map — application namespaces are usually wanted; third-party/infra services (an ingress controller, cert-manager, a Helm-installed Grafana/Loki/Prometheus) usually are not, because their "repo" is upstream open source, not the user's code. Services the user excludes here are simply out of scope for the run — they are not `unresolved_services`.

## Phase 2: Rank candidates and gather evidence

Two decisions come out of this phase: which repos plausibly back each service, and what real evidence backs the top few of those guesses. **Evidence comes first; a service name is not evidence.** Live data proves it — a service called `account-service` can run an image named `neutral-service` with nothing name-linking it to any repo. So verify captured evidence first, and fall back to name similarity only when no evidence resolves.

### Evidence-first: verify captured `source_repo_evidence`

When `map-topology` wrote `topology-export.json`, each workload may carry a `source_repo_evidence[]` array — tiered, typed candidates for its source repo (see [map-topology's export contract](../map-topology/references/scoutflo-export.md#source_repo_evidence--tiered-typed-servicerepo-evidence-optional-additive)). Read it per service (a service's evidence lives on the workload it is `DEPLOYED_AS`), then **verify each candidate live before trusting it** — a heuristic `image_registry_path` candidate often mirrors the repo but frequently doesn't.

```bash
set -eu
EXPORT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/topology-export.json"
SERVICE="account-service"                                   # one name from Phase 1
NS="storefront"                                             # its namespace (Phase 1 keeps it)
# Pull this service's evidence candidates, best tier first (authoritative before heuristic).
[ -f "$EXPORT" ] && jq -c --arg svc "$SERVICE" --arg ns "$NS" '
  # the workload this service is DEPLOYED_AS -> its source_repo_evidence
  (.relationships[] | select(.relation=="DEPLOYED_AS" and .from.name==$svc) | .to.name) as $wl
  | .resources[] | select(.name==$wl) | (.attributes.source_repo_evidence // [])
  | sort_by(if .confidence=="authoritative" then 0 else 1 end)
  | .[]' "$EXPORT" 2>/dev/null
```

For each candidate, run the cookbook's [resolve a repo by owner/name](references/github-queries.md#resolve-a-repo-by-owner-and-name) call on its `candidate_repo`:

- **Resolves (`200`)** → strong evidence. Present it as the top candidate, with an `evidence[]` row citing the real source, e.g. `"image_registry_path candidate open-telemetry/demo verified live → repo id 542887714"`. An **authoritative** tier (OCI/ArgoCD) that resolves outranks a **heuristic** (image-path) one; an ArgoCD candidate also carries a `subpath` for the monorepo case.
- **404 / no access** → drop that candidate to the next tier; a registry path that isn't a real repo simply falls through. Never present an unresolved candidate as evidence, and never assert it.

Evidence-verified candidates are still **candidates**, not mappings — Phase 3 confirmation is mandatory exactly as for name-ranked ones. What changes is the *quality* of what's proposed: a live-verified repo with a cited signal, not a name guess.

### Rank by name similarity (fallback when no evidence resolved)

When a service has no `source_repo_evidence`, or none of its candidates resolved live, fall back to name similarity. Normalize both sides (lowercase, strip `-`/`_`/`.` separators) and rank in three tiers — exact, containment, shared-token overlap — with a deterministic tie-break and a short-name guard. It only ever produces candidates for the user to confirm or reject; it never writes a mapping on its own.

```bash
set -eu
SERVICE="checkout"                                    # one name from Phase 1's list
REPOS="${TMPDIR:-/tmp}/map-repos-repos.jsonl"          # from the cookbook's listing call
norm() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '_.-'; }
ns=$(norm "$SERVICE")
# Short-name guard: containment on a very short normalized name (< 5 chars, e.g. "ad")
# floods the list with substring false positives; below the floor only the exact and
# token tiers may fire, never bare containment.
guard=5
jq -c --arg ns "$ns" --arg svc "$SERVICE" --argjson guard "$guard" '
  ($svc | ascii_downcase | split("[-_.]"; "") | map(select(length > 2))) as $stok
  | . + {norm_name: (.name | ascii_downcase | gsub("[-_.]"; ""))}
  | .norm_name as $nn
  | (.name | ascii_downcase | split("[-_.]"; "") | map(select(length > 2))) as $rtok
  | ([$stok[] | select(. as $t | $rtok | index($t))] | length) as $shared
  | . + {score:
      (if $nn == $ns then 3
       elif (($ns | length) >= $guard) and (($nn | contains($ns)) or ($ns | contains($nn))) then 2
       elif $shared > 0 then 1
       else 0 end)}
  | select(.score > 0)
' "$REPOS" | jq -s 'sort_by(-.score, (.norm_name | length), .name)'
```

Expected: a JSON array of candidates, highest tier first; within a tier, ties break deterministically toward the shorter (closer) name, then alphabetically — never by listing order. An empty array is not a failure: Phase 3 asks the user for the repo directly, and the monorepo probe below runs first. Show each candidate's `archived` flag whenever it is true — an archived repo can still be confirmed deliberately, but confirming one blind and then flagging it as a "contradiction" on the next re-run (Phase 5 treats archived as one) helps nobody.

Each candidate's `id` field here is a JSON number, straight from the listing call. When Phase 4 writes a confirmed mapping, stringify it as `repository_id` (e.g. `.id | tostring`) — the export schema and Phase 5's verification both require a string, never a number, so a confirmed candidate is never passed through as-is.

### Corroborate the top candidates only

For only the top 3 ranked candidates per service (fewer if the ranked list is shorter), run the cookbook's README and manifest-name blocks and attach whatever they return to that candidate's evidence. Never fetch corroborating evidence for every repo in the org — that is the estate-sizing discipline this skill needs instead of a worklist: the expensive calls are bounded to `services × 3`, not `services × total repos`, so no large-path batching machinery is ever required here.

### Monorepo probe: when ranking comes back empty for many services at once

Name-vs-name ranking silently assumes every service has its own repository. Estates that keep many services inside **one repository** (under `services/<name>/`, `apps/<name>/`, or `packages/<name>/`) produce the opposite signature: an empty or junk ranked list for *most* of the service list at once. Treat that signature — more than half the in-scope services with no exact/containment candidate — as a trigger, not a dead end:

1. Ask the user whether their services live together in one repository, and if they know it, take the owner/name directly (resolve it with the cookbook's [resolve a repo by owner/name](references/github-queries.md#resolve-a-repo-by-owner-and-name) call — this also covers a repo in a *different* org than `github.org`).
2. When they don't know, probe for it — bounded: take the repos whose normalized name shares a token with the *estate* (the org's own product/team words, or any repo a service's weak tier-1 hit pointed at), at most 5, and run the cookbook's [list a repo's top-level tree](references/github-queries.md#list-a-repos-top-level-tree) call on each. A repo whose tree has a `services/`, `apps/`, or `packages/` directory containing entries matching several in-scope service names is a monorepo candidate; count the matches and present it with that evidence ("`ai-sre-benchmark-fixtures` contains services/ entries matching 11 of your 12 unresolved services").
3. Confirmation stays per the never-auto-accept rule, but **batched**: present the monorepo candidate once, list every service whose name matched a subdirectory, and let the user confirm the whole set in one answer (plus per-service opt-outs), rather than asking the same question N times. Each confirmed service gets its own mapping row sharing the repo's `repository_id` with its own `path` (`services/<name>`), per the schema.

The probe costs at most 5 tree calls per run — inside the same estate-sizing discipline as corroboration (never `services × total repos`).

## Phase 3: Confirm every service

Never write a mapping without this step, including a single candidate that looks obviously right. Name each service by `namespace/service` when Phase 1 flagged a duplicate name — the user must know *which* `api-gateway` they are confirming. Show the ranked candidates with whatever evidence Phase 2 gathered (including an `archived` warning where set), and ask:

- Which candidate is correct (by number), or
- "none of these" — then take an owner/name or URL directly and resolve it to its immutable id with the cookbook's [resolve a repo by owner/name](references/github-queries.md#resolve-a-repo-by-owner-and-name) call (works for repos outside the configured `github.org` too — verify it resolves before writing anything), or
- "skip" — the service goes into `unresolved_services`, not into `mappings`.

- ❌ Service `checkout` had exactly one name-matching repo `checkout-api` with a matching `package.json` name; wrote the mapping without asking.
- ✅ Service `checkout` had exactly one strong candidate; showed the user the name match and the `package.json` evidence, and waited for them to type "1" before writing anything.

**Monorepo batch confirmation** (from the Phase 2 probe): one question for the whole set, not N repeats — show the monorepo candidate, its tree evidence, and the list of services whose names matched subdirectories; the user confirms the set (with per-service opt-outs) in one answer. Each confirmed service still becomes its own mapping row: shared `repository_id`, its own `path`. A batch answer is still an explicit answer — what never happens is a mapping written with *no* answer.

**Re-runs re-propose unresolved services too**, not just confirmed mappings: read the prior file's `unresolved_services` and ask once whether to retry them this run or keep them skipped — do not silently re-grind the same rejected candidates from scratch, and do not silently drop the list either.

There is no code to run in this phase — it is a conversation, not a command block. The only fixed rule is the never-auto-accept boundary above; everything else (how to phrase the question, how many candidates to show) is judgment.

## Phase 4: Write repo-map.md and repo-map.json

Before composing anything, back up any existing `repo-map.json` so the re-run delta below has the pre-overwrite version to compare against. Compose both files in a temp location next; Phase 5 needs the old and new versions to compute the re-run delta.

```bash
set -eu
OUT_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
TMP="${TMPDIR:-/tmp}/map-repos-write"
mkdir -p "$TMP" "$OUT_DIR"

# Back up any previously written repo-map.json before it gets overwritten below.
# On a first run there is nothing to back up, which is expected, not an error.
OUT="${OUT_DIR}/repo-map.json"
[ -f "$OUT" ] && cp "$OUT" "${TMP}/repo-map.prev.json" && echo "previous map saved" || echo "first run"

GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# MAPPINGS_JSON and UNRESOLVED_JSON are produced by Phase 3's confirmation loop
# (one jq array of mapping objects — each carrying namespace and, for a monorepo
# mapping, its path — and one jq array of service name strings); this block only
# assembles and writes them, it never decides their content.
#
# GUARD: the two literals below are PLACEHOLDERS. Running this block without
# substituting Phase 3's real arrays writes an empty map over a real one and
# Phase 5 would have nothing to catch — so Phase 5 now reconciles the written
# counts against Phase 1's in-scope service list and fails on a mismatch.
MAPPINGS_JSON='[]'        # replace with Phase 3's actual accumulated array
UNRESOLVED_JSON='[]'      # replace with Phase 3's actual accumulated array

jq -n --arg gen "$GENERATED_AT" --argjson mappings "$MAPPINGS_JSON" --argjson unresolved "$UNRESOLVED_JSON" \
  '{version: "scoutflo-repo-map/v1", generated_at: $gen, mappings: $mappings, unresolved_services: $unresolved}' \
  > "${TMP}/repo-map.new.json"

jq empty "${TMP}/repo-map.new.json"

{
  echo "# Service to Repository Map"
  echo
  echo "Generated (UTC): ${GENERATED_AT}"
  echo "Generated by: /scoutflo:map-repos"
  echo
  echo "## Mappings"
  echo
  echo "| Service | Owner/Repo | Path | Confirmed | Evidence |"
  echo "| --- | --- | --- | --- | --- |"
  jq -r '.mappings[] | "| \(if .namespace then .namespace + "/" else "" end)\(.service) | \(.owner)/\(.name) | \(.path // "-") | \(.confirmed_at) | \(.evidence | join("; ")) |"' "${TMP}/repo-map.new.json"
  echo
  echo "## Unresolved services"
  echo
  jq -r 'if (.unresolved_services | length) == 0 then "None." else (.unresolved_services[] | "- \(.)") end' "${TMP}/repo-map.new.json"
} > "${TMP}/repo-map.new.md"

cp "${TMP}/repo-map.new.json" "${OUT_DIR}/repo-map.json"
cp "${TMP}/repo-map.new.md" "${OUT_DIR}/repo-map.md"
echo "wrote: ${OUT_DIR}/repo-map.json and ${OUT_DIR}/repo-map.md"
```

Expected: either `previous map saved` or `first run` printed before anything is written, then `wrote: .../repo-map.json and .../repo-map.md`, and `jq empty` above exits 0 before either file is copied into place — an invalid JSON compose is caught before it overwrites anything, and by the time it does overwrite, the previous version (if any) is already safe in `${TMP}/repo-map.prev.json`.

## Phase 5: Verify and summarize

The write is unverified until re-read:

```bash
set -eu
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/repo-map.json"
SVC="${TMPDIR:-/tmp}/map-repos-services.tsv"   # Phase 1's in-scope list (after any scoping exclusions)
[ -f "$OUT" ] || { echo "repo-map.json was not written"; exit 1; }
jq -e '.version == "scoutflo-repo-map/v1"' "$OUT" >/dev/null || { echo "repo-map.json missing or invalid version"; exit 1; }
jq -r '"mapped: \(.mappings | length) services, unresolved: \(.unresolved_services | length)"' "$OUT"
jq -e '[.mappings[] | (.repository_id | type == "string")] | all' "$OUT" >/dev/null || { echo "a mapping is missing a string repository_id"; exit 1; }

# Reconcile against the input: every in-scope Phase 1 service must be accounted for,
# as a mapping or as unresolved. This is what catches Phase 4's placeholder '[]'
# literals being run unsubstituted — an "empty map that validates" is a bug, not a result.
if [ -s "$SVC" ]; then
  in_scope=$(wc -l < "$SVC" | tr -d ' ')
  accounted=$(jq -r '(.mappings | length) + (.unresolved_services | length)' "$OUT")
  echo "reconcile: in-scope=${in_scope} accounted=${accounted}"
  [ "$accounted" -eq "$in_scope" ] || { echo "RECONCILE FAIL: ${in_scope} services went into Phase 3 but only ${accounted} came out — Phase 4 was run with placeholder or partial arrays; do not report success"; exit 1; }
fi
```

Expected: `mapped: N services, unresolved: M`, both `jq -e` assertions exit 0, and `reconcile: in-scope=X accounted=X` with matching counts. If the repository_id assertion fails, a mapping was written with the wrong identity shape; if the reconcile fails, the write does not reflect the confirmation conversation — stop and fix Phase 4 before reporting success.

### Re-run delta: carry forward, never silently drop or rewrite

This is why Phase 4 backs up any pre-existing `repo-map.json` to `${TMP}/repo-map.prev.json` before it writes the new one: on a re-run, Phase 3 reads that prior file's `mappings` (before Phase 4 ever runs) and proposes every service already in it to the user as already-confirmed, kept exactly as-is (same `repository_id`, same `confirmed_at`) unless a fresh lookup contradicts it. This check needs the cookbook's [fetch a repo by id](references/github-queries.md#fetch-a-repo-by-its-immutable-id) call, not the org-wide listing — a rename or transfer changes what the listing shows for that id, but a repo transferred *out* of the configured org/user entirely would simply be absent from that listing, indistinguishable from deletion; the by-id call still finds it (or gets a real 404) either way.

A contradiction is: the repo behind a confirmed `repository_id` is now archived, or the by-id lookup returns a different `owner`/`name` than last recorded (a rename or transfer — expected and fine, update the label) or 404s entirely (the repo was deleted or the token lost access — flag it, do not drop the mapping silently). Name the exact contradiction to the user in Phase 3 rather than auto-resolving it; a customer-confirmed fact is never silently rewritten without them seeing why.

Monorepo mappings recheck cheaply: many rows share one `repository_id`, so **one** by-id lookup covers all of them — a contradiction on that repo applies to every service mapped into it (name them all), and a sibling row's different `path` is never a contradiction. `path` is user-asserted structure inside the repo; the by-id call cannot see it, so a moved subdirectory is only discovered when the user says so or a downstream consumer reports it.

Close by telling the user, in the terminal:

- Path written (`repo-map.md` and `repo-map.json`), org/user resolved.
- Services mapped, services unresolved, by name.
- Any re-run contradictions found and how they were resolved.
- The follow-up: re-run whenever a service or repo changes.

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| A single strong-looking name match written without asking | Never auto-accept, even one obvious candidate — always show evidence and wait for explicit confirmation (Phase 3) |
| `github.org` is actually a personal account, not an org | Fall back from `/orgs/{login}` to `/users/{login}` on a 404, in both Phase 0 and the listing cookbook, and say which path resolved |
| Corroborating evidence fetched for every repo in the org, not just top candidates | Bound README/manifest calls to the top 3 ranked candidates per service; never fetch evidence for the full repo list |
| A repo renamed or transferred between runs silently breaks a confirmed mapping | Key every mapping on `repository_id`, never on `owner`/`name`; a rename only updates the label, it never invalidates the mapping |
| A repo deleted or access lost between runs, and the mapping is dropped without telling the user | Flag a 404-on-recheck as a contradiction in Phase 5's re-run delta; never silently remove a previously confirmed mapping |
| No `topology.md` exists yet, so the skill guesses services from repo names | Ask the user directly for their service list; never invert the evidence direction by inferring services from GitHub |
| A secret token value ends up in `evidence[]` or the terminal | `evidence` entries are derived facts (name similarity strings, README excerpts, manifest names) never raw command output containing the `Authorization` header; presence-check `GITHUB_TOKEN`, never print it |
| A monorepo estate (all services in one repo) yields "unresolved" for everything and the run ends there | Treat mass-empty ranking as the monorepo signature: run the Phase 2 monorepo probe (bounded tree calls), batch-confirm the set, and record each service's `path` — never conclude "no repos found" from name-ranking alone |
| Two services with the same name in different namespaces collapse into one mapping | Phase 1 keeps `namespace<TAB>service` rows (no cross-namespace dedup); Phase 3 confirms each `namespace/service` separately; the mapping records `namespace` |
| Phase 4 run with its placeholder `[]` literals overwrites a real map with an empty one that still validates | Phase 5's reconcile assertion compares mappings+unresolved against Phase 1's in-scope count and fails on mismatch — an empty map that validates is a bug, not a result |
| An archived repo confirmed blind, then flagged as a "contradiction" on the very next re-run | Surface the listing's `archived` flag on every candidate at confirmation time; archived can be chosen, but only knowingly |
| A very short service name (`ad`) floods the candidate list with substring false positives in arbitrary order | The short-name guard disables bare containment below 5 normalized chars; the token tier + deterministic tie-break (score, then name length, then name) keep what remains stable and honest |
| A user-supplied repo (the "none of these" path) written without resolving or verifying it | Resolve owner/name to the immutable numeric id with the cookbook's resolve call — which must return 200 — before any mapping is written; works for cross-org repos too |
| A `source_repo_evidence` candidate (esp. heuristic `image_registry_path`) presented as fact without live verification | Verify every captured candidate live via the resolve call first; a 404 drops it to the next tier or name fallback — a registry path (`.../open-telemetry/demo`) often is NOT the source repo (`opentelemetry-demo`). Never assert an unverified candidate; confirmation stays mandatory regardless of tier |
