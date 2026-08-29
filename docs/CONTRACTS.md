# Cross-skill contracts & linkages

**Read this before adding or changing any skill.** This is the map of every
data/behavior contract that ties the plugin's skills together — what each
contract is, who produces it, who consumes it, the invariant that must hold, and
the **guard** that enforces it (a `ci/` gate that runs on every push, a
`tests/*.sh` suite run by `ci/run-tests.sh`, and/or a local `selftest/run.sh`
case). When you touch a producer, every consumer and its guard is your
responsibility; the guard is what stops the drift this document exists to
prevent.

Two enforcement layers:

- **CI gates + test suites** (in this repo) run on **every push/PR** and block
  the merge — this is the "checked by default" layer. `ci/structure-check.sh`
  composes the structural/behavioral gates; `ci/run-tests.sh` runs every
  `tests/*.sh` and `skills/*/tests/*.sh` (which exercise the *real* libs).
- **`selftest/run.sh`** (local-only, a sibling of this repo — not shipped) is the
  richer behavioral net: it builds fixtures, runs the real libs and scripts
  end-to-end, and locks every bug a past review found. Run it before shipping a
  behavior change: `sh ../selftest/run.sh`.

If you add a new contract, add a row here **and** its guard. If a guard here
names a gate/case that no longer exists, that is itself a defect.

---

## C1 — Per-audit output: findings.json / report.md / report.html / inventory.json

- **Producer:** every `audit-*` (except `audit-all`, `audit-cost` for inventory).
- **Consumers:** `audit-all`, `correlation-engine`, `cost-analysis`,
  `render-report-viz`, `rca`, the history ledger.
- **Invariants:** evidence-aware audit emitters use `scoutflo-findings/v2`;
  `v1` remains readable for historical input and audit skills still in the
  staged migration. In both versions, `overall` reconciles
  with the scorecard (weight-normalized sum over included categories); weights
  sum 100; `severity_counts` = histogram of **non-suppressed** findings; every
  non-`info` finding carries a concrete `affected` resource; one **registered**
  ID prefix per audit; each run also writes `report.md`, `report.html`, and
  `inventory.json` (`scoutflo-inventory/v1`).
- **SSOT:** `report-standard/findings-schema.md`, `inventory-schema.md`,
  `report-template.md`, `severity-and-scoring.md`, `README.md`.
- **Guards:** `report-standard/check-findings.sh` (reconciliation, histogram,
  affected, enums — run by every audit + `tests/`), `check-report.sh` plus
  `tests/test-check-report.sh`
  (report.md/report.html/inventory reconcile), `ci/skill-completeness-check.sh`,
  the finding-ID prefix-registry check (see C9). Selftest: `layer_validators`,
  `report-real:*`.

## C2 — Output directory layout (single vs multi-target, and always-nested audits)

- **Producer:** an audit writes `<integration>/<date>/` for a single block, or
  `<integration>/<label>/<date>/` for a labeled list. **`signoz` and
  `kubernetes` ALWAYS nest two levels** (`signoz/<host>/`, `kubernetes/<context>/`)
  even as a single block.
- **Consumers (must glob BOTH one- and two-level):** `audit-all` roll-ups,
  `correlation-engine.sh` (`correlation_collect_findings`),
  `render-report-viz.sh` (`rollup` + `inventory-rollup`),
  `cost-analysis.sh` (`cost_analysis_aggregate_findings`). All skip
  `all/`, `cost-analysis/`, `cost/`, `doctor/`.
- **Invariant:** a one-level glob silently drops signoz/kubernetes/multi-target
  stacks — never regress a consumer to a single `*/` glob.
- **Guards:** `ci/multi-target-parity-check.sh` (producers nest by `_SEG`),
  `ci/multi-target-consumer-check.sh` (the three aggregators dual-glob).
  Tests: `skills/correlation-engine/tests/`, `skills/cost-analysis/tests/`,
  `tests/test-report-viz.sh` (all carry a two-level fixture). Selftest:
  `layer_capstone` three-level dual-glob assertions.

## C3 — Target resolution (multi-target enumerator)

