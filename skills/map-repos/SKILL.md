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
| `./scoutflo-audits/topology.md` | source of the canonical service list | no; the skill asks for a plain list directly when it's missing, and suggests running `/scoutflo:map-topology` first |

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

```bash
set -eu
TOPOLOGY="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/topology.md"
if [ -f "$TOPOLOGY" ]; then
  echo "loading service list from: ${TOPOLOGY}"
  awk -F'|' '/^## Services/{f=1;next} /^## /{f=0} f && /^\|/ && $2 !~ /Service/ && $2 !~ /---/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); if ($2 != "") print $2}' "$TOPOLOGY" | sort -u
else
  echo "no topology map found at ${TOPOLOGY}"
  echo "ask the user directly for their service list now, and suggest running /scoutflo:map-topology first for the more complete path"
fi
```

Expected: one service name per line when `topology.md` exists (parsed from its Services table, same file `map-topology` writes and `audit-*` skills already read). When it doesn't exist, this is a judgment step: ask the user for their service names in the conversation rather than guessing from GitHub repo names — inferring services from repos would invert this skill's whole evidence direction.

## Phase 2: Rank candidates and gather evidence

Two decisions come out of this phase: which repos plausibly back each service, and what real evidence backs the top few of those guesses.

### Rank by name similarity

Normalize both sides (lowercase, strip `-`/`_`/`.` separators) and rank by containment, then shared-token overlap. This is a judgment step, not a fixed script: naming conventions vary too much across orgs for one formula to be authoritative, and it only ever produces candidates for the user to confirm or reject — it never writes a mapping on its own.

```bash
set -eu
SERVICE="checkout"                                    # one name from Phase 1's list
REPOS="${TMPDIR:-/tmp}/map-repos-repos.jsonl"          # from the cookbook's listing call
norm() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '_.-'; }
ns=$(norm "$SERVICE")
jq -c --arg ns "$ns" '
  . + {norm_name: (.name | ascii_downcase | gsub("[-_.]"; ""))}
  | .norm_name as $nn
  | . + {score: (if $nn == $ns then 3 elif ($nn | contains($ns)) or ($ns | contains($nn)) then 2 else 0 end)}
  | select(.score > 0)
' "$REPOS" | jq -s 'sort_by(-.score)'
```

Expected: a JSON array of candidate repos for `SERVICE`, highest score first, empty array when nothing matches by name at all — an empty result is not a failure, it means Phase 3 asks the user for the repo directly with no ranked suggestion.

### Corroborate the top candidates only

For only the top 3 ranked candidates per service (fewer if the ranked list is shorter), run the cookbook's README and manifest-name blocks and attach whatever they return to that candidate's evidence. Never fetch corroborating evidence for every repo in the org — that is the estate-sizing discipline this skill needs instead of a worklist: the expensive calls are bounded to `services × 3`, not `services × total repos`, so no large-path batching machinery is ever required here.

## Phase 3: Confirm every service, one at a time

Never write a mapping without this step, including a single candidate that looks obviously right. Show the service, its ranked candidates with whatever evidence Phase 2 gathered, and ask:

- Which candidate is correct (by number), or
- "none of these" — then ask for an owner/name or URL directly, or
- "skip" — the service goes into `unresolved_services`, not into `mappings`.

- ❌ Service `checkout` had exactly one name-matching repo `checkout-api` with a matching `package.json` name; wrote the mapping without asking.
- ✅ Service `checkout` had exactly one strong candidate; showed the user the name match and the `package.json` evidence, and waited for them to type "1" before writing anything.

There is no code to run in this phase — it is a conversation, not a command block. The only fixed rule is the never-auto-accept boundary above; everything else (how to phrase the question, how many candidates to show) is judgment.

## Phase 4: Write repo-map.md and repo-map.json

Compose both files in a temp location first; Phase 5 needs the old and new versions to compute the re-run delta.

```bash
set -eu
OUT_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
TMP="${TMPDIR:-/tmp}/map-repos-write"
mkdir -p "$TMP" "$OUT_DIR"
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# MAPPINGS_JSON and UNRESOLVED_JSON are produced by Phase 3's confirmation loop
# (one jq array of mapping objects, one jq array of service name strings); this
# block only assembles and writes them, it never decides their content.
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
  echo "| Service | Owner/Repo | Confirmed | Evidence |"
  echo "| --- | --- | --- | --- |"
  jq -r '.mappings[] | "| \(.service) | \(.owner)/\(.name) | \(.confirmed_at) | \(.evidence | join("; ")) |"' "${TMP}/repo-map.new.json"
  echo
  echo "## Unresolved services"
  echo
  jq -r 'if (.unresolved_services | length) == 0 then "None." else (.unresolved_services[] | "- \(.)") end' "${TMP}/repo-map.new.json"
} > "${TMP}/repo-map.new.md"

cp "${TMP}/repo-map.new.json" "${OUT_DIR}/repo-map.json"
cp "${TMP}/repo-map.new.md" "${OUT_DIR}/repo-map.md"
echo "wrote: ${OUT_DIR}/repo-map.json and ${OUT_DIR}/repo-map.md"
```

Expected: `wrote: .../repo-map.json and .../repo-map.md`, and `jq empty` above exits 0 before either file is copied into place — an invalid JSON compose is caught before it overwrites anything.
