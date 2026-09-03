# Ship manifest — what a plugin consumer actually needs

This repo is developed and shipped from the same tree, so today a `claude plugin install` pulls the **entire** repository — including `ci/`, `tests/`, contributor docs, and per-skill `evals/` fixtures a consumer never runs. That's install bloat and it puts internal test fixtures in front of customers. This manifest declares the boundary between the **runtime surface** (what a consumer needs) and **dev-only** paths (safe to strip from a published artifact). `tests/test-package-boundary.sh` enforces that every tracked top-level entry is classified here — so a new top-level directory can't silently land on either side.

This is a **declaration + gate**, not a build step: it does not change what ships today. A future publish step (e.g. a packaging script or a published `agent-plugin` branch) can use these lists to emit a trimmed artifact; until then the gate keeps the boundary honest and reviewed.

## Runtime surface (SHIP — a consumer needs these)

- `.claude-plugin/` — plugin manifest + marketplace entry
- `skills/` — the skills themselves (**except** each skill's `evals/` and `tests/` subdirectories, which are dev-only)
- `report-standard/` — schemas, renderers, and validators the skills invoke at runtime
- `templates/` — `toolkit.yaml.example` and friends that `connect` writes from
- `hooks/` — the SessionStart config-health nudge (`hooks/hooks.json` auto-discovered by Claude Code; no `plugin.json` manifest key needed, so no compat exposure)
- `LICENSE`, `README.md`, `CHANGELOG.md` — user-facing

## Dev-only (STRIP-able from a published artifact — a consumer does not need these)

- `ci/` — repository gates (run in CI, not by a consumer)
- `tests/` — pressure scenarios + shell test suites
- `docs/` — contributor and internal documentation
- `skills/*/evals/` — behavioral eval specs + offline fixtures (see [eval-format.md](eval-format.md))
- `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `CONTRIBUTING.md`, `ENGINEERING.md` — contributor guidance
- `.github/`, `.claude/`, `.gitignore`, `.gitleaksignore` — repo/tooling config

Generated output (`scoutflo-audits/`) is gitignored and never tracked, so it is out of scope here.
