# The Depth Doctrine

The thing a customer cannot get without this plugin.

A linter, a `kube-score`, a Trivy scan, an AWS Trusted Advisor row, a Grafana
"you have no alerts" banner — all of these already tell a customer *"resource X
is missing property Y."* If a Scoutflo finding says only that, we have added
nothing they could not get for free in thirty seconds. **Surface findings are
not a product.** This document defines the bar every scored check must clear, so
that every finding we ship answers the four questions a good SRE would ask next
and a scanner never does: *who is actually affected, how bad is it here
specifically, what is the exact fix, and how does it chain with everything else
that is wrong.*

This is a **toolkit-wide standard**, versioned with the plugin, referenced by
every `audit-*` skill's check catalog. It does not change the
[findings schema](findings-schema.md) or [scoring model](severity-and-scoring.md)
— it raises the quality of what fills those fields.

## The five elements of a deep finding

Every scored finding (severity ≥ low; `info` observations are exempt) must carry
all five. If a check can only produce three, the check is under-built — deepen it
or fold it into a check that can.

1. **Precise locus — the exact object and the exact wrong value.**
   Not "the namespace has no policy." Name the resource by its stable key, the
   field, and the observed value: *"Deployment `payments/api`, container `web`,
   runs `securityContext.privileged: true` and `runAsUser: 0`."* The reader can
   go straight to the object. This lives in `affected` (the where) and the
   evidence `observed` (the exact value), never as a vague scope.

2. **Blast radius — computed from the live estate, not asserted.**
   The concrete consequence *in this estate*: who can reach what, what goes down,
   what an attacker gets. *"This SA's mounted token can `list secrets` in all 24
   namespaces (verified via `auth can-i`), so any RCE in this pod exfiltrates
   every credential in the cluster."* / *"`checkout` is `replicas: 1` with no PDB
   and all pods are on node `ng-2-a`; that one node draining during a routine
   upgrade takes checkout fully offline."* Blast radius is derived by querying
   the graph (reachability, bindings, placement, dependents) — a number or a
   named set, not the adjective "risky." This is the `impact` line.

3. **Correlation — the chain, not the isolated fact.**
   A deep audit connects findings into an attack path or a failure cascade and
   says so explicitly: *"K8S-010 (public LoadBalancer on `store-front`) +
   K8S-008 (its pod mounts an SA token) + K8S-006 (that SA can list secrets
   cluster-wide) + K8S-003 (its namespace has no NetworkPolicy) is a single
   external-to-cluster-secrets path."* One named chain is worth more than three
   findings a reader has to assemble themselves. When findings chain, each names
   the others in its evidence; the report's correlation view and `/scoutflo:rca`
   consume these joins. A cascade the customer's own tools cannot see is the
   clearest proof of value.

4. **Exact remediation — the specific change, not the principle.**
   Not "apply least privilege" or "follow best practices." The concrete change:
   the NetworkPolicy default-deny manifest shape to add, the exact RBAC rule to
   remove and what breaks if you do, the probe stanza to add, the flag to set.
   Point at the `setup-*` skill that performs it (`remediation`) and, where the
   fix has a failure mode, name it (*"add the default-deny, then add an explicit
   allow from `api-gateway` first, or you cut `payments` off from its
   database"*). A fix the customer can paste and verify.

5. **Verification — how they confirm it took.**
   Every remediation states the read-only check that proves the fix landed
   (*"re-run `auth can-i list secrets --as=system:serviceaccount:ns:sa` — it must
   return `no`"*). A fix with no verification step is a suggestion, not a
   remediation.

## Surface vs deep — worked contrast

| The scanner already says (surface) | What we ship (deep) |
| --- | --- |
| "`prod` namespace has no NetworkPolicy." | "`prod` has no NetworkPolicy, so all 31 pods share a flat L3 network; `payments-db` (pod `payments-db-0`, port 5432) accepts connections from every pod including the internet-facing `store-front`. Add a default-deny + explicit allow from `payments` only; verify with a denied test connection from another namespace." |
| "3 workloads have no CPU/memory limits." | "`ingress-nginx` (the ingress controller — every request's shared path) has no memory limit and lives on a node with 2 other unlimited workloads; a memory spike OOM-kills the node's kubelet and takes all 3 down. K8SRT-002 already shows it OOMKilled once (exit 137) this week. Set limits at 1.5× observed working-set." |
| "IAM user has AdministratorAccess." | "IAM user `ci-deployer` has `AdministratorAccess`, its access key is 400 days old and last used 2h ago from an EC2 role range, and it can `iam:CreateAccessKey` on all users — a leaked CI key is full-account takeover with persistence. Replace with a scoped deploy policy (attached); rotate the key; verify with Access Analyzer." |
| "You have 212 alert rules." | "Of 212 rules, 47 have fired > 50×/day for 30 days and route to the same PagerDuty service as the 3 rules that actually page a human — the real pages are buried in noise (this is why MTTA is 40min). The top 5 noisiest by count are [...]; move them to a ticket route or add `for:`. " |

The left column is free. The right column is why they installed us.

## The mechanical checklist (apply to every scored finding)

- [ ] `affected` names concrete objects by stable key, not a vague scope.
- [ ] `evidence[].observed` quotes the **load-bearing value** (the actual bad
      config / count / status), not a restatement of the check.
- [ ] `impact` states blast radius derived from the live estate (who/what/how
      many), not an adjective.
- [ ] The finding names any other finding it chains with (attack path / cascade),
      when one exists.
- [ ] `recommendation` is a specific change a reader can execute, and
      `remediation` points at the skill that performs it.
- [ ] The remediation carries a verification step and, where relevant, its own
      failure mode.
- [ ] Severity and `points_recoverable` reflect the computed blast radius, not
      the checkbox.

## This applies to existing checks too

Adding more shallow checks is not depth. A 40-check audit whose findings each say
"X is missing" is still a linter with a bigger catalog. When you touch any audit:
**deepen the checks it already has** to this bar before adding new ones, and add
new checks only where they open a genuinely new failure class (a new attack path,
a new cascade, a new reachability question) the current catalog can't reach.

## What does *not* have to be deep

- `info` findings and parallel non-scored snapshot rows (`K8SRT-`, `TOPO-`,
  `AWSOPT-`, cost rows) are observations by design — they carry evidence but not
  the full five elements, and they never move the score.
- A **blocked** check states its blocker as evidence and stops there; you cannot
  compute blast radius for something you could not observe. Honesty over depth:
  never fabricate a blast radius to hit the checklist.

## Where this is enforced

Structure and reconciliation are mechanical
([`check-findings.sh`](check-findings.sh) already requires `affected` on every
non-info finding, evidence with real `observed` output, and a `remediation`
pointer). Depth of *reasoning* — blast radius computed from the live estate,
correlation chains, exact fixes — is a **maintainer-review and live-smoke**
judgment, checked against this doctrine on every new or changed audit, the same
way correctness is. The gates stop a finding with no `affected`; this doctrine is
how the reviewer decides whether the `affected`, `impact`, and `recommendation`
that *are* present clear the bar or read like a free scanner.