- **Contract:** every own-block `audit-*` **and** `doctor` resolve targets
  through `report-standard/toolkit-targets.sh` (`count`/`label`/`get`/`labels`/
  `kind`; no `yq` required — POSIX-awk fallback), select the current target via
  the `SCOUTFLO_TARGET` env var, and nest output by a resolved `<PREFIX>_SEG`. A
  single block resolves to exactly one target whose label defaults to the
  integration name (byte-identical to the pre-multi-target read).
- **Exemptions:** `audit-lgtm`, `audit-alertmanager`, `audit-prometheus`
  (shared-backend blocks — they read `prometheus`/`loki`/`tempo`/`mimir`/
  `victoriametrics` as a single mapping, never a labeled own block; a labeled
  list there would break `doctor` and the other readers).
- **Metrics-plane ownership boundary (v0.1.156/157, fixed):** within the shared
  metrics blocks, the **Prometheus server + rule-engine plane** (`prometheus.url`
  — scrape targets, `up`, TSDB, WAL/compaction, remote-write, config reload, rule
  health) is `audit-prometheus` (`PROM-*`); the **Mimir/VictoriaMetrics stores**
  (`mimir.url` / `victoriametrics.url` / `vmalert_url` — store reachability,
  queryability, multi-tenancy, ingestion freshness, ruler health, store
  cardinality) are `audit-lgtm` (`LGTM-001..004/006..008`, category "Metrics
  stores"). `LGTM-005` (scrape targets) is retired → `PROM-010/012`; the
  metrics-half of `LGTM-065` (Prometheus TSDB cardinality) → `PROM-030`. The two
  audits never double-score the same series. Guard: the maintainer review + the
  `layer_depth` selftest lock asserting `audit-lgtm` keeps `LGTM-006` and the
  "Metrics stores" category.
- **Reference implementation:** `audit-azure` (`AZ_KIND`/`AZ_N`/`AZ_IDX`/
  `AZ_LABEL`/`AZ_SEG`).
- **Guards:** `ci/multi-target-parity-check.sh`. Selftest: `layer_targets`
  (enumerator over single + labeled-list fixtures, both yq and awk paths), the
  doctor row-coverage case (a labeled list is iterated, not read as target 0).
- **Gotcha:** a script invoked standalone must locate `toolkit-targets.sh`
  **relative to its own `$0`**, never via `CLAUDE_PLUGIN_ROOT`/CWD alone (that
  broke `doctor` once — a missing enumerator silently made every block "absent").

## C4 — affected → correlation → rca

- **Producer:** `findings[].affected` names concrete resources (required for
  non-`info`).
- **Consumers:** `correlation-engine` joins overlaps (same `affected` service
  across targets) and cascades (shared-resource datastore→alerting chains);
  `rca` reads `correlation.json` (Phase 5) for cross-stack agreement + cascades;
  `cost-analysis` dedups via `correlation.json`.
- **Invariant:** a non-`info` finding with no `affected` is unjoinable — rejected
  at the gate.
- **Guards:** `check-findings.sh` (affected required). Tests:
  `skills/correlation-engine/tests/`. Selftest: `layer_capstone` (a shared
  `affected` resource is detected as an overlap across a one- and two-level target).

## C5 — correlation.json shape (producer ↔ consumer field agreement)

- **Producer:** `correlation-engine.sh` writes `overlaps[]`
  `{overlap_id:"OVL-<service>", type, service, targets[], findings[{target,finding_id,title,severity}], recommendation}`
  and `cascades[]`
  `{cascade_id, root_cause{finding_id,title,target,shared_resources}, effects[{finding_id,title,target,condition}]}`.
- **Consumers:** `rca` Phase 5, `cost-analysis` dedup, `render-report-viz overlaps`,
  `topology-guided-setup`.
- **Invariants:** consumers read **only** fields the lib writes — there is no
  `chain_length`/`services[]`/`skill`/`redundancy_level`/`root_cause.impact`/
  `effects[].step` (a phantom `chain_length` read once rendered "prevents
  null-step cascade"). `correlation.json` is **context-neutral**: business-context
  weighting happens in the consumers (`rca`, `cost-analysis`), not in the engine.
  `correlation.json` also carries `coverage[]` (see C14) and its counters; that
  section is likewise advisory — it never mutates a finding or its severity.
- **SSOT:** `skills/correlation-engine/SKILL.md` "What correlation.json contains"
  (must match the lib exactly).
- **Guards:** `skills/correlation-engine/tests/`,
  `skills/topology-guided-setup/tests/` (rationale uses `effect_count`, not
  `chain_length`). Selftest: `layer_capstone`.

## C6 — business-context APPLY chain

- **Producers:** `business-context` `bc_derive_json` →
  `~/.scoutflo/business_context.json` = `{environment, cost_sensitivity,
  critical_dependencies, environment_map[], service_slas[], exclusions{accounts,
  regions,services,resources}, derived_at}`; `business-context-resolver` →
  `~/.scoutflo/computed_metadata.jsonl` (per-resource); the `.md` is the SSOT and
  a valid fallback source.
- **Consumers:** all 17 own-block audits' **Metadata Load** block — the canonical
  block (byte-identical across all 17) that loads the workspace layer
  (`business_context.json`, else the `.md` via the ssot-md fallback) **and** the
  per-resource layer (`computed_metadata.jsonl`) **together**, then applies:
  exclude (`.exclusions` → `not-in-scope`, never a fail), escalate
  `critical_dependencies`, per-env `uptime_sla` from `environment_map` with
  per-service `service_slas` winning, `cost_sensitivity` ordering.
- **Design limit (D1):** one integration block is judged against ONE environment;
  do not mix environments across a block's labels (use a separate env/config file).
- **SSOT:** `docs/BUSINESS-CONTEXT-INTEGRATION-v0168.md` (the canonical block).
- **Guards:** `ci/business-context-parity-check.sh` (every audit reads the SSOT +
  names an apply behavior). Tests: `skills/business-context/tests/`. Selftest:
  business-context exclusions/SLA round-trip.
- **Ownership:** `/scoutflo:business-context` owns `business_context.md`;
  `/scoutflo:connect` proposes but never writes it (a resolver→connect dead-end
  loop was a real bug).

## C7 — topology-export.json → consumers

- **Producers:** `map-topology` → `topology-export.json`
  (`scoutflo-topology-export/v1`, `relationships[]` with `{from{name},to{name},relation}`);
  `map-repos` → `repo-map.json`.
- **Consumers:** `rca` (Phase 3 edge classification), `correlation-engine`,
  every audit's **Topology Readiness** section, `render-report-viz mermaid-topo`.
- **Invariants:** edge semantics are fixed — `DEPLOYED_AS`/`PART_OF`/`ROUTES_TO`
  are **identity** edges (never a candidate cause); `CALLS`/`ServiceEntry` are
  **dependency** edges. `map-topology` emits the canonical `relationships[]`;
  consumers read `relationships[]` **and** tolerate a legacy `edges[]` shape as a
  fallback (older or hand-authored exports). Keep the `edges[]` fallback in
  `rca`/`render-report-viz` — it is backward-compat, not dead code — and do not add
  a *third* divergent reader. `map-topology` is
  **per-cluster** (re-run per labeled kubernetes context; one shared `topology.md`
  describes the wrong cluster for the others).
- **SSOT:** `skills/map-topology/references/scoutflo-export.md`.
- **Guards:** the G6 topology-readiness maintainer review; `rca`/`render-report-viz`
  edge handling. (Add a schema-agreement test when the export schema changes.)

## C8 — Topology Readiness headline string

- **Producer:** each audit's `report.md` headline
  `<r> of <n> critical services are ready for automatic Scoutflo correlation`
  (`report-standard/topology-readiness.md`); `check-report.sh` **rejects** any
  report whose topology prose contains the old `sync-ready` jargon.
- **Consumer:** `audit-all` greps that exact plain-language headline for the
  combined Topology Readiness table.
- **Invariant:** a consumer must never grep for `sync-ready` (a conformant report
  can't contain it → every target would read "readiness not recorded").
- **Guards:** `ci/audit-all-map-check.sh` (fails on `sync-ready` in audit-all),
  `check-report.sh`. Selftest: sync-ready contract case; pressure scenario
  `tests/pressure-scenarios/audit-all/stale-topology-readiness-line.md`.

## C9 — Config-key agreement (connect ↔ doctor ↔ audit) + prefix registry

- **Contract:** for each provider, the `toolkit.yaml` keys the user is told to
  write (`connect/references/providers.md`), the keys `doctor.sh` reads, and the
  keys the audit reads must **agree** — a key one side reads but another never
  documents is drift (a provider that connects but doctor/audit can't read, or
  vice versa). Every audit's finding-ID prefix is registered exactly once in
  `findings-schema.md`.
- **Guards:** `ci/config-key-agreement-check.sh` (per-provider key + prefix
  agreement), `ci/coverage-check.sh` (template ↔ providers.md ↔ connect/start),
  `ci/catalog-consistency-check.sh`, `ci/audit-all-map-check.sh`. Selftest:
  config-key agreement + prefix-registry cases.

## C10 — audit-all coverage & scheduled runs

- **Contract:** every own-block `audit-*` (except the shared-backend exemptions)
  has a row in `audit-all`'s Phase-1 config→audit map; `schedule-audits`
  delegates entirely to `audit-all`, so an unmapped provider is silently skipped
  by "audit everything" and every scheduled run.
- **Guards:** `ci/audit-all-map-check.sh`.

## C11 — Surface/catalog consistency

- **Contract:** every public skill appears in `connect` Step 1 + the `start`
  catalog + `README`; `marketplace.json` description/keywords track `plugin.json`;
  the stated min CLI version is consistent across docs + `doctor.sh`.
- **Guards:** `ci/coverage-check.sh`, `ci/catalog-consistency-check.sh`,
  `ci/manifest-compat-check.sh`, `ci/min-version-consistency` (in structure-check).

## C12 — Authenticated probes assert JSON (no HTML false-green)

- **Contract:** every *authenticated* HTTP doctor/verify probe captures
  `%{content_type}` and/or asserts a JSON body, so a 200 HTML SSO/login/SPA page
  fails closed. A deliberately status-only probe carries a `status-probe-ok`
  comment. (HyperDX: Personal API Access Key → Bearer → `/api/v2` (probe the
  app-proxy-doubled `/api/api/v2` too), never the ingestion key; SigNoz:
  `signoz-viewer` role, 403 = no role.)
- **Guards:** `ci/content-type-probe-check.sh`. Selftest: HyperDX + SigNoz auth
  locks in `layer_depth`.

## C13 — Behavioral parity (scope / redaction / env-load)

- **Contract:** every `audit-*` wires the estate-sizing scope checkpoint, the
  secret-redaction discipline (secrets by key/name only, never printed/written),
  and sources the home-anchored secret store in its doctor gate. **`doctor` and
  every audit must resolve that store identically** via the layered resolver
  (`SCOUTFLO_ENV_FILE` → `./.scoutflo/env` → `$HOME/.scoutflo/env`) — a hardcoded
  `$HOME`-only path in one and the layered path in the other is a real
  doctor↔audit asymmetry on sandboxed/project-local surfaces. Secrets live in the
  store, not the operator's interactive shell (the plugin runs in its own process
  and cannot see a shell `export`); `connect` writes the store for the operator.
- **Guards:** `ci/scope-checkpoint-check.sh`, `ci/redaction-parity-check.sh`,
  `ci/env-load-parity-check.sh` (asserts the layered resolver in every `audit-*`
  **and** in `doctor.sh`), `ci/leak-scan.sh`. Selftest: `layer_parity`.

## C14 — Cross-tool coverage correlation (a gap in one tool covered by another)

- **Producers:** every audit's `inventory.json` records its **active** monitors/
  alerts (`kind` + `covers` + `enabled` + `routes_to`); an audit's coverage-gap
  findings carry the affected resource in `affected[]`, and MAY carry an optional
  `coverage_gap: {signal, kind}` (findings-schema) that names the exact signal so
  the engine identifies the gap without the area+title heuristic and words the
  reframe against that signal.
- **Consumer:** `correlation-engine.sh` (`correlation_collect_coverage` +
  `correlation_find_coverage`) joins each coverage-gap finding against **other**
  providers' active, routed monitors and writes a `coverage[]` array +
  `total_coverage_*` counters to `correlation.json`; `render-report-viz overlaps`
  renders the "Cross-tool coverage" subsection, `rca` Phase 5.5 reframes, and
  `audit-all` §7 surfaces it.
- **Invariants:** advisory only — **never** mutates `findings.json` or an
  audit-owned severity. An item counts as active coverage only when its `kind` is
  an alerting/monitor type that watches its `covers` resource — one of `monitor`,
  `alarm`, `alert`, `alert_rule`, `alert_policy`, `log_alert`, `activity_log_alert`,
  `uptime_check` (routing/muting/delivery kinds like `receiver`/`silence`/`route`/
  `escalation_policy`/`notification_channel` never count) — `enabled != false`, and
  `routes_to` names a real receiver. This kind list is the SSOT the `active()` filter
  in `correlation-engine.sh` must match; adding a provider that emits a new alerting
  kind means updating both.
  A `covered-elsewhere` verdict requires an **exact** normalized `covers==affected`
  match and is always worded **single-tool-dependency** (never "covered"); a fuzzy
  match is `unmappable` (verify-pending); nothing is `true-gap`. Confidence is
  highest when `map-topology` has run so both sides use the canonical service name.
  Every `covered_by` entry names an inventory item present in this run.
- **SSOT:** `skills/correlation-engine/SKILL.md` (`coverage[]` schema, must match
  the lib) and `report-standard/inventory-schema.md` (`covers` = canonical service
  name when known).
- **Guards:** `ci/multi-target-consumer-check.sh` (locks the coverage collector to
  the two-level `inventory.json` glob), `skills/correlation-engine/tests/`
  (covered-elsewhere / true-gap / disabled-excluded + `coverage_gap.signal` cases).

## C15 — Required vs optional config keys (per provider)

- **Contract:** each provider's config keys have a required/optional shape the
  operator-facing surfaces must reflect: a genuinely **required** key is present
  and uncommented in `templates/toolkit.yaml.example`; an **either-or lane** (e.g.
  ClickStack = ClickHouse **or** HyperDX; at least one) keeps ≥1 member uncommented;
  a genuinely optional key is commented or absent. This is the sub-key granularity
  that block-level C9 (`config-key-agreement`) does not see — it is the class behind
  the ClickStack HyperDX-only blocker (the setup surface called a lane optional while
  the audit hard-required it).
- **SSOT:** the declaration embedded in `ci/optional-key-parity-check.sh` (kept in
  lockstep with each audit's doctor gate).
- **Guard:** `ci/optional-key-parity-check.sh` asserts the template matches the
  declaration (required keys uncommented; each `oneof` lane has a member). Its scope
  is the operator-facing declaration + template; the audit-side enforcement of the
  same optionality is the skill's own doctor-gate behavior + the maintainer review.

## C16 — Evidence-aware check ledger, readiness, and assessment coverage

- **Producer:** each v2 audit writes one `checks[]` row per stable catalog check,
  including pass and not-in-scope rows that do not become findings.
- **Consumers:** `check-findings.sh`, `render-report-viz.sh`, the scorecard,
  Slack brief, and `history.jsonl`.
- **Invariants:** `blocked` means unassessed and never counts as a verified
  failure; readiness is calculated only over unsuppressed pass/partial/fail
  checks; assessment coverage is assessed/applicable; every partial/fail/blocked
  row has a same-ID finding, every readiness finding points back to one such
  row, and pass/not-in-scope rows cannot carry open findings; deliberately
  non-scored findings explicitly declare `scoring_scope:non-scored`, have no
  check row, and recover zero points; an active exemption is represented by
  `suppressed:true` plus `suppression_reason` on the original partial/fail row
  and a same-ID lifecycle=suppressed finding; blocked and suppressed findings
  recover zero readiness points; a run with no scored checks is `unassessed`
  with `overall:null`; end-to-end requires 100% assessment coverage.
  Raw score deltas and trend points are comparable only when `scoring_model` and
  `check_set` match. Customer reports render `report_lanes` through the
  deterministic `Findings by purpose` view; the two lanes never create a second
  score or duplicate the detailed finding evidence.
- **SSOT:** `report-standard/findings-schema.md` and
  `report-standard/severity-and-scoring.md`.
- **Guards:** `report-standard/check-findings.sh` and
  `tests/test-check-findings.sh`; renderer and report-lane parity are covered by
  `tests/test-report-viz.sh` and `tests/test-check-report.sh`; prompt-level
  roll-up and Slack consumers are covered by `tests/test-v2-consumer-safety.sh`.

---

## Gate & test index (kept honest by `ci/contract-map-check.sh`)

Every gate `ci/structure-check.sh` composes is listed here; `ci/contract-map-check.sh`
fails the build if a composed gate is missing from this file or if this file names
a gate that does not exist — so the map cannot silently drift from reality.

Structural / linkage:
`ci/anchor-check.sh` (every `skill#anchor` resolves) ·
`ci/crossblock-check.sh` (no fenced block reads an undeclared cross-block var) ·
`ci/coverage-check.sh` (every audit in connect + start; every template block has a providers.md source) ·
`ci/remediation-map-check.sh` (every remediation pointer resolves to a real skill#anchor + catalog ID) ·
`ci/skill-completeness-check.sh` (per-lane structural markers) ·
`ci/manifest-compat-check.sh` · `ci/min-version-consistency-check.sh` ·
`ci/catalog-consistency-check.sh` (README + start; marketplace/plugin) ·
`ci/liveness-readonly-check.sh` · `ci/audit-dir-check.sh` (output paths via `SCOUTFLO_AUDIT_DIR`) ·
`ci/named-section-check.sh` (every `(cookbook: "...")` resolves) ·
`ci/config-key-agreement-check.sh` (**C9** — doctor KNOWN_BLOCKS == configurable template blocks) ·
`ci/optional-key-parity-check.sh` (**C15** — per-provider required keys + either-or lane contracts reflected in the template) ·
`ci/prefix-registry-check.sh` (**C1/C9** — every emitted finding-ID prefix is registered) ·
`ci/audit-all-map-check.sh` (**C8/C10** — every own-block audit mapped in audit-all; no `sync-ready` jargon) ·
`ci/contract-map-check.sh` (**this file** — the map stays honest).

Behavioral parity:
`ci/scope-checkpoint-check.sh` · `ci/redaction-parity-check.sh` ·
`ci/business-context-parity-check.sh` (**C6**) · `ci/env-load-parity-check.sh` (**C13**) ·
`ci/content-type-probe-check.sh` (**C12**) ·
`ci/multi-target-parity-check.sh` (**C2/C3** — producers) ·
`ci/multi-target-consumer-check.sh` (**C2** — the three aggregators dual-glob).

Output correctness (run by every audit + `ci/run-tests.sh`):
`report-standard/check-findings.sh` (**C1/C4/C16**) · `report-standard/check-report.sh` (**C1/C8/C_M**) ·
`ci/leak-scan.sh` (**C13**).

Behavioral test suites (real libs, run by `ci/run-tests.sh`):
`skills/correlation-engine/tests/` (**C2/C4/C5**) · `skills/cost-analysis/tests/` (**C2**) ·
`tests/test-report-viz.sh` (**C2/C16**) · `tests/test-check-findings.sh` (**C16**) · `skills/business-context/tests/` (**C6**) ·
`skills/topology-guided-setup/tests/` (**C5**) · `tests/test-multi-target-enumerator.sh` (**C3**).

Local behavioral net (not shipped): `../selftest/run.sh` — one case per contract above,
each tagged with its `Cn` id; run before shipping a behavior change.

## When you build a NEW provider integration

Follow `../integration-kit/PLAYBOOK.md`. Every contract above applies; the ones a
new provider most often breaks: C1 (schema + registered prefix), C2/C3
(multi-target output + resolver), C6 (Metadata Load block — copy the canonical
one verbatim), C9 (providers.md ↔ doctor ↔ audit keys), C10 (audit-all map row),
C11 (connect/start/README/template). Run all four gates + the selftest before the
PR; the live smoke against a real estate is a hard merge gate (`AGENTS.md`).
