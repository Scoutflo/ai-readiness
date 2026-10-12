---
name: setup-lgtm
description: Guided hardening of LGTM and VictoriaMetrics stacks from audit-lgtm and audit-alertmanager findings: alert routing, noisy rules, retention, HA, exposure, service labels, and monitoring-namespace NetworkPolicies and PDBs, each change announced, confirmed, then verified live. Use when the user asks to fix an LGTM-NNN or ALR-NNN finding or repair Alertmanager or vmalert routing. Do not use for Grafana dashboards or contact points (use setup-grafana), NetworkPolicies or PDBs outside the monitoring stack (use setup-kubernetes), or read-only checks (use audit-lgtm or audit-alertmanager).
disable-model-invocation: true
---

# setup-lgtm

Fixes findings from an `audit-lgtm` run against your LGTM or VictoriaMetrics-family stack, and the `audit-alertmanager` findings that point here. Input is one or more finding IDs from the latest `./scoutflo-audits/lgtm/<date>/findings.json` (`lgtm/<label>/<date>/` for one stack of an `lgtm:` list) or `./scoutflo-audits/alertmanager/<date>/findings.json`. You usually arrive here from a finding's `remediation` pointer, for example `setup-lgtm#fix-default-receiver`.

| Finding ID | Fix section |
| --- | --- |
| LGTM-011, LGTM-012, LGTM-014; ALR-002, ALR-003, ALR-005, ALR-006, ALR-018 | [Fix default receiver](#fix-default-receiver) |
| LGTM-015, LGTM-016; ALR-004, ALR-016, ALR-017, ALR-022, ALR-023 | [Add severity routes and inhibition](#add-severity-routes-and-inhibition) (an unintended silence expires through your Alertmanager UI) |
| LGTM-013 | [Test-fire receivers](#test-fire-receivers) |
| LGTM-004, LGTM-017, LGTM-080 to LGTM-082; ALR-011, ALR-013 | [Quiet noisy rules](#quiet-noisy-rules) (the same blocks fix the expression a `lastError` names or add a missing datastore rule) |
| ALR-015 | [Quiet noisy rules](#quiet-noisy-rules) for top talkers, [Add severity routes and inhibition](#add-severity-routes-and-inhibition) for `repeat_interval` |
| LGTM-023, LGTM-031, LGTM-043 | [Standardize service labels](#standardize-service-labels) |
| LGTM-061 | [Set retention](#set-retention) |
| LGTM-001, LGTM-060 | [Enable HA](#enable-ha) (LGTM-001 is an outage first: restore the store through its owner) |
| LGTM-063 | [Lock down exposure](#lock-down-exposure) |
| LGTM-064 | [Add network policies](#add-network-policies), [Add disruption budgets](#add-disruption-budgets) |
| LGTM-006, LGTM-007, LGTM-008, LGTM-025, LGTM-030, LGTM-032 to LGTM-034, LGTM-062, LGTM-070 to LGTM-073 | Plan only: this skill has no verified procedure for tenant headers, collector buffers, instrumentation, storage backups, or ruler holds, limits, and flags. Record each as pending with a named owner ([Record and wrap up](#record-and-wrap-up)). |

In scope: Alertmanager and vmalert routing, receiver test-fires, noisy rule cleanup, retention, HA and replication, ingress exposure, NetworkPolicies, PodDisruptionBudgets, and service-label alignment at the collector level. Grafana contact points, dashboards, and datasources belong to `setup-grafana`. Error-tracking fixes belong to `setup-sentry`. Missing application instrumentation is a change inside your application code; this skill records those items with a named owner instead of touching app repos.

## The change protocol

Every change follows one loop, no exceptions:

1. **Announce.** Show the exact change before touching anything: the API call, manifest, or values diff with real values filled in, plus its rollback.
2. **Confirm.** Wait for explicit approval in the conversation. One approval may cover a batch only when every change in the batch was shown first. Silence, an earlier approval, or "fix everything" from three steps ago is not consent. Declining means zero changes.
3. **Execute.** Apply exactly what was announced. If reality forces a different change, stop and re-announce.
4. **Verify.** Re-fetch the modified object with a read call and show the changed field holding the intended value. A write is unverified until re-read.
5. **Record.** Append the change, its verification evidence, and any pending items with a named owner to the change record.

## Doctor gate

Run these checks before any real work. A failed check stops the skill with the exact failure and the fix, usually `/scoutflo:connect`. This skill uses the elevated credential tier: it mutates cluster and Alertmanager state.

A single `lgtm:` block reads the top-level keys below. An `lgtm:` list holds one entry per stack with flat keys (`kubernetes_context`, `monitoring_namespace`, `alertmanager_url`, `prometheus_url`, `<store>_token_env`, ...); export `SCOUTFLO_TARGET=<label>` to pick the stack whose findings you are fixing. The gates refuse to guess one.

| Integration | Config keys | Env var | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| Kubernetes | `kubernetes.context`, `kubernetes.monitoring_namespace` | none (kubeconfig) | patch/apply on workloads, config, NetworkPolicies, PDBs in the monitoring namespace | elevated |
| Alertmanager | `prometheus.alertmanager_url` | the one `prometheus.token_env` names, if set | GET status, POST alerts | elevated |
| Metrics backend | `prometheus.url` or `victoriametrics.url` or `mimir.url` | the one its `token_env` names, if set | read, for verification | read-only |
| Loki / Tempo | `loki.url`, `tempo.url` | the ones their `token_env` names, if set | read, for label-parity verification | read-only |
| Helm | none | none | needed only when the stack is Helm-managed | elevated |

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing ${CFG}; run /scoutflo:connect"; exit 1; }
# Secret store: sets the *_env variables /scoutflo:connect wrote; prints nothing.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
for bin in curl jq kubectl; do command -v "$bin" >/dev/null || { echo "missing binary: $bin"; exit 1; }; done
command -v helm >/dev/null || echo "note: helm not found; Helm-managed changes are unavailable"
# One stack: a single lgtm block reads the top-level blocks, an lgtm list the entry SCOUTFLO_TARGET names.
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$TT" "$CFG" lgtm kind)" = seq ]; then
  IDX=""; [ -z "${SCOUTFLO_TARGET:-}" ] || IDX="$(sh "$TT" "$CFG" lgtm labels | grep -Fnx -- "$SCOUTFLO_TARGET" | head -1 | cut -d: -f1)"
  [ -n "$IDX" ] || { echo "lgtm lists several stacks; export SCOUTFLO_TARGET as one of:"; sh "$TT" "$CFG" lgtm labels; exit 1; }
  IDX=$((IDX - 1)); STACK="$SCOUTFLO_TARGET"
  v() { sh "$TT" "$CFG" lgtm get "$IDX" "${1}_${2}"; }
  KUBE_CONTEXT="$(v kubernetes context)"; MON_NS="$(v monitoring namespace)"
  ALERTMANAGER_URL="$(v alertmanager url)"; AM_TOKEN_ENV="$(v alertmanager token_env)"
else
  STACK="lgtm"
  v() { sh "$TT" "$CFG" "$1" get 0 "$2"; }
  KUBE_CONTEXT="$(v kubernetes context)"; MON_NS="$(v kubernetes monitoring_namespace)"
  ALERTMANAGER_URL="$(v prometheus alertmanager_url)"; AM_TOKEN_ENV="$(v prometheus token_env)"
fi
MON_NS="${MON_NS:-monitoring}"; METRICS_URL=""; METRICS_TOKEN_ENV=""
for s in prometheus victoriametrics mimir; do
  u="$(v "$s" url)"; [ -n "$u" ] || continue
  METRICS_URL="${u%/}"; METRICS_TOKEN_ENV="$(v "$s" token_env)"; [ "$s" != mimir ] || METRICS_URL="${METRICS_URL}/prometheus"; break
done
LOKI_URL="$(v loki url)"; LOKI_TOKEN_ENV="$(v loki token_env)"
TEMPO_URL="$(v tempo url)"; TEMPO_TOKEN_ENV="$(v tempo token_env)"
[ -n "$KUBE_CONTEXT" ] || { echo "no kubernetes context for stack ${STACK} in ${CFG}; this skill changes Kubernetes-hosted stacks; run /scoutflo:connect"; exit 1; }
[ -n "$ALERTMANAGER_URL" ] || { echo "no alertmanager url for stack ${STACK} in ${CFG}; run /scoutflo:connect"; exit 1; }
[ -n "$METRICS_URL" ] || { echo "no prometheus, victoriametrics, or mimir url for stack ${STACK} in ${CFG}; run /scoutflo:connect"; exit 1; }
# A token_env the config names must be set. Presence only; the value is never printed.
for TV in "$AM_TOKEN_ENV" "$METRICS_TOKEN_ENV" "$LOKI_TOKEN_ENV" "$TEMPO_TOKEN_ENV"; do
  [ -z "$TV" ] || [ -n "$(printenv "$TV" 2>/dev/null || true)" ] || { echo "${TV} is named by a token_env in ${CFG} but is not set; add it to ~/.scoutflo/env or run /scoutflo:connect"; exit 1; }
done
# The bearer header goes out only when its token is non-empty; otherwise a harmless Accept header.
hdr() { t=""; [ -z "$1" ] || t="$(printenv "$1" 2>/dev/null || true)"; if [ -n "$t" ]; then printf 'Authorization: Bearer %s' "$t"; else printf 'Accept: application/json'; fi; }
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" auth can-i patch statefulsets >/dev/null \
  || { echo "no write access to ${MON_NS} in ${KUBE_CONTEXT}; switch to an elevated kubeconfig"; exit 1; }
# Capture each response before parsing it: a 401, 404, or timeout stops here instead of printing nothing.
AM="$(curl -fsS --max-time 10 -H "$(hdr "$AM_TOKEN_ENV")" "${ALERTMANAGER_URL}/api/v2/status")" || { echo "Alertmanager unreachable or unauthorized at ${ALERTMANAGER_URL}"; exit 1; }
AMS="$(printf '%s' "$AM" | jq -er '.cluster.status')" || { echo "${ALERTMANAGER_URL} answered without an Alertmanager v2 status: wrong URL or a login page"; exit 1; }
echo "alertmanager cluster: ${AMS}"
MB="$(curl -fsS --max-time 10 -H "$(hdr "$METRICS_TOKEN_ENV")" "${METRICS_URL}/api/v1/status/buildinfo" 2>/dev/null || true)"
if MV="$(printf '%s' "$MB" | jq -er '.data.version' 2>/dev/null)"; then echo "metrics backend: ${MV}"
elif [ "$(curl -fsS --max-time 10 -H "$(hdr "$METRICS_TOKEN_ENV")" "${METRICS_URL}/health" 2>/dev/null || true)" = "OK" ]; then echo "metrics backend: OK (/health)"
else echo "metrics backend unreachable or unauthorized at ${METRICS_URL}"; exit 1; fi
if [ -n "$LOKI_URL" ]; then
  LB="$(curl -fsS --max-time 10 -H "$(hdr "$LOKI_TOKEN_ENV")" "${LOKI_URL}/loki/api/v1/labels" 2>/dev/null || true)"
  if printf '%s' "$LB" | jq -e '.status == "success"' >/dev/null 2>&1; then echo "logs: Loki labels API answers"
  elif [ "$(curl -fsS --max-time 10 -H "$(hdr "$LOKI_TOKEN_ENV")" "${LOKI_URL}/health" 2>/dev/null || true)" = "OK" ]; then echo "logs: OK (/health, VictoriaLogs)"
  else echo "logs backend unreachable or unauthorized at ${LOKI_URL}"; exit 1; fi
else echo "note: no loki url for stack ${STACK}; log label parity cannot be verified"; fi
if [ -n "$TEMPO_URL" ]; then
  TE="$(curl -fsS --max-time 10 -H "$(hdr "$TEMPO_TOKEN_ENV")" "${TEMPO_URL}/api/echo" 2>/dev/null || true)"
  [ "$TE" = "echo" ] || [ "$(curl -fsS --max-time 10 -H "$(hdr "$TEMPO_TOKEN_ENV")" "${TEMPO_URL}/health" 2>/dev/null || true)" = "OK" ] \
    || { echo "traces backend unreachable or unauthorized at ${TEMPO_URL}"; exit 1; }
  echo "traces: answers"
else echo "note: no tempo url for stack ${STACK}; trace label parity cannot be verified"; fi
echo "doctor gate: pass for stack ${STACK} (context ${KUBE_CONTEXT}, namespace ${MON_NS})"
```

Expected: Alertmanager cluster status `ready` (or `disabled` on a single replica), a version string or `OK` from the metrics backend, and `doctor gate: pass`. Every HTTP block below sends `Authorization: Bearer` only when the variable its `token_env` names is non-empty, and `Accept: application/json` otherwise; the value never appears in output or logs. The blocks send bearer tokens only: a basic-auth endpoint, or a multi-tenant Mimir that needs `X-Scope-OrgID`, fails here with a 401, which stops the run rather than passing it.

## Live-safety gate

Fill the four `PINNED_` lines with the values you will put in every block below. The gate reads the same keys from `toolkit.yaml` by command (the `SCOUTFLO_TARGET` entry for an `lgtm:` list) and stops on any difference.

```bash
set -eu
PINNED_CONTEXT="your-kube-context"                    # the --context every block below uses
PINNED_NS="monitoring"                                # the -n every block below uses
PINNED_AM_URL="https://alertmanager.example.com"      # the ALERTMANAGER_URL every block below uses
PINNED_METRICS_URL="https://prometheus.example.com"   # the METRICS_URL every block below uses
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$TT" "$CFG" lgtm kind)" = seq ]; then
  IDX=""; [ -z "${SCOUTFLO_TARGET:-}" ] || IDX="$(sh "$TT" "$CFG" lgtm labels | grep -Fnx -- "$SCOUTFLO_TARGET" | head -1 | cut -d: -f1)"
  [ -n "$IDX" ] || { echo "lgtm lists several stacks; export SCOUTFLO_TARGET as one of:"; sh "$TT" "$CFG" lgtm labels; exit 1; }
  IDX=$((IDX - 1)); STACK="$SCOUTFLO_TARGET"; SEG="lgtm/${SCOUTFLO_TARGET}"
  v() { sh "$TT" "$CFG" lgtm get "$IDX" "${1}_${2}"; }
  KUBE_CONTEXT="$(v kubernetes context)"; MON_NS="$(v monitoring namespace)"
  ALERTMANAGER_URL="$(v alertmanager url)"; AM_TOKEN_ENV="$(v alertmanager token_env)"
else
  STACK="lgtm"; SEG="lgtm"
  v() { sh "$TT" "$CFG" "$1" get 0 "$2"; }
  KUBE_CONTEXT="$(v kubernetes context)"; MON_NS="$(v kubernetes monitoring_namespace)"
  ALERTMANAGER_URL="$(v prometheus alertmanager_url)"; AM_TOKEN_ENV="$(v prometheus token_env)"
fi
MON_NS="${MON_NS:-monitoring}"; METRICS_URL=""; METRICS_TOKEN_ENV=""
for s in prometheus victoriametrics mimir; do
  u="$(v "$s" url)"; [ -n "$u" ] || continue
  METRICS_URL="${u%/}"; METRICS_TOKEN_ENV="$(v "$s" token_env)"; [ "$s" != mimir ] || METRICS_URL="${METRICS_URL}/prometheus"; break
done
[ -n "$KUBE_CONTEXT" ] || { echo "no kubernetes context for stack ${STACK} in ${CFG}; stop"; exit 1; }
BAD=0
[ "$PINNED_CONTEXT" = "$KUBE_CONTEXT" ] || { echo "MISMATCH context: blocks pin '${PINNED_CONTEXT}', ${CFG} names '${KUBE_CONTEXT}'"; BAD=1; }
[ "$PINNED_NS" = "$MON_NS" ] || { echo "MISMATCH namespace: blocks pin '${PINNED_NS}', ${CFG} names '${MON_NS}'"; BAD=1; }
[ "${PINNED_AM_URL%/}" = "${ALERTMANAGER_URL%/}" ] || { echo "MISMATCH alertmanager: blocks pin '${PINNED_AM_URL}', ${CFG} names '${ALERTMANAGER_URL}'"; BAD=1; }
[ "${PINNED_METRICS_URL%/}" = "${METRICS_URL%/}" ] || { echo "MISMATCH metrics: blocks pin '${PINNED_METRICS_URL}', ${CFG} names '${METRICS_URL}'"; BAD=1; }
[ "$BAD" -eq 0 ] || { echo "stop: correct the pinned values or ${CFG}, then re-run this gate"; exit 1; }
hdr() { t=""; [ -z "$1" ] || t="$(printenv "$1" 2>/dev/null || true)"; if [ -n "$t" ]; then printf 'Authorization: Bearer %s' "$t"; else printf 'Accept: application/json'; fi; }
# Identity reads: what the cluster and each HTTP target say they are.
echo "stack ${STACK}; findings under ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${SEG}/"
echo "shell context: $(kubectl config current-context 2>/dev/null || echo none); pinned context: ${KUBE_CONTEXT}"
echo "api server: $(kubectl config view --minify --context "$KUBE_CONTEXT" -o jsonpath='{.clusters[0].cluster.server}')"
WL="$(kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get statefulsets,deployments -o name)" || { echo "cannot read ${MON_NS} on ${KUBE_CONTEXT}; stop"; exit 1; }
[ -n "$WL" ] || { echo "no workloads in ${MON_NS} on ${KUBE_CONTEXT}: wrong cluster or namespace; stop"; exit 1; }
printf '%s\n' "$WL" | head -5
AM="$(curl -fsS --max-time 10 -H "$(hdr "$AM_TOKEN_ENV")" "${ALERTMANAGER_URL}/api/v2/status")" || { echo "Alertmanager identity read failed at ${ALERTMANAGER_URL}; stop"; exit 1; }
AMI="$(printf '%s' "$AM" | jq -er '"alertmanager: version \(.versionInfo.version // "unknown"), cluster \(.cluster.status), \(.cluster.peers // [] | length) peer(s)"')" || { echo "${ALERTMANAGER_URL} is not an Alertmanager v2 API; stop"; exit 1; }
echo "$AMI"
MB="$(curl -fsS --max-time 10 -H "$(hdr "$METRICS_TOKEN_ENV")" "${METRICS_URL}/api/v1/status/buildinfo" 2>/dev/null || true)"
echo "metrics: $(printf '%s' "$MB" | jq -er '"version " + .data.version' 2>/dev/null || echo "no buildinfo (a VictoriaMetrics /health backend)")"
echo "live-safety gate: pass. Confirm this is the stack you mean to change before approving anything."
```

If any line says `MISMATCH`, or the API server, workloads, or Alertmanager are not the ones you expect, stop and report it. Never proceed on "probably the right cluster". Every command below pins `--context` and `-n` explicitly; the shell default is never trusted.

## Load findings and build the change plan

1. Read the latest audit runs and list the open findings that point here:

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
ROOT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
SEG="lgtm"
if [ "$(sh "$TT" "$CFG" lgtm kind)" = seq ]; then
  [ -n "${SCOUTFLO_TARGET:-}" ] && sh "$TT" "$CFG" lgtm labels | grep -Fqx -- "$SCOUTFLO_TARGET" \
    || { echo "lgtm lists several stacks; export SCOUTFLO_TARGET as one of:"; sh "$TT" "$CFG" lgtm labels; exit 1; }
  SEG="lgtm/${SCOUTFLO_TARGET}"
fi
# Only date-named folders are audit runs. This skill's setup-<date>/, audit-lgtm's large-path runs/,
# and per-stack <label>/ folders sit beside them and hold no findings.json.
latest() { find "$1" -mindepth 1 -maxdepth 1 -type d -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' 2>/dev/null | sort | tail -1; }
FOUND=0
for RUN in "$(latest "${ROOT}/${SEG}")" "$(latest "${ROOT}/alertmanager")"; do
  [ -n "$RUN" ] && [ -f "${RUN}/findings.json" ] || continue
  FOUND=1; echo "== ${RUN}/findings.json"
  jq -r '.findings[] | select((.lifecycle // "new") != "suppressed") | select((.remediation // "") | test("setup-lgtm"))
    | [.id, .severity, .title, .remediation] | @tsv' "${RUN}/findings.json"
done
[ "$FOUND" -eq 1 ] || { echo "no audit run under ${ROOT}/${SEG}/ or ${ROOT}/alertmanager/; run /scoutflo:audit-lgtm first"; exit 1; }
```

`audit-alertmanager` audits the one Alertmanager at `prometheus.alertmanager_url`; on an `lgtm:` list, fix its ALR IDs only on the stack whose `alertmanager_url` is that Alertmanager.

2. Select scope. Take the finding IDs you were asked to fix, or, if asked for "everything critical and high", enumerate those IDs explicitly so the plan names each one. Map each finding's `remediation` anchor to a section below.

3. Discover who owns each object before planning an edit. A change made below its owner gets reverted:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
MON_NS="monitoring"                # kubernetes.monitoring_namespace

helm --kube-context "$KUBE_CONTEXT" list -A -o json | jq -r '.[] | "\(.namespace)/\(.name) \(.chart)"'
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get deploy,sts -o json \
  | jq -r '.items[] | "\(.kind)/\(.metadata.name) managed-by=\(.metadata.labels["app.kubernetes.io/managed-by"] // "none") argocd=\(.metadata.labels["argocd.argoproj.io/instance"] // "-")"'
```

Helm-managed objects change through `helm upgrade` on the release. Operator-managed objects change through their CRs. If Argo CD or Flux owns the release, make the change in the Git source your controller syncs from; the protocol still applies, with "execute" meaning commit and sync, then verify live.

4. Create the working directory and snapshot targets before any change:

```bash
set -eu
RUN_DATE="$(date -u +%F)"
WORK_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm/setup-${RUN_DATE}"
BACKUP_DIR="${WORK_DIR}/backups"
CHANGE_LOG="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm/changes.md"
mkdir -p "$BACKUP_DIR"
```

Backups can embed receiver URLs and other sensitive config. `./scoutflo-audits/` stays out of version control.

5. Announce the full plan as one table and wait for approval:

| # | Finding | Object | Exact change | Rollback |
| --- | --- | --- | --- | --- |

Approval must be explicit and may cover the whole table because every row was shown. If you approve only some rows, only those execute. A decline ends the run with zero changes. Execute approved rows one at a time, verifying each before starting the next. Order safety first: routing fixes before test-fires, allow-policies before default-deny, additive changes before destructive ones.

Findings that change the same object (LGTM-014 to LGTM-016 often all edit one Alertmanager config) go in one row: one backup, one edit, one verify. Every backup block refuses to overwrite an existing backup file, so a second change to an object already backed up today stops instead of destroying the first change's pre-change copy. Record the exact backup file in each change entry.

**Mid-batch failure rule.** If row N of an approved batch fails its verification, stop the batch immediately: no row N+1 runs. Every row already applied keeps its backup in `BACKUP_DIR`, taken before that row's write; those rows stay applied and recorded, they are not rolled back automatically. Re-fetch the failed object's current state, report exactly what happened (the command, the error, and what the live object now shows), and diagnose before doing anything else. Re-announce the remaining unexecuted rows as a fresh plan only after the user decides how to proceed; the earlier approval does not carry over to a re-announced batch. A half-applied change (a receiver pointed at a new webhook but never test-fired, a NetworkPolicy applied without its allow rule verified first) is worse than no change; verify or roll back the failed row before anything else runs.

## Fix sections by finding family

| Audit finding area | Sections | Payload details |
| --- | --- | --- |
| alert-routing | Fix default receiver, Add severity routes and inhibition, Test-fire receivers, Quiet noisy rules | [references/alerting.md](references/alerting.md) |
| service-coverage, correlation gaps | Standardize service labels | [references/hardening.md](references/hardening.md) |
| reliability-security | Set retention, Enable HA, Lock down exposure, Add network policies, Add disruption budgets | [references/hardening.md](references/hardening.md) |

### Fix default receiver

For findings where the default route points at a dead webhook, localhost, or a `null` receiver.

1. Read the running config and quote the current default route in the announcement:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
ALERTMANAGER_URL="https://alertmanager.example.com"   # prometheus.alertmanager_url
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
AM_TOKEN="${PROM_TOKEN:-}"   # the variable prometheus.token_env names; empty for an open endpoint
AUTH="Authorization: Bearer ${AM_TOKEN}"; [ -n "$AM_TOKEN" ] || AUTH="Accept: application/json"

BODY="$(curl -fsS --max-time 10 -H "$AUTH" "${ALERTMANAGER_URL}/api/v2/status")" || { echo "Alertmanager unreachable or unauthorized at ${ALERTMANAGER_URL}" >&2; exit 1; }
ORIG="$(printf '%s' "$BODY" | jq -er '.config.original')" || { echo "no running config in the status response" >&2; exit 1; }
printf '%s\n' "$ORIG" | sed -n '/^route:/,/^receivers:/p'
```

2. Locate where that config comes from (Helm values, operator CR, or a raw Secret) and back it up; per-style payloads and rollbacks are in [references/alerting.md](references/alerting.md). On a VictoriaMetrics stack, also run the vmalert notifier check there (LGTM-012): a stale notifier URL means rules evaluate but nothing reaches the receiver you fix.
3. Announce the diff: old receiver, new receiver, the full route block after the change. Webhook URLs never go inline in config you write; use `*_file` options or an existing Secret mount.
4. Apply through the owner (helm upgrade, CR apply, or Secret replace).
5. Verify against the running config, not the Secret or values file, then prove delivery with a test-fire (next section):

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
ALERTMANAGER_URL="https://alertmanager.example.com"   # prometheus.alertmanager_url
WANT_DEFAULT="team-default"   # the default receiver you announced
WANT_ROUTES="team-pager"      # receivers of the routes you announced, space-separated; "" for none
WANT_INHIBIT="no"             # "yes" when the change added inhibit_rules
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
AM_TOKEN="${PROM_TOKEN:-}"   # the variable prometheus.token_env names; empty for an open endpoint
AUTH="Authorization: Bearer ${AM_TOKEN}"; [ -n "$AM_TOKEN" ] || AUTH="Accept: application/json"

BODY="$(curl -fsS --max-time 10 -H "$AUTH" "${ALERTMANAGER_URL}/api/v2/status")" || { echo "Alertmanager unreachable or unauthorized at ${ALERTMANAGER_URL}" >&2; exit 1; }
ORIG="$(printf '%s' "$BODY" | jq -er '.config.original')" || { echo "no running config in the status response" >&2; exit 1; }
ROUTE="$(printf '%s\n' "$ORIG" | sed -n '/^route:/,/^[^ ]/p')"
GOT="$(printf '%s\n' "$ROUTE" | sed -n 's/^  receiver: *//p' | head -1 | tr -d "\"'")"
[ "$GOT" = "$WANT_DEFAULT" ] || { echo "default receiver is '${GOT}', expected '${WANT_DEFAULT}'" >&2; exit 1; }
for R in $WANT_ROUTES; do
  printf '%s\n' "$ROUTE" | grep -Eq "receiver: *[\"']?${R}[\"']?\$" || { echo "no route sends to ${R}" >&2; exit 1; }
done
[ "$WANT_INHIBIT" != "yes" ] || printf '%s\n' "$ORIG" | grep -q '^inhibit_rules:' || { echo "no inhibit_rules in the running config" >&2; exit 1; }
echo "VERIFIED: default receiver ${GOT}; route receivers: ${WANT_ROUTES:-none}"
```

Expected: `VERIFIED`. Allow up to a minute for the config reloader, then re-run before deciding. With `AlertmanagerConfig` CRs the operator prefixes receiver names with `<namespace>/<cr-name>/`; use the names the step 1 read shows.

Rollback: run the matching rollback block in [references/alerting.md](references/alerting.md) (raw Secret or CR path), or `helm rollback` to the recorded revision.

### Add severity routes and inhibition

For findings about missing severity routing, grouping, or inhibition. Same locate/backup/apply/verify path as the default receiver; route and `inhibit_rules` payloads are in [references/alerting.md](references/alerting.md). Verify with the step 5 block of [Fix default receiver](#fix-default-receiver), `WANT_ROUTES` set to each new route's receiver and `WANT_INHIBIT="yes"` when you added inhibit rules, then test-fire one alert per new route.

### Test-fire receivers

Proves a receiver actually delivers. This pages real humans: tell your on-call before firing at a pager receiver, and announce each test-fire as its own change.

Alertmanager replicas share silences and the notification log, not alerts. On an HA Alertmanager (cluster `ready` with more than one peer), a POST through one load-balanced URL reaches one replica, and the verify and resolve calls can land on another. Send all three to every replica: list the pods, port-forward each in its own terminal on its own local port, and put every forwarded address in `ALERTMANAGER_URLS`:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
MON_NS="monitoring"                # kubernetes.monitoring_namespace
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get pods -l 'app.kubernetes.io/name in (alertmanager,vmalertmanager)' -o name
# Per pod, in its own terminal: kubectl --context <context> -n <namespace> port-forward <pod> 19093:9093 (19094 for the next pod, ...)
# then ALERTMANAGER_URLS="http://127.0.0.1:19093 http://127.0.0.1:19094" in the three blocks below.
```

Fire:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
ALERTMANAGER_URLS="https://alertmanager.example.com"   # prometheus.alertmanager_url; on HA, every replica's forwarded address
TEST_SEVERITY="critical"                               # the route under test
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
AM_TOKEN="${PROM_TOKEN:-}"   # the variable prometheus.token_env names; empty for an open endpoint
AUTH="Authorization: Bearer ${AM_TOKEN}"; [ -n "$AM_TOKEN" ] || AUTH="Accept: application/json"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# macOS (BSD) date, then GNU date fallback:
END="$(date -u -v+10M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+10 minutes' +%Y-%m-%dT%H:%M:%SZ)"

for AM_URL in $ALERTMANAGER_URLS; do
  curl -fsS --max-time 10 -X POST "${AM_URL}/api/v2/alerts" -H "$AUTH" \
    -H 'Content-Type: application/json' \
    -d "[{\"labels\":{\"alertname\":\"ToolkitReceiverTest\",\"severity\":\"${TEST_SEVERITY}\",\"service\":\"receiver-test\"},
         \"annotations\":{\"summary\":\"Controlled receiver test from setup-lgtm. Safe to acknowledge.\"},
         \"startsAt\":\"${NOW}\",\"endsAt\":\"${END}\"}]"
  echo "posted to ${AM_URL}"
done
```

Verify, in order:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
ALERTMANAGER_URLS="https://alertmanager.example.com"   # the same addresses the fire block used
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
AM_TOKEN="${PROM_TOKEN:-}"   # the variable prometheus.token_env names; empty for an open endpoint
AUTH="Authorization: Bearer ${AM_TOKEN}"; [ -n "$AM_TOKEN" ] || AUTH="Accept: application/json"

for AM_URL in $ALERTMANAGER_URLS; do
  BODY="$(curl -fsS --max-time 10 -H "$AUTH" -G "${AM_URL}/api/v2/alerts" \
    --data-urlencode 'filter=alertname="ToolkitReceiverTest"')" || { echo "alert read failed at ${AM_URL}" >&2; exit 1; }
  printf '%s' "$BODY" | jq -e 'length > 0 and all(.[]; .status.state == "active")' >/dev/null \
    || { echo "test alert is not active at ${AM_URL}: $(printf '%s' "$BODY" | jq -c '[.[].status.state]')" >&2; exit 1; }
  echo "active at ${AM_URL}"
done
```

Expected: `active at` each address. Then confirm with a human that the message arrived at the receiver (channel message, page, email). Delivery is proven by receipt, not by the POST succeeding. If nothing arrives, read the Alertmanager pod logs for `notify` errors; the failure shapes are in [references/alerting.md](references/alerting.md).

Rollback (also run this after a successful test):

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
ALERTMANAGER_URLS="https://alertmanager.example.com"   # the same addresses the fire block used
TEST_SEVERITY="critical"                               # the route under test
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
AM_TOKEN="${PROM_TOKEN:-}"   # the variable prometheus.token_env names; empty for an open endpoint
AUTH="Authorization: Bearer ${AM_TOKEN}"; [ -n "$AM_TOKEN" ] || AUTH="Accept: application/json"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for AM_URL in $ALERTMANAGER_URLS; do
  curl -fsS --max-time 10 -X POST "${AM_URL}/api/v2/alerts" -H "$AUTH" \
    -H 'Content-Type: application/json' \
    -d "[{\"labels\":{\"alertname\":\"ToolkitReceiverTest\",\"severity\":\"${TEST_SEVERITY}\",\"service\":\"receiver-test\"},
         \"startsAt\":\"${NOW}\",\"endsAt\":\"${NOW}\"}]"
  # Read back: a resolved alert drops out of the alerts list.
  BODY="$(curl -fsS --max-time 10 -H "$AUTH" -G "${AM_URL}/api/v2/alerts" \
    --data-urlencode 'filter=alertname="ToolkitReceiverTest"')" || { echo "alert read failed at ${AM_URL}" >&2; exit 1; }
  printf '%s' "$BODY" | jq -e 'length == 0' >/dev/null \
    || { echo "test alert still active at ${AM_URL}: your clock may run ahead of the Alertmanager's; the original endsAt resolves it within 10 minutes" >&2; exit 1; }
  echo "resolved at ${AM_URL}"
done
```

Expected: `resolved at` each address. The `endsAt` of now resolves the alert immediately; the original `endsAt` bounds it even if you forget.

### Quiet noisy rules

For findings about rules firing on non-issues: missing `for` durations, completed Jobs paging as unready pods, dev namespaces paging production receivers.

1. Find the rule's source CR or rule file, back it up, and announce the exact edit (add `for`, tighten the `expr`, or delete the rule block). Patterns per rule engine are in [references/alerting.md](references/alerting.md). The same blocks fix the expression an LGTM-004 `lastError` names, or add a missing datastore rule (LGTM-080 to LGTM-082) to the rule CR of the evaluator that can see the series.
2. Apply through the owner.
3. Verify against the live rule API, not the file:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
RULES_URL="https://prometheus.example.com"   # the evaluator holding the rule: prometheus.url, victoriametrics.vmalert_url, or mimir.url + "/prometheus"
RULE_NAME="KubePodNotReady"                  # the rule you changed
WANT_FOR="600"                               # the announced `for` in seconds (600 = 10m); "any" for an expression fix or added rule; "absent" after a deletion
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
RULES_TOKEN="${PROM_TOKEN:-}"   # the variable that evaluator's token_env names; empty for an open endpoint
AUTH="Authorization: Bearer ${RULES_TOKEN}"; [ -n "$RULES_TOKEN" ] || AUTH="Accept: application/json"

BODY="$(curl -fsS --max-time 10 -H "$AUTH" "${RULES_URL}/api/v1/rules")" || { echo "rules API unreachable or unauthorized at ${RULES_URL}" >&2; exit 1; }
printf '%s' "$BODY" | jq -r --arg n "$RULE_NAME" '.data.groups[].rules[] | select(.name == $n) | "\(.name) for=\(.duration // "-")s health=\(.health) state=\(.state // "-")"'
printf '%s' "$BODY" | jq -e --arg n "$RULE_NAME" --arg want "$WANT_FOR" '[.data.groups[].rules[] | select(.name == $n)] as $r
  | if $want == "absent" then ($r | length == 0)
    elif $want == "any" then ($r | length > 0 and all(.[]; .health == "ok"))
    else ($r | length > 0 and all(.[]; .duration == ($want | tonumber) and .health == "ok")) end' >/dev/null \
  || { echo "${RULE_NAME} does not match WANT_FOR=${WANT_FOR}; see the rule line above (a changed rule shows health ok after one evaluation interval)" >&2; exit 1; }
echo "VERIFIED: ${RULE_NAME} (${WANT_FOR})"
```

Expected: the rule line with the new `for` and `health=ok`, then `VERIFIED`.

Rollback: run the rule rollback block in [references/alerting.md](references/alerting.md#quiet-noisy-rules-per-rule-engine), which restores the backed-up CR, or `helm rollback` to the recorded revision. Never `kubectl apply` the raw backup: its stale resourceVersion conflicts with the changed rule.

Deleting a rule removes a detection path. Confirm rule deletions individually, never inside a batch approval.

### Standardize service labels

For correlation findings where the same service carries different names across metrics, logs, and traces. Fix at the collection layer so every signal derives the label the same way; relabel, pipeline, and OTel payloads are in [references/hardening.md](references/hardening.md).

1. Announce the canonical label plan: one `service` value per service, sourced from one pod label (for example `app.kubernetes.io/name`), and which collectors change.
2. Apply the relabel or processor change per collector, through its owner, one collector at a time.
3. Verify parity live after each apply (allow one scrape/flush interval):

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
METRICS_URL="https://prometheus.example.com"   # prometheus.url (or victoriametrics.url, or mimir.url + "/prometheus")
LOKI_URL="https://loki.example.com"            # loki.url
WINDOW_MINUTES="15"                            # only names seen this recently count; example, tune to your traffic
WORK_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm/setup-$(date -u +%F)"
mkdir -p "$WORK_DIR"
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
MET_TOKEN="${PROM_TOKEN:-}"   # the variable the metrics block's token_env names; empty for an open endpoint
LOG_TOKEN="${LOKI_TOKEN:-}"   # the variable loki.token_env names; empty for an open endpoint
MAUTH="Authorization: Bearer ${MET_TOKEN}"; [ -n "$MET_TOKEN" ] || MAUTH="Accept: application/json"
LAUTH="Authorization: Bearer ${LOG_TOKEN}"; [ -n "$LOG_TOKEN" ] || LAUTH="Accept: application/json"
# Recent names only: renamed series keep their old value in the store until retention drops them.
# macOS (BSD) date, then GNU date fallback:
SINCE="$(date -u -v-"${WINDOW_MINUTES}"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "-${WINDOW_MINUTES} minutes" +%Y-%m-%dT%H:%M:%SZ)"

MET_BODY="$(curl -fsS --max-time 10 -H "$MAUTH" -G "${METRICS_URL}/api/v1/label/service/values" --data-urlencode "start=${SINCE}")" \
  || { echo "metrics label read failed at ${METRICS_URL}" >&2; exit 1; }
LOG_BODY="$(curl -fsS --max-time 10 -H "$LAUTH" -G "${LOKI_URL}/loki/api/v1/label/service/values" --data-urlencode "start=${SINCE}")" \
  || { echo "log label read failed at ${LOKI_URL}" >&2; exit 1; }
printf '%s' "$MET_BODY" | jq -r '.data[]' | LC_ALL=C sort > "${WORK_DIR}/metrics-services.txt"
printf '%s' "$LOG_BODY" | jq -r '.data[]' | LC_ALL=C sort > "${WORK_DIR}/logs-services.txt"
# Two empty lists compare equal and prove nothing.
[ -s "${WORK_DIR}/metrics-services.txt" ] && [ -s "${WORK_DIR}/logs-services.txt" ] \
  || { echo "a service list is empty: check the label name and that both stores hold recent data" >&2; exit 1; }
DIFF="$(LC_ALL=C comm -3 "${WORK_DIR}/metrics-services.txt" "${WORK_DIR}/logs-services.txt")"
[ -z "$DIFF" ] || { echo "names still differ (first column metrics only, indented logs only):"; printf '%s\n' "$DIFF"; exit 1; }
echo "ALIGNED: $(wc -l < "${WORK_DIR}/metrics-services.txt" | tr -d ' ') service names match across metrics and logs"
```

Expected: `ALIGNED`. The VictoriaLogs and Tempo versions of this check are in the reference.

Renaming a label breaks every dashboard query and alert `expr` that used the old name, and starts new series. Update the affected rules and dashboards in the same announced change, and re-run the audit's correlation check afterward. `service.name` set inside application SDKs is an application change: record it as pending with the owning team named.

Rollback: revert the collector change through its owner. For Helm, `helm rollback` to the recorded revision. For a CR or ConfigMap, back it up first with the CR backup block in [references/alerting.md](references/alerting.md#operator-cr-path) and restore it with the rule rollback block in [references/alerting.md](references/alerting.md#quiet-noisy-rules-per-rule-engine), `KIND` and `NAME` set to the object. Old label values return on the next scrape.

### Set retention

For findings about missing or unbounded retention. Retention values are examples, tune to your compliance and cost targets:

```bash
RETENTION="30d"   # example, tune to your environment
```

Per-backend flags, values paths, and verification reads (Prometheus `/api/v1/status/flags`, VictoriaMetrics `/flags`, Loki `/config`, Tempo compactor) are in [references/hardening.md](references/hardening.md).

Reducing retention deletes data, sometimes within minutes of the component restarting. Announce a reduction as its own change with the data loss stated, never inside a batch.

Rollback: restore the previous value the same way; deleted data does not come back.

### Enable HA

For findings about single-replica Alertmanager or single-node metrics storage. Replica counts are examples, tune to your environment. Payloads per component are in [references/hardening.md](references/hardening.md).

Verify Alertmanager clustering and node spread after the change:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"                      # kubernetes.context
MON_NS="monitoring"                                   # kubernetes.monitoring_namespace
ALERTMANAGER_URL="https://alertmanager.example.com"   # prometheus.alertmanager_url
WANT_REPLICAS="2"                                     # the replica count you announced; example, tune to your environment
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
AM_TOKEN="${PROM_TOKEN:-}"   # the variable prometheus.token_env names; empty for an open endpoint
AUTH="Authorization: Bearer ${AM_TOKEN}"; [ -n "$AM_TOKEN" ] || AUTH="Accept: application/json"

BODY="$(curl -fsS --max-time 10 -H "$AUTH" "${ALERTMANAGER_URL}/api/v2/status")" || { echo "Alertmanager unreachable or unauthorized at ${ALERTMANAGER_URL}" >&2; exit 1; }
printf '%s' "$BODY" | jq -e --argjson n "$WANT_REPLICAS" '.cluster.status == "ready" and (.cluster.peers | length) == $n' >/dev/null \
  || { echo "cluster is $(printf '%s' "$BODY" | jq -r '"\(.cluster.status) with \(.cluster.peers // [] | length) peer(s)"'), expected ready with ${WANT_REPLICAS}" >&2; exit 1; }
NODES="$(kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get pods -l 'app.kubernetes.io/name in (alertmanager,vmalertmanager)' \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | grep -c . || true)"
[ "$NODES" -ge 2 ] || { echo "the replicas share one node: a node failure still takes alerting down" >&2; exit 1; }
echo "VERIFIED: ready with ${WANT_REPLICAS} peers on ${NODES} nodes"
```

Expected: `VERIFIED`. For metrics storage, adding replication multiplies disk usage and may require query-side deduplication; the reference states the checks per backend. Rollback: restore the previous replica or replication values and verify the same reads.

### Lock down exposure

For findings where a metrics, logs, traces, or Alertmanager endpoint is publicly reachable without auth.

1. Enumerate exposure and quote it in the announcement:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
MON_NS="monitoring"                # kubernetes.monitoring_namespace

kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get ingress -o json \
  | jq -r '.items[] | "\(.metadata.name) hosts=\([.spec.rules[].host] | join(","))"'
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get svc -o json \
  | jq -r '.items[] | select(.spec.type=="LoadBalancer" or .spec.type=="NodePort") | "\(.metadata.name) \(.spec.type)"'
```

2. Prove it live before and after, unauthenticated on purpose, at an API path: `/` proves nothing, since Prometheus redirects it and Loki or Tempo can answer 404 there while their APIs are open.

```bash
set -eu
INGRESS_HOST="alertmanager.example.com"   # the exposed host from step 1
PROBE_PATH="/api/v2/status"               # Alertmanager; Prometheus or VictoriaMetrics /api/v1/status/buildinfo; Mimir /prometheus/api/v1/status/buildinfo; Loki /loki/api/v1/labels; Tempo /api/echo
CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://${INGRESS_HOST}${PROBE_PATH}" || true)"
case "$CODE" in
  200) echo "EXPOSED: https://${INGRESS_HOST}${PROBE_PATH} answers 200 without credentials"; exit 1 ;;
  302|401|403|404|000) echo "CLOSED: ${CODE} without credentials (000 is a timeout or no route)" ;;
  *) echo "UNEXPECTED: ${CODE}; read the response before deciding" >&2; exit 1 ;;
esac
```

Before the fix, `EXPOSED` reproduces the finding. After it, `CLOSED`: a `302` to a login page, `401`, `403`, `404`, or a timeout, from the same machine that saw `EXPOSED`.

3. Fix by deleting the ingress, adding an auth layer, or converting the Service to ClusterIP; options with rollbacks are in [references/hardening.md](references/hardening.md). Back up the object first; each option's rollback block restores from that backup.

Removing an ingress your team actually uses locks them out too. Confirm who consumes the endpoint before deleting, and name the internal access path they switch to.

### Add network policies

For findings about missing NetworkPolicies in the monitoring namespace. A pod is isolated the moment any policy selects it, and the allow policy selects every pod in the namespace, so applying it is the breaking change, not the deny. Order is load-bearing; the blocks are in [references/hardening.md](references/hardening.md#networkpolicies):

1. Save the baseline `up` count before any policy exists.
2. Announce the allow policy with every inbound path your stack needs: traffic inside the namespace, Grafana and other query clients in other namespaces, workloads pushing logs, traces, OTLP, or remote-write, your ingress controller, and any operator webhook the API server calls.
3. Apply it, and compare the `up` count with the baseline before anything else runs.
4. Only then apply default-deny. While the allow policy selects every pod it changes nothing; it keeps the namespace closed if the allow policy is later narrowed or removed. Compare the count again, then prove enforcement with a probe at a port the allow policy does not open.

- ❌ `LGTM-064 fixed: kubectl get networkpolicy lists default-deny-ingress.`
- ✅ `LGTM-064 fixed: the probe from default to a port the allow policy does not open timed out (exit 28), and the up count matched the saved baseline.`

Rollback: the NetworkPolicy rollback block in [references/hardening.md](references/hardening.md#networkpolicies), which removes the deny policy first.

### Add disruption budgets

For findings about missing PDBs on monitoring components. Only add a PDB where replicas are 2 or more; a PDB on a single replica blocks node drains. Manifest in [references/hardening.md](references/hardening.md).

Verify, once per new PDB:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
MON_NS="monitoring"                # kubernetes.monitoring_namespace
PDB_NAME="alertmanager"            # the PDB you created

ALLOWED="$(kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get pdb "$PDB_NAME" -o jsonpath='{.status.disruptionsAllowed}')"
echo "${PDB_NAME}: disruptionsAllowed=${ALLOWED:-not yet computed}"
[ "${ALLOWED:-0}" -ge 1 ] || { echo "the budget allows no disruption, so node drains hang: fix the replica count or delete the PDB" >&2; exit 1; }
```

Expected: `disruptionsAllowed` of 1 or more. `0` means the PDB is blocking maintenance; fix the replica count or delete the PDB. Right after creation the status can lag a few seconds; re-run before deciding.

Rollback, in its own fresh shell (one PDB per run):

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
MON_NS="monitoring"                # kubernetes.monitoring_namespace
PDB_NAME="<pdb-created-above>"     # one PDB this setup created
case "$PDB_NAME" in ''|'<'*) echo "Set PDB_NAME to a PDB this setup created" >&2; exit 1 ;; esac
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" delete pdb "$PDB_NAME"
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get pdb "$PDB_NAME" 2>&1 | tail -1
```

Expected: `NotFound`.

## Record and wrap up

Append one entry per executed change to `${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm/changes.md`:

```markdown
## <UTC timestamp> | <finding IDs>
- Change: <object and what changed>
- Command: <exact command or values diff applied>
- Verified: <the read-back command and the value it showed>
- Backup: <the exact file the backup step printed, or the Helm revision it recorded>
- Rollback: <the rollback block and the values it needs>
- Pending: <item> (owner: <team or person>)
```

End the run with:

1. A summary table: finding ID, change, verification result, remaining risk.
2. The pending list for items outside this skill's reach (application instrumentation, SDK `service.name`, Git-owned config awaiting merge), each with a named owner.
3. A fresh `/scoutflo:audit-lgtm` run to re-score; its delta shows which findings moved to fixed. If routing changed, `audit-alertmanager` proves the paging path end to end.

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Helm-, operator-, or GitOps-owned object edited directly, reverted at next sync | Discover the owner first; change at the owner level and verify live after sync |
| Change applied to the wrong cluster | Run the live-safety gate, which stops when the pinned values differ from `toolkit.yaml`; pin `--context` on every kubectl command |
| Allow policy that selects every pod applied with a path missing: Grafana, pushes, or webhooks cut off | List every inbound path before applying; compare the `up` count with the saved baseline after each policy |
| Test alert posted through a load-balanced URL reaches one HA replica | Fire, verify, and resolve on every replica's address |
| Second backup of the same object overwrites the first change's pre-change copy | Backup blocks refuse an existing file; announce same-object changes as one row |
| Test alert without `endsAt` keeps re-notifying | Set `endsAt` on every test-fire and post an explicit resolve after the test |
| Receiver marked fixed without delivery proof | End every receiver change with a test-fire and a human confirming receipt |
| Pager receiver test-fired without warning | Tell your on-call before firing at any paging receiver |
| Retention reduced and data expired immediately | Treat reductions as destructive; announce the data loss and confirm individually |
| PDB on a single-replica component blocks node drains | Add PDBs only where replicas are 2 or more; assert `disruptionsAllowed` of 1 or more after |
| Service label renamed, dashboards and alert exprs break | Update rules and dashboards in the same change; re-run the label parity check |
| Alertmanager config written but never picked up | Verify by re-reading `.config.original` from the API, not the Secret or file |
| Noisy rule deleted inside a batch, detection path lost | Confirm every rule deletion individually with the rule body quoted |
