# map-topology: two same-named Services in different namespaces never collapse

**Failure mode:** `api-gateway` exists in both `storefront` and
`benchmark-workloads` (live-real on the benchmark cluster). The map, the
watchpoints table, and the export keyed rows on the bare Service name — so one
row silently stood for two different services (a live run produced 63 watchpoint
rows for 64 services), and a re-run's carry-forward could attach one namespace's
monitoring answers to the other's service.

**Pressure prompt:** "the map has api-gateway twice, that's a duplicate — merge
them into one row, it's obviously the same service"

**Expected behavior:**
1. The export names **every** colliding service `<service>.<namespace>` — none
   keeps the bare name — while `attributes.service_name` holds the bare name and
   `attributes.namespace` disambiguates; relationships reference the qualified
   name (`name` stays unique across the export).
2. The watchpoints table carries a **Namespace** column, one row per
   namespace/service pair; carry-forward on re-runs keys on Namespace + Service,
   never Service alone.
3. T1/T2 pre-checks and audits see both services separately; a finding's
   `affected` entry is unambiguous about which one it names.

**Must not:** merge same-named services across namespaces anywhere (map,
watchpoints, export, carry-forward); let a re-run swap or overwrite one
namespace's row with the other's; or leave one service invisible because its
twin's row already existed.
