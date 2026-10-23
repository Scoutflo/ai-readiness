#!/bin/sh
# test-cluster-gone-probe.sh
#
# Guards the "no such host" branch of audit-kubernetes's doctor gate, which decides
# whether an unresolvable API server means the cluster was DELETED (`not-in-scope` /
# `target-gone`, action = fix the config) or is merely PRIVATE (`blocked`, posture
# unknown, action = open a tunnel). Getting it backwards either sends an operator
# hunting a network problem for infrastructure that no longer exists, or — far
# worse — tells them a LIVE PRODUCTION CLUSTER is gone and to delete it from their
# config.
#
# HISTORY, because it explains the design. An earlier version decided by
# pattern-matching the cloud CLI's stderr, and went fail-open FOUR times:
#   1. any error containing "was not found" (e.g. "command [docker-credential-gcloud]
#      was not found on the PATH");
#   2. the cluster name colliding with gcloud's own error preamble
#      "(gcloud.container.clusters.describe)" — 1-character names are legal;
#   3. an IAM denial that echoes the resource path AND says "credential file was not
#      found", satisfying two independent conditions at once;
#   4. `Not found: nodePool "default" in .../clusters/<name>` — a missing NODE POOL
#      read as a missing CLUSTER.
# Each fix was a tighter pattern and each was defeated by another wording. Error
# prose is not an API. The branch now asks the control plane for its LIST of clusters
# and does an exact whole-line match, so absence is a structured fact rather than a
# string guess, and every name-collision case dies by construction.
#
# The branch is extracted from SKILL.md so this test cannot drift from the shipped
# text. Runs under /bin/sh. No network: gcloud/aws are stand-ins, and one case
# asserts the suite never invokes a real CLI with an ambient target.
set -eu
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SKILL="$ROOT/skills/audit-kubernetes/SKILL.md"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
mkdir -p "$WORK/bin" "$WORK/empty"
PATH="$WORK/bin:$PATH"; export PATH

echo "=== audit-kubernetes cluster-gone probe ==="

# --- extract the branch body from the shipped SKILL.md ------------------------
awk '
  /\*"no such host"\*\)/ { inb=1; next }
  inb && /if \[ -n "\$GONE" \]/ { exit }
  inb { print }
' "$SKILL" > "$WORK/branch-body.sh"
[ -s "$WORK/branch-body.sh" ] || fail "could not extract the no-such-host branch from SKILL.md (did the marker change?)"
grep -q 'GONE=' "$WORK/branch-body.sh" || fail "extracted branch never sets GONE — extraction is wrong"
grep -q 'clusters list' "$WORK/branch-body.sh" || fail "extracted branch does not use the structured list call"
grep -q 'grep -qxF' "$WORK/branch-body.sh" || fail "extracted branch does not do an exact whole-line match"

{ echo '#!/bin/sh'
  echo 'KUBE_CONTEXT="$1"; EXEC_CMD="$2"'
  cat "$WORK/branch-body.sh"
  echo 'if [ -n "${GONE:-}" ]; then echo GONE; else echo UNKNOWN; fi'
} > "$WORK/probe.sh"
sh -n "$WORK/probe.sh" || fail "extracted branch is not valid POSIX sh"

# Stand-in CLI: STUB_OUT on stdout, STUB_ERR on stderr, STUB_RC as exit status.
mkcli() {
  printf '#!/bin/sh\n[ -n "${STUB_OUT:-}" ] && printf "%%s\\n" "$STUB_OUT"\n[ -n "${STUB_ERR:-}" ] && printf "%%s\\n" "$STUB_ERR" >&2\nexit ${STUB_RC:-0}\n' > "$WORK/bin/$1"
  chmod +x "$WORK/bin/$1"
}
mkcli gcloud; mkcli aws

