# Cloud Mode — AWS resources and service→resource edges

Command recipes for map-topology's **Cloud Mode** on AWS: discover the
resources behind your services (databases, caches, queues, topics, buckets,
streams), then derive **service→resource edges** with evidence. The workflow
and the review UX live in [SKILL.md](../SKILL.md); service discovery itself is
in [non-k8s-sources.md](non-k8s-sources.md) (this file starts where that one
stops). Export shape: [scoutflo-export.md](scoutflo-export.md).

Every command is read-only (`list`/`describe`/`get`). Nothing here ever
requests or reads a secret **value** — see "Redaction discipline for
configuration values". The traffic-map rule from the sources cookbook still
stands: none of this produces CALLS edges; service→resource relations
(`STORES_DATA_IN`, `CACHES_IN`, `PUBLISHES_TO`, `SUBSCRIBES_TO`, `USES`,
`CONFIGURED_BY`) are a different lane from service→service traffic, and an
edge with no join evidence does not exist.

## Evidence classes

Every edge carries exactly one primary class (plus corroborations):

| Class | Meaning | Typical source here |
| --- | --- | --- |
| `declared` | configuration names the resource | task-def/function env or secret refs, event source mappings, notification configs |
| `observed` | traffic proves it (expires) | App Signals, X-Ray, RDS Performance Insights |
| `permitted` | identity is allowed to reach it | task/function role IAM policies |
| `reachable` | a network path exists | security-group references, VPC endpoints |
| `intent` | grouping asserts it | tags, CloudFormation stack co-location |

Composition rules are in "Evidence composition and confidence". The short
version: `declared` corroborated by `reachable` is near-certain; `permitted`
alone is strong only for IAM-gated data planes (DynamoDB/S3/SQS/SNS), weak for
password-auth engines (RDS/ElastiCache); a `declared` edge with **no** network
path is surfaced as a probable-stale-config question, never drawn silently.

## Identity and access-tier gate

Same identity discipline as every AWS block in this toolkit: explicit
`--profile`/`--region`, verify identity first. Then probe which access tier
this credential actually has, so the run announces its ceiling instead of
half-failing later:

```bash
set -eu
AWS_PROFILE_CFG="your-aws-profile"   # from toolkit.yaml aws.profile (resolved in Phase 0)
AWS_REGION_CFG="your-aws-region"     # from toolkit.yaml aws.region
A() { aws --profile "${AWS_PROFILE_CFG}" --region "${AWS_REGION_CFG}" "$@"; }
A sts get-caller-identity --output json | jq -e '.Account' >/dev/null || { echo "AWS identity check failed — fix the aws block"; exit 1; }

# Tier probe: can we read declared configuration at all? (One bounded call each;
# AccessDenied is an ANSWER here, not an error — it selects the degraded lanes.)
TIER="full-read"
# NOTE: with --max-items, text output appends a NextToken line ("None"/token) —
# take line 1 only, or the ARN comes back two lines and the probe misfires
# (live-caught on a real estate: a readable account misreported as no-config-read).
TD=$(A ecs list-task-definitions --max-items 1 --query 'taskDefinitionArns[0]' --output text 2>/dev/null) || TD="DENIED"
TD=$(printf '%s\n' "$TD" | head -n1)
if [ "$TD" = "DENIED" ]; then TIER="inventory-only"
elif [ -n "$TD" ] && [ "$TD" != "None" ] && ! A ecs describe-task-definition --task-definition "$TD" >/dev/null 2>&1; then TIER="no-config-read"; fi
if ! A iam list-account-aliases >/dev/null 2>&1 && [ "$TIER" != "full-read" ]; then TIER="inventory-only"; fi
echo "access tier: ${TIER}"
case "$TIER" in
  full-read)      echo "lanes: declared + permitted + reachable + observed(if enabled)";;
  no-config-read) echo "lanes: permitted + reachable + resource-side declared only — env/config not readable; edge ceiling is permitted/reachable and the map will say so";;
  inventory-only) echo "lanes: endpoint catalog + containment only — who-uses-what needs the guided/confirmation path";;
esac
```

The tier is recorded in the map header. Never retry a denied call against a
different profile; the tier IS the answer, and the honest map at that tier is
the product. The three tiers correspond to the three requestable policy
postures in "Access tiers to request".

## Resource endpoint catalog

The join table for everything else: one row per resource with its
**endpoint host:port**, **logical names**, engine, and id. TSV columns:
`kind  id  endpoint_host  endpoint_port  engine  logical_names`.

