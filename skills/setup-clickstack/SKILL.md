---
name: setup-clickstack
description: Guided hardening of a ClickStack (ClickHouse + HyperDX + OpenTelemetry) stack from audit-clickstack findings. Sets deliberate per-table retention TTL on the otel_* telemetry tables, creates a HyperDX alert wired to a live receiver, creates a scoped read-only ClickHouse user for audits, and hardens ClickHouse auth (plaintext_password to sha256_password, default-user password). States each change, waits for your confirmation, executes one object at a time, then re-reads and verifies live. Use when the user asks to fix a CS-NNN finding, set otel_* retention, wire a HyperDX alert to a receiver, create a read-only ClickHouse audit user, or move a ClickHouse user off plaintext_password. Do not use for read-only assessment (use audit-clickstack), for Grafana-fronted dashboards (use setup-grafana), or for the Alertmanager paging path (use audit-alertmanager).
disable-model-invocation: true
---

# setup-clickstack

Repair the selected `audit-clickstack` findings through a concrete change plan, a supported administrative surface and a fresh audit retest. The supported changes are table TTL, a dedicated read-only audit user, user authentication hardening and HyperDX alert configuration. Collector, storage, TLS, dashboard and source changes receive a bounded plan with an owner. These scope boundaries are explicit; an unimplemented change is never reported as fixed.

