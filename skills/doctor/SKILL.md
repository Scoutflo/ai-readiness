---
name: doctor
description: Preflight connection check; a bundled read-only script reads ~/.scoutflo/toolkit.yaml, makes one cheap call per configured integration, and emits a JSON-per-check matrix with fix hints and distinct exit codes. Use when the user mentions doctor, preflight, connection check, cannot reach Grafana, Sentry, or Prometheus, 401 or timeout errors before an audit, or blocked audit checks. Do not use to create or rotate credentials (use connect) or for scored assessment (use the audit-* skills).
---

# Doctor: Connection Preflight

Doctor answers one question before any audit or setup skill spends your time: can this machine actually reach everything `~/.scoutflo/toolkit.yaml` says it can, with the credentials currently in the environment?

Run it after `/scoutflo:connect`, before your first `/scoutflo:audit-all`, and whenever an audit reports a blocked check. Every `audit-*` and `setup-*` skill re-runs the subset of these checks it needs as its own doctor gate; this skill is the full matrix in one place.

All checking lives in one bundled script, `scripts/doctor.sh`. It is read-only, non-interactive, and never prints a secret: tokens are checked for presence and sent only inside request headers. The single exception to read-only is the optional Slack test post, which sends a visible message and runs only when you pass `--slack-test` after the user explicitly confirms. Doctor produces no `findings.json` and no score; it is a preflight, not an audit, and a failed check here is a stop-and-fix, never a finding.

## Prerequisites

- `curl` required; `jq` checked because every other skill needs it.
- `yq` optional. Without it, the script falls back to a POSIX parser that handles the flat two-level layout of `templates/toolkit.yaml.example`. Anything more nested needs `yq`.
- A vendor CLI **only when its provider is configured**, and doctor emits a `binary-<cli>` row (pass/fail) for each so a missing one is a clear, named failure rather than a downstream crash: `kubectl` (a `kubernetes:` block), `aws` (`aws:`), `gcloud` (`gcp:`), `doctl` (`digitalocean:`). Every other provider is HTTPS+token and needs no CLI.

## Step 0: Report the storage location (no choice required)

**You do not have to decide where reports go.** By default they land in
`./scoutflo-audits/` next to wherever you run — zero configuration, and it just
works. This step simply *prints* the resolved location so you know where to look;
it never asks you to pick a directory. Setting a custom location is optional and
only matters if you want one durable history that follows you across folders.

The resolved location is:

- **`SCOUTFLO_AUDIT_DIR`** if you have exported it (opt-in, for a fixed location), else
- **`./scoutflo-audits`** — the default, next to where you launched Claude Code.

Why an env var and not a config value: every command runs in a *fresh shell*, which
inherits your environment but cannot read a per-run config file, so `SCOUTFLO_AUDIT_DIR`
is the only thing that reliably carries the location across all of them. `reports_dir`
in `~/.scoutflo/toolkit.yaml` is just a convenience — this step reads it to print the
one `export` line that pins the location, and flags it if set but not yet exported.
None of this is required to start; the default is fine for a first run.