```bash
set -eu
AWS_PROFILE_CFG="your-aws-profile"; AWS_REGION_CFG="your-aws-region"   # from toolkit.yaml aws block (Phase 0)
A() { aws --profile "${AWS_PROFILE_CFG}" --region "${AWS_REGION_CFG}" "$@"; }
CAT="${TMPDIR:-/tmp}/cloudmode-aws-catalog.tsv"; : > "$CAT"
# RDS instances + Aurora clusters (writer/reader endpoints both catalogued)
A rds describe-db-instances --query 'DBInstances[].{id:DBInstanceIdentifier,h:Endpoint.Address,p:Endpoint.Port,e:Engine,db:DBName}' --output json \
| jq -r '.[] | select(.h != null) | ["database", .id, .h, (.p|tostring), .e, (.db // "-")] | @tsv' >> "$CAT"
A rds describe-db-clusters --query 'DBClusters[].{id:DBClusterIdentifier,h:Endpoint,r:ReaderEndpoint,p:Port,e:Engine,db:DatabaseName}' --output json \
| jq -r '.[] | select(.h != null) | (["database", .id, .h, (.p|tostring), .e, (.db // "-")] | @tsv), (select(.r != null) | ["database", (.id + "/reader"), .r, (.p|tostring), .e, (.db // "-")] | @tsv)' >> "$CAT"
# ElastiCache (replication groups first — the primary/configuration endpoint is what clients use)
A elasticache describe-replication-groups --query 'ReplicationGroups[].{id:ReplicationGroupId,c:ConfigurationEndpoint,n:NodeGroups[0].PrimaryEndpoint}' --output json \
| jq -r '.[] | (.c // .n) as $ep | select($ep != null) | ["cache", .id, $ep.Address, ($ep.Port|tostring), "redis", "-"] | @tsv' >> "$CAT"
A elasticache describe-cache-clusters --show-cache-node-info \
  --query 'CacheClusters[?ReplicationGroupId==null].{id:CacheClusterId,e:Engine,ep:ConfigurationEndpoint,n:CacheNodes[0].Endpoint}' --output json \
| jq -r '.[] | (.ep // .n) as $ep | select($ep != null) | ["cache", .id, $ep.Address, ($ep.Port|tostring), .e, "-"] | @tsv' >> "$CAT"
# SQS queues (the URL is the endpoint; the queue NAME is the logical name).
# Host cut in shell, not sed — BSD sed has no \t. Guard "None" (empty text output).
for q in $(A sqs list-queues --query 'QueueUrls[]' --output text 2>/dev/null | tr '\t' '\n'); do
  { [ -n "$q" ] && [ "$q" != "None" ]; } || continue
  qh=${q#https://}; qh=${qh%%/*}
  printf 'message_queue\t%s\t%s\t443\tsqs\t%s\n' "${q##*/}" "$qh" "${q##*/}" >> "$CAT"
done
# SNS topics
A sns list-topics --query 'Topics[].TopicArn' --output json | jq -r '.[] | ["message_queue", (split(":")|last), "sns.amazonaws.com", "443", "sns", (split(":")|last)] | @tsv' >> "$CAT"
# S3 buckets (global service; region filter happens at the join, not here)
A s3api list-buckets --query 'Buckets[].Name' --output json | jq -r '.[] | ["object_storage", ., (. + ".s3.amazonaws.com"), "443", "s3", .] | @tsv' >> "$CAT"
# MSK bootstrap brokers + OpenSearch domains (skip cleanly when the service is unused)
for arn in $(A kafka list-clusters-v2 --query 'ClusterInfoList[].ClusterArn' --output text 2>/dev/null | tr '\t' '\n'); do
  [ -n "$arn" ] && A kafka get-bootstrap-brokers --cluster-arn "$arn" --output json 2>/dev/null \
  | jq -r --arg id "${arn##*/}" '[.. | strings] | map(select(test("^[a-z0-9.-]+:[0-9]+")))[0] // empty | split(",")[0] | split(":") | ["message_queue", $id, .[0], .[1], "kafka", $id] | @tsv' >> "$CAT"
done
for d in $(A opensearch list-domain-names --query 'DomainNames[].DomainName' --output text 2>/dev/null | tr '\t' '\n'); do
  [ -n "$d" ] && A opensearch describe-domain --domain-name "$d" --query 'DomainStatus.{h:Endpoint,hs:Endpoints}' --output json \
  | jq -r --arg id "$d" '(.h // (.hs // {} | to_entries | .[0].value // empty)) | select(. != null and . != "") | ["database", $id, ., "443", "opensearch", $id] | @tsv' >> "$CAT"
done
sort -u "$CAT" -o "$CAT"; echo "catalog rows: $(wc -l < "$CAT" | tr -d ' ')"
```

