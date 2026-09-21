# Non-Kubernetes topology sources — command recipes

Cookbook for map-topology's source-routed discovery when the estate has **no
Kubernetes cluster** (or Kubernetes covers only part of it). The workflow lives
in [SKILL.md](../SKILL.md); this file holds the exact read-only blocks per
source, the merge rules, and what each source honestly can and cannot tell you.

Every command here is read-only (`list`/`describe`/`get`, or a GraphQL/REST
read); nothing mutates. Authenticated HTTP probes keep the body and
content-type and fail closed on non-JSON, exactly like the audits' doctor gates.

## What each source can and cannot give

| Source | Services | Call edges (traffic map) | Entry points | Workload objects for the export |
| --- | --- | --- | --- | --- |
| Kubernetes / Istio | yes (authoritative) | Istio: yes; plain: partial | Ingress/Gateway | yes — the only source the platform import accepts workloads from today |
| AWS | ECS services, Lambda functions, EC2 groups by tag | no (infrastructure sees placement, not calls) | ALB/NLB listeners + target groups | **no** — never fabricate; see the export rules below |
| DigitalOcean | App Platform apps/components, tagged droplets | no | app ingress / load balancers | no |
| New Relic | service entities (OTel `EXT` + agent `APM` domains) | **yes** — span-derived `relatedEntities` CALLS edges | no | no |
| Tempo service-graphs (via the `prometheus`/`mimir`/`victoriametrics` block) | **yes** — the metric's `client`/`server` values are service names | **yes** — trace-derived call edges | no | no |
| Sentry | projects (+ environments) | no | no | no — but a Sentry `project` is a platform-accepted correlation anchor, so these services still correlate |
| Guided capture (no source configured) | user-asserted list | user-asserted | user-asserted | no |

Rule of thumb: **infrastructure sources name the services; APM sources connect
them.** The best non-Kubernetes map combines one of each.

## Source routing

Pick sources in Phase 0 from what `toolkit.yaml` actually configures:

1. `kubernetes` present → the existing Istio/plain paths run unchanged (Phases
   1–2C). Other configured sources may still ADD services that live outside the
   cluster (a Lambda, a legacy VM) — merged per the rules below, never replacing
   cluster truth.
2. No `kubernetes` → run every configured source below and merge. At least one
   infrastructure source (aws/digitalocean/azure/gcp) OR one APM source
   (newrelic/sentry) OR a metrics store carrying Tempo service-graph data
   (prometheus/mimir/victoriametrics — a one-metric probe decides; see the
   section below) is required to proceed automatically.
3. Nothing configured → **guided capture** (below). Never a dead-end, never a
   fabricated map.

## AWS (ECS services, Lambda, EC2 tag groups, ALB entry points)

Resolve the profile/region from the config's `aws` block the same way
`audit-aws` does, verify identity first, and use explicit `--profile`/`--region`
on every call:

```bash
set -eu
AWS_PROFILE_CFG="your-aws-profile"   # from toolkit.yaml aws.profile (resolved in Phase 0)
AWS_REGION_CFG="your-aws-region"     # from toolkit.yaml aws.region
aws sts get-caller-identity --profile "${AWS_PROFILE_CFG}" --region "${AWS_REGION_CFG}" --output json | jq -e '.Account' >/dev/null

# ECS: clusters -> services (the closest thing to workloads outside Kubernetes)
for c in $(aws ecs list-clusters --profile "${AWS_PROFILE_CFG}" --region "${AWS_REGION_CFG}" --query 'clusterArns[]' --output text); do
  aws ecs list-services --cluster "$c" --profile "${AWS_PROFILE_CFG}" --region "${AWS_REGION_CFG}" --query 'serviceArns[]' --output text \
  | tr '\t' '\n' | while IFS= read -r s; do [ -n "$s" ] && printf 'ecs\t%s\t%s\n' "${c##*/}" "${s##*/}"; done
done

# Lambda: one row per function (group by a service/app tag when your team uses one)
aws lambda list-functions --profile "${AWS_PROFILE_CFG}" --region "${AWS_REGION_CFG}" \
  --query 'Functions[].FunctionName' --output json | jq -r '.[] | "lambda\t-\t\(.)"'

# EC2: group instances into services by their Name/service tag — a tag convention,
# not ground truth; record the grouping tag you used in the map header.
aws ec2 describe-instances --profile "${AWS_PROFILE_CFG}" --region "${AWS_REGION_CFG}" \
  --filters Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].{id:InstanceId,tags:Tags}' --output json \
| jq -r '.[] | ((.tags // []) | map(select(.Key=="service" or .Key=="Service" or .Key=="Name")) | sort_by(.Key) | .[0].Value // "untagged") as $svc | "ec2\t-\t\($svc)\t\(.id)"' | sort

# Entry points: internet-facing ALBs/NLBs -> listeners -> target groups
aws elbv2 describe-load-balancers --profile "${AWS_PROFILE_CFG}" --region "${AWS_REGION_CFG}" \
  --query 'LoadBalancers[?Scheme==`internet-facing`].{name:LoadBalancerName,arn:LoadBalancerArn,dns:DNSName}' --output json \
| jq -c '.[]'
```