```bash
set -eu
CFG="$HOME/.scoutflo/toolkit.yaml"

# What the runs will ACTUALLY write to (only the env var threads through fresh shells).
if [ -n "${SCOUTFLO_AUDIT_DIR:-}" ]; then EFFECTIVE="$SCOUTFLO_AUDIT_DIR"; EFFSRC="SCOUTFLO_AUDIT_DIR env"
else EFFECTIVE="./scoutflo-audits"; EFFSRC="default (launch directory)"; fi

# What the config ASKS for (used only to generate the export line / detect a gap).
RD=""
[ -f "$CFG" ] && RD="$(sed -n 's/^reports_dir:[[:space:]]*//p' "$CFG" | head -1 | sed 's/[[:space:]]*#.*$//; s/^"//; s/"$//; s/^'\''//; s/'\''$//')"

abspath() { case "$1" in "~"|"~/"*) set -- "$HOME${1#\~}";; esac; case "$1" in /*) printf '%s' "$1";; ./*) printf '%s/%s' "$(pwd)" "${1#./}";; *) printf '%s/%s' "$(pwd)" "$1";; esac; }
EFF_ABS="$(abspath "$EFFECTIVE")"
echo "Reports will be written to: ${EFF_ABS}"
echo "  (source: ${EFFSRC})"

if [ -n "$RD" ]; then
  RD_ABS="$(abspath "$RD")"
  if [ "$RD_ABS" != "$EFF_ABS" ]; then
    echo "  ACTION NEEDED: toolkit.yaml sets reports_dir to ${RD_ABS}, but runs write to"
    echo "  ${EFF_ABS} until SCOUTFLO_AUDIT_DIR is exported. Add this line to your shell"
    echo "  profile (~/.zshrc or ~/.bashrc) AND to ~/.scoutflo/env for scheduled runs,"
    echo "  then relaunch Claude Code:"
    echo "      export SCOUTFLO_AUDIT_DIR=\"${RD_ABS}\""
  fi
elif [ "$EFFSRC" = "default (launch directory)" ]; then
  echo "  This is the default and is fine to start. Optional: if you want one durable"
  echo "  history that follows you across folders, export SCOUTFLO_AUDIT_DIR to a fixed"
  echo "  absolute path once (see connect Step 4c). Otherwise, just run from the same"
  echo "  folder each time and reports accumulate here with full run-to-run history."
fi

# A stray default tree while an explicit location is in force means unmerged history.
if [ "$EFFSRC" = "SCOUTFLO_AUDIT_DIR env" ] && [ -d "./scoutflo-audits" ] && [ "$EFF_ABS" != "$(pwd)/scoutflo-audits" ]; then
  echo "  WARNING: a separate ./scoutflo-audits exists in this folder from an earlier run;"
  echo "  its history will NOT merge with ${EFF_ABS}. Move it in or ignore it deliberately."
fi
```

## Step 1: Run the script

Fixed step: run as written, do not modify flags, do not re-implement the checks by hand.

```bash
# ${CLAUDE_PLUGIN_ROOT} is set by the plugin runtime. Running from a repo
# checkout instead: export CLAUDE_PLUGIN_ROOT as the repo root first.
OUT_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/doctor/$(date -u +%Y-%m-%d)"   # run directory for this doctor run
sh "${CLAUDE_PLUGIN_ROOT}/skills/doctor/scripts/doctor.sh" --out "${OUT_DIR}"
echo "doctor_exit=$?"
# Expect: doctor_exit=0 when every configured integration passes.
# 1 = toolkit.yaml missing, 2 = a required env var is unset, 3 = a live check failed.
```

The script emits one JSON line per check to stdout, human-readable progress to stderr, and appends every row to `${OUT_DIR}/matrix.tsv`. Reruns append below the earlier rows; for a clean table, delete `matrix.tsv` first or pass a fresh `--out`.

Flags:

| Flag | Meaning |
| --- | --- |
| `--out DIR` | Run directory for `matrix.tsv`. Default: `${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/doctor/<UTC date>` — the `SCOUTFLO_AUDIT_DIR` env var if exported, else `./scoutflo-audits` (same as Step 0; `reports_dir` is not read here) |
| `--config FILE` | Config to read. Default: `~/.scoutflo/toolkit.yaml` |
| `--slack-test` | Send the Slack webhook test post. Only after explicit user confirmation; see below |

## Step 2: Interpret the results

Judgment step: read the JSON lines and decide what to fix first. Each line has seven fields:

```json
{"integration":"grafana","check":"health","configured":"yes","env_var":"GRAFANA_TOKEN","result":"pass","http_code":"200","hint":"-"}
```

| Field | Meaning |
| --- | --- |
| `integration` | Template-order row: toolkit, grafana, sentry, pagerduty, datadog, elk, jsm, zenduty, groundcover, prometheus, alertmanager, loki, tempo, mimir, victoriametrics, vmalert, digitalocean, gcp, kubernetes, slack |
| `check` | What was checked: `env` (variable presence), a live endpoint (`health`, `identity`, `org`, `abilities`, `analytics`, `validate`, `monitors-read`, `cost-permissions`, `alerting-health`, `query`, `status`, `ready`, `rbac`, `account`, `monitoring-api`, `webhook-post`), `binary-*`, or `configured` for unconfigured rows |
| `configured` | `yes` when the block exists with a non-empty `url`, `host`, `token_env`, `project`, or `context`. Unconfigured rows are informational, never failures |
| `env_var` | The `*_env` variable name, `none` when the block names no token, `-` when not applicable. Names only; values never |
| `result` | `pass`, `fail`, `env-missing`, or `skipped` |
| `http_code` | Captured status code; `"000"` means the transport failed before any HTTP response; `null` for non-HTTP checks |
| `hint` | The concrete fix, quoting the observed failure shape (curl exit code or HTTP status), never a guess |