DynamoDB tables, Redshift, DocumentDB, and MemoryDB follow the same pattern
(`list` + endpoint field) — add them when the estate uses them; DynamoDB has no
per-table endpoint (IAM-gated data plane), so its identity is the **table
name** and its edges come from the permitted lane and SDK env conventions.

## Resolution chains

Estates rarely connect to raw endpoints; they connect to a CNAME or a proxy.
Resolve both so the join doesn't miss the real edge, and record every hop in
the edge's `resolution_chain`:

```bash
set -eu
AWS_PROFILE_CFG="your-aws-profile"; AWS_REGION_CFG="your-aws-region"   # from toolkit.yaml aws block (Phase 0)
A() { aws --profile "${AWS_PROFILE_CFG}" --region "${AWS_REGION_CFG}" "$@"; }
# Route53 private/public CNAMEs pointing at catalog hosts (bounded: CNAME rows only)
for z in $(A route53 list-hosted-zones --query 'HostedZones[].Id' --output text | tr '\t' '\n'); do
  A route53 list-resource-record-sets --hosted-zone-id "$z" --query "ResourceRecordSets[?Type=='CNAME'].{n:Name,v:ResourceRecords[0].Value}" --output json \
  | jq -r '.[] | [.n, .v] | @tsv'
done > "${TMPDIR:-/tmp}/cloudmode-aws-cnames.tsv" 2>/dev/null || true
# RDS Proxy: proxy endpoint -> target DB (a service declaring the proxy host stores data in the TARGET)
A rds describe-db-proxies --query 'DBProxies[].{name:DBProxyName,h:Endpoint}' --output json 2>/dev/null \
| jq -r '.[] | [.name, .h] | @tsv' | while IFS="$(printf '\t')" read -r pn ph; do
  A rds describe-db-proxy-targets --db-proxy-name "$pn" --query 'Targets[].{t:RdsResourceId,type:Type}' --output json \
  | jq -r --arg pn "$pn" --arg ph "$ph" '.[] | [$pn, $ph, .t, .type] | @tsv'
done > "${TMPDIR:-/tmp}/cloudmode-aws-proxies.tsv" 2>/dev/null || true
```

## Declared configuration: ECS

For each in-scope ECS service (from the sources cookbook + the scope
checkpoint), read its **active** task definition once and extract two things —
**host-shaped values** (redacted to host:port on capture, per the redaction
section) and **secret references** (ARNs/names only, values never fetched):

```bash
set -eu
AWS_PROFILE_CFG="your-aws-profile"; AWS_REGION_CFG="your-aws-region"   # from toolkit.yaml aws block (Phase 0)
A() { aws --profile "${AWS_PROFILE_CFG}" --region "${AWS_REGION_CFG}" "$@"; }
CLUSTER="your-cluster"; SVC="your-service"      # one in-scope service per pass
TDARN=$(A ecs describe-services --cluster "$CLUSTER" --services "$SVC" --query 'services[0].taskDefinition' --output text)
A ecs describe-task-definition --task-definition "$TDARN" --output json > "${TMPDIR:-/tmp}/cloudmode-td.json"
# (a) env KEYS whose VALUE contains a host[:port] — extract key + host:port + path db name ONLY,
#     into a temp join file (never to screen): secret-named keys are skipped outright, and URL
#     userinfo (user:password@) is stripped BEFORE capture so credentials can never match.
jq -r '.taskDefinition.containerDefinitions[] | .environment // [] | .[]
  | select(.name | test("(?i)password|passwd|secret|token|api_?key|private|credential") | not)
  | .name as $k | (.value // "") | gsub("://[^@/]*@"; "://")
  | capture("(?<h>[A-Za-z0-9][A-Za-z0-9.-]+\\.[A-Za-z]{2,})(:(?<p>[0-9]{2,5}))?(/(?<db>[A-Za-z0-9_-]+))?"; "g")
  | [$k, .h, (.p // "-"), (.db // "-")] | @tsv' "${TMPDIR:-/tmp}/cloudmode-td.json" 2>/dev/null \
  | sort -u > "${TMPDIR:-/tmp}/cloudmode-extract-ecs-${SVC}.tsv"
echo "extraction rows: $(wc -l < "${TMPDIR:-/tmp}/cloudmode-extract-ecs-${SVC}.tsv" | tr -d ' ') (consumed by the synthesis join, then deleted — extractions are join probes, not output)"
# (b) secret REFERENCES: name + the ref ARN/path (this is CONFIGURED_BY evidence and a join key by name)
jq -r '.taskDefinition.containerDefinitions[] | .secrets // [] | .[] | [.name, .valueFrom] | @tsv' "${TMPDIR:-/tmp}/cloudmode-td.json"
# (c) the task role for the permitted lane, and the awsvpc security groups for the reachable lane
jq -r '.taskDefinition.taskRoleArn // empty' "${TMPDIR:-/tmp}/cloudmode-td.json"
A ecs describe-services --cluster "$CLUSTER" --services "$SVC" \
  --query 'services[0].networkConfiguration.awsvpcConfiguration.securityGroups' --output json | jq -r '.[]?'
rm -f "${TMPDIR:-/tmp}/cloudmode-td.json"
```

