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
if [ "$code" = "404" ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Authorization: Bearer ${GITHUB_TOKEN}" "https://api.github.com/users/${GITHUB_ORG}")
  echo "resolved as: user (org lookup 404'd)"
elif [ "$code" = "200" ]; then
  echo "resolved as: org"
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
