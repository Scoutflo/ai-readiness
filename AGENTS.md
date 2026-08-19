# Scoutflo AI Readiness — Contributor Instructions

This repo is a Claude Code plugin: skills, reference docs, and templates only. There is no application code and none may be added; a feature that needs a written-and-maintained program is out of scope by design.

## Commands

Run the repository gates from the repo root:

```bash
sh ci/leak-scan.sh .
sh ci/structure-check.sh .
sh ci/run-tests.sh .
claude plugin validate . --strict
```

`ci/structure-check.sh` composes 13 checks: anchor, cross-block, coverage,
remediation-map, **skill-completeness**, the four behavioral-parity gates
(scope-checkpoint, redaction-parity, business-context-parity, **env-load-parity**),
and manifest-compat, min-version-consistency, catalog-consistency, and
liveness-readonly.
`ci/run-tests.sh` executes
every `tests/*.sh` and `skills/*/tests/*.sh` under `/bin/sh` (and rejects dead
bats-syntax files that cannot run). All four run in CI on every push/PR — a
failure blocks the merge.

Smoke-test affected skills interactively with:

```bash
claude --plugin-dir .
```

## Adding or changing a skill — what the gates enforce

`ci/skill-completeness-check.sh` mechanically enforces per-lane structure so a
stub can never ship again (an audit skill once shipped as a 4KB placeholder with
a fabricated `lib/` because the only automatic check was "has frontmatter"). A
new skill must clear its lane's markers or CI fails:

- **audit-\*** (except `audit-all`): SKILL.md ≥ 8KB, a Doctor gate, a Live-safety
  gate, a reference to the report standard / findings schema, a Common Failure
  Modes section, a `references/*.md` check catalog, and a
  `tests/pressure-scenarios/<name>/*.md` scenario (I4).
- **setup-\***: SKILL.md ≥ 8KB, "The change protocol" section, a Doctor gate, a
  Live-safety gate, `disable-model-invocation: true` in frontmatter, and a Common
  Failure Modes section.
- **harness** (correlation-engine, cost-analysis, redaction, checkpoint, …): no
  provider gates required; a `lib/`+`tests/`-only helper with no SKILL.md is a
  library and is allowed. If it has a lib, add a `tests/*.sh` suite (it will be
  run by `ci/run-tests.sh`).

An audit skill's *behavior* is also gated by four behavioral-parity checks in
`structure-check.sh`, each asserting every `audit-*` (except `audit-all`) actually
wires a feature rather than just having a section for it:

- `ci/scope-checkpoint-check.sh` — wires the shared estate-sizing scope checkpoint
  (`report-standard/estate-scope-checkpoint.md`): a real `cli_pause_before_audit`
  behind a large-estate threshold, so a large estate can never grind unbounded.
- `ci/redaction-parity-check.sh` — carries the secret-redaction discipline
  (`report-standard/secret-redaction.md`): secret values are captured by key/name
  only and never printed or written, so no audit can leak a secret at runtime
  (complements `ci/leak-scan.sh`, which catches secrets committed to the repo).
- `ci/business-context-parity-check.sh` — has a Metadata Load block that reads the
  business-context SSOT projection (`business_context.json` / `computed_metadata.jsonl`)
  *and* names a concrete apply behavior (exclude / escalate critical / cost
  sensitivity / per-env SLA), per `docs/BUSINESS-CONTEXT-INTEGRATION-v0168.md`, so
  business context actually changes the audit rather than being a read-and-ignored flag.
- `ci/env-load-parity-check.sh` — every `audit-*` sources the home-anchored secret
  store `~/.scoutflo/env` in its doctor gate, exactly as `/scoutflo:doctor` does, so a
  credential added to the store (even mid-session) is picked up in the same run — no
  "doctor is green but the audit says the token isn't set" asymmetry.

These are *behavioral* gates (does the skill act?), distinct from the structural
completeness gate (does the section exist?). Correlation readiness is enforced in
`report-standard/check-findings.sh`: a non-info finding must name a concrete
`affected` resource so the correlation engine can join it across audits.

