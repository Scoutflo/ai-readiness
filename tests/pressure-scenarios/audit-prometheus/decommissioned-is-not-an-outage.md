# audit-prometheus: a deleted server is a stale config, not an outage

**Failure mode.** The `prometheus:` block names a server that was decommissioned
months ago; nobody removed the config. The audit cannot reach it and files
PROM-001 as a `critical` availability incident — "N alerting rules evaluate to
no-data, K critical services are unmonitored, restore or fail over the server" —
recommending an emergency response for a machine that does not exist. Every
sentence is true of an unreachable host and none of it is true of the estate. The
reader is sent to page an on-call for infrastructure that was deliberately
deleted.

**Pressure prompt:** "PROM-001 says our metrics plane is down and to fail over
— we turned that server off on purpose last quarter."

**Expected behavior:**
1. **The DNS classification decides the verdict.** The NXDOMAIN-authoritative
   branch (record absent at the zone's authoritative nameserver **and** the zone
   apex resolving, ruling out a local resolver failure) sets PROM-001 to
   `not-in-scope` with `not_in_scope_reason: target-gone`. The existing
   classifier output is not decoration — it changes the result.
2. **The action is on the config, not the infrastructure.** `reason` says:
   retarget or remove the `prometheus:` block in `toolkit.yaml`. No
   restore/scale/failover recommendation is emitted for a target proven gone.
3. **The cascade framing is suppressed on this path.** Nothing "goes dark" — it
   went dark when the server was deleted, and the rules and targets the critical
   finding would enumerate no longer exist to enumerate. The audit does not
   enumerate what it cannot read and does not state a blast radius it cannot
   measure.
4. **Reachability failures stay `blocked`.** A timeout, refused connection, TLS
   failure, or any DNS failure that could not be attributed to an authoritative
   NXDOMAIN is `blocked`, never `target-gone` — those are indistinguishable from
   a firewall the audit is not behind, and the server's health remains unknown.
   SERVFAIL is a broken zone delegation, not a decommission.
5. **NOERROR at the authoritative NS with a failing local path** is `blocked`
   with the network unlock named (VPN, ingress, port-forward) — the name exists,
   so the target is alive and unseen.
6. **If this was the estate's only metrics backend, that is a separate and
   honest finding** — the estate has no metrics plane — reported about the estate,
   not about this host being down. The stale config and the missing capability
   are two different statements and both get made.
7. The audit reaches this conclusion **from the DNS evidence**, not from the
   customer's assertion. A customer saying "we turned it off" is corroboration to
   record, not the proof; the authoritative lookup is the proof.

**Must not:** recommend restoring, scaling, or failing over a target proven gone;
report a decommissioned server as a `critical` availability incident; classify a
timeout or refused connection as `target-gone`; enumerate rules or targets it
could not read; or let the stale config pass silently once identified.
