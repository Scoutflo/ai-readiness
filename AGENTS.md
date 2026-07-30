# Scoutflo AI Readiness — Contributor Instructions

This repo is a Claude Code plugin: skills, reference docs, and templates only. There is no application code and none may be added; a feature that needs a written-and-maintained program is out of scope by design.

## Commands

Run the repository gates from the repo root:

```bash
sh ci/leak-scan.sh .
sh ci/structure-check.sh .
claude plugin validate . --strict
```

Smoke-test affected skills interactively with:

```bash
claude --plugin-dir .
```

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

1. **Skill Review Gate Compliance** — Every skill must pass the rubric review (docs/skill-review-rubric.md) with all Blocking parameters at PASS before shipping. Pressure scenarios (I4) are mandatory, not optional. No workarounds, no exceptions.

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
