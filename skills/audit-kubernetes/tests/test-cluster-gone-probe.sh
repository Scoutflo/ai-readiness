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
#      read as a missing CLUSTER;
#   5. a context split on `_` asking about the wrong name and getting a truthful
#      not-found.
# Each fix was a tighter pattern and each was defeated by another wording. Error
# prose is not an API. The branch now asks the control plane for its LIST of clusters
# and does an exact whole-line match, so absence is a structured fact rather than a
# string guess, and every name-collision case dies by construction.
#
# THE REWRITE WAS NOT THE END OF IT. A maintainer rubric review then defeated the
# list twice more — not its matching, but its AUTHORITY, which is the part a
# structured call does not establish for free:
#   6. gcloud exits 0 with a knowingly INCOMPLETE list when a zone does not answer
#      (`list.py`: warns "The following zones did not respond ... List results may
#      be incomplete" on stderr, status 0). The branch sent stderr to /dev/null, so
#      a live cluster in that zone was simply absent from a "successful" list.
#   7. `aws eks list-clusters` ran under the shell's AMBIENT credentials, not the
#      kubeconfig context's. `aws eks update-kubeconfig` writes the profile into
#      exec.env (AWS_PROFILE); a multi-account kubeconfig therefore asked the wrong
#      account whether this cluster exists, and got a truthful no.
# Absence is evidence only when the list is BOTH complete AND answered by the account
# that owns the cluster. Tests 10 and 11 hold that line.
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
grep -q 'did not respond' "$WORK/branch-body.sh" || fail "extracted branch does not reject an incomplete (partial-zone) list"
grep -q 'get-caller-identity' "$WORK/branch-body.sh" || fail "extracted branch does not prove which AWS account answered the list"

{ echo '#!/bin/sh'
  echo 'KUBE_CONTEXT="$1"; EXEC_CMD="$2"'
  cat "$WORK/branch-body.sh"
  echo 'if [ -n "${GONE:-}" ]; then echo GONE; else echo UNKNOWN; fi'
} > "$WORK/probe.sh"
sh -n "$WORK/probe.sh" || fail "extracted branch is not valid POSIX sh"

# Stand-in CLIs. The list call answers with STUB_OUT / STUB_ERR / STUB_RC. `aws sts
# get-caller-identity` is a separate call with its own knobs, because the EKS branch
# must prove WHICH ACCOUNT is answering before absence counts: STUB_ACCT (default
# 1234, the account in $EKS) and STUB_STS_RC. The stub also records the AWS_PROFILE
# it was invoked with, so Test 11 can prove the context's profile is really used.
mkcli() {
  cat > "$WORK/bin/$1" <<STUB
#!/bin/sh
case "\$*" in
  *get-caller-identity*)
    printf '%s\n' "\${AWS_PROFILE:-<none>}" >> "$WORK/profile.log"
    [ "\${STUB_STS_RC:-0}" -eq 0 ] && printf '%s\n' "\${STUB_ACCT-1234}"
    exit \${STUB_STS_RC:-0} ;;
esac
[ -n "\${STUB_OUT:-}" ] && printf '%s\n' "\$STUB_OUT"
[ -n "\${STUB_ERR:-}" ] && printf '%s\n' "\$STUB_ERR" >&2
exit \${STUB_RC:-0}
STUB
  chmod +x "$WORK/bin/$1"
}
mkcli gcloud; mkcli aws
# kubectl is read locally (kubeconfig only, no cluster call): hand back STUB_PROFILE.
cat > "$WORK/bin/kubectl" <<'KSTUB'
#!/bin/sh
printf '%s' "${STUB_PROFILE:-}"
KSTUB
chmod +x "$WORK/bin/kubectl"
: > "$WORK/profile.log"

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
[ "$(v "$GKE" gke-gcloud-auth-plugin 'live' 'WARNING: API deprecated' 0)" = "UNKNOWN" ] || fail "a benign stderr warning on a successful list flipped the verdict"
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
  cat > "$WORK/bin/$c" <<LOG