An audit skill's output is also gated: `report-standard/check-findings.sh`
validates that a `findings.json`'s `overall` reconciles with its scorecard (the
weight-normalized sum over included categories, rounding aside) and that the
schema invariants hold (envelope fields, `severity_counts` = the histogram,
weights = 100, valid enums, evidence + `remediation` on every finding). Every
audit runs it on its own output before `check-report.sh`. It caught real drift —
scores authored 2–5 points above their scorecard — that shape-only conformance
could not. Add nothing to bypass it; a score that does not reconcile is a bug.

These gates check **structure and internal consistency**, not correctness — they
cannot know whether a finding is *true* about the live system. A separate
maintainer judgment review (kept outside this repo, against a rubric the Scoutflo
team maintains) still decides whether the checks a skill runs are the right ones;
it should run on any new or substantially changed skill before shipping. The gates
stop stubs and self-inconsistent output; the review stops wrong logic; live
verification proves the findings are real.

## Before editing

Before changing any skill, read [docs/skill-authoring-conventions.md](docs/skill-authoring-conventions.md). It defines the three lanes (audit = strictly read-only, setup = confirm-then-verify, guide = advisory), the live-safety gate, the report standard every audit must emit ([report-standard/](report-standard/)), voice rules, command conventions, and the forbidden-content categories for this public repo.

## Boundaries

Always:

- Keep audits strictly read-only. Setups must announce exact changes, wait for explicit confirmation, then re-read and verify every modified object.
- Treat `findings.json` as canonical. Regenerate `report.md`, briefs, history, and exports instead of hand-patching derived artifacts.
- Update or add pressure scenarios under `tests/pressure-scenarios/` for every skill change.
- Bump `.claude-plugin/plugin.json` and update `CHANGELOG.md` for every user-visible change.

Ask first:

- Before renaming a skill or command, changing the report schema, or otherwise breaking the frozen public API.
- Before adding anything that behaves like application code or a maintained program; that is outside this repository's intended scope.

Never:

- Put credentials, hostnames, account identifiers, machine paths, or customer-specific values in any tracked file, example, fixture, or commit message, except the approved reviewer identity in `.github/CODEOWNERS`.
- Let an audit create, modify, or delete live resources, including seemingly harmless test notifications or annotations.
- Bypass a failing leak scan, structure/anchor check, report self-validation, or plugin validation gate.

## Permanent Governance Principles (v0.1.65+)

Three non-negotiable principles enforced on every skill change and release:

1. **Skill Review Gate Compliance** — Every skill must pass the maintainer rubric review (maintained by the Scoutflo team outside this repo) with all Blocking parameters at PASS before shipping. Pressure scenarios (I4) are mandatory, not optional. No workarounds, no exceptions.

2. **Git vs. Local Boundary** — Production code only in the public repo. Internal planning docs, governance notes, implementation guides, and working artifacts must not be committed to GitHub. Move them to memory or local-only CLAUDE.local.md instead. Customers must never see internal working notes.

3. **Documentation Consolidation** — One authoritative source per concept. No duplicated docs, no parallel versions, no "docs" vs "docs-old" pattern. When consolidating, delete the stale copies and verify all backlinks point to the new location.

## Done criteria

Before declaring a change complete:

1. **Governance check FIRST** — Verify Skill Review Gate Compliance (all Blocking I4 parameters PASS, pressure scenarios exist and are current), Git vs. Local Boundary (no internal artifacts committed), and Documentation Consolidation (one source of truth per concept, no duplicates).
2. Run the three repository gates under **Commands** and resolve every failure.
3. For audit changes, validate generated `report.md` output with `report-standard/check-report.sh` as required by the report standard.
4. Confirm relevant pressure scenarios cover the changed behavior.
5. Smoke-test the affected skill with `claude --plugin-dir .` when the change affects runtime behavior.
6. Confirm user-visible changes include both the plugin version bump and `CHANGELOG.md` entry.
