#!/bin/sh
# test-store-token-import.sh: a step that needs a secret reads exactly that secret from the secret
# store, and nothing else (CONTRACTS C13).
#
# Each command block runs in a fresh shell, so the doctor gate's load of the store never carried
# over: a token kept only in the store passed the doctor and read as "not set" in the next step.
# Now, in the audits, the maps, rca, migration-plan and setup-sentry:
#   - a step that reads a secret by its default name (the *_env defaults in the config template,
#     or doctl, which reads DIGITALOCEAN_ACCESS_TOKEN itself) takes it from the variable the single
#     config block names, read from the store or the shell, and leaves it unset when that variable
#     is unset; when the config names no variable, the step behaves exactly as before;
#   - on a list of targets that each name their own variable, that step stops instead of guessing;
#   - a step that reads `printenv "$<name variable>"` reads that variable from the store or the shell.
# Nothing else in the store (report folder, kubeconfig, another environment's secrets) enters a step.
#
# Test 1 checks every in-scope block; the others run published preludes against fixtures.
# Read-only; POSIX sh + awk.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/store-token-import.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

# default secret name -> config block and key, from the config template (identity selectors and
# the Slack webhook left out: their steps keep reading the shell only)
MAP="$(awk '/^[a-z_]+:/ { blk = $1; sub(":", "", blk) }
  match($0, /[a-z_]+_env: [A-Z][A-Z0-9_]+/) { kv = substr($0, RSTART, RLENGTH); split(kv, a, ": ")
    if (blk != "" && !(a[2] in seen)) { seen[a[2]] = 1; printf "%s:%s:%s ", a[2], blk, a[1] } }' "$ROOT/templates/toolkit.yaml.example" \
  | tr ' ' '\n' | grep -vE '^(AWS_ROLE_ARN|GOOGLE_APPLICATION_CREDENTIALS|HDX_EU_KEY|HDX_US_KEY|SCOUTFLO_SLACK_WEBHOOK):' | tr '\n' ' ')"
[ -n "$MAP" ] || fail "no *_env defaults found in templates/toolkit.yaml.example"
FETCH="printenv -- \"\$2\"' _ \"\$SCOUTFLO_ENV\""

echo "=== secret-store token import ==="