A secret reference like `.../prod/checkout/DATABASE_URL` is evidence twice
over: a `CONFIGURED_BY` edge to the secrets store, and a **named** join hint
(the path names the service and often the resource) — recorded as
`join_key: secret-ref-name`, class `declared`, without ever reading the value.

## Declared configuration: Lambda

```bash
set -eu
AWS_PROFILE_CFG="your-aws-profile"; AWS_REGION_CFG="your-aws-region"   # from toolkit.yaml aws block (Phase 0)
A() { aws --profile "${AWS_PROFILE_CFG}" --region "${AWS_REGION_CFG}" "$@"; }
FN="your-function"                                # one in-scope function per pass
# Env keys -> host extraction, same redaction discipline as ECS (secret-named keys skipped,
# URL userinfo stripped before capture, extraction to the temp join file, never to screen)
A lambda get-function-configuration --function-name "$FN" --output json \
| jq -r '(.Environment.Variables // {}) | to_entries[]
    | select(.key | test("(?i)password|passwd|secret|token|api_?key|private|credential") | not)
    | .key as $k | .value | gsub("://[^@/]*@"; "://")
    | capture("(?<h>[A-Za-z0-9][A-Za-z0-9.-]+\\.[A-Za-z]{2,})(:(?<p>[0-9]{2,5}))?(/(?<db>[A-Za-z0-9_-]+))?"; "g")
    | [$k, .h, (.p // "-"), (.db // "-")] | @tsv' 2>/dev/null \
  | sort -u > "${TMPDIR:-/tmp}/cloudmode-extract-lambda-${FN}.tsv"
echo "extraction rows: $(wc -l < "${TMPDIR:-/tmp}/cloudmode-extract-lambda-${FN}.tsv" | tr -d ' ')"
# DLQ + role (permitted lane) from the same call
A lambda get-function-configuration --function-name "$FN" --query '{dlq:DeadLetterConfig.TargetArn,role:Role,vpcsg:VpcConfig.SecurityGroupIds}' --output json
# Event source mappings: the PLATFORM polls the source for you — a SUBSCRIBES_TO/CONSUMES edge with near-zero noise
A lambda list-event-source-mappings --function-name "$FN" \
  --query 'EventSourceMappings[].{src:EventSourceArn,state:State}' --output json | jq -c '.[]'
# On-failure/on-success destinations
A lambda get-function-event-invoke-config --function-name "$FN" --output json 2>/dev/null \
| jq -r '.DestinationConfig // {} | to_entries[] | select(.value.Destination != null) | [.key, .value.Destination] | @tsv' || true
```

An event source mapping in state `Enabled` is the strongest declared edge AWS
offers (`mechanism: aws.lambda.esm`): the platform itself maintains the
connection. Emit `SUBSCRIBES_TO` (SQS/Kafka/MQ) or `CONSUMES`
(Kinesis/DynamoDB streams) accordingly.

Honesty note: this block's extraction pipeline is behavior-tested, but the
Lambda API responses themselves were verified against documentation, not a
live function (the smoke estate had none) — on first use against a real
Lambda estate, confirm the response fields before trusting a surprising
result, and treat a shape mismatch as a bug to report, not to paper over.

## Reverse event wiring

Resource-side declarations that point AT services — these work even at the
`no-config-read` tier because they are resource reads, not service-config
reads:

