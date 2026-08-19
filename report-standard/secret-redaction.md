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

## The `raw/` working dir and the scope of `ci/leak-scan.sh`

`ci/leak-scan.sh` is a **repo-hygiene gate**: its job is to keep secrets and
machine-identifying values out of the *committed repository* and out of the
*shareable deliverables* an audit produces (`findings.json`, `report.md`,
`report.html`, `inventory.json`). Those four are the leak-clean contract — they
must pass leak-scan on every run.

An audit's `raw/` dump is different. It is **local-only working data** that, by
design, holds the customer's own environment: their resource ids, service names,
and — unavoidably — operator identifiers and free-text fields the provider API
returns. Two rules keep it sane:

1. **Strip structured PII at capture.** Secret values (DSNs, tokens, webhook URLs,
   auth headers) are never written at all. Structured operator identifiers that a
   check does not read — e.g. Sentry `createdBy.email`/`owner`/commit-author
   emails, GCP alert-policy `creationRecord`/`mutationRecord.mutatedBy` — are
   nulled/stripped at capture (a `jq` pass on the raw files), so the common PII a
   leak-scan would flag never lands.
2. **Free-text customer data is out of scope, not a leak.** A value the customer
   embedded in a free-text field — a filesystem path inside *their own* VCS commit
   message, a hostname in a description — is their data, not a secret of ours, and
   cannot be stripped without destroying the evidence the check relies on. Running
   `ci/leak-scan.sh` over an audit's local `raw/` dir will therefore surface such
   values; that is expected and is **not** a leak of anything sensitive. Point the
   gate at the deliverable set (or the repo), never at a customer's `raw/`.
