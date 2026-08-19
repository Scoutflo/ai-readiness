# Full live sweep — Claude playbook

The audit skills are executed by Claude reading the skill (not by a shell
script), so the end-to-end "run every audit against real data" pass is driven
from Claude and then validated by `tests/selftest/run.sh`. This playbook is the
copy-paste recipe. It is deliberately conservative: strictly read-only, honest
about what can't be reached, and it never fabricates a result.

## 0. Preconditions

- `~/.scoutflo/toolkit.yaml` + `~/.scoutflo/env` configured for the providers you
  want to exercise (run `/scoutflo:connect` if not).
- For a hermetic provider you fully control, spin the local ClickStack:
  `sh tests/selftest/run.sh --layer integration --keep` leaves a healthy instance
  (or provision your own) so `audit-clickstack` has a real target.

## 1. See what is reachable (read-only)

Run `/scoutflo:doctor`. It classifies every configured provider live vs failed
with an actionable hint. Only the providers that come back reachable can be
live-audited right now; note the rest as blocked (don't pretend they passed).

## 2. Run each reachable audit into a throwaway sandbox

Paste to Claude:

> Run the Scoutflo AI Readiness live audit sweep as a fresh customer. Use a
> throwaway audit dir: `export SCOUTFLO_AUDIT_DIR=/tmp/scoutflo-selftest-live`.
> For each provider that `/scoutflo:doctor` reports reachable, run its
> `/scoutflo:audit-<provider>` **read-only** against the live system, following
> the skill exactly. Test the empty/hidden-scope guardrail where it applies. Do
> not fabricate any result — if a command errors or access is denied, report it
> verbatim and move on. For each audit, confirm it wrote `findings.json`,
> `report.md`, and `inventory.json`.

Safety rails to keep in the prompt: read-only only (no create/update/delete, no
test notifications); correct cloud profile/context pinned explicitly on every
command; never print a secret value.

## 3. Validate everything the sweep produced

```bash
sh tests/selftest/run.sh --layer live --dir /tmp/scoutflo-selftest-live
```

This runs the doctor sweep and pushes every produced `findings.json` /
`report.md` through `check-findings` + `check-report` + `leak-scan`. Every row
should be PASS; a FAIL points at the exact audit + validator.

## 4. Cross-cutting capstone on the real outputs

Paste to Claude:

> Over `SCOUTFLO_AUDIT_DIR=/tmp/scoutflo-selftest-live`, run `correlation-engine`
> to build `correlation.json`, then `cost-analysis` for the roll-up, then
> `/scoutflo:rca` for a real cross-stack theme, and `/scoutflo:audit-all`'s
> aggregation. Verify the joins/roll-up/RCA cite real findings and never invent.

The correlation + cost libs are also exercised hermetically by
`run.sh --layer capstone`; this step confirms them on your real fleet.

## 5. Record the outcome

`run.sh` writes `tests/selftest/last-run.md`. For the LLM-driven steps, keep the
sandbox (`--keep` / a stable `SCOUTFLO_AUDIT_DIR`) and re-run `--layer live`
anytime to re-validate without re-auditing.
