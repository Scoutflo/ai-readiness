#!/bin/sh
# cluster-triage.sh — read-only triage of the kube contexts in $KUBECONFIG (or the default
# ~/.kube/config): which contexts are LIVE, which are UNREACHABLE (and why), and which are
# DUPLICATES of the same cluster (same API-server URL). A big kubeconfig — dozens of contexts,
# some deleted/dead, some pointing at the same cluster — is reduced to the live, distinct
# clusters BEFORE you configure an audit, so a dead or duplicate context never becomes a target.
#
#   Usage:
#     sh cluster-triage.sh          # print a table + a one-line summary
#     sh cluster-triage.sh --live   # print ONLY the live, distinct context names (one per line)
#
# Read-only: only `kubectl config` reads + ONE bounded read per distinct server
# (`kubectl auth can-i get pods`, the same reachability check /scoutflo:doctor uses — "yes"/"no"
# both mean reachable; a context/network error means unreachable). Nothing is created or changed.
# Never prints a token; the API-server URL is redacted to host:port only. Every probe is bounded
# by --request-timeout so a dead context cannot hang the sweep.
set -eu

command -v kubectl >/dev/null 2>&1 || { echo "cluster-triage: kubectl not found — install it or skip Kubernetes" >&2; exit 2; }

ONLY_LIVE=0
case "${1:-}" in
  --live) ONLY_LIVE=1 ;;
  -h|--help) echo "usage: sh cluster-triage.sh [--live]"; exit 0 ;;
  "") : ;;
  *) echo "cluster-triage: unknown arg '$1' (use --live or no arg)" >&2; exit 2 ;;
esac

TIMEOUT="${CLUSTER_TRIAGE_TIMEOUT:-5s}"   # bounded per-context probe; tune for a slow network

CTXS="$(kubectl config get-contexts -o name 2>/dev/null || true)"
[ -n "$CTXS" ] || { [ "$ONLY_LIVE" -eq 1 ] || echo "cluster-triage: no kube contexts found (empty kubeconfig)"; exit 0; }

MAP="$(mktemp)"; SEEN="$(mktemp)"; OUT="$(mktemp)"; ERRF="$(mktemp)"
trap 'rm -f "$MAP" "$SEEN" "$OUT" "$ERRF"' EXIT

# Resolve each context's cluster API-server URL (the dedup key), read-only.
for c in $CTXS; do
  cl="$(kubectl config view -o "jsonpath={.contexts[?(@.name=='$c')].context.cluster}" 2>/dev/null || true)"
  srv=""
  [ -n "$cl" ] && srv="$(kubectl config view -o "jsonpath={.clusters[?(@.name=='$cl')].cluster.server}" 2>/dev/null || true)"
  printf '%s\t%s\n' "$c" "$srv" >> "$MAP"
done

LIVE=0; DUPE=0; DEAD=0; TOTAL=0
while IFS='	' read -r ctx srv; do
  TOTAL=$((TOTAL + 1))
  host="$(printf '%s' "$srv" | sed -E 's#^https?://##; s#/.*$##')"   # redact to host:port
  if [ -z "$srv" ]; then
    printf '%s\t%s\t%s\n' "$ctx" "(no server)" "unreachable:no-cluster-server-in-kubeconfig" >> "$OUT"; DEAD=$((DEAD + 1)); continue
  fi
  # duplicate? same server URL already claimed by an earlier context
  prev="$(awk -F'\t' -v s="$srv" '$2==s{print $1; exit}' "$SEEN")"
  if [ -n "$prev" ]; then
    printf '%s\t%s\t%s\n' "$ctx" "$host" "duplicate-of:$prev" >> "$OUT"; DUPE=$((DUPE + 1)); continue
  fi
  printf '%s\t%s\n' "$ctx" "$srv" >> "$SEEN"
  # bounded, read-only reachability probe (yes/no = reachable; error = unreachable)
  ans="$(kubectl --context "$ctx" --request-timeout="$TIMEOUT" auth can-i get pods 2>"$ERRF" || true)"
  case "$ans" in
    yes|no)
      printf '%s\t%s\t%s\n' "$ctx" "$host" "live" >> "$OUT"; LIVE=$((LIVE + 1)) ;;
    *)
      err="$(tr '\n' ' ' < "$ERRF" | head -c 200)"
      reason="unreachable"
      case "$err" in
        *"no such host"*|*"dial tcp"*|*"i/o timeout"*|*"connection refused"*|*"deadline exceeded"*) reason="unreachable:network — run from inside the VNet, add your IP to the API-server authorized ranges, or open a tunnel/JIT session" ;;
        *exec*|*credential*|*token*|*Unauthorized*|*oauth2*|*"getting credentials"*) reason="unreachable:reauth — gcloud auth login / aws sso login / az login (exec-plugin credential expired)" ;;
      esac
      printf '%s\t%s\t%s\n' "$ctx" "$host" "$reason" >> "$OUT"; DEAD=$((DEAD + 1)) ;;
  esac
done < "$MAP"

if [ "$ONLY_LIVE" -eq 1 ]; then
  awk -F'\t' '$3=="live"{print $1}' "$OUT"
  exit 0
fi

printf '%-42s  %-30s  %s\n' "CONTEXT" "SERVER (host)" "STATUS"
while IFS='	' read -r ctx host status; do
  printf '%-42s  %-30s  %s\n' "$ctx" "$host" "$status"
done < "$OUT"
echo ""
echo "cluster-triage: ${TOTAL} contexts -> ${LIVE} live distinct, ${DEAD} unreachable, ${DUPE} duplicate(s). Configure audits against the live, distinct clusters only."
