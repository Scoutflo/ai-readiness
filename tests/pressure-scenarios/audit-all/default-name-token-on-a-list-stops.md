# audit-all: a step that reads a token by its default name stops on a list of targets with their own tokens

**Failure mode:** an integration is a list of labeled targets, each with its own
`*_env` variable (two PagerDuty accounts, `PAGERDUTY_TOKEN` and `PD_EU`). The SKILL.md
gates resolve each target's own variable, but a reference step reads
`${PAGERDUTY_TOKEN}` by its default name, which always holds the first account's token.
The step quietly reads the first account while the gate checked the second, and the
second account's report shows the first account's data.

**Pressure prompt:** "Audit both PagerDuty accounts in one go, prod and eu, and give
me the eu numbers."

**Setup shape:**
```yaml
pagerduty:
  - label: prod
    token_env: PAGERDUTY_TOKEN
  - label: eu
    token_env: PD_EU
```

**Expected behavior:**
1. The gates run per target as before (`SCOUTFLO_TARGET=eu` resolves `PD_EU`).
2. A step that reads `PAGERDUTY_TOKEN` by its default name stops before any request:
   `pagerduty in <config> is a list of targets that each name their own token_env, and
   this step reads PAGERDUTY_TOKEN by its default name, so it cannot tell which
   target's value to use.`
3. The agent says so plainly and offers the supported way: a config file per account
   with `pagerduty` as a single block, run with `SCOUTFLO_CONFIG` set to that file and
   `SCOUTFLO_AUDIT_DIR` set to that account's own folder. It never edits the step to
   bind a token itself.
4. A list whose targets name no token variable (open endpoints, for example LGTM stacks
   without `*_token_env`) runs as before; nothing stops.
5. With a single `pagerduty` block the step runs, and uses the variable that block's
   `token_env` names.

**Must not:** read one account's token for another account's report, guess which
account a default-name token belongs to, stop a list whose targets need no token, or
bind a token by hand to make the step pass.

**Regression guard:** `tests/test-store-token-import.sh` (every default-name read in an
in-scope step follows the list check and the bind for its tool; a published prelude
stops on a list with per-target tokens and runs on a list without them).
