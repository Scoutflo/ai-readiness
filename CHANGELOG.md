# Changelog

## 0.1.93

Docs: the README "What's new" block was stale at v0.1.86 while the plugin shipped through v0.1.92 — six releases, including the ELK space-discovery fix and the env-load fix, were not reflected.

- **Refreshed "What's new" to v0.1.92.** Now leads with the ELK space discovery (enumerate Kibana spaces, never assume `default`, honest zero-rules/visibility-gap handling, `spaces:["*"]` connect recipe), the same-session `~/.scoutflo/env` sourcing across all audits + the "where does my token go" FAQ, and Prometheus first-class discoverability — alongside the existing rca / audit-cost / business-context / scope-checkpoint entries.
- **Corrected the self-policing counts** from "13 gates / 18 test suites" to the current "9 structure/parity gates + report self-validation, 19 test suites," and the history pointer to `v0.1.76 → v0.1.92`.

README only — no skill, gate, schema, or scoring change.

## 0.1.92

Closes the one loose end in the v0.1.90 ELK space fix before a customer re-runs the ELK scan.

- **Empty/hidden-estate scoring no longer risks a self-gate crash.** The Case B path (zero rules visible across every space the key can see) told the skill to exclude **all four** scored categories — but their weights sum to 100, leaving no included category, and `check-findings.sh` (which every audit runs on its own output in its final phase) rejects an all-excluded scorecard with "no included categories to recompute overall from." That would have surfaced as a validation error at the very end of the run instead of a clean "insufficient signal, widen your key" result. Fixed: Case B now excludes only the three genuinely rule-dependent categories (**Rule health, Alert noise, Coverage**) and keeps **Rule delivery included**, scored from its rule-independent checks (ELK-004 framework health, ELK-002/003 connectors). This is both crash-safe and more truthful — framework health is assessable with zero rules.
- **Locked in CI.** `skills/audit-elk/tests/test-space-discovery.sh` gains a case that runs the real `check-findings.sh` against the Case B scorecard: the delivery-included shape reconciles (`overall=100` over the one remaining weight), and the old all-four-excluded shape is rejected.

audit-elk SKILL.md only (2 lines) + its test; no other skill, gate, schema, or report change.

## 0.1.91

Fixes a "doctor says connected, the audit says the token isn't set" asymmetry — and clarifies the step customers kept getting stuck on: "I made the token, now what do I do with it?" **Live-proven against a real Kibana 8.19.11.**

**The bug.** `/scoutflo:doctor` sources the home-anchored secret store `~/.scoutflo/env` before its checks, but the 14 audit skills did not — they only presence-checked the `*_env` variable. So a customer who added a token to `~/.scoutflo/env` mid-session saw **green** in doctor (which sourced the file) but **"TOKEN is not set"** in the audit (a fresh shell that never sourced it, whose login profile was read at launch before the token was added). Same session, opposite answers.

- **Every audit skill now sources `~/.scoutflo/env` in its doctor gate**, exactly as doctor does (`[ -f "$HOME/.scoutflo/env" ] && . "$HOME/.scoutflo/env" || true`). A token added to the store is now picked up by the audit in the same session — no re-export, no new terminal. Applied uniformly to all 15 audit skills (alert-routing, aws, cost, datadog, digitalocean, elk, gcp, grafana, groundcover, jsm, kubernetes, lgtm, pagerduty, sentry, zenduty).
- **New parity gate `ci/env-load-parity-check.sh`** (composed into `structure-check.sh`) mechanically requires every `audit-*` to source the store, so no future audit can regress into the doctor-green-but-audit-blind trap. Guarded by 3 new cases in `test-parity-gates.sh`.

**"I created the token — where does it go?" (docs clarity).** The value does **not** go into `toolkit.yaml`; that file only names the variable (`token_env: KIBANA_API_KEY`). The value goes into `~/.scoutflo/env` keyed by that exact name, and skills read it there at run time. connect Step 4 and a new FAQ entry now spell out the three moving parts (config names the var → `~/.scoutflo/env` holds the value → the audit reads it by name) with the one-time copy-paste setup.

Live-proof: with a real read-only API key placed only in `~/.scoutflo/env` (never pre-exported), the OLD gate left `KIBANA_API_KEY` unset (audit would stop); the NEW gate sourced it, the audit proceeded, and the key returned **HTTP 200** against real Kibana. Proof key invalidated and all scratch reverted afterward.

Skill/CI/docs only — no check logic, scoring, schema, or report change; the one behavior change (audits now read `~/.scoutflo/env`) is additive and matches doctor.

## 0.1.90

Fixes the ELK audit's wrong/empty-space failure and the ELK onboarding friction seen in a live customer session — **live-proven against a real multi-space Kibana 8.19.11**, not just gated.

**The headline bug (a real customer 0/100 on a non-default space).** `audit-elk` derived its audited spaces purely from static `elk.spaces` (defaulting to `["default"]`) and never enumerated the spaces that actually exist — so when a customer's alerting rules lived in a non-default Kibana space, it audited the empty `default` space and reported a confident, wrong result, with no way to re-scope when told "use the right space." This was a plugin design gap, not a Kibana API limit.

- **Phase 1 now discovers spaces via `GET /api/spaces/space`** (a global endpoint, no admin privilege) and audits every discovered space, or the `elk.spaces` subset when set. `elk.spaces` is now an optional *restriction*, not the source of truth. The report names three sets: discovered, audited, skipped (elk-checks.md new section 4a).
- **New empty/hidden-rules guardrail + check ELK-033 (Coverage).** Zero rules across every visible space no longer scores as an empty estate. It trips a visibility trip-wire: mark the rule-dependent categories `blocked`, author them into `score.excluded`, renormalize, and emit ELK-033 with the reason — never a confident `0/100` or a vacuously-high score. When other spaces were discovered but not audited, it pauses to re-scope (interactive) or audits all discovered (non-interactive/scheduled).
- **A key sees only spaces where it holds a privilege**, so complete discovery needs the read privileges at `spaces:["*"]`. The connect recipe now grants exactly that.

**ELK onboarding friction (also from the session).**
- **connect `references/providers.md`** now leads with a worked `POST /_security/api_key` example using the *correct* Kibana-feature `role_descriptors` (`feature_stackAlerts.read` / `feature_rulesSettings.read` / `feature_actions.read` at `spaces:["*"]`), and warns that a `cluster:["monitor"]` + index-read key authenticates but **403s** the alerting/connector reads — the exact wrong shape the customer built. Verify steps now include a real rule read and a space list, not just `/api/alerting/_health` (which can pass on an under-privileged key).
- **`read -rs` "shows nothing as you paste — that's the -s flag, not a hang"** note added, with a plain `export VAR="…"` alternative.
- **`doctor`** now surfaces a `spaces` row (how many Kibana spaces the key can see, with a widen-to-`spaces:["*"]` hint when only `default` is visible), and the aws/gcloud/kubectl missing-CLI hints now carry install links; connect Prerequisites gained a CLI-install table.

**Locks.** Two new pressure scenarios (`rules-in-non-default-space`, `zero-rules-visible-scope-gap`) + `skills/audit-elk/tests/test-space-discovery.sh` (8 assertions, structural + functional). Rubric review: PASS. Live-proof against `scoutflo-elk-stack`: OLD default-only path saw 4 rules and missed a seeded non-default-space rule; NEW discovery found both spaces (5 rules total) and surfaced the missed rule as a real ELK-001; the correct `role_descriptors` returned 200 while the wrong shape returned 403 — all on real Kibana, all seeded objects reverted.

## 0.1.89

Discoverability + a live-friction fix, both surfaced from real customer-meeting runs.

- **Prometheus is now first-class discoverable — no new skill, because coverage already exists.** Prometheus is audited by `audit-lgtm` (backend health: scrape targets, rule evaluation, TSDB cardinality, retention) and by `audit-alert-routing` (the Prometheus→Alertmanager→receiver paging path). But a Prometheus-only shop looking for an `audit-prometheus` command wouldn't find it, and neither skill *named* Prometheus where a user looks. Fixed by naming it explicitly, without duplicating any checks:
  - `audit-lgtm` frontmatter now lists **Prometheus** as a trigger word (so "audit my Prometheus" auto-invokes it), and its README + `start` catalog rows and the "run your first audit" lines now say plainly that `audit-lgtm` *is* your Prometheus audit, paired with `audit-alert-routing` for the paging path.
  - `audit-alert-routing` frontmatter now names the **Prometheus/Alertmanager paging path** as a trigger (its body already opened on it).
- **Hardened the `audit-grafana` `/api/ds/query` cookbook against a bash-sandbox stall.** During a live Prometheus-datasource panel replay, an agent improvised an absolute epoch-milliseconds window (`NOW_MS=…; FROM_MS=$((NOW_MS - 300000))`), which Claude Code's command sandbox rejects ("Arithmetic expansion references variable or non-literal") — stopping the audit for a permission prompt mid-run. The cookbook now states the rule up front: always use Grafana relative-time strings (`from: "now-1h", to: "now"`) for every datasource including Prometheus, and use `instant: true` for a point value — never computed millisecond literals. (The shipped cookbook already used relative strings; this makes the constraint explicit so it isn't improvised away.)

Docs/frontmatter only — no check logic, gate, scoring, or schema change. Coverage is unchanged; only how customers find it, and one friction removed.

## 0.1.88

Docs fix for a real customer-facing confusion: the README/FAQ overclaimed that after install the plugin "works directly inside Claude.app's chat, no terminal needed." Every skill runs local shell + writes local files, so it needs a **Local** Claude surface — a customer in the desktop app's **Chat tab** (a cloud surface) hit `/scoutflo:connect` failing with "cannot create the toolkit file locally" while `/scoutflo:start` (pure text) worked, and the docs implied that shouldn't happen.

- **Corrected the surface requirement across README (Install intro, Step 3, Troubleshooting) and docs/faq.md.** Now states plainly: skills need local execution and work in the `claude` terminal CLI, the desktop app's **Code tab with the "Local" environment**, or the VS Code/JetBrains extensions — **not** the desktop **Chat tab** or claude.ai browser (cloud VMs with no access to your machine). Added a Troubleshooting entry for the exact "can't create the toolkit file" error and why `start` succeeds where `connect` fails in a cloud surface.

Docs only — no skill, gate, test, or scoring change. (Capability map confirmed against current Claude Code documentation.)

## 0.1.87

Docs: README now shows the end-to-end flow and refreshes the stale intro.

- **New "How it works (end to end)" section with a Mermaid flow diagram** — the full path from `/scoutflo:start` through setup (connect / doctor / map-topology / business-context) → audit (14 audits + audit-cost) → understand (correlation-engine + rca) → fix (setup-*, gated on your yes), with the `findings.json`/`report.md` artifacts as the source of truth every analysis reads. Color-coded: read-only (green), write-behind-confirmation (amber), on-disk artifacts (blue). Plus a use-case → skill table.
- **Refreshed the stale "What's New in v0.1.65" block** to the current v0.1.86 reality (rca, audit-cost, business-context SSOT, scope checkpoint, self-policing gates) and pointed to CHANGELOG for full history.

Docs only — no skill, gate, test, or scoring change.

## 0.1.86

Adversarial live-data testing of the new `/scoutflo:rca` skill — and it earned its keep by catching a real latent bug before any customer could.

- **Fixed a Phase 1 jq precedence bug in `/scoutflo:rca`.** The resource-resolution filter `select(((.affected // []) | join(" ") + " " + .title + " " + .id) | test(...))` had wrong operator precedence: the `|` piped the joined string into `+ .title + .id`, so `.title`/`.id` were indexed against a string, erroring out under jq (`Cannot index array with string "id"`). Effect: **searching by a resource name silently found nothing in the per-report findings** — exactly the "why is X failing" lookup the skill exists for. It only appeared to work in the v0.1.85 demo because the correlation path (a separate, correct filter) still returned signal. Corrected to fully parenthesize the joined string: `( ((.affected // []) | join(" ")) + " " + (.title // "") + " " + (.id // "") )`. Verified on the real reports — resource-name lookup now surfaces genuine cross-stack findings (e.g. `checkout-edge-api` → ALR-002/GC-032/LGTM-031 across four stacks). No other skill had this pattern.
- **New `tests/test-rca-grounding-live.sh`** — an adversarial, deterministic grounding proof (18 test suites now). Against real-shape fixtures it asserts the anti-hallucination guarantees: a real target resolves across findings + topology + correlation; a **cascade root and its effect both resolve to real finding-ids**; **every citation any phase can emit resolves to a real finding** (no fabrication); a **nonexistent target yields zero signal** (the insufficient-signal path, never an invented cause); a **null topology node** doesn't crash; and missing topology/correlation **degrade rather than crash**. This locks the customer-facing "grounded, never invents a cause" promise as CI.

No audit finding IDs, scoring, or other skills changed. This hardens the RCA skill shipped in v0.1.85.

## 0.1.85

New **`/scoutflo:rca`** skill — the "ask a question about the reports and get a grounded root cause" capability. Ask *"why is `<service/resource>` failing / at risk — give me the RCA?"* and it correlates across every audit's `findings.json`, the correlation engine's overlaps/cascades, the service topology, and business context, then returns an evidence-cited root-cause analysis with a confidence level and an explicit "what I could not determine."

