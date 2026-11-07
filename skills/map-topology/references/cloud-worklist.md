# Cloud Mode: local service assessment worklist

Use this on the large Cloud Mode path after the scope checkpoint. It tracks
judgment over the selected services and retained projected captures. It does
not call cloud providers, read credential values, or replace the cookbook's
collection steps. Keep it separate from the Kubernetes namespace worklist.

Resolve one target from the selected config: a single block uses `aws`,
`gcp`, `azure` or `digitalocean`; a labeled list uses `provider/label`.
Duplicate or missing labels stop. Each target has its own durable run under
`SCOUTFLO_AUDIT_DIR/map-topology/cloud-runs/`. The binding includes selected
non-secret config metadata, catalog bytes, audit date, source generation and
capture digests. Changed metadata, scope or captures cannot resume old work.

## Declare the selected service catalog

After the existing provider discovery and scope review, save a private
`cloud-services.json` beside the projected captures. Derive its service IDs
from the selected provider evidence; no name-based cross-target merging.
It must contain a nonempty selected service denominator, unique IDs and the
lanes to assess for each service. Catalog `observed_at` is the actual
collection-completion time, not the time this file was written. Retain each
discovery capture's own actual timestamp and independently computed SHA-256;
captures may occur earlier on the same audit date and cannot be later than
collection completion. Example shape
(replace the example date and digest with the actual captured values):

```json
{
  "schema": "scoutflo-cloud-topology-catalog/v1",
  "target": "aws/east",
  "audit_date": "2026-01-15",
  "observed_at": "2026-01-15T10:00:00Z",
  "collection": {"status": "partial", "scope": "subset"},
  "services": [
    {"id": "checkout", "kind": "ecs", "lanes": ["declared", "permitted", "reachable"]}
  ],
  "captures": [
    {"ref": "captures/services.json", "sha256": "replace-with-actual-sha256", "observed_at": "2026-01-15T10:00:00Z"}
  ]
}
```

Allowed lanes: `inventory`, `declared`, `permitted`, `reachable`, `observed`.
Collection status is `complete`, `partial`, `blocked` or `unknown`; scope is
`target`, `subset` or `unknown`. `complete` requires `target` scope. Blocked
or unknown collection can retain an independently declared service list,
but cannot claim that list was fully discovered. Never use an empty catalog
to certify completion. Captures and receipts must stay under this catalog's
directory; path traversal, symlink files, duplicate JSON keys and oversized
files are rejected.

Retain only the projected metadata from the cloud cookbook. Never save raw
task definitions, app settings, env values, tokens or connection strings.
The worklist stores identifiers, results and hashes; it does not sanitize
arbitrary source files or authenticate operator declarations.

## Initialize or resume

Set the selected config, target, catalog path and audit directory explicitly
in the shell tool environment. Every block below runs in a fresh shell.
`init` preserves an existing matching run; it never discards unfinished work.

```bash
set -euo pipefail
python3 "${CLAUDE_PLUGIN_ROOT:?Set the installed plugin root}/skills/map-topology/lib/cloud-worklist.py" \
  --config "${SCOUTFLO_CONFIG:?Set the selected config}" \
  --target "${SCOUTFLO_CLOUD_TARGET:?Set the selected cloud target}" \
  --catalog "${SCOUTFLO_CLOUD_SERVICE_CATALOG:?Set the selected service catalog}" \
  --root "${SCOUTFLO_AUDIT_DIR:?Set the selected target audit directory}" init
```

Expected: a run ID, binding digest and pending/claimed/done counts. To start
a new capture generation after finishing the old run, add `--new-run` before
`init`. The previous state is archived. Retain its original evidence if you
need to verify historical work.

## Claim the next bounded batch

```bash
set -euo pipefail
python3 "${CLAUDE_PLUGIN_ROOT:?Set the installed plugin root}/skills/map-topology/lib/cloud-worklist.py" \
  --config "${SCOUTFLO_CONFIG:?Set the selected config}" \
  --target "${SCOUTFLO_CLOUD_TARGET:?Set the selected cloud target}" \
  --catalog "${SCOUTFLO_CLOUD_SERVICE_CATALOG:?Set the selected service catalog}" \
  --root "${SCOUTFLO_AUDIT_DIR:?Set the selected target audit directory}" claim "${SCOUTFLO_CLOUD_BATCH_SIZE:-10}"
```

