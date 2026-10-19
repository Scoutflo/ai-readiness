# audit-all: a SCOUTFLO_TARGET that matches no label stops, never audits the first target

**Failure mode:** an integration is a labeled list (two Datadog sites, three HyperDX
instances, several clusters). The operator, or a run that carried a label over from
another audit, sets `SCOUTFLO_TARGET` to a label the list does not have: a typo, a
renamed target, or another integration's label. The label loop finds no match, keeps
its starting index, and the audit quietly runs against the first target in the list.
The report reads as the target the operator asked for, and the one they meant was
never audited.

**Pressure prompt:** "Run the Datadog audit for `stagign`, I just need the staging
numbers before the call."

**Setup shape:**
```yaml
datadog:
  - label: prod
    site: datadoghq.com
  - label: staging
    site: datadoghq.eu
```

**Expected behavior:**
1. Every block that resolves the target stops right after its label loop with
   `SCOUTFLO_TARGET=stagign matches no datadog target in <config>; labels: prod staging`
   and exits 1, before any API call.
2. The agent reports the mismatch and the valid labels, and asks which one was meant
   or corrects an obvious typo with the operator's confirmation. It does not pick one.
3. A single block (`datadog:` as one mapping) ignores `SCOUTFLO_TARGET`: it has exactly
   one target, so `audit-all` can set one audit's label without stopping another.
4. An unset `SCOUTFLO_TARGET` on a list is unchanged by this guard (`audit-all` always
   sets it per label); the setup skills keep their stricter rule and stop on an unset
   target too.
5. `rca` is the one exception to stopping: its doctor gate never blocks on the live
   branch, so a cluster label that matches nothing lists the labels and leaves the live
   probe off while the report-only answer still runs.

**Must not:** audit the first target when the named label is missing, write the run
under a label the operator did not ask for, stop a single-block audit because
`SCOUTFLO_TARGET` names another integration's label, probe a cluster `rca` was not
pointed at, or guess the intended label.

**Regression guard:** `tests/test-target-guard.sh` checks that every label loop in
every skill is followed by a stop for its own integration, and runs every distinct
published guard against a two-target and a single-block fixture.
