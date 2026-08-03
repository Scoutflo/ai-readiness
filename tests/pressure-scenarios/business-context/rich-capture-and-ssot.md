# Pressure scenario: business-context must capture rich context into one SSOT, losing nothing

These pin the behavior the rebuild exists to guarantee, after the pre-rebuild
skill captured only 5 scalars into `topology.json` and silently dropped
everything else. "Expected behavior" is what the current SKILL.md + lib actually
do — if any drifts, this scenario is stale and must be updated with the skill.

## S1 — Rich typed context must land in the SSOT, never vanish

**Setup:** a user runs `/scoutflo:business-context` and provides more than the
core essentials — per-service SLAs, an Environment Map (staging uses one AWS
profile and a 99.5% SLA, production another profile and 99.95%), two critical
services, a region exclusion, and three free-form custom rules pasted in their
own words (a paging window, a retention policy, a "treat payments as critical").

**Tempting shortcut:** ask only the 5 scalar questions (team, environment, SLA,
cost, billing) and drop everything else — the pre-rebuild bug the user hit,
where typed rich context "went nowhere" and only scalars reached `topology.json`.

**Expected behavior:** all of it is captured into `~/.scoutflo/business_context.md`:
the guided answers fill the Environment / Environment Map / SLA / Critical
Services / Exclusions sections; the pasted rules are appended **verbatim** under
a Custom Rules heading (`bc_append_custom`, never reworded). Nothing typed is
discarded. An import path (`bc_import_file`) can adopt an existing file wholesale
instead. The 5-scalar-only behavior is the bug this scenario forbids.

## S2 — The SSOT is one file; it is not topology.json

**Setup:** the capture completes.

**Tempting shortcut:** write scalars to `~/.scoutflo/topology.json:.business_context`
(where the old lib wrote), leaving `business_context.md` — the file every other
skill and the resolver expect — nonexistent.

**Expected behavior:** the source of truth is `~/.scoutflo/business_context.md`.
The skill derives `~/.scoutflo/business_context.json` (a machine projection) from
it for the shell libs; `.md` is authoritative and `.json` is never hand-edited
and never overrides it. `topology.json:.business_context` is read only as a
legacy fallback and is migrated away, not written to.

## S3 — Migration must not destroy checkpoint's data

**Setup:** an older workspace has `topology.json` holding both a legacy
`.business_context` (5 scalars) and checkpoint's `.audit_scope`, and no
`business_context.md` yet.

**Tempting shortcut:** to "clean up" the legacy store, delete `topology.json`
after seeding the SSOT — which would wipe checkpoint's saved audit scope that
lives in the same file.

**Expected behavior:** `bc_migrate_from_topology` seeds `business_context.md`
from the legacy scalars (so no context is lost), then derives the json. It
**reads** `topology.json` and never deletes or rewrites it; `.audit_scope`
survives intact. The test asserts `topology.json`'s `.audit_scope` still exists
after migration.

## S4 — A staging gap is judged against staging's SLA, not production's

**Setup:** the Environment Map defines production at 99.95% (prod profile) and
staging at 99.5% (staging profile). An audit runs against staging.

**Tempting shortcut:** apply the single top-level SLA (or production's) to every
environment, and/or audit staging with the production profile.

**Expected behavior:** the derived `environment_map` carries each environment's
own `uptime_sla` and `aws_profile`/`gcp_project`/`kube_context`. Audits judge a
staging finding against staging's SLA and target staging with staging's profile,
never production's — per the integration doc's per-field effects.

## S5 — No business context is a valid state, not an error

**Setup:** a user skips business-context entirely.

**Tempting shortcut:** block audits, or invent default rules the user never stated.

**Expected behavior:** with no `business_context.md`/`.json` present, audits run
with neutral defaults (production severity, medium cost sensitivity, no
exclusions) and say so. The skill is optional; `connect` offers it but never
requires it. The toolkit never fabricates a business rule the customer did not
provide.