Result vocabulary:

- `pass`: the check succeeded.
- `fail`: the check ran and failed. The hint says why and what to fix.
- `env-missing`: the block names a `*_env` variable that is not set in this shell. The integration's live checks are recorded as `skipped`, never attempted, so no empty Authorization header is ever sent.
- `skipped`: not attempted for a stated reason (unconfigured, blocked by `env-missing`, or the Slack post awaiting confirmation). Skipped rows never fail the run.

Exit code precedence: `2` (env var missing) wins over `3` (live check failed), because exporting the variable may fix the live checks too. Fix in that order.

## Step 3: Render the connection matrix

```bash
OUT_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/doctor/$(date -u +%Y-%m-%d)"   # same directory used in Step 1
column -t -s "$(printf '\t')" "${OUT_DIR}/matrix.tsv"
```

Typical output:

```
integration      check         configured  env_var        result   http_code  hint
toolkit          binary-curl   yes         -              pass     -          -
toolkit          binary-jq     yes         -              pass     -          -
grafana          env           yes         GRAFANA_TOKEN  pass     -          -
grafana          health        yes         GRAFANA_TOKEN  pass     200        -
grafana          identity      yes         GRAFANA_TOKEN  pass     200        -
sentry           env           yes         SENTRY_TOKEN   env-missing  -      export SENTRY_TOKEN in this shell, then rerun doctor
sentry           org           yes         SENTRY_TOKEN   skipped  -          blocked: SENTRY_TOKEN is not set
prometheus       query         yes         none           fail     000        curl exit 7: connection refused; wrong port, service not exposed, or the port-forward is not running
loki             configured    no          -              skipped  -          add a loki block via /scoutflo:connect if you run Loki
kubernetes       rbac          yes         -              pass     -          -
slack            webhook-post  yes         SCOUTFLO_SLACK_WEBHOOK  skipped  -  test post sends a visible channel message; rerun with --slack-test after the user confirms
```

Close with a verdict:

- Exit 0: "Ready. Run /scoutflo:map-topology, then /scoutflo:audit-all."
- Exit 2 or 3: name the affected skills, fix, then rerun doctor. Exit 2 wording names the env var ("audit-sentry will not run until SENTRY_TOKEN is set"); exit 3 wording quotes the live evidence ("grafana failed its live check: http_code 000, curl exit 7 - host unreachable"), never the env var. Never advise starting an audit over a failed row, and never downgrade a doctor failure into a finding.

Verify the verdict mechanically before declaring it:

```bash
OUT_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/doctor/$(date -u +%Y-%m-%d)"   # same directory used in Step 1
awk -F '\t' 'NR>1 && $3=="yes" && ($5=="fail" || $5=="env-missing")' "${OUT_DIR}/matrix.tsv"
# Expect: no output. Every printed row is exactly a check still to fix.
```

## What the script checks

One cheap read-only call per configured integration. Unconfigured integrations are skipped cleanly; they are never failures.

