# Contributing

Start with [AGENTS.md](AGENTS.md) and [docs/skill-authoring-conventions.md](docs/skill-authoring-conventions.md); they define the lanes, the report standard, and the content rules every change must follow.

## Branch and release discipline

`main` is release-only. The plugin marketplace serves from the default branch, and directory listings re-pin on new commits to it, so anything merged to `main` is immediately installable by users.

- All work happens on branches; pull requests target `release/dev`. Promote tested, approved releases from `release/dev` to `main`.
- Require the `gates` status check and the required approving review before merging. Release promotion needs explicit maintainer authorization; administrator access is not permission to bypass review.
- Every user-visible change bumps `version` in `.claude-plugin/plugin.json` and gets a CHANGELOG entry. Users receive updates only on version bumps.
- Tag releases: `claude plugin tag . --push -m "Release %s"`.

## PR checklist

1. `sh ci/leak-scan.sh .` prints CLEAN and `sh ci/structure-check.sh .` prints STRUCTURE-OK.
2. `sh ci/run-tests.sh .` prints TESTS-OK (every `tests/*.sh` and `skills/*/tests/*.sh` pass under `/bin/sh`). The native Alertmanager configuration tests require Python 3.9+ with PyYAML; CI installs PyYAML 6.0.3 in an isolated environment.
3. `sh ci/plugin-validate.sh .` passes on the CI-pinned Claude Code v2.1.281 and current contributor CLIs. It strictly validates the explicit marketplace manifest and the actual plugin manifest/assets in an isolated metadata fixture, and rejects OS metadata. It does not suppress warnings. The fixture does not validate skill content; the structure and test gates cover that separately. The supported runtime minimum remains v2.1.140, guarded by `ci/manifest-compat-check.sh`.
4. Skill changes update or add pressure scenarios under `tests/pressure-scenarios/`.
5. Tested live with `claude --plugin-dir .` for the skills you touched.
6. No renames of shipped skill or command names; they are frozen public API.

## License

This project is licensed under Apache-2.0 (see [LICENSE](LICENSE)). By submitting a contribution, you agree that it is provided under the same license.
