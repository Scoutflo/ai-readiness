#!/bin/sh
# test-cluster-gone-probe.sh
#
# Guards the "no such host" branch of audit-kubernetes's doctor gate, which
# decides whether an unresolvable API server means the cluster was DELETED
# (`not-in-scope` / `target-gone`, action = fix the config) or is merely PRIVATE
# (`blocked`, posture unknown, action = open a tunnel). Getting that backwards
# sends an operator hunting a network problem for infrastructure that no longer
# exists, or — far worse — declares a LIVE cluster decommissioned.
#
# The probe must FAIL CLOSED: only an answer that is *about this cluster* and
# carries a not-found signature may conclude absence. Every review-round input
# below once produced a false "deleted"; each is now a permanent case.
#
# The branch is extracted from SKILL.md so the test cannot drift from the
# shipped text. Runs under /bin/sh, no network: gcloud/aws are stand-ins.
set -eu
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SKILL="$ROOT/skills/audit-kubernetes/SKILL.md"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
mkdir -p "$WORK/bin"
PATH="$WORK/bin:$PATH"; export PATH

echo "=== audit-kubernetes cluster-gone probe ==="

# --- extract the branch body from the shipped SKILL.md ------------------------
# From the `*"no such host"*)` case label to its terminating `;;` at that depth.
awk '
  /\*"no such host"\*\)/ { inb=1; next }
  inb && /if \[ -n "\$GONE" \]/ { exit }
  inb { print }
' "$SKILL" > "$WORK/branch-body.sh"
[ -s "$WORK/branch-body.sh" ] || fail "could not extract the no-such-host branch from SKILL.md (did the marker change?)"
grep -q 'GONE=' "$WORK/branch-body.sh" || fail "extracted branch does not set GONE — extraction is wrong"

cat > "$WORK/probe.sh" <<'HDR'
#!/bin/sh
KUBE_CONTEXT="$1"; EXEC_CMD="$2"
HDR
cat "$WORK/branch-body.sh" >> "$WORK/probe.sh"
cat >> "$WORK/probe.sh" <<'FTR'
if [ -n "${GONE:-}" ]; then echo "GONE"; else echo "UNKNOWN"; fi
FTR
sh -n "$WORK/probe.sh" || fail "extracted branch is not valid POSIX sh"

stub_gcloud() { printf '#!/bin/sh\nprintf "%%s\\n" "$STUB_ERR" >&2\nexit %s\n' "${2:-1}" > "$WORK/bin/gcloud"; chmod +x "$WORK/bin/gcloud"; }
stub_aws()    { printf '#!/bin/sh\nprintf "%%s\\n" "$STUB_ERR" >&2\nexit %s\n' "${2:-1}" > "$WORK/bin/aws";    chmod +x "$WORK/bin/aws"; }
stub_gcloud; stub_aws

verdict() { STUB_ERR="$2" sh "$WORK/probe.sh" "$1" "$3"; }

# --- the fail-closed matrix (GKE) --------------------------------------------
echo "Test 1: only an answer ABOUT THIS CLUSTER with a not-found signature may say gone"
CTX="gke_myproj_us-central1_live"
# These two are real gcloud plumbing failures. Both contain "was not found" and
# both once produced "the cluster NO LONGER EXISTS" for a cluster that was alive.
for e in \
  "ERROR: (gcloud.container.clusters.describe) command [docker-credential-gcloud] was not found on the PATH; reauthenticate with gcloud auth login" \
  "ResponseError: code=403, message=Required container.clusters.get permission; credential file was not found"
do
  [ "$(verdict "$CTX" "$e" gke-gcloud-auth-plugin)" = "UNKNOWN" ] \
    || fail "a gcloud plumbing error containing 'was not found' was read as a deleted cluster: $e"
done
echo "PASS"

