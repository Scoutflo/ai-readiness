## Summary

<!-- What this changes and why, in a few sentences. -->

## Checklist (all required — see AGENTS.md "Done criteria")

- [ ] Base branch is `release/dev` (never `main`)
- [ ] `sh ci/leak-scan.sh .` — CLEAN
- [ ] `sh ci/structure-check.sh .` — STRUCTURE-OK (15 checks)
- [ ] `sh ci/run-tests.sh .` — all suites pass
- [ ] `claude plugin validate . --strict` — passes
- [ ] Pressure scenarios added/updated for every changed skill
- [ ] `.claude-plugin/plugin.json` version bumped + `CHANGELOG.md` entry

## Live smoke (hard merge gate for new / behavior-changed skills)

- [ ] I ran the changed skill against a **real estate** and describe the run below
- [ ] OR: my environment cannot reach one — a maintainer must run the smoke **before merge** (the PR does not merge on static gates alone)

**What it ran against / what it found:**

<!-- e.g. "map-repos against a 229-repo org whose services live in one monorepo:
      probe found the fixtures repo, matches 6 of 11 unresolved services." -->
