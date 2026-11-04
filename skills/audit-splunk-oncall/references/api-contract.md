# Splunk On-Call API and evidence contract

## Proven source and limits

Official source: [VictorOps public API specification](https://portal.victorops.com/api-docs/victorops-api-v1.yaml). The specification is Swagger2.0; its declared0.0.3 is an API-document version, not the product's deployed version. Required headers are shared `apiId`/`apiKey` parameters, not a `securityDefinitions` block. The SaaS product exposes no product-version identity endpoint proven by this integration; do not fabricate one for a report.

Populated management shapes below were observed in a test account in November2026, including staffed and intentionally unstaffed rotations. The collection recipe and skills still require their own current live acceptance. Source documentation, provider research and successful execution of this release are separate claims. Lower-role, second-account, revoke/expiry, live429, large populated pagination, future/DST coverage and human notification receipt are verify-pending.

| Fixed GET path | Projected fields and purpose |
| --- | --- |
| `/api-public/v1/team/{team}` | Object `slug` must equal the configured anchor before and after the run |
| `/api-public/v1/team` | Bare array of team objects; retain `slug` |
| `/api-public/v1/policies` | `policies[].policy.slug` and `.team.slug`; retain ownership join |
| `/api-public/v1/org/routing-keys` | `routingKeys[].targets[].policySlug`; create run-local ordinal aliases and remove all key values/links |
| `/api-public/v1/policies/{policy}` | `slug`, `steps[].timeout`, `entries[].executionType`, supported `user.username`/`rotationGroup.slug` |
| `/api-public/v1/team/{team}/members` | `members[].username`, boolean `verified`; no contacts or personal names |
| `/api-public/v1/teams/{team}/rotations` | `rotationGroups[].slug/groupId/teamSlug`; `groupId` observed integer |
| `/api-public/v2/team/{team}/rotations` | `rotations[].groupId`, `shifts[].shiftId/shifttype/timezone/shiftMembers[].username/current.username` |
| `/api-public/v1/oncall/current` | `teamsOnCall[].team.slug`, `.oncallNow[].escalationPolicy.slug`, `.users[].onCalluser.username` |

All collection paths are constructed from constants and validated identifiers. Never dereference `_selfUrl`, `_teamUrl` or a response-provided next URL. The known account team proves consistency with the operator's anchor, not a cryptographic tenant ID. Both keys are confidential header values. A route key is also a secret, even when the provider calls it a name and a read-only key can list it. The optional `--source-route-env VARIABLE_NAME` mode resolves an independently verified source key from the protected store and returns only `source_match.route_aliases` and `.policies`; no match stays empty, ambiguity remains visible, and neither outcome invents source-side provenance.

## Transport and projection

The reader makes serial GETs at least one second apart (the selected endpoints document at most two calls/second). It never retries on429. Stop and record a blocked check; a later bounded rerun must respect provider Retry-After if available. Do not burst or probe the limit. History, if separately introduced, requires its own one-call-per-minute budget and populated pagination proof; the core recipe does not call history.

Curl has fixed HTTPS origin, identity encoding, no redirects, max25seconds, max2MiB and complete JSON parsing. Curl8.4+ is required for the unknown-length body bound. Missing/rejected auth,3xx,404,429,5xx, oversized/truncated bodies and malformed JSON are distinct from a successful empty collection. Diagnostics retain only a status/class. No provider errors, credentials or unprojected JSON go to files or the model.

The recipe validates required envelopes before projection. It preserves missing `isMultiResponder` as null/unknown and unknown execution types as types without private payloads. It fails if current endpoint casing/wrappers differ; it does not silently accept a different API generation. IDs and enum types are endpoint-specific. Unsupported timing/override semantics block downstream judgments even when their fields parse.

Do not run curl with tracing, verbose headers, shell xtrace or a user-provided proxy/URL override that sends credentials elsewhere. A connected transport must prove the same target and effects. Never include provider credentials in arguments shown to the user. A failed scope/identity check is not repaired by trying another account's key.

## Sensitive incident evidence

Core audit collection intentionally does not fetch alert detail. `GET /api-public/v1/alerts/{uuid}` may expose actual `apiKey`, `routingKey` and JSON-string `raw` containing the inbound credential and URL. Read-only permission does not make that output safe. If a selected investigation needs it, keep the raw response only in memory and allowlist the exact necessary non-secret fields before any model/log/file output. Never save first and regex-scrub later. Do not treat arbitrary JSON-string payloads as harmless text.

A safe lineage projection contains the known incident/alert identity, message-state type, original source-evidence reference, policy/team slugs, captured recipient identity and booleans confirming the expected key/source match. Omit keys, inbound URLs, raw payloads, arbitrary messages, personal contact addresses and unknown fields. Timestamp type observation is not a units guarantee. No standalone ad hoc alert-detail recipe ships until its additional projection/identity checks are reviewed; SOC-008 may consume already projected evidence with explicit provenance.

## Large estates

After the shared pause, retain the selected team slugs from the complete census, target label and anchor in a mode0600 worklist under the target's `runs/<fixed UTC run ID>/`. Check for a pending worklist before creating another. Resume only after matching the configured target/anchor and revalidating drift; never combine another account or stale roster generation. The report's observation window must include all completed batches.

Use the following **fixed** fresh-shell recipe for `init`, `batch`, or `finish`. Before `init`, set a unique `SCOUTFLO_RUN_ID` once and keep it for every later invocation; select optional `SCOUTFLO_TEAMS` as comma-separated exact slugs from the census. On a large run, supply the team set agreed at the checkpoint. `init` lists existing pending runs and refuses to create another until the operator explicitly chooses `SCOUTFLO_NEW_RUN=yes`. `batch` handles up to10 pending teams. `finish` verifies every selected row and its saved snapshot and emits the manifest the report must consume. These are local actions; the only remote operation is the read-only collector.

```bash
set -eu
umask 077
MODE="${SCOUTFLO_BATCH_MODE:-init}"
RUN_ID="${SCOUTFLO_RUN_ID:?set one fixed run ID and retain it across batches}"
SELECTED="${SCOUTFLO_TEAMS:-}"
case "$MODE" in init|batch|finish) ;; *) echo 'invalid batch mode'; exit 1 ;; esac
case "$RUN_ID" in *[!A-Za-z0-9_-]*|'') echo 'invalid run ID'; exit 1 ;; esac
PLAN=$(sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-splunk-oncall/scripts/collect.sh" --plan)
SOC_SEG=$(printf '%s' "$PLAN" | jq -er '.target')
BASE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${SOC_SEG}/runs"
RUN="$BASE/$RUN_ID"; WORK="$RUN/worklist.json"
mkdir -p "$BASE"
if [ "$MODE" = init ]; then
  for old in "$BASE"/*/worklist.json; do
    [ -f "$old" ] || continue
    if jq -e 'any(.teams[];.state=="pending")' "$old" >/dev/null; then
      echo "Pending run: $old"
      [ "${SCOUTFLO_NEW_RUN:-}" = yes ] || { echo 'Resume that run with batch mode, or explicitly choose a new run'; exit 1; }
    fi
  done
  mkdir "$RUN" || { echo 'Run already exists; choose batch/finish for that run'; exit 1; }
  printf '%s' "$PLAN" | jq --arg selection "$SELECTED" --arg run "$RUN_ID" '
    .team_slugs as $known | (if $selection=="" then $known else $selection|split(",")|unique end) as $wanted |
    if ($wanted|length)>0 and all($wanted[]; . as $t | $known|index($t)) then
      {run_id:$run,target:.target,anchor_team:.anchor_team,credential_refs:.credential_refs,scope:"selected-teams",teams:[$wanted[]|{slug:.,state:"pending"}]}
    else error("selected team missing or scope empty") end' > "$WORK"
  echo "Initialized worklist: $WORK"
  exit 0
fi
[ -d "$RUN" ] && [ ! -L "$RUN" ] && [ -f "$WORK" ] && [ ! -L "$WORK" ] || { echo 'Missing or unsafe worklist'; exit 1; }
mkdir "$RUN/lock" || { echo 'Another batch owns the lock; do not steal it by age'; exit 1; }
trap 'rmdir "$RUN/lock"' EXIT HUP INT TERM
jq -e --arg target "$SOC_SEG" --arg run "$RUN_ID" '.target==$target and .run_id==$run and (.teams|length)>0 and all(.teams[];(.slug|test("^[A-Za-z0-9_-]+$")) and (.state=="pending" or .state=="done"))' "$WORK" >/dev/null
# Every saved team must still occur in this freshly authenticated account census.
printf '%s\n' "$PLAN" "$(cat "$WORK")" | jq -se '.[0].team_slugs as $known | .[0].anchor_team==.[1].anchor_team and .[0].credential_refs==.[1].credential_refs and all(.[1].teams[];.slug as $t|$known|index($t))' >/dev/null
if [ "$MODE" = batch ]; then
  for team in $(jq -r '[.teams[]|select(.state=="pending")][0:10][].slug' "$WORK"); do
    TMP=$(mktemp "$RUN/.snapshot.XXXXXX")
    if sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-splunk-oncall/scripts/collect.sh" --team "$team" > "$TMP"; then
      jq -e --arg team "$team" --arg target "$SOC_SEG" '.scope==$team and .target==$target and .complete_reads==true' "$TMP" >/dev/null
      mv "$TMP" "$RUN/$team.json"
      NEXT=$(mktemp "$RUN/.worklist.XXXXXX")
      jq --arg team "$team" '.teams |= map(if .slug==$team then .state="done" else . end)' "$WORK" > "$NEXT"
      mv "$NEXT" "$WORK"
    else
      rm -f "$TMP"; echo 'Batch failed; remaining work stays pending'; exit 1
    fi
  done
else
  jq -e 'all(.teams[];.state=="done")' "$WORK" >/dev/null || { echo 'Pending work blocks completion'; exit 1; }
  for team in $(jq -r '.teams[].slug' "$WORK"); do
    [ -f "$RUN/$team.json" ] && [ ! -L "$RUN/$team.json" ] || { echo 'Completed snapshot missing'; exit 1; }
    jq -e --arg team "$team" --arg target "$SOC_SEG" '.scope==$team and .target==$target and .complete_reads==true' "$RUN/$team.json" >/dev/null
  done
  cat "$WORK"
fi
```

A scoped capture retains selected policy rows, intersecting routes and selected current users. A fanout route retains outside targets in `out_of_scope_policies`; never call them missing. This procedure cannot assess orphan routes with no selected policy target. State that limit and block the account-wide portion of SOC-001, even if all selected teams finished. The account anchor is revalidated by every census/collector invocation; a changed credential or anchor requires a fresh run, not reuse of the old worklist.

After completion, re-read current coverage before publishing and state the complete observation interval. Do not sum run-local route ordinals across snapshots or invent unique account totals. Build findings from stable policy/team/shift relationships, preserving each batch's evidence reference. Changes in roster/policies between batches are drift requiring refreshed evidence. Completed old snapshots are historical observations, not a current atomic picture. Never merge accounts or skip the zero-pending final check.

## Report validation

Author findings and the inventory from observed evidence using the parent skill's exact seven-check scoring contract. Use [report-template.md](../../../report-standard/report-template.md) for the Markdown spine. Derive the scorecard, inventory and lanes sections from their canonical JSON; do not duplicate evidence by hand. The renderer's HTML mode takes an explicit output-file argument.

This fresh-shell block selects the same target through the shared `report-standard/toolkit-targets.sh` used by the collection recipe. It requires an already authored report for the chosen date. It validates target identity, findings, deterministic report sections and HTML; failures block completion.

```bash
set -eu
PLAN=$(sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-splunk-oncall/scripts/collect.sh" --plan)
SOC_SEG=$(printf '%s' "$PLAN" | jq -er '.target')
RUN_DATE="${SCOUTFLO_RUN_DATE:-$(date -u +%Y-%m-%d)}"
printf '%s\n' "$RUN_DATE" | LC_ALL=C grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || { echo 'invalid run date'; exit 1; }
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${SOC_SEG}/${RUN_DATE}"
jq -e --arg target "$SOC_SEG" '.target==$target and .skill=="audit-splunk-oncall"' "$OUT/findings.json" >/dev/null
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-findings.sh" "$OUT/findings.json"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" html "$OUT/findings.json" "$OUT/report.html"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-report.sh" "$OUT/report.md"
```

Healthy result: findings and report validators both pass, report.html exists, the target matches the resolved connection, and assessment coverage/limitations are visible. A green validator establishes schema/reconciliation, not that the provider findings are true or that notification delivery occurred.
