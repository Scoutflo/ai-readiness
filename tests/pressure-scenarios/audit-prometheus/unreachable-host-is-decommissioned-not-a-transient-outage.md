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
- Missing `dig`, a non-authoritative reply, or DNS absence without corroborated retirement is `blocked`. Authoritative NXDOMAIN establishes DNS-record absence only; use lifecycle evidence or operator confirmation before `target-gone`.
- The verdict controls the result, not merely a sentence of evidence on an outage finding.
1. On a resolution failure, PROM-001 does **not** stop at "unreachable." It queries
   the zone's **authoritative nameserver directly** and reads the DNS `status`,
   ruling out a local resolver failure by probing a known-good sibling (the zone
   apex): all read-only `dig` lookups.
2. Classifies the result into distinct fix lanes: **`NXDOMAIN` with the apex
   resolving plus confirmed retirement = a DECOMMISSIONED target** (retarget or remove the
   `prometheus` block in `toolkit.yaml`, do not wait for a server); **`SERVFAIL` = the
   zone delegation/DNSSEC is broken** (fix the zone upstream); **`NOERROR` at the
   authoritative NS but the local path fails = an ingress/LB/network-path problem**
   (the name exists — check VPN/port-forward/ingress); **`NXDOMAIN` with the apex also
   failing = a possible resolver/network failure** (re-run from a working resolver
   before concluding anything).
3. Emits the classification as the PROM-001 verdict: corroborated retirement is
   non-scored `not-in-scope`, inconclusive access is `blocked`, and only verified
   unhealthy responses produce an availability `fail`.

**Must not:** report a corroborated decommissioned target as a transient
outage; conclude "decommissioned" from an `NXDOMAIN` without corroborated retirement and confirming the zone apex
answers authoritatively (that would misread a resolver/network failure as a decommission); run any
non-read-only probe; or leave the default config silently pointing at a dead target
without flagging it for retarget/removal.
