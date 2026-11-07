# Source evidence and batched paging-path assessment

SOC-007 joins a verified upstream source to one selected On-Call account, route,
policy, team and current responder path. An incoming alert URL uses a different
host and credential from the management API. A monitor handle, resolved hostname,
intermediary webhook or count of monitors does not establish this join. The
source audit owns source-rule evaluation and destination resolution; On-Call owns
the downstream management relationship. Neither proves delivery to a person.

## Producer envelope and capture receipt

The metadata-only producer artifact uses `schema:
scoutflo-alert-source-evidence/v1` and exactly these fields:

| Field | Meaning |
| --- | --- |
| `producer` | `audit-<source_provider>` or `attended-source` |
| `source_provider` | `datadog`, `clickstack`, `alertmanager`, `prometheus`, `grafana`, `sentry`, `kubernetes` or `generic` |
| `source_target` | Exact selected source target, including its label where configured; never a display name or inferred account |
| `observed_at` | UTC `YYYY-MM-DDTHH:MM:SSZ` of the actual source observation |
| `verification` | `{kind,status,evidence_ref}`; kind is `api-read`, `attended` or `import-only`; status is `verified`, `candidate` or `blocked` |
| `records` | Every in-scope source-path record, including unresolved destinations |

Each record has exactly `record_id`, `source_id`, `route_env`,
`route_verification` and `definition`. `record_id` is unique within the source
capture; one monitor can have multiple paths. `source_id` is its native ID.
`route_env` names a protected exact routing-key value or is null.
`route_verification` is `verified`, `candidate` or `blocked`. Set verified only
after an independent read or attended observation actually established that
protected value for this source. Capturing source configuration successfully
does not verify its route. Datadog handles and ClickStack resolved webhook IDs
remain candidates until the exact downstream mapping is observed.

`verification.evidence_ref` names a sibling receipt, such as
`source-routing-capture.json`. No parent traversal, symlinks or arbitrary file
paths are accepted for this reference. The receipt has exactly:
`schema: scoutflo-alert-source-capture/v1`, `producer`, `source_provider`,
`source_target`, `observed_at`, `verification: {kind,status}` and
`records_sha256`. All shared fields must equal the envelope. The digest is SHA256
of `json.dumps(records,sort_keys=True,separators=(',',':'),ensure_ascii=True,
allow_nan=False).encode()`. Producers write the receipt only after validating the
actual captured source response and selected target. Packaging an old/imported
file must retain `import-only`; a free-standing verified flag is insufficient.

The fixed safe definitions are:

- **Datadog:** `monitor_id`, `monitor_type`, `notification_handles`, `enabled`,
  `service_tags`, `source_site`. Handles and service tags use the source audit's
  safe projection. No message, query, URL or header.
- **ClickStack:** `alert_id`, `source_id`, `connection_id`, `enabled`,
  `channel_type`, `receiver_id`, `receiver_resolution`, `destination_class`,
  `destination_kind`. Missing or ambiguous receiver joins remain blocked.
- **Other/attended source:** `source_id`, `kind`, `receiver_id`, `enabled`,
  `destination_kind`. Use safe IDs, boolean/null enabled and a destination kind
  of `oncall-inbound`, `intermediary`, `other` or `unknown`.

An attended receipt records a completed observation, not a promise to check it.
Inspect its underlying UI/config read and exact protected-value comparison before
authoring it. This is local provenance, not a digital signature from the provider;
the tools cannot make operator-invented evidence trustworthy. Never convert a
candidate producer artifact to verified by editing its flags. Keep the original
capture and record a new attended observation with its own time and receipt.
The helpers reject unknown fields, duplicate JSON keys, non-finite values, unsafe
strings, oversized input (2 MiB per file) and more than 2,000 path records. Larger
worklists require explicitly selected source batches; record each omitted tail.

## Declare the intended mapping and bind privately