Interpretation: an ECS service or a Lambda is a **service row**; EC2 grouping is
only as good as the tag discipline (`untagged` rows go to the map as exactly
that — a finding-shaped fact, not something to hide). ALB listeners are the
Entry points section; a target group's registered targets tie an entry point to
a service. AWS gives **no call edges** — do not infer "A calls B" from a shared
security group or subnet; that is placement, not traffic.

## DigitalOcean (App Platform, droplets)

```bash
set -eu
# doctl resolves auth from digitalocean.token_env, same as audit-digitalocean.
doctl apps list --output json | jq -r '.[] | .spec.name as $app | (.spec.services // [])[] | "do-app\t\($app)\t\(.name)"'
doctl compute droplet list --output json | jq -r '.[] | "droplet\t-\t\(.name)"'
```

App Platform components are service rows with a real ingress (the app's default
domain = an entry point). Droplets are the EC2 case: name/tag grouping, stated.

## New Relic (service entities + the span-derived traffic map)

The one non-Kubernetes source that provides **call edges**. Same auth as
`audit-newrelic` (User key from `newrelic.api_key_env`, region host); reads are
NerdGraph query documents only:

```bash
set -eu
NR_API_HOST="api.newrelic.com"        # or api.eu.newrelic.com — from newrelic.region (Phase 0)
NR_ACCT="your-account-id"             # from newrelic.account_id
# NEW_RELIC_USER_KEY resolved from newrelic.api_key_env by the Phase-0 gate
[ -n "${NEW_RELIC_USER_KEY:-}" ] || { echo "NEW_RELIC_USER_KEY is not set — run the Phase-0 source gate first"; exit 1; }
NRB="$(mktemp)"
NRM="$(curl -s -o "$NRB" -w '%{http_code} %{content_type}' --max-time 30 \
  -X POST "https://${NR_API_HOST}/graphql" -H 'Content-Type: application/json' -H "API-Key: ${NEW_RELIC_USER_KEY}" \
  --data "{\"query\":\"{ actor { entitySearch(query: \\\"accountId = ${NR_ACCT} AND (domain = 'EXT' OR domain = 'APM')\\\") { results { entities { guid name alertSeverity } } } } }\"}")"
NRC="${NRM%% *}"; NRCT="${NRM#* }"
[ "$NRC" = "200" ] && printf '%s' "$NRCT" | grep -qi json && jq -e '.data' "$NRB" >/dev/null \
  || { echo "New Relic entity read failed (HTTP ${NRC}) — fix the newrelic block, do not guess services"; rm -f "$NRB"; exit 1; }
jq -r '.data.actor.entitySearch.results.entities[] | "newrelic\t\(.guid)\t\(.name)\t\(.alertSeverity)"' "$NRB"
rm -f "$NRB"

# Call edges for the traffic map: per service guid (bound this to the merged
# service list, not the whole estate), read the span-derived CALLS relationships.
# query { actor { entity(guid: "<guid>") { relatedEntities {
#   results { type source { entity { name } } target { entity { name } } } } } } }
# Keep only type == "CALLS" rows; each is one traffic-map edge, evidence "newrelic spans".
```

Both entity domains matter: OpenTelemetry-instrumented services are `EXT`,
agent-instrumented ones are `APM` — query only one and half the estate is
invisible. `alertSeverity: NOT_CONFIGURED` per service is worth carrying into
the watchpoints table (it means no alerting evaluates that service).

## Tempo service-graphs (services + call edges from the metrics store)

