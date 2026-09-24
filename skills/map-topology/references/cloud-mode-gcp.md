# Cloud Mode — GCP resources and service→resource edges

Command recipes for map-topology's **Cloud Mode** on Google Cloud: Cloud Run /
Cloud Functions as the service side (GKE stays in K8s Mode); Cloud SQL,
Memorystore, Pub/Sub, and Cloud Storage as the resource side; the Cloud Run
spec, service-account IAM bindings, and private-network containment as the
connecting threads.

**Live-verified (2026-09-21) on a real project**: identity gate, the catalog
(Cloud SQL with connectionName, Pub/Sub, GCS), the Cloud Run spec read, SA
resolution, the asset-inventory IAM search (returned real per-secret
`secretAccessor` bindings — the CONFIGURED_BY row worked verbatim), and the
peering + audit-log skip paths. Memorystore and Cloud Functions rows ran
against an estate that has none — their first live rows are still owed.

**Shared rules** (identical across clouds, defined once in
[cloud-mode-aws.md](cloud-mode-aws.md)): evidence classes, the composition
and confidence table, review tiers, and the redaction discipline. Everything
below is read-only; no lane requests or reads a secret value (Secret Manager
references join by NAME only).

## Identity and access gate

The `gcp` block names the `project` (and optionally `credentials_env` for a
service-account key file path — presence checked, contents never printed;
without it, the active gcloud login is the identity, exactly as `audit-gcp`
works). Pass `--project` explicitly on every call:

```bash
set -eu
GCP_PROJECT="your-project-id"        # from toolkit.yaml gcp.project (resolved in Phase 0)
gcloud auth list --filter=status:ACTIVE --format="value(account)" | head -n1 | grep -q . \
  || { echo "no active gcloud identity — run gcloud auth login / set credentials_env"; exit 1; }
gcloud projects describe "$GCP_PROJECT" --format="value(projectId)" >/dev/null \
  || { echo "cannot read project ${GCP_PROJECT} — fix the gcp block"; exit 1; }
echo "gcp project: ${GCP_PROJECT}  identity: $(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -n1)"
```

## Resource endpoint catalog

`kind  id  endpoint_host  endpoint_port  engine  logical_names`:

```bash
set -eu
GCP_PROJECT="your-project-id"
CAT="${TMPDIR:-/tmp}/cloudmode-gcp-catalog.tsv"; : > "$CAT"
# Cloud SQL: connectionName is ALSO a join key (the Cloud Run annotation names it verbatim)
gcloud sql instances list --project "$GCP_PROJECT" --format=json 2>/dev/null \
| jq -r '.[] | . as $i
  | (.ipAddresses // [])[]? 
  | ["database", $i.name, .ipAddress, "5432", ($i.databaseVersion // "-" | ascii_downcase), ($i.connectionName // "-")] | @tsv' >> "$CAT" || true
# Memorystore Redis: region-scoped list. Try the wildcard first; a gcloud release
# without it falls back to the configured region(s) — say which path ran.
MSB=$(gcloud redis instances list --project "$GCP_PROJECT" --region=- --format=json 2>/dev/null) || MSB=""
[ -n "$MSB" ] && printf '%s' "$MSB" \
| jq -r '.[] | ["cache", (.name|split("/")|last), .host, ((.port // 6379)|tostring), "redis", "-"] | @tsv' >> "$CAT" \
  || echo "memorystore: region-wildcard unavailable — re-run this line per configured gcp.region (verify live)"
# Pub/Sub topics + subscriptions (logical names ARE the identity; no host)
gcloud pubsub topics list --project "$GCP_PROJECT" --format=json 2>/dev/null \
| jq -r '.[] | ["message_queue", (.name|split("/")|last), "pubsub.googleapis.com", "443", "pubsub", (.name|split("/")|last)] | @tsv' >> "$CAT" || true
# Cloud Storage buckets
gcloud storage buckets list --project "$GCP_PROJECT" --format=json 2>/dev/null \
| jq -r '.[] | ["object_storage", (.name // .id), ((.name // .id) + ".storage.googleapis.com"), "443", "gcs", (.name // .id)] | @tsv' >> "$CAT" || true
sort -u "$CAT" -o "$CAT"; echo "catalog rows: $(wc -l < "$CAT" | tr -d ' ')"
```