| Integration | Live check | Healthy | Common failure meaning |
| --- | --- | --- | --- |
| grafana | GET `/api/health`, then GET `/api/org` | 200, 200 | 401: bad or expired token. 403 on `/api/org` with health 200: token authenticated but lacks even the Viewer basic role. Transport failure: wrong `grafana.url`. `GET /api/user` is deliberately never used: confirmed live on Grafana 10.4.1 that a real, correctly-scoped service-account token hard-403s there regardless of role, since that endpoint identifies an interactively logged-in user, not a service account |
| sentry | GET `/api/0/organizations/<org>/` | 200 | 404: wrong region host or org slug; run the region probe in `connect` `references/providers.md` |
| pagerduty | GET `/abilities`, then POST `/analytics/metrics/incidents/all` (read-only filter body) | 200, 200 | 401 on abilities: key invalid/revoked or wrong region host (`pagerduty.region` us vs eu). The analytics probe never fails the run: 402/403 there records `skipped` with a reason, because read-only keys are documented GET-only and Analytics may be plan-gated; audit-pagerduty reads that row to include or honestly exclude its actionability section |
| elk | GET `/api/alerting/_health` (Kibana, `Authorization: ApiKey`) | 200 | 404: `elk.kibana_url` points at Elasticsearch not Kibana, or a space/base-path prefix is wrong. 401/403: key invalid or the role lacks Kibana Read on Stack Rules. The response fields (`is_sufficiently_secure`, `has_permanent_encryption_key`) are themselves audit signals |
| datadog | GET `/api/v1/validate` (API key), then GET `/api/v1/monitor?page_size=1` (app key + `monitors_read`) | 200, 200 | Datadog needs a key PAIR; both headers are sent together. 403 on validate: API key wrong or wrong `datadog.site` (a valid key on the wrong site 403s). 403 on monitor: app key invalid, unscoped for `monitors_read`, or its creating user was disabled (app keys are user-bound). A `cost-permissions` row records whether `usage_read`/`billing_read` are present; a miss there is `skipped`, never a failure — audit-datadog reads it to run or exclude the non-scored cost section |
| jsm | resolve `cloud_id` (from `jsm.cloud_id`, else the unauthenticated `tenant_info` route), then GET `/jsm/ops/api/<cloud_id>/v1/alerts?size=1` (Atlassian API token over Basic auth) | non-empty cloud_id, then 200 | No cloud_id: `jsm.site` wrong or its `tenant_info` route blocked; set `jsm.cloud_id` explicitly. 401: bad token or email (the token is the Basic password, not a classic Opsgenie GenieKey). 403: the token's user has no JSM Operations access. 404: wrong `cloud_id` or the site has no Operations |
| zenduty | GET `/api/account/teams/` (`Authorization: Token <key>`) | 200 | 401/403: key invalid or not prefixed correctly — the header must be `Authorization: Token <key>` (the literal word `Token`, not `Bearer`). 429: rate-limited — Zenduty's per-endpoint-class limits are tight; wait ~1 minute. Zenduty has no read-only key scope, so a Bot Token (Beta) is the least-privilege path |
| groundcover | POST `/api/monitors/list` (`Authorization: Bearer`, `{"sources":[]}`) | 200 | There is no whoami endpoint, so listing monitors is the auth probe (a read-by-query POST, not a mutation). 401: key invalid. 403: key lacks Viewer access, or this is a multi-backend account and `groundcover.backend_id` (the `X-Backend-Id` header) is missing or wrong |
| prometheus | GET `/api/v1/query?query=vector(1)` | 200 | `vector(1)` succeeds even with zero targets, so it tests the API, not your fleet. `/-/ready` is deliberately not used: it varies by deployment |
| alertmanager | GET `/api/v2/status` | 200 | 404 with a working root usually means the URL points at something other than Alertmanager |
| loki, tempo, mimir | GET `/ready` | 200 | Behind a multi-tenant gateway or path prefix, `/ready` may 404 while queries work; verify the health path against your deployment before concluding the store is down |
| victoriametrics | GET `/health` | 200 | Cluster editions may serve health per component; verify the path against your deployment |
| vmalert | GET `/health` | 200 | If `/health` is not exposed in your setup, `GET /api/v1/rules` returning JSON is an equivalent read-only proof |
| digitalocean | `doctl` installed (binary check), then GET `/v2/account` | doctl present, then 200 | `binary-doctl fail`: `doctl` not installed but a `digitalocean:` block is configured (audit-digitalocean is doctl-based) — install doctl. 401: token missing, invalid, or expired. 403: token valid but scoped too low for account read |
| gcp | `gcloud auth print-access-token` (or `application-default` when `credentials_env` is set), then GET the Monitoring API `notificationChannels` | non-empty token, then 200 | No token at all: not logged in, or the key file `credentials_env` names is missing or invalid; run `gcloud auth login` or fix the key file. 403 on the API call: identity lacks `monitoring.viewer`. 404: `gcp.project` is wrong |
| kubernetes | `kubectl --context <ctx> auth can-i get pods` | `yes` | `no`: the context reaches the cluster but lacks read RBAC; bind the `view` ClusterRole. A context error: the config value does not exist in your kubeconfig; run `kubectl config get-contexts` |
| slack | POST test message (only with `--slack-test`) | 200 and the message appears | 404 or `no_service`: the webhook was revoked; create a new one via `/scoutflo:connect` |

Authorization headers are sent only when the block names a `token_env` and that variable is non-empty. PagerDuty uses its own `Authorization: Token token=<key>` scheme rather than a Bearer header, Datadog uses a `DD-API-KEY` + `DD-APPLICATION-KEY` header pair, Kibana uses `Authorization: ApiKey <encoded>`, JSM Operations uses HTTP Basic auth (`email:token`) with an Atlassian API token, Zenduty uses `Authorization: Token <key>` (the literal word `Token`, not `Bearer`), and Groundcover uses `Authorization: Bearer <key>` plus an `X-Backend-Id` header on multi-backend accounts; the same never-send-empty rule applies to all of them. A named-but-unset variable yields `env-missing`, not a call with an empty header. GCP has no static `token_env`; its identity comes from `gcloud`, and the same empty-credential rule applies: no access token, no call.