echo "Test 1: every secret read in an in-scope step takes its value from the store, and only that value"
find "$ROOT/skills" -name '*.md' | sort > "$WORK/files"
: > "$WORK/bad"; READS=0; IND=0
while IFS= read -r f; do
  skill="${f#"$ROOT"/skills/}"; skill="${skill%%/*}"
  case "$skill" in audit-*|map-topology|map-repos|rca|migration-plan|setup-sentry) ;; *) continue ;; esac
  out="$(awk -v map="$MAP" -v fname="${f#"$ROOT"/}" -v skill="$skill" -v fetch="$FETCH" '
    BEGIN { n = split(map, M, " "); for (i = 1; i <= n; i++) { split(M[i], p, ":"); blk[p[1]] = p[2]; key[p[1]] = p[3] }
            split("loki tempo mimir prometheus victoriametrics", S, " "); for (i in S) lgs[S[i]] = 1
            lgk["LOKI_TOKEN"] = "loki_token_env"; lgk["TEMPO_TOKEN"] = "tempo_token_env"; lgk["MIMIR_TOKEN"] = "mimir_token_env"
            lgk["VM_TOKEN"] = "victoriametrics_token_env"; lgk["PROM_TOKEN"] = "prometheus_token_env" }
    function strip(l,   out, i, c, q) {
      out = ""; q = ""
      for (i = 1; i <= length(l); i++) {
        c = substr(l, i, 1)
        if (q != "") { out = out c; if (c == "\\" && q == "\"") { i++; out = out substr(l, i, 1) } else if (c == q) q = ""; continue }
        if (c == "\"" || c == "\047") { q = c; out = out c; continue }
        if (c == "#" && (i == 1 || substr(l, i - 1, 1) ~ /[ \t;]/)) break
        out = out c
      }
      return out
    }
    function report(msg) { print "U " fname ":" start " " msg }
    /^[ \t]*```(bash|sh)[ \t]*$/ { inb = 1; start = FNR; nl = 0; next }
    inb && /^[ \t]*```[ \t]*$/ {
      inb = 0; ladder = 0; whole = 0; split("", asg); split("", lst); split("", bnd); doclose = 0
      for (i = 1; i <= nl; i++) {
        l = strip(L[i])
        if (index(l, "SCOUTFLO_ENV=\"${SCOUTFLO_ENV_FILE:-}\"")) ladder = 1
        if (!whole && l ~ /(^|[;&| \t{])\.[ \t]+("\$SCOUTFLO_ENV"|"?(\$HOME|~|\$\{HOME\})\/\.scoutflo\/env)/) whole = 1
        if (match(l, /"\$_SF_CFG" [a-z_]+ get "\$_sf_i" [a-z_]+_env/) && l ~ /exit 1/) { g = substr(l, RSTART + 10, RLENGTH - 10); split(g, gg, " "); lst[gg[1] ":" gg[4]] = 1 }
        if (match(l, /"\$_SF_CFG" [a-z_]+ get 0 [a-z_]+_env 2>/) && index(l, fetch) && match(l, /then [A-Z][A-Z0-9_]+="\$_sf_v"/)) {
          v = substr(l, RSTART + 5, RLENGTH - 5); sub(/=.*/, "", v)
          if (match(l, /"\$_SF_CFG" [a-z_]+ get 0 [a-z_]+_env/)) { bk = substr(l, RSTART + 10, RLENGTH - 10); split(bk, bb, " "); bnd[v] = bb[1] ":" bb[4] }
        }
        if (index(l, "doctl would otherwise act as its own saved login")) doclose = 1
        # indirect reads of a named variable
        s = l
        while (match(s, /printenv[ \t]+"\$[A-Za-z_][A-Za-z0-9_]*"/)) {
          nm = substr(s, RSTART, RLENGTH); sub(/^printenv[ \t]+"\$/, "", nm); sub(/"$/, "", nm); s = substr(s, RSTART + RLENGTH)
          if (nm ~ /^(GCP_CRED_VAR|SLACK_URL_ENV|WEBHOOK_ENV|_sf_tv)$/) continue
          if (!whole) { report("reads $" nm " with plain printenv, so a value kept only in the store is never seen"); nind++ }
        }
        if (index(l, fetch)) nind++
        # default-name reads
        reads = ""; s = l
        while (match(s, /\$\{?[A-Za-z_][A-Za-z0-9_]*/)) { nm = substr(s, RSTART, RLENGTH); sub(/^\$\{?/, "", nm); if ((nm in blk) && !(nm in asg)) reads = reads " " nm; s = substr(s, RSTART + RLENGTH) }
        isdoctl = (l ~ /(^|[;&|(`]|\$\(|(then|do|else)[ \t])[ \t]*([A-Z_]+=[^ \t]*[ \t]+)*doctl[ \t]+/ && l !~ /doctl[ \t]+-?-?version/ && !("DIGITALOCEAN_ACCESS_TOKEN" in asg))
        if (isdoctl) reads = reads " DIGITALOCEAN_ACCESS_TOKEN"
        nr = split(reads, R, " ")
        for (r = 1; r <= nr; r++) {
          v = R[r]; nreads++; b = blk[v]; k = key[v]
          if (skill == "audit-lgtm" && (b in lgs)) { g = "lgtm"; ki = (v in lgk) ? lgk[v] : "" }
          else if (skill == "audit-lgtm" && v == "GRAFANA_TOKEN") { g = b; ki = "" }
          else { g = b; ki = k }
          if (!ladder) report("reads " v " before resolving the secret store")
          if (bnd[v] != b ":" k) report("reads " v " without first taking it from " b "." k " (found: " (bnd[v] == "" ? "none" : bnd[v]) ")")
          if (ki != "" && !((g ":" ki) in lst)) report("reads " v " with no stop for a list of " g " targets that name their own " ki)
          if (isdoctl && v == "DIGITALOCEAN_ACCESS_TOKEN" && !doclose) report("runs doctl with no stop when the configured token is unset")
        }
        # a bind line assigns only conditionally, so it is not an assignment here
        s = (l ~ /^[ \t]*_sf_tv=/) ? "" : l
        while (match(s, /(^|[;&|( {\t])(export[ \t]+|local[ \t]+|readonly[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/)) { a = substr(s, RSTART, RLENGTH); sub(/=$/, "", a); sub(/.*[ \t;&|({]/, "", a); asg[a] = 1; s = substr(s, RSTART + RLENGTH) }
      }
      next
    }
    inb { L[++nl] = $0 }
    END { print "N " nreads + 0 " " nind + 0 }' "$f")"
  printf '%s\n' "$out" | sed -n 's/^U //p' >> "$WORK/bad"
  set -- $(printf '%s\n' "$out" | sed -n 's/^N //p')
  READS=$((READS + $1)); IND=$((IND + $2))
done < "$WORK/files"
[ "$READS" -gt 100 ] || fail "found only ${READS} default-name secret reads; the scan is not matching the published blocks"
[ "$IND" -gt 10 ] || fail "found only ${IND} store-aware named reads; the scan is not matching the published blocks"
if [ -s "$WORK/bad" ]; then sed 's/^/  /' "$WORK/bad" | head -40 >&2; fail "$(wc -l < "$WORK/bad" | tr -d ' ') problems"; fi
echo "PASS (${READS} default-name reads take their value from the configured variable; ${IND} named reads see the store)"

# prelude <file> <check-text>: the published lines from the store ladder through the last bind (or
# doctl stop) of the first block that contains <check-text>
prelude() {
  awk -v want="$2" '/^```bash/ { n = 0; inb = 1; hit = 0; next } /^```/ { if (inb && hit) exit; inb = 0; next }
    inb { L[++n] = $0; if (index($0, want)) hit = 1 }
    END { s = 0; e = 0; for (i = 1; i <= n; i++) { if (!s && index(L[i], "SCOUTFLO_ENV=\"${SCOUTFLO_ENV_FILE:-}\"")) s = i
            if (index(L[i], "_sf_tv=") || index(L[i], "doctl would otherwise act as its own saved login")) e = i }
          if (s && e) for (i = s; i <= e; i++) print L[i] }' "$1"
}
mkdir -p "$WORK/home/.scoutflo" "$WORK/cwd" "$WORK/proj/.scoutflo"
# run <script> <store file or ""> <config file> [VAR=value ...]: a fresh, clean environment
run() {
  _s="$1"; _st="$2"; _c="$3"; shift 3
  ( cd "${RUN_CWD:-$WORK/cwd}" && env -i PATH="$PATH" HOME="$WORK/home" SCOUTFLO_ENV_FILE="$_st" SCOUTFLO_CONFIG="$_c" \
      CLAUDE_PLUGIN_ROOT="$ROOT" SCOUTFLO_AUDIT_DIR=/caller/folder "$@" sh "$_s" ) < /dev/null 2>&1
}

echo "Test 2: a published PagerDuty prelude takes only the configured token from the store"
prelude "$ROOT/skills/audit-pagerduty/references/pagerduty-checks.md" '"$_SF_CFG" pagerduty get 0 token_env' > "$WORK/pd-pre.sh"
grep -q 'pagerduty get "$_sf_i" token_env' "$WORK/pd-pre.sh" && grep -q 'pagerduty get 0 token_env' "$WORK/pd-pre.sh" || fail "could not extract the pagerduty prelude"
{ echo 'set -eu'; cat "$WORK/pd-pre.sh"; echo 'echo "token: ${PAGERDUTY_TOKEN-<unset>} dir: ${SCOUTFLO_AUDIT_DIR}"'; } > "$WORK/pd.sh"
printf 'pagerduty:\n  token_env: PAGERDUTY_TOKEN\n' > "$WORK/pd-default.yaml"
printf 'pagerduty:\n  token_env: PD_RO\n' > "$WORK/pd-custom.yaml"
printf 'pagerduty:\n  region: us\n' > "$WORK/pd-nokey.yaml"
printf 'pagerduty:\n  - label: prod\n    token_env: PAGERDUTY_TOKEN\n  - label: eu\n    token_env: PD_EU\n' > "$WORK/pd-list.yaml"
printf 'pagerduty:\n  - label: prod\n    region: us\n  - label: eu\n    region: eu\n' > "$WORK/pd-list-nokey.yaml"
printf "export PAGERDUTY_TOKEN='from-store'\nexport SCOUTFLO_AUDIT_DIR=/store/folder\n" > "$WORK/store-a"
printf "export PAGERDUTY_TOKEN='another-account'\nexport PD_RO='the-configured-one'\n" > "$WORK/store-b"
printf "export PAGERDUTY_TOKEN='another-account'\n" > "$WORK/store-c"
printf "export PAGERDUTY_TOKEN='from-project'\n" > "$WORK/proj/.scoutflo/env"
printf "export PAGERDUTY_TOKEN='from-home'\n" > "$WORK/home/.scoutflo/env"
printf "export BROKEN=abc d-SECRETPART\nexport PD_RO='the-configured-one'\n" > "$WORK/store-bad"
x() { [ "$2" = "$3" ] || fail "$1: expected [$2], got [$3]"; }
x "store file named by SCOUTFLO_ENV_FILE" "token: from-store dir: /caller/folder" "$(run "$WORK/pd.sh" "$WORK/store-a" "$WORK/pd-default.yaml")"
x "project-local store" "token: from-project dir: /caller/folder" "$(RUN_CWD="$WORK/proj" run "$WORK/pd.sh" "" "$WORK/pd-default.yaml")"
x "home store, last on the ladder" "token: from-home dir: /caller/folder" "$(run "$WORK/pd.sh" "" "$WORK/pd-default.yaml")"
x "store value wins over the shell, as in the doctor" "token: from-store dir: /caller/folder" "$(run "$WORK/pd.sh" "$WORK/store-a" "$WORK/pd-default.yaml" PAGERDUTY_TOKEN=from-shell)"
x "the variable token_env names" "token: the-configured-one dir: /caller/folder" "$(run "$WORK/pd.sh" "$WORK/store-b" "$WORK/pd-custom.yaml" PAGERDUTY_TOKEN=from-shell)"
x "configured variable unset: no other credential" "token: <unset> dir: /caller/folder" "$(run "$WORK/pd.sh" "$WORK/store-c" "$WORK/pd-custom.yaml" PAGERDUTY_TOKEN=from-shell)"
x "config names no variable: as before" "token: from-shell dir: /caller/folder" "$(run "$WORK/pd.sh" "$WORK/store-a" "$WORK/pd-nokey.yaml" PAGERDUTY_TOKEN=from-shell)"
x "no config: as before" "token: <unset> dir: /caller/folder" "$(run "$WORK/pd.sh" "$WORK/store-a" "$WORK/none.yaml")"
x "a list whose targets name no variable: as before" "token: from-shell dir: /caller/folder" "$(run "$WORK/pd.sh" "$WORK/store-a" "$WORK/pd-list-nokey.yaml" PAGERDUTY_TOKEN=from-shell)"
if out="$(run "$WORK/pd.sh" "$WORK/store-a" "$WORK/pd-list.yaml")"; then fail "a list of targets with their own token_env did not stop the step (output: $out)"; fi
printf '%s\n' "$out" | grep -q 'pagerduty in .* is a list of targets that each name their own token_env' || fail "the stop on a list does not say why: $out"
out="$(run "$WORK/pd.sh" "$WORK/store-bad" "$WORK/pd-custom.yaml")" || fail "a malformed store line ended the step: $out"
printf '%s\n' "$out" | grep -q 'SECRETPART' && fail "a malformed store line printed part of its value: $out"
# sh and bash read past the bad line; dash stops reading the store there, so the token stays unset
# (the step fails closed and the doctor names the bad line). Either way the step itself carries on.
case "$out" in "token: the-configured-one dir: /caller/folder"|"token: <unset> dir: /caller/folder") ;; *) fail "a malformed store line broke the step: $out" ;; esac
{ echo 'set -eu'; cat "$WORK/pd-pre.sh"; echo 'echo "${PAGERDUTY_TOKEN}"'; } > "$WORK/pd-u.sh"
run "$WORK/pd-u.sh" "$WORK/store-c" "$WORK/pd-custom.yaml" > /dev/null && fail "an unset configured token no longer stops a set -u step"
echo "PASS"

echo "Test 3: a published Datadog prelude binds both keys from their own variables"
prelude "$ROOT/skills/audit-datadog/references/datadog-checks.md" '"$_SF_CFG" datadog get 0 app_key_env' > "$WORK/dd-pre.sh"
grep -q 'datadog get 0 api_key_env' "$WORK/dd-pre.sh" || fail "could not extract a datadog prelude with both keys"
{ echo 'set -eu'; cat "$WORK/dd-pre.sh"; echo 'echo "api=${DATADOG_API_KEY-<unset>} app=${DATADOG_APP_KEY-<unset>}"'; } > "$WORK/dd.sh"
printf 'datadog:\n  site: datadoghq.com\n  api_key_env: DD_RO_API\n  app_key_env: DD_RO_APP\n' > "$WORK/dd.yaml"
printf "export DATADOG_API_KEY=wrong-api\nexport DATADOG_APP_KEY=wrong-app\nexport DD_RO_API=right-api\nexport DD_RO_APP=right-app\n" > "$WORK/store-dd"
x "datadog key pair" "api=right-api app=right-app" "$(run "$WORK/dd.sh" "$WORK/store-dd" "$WORK/dd.yaml")"
echo "PASS"

echo "Test 4: a published doctl prelude stops when the configured token is unset, so doctl never uses its own login"
prelude "$ROOT/skills/audit-cost/references/digitalocean-cost.md" 'doctl would otherwise act as its own saved login' > "$WORK/do-pre.sh"
grep -q 'digitalocean get 0 token_env' "$WORK/do-pre.sh" || fail "could not extract a doctl prelude"
{ echo 'set -eu'; cat "$WORK/do-pre.sh"; echo 'echo "do=${DIGITALOCEAN_ACCESS_TOKEN-<unset>}"'; } > "$WORK/do.sh"
printf 'digitalocean:\n  token_env: DO_RO\n' > "$WORK/do.yaml"
printf "export DO_RO=right-do\n" > "$WORK/store-do"
x "doctl token from its variable" "do=right-do" "$(run "$WORK/do.sh" "$WORK/store-do" "$WORK/do.yaml" DIGITALOCEAN_ACCESS_TOKEN=from-shell)"
if out="$(run "$WORK/do.sh" "$WORK/store-c" "$WORK/do.yaml" DIGITALOCEAN_ACCESS_TOKEN=from-shell)"; then fail "doctl ran with the configured token unset (output: $out)"; fi
printf '%s\n' "$out" | grep -q 'DO_RO is not set' || fail "the doctl stop does not name the variable: $out"
echo "PASS"

echo "Test 5: audit-lgtm's store tokens follow the stack list"
prelude "$ROOT/skills/audit-lgtm/references/backend-checks.md" '"$_SF_CFG" loki get 0 token_env' > "$WORK/lg-pre.sh"
grep -q 'lgtm get "$_sf_i" loki_token_env' "$WORK/lg-pre.sh" || fail "could not extract an audit-lgtm prelude with the loki token"
{ echo 'set -eu'; cat "$WORK/lg-pre.sh"; echo 'echo "loki=${LOKI_TOKEN-<unset>}"'; } > "$WORK/lg.sh"
printf "export LOKI_TOKEN='another-stack'\nexport LOKI_RO='the-configured-one'\n" > "$WORK/store-l"
printf 'lgtm:\n  runtime_mode: external\nloki:\n  url: https://loki.example.com\n  token_env: LOKI_RO\n' > "$WORK/lg-single.yaml"
printf 'lgtm:\n  - label: prod\n    runtime_mode: external\n    loki_url: https://a.example.com\n  - label: preprod\n    runtime_mode: external\n    loki_url: https://b.example.com\n' > "$WORK/lg-open.yaml"
printf 'lgtm:\n  - label: prod\n    runtime_mode: external\n    loki_url: https://a.example.com\n    loki_token_env: LOKI_A\n  - label: preprod\n    runtime_mode: external\n    loki_url: https://b.example.com\n' > "$WORK/lg-tok.yaml"
x "single stack: loki.token_env" "loki=the-configured-one" "$(run "$WORK/lg.sh" "$WORK/store-l" "$WORK/lg-single.yaml")"
x "stack list with open stores: as before" "loki=<unset>" "$(run "$WORK/lg.sh" "$WORK/store-l" "$WORK/lg-open.yaml")"
if out="$(run "$WORK/lg.sh" "$WORK/store-l" "$WORK/lg-tok.yaml")"; then fail "a stack list with its own loki_token_env did not stop (output: $out)"; fi
printf '%s\n' "$out" | grep -q 'lgtm in .* is a list of targets that each name their own loki_token_env' || fail "audit-lgtm's stop does not say why: $out"
echo "PASS"

echo "STORE-TOKEN-IMPORT-OK"