Create a mapping file with `schema: scoutflo-oncall-source-mapping/v1`, exact
`source_provider`, `source_target`, `source_sha256` of the complete source file's
bytes, `expected_oncall_target` equal to the selected config segment, and
`records: [{record_id,expected_policy,expected_team}]`. These are declared intended
destinations, not values guessed from the currently observed On-Call response.
Duplicate or foreign record IDs are rejected. An omitted mapping remains a
blocked source record. No source record disappears from the denominator.

Run the local binder after the audit's doctor/target selection. It reads only the
configured read-only credentials and verified records' named route variables from
the protected store. It makes no provider calls, writes nothing itself, and never
falls back to a setup credential. Set `SCOUTFLO_SOURCE_EVIDENCE`,
`SCOUTFLO_SOURCE_MAPPING` and `SCOUTFLO_ONCALL_SOURCE_BINDING` to private files.

```bash
set -eu
set +x
umask 077
: "${SCOUTFLO_SOURCE_EVIDENCE:?Select the verified source export}"
: "${SCOUTFLO_SOURCE_MAPPING:?Select its reviewed intended mapping}"
: "${SCOUTFLO_ONCALL_SOURCE_BINDING:?Select a new private bound-packet path}"
[ ! -e "$SCOUTFLO_ONCALL_SOURCE_BINDING" ] || { echo 'Preserve the existing generation; select a new packet path'; exit 2; }
PACKET=$(sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-splunk-oncall/scripts/collect.sh" --bind-source-evidence "$SCOUTFLO_SOURCE_EVIDENCE" "$SCOUTFLO_SOURCE_MAPPING")
printf '%s\n' "$PACKET" > "$SCOUTFLO_ONCALL_SOURCE_BINDING"
```

The resulting `scoutflo-oncall-source-binding/v1` packet binds the exact source
file and receipt digests, source target, safe definition hash, observation time,
selected On-Call target, credential generation, intended policy/team and exact
protected route value. Only a private keyed HMAC binds sensitive values. A route
value is never emitted, hashed without a key, or used as a persistent resource ID.
The packet contains a private local source-file reference: keep it outside public
repositories and shared reports. It is evidence for this run, not a bearer
credential. Renaming a source file, replacing its receipt, rotating credentials,
changing a source definition or reusing a route variable for another key requires
rebinding after a new verified observation. Changing only the selected target
cannot replay an otherwise identical route/policy/team chain in another account.

## Collect once and assess every source path

This block makes one complete, rate-limited management collection. Exact-key
comparisons happen in memory before projection. It then executes the same
[effective-quality predicate](effective-quality.md) locally for every record.
It does not repeat the full collection per monitor. A routing snapshot is
sequential evidence with observation times, not an atomic snapshot.

```bash
set -eu
set +x
: "${SCOUTFLO_ONCALL_SOURCE_BINDING:?Select the current private bound packet}"
SNAPSHOT=$(sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-splunk-oncall/scripts/collect.sh" --source-records "$SCOUTFLO_ONCALL_SOURCE_BINDING")
printf '%s' "$SNAPSHOT" | sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-splunk-oncall/scripts/source-evidence.sh" evaluate "${CLAUDE_PLUGIN_ROOT}"
```

The metadata-only result is `scoutflo-oncall-source-assessment/v1`. Its unit is
`source-path-records`, with `total`, `assessed` and separate `verified`, `not-met`,
`blocked`, `inapplicable` counts plus one result per record. `assessed` includes
verified and not-met only. Candidate routes, missing expected mappings and
unverified current responders remain blocked. An exact verified source key that
does not select its intended policy is not-met, subject to the catalog's
confirming-read requirements before a finding. Multiple matches are ambiguous.
No score, page count, redundancy requirement or delivery claim is invented.

Include the source and management target/time, covered records and blocked tail
in the audit report. These counts describe selected paths, not unique monitors,
unique applications, incidents or delivered notifications. Populate SOC-007's
check ledger and any resulting finding under the existing report standard; this
assessment is supporting evidence, not a second scoring model. For one repaired
path use [verify-path](verify-path.md) with its exact record ID. Old source files
and `source_match` snapshots remain readable but cannot certify new SOC-007
provenance; their other established check semantics remain unchanged.
