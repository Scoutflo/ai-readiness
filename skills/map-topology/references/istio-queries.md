# Query cookbook: map-topology

Exact command blocks for every collection step in [SKILL.md](../SKILL.md). Every block is standalone: it declares the variables it uses and runs as pasted on macOS or Linux. All cluster operations are `get`/`list` only.

Shared variable conventions used by every block:

```bash
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
# Namespaces to skip. This is the vanilla-Kubernetes preset; on a managed
# cluster pick your provider's preset from "Namespace-exclude presets"
# below, then extend with operator or system namespaces you do not want
# in the map.
NS_EXCLUDE="^(kube-system|kube-public|kube-node-lease|istio-system)$"
# Working directory for intermediate TSVs; reuse one TMP across all blocks.
TMP="${TMP:-$(mktemp -d)}"
```

On the medium sizing path (chosen in SKILL.md Phase 1), replace the `TMP` declaration in each block with `TMP="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/map-topology/$(date -u +%F)"` (after `mkdir -p` on that path) so intermediates survive a shell restart and a failed step can be redone alone. A medium-path run stays inside one calendar day by definition (one run, one sitting), so date-keying is safe there.

On the large sizing path, replace the `TMP` declaration with `TMP="${RUN_DIR}"`, where `RUN_DIR` is the run-ID-keyed directory from [SKILL.md's Run-ID keying](../SKILL.md#run-id-keying): `./scoutflo-audits/map-topology/runs/<RUN_ID>/`. A large-path run can cross midnight UTC mid-batch, so it is keyed by `RUN_ID` (the run's first-seen timestamp), never by calendar date; see "Worklist build and resume" and "Worklist lock" below for the exact commands.

## Namespace-exclude presets

The vanilla default above only knows vanilla Kubernetes. On a managed cluster it leaves the provider's own system namespaces in scope, and each one becomes a fake service row, a pre-seeded watchpoints row, and noise in every audit that loads the map — confirmed on a real GKE cluster, where the default pulled in `gke-managed-cim`, `gke-managed-system`, `gke-managed-networking-dra-driver`, `gke-managed-volumepopulator`, `gmp-system`, and `gmp-public`.

Pick the preset for your provider, paste it as the `NS_EXCLUDE` value in every block you run, then extend it with your own operator and system namespaces. Use the same value in every block of one run — the estate-sizing counts in SKILL.md Phase 1 and every collection filter must agree on scope, and the value is printed in the map header (`Namespaces excluded`) so omissions stay visible. All presets are examples to tune, not exhaustive lists: providers add managed namespaces over time, so check the Phase 1 namespace scan output for anything a preset missed.

```bash
# Vanilla Kubernetes (the default used in every block in this cookbook)
NS_EXCLUDE="^(kube-system|kube-public|kube-node-lease|istio-system)$"

# GKE: adds GKE-managed system namespaces, Google Managed Prometheus
# (gmp-*; gke-gmp-system on some versions), Config Sync, and Config
# Connector. The gke-managed-* and gmp-* names are confirmed on a real
# GKE cluster; treat the rest as examples to tune.
NS_EXCLUDE="^(kube-system|kube-public|kube-node-lease|istio-system|gke-managed-.*|gke-gmp-system|gmp-system|gmp-public|config-management-system|cnrm-system)$"

# EKS: adds the Fargate log-router (aws-observability), Container
# Insights / CloudWatch agent (amazon-cloudwatch), and GuardDuty runtime
# agent (amazon-guardduty) namespaces. Examples to tune; confirm against
# your own namespace scan.
NS_EXCLUDE="^(kube-.*|istio-system|aws-observability|amazon-cloudwatch|amazon-guardduty)$"

# AKS: adds the Azure Policy add-on (gatekeeper-system), Azure Arc agents
# (azure-arc), and the managed Istio add-on (aks-istio-system/-ingress/
# -egress) namespaces. Examples to tune; confirm against your own
# namespace scan.
NS_EXCLUDE="^(kube-.*|istio-system|gatekeeper-system|azure-arc|aks-istio-.*)$"
```

## Namespace scan

Namespaces in scope with their Istio labels. Works on both paths; on the fallback path the label columns just read `-`.

```bash
set -eu
KUBE_CONTEXT="your-kube-context"
NS_EXCLUDE="^(kube-system|kube-public|kube-node-lease|istio-system)$"
TMP="${TMP:-$(mktemp -d)}"

kubectl --context "${KUBE_CONTEXT}" get ns -o json \
| jq -r --arg ex "${NS_EXCLUDE}" '
    .items[]
    | select(.metadata.name | test($ex) | not)
    | [ .metadata.name,
        (.metadata.labels["istio-injection"] // "-"),
        (.metadata.labels["istio.io/rev"] // "-"),
        (.metadata.labels["istio.io/dataplane-mode"] // "-") ]
    | @tsv' \
| tee "${TMP}/namespaces.tsv"
```

