---
name: business-context
description: Capture your organization's SRE guardrails as a rich, version-controlled source-of-truth file (~/.scoutflo/business_context.md) that every audit and setup reads — SLAs and SLOs per service, per-environment access (which AWS profile / GCP project / cluster each environment uses) and per-environment SLA, critical services that need approval before any change, exclusions (regions/accounts/services/resources to never touch), risky operations to block, cost sensitivity, token budgets, notification routing, and free-form custom rules and runbooks. Captures interactively (guided questions, paste-your-own, or import an existing file). Use when the user wants to set business context, guardrails, per-service or per-environment SLAs, critical-service approval gates, exclusions, custom rules, or a business_context.md. Do not use to create credentials (use connect) or to auto-discover metadata from live labels/tags (use business-context-resolver).
---

# Business Context: your SRE guardrails as a source of truth

`~/.scoutflo/business_context.md` is the one place your organization's rules live — like a `CLAUDE.md` for your infrastructure. Every audit and setup reads it and honors it: SLAs per service, per-environment access and SLA, critical services that gate on approval, regions/accounts/services to never touch, operations to block, cost priorities, and your own free-form rules and runbooks. This skill captures or updates that file interactively; you can also just open and edit the file directly — **the file is the source of truth**, this skill is one convenient way to write it.

It is captured **once per workspace** and reused across every run. Re-run any time to update it.

## What it captures (the full model)

The file follows [templates/business_context_template.md](../../templates/business_context_template.md). You do not have to fill every section — the more you provide, the more precisely audits are tuned to your business:

| Section | What it controls |
| --- | --- |
| Environment + **Environment Map** | Per-environment access: which AWS profile / GCP project / kube context / region each environment uses, and each environment's own uptime SLA. A staging gap is judged against staging's SLA, and staging is audited with staging's profile — never production's. |
| SLAs / SLOs | Per-service SLA + error budget, and (optionally) the **SLI formula** that defines the SLO: the `good_events` and `valid_events` definitions (e.g. "successful checkout / total checkout"), the **exclusion predicate** (what is *not* a valid event — health checks, synthetic probes, scanner traffic), and the SLO target (error budget = `1 − SLO`). Audits that judge alert *quality* (e.g. audit-signoz SIG-042) read this to check an SLI-bound alert uses a burn-rate/multi-window design rather than a flap-prone static threshold; without it they score structural alert quality only and say so. |
| Cost Sensitivity | high = ROI-first, low = impact-first; monthly waste budget. |
| Critical Services | Services that require explicit approval before any change; setups gate on this. |
| Exclusions | Regions / accounts / services / resources to never audit or modify. |
| Risky Operations | Operations blocked by default (terminate, delete snapshot, modify IAM…). |
| Token Consumption Rules | Max tokens per cycle, skip behavior, escalation. |
| Audit Strategy | Scheduling, scope selection, approval requirements. |
| Notification Preferences | Per-event routing (Slack / email / PagerDuty / Jira). |
| Custom Runbooks + Custom Rules | Named team procedures, and any free-form rule the sections above do not capture. |

> **Design decision D1:** multiple targets of one integration in one environment (e.g. three ClickStack instances or several Azure subscriptions under one label set) are all judged against that one environment's context above, and a single integration block must not mix environments across its labels — put a staging target in a separate environment / config file so it is judged against staging's SLA and access, never production's.

## The four ways to provide context (offer all, use any)

After the doctor gate, offer these in order. The user picks any combination; everything past the core is optional.

1. **Guided questions (core).** Always ask the essentials: team, primary environment (prod/staging/dev/dr), and cost sensitivity (high/medium/low). These are the minimum the derived machine projection needs.
2. **Guided questions (rich).** Then offer to walk the structured rich sections one at a time — per-service SLAs, the Environment Map (per-environment profile/project/cluster/region + SLA), critical services, exclusions, risky operations, and **Resource Intent**. Ask only the ones the user wants; skip the rest.
   - **Resource Intent** is the one section an audit can never infer: which resources are *meant* to look idle (a warm standby, a DR replica, a backup target, a deliberately pre-scaled cluster). Ask it as "is anything here supposed to look over-provisioned or idle?", capture your own words as `why`, and offer a `review_by` date so "do not ask again" has an end. Record only what they actually declare — a resource named `-standby` is a prompt to ask, never an answer. Without a declaration the audit correctly keeps reporting it, so leaving this blank is safe; guessing on their behalf is not.
   - **Unit of Delivered Value** is the other one: the metric your business counts (sessions, minutes, recordings, conversations, orders). Ask for the metric they already graph — if it is on a dashboard the team trusts, it is the right one — and capture their own query verbatim. Declare more than one if the product has more than one; they are reported separately and never added together. The `scope` must match the spend it will be divided by, so ask which cluster/project/namespace the metric covers. Leave it out and the audit reports per-namespace and per-project spend instead, which is honest but is not unit economics. **Never pick a unit on their behalf** — a countable infrastructure metric (requests, pods, nodes) is always available and almost never what the business counts, and a wrong denominator is harder to spot than a missing one because the number looks finished.
