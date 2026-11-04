#!/bin/sh
# Read-only collection workflow harness. Provider reads stay in fixed cookbook
# recipes; this file manages selected config, preflight and local evidence only.
set -eu

afc_fail() { printf 'alert-fatigue collection: %s\n' "$*" >&2; return 1; }
afc_hash() { shasum -a 256 < "$1" | awk '{print $1}'; }
afc_open() {
  AFC_PLAN="${1:?collection plan JSON}"
  AFC_ROOT="${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT}"
  AFC_AUDITS="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
  AFC_CONFIG="${SCOUTFLO_CONFIG:-$HOME/.scoutflo/toolkit.yaml}"
  [ -f "$AFC_CONFIG" ] || { afc_fail 'config missing; run /scoutflo:connect'; return 1; }
  jq -e --argjson now "$(date -u +%s)" '
    .schema=="scoutflo-fatigue-collection/v1"
    and (.run_id|type)=="string" and (.run_id|test("^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$"))
    and (.run_date|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
    and (.provider|test("^(aws|azure|gcp|grafana|sentry|datadog|pagerduty|splunk_oncall|zenduty|signoz|newrelic|groundcover|elk|prometheus|alertmanager|lgtm)$"))
    and (.target_label|type)=="string" and (.target_label|length)>0
    and (.window.start|type)=="number" and (.window.end|type)=="number" and .window.start>=0 and .window.start<.window.end and .window.end<=$now
    and (.window.description|type)=="string" and (.window.description|length)>0
    and (.identity.expected|type)=="string" and (.identity.expected|length)>0
    and (.identity.path|type)=="array" and (.identity.path|length)>0
    and all(.identity.path[]; type=="string" or type=="number")
    and (.limits.batch_size|type)=="number" and (.limits.batch_size|floor)==.limits.batch_size and .limits.batch_size>=1 and .limits.batch_size<=100
    and (.limits.max_pages|type)=="number" and (.limits.max_pages|floor)==.limits.max_pages and .limits.max_pages>=1 and .limits.max_pages<=1000
    and (.limits.page_size|type)=="number" and (.limits.page_size|floor)==.limits.page_size and .limits.page_size>=1 and .limits.page_size<=1000
    and (.objects|type)=="array" and (.objects|length)>0
    and all(.objects[]; (.job_id|test("^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$"))
      and (.object_id|type)=="string" and (.object_id|length)>0
      and (.object_kind|type)=="string" and (.object_kind|length)>0)
    and ([.objects[].job_id]|length)==([.objects[].job_id]|unique|length)
  ' "$AFC_PLAN" >/dev/null || { afc_fail 'invalid collection plan'; return 1; }
  AFC_PROVIDER=$(jq -r .provider "$AFC_PLAN")
  AFC_BLOCK="$AFC_PROVIDER"; [ "$AFC_BLOCK" != alertmanager ] || AFC_BLOCK=prometheus
  AFC_LABEL=$(jq -r .target_label "$AFC_PLAN")
  AFC_TT="$AFC_ROOT/report-standard/toolkit-targets.sh"
  afc_count=$(sh "$AFC_TT" "$AFC_CONFIG" "$AFC_BLOCK" count)
  AFC_INDEX=''; afc_matches=0; afc_i=0
  while [ "$afc_i" -lt "$afc_count" ]; do
    if [ "$(sh "$AFC_TT" "$AFC_CONFIG" "$AFC_BLOCK" label "$afc_i")" = "$AFC_LABEL" ]; then AFC_INDEX="$afc_i"; afc_matches=$((afc_matches+1)); fi
    afc_i=$((afc_i+1))
  done
  [ "$afc_matches" -eq 1 ] || { afc_fail 'target label must match exactly one configured target'; return 1; }
  AFC_CONFIG_KIND=$(sh "$AFC_TT" "$AFC_CONFIG" "$AFC_BLOCK" kind)
  AFC_TARGET="$AFC_PROVIDER"
  [ "$AFC_CONFIG_KIND" != seq ] || AFC_TARGET="$AFC_PROVIDER/$AFC_LABEL"
  AFC_RUN="$AFC_AUDITS/alert-fatigue/runs/$(jq -r .run_id "$AFC_PLAN")"
  umask 077; mkdir -p "$AFC_RUN"
  if [ ! -f "$AFC_RUN/plan.json" ] && [ -d "$AFC_RUN/jobs" ]; then
    afc_fail 'legacy run has evidence but no immutable plan; preserve it and choose a new run_id'; return 1
  fi
  afc_tmp=$(mktemp -d "$AFC_RUN/.open.XXXXXX")
  jq -S . "$AFC_PLAN" > "$afc_tmp/plan.json"
  printf '%s:\n' "$AFC_BLOCK" > "$afc_tmp/config.yaml"
  # Metadata and variable NAMES only. Never copy secret values or setup credentials.
  case "$AFC_PROVIDER" in
    aws) afc_keys='account_id region profile role_env tier';;
    azure) afc_keys='subscription_id tenant_id region tier';;
    gcp) afc_keys='project region credentials_env tier';;
    grafana) afc_keys='url token_env tier';;
    sentry) afc_keys='host org token_env tier';;
    datadog) afc_keys='site api_key_env app_key_env tier';;
    pagerduty) afc_keys='region token_env tier';;
    splunk_oncall) afc_keys='api_id_env api_key_env team_slug';;
    zenduty) afc_keys='token_env tier';;
    signoz) afc_keys='url api_key_env tier';;
    newrelic) afc_keys='account_id region api_key_env tier';;
    groundcover) afc_keys='api_url backend_id token_env tier';;
    elk) afc_keys='kibana_url token_env tier';;
    prometheus|alertmanager) afc_keys='url alertmanager_url token_env basic_user_env basic_pass_env';;
    lgtm) afc_keys='runtime_mode kubernetes_context prometheus_url prometheus_token_env alertmanager_url alertmanager_token_env vmalert_url vmalert_token_env';;
  esac
  for afc_key in $afc_keys; do
    afc_value=$(sh "$AFC_TT" "$AFC_CONFIG" "$AFC_BLOCK" get "$AFC_INDEX" "$afc_key")
    # Preserve the owning audit's historical single-map defaults only. A list
    # item must name its own credential; an explicit custom name never falls back.
    if [ -z "$afc_value" ] && [ "$AFC_CONFIG_KIND" = map ]; then
      case "$AFC_PROVIDER:$afc_key" in
        grafana:token_env) afc_value=GRAFANA_TOKEN;; sentry:token_env) afc_value=SENTRY_TOKEN;;
        pagerduty:token_env) afc_value=PAGERDUTY_TOKEN;; zenduty:token_env) afc_value=ZENDUTY_TOKEN;;
        elk:token_env) afc_value=KIBANA_API_KEY;; groundcover:token_env) afc_value=GROUNDCOVER_API_KEY;;
        signoz:api_key_env) afc_value=SIGNOZ_API_KEY;; newrelic:api_key_env) afc_value=NEW_RELIC_USER_API_KEY;;
        datadog:api_key_env) afc_value=DATADOG_API_KEY;; datadog:app_key_env) afc_value=DATADOG_APP_KEY;;
      esac
    fi
    [ -n "$afc_value" ] || continue
    case "$afc_key" in *_env) printf '%s' "$afc_value" | LC_ALL=C grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$' || { rm -rf "$afc_tmp"; afc_fail 'invalid credential variable name'; return 1; };; esac
    case "$afc_key" in *url)
      printf '%s' "$afc_value" | LC_ALL=C grep -Eq '^https?://[^/?#@[:space:]]+(/[^?#[:space:]]*)?$' || { rm -rf "$afc_tmp"; afc_fail 'base URL must not contain credentials, query, fragment or whitespace'; return 1; };; esac
    afc_yaml=$(printf '%s' "$afc_value" | jq -Rs .)
    printf '  %s: %s\n' "$afc_key" "$afc_yaml" >> "$afc_tmp/config.yaml"
    # Round-trip through the shared parser, including its no-yq fallback.
    [ "$(sh "$AFC_TT" "$afc_tmp/config.yaml" "$AFC_BLOCK" get 0 "$afc_key")" = "$afc_value" ] || { rm -rf "$afc_tmp"; afc_fail 'config projection cannot preserve this scalar'; return 1; }
  done
  printf '  cost_checks: false\n' >> "$afc_tmp/config.yaml"
  if [ "$AFC_PROVIDER" = lgtm ] && [ "$(sh "$AFC_TT" "$afc_tmp/config.yaml" lgtm get 0 runtime_mode)" = kubernetes ]; then
    afc_ctx=$(sh "$AFC_TT" "$afc_tmp/config.yaml" lgtm get 0 kubernetes_context)
    if [ -z "$afc_ctx" ] && [ "$(sh "$AFC_TT" "$AFC_CONFIG" lgtm kind)" = map ] && [ "$(sh "$AFC_TT" "$AFC_CONFIG" kubernetes count)" -eq 1 ]; then
      afc_ctx=$(sh "$AFC_TT" "$AFC_CONFIG" kubernetes get 0 context)
    fi
    [ -n "$afc_ctx" ] || { rm -rf "$afc_tmp"; afc_fail 'selected LGTM stack needs an unambiguous configured kubernetes context'; return 1; }
    printf 'kubernetes:\n  context: %s\n' "$(printf '%s' "$afc_ctx" | jq -Rs .)" >> "$afc_tmp/config.yaml"
  fi
  if [ -f "$AFC_RUN/plan.json" ]; then
    cmp -s "$afc_tmp/plan.json" "$AFC_RUN/plan.json" && cmp -s "$afc_tmp/config.yaml" "$AFC_RUN/config.yaml" || { rm -rf "$afc_tmp"; afc_fail 'run basis changed; preserve this run and choose a new run_id'; return 1; }
  else
    # Initialisation is exclusive; another session cannot overwrite the basis.
    mkdir "$AFC_RUN/.init-lock" 2>/dev/null || { rm -rf "$afc_tmp"; afc_fail 'run initialization already active'; return 1; }
    if [ -f "$AFC_RUN/plan.json" ]; then
      cmp -s "$afc_tmp/plan.json" "$AFC_RUN/plan.json" && cmp -s "$afc_tmp/config.yaml" "$AFC_RUN/config.yaml" || { rmdir "$AFC_RUN/.init-lock"; rm -rf "$afc_tmp"; afc_fail 'concurrent initialization used a different basis'; return 1; }
    else
      mv "$afc_tmp/config.yaml" "$AFC_RUN/config.yaml"
      mv "$afc_tmp/plan.json" "$AFC_RUN/plan.json"
    fi
    rmdir "$AFC_RUN/.init-lock"
  fi
  rm -rf "$afc_tmp"
  AFC_PLAN="$AFC_RUN/plan.json"
  AFC_BASIS="$(afc_hash "$AFC_PLAN")/$(afc_hash "$AFC_RUN/config.yaml")"
  mkdir -p "$AFC_RUN/jobs"
  printf 'collection target: %s; config: %s; run: %s\n' "$AFC_TARGET" "$AFC_CONFIG" "$AFC_RUN"
}