| Finding | Workflow | Effect |
| --- | --- | --- |
| CS-020 | [Set retention TTL](#set-retention-ttl) | Change one selected table's automatic retention |
| CS-040 | [Create HyperDX alert](#create-hyperdx-alert) | Create or repair one alert and its selected channels |
| CS-050 | [Create read-only user](#create-read-only-user) | Create a new dedicated principal and scoped grants |
| CS-050 | [Harden ClickHouse auth](#harden-clickhouse-auth) | Change a selected user's authentication method/credential |
| CS-060 | [Manage storage capacity](#manage-storage-capacity) | Owner plan for measured headroom risk |
| CS-030/061 | [Manage merge pressure](#manage-merge-pressure) | Owner plan for evidenced merge/write failures |
| CS-010/011 | [Fix collector pipeline](#fix-collector-pipeline) | Owner plan for the exact stale service/signal path |
| CS-041 | [Create dashboard source](#create-dashboard-source) | Owner plan for the exact source/data binding |

## Target and credential boundary

Use the same `clickstack` block or selected labeled list item as the audit, with `SCOUTFLO_TARGET` for a list. The existing keys are `clickhouse_url`, `clickhouse_user`, `clickhouse_password_env`, `hyperdx_url`, `hyperdx_api_key_env`, and the optional explicit legacy session email/password variable names. Do not invent separate `clickhouse.*` or `hyperdx.*` config blocks. Read-only audit credentials stay read-only.

ClickHouse changes are **attended administration workflows**, not executable placeholder SQL templates. Use the actual target's supported administrator console or client, authenticated with the separately approved elevated credential from the local secret store. Never substitute the audit user, an inherited terminal connection, a password-bearing command argument, or an unverified generic API body. If the administrative surface is unavailable, preparation can finish but application stays blocked. Authentication/grant/DDL behavior must be confirmed for that installed ClickHouse version before execution.

HyperDX changes use the exact selected instance's UI. The current external API v2 key reads are separate from legacy internal session routes. A status code from `/api/health` or `/api/alerts` alone is not authentication proof. Never try header variants or fall back from a selected but missing API key to another login.

## Doctor gate and live-safety gate

Resolve the selected target and run `/scoutflo:doctor` before planning. Print the selected label and hostnames only; never full credential-bearing URLs. Use the audit's [target and probe blocks](../audit-clickstack/SKILL.md#doctor-gate), which resolve config/secret names afresh and assert actual responses. A configured unreadable lane is blocked, not excluded.

For ClickHouse, read this independent server identity with the safe read-only helper:

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/clickhouse-context.sh"
chq "SELECT hostName() AS host, currentUser() AS user,
            currentDatabase() AS database, version() AS version FORMAT JSON"
```

Compare the actual server identity and database with the intended account/environment, then record the verified identity in the plan. A host behind a proxy may differ from the URL host; establish that mapping explicitly rather than weakening the check. In the administrator surface, independently verify the same server/database and the intended elevated principal before any write. A mismatch stops application; a positive table count on another server never passes this gate.

Bootstrap exception: creating the first audit user may precede a usable read-only credential. In that case establish server/database/principal identity with an attended admin read, record that narrower proof, create only the approved user, then configure the new read credential and pass the full doctor/audit gate. Do not claim the bootstrap read was an independent read-only audit.

## Load findings and build the change plan

Read only the selected target's latest completed report. Historical findings must be revalidated before changing anything.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/target-context.sh"
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/$CS_SEG"
# Only a dated audit with both artifacts is a completed report candidate.
# setup-*/ and runs/ are workspaces, never a newer audit.
LATEST=$(for f in "$TARGET_DIR"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/findings.json; do
  [ -f "$f" ] && [ -f "$(dirname "$f")/report.md" ] || continue
  CANDIDATE_DATE=$(basename "$(dirname "$f")")
  jq -e --arg t "$CS_SEG" --arg d "$CANDIDATE_DATE" '
    .target==$t and .run_date==$d and (.findings|type=="array")
    and (try (($d+"T00:00:00Z")|fromdateiso8601|.<=now and strftime("%Y-%m-%d")==$d) catch false)
  ' "$f" >/dev/null 2>&1 || continue
  printf '%s\n' "$f"
done | sort | tail -1)
[ -n "$LATEST" ] || { echo 'Run the selected audit before planning'; exit 1; }
jq -e --arg t "$CS_SEG" '.target==$t and (.findings|type=="array")' "$LATEST" >/dev/null
jq -r '.findings[] | [.id,.severity,.title,.remediation] | @tsv' "$LATEST"
```

Prepare a private run directory beneath that target, with a unique run ID, and retain a plan, safe preimages, postimages and an append-only change ledger. Directory creation is local preparation, not provider application. Every row names:

| Required field | Meaning |
| --- | --- |
| Finding and intended outcome | Exact check, service/signal and declared requirement |
| Target and object | Config segment, independently verified server/account, database and immutable object ID where available |
| Before and after | Exact fields to change, selected channels/grants/TTL interval, neighbouring fields to preserve |
| Authority and risk | Existing approval for this exact effect, or the concrete confirmation still needed |
| Safe preimage and restore | Reconstructable nonsecret prior fields, protected secret-store references, rollback limitations |
| Verification predicate | Exact readback equality, affected client check and follow-up audit |

Never retain raw `SHOW CREATE TABLE`, engine arguments, auth parameters, webhook URLs or arbitrary response bodies in the ledger. They can contain credentials. The audit helpers project them before output. A projected preimage is suitable for restore only when it contains the complete changed semantics; an unknown TTL or masked receiver is not a recoverable backup.

## The change protocol

1. Present the concrete plan, including exact effects, risk, preserved neighbours and restore limits. Existing approval remains valid for the same reviewed scope; a different target or effect requires a new confirmation. A vague repair request does not authorize an unreviewed destructive consequence.
2. Re-read the object immediately before application and compare it with the approved preimage. Changed identity or drift stops that row.
3. Apply one approved object through the supported administrative surface. Keep secrets in the provider's protected input or local secret store, never chat, command history, screenshots, output or backups. Do not assume the server will mask an unsafe client-side command.
4. A timeout or uncertain save is **unknown**, not a retry signal. Read back the exact object ID before taking another action. Never repeat a create blindly.
5. Verify actual postimage equality and preserved neighbours. Stop at the first failed or unverified row; record already-applied effects and do not run the next row.
6. On partial creation, preserve the exact immutable ID and successful stages. Cleanup is allowed only for an object this run created, after a current identity/postimage comparison and approved cleanup. A matching name or two familiar grants never proves ownership.
7. Re-run the relevant read-only audit. Distinguish configuration repair, effective client behavior and any external receipt. Retention deletion and notifications already sent cannot be undone by restoring configuration.

## Set retention TTL

CS-020; one selected telemetry table. Before choosing a value, capture the declared retention need, exact database/table, timestamp semantics, current disk/part/byte footprint and the current **table DDL TTL** through the safe `create_table_query` projection. `engine_full` can omit TTL and cannot establish its absence. A column TTL, conditional TTL, move/recompression rule or unsupported expression requires an attended semantic read; never flatten it into a simple delete TTL.

1. Record a reconstructable prior TTL rule or verified absence. Keep raw DDL private in the provider UI; store only validated changed semantics. Unknown prior rules block an automated restore claim.
2. Present the exact desired expression for the verified timestamp column and interval, plus the data-deletion and I/O effect. Reducing retention may delete old data that configuration rollback cannot recover. Show which backup/restore evidence or explicit data-loss acceptance covers that consequence. Obtain any required destructive-change approval before application.
3. Confirm installed-version behavior for TTL materialization. `MODIFY TTL` can schedule work on existing parts depending on settings; do not promise a cheap metadata-only change. If offering `materialize_ttl_after_modify=0`, first verify support and explain the difference between existing and future parts.
4. In the confirmed admin surface, apply only the approved table TTL. Never rebuild the table or change its schema as a shortcut. On ambiguity, inspect the actual table definition and mutation state before retrying.
5. Read back `create_table_query` through the audit helper. Assert the full changed TTL semantics, not a substring somewhere in an engine string. For a supported simple day TTL, the projected `ttl.days` must equal the approved days and `ttl.assessment` must be `known`. Check the specifically attributable mutation/job; the latest unrelated mutation is not this write's completion proof.
6. Recheck the affected service's data, retention and headroom. Mark any ongoing materialization pending; do not claim storage reclaimed merely because the TTL was saved.

**Restore:** compare the current TTL with this run's verified postimage and restore the exact prior rule or remove only the rule this run added. Reconfirm disruptive effects as needed. Re-read the full changed semantics and job state. Restoring a TTL does not restore deleted rows; use the separately approved data restore if one is required.

## Create HyperDX alert

For CS-040, repair the exact configured channel that the audit found missing or unresolved. Existing alternate channels may still deliver; do not replace them or claim every alert reaches nobody. **Risk class: HyperDX alert configuration; optional notification test is a separate external effect.**

Use the [safe read recipe](../audit-clickstack/references/hyperdx-source-evidence.md) to identify the target, alert ID, channel index, destination class and completeness. OSS external v2 uses the Personal API Access Key on `/api/v2` (or its verified proxy prefix); legacy `/api/alerts` is session-authenticated. Do not send a Bearer key to a session route or copy a legacy payload to a different edition. Current `channels[]` is authoritative when present; `channel` mirrors the first. A new alert may monitor a tile, saved search or inline chart, with version-specific required fields.

The supported repair workflow is attended in the selected HyperDX UI:

1. Open the exact target and alert from the safe audit record. For a new alert, identify the existing source and tile/saved search, the customer's threshold, interval, signal semantics and intended responder. Do not invent a local alert when external alerting is declared intentional.
2. Read the current full definition privately in the UI. Record a redacted preimage: alert ID, channel IDs/order, activation, source selection, threshold/window and a safe field inventory. Keep any credential-bearing receiver URL in the provider UI or approved secret store only. If a masked receiver cannot be recovered, record the restore limitation before proposing replacement.
3. Confirm that the selected webhook exists on this same target. Its URL host alone is insufficient: verify the intermediary's onward mapping or the paging provider's expected routing policy with its owning read audit. A newly minted incoming credential or expanded access requires the applicable explicit approval.
4. Present the exact before/after fields, scope, intended external notifications, preserved channels and rollback. Obtain the operator's confirmation under **The change protocol**. Re-read before save; if the target or definition changed, stop and refresh the plan.
5. Change only the confirmed fields, or create the confirmed alert. Save once. On an uncertain save, read back by the exact ID before trying again; never create duplicates by retrying blindly. Record only safe IDs and field equality, not raw payloads or response bodies.
6. Run the fixed audit collection again in a fresh shell, with this target selected:

```bash
set -eu
sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/collect-hyperdx.sh"
```

Match the exact alert/channel ID to the expected receiver and preserved channel list in the current safe projection. Use a separate fresh attended UI read to verify the full source selection, activation, threshold/window and any fields omitted by the projection against the approved postimage. Neither read substitutes for the other. This proves configuration repair only. Under separately confirmed test scope, generate one identifiable source event, verify the destination incident and ask the intended responder to confirm receipt. Record source recovery/incident resolution separately; do not confuse either with acknowledgement. A configuration-only repair leaves delivery explicitly unverified.

**Rollback:** re-open the same target and exact alert ID, compare it with this run's verified postimage, and restore only the recorded prior fields after confirmation. If the run created a new alert, deletion requires this run's creation receipt; never delete a pre-existing alert as rollback. If fields drifted or the masked preimage cannot be restored, stop and report the exact limitation rather than guessing. Re-run the safe audit read to verify restoration and preserved neighbours. Changes do not retract notifications already sent.

## Create read-only user

CS-050. Through the verified administrator surface, create one dedicated read-only principal using the installed version's supported password and grant controls. The secret is generated/stored through a protected store, not interpolated into a displayed SQL string.

- Before creation, prove the name is absent and record current principal inventory. Do not use `IF NOT EXISTS` to disguise an existing user, or grant onto an existing principal under a create plan.
- The plan lists the exact telemetry database/tables and required system-table reads. Grant the minimum necessary `SELECT`/metadata permissions without write, access-management or grant-option privileges. Inspect inherited/default roles too; two explicit SELECT grants do not prove effective least privilege.
- Record the new immutable user ID and each completed stage immediately. If creation succeeds but a grant fails, stop. Read actual state before any retry; never issue another create.
- Verify the actual authentication method and complete effective privilege set. Use the new credential for a real read of the intended telemetry/system surfaces, and verify its read-only profile/grants without attempting a destructive write as a test.
- Configure that principal in the selected `clickstack.clickhouse_user` and `clickhouse_password_env` through `/scoutflo:connect`; keep elevated credentials separate. Run doctor and a fresh audit with this principal.

**Cleanup/restore:** dropping a newly created principal requires this run's immutable creation receipt, the same target, no intervening principal replacement or grant drift, and confirmation that no client depends on it. A name, current existence or familiar grants is not ownership proof. If the user pre-existed, do not drop it. Remove only run-owned changes after a reviewed restore plan and verify absence/effective grants. Update the local connection only after a usable replacement is verified.

## Harden ClickHouse auth

CS-050. Record the selected user's immutable identity, authentication method, effective grants, dependent clients and secret owner. Do not record `auth_params` or raw password/hash values. Authentication-method metadata is an inventory snapshot, **not** a password backup.

1. Identify a supported target authentication method and credential delivery mechanism for this installed version. Coordinate the new protected secret with every affected client owner before changing a service user. Never reset the currently used administrator principal as an incidental fix.
2. Present the exact user, method change, rollout order, outage exposure and recovery secret owner. A service credential change can break ingestion immediately; obtain the required approval for that impact.
3. Re-read identity/preimage, then change only the approved authentication fields in the administrative surface. No password appears in command arguments, history, reports or backups.
4. Verify the new method from the safe user projection. Then verify a real client authenticates with the intended new secret and resumes its expected reads/writes. Merely seeing `sha256_password` does not prove that the deployed client works.
5. For an open default user, re-run the audit's exact unauthenticated query probe and interpret `denied`, `accessible` and `unverified` separately. A generic HTTP denial does not establish a ClickHouse password policy.

**Recovery:** an unreadable old password cannot be restored from an auth-type snapshot. Use the owner-supplied recovery credential or a forward rotation with an explicit plan, then verify each dependent client. Never label that action a verified restoration of an unknown old secret. TLS/listener changes are a separately owned server configuration plan.

## Manage storage capacity

CS-060, plan with a named storage owner. Base the plan on measured free space and verified same-disk growth samples, not retained bytes divided by part age. Options include capacity expansion, a verified storage policy or deliberate retention changes. For each option state the exact volume/table, new value, resource cost, possible data movement and reversibility. A grown disk usually cannot be shrunk as rollback. After the owner applies the approved change, read the same disk and affected tables again; verify headroom against the declared target and ingestion against real write/freshness evidence. No forecast without comparable samples and assumptions.

## Manage merge pressure

CS-030/061, plan with a named database/collector owner. Confirm actual active-part pressure and recent INSERT exceptions; cumulative error counters alone are insufficient. Prefer correcting small-batch/high-frequency ingestion when evidenced. Raising a part limit changes the failure tradeoff and is not a repair by itself. Record batch/flush or database-setting preimages, exact effects and restore method. Retest part trends, affected service freshness and the actual write-exception window after the owner applies the approved change.

## Fix collector pipeline

CS-010/011, plan with the collector owner. Trace the exact service/signal through effective configuration: explicit `env` overrides `envFrom`, receiver listeners differ from exporters, and parallel storage outputs must remain intact. Preserve unrelated branches and secret references. Confirm endpoint/account/database/table binding before proposing a change. After approved application by the owner, verify fresh data for that service and signal, plus write-path health; a global table maximum or another region's activity cannot certify it.

## Create dashboard source

CS-041, plan with the HyperDX owner. Confirm dashboard tile → source ID → connection ID and independently compare the connection's endpoint/database/table with the actual data plane. Matching regional hostnames or table names are not that proof. Preserve alternate sources and tiles, record exact pre/postimages, and let the owner apply the approved version-specific change. Retest source IDs, the exact service query and usable panel data. Zero alerts never removes this workflow. This section prepares and verifies the owner plan; it does not silently expand the skill's write scope.

## Record and wrap up

Use the selected target's private `changes.md` and run directory, preserving prior runs. Each row records timestamp, finding, immutable object identity, exact safe field changes, approved authority, application stage, verification result, preserved neighbours, restore receipt and remaining owner action. Never mix targets into the legacy flat path; flat single-block and nested labeled paths both remain supported.

End with the completed, blocked and owner-plan rows separately. Run `/scoutflo:audit-clickstack` in a new shell for the same target and compare the actual finding lifecycle/check results. Configuration repair is enough only for a configuration check. A separate approved test event and matching human receipt are needed before claiming delivery. Recovered source health, incident resolution and human acknowledgement are distinct observations.

## Common failure modes

| Failure | Required handling |
| --- | --- |
| Placeholder URL or inherited admin connection | Resolve selected config; compare independent server/database identity in both read and admin surfaces |
| API-key denial followed by login fallback | Selected key stays blocked; legacy login is a separately explicit mode |
| TTL inferred from engine string or substring | Read full table TTL through safe projection; unsupported expressions need attended interpretation |
| Unknown old password treated as a backup | Record the recovery owner and verified protected credential path, or leave recovery unverified |
| Partial user creation retried blindly | Read exact immutable ID/stages; finish or clean up only approved run-owned effects |
| Two familiar grants treated as creation ownership | Require this run's immutable creation receipt and current drift check |
| Receiver exists so delivery is certified | Keep configuration/readback separate from incident and human receipt |
| Mutation succeeds but verification fails | Stop the batch, retain unknown state and inspect before retrying |
| Raw DDL, webhook, password or error saved | Capture only safe projections and protected-store references |
| Owner plan presented as applied | Keep it pending until application and the exact audit retest are observed |
