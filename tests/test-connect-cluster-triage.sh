#!/bin/sh
# IMP-007: cluster-triage.sh reduces a big kubeconfig to live, distinct clusters — flagging
# duplicates (same API-server URL) and unreachable contexts (network vs reauth) — read-only.
# Fully hermetic: a stub `kubectl` on PATH returns canned config + reachability, so every
# branch is deterministic and offline (no real cluster, no network wait).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CT="$ROOT/skills/connect/scripts/cluster-triage.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }
ok() { echo "ok: $1"; }
[ -f "$CT" ] || fail "cluster-triage.sh missing"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# --- stub kubectl: 6 contexts covering every branch -------------------------------------
#   prod    -> server A, auth can-i => yes            => live
#   prod-2  -> server A (same as prod)                => duplicate-of:prod
#   staging -> server B, auth can-i => no (exit 1)    => live (no = reachable)
#   dead-net-> server C, i/o timeout                  => unreachable:network
#   expired -> server D, exec/oauth2 error            => unreachable:reauth
#   nosrv   -> no cluster                             => unreachable:no-cluster-server
mkdir -p "$WORK/bin"
cat > "$WORK/bin/kubectl" <<'STUB'
#!/bin/sh
args="$*"
case "$args" in
  *"config get-contexts"*) printf 'prod\nprod-2\nstaging\ndead-net\nexpired\nnosrv\n'; exit 0 ;;
esac
case "$args" in
  *"config view"*contexts*)
    n=$(printf '%s' "$args" | sed -E "s/.*@\.name=='([^']*)'.*/\1/")
    case "$n" in prod) printf cp;; prod-2) printf cp2;; staging) printf cs;; dead-net) printf cd;; expired) printf ce;; *) printf '';; esac
    exit 0 ;;
  *"config view"*clusters*)
    n=$(printf '%s' "$args" | sed -E "s/.*@\.name=='([^']*)'.*/\1/")
    case "$n" in cp) printf 'https://a.example:6443';; cp2) printf 'https://a.example:6443';; cs) printf 'https://b.example:6443';; cd) printf 'https://c.example:6443';; ce) printf 'https://d.example:6443';; *) printf '';; esac
    exit 0 ;;
esac
case "$args" in
  *"auth can-i"*)
    n=$(printf '%s' "$args" | sed -E 's/.*--context ([^ ]*).*/\1/')
    case "$n" in
      prod) echo yes; exit 0 ;;
      staging) echo no; exit 1 ;;
      dead-net) echo "Unable to connect to the server: dial tcp: i/o timeout" >&2; exit 1 ;;
      expired) echo "error: getting credentials: exec plugin gke-gcloud-auth-plugin failed: oauth2: cannot fetch token" >&2; exit 1 ;;
      *) echo "error: unreachable" >&2; exit 1 ;;
    esac ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/kubectl"

OUT="$(PATH="$WORK/bin:$PATH" CLUSTER_TRIAGE_TIMEOUT=1s sh "$CT" 2>/dev/null)"

printf '%s\n' "$OUT" | grep -qE '^prod .* live$'                  || fail "prod should be live: $OUT"
printf '%s\n' "$OUT" | grep -qE '^prod-2 .* duplicate-of:prod$'   || fail "prod-2 should be duplicate-of:prod"
printf '%s\n' "$OUT" | grep -qE '^staging .* live$'               || fail "staging (auth can-i=no) should be live (reachable)"
printf '%s\n' "$OUT" | grep -qE '^dead-net .* unreachable:network' || fail "dead-net should be unreachable:network"
printf '%s\n' "$OUT" | grep -qE '^expired .* unreachable:reauth'   || fail "expired should be unreachable:reauth"
printf '%s\n' "$OUT" | grep -qE '^nosrv .* unreachable:no-cluster-server' || fail "nosrv should be unreachable:no-cluster-server"
printf '%s\n' "$OUT" | grep -qE '6 contexts -> 2 live distinct, 3 unreachable, 1 duplicate' || fail "summary counts wrong: $(printf '%s' "$OUT" | tail -1)"
# never leaks a scheme/path — server shown as host only
printf '%s\n' "$OUT" | grep -q 'https://' && fail "server URL not redacted to host (leaked scheme)" || :
ok "table: live x2 (yes+no), duplicate x1, unreachable network+reauth+no-server; summary correct; host redacted"

# --live mode = only the live, distinct context names
LIVE="$(PATH="$WORK/bin:$PATH" CLUSTER_TRIAGE_TIMEOUT=1s sh "$CT" --live 2>/dev/null | tr '\n' ',')"
[ "$LIVE" = "prod,staging," ] || fail "--live should print exactly 'prod' and 'staging', got: $LIVE"
ok "--live: prints only the live distinct contexts (prod, staging)"

echo "PASS: connect-cluster-triage (dedup + reachability classification + --live, hermetic)"