afc_get() { sh "$AFC_TT" "$AFC_RUN/config.yaml" "$AFC_BLOCK" get 0 "$1"; }
# Reload the named local store before EVERY provider-read block, not only doctor.
# No eval, shell tracing or token output. Callers use the variables only in the
# fixed provider headers in the cookbook; an unset named variable stops the call.
afc_load_auth() {
  afc_store="${SCOUTFLO_ENV_FILE:-$HOME/.scoutflo/env}"
  if [ -f "$afc_store" ]; then . "$afc_store"; fi
  AFC_TOKEN=''; AFC_API_KEY=''; AFC_APP_KEY=''; AFC_API_ID=''; AFC_BASIC_USER=''; AFC_BASIC_PASS=''
  AFC_PROMETHEUS_TOKEN=''; AFC_ALERTMANAGER_TOKEN=''; AFC_VMALERT_TOKEN=''
  for afc_pair in token_env:TOKEN api_key_env:API_KEY app_key_env:APP_KEY api_id_env:API_ID basic_user_env:BASIC_USER basic_pass_env:BASIC_PASS prometheus_token_env:PROMETHEUS_TOKEN alertmanager_token_env:ALERTMANAGER_TOKEN vmalert_token_env:VMALERT_TOKEN role_env:ROLE credentials_env:CREDENTIALS; do
    afc_key=${afc_pair%:*}; afc_name=$(afc_get "$afc_key"); [ -n "$afc_name" ] || continue
    afc_secret=$(printenv "$afc_name" 2>/dev/null || true)
    [ -n "$afc_secret" ] || { afc_fail "$afc_name is unset; run /scoutflo:connect"; return 1; }
    case "${afc_pair#*:}" in TOKEN) AFC_TOKEN=$afc_secret;; API_KEY) AFC_API_KEY=$afc_secret;; APP_KEY) AFC_APP_KEY=$afc_secret;; API_ID) AFC_API_ID=$afc_secret;; BASIC_USER) AFC_BASIC_USER=$afc_secret;; BASIC_PASS) AFC_BASIC_PASS=$afc_secret;; PROMETHEUS_TOKEN) AFC_PROMETHEUS_TOKEN=$afc_secret;; ALERTMANAGER_TOKEN) AFC_ALERTMANAGER_TOKEN=$afc_secret;; VMALERT_TOKEN) AFC_VMALERT_TOKEN=$afc_secret;; esac
  done
  case "$AFC_PROVIDER" in
    grafana|sentry|pagerduty|zenduty|groundcover|elk) [ -n "$AFC_TOKEN" ] || { afc_fail 'required token_env is absent'; return 1; };;
    datadog) [ -n "$AFC_API_KEY" ] && [ -n "$AFC_APP_KEY" ] || { afc_fail 'both Datadog key names are required'; return 1; };;
    signoz|newrelic) [ -n "$AFC_API_KEY" ] || { afc_fail 'api_key_env is required'; return 1; };;
    splunk_oncall) [ -n "$AFC_API_ID" ] && [ -n "$AFC_API_KEY" ] || { afc_fail 'both On-Call credential names are required'; return 1; };;
  esac
  if [ -n "$AFC_BASIC_USER$AFC_BASIC_PASS" ]; then
    [ -n "$AFC_BASIC_USER" ] && [ -n "$AFC_BASIC_PASS" ] || { afc_fail 'both basic auth names are required'; return 1; }
  fi
  afc_auth_binding "${1:-initialize}"
}