echo "Test 1b: a name appearing in gcloud's OWN error preamble is not a naming match"
# gcloud prefixes every error with "(gcloud.container.clusters.describe)", so a
# bare substring test for the cluster name is satisfied by construction for any
# cluster named after a word in that preamble. 1-char GKE names are legal, so this
# is reachable in practice — it silently reduced the two-condition guard back to
# the single-condition one. The match must be STRUCTURAL (.../clusters/<name>).
PRE='ERROR: (gcloud.container.clusters.describe)'
for n in a b cloud cluster clusters describe found not on; do
  [ "$(verdict "gke_myproj_us-central1_$n" "$PRE command [docker-credential-gcloud] was not found on the PATH" gke-gcloud-auth-plugin)" = "UNKNOWN" ] \
    || fail "a live cluster named '$n' was declared deleted by a plumbing error that merely contains its name"
done
# A 404 about a DIFFERENT cluster is not evidence about this one.
[ "$(verdict "gke_p_eu-west1_a" "$PRE Response: [404] Not found: projects/p/locations/eu-west1/clusters/some-other-cluster." gke-gcloud-auth-plugin)" = "UNKNOWN" ] \
  || fail "a 404 about a different cluster was accepted as proof about this one"
# Nor is a 404 about a cluster whose name merely has this one as a PREFIX.
[ "$(verdict "gke_p_eu-west1_live" "$PRE Response: [404] Not found: projects/p/locations/eu-west1/clusters/live-2." gke-gcloud-auth-plugin)" = "UNKNOWN" ] \
  || fail "a 404 about 'live-2' was accepted as proof that 'live' is gone"
echo "PASS"

echo "Test 2: an inconclusive answer is never 'gone'"
for e in \
  "ERROR: (gcloud) Your credentials have expired" \
  "ERROR: PERMISSION_DENIED on projects/myproj" \
  "ERROR: RESOURCE_EXHAUSTED quota exceeded" \
  "ERROR: no route found to host" \
  ""
do
  [ "$(verdict "$CTX" "$e" gke-gcloud-auth-plugin)" = "UNKNOWN" ] \
    || fail "an inconclusive gcloud failure was read as a deleted cluster: '$e'"
done
# A probe that SUCCEEDS (cluster exists) must also be UNKNOWN, not gone.
stub_gcloud "" 0
[ "$(verdict "$CTX" "" gke-gcloud-auth-plugin)" = "UNKNOWN" ] || fail "a successful describe was read as a deleted cluster"
stub_gcloud
echo "PASS"

echo "Test 3: a genuinely deleted cluster IS detected, in gcloud's real 404 wording"
# gcloud renders a missing cluster as: Response: [404] Not found: projects/.../clusters/<name>.
[ "$(verdict "$CTX" "Response: [404] Not found: projects/myproj/locations/us-central1/clusters/live." gke-gcloud-auth-plugin)" = "GONE" ] \
  || fail "gcloud's real [404] Not found wording did not register as target-gone — the probe would never fire"
echo "PASS"

echo "Test 4: a cluster name containing underscores is parsed whole"
# Splitting the context on '_' asks about 'my' for a cluster called
# 'my_prod_cluster', gets a TRUTHFUL not-found, and reports a LIVE cluster gone.
U="gke_myproj_us-central1_my_prod_cluster"
[ "$(verdict "$U" "Response: [404] Not found: projects/myproj/locations/us-central1/clusters/my_prod_cluster." gke-gcloud-auth-plugin)" = "GONE" ] \
  || fail "an underscored cluster name was not parsed whole (a 404 naming it should be gone)"
[ "$(verdict "$U" "Response: [404] Not found: projects/myproj/locations/us-central1/clusters/my." gke-gcloud-auth-plugin)" = "UNKNOWN" ] \
  || fail "a 404 about a TRUNCATED name was accepted as proof this cluster is gone"
echo "PASS"

echo "Test 5: an incomplete context makes no claim (and no cloud call)"
: > "$WORK/called"
printf '#!/bin/sh\necho called >> "%s"\nexit 1\n' "$WORK/called" > "$WORK/bin/gcloud"; chmod +x "$WORK/bin/gcloud"
for c in "gke_myproj__live" "renamed-by-user" "gke_only_three"; do
  [ "$(verdict "$c" "" gke-gcloud-auth-plugin)" = "UNKNOWN" ] || fail "incomplete context '$c' produced a gone verdict"
done
[ ! -s "$WORK/called" ] || fail "an incomplete context still invoked gcloud (ambient-target risk): $(cat "$WORK/called")"
stub_gcloud
echo "PASS"