```bash
set -eu
AWS_PROFILE_CFG="your-aws-profile"; AWS_REGION_CFG="your-aws-region"   # from toolkit.yaml aws block (Phase 0)
A() { aws --profile "${AWS_PROFILE_CFG}" --region "${AWS_REGION_CFG}" "$@"; }
# S3 -> who gets notified (Lambda/SQS/SNS)
BUCKET="your-bucket"
A s3api get-bucket-notification-configuration --bucket "$BUCKET" --output json \
| jq -r '[(.LambdaFunctionConfigurations // [])[] | ["lambda", .LambdaFunctionArn]],
         [(.QueueConfigurations // [])[] | ["sqs", .QueueArn]],
         [(.TopicConfigurations // [])[] | ["sns", .TopicArn]] | .[] | @tsv' 2>/dev/null || true
# SNS topic -> subscribers (Lambda/SQS/HTTP endpoints)
TOPIC_ARN="your-topic-arn"
A sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" \
  --query 'Subscriptions[].{proto:Protocol,ep:Endpoint}' --output json | jq -c '.[]'
# EventBridge rules -> targets (bounded to the default bus unless the estate names more)
for r in $(A events list-rules --query 'Rules[].Name' --output text | tr '\t' '\n'); do
  [ -n "$r" ] && A events list-targets-by-rule --rule "$r" --query 'Targets[].Arn' --output json \
  | jq -r --arg r "$r" '.[] | [$r, .] | @tsv'
done
```

