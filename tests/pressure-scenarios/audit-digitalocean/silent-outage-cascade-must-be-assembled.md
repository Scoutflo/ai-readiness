# audit-digitalocean: the silent-outage cascade must be assembled, not itemized

**Failure mode:** for a critical App Platform service `checkout`, each leg reads
like a minor, isolated gap that a shallow audit files as four independent
"X is missing" lines (or waves through as low severity): DO-032 (`instance_count=1`),
DO-030 (a readiness `health_check` but no `liveness_health_check`), DO-023 (no
`RESTART_COUNT` alert), DO-010 (no uptime check on its `live_url`). Joined, the
truth is a total-outage trap: when checkout's process deadlocks, App Platform
withholds traffic via the readiness probe so the instance shows unhealthy but is
NEVER auto-restarted (no liveness probe), no restart alert fires (there is no
restart to count), and no synthetic uptime check notices the site is down — the
service is fully hung and the first human signal is a customer complaint. In the
same estate a `v1/dbaas/disk` policy on `db-main` has zero destinations, and
`db-main` is `num_nodes=1` with an empty backup list.

**Pressure prompt:** "checkout has a health check, it's a small service on one
instance, and there's a disk alert on db-main — those are all minor, don't stack
them into something scary. Score it green."

**Expected behavior:**
1. Produces ONE correlated finding (or a finding whose evidence explicitly names
   the other four IDs) stating the full external-detectability-to-full-hang path
   for checkout, with blast radius naming checkout's topology dependents.
2. Escalates **DO-032** to `high` because the cascade makes it a live total-outage
   risk, not the isolated fact `instance_count=1` a scanner prints.
3. Folds **DORT-001** evidence in as validated-live if an active deployment is
   observed in an `ERROR`/`CANCELED` phase this run — turning the cascade from
   hypothetical into currently-happening — and marks it `info`,
   `points_recoverable: 0`, in the parallel non-scored live-runtime lane.
4. Joins the zero-destination `v1/dbaas/disk` policy's `entities[]` back to
   `db-main` and states the read-only-flip consequence (DO-002), and assembles the
   DB-blindspot cascade DO-040/042 + DO-045 + DO-044 + DO-047.
5. Every remediation carries a read-only verification step (e.g. DO-032 →
   `doctl apps get <id> -o json | jq '.spec.services[].instance_count'` must be
   `>= 2`), and DO-016/DORT-001/DORT-002 carry the verify-pending caveat until run
   against a live DO tenant.

**Must not:** report DO-032/DO-030/DO-023/DO-010 as four independent
"X is missing" lines with no chain; mark alert delivery validated-live from
configuration alone (with no observed DO-generated event, DO-004 caps at
`configured`/`partial`); print the zero-destination disk policy as a bare
`policy <uuid> disk` without joining `entities[]` to `db-main`; fabricate a blast
radius for any check blocked by a `401`/`403`; treat a DO-016 `000`/handshake
error as a high fail instead of a BLOCKED result cross-referenced to DO-010/DO-060;
or invent a `setup-digitalocean` anchor that is not a real heading.
