# Changelog

## 0.1.39

Preserved T6 evaluation precision after the v0.1.38 genericization. The
public Topology Readiness spec now states the customer-actionable naming
rule explicitly — carry a plain snake_case `service_name`; a camelCase or
provider-specific field (e.g. `serviceName`) can pass a provider''''s own
schema (T4) but not anchor correlation (T6) — without exposing the internal
mapping algorithm. The T6 check itself was never changed; report output
quality is unaffected.

## 0.1.38

Kept platform-internal correlation mechanism out of the public spec. The
Scoutflo Topology Readiness spec (report-standard/topology-readiness.md)
and the export guidance now describe *what* makes a service sync-ready —
identity, workload mapping, observability edges with the provider''''s own
identifying attributes, integration identity, and confidence — without the
internal field-to-category mapping, engine internals, or contract-derivation
detail. Those are Scoutflo''''s and are maintained separately. Customer-facing
checks and report behavior are unchanged; only the level of internal detail
in the public docs was reduced.

## 0.1.37

Reworked the human-facing report **Findings** format so a report reads like
something any user can follow, not a coded table. Each finding now renders
as a plain-English heading plus **What's wrong / Where / Why it matters /
How to fix**, with the stable check ID demoted to a small `ref:` line (it
still drives delta tracking, the evidence appendix, and exemptions — a
reader just no longer needs it to understand the finding). Added an optional
`impact` field to `findings.json` to carry the "why". The output-conformance
gate (`report-standard/check-report.sh`) now **enforces** the new shape: the
old `ID | Severity | Title` findings table no longer conforms. Nothing
changed about what is detected or scored — only how findings are presented.

## 0.1.36

Public-release readiness. Added the Apache-2.0 `LICENSE` and set the
manifest `license` field (was previously unset). Refreshed the
customer-facing docs (README, install, FAQ, marketplace metadata):
removed all early-access / private-repo framing, surfaced the alert-noise
/ alert-fatigue capability and the report output-conformance guarantee,
and refreshed keywords for discoverability. Updated the contributor docs
(AGENTS, CONTRIBUTING, skill-authoring conventions) for accuracy and a
license note. No skill logic changed.

## 0.1.35 (unreleased)

Added an output-conformance gate so generated reports can no longer
silently drift from the standard. `report-standard/check-report.sh`
validates any emitted `report.md` against the canonical template
skeleton: the header table, the exact `**Score: <n>/100**` line, and the
required section spine (Executive summary, Scorecard, Findings, Next safe
actions, Evidence appendix) in order. Every audit skill now runs it on
its own `report.md` in the final phase before declaring the run done.
Until now CI validated skill *source* (structure, anchors, leak-scan) but
nothing validated the report *output* — which is why reports generated
across different sessions varied in header form and score-line phrasing.
This closes that gap: a report that does not match the template now fails
loudly at generation time, the same way `leak-scan` fails on source.

## 0.1.34 (unreleased)

Mirrored the alert-hygiene lens (Stage 1.1's anchor) into every
already-connected provider audit, each grounded in the verified
16-provider docs survey and folded into the skill's EXISTING alerting
category (denominator grows, weights unchanged — no reweighting):

- audit-grafana: GRAF-100 to GRAF-103 (missing `for` debounce, flap
  protection via `keep_firing_for`/recovery-threshold hysteresis,
  mute-timing and stale-silence hygiene, resolve-noise via
  `disableResolveMessage`), plus a noise reading folded into GRAF-052
  (no-data/error `Alerting`) and GRAF-056 (the corrected `group_by`
  `['...']` = disables-aggregation semantics). Honest ceiling: the
  provisioning API exposes config, not firing history or per-receiver
  counters, and the built-in Grafana Alertmanager has no inhibition — so
  no observed-flapping or inhibition check is invented.
- audit-sentry: SNTRY-101 to SNTRY-105 (filter gating, all-environment
  scope, flap-prone metric alerts, spike-protection posture with the
  corrected new-org default, inbound data filters).
- audit-lgtm: LGTM-070 to LGTM-073 (ruler-native `keep_firing_for`, group
  `limit`, resend/restart-state timing, HA duplicate-evaluation). Grouping
  and inhibition delegate to the Alertmanager/Grafana these backends route
  to; Mimir points at its bundled Alertmanager; Tempo is noted as a
  metrics-cardinality-feeds-noise input, not a scored check.
- audit-aws: AWS-060 to AWS-065 (single-datapoint debounce via M-of-N,
  missing/low-sample data noise, 30-day flap history, forgotten mutes,
  composite-alarm correlation, resolve wiring). Honest ceiling: CloudWatch
  has no native grouping/dedup/rate-limiting/scheduled-mute/routing —
  composite alarms are its correlation ceiling.
- audit-gcp: GCP-063 to GCP-066 (retest-window duration, auto-close,
  notification rate limit, renotify/resolve cadence). Names the three
  Alertmanager-class controls Cloud Monitoring lacks rather than scoring
  them.
- audit-digitalocean: DO-070 to DO-072 (shortest-dwell-window flag,
  permanently-disabled policy, duplicate single-entity policies
  collapsible under tag scope). Deliberately thin with an explicit
  honest-ceiling note — DO Monitoring lacks flapping-hold, grouping,
  dedup, and timed muting entirely.

Every check is read-only and reuses data the audit already captures.
Reference commands (bash -n and jq tested) live in each skill's own
reference file. Validation across all six: structure/anchor/leak-scan
clean, `plugin validate --strict` passed, frontmatter intact.

## 0.1.33 (unreleased)

Added an Alert hygiene category to `audit-alert-routing` — the anchor
(Stage 1.1) of a new alert-noise / alert-fatigue capability, grounded in
a verified survey of 16 providers' official docs. Seven new read-only
checks (ALR-012 to ALR-018): flapping/churn with no anti-flap hold,
permanently-firing rules and stale silences, missing `for` debounce,
notification-volume concentration and re-page storms, missing grouping or
inhibition, unintended duplicate delivery plus HA-dedup health, and
resolve-noise. The key new technique is a range query over the `ALERTS`
series (`query_range` over a 14-day lookback) to reconstruct each rule's
firing episodes and firing fraction — snapshot reads can't see flapping
or stuck rules. Category weights rebalanced to fit the new category at 15
(Config integrity 25->20, Route matching 20->15, Reachability 10->5).
Reference commands, thresholds, and jq are in verification-chain.md
section 13; every block is read-only and reuses endpoints the audit
already reaches. Honest ceiling stated in the skill and every report:
these are structural noise signals, not an alert-to-incident actionability
rate (this audit has no incident feed, so it never reports a fabricated
"N% actionable" number); the flapping/volume window is bounded by
Prometheus retention of the `ALERTS` series and counter continuity, and
the run reports the effective lookback it actually had; flapping faster
than the query step is invisible and the report says so.

## 0.1.32 (unreleased)

Continued the same direct re-read of the platform's provider-identity and
attribute-schema code, this time re-checking more than one copy of the platform's own schema definitions (both are confirmed
unchanged since the 2026-07-20 snapshot). One copy has a narrower monitoring-key list than another (no `cloudwatch`, `pagerduty`,
or `zenduty` keys there), which is expected divergence, not a bug - but it
independently confirms the fact that matters: `gcp` has no monitoring
attribute-schema key in either copy, and no GCP-specific attribute schema
or correlation-contract exists anywhere in the platform's topology-contract definitions either. Unlike DigitalOcean, GCP is a valid
provider-identity enum value, so T4/T5 are unaffected; but native GCP
Cloud Monitoring/Cloud Logging has no typed attribute fields at all for
T6's confidence-scored correlation, capping a `MONITORED_BY` edge at
`partial` on attribute depth alone even with solid live-alert proof.
`audit-gcp`'s Topology Readiness guidance previously implied full T6
credit was reachable the same way it is for Prometheus or Grafana; fixed
to state this caveat explicitly, including the honest way out (alerting
routed through a schema-modeled provider stays fully reachable through
that provider's own edge instead).

## 0.1.31

Found a significant, confirmed real platform gap doing a fresh, direct
re-read of the platform's actual provider-identity code (not relying on
the existing dated snapshot alone): DigitalOcean is not itself a valid
topology provider identity on the Scoutflo platform - confirmed against
both the source repo and what's actually deployed in the platform's installed package. GCP and Azure are both present as first-class cloud
providers in the same enum; DigitalOcean is absent entirely, and there is
no per-field attribute schema for it either. Traced the consequence into
the platform's own attribute-extraction code: the documented workaround
for an unmodeled provider (setting a generic placeholder identity with the
real provider name stashed in an attributes field) does not restore
correlation for it, because the extractor looks up a resource's schema by
its literal top-level provider value, not by that stashed field - so it
only preserves the resource ID for display, nothing more. `audit-
digitalocean`'s Topology Readiness guidance previously implied a DO
`MONITORED_BY` edge the audit verified live could straightforwardly count
toward T6; fixed to state the real gap plainly instead, including the
honest way out (a customer's real alerting routed through Grafana, Sentry,
or another platform-modeled provider stays fully reachable through that
provider's own edge). `sre-toolkit`'s own export provider list was already
correct - it never claimed DigitalOcean as a valid value - so this is a
guidance fix, not a schema fix.

## 0.1.30 (unreleased)

Found a real provider-parity gap on a full cross-provider re-check of every
readiness lesson against all three cloud audits (`audit-aws`, `audit-gcp`,
`audit-digitalocean`), not just the observability-stack audits already
re-checked: `audit-aws` (`AWS-051`) and `audit-digitalocean` (`DO-051`)
both check log retention as its own line item; `audit-gcp` had no
equivalent check anywhere in its catalog. Added `GCP-054` (Logs as a
signal category, `gcloud logging buckets list --format='table(name,
retentionDays,locked)'`) requiring retention on critical-service log
buckets to be a deliberate decision, not an unexamined default - same
discipline the other two providers already apply. No write path exists
for this in `setup-gcp` yet, so it routes to the existing plan-only
out-of-scope pointer. Also confirmed on this same pass: environment-label
requirements (E9) already exist in all three providers (`AWS-003`,
`GCP-060`, `DO-005`), and none of the three has the `GRAF-001`-style
vacuous-pass risk (`GCP-001`/`DO-001`/`AWS-001` are all already worded as
"at least one X exists," not "every existing X passes").

## 0.1.29 (unreleased)

Closed a vacuous-pass loophole found on a full, deliberate re-verification
pass against every item in the readiness-lessons list this plugin is being
checked against: `audit-grafana`'s `GRAF-001` only checked that every
*existing* datasource passes its health check. On an instance with zero
datasources, that loop trivially "passes" with nothing actually checked -
exactly the real, previously-observed failure shape of a Grafana instance
reporting `/api/health: ok` while having zero datasources and zero
dashboards, telling a customer nothing about whether the instance is
usable. Fixed GRAF-001 to require at least one datasource to exist before
crediting the health-check pass. (The equivalent "zero dashboards" case
was checked and found already covered: `GRAF-090` requires at least one
dashboard per critical service, so a fully dashboard-less instance already
fails there.)

## 0.1.28 (unreleased)

Two more targeted sharpenings of existing checks, closing out a careful
final pass for gaps that genuinely belong in this plugin (as opposed to
Scoutflo-platform-internal checks that don't) - both scoped to editing an
existing check's depth, no new check IDs, no scoring-table changes:

- `map-topology`'s export spec (`references/scoutflo-export.md`) never
  mentioned `diagnostic_criticality`, a real, accepted field on every
  relationship in the platform's actual bulk-import contract. A
  relationship missing it can be silently dropped from an investigation's
  topology slice on the live platform even though the edge exists in the
  graph - a quiet, invisible degradation, not a rejected import. Documented
  it as a real, worth-setting field.
- `audit-lgtm`'s `LGTM-032` (per-service metrics coverage) only checked
  that metrics exist (`count() > 0`), never their depth. A service can
  pass that existence check while having no per-pod resource series, no
  populated HTTP status-code label, and no real latency histogram - which
  means resource-saturation and percentile/SLO questions have nothing to
  query even though the service "has metrics." Added the three depth
  queries and downgraded existence-only to `partial`; full `pass` now
  needs real depth, not just existence.

## 0.1.27 (unreleased)

Added `environment` to `audit-alert-routing`'s ALR-007 triage-metadata
contract (both the required identity-labels list in the skill and the
matching reference doc). A paging alert can carry `severity`/`service`/
`namespace` correctly and still have no environment label at all, which
makes prod-vs-staging blast-radius reasoning impossible at triage time
even though every other identity field checks out. This was the one
precisely-scoped addition that came out of a broader pass deciding whether
a separate readiness-scoring skill was warranted for this class of gap —
it isn't; the existing audit-alert-routing and map-topology skills already
cover the bulk of it (alert coverage via ALR-004, hygiene via ALR-011,
multi-cluster identity and cross-service CALLS-edge scope already added to
map-topology/topology-readiness.md in 0.1.26), so this stays a targeted
sharpening of an existing check rather than new skill surface.

## 0.1.26 (unreleased)

Documented two real boundaries of the Scoutflo Topology Readiness (T1-T6)
model that a clean per-service scorecard can silently hide: multi-cluster
identity bleed (a repeated service name across clusters can resolve to a
workload in the wrong cluster, invisible to any per-service check), and
cross-service `CALLS` edges being out of scope for T1-T6 by design (every
service can individually pass T1-T6 while the graph still has zero
recorded cross-service call relationships, leaving blast-radius reasoning
with no data). Added the multi-cluster case to `map-topology`'s own Common
Failure Modes table as well, since that's the skill that actually records
cluster identity. Both are real, previously-confirmed platform behaviors,
not hypothetical edge cases.

## 0.1.25 (unreleased)

Found running `claude plugin tag` for the first time this project has ever
attempted a tagged release: three of the toolkit's 19 skills -
`start`, `audit-grafana`, and `audit-sentry` - had broken YAML frontmatter.
Each description began with the skill's own subject followed by a colon
and a space before more prose (`"Orientation for the Scoutflo AI
Readiness: the local-only guarantee, ..."`, `"...Grafana application
layer: datasource health..."`, `"...your Sentry org: project privacy
scrubbing..."`), which YAML parses as an attempted nested mapping inside
an unquoted scalar, not as prose - `mapping values are not allowed here`.
Per `claude plugin validate`'s own warning, this isn't a hard failure at
runtime, but the skill's frontmatter fields (including its description,
which every other skill's `disable-model-invocation` and description text
is used for) silently drop to empty metadata instead - meaning these three
skills' descriptions were never actually reaching Claude Code's skill
picker correctly, undetected through 24 prior version bumps because
neither CI's structure check nor a plain YAML syntax check happened to
catch this specific pattern. Fixed by quoting each description as a single
YAML scalar. Confirmed via a full frontmatter parse check across all 19
skills that no other skill has the same pattern.

## 0.1.24 (unreleased)

Final customer-facing documentation pass: read every doc a customer sees
(README, CONTRIBUTING, docs/install.md, docs/faq.md) end to end against
current behavior. README, install docs, and the full skill catalog were
already accurate - all 19 skill names cross-checked against the actual
`skills/` directory, no stale version numbers found anywhere. Found and
fixed two real gaps:

- `.claude-plugin/marketplace.json`'s keyword list was stale - it only had
  `sre, observability, audit, monitoring`, missing `digitalocean`, `gcp`,
  `aws`, `grafana`, `sentry`, and the rest that `plugin.json`'s own keyword
  list already carried. This hurt marketplace search discoverability for
  anyone searching by a specific provider name. Synced both lists.
- `docs/faq.md` and `schedule-audits/SKILL.md`'s own status note both said
  "acceptance runs land in v1.5" for schedule-audits, which was already
  out of date after this session's real crontab-path live test. Updated
  both to state precisely what's proven (crontab) and what isn't yet
  (GitHub Actions, Claude cloud schedule).

## 0.1.23 (unreleased)

Onboarding-friction pass on `connect`, prompted by a real observation: this
session's live-testing repeatedly found wrong-host, wrong-scope, and
wrong-flag mistakes that only surfaced deep into a live audit run, well
after the credential was created. Two changes:

- `connect/SKILL.md` Step 3 now explicitly instructs running each
  provider's verify command the moment that credential is exported, before
  starting the next integration - not waiting for the single `doctor` pass
  at the end of Step 7, where several small per-provider mistakes can
  compound into one confusing failure list. The per-provider verify
  commands already existed; the flow just didn't say when to run them.
- Added a "Quick reference: read-only tier, all providers" table at the
  top of `references/providers.md` - one scannable row per provider
  (credential type, exact minimum scopes, where to start) instead of
  requiring a read through nine full prose sections before knowing what
  to go create. Full click paths and elevated-tier scopes stay in each
  provider's own section, linked from the table.

## 0.1.22 (unreleased)

Live-tested `schedule-audits`'s crontab path for the first time, on this
machine, with a real (later removed) crontab entry and env file - the last
skill in the toolkit to get any live exercise. The mechanics (filling the
template, installing the entry, verifying its presence) all worked exactly
as documented. Found a real gap running the required "prove it works by
hand" step: the manual run failed with `Not logged in · Please run /login`
- interactive subscription login does not carry into a headless `claude -p`
invocation the way it does an interactive session, even though the
prerequisite list already named "authenticated (subscription login, or
export ANTHROPIC_API_KEY)" as sufficient. Added a cheap headless-auth
pre-check (Phase 3b, new step 4) that fails fast and cheap instead of only
surfacing this after a full, slow audit-all attempt, and added the exact
failure string to Common Failure Modes so it's recognizable on sight. Test
artifacts (the crontab entry and env file) were removed after the test;
nothing was left running on this machine.

## 0.1.21 (unreleased)

Ran `setup-aws`'s live write path for real for the first time - the last of
the six setup skills to get live coverage - against the real `scoutflo-
official` AWS account, fixing a real AWS-010 finding from the earlier
`audit-aws` live run: all 18 real CloudWatch alarms in the account had
empty `AlarmActions`, and zero SNS topics existed at all. Created a real
SNS topic, subscribed a real recipient, and re-applied one real RDS CPU
alarm (`database-1-instance-1-cpu-high`) with the topic attached, verified
live. Deliberately tested the documented restore pair and found a real bug:
it calls `sns unsubscribe` before `sns delete-topic`, but an unconfirmed
email/SMS subscription's ARN is the literal string `PendingConfirmation`
(or `pending confirmation`), not a real ARN - the common case for a fresh
subscription, since a human has to click the confirmation link first -
and `sns unsubscribe` on it fails live with `InvalidParameter: An ARN must
have at least 6 elements, not 1`. Confirmed live that `sns delete-topic`
alone is sufficient cleanup regardless, since deleting the topic removes
every subscription on it, pending or not. Fixed the restore pair in
`references/aws-fix-commands.md` to skip the unsubscribe call for the
unconfirmed case. Final state: the topic, subscription (pending human
confirmation, as expected), and alarm routing are all live and verified;
the other 17 alarms in the account remain the same safe fix, not attempted
in this pass.

## 0.1.20 (unreleased)

Ran `setup-gcp`'s live write path for real for the first time, against the
real `scoutflo-external` GCP project, fixing a real GCP-020 finding from the
earlier `audit-gcp` live run: zero CPU alert policies across all 42 VMs.
Gated first (confirmed 42 live CPU utilization series, matching the VM
count, before creating anything), then found a significant, previously
unnoticed bug on the very first policy-creation attempt: the documented
alert-policy JSON payload's `documentation` object sets `content` but never
`mimeType`, and the real Monitoring API rejects that outright with
`400 INVALID_ARGUMENT: "non-empty content requires non-empty MIME type and
vice versa"`. The skill's own text says this exact payload shape is reused
for uptime, GKE, load-balancer, and log-based-metric policies too - meaning
this bug would have broken alert-policy creation everywhere in the skill,
not just this one case. Fixed by adding `mimeType: "text/markdown"` to the
literal example payload and to the "Improve alert documentation" PATCH
section, which touches the same field. Verified live: created a real
two-tier CPU policy pair (WARNING 80%, SATURATION 95%) routed to the
project's real prod alerts channel, both enabled and channel-attached.
Tested rollback for real (DELETE, confirm 404 on re-fetch) before
re-applying the fix as the final state.

## 0.1.19 (unreleased)

Ran `setup-sentry`'s live write path for real for the first time, against
a real Sentry org, fixing a real SNTRY-001 finding from the
earlier `audit-sentry` live run: a dead project (zero accepted
events in 14 days) still carried Sentry's auto-created default rule
(`createdBy: null`). The read-only token connected for `audit-sentry`
correctly lacked `project:write` (confirmed live: project-settings and
client-key-rate-limit writes both 403 consistently), so the originally
planned SNTRY-003 fix (unlimited client-key rate limits) couldn't proceed
with that token - but probing further found the same token does carry
`alerts:write` (confirmed via a real create-then-delete round trip on a
throwaway rule), which was enough to fix SNTRY-001 for real: backed up the
default rule, deleted it, verified absence, then deliberately tested
restore and found two real things worth documenting. First, restoring the
rule via POST succeeds but is not byte-identical: Sentry assigns
`createdBy` from the requesting token's identity on create, so a restored
default rule no longer matches the `createdBy == null` signature the skill
itself uses to find such rules - a future automated pass won't recognize a
restored copy as the auto-created default anymore. Second, the doctor
gate's claim that deleting this rule needs `project:admin` in addition to
the base elevated scopes does not hold - confirmed live that `alerts:write`
alone was sufficient, with `project:write` and (presumably) `project:admin`
both absent from the token used. Documented both in `setup-sentry/SKILL.md`
and corrected the scope table. Final state: the dead rule stays deleted,
verified absent.

## 0.1.18 (unreleased)

Ran `setup-digitalocean`'s live write path for real for the first time,
against the real Scoutflo DO team account, fixing a real finding from the
earlier `audit-digitalocean` live run: the production API gateway
(`api.app-server.scoutflo.com`) had no uptime check, unlike its staging
sibling. Confirmed live before touching anything that the app's root and
`/health` paths both return `500`, while `/v1/health/ready` (the same path
its staging sibling's existing check already uses) returns `200`. Created
the uptime check plus its three alert rules (down, SSL-expiry, latency),
verified live, then deliberately exercised rollback and found a real bug:
the documented rollback command, `doctl monitoring uptime delete
"$CHECK_ID" -f`, fails outright because `doctl monitoring uptime delete`
has no `-f`/force flag at all (confirmed via `--help`) - unlike `doctl
monitoring alert delete`, which does support `-f` and works as documented.
`doctl monitoring uptime delete "$CHECK_ID"` alone (no flag) deletes
immediately with no confirmation prompt needed. Fixed both occurrences in
`setup-digitalocean/SKILL.md`. Verified the corrected rollback actually
works (deleted, confirmed absence, then re-applied the fix as the final
state). Also confirmed as a false alarm along the way: this account's
database CPU/memory/disk alert policies, which looked like duplicates at a
glance, are actually a correctly-designed two-tier setup (warning +
saturation thresholds) on every database - no change needed there. One
process note: while inspecting those policies for comparison, a real Slack
webhook URL embedded in the policy JSON was printed to this session's own
output before the mistake was caught - flagging it for the record even
though it never reached any committed file.

## 0.1.17 (unreleased)

Ran `setup-grafana`'s live write path for real for the first time, against
a real self-hosted Grafana instance, fixing a real finding from the earlier
audit-grafana live run: the default datasource pointed at a service that
doesn't exist in the cluster. Applied the fix (made the working
VictoriaMetrics datasource the default instead), verified it live, then
deliberately exercised the rollback path to confirm it and found two real
gotchas neither previously documented: (1) restoring a backed-up object
verbatim fails `409 Conflict` because Grafana's datasource API uses
optimistic concurrency on a `version` field that goes stale the moment the
object changes - the live object's current version must be re-fetched and
spliced into the restore payload before PUT-ing it back; (2) a
file-provisioned (`readOnly: true`) object cannot be restored via the API
at all, even for a field Grafana itself changed as a side effect of another
write - confirmed live restoring the previous default's `isDefault` flag
failed `403 "Cannot update read-only data source"`, meaning rollback for a
file-provisioned object requires editing its provisioning source, not an
API call. Documented both in `setup-grafana/SKILL.md`'s backup/rollback
section. Final state: the working datasource is now the real default,
confirmed live-healthy, left in place since it's the objectively correct
fix for this instance.

## 0.1.16 (unreleased)

Found running `audit-sentry` live for the first time ever, against a real
Sentry SaaS org - the last audit skill in this toolkit to get live
coverage. Found and fixed a real, confirmed crash: the SNTRY-005 receiver-
liveness jq (`references/api-checks.md`) had a scoping bug -
`($active | index(.integration_id))` evaluates `.integration_id` with `.`
bound to the piped-in `$active` array, not the outer action object, so it
errors on every real project with `jq: error: Cannot index array with
string "integration_id"`. Fixed by binding the id to a variable first
(`.integration_id as $id | ...`), verified against both a synthetic fixture
and the shape of the real failure. Also documented two smaller real
gaps found live: `/projects/{org}/{project}/uptime/` can return
`405 Method Not Allowed` on real Sentry SaaS rather than the only-documented
404 (the existing `|| echo '[]'` fallback already covers it, no behavior
change, just corrected the doc); and a rule migrated to Sentry's newer
workflow-engine model can show up with empty `conditions`/`filters` but a
populated `errors` array explaining why - the SNTRY-014 noise check should
treat that case as "not representable in this API view," not literally
proven noise. This run also produced a real score (48/100, well below the
85 end-to-end gate) with genuine findings in the org's actual Sentry
configuration - three projects with alert rules that tier by name only with
no real environment field set, a project with zero accepted events in 14
days despite 12 configured rules, unlimited rate limits on every project's
keys, and Sentry's default "notify everyone" rule still active alongside
custom paging rules on one project.

## 0.1.15 (unreleased)

Found running `audit-lgtm` live for the first time ever (the toolkit's
flagship audit skill, previously fixture-tested only) against two different
real backend families in the same session: a Grafana/Loki/Mimir/Tempo stack
and a separate VictoriaMetrics/VictoriaLogs/VictoriaTraces stack. Mimir's
tenant-header example placeholder (`mimir.tenant_id = "your-tenant"`) gave
no hint of the common real-world default: confirmed live that a real
deployment's actual tenant was `anonymous`, the value Mimir falls back to
when multi-tenancy auth was never explicitly configured - not `your-tenant`
or any other guessable string. Also, the failure mode without the right
tenant header isn't always a clean `401`: it can come back as a plain-text
`no org id` body with no JSON content type, which crashes `jq` rather than
failing cleanly. Documented both in `references/backend-checks.md` section
3. Two other apparent gaps raised during these live runs (a VictoriaMetrics
cluster-vs-standalone API path assumption, and undocumented native
VictoriaLogs/VictoriaTraces query syntax) were checked against the same
reference doc and found to be false alarms - the skill already tries the
flat single-node metrics path first and already documents VictoriaLogs'
LogsQL and VictoriaTraces' Jaeger API in full, so no fix was needed there.
Both live runs also produced real scores (60/100 and 55/100, neither
end-to-end) with genuine findings in the audited environments themselves -
dead-end Alertmanager routing, single-replica stores with no HA posture,
unauthenticated public endpoints, and one real cross-cluster trace
contamination finding (a VictoriaTraces instance carrying trace data
labeled with a different real cluster's identity).

## 0.1.14 (unreleased)

Found preparing to run `audit-grafana` live for the first time, against a
real self-hosted Grafana 10.4.1 instance with a freshly minted,
correctly-scoped Viewer service-account token: every Grafana identity check
across this toolkit (`doctor.sh`'s grafana identity check, `audit-grafana`'s
doctor gate, `setup-grafana`'s doctor gate, and `connect`'s verify snippet)
called `GET /api/user`, which returns a hard `403 "Endpoint only available
for users"` for a real service-account token on modern Grafana regardless
of its assigned role - that endpoint identifies an interactively logged-in
user, not a service account. `audit-grafana` and `setup-grafana`'s doctor
gates used `curl -fsS` on this call with no error handling under `set -eu`,
so a real, perfectly healthy audit or setup token would have crashed the
whole gate before either skill ever started - this would have blocked every
customer using a real Grafana service-account token, the exact credential
type `connect`'s own setup instructions tell them to create. Fixed by
switching every identity check to `GET /api/org`, which works correctly for
both service-account tokens and legacy API keys; verified the fix live
against the same real instance (doctor's grafana identity check now passes
200 where it previously would have crashed at 403). Also dropped the
now-redundant `/api/user` identity capture from `audit-grafana`'s
`grafana-audit.sh` (nothing downstream read `identity.json`; `org.json`
already covered identity).

## 0.1.13 (unreleased)

Documented a real edge case found running `map-topology` live against a
second, larger, different real GKE cluster (27 namespaces, 62 workloads):
the mesh-path gate (Istio CRDs present + a ready `istiod`) can be
technically satisfied while the mesh is adopted almost nowhere - this
cluster had 0 sidecars across 27 namespaces except one
`istio-injection=enabled` test namespace, where every mesh object (1
VirtualService, 1 DestinationRule, 1 Gateway, 1 ServiceEntry) also lived.
The skill's own decision rule chose the mesh path correctly; what wasn't
previously called out is that a correctly-chosen mesh path can still yield
near-empty mesh-derived data, which reads like a bug if you don't know to
expect it. Added to Common Failure Modes. No code or command changed - this
run found zero actual skill bugs; every kubectl/jq step (namespace scan,
sidecar coverage, workload join, ingress, VS/DR/Gateway/ServiceEntry
queries, and the T1/T2 pre-check) worked exactly as documented against this
bigger, messier real estate, including 76/76 T2 passes and a correct,
consistent 0/76 T1 result (both fields the pre-check declines to guess -
`environment`, `business_criticality` - correctly left unset rather than
invented in a non-interactive run).

## 0.1.12 (unreleased)

Found running `audit-gcp` for real, live, against a real GCP project for the
first time (74 scored objects, large path - the first live exercise ever of
the large-path worklist/batch/resume machinery, which worked correctly,
including two genuine mid-run crashes that correctly left their rows
`pending` and resumed cleanly rather than being falsely marked `done`): the
`GCP-011` check in `references/gcp-checks.md` section 6 scanned alert-policy
filters for `check_id = "..."` (with spaces around `=`). Real GCP filters in
this project used no spaces (`check_id="..."`), so the documented command
matched zero policies and would have falsely failed GCP-011 for all 12
uptime checks even though every one of them genuinely had a policy. Fixed
the regex to tolerate both spacing conventions (`check_id\s*=\s*"..."`),
verified against both the real project's filter shape and a synthetic
spaced-filter case. This run also produced a real score (50/100, not
end-to-end) with genuine findings - zero logs-based metrics, zero CPU
policies and zero Ops Agent across all 42 VMs, zero dashboards - written to
`scoutflo-audits/gcp/2026-07-20/`.

## 0.1.11 (unreleased)

Found running `audit-digitalocean` for real, live, against a real DO team
account for the first time (19 scored objects, medium path): the
per-database logsink capture in `references/do-checks.md` section 4 had two
real bugs. `doctl databases logsink list <id> -o json` is not a valid
subcommand on doctl 1.155.0 - it silently prints the top-level `databases
--help` text and **exits 0**, so the documented `|| curl fallback` never
fires, and the help banner gets written into `logsinks.json` as if it were
real data. Separately, the fallback's own curl URL was wrong: `/v2/
databases/{id}/logsinks` (plural) 404s; the real endpoint is `/v2/databases/
{id}/logsink` (singular), confirmed 200 live against all 4 clusters in the
account. Fixed by dropping the unreliable doctl subcommand entirely and
calling the corrected singular curl endpoint directly. This one live run
also surfaced five real high-severity findings in the account's actual
observability posture (zero log forwarding on any app, plaintext-stored
secret-shaped env vars on 8/10 apps, a production API gateway with no
uptime check that was observed returning live HTTP 500, three single-node
production database clusters with no standby, and four apps with no
resource alerting) - scored 58/100, written to
`scoutflo-audits/digitalocean/2026-07-20/`. No secret value (token, webhook
URL, app-spec env value) appeared anywhere in the audit's own output,
findings.json, or report.md - verified by grep before this was written up.

## 0.1.10 (unreleased)

Implemented the "guided walkthrough" convention from 0.1.9 for real,
not just documented it: every audit skill (audit-aws, audit-lgtm,
audit-grafana, audit-sentry, audit-alert-routing, audit-digitalocean,
audit-gcp) now compares its estate-sizing count against the previous
run's recorded estate and states plainly whether the estate is
unchanged or how it changed, in the executive summary. Tested the
comparison logic against real data (today's actual audit-aws run)
before propagating to the other six. This is honestly scoped: it is
drift *detection and reporting*, not a skip-the-live-check
optimization - most of these APIs bundle enumeration and live state
in the same response, so there's little to skip without weakening the
"always validate live" rule every audit already follows. Every check
in every phase still runs fresh regardless of drift status.

## 0.1.9 (unreleased)

Two additions closing out the topology-readiness/feedback-loop work:

- `map-topology` now runs its own T1/T2 structural pre-check
  (topology-readiness.md's identity and workload-attribute checks)
  immediately after writing topology-export.json, since it already has
  everything both checks need without any live provider call. A
  customer sees an identity or workload gap on the very first map, not
  after connecting a provider and waiting for an audit to reach that
  service. Verified the jq against a real fixture before shipping -
  caught two real bugs in the process (invalid `$.field` jq syntax,
  which is not valid jq; and `column -N`, a GNU-only flag that breaks
  on macOS/BSD - fixed both before commit).
- Documented a new "guided walkthrough" convention in
  report-standard/README.md: audits may reuse a prior run's estate
  scope (skip full re-enumeration) when topology.md and the estate
  size are unchanged since the last run, but every live check still
  always runs fresh - reuse applies to *what to check*, never to
  *whether a result is still true*. Reports must state which mode ran.

## 0.1.8 (unreleased)

Precise follow-up to 0.1.7's T6 fix, grounded in the platform's exact field-to-correlation-category mapping: camelCase field names are
never split by the platform's category matcher, only exact snake_case
strings or a small set of substring rules. This means several
providers' own `serviceName` field - a real, valid, sometimes-required
attribute-schema field - silently fails to populate the `service`
category T6 needs, even though it correctly satisfies T4. Affected:
AWS CloudWatch (`serviceName`, optional), VictoriaLogs/Tempo/
VictoriaTraces (`serviceName`, required), Sentry (`serviceName`,
optional - and Sentry's only *required* field, `project`, satisfies
just one half of T6's two-part anchor rule). Documented the exact
mapping rules in topology-readiness.md and added specific guidance to
audit-aws, audit-lgtm, and audit-sentry's Topology Readiness
paragraphs: mirror the service name into a literal `service` (or
`service_name`) key so T6 is not silently `partial` on a genuinely
correct edge.

## 0.1.7 (unreleased)

Refined the Scoutflo Topology Readiness spec against
the current topology-correlation requirements rather than the earlier, slightly
out-of-date read. Found T6's "confidence >= 8" rule was a real
oversimplification: the platform also requires a service/workload/app identity
attribute plus either a Kubernetes anchor (namespace/pod/container) or,
for Sentry specifically, a project/environment attribute - before an
edge is actionable. A confidence-8+ edge missing that anchor
combination is downgraded to a non-actionable warning state even
though the number alone would suggest it passes. Fixed T6 in
`report-standard/topology-readiness.md` and the matching confidence
guidance in `skills/map-topology/references/scoutflo-export.md` to
state the full rule, not just the number. This affects all 7 audit
skills' Topology Readiness sections since they all read the shared
spec; no per-skill changes were needed.

## 0.1.6 (unreleased)

Found running `audit-alert-routing` for real against a live GKE cluster
running Google Managed Prometheus (during live end-to-end testing): the estate-sizing check and
two rule-discovery commands hardcoded `kubectl get prometheusrule`, the
Prometheus Operator's CRD. GMP-based clusters (a common GKE choice) use
a different CRD family (`rules.monitoring.googleapis.com`,
`clusterrules`, `globalrules`) and have no `PrometheusRule` type at
all - the command failed outright with "the server doesn't have a
resource type" instead of returning zero rules, breaking the pipe into
`jq` and, in the estate-sizing case, crashing the whole script under
`set -eu`. Fixed all three call sites to degrade to zero/empty instead
of crashing, and documented that the live `/api/v1/rules` check
(already used elsewhere in the same phase, works identically regardless
of CRD family) is the real source of truth either way. Flagged one
narrower, not-yet-fixed gap: the triage-metadata check (ALR-007) still
can't assess anything on a CRD-less cluster since it iterates the CRD
list, even though the live rules API does carry the same labels and
annotations inline - confirmed on the real cluster, but not yet wired
up as an alternate path.

## 0.1.5 (unreleased)

Found while doing a pre-share sanity sweep (confirming no internal-only
skill or identifier had leaked into the customer-facing plugin before
inviting the team to test it): `ci/leak-scan.sh`'s 12-digit-number
check had no allowlist for `123456789012`, AWS's own canonical example
account ID, which this toolkit's AWS skills intentionally use as their
placeholder throughout. Every hit the scanner produced was this same
benign, clearly-commented placeholder - a false positive in the
scanner itself, not a real leak. Added a narrow exception for that
exact value; any other 12-digit run is still flagged.

## 0.1.4 (unreleased)

Found running `audit-aws`'s Phase 2 inventory for real against a live
AWS account (during live end-to-end testing): the log-groups raw capture in
`references/aws-checks.md` section 4 wrote
`subscription_filters_present: false` as a **hardcoded literal** for
every log group, never a real `describe-subscription-filters` call.
The actual AWS-050 check logic (section 10) is unaffected - it
correctly does its own live per-log-group check rather than trusting
this field - but the field sat in `log-groups.json` looking like real
data with nothing marking it as dead, which is exactly the kind of
trap that gets trusted by a future skim instead of a full read. Removed
the misleading field rather than leaving it as a landmine.

## 0.1.3 (unreleased)

Found running `map-topology` for real against a live GKE cluster
(during live end-to-end testing): the workload version-resolution jq in
`references/istio-queries.md` (both the single-pass and large-path
merged-batch copies) split an image reference on every `:` without
first stripping an `@sha256:...` digest suffix. Any image pinned by
both tag and digest - `repo/image:v1.0.1@sha256:<64-hex>`, a common
pattern for GKE-managed images - had its real tag clobbered by the
digest hash: `topology.md` would report the workload's "version" as a
raw SHA-256 string instead of `v1.0.1`. Fixed by stripping the digest
suffix (`split("@")[0]`) before splitting on `:` for the tag. Verified
against the real image string that surfaced this (dranet:v1.0.1-gke.5
from `gke-managed-networking-dra-driver`), a digest-only image with no
real tag (correctly still resolves to `unknown`), and a plain
tag-only image (unaffected).

## 0.1.2 (unreleased)

Found during a live end-to-end walkthrough, simulating a
brand-new customer from a clean `~/.scoutflo/toolkit.yaml`:

- `start`: the skill catalog table and the "run your first audit" step
  were missing `audit-digitalocean`/`setup-digitalocean`,
  `audit-gcp`/`setup-gcp`, and `audit-aws`/`setup-aws` entirely, despite
  the skill's own text promising "installed skills always appear in
  this table." A first-time customer running `/scoutflo:start` had no
  way to discover three fully-shipped, gated audit/setup pairs existed.

## 0.1.1 (unreleased)

Fixes found during a live end-to-end review (first real end-to-end run
of the toolkit, not just rubric review):

- `connect`: every question it asks (which integrations, host, org slug,
  tier, anything) is now always plain chat text, never a structured
  multiple-choice/multi-select tool. Some client environments cap that
  kind of tool at a small number of options and/or require a minimum,
  and connect's Step 1 integration picker (up to 9 rows) and Step 2's
  free-text fields (like an org slug wrapped in a single-option "I'll
  type it" placeholder) hit both limits in live testing, in each case
  crashing the question outright instead of asking it.
- `.claude-plugin/plugin.json`: description and keywords now list
  DigitalOcean, GCP, and AWS, which had shipped but were missing from
  both.

## 0.1.0 (unreleased)

Initial toolkit, expanded through the S0-S3 hardening wave and the AWS
pack (see `docs/skill-review-rubric.md` and the two build plans under
`docs/superpowers/plans/` for the full history).

- Harness: `start`, `connect` (two token tiers, per-provider scopes), `doctor` preflight (script-first, live-tested against real GCP/AWS credentials), `map-topology` (Istio or plain Kubernetes; writes `topology.md` + Scoutflo-aligned `topology-export.json`, worklist/resume batching for large clusters), `audit-all` orchestrator (estate roll-up, combined Topology Readiness, one combined brief), `schedule-audits` (experimental).
- Audits: `audit-lgtm` (flagship, scored), `audit-grafana`, `audit-sentry`, `audit-alert-routing`, `audit-digitalocean`, `audit-gcp`, `audit-aws` (adds a parallel, non-scored Cost & Resource Optimization section sourced from AWS's own recommendation engines).
- Setups: `setup-lgtm`, `setup-grafana`, `setup-sentry`, `setup-digitalocean`, `setup-gcp`, `setup-aws` (confirm-then-verify protocol; independent live-safety gates; worked backup/restore pairs).
- Report standard: findings.json + report.md with weighted scoring, finding lifecycle (new/unchanged/regressed/resolved/suppressed), `exemptions.yaml` with mandatory reason and expiry, pass/total denominators, run-over-run deltas, history-ledger rotation, Scoutflo Topology Readiness section, a generalized parallel-non-scored-section pattern, one-message Slack briefs.
- Quality gate: `docs/skill-review-rubric.md` (~40 parameters) and a project-scoped reviewer skill; `ci/anchor-check.sh` mechanically verifies every `skill#anchor` cross-reference resolves. All 19 skills GATE: PASS.
- QA: 47+ pressure scenarios; CI leak scan, structure, and anchor gates.