# --- EKS -------------------------------------------------------------------
echo "Test 6: EKS follows the same two-part rule"
A="arn:aws:eks:eu-west-1:1234:cluster/prod"
[ "$(verdict "$A" "An error occurred (ResourceNotFoundException) when calling the DescribeCluster operation: No cluster found for name: prod." aws)" = "GONE" ] \
  || fail "a real EKS ResourceNotFoundException naming the cluster was not detected"
[ "$(verdict "$A" "An error occurred (ResourceNotFoundException) when calling the DescribeCluster operation: No cluster found for name: something-else." aws)" = "UNKNOWN" ] \
  || fail "an EKS not-found about a DIFFERENT cluster was accepted as proof about this one"
[ "$(verdict "$A" "An error occurred (ExpiredTokenException) when calling the DescribeCluster operation" aws)" = "UNKNOWN" ] \
  || fail "an expired AWS token was read as a deleted cluster"
[ "$(verdict "my-eks-alias" "" aws)" = "UNKNOWN" ] || fail "a non-ARN EKS context alias produced a gone verdict"
echo "PASS"

echo "Test 7: a missing CLI cannot prove absence"
# Deleting the stubs is NOT enough: `command -v gcloud` would then resolve the
# REAL CLI on a developer machine and the probe would make an authenticated cloud
# call with whatever ambient credentials are loaded — a live API call from a unit
# test, and a profile-guardrail violation. Run with a PATH that cannot resolve
# either CLI instead.
mkdir -p "$WORK/empty"
# A minimal PATH that still resolves the shell but not the cloud CLIs. Verify that
# before using it: if a machine really does ship gcloud/aws in /usr/bin we SKIP
# rather than let the probe make a live authenticated call.
NOCLI_PATH="$WORK/empty:/usr/bin:/bin"
if PATH="$NOCLI_PATH" command -v gcloud >/dev/null 2>&1 || PATH="$NOCLI_PATH" command -v aws >/dev/null 2>&1; then
  echo "SKIP (a cloud CLI is installed in /usr/bin or /bin on this machine, so the"
  echo "      missing-CLI path cannot be exercised without risking a live call)"
else
  verdict_nocli() { PATH="$NOCLI_PATH" STUB_ERR="$2" sh "$WORK/probe.sh" "$1" "$3"; }
  [ "$(verdict_nocli "$CTX" "" gke-gcloud-auth-plugin)" = "UNKNOWN" ] || fail "a missing gcloud produced a gone verdict"
  [ "$(verdict_nocli "$A" "" aws)" = "UNKNOWN" ] || fail "a missing aws produced a gone verdict"
fi
echo "PASS"

echo "Test 8: no cloud CLI is ever invoked with an ambient or empty target"
# Belt-and-braces against the class of bug Test 7 itself had: log every argv and
# assert nothing ran without a fully-populated target.
: > "$WORK/argv.log"
for c in gcloud aws; do
  printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "%s"\nexit 1\n' "$c" "$WORK/argv.log" > "$WORK/bin/$c"
  chmod +x "$WORK/bin/$c"
done
verdict "gke_myproj_us-central1_live" "" gke-gcloud-auth-plugin >/dev/null
verdict "arn:aws:eks:eu-west-1:1234:cluster/prod" "" aws >/dev/null
verdict "renamed-by-user" "" gke-gcloud-auth-plugin >/dev/null
verdict "gke_myproj__live" "" gke-gcloud-auth-plugin >/dev/null
verdict "my-eks-alias" "" aws >/dev/null
grep -qE -- '--project +(--|$)|--location +(--|$)|--name +(--|$)|--region +(--|$)' "$WORK/argv.log" \
  && fail "a cloud CLI was invoked with an empty target flag: $(cat "$WORK/argv.log")"
[ "$(grep -c . "$WORK/argv.log")" -eq 2 ] \
  || fail "expected exactly 2 cloud calls (one per well-formed context), got: $(cat "$WORK/argv.log")"
stub_gcloud; stub_aws
echo "PASS"

echo
echo "=== cluster-gone probe tests passed ==="