# Only a salted digest and random seed persist, both private to this run. The
# credential bytes flow through stdin, never a command argument or a file. NUL
# framing distinguishes names/values (environment values cannot contain NUL).
afc_auth_stream() {
  printf '%s\000%s\000' "$afc_auth_seed" "$AFC_BASIS"
  for afc_auth_key in token_env api_key_env app_key_env api_id_env basic_user_env basic_pass_env prometheus_token_env alertmanager_token_env vmalert_token_env role_env credentials_env; do
    afc_auth_name=$(afc_get "$afc_auth_key")
    [ -n "$afc_auth_name" ] || continue
    printf '%s\000%s\000' "$afc_auth_key" "$afc_auth_name"
    printenv "$afc_auth_name"
    printf '\000'
  done
}
afc_auth_refuse() {
  rm -f "$AFC_RUN/identity.json" "$AFC_RUN/preflight.json"
  afc_fail "$1; preserve this run and choose a new run_id"
}
afc_auth_binding() {
  afc_auth_dir="$AFC_RUN/.auth-binding"
  if [ ! -d "$afc_auth_dir" ]; then
    [ "$1" = initialize ] || { afc_auth_refuse 'credential binding missing'; return 1; }
    mkdir "$AFC_RUN/.auth-init-lock" 2>/dev/null || { afc_fail 'credential binding initialization already active'; return 1; }
    if [ ! -d "$afc_auth_dir" ]; then
      # Never backfill a missing binding around earlier attempts or completed jobs.
      if [ -n "$(find "$AFC_RUN/jobs" -mindepth 1 -print -quit)" ] || [ -e "$afc_auth_dir" ]; then
        rmdir "$AFC_RUN/.auth-init-lock"; afc_auth_refuse 'run has job evidence but no credential binding'; return 1
      fi
      afc_auth_tmp=$(mktemp -d "$AFC_RUN/.auth-init.XXXXXX")
      afc_auth_seed=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
      [ "${#afc_auth_seed}" -eq 64 ] || { rm -rf "$afc_auth_tmp"; rmdir "$AFC_RUN/.auth-init-lock"; afc_fail 'cannot initialize private credential binding'; return 1; }
      printf '%s\n' "$afc_auth_seed" > "$afc_auth_tmp/seed"
      AFC_AUTH_GENERATION=$(afc_auth_stream | shasum -a 256 | awk '{print $1}')
      jq -n --arg basis "$AFC_BASIS" --arg target "$AFC_TARGET" --arg digest "$AFC_AUTH_GENERATION" '{schema:"scoutflo-collection-auth/v1",basis:$basis,target:$target,digest:$digest}' > "$afc_auth_tmp/binding.json"
      mv "$afc_auth_tmp" "$afc_auth_dir"
    fi
    rmdir "$AFC_RUN/.auth-init-lock"
  fi
  [ -f "$afc_auth_dir/seed" ] && [ -f "$afc_auth_dir/binding.json" ] || { afc_auth_refuse 'credential binding is incomplete'; return 1; }
  afc_auth_seed=$(cat "$afc_auth_dir/seed")
  printf '%s' "$afc_auth_seed" | LC_ALL=C grep -Eq '^[a-f0-9]{64}$' || { afc_auth_refuse 'credential binding seed is invalid'; return 1; }
  AFC_AUTH_GENERATION=$(afc_auth_stream | shasum -a 256 | awk '{print $1}')
  jq -e --arg basis "$AFC_BASIS" --arg target "$AFC_TARGET" --arg digest "$AFC_AUTH_GENERATION" '.schema=="scoutflo-collection-auth/v1" and .basis==$basis and .target==$target and .digest==$digest' "$afc_auth_dir/binding.json" >/dev/null || { afc_auth_refuse 'selected credential generation changed or binding is invalid'; return 1; }
}