#!/bin/sh
printf '%s %s\n' "$c" "\$*" >> "$WORK/argv.log"
case "\$*" in *get-caller-identity*) echo 1234; exit 0 ;; esac
exit 1
LOG
  chmod +x "$WORK/bin/$c"
done
v "$GKE" gke-gcloud-auth-plugin >/dev/null
v "$EKS" aws >/dev/null
v "renamed-by-user" gke-gcloud-auth-plugin >/dev/null
v "my-eks-alias" aws >/dev/null
grep -qE -- '--project +(--|$)|--region +(--|$)' "$WORK/argv.log" \
  && fail "a cloud CLI was invoked with an empty target flag: $(cat "$WORK/argv.log")"
# 3 = the GKE list, plus the EKS identity proof and its list. The two malformed
# contexts must contribute nothing.
[ "$(grep -c . "$WORK/argv.log")" -eq 3 ] \
  || fail "expected exactly 3 cloud calls (GKE list; EKS sts + list), got: $(cat "$WORK/argv.log")"
# Listing per project covers zonal AND regional clusters, so pinning a location
# would reintroduce the zonal/regional mismatch class.
grep -q -- '--location' "$WORK/argv.log" \
  && fail "the list call pins a location, which reintroduces the zonal/regional mismatch class"
mkcli gcloud; mkcli aws
echo "PASS"

echo "Test 10: an INCOMPLETE list cannot prove absence (gcloud exits 0 on a dead zone)"
# gcloud warns on stderr and still exits 0; the cluster it cannot see is simply
# missing from the output. Absence stops being evidence.
for w in \
  'WARNING: The following zones did not respond: us-central1-b. List results may be incomplete.' \
  'WARNING: The following zones did not respond: europe-west1-c, us-east1-d.' \
  'WARNING: List results may be incomplete.'
do
  [ "$(v "$GKE" gke-gcloud-auth-plugin 'other-a' "$w" 0)" = "UNKNOWN" ] \
    || fail "a knowingly incomplete list produced a gone verdict for: '$w'"
done
# A benign warning must still allow one, or the probe becomes useless in practice.
[ "$(v "$GKE" gke-gcloud-auth-plugin 'other-a' 'WARNING: gcloud update available' 0)" = "GONE" ] \
  || fail "a benign warning suppressed a legitimate target-gone verdict"
echo "PASS"

echo "Test 11: only the cluster's OWN account may answer for it"
# $EKS is owned by account 1234. A list answered by any other account omits the
# cluster for a reason that has nothing to do with deletion.
[ "$(STUB_ACCT=9999 v "$EKS" aws 'staging' '' 0)" = "UNKNOWN" ] \
  || fail "a list answered by a DIFFERENT AWS account produced a gone verdict"
[ "$(STUB_STS_RC=1 v "$EKS" aws 'staging' '' 0)" = "UNKNOWN" ] \
  || fail "an unreadable caller identity produced a gone verdict"
[ "$(STUB_ACCT='' v "$EKS" aws 'staging' '' 0)" = "UNKNOWN" ] \
  || fail "an empty caller identity produced a gone verdict"
[ "$(STUB_ACCT=1234 v "$EKS" aws 'staging' '' 0)" = "GONE" ] \
  || fail "the owning account's own list omitting the cluster did not register as target-gone"
# ...and the identity must be proven under the CONTEXT's profile, not the shell's.
: > "$WORK/profile.log"
STUB_PROFILE=prod-eks STUB_ACCT=1234 v "$EKS" aws 'staging' '' 0 >/dev/null
grep -qx 'prod-eks' "$WORK/profile.log" \
  || fail "the identity check ignored the kubeconfig context's AWS_PROFILE (saw: $(cat "$WORK/profile.log"))"
echo "PASS"

echo
echo "=== cluster-gone probe tests passed ==="