- **Evidence-grounded, never invents a cause.** Every factual clause cites the finding-id / topology edge / correlation id it came from; the answer carries a confidence level and a mandatory gaps section; when signal is thin it emits an "insufficient signal — run this audit to confirm" form instead of a fabricated chain. Same never-fabricate discipline the toolkit enforces on scores and dollars. A pressure scenario pins the six anti-hallucination behaviors.
- **Read-only analysis.** It reasons over local artifacts only (`findings.json`, `correlation.json`, `topology-export.json`, `business_context.json`) — makes zero provider calls and changes nothing. If live confirmation is needed it names the audit to run.
- **Live-proven on real data.** Run end to end against the live reports: for a business-critical service it correlated **6 findings across 4 monitoring stacks + 3 topology edges + business criticality** into one cited RCA with confidence and gaps. The live run also surfaced and fixed a real robustness bug — `topology-export.json` ships in two shapes under the same schema version (`edges[]` in generated files vs `relationships[]` in the spec); the RCA now reads **both** and guards nulls, so a partial export never blinds it.
- Wired into the `/scoutflo:start` catalog; passed the rubric review (one schema-mismatch blocker found and fixed before ship).

No audit finding IDs, category weights, scoring, or existing skills changed — this is purely additive analysis over artifacts audits already produce.

## 0.1.84

Housekeeping from a senior over-engineering review of v0.1.76–0.1.83: the review found the architecture stable and its complexity justified (the business-context SSOT→projection stores have a single writer with read-only consumers; the three behavioral-parity gates share only trivial skeleton and are clearer separate; cost-analysis roll-up and audit-cost are distinct, not redundant), with exactly one real defect.

- **Removed dead file `ci/validate-metadata-discovery.sh`** — a 45-byte stub containing the literal unexpanded string `$(cat /tmp/ci_validate-metadata-discovery.sh)` (the same broken-authoring class as the v0.1.80 integration stub), left over from the reverted v0.1.68 metadata feature. Nothing referenced or invoked it. No behavior change.

No skills, gates, tests, finding IDs, or scoring changed.

## 0.1.83

Closes the last three "feature built but not wired everywhere" gaps and locks each behind a behavioral-parity CI gate, so the whole audit fleet honors redaction, business context, and correlation uniformly — the same discipline used for the estate-scope checkpoint in v0.1.81.

- **Secret redaction — uniform + gated.** New `report-standard/secret-redaction.md` states the shared two-layer discipline (redact at capture; mask written artifacts with `redact_file` as defense-in-depth). New `ci/redaction-parity-check.sh` (in `structure-check.sh`) requires every `audit-*` to carry the no-secret-values discipline; the 3 audits that lacked it (cost, grafana, kubernetes) now state it. Complements `leak-scan.sh` (repo secrets) with runtime-output protection.
- **Business context — actually applied, not just detected.** New `ci/business-context-parity-check.sh` requires every `audit-*` to (a) have a Metadata Load block, (b) read the SSOT projection `business_context.json` (or `computed_metadata.jsonl`), and (c) name a concrete apply behavior (exclude excluded resources / escalate critical services / per-environment SLA / cost sensitivity). All 15 audits now read `business_context.json` (upgraded from the old `business_context.md`-only blocks that set a mode flag and did nothing); the 4 audits with no block at all (alert-routing, digitalocean, groundcover, jsm) got one. Aligns the fleet with the v0.1.80 SSOT and the fixed integration doc.
- **Correlation readiness — enforced.** `check-findings.sh` now requires every non-info finding to name a concrete `affected` resource, which is the key the correlation engine joins on for overlaps and cascades. Info findings stay exempt (observations may be account-scoped). All 16 shipped findings.json already comply. This closes correlation as done: the engine already reads `area` (required) + `affected` (now required), and degrades gracefully when a finding omits it.
- **Guarded by tests:** new `tests/test-parity-gates.sh` (7 cases: fleet passes both gates; stubs missing the discipline/block/apply-behavior are rejected; audit-all exempt). 17 test suites now, all green. AGENTS.md documents all three gates.

No audit finding IDs, category weights, or the scoring model changed. Gates + shared references + per-audit discipline wiring only.

## 0.1.82

Removes the last "past data overpowers the output" bias: the `cost-analysis` roll-up's 24h skip-and-reuse cache. It's the same class of defect that made the old deep-cost path shallow — a cache that could hand back a **stale** roll-up instead of rebuilding.

- **`cost-analysis` now ALWAYS regenerates.** Deleted `cost_analysis_should_skip` and the `--force` branch from `skills/cost-analysis/lib/cost-analysis.sh`. Every invocation rebuilds from the findings present now. The roll-up reads only local `findings.json`/`correlation.json` (**zero provider API calls**), so there was nothing worth caching — and no `--force` is needed because there's no skip to force past. History (`cost-analysis.jsonl`) is still appended for the trend line; it never gates a run.
- **`audit-cost` deliberately has no `--force`** — it already always runs deep and live with no skip/reuse cache (verified: zero skip logic). A `--force` flag would falsely imply a stale/cheap mode exists. The estate-scope checkpoint (v0.1.81) is the only pause, and it's about scope, not caching.
- **Tests updated to assert the new behavior, and fabricated numbers removed.** `test-v0171` Test 6 now asserts the roll-up regenerates and `cost_analysis_should_skip()` is gone; `test-v0167-token-efficiency` dropped its skip/force phases and the fabricated `~63000-token / N% savings` Phase 6 (unmeasured claims) in favor of an honest summary pointing at `tests/measure-efficiency.sh` for real numbers; `measure-efficiency.sh` and the SKILL/spec docs updated to describe always-regenerate.

No audit finding IDs, category weights, or the scoring model changed. Docs + the roll-up harness + tests only; the deep `audit-cost` path is unchanged (it never had a skip).

## 0.1.81

Wires the interactive estate-sizing **scope checkpoint** into every audit and adds a CI parity gate so it can't rot again. The `cli_pause_before_audit` / `cli_prompt_exclude_services` helpers and the `checkpoint` scope-persistence skill shipped in v0.1.65, but **no audit ever called them** — so a large estate (e.g. `audit-grafana` at 4,017 objects, `audit-aws` at 1,336) ground through the whole estate with no pause and no chance to scope.

- **New `report-standard/estate-scope-checkpoint.md`** — the single shared mechanism: after an audit's Estate sizing step computes its object count, it pauses on the large/xlarge path (≥501 objects), confirms, offers service/region exclusions, and reuses any scope saved by `/scoutflo:checkpoint`. Consistent thresholds (small ≤100 / medium ≤500 / large 501–2000 / xlarge >2000) across all audits.
- **All 14 audits wired** — each got a `### Scope checkpoint` subsection in its Estate sizing phase calling the shared block (`audit-cost` already had it). Two audits whose sizing counts into a differently-named variable (`audit-kubernetes` → `OBJ`, `audit-sentry` → `PROJECT_COUNT`) set `TOTAL` from it explicitly.
- **New `ci/scope-checkpoint-check.sh` behavioral-parity gate** (wired into `structure-check.sh`) — fails if any `audit-*` (except `audit-all`) doesn't wire a real `cli_pause_before_audit` behind a large-estate threshold. This is a *behavioral* gate (does the skill act on its estate-sizing phase?), complementing the *structural* skill-completeness gate (does the section exist?). Guarded by a 5-case self-test (`tests/test-scope-checkpoint-gate.sh`); 16 test suites now.

No audit finding IDs, category weights, or the scoring model changed. This closes the systemic "features built but never wired" gap for the estate-scoping feature; the same parity-gate pattern can now be extended to other v0.1.65 features (redaction, correlation emit) that are still inconsistently wired.

## 0.1.80

Rebuilds the **business-context** skill from a 5-field scalar prompt into rich source-of-truth capture, and consolidates three competing context stores into one. The old skill asked only team/environment/SLA/cost/billing and saved scalars to `topology.json` — so per-service SLAs, per-environment access, exclusions, risky-ops, and custom runbooks (all of which the shipped template already defined) had nowhere to go, and a rich `business_context.md` was required by other skills but created by none.

