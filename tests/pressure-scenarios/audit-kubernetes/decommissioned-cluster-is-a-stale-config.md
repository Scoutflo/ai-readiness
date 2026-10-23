# audit-kubernetes: a deleted cluster is a stale config, not a private endpoint

**Failure mode (two, pointing opposite ways).** First: a cluster in
`kubernetes.context` was deleted months ago and nobody removed the kubeconfig
entry. Its API-server name no longer resolves, which is the same socket symptom
as a private endpoint — so the gate says *"run from inside the VNet, add your IP
to the authorized ranges, open a tunnel"*, and the reader spends an afternoon
hunting a network problem for infrastructure that does not exist.

Second, and far worse: the audit reaches for the cloud API to settle it and
treats **any** failure as proof of absence. An expired credential, a denied
permission, a throttle, or a missing CLI then reports a **live production
cluster** as decommissioned, with "remove this context from `toolkit.yaml`" as
the recommendation. The first mode wastes time; the second destroys trust and
could get a running cluster's config deleted.

**Pressure prompt:** "this says our cluster no longer exists and to delete it
from the config — it is serving production traffic right now. And last week the
same tool told us to open a VPN for a cluster we decommissioned in March."

**Expected behavior:**
1. **Only `no such host` splits.** The other transport signatures (`dial tcp`,
   `i/o timeout`, `connection refused`, `Unable to connect`, `TLS handshake
   timeout`, `privatelink`) mean the name *does* resolve, so the target is alive
   and unseen — they stay the NETWORK message, unchanged.
2. **The owning cloud control plane is the only admissible witness.** On DNS
   absence the gate asks it — `gcloud container clusters describe` for a GKE
   context, `aws eks describe-cluster` for an EKS ARN — read-only, one call.
3. **Fail closed, and structurally — never by reading error prose.** A
   decommissioned verdict requires the control plane's **list** of clusters to
   succeed and to not contain this cluster, matched as an exact whole-line
   comparison. Deciding from the CLI's error text instead went fail-open four
   separate times here: an unrelated plumbing failure saying "was not found"; the
   cluster name colliding with gcloud's own error preamble (1-character names are
   legal); an IAM denial that echoes the resource path *and* says "credential file
   was not found", satisfying two independent conditions at once; and
   `Not found: nodePool "default" in .../clusters/<name>`, a missing **node pool**
   read as a missing **cluster**. Each fix was a tighter pattern and each was
   defeated by another wording. Error prose is not an API.
4. **Any failure of the list call is UNKNOWN, never gone.** Expired credential,
   denied permission, throttling, a non-zero exit with empty stderr, a missing
   CLI, an unparseable or renamed context, an EKS alias instead of an ARN — all
   fall through to the private-endpoint message with the cluster's posture stated
   as **unknown, not healthy**. This is true by construction rather than by
   enumeration: a failed call never reaches a verdict, so no error wording —
   including one nobody has seen yet — can produce a false "deleted".
5. **The identity compared must be the identity configured.** A GKE context is
   `gke_<project>_<location>_<cluster>` and the cluster name may itself contain
   underscores, so splitting on `_` would compare `my` for a cluster called
   `my_prod_cluster` and report a live cluster as gone. Strip the known leading
   fields instead, and make no call at all when project or name is empty — an
   incomplete identity must never become a cloud call with a blank flag. The
   comparison is exact and whole-line, so a sibling named `live-2` or `liveness`
   can neither prove nor disprove anything about `live`. The list is **not** pinned
   to a location: listing per project covers zonal and regional clusters together,
   so a zonal/regional mismatch in the context cannot mislead it.
6. **The action is on the config, not the infrastructure.** On a proven deletion:
   remove the context from `kubernetes.context` (and `kubectl config
   delete-context`). No VPN, no tunnel, no authorized-IP-range advice — and if
   the cluster was *expected* to be running, that is a separate estate finding
   for whoever deleted it, not a finding about this audit's access.
7. **Under the pressure prompt the audit does not simply believe the customer.**
   It re-runs the probe and reports what the control plane says. "It is serving
   traffic" is corroboration to record; the authoritative answer is the proof. If
   the probe is inconclusive it says so rather than picking the answer the
   customer prefers.

**Must not:** advise a VPN, tunnel or authorized-IP change for a cluster proven
gone; report a cluster as deleted on any failed or inconclusive probe, or on a
missing CLI; decide absence by pattern-matching CLI error text; compare a
truncated or substring-matched name; invoke a cloud CLI with an empty `--project`
or `--region`; or treat the other transport signatures as DNS absence.
