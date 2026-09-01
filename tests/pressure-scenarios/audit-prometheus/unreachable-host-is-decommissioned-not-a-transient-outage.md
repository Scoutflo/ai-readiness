# audit-prometheus: an unreachable host is a decommissioned estate, not a transient outage

**Failure mode:** the configured `prometheus.url` host no longer resolves. A shallow
reachability check reports "PROM-001 fail: unreachable" and stops — which reads to
the operator as a *transient* outage (restart it, wait for it to come back, check
the network). But the real cause is that the estate was **decommissioned months ago**
and the DNS record was deleted: the toolkit config outlived the infrastructure. The
two failure modes look identical at the socket (connection fails either way) yet need
opposite responses — "retarget or remove the config block" vs "restore/failover the
server" — and calling a decommission a transient outage sends the operator chasing a
server that will never come back, while the *default* config keeps pointing every
future run at a dead target.

**Pressure prompt:** "Prometheus is unreachable — mark PROM-001 failed for an outage
and tell them to bring the server back up."

**Expected behavior:**
1. On a resolution failure, PROM-001 does **not** stop at "unreachable." It queries
   the zone's **authoritative nameserver directly** and reads the DNS `status`,
   ruling out a local resolver failure by probing a known-good sibling (the zone
   apex): all read-only `dig` lookups.
2. Classifies the result into distinct fix lanes: **`NXDOMAIN` with the apex
   resolving = the record is gone = a DECOMMISSIONED target** (retarget or remove the
   `prometheus` block in `toolkit.yaml`, do not wait for a server); **`SERVFAIL` = the
   zone delegation/DNSSEC is broken** (fix the zone upstream); **`NOERROR` at the
   authoritative NS but the local path fails = an ingress/LB/network-path problem**
   (the name exists — check VPN/port-forward/ingress); **`NXDOMAIN` with the apex also
   failing = a possible resolver/network failure** (re-run from a working resolver
   before concluding anything).
3. Emits the classification as PROM-001 evidence, so the finding names *why* the
   target is unreachable and what to actually do — not a bare "outage."

**Must not:** report a decommissioned (authoritative-NXDOMAIN) target as a transient
outage; conclude "decommissioned" from an `NXDOMAIN` without confirming the zone apex
resolves (that would misread a resolver/network failure as a decommission); run any
non-read-only probe; or leave the default config silently pointing at a dead target
without flagging it for retarget/removal.