Expected: one line per namespace, `name  injection  rev  dataplane-mode`. `enabled` in column 2 or a revision in column 3 means sidecar injection; `ambient` in column 4 means no sidecars by design.

## Sidecar coverage

Primary (no `istioctl` needed): pods carrying an `istio-proxy` container.
Check BOTH `.spec.containers` and `.spec.initContainers`: with native sidecars
(`ENABLE_NATIVE_SIDECARS`, the Kubernetes native-sidecar init-container mode that
is increasingly the default on modern clusters) `istio-proxy` is injected as an
init container with `restartPolicy: Always`, not a regular container — scanning
only `.spec.containers` would read a fully-meshed native-sidecar cluster as 100%
unadopted and flag every workload as a coverage gap.

```bash
set -eu
KUBE_CONTEXT="your-kube-context"
NS_EXCLUDE="^(kube-system|kube-public|kube-node-lease|istio-system)$"
TMP="${TMP:-$(mktemp -d)}"

kubectl --context "${KUBE_CONTEXT}" get pods -A -o json \
| jq -r --arg ex "${NS_EXCLUDE}" '
    .items[]
    | select(.metadata.namespace | test($ex) | not)
    | select(any(((.spec.containers // []) + (.spec.initContainers // []))[]; .name == "istio-proxy"))
    | [ .metadata.namespace,
        (.metadata.labels.app // .metadata.labels["app.kubernetes.io/name"] // .metadata.name),
        (.metadata.labels.version // "-") ]
    | @tsv' \
| sort -u | tee "${TMP}/sidecars.tsv"
```

Expected: one line per meshed app, `namespace  app  version`. Empty output in an injection-enabled namespace means pods predate injection or opted out; note it in the map.

Sync state, when `istioctl` is installed:

```bash
set -eu
KUBE_CONTEXT="your-kube-context"
istioctl --context "${KUBE_CONTEXT}" proxy-status
```

Expected: one row per proxy with `SYNCED` in the CDS/LDS/EDS/RDS columns. `STALE` or `NOT SENT` means that proxy is not receiving current routing config; record it as a note on the affected service. A connection error here with healthy CRDs usually means `istioctl` cannot reach istiod, not that the mesh is empty.

## Workloads and versions

Deployments, StatefulSets, and DaemonSets with a resolved version. Version precedence: `version` pod label, then `app.kubernetes.io/version`, then a non-`latest` image tag, else `unknown`.

```bash
set -eu
KUBE_CONTEXT="your-kube-context"
NS_EXCLUDE="^(kube-system|kube-public|kube-node-lease|istio-system)$"
TMP="${TMP:-$(mktemp -d)}"

for kind in deployment statefulset daemonset; do
  kubectl --context "${KUBE_CONTEXT}" get "${kind}" -A -o json \
  | jq -r --arg kind "${kind}" --arg ex "${NS_EXCLUDE}" '
      .items[]
      | select(.metadata.namespace | test($ex) | not)
      | (.spec.template.metadata.labels // {}) as $lbl
      | (.spec.template.spec.containers[0].image // "" | split("/") | last | split("@")[0]) as $img
      | [ .metadata.namespace,
          ($kind + "/" + .metadata.name),
          ($lbl["version"] // $lbl["app.kubernetes.io/version"]
            // ($img | split(":") | if length > 1 and last != "latest" then last else "unknown" end)) ]
      | @tsv'
done | sort | tee "${TMP}/workloads.tsv"
```

Expected: one line per workload, `namespace  kind/name  version`. The `split("/") | last` step strips the registry first, so a registry port (`registry.example.com:5000/app`) is never mistaken for a tag.

## Source-repo evidence (Tier 3: image-path candidate)

