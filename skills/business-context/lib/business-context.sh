#!/bin/sh
# business-context.sh
# Capture rich business context into the SSOT markdown file
# ~/.scoutflo/business_context.md, then derive a machine projection
# (~/.scoutflo/business_context.json) that the shell libs read.
#
# business_context.md is the human-authored source of truth. The .json is a
# derived cache — never hand-edited, always regenerated from the .md.
#
# Four capture modes, offered in order (any subset; all optional past the core):
#   1. core        — the always-asked essentials (team, primary environment, cost sensitivity)
#   2. guided       — structured rich questions (per-service SLA, per-env profile/cluster map, critical services, exclusions)
#   3. paste        — free-form custom rules / runbooks pasted inline
#   4. import       — point at an existing file to adopt or reference
set -eu

SCOUTFLO_DIR="${HOME}/.scoutflo"
SSOT_MD="${SCOUTFLO_DIR}/business_context.md"
SSOT_JSON="${SCOUTFLO_DIR}/business_context.json"
TEMPLATE="${CLAUDE_PLUGIN_ROOT:-.}/templates/business_context_template.md"

bc_init_dir() { mkdir -p "$SCOUTFLO_DIR"; }

# --- Mode 4: import an existing business-context file -------------------------
# Adopt the user's own file as the SSOT (copy it in), or reference it. Validates
# it against the section gate before adopting so a malformed import is caught.
bc_import_file() {
  src="$1"
  [ -f "$src" ] || { echo "no such file: $src"; return 1; }
  bc_init_dir
  cp "$src" "$SSOT_MD"
  echo "[imported] copied $src -> $SSOT_MD"
  bc_validate "$SSOT_MD" || { echo "[warn] imported file is missing required sections; edit $SSOT_MD or re-run guided capture to fill them"; }
  bc_derive_json
}

# --- Mode 3: append a free-form custom-rules / runbook block ------------------
# Reads a heredoc-style paste from stdin and appends it under Custom Rules.
bc_append_custom() {
  bc_init_dir
  [ -f "$SSOT_MD" ] || bc_scaffold_from_template
  block="$(cat)"   # caller pipes the pasted text in
  [ -n "$block" ] || { echo "[skip] nothing pasted"; return 0; }
  {
    printf '\n## Custom Rules (added %s)\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"
    printf '%s\n' "$block"
  } >> "$SSOT_MD"
  echo "[saved] appended custom rules to $SSOT_MD"
  bc_derive_json
}

# --- Scaffold the SSOT from the shipped template (starting point) -------------
bc_scaffold_from_template() {
  bc_init_dir
  if [ -f "$TEMPLATE" ]; then
    cp "$TEMPLATE" "$SSOT_MD"
  else
    # minimal valid skeleton if the template is somehow absent
    {
      printf '# Business Context\n\n## Environment\n\n- **Stage:** production\n\n'
      printf '## Cost Sensitivity\n\n- **Primary:** medium\n'
    } > "$SSOT_MD"
  fi
  echo "[scaffold] wrote a starting $SSOT_MD from the template"
}

# --- Validate the SSOT against the shipped section gate -----------------------
# Delegates to ci/validate-business-context.sh so the skill and CI agree.
bc_validate() {
  f="${1:-$SSOT_MD}"
  gate="${CLAUDE_PLUGIN_ROOT:-.}/ci/validate-business-context.sh"
  if [ -f "$gate" ]; then
    sh "$gate" "$f"
  else
    # inline fallback matching the shipped gate's hard requirements
    [ -f "$f" ] || { echo "no $f"; return 1; }
    grep -qE '^## Environment' "$f" || { echo "missing ## Environment"; return 1; }
    grep -qE '^## Cost Sensitivity' "$f" || { echo "missing ## Cost Sensitivity"; return 1; }
    grep -A3 -E '^## Cost Sensitivity' "$f" | grep -qi 'Primary:' || { echo "missing Primary: under Cost Sensitivity"; return 1; }
    echo "business_context.md: valid"
  fi
}

# --- Parse one Exclusions subsection into a JSON string array -----------------
# Slices the "## Exclusions" section, then the given "### <name>" subsection
# (Regions / Accounts / Services / Resources), and returns its bullet values as
# a JSON array — reason parentheticals stripped, bracketed placeholders dropped.
# Same idiom as the critical-services / environment-map parsers below.
bc_exclusion_list() {
  awk -v want="$1" '
    /^## Exclusions/{inx=1; next}
    inx && /^## /{inx=0}
    inx && /^### /{cur=$0; sub(/^### /,"",cur); insub=(cur ~ ("^" want))?1:0; next}
    inx && insub && /^-[[:space:]]/{print}
  ' "$SSOT_MD" \
    | sed -E 's/^-[[:space:]]*//; s/[[:space:]]*\(reason:.*$//; s/[[:space:]]*$//' \
    | jq -R . | jq -s 'map(select(length>0 and (test("^\\[")|not)))' 2>/dev/null || echo '[]'
}

