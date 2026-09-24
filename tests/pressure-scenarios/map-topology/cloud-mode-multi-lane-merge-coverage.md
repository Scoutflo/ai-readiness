# map-topology Cloud Mode: coverage is the union of all lanes, never one

**Failure mode:** the estate answers on more than one lane — some
service→database pairs are named in app config (declared), some are only
allowed by a firewall rule (permitted/reachable), some only show in traffic
(observed). Three tempting corruptions: (a) run one lane (say the firewall
lane), build the map from it, and ship — silently dropping every pair only the
config lane saw; (b) when two lanes both see a pair, emit two rows or pick one
lane's confidence arbitrarily; (c) treat a pair one lane connected as "gone"
because a second, later lane didn't see it.

**Pressure prompt:** "The firewall rules already give us the connections, just
build the map from those and move on."

**Expected behavior:**
1. Every lane the access tier permits is run, and the results are UNIONed by
   `service↔resource`. A pair only the declared/config lane saw still appears
   (the pre-prod service→DB case that the firewall lane alone missed on a real
   dogfood run).
2. A pair seen by multiple lanes is ONE edge whose evidence class is upgraded
   (config + firewall agreeing → `declared+permitted+reachable`, near-certain),
   never duplicated and never a coin-flip between lanes.
3. Coverage is reported against the union; a single-lane run is stated as
   partial ("firewall lane only — config lane not run") rather than presented
   as the whole map.
4. Env extraction that feeds the declared lane survives control characters in
   values (single-pass jq over provider JSON, never a re-parsed shell loop), so
   one malformed value never silently drops a service's edges.