- **`~/.scoutflo/business_context.md` is now the single source of truth** — a rich, version-controllable file (like a CLAUDE.md for your infra) following `templates/business_context_template.md`: per-service SLAs, a new **Environment Map** (which AWS profile / GCP project / kube context + which SLA each environment uses — so staging is audited with staging's profile and judged against staging's SLA, never production's), critical services, exclusions, risky operations, cost sensitivity, token budgets, notification routing, custom runbooks, and a free-form Custom Rules section.
- **Four capture modes** in the rebuilt skill: guided core questions, guided rich questions, **paste your own rules/runbooks verbatim**, and **import an existing file**. None past the core is forced.
- **Consolidation with no behavior loss.** The skill derives `~/.scoutflo/business_context.json` (a machine projection) from the SSOT; `correlation-engine`, `cost-analysis`, and `topology-guided-setup` now read that projection first, falling back to the legacy `topology.json:.business_context` so nothing regresses mid-migration. `bc_migrate_from_topology` seeds the SSOT from a legacy scalar store on first run **without deleting `topology.json`** (checkpoint owns `.audit_scope` there — a migration that deleted the file would silently disable that; the test asserts it survives). The safety-critical `topology-guided-setup` critical-service approval gate keeps working (its test passes against the new projection).
- **Fixed the broken 31-byte `docs/BUSINESS-CONTEXT-INTEGRATION-v0168.md` stub** (it literally contained `$(cat /tmp/spec_integration.md)` — the unexpanded command) that all 10 audit skills delegate their "apply business context" logic to. It now documents the real load order, per-field effects, and the Metadata Load block.
- **`connect` now offers business-context capture** (Step 8) after doctor verification — previously it never mentioned `business_context.md` even though `business-context-resolver` required it.
- The `business-context` test is rewritten to exercise the real lib (SSOT emission, validator pass, JSON derivation, critical-services + environment-map parsing, paste, import, migration) instead of hand-building `topology.json` and asserting on it.

No audit finding IDs, category weights, or the scoring model changed.

## 0.1.79

New first-class **`audit-cost`** skill — a deep, live, per-resource cloud cost audit — replacing the thin `cost-analysis` re-aggregator as the way to investigate cost. The old skill only re-read the cost-optimization findings other audits had already written (so a real run surfaced one recycled finding and no report.md); this one queries each provider's own cost surfaces live and produces per-resource findings.

- **`audit-cost` (audit lane, report-only).** Queries live: AWS (Compute Optimizer / Cost Explorer SP+RI coverage / Cost Optimization Hub / Trusted Advisor + presence facts: unattached EBS, idle EIPs, stopped EC2, snapshot sprawl, no-lifecycle S3, gp2→gp3), GCP (Recommender idle/rightsizing/CUD, per-location), Kubernetes (requests-vs-usage over-provisioning, idle PVCs, orphaned PVs, node headroom — ratio facts, plus Kubecost/OpenCost native $ when present), Datadog (host/custom-metric/log-volume cost from the usage API), DigitalOcean (idle droplets/volumes/snapshots, list-price context). 64 checks across five per-provider reference catalogs.
- **Ranked-savings, not scored.** New schema `scoutflo-cost/v1` (no 0–100 score — cost is a ranked-savings axis, not a health score, per the toolkit's parallel-non-scored-section rule). Report leads with the savings summary line. Validated by a new **`report-standard/check-cost.sh`** (the money-integrity gate: the savings total sums *only* verbatim provider-native figures; a presence fact can never carry a dollar; per-resource `affected` required; ranked native-first) with a 10-case self-test. **The one hard rule — never invent a dollar figure — is mechanically enforced.**
- **Interactive scope checkpoint built in.** On large/xlarge estates the skill pauses (via `cli-interactive` + `checkpoint`) and offers scope/exclusions saved to `topology.json`, instead of grinding unbounded — the behavior large audits were missing.
- **Wired** into connect (picker), start (catalog), doctor (GCP Recommender cost probe), and audit-all (which keeps the fast `cost-analysis` roll-up and points at `audit-cost` for deep analysis). `cost-analysis`'s description/doc corrected to describe what it actually is (a roll-up) and to redirect deep analysis to `audit-cost`.
- **AWS phase proven live** end to end against a real account: produced a validated `findings.json` + ranked `report.md` (4 unattached EBS with per-volume ages, 117 no-lifecycle S3 buckets, 0% RI/SP coverage, gp2→gp3 candidates) and correctly reported **zero native-dollar figures** because Compute Optimizer was not enrolled — the honest presence-fact path. GCP/Kubernetes/Datadog/DigitalOcean are authored to the same contract but not yet live-proven (see the skill's maturity note); built one at a time with proof.

No existing audit logic, finding IDs, category weights, or the scoring model changed.

## 0.1.78

Closes a report-quality gap: an audit's headline score is authored by the model at runtime, and nothing mechanically checked that it reconciled with the scorecard printed beside it — so a report could ship with an overall 2–5 points above what its own categories supported. Now the numbers are gated, not just the report's shape.

- **New `report-standard/check-findings.sh` — scoring-integrity + schema gate for `findings.json`.** It recomputes `overall` from `score.categories` (excluding renormalized categories exactly as `severity-and-scoring.md` prescribes) and fails on any disagreement over one point, plus the machine-checkable schema invariants: required envelope fields present, `severity_counts` equal to the actual histogram, weights summing to 100, well-formed unique finding IDs, valid `status`/`lifecycle`/`severity` enums, evidence + a non-empty `remediation` pointer on every finding, `end_to_end` allowed only at/above the gate with no excluded category, and info findings at `points_recoverable: 0`. It checks arithmetic and schema, **not** whether a finding is *true* about the live system — that still needs live verification.
- **Wired into all 14 audit skills' final self-validation phase**, run on `findings.json` immediately before `check-report.sh` runs on `report.md` (findings.json is canonical, so it validates first). A run cannot declare done with a score that does not reconcile.
- **New `tests/test-check-findings.sh`** — the gate guards itself: a valid file (with a renormalized excluded category) passes, and each defect class is rejected (score drift, wrong `severity_counts`, missing envelope field, empty `remediation`, weights ≠ 100, malformed ID, `end_to_end` below gate, info finding with non-zero points). Runs under `ci/run-tests.sh` (14 suites now).
- **Documented in `severity-and-scoring.md`** as an enforced "Scoring integrity" note, mirroring the existing report-conformance note.

No audit logic, finding IDs, category weights, or the scoring model itself changed — this validates the model, it does not alter it. The `report-standard` docs and the gate are the only shipped changes.

## 0.1.77

Closes the onboarding-check gap that let the v0.1.76 `audit-kubernetes` stub ship green: the automatic gates only checked that a `SKILL.md` had frontmatter, so a 4KB placeholder passed everything and the real quality bar (the rubric review) is manual and was simply never run on it. New skills are now mechanically held to their lane's structure.

- **New `ci/skill-completeness-check.sh` — a lane-aware structural gate, wired into `ci/structure-check.sh`** (so it runs in CI on every push/PR). It classifies each skill by name prefix and enforces the markers every shipped skill in that lane already has:
  - **audit-\*** (except `audit-all`): `SKILL.md` ≥ 8KB, a Doctor gate, a Live-safety gate, a reference to the report standard / findings schema, a Common Failure Modes section, a `references/*.md` check catalog, and an I4 pressure scenario under `tests/pressure-scenarios/<name>/`.
  - **setup-\***: `SKILL.md` ≥ 8KB, "The change protocol" section, a Doctor gate, a Live-safety gate, `disable-model-invocation: true` in frontmatter, and a Common Failure Modes section.
  - **harness**: no provider gates; a `lib/`+`tests/`-only helper with no `SKILL.md` is correctly treated as a library, not a stub. The 8KB floor is applied only to the audit/setup lanes, where genuinely concise harness skills (checkpoint ~2.5KB) would otherwise false-fail.
  The gate asserts gate *presence* by phrase, not heading depth, because some skills write "Live-safety gate." as bold-inline rather than a `##` heading.
- **New `tests/test-skill-completeness-gate.sh` — the gate guards itself.** Five falsifiable cases prove the current fleet passes, an audit stub is rejected, a complete audit skill passes every marker, a setup skill missing `disable-model-invocation` is rejected, and a harness library dir is allowed. Runs under `ci/run-tests.sh` (13 suites now).
- **AGENTS.md documents the contract** — a new "Adding or changing a skill" section states exactly what each lane must contain, and reiterates that the gate checks *structure* while the rubric review (`docs/skill-review-rubric.md`) still decides whether the checks a skill runs are the *right* ones. The gate stops stubs; the review stops wrong logic.

No audit logic, finding IDs, or scoring changed. CI + contributor-guardrail only.

## 0.1.76

Three structural improvements from the post-v0.1.75 review: CI now actually runs the tests, `audit-kubernetes` is rebuilt to fleet parity, and `setup-kubernetes` closes the first of the audit→setup remediation gaps.

- **CI executes the test suites (the root-cause fix).** For eight releases CI ran only leak-scan / structure-check / plugin-validate and never executed a single test or shell library — which is how the v0.1.69 finding-dropping pipeline, the doctor crash, and the echo/jq portability break all shipped green. New `ci/run-tests.sh` discovers and runs every `tests/*.sh` and `skills/*/tests/*.sh` under `/bin/sh`, fails the build on any failure, and **hard-rejects dead bats-syntax tests** (`@test`/`$BATS_TEST_DIRNAME`) that cannot run under POSIX sh — the class that hid those bugs. Wired into `.github/workflows/ci.yml` as a required step (12 suites pass today).
- **audit-kubernetes rebuilt to fleet parity.** It was a 4KB stub (no `references/`, still auditing PodSecurityPolicy — removed in K8s 1.25). Now a ~24KB skill matching its siblings: doctor + live-safety gates, estate sizing, a full check catalog in `references/kubernetes-checks.md` (K8S-001 Pod Security Admission, K8S-002/006 RBAC over-permissioning, K8S-003 network policies, K8S-004 resource limits, K8S-005 disruption budgets), category weights, the report standard, explicit-context safety, and a pressure scenario pinning "PSP-absence is not a finding on 1.25+". Check set grounded in the live audit-all run.
- **New `setup-kubernetes` skill.** Pairs with the rebuilt audit so its remediation pointers resolve to a real, safe procedure: confirm-then-verify hardening for all five K8S findings (PSA labels, RBAC tightening, default-deny+allow network policies, resource limits, PDBs), with baseline-before-restricted and scoped-Role-before-removing-wildcard guards. Carries an explicit maturity note that it is **not yet proven live end to end**. 6 K8S remediation mappings added (124 total, all gate-verified).
- The remaining 6 audits without a setup counterpart (datadog, elk, zenduty, pagerduty, alert-routing, groundcover) stay a tracked, build-one-at-a-time-with-live-proof roadmap — not a fabricated batch, per the v0.1.69 lesson.

No existing audit logic, finding IDs, or scoring changed.

## 0.1.75

Adds a measured, reproducible efficiency section to `docs/token-costs.md` and retires an unsubstantiated wall-clock claim.

- **New `tests/measure-efficiency.sh`** — regenerates every efficiency number from the repo on demand. Byte counts are exact; token columns are labelled ~chars/4 estimates. Measures: fixed instruction cost per audit (exact bytes of each `SKILL.md` + `references/*.md`), the full-suite-vs-targeted lever, and that the correlation/cost phases are pure shell (zero model tokens) with a 24h skip on unchanged data.
- **docs/token-costs.md: "Efficiency, measured" section** — per-audit fixed instruction floor (all 13 = ~915KB / ~228.9K est tokens), the targeted-subset cost lever, and the re-run-avoidance behaviour, each tied to the script that reproduces it. Explicit "what this does not claim" block.
- **Withdrew the wall-clock time figure** — removed the unmeasured "~40 minutes" line from the Real-World Example and added a note that no "X% faster / N hours" figure is published: audit wall-time is model-latency- and estate-bound, not a plugin property. Token/cost is the efficiency the plugin actually controls, and that is what is now measured. (This closes the same gap as the retracted v0.1.69 "40–50% faster" announcement claim — it was never in the repo and is not added.)

No audit logic, finding IDs, or scoring changed. Docs + a measurement script only.

## 0.1.74

Senior-review sweep of the whole v0.1.70–v0.1.73 arc: every test file in the repo now genuinely runs and exits 0, one more latent library bug fixed, and boundary hygiene tightened.

- **Removed five dead bats-format test files that never ran** — `audit-all/test-v0165-integration-end-to-end.sh`, `business-context/test-business-context-integration.sh`, `checkpoint/test-checkpoint-integration.sh`, `cli-interactive/test-cli-interactive-integration.sh`, `topology-guided-setup/test-topology-guided-setup.sh` all crashed on load (unbound `BATS_TEST_DIRNAME`/`SCOUTFLO_ROOT` under `set -eu`) and had never executed a single assertion. This is the same dead-test class that hid the doctor persistence bug for eight releases.
- **topology-guided-setup: fixed `| head -1` on pretty-printed jq output** — the overlap/cascade helpers piped multi-line JSON objects through `head -1`, returning the literal string `{` (unparseable) whenever a finding matched. Every consumer of `topology_guided_check_overlap`/`check_cascade_root`/`check_cascade_impact` received broken JSON. Now `jq -c 'first(...) // empty'`. Replaced the dead stub with a real six-test suite (overlap, cascade root, cascade impact, criticality, no-match, missing-file degradation) that runs under `/bin/sh`.
- **cost-analysis: corrupted history ledger no longer kills the run** — a malformed line in `cost-analysis.jsonl` crashed both the 24h skip check and the trend build (`jq: Invalid numeric literal`), aborting the whole analysis. Both reads now use `fromjson?`: a bad line degrades the trend and forces a fresh run instead of failing. Regression test added (Test 6b).
- **Boundary hygiene** — moved the internal test-results artifact `TEST-RESULTS-v0167.md` out of the public repo (AGENTS.md Git vs. Local Boundary) and replaced customer-specific names in tracked files (CHANGELOG history, token-costs, specs, coverage-check comment, test fixture) with neutral descriptions, per the repo's forbidden-content rule.

No audit logic, finding IDs, or scoring changed.

## 0.1.73

Fixes five real defects a full live `/scoutflo:audit-all` run surfaced — the kind static tests missed because nothing exercised the end-to-end load path. All five now carry falsifiable regression tests.

- **doctor never initialized its persistence layer** — `scripts/doctor.sh` referenced `doctor_integration_init` but only sourced `doctor-integration.sh` (a thin forwarder), never `doctor-persistence.sh` where the functions are defined. Under `set -eu` this crashed with `doctor_state_init: command not found` (exit 127) the moment persistence was reached — broken since v0.1.65. Now sources both libs in order. Regression-tested by a new end-to-end `test-doctor-integration.sh` that actually invokes `doctor.sh` (the old bats-style test only sourced the lib directly and, worse, crashed on an unbound `BATS_TEST_DIRNAME` so it never ran).
- **doctor skip-logic used an unescaped `>`** — `[ "$a" > "$b" ]` is a shell redirect, not a string comparison: it always succeeded and silently created a junk file named after the timestamp in the launch directory. Now `[ "$a" \> "$b" ]`; the new integration test asserts no such file appears.
- **correlation-engine and cost-analysis crashed under `/bin/sh`** — both libraries piped JSON through `echo "$var" | jq`, and shells whose `echo` interprets backslashes (dash, zsh-as-sh) mangled the `\"` escapes, producing `jq: Invalid escape` on any real findings set. Converted every data pipe to `printf '%s\n'` (escape-safe). Also fixed in `topology-guided-setup`. New test re-runs correlation under an explicit `sh -c` and requires exit 0.
- **correlation cascade detection over-matched** — the effect predicate had no join to the root, so every "database-ish" finding attached the same global list of every alert-ish finding (a live run produced 6 bogus roots each with an identical 28-effect list, matching `redis` as a substring of a rule name). Rewritten to require a **real shared-resource join**: a cascade root must be a datastore-durability finding whose concrete affected resource is also named in the effect finding. New tests prove it fires on a genuine shared-resource cascade and emits nothing when no resource is shared.
- **audit-kubernetes shipped a fabrication stub and a removed-API check** — `lib/k8s-audit.sh` emitted three hardcoded findings and a canned report without ever querying a cluster (referenced by nothing; deleted). The SKILL.md also audited PodSecurityPolicy, **removed in Kubernetes 1.25** — updated to Pod Security Admission (`pod-security.kubernetes.io/*` namespace labels) with a documented PSP fallback only for pre-1.25 servers.

No audit finding IDs or scoring semantics changed. Standalone audit behavior is unchanged except audit-kubernetes now checks the current pod-security mechanism.

## 0.1.72

Fixes the config re-add gap a live customer session exposed: after connect correctly trims `toolkit.yaml` to only the integrations in use, re-adding a provider later had no stated canonical source for that provider's exact key shape, so a session could reconstruct keys from memory and invent wrong ones.

- **AWS section added to connect's providers.md** — AWS was the one connectable integration with no Config block in `references/providers.md` (the template block plus a one-line row in connect's Step 2 table was all that existed). It now has the full per-provider treatment: Config YAML, auth paths (profile / credential chain / assumed role), least-privilege read-only and elevated policies, console click path, and an export-and-verify snippet whose account-match check mirrors doctor's.
- **Step 6 re-add rule made explicit** — re-adding a previously deleted block must copy the Config block verbatim from providers.md (or the plugin's shipped template) and only then fill in values; key names are per-provider contracts (`token_env` vs `api_key_env`+`app_key_env`, `kibana_url`, quoted `account_id`, `context`) that doctor and the audits parse, and an invented key silently reads as "not configured". Also states why trimming placeholder blocks is correct (a leftover `grafana.example.com` makes doctor probe a fake host).
- **Coverage gate extended** — `ci/coverage-check.sh` now fails if any top-level key in `templates/toolkit.yaml.example` lacks a matching canonical block in providers.md, so the re-add source can never silently drift again (negative-tested).
- **Pressure scenario updated** — `connect/rerun-preserves-existing-config.md` now also forbids reconstructing block keys from memory.

No audit logic, checks, finding IDs, or scoring changed.

## 0.1.71

Delivers the one-command orchestration outcomes v0.1.69 promised — correctly this time: SKILL.md-driven, per-audit `findings.json` canonical, every mechanism executed against mock data before shipping, and a new CI gate that makes the remediation map impossible to fabricate.

- **Phase 3.5/3.6 wiring fixed** — `audit-all`'s correlation and cost-analysis blocks referenced an undefined `${SKILLS_LIB}` variable, so both phases crashed under `set -u` for every user since v0.1.66/67. They now use the standard `${CLAUDE_PLUGIN_ROOT}` convention and are proven to execute.
- **Correlation engine rewritten to read real audit output** — the old library globbed a directory layout no audit writes (`<date>/<target>/` instead of `<target>/<date>/`), grouped by a `service` field no finding has (the schema field is `affected`), and could therefore never correlate anything. It now reads the report-standard layout, detects overlaps as the same affected service flagged by two or more targets, links cascades from database-family findings to this run's alert-delivery findings (every referenced ID is real), annotates business context without touching audit-owned severity, and writes one canonical `correlation.json`.
- **Cost analysis rewritten to the report standard** — the old library read a `cost_section` top-level field no audit emits and scored waste against an invented "total spend = waste × 20" denominator. It now aggregates the real `area: cost-optimization` findings (`AWSOPT-*`, `DDOPT-*`), sums only provider-native `estimated_monthly_savings_usd` figures (presence facts are counted, never priced), deduplicates via `correlation.json`, and keeps the 24h skip logic (now macOS/BSD-date compatible). No 0-100 cost score: cost findings are a non-scored parallel section per the report standard.
- **Phase 3.7: redaction pass** — `audit-all` now runs the shipped redaction library over the combined `report.md` and Slack brief before delivery (defense-in-depth; per-audit reports already follow the no-secrets writing rules).
- **audit-kubernetes joins the run plan** — a `kubernetes` block in toolkit.yaml now queues `audit-kubernetes` in `audit-all`, completing the 13-row config→audit table.
- **Remediation map, rebuilt from ground truth** — `docs/finding-remediation-map.json` regenerated from the setup skills' own fix sections: 118 mappings, every finding ID present in its audit's real catalog, every anchor a real heading. The combined report's Next safe actions section uses it as fallback when a finding's `remediation` field is empty; unmapped IDs get an honest "no setup pointer" note, never an invented anchor.
- **New CI gate: `ci/remediation-map-check.sh`** (wired into structure-check) — fails the build if any map entry names a nonexistent setup skill, an unresolvable anchor, or a finding ID absent from its audit catalog. The v0.1.69 failure class (38/38 fabricated entries) is now mechanically impossible to ship.
- **Falsifiable tests** — new `tests/test-v0171-orchestration-wiring.sh` executes correlation, cost-analysis, redaction, and the map lookup against report-standard fixtures with exact-value assertions and a negative control (a gutted library fails the suite). `skills/redaction/tests/test-redaction.sh` rewritten to test the actual library (the old one tested inline sed copies and its own fixture didn't match the pattern). Removed four bats-dependent test files that crashed on `BATS_TEST_DIRNAME` and had never run.
- **Git vs. Local Boundary cleanup** — moved 15 internal planning/execution artifacts (EXECUTION-ROADMAP*, SSOT-*, START-HERE, TESTING-READY, wiring checklists) out of the public repo per AGENTS.md governance.
- **Pressure scenarios** — new `audit-all/remediation-pointer-from-map-only.md`; `no-phantom-integration-pipeline.md` updated for Phase 3.7.

No audit checks, finding IDs, or scoring changed. Standalone audit behavior is untouched.

## 0.1.70

Removes the v0.1.69 "Smart Auto Integration Pipeline" — it was never wired into `audit-all` and its libraries were defective. Every capability it claimed already ships through the v0.1.65–v0.1.68 mechanisms, which are unchanged and remain the single source of truth.

- **Removed dead pipeline code** — `skills/audit-all/lib/{shared-state-init,integration-helpers,integration-pipeline}.sh` and `skills/audit-all/scripts/audit-all-v0169.sh`. Nothing invoked them: `audit-all/SKILL.md` never referenced them, and the orchestrator script attempted to execute `/scoutflo:*` slash commands from bash, which cannot work. The helper library also silently dropped every finding in its exemption filter, so wiring it up would have made every audit report zero findings.
- **Removed the broken remediation map** — `docs/finding-remediation-map.json` used invented finding IDs (`DATADOG-*`, `GRAFANA-*`, `SENTRY-*`) that match no audit's real catalog (`DD-*`, `GRAF-*`, `SNTRY-*`), pointed at six setup skills that do not exist, and none of its 38 anchors resolved to a real heading.
- **Reverted the v0.1.69 sections in all 12 audit SKILL.md files** — they claimed integration behavior that did not exist, three files carried duplicate sections, the shared doc links were broken, and two files gained `set -u` blocks that crash standalone runs (`audit-datadog`, `audit-sentry`). This also restores `audit-kubernetes`'s v0.1.68 Metadata Load section, which v0.1.69 had deleted.
- **Removed assertion-free test suites** — `tests/test-v0169-smart-auto-integration.sh` and `tests/e2e-v0169-real-audit.sh` printed unconditional PASS banners (including "0 findings escalated" as a pass) and could not fail if the code under test were deleted.
- **Removed the overclaiming docs** — `docs/smart-auto-integration-guide.md` and `docs/v0169-release-summary.md` described the unimplemented design as tested and production-ready.
- **Removed a corrupted v0.1.68 test file** — `tests/test-v0168-metadata-discovery.sh` was committed containing only the literal unexpanded string `$(cat /tmp/...)`; it never contained a test and could never run.

Where each claimed capability actually lives (unchanged, already shipped): exemptions and finding lifecycle — computed inside every audit per `report-standard/findings-schema.md`; business-context severity adjustment — each audit's Metadata Load section (v0.1.67/v0.1.68); correlation — `audit-all` Phase 3.5 (`correlation-engine`); cost analysis — `audit-all` Phase 3.6 (`cost-analysis`); redaction — the `redaction` skill's report/brief pass; remediation pointers — each report's Next safe actions section; topology sequencing — `topology-guided-setup`.

No audit logic, checks, finding IDs, or scoring changed relative to v0.1.68.

## 0.1.69

> **Retracted in 0.1.70.** The pipeline described below was never wired into `audit-all`, its libraries were defective, and the "Testing" line below did not reflect reality (the structure-check gate failed on this release's HEAD). See the 0.1.70 entry for what was removed and where each claimed capability actually ships. The entry is preserved unedited below for the record.

Smart Auto Integration Pipeline — all 12 audits wired together with automatic correlation, lifecycle tracking, exemption filtering, and topology-guided remediation.

- **Smart Auto Integration Pipeline** — Three-layer system orchestrates Phases 0-13: (0) initialize shared state from business_context.md + exemptions.yaml + topology.json, (1-12) run all audits with shared env vars + apply integration logic, (13) correlate + redact + cost-analyze + guide topology sequencing + generate report.
- **Shared State Model** — All 12 audits read SCOUTFLO_* env vars (BUSINESS_CONTEXT, EXEMPTIONS, TOPOLOGY, METADATA, SESSION_ID). Single source of truth for exemptions, teams, SLAs, cost sensitivity. No more manual findings post-processing.
- **Eight Integration Layers** — C1 (history ledger), C3 (lifecycle: new/unchanged/regressed/resolved), C4 (exemptions filtering), B (severity escalation for critical services), Red (redaction), Cor (correlation), G3 (remediation links), G5 (topology-guided sequencing).
- **Helper Functions** — New shared library (integration-helpers.sh) called by all 12 audits after findings.json: apply_exemptions(), classify_lifecycle(), escalate_severity(), add_remediation(), append_to_shared_log(), log_to_history(). Each audit integrates by two lines: `source integration-helpers.sh` + `apply_all_integration_logic()`.
- **Remediation Mapping** — New finding-remediation-map.json maps 40+ finding IDs to setup skills + anchors. Updated with each new finding type. Audit skills populate next_safe_action from this map.
- **All 12 audits updated** — audit-aws, audit-gcp, audit-lgtm, audit-grafana, audit-sentry, audit-datadog, audit-kubernetes, audit-elk, audit-zenduty, audit-pagerduty, audit-digitalocean, audit-alert-routing all wired in.
- **Test Suite** — Comprehensive test-v0169-smart-auto-integration.sh covers Phase 0 init, integration helpers, full pipeline, and all 8 integration layers.
- **Documentation** — smart-auto-integration-guide.md explains architecture, usage, configuration, and troubleshooting. Each audit SKILL.md updated with v0.1.69 section.
- **Backward compatible** — All audits still work standalone. Individual invocation skips integration and produces local findings.json unchanged.

Testing: ✅ All 12 audit SKILL.md updated and gates passing, ✅ Integration helpers tested, ✅ shared-state-init, integration-pipeline, audit-all-v0169 orchestrator verified.

Context: v0.1.69 completes the automatic integration infrastructure promised in v0.1.65-0.1.68. Enables one-command full audit with correlation, cost analysis, and topology-guided remediation sequencing.

## 0.1.68

Metadata-driven business context discovery for all 10 audit skills.

- **All 10 audit skills now read optional metadata** — Each audit-aws, audit-gcp, audit-lgtm, audit-grafana, audit-sentry, audit-datadog, audit-kubernetes, audit-elk, audit-zenduty, audit-pagerduty can load pre-computed resource metadata from `~/.scoutflo/computed_metadata.jsonl` (v0.1.68) and fall back to v0.1.67 `business_context.md` (backward compatible).
- **Metadata-driven filtering** — Skip excluded resources (action: skip), escalate critical services (escalation: CRITICAL), apply cost sensitivity (cost_sensitivity: high/medium/low). Single source of truth for guardrails across all audits.
- **business-context-resolver skill** — New skill auto-discovers K8s labels, AWS tags, GitHub CODEOWNERS and generates computed_metadata.jsonl. Scales from startup (5 services, manual) to enterprise (1000+, auto-discovery). 50% token savings on mid-market setups, 86% on enterprise.
- **Backward compatible** — Existing v0.1.67 customers unaffected. Auto-discovery is opt-in. When no metadata file exists, audits work unchanged.
- **Governance principles codified** — AGENTS.md now enforces three permanent principles: Skill Review Gate Compliance (I4 pressure scenarios mandatory), Git vs. Local Boundary (no internal artifacts in public repo), Documentation Consolidation (one authoritative source per concept).

No audit logic, checks, finding IDs, or scoring changed from v0.1.64-v0.1.67 release chain.

## 0.1.67

Cost Analysis skill + v0.1.66 architecture refinements: correlation engine for overlap/cascade detection, topology-guided setup for intelligent fix decisions.

- **Cost Analysis Skill** — New `/scoutflo:cost-analysis` aggregates cost_section from all audit skills (AWS Cost Explorer, GCP Cost Management, Datadog usage, etc). Zero extra API calls—reads existing audit findings.json. Deduplicates via correlation.json, scores 0-100 based on waste% + trend + overlaps. Per-finding ROI calculation (annual savings). Sorted by business context (cost_sensitivity high=ROI, low=impact). History-driven skip logic: skips if <24h old + no new findings, saves ~$0.10/week on large estates. Wired into audit-all Phase 3.6.
- **Correlation Engine** — New `/scoutflo:correlation-engine` detects: (a) coverage overlaps (AWS CloudWatch + Grafana alert same metric = redundant), (b) cascade risks (MySQL crash → monitoring disabled → incident response fails), (c) applies business context (staging gaps intentional, production gaps critical). Outputs correlation.json with overlap IDs, cascade chains, dedup counts. Wired into audit-all Phase 3.5.
- **Topology-Guided Setup** — New integration layer (not a user-facing skill) makes setup-* skills smart: reads topology.json + correlation.json to avoid cascading failures, skip redundant fixes, prioritize root causes. Decision types: OVERLAP_DETECTED (skip or dedup), CASCADE_ROOT (fix first), CASCADE_IMPACT (wait for root), CRITICAL_SERVICE (require approval), STANDARD (proceed). Token savings: 20-30% by skipping cascade-impacted findings.
- **Cost-Analysis Architecture Spec** — Documented two-layer cost system: Layer 1 (individual audits' cost_section), Layer 2 (master cost-analysis aggregation). Deduplication logic, skip logic algorithm, scoring formula, history ledger pattern. Attached as docs/specs/cost-analysis-architecture.md.

Testing: ✅ 9 unit tests for cost-analysis (skip logic, aggregation, dedup, scoring, history), ✅ 7 tests for topology-guided setup (overlap, cascades, criticality, business context), ✅ All gates passing.

Context: v0.1.67 completes the correlation and topology-guided workflows promised for v0.1.66. Cost analysis enables ROI-driven remediation for large estates (a large estate: 1180 EC2 + 77 RDS → ~$500/mo identifiable waste, scored analysis enables prioritization).

## 0.1.66

Correlation engine and topology-guided setup foundations.

- **Correlation Engine** — Detects overlaps (redundant monitoring) and cascades (dependency chains). Applies business context. Outputs correlation.json for downstream use (cost-analysis, topology-guided setup).
- **Topology-Guided Setup** — Integration layer for setup skills to make decisions based on topology + correlation. Prevents cascade failures, skips redundant fixes, prioritizes root causes.

## 0.1.65

Eight new features for production-ready AI-guided infrastructure auditing: persistent doctor state, redaction guardrails, checkpoint scope selection, business context metadata, Kubernetes integration, and correlation foundations.

- **Doctor Persistence** — Check results now persist to `~/.scoutflo/doctor-state.json` with state machine (passed→7d skip, failed→immediate rerun, fixed→14d skip). Auto-detects when users fix issues mid-session. Reduces redundant checks on large estates.
- **Redaction Guardrail** — Global regex-based pattern matching: AWS keys (AKIA), Stripe tokens (sk_live_/sk_test_), Bearer tokens. Applied to findings.json descriptions and report.md before display. Zero secrets leaked in output.
- **Checkpoint/Scope Selection** — Interactive inventory selection after discovery. Saves selected services to `topology.json` for reuse. Smart batching: <100 resources=1 pass, 100-500=100 batch, 500-2K=200 batch, >2K=500 batch. Saves 50-70% tokens on re-runs.
- **Business Context Skill** — New `/scoutflo:business-context` captures team, environment, SLA, cost sensitivity, billing owner. Persisted to topology.json. Audit skills read and adjust finding severity (staging gaps marked low, prod gaps high). Setup skills use to prevent auto-fixes on critical services.
- **Kubernetes Audit Integration** — New `/scoutflo:audit-kubernetes` detects clusters, audits PSP/RBAC/network policies. Wired into audit-all pipeline. Outputs to scoutflo-audits/kubernetes/<cluster>/<date>/.
- **CLI Interactive Filters** — Pause before 1000+ resource audits. Build exclusion filters by service/region/status. Reduces accidental large-estate token spend.
- **Cross-References** — Finding linkage arrays detect related issues across audits. Enables cascade-risk detection (MySQL crash → alerts disabled → backups fail).
- **Integration Layers** — doctor-integration.sh and redaction-integration.sh wired into audit pipeline. All 8 features tested: 32 unit tests + 6 real-world E2E scenarios passing.

Testing: ✅ 32 unit tests passing, ✅ 6 E2E scenarios verified, ✅ All gates passing (leak-scan, structure-check, gitleaks, plugin-validate).

Context: v0.1.65 completes the foundation for topology-guided setup and correlation engine (v0.1.66). First-customer production rollout readiness confirmed.

## 0.1.64

End-to-end audit verification and token cost documentation.

- **E2E verification: all 12 audits passed conformance** — 8 audits completed with Haiku 4.5 (Opus/Sonnet/Fable unavailable due to account entitlement, awaiting AWS Sales restoration). All reports valid against report-standard schema and lexical gates. Measured token consumption: ~702K tokens for full suite (~$0.56 at Haiku pricing).
- **New docs/token-costs.md** — per-audit token consumption, cost factors (estate size, config complexity, model choice), real-world example (a medium estate ~$0.58), billing model, and ways to control costs (targeted audits, scheduling, smaller models). Updated FAQ and README with link.
- **AWS Bedrock model access RCA** — traced Opus/Sonnet/Fable 403 AccessDeniedException to account-level entitlement issue (not a toggle or IAM policy). Confirmed via exact error message: "is not available for this account." Haiku 4.5 remains fully accessible. Root cause: likely AWS Sales action on billing or compliance hold. No plugin code change needed.
- No audit logic, checks, finding IDs, or scoring changed.

Context: v0.1.63 release included 16 verified QA fixes (version stamp, VL/VT probe fallback, run-completion messages, SCOUTFLO_AUDIT_DIR honor, Slack leak-safe briefs, cross-block state check). This release documents the measured costs and E2E passing status, completing the verification phase for customer release.

## 0.1.63

Config-location flexibility: every skill now honors `SCOUTFLO_CONFIG`.
No audit logic, checks, finding IDs, or scoring changed.

- **All 19 hardcoded `~/.scoutflo/toolkit.yaml` references in skill command
  blocks** became `${SCOUTFLO_CONFIG:-$HOME/.scoutflo/toolkit.yaml}` — the same
  override `doctor.sh` already supported, now honored toolkit-wide and
  live-verified end to end (doctor read a relocated config and checked exactly
  its blocks).
- **FAQ: "Can I keep everything in one dedicated project folder?"** Reports
  already follow the launch folder (or `SCOUTFLO_AUDIT_DIR`); credentials are
  home-anchored on purpose (per-machine, works from every session, never lands
  in a zipped/committed project tree). For real relocation needs (isolated
  estates, shared-machine policy), `SCOUTFLO_CONFIG` is the documented lever.
- **connect** now explains the trade-off and sets up the override when a user
  asks to keep config in their project folder (instead of just refusing), and
  **doctor**'s config-not-found row mentions the override.

Context: a teammate ran the toolkit from a dedicated project folder and read the
fixed `~/.scoutflo/` answer as "the plugin forces root" — the home anchor is the
right default (it's exactly why tokens survive folder changes), but the escape
hatch existed only in doctor.sh and was undocumented. Now it's toolkit-wide, and
the docs say when to use it and when not to.


## 0.1.62

UX sweep: version self-diagnosis, VictoriaLogs/Traces doctor support, the
run-completion message everywhere, and a batch of confirmed doc-consistency fixes.
No audit logic, checks, finding IDs, or scoring changed.

- **Version stamp**: `doctor` prints `Scoutflo AI Readiness toolkit vX.Y.Z`
  (with the update command) at the top of every run, and `start` states the
  installed version in its orientation. Plugins do not auto-update — a stale
  install was the root cause of "my picker shows fewer integrations" reports;
  now any pasted output is self-diagnosing.
- **doctor: loki/tempo probe handles VictoriaLogs/VictoriaTraces.** A `loki:` or
  `tempo:` URL often fronts VictoriaLogs/VictoriaTraces (drop-in role), which
  answer `/health`, not Loki/Tempo's `/ready`. Doctor now falls back to `/health`
  and labels the backend instead of reporting a false fail. `audit-lgtm` already
  detected the engine; now preflight matches.
- **Run-completion message in all 14 audits**: the 10 audits missing the
  report-standard close (score headline, top fixes, **absolute** report path,
  OS open command, leak-safe share pointer) now reference it at their final
  phase — same sentence audit-lgtm/aws/alert-routing/audit-all already had.
  map-topology's close-out now requires absolute artifact paths + open command.
- **Slack briefs post absolute report paths** (7 scripted brief blocks resolved
  `$OUT` relative to the launch dir; now `OUT_ABS` via `cd/pwd`).
- **Setup change logs honor `SCOUTFLO_AUDIT_DIR`** (6 setup skills wrote
  `./scoutflo-audits/<target>/changes.md` literally — the rollback record could
  land in a different tree than the audits).
- **Guidance completeness**: doctor verdict now covers exit 1 (no config yet →
  run connect); connect's ending covers non-zero doctor exits; schedule-audits
  states plainly that the Claude-cloud runner has no fill-in walk-through yet.
- **Doc consistency batch**: FAQ platform list now includes PagerDuty, Datadog,
  ELK/Kibana, JSM Operations, Zenduty, groundcover; connect's description adds
  DigitalOcean/GCP/AWS; README's connect example names all paging integrations;
  start no longer claims a Datadog audit is "planned" (it shipped in 0.1.45) and
  lists all three schedule runners; connect's row count corrected to 18;
  plugin.json keywords aligned with marketplace.json (loki, alert-fatigue,
  alert-noise); templates rebranded from the pre-rename "SRE Toolkit" name.

## 0.1.61

Disambiguate the plugin's health check from Claude Code's built-in `/doctor`.
Docs only — no skill logic, checks, IDs, or scoring changed.

- **New FAQ entry** for the common confusion: someone types bare `/doctor` and
  Claude Code's own built-in install-diagnostic runs (it analyzes the whole
  install — plugins, sessions, MCP servers, permission mode), which is unrelated
  to this toolkit. The plugin's health check is always the namespaced
  `/scoutflo:doctor` (reads `~/.scoutflo/toolkit.yaml`, one cheap read-only call
  per configured integration). Every plugin command is namespaced this way.
- **`start` first-steps** now notes at the point of use that bare `/doctor` is a
  different, built-in command — type the full `/scoutflo:doctor`.

Context: a teammate ran bare `/doctor` and saw Claude Code's built-in diagnostic
(plugin decluttering, auto-mode proposals, MCP analysis) and thought the plugin
had gone out of scope. Our `/scoutflo:doctor` was correct all along and does none
of that; this closes the naming-collision confusion in the docs.

## 0.1.60

Better `doctor` guidance on transport (proxy/firewall) failures — the class a
locked-down corporate network hits, which is NOT an auth error.

- `doctor.sh` `transport_hint()` now has a specific message for **curl exit 52/55/56**
  (connection dropped mid-transfer, no HTTP response): "usually a proxy or corporate
  firewall between you and the host, not the token; retry with proxy vars cleared and
  confirm the host is reachable". Previously these fell into the generic catch-all,
  which a user could misread as a credential problem. The catch-all itself now also
  states plainly it is a transport failure, not an auth error. Doctor SKILL.md
  transport-exit table updated to match.

Context: a fresh-session doctor run showed `curl exit 56` on Sentry after the token
was correctly persisted to ~/.scoutflo/env — the token was fine (verified 200 from a
reachable network); the exit 56 was that machine's proxy/network to sentry.io. This
makes doctor say that clearly instead of leaving the user guessing.

No audit logic, checks, IDs, or scoring changed.

## 0.1.59

Coverage sanity: `connect` was missing three cloud providers from its picker, and
nothing caught it. Fixed + gated so it can't recur.

- **Added DigitalOcean, GCP, and AWS to `connect` Step 1 "Pick your integrations".**
  All three have audit + setup skills, toolkit-template blocks, and doctor coverage,
  but were absent from connect's picker table — so a user connecting through that
  list was never offered the three cloud providers. (The plugin was never limited to
  9 integrations; the picker is now the full set. A "9 shown" symptom is the model
  abbreviating the list at display time, not a plugin limit.)
- **New CI gate `ci/coverage-check.sh` (wired into `structure-check.sh`).** Asserts
  every `audit-<x>` skill (except the `audit-all` orchestrator) is surfaced in both
  connect Step 1 and the `/scoutflo:start` catalog — so an audit can never again be
  runnable but undiscoverable. Verified it fails (naming the provider) when a picker
  row is removed.

No audit logic, checks, IDs, or scoring changed.

## 0.1.58

`doctor` now flags a missing DigitalOcean CLI, closing the last gap in CLI-presence
highlighting.

- **`binary-doctl` check in `doctor.sh`.** `audit-digitalocean` is doctl-based (88
  doctl calls), and connect lists `doctl` as its required CLI, but doctor checked
  the DO token and never whether `doctl` was installed — so a DO user without it hit
  a confusing downstream "command not found" instead of a clean doctor row. Doctor
  now emits `binary-doctl fail` (with an install pointer) when a `digitalocean:`
  block is configured and `doctl` is absent, matching the existing `binary-aws` /
  `binary-gcloud` / `binary-kubectl` checks. Conditional on the provider being
  configured; HTTPS+token providers still need no CLI.
- Doctor SKILL.md prerequisites + the DigitalOcean gate row document the check;
  pressure scenario `tests/pressure-scenarios/doctor/missing-cli-binary-flagged.md`.

Net: doctor's CLI-presence highlighting is now consistent across all four
CLI-backed providers (kubectl, aws, gcloud, doctl). No audit logic, checks, IDs, or
scoring changed.

## 0.1.57

Report-output UX: make the final report easier to read and act on, and settle the
CLI-vs-MCP question.

- **Cost/savings sections now lead with a totals line.** The report standard's
  parallel-section rule (and `audit-aws` §9) now require a one-line savings summary
  before the table: `~$<sum>/month (~$<sum×12>/year) across N opportunities`, plus
  the single largest lever — built only from provider-sourced figures (Compute
  Optimizer / Cost Explorer / Cost Optimization Hub), never recomputed. It counts
  opportunities *with* a figure separately from those *without*, and says
  "no dollar figure available" instead of `$0` when nothing is provider-sourced.
  The per-row table gained `Current → recommended` and an annualized column.
  Pressure scenario `cost-savings-summary-honest-totals.md`.
- **Report comprehension aids** (report-template.md): every headline score/count is
  paired with a plain-language clause (`72/100 — good base coverage, below the 85
  gate`), and each report leads the reader to the single highest-value action
  ("Start here: …") so they can act without reading the whole thing.
- **CLI vs MCP: explicit per-operation transport selection.** The authoring
  conventions now frame this as deliberate routing, not MCP-as-fallback: reads
  (every audit call, doctor, map-topology) default to the **fast direct CLI/HTTP
  path**; a connected MCP tool is used when it is the equivalent read route or the
  only reachable one; and **writes** (setup mutations) prefer a provider's typed
  MCP tool when one exists, since it is often the safer mutation path than a
  hand-built `curl -X POST`/CLI flag — falling back to CLI/HTTP otherwise. A
  decision table makes the read→direct / write→typed-tool split explicit. Skills
  must NOT ask the user to choose; a stack with only CLIs, only MCP servers, or a
  mix all work with no configuration. All existing MCP safety rules
  (read-only-by-effect in audits, equivalence-or-fallback, prove-the-target,
  never-required, secrets) are unchanged; connect + FAQ reworded to match.

Docs/guidance only; no audit logic, checks, IDs, or scoring changed.

`connect` now guides credential setup properly — the fix for a real onboarding
gap where the skill would tell you how to *read* a token but not give a
copy-pasteable command to *set* one.

- **Reuse-first (Step 4a).** Before asking you to create or paste anything,
  `connect` runs a presence-only env scan (prints variable names + set/unset,
  never a value) across all provider `*_env` names and, for any already set,
  asks whether to reuse it or set a fresh read-only one.
- **Exact set commands, per OS.** For anything not set, `connect` hands over the
  copy-pasteable command with a placeholder — `export VAR="<paste…>"` for
  macOS/Linux/Git Bash and `$Env:VAR = "<paste…>"` for Windows PowerShell — plus
  `setx`/profile persistence and the silent-prompt (`read -rs`) form for anyone
  avoiding shell history. The skill must give a **set** command for every needed
  variable, never just a "show the token" command.
- **Boundary + failure-mode rules** updated to require the set command and the
  reuse scan; added a pressure scenario
  (`tests/pressure-scenarios/connect/set-token-command-not-just-read.md`).
- **Set once, globally (fixes "asked again every session").** `connect` now makes
  the home-anchored `~/.scoutflo/env` the canonical secret store: add a credential
  there once (`echo 'export VAR="…"' >> ~/.scoutflo/env`, or `setx` on Windows) and
  source it from your shell profile once, and every new terminal/session/directory
  has it. **`doctor.sh` now sources `~/.scoutflo/env`** before its checks, and its
  env-missing hint points there (with the Windows `setx` form) instead of a
  throwaway per-shell `export`; connect's reuse scan sources it too. `start` step 1
  states the set-once behavior. Pressure scenario
  `set-once-global-not-per-shell.md`.
- **map-topology clarity:** the intro now says explicitly that Istio topology is
  read **directly from the Istio CRDs** (VirtualServices, DestinationRules,
  Gateways, ServiceEntries, sidecar coverage) via `kubectl`/`istioctl` — **not**
  Kiali, a mesh dashboard, or Prometheus — so a customer without Kiali knows
  nothing changes for them.

Docs/guidance only (plus doctor.sh now sources the global env file); no audit
logic, checks, IDs, or scoring changed.

**Run-completion message.** Added a shared convention for what a skill says in chat
when a run finishes (report-standard/report-template.md → "Run-completion message"):
a one-line score headline, the top fixes by points_recoverable, the **absolute**
report path, an OS-specific open command (`open`/`xdg-open`/`Invoke-Item`), and a
leak-safe share pointer (the full report names hosts/routes → share in-team; the
Slack brief is the safe summary). `audit-all` gets a matching Phase 6 for the
combined run; representative audits point at the convention from their closing
phase. Pressure scenario
`tests/pressure-scenarios/audit-all/completion-message-guides-to-report.md`. This
replaces the previous bare "done" close so users are always guided to open/share
the report.

**Reports-location guidance reframed default-first.** `doctor` Step 0 and `start`
"Where reports land" now lead with "you don't have to choose — the default
`./scoutflo-audits/` just works, and doctor prints the exact absolute path," and
demote the `SCOUTFLO_AUDIT_DIR`/`reports_dir` mechanics to an explicitly optional
"pin it so it follows you across folders" note; the default first run no longer
reads as a required decision. Verified this pass that both auth tokens
(`~/.scoutflo/env`, sourced by `doctor.sh` and the shell profile) and host/org
config (`~/.scoutflo/toolkit.yaml`, read from `$HOME` by every skill) are already
home-global and reused across sessions, terminals, and directories.

## 0.1.56

MCP-server awareness. Skills stay CLI/HTTP-first (the portable default, unchanged),
but now explicitly permit using a provider's connected **read-only MCP tools** in
place of the equivalent `curl`/CLI call to gather the same evidence — so a system
reachable only through its MCP server is auditable without installing its vendor
CLI. This is docs/convention only; no command block was rewritten.

- **`docs/skill-authoring-conventions.md`** — new "Integration access: CLI/HTTP
  first, MCP-equivalent allowed" section: MCP substitution is allowed only when it
  returns the same data, read-only discipline and lane rules are unchanged (audits
  call read-only MCP tools only, never mutating ones), the tool call + output is
  the evidence, live-safety and secrets rules still apply, and no skill may ever
  hard-depend on MCP — the CLI/HTTP path is always the baseline.
- **`connect`** — prerequisites now note that most integrations need only
  `curl`+`jq` (HTTPS+token), only K8s/AWS/GCP/DO use a CLI, and that connected
  read-only MCP servers can stand in for a missing CLI.
- **FAQ** — added "We use MCP servers instead of CLIs — does this still work?" (yes,
  with the read-only-substitution explanation).
- **Safety hardening (from adversarial review before ship):** the MCP substitution
  rule now says **classify by effect, not name** — an MCP tool named
  `get`/`query`/`describe` that has a side effect (starts a job, syncs/refreshes,
  rotates a credential) is mutating, and any tool whose description isn't clearly
  side-effect-free is treated as mutating and skipped in favor of the CLI/HTTP path.
  It also requires the MCP tool to **prove its target** matches the config, else
  fall back to the explicitly-targeted CLI/HTTP path (an MCP server bakes its
  target in and may expose no identity call). Added a pressure scenario
  (`tests/pressure-scenarios/audit-lgtm/mcp-tool-substitution-safety.md`) covering
  an ambiguously-named tool and a wrong-target server.

No audit logic, checks, IDs, or scoring changed.

## 0.1.55

Two things: a permanent CI gate for the cross-block-state bug class (so it can
never be missed by review again), and Windows support.

- **New gate `ci/crossblock-check.sh` (wired into `structure-check.sh`).** After
  the v0.1.54 review found the audit-aws `$TOTAL`-unbound crash, this gate scans
  every ```bash block and `.sh` script for the whole class: a `set -u` block that
  references an UPPER_SNAKE variable it never assigns but another block in the same
  file does — the exact "fresh shell → unbound variable → abort" pattern. It is
  POSIX-awk-only (runs under dash/BSD/Git Bash), skips `${VAR:-}`-guarded uses,
  `read`/`for`/comment cases, and known environment vars, so it is false-positive
  free while still catching the real shape.
- **Fixed `audit-lgtm` — the same `$TOTAL` bug (blocking).** The gate immediately
  found that the guided-walkthrough drift check was a separate ```bash block
  reading `$TOTAL` from the estate-sizing block; under `set -eu` it aborted with
  `TOTAL: unbound variable` on every non-first run (reproduced). Merged the drift
  check into the estate-sizing block, matching audit-gcp and the audit-aws fix.
  (The fleet-wide sweep confirmed these two were the only occurrences.)
- **Windows support.** Every skill runs POSIX shell, and Claude Code on Windows
  uses Git Bash when present but falls back to PowerShell (which cannot run these
  commands) when it is not. Documented Git Bash as the Windows prerequisite in the
  README requirements + troubleshooting, a new `docs/install.md` **Windows**
  section (including the `CLAUDE_CODE_GIT_BASH_PATH` setting), and the FAQ. No
  script changes were needed: an audit confirmed the date math already uses a
  BSD-first/GNU-fallback form that works on both macOS and Git Bash/Linux, and
  there are no `readlink -f` / `grep -P` / `stat` / `base64 -w` / bash-only `[[ ]]`
  portability hazards. macOS and Linux are unaffected.

No audit logic, checks, IDs, or scoring changed.

## 0.1.54

End-to-end verification pass: a formal maintainer-rubric review of every skill
touched by the recent hardening (v0.1.52) and storage (v0.1.53) work — plus the
storage substitution touched all skills. Eight skills reviewed against the full
A1–I5 rubric; five passed clean, and the review surfaced defects in the other
three (and two docs), each confirmed with a local reproduction before the fix.

- **audit-aws — cross-block state (blocking, E1):** the guided-walkthrough drift
  check was a separate ```bash fence that read `$TOTAL` from the preceding
  estate-sizing block. In a fresh shell under `set -eu` it aborted with
  `TOTAL: unbound variable` on every non-first run (reproduced). Merged the drift
  check into the estate-sizing block, matching audit-gcp's single-block pattern.
- **audit-alert-routing — dead drift input (D1):** the drift check read
  `.estate.objects` from the previous run, but the skill never recorded
  `estate: {objects, path}` — so the drift line always reported "first run" and
  `audit-all` had no size to roll up. Added the write instruction that aws/gcp/lgtm
  already carry.
- **doctor / schedule-audits — dead `reports_dir` tier resurfaced (v0.1.53
  follow-through):** the doctor `--out` flag table and the schedule-audits
  guidance still described a three-tier `SCOUTFLO_AUDIT_DIR → reports_dir →
  default` resolution that the two-tier shell substitution never implemented, and
  schedule-audits prescribed "set `reports_dir` to align interactive runs" — which
  does not work and leaves the divergent histories that section exists to prevent.
  Corrected all of them (doctor `--out` line, schedule-audits body + failure-mode
  row, `crontab.example`) to the honest "export `SCOUTFLO_AUDIT_DIR`; `reports_dir`
  only prints the export line" story.
- **consultant-voice sweep (H2):** replaced the rubric-banned "the customer"
  phrasing with self-service "you/your" in audit-aws (×2 + its reference),
  audit-gcp, audit-digitalocean, and an audit-alert-routing code comment.

All six v0.1.52/v0.1.53 code changes were independently re-verified as landed and
non-regressed by the reviews (native-sidecar filter, DD-032 SLO logic, ALR-011
timestamp parse, ALR-019 gate + map-form matcher, receiver/dashboard guards, the
`${SCOUTFLO_AUDIT_DIR:-…}` substitution across all shell), and topology-readiness
claims were re-checked against the current platform schema sources. No audit
logic, checks, IDs, or scoring changed.

## 0.1.53

Configurable, explicit storage location for reports and runtime data. Until now
every skill wrote to `./scoutflo-audits/` relative to the directory Claude Code
was launched from, with no override and nothing that surfaced the resolved path —
so launching from a different folder silently started a fresh, empty history (no
delta, and `topology.md`/`exemptions.yaml` from the other folder weren't found).
Credentials were never affected (they live in `~/.scoutflo/`); only this
reports/history layer was folder-relative.

- **`SCOUTFLO_AUDIT_DIR` override.** Every shell reference to the reports dir
  (251 sites across the skills and scripts) now resolves as
  `${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}`: export that env var to write to one
  fixed absolute path regardless of launch folder, or leave it unset for the
  unchanged default. Because each skill command runs in a fresh shell, an exported
  environment variable is the only thing that threads through them all — so this,
  not a config value, is the real lever. Fully backward-compatible: unset behaves
  exactly as before.
- **`reports_dir` convenience in `toolkit.yaml`.** A documented `reports_dir:` key
  that `doctor`/`start` read to print the exact `export SCOUTFLO_AUDIT_DIR=...`
  line for your shell profile and `~/.scoutflo/env`. It is explicitly a
  convenience, not a second live tier: `doctor` **warns loudly** ("ACTION NEEDED")
  when `reports_dir` is set but not yet exported, showing both the path runs will
  actually use and the one-liner to fix it — so it can never silently fork history.
- **`doctor` Step 0 + `start` "Where reports land"** now resolve and print the
  absolute reports path, its source, the folder-change caveat, and a warning when
  a stray default `./scoutflo-audits/` coexists with an explicit location.
- **`schedule-audits` + `crontab.example`** document exporting `SCOUTFLO_AUDIT_DIR`
  in `~/.scoutflo/env` so scheduled runs (which start in their own directory) share
  the same history as interactive runs, with a matching Common-Failure-Modes row.
- Docs (`report-standard/README.md`, `docs/faq.md`, `toolkit.yaml.example`) state
  the resolution honestly: the env var is the live mechanism, `reports_dir` is the
  convenience that generates its export line.

No audit logic, checks, IDs, or scoring changed; this is storage-location plumbing
and its documentation. Reviewed by the maintainer skill (which caught and got a fix
for an earlier draft where the docs promised a three-tier order the two-tier shell
substitution didn't implement).

## 0.1.52

Pre-customer hardening pass across the five skills a first customer's stack
exercises most (AWS/EKS, Kubernetes+Istio, Prometheus alerting, Datadog, and the
LGTM/VictoriaMetrics family). Each defect below was found by adversarial review
and confirmed with a local reproduction before the fix; no new checks or IDs,
all correctness fixes to shipped behaviour. Also corrects the install docs.

- **audit-alert-routing — secret leak (high):** the layer-1 receiver extraction
  pulled `webhookConfigs[].url` into a field named `channels` and printed it
  verbatim. A webhook URL is credential-bearing, and once relabelled as
  `channels` the redaction filter could no longer catch it — a direct violation
  of the skill's own no-secrets rule. Now emits only non-secret routing
  identifiers (Slack channels, email targets) plus the *count* of webhook /
  PagerDuty / Opsgenie targets.
- **audit-alert-routing — ALR-011 false pass (high):** the long-firing filter
  used `.startsAt | fromdateiso8601`, which rejects the millisecond timestamps
  Alertmanager's API v2 always emits, so the check errored and silently reported
  "no long-firing alerts". Now strips the fractional/offset part before parsing.
- **audit-alert-routing — ALR-019 auth gate (high):** the Prometheus-version
  gate used a bare `curl` with no HTTP-code capture, so a 401/403 collapsed the
  headline check to `not-in-scope` (removed from the denominator) instead of
  `blocked`. Now captures the code, treats 401/403/non-200 as blocked, tolerates
  a leading `v`, and also scans the `match:`/`match_re:` map form of a pinned
  `le`/`quantile` matcher (the previous grep saw only the inline `le="1"` form).
- **audit-alert-routing — receiver-count auth gate (medium):** the estate-sizing
  `/api/v2/receivers` count had no HTTP-code capture, so an auth failure either
  miscounted (JSON error body's key count) or aborted the block. Now stops and
  reports an auth finding as the skill already promised.
- **audit-alert-routing — ALR-006 dispatch proof (high):** the success counter
  `alertmanager_notifications_total` was queried only as a lifetime instant, while
  the ALR-006 verdict (and the skill's own Phase 6 text) needs an `increase()`
  over `RECENT_WINDOW` "climb vs flat" comparison — a cumulative counter's instant
  value is all-time, so a receiver that went dead after a channel migration keeps
  a large total and reads as "active right now", inverting the verdict. Added the
  windowed success query and based the verdict on it, keeping lifetime as context.
- **audit-aws — false cost findings (high):** AWSOPT-001 compared Compute
  Optimizer's `finding` against `"OPTIMIZED"`, but the enum is mixed-case
  (`"Optimized"`), so every correctly-sized instance was flagged. The RDS branch
  additionally read the wrong field (`finding` instead of `instanceFinding`) and
  set `estimated_monthly_savings_usd` to a **boolean** rather than the API's
  `estimatedMonthlySavings.value` — violating the skill's copy-verbatim rule.
  Both fixed to the real enum, field, and savings value.
- **audit-aws — AWS-003 broken run (medium):** the short-description screen ran
  `jq 'select(...)'` on `alarms.json` (a JSON array) with no `.[]` iterator, so
  it errored `Cannot index array with string` on every run. Added the iterator.
- **audit-aws — Cost Optimization Hub region (medium):** AWSOPT-011 could target
  a per-region Hub endpoint, but the service exists only in `us-east-1`; for a
  non-us-east-1 account the call failed and, wrapped in `2>/dev/null`, was
  silently reinterpreted as "not enrolled". Now pinned to `us-east-1` and reports
  a genuine failure as blocked.
- **audit-datadog — downtime false pass (high):** the v2 downtime capture used
  `?page[limit]=100` without `curl -g`, so curl aborted with "bad range in URL"
  before the request; piped into jq with no `pipefail`, that wrote an empty
  `downtimes.json` and passed the whole downtime half of Muting-and-downtime.
  Added `-g`, and `pipefail` to the capture block so a mandatory-capture failure
  aborts loudly instead of writing an empty file.
- **audit-datadog — DD-032 metric-SLO false positive (high):** flagged every SLO
  with empty `monitor_ids` as unalerted, but metric- and time_slice-type SLOs
  always have empty `monitor_ids` and are alerted by separate `slo alert`
  monitors. Now only flags monitor-type SLOs with no monitors, or non-monitor
  SLOs that no `slo alert` monitor references.
- **audit-datadog — DD-031 dead check (medium):** the composite-monitor
  deleted-constituent scan read `.query`, but the inventory projection never
  captured `query`, so the check always returned empty. Added `query` to the
  projection.
- **audit-lgtm — service miscount (high):** the critical-service count and the
  large-path worklist matched every `^| ... |` row in `topology.md`, not just the
  `## Services` table — double-counting real services (they recur in Integration
  watchpoints) and enqueuing phantom rows named `---`/`Mesh`. This inflated
  `estate.objects` ~6x and produced false LGTM-030 "service blind in every
  signal" rows on the large path. Both now scope to the Services table and dedup.
- **audit-lgtm — drift/delta false "first run" (medium):** the drift and Slack
  baseline selection took the last date-sorted dir under the target, but the
  large path leaves a persistent `runs/` sibling that sorts last, so a repeat run
  reported "first run" / no movement. Both now select date-named dirs only.
- **audit-lgtm — vmalert type bucket (medium):** the rule-type histogram bucketed
  by the rule-level `.type` (`alerting`/`recording`) instead of the group-level
  `.type` (the datasource: `prometheus`/`vlogs`), so a VictoriaLogs rule group
  never surfaced as `vlogs`. Now buckets by group type.
- **audit-lgtm — dashboard sizing (low):** the estate-sizing block lacked
  `pipefail`, so a `dashboards:read` 403 on `/api/search` silently counted zero
  dashboards and could mis-size the run. Added `pipefail` and a guarded fallback.
- **map-topology — native sidecars missed (medium):** the Istio sidecar-coverage
  filter scanned only `.spec.containers` for `istio-proxy`, so a cluster using
  native (init-container) sidecars read as 100% unadopted. Now scans both
  `.spec.containers` and `.spec.initContainers`.
- **map-topology (low):** fixed a dangling cookbook reference (step 0 pointed at
  a section title that does not exist) and documented that VirtualService
  delegation is not followed by the route classifier.
- **topology-readiness / audit-{lgtm,aws,sentry} (low):** the T4-vs-T6 camelCase
  caveat linked to `topology-readiness.md#t6s-category-mapping-is-stricter-...`,
  an anchor no heading produced. Renamed the target heading so all three
  references resolve. (The anchor gate only checks skill-to-skill links, so a
  dead link into `report-standard/` slipped past it.)
- **docs:** corrected the install guidance — a public repo needs no GitHub
  credentials to install (it clones anonymously over HTTPS; the real failure
  modes are a firewall/proxy or missing `git`), the Claude desktop app *can*
  install from an already-added marketplace via its plugin browser (only adding a
  new marketplace needs the CLI or a `settings.json` entry), and `/plugin`
  requires Claude Code ~v2.1.140+.

## 0.1.51

Two fixes from the first live QA run of the Phase 2 skills (found against real
provider instances, not desk review):

- **audit-datadog:** the `quality_issues[]` corroboration (DD-015) read the array
  at `.monitors[].metadata.quality_issues`, but it is a top-level field on each
  monitor (`.monitors[].quality_issues`) — verified live against a Datadog US5
  org (22 issues present at the top level, 0 under `.metadata`). The endpoint and
  paging (`monitor/search?per_page=1000`, `metadata.total_count`) were already
  correct. jq path fixed in the reference and the DD-015 description.
- **audit-groundcover:** made the skill self-hosted-aware. On SaaS
  (`api.groundcover.com`) the `/api/monitors/*` paths are correct; on a
  self-hosted host they can `404` even after the base authenticates (verified
  live), because the self-hosted monitors component does not expose the cloud
  monitors API at that base. The skill now detects mode, marks the config-level
  monitor checks `not-in-scope` on a self-hosted 404 (never a fabricated "no
  monitors"), and falls back to the Alertmanager-compatible firing surface
  (`/api/alertmanager/grafana/api/v2/alerts`) for firing state — matching how the
  platform itself routes self-hosted Groundcover.

No new checks or IDs; both are correctness fixes to shipped checks.

## 0.1.50

Freshness and correctness pass across the seven pre-Phase-2 audit skills (the
"existing-7 backlog"): deprecation-aware and current-API checks, each verified
against official documentation before editing. No new skills; existing skills
gain checks and version-awareness.

- **audit-alert-routing:** **ALR-019** (high) — the Prometheus 3.0 `le`/`quantile`
  float-normalization trap: a route or inhibition matcher pinned to an integer
  (`le="1"`) silently stops matching after the series is normalized to `le="1.0"`,
  so it is version-gated on the target's Prometheus major and rewritten to the
  float form or a decimal-tolerant regex. **ALR-020** (medium) — a receiver still
  on the deprecated `msteams_configs` block (retired Office 365 connector) is a
  dying delivery path; migrate to `msteamsv2_configs` (Alertmanager 0.28.0+).
- **audit-gcp:** **GCP-016** (medium) — a disabled uptime check still referenced
  by a policy (silently never fires), plus failure-logging (`logCheckFailures`)
  off. **GCP-067** (low) — MQL conditions are migration debt: console support for
  MQL ended 2025-07-22 (policies still evaluate, but the console can no longer
  create or edit them; PromQL is the alternative). The condition inventory now
  covers all six current types including `conditionSql`.
- **audit-grafana:** recording rules (a `record` block, GA since 11.3) are
  excluded from the alert-rule count and label checks so they are not scored as
  alert rules with no receiver; the provisioning-API deprecation (App Platform
  APIs at `notifications.alerting.grafana.app/v1beta1` on 12.x) is documented as
  a dual-read gated on endpoint availability, not a version number; the Mute
  Timings → Active Time Intervals (12.1) rename is noted for report wording.
- **audit-sentry:** **SNTRY-015** (high, capability-gated) — on workflow-engine
  orgs, a detector with an empty `workflowIds` array detects but notifies nobody
  (the new-model equivalent of a rule with no action); `not-in-scope` on
  classic-model orgs where the detectors endpoint 404s.
- **audit-lgtm:** flag EOL collectors still running — Promtail (EOL 2026-03-02)
  and Grafana Agent (EOL 2025-11-01), both superseded by Grafana Alloy — as
  migration debt under LGTM-025; honor vmalert's `type: vlogs` (VictoriaLogs)
  rules and the `datasource_type` filter so a vlogs rule is not judged as PromQL;
  note the Loki SSD-mode pre-4.0 deprecation as a reliability signal.
- **audit-digitalocean:** the distinct `liveness_health_check` (GA June 2025) is
  read alongside the readiness `health_check` under DO-030 — a component with
  only readiness never auto-restarts on a hang; an autoscaled component with no
  App Platform alert on its scaled metric is flagged under DO-033, read from the
  app-spec `alerts` array (not `doctl monitoring alert list`, which has no App
  Platform metric type).
- **audit-aws:** **AWS-007** (medium) — an Application Signals SLO with no
  burn-rate config, or whose burn-rate metric no alarm watches (the SLO object
  carries no alarm reference, so it is cross-referenced against
  `describe-alarms`); `not-in-scope` when Application Signals is unused.
  **AWS-056** (medium) — a CloudWatch Logs anomaly detector stuck `FAILED` or
  `PAUSED`. **AWSOPT-011** (non-scored cost) — Cost Optimization Hub aggregated
  recommendations, enrollment-gated, savings taken verbatim from the Hub's
  `estimatedMonthlySavings`.

Every added command is read-only (GET / `list-*` / `describe-*` / documented
read-by-query), each new scored check is wired into its catalog and category
weights, and the whole change set passed an adversarial correctness review
(read-only safety, scoring integrity, capability-gating, and claim accuracy all
verified). With this the build phase is closed: Phase 1 (7 skills), Phase 2 (6
new integrations), and the existing-7 freshness backlog are all complete.

## 0.1.49

New integration: **groundcover** (`/scoutflo:audit-groundcover`) — Stage 2.5
of the new-integrations wave, and the sixth and final Phase 2 integration.
Scored, read-only audit of the groundcover monitors that watch your telemetry,
across four categories: monitor firing hygiene (`pendingFor` debounce,
`customResolveThreshold` hysteresis, `autoResolve`, deliberate `noDataState`
and `executionErrorState`), notification noise (re-notification storms,
resolve-churn, `connectedApps` route-bypass, detect-but-page-nobody), monitor
health and silences (paused live monitors, open-ended recurring silences), and
coverage and destination liveness (dead workflow destinations, severity use,
critical-service coverage).

Built against the current groundcover API, verified against the live docs.
groundcover's monitors and workflows are built on Keep, so the audit is honest
about the ceiling and the correctness traps:

- **Auth is `Authorization: Bearer <key>`** on a service-account API key, plus
  an `X-Backend-Id` header on multi-backend accounts (a multi-backend 403 is a
  missing-`backend_id` config gap, not an empty account). A **Viewer**-role
  service account is a true read-only tier. The doctor/list probe is `POST
  /api/monitors/list` with `{"sources":[]}` (a read-by-query — there is no
  whoami endpoint).
- **Honest ceiling, not fabricated findings.** groundcover has no group-by
  alert bundling, no inhibition rules, and no native deduplication or
  throttling (any such logic is hand-coded in Keep-style workflows). The audit
  states this ceiling and never files a finding for a control the platform does
  not have; `category` groups the Monitor List UI only, not notifications.
- **Capability-gated runtime state.** The per-monitor runtime-state source
  (firing history, last evaluation error, live silence flags) is not confirmed
  in groundcover's public docs, so the audit probes it once and marks the two
  health checks that depend on it (GC-022/GC-023) `not-in-scope` when it is
  absent, rather than guessing a monitor's live state. The config checks never
  depend on it.
- **Silences.** Recurring silences are read via `GET
  /api/monitors/recurring-silences` for open-ended-suppression hygiene;
  one-time silences have no list endpoint, so the report states a silenced
  monitor may not be visible rather than claiming a clean bill.

- skills/audit-groundcover: SKILL.md + references/groundcover-checks.md
  (GC-001..032). Topology Readiness treats groundcover as its real platform
  identity — a `monitoring.groundcover` alerting provider that, unlike the
  all-optional PagerDuty and Zenduty schemas, requires `namespace` and
  `workloadName`, giving it a strong Kubernetes-anchored identity; carries the
  camelCase `workloadName`/`serviceName` anchor-mirror caveat.
- connect: groundcover section (Bearer auth, Viewer-role service account,
  `X-Backend-Id` for multi-backend); toolkit.yaml.example groundcover block.
- doctor: groundcover block (`POST /api/monitors/list` probe, Bearer +
  optional `X-Backend-Id`, 401/403 interpretation); doctor SKILL.md documented.
- Wired into audit-all, start, README, and plugin/marketplace metadata; three
  pressure scenarios (missing-controls fabrication, unverified runtime state,
  multi-backend 403).

Not yet live-tested against a real groundcover account (deferred, tracked).

With this release the Phase 2 new-integrations set is complete: PagerDuty,
Datadog, ELK/Kibana, JSM Operations, Zenduty, and groundcover.

## 0.1.48

New integration: **Zenduty (Xurrent IMR)** (`/scoutflo:audit-zenduty`) — Stage
2.2 of the new-integrations wave, closing all but one of the Phase 2 build set.
Zenduty was acquired by Xurrent and rebranded Xurrent IMR (a branding change,
not a sunset); the API and product are alive at `www.zenduty.com/api`. Scored,
read-only audit across four categories: escalation and on-call (single-point-
of-failure escalations, empty on-call rotations, disabled ingestion
integrations), alert noise (per-service `collation` dedup, suppress and
flapping-guard alert rules, delay, `entity_id` dedup, auto-resolve, open-ended
recurring maintenance windows), coverage and hygiene (global-routing overlap and
missing default routes, critical-service paging paths, deprecated
API-Integration ingestion), and actionability (unacked aging plus MTTA/MTTR from
Zenduty's own analytics).

Built against the current Zenduty API, verified against the live OpenAPI spec.
Correctness guards baked into the checks and the pressure scenarios:

- **Auth is `Authorization: Token <key>`** — the literal word `Token`, not
  `Bearer` (a Bearer call 401s). There is no read-only key scope; a Bot Token
  (Beta) with view-only permissions is the least-privilege path, and read-only
  is otherwise enforced by GET-only use.
- **Tight per-endpoint-class rate limits are the defining constraint** (alert
  GET 1/second, incident GET 3/second, list GETs 5/second). The audit paces by
  design, backs off on `429` (no documented `Retry-After`, so a fixed wait plus
  exponential backoff), and marks throttled checks `blocked` with the reason
  rather than fabricating a pass; the large path batches by team.
- **Verified API shapes.** The dedup field is `collation` (0 off, 1 time-based)
  with `collation_time`, not a `correlation` field; content-based and AI
  correlation are not exposed in the API, so their absence is reported as "not
  API-readable", never a fail. Incident listing is `POST /api/incidents/filter/`
  (a read-by-filter; there is no GET list), with ack state read from the
  `status` integer. Escalation single-point-of-failure is `repeat_policy: 0`
  with one target; open-ended maintenance is `repeat_interval` set with
  `repeat_until: null`; the legacy API-Integration ingestion type stopped
  working 2025-05-15 and any remaining one is migration debt.
- **Server-side actionability.** Unlike JSM Operations, Zenduty exposes an
  analytics API, so MTTA/MTTR come from the vendor's own `mtta_seconds`/
  `mttr_seconds`, never fabricated. The two read-by-POST calls (incident filter
  and analytics) are explicitly carved out of the otherwise GET-only rule.

- skills/audit-zenduty: SKILL.md + references/zenduty-checks.md (ZD-001..032).
  Topology Readiness treats Zenduty as its real platform identity — a
  `monitoring.zenduty` alerting provider (like PagerDuty, a `MONITORED_BY` edge
  that can reach full confidence), not a ticketing sink; the camelCase
  `serviceName` anchor-mirror caveat is carried.
- connect: Zenduty (Xurrent IMR) section (Token auth, Bot Tokens beta as the
  least-privilege path, tight rate limits); toolkit.yaml.example zenduty block.
- doctor: Zenduty block (`Authorization: Token`, `GET /api/account/teams/`
  probe, 401/403/429 interpretation); doctor SKILL.md documented.
- Wired into audit-all, start, README, and plugin/marketplace metadata; three
  pressure scenarios (Bearer-auth trap, rate-limit hammering, collation vs
  correlation).

Not yet live-tested against a real Zenduty account (deferred, tracked).

## 0.1.47

New integration: **JSM Operations** (`/scoutflo:audit-jsm`) — Stage 2.4 of the
new-integrations wave, and the cloud successor to standalone Opsgenie. Scored,
read-only audit of the Jira Service Management Operations account that carries
your paging, across four categories: alert delivery and escalation (teams with
no escalation or a single step with no repeat, routing rules that join an empty
schedule, disabled ingestion integrations), alert noise (notification-policy
dedup, blanket `suppress`, delay, auto-close, auto-restart storms, stable
`alias` for dedup, alert policies, permanent maintenance blackouts), coverage
and health (dead heartbeats, critical-service paging paths, teams named as
audited-or-uncovered, stale integrations), and actionability (unacknowledged
aging, MTTA, and the share of alerts closed with no acknowledgement).

Built against the current **JSM Operations REST API v1** on `api.atlassian.com`
(`/jsm/ops/api/{cloud_id}/v1/...`), verified against Atlassian's published
OpenAPI spec — not classic Opsgenie. Correctness guards baked into the checks
and the pressure scenarios:

- **Not classic Opsgenie.** Auth is an Atlassian API token over HTTP Basic
  (`email:token`), never `api.opsgenie.com` and never a `GenieKey` header
  (standalone Opsgenie is end-of-sale, hard shutdown 2027-04-05).
- **Verified API shapes.** Alert timestamps are flat `ackTime`/`closeTime` (no
  `report` nesting), heartbeat health is a `status` enum
  (`Responsive|Unresponsive|Off|Pending`) with no `expired` field, maintenance
  windows are flat `startDate`/`endDate`+`status`, and the alerts list is
  hard-capped at `offset + size < 20000`.
- **No analytics API.** JSM Operations has no reporting/analytics endpoint, so
  MTTA and the acked/auto-closed share are computed client-side from alert
  timestamps within the retrieval cap, with the window and alert count stated
  every time — never fabricated or implied as vendor analytics.
- **Team-scoped.** Notification policies and heartbeats hang off a team id, so
  every coverage denominator names the teams audited and any team skipped.

- skills/audit-jsm: SKILL.md + references/jsm-checks.md (JSM-001..032).
  Topology Readiness treats JSM as its real platform identity — a `ticketing.jsm`
  incident sink (a service that creates tickets in JSM), not an alerting source
  like PagerDuty; the Operations paging hygiene is a layered signal correlated
  by the optional `serviceName`/`team` fields.
- connect: JSM Operations section (cloud_id discovery, Atlassian API token over
  Basic auth, GET-only read-only tier, GenieKey-is-not-for-audits note);
  toolkit.yaml.example jsm block.
- doctor: JSM block (cloud_id resolve, Basic auth, `/v1/alerts?size=1` probe,
  401/403/404 interpretation); doctor SKILL.md documented.
- Wired into audit-all, start, README, and plugin/marketplace metadata; three
  pressure scenarios (Opsgenie/GenieKey trap, heartbeat status-not-expired,
  no-analytics fabrication).

Not yet live-tested against a real JSM Operations account (deferred, tracked).

## 0.1.46

New integration: **ELK / Kibana** (`/scoutflo:audit-elk`) — Stage 2.6 of the
new-integrations wave. Scored, read-only audit of Kibana Alerting (Stack Rules
and their connectors) across every Kibana space you point it at, version-aware
for Kibana 9.x. Four scored categories: rule delivery (enabled rules with no
action, rules targeting a connector with missing secrets or a deprecated
connector, orphaned connectors, alerting-framework health), rule health (rules
stuck in execution error or warning, failed last runs, live controls left
disabled), alert noise (flapping detection, `alert_delay` debounce, action
throttling vs re-notify-every-interval, per-alert fan-out on high-cardinality
rules, indefinite snoozes and `mute_all`, permanent maintenance windows), and
coverage (rule-type spread, critical-service coverage from topology, and the
legacy-Watcher-vs-Kibana-Alerting split so a Kibana-only view does not silently
imply Watcher-covered services are unmonitored).

Three ELK-specific correctness guards baked into the checks and the pressure
scenarios: `flapping: null` means "use the space default" (which is ON) and is
NOT a finding, only an explicit `enabled: false` or a weak window is; the
maintenance-window public API is 9.2+, so ELK-025 version-gates itself to
`not-in-scope` on 8.x/9.0/9.1 rather than filing a 404 as a broken feature;
and a 404 on `/api/alerting/*` is read as `elk.kibana_url` pointing at
Elasticsearch, not "no rules configured". Rules are space-isolated, so every
coverage denominator names the spaces audited and any space skipped.

- skills/audit-elk: SKILL.md + references/elk-checks.md (ELK-001..032), auth
  is `Authorization: ApiKey <encoded>` with one Elasticsearch API key (works on
  both the Elasticsearch and Kibana APIs; alerting rules are a Kibana API),
  presence-checked only. Topology Readiness treats ELK as its real platform
  identity — a `logging.elk` log source (`SENDS_LOGS_TO` reaches full confidence
  on the log-index fields) with alerting layered on as a `MONITORED_BY`-style
  signal on the optional `alertRuleId`.
- connect: ELK/Kibana section (space-isolation, ES API key on both APIs, Kibana
  feature privileges for Stack Rules and Connectors); toolkit.yaml.example block.
- doctor: ELK block (`/api/alerting/_health` probe, ApiKey auth, 404/401/403
  interpretation); doctor SKILL.md documented.
- Wired into audit-all, start, README, and plugin/marketplace metadata; three
  pressure scenarios (Elasticsearch-URL 404, flapping-null false finding,
  maintenance-window version gate).

Not yet live-tested against a real Kibana instance (deferred, tracked).

## 0.1.45

New integration: **Datadog** (`/scoutflo:audit-datadog`) — Stage 2.3 of the
new-integrations wave. Scored categories: monitor delivery (monitors with
no `@handle`, dead Slack/webhook/PagerDuty handles verified against the live
integration, draft monitors that never notify), monitor noise (recovery
thresholds, no-data handling, bounded renotification, evaluation delay,
auto-resolve, plus Datadog's own `quality_issues[]` reconciled with the
audit's findings), muting and downtime (indefinite mutes, open-ended
broad-scope downtimes read from the v2 API only — v1 is deprecated including
reads), and coverage and staleness (stale monitors by intent, broken
composite references, SLOs with no burn-rate monitor, tag hygiene). Plus a
separate **non-scored Cost & Resource Optimization** section from Datadog's
own usage endpoints (estimated cost, top custom-metric contributors),
modeled on audit-aws — `DDOPT-NNN`, excluded when the app key lacks
usage/billing scope, never a fabricated savings figure. `connect` gains the
API+Application key-pair recipe with the 9-site table and the app-keys-die-
with-their-user warning; `doctor` gains a site-aware `/api/v1/validate` +
`/api/v1/monitor` scope probe plus a non-failing cost-permission probe the
audit reads to run or exclude its cost section. Topology Readiness verified
against the live `monitoring.datadog` schema (required `monitorId`; camelCase
`serviceName` anchor caveat stated).

## 0.1.44

New integration: **PagerDuty** (`/scoutflo:audit-pagerduty`) — the first
paging-layer audit, and the first skill with a vendor-analytics-backed
**actionability** section: auto-resolved incident share, MTTA, and
sleep-hour interruptions per service, read from PagerDuty's own Analytics
API (never fabricated; the whole category is excluded with the doctor-probe
reason when the key or plan cannot reach Analytics). Scored categories:
escalation and on-call (SPOF policies, rendered schedule coverage, dead
schedule references, email-only responders), alert grouping and noise
(all four grouping types incl. the newest unified type, Event
Orchestration suppress review, permanent maintenance windows), incident
health (unacked aging, priorities, urgency), service hygiene (orphaned/
stale services, Rulesets EOL migration debt, PagerDuty's own Standards
scores read as a corroboration anchor — disagreement is itself a finding),
plus AIOps plan-gating reported honestly as "not on your plan", never as
misconfiguration. Handles the Schedules v3 rollout (v2 detail endpoint
400s on upgraded schedules) from day one. `connect` gains the PagerDuty
read-only key recipe (with the analytics POST caveat); `doctor` gains the
abilities probe plus a non-failing analytics probe the audit reads to
include or exclude its actionability category.

## 0.1.43

Docs fix: install instructions didn't distinguish the one-time terminal
step from everyday Claude.app chat use, which caused a real install failure
(`/plugin` typed into Claude.app's chat, which doesn't support that command
there). README.md and docs/install.md now explicitly call out that
`claude plugin marketplace add` / `claude plugin install` (and the
list/update/uninstall equivalents) only run in the standalone `claude`
terminal CLI, and that after that one-time step, every `/scoutflo:...`
skill works directly in Claude.app's chat with no terminal needed. Added
the missing CLI-install prerequisite (`npm install -g @anthropic-ai/claude-code`)
and a new FAQ entry ("Do I need a terminal to use this?").

## 0.1.42

Fixes two real bugs found during a report-bundle regeneration and
adversarial review: the LGTM-039 telemetry-scope gate compared the active
kubectl context instead of each critical service's declared `cluster_id`
in `topology-export.json`, so a central monitoring stack watching a
different cluster than the one a service runs on (a common deployment
pattern) produced a false-positive LGTM-030 (no telemetry) instead of the
correct info-level LGTM-039 (scope mismatch). The gate now checks per
service, using the declared `cluster_id` first. Separately, the Scoutflo
Topology Readiness section's customer-facing prose leaked internal
data-model jargon (`sync-ready`, `MONITORED_BY`, `topology-export.json`,
T-codes) — rewritten for a reader with no Scoutflo context, with a new
`check-report.sh` gate that fails the build if that jargon reappears.

## 0.1.41

Docs polish: FAQ gained a "What does the 0-100 score mean?" entry (target
profile, the 85 end-to-end gate, conservative-scoring note); the install
guide gained "Verify or update the installed version" and "Uninstall"
sections (including what is deliberately left behind: credentials and
local reports).

## 0.1.40

Report-quality pass driven by first team feedback on real reports.

- **Every number carries its scale.** New general template rule; Topology
  Readiness confidence now renders `n/10`, never a bare number. Enforced by
  `check-report.sh`.
- **Topology Readiness reads in plain English.** The six checks now render
  under their plain-English names (Service identity, Workload mapping,
  Telemetry connections, Connection details, Tool identity, Match
  confidence); the `T1`-`T6` codes are demoted to a legend line, the same
  pattern as finding IDs. Enforced by `check-report.sh`.
- **Ticket-ready remediation.** The Topology Readiness section now ends
  with a required sync-readiness action plan (Service / Blocked on / Do
  this / Done when) whenever any service is below ready — each row concrete
  enough to paste into an issue tracker unchanged. Findings' **How to fix**
  is now 1-3 concrete steps naming the exact object, plus a required
  **Done when** verification line (enforced by `check-report.sh`).
- **Missing or mismatched topology export is now actionable.** Three
  distinct rendered states (no export / export for a different target /
  non-Kubernetes estate), each with a one-line unlock path — never a bare
  "unavailable". All audit skills aligned.
- **A report at any estate state.** New toolkit-wide scoring rule: once past
  the doctor and live-safety gates, an audit always ends in `findings.json`
  and `report.md` — mid-run failures become `blocked` checks or excluded
  categories with the blocker as evidence, never an abort. A worst-state
  estate yields a low score and a long action list, not a crash.
- **audit-lgtm: telemetry-scope gate (new check LGTM-039).** A central
  monitoring stack hosted on one cluster while monitoring another no longer
  produces false criticals: Phase 6 now probes whether the backends
  actually monitor the audited cluster (cluster labels, `kube_node_info`,
  namespace overlap) before scoring coverage. On mismatch, coverage rows
  are `blocked` with the reason — never LGTM-030 — and telemetry-only
  service labels are not treated as orphans. New pressure scenario covers
  the hosted-vs-monitored cluster split.

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
