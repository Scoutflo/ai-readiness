# Scoutflo AI Readiness — Contributor Instructions

This repo is a Claude Code plugin: skills, reference docs, and templates only. There is no application code and none may be added; a feature that needs a written-and-maintained program is out of scope by design.

Before changing any skill, read [docs/skill-authoring-conventions.md](docs/skill-authoring-conventions.md) — it defines the three lanes (audit = strictly read-only, setup = confirm-then-verify, guide = advisory), the live-safety gate, the report standard every audit must emit ([report-standard/](report-standard/)), voice rules, and the forbidden-content categories for this public repo.

Rules that gate every PR:

1. Audits never mutate anything. Setups announce changes, wait for explicit confirmation, and verify each object after writing.
2. `findings.json` is canonical; `report.md` and briefs are derived and regenerated, never hand-patched.
3. No credentials, hostnames, account identifiers, machine paths, or customer-specific values in any file. CI runs a leak scan, a structure check, and an anchor check (`ci/`), and each audit self-validates its own `report.md` against `report-standard/check-report.sh`; a failing gate blocks merge.
4. Skill and command names are frozen public API. Renames are breaking changes.
5. Every skill change updates or adds pressure scenarios under `tests/pressure-scenarios/`.
6. Version bumps in `.claude-plugin/plugin.json` are what deliver updates to users; bump on every user-visible change and record it in CHANGELOG.md.

Test locally with `claude --plugin-dir .` and validate with `claude plugin validate .` before opening a PR.