When the estate's tracing writes Tempo service-graph metrics into its metrics
store, the store alone is a real topology source: one instant query returns
service names AND who-calls-whom, trace-derived. The availability probe IS the
query — metric present means the source is live, absent means skip with the
honest note ("your metrics store has no service-graph data; enabling Tempo's
metrics-generator unlocks this"). The exact query, the `connection_type`
split (empty = service calls, `database` = resource edges, `messaging_system`
= queue candidates), and the join rules live in
[cloud-mode-apm-overlay.md](cloud-mode-apm-overlay.md) — one recipe serves
both this discovery step and the overlay.

## Sentry (projects as service identities)

```bash
set -eu
SENTRY_HOST="https://sentry.io"       # or the self-hosted host from sentry.host
SENTRY_ORG="your-org-slug"            # from sentry.org
# SENTRY_TOKEN resolved from sentry.token_env by the Phase-0 gate
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set — run the Phase-0 source gate first"; exit 1; }
SB="$(mktemp)"
SM="$(curl -s -o "$SB" -w '%{http_code} %{content_type}' --max-time 30 \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" "${SENTRY_HOST}/api/0/organizations/${SENTRY_ORG}/projects/")"
SC="${SM%% *}"; SCT="${SM#* }"
[ "$SC" = "200" ] && printf '%s' "$SCT" | grep -qi json && jq -e 'type=="array"' "$SB" >/dev/null \
  || { echo "Sentry projects read failed (HTTP ${SC})"; rm -f "$SB"; exit 1; }
jq -r '.[] | "sentry\t\(.slug)\t\(.name)"' "$SB"
rm -f "$SB"
```

A Sentry project is more than a service hint: `project` (+ `environment`) is a
**correlation anchor the Scoutflo platform accepts** — on a non-Kubernetes
estate, a service whose `MONITORED_BY` edge carries the Sentry `project`
attribute can still reach full match confidence. This is the strongest
correlation path a non-Kubernetes estate has today; say so in the map header.

## Candidate sources the run recognizes but does not read yet (verify-first)

Named at the start so an estate's real tools are never ignored silently — but
none of these becomes a lane until its API surface is verified against current
docs on a real instance (the standing verify-first rule):

| Tool (config block) | What it could give | Why it is not a lane yet |
| --- | --- | --- |
| Datadog (`datadog`) | APM service list + dependency map | the relevant catalog/dependency APIs are preview-stability; verify live first |
| Groundcover (`groundcover`) | eBPF-observed service map | no verified service-map API in its documented surface today |
| ClickStack/HyperDX (`clickstack`) | OTel trace-derived services | the v2 REST surface is session-cookie-auth and undocumented for this use |
| Elastic APM (`elk`) | service map | API surface unverified for this use |
| SigNoz (`signoz`) | OTel-native service list + dependencies | checked against the official public API spec (2026-09-21): no service-list or dependency endpoint is documented — only the generic query surface; stays verify-first until SigNoz documents one |

When one of these is the ONLY thing an estate has, say exactly that — "your
<tool> likely knows your services; reading it needs a one-time verification
pass" — and offer the guided capture meanwhile. Never scrape an unverified
endpoint and present the result as fact.

## Guided capture (no source configured)

Never a dead-end: when no topology source is configured, capture the map from
the operator instead — service names, what calls what, where user traffic
enters, and which backend watches each service. Mark every row
`evidence: asserted` (the same honesty tag the watchpoints table already uses),
and record in the header that the map is operator-asserted until a source is
connected. An asserted map still gives the audits canonical service names —
which is most of `topology.md`'s daily value.

## Merge rules (multiple sources, one map)

1. Normalize service names (lowercase, trim environment suffixes only when the
   operator confirms they are the same service) and de-duplicate across sources;
   each service row records `sources` (e.g. `ecs+newrelic+sentry`).
2. **Infrastructure sources win on existence; APM sources win on connectivity.**
   A New Relic entity with no matching infrastructure row is still a real
   service (serverless, or infra not configured) — keep it, tagged
   `newrelic-only`.
3. Conflicts are surfaced, never guessed: two sources disagreeing on a name
   (checkout vs checkout-svc) become one row with an alias note and an open
   question for the operator, mirroring the duplicate-name rule.
4. Call edges come only from sources that observe calls (Istio, New Relic
   spans). Never synthesize an edge from co-location, shared tags, or naming.

## Export rules for non-Kubernetes estates (topology-export.json)

What the platform import contract accepts today, and what it does not — emit
accordingly and say so, never fabricate:

- **Emit**: every service (relationship endpoints carry `entity_type: service`),
  its correlation attributes (`service_name`; plus the Sentry `project` and
  `environment` on the Sentry `MONITORED_BY` edge — the platform-accepted
  non-Kubernetes anchor), one resource per integration backend
  (`monitoring`/`alerting`/`vcs`/`ci_cd` with `identity.provider` +
  `external_id`), and the `SENDS_METRICS_TO`/`SENDS_LOGS_TO`/`SENDS_TRACES_TO`/
  `MONITORED_BY`/`CALLS` edges the sources actually evidenced.
- **Do NOT emit**: `kubernetes_*` workload resources or `DEPLOYED_AS` edges —
  the import contract's workload types are Kubernetes-only today, and a
  fabricated "deployment" for an ECS service would be a lie the platform then
  trusts. A non-Kubernetes service legitimately has no workload resource; the
  Topology Readiness section renders the consequence honestly (workload mapping
  reads as a current platform limit for these services, while Sentry-anchored
  match confidence still stands).
- Entry points from ALBs/App-Platform ingress go into `topology.md`'s Entry
  points section (and `ROUTES_TO` edges where a target group names the service).
- Header discipline: the map header names the sources used, the EC2/droplet
  grouping tag, and the workload-object limitation, so no reader mistakes a
  cloud-derived map for a cluster-derived one.