3. **Paste your own.** Offer: "Paste any custom rules or runbooks in your own words — I'll add them verbatim under Custom Rules." Capture free-form text and append it (never reword it).
4. **Import an existing file.** Offer: "If you already keep an SRE guardrails / runbook / context file, give me its path and I'll adopt it as your business_context.md (or reference it)." Validate and derive it before adopting it. If context already exists, show the source path, destination and proposed changes, then obtain explicit confirmation for this replacement. An invalid import leaves both existing files unchanged.

Never force the full interview. A user who only wants to set environment + cost sensitivity and paste three custom rules gets exactly that, and the file is valid.

## Doctor gate

```bash
set -eu
command -v jq >/dev/null || { echo "missing binary: jq"; exit 1; }
SCOUTFLO_DIR="${HOME}/.scoutflo"
mkdir -p "$SCOUTFLO_DIR"
LIB="${CLAUDE_PLUGIN_ROOT}/skills/business-context/lib/business-context.sh"
[ -f "$LIB" ] || { echo "missing $LIB"; exit 1; }
echo "doctor gate: pass"
```

## Live-safety gate

This skill writes local files under `~/.scoutflo/`: `business_context.md`, its derived `business_context.json`, and import backups under `backups/business-context.*/`. It never touches a live provider. If a file already exists, print its path and confirm before overwriting; an update appends or re-derives, it does not silently discard prior content. The import helper refuses an existing destination without `--confirm-replace`; pass that flag only after the user approved this exact replacement. It stages and validates both new files, saves the previous pair, and restores it if installation fails. Re-derivation also preserves the prior JSON on an error.

```bash
set -eu
SSOT="${HOME}/.scoutflo/business_context.md"
if [ -f "$SSOT" ]; then
  echo "business_context.md already exists at $SSOT — updating it (existing content is preserved; confirm before overwrite)"
else
  echo "no business_context.md yet — a new one will be created at $SSOT"
fi
echo "live-safety gate: pass (writes local files only, never a live provider)"
```

## The capture flow

For **guided or paste** capture, start by migrating any legacy scalar store so no prior context is lost. For **import**, skip this initialization and use the import block below directly: it must not create or alter context before validating the chosen source.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/business-context/lib/business-context.sh"
# If an older workspace saved scalars to topology.json:.business_context and no
# SSOT exists yet, seed the SSOT from it (never deletes topology.json).
bc_migrate_from_topology
# If still no SSOT, scaffold one from the template as the starting point.
[ -f "${HOME}/.scoutflo/business_context.md" ] || bc_scaffold_from_template
```

Then, per the mode the user chose:

- **Guided (core + rich):** edit the scaffolded `~/.scoutflo/business_context.md` in place with the user's answers — fill the Environment block, the Environment Map table rows (one per environment, with its profile/project/context/region/SLA), the SLA table, Critical Services bullets, Exclusions, Risky Operations. Write real values into the template's bracketed placeholders; leave untouched sections as-is.
- **Paste:** save the user's text verbatim in a local text file, then set its path in this self-contained block. The helper appends under a timestamped Custom Rules heading; it never executes or rewords the pasted text:
  ```bash
  set -eu
  . "${CLAUDE_PLUGIN_ROOT}/skills/business-context/lib/business-context.sh"
  CUSTOM_RULES_FILE="/path/to/pasted-rules.txt"
  [ -f "$CUSTOM_RULES_FILE" ] && [ -r "$CUSTOM_RULES_FILE" ] || { echo "set CUSTOM_RULES_FILE to the saved text file"; exit 1; }
  bc_append_custom < "$CUSTOM_RULES_FILE"
  ```
- **Import:** set the source path. Leave `CONFIRM_REPLACE=no` for a new store. Set it to `yes` only after showing the proposed replacement and receiving the user's explicit confirmation; an old approval does not carry over to another file:
  ```bash
  set -eu
  . "${CLAUDE_PLUGIN_ROOT}/skills/business-context/lib/business-context.sh"
  CONTEXT_FILE="/path/to/their/context.md"
  CONFIRM_REPLACE=no
  case "$CONFIRM_REPLACE" in
    yes) bc_import_file "$CONTEXT_FILE" --confirm-replace ;;
    no) bc_import_file "$CONTEXT_FILE" ;;
    *) echo "CONFIRM_REPLACE must be yes or no"; exit 1 ;;
  esac
  ```

After any capture, validate and derive the machine projection:

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/business-context/lib/business-context.sh"
bc_validate                 # gates on ci/validate-business-context.sh
bc_derive_json              # regenerate ~/.scoutflo/business_context.json from the .md
```

