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

Expected: one JSON object per line in `$OUT`, `repos listed: N` matching the org's/user's actual repo count. Each object already carries the repo's immutable numeric `id` — no separate "fetch repo by id" call is ever needed; the listing call is the only source of identity.

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