The Cloud SQL port default above is engine-dependent (5432/3306/1433) — set
it from `databaseVersion` when composing real rows.

## Declared configuration

The Cloud Run spec is GCP's precision thread — the Cloud SQL annotation
carries the exact `PROJECT:REGION:INSTANCE` that the catalog's
`connectionName` matches verbatim:

```bash
set -eu
GCP_PROJECT="your-project-id"; GCP_REGION="your-region"
gcloud run services list --project "$GCP_PROJECT" --region "$GCP_REGION" --format=json 2>/dev/null \
| jq -r '.[] | .metadata.name as $svc
  | (.spec.template.metadata.annotations["run.googleapis.com/cloudsql-instances"] // "")
  | select(. != "") | split(",")[] 
  | [$svc, "cloudsql", .] | @tsv' || echo "cloud run: none in ${GCP_REGION} — skipping"
# Env extraction (same shared redaction discipline: secret-named keys skipped, secretKeyRef
# recorded as a reference by NAME, userinfo stripped, extractions to the temp join file)
gcloud run services list --project "$GCP_PROJECT" --region "$GCP_REGION" --format=json 2>/dev/null \
| jq -r '.[] | .metadata.name as $svc
  | (.spec.template.spec.containers[]? .env // [])[]
  | select(.valueFrom == null)
  | select(.name | test("(?i)password|passwd|secret|token|api_?key|private|credential") | not)
  | .name as $k | (.value // "") | gsub("://[^@/]*@"; "://")
  | capture("(?<h>[A-Za-z0-9][A-Za-z0-9.-]+\\.[A-Za-z]{2,})(:(?<p>[0-9]{2,5}))?"; "g")
  | [$svc, $k, .h, (.p // "-")] | @tsv' 2>/dev/null | sort -u > "${TMPDIR:-/tmp}/cloudmode-gcp-extract.tsv" || true
[ -f "${TMPDIR:-/tmp}/cloudmode-gcp-extract.tsv" ] && echo "extraction rows: $(wc -l < "${TMPDIR:-/tmp}/cloudmode-gcp-extract.tsv" | tr -d ' ')"
# secretKeyRef entries -> CONFIGURED_BY + name-join hints (never resolved)
# Pub/Sub wiring from the resource side: push subscriptions name their consumer URL
gcloud pubsub subscriptions list --project "$GCP_PROJECT" --format=json 2>/dev/null \
| jq -r '.[] | [(.name|split("/")|last), (.topic|split("/")|last), (.pushConfig.pushEndpoint // "pull")] | @tsv' || true
```

Cloud Functions (`gcloud functions list --format=json` → env, event
triggers) follow the same pattern; the trigger is the ESM-equivalent
(`SUBSCRIBES_TO` the trigger topic/bucket, near-zero noise).

## Permitted lane: service-account IAM bindings

Per distinct runtime service account (Cloud Run: `spec.template.spec.serviceAccountName`):

```bash
set -eu
GCP_PROJECT="your-project-id"; SA="runtime-sa@<project-id>.iam.gserviceaccount.com"   # the full SA address from the Cloud Run spec
# Preferred: one Asset-Inventory search per SA (needs cloudasset API enabled; skip clean)
AIB=$(gcloud asset search-all-iam-policies --scope="projects/${GCP_PROJECT}" \
  --query="policy:${SA}" --format=json 2>/dev/null) || AIB=""
[ -n "$AIB" ] && printf '%s' "$AIB" | jq -r '.[] | .resource as $r | .policy.bindings[]? | select(.members[]? | contains("'"$SA"'")) | [$r, .role] | @tsv' \
  || echo "asset-inventory search unavailable — fall back to bounded per-resource get-iam-policy on catalog rows"
```

