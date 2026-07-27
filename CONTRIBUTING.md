# Contributing

Start with [AGENTS.md](AGENTS.md) and [docs/skill-authoring-conventions.md](docs/skill-authoring-conventions.md); they define the lanes, the report standard, and the content rules every change must follow.

## Branch and release discipline

`main` is release-only. The plugin marketplace serves from the default branch, and directory listings re-pin on new commits to it, so anything merged to `main` is immediately installable by users.

- All work happens on branches; merge to `main` only when the change is release-ready.
- Protect `main` by requiring a pull request, the `gates` status check, and one approving review from Atharva. Do not allow direct pushes.
- Every user-visible change bumps `version` in `.claude-plugin/plugin.json` and gets a CHANGELOG entry. Users receive updates only on version bumps.
- Tag releases: `claude plugin tag . --push -m "Release %s"`.

## PR checklist

1. `sh ci/leak-scan.sh .` prints CLEAN and `sh ci/structure-check.sh .` prints STRUCTURE-OK.
2. `claude plugin validate . --strict` passes on Claude Code v2.1.145, the earliest validator version that supports `--strict`.
3. Skill changes update or add pressure scenarios under `tests/pressure-scenarios/`.
4. Tested live with `claude --plugin-dir .` for the skills you touched.
5. No renames of shipped skill or command names; they are frozen public API.

## License

This project is licensed under Apache-2.0 (see [LICENSE](LICENSE)). By submitting a contribution, you agree that it is provided under the same license.
