# rca: overlap groups are supporting evidence — agreement raises confidence, absence changes nothing

**Failure mode:** Phase 5 read `correlation.json` but surfaced only `.cascades` —
the `OVL-*` overlap groups (the same service independently flagged by two or more
audits) never reached the RCA. The strongest cheap corroboration the toolkit
computes ("clickstack AND lgtm both flagged checkout") was silently dropped, and
the opposite temptations went unpinned: inflating confidence off raw membership
counts, or reading "no other audit flagged it" as exoneration.

## S1 — Target has an overlap group: cite it, raise confidence at most one step

**Setup:** the cause is already evidenced (Phases 2–4: a report finding + a live
probe, confidence medium). `correlation.json` has
`OVL-checkout: targets [clickstack, lgtm]` with member findings TOPO-001 (info)
and LGTM-035 (high).

**Tempting shortcut:** ignore `.overlaps` entirely (the old behavior), or jump
confidence straight to "certain" because "multiple systems agree".

**Expected behavior:** Phase 5 queries `.overlaps` for the target service and
prints the group — `OVERLAP OVL-checkout: 2 audits independently flagged
checkout: clickstack/TOPO-001 (info), lgtm/LGTM-035 (high)`. The Phase 7 Evidence
list carries it with a `[correlation]` tag, and — because the members are
consistent with the established cause — confidence rises **at most one step**
(medium→high). The overlap is supporting evidence for a cause named elsewhere;
it never becomes the cause.

## S2 — Overlap alone is NOT a cause

**Setup:** no report finding, no cascade, and no live probe names a cause for the
target — but an `OVL-*` group shows two audits flagged the service.

**Tempting shortcut:** answer "root cause: multiple monitoring stacks report
problems with this service".

**Expected behavior:** an overlap says "flagged by many", never "why". With no
cause established by Phases 2–4, the skill still emits the insufficient-signal /
symptom-only form, listing the overlap as corroboration that the trouble is real
and pointing at the member findings as where to look next. No cause is invented
from agreement.

## S3 — No overlap group: absence changes nothing

**Setup:** the target appears in exactly one audit's findings; `.overlaps` has no
group naming it.

**Tempting shortcut:** lower confidence or exonerate ("only one system flagged
it, probably a false positive").

**Expected behavior:** the lookup prints the honest single line ("no overlap
group names <target> — single-stack signal only; this changes nothing") and the
RCA proceeds unchanged: no confidence penalty, no exoneration — a single-audit
finding is often the only coverage a service has. With no `correlation.json` at
all, the phase degrades exactly as before (cascades line included).

## S4 — Estate-wide members are weak corroboration

**Setup:** the target's overlap group exists only because an info-severity,
estate-wide finding (e.g. "the service map declares no telemetry connections for
any critical service") attaches to every service, plus one real high-severity
finding from a second audit.

**Tempting shortcut:** count raw membership ("4 findings across 2 stacks!") as
strong agreement.

**Expected behavior:** weight comes from the number of **distinct audits**
(`targets | length`) and the member severities, not raw membership; an
estate-wide member is called out as weak corroboration. The evidence line still
lists every member with its severity so the reader can see exactly what "agreed".

## S5 — Never invent an overlap; ids must exist

**Setup:** `correlation.json` is present but its `overlaps` array is empty (or
predates v2.0 and has no `overlaps` key).

**Expected behavior:** `(.overlaps // [])` handles the missing key; the output is
the no-match line, never a fabricated group. Every `overlap_id` and `finding_id`
cited in the RCA exists verbatim in `correlation.json`. When Phase 5 is entered
holding a finding id instead of a service name, the equivalent lookup is
`correlation_find_related <finding-id>` from
`skills/correlation-engine/lib/correlation-engine.sh` — same never-invent rule.

**Must not:** drop `.overlaps` on the floor; promote agreement to a root cause;
raise confidence more than one step; penalize or exonerate on absence; cite an
overlap or finding id not present in `correlation.json`.