afc_preflight() {
  rm -f "$AFC_RUN/identity.json" "$AFC_RUN/preflight.json"
  afc_load_auth || return 1
  case "$AFC_PROVIDER" in
    aws) [ -n "$(afc_get profile)" ] && [ -n "$(afc_get region)" ] && [ -n "$(afc_get account_id)" ] || { afc_fail 'pin AWS profile, region and account_id before collection'; return 1; };;
    gcp) afc_config_name=$(jq -er '.cli_configuration|select(type=="string" and length>0)' "$AFC_PLAN") || { afc_fail 'pin cli_configuration for GCP; never activate shared defaults'; return 1; }
         export CLOUDSDK_ACTIVE_CONFIG_NAME="$afc_config_name";;
    azure) [ -n "$(afc_get subscription_id)" ] || { afc_fail 'pin Azure subscription_id'; return 1; };;
  esac
  # Only this projected provider/target reaches doctor, never unrelated stacks.
  afc_check=$(mktemp -d "$AFC_RUN/preflight.XXXXXX")
  if ! sh "$AFC_ROOT/skills/doctor/scripts/doctor.sh" --config "$AFC_RUN/config.yaml" --out "$afc_check" > "$afc_check/rows.jsonl"; then
    afc_fail "doctor failed; evidence retained in $afc_check"; return 1
  fi
  jq -se --arg provider "$AFC_BLOCK" '
    [ .[] | select(.configured=="yes" and (.integration==$provider or (.integration|startswith($provider+" (")))) ] as $rows
    | ($rows|length)>0 and any($rows[]; .result=="pass")
    and all($rows[]; .result=="pass" or .result=="skipped")
  ' "$afc_check/rows.jsonl" >/dev/null || { afc_fail 'doctor did not prove the selected target'; return 1; }
  jq -n --arg basis "$AFC_BASIS" --arg target "$AFC_TARGET" --arg generation "$AFC_AUTH_GENERATION" --argjson at "$(date -u +%s)" '{basis:$basis,target:$target,auth_generation:$generation,checked_at:$at}' > "$AFC_RUN/preflight.json"
}