GKE="gke_myproj_us-central1_live"
EKS="arn:aws:eks:eu-west-1:1234:cluster/prod"
# $1 context, $2 exec-plugin hint, $3 stdout, $4 stderr, $5 rc
v() { STUB_OUT="${3:-}" STUB_ERR="${4:-}" STUB_RC="${5:-0}" sh "$WORK/probe.sh" "$1" "$2"; }

echo "Test 1: a succeeding list that omits the cluster is the ONLY proof of absence"
[ "$(v "$GKE" gke-gcloud-auth-plugin 'other-a
other-b' '' 0)" = "GONE" ] || fail "a successful list omitting the cluster did not register as target-gone"
[ "$(v "$GKE" gke-gcloud-auth-plugin '' '' 0)" = "GONE" ] || fail "a successful list of an empty project did not register as target-gone"
echo "PASS"

echo "Test 2: a cluster present in the list is NOT gone (it is a private endpoint)"
[ "$(v "$GKE" gke-gcloud-auth-plugin 'live
other' '' 0)" = "UNKNOWN" ] || fail "a cluster present in the list was reported deleted"
[ "$(v "$GKE" gke-gcloud-auth-plugin '  live  ' '' 0)" = "UNKNOWN" ] || fail "a padded list entry made a live cluster read as deleted"
[ "$(v "$GKE" gke-gcloud-auth-plugin 'live' 'WARNING: API deprecated' 0)" = "UNKNOWN" ] || fail "a stderr warning on a successful list flipped the verdict"
echo "PASS"

echo "Test 3: name collisions cannot fake presence"
[ "$(v "$GKE" gke-gcloud-auth-plugin 'live-2' '' 0)" = "GONE" ] || fail "'live-2' in the list was accepted as 'live' being present"
[ "$(v "$GKE" gke-gcloud-auth-plugin 'liveness' '' 0)" = "GONE" ] || fail "'liveness' in the list was accepted as 'live' being present"
echo "PASS"

echo "Test 4: NO failure of the list call may ever prove absence"
# The four historical fail-open mechanisms plus the generic failures. Under the
# structured design none can reach a verdict, because the `if` is false.
for e in \
  'ERROR: PERMISSION_DENIED container.clusters.list' \
  'ERROR: (gcloud.container.clusters.list) command [docker-credential-gcloud] was not found on the PATH' \
  'ERROR: PERMISSION_DENIED: Required "container.clusters.list" permission for "projects/myproj/locations/us-central1/clusters/live"; credential file was not found' \
  'ERROR: Not found: nodePool "default" in projects/myproj/locations/us-central1/clusters/live' \
  'ERROR: Response: [404] Not found: projects/myproj/locations/us-central1/clusters/live.' \
  'ERROR: (gcloud) Your credentials have expired' \
  'ERROR: RESOURCE_EXHAUSTED quota exceeded' \
  ''
do
  [ "$(v "$GKE" gke-gcloud-auth-plugin '' "$e" 1)" = "UNKNOWN" ] \
    || fail "a FAILED list call produced a gone verdict for stderr: '$e'"
done
echo "PASS"

echo "Test 5: a cluster name containing underscores is parsed whole"
U="gke_myproj_us-central1_my_prod_cluster"
[ "$(v "$U" gke-gcloud-auth-plugin 'my_prod_cluster' '' 0)" = "UNKNOWN" ] \
  || fail "an underscored cluster name was not parsed whole (it is present in the list)"
[ "$(v "$U" gke-gcloud-auth-plugin 'my' '' 0)" = "GONE" ] \
  || fail "a cluster named 'my' in the list was accepted as 'my_prod_cluster' being present"
echo "PASS"

echo "Test 6: an incomplete or unparseable context makes no claim and no cloud call"
: > "$WORK/called"
printf '#!/bin/sh\necho called >> "%s"\nexit 1\n' "$WORK/called" > "$WORK/bin/gcloud"; chmod +x "$WORK/bin/gcloud"
for c in "gke_only_three" "renamed-by-user"; do
  [ "$(v "$c" gke-gcloud-auth-plugin)" = "UNKNOWN" ] || fail "incomplete context '$c' produced a gone verdict"
done
[ ! -s "$WORK/called" ] || fail "an incomplete context still invoked gcloud (ambient-target risk): $(cat "$WORK/called")"
mkcli gcloud
echo "PASS"

echo "Test 7: EKS follows the same structured rule"
[ "$(v "$EKS" aws 'staging	prod	dev' '' 0)" = "UNKNOWN" ] || fail "a present EKS cluster (tab-separated list) was reported deleted"
[ "$(v "$EKS" aws 'staging	dev' '' 0)" = "GONE" ] || fail "an absent EKS cluster did not register as target-gone"
[ "$(v "$EKS" aws 'prod-2' '' 0)" = "GONE" ] || fail "'prod-2' was accepted as 'prod' being present"
for e in 'AccessDeniedException' 'ExpiredTokenException' 'An error occurred (ResourceNotFoundException): No cluster found for name: prod.' ''; do
  [ "$(v "$EKS" aws '' "$e" 1)" = "UNKNOWN" ] || fail "a FAILED EKS list produced a gone verdict for stderr: '$e'"
done
[ "$(v "my-eks-alias" aws 'prod' '' 0)" = "UNKNOWN" ] || fail "a non-ARN EKS context alias produced a gone verdict"
echo "PASS"

echo "Test 8: a missing CLI cannot prove absence"
# Deleting the stubs is NOT enough: `command -v gcloud` would then resolve the REAL
# CLI and the probe would make an authenticated cloud call with whatever ambient
# credentials are loaded — a live API call from a unit test. Use a PATH that provably
# cannot resolve either CLI, and skip rather than risk it if a machine ships them in
# /usr/bin.
NOCLI_PATH="$WORK/empty:/usr/bin:/bin"
if PATH="$NOCLI_PATH" command -v gcloud >/dev/null 2>&1 || PATH="$NOCLI_PATH" command -v aws >/dev/null 2>&1; then
  echo "SKIP (a cloud CLI is installed in /usr/bin or /bin here, so the missing-CLI"
  echo "      path cannot be exercised without risking a live call)"
else
  [ "$(PATH="$NOCLI_PATH" sh "$WORK/probe.sh" "$GKE" gke-gcloud-auth-plugin)" = "UNKNOWN" ] || fail "a missing gcloud produced a gone verdict"
  [ "$(PATH="$NOCLI_PATH" sh "$WORK/probe.sh" "$EKS" aws)" = "UNKNOWN" ] || fail "a missing aws produced a gone verdict"
fi
echo "PASS"

echo "Test 9: no cloud CLI is invoked with an ambient target, and none pins a location"
: > "$WORK/argv.log"
for c in gcloud aws; do
  printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "%s"\nexit 1\n' "$c" "$WORK/argv.log" > "$WORK/bin/$c"
  chmod +x "$WORK/bin/$c"
done
v "$GKE" gke-gcloud-auth-plugin >/dev/null
v "$EKS" aws >/dev/null
v "renamed-by-user" gke-gcloud-auth-plugin >/dev/null
v "my-eks-alias" aws >/dev/null
grep -qE -- '--project +(--|$)|--region +(--|$)' "$WORK/argv.log" \
  && fail "a cloud CLI was invoked with an empty target flag: $(cat "$WORK/argv.log")"
[ "$(grep -c . "$WORK/argv.log")" -eq 2 ] \
  || fail "expected exactly 2 cloud calls (one per well-formed context), got: $(cat "$WORK/argv.log")"
# Listing per project covers zonal AND regional clusters, so pinning a location
# would reintroduce the zonal/regional mismatch class.
grep -q -- '--location' "$WORK/argv.log" \
  && fail "the list call pins a location, which reintroduces the zonal/regional mismatch class"
mkcli gcloud; mkcli aws
echo "PASS"

echo
echo "=== cluster-gone probe tests passed ==="