Interpretation: an S3 notification to a Lambda is `S3 bucket → PUBLISHES_TO →
that function` seen from the bucket side (the function `SUBSCRIBES_TO` the
bucket's events); an SNS subscription pointing at a service's queue chains
`service ← SUBSCRIBES_TO ← queue ← SUBSCRIBES_TO ← topic`.

## Declared-edge synthesis

The join: every extracted host[:port] / logical name / secret-ref name from
the two declared sections is matched against the endpoint catalog — directly,
then through the resolution chains:

1. **Host match**: extracted host equals a catalog `endpoint_host` (port
   agreeing when both known) → edge, `join_key: env:<KEY>→host`,
   `evidence_class: declared`.
2. **Chain match**: extracted host is a CNAME (or RDS Proxy endpoint) whose
   chain lands on a catalog host → same edge, `resolution_chain` recording
   every hop.
3. **Logical-name match**: env path/db segment or queue/topic name equals a
   catalog `logical_names` entry → edge with `join_key: logical-name`; used
   alone it is one tier weaker (name collisions exist) — flag for review
   rather than bulk-accept.
4. **Ref match**: a secret/parameter ref whose path names a catalog id →
   `CONFIGURED_BY` to the store always, plus a review-tier resource edge when
   the path names exactly one resource.

Relation by resource kind: `database → STORES_DATA_IN` · `cache → CACHES_IN` ·
`message_queue → PUBLISHES_TO/SUBSCRIBES_TO/CONSUMES` (direction from the
mechanism: ESM/notification = consume side; an SDK env var alone can't prove
direction — emit `USES` and let review upgrade it) · `object_storage → USES`.
One edge per service↔resource pair; additional mechanisms append to the SAME
edge's evidence, never duplicate rows.

## Permitted lane: IAM

For each **distinct** task/function role (dedupe first — many services share a
role, and a shared role means shared, weaker evidence):

```bash
set -eu
AWS_PROFILE_CFG="your-aws-profile"; AWS_REGION_CFG="your-aws-region"   # from toolkit.yaml aws block (Phase 0)
A() { aws --profile "${AWS_PROFILE_CFG}" --region "${AWS_REGION_CFG}" "$@"; }
ROLE_ARN="arn:aws:iam::123456789012:role/your-task-role"   # from the declared sections (one distinct role per pass)
ROLE="${ROLE_ARN##*/}"
{ for p in $(A iam list-attached-role-policies --role-name "$ROLE" --query 'AttachedPolicies[].PolicyArn' --output text | tr '\t' '\n'); do
    [ -n "$p" ] || continue
    v=$(A iam get-policy --policy-arn "$p" --query 'Policy.DefaultVersionId' --output text)
    A iam get-policy-version --policy-arn "$p" --version-id "$v" --query 'PolicyVersion.Document' --output json
  done
  for n in $(A iam list-role-policies --role-name "$ROLE" --query 'PolicyNames[]' --output text | tr '\t' '\n'); do
    [ -n "$n" ] && A iam get-role-policy --role-name "$ROLE" --policy-name "$n" --query 'PolicyDocument' --output json
  done
} | jq -r '[.Statement[]? | select(.Effect=="Allow")] | .[] | (.Action | if type=="array" then . else [.] end)[] as $a | (.Resource | if type=="array" then . else [.] end)[] as $r | [$a, $r] | @tsv' | sort -u
```

Action-verb → relation map (extend as engines appear; unknown verbs are
ignored, never guessed):

| Action pattern | Relation | Note |
| --- | --- | --- |
| `sqs:SendMessage` | PUBLISHES_TO | |
| `sqs:ReceiveMessage`, `sqs:DeleteMessage` | SUBSCRIBES_TO | |
| `sns:Publish` | PUBLISHES_TO | |
| `dynamodb:GetItem/Query/Scan/PutItem/UpdateItem/DeleteItem/BatchGet*/BatchWrite*` | STORES_DATA_IN | permitted is STRONG here (IAM-gated data plane) |
| `s3:GetObject/PutObject/DeleteObject` | USES | resource ARN names the bucket (strip `/*`) |
| `kinesis:GetRecords` / `kinesis:PutRecord*` | CONSUMES / PUBLISHES_TO | |
| `secretsmanager:GetSecretValue`, `ssm:GetParameter*` | CONFIGURED_BY | edge to the store; never call these actions yourself |
| `rds-db:connect` | STORES_DATA_IN | rare (IAM DB auth) — strong when present |

**Wildcard demotion (hard rule):** a statement whose `Resource` is `*` (or an
account-wide/whole-service wildcard) never materializes per-resource edges —
at most one `intent`-class note on the service ("role may access any SQS
queue"). A specific ARN yields a `permitted` edge to exactly that resource.
Ignore `Deny`-statement complexities beyond this: this lane proposes
candidates for corroboration, it does not adjudicate IAM.

## Reachable lane: security groups and VPC endpoints

```bash
set -eu
AWS_PROFILE_CFG="your-aws-profile"; AWS_REGION_CFG="your-aws-region"   # from toolkit.yaml aws block (Phase 0)
A() { aws --profile "${AWS_PROFILE_CFG}" --region "${AWS_REGION_CFG}" "$@"; }
# One call: every SG's inbound rules that reference OTHER SGs, with ports
A ec2 describe-security-groups --query 'SecurityGroups[].{id:GroupId,perms:IpPermissions}' --output json \
| jq -r '.[] | .id as $to | .perms[]? | (.FromPort // 0) as $p | .UserIdGroupPairs[]? | [.GroupId, $to, ($p|tostring)] | @tsv' | sort -u
# Gateway/interface endpoints (private-path corroboration for S3/DynamoDB/etc.)
A ec2 describe-vpc-endpoints --query 'VpcEndpoints[].{svc:ServiceName,vpc:VpcId,state:State}' --output json | jq -c '.[] | select(.state=="available")'
```

Join: service side = the awsvpc/Lambda-VPC security groups captured in the
declared sections; resource side = the SGs on RDS (`VpcSecurityGroups`),
ElastiCache (`SecurityGroups`), MSK, OpenSearch (read them alongside the
catalog when this lane runs). `svc-SG → allowed into → resource-SG on the
engine's port` = `reachable`. **Same-SG case** (very common on small estates,
live-confirmed: an ECS service and its RDS instances all in one SG): shared
membership alone is NOT reachability — count it only when that SG has a
self-referencing inbound rule on the engine's port (a `UserIdGroupPairs`
entry naming the SG itself). Used two ways: **corroborate** a declared edge
(upgrade its confidence) or **refute** one (declared but no path → surface as
a probable-stale-config question in the review). A reachable-only pair with no
other evidence is a weak candidate — review tier, never bulk-accept: shared
SGs make network reachability common; reachability is not usage.

## Observed lane: opportunistic probes

All three are availability-gated: probe once, use when present, skip cleanly
when not — never a failure, always a one-line note in the map header.

```bash
set -eu
AWS_PROFILE_CFG="your-aws-profile"; AWS_REGION_CFG="your-aws-region"   # from toolkit.yaml aws block (Phase 0)
A() { aws --profile "${AWS_PROFILE_CFG}" --region "${AWS_REGION_CFG}" "$@"; }
# Capture-then-branch, never `aws | jq || echo`: jq exits 0 on EMPTY input, so a
# piped fallback message never fires and a failed probe looks like silence
# (live-caught). Each probe announces data, empty, or unavailable explicitly.
ST=$(date -u -v-24H '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -u -d '24 hours ago' '+%Y-%m-%dT%H:%M:%S')
ET=$(date -u '+%Y-%m-%dT%H:%M:%S')
# (1) CloudWatch Application Signals — typed service dependencies (if enabled)
ASB=$(A application-signals list-services --start-time "$ST" --end-time "$ET" --max-results 20 --output json 2>/dev/null) || ASB=""
[ -n "$ASB" ] && printf '%s' "$ASB" | jq -c '.ServiceSummaries[]? | .KeyAttributes' \
  || echo "app-signals: unavailable/not enabled — skipping (observed lane)"
# per in-scope service (bounded): list-service-dependencies with its KeyAttributes -> typed Dependency rows
# (2) X-Ray service graph — database nodes carry the endpoint identity
XB=$(A xray get-service-graph --start-time "$ST" --end-time "$ET" --output json 2>/dev/null) || XB=""
[ -n "$XB" ] && printf '%s' "$XB" | jq -c '.Services[]? | select(.Type != null and (.Type | test("Database|RDS|DynamoDb"; "i"))) | {name:.Name, type:.Type}' \
  || echo "x-ray: unavailable/no trace data — skipping"
# (3) RDS Performance Insights — the DB-side view of WHO connects (db.host dimension; verify the
#     exact dimension group live on first use — availability varies by engine)
DBI="your-db-resource-id"   # DbiResourceId from the catalog read
PIB=$(A pi get-resource-metrics --service-type RDS --identifier "$DBI" \
  --metric-queries '[{"Metric":"db.load.avg","GroupBy":{"Group":"db.host"}}]' \
  --start-time "$(date -u -v-1H '+%s' 2>/dev/null || date -u -d '1 hour ago' '+%s')" --end-time "$(date -u '+%s')" \
  --period-in-seconds 300 --output json 2>/dev/null) || PIB=""
[ -n "$PIB" ] && printf '%s' "$PIB" | jq -c '.MetricList[]? | .Key' \
  || echo "performance-insights: unavailable/not enabled for ${DBI} — skipping"
```

Observed edges carry `valid_from` = the probe window and **expire**: an
observed edge older than the estate's re-run cadence degrades back to whatever
its declared/permitted evidence supports — absence of traffic is not absence
of dependency (batch jobs, DR paths).

## IaC-in-repo lane

When `repo-map.json` exists (map-repos ran), the mapped repos' IaC and compose
files declare the same wiring with **placeholder values** — join keys with
zero live-config access. Read-only GitHub content reads, bounded to mapped
repos and to these filename patterns: `*.tf`, `template*.y*ml`,
`docker-compose*.y*ml`, `serverless*.y*ml`, `k8s/*.y*ml`, `.env.example`.
Extract host-shaped strings and resource identifiers with the same capture
pattern as the ECS section (keys/hosts only — an `.env.example` may still hold
a real credential someone pasted; the redaction discipline applies to repo
content exactly as to live config). Edges from this lane are
`declared` with `mechanism: iac-in-repo` and the file path as evidence.
Terraform **state** files are excluded outright — state carries secret values.

## Evidence composition and confidence

Per service↔resource pair, combine lanes into ONE edge:

| Combination | Confidence | Action |
| --- | --- | --- |
| declared + reachable (+ observed) | 0.95–0.99 | Tier A — bulk-confirm table |
| declared alone | 0.85 | Tier A, flagged "network unverified" |
| esm / reverse-wiring / rds-proxy-target | 0.95 | Tier A (platform-maintained declarations) |
| permitted(IAM-gated plane) + reachable | 0.80 | Tier A low / Tier B |
| permitted alone (specific ARN) | 0.60 | Tier B — review |
| reachable alone / logical-name alone | 0.45 | Tier B — review |
| intent only (tags/stack) | never drawn | note in the map appendix only |
| declared + reachability CHECKED and absent | — | Tier C — surfaced as probable stale config |
| user-confirmed (any tier) | asserted | `evidence: asserted`, upgraded on new evidence |

Numbers are the plugin's ranking heuristic for review batching (they map to
the platform's `confidence` field on export); they are never presented as
measured probabilities.

## Redaction discipline for configuration values

Task-def and Lambda env reads return live values, which may include
credentials embedded in URLs. Hard rules, mirroring
[secret-redaction](../../../report-standard/secret-redaction.md):

- Values are parsed **in-stream** with the capture pattern above; only
  `key + host + port + path-db-name` survive, and only into the temp join
  files — extraction rows are join probes, never printed and never exported.
  What reaches the map/export is exclusively a value that MATCHED the
  endpoint catalog (a real endpoint, by definition).
- Never write a raw task definition, function configuration, or `.env`-like
  buffer to the audit dir; temp files are deleted in the same block or
  consumed and deleted by the synthesis join.
- `user:password@host` forms: URL userinfo is stripped (`gsub("://[^@/]*@";
  "://")`) BEFORE capture, so a credential — even a dotted, host-shaped one —
  cannot match. Keys named like secrets (`password`, `secret`, `token`,
  `api_key`, `private`, `credential`) are skipped without parsing at all.
- Secret refs are recorded by ARN/name only; `secretsmanager:GetSecretValue` /
  `ssm:GetParameter` are never called by any lane, any tier.
- At `no-config-read` tier this section is moot by construction — that is the
  point of offering that tier to security-conscious estates.

## Bounded reads

| Lane | Cost model | Bound |
| --- | --- | --- |
| Endpoint catalog | 1 list/describe per engine family | fixed (~8 calls/region) |
| ECS/Lambda declared | 2 calls per in-scope service | scope checkpoint decides the list |
| Reverse wiring | 1 call per bucket/topic/rule | cap at the checkpoint estate size; sample + note when above |
| IAM permitted | ~3 calls per **distinct** role | dedupe roles first |
| Security groups | 2 calls total | fixed |
| Observed probes | 1 probe each + 1 per in-scope service (App Signals) / per DB (PI) | skip-clean when disabled |
| Route53 chains | 1 call per hosted zone | zones listed once; skip per-zone detail above ~20 zones (example, tune to your estate) with a note |

The estate-scope checkpoint (SKILL.md Phase 2E step 0) runs BEFORE the
per-service lanes: counts come from the catalog + service lists (cheap), the
user picks scope, and only then do the per-service reads run.

## Access tiers to request

Three named postures to hand your security team as documents, not
negotiations. Each maps to a ladder rung in the tier gate above; the run
announces which one it detected and what that ceiling means.

1. **Broad read** — the AWS-managed `ReadOnlyAccess` policy (what many estates
   already grant). Full lanes. Note honestly: this policy can read plaintext
   ECS/Lambda env values; the redaction discipline above is what stands
   between that and exposure, and some security teams will decline it.
2. **`topology-discovery` (scoped)** — only the actions this cookbook runs:
   `ecs:List*/Describe*`, `lambda:List*/GetFunctionConfiguration/GetFunctionEventInvokeConfig`,
   `rds:Describe*`, `elasticache:Describe*`, `sqs:ListQueues/GetQueueAttributes`,
   `sns:ListTopics/ListSubscriptionsByTopic`, `s3:ListAllMyBuckets/GetBucketNotification`,
   `kafka:ListClustersV2/GetBootstrapBrokers`, `es:ListDomainNames/DescribeDomain`
   (and `opensearch:*` read equivalents), `events:ListRules/ListTargetsByRule`,
   `route53:ListHostedZones/ListResourceRecordSets`, `ec2:DescribeSecurityGroups/DescribeVpcEndpoints`,
   `iam:ListAttachedRolePolicies/ListRolePolicies/GetPolicy/GetPolicyVersion/GetRolePolicy`,
   `xray:GetServiceGraph`, `application-signals:List*`, `pi:GetResourceMetrics`,
   `sts:GetCallerIdentity`. **No** `secretsmanager:GetSecretValue`, **no**
   `ssm:GetParameter*`, **no** `s3:GetObject` — secret values are out of scope
   by construction.
3. **`topology-discovery-noconfig`** — tier 2 minus the env-value-bearing
   calls (`ecs:DescribeTaskDefinition`, `lambda:GetFunctionConfiguration`).
   The declared lane then comes only from resource-side reads (event source
   mappings listed without function config where permitted, reverse wiring,
   RDS Proxy targets) and IaC-in-repo; the map states "service configuration
   not readable at this access tier" per service.

Write the chosen tier into the map header verbatim so a reader knows which
ceiling produced the map.

## Zero-access discovery pack

When this toolkit's environment gets no cloud access at all: generate a
single self-contained POSIX script from this cookbook's read blocks for
whoever holds the credentials to run **inside their own boundary**, and
import its output file. Rules for the generated script:

- Read-only calls from this cookbook only; explicit `--profile`/`--region`
  arguments the operator fills in; `sts get-caller-identity` echoed first so
  they see (and consent to) the identity being used.
- Output is ONE reviewable TSV (`cloudmode-discovery.tsv`): catalog rows,
  extracted `key/host/port/logical-name` rows, secret-ref names, role→ARN
  rows, SG pairs. No raw JSON dumps, no env values — the same in-stream
  extraction as the ECS/Lambda sections.
- Self-check before exit, fail closed: scan the output for secret-shaped
  content (`password=`, `PRIVATE KEY`, AWS secret-key base64 shape,
  `://[^/]*:[^@]*@` credentials-in-URL) and abort with the offending line
  number — never write a file that fails the scan.
- The credential holder reads the file, then hands it over; its rows import exactly
  like live-lane output with `mechanism: zero-access-pack` on the evidence,
  and the review protocol (Tier batches) applies unchanged.