# Run the owning audit's fixed identity read, then pass its safe JSON projection.
# The expected identity is pinned BEFORE the read in the immutable plan. The path
# is a JSON field path, not executable shell/JQ code. Empty/multiple values fail.
afc_verify_identity() {
  rm -f "$AFC_RUN/identity.json"
  afc_load_auth existing || return 1
  [ -f "$AFC_RUN/preflight.json" ] || { afc_fail 'run doctor first'; return 1; }
  jq -e --arg generation "$AFC_AUTH_GENERATION" '.auth_generation==$generation' "$AFC_RUN/preflight.json" >/dev/null || { afc_fail 'doctor credential generation is missing or different'; return 1; }
  afc_path=$(jq -c .identity.path "$AFC_PLAN")
  afc_expected=$(jq -r .identity.expected "$AFC_PLAN")
  afc_observed=$(jq -ser --argjson path "$afc_path" 'select(length==1) | .[0] | getpath($path) | select(type=="string" or type=="number") | tostring | select(length>0)' "$1") || { afc_fail 'identity response is empty, ambiguous or malformed'; return 1; }
  printf 'expected identity: %s; observed identity: %s; target: %s\n' "$afc_expected" "$afc_observed" "$AFC_TARGET"
  [ "$afc_observed" = "$afc_expected" ] || { afc_fail 'identity mismatch; stop and correct the selected target'; return 1; }
  jq --arg observed "$afc_observed" '. + {observed:$observed}' "$AFC_RUN/preflight.json" > "$AFC_RUN/identity.json"
}
afc_gate() {
  afc_load_auth existing || return 1
  [ -f "$AFC_RUN/identity.json" ] || { afc_fail 'live identity not verified'; return 1; }
  jq -e --arg basis "$AFC_BASIS" --arg target "$AFC_TARGET" --arg generation "$AFC_AUTH_GENERATION" --argjson now "$(date -u +%s)" '.basis==$basis and .target==$target and .auth_generation==$generation and .checked_at<=$now and ($now-.checked_at)<=300' "$AFC_RUN/identity.json" >/dev/null || { afc_fail 'preflight expired or belongs to another target; rerun it'; return 1; }
}

