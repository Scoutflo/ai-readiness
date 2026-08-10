# Engineering Contract

## Purpose And Scope

This repository publishes the Scoutflo AI Readiness Claude Code plugin. It contains skills, reference documentation, templates, deterministic validation, and contributor guidance. It does not contain application code, and features that require a maintained application or service are outside its scope.

This file is the canonical map of engineering practice. Native repository artifacts remain authoritative for the detailed mechanisms assigned to them below.

## Risk Posture

Audits are strictly read-only. Setup skills announce exact mutations, wait for explicit confirmation, execute only the approved change, and re-read every modified object to verify it. Guide skills remain advisory.

Never place credentials, secret values, machine paths, customer-specific data, hostnames, or account identifiers in tracked content, except approved reviewer identities in `.github/CODEOWNERS`. Do not bypass failed validation, mutate live resources from audit skills, rewrite published history, or broaden an approved change without fresh authorization.

## Authority Map

| Concern | Authoritative source | What it owns | Scope | Evidence or enforcement | Owner or reviewer | Freshness or review trigger |
| --- | --- | --- | --- | --- | --- | --- |
| Canonical engineering map | `ENGINEERING.md` | Relationships among engineering policies and their owners | Repository-wide | Accepted repository guidance | Repository administrators | Any material policy or authority change |
| Contributor commands and safety boundaries | `AGENTS.md` | Required gates, edit boundaries, and completion criteria | Repository-wide | Contributor guidance | Repository maintainers | Gate or safety-policy changes |
| Skill design | `docs/skill-authoring-conventions.md` | Audit, setup, and guide behavior; reporting and command conventions | Skills and supporting content | Authoring standard and structure checks | Skill maintainers | Skill-lane or report-standard changes |
| Branch, review, and release discipline | `CONTRIBUTING.md` | Branch lifecycle, PR checklist, versioning, and tagging | Contributions and releases | Contributor guidance | Repository maintainers | Branch, review, or release-policy changes |
| Hosted validation | `.github/workflows/ci.yml` | Stable `gates` check and its executed validation steps | Pushes and pull requests | GitHub Actions | Repository administrators | CI dependency or gate changes |
| Review ownership | `.github/CODEOWNERS` | Code-owner routing | Repository-wide | GitHub review routing | Designated code owner | Ownership changes |
| Plugin identity and version | `.claude-plugin/plugin.json` | Published plugin metadata and version | Plugin release | Claude plugin validation | Release maintainers | Every user-visible release |
| Audit output contract | `report-standard/` | Canonical findings and derived-report requirements | Audit skills and generated reports | Report validation | Skill maintainers | Schema or reporting-policy changes |

## Change Lifecycle

Create work on a descriptive feature branch. Keep the change within its approved scope, update the native authoritative artifacts, and add or update pressure scenarios for skill changes. Run the required local validation before requesting review.

Open a pull request to `main`. Resolve review and validation failures without bypassing them. Merge only when the change is release-ready. After merge, use the resulting hosted evidence and repository state for verification and future learning.

## Validation Expectations

Before review, run the standard leak, structure, **test-suite** (`sh ci/run-tests.sh .`), and strict plugin-validation gates defined in `AGENTS.md`. Documentation-only changes run the same standard gates.

Audit and runtime changes also run the relevant report validation, pressure scenarios, and interactive smoke tests required by their native guidance. Before merge, the hosted `gates` check must pass against the current pull-request head.

A declared command is not evidence that it passed. Record actual local, hosted, or runtime results at the boundary where the claim is made.

## Review And Merge Policy

All ordinary changes use pull requests targeting `main`. Non-administrator merges require the hosted `gates` check and one code-owner approval. Administrators may bypass hosted protection when necessary, but must still run required validation and verify release readiness.

Direct pushes are prohibited for non-administrators. Force pushes and published-history rewrites are prohibited. Merge commits, squash merges, and rebases are all permitted; no linear-history policy is required.

## Release And Production Policy

The default branch `main` is the production and release branch. Merging to `main` makes repository content immediately installable through the plugin marketplace, so every merge must be release-ready.

Every user-visible change updates the plugin version and changelog. Releases are tagged using the process in `CONTRIBUTING.md`. There is no PREPROD environment or separate deployment promotion.

Rollback uses a corrective pull request followed by a new version and tag. Do not rewrite published history or silently replace a released version.

## Exceptions And Deferrals

| Item | Rationale | Owner | Review trigger |
| --- | --- | --- | --- |
| Administrator bypass of hosted protection | Administrators may need to recover or unblock repository operations; bypass never waives required validation or release readiness | Repository administrators | Any branch-protection or review-policy change |
| Reviewer identity in `.github/CODEOWNERS` | GitHub requires a tracked account identity to enforce the approved code-owner review policy | Repository administrators | Any review-ownership change |
| Secret scanning, push protection, and Dependabot security updates are disabled | Hosted hardening remains intentionally deferred; this does not relax the repository prohibition on tracked secrets or identifiers | Repository administrators | Before accepting external contributions or at the next security review |

## Ownership And Review Triggers

Repository administrators maintain hosted controls, secret settings, and this canonical map. Native artifact owners maintain the detailed mechanisms assigned in the authority map. CODEOWNERS governs repository review without moving hosted-control ownership into tracked guidance.

Review this contract whenever branch protection, required checks, review ownership, release behavior, repository scope, security posture, or an authoritative native artifact changes.