## The Slack test post

This is the one check that writes: it posts a visible message to your channel. Ask the user for explicit confirmation in the conversation before passing `--slack-test`; if declined or unanswered, the default `skipped` row is a valid healthy-enough state. The webhook URL is itself the credential; the script never prints it, and neither should you.

```bash
# Only after the user has explicitly confirmed the visible test post.
OUT_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/doctor/$(date -u +%Y-%m-%d)"   # run directory for this doctor run
sh "${CLAUDE_PLUGIN_ROOT}/skills/doctor/scripts/doctor.sh" --out "${OUT_DIR}" --slack-test
echo "doctor_exit=$?"
# Expect: doctor_exit=0 and a slack webhook-post row with result pass, http_code 200.
```

## Fix hints per failure class

The script's hints quote the observed failure shape. This table is the deeper read once you have a row in hand:

| Failure class | Likely cause | Fix |
| --- | --- | --- |
| exit 1, config not found | No `~/.scoutflo/toolkit.yaml` | Run `/scoutflo:connect`; it seeds the file from `templates/toolkit.yaml.example` |
| `env-missing` | The `*_env` variable is not exported in this shell | Export it here (env vars are per-shell), or load it from your profile; created per `connect` `references/providers.md` |
| `http_code` 000, curl exit 6 | DNS lookup failed | Typo in the URL, or the host resolves only on VPN or internal DNS |
| `http_code` 000, curl exit 7 | Connection refused | Wrong port, service not exposed, or the port-forward is not running |
| `http_code` 000, curl exit 28 | Timeout | Firewall or network path; confirm you can reach the host at all before raising `CURL_MAX_TIME` |
| `http_code` 000, curl exit 35 or 60 | TLS failure | Internal CA not trusted by your system; install the CA properly, never disable verification |
| HTTP 401 | Token missing, invalid, or expired | Recreate per the provider section in `connect`; confirm the variable is exported in this shell |
| HTTP 403 | Token valid, scope or role too low | Raise to the tier scopes in `connect` `references/providers.md` |
| HTTP 404 | Wrong path, wrong region host, or a path prefix | Sentry: run the region probe. Gateways: verify the health path against your deployment |
| kubernetes `rbac` fail with "no" | Context reaches the cluster, read RBAC missing | Bind the `view` ClusterRole per `connect` `references/providers.md` |
| kubernetes `rbac` fail with a context error | `kubernetes.context` not in your kubeconfig | `kubectl config get-contexts`, then fix the config value |
| A key you set reads as unconfigured | Block name or indentation mismatch, or nesting beyond the fallback parser | Compare against `templates/toolkit.yaml.example`; install `yq` for anything nested |

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Doctor passes in one terminal, the audit fails in another | Env vars are per-shell; export them in your profile or run doctor and the audit in the same shell |
| Empty `Authorization` header sent to an unauthenticated endpoint, causing a proxy 401 | Run the bundled script; it attaches the header only when `token_env` is named and set. Never hand-roll a check that adds the header unconditionally |
| Checks re-implemented inline instead of running the script | The script is the check contract: exit codes, JSON shape, and header guards live there. Inline curl loops drift and leak |
| `/ready` 404 behind a path-prefixed gateway read as "service down" | Health paths vary by deployment; verify the path, and treat a successful real query as authoritative |
| Sentry 404 read as "org does not exist" | Wrong region host; probe both region hosts before concluding anything about the org |
| Grafana health `ok` but every later audit call 403 | The script checks identity via `/api/org` during doctor, not mid-audit; fix the 403 row before any audit |
| Slack test post fired without asking | The post is visible to the channel; pass `--slack-test` only on explicit confirmation, and `skipped` is a valid state |
| Secret value printed while debugging a failing check | Debug with the recorded `http_code` and curl exit codes; the script never prints values, and neither should any manual follow-up |
| A failed doctor row carried into an audit as a "blocked finding" | Doctor failures stop the run; fix and rerun doctor before starting any audit |
| Stale rows read after a rerun into the same `--out` directory | `matrix.tsv` appends; delete it first or use a fresh `--out`, and treat the JSON stdout of the latest run as the truth |