afc_next() {
  afc_gate || return 1
  afc_limit=$(jq -r .limits.batch_size "$AFC_PLAN"); afc_n=0
  for afc_job in $(jq -r '.objects[].job_id' "$AFC_PLAN"); do
    if [ -f "$AFC_RUN/jobs/$afc_job/complete.json" ]; then
      afc_receipt_ok "$afc_job" || return 1
      continue
    fi
    [ "$afc_n" -lt "$afc_limit" ] || break
    jq -c --arg id "$afc_job" '.objects[]|select(.job_id==$id)' "$AFC_PLAN"
    afc_n=$((afc_n+1))
  done
}
# Call before the provider read. Exit 3 means a verified result already exists;
# do not fetch it again. Concurrent sessions cannot claim the same pending job.
afc_claim() {
  afc_gate || return 1
  afc_claim_id="$1"
  jq -e --arg id "$afc_claim_id" '[.objects[]|select(.job_id==$id)]|length==1' "$AFC_PLAN" >/dev/null || { afc_fail 'unknown job'; return 1; }
  afc_claim_dir="$AFC_RUN/jobs/$afc_claim_id"; mkdir -p "$afc_claim_dir"
  if [ -f "$afc_claim_dir/complete.json" ]; then afc_receipt_ok "$afc_claim_id" || return 1; return 3; fi
  mkdir "$afc_claim_dir/.read-lock" 2>/dev/null || { afc_fail 'job already claimed; do not duplicate its provider read'; return 1; }
  printf '%s\n' "$$" > "$afc_claim_dir/.read-lock/owner"
  if [ -f "$afc_claim_dir/complete.json" ]; then afc_release "$afc_claim_id"; afc_receipt_ok "$afc_claim_id" || return 1; return 3; fi
}
afc_release() {
  afc_lock="$AFC_RUN/jobs/$1/.read-lock"
  [ -d "$afc_lock" ] || return 0
  [ "$(cat "$afc_lock/owner" 2>/dev/null || true)" = "$$" ] || { afc_fail 'claim belongs to another session; preserve it'; return 1; }
  rm -f "$afc_lock/owner"; rmdir "$afc_lock"
}