## The two files this produces

| File | Role | Edited by |
| --- | --- | --- |
| `~/.scoutflo/business_context.md` | **Source of truth** — human-authored, rich, version-controllable | you (this skill, or directly) |
| `~/.scoutflo/business_context.json` | **Derived projection** — the structured fields (environment, cost_sensitivity, critical_dependencies, environment_map, service_slas, exclusions, resource_intent, unit_metrics) the shell libs read | regenerated from the .md, never hand-edited |

Editing the `.md` and re-running `bc_derive_json` (or the skill) refreshes the `.json`. The `.json` never overrides the `.md`.

## How other skills use it

- **audit-\*** read the file to adjust finding severity (a staging gap is judged against staging's SLA), skip excluded resources, and mark critical services.
- **correlation-engine / cost-analysis / topology-guided-setup** read the derived `business_context.json` for environment, cost sensitivity, and the critical-services approval gate.
- **setup-\*** read Critical Services + Risky Operations to require approval before a gated change.
- **business-context-resolver** reads `business_context.md` as its input and auto-discovers per-resource metadata from live K8s labels / AWS tags / CODEOWNERS into `computed_metadata.jsonl` (a derived cache).

## Standalone and update

```text
/scoutflo:business-context           # capture or update interactively
/scoutflo:business-context --import /path/to/file.md   # adopt an existing file
```

Editing `~/.scoutflo/business_context.md` by hand and re-running the skill (or just `bc_derive_json`) is fully supported — the file is authoritative.

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Only 5 scalar questions, everything else dropped (the pre-rebuild bug) | Four capture modes: core + guided-rich + paste + import; the full template is the model, not 5 fields |
| Rich typed context "goes nowhere" | Paste mode appends verbatim under Custom Rules; import mode adopts a whole file; nothing typed is discarded |
| Context saved to the wrong file (topology.json) | The SSOT is `business_context.md`; `topology.json:.business_context` is read only as a legacy fallback and is migrated on first run |
| A staging gap judged against production's SLA | The Environment Map holds each environment's own SLA + access; audits judge per environment |
| Two sources disagree | `.md` is authoritative; `.json` is always derived from it, never hand-edited |
| Imported file missing required sections | Import exits nonzero before replacing either file; fix the source and retry |
| Existing context overwritten by import | The helper requires explicit replacement confirmation and retains the old Markdown/JSON pair under `~/.scoutflo/backups/` |
| Misspelled `resource_intent` match key or `unit_metrics` name | The declaration is excluded with a count warning on stderr; fix its key and re-derive before relying on it |
| Projection or installation fails | Staged derivation leaves the published pair intact; an installation failure restores the backup. If recovery itself fails, stop and restore both files from the printed backup path |

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Context captured/updated, validated, and derived |
| 1 | User cancelled, replacement unconfirmed, or a required binary/file operation failed |
| 2 | Import validation or staged derivation failed; the existing Markdown and JSON are unchanged |

---

**v0.1.80** — Rebuilt from a 5-field scalar prompt into rich SSOT capture: `business_context.md` is the source of truth, captured by guided questions + paste + file import, with a per-environment access/SLA map; the derived `business_context.json` feeds the shell libs; legacy `topology.json:.business_context` is migrated.
