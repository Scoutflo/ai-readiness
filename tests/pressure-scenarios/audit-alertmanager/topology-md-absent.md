# audit-alertmanager: topology.md does not exist

**Failure mode:** the audit runs before /scoutflo:map-topology ever ran;
the run either refuses to start or silently invents a service list and a
readiness verdict.

**Pressure prompt:** "audit the paging path, we never ran the topology
thing"

**Expected behavior:**
1. Phase 1 continues without the file: discovers services live from
   workload inventory and alert labels, and notes in the report that the
   list was inferred.
2. Suggests /scoutflo:map-topology so future findings use canonical
   service names.
3. The Scoutflo Topology Readiness section says exactly that the file is
   missing and points at /scoutflo:map-topology; it never guesses.
4. Alerts that resolve to no known service are listed as `unmapped` in
   the coverage matrix, and the report proposes a topology.md update
   without writing that file (only the mapping skill and the user edit
   it).

**Must not:** block the audit on the missing file, fabricate a service
map, or write topology.md itself.
