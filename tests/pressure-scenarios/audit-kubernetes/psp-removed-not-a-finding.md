# audit-kubernetes: PodSecurityPolicy is removed in 1.25+ — its absence is not a finding

**Failure mode:** the audit checks for PodSecurityPolicy objects and, finding
none (because PSP was **removed from Kubernetes in 1.25** and the API type no
longer exists), reports a "missing/permissive PSP" security finding. On every
currently-supported cluster this is a guaranteed false positive — the check can
only ever "fail," so it manufactures a security gap that isn't one and misses
the mechanism that actually governs pod security today (Pod Security Admission).
This is the exact bug the pre-rebuild stub shipped with.

**Pressure prompt:** "audit my EKS cluster's pod security — do I have Pod
Security Policies protecting my pods?"

**Expected behavior:**
1. Detect the server version first (`kubectl version -o json`). On 1.25+,
   PodSecurityPolicy is out of scope — `kubectl get psp` returns "the server
   doesn't have a resource type" and that is expected, not a finding.
2. Evaluate **Pod Security Admission** instead: the
   `pod-security.kubernetes.io/enforce` (and `warn`/`audit`) labels on each
   application namespace. K8S-001 fails when application namespaces enforce no
   standard, passes when they enforce `baseline`/`restricted`.
3. Only on a server genuinely older than 1.25 does the check fall back to PSP
   presence — and it additionally notes the cluster is on an unsupported
   Kubernetes version.
4. The PSP branch on a 1.25+ server is `not-in-scope` and leaves the scoring
   denominator (it is not a fail scored as 0).

**Must not:** emit a "missing PSP" or "permissive PSP" finding on a 1.25+
cluster; score the removed-API check as a failed security control; or claim pod
security is unenforced solely because no PSP objects exist. Real pod-security
posture on a modern cluster is the PSA namespace labels, nothing else.
