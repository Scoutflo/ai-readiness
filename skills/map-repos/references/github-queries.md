# GitHub query cookbook

Exact `curl`/`jq` blocks for `map-repos`. Every call is a `GET`; nothing here ever mutates GitHub.

## List repos in the org or user account

Paginates until a page returns fewer than 100 results. Falls back from the org path to the user path on a 404, exactly like Phase 0's identity check.

```bash
set -eu
GITHUB_ORG="your-org"          # github.org
GITHUB_TOKEN_PRESENT="${GITHUB_TOKEN:+set}"
[ -n "${GITHUB_TOKEN_PRESENT:-}" ] || { echo "GITHUB_TOKEN is not set; run /scoutflo:connect"; exit 1; }
OUT="${TMPDIR:-/tmp}/map-repos-repos.jsonl"
: > "$OUT"

BASE="https://api.github.com/orgs/${GITHUB_ORG}/repos"
probe=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Authorization: Bearer ${GITHUB_TOKEN}" "${BASE}?per_page=1")
[ "$probe" = "404" ] && BASE="https://api.github.com/users/${GITHUB_ORG}/repos"

page=1
while :; do
  resp=$(curl -fsS --max-time 15 -H "Authorization: Bearer ${GITHUB_TOKEN}" "${BASE}?per_page=100&page=${page}")
  n=$(printf '%s' "$resp" | jq 'length')
  [ "$n" -eq 0 ] && break
  printf '%s' "$resp" | jq -c '.[] | {id: .id, name: .name, owner: .owner.login, full_name: .full_name, description: (.description // ""), archived: .archived}' >> "$OUT"
  [ "$n" -lt 100 ] && break
  page=$((page + 1))
done
echo "repos listed: $(wc -l < "$OUT" | tr -d ' ')"
```

Expected: one JSON object per line in `$OUT`, `repos listed: N` matching the org's/user's actual repo count. Each object already carries the repo's immutable numeric `id` — this listing call is the only source of identity when mapping candidates for the first time, no separate per-repo call is needed for that. A targeted by-id lookup is still useful later, for re-checking one already-confirmed id on a re-run — see the next section.

## Fetch a repo by its immutable id

Used by Phase 5's re-run delta to re-check one already-confirmed `repository_id`, not for initial candidate discovery (the listing call above covers that). Unlike the listing call, this finds the repo even if it was transferred out of the configured org/user entirely — a transfer would simply be absent from that org's/user's listing, but this call still reaches it by id (or gets a real 404 if it was deleted or access was lost).

```bash
set -eu
REPOSITORY_ID="812345678"      # an already-confirmed repository_id from a prior repo-map.json
resp=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Authorization: Bearer ${GITHUB_TOKEN}" "https://api.github.com/repositories/${REPOSITORY_ID}")
if [ "$resp" = "200" ]; then
  curl -fsS --max-time 10 -H "Authorization: Bearer ${GITHUB_TOKEN}" "https://api.github.com/repositories/${REPOSITORY_ID}" \
    | jq -c '{id: .id, name: .name, owner: .owner.login, full_name: .full_name, archived: .archived}'
else
  echo "repo ${REPOSITORY_ID}: ${resp} (404 means deleted or access lost; treat as a contradiction to flag, never as a silent drop)"
fi
```

Expected: a single JSON object with the current `name`/`owner`/`archived` state on `200` (compare against the last-recorded label to detect a rename or transfer), or the `repo <id>: 404 ...` line on failure.

## Fetch a repo's README (first section only)

```bash
set -eu
OWNER="your-org"                # from a candidate row
NAME="checkout-api"             # from a candidate row
resp=$(curl -s --max-time 10 -H "Authorization: Bearer ${GITHUB_TOKEN}" "https://api.github.com/repos/${OWNER}/${NAME}/readme")
content=$(printf '%s' "$resp" | jq -r '.content // empty')
if [ -n "$content" ]; then
  printf '%s' "$content" | tr -d '\n' | base64 -d 2>/dev/null | head -c 500 || printf '%s' "$content" | tr -d '\n' | base64 -D | head -c 500
else
  echo "(no README, or repo not found)"
fi
```

Expected: the first ~500 characters of the decoded README, or the "(no README...)" line. `base64 -d` is the GNU/Linux and Git-Bash form; `base64 -D` is the BSD/macOS form — the `||` fallback covers both without detecting the platform explicitly.

## Fetch a manifest's `name` field

```bash
set -eu
OWNER="your-org"                # from a candidate row
NAME="checkout-api"             # from a candidate row
for path in package.json go.mod pyproject.toml; do
  resp=$(curl -s --max-time 10 -H "Authorization: Bearer ${GITHUB_TOKEN}" "https://api.github.com/repos/${OWNER}/${NAME}/contents/${path}")
  content=$(printf '%s' "$resp" | jq -r '.content // empty')
  [ -z "$content" ] && continue
  decoded=$(printf '%s' "$content" | tr -d '\n' | base64 -d 2>/dev/null || printf '%s' "$content" | tr -d '\n' | base64 -D)
  case "$path" in
    package.json)
      name=$(printf '%s' "$decoded" | jq -r '.name // empty') ;;
    go.mod)
      name=$(printf '%s' "$decoded" | awk '/^module /{print $2; exit}') ;;
    pyproject.toml)
      name=$(printf '%s' "$decoded" | awk -F'"' '/^name *=/{print $2; exit}') ;;
  esac
  [ -n "${name:-}" ] && { echo "${path}: ${name}"; break; }
done
```

Expected: one `<path>: <name>` line for the first manifest found with a usable name field, or no output at all when none exist — absence is a normal outcome, not an error.