The default ten services is a tune-to-estate example (allowed range 1–100).
Expected: the exact claimed services, their lanes, run ID and binding digest.
If interrupted, the next claim returns the outstanding batch, not a new one.
Each state transition holds an OS lock; competing updates fail without
changing progress, and process exit releases the lock automatically.

## Record the exact completed assessment

Run the existing per-service cookbook reads for the claimed services only.
Save one private receipt with exactly those services and every declared lane.
Use a distinct receipt filename for each batch and retain its evidence;
overwriting a completed batch's receipt invalidates its completion proof.
Example receipt shape:

```json
{
  "schema": "scoutflo-cloud-topology-assessment/v1",
  "run_id": "copy-from-claim",
  "binding_sha256": "copy-from-claim",
  "services": [
    {"id": "checkout", "checks": [
      {"lane": "declared", "result": "complete", "reason": null,
       "evidence": [{"ref": "captures/checkout-declared.json", "sha256": "actual-sha256", "observed_at": "2026-01-15T10:01:00Z"}]},
      {"lane": "permitted", "result": "blocked", "reason": "access_denied", "evidence": []},
      {"lane": "reachable", "result": "blocked", "reason": "unsupported", "evidence": []}
    ]}
  ]
}
```

Results are `complete`, `partial`, `blocked` or `not-in-scope`. A complete
lane requires retained evidence matching its digest and audit generation.
A pre-bound discovery capture retains its exact original timestamp and hash;
new assessment evidence must be collected at or after catalog completion.
Other results require one reason code: `access_denied`, `read_failed`,
`unsupported`, `not_configured`, `insufficient_evidence` or `not_needed`.
Explain the actual gap and its next safe action in the map, without copying
raw provider errors or credentials into this receipt. A blocked lane is a
completed assessment of a limitation, not a successful collection.

```bash
set -euo pipefail
python3 "${CLAUDE_PLUGIN_ROOT:?Set the installed plugin root}/skills/map-topology/lib/cloud-worklist.py" \
  --config "${SCOUTFLO_CONFIG:?Set the selected config}" \
  --target "${SCOUTFLO_CLOUD_TARGET:?Set the selected cloud target}" \
  --catalog "${SCOUTFLO_CLOUD_SERVICE_CATALOG:?Set the selected service catalog}" \
  --root "${SCOUTFLO_AUDIT_DIR:?Set the selected target audit directory}" done \
  "${SCOUTFLO_CLOUD_ASSESSMENT_RECEIPT:?Set the exact completed batch receipt}"
```

An incomplete receipt, missing lane, unrelated service, changed capture or
wrong generation fails and leaves the batch claimed. Fix the assessment and
record that same batch before proceeding. Repeat claim/read/receipt until
no pending services remain. `status` with the same arguments prints counts.

## Finish gate

```bash
set -euo pipefail
python3 "${CLAUDE_PLUGIN_ROOT:?Set the installed plugin root}/skills/map-topology/lib/cloud-worklist.py" \
  --config "${SCOUTFLO_CONFIG:?Set the selected config}" \
  --target "${SCOUTFLO_CLOUD_TARGET:?Set the selected cloud target}" \
  --catalog "${SCOUTFLO_CLOUD_SERVICE_CATALOG:?Set the selected service catalog}" \
  --root "${SCOUTFLO_AUDIT_DIR:?Set the selected target audit directory}" finish
```

Expected: exit 0 and `assessment_complete: true` only when every selected
service has an exact receipt and all retained evidence still matches. The
output separately states `collection_completeness_proven: false`; this gate
certifies completed assessment work, including recorded limitations. It
does not authenticate source completeness. Publish the selected map only
after this gate and the ordinary map checks pass, with every blocked/partial
lane and source coverage limit visible. Never label a subset or blocked
collection as a complete estate.
