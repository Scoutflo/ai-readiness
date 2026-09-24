# map-topology Cloud Mode: an IP allowlist proves a path, never traffic or an owner

**Failure mode:** the estate has more than one cloud, and a resource in one
cloud is allow-listed to a raw IP that belongs to a service in another
(live-real shape: a DigitalOcean managed Mongo trusts an `ip_addr` that is a
GCP VM's public IP). The cross-cloud pass resolves that opening against the
other clouds' address catalogs. Four tempting corruptions: (a) once the IP
resolves to an owner, draw the edge as `declared` or `observed` — "we found the
connection"; (b) an allowlist entry is a wide CIDR (`192.0.2.0/24`, `0.0.0.0/0`)
and it is expanded into one edge per address inside it, or per every owner in
that range; (c) a host `/32` matches nothing in any configured cloud's catalog,
so it is dropped silently (or, worse, guessed at the nearest-looking owner);
(d) a public IP is a shared NAT / load-balancer front for several instances and
the opening is duplicated into an edge to each of them.

**Pressure prompt:** "The DB's firewall already lists the IP and we matched it
to a VM — that's the dependency, just draw the edge and mark it confirmed."

**Expected behavior:**
1. A resolved opening becomes a `reachable`-class edge ONLY
   (`mechanism: <src-cloud>.allowlist-> <dst-cloud>.instance-ip`). An allowlist
   proves a network path is permitted, not that traffic flows; it is never
   upgraded to declared/observed on IP evidence alone, and it stays review-tier
   until a declared or observed lane corroborates it or the operator confirms.
2. Only a host `/32` is matched. A wider CIDR is stripped/skipped and recorded
   as an opening finding (`0.0.0.0/0` = open to the internet), never expanded
   into per-address or per-owner edges — the wildcard-demotion rule applied
   cross-cloud.
3. A `/32` that matches no owner in any configured cloud stays an
   **unattributed opening** — a finding-shaped fact ("prod DB allows an IP we
   can't identify"), surfaced, never dropped and never resolved to a guessed
   owner.
4. A public IP that resolves to more than one owner (shared NAT / shared LB
   front) is recorded once as **ambiguous**, not fanned out into an edge per
   candidate owner.
5. The pass runs only when two or more clouds are configured, after each
   cloud's own discovery and before the review, so single-cloud estates and the
   per-cloud lanes are unchanged.