Role-to-relation mapping mirrors the shared table: `roles/cloudsql.client` →
STORES_DATA_IN corroboration; `roles/pubsub.publisher`/`subscriber` →
PUBLISHES_TO/SUBSCRIBES_TO; `roles/storage.objectViewer`/`objectAdmin` →
USES; `roles/secretmanager.secretAccessor` → CONFIGURED_BY. **Default-SA
demotion (hard rule):** bindings on the default compute service account
(the `<project-number>-compute@developer.…` default address) are shared by
everything that never set a dedicated SA — demote to one intent-class note,
never per-resource edges, same as the AWS wildcard rule.

## Reachable lane: private-network containment

Private-IP Cloud SQL and Memorystore have NO declaration — this is the only
lane that ties them down. A Cloud Run service with a VPC connector (or a GCE
service in the VPC) can reach a private-IP instance whose address sits in the
peered private-services range:

```bash
set -eu
GCP_PROJECT="your-project-id"
gcloud compute networks list --project "$GCP_PROJECT" --format="value(name)" | while IFS= read -r NET; do
  gcloud services vpc-peerings list --network "$NET" --project "$GCP_PROJECT" --format=json 2>/dev/null \
  | jq -r --arg n "$NET" '.[] | [$n, .peering, ((.reservedPeeringRanges // []) | join(","))] | @tsv' || true
done
```

Corroboration/refutation only, per the shared composition rules.

**Public-IP allowlist openings** (the rows the cross-cloud pass consumes): a
public-IP Cloud SQL lists `authorizedNetworks`, and a firewall rule lists
`sourceRanges`. Each is recorded as an *unattributed* opening — host `/32`
only; a wide range is a finding (`0.0.0.0/0` = open to the internet), never a
per-owner edge. When another cloud is also configured, those host `/32`
openings feed the cross-cloud attribution pass (shared rules, cookbook:
"Cross-cloud IP attribution" in the AWS cookbook — live-proven: GCP VM IPs on
one side, DO managed-DB allowlists on the other):

```bash
set -eu
GCP_PROJECT="your-project-id"
# Cloud SQL public-IP authorized networks -> ip<TAB>instance (unattributed openings)
gcloud sql instances list --project "$GCP_PROJECT" --format=json 2>/dev/null \
| jq -r '.[] | .name as $i | ((.settings.ipConfiguration.authorizedNetworks // [])[]
    | [.value, $i] | @tsv)' || true
# Firewall source ranges guarding db-tier tags -> range<TAB>target-tag
gcloud compute firewall-rules list --project "$GCP_PROJECT" --format=json 2>/dev/null \
| jq -r '.[] | select(.direction=="INGRESS") | .name as $r
    | ((.sourceRanges // [])[]) as $sr | ((.targetTags // ["*"])[])
    | [$sr, .] | @tsv' || true
```

## Observed lane: VPC flow logs

The strongest no-secrets observed source on GCP: connection metadata only
(who talked to whom, on which port), no payload, no configuration access
needed — only log read. Live-verified on a real project (real flow records
returned, including genuine service→datastore connections). Availability
check first, then a bounded read:

