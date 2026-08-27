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

  now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"
  jq -n \
    --arg env "$stage" --arg cost "$cost" --arg now "$now" \
    --argjson crit "$crit" --argjson envmap "$envmap" \
    --argjson svcslas "$svcslas" \
    --argjson excl_accounts "$excl_accounts" --argjson excl_regions "$excl_regions" \
    --argjson excl_services "$excl_services" --argjson excl_resources "$excl_resources" \
    '{
      source: "business_context.md",
      environment: $env,
      cost_sensitivity: $cost,
      critical_dependencies: $crit,
      environment_map: $envmap,
      service_slas: $svcslas,
      exclusions: {
        accounts: $excl_accounts,
        regions: $excl_regions,
        services: $excl_services,
        resources: $excl_resources
      },
      derived_at: $now
    }' > "$SSOT_JSON"
  echo "[derived] $SSOT_JSON (environment=$stage cost=$cost critical=$(echo "$crit" | jq 'length') envs=$(echo "$envmap" | jq 'length') slas=$(echo "$svcslas" | jq 'length'))"
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