afc_receipt_ok() {
  afc_load_auth existing || return 1
  afc_dir="$AFC_RUN/jobs/$1"
  [ -f "$afc_dir/result.json" ] || { afc_fail 'completed job lost its result; preserve run for investigation'; return 1; }
  jq -e --arg basis "$AFC_BASIS" --arg generation "$AFC_AUTH_GENERATION" --arg hash "$(afc_hash "$afc_dir/result.json")" '.basis==$basis and .auth_generation==$generation and .result_hash==$hash' "$afc_dir/complete.json" >/dev/null || { afc_fail 'completed evidence changed; refusing silent reuse or re-pull'; return 1; }
}
# Commit only after the fixed read, pagination, field assertions and normalizer
# succeeded. A failed/partial read has no complete receipt and remains resumable.
afc_complete() {
  afc_gate || return 1
  afc_id="$1"; afc_result="$2"
  afc_object=$(jq -cer --arg id "$afc_id" '[.objects[]|select(.job_id==$id)]|select(length==1)|.[0]' "$AFC_PLAN") || { afc_fail 'unknown job'; return 1; }
  afc_dir="$AFC_RUN/jobs/$afc_id"
  [ ! -f "$afc_dir/complete.json" ] || { afc_receipt_ok "$afc_id"; return; }
  jq -e --argjson job "$afc_object" --arg target "$AFC_TARGET" --arg provider "$AFC_PROVIDER" --slurpfile plan "$AFC_PLAN" '
    .signal.provider==$provider and .signal.target==$target
    and .signal.object_id==$job.object_id and .signal.object_kind==$job.object_kind
    and .proof.window==$plan[0].window and .proof.response_assertions_passed==true
    and (.proof.method|type)=="string" and (.proof.method|length)>0
    and ((.signal|has("fires")|not) or (.proof.complete_window==true and .proof.count_semantics=="exact-events"))
  ' "$afc_result" >/dev/null || { afc_fail 'result lacks matching identity/window/verified measurement semantics'; return 1; }
  afc_candidate=$(mktemp "$AFC_RUN/.signals.XXXXXX")
  jq --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --slurpfile plan "$AFC_PLAN" '{schema:"scoutflo-fatigue-signals/v1",generated_at:$generated_at,window:$plan[0].window.description,signals:[.signal]}' "$afc_result" > "$afc_candidate"
  if ! sh "$AFC_ROOT/report-standard/check-fatigue-signals.sh" "$afc_candidate" "$AFC_AUDITS" "$(jq -r .run_date "$AFC_PLAN")"; then rm -f "$afc_candidate"; return 1; fi
  rm -f "$afc_candidate"
  mkdir -p "$afc_dir"; mkdir "$afc_dir/.lock" 2>/dev/null || { afc_fail 'job already active'; return 1; }
  if [ -f "$afc_dir/complete.json" ]; then rmdir "$afc_dir/.lock"; afc_receipt_ok "$afc_id"; return; fi
  cp "$afc_result" "$afc_dir/result.json"
  jq -n --arg basis "$AFC_BASIS" --arg hash "$(afc_hash "$afc_dir/result.json")" --arg generation "$AFC_AUTH_GENERATION" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{basis:$basis,auth_generation:$generation,result_hash:$hash,completed_at:$at}' > "$afc_dir/complete.tmp"
  mv "$afc_dir/complete.tmp" "$afc_dir/complete.json"; rmdir "$afc_dir/.lock"
}
afc_assemble() {
  afc_load_auth existing || return 1
  afc_files=''; set --
  for afc_job in $(jq -r '.objects[].job_id' "$AFC_PLAN"); do
    [ -f "$AFC_RUN/jobs/$afc_job/complete.json" ] || { afc_fail 'unfinished jobs remain; keep worklist and resume before publishing'; return 1; }
    afc_receipt_ok "$afc_job" || return 1
    set -- "$@" "$AFC_RUN/jobs/$afc_job/result.json"
  done
  afc_candidate=$(mktemp "$AFC_RUN/.assembled.XXXXXX")
  jq -s --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg window "$(jq -r .window.description "$AFC_PLAN")" --arg provider "$AFC_PROVIDER" --arg target "$AFC_TARGET" '{schema:"scoutflo-fatigue-signals/v1",generated_at:$generated_at,window:$window,signals:map(.signal),provider_coverage:[{provider:$provider,target:$target,tier:"fire-history",status:"collected",objects:length,reason:(if all(.[]; .proof.count_semantics=="sampled-state-values") then "Sampled state observations only; exact fire counts, episode counts, continuity and delivery remain unavailable" else null end),verification:(if all(.[]; .proof.verification=="live-verified") then "live-verified" else "spec-only" end)}]}' "$@" > "$afc_candidate"
  if ! sh "$AFC_ROOT/report-standard/check-fatigue-signals.sh" "$afc_candidate" "$AFC_AUDITS" "$(jq -r .run_date "$AFC_PLAN")"; then rm -f "$afc_candidate"; return 1; fi
  mv "$afc_candidate" "$AFC_RUN/fatigue-signals.json"
  printf 'validated signal fragment: %s/fatigue-signals.json\n' "$AFC_RUN"
}

