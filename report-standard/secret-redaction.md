# Secret redaction (shared discipline across every audit)

Audits read live provider config that can carry secrets — webhook URLs, API
tokens, bearer headers, cloud keys, connection strings. **A secret must never
reach the terminal, an evidence block, `findings.json`, `report.md`, or a Slack
brief.** This is the shared rule; each audit states it and applies it the same
way, and `ci/redaction-parity-check.sh` enforces that every audit carries the
discipline so a new audit can't silently leak.

## Two layers, both required

1. **Redact at capture (primary).** When a read returns a value that may contain
   a secret (a notification channel's `labels`, an Alertmanager receiver's
   `url`, an app spec's env values, a datasource's `secureJsonData`), capture
   only the **key names / types / receiver names**, never the values. A secret
   that never lands on disk cannot leak. This is the safest layer and every
   audit that reads such a surface must do it.
2. **Redaction pass over written artifacts (defense-in-depth).** Before a report
   or brief is finalized, run the redaction filter over it so any secret that
   slipped through capture is masked in place. `audit-all` does this over the
   combined roll-up (Phase 3.7); a single audit run standalone masks its own
   `report.md` the same way in its final phase.

## The masking filter

`skills/redaction/lib/redaction.sh` provides `redact_file <path>` (masks in
place) and `has_secrets <path>` (detects). It masks AWS access keys
(`AKIA…`/`ASIA…`), long Bearer tokens, Stripe keys (`sk_live_…`), GitHub PATs
(`ghp_…`), and generic `token=`/`password=` query params. A clean file passes
through byte-identical.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/redaction/lib/redaction.sh"
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/<target>/$(date -u +%Y-%m-%d)"
# After report.md is written and validated, mask any secret that slipped capture:
redact_file "$OUT/report.md"
has_secrets "$OUT/report.md" && echo "[redaction] WARNING: residual secret pattern — investigate capture" || echo "[redaction] report clean"
```

## What each audit must state (the parity contract)

Every `audit-*` SKILL.md must carry, in prose, the redaction discipline: a line
that says secret values (webhook URLs, tokens, auth headers, keys) are never
printed or written — captured by key/name only — and, for audits that read a
secret-bearing surface, a pointer to the at-capture redaction step. Audits that
read no secret-bearing surface still state the rule (so the guarantee is uniform
and a future secret-bearing check inherits it). `ci/redaction-parity-check.sh`
checks this is present; `ci/leak-scan.sh` separately catches secrets committed to
the repo. Together: nothing leaks at author time (leak-scan) or run time
(redaction discipline + filter).