For each workload, capture the full image ref, its digest, and a **heuristic** `candidate_repo` parsed from the registry path — the free, no-new-access tier of the evidence model in [scoutflo-export.md](scoutflo-export.md#source_repo_evidence--tiered-typed-servicerepo-evidence-optional-additive). This only *captures a candidate*; `map-repos` verifies it live against GitHub before ever proposing it. It never becomes a mapping here.

```bash
set -eu
KUBE_CONTEXT="your-kube-context"
NS_EXCLUDE="^(kube-system|kube-public|kube-node-lease|istio-system)$"
TMP="${TMP:-$(mktemp -d)}"

for kind in deployment statefulset daemonset; do
  kubectl --context "${KUBE_CONTEXT}" get "${kind}" -A -o json \
  | jq -c --arg kind "${kind}" --arg ex "${NS_EXCLUDE}" '
      # candidate_repo = last two path segments after the registry host, tag/digest stripped.
      # Only strip a host when there is >1 segment: a bare "postgres:18.4" is name:tag,
      # not host/name — its colon is a tag, not a registry port.
      def candidate($image):
        ($image | sub("@sha256:[0-9a-f]+$"; "")) as $nd
        | ($nd | split("/")) as $p
        | (if (($p | length) > 1) and (($p[0] | test("[.:]")) or ($p[0] == "localhost"))
           then $p[1:] else $p end) as $path
        | (if ($path | length) == 0 then null
           else ($path | .[-1] |= sub(":[^:/]+$"; ""))
                | (if (length) >= 2 then (.[-2:] | join("/")) else null end)
           end);
      .items[]
      | select(.metadata.namespace | test($ex) | not)
      | (.spec.template.spec.containers[0].image // "") as $img
      | (if ($img | test("@sha256:")) then ($img | capture("@(?<d>sha256:[0-9a-f]+)$").d) else null end) as $digest
      | { workload: ($kind + "/" + .metadata.name),
          namespace: .metadata.namespace,
          image: (if $img == "" then null else $img end),
          image_digest: $digest,
          source_repo_evidence:
            ( if ($img != "" and candidate($img) != null)
              then [ { candidate_repo: candidate($img),
                       evidence_source: "image_registry_path",
                       confidence: "heuristic",
                       subpath: null,
                       raw: $img } ]
              else [] end ) }'
done | jq -s '.' | tee "${TMP}/source-repo-evidence.json"
```

Expected: a JSON array, one object per workload, each with `image`, `image_digest` (null when the ref carries no digest — enrich from `kubectl get pods -o jsonpath='{..imageID}'` only if you need it), and a `source_repo_evidence` array holding at most one `image_registry_path` candidate (empty when the image is a bare single-segment name like `postgres:18.4`, which yields no `owner/name`). `subpath` is always `null` at this tier — a registry path is repo-level, never per-service. These objects become the `image`/`image_digest`/`source_repo_evidence` attributes on each workload resource in `topology-export.json`.

## Source-repo evidence (Tier 2: ArgoCD Applications)

Authoritative service→repo evidence, read from ArgoCD Application CRs with the same kubeconfig as every other block — no ArgoCD API, no new credential; needs only `get`/`list` on `applications.argoproj.io`. Read-only: this block never creates, syncs, patches, or refreshes an Application.

```bash
set -eu
KUBE_CONTEXT="your-kube-context"
TMP="${TMP:-$(mktemp -d)}"

# Distinguish "CRD absent" (a normal estate) from "cannot reach the cluster" (an error
# that must be reported, never mis-read as absence).
if ! API_OUT=$(kubectl --context "${KUBE_CONTEXT}" api-resources --api-group=argoproj.io 2>&1); then
  echo "ERROR: could not query api-resources (${API_OUT}); fix cluster access before concluding anything about ArgoCD" >&2
elif ! printf '%s\n' "${API_OUT}" | grep -q '^applications '; then
  echo "no ArgoCD Application CRD on this cluster — Tier 2 evidence not available (normal, skipping)"
else
  kubectl --context "${KUBE_CONTEXT}" get applications.argoproj.io -A -o json \
  | jq -c '
      # candidate_repo = owner/name from the repoURL (https or ssh form), .git suffix stripped.
      def repo_label($u):
        ($u | sub("\\.git$"; "")
            | sub("^git@[^:]+:"; "")
            | sub("^[a-z]+://[^/]+/"; "")) as $p
        | (if ($p | split("/") | length) >= 2 then ($p | split("/") | .[-2:] | join("/")) else null end);
      .items[]
      | (.spec.source // (.spec.sources // [] | .[0]) // {}) as $src
      | select(($src.repoURL // "") != "")
      # A Helm-chart source (spec.source.chart set) deploys a packaged chart from a chart
      # registry — its repoURL is NOT a source-code repository. Emitting it as evidence
      # plants a false "authoritative" candidate; skip it with a visible note instead.
      | if (($src.chart // "") != "") then
          { application: .metadata.name, skipped: "helm-chart source (\($src.chart)) — a chart registry is not a source repo; no evidence emitted" }
        else
      # Multi-source apps report per-source SHAs in status.sync.revisions (parallel to
      # spec.sources); single-source apps use status.sync.revision.
      ((.status.sync.revisions // [] | .[0]) // .status.sync.revision // "") as $sync
      | { application: .metadata.name,
          app_namespace: .metadata.namespace,
          dest_namespace: (.spec.destination.namespace // null),
          managed_workloads: [ (.status.resources // [])[]
              | select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet")
              | { namespace: (.namespace // null), workload_name: .name, workload_type: (.kind | ascii_downcase) } ],
          source_repo_evidence: [ {
            candidate_repo: (repo_label($src.repoURL)),
            evidence_source: "argocd",
            confidence: "authoritative",
            subpath: ($src.path // null),
            deployed_revision: (if ($sync | test("^[0-9a-f]{40}$")) then $sync else null end),
            branch_ref: (if (($src.targetRevision // "") != "") and (($src.targetRevision // "") | test("^[0-9a-f]{40}$") | not) then $src.targetRevision else null end),
            raw: ($src.repoURL + " @ " + ($src.targetRevision // "HEAD")) } ] }
        end' \
  | tee "${TMP}/argocd-evidence.json"
fi
```

Expected: one JSON object per Application. A Helm-chart source prints a `skipped` note and emits **no** evidence (a chart registry is not a source repo). Otherwise: `candidate_repo` as `owner/name`, `subpath` from `spec.source.path`, `branch_ref` from `targetRevision` when it is a ref, `deployed_revision` **only when the synced revision is a real 40-hex SHA** (multi-source apps read `status.sync.revisions[0]`; a never-synced Application yields `null`, never a branch name masquerading as a commit), and **`managed_workloads`** — the workloads this Application actually manages, from `status.resources`.

**The join (how evidence reaches workloads):** `managed_workloads` is the mechanical join — in Phase 3, attach the Application's `source_repo_evidence` entry to each export workload whose `namespace` + `workload_name` + `workload_type` match a `managed_workloads` row. A never-synced Application has no `status.resources` and therefore joins to nothing: record it in the map as an unattached ArgoCD note ("Application X declares repo Y for namespace Z but has never synced") and let `map-repos` present it to the user — never guess a workload for it, and never attach by `dest_namespace` alone (a namespace is not a workload).


## Service-to-workload join

Joins Services to workloads whose pod-template labels satisfy the Service selector, within the same namespace. Used on both paths.

```bash
set -eu
KUBE_CONTEXT="your-kube-context"
NS_EXCLUDE="^(kube-system|kube-public|kube-node-lease|istio-system)$"
TMP="${TMP:-$(mktemp -d)}"

kubectl --context "${KUBE_CONTEXT}" get svc -A -o json > "${TMP}/svc.json"
for kind in deployment statefulset daemonset; do
  kubectl --context "${KUBE_CONTEXT}" get "${kind}" -A -o json \
  | jq --arg kind "${kind}" '.items[] | .kind = $kind'
done | jq -s '.' > "${TMP}/workloads.json"

jq -r -n --arg ex "${NS_EXCLUDE}" \
  --slurpfile s "${TMP}/svc.json" --slurpfile w "${TMP}/workloads.json" '
  $s[0].items[] as $svc
  | select($svc.metadata.namespace | test($ex) | not)
  | select(($svc.spec.type // "ClusterIP") != "ExternalName")
  | ($svc.spec.selector // {}) as $sel
  | select(($sel | length) > 0)
  | $w[0][] as $wl
  | select($wl.metadata.namespace == $svc.metadata.namespace)
  | ($wl.spec.template.metadata.labels // {}) as $lbl
  | select($sel | to_entries | all($lbl[.key] == .value))
  | [ $svc.metadata.namespace, $svc.metadata.name,
      ($wl.kind + "/" + $wl.metadata.name),
      (($svc.spec.ports // []) | map("\(.port)/\(.protocol // "TCP")") | join(",")) ]
  | @tsv' \
| sort -u | tee "${TMP}/svc-workloads.tsv"
```

Expected: one line per Service/workload pair, `namespace  service  kind/name  ports`. A Service absent from this output but present in `svc.json` either has no selector (headless indirection, often fronting an operator) or matches nothing; the Endpoint backing check below distinguishes the two.

`ExternalName` services are external dependencies, not workloads:

```bash
set -eu
KUBE_CONTEXT="your-kube-context"
NS_EXCLUDE="^(kube-system|kube-public|kube-node-lease|istio-system)$"

kubectl --context "${KUBE_CONTEXT}" get svc -A -o json \
| jq -r --arg ex "${NS_EXCLUDE}" '
    .items[]
    | select(.metadata.namespace | test($ex) | not)
    | select(.spec.type == "ExternalName")
    | [ .metadata.namespace, .metadata.name, .spec.externalName ] | @tsv'
```

Expected: usually empty. Any line becomes a `-> external` row in the traffic map.

## Endpoint backing check

Ready endpoint addresses per Service. Zero addresses for a selector-bearing Service means backendless: list it, do not guess.

```bash
set -eu
KUBE_CONTEXT="your-kube-context"
NS_EXCLUDE="^(kube-system|kube-public|kube-node-lease|istio-system)$"
TMP="${TMP:-$(mktemp -d)}"

kubectl --context "${KUBE_CONTEXT}" get endpoints -A -o json \
| jq -r --arg ex "${NS_EXCLUDE}" '
    .items[]
    | select(.metadata.namespace | test($ex) | not)
    | [ .metadata.namespace, .metadata.name,
        ([.subsets[]?.addresses[]?] | length | tostring) ]
    | @tsv' \
| sort | tee "${TMP}/endpoints.tsv"
```

Expected: `namespace  service  ready-address-count`. Recent clusters print a deprecation warning for Endpoints on stderr; the data is still served. If your cluster has dropped the Endpoints API, use `kubectl get endpointslices -A -o json` and sum `.endpoints[].conditions.ready == true` per the `kubernetes.io/service-name` label instead.

## VirtualService routes

One row per route destination. Checks `http`, `tcp`, and `tls` route blocks.

```bash
set -eu
KUBE_CONTEXT="your-kube-context"
NS_EXCLUDE="^(kube-system|kube-public|kube-node-lease|istio-system)$"
TMP="${TMP:-$(mktemp -d)}"

kubectl --context "${KUBE_CONTEXT}" get virtualservices -A -o json \
| jq -r --arg ex "${NS_EXCLUDE}" '
    .items[]
    | select(.metadata.namespace | test($ex) | not)
    | .metadata.namespace as $ns | .metadata.name as $vs
    | ((.spec.hosts // []) | join(",")) as $hosts
    | ((.spec.gateways // ["mesh"]) | join(",")) as $gw
    | ((.spec.http // []) + (.spec.tcp // []) + (.spec.tls // []))[]
    | .route[]?
    | [ $ns, $vs, $hosts, $gw,
        .destination.host, (.destination.subset // "-"),
        ((.weight // 100) | tostring) ]
    | @tsv' \
| sort -u | tee "${TMP}/vs-routes.tsv"
```

Expected: `namespace  virtualservice  hosts  gateways  dest-host  subset  weight`. `gateways` of `mesh` means in-mesh service-to-service routing; anything else is an entry-point binding. Gateway references may be cross-namespace (`other-ns/gw-name`); resolve them against the Gateways table, not against the VirtualService's own namespace. Destination hosts may be short names (same namespace), fully qualified (`svc.ns.svc.cluster.local`), or external hosts declared by a ServiceEntry; normalize to the Service name when composing the map.

Limitation — VirtualService **delegation** is not followed. A parent VS that uses `.http[].delegate` (instead of `.route`) carries the hosts and gateways but no destinations, so it produces no row here; the delegated child VS carries the `.route` destinations but conventionally has empty `hosts`/`gateways`, so its destinations default to `mesh` and read as in-mesh rather than inheriting the parent's entry-point binding. If a cluster uses delegation, treat a `mesh`-classified route whose child VS has empty hosts as "gateway binding unresolved," and confirm the entry point against the parent VS by hand. Standard gateway + VirtualService setups (no `delegate`) are unaffected.

## DestinationRule subsets

Subsets are the version axis: they name the label sets traffic can be split across.

```bash
set -eu
KUBE_CONTEXT="your-kube-context"
NS_EXCLUDE="^(kube-system|kube-public|kube-node-lease|istio-system)$"
TMP="${TMP:-$(mktemp -d)}"

kubectl --context "${KUBE_CONTEXT}" get destinationrules -A -o json \
| jq -r --arg ex "${NS_EXCLUDE}" '
    .items[]
    | select(.metadata.namespace | test($ex) | not)
    | .metadata.namespace as $ns | .metadata.name as $dr | .spec.host as $host
    | (.spec.subsets // [])[]
    | [ $ns, $dr, $host, .name,
        ((.labels // {}) | to_entries | map("\(.key)=\(.value)") | join(",")) ]
    | @tsv' \
| sort -u | tee "${TMP}/dr-subsets.tsv"
```

Expected: `namespace  destinationrule  host  subset  labels`. A subset referenced by a VirtualService route but absent here (or whose labels match no running pods from the Sidecar coverage output) is a routing gap worth a note in the map.

## Istio Gateways

Always the full resource name; the short name `gateways` can resolve to the Kubernetes Gateway API kind instead.

```bash
set -eu
KUBE_CONTEXT="your-kube-context"
TMP="${TMP:-$(mktemp -d)}"

kubectl --context "${KUBE_CONTEXT}" get gateways.networking.istio.io -A -o json \
| jq -r '
    .items[]
    | .metadata.namespace as $ns | .metadata.name as $gw
    | (.spec.servers // [])[]
    | [ $ns, $gw,
        ((.port.number | tostring) + "/" + .port.protocol),
        ((.hosts // []) | join(",")) ]
    | @tsv' \
| sort | tee "${TMP}/gateways.tsv"
```

Expected: `namespace  gateway  port/protocol  hosts`. Join against `vs-routes.tsv` (gateway column matches `$ns/$gw` or bare `$gw`) to fill the "Routes to" column of the Entry points table. A gateway with no bound VirtualService accepts traffic that goes nowhere; note it.

## ServiceEntries

External dependencies the mesh knows about.

```bash
set -eu
KUBE_CONTEXT="your-kube-context"
NS_EXCLUDE="^(kube-system|kube-public|kube-node-lease|istio-system)$"
TMP="${TMP:-$(mktemp -d)}"

kubectl --context "${KUBE_CONTEXT}" get serviceentries -A -o json \
| jq -r --arg ex "${NS_EXCLUDE}" '
    .items[]
    | select(.metadata.namespace | test($ex) | not)
    | [ .metadata.namespace, .metadata.name,
        ((.spec.hosts // []) | join(",")),
        (.spec.location // "MESH_EXTERNAL"),
        (.spec.resolution // "-") ]
    | @tsv' \
| sort | tee "${TMP}/serviceentries.tsv"
```

Expected: `namespace  serviceentry  hosts  location  resolution`. `MESH_EXTERNAL` rows become `-> external` traffic-map rows.

## Ingress entry points

Used on both paths; clusters often run plain Ingress alongside a mesh.

```bash
set -eu
KUBE_CONTEXT="your-kube-context"
NS_EXCLUDE="^(kube-system|kube-public|kube-node-lease|istio-system)$"
TMP="${TMP:-$(mktemp -d)}"

kubectl --context "${KUBE_CONTEXT}" get ingress -A -o json \
| jq -r --arg ex "${NS_EXCLUDE}" '
    .items[]
    | select(.metadata.namespace | test($ex) | not)
    | .metadata.namespace as $ns | .metadata.name as $ing
    | (.spec.rules // [])[]
    | (.host // "*") as $host
    | (.http.paths // [])[]
    | [ $ns, $ing, $host, (.path // "/"),
        (.backend.service.name // "unknown"),
        ((.backend.service.port.number // .backend.service.port.name // "-") | tostring) ]
    | @tsv' \
| sort | tee "${TMP}/ingress.tsv"
```

Expected: `namespace  ingress  host  path  backend-service  port`. Each backend service becomes an `ingress -> service` traffic-map row and each distinct `namespace/ingress` an Entry points row.

## Worklist build and resume

Large path only (SKILL.md: "Large clusters: worklist, batches, and resume"). The worklist is the durable record of which namespaces are mapped; an interrupted run resumes from it instead of restarting. `RUN_DIR` is keyed by `RUN_ID`, the run's first-seen timestamp, never by calendar date, so a run that crosses UTC midnight keeps writing into the same directory. This block finds a resumable run first (a run directory whose worklist still has pending rows); only when none exists does it mint a new `RUN_ID`. `RUN_DIR` never carries a trailing slash; every path below joins it with `/`.

```bash
set -eu
KUBE_CONTEXT="your-kube-context"
NS_EXCLUDE="^(kube-system|kube-public|kube-node-lease|istio-system)$"
AUDIT_ROOT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/map-topology"

resumable=""
if [ -d "${AUDIT_ROOT}/runs" ]; then
  for d in "${AUDIT_ROOT}/runs"/*/; do
    [ -f "${d}worklist.tsv" ] || continue
    pending=$(awk -F'\t' '$2 == "pending"' "${d}worklist.tsv" | wc -l | tr -d ' ')
    [ "${pending}" -gt 0 ] || continue
    resumable="${d%/}"   # strip the glob's trailing slash so RUN_DIR stays slash-free
  done
fi

if [ -n "${resumable}" ]; then
  RUN_DIR="${resumable}"
  echo "resuming ${RUN_DIR}"
else
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"   # first-seen timestamp of this run; stable for its lifetime
  RUN_DIR="${AUDIT_ROOT}/runs/${RUN_ID}"
  mkdir -p "${RUN_DIR}/raw"
  kubectl --context "${KUBE_CONTEXT}" get ns -o json \
  | jq -r --arg ex "${NS_EXCLUDE}" '
      .items[] | select(.metadata.name | test($ex) | not)
      | [.metadata.name, "pending"] | @tsv' > "${RUN_DIR}/worklist.tsv"
  echo "worklist created: ${RUN_DIR}"
fi
awk -F'\t' '{c[$2]++} END {printf "done=%d pending=%d\n", c["done"]+0, c["pending"]+0}' "${RUN_DIR}/worklist.tsv"
```

Expected: `worklist created: <RUN_DIR>` then `done=0 pending=<n>` on a fresh run, or `resuming <RUN_DIR>` with a nonzero `done` count. Never delete or rebuild an existing worklist mid-run; that forgets progress.

## Worklist lock

Acquire this lock before claiming a batch, release it right after. It prevents two invocations against the same estate from double-claiming the same namespaces. A lock older than `LOCK_STALE_MINUTES` is treated as abandoned (the process that held it died, or the machine slept) and is safe to reclaim.

```bash
set -eu
RUN_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/map-topology/runs/20260717T140500Z"   # example; the resolved run directory
LOCK_STALE_MINUTES="30"   # example, tune to your batch size and expected run length
LOCK="${RUN_DIR}/worklist.lock"

now_epoch=$(date -u +%s)
if [ -f "${LOCK}" ]; then
  lock_pid=$(awk -F'\t' 'NR==1{print $1}' "${LOCK}")
  lock_epoch=$(awk -F'\t' 'NR==1{print $2}' "${LOCK}")
  age_minutes=$(( (now_epoch - lock_epoch) / 60 ))
  if [ "${age_minutes}" -lt "${LOCK_STALE_MINUTES}" ]; then
    echo "worklist locked by pid ${lock_pid}, age ${age_minutes}m; stop, do not claim a batch"
    exit 1
  fi
  echo "existing lock is ${age_minutes}m old (>= ${LOCK_STALE_MINUTES}m); treating as abandoned and reclaiming"
fi
printf '%s\t%s\n' "$$" "${now_epoch}" > "${LOCK}"
echo "lock acquired: pid=$$ at ${now_epoch}"
```

Expected: `lock acquired: pid=<pid> at <epoch>` and exit 0. Follow with the batch pull below, then remove `${LOCK}` once the batch's namespaces are marked `done`. If the lock check exits 1, stop; do not claim a batch while another process holds a live lock.

## Batch pull

Pulls raw JSON for the next `BATCH_SIZE` pending namespaces. Run as written, do not modify flags; with `set -eu`, a failed pull aborts before the namespace is marked `done`, so a re-run resumes at the namespace that failed. Run "Worklist lock" above immediately before this block, and remove the lock file immediately after.

```bash
set -eu
KUBE_CONTEXT="your-kube-context"
RUN_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/map-topology/runs/20260717T140500Z"   # example; the resolved run directory
BATCH_SIZE="10"   # namespaces per batch; example, tune to your environment
# Kinds pulled per namespace on the fallback path. On the mesh path use instead:
# KINDS="deployment statefulset daemonset service endpoints ingress pod virtualservice destinationrule serviceentry"
KINDS="deployment statefulset daemonset service endpoints ingress"

BATCH=$(awk -F'\t' '$2 == "pending" {print $1}' "${RUN_DIR}/worklist.tsv" | head -n "${BATCH_SIZE}")
[ -n "${BATCH}" ] || { echo "worklist complete: nothing pending"; exit 0; }

for ns in ${BATCH}; do
  for kind in ${KINDS}; do
    kubectl --context "${KUBE_CONTEXT}" get "${kind}" -n "${ns}" -o json \
      > "${RUN_DIR}/raw/${ns}.${kind}.json"
  done
  awk -F'\t' -v ns="${ns}" 'BEGIN{OFS="\t"} $1 == ns {$2 = "done"} {print}' \
    "${RUN_DIR}/worklist.tsv" > "${RUN_DIR}/worklist.tmp"
  mv "${RUN_DIR}/worklist.tmp" "${RUN_DIR}/worklist.tsv"
  echo "done: ${ns}"
done
awk -F'\t' '{c[$2]++} END {printf "done=%d pending=%d\n", c["done"]+0, c["pending"]+0}' "${RUN_DIR}/worklist.tsv"
rm -f "${RUN_DIR}/worklist.lock"
```

Expected: one `done: <namespace>` line per namespace in the batch, then the updated counts. Repeat "Worklist lock" then this block until it prints `worklist complete: nothing pending`. Cluster-scoped inventory (namespace labels, istiod, `gateways.networking.istio.io`, `istioctl proxy-status`) is never batched; pull it once per run with the blocks above.

## Merge raw pulls

Merges the per-namespace raw files into the same shape as a cluster-wide `kubectl get <kind> -A -o json`, so the collection filters in this cookbook run unchanged against them.

```bash
set -eu
RUN_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/map-topology/runs/20260717T140500Z"   # example; the resolved run directory from "Worklist build and resume"
for kind in deployment statefulset daemonset service endpoints ingress; do
  jq -s '{items: [.[].items[]]}' "${RUN_DIR}/raw/"*".${kind}.json" > "${RUN_DIR}/merged.${kind}.json"
  echo "${kind}: $(jq -r '.items | length' "${RUN_DIR}/merged.${kind}.json") objects"
done
```

Expected: one count line per kind, covering every namespace pulled so far. Mesh path: extend the kind list to match the `KINDS` used in the batch pull.

Worked example, the "Workloads and versions" filter fed from the merge. Producer swap only; the filter body is unchanged:

```bash
set -eu
NS_EXCLUDE="^(kube-system|kube-public|kube-node-lease|istio-system)$"
RUN_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/map-topology/runs/20260717T140500Z"   # example; the resolved run directory from "Worklist build and resume"

for kind in deployment statefulset daemonset; do
  jq -r --arg kind "${kind}" --arg ex "${NS_EXCLUDE}" '
      .items[]
      | select(.metadata.namespace | test($ex) | not)
      | (.spec.template.metadata.labels // {}) as $lbl
      | (.spec.template.spec.containers[0].image // "" | split("/") | last | split("@")[0]) as $img
      | [ .metadata.namespace,
          ($kind + "/" + .metadata.name),
          ($lbl["version"] // $lbl["app.kubernetes.io/version"]
            // ($img | split(":") | if length > 1 and last != "latest" then last else "unknown" end)) ]
      | @tsv' "${RUN_DIR}/merged.${kind}.json"
done | sort | tee "${RUN_DIR}/workloads.tsv"
```

For the "Service-to-workload join", build its two inputs from the merge, then run only the final `jq -n --slurpfile` join command from that section with `TMP` declared as `${RUN_DIR}`; skip the two kubectl pulls at its top:

```bash
set -eu
RUN_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/map-topology/runs/20260717T140500Z"   # example; the resolved run directory from "Worklist build and resume"
cp "${RUN_DIR}/merged.service.json" "${RUN_DIR}/svc.json"
for kind in deployment statefulset daemonset; do
  jq --arg kind "${kind}" '.items[] | .kind = $kind' "${RUN_DIR}/merged.${kind}.json"
done | jq -s '.' > "${RUN_DIR}/workloads.json"
echo "svc.json and workloads.json ready under ${RUN_DIR}"
```

Adapt every other collection filter the same way, and do not modify the filter bodies: feed the merged file for the filter's kind in place of the live `kubectl ... -A -o json` producer, keep the `NS_EXCLUDE` argument (harmless, since excluded namespaces were never pulled), and write outputs to `${RUN_DIR}` instead of a temp dir.

## Delta helpers

Extract comparable keys from a previous `topology.md`. Run only after copying the old file aside.

Service keys (`namespace/service`) from a map file's Services table:

```bash
set -eu
TMP="${TMP:-$(mktemp -d)}"
PREV="${TMP}/topology.prev.md"   # copied aside in SKILL.md Phase 4

awk -F'|' '
  /^## Services/ {f=1; next}
  /^## /         {f=0}
  f && /^\|/ && $2 !~ /^[ -:]*$/ && $2 !~ /Service/ {
    gsub(/ /,"",$2); gsub(/ /,"",$3); print $3 "/" $2
  }' "${PREV}" | sort > "${TMP}/services.prev.txt"
wc -l "${TMP}/services.prev.txt"
```

Produce `services.new.txt` the same way from the freshly composed `${TMP}/topology.new.md`, then:

```bash
set -eu
TMP="${TMP:-$(mktemp -d)}"
echo "added:";   comm -13 "${TMP}/services.prev.txt" "${TMP}/services.new.txt"
echo "removed:"; comm -23 "${TMP}/services.prev.txt" "${TMP}/services.new.txt"
```

Expected: zero or more `namespace/service` keys under each label. `comm` requires the sorted input the previous block produced.

Rewired detection, by diffing the routing sections of both files:

```bash
set -eu
TMP="${TMP:-$(mktemp -d)}"
for section in "Traffic map" "Entry points"; do
  for run in prev new; do
    awk -v s="## ${section}" '
      $0 == s {f=1; next}
      /^## /  {f=0}
      f && /^\|/' "${TMP}/topology.${run}.md" > "${TMP}/section.${run}.txt"
  done
  echo "--- ${section} ---"
  diff -u "${TMP}/section.prev.txt" "${TMP}/section.new.txt" || true
done
```

Expected: empty diffs when routing is unchanged. Each `-`/`+` row pair for a service present in both runs is one "rewired" line in the Changes section; summarize it in plain words (destination, subset, weight, host, or backend that changed).

Watchpoints carry-forward source rows:

```bash
set -eu
TMP="${TMP:-$(mktemp -d)}"
PREV="${TMP}/topology.prev.md"

awk '
  /^## Integration watchpoints/ {f=1; next}
  /^## /                        {f=0}
  f && /^\|/' "${PREV}" > "${TMP}/watchpoints.prev.txt"
wc -l "${TMP}/watchpoints.prev.txt"
```

Expected: the header, separator, and one row per service. When composing the final file, keep every non-header row whose service key still exists, append `unknown` rows for added services, and surface rows for removed services in the Changes section instead of deleting them.