```bash
set -eu
GCP_PROJECT="your-project-id"
# Are flow logs enabled anywhere? (per-subnet setting)
N=$(gcloud compute networks subnets list --project "$GCP_PROJECT" --format="value(enableFlowLogs)" 2>/dev/null | grep -c True || true)
# ⚠️ Two config surfaces exist (doc-verified): the classic per-subnet setting AND
# Network Management API configs — the NM-API kind does NOT set enableFlowLogs on
# subnets, so a zero count here does not prove flow logs are off. Probe both.
NM=$(gcloud network-management vpc-flow-logs-configs list --location=global --project "$GCP_PROJECT" --filter="state:ENABLED" --format="value(name)" 2>/dev/null | grep -c . || true)
[ "$(( ${N:-0} + ${NM:-0} ))" -gt 0 ] || { echo "vpc flow logs: not enabled (subnet setting and NM-API configs both empty) — skipping (the unlock: enable flow logs on the subnets that matter)"; exit 0; }
echo "flow-log config: subnet-enabled=${N} nm-api-configs=${NM}"
# Bounded read. ⚠️ Use --freshness for the window — an in-query timestamp
# string fails SILENTLY on gcloud logging read (live-caught).
FB=$(gcloud logging read 'logName:"compute.googleapis.com%2Fvpc_flows"' \
  --project "$GCP_PROJECT" --limit 200 --freshness=2h --format=json 2>/dev/null) || FB=""
# NM-API-configured flow logs write to a different log name — read it too when the classic one is empty
[ "$FB" = "[]" ] || [ -z "$FB" ] && { FB=$(gcloud logging read 'logName:"networkmanagement.googleapis.com%2Fvpc_flows"' \
  --project "$GCP_PROJECT" --limit 200 --freshness=2h --format=json 2>/dev/null) || FB=""; } || true
[ -n "$FB" ] && printf '%s' "$FB" | jq -r '.[] | .jsonPayload
  | [(.connection.src_ip // "-"), (.connection.dest_ip // "-"),
     ((.connection.dest_port // 0)|tostring),
     (.src_instance.vm_name // "-"), (.dest_instance.vm_name // "-")] | @tsv' \
  | sort | uniq -c | sort -rn | head -40 \
  || echo "vpc flow logs: enabled but no readable entries — check log-read access"
```

Join rules: keep rows whose `dest_port` matches an engine port from the
endpoint catalog (5432/3306/6379/9092/27017/6333…), then resolve identities —
`src_instance`/`dest_instance` names when present, otherwise join the IPs
against the estate's own address catalog (instance/service/resource private
IPs). ⚠️ The instance annotations are often ABSENT (live-confirmed: load
balancer and health-check flows carry none) — the IP-catalog join is the
reliable path, not a fallback. Each matched pair is an `observed` edge
(`mechanism: gcp.vpc-flow-logs`) with the standard TTL semantics; unmatched
public IPs are noted, never guessed into identities.

## Observed lane: Data Access audit logs

Default-OFF on GCP and needs `roles/logging.privateLogViewer` — probe once,
skip clean:

```bash
set -eu
GCP_PROJECT="your-project-id"
DAB=$(gcloud logging read 'logName:"cloudaudit.googleapis.com%2Fdata_access" AND timestamp>="-24h"' \
  --project "$GCP_PROJECT" --limit 20 --format=json 2>/dev/null) || DAB=""
[ -n "$DAB" ] && printf '%s' "$DAB" | jq -c '.[] | {sa: .protoPayload.authenticationInfo.principalEmail, res: .resource.type}' \
  || echo "data-access audit logs: off or not readable — skipping (observed lane)"
```

## Traps

- **CAI relationships are not a lane**: the Asset Inventory *relationship*
  export needs Security Command Center Premium AND excludes Cloud Run /
  Cloud SQL / Memorystore. `search-all-iam-policies` (used above) is the
  supported read.
- Memorystore listing is region-scoped; a `--region=-` wildcard is not
  guaranteed on every gcloud release — verify live, and fall back to
  iterating the configured region(s).
- GKE workloads stay in K8s Mode; drawing a second copy of a GKE service from
  the GCP side would duplicate identity. Cloud Mode on GCP covers what the
  cluster cannot see.
- The default compute SA demotion rule above is load-bearing: on estates that
  never set per-service SAs, the permitted lane honestly yields ONE note, not
  a fan-out.

## Bounded reads

| Lane | Cost | Bound |
| --- | --- | --- |
| Catalog | ~4 list calls | fixed per project (+1 per region for Memorystore fallback) |
| Cloud Run/Functions specs | 1 list call per region | config regions |
| IAM search | 1 call per distinct SA | dedupe SAs; skip-clean without cloudasset |
| Peering ranges | 1 call per network | network count (small) |
| Audit-log probe | 1 bounded read | skip-clean |