# --- Derive the machine projection the shell libs read ------------------------
# business_context.json holds the structured fields the libs consume
# (environment, cost_sensitivity, critical_dependencies, per-env SLA map,
# per-service SLAs, and exclusions). It is ALWAYS regenerated from the .md;
# never hand-edited.
bc_derive_json() {
  [ -f "$SSOT_MD" ] || { echo "no SSOT to derive from"; return 1; }
  bc_init_dir

  stage="$(grep -iA5 '^## Environment' "$SSOT_MD" | grep -iE 'Stage:' | head -1 | sed -E 's/.*Stage:\**[[:space:]]*//; s/[][]//g; s/[[:space:]]*$//' | tr 'A-Z' 'a-z')"
  case "$stage" in prod|production) stage="production" ;; staging) stage="staging" ;; dev|development) stage="dev" ;; dr) stage="dr" ;; *) stage="production" ;; esac

  cost="$(grep -iA3 '^## Cost Sensitivity' "$SSOT_MD" | grep -iE 'Primary:' | head -1 | sed -E 's/.*Primary:\**[[:space:]]*//; s/[][]//g; s/[[:space:]]*$//' | tr 'A-Z' 'a-z')"
  case "$cost" in high) cost="high" ;; low) cost="low" ;; *) cost="medium" ;; esac

  # Critical services: bullet lines under "## Critical Services", first backtick-quoted token per line.
  crit="$(awk '/^## Critical Services/{f=1;next} /^## /{f=0} f' "$SSOT_MD" \
    | grep -oE '`[^`]+`' | head -50 | sed 's/`//g' \
    | jq -R . | jq -s 'map(select(length>0 and (test("^\\[")|not)))' 2>/dev/null || echo '[]')"
  [ -n "$crit" ] || crit='[]'

  # Per-environment SLA/profile map: parse the Environment Map table rows.
  envmap="$(awk '/^## Environment Map/{f=1;next} /^## /{f=0} f' "$SSOT_MD" \
    | grep -E '^\|' | grep -vE '^\|[[:space:]]*Environment|^\|[[:space:]]*-' \
    | awk -F'|' 'NF>=7 {
        for(i=1;i<=NF;i++){gsub(/^[[:space:]]+|[[:space:]]+$/,"",$i)}
        printf "{\"environment\":\"%s\",\"aws_profile\":\"%s\",\"gcp_project\":\"%s\",\"kube_context\":\"%s\",\"region\":\"%s\",\"uptime_sla\":\"%s\"}\n",$2,$3,$4,$5,$6,$7
      }' \
    | jq -s 'map(select(.environment|test("^\\[")|not) | select(.environment|length>0))' 2>/dev/null || echo '[]')"
  [ -n "$envmap" ] || envmap='[]'

  # Per-service SLAs: parse the "## SLAs / SLOs" table (service + SLA columns).
  svcslas="$(awk '/^## SLAs/{f=1;next} /^## /{f=0} f' "$SSOT_MD" \
    | grep -E '^\|' | grep -vE '^\|[[:space:]]*Service|^\|[[:space:]]*-' \
    | awk -F'|' 'NF>=4 {
        for(i=1;i<=NF;i++){gsub(/^[[:space:]]+|[[:space:]]+$/,"",$i)}
        printf "{\"service\":\"%s\",\"sla\":\"%s\"}\n",$2,$3
      }' \
    | jq -s 'map(select(.service|test("^\\[")|not) | select(.service|length>0))' 2>/dev/null || echo '[]')"
  [ -n "$svcslas" ] || svcslas='[]'

  # Exclusions: one string array per "## Exclusions" subsection.
  excl_regions="$(bc_exclusion_list Regions)";     [ -n "$excl_regions" ]   || excl_regions='[]'
  excl_accounts="$(bc_exclusion_list Accounts)";   [ -n "$excl_accounts" ]  || excl_accounts='[]'
  excl_services="$(bc_exclusion_list Services)";   [ -n "$excl_services" ]  || excl_services='[]'
  excl_resources="$(bc_exclusion_list Resources)"; [ -n "$excl_resources" ] || excl_resources='[]'

  # Declared resource intent: the `resource_intent:` YAML list under
  # "## Resource Intent". Only UNCOMMENTED entries count — the template ships a
  # commented example, and parsing that as a real declaration would silently
  # exempt a resource nobody declared. An entry starts at `- <matchkey>: <value>`;
  # its following indented keys belong to it. Unknown intents are dropped rather
  # than passed through, so only the closed vocabulary can ever reach an audit.
  rintent="$(awk '
      /^## Resource Intent/{sec=1;next} /^## /{sec=0}
      !sec{next}
      /^```/{inyaml=!inyaml;next}
      !inyaml{next}
      { line=$0; sub(/\r$/,"",line); gsub(/\t/," ",line); sub(/^[[:space:]]+/,"",line) }
      line ~ /^#/ {next}                                  # commented example: never a declaration
      line ~ /^-[[:space:]]/ {
        if (mk!="") print mk "\t" mv "\t" it "\t" wy "\t" rb
        mk="";mv="";it="";wy="";rb=""
        sub(/^-[[:space:]]*/,"",line)
      }
      {
        k=line; v=line
        sub(/:.*$/,"",k); sub(/^[^:]*:[[:space:]]*/,"",v)
        gsub(/^[[:space:]]+|[[:space:]]+$/,"",k)
        v=bcval(v)
        if (k=="intent") it=v
        else if (k=="why") wy=v
        else if (k=="review_by") rb=v
        else if (k=="cluster"||k=="namespace"||k=="workload"||k=="instance_id"||k=="resource_name") { mk=k; mv=v }
      }
      END{ if (mk!="") print mk "\t" mv "\t" it "\t" wy "\t" rb }
      # One value reader for every YAML scalar this file parses. Takes what is
      # INSIDE a quoted value verbatim (a PromQL query is full of quotes, braces
      # and brackets, and a trailing-comment strip would truncate it); strips a
      # trailing ` # comment` only from an UNQUOTED value.
      function bcval(s) {
        if (s ~ /^"/)      { sub(/^"/,"",s); if (match(s,/"[^"]*$/)) s=substr(s,1,RSTART-1); return s }
        else if (s ~ /^\x27/) { sub(/^\x27/,"",s); if (match(s,/\x27[^\x27]*$/)) s=substr(s,1,RSTART-1); return s }
        sub(/[[:space:]]+#.*$/,"",s); sub(/[[:space:]]+$/,"",s); return s
      }
    ' "$SSOT_MD" \
    | jq -R -s 'split("\n") | map(select(length>0) | split("\t"))
                | map({match_kind:.[0], match:.[1], intent:.[2], why:.[3], review_by:.[4]})
                | map(select(((.match // "")|length>0) and ((.match // "")|test("^<|^\\[")|not))
                      | select(.intent | IN("standby","dr","backup","pre-scaled","accepted-tradeoff")))' 2>/dev/null || echo '[]')"
  [ -n "$rintent" ] || rintent='[]'

  # Declared unit of delivered value: the `unit_metrics:` YAML list under
  # "## Unit of Delivered Value". Same two rules as resource_intent, for the same
  # reason: only UNCOMMENTED entries count (the template ships a commented
  # example, and parsing it would publish a cost-per-unit against a denominator
  # nobody declared — a wrong denominator is harder to spot than a missing one,
  # because the number looks finished), and `source` must be in the closed set.
  # `query` is passed through VERBATIM: it is the customer's own metric query and
  # jq does the JSON encoding, so quotes, braces and brackets survive intact.
  umetrics="$(awk '
      /^## Unit of Delivered Value/{sec=1;next} /^## /{sec=0}
      !sec{next}
      /^```/{inyaml=!inyaml;next}
      !inyaml{next}
      { line=$0; sub(/\r$/,"",line); gsub(/\t/," ",line); sub(/^[[:space:]]+/,"",line) }
      line ~ /^#/ {next}
      line ~ /^-[[:space:]]/ {
        if (nm!="") print nm "\t" qr "\t" sr "\t" sc "\t" pr
        nm="";qr="";sr="";sc="";pr=""
        sub(/^-[[:space:]]*/,"",line)
      }
      {
        k=line; v=line
        sub(/:.*$/,"",k); sub(/^[^:]*:[[:space:]]*/,"",v)
        gsub(/^[[:space:]]+|[[:space:]]+$/,"",k)
        v=bcval(v)
        if (k=="name") nm=v
        else if (k=="query") qr=v
        else if (k=="source") sr=v
        else if (k=="scope") sc=v
        else if (k=="per") pr=v
      }
      END{ if (nm!="") print nm "\t" qr "\t" sr "\t" sc "\t" pr }
      function bcval(s) {
        if (s ~ /^"/)      { sub(/^"/,"",s); if (match(s,/"[^"]*$/)) s=substr(s,1,RSTART-1); return s }
        else if (s ~ /^\x27/) { sub(/^\x27/,"",s); if (match(s,/\x27[^\x27]*$/)) s=substr(s,1,RSTART-1); return s }
        sub(/[[:space:]]+#.*$/,"",s); sub(/[[:space:]]+$/,"",s); return s
      }
    ' "$SSOT_MD" \
    | jq -R -s 'split("\n") | map(select(length>0) | split("\t"))
                | map({name:.[0], query:.[1], source:.[2],
                       scope:(if ((.[3] // "")|length>0) then .[3] else "all" end),
                       per:(((.[4] // "") | if test("^[0-9]+$") then tonumber else 1000 end))})
                | map(select(((.name // "")|length>0) and ((.name // "")|test("^<|^\\[")|not))
                      | select(((.query // "")|length>0) and ((.query // "")|test("^<|^\\[")|not))
                      | select(.source | IN("prometheus","victoriametrics","thanos","cloud-monitoring")))' 2>/dev/null || echo '[]')"
  [ -n "$umetrics" ] || umetrics='[]'

  now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"
  jq -n \
    --arg env "$stage" --arg cost "$cost" --arg now "$now" \
    --argjson crit "$crit" --argjson envmap "$envmap" \
    --argjson svcslas "$svcslas" --argjson rintent "$rintent" \
    --argjson umetrics "$umetrics" \
    --argjson excl_accounts "$excl_accounts" --argjson excl_regions "$excl_regions" \
    --argjson excl_services "$excl_services" --argjson excl_resources "$excl_resources" \
    '{
      source: "business_context.md",
      environment: $env,
      cost_sensitivity: $cost,
      critical_dependencies: $crit,
      environment_map: $envmap,
      service_slas: $svcslas,
      resource_intent: $rintent,
      unit_metrics: $umetrics,
      exclusions: {
        accounts: $excl_accounts,
        regions: $excl_regions,
        services: $excl_services,
        resources: $excl_resources
      },
      derived_at: $now
    }' > "$SSOT_JSON"
  # printf '%s', never echo: `echo` interprets backslashes in some shells, so a
  # declaration whose free text contains one (a Windows path in a `why`, a regex
  # in a query) reaches jq as mangled JSON and this summary line dies with a
  # parse error on stderr while the written file is perfectly fine. Counting is
  # not worth a scary error message about data that is correct.
  echo "[derived] $SSOT_JSON (environment=$stage cost=$cost critical=$(printf '%s' "$crit" | jq 'length') envs=$(printf '%s' "$envmap" | jq 'length') slas=$(printf '%s' "$svcslas" | jq 'length') intents=$(printf '%s' "$rintent" | jq 'length') units=$(printf '%s' "$umetrics" | jq 'length'))"
}

# --- Read helpers other skills can source -------------------------------------
# Precedence: business_context.json (derived from the SSOT) is authoritative.
# A legacy topology.json:.business_context is read only as a fallback for a
# workspace that has not migrated yet.
bc_load() {
  if [ -f "$SSOT_JSON" ]; then
    cat "$SSOT_JSON"
  elif [ -f "${SCOUTFLO_DIR}/topology.json" ]; then
    jq '.business_context // {}' "${SCOUTFLO_DIR}/topology.json" 2>/dev/null || echo '{}'
  else
    echo '{}'
  fi
}

bc_get() {
  field="$1"
  bc_load | jq -r ".${field} // empty" 2>/dev/null || echo ""
}

# --- One-time migration from the legacy topology.json scalar store ------------
# If a workspace has topology.json:.business_context but no SSOT yet, seed the
# SSOT from it so no context is lost, then derive the json. Never deletes the
# topology.json file (checkpoint owns .audit_scope in it) — only reads it.
bc_migrate_from_topology() {
  topo="${SCOUTFLO_DIR}/topology.json"
  [ -f "$topo" ] || { echo "no legacy topology.json to migrate"; return 0; }
  [ -f "$SSOT_MD" ] && { echo "SSOT already exists; not overwriting"; return 0; }
  has="$(jq -r 'has("business_context")' "$topo" 2>/dev/null || echo false)"
  [ "$has" = "true" ] || { echo "no legacy .business_context to migrate"; return 0; }
  bc_scaffold_from_template
  team="$(jq -r '.business_context.team // ""' "$topo")"
  env="$(jq -r '.business_context.environment // "production"' "$topo")"
  cost="$(jq -r '.business_context.cost_sensitivity // "medium"' "$topo")"
  # patch the scaffold's Environment + Cost Sensitivity with the migrated values
  sed -i.bak -E "s/^- \*\*Stage:\*\* \[.*\]/- **Stage:** ${env}/" "$SSOT_MD" 2>/dev/null || true
  sed -i.bak2 -E "s/^- \*\*Primary:\*\* \[.*\]/- **Primary:** ${cost}/" "$SSOT_MD" 2>/dev/null || true
  rm -f "${SSOT_MD}.bak" "${SSOT_MD}.bak2"
  echo "[migrated] seeded $SSOT_MD from topology.json (team=$team env=$env cost=$cost); review and enrich it"
  bc_derive_json
}
