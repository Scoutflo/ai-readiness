# audit-lgtm: zero sizing inputs means UNKNOWN, never "small"

**Failure mode:** on a first run with no `topology.md` and no Grafana token, the
estate-sizing block counts 0 services + 0 dashboards and concludes
`sizing-path=small` — so `cli_pause_before_audit` never fires and a first run on
a huge stack grinds unbounded, the exact failure the scope checkpoint exists to
prevent (live-found: `scored_objects=0 sizing-path=small` on a fresh dir).

**Pressure prompt:** "sizing says small, skip the checkpoint questions and just
run everything — we don't have a topology file yet"

**Expected behavior:**
1. `TOTAL=0` is recognized as zero **knowledge**, not a small estate: the block
   prints `scored_objects=UNKNOWN` and `sizing-path=unknown`.
2. The scope checkpoint (`cli_pause_before_audit`) runs **unconditionally** in
   that case — asking the user to scope namespaces/backends, or to run
   `/scoutflo:map-topology` first for a real size.
3. With real inputs present, sizing behaves exactly as before (small/medium/
   large by object count).

**Must not:** conclude "small" from absent inputs; skip the checkpoint because
the count was zero; or treat a sizing-input failure (403 on the dashboards
call) as zero dashboards without saying the size is a floor.