# Normalize bounded Prometheus sampled state, not exact notification/fire history.
# Distinct active-since values are observations, not episode counts: restoration
# may adjust them and sampling may miss changes. Deduplicate HA copies.
afc_prometheus_result() {
  afc_job=$(jq -cer --arg id "$1" '[.objects[]|select(.job_id==$id)]|select(length==1)|.[0]' "$AFC_PLAN") || return 1
  jq -e --arg target "$AFC_TARGET" --argjson job "$afc_job" --slurpfile plan "$AFC_PLAN" '
    $plan[0] as $p
    | select(.status=="success" and .data.resultType=="matrix")
    | select(((.warnings // [])|length)==0)
    | select((.data.result|type)=="array" and (.data.result|length)<$p.limits.page_size)
    | select(all(.data.result[];
        .metric.alertname==$job.object_id and (.values|type)=="array"
        and all(.values[]; type=="array" and length==2
          and (.[0]|type)=="number" and .[0]>=$p.window.start and .[0]<=$p.window.end
          and (.[1]|type)=="string" and (try (.[1]|tonumber) catch -1)>0
          and (try (.[1]|tonumber) catch -1)<=.[0])))
    | [.data.result[].values[] | .[1]|tonumber] | unique as $starts
    | {signal:{provider:"prometheus",target:$target,object_id:$job.object_id,
         object_kind:$job.object_kind,source_finding_ids:($job.source_finding_ids // []),
         distinct_active_since_values:($starts|length),
         measurement_note:"Distinct active-since values observed while firing in the sampled window; restoration can adjust them and sampling can miss changes. This is not an episode count, exact fires, continuous stuck duration or notification delivery"},
       proof:{window:$p.window,response_assertions_passed:true,
         method:"bounded ALERTS_FOR_STATE sampled only while ALERTS is firing",
         complete_window:false,count_semantics:"sampled-state-values"}}
  '
}
