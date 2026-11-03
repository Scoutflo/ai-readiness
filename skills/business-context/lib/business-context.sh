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
# --confirm-replace records the user's approval for THIS source and destination;
# it is not a session-wide permission. Stage both files before touching the old
# pair. The subshell keeps temporary paths and traps out of the caller's shell.
bc_import_file() (
  bc_src="${1:-}"
  bc_replace="${2:-}"
  [ "$#" -le 2 ] && { [ -z "$bc_replace" ] || [ "$bc_replace" = --confirm-replace ]; } \
    || { echo "usage: bc_import_file FILE [--confirm-replace]" >&2; return 1; }
  [ -f "$bc_src" ] && [ -r "$bc_src" ] && [ -s "$bc_src" ] \
    || { echo "import source is missing, unreadable or empty: $bc_src" >&2; return 2; }
  umask 077
  bc_init_dir || return 1
  bc_lock="${SCOUTFLO_DIR}/.business-context-import.lock"
  mkdir "$bc_lock" 2>/dev/null \
    || { echo "another import holds $bc_lock; inspect it before retrying" >&2; return 1; }
  bc_stage=""; bc_backup=""; bc_installing=no; bc_had_md=no; bc_had_json=no
  bc_import_cleanup() {
    bc_rc=$?
    trap - EXIT HUP INT TERM
    if [ "$bc_installing" = yes ]; then
      bc_restored=yes
      if [ "$bc_had_md" = yes ]; then
        cp -p "$bc_backup/business_context.md" "$SSOT_MD" || bc_restored=no
      else rm -f "$SSOT_MD" || bc_restored=no; fi
      if [ "$bc_had_json" = yes ]; then
        cp -p "$bc_backup/business_context.json" "$SSOT_JSON" || bc_restored=no
      else rm -f "$SSOT_JSON" || bc_restored=no; fi
      if [ "$bc_restored" = yes ]; then
        echo "import failed; previous context restored from $bc_backup" >&2
      else
        echo "import failed and recovery failed; preserve $bc_backup and restore both context files before continuing" >&2
        bc_rc=1
      fi
    fi
    [ -z "$bc_stage" ] || rm -rf "$bc_stage"
    rmdir "$bc_lock" || bc_rc=1
    exit "$bc_rc"
  }
  trap bc_import_cleanup EXIT
  trap 'exit 1' HUP INT TERM
  for bc_dest in "$SSOT_MD" "$SSOT_JSON"; do
    [ ! -L "$bc_dest" ] && { [ ! -e "$bc_dest" ] || [ -f "$bc_dest" ]; } \
      || { echo "refusing a non-regular context destination: $bc_dest" >&2; return 1; }
  done
  [ ! -f "$SSOT_MD" ] || bc_had_md=yes
  [ ! -f "$SSOT_JSON" ] || bc_had_json=yes
  if { [ "$bc_had_md" = yes ] || [ "$bc_had_json" = yes ]; } && [ "$bc_replace" != --confirm-replace ]; then
    echo "context already exists at $SSOT_MD / $SSOT_JSON; show the replacement and obtain confirmation, then use --confirm-replace" >&2
    return 1
  fi
  bc_stage=$(mktemp -d "${SCOUTFLO_DIR}/.business-context-import.XXXXXX") || return 1
  cp "$bc_src" "$bc_stage/incoming.md" || return 1
  bc_validate "$bc_stage/incoming.md" || return 2
  # The real parser runs against the staged copy. Neither published file moves
  # on a validation or projection error, even when the caller uses `if`/`||`.
  (
    SSOT_MD="$bc_stage/incoming.md"
    SSOT_JSON="$bc_stage/incoming.json"
    bc_derive_json
  ) || return 2
  jq -e 'type == "object"' "$bc_stage/incoming.json" >/dev/null || return 2
  mkdir -p "${SCOUTFLO_DIR}/backups" || return 1
  bc_backup=$(mktemp -d "${SCOUTFLO_DIR}/backups/business-context.XXXXXX") || return 1
  [ "$bc_had_md" = no ] || cp -p "$SSOT_MD" "$bc_backup/business_context.md" || return 1
  [ "$bc_had_json" = no ] || cp -p "$SSOT_JSON" "$bc_backup/business_context.json" || return 1
  bc_installing=yes
  mv "$bc_stage/incoming.json" "$SSOT_JSON" || return 1
  mv "$bc_stage/incoming.md" "$SSOT_MD" || return 1
  bc_installing=no
  echo "[imported] $SSOT_MD and $SSOT_JSON; previous files saved in $bc_backup"
)

# --- Mode 3: append a free-form custom-rules / runbook block ------------------
# Reads a heredoc-style paste from stdin and appends it under Custom Rules.
bc_append_custom() (
  bc_init_dir || return 1
  umask 077
  bc_paste_tmp=$(mktemp "${SCOUTFLO_DIR}/.business-context-paste.XXXXXX") || return 1
  trap 'rm -f "$bc_paste_tmp"' EXIT
  trap 'exit 1' HUP INT TERM
  # Command substitution removes trailing newlines. Stage stdin as bytes so a
  # pasted runbook, including its final blank lines, survives unchanged.
  cat > "$bc_paste_tmp" || return 1
  [ -s "$bc_paste_tmp" ] || { echo "[skip] nothing pasted"; return 0; }
  [ -f "$SSOT_MD" ] || bc_scaffold_from_template || return 1
  {
    printf '\n## Custom Rules (added %s)\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"
    cat "$bc_paste_tmp"
  } >> "$SSOT_MD" || return 1
  echo "[saved] appended custom rules to $SSOT_MD"
  bc_derive_json
)

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
  [ -f "$f" ] && [ -r "$f" ] && [ -s "$f" ] \
    || { echo "missing, unreadable or empty context: $f" >&2; return 1; }
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
    | jq -R . | jq -s 'map(select(length>0 and (test("\\[|<")|not)))' 2>/dev/null || echo '[]'
}

# --- Derive the machine projection the shell libs read ------------------------
# business_context.json holds the structured fields the libs consume
# (environment, cost_sensitivity, critical_dependencies, per-env SLA map,
# per-service SLAs, and exclusions). It is ALWAYS regenerated from the .md;
# never hand-edited.
bc_derive_json() (
  [ -f "$SSOT_MD" ] || { echo "no SSOT to derive from"; return 1; }
  command -v jq >/dev/null || { echo "missing binary: jq" >&2; return 1; }
  bc_init_dir || return 1
  umask 077
  bc_json_tmp=$(mktemp "${SCOUTFLO_DIR}/.business-context-json.XXXXXX") || return 1
  trap 'rm -f "$bc_json_tmp"' EXIT
  trap 'exit 1' HUP INT TERM

  stage="$(grep -iA5 '^## Environment' "$SSOT_MD" | grep -iE 'Stage:' | head -1 | sed -E 's/.*Stage:\**[[:space:]]*//; s/[][]//g; s/[[:space:]]*$//' | tr 'A-Z' 'a-z')"
  case "$stage" in prod|production) stage="production" ;; staging) stage="staging" ;; dev|development) stage="dev" ;; dr) stage="dr" ;; *) stage="production" ;; esac

  cost="$(grep -iA3 '^## Cost Sensitivity' "$SSOT_MD" | grep -iE 'Primary:' | head -1 | sed -E 's/.*Primary:\**[[:space:]]*//; s/[][]//g; s/[[:space:]]*$//' | tr 'A-Z' 'a-z')"
  case "$cost" in high) cost="high" ;; low) cost="low" ;; *) cost="medium" ;; esac

  # Placeholder test is UNANCHORED on purpose: the shipped template fills some
  # columns (environment names, a leading word) while leaving others as
  # [placeholder]/<placeholder>. Anchoring at ^ let a fresh, never-filled SSOT
  # derive three environment rows with REAL-looking SLA numbers and an exclusion —
  # which every audit then judged findings against. A row carrying ANY unfilled
  # placeholder is not a declaration.
  # Critical services: bullet lines under "## Critical Services", first backtick-quoted token per line.
  crit="$(awk '/^## Critical Services/{f=1;next} /^## /{f=0} f' "$SSOT_MD" \
    | grep -oE '`[^`]+`' | head -50 | sed 's/`//g' \
    | jq -R . | jq -s 'map(select(length>0 and (test("\\[|<")|not)))' 2>/dev/null || echo '[]')"
  [ -n "$crit" ] || crit='[]'

  # Per-environment SLA/profile map: parse the Environment Map table rows.
  envmap="$(awk '/^## Environment Map/{f=1;next} /^## /{f=0} f' "$SSOT_MD" \
    | grep -E '^\|' | grep -vE '^\|[[:space:]]*Environment|^\|[[:space:]]*-' \
    | awk -F'|' 'NF>=7 {
        for(i=1;i<=NF;i++){gsub(/^[[:space:]]+|[[:space:]]+$/,"",$i)}
        printf "%s\t%s\t%s\t%s\t%s\t%s\n",$2,$3,$4,$5,$6,$7
      }' \
    | jq -Rs 'split("\n") | map(select(length>0) | split("\t")
        | if length==6 then {environment:.[0],aws_profile:.[1],gcp_project:.[2],kube_context:.[3],region:.[4],uptime_sla:.[5]}
          else error("Environment Map row has unexpected tab-separated fields") end)
        | map(select([.environment,.aws_profile,.gcp_project,.kube_context,.region,.uptime_sla] | any(test("\\[|<"))|not) | select(.environment|length>0))')" \
    || { echo 'failed to derive Environment Map; previous JSON preserved' >&2; return 1; }
  [ -n "$envmap" ] || envmap='[]'

  # Per-service SLAs: parse the "## SLAs / SLOs" table (service + SLA columns).
  svcslas="$(awk '/^## SLAs/{f=1;next} /^## /{f=0} f' "$SSOT_MD" \
    | grep -E '^\|' | grep -vE '^\|[[:space:]]*Service|^\|[[:space:]]*-' \
    | awk -F'|' 'NF>=4 {
        for(i=1;i<=NF;i++){gsub(/^[[:space:]]+|[[:space:]]+$/,"",$i)}
        printf "%s\t%s\n",$2,$3
      }' \
    | jq -Rs 'split("\n") | map(select(length>0) | split("\t")
        | if length==2 then {service:.[0],sla:.[1]}
          else error("SLA row has unexpected tab-separated fields") end)
        | map(select([.service,.sla] | any(test("\\[|<"))|not) | select(.service|length>0))')" \
    || { echo 'failed to derive service SLAs; previous JSON preserved' >&2; return 1; }
  [ -n "$svcslas" ] || svcslas='[]'

  # Exclusions: one string array per "## Exclusions" subsection.
  excl_regions="$(bc_exclusion_list Regions)";     [ -n "$excl_regions" ]   || excl_regions='[]'
  excl_accounts="$(bc_exclusion_list Accounts)";   [ -n "$excl_accounts" ]  || excl_accounts='[]'
  excl_services="$(bc_exclusion_list Services)";   [ -n "$excl_services" ]  || excl_services='[]'
  excl_resources="$(bc_exclusion_list Resources)"; [ -n "$excl_resources" ] || excl_resources='[]'

  # Declared resource intent: the `resource_intent:` YAML list under
  # "## Resource Intent". An entry starts at `- <matchkey>: <value>`; its following
  # indented keys belong to it. Two filters keep an undeclared resource from being
  # exempted, and BOTH are load-bearing: an unfilled `<placeholder>` match is
  # dropped, and an intent outside the closed vocabulary is dropped rather than
  # passed through. (The `/^#/` skip is defence-in-depth only — a commented
  # `# intent: x` parses its key as "# intent", which matches nothing, so the
  # parser is comment-immune by construction.)
  _ri_raw="$(awk '
      /^## Resource Intent/{sec=1;next} /^## /{sec=0}
      !sec{next}
      /^```/{inyaml=!inyaml;next}
      !inyaml{next}
      { line=$0; sub(/\r$/,"",line); gsub(/\t/," ",line); sub(/^[[:space:]]+/,"",line) }
      line ~ /^#/ {next}                                  # defence-in-depth; see the note above
      line ~ /^-[[:space:]]/ {
        if (entry) print mk "\t" mv "\t" it "\t" wy "\t" rb
        entry=1
        mk="";mv="";it="";wy="";rb=""
        sub(/^-[[:space:]]*/,"",line)
      }
      {
        k=line; v=line
        sub(/:.*$/,"",k); sub(/^[^:]*:[[:space:]]*/,"",v)
        gsub(/^[[:space:]]+|[[:space:]]+$/,"",k)
        v=(k=="why") ? bcraw(v) : bcval(v)
        if (k=="intent") it=v
        else if (k=="why") wy=v
        else if (k=="review_by") rb=v
        else if (k=="cluster"||k=="namespace"||k=="workload"||k=="instance_id"||k=="resource_name") { mk=k; mv=v }
      }
      END{ if (entry) print mk "\t" mv "\t" it "\t" wy "\t" rb }
      # --- YAML scalar readers, shared by both parsers below ---------------------
      # A quoted scalar ends at its FIRST closing quote. Ending at the LAST one
      # (match(/"[^"]*$/)) let a trailing comment that itself contains a quote
      # extend the value: `- cluster: "prod-east"  # the "big" one` captured
      # `prod-east"  # the "big`, which matches no real cluster — so a declared
      # exemption silently stopped applying.
      # bcval strips a trailing ` # comment` from an UNQUOTED scalar (YAML-correct,
      # and it stops `intent: standby # warm` from voiding the whole entry).
      # bcraw never strips it: `#` is ordinary in free text ("see ticket #123"),
      # and the template promises those words are quoted back verbatim.
      function bcval(s) { return bcscalar(s, 1) }
      function bcraw(s) { return bcscalar(s, 0) }
      function bcscalar(s, strip,   i, q) {
        q = sprintf("%c", 39)                       # single quote, without \x27 (not POSIX)
        if (substr(s,1,1) == "\"") { s=substr(s,2); i=index(s,"\""); if (i>0) s=substr(s,1,i-1); return s }
        if (substr(s,1,1) == q)    { s=substr(s,2); i=index(s,q);    if (i>0) s=substr(s,1,i-1); return s }
        if (strip) sub(/[[:space:]]+#.*$/,"",s)
        sub(/[[:space:]]+$/,"",s)
        return s
      }
    ' "$SSOT_MD")"
  rintent="$(printf '%s\n' "$_ri_raw" \
    | jq -R -s 'split("\n") | map(select(length>0) | split("\t"))
                | map({match_kind:.[0], match:.[1], intent:.[2], why:.[3], review_by:.[4]})
                | map(.match = ((.match // "") | sub("^\\s+";"") | sub("\\s+$";"")))
                | map(select(((.match // "")|length>0) and ((.match // "")|test("^<|^\\[")|not))
                      | (.intent |= ascii_downcase) | select(.intent | IN("standby","dr","backup","pre-scaled","accepted-tradeoff")))' 2>/dev/null || echo '[]')"
  [ -n "$rintent" ] || rintent='[]'

  # Declared unit of delivered value: the `unit_metrics:` YAML list under
  # "## Unit of Delivered Value".
  #
  # NOTE the asymmetry with resource_intent above: this template example is NOT
  # commented out — it is a LIVE entry carrying `<placeholder>` values. So the
  # PLACEHOLDER filter is the only thing keeping a freshly scaffolded SSOT at `[]`,
  # and it is load-bearing in the strongest sense: without it every customer who
  # runs the skill gets a fabricated unit, and `COST-UNIT-004` stops firing, so
  # they believe unit economics is on while the denominator means nothing. A wrong
  # denominator is harder to spot than a missing one, because the number looks
  # finished.
  #
  # `query` is the customer's own metric query and is passed through VERBATIM (jq
  # does the JSON encoding, so quotes, braces and brackets survive). A YAML block
  # scalar (`query: >` / `query: |`) is REJECTED rather than accepted as the
  # one-character string ">": a kept entry would be sent to their Prometheus as a
  # query, and silently shipping `>` is worse than honestly reporting no unit.
  _um_raw="$(awk '
      /^## Unit of Delivered Value/{sec=1;next} /^## /{sec=0}
      !sec{next}
      /^```/{inyaml=!inyaml;next}
      !inyaml{next}
      { line=$0; sub(/\r$/,"",line); gsub(/\t/," ",line); sub(/^[[:space:]]+/,"",line) }
      line ~ /^#/ {next}
      line ~ /^-[[:space:]]/ {
        if (entry) print nm "\t" qr "\t" sr "\t" sc "\t" pr
        entry=1
        nm="";qr="";sr="";sc="";pr=""
        sub(/^-[[:space:]]*/,"",line)
      }
      {
        k=line; v=line
        sub(/:.*$/,"",k); sub(/^[^:]*:[[:space:]]*/,"",v)
        gsub(/^[[:space:]]+|[[:space:]]+$/,"",k)
        v=bcval(v)   # `query` strips a trailing YAML comment: keeping it would send
                     # the comment to the metric backend as part of the query. A
                     # query that gets TRUNCATED by that strip (an unquoted value
                     # with `#` inside a label) is caught by the balanced-quote
                     # check in the jq filter and dropped with a warning.
        if (k=="name") nm=v
        else if (k=="query") qr=v
        else if (k=="source") sr=v
        else if (k=="scope") sc=v
        else if (k=="per") pr=v
      }
      END{ if (entry) print nm "\t" qr "\t" sr "\t" sc "\t" pr }
      # --- YAML scalar readers, shared by both parsers below ---------------------
      # A quoted scalar ends at its FIRST closing quote. Ending at the LAST one
      # (match(/"[^"]*$/)) let a trailing comment that itself contains a quote
      # extend the value: `- cluster: "prod-east"  # the "big" one` captured
      # `prod-east"  # the "big`, which matches no real cluster — so a declared
      # exemption silently stopped applying.
      # bcval strips a trailing ` # comment` from an UNQUOTED scalar (YAML-correct,
      # and it stops `intent: standby # warm` from voiding the whole entry).
      # bcraw never strips it: `#` is ordinary in free text ("see ticket #123"),
      # and the template promises those words are quoted back verbatim.
      function bcval(s) { return bcscalar(s, 1) }
      function bcraw(s) { return bcscalar(s, 0) }
      function bcscalar(s, strip,   i, q) {
        q = sprintf("%c", 39)                       # single quote, without \x27 (not POSIX)
        if (substr(s,1,1) == "\"") { s=substr(s,2); i=index(s,"\""); if (i>0) s=substr(s,1,i-1); return s }
        if (substr(s,1,1) == q)    { s=substr(s,2); i=index(s,q);    if (i>0) s=substr(s,1,i-1); return s }
        if (strip) sub(/[[:space:]]+#.*$/,"",s)
        sub(/[[:space:]]+$/,"",s)
        return s
      }
    ' "$SSOT_MD")"
  umetrics="$(printf '%s\n' "$_um_raw" \
    | jq -R -s 'def trim: sub("^\\s+";"") | sub("\\s+$";"");
                split("\n") | map(select(length>0) | split("\t"))
                | map({name:((.[0] // "")|trim), query:((.[1] // "")|trim),
                       source:((.[2] // "")|trim|ascii_downcase),
                       scope:(((.[3] // "")|trim) as $s | if ($s|length>0) then $s else "all" end),
                       per:(((.[4] // "")|trim) | if test("^[1-9][0-9]*$") then tonumber else 1000 end)})
                | map(select((.name|length>0) and (.name|test("^<|^\\[")|not))
                      | select((.query|length>0) and (.query|test("^<|^\\[")|not))
                      | select(.query|test("^[>|][-+0-9]*$")|not)
                      | select(((.query|gsub("[^\"]";"")|length) % 2) == 0)
                      | select(.scope|test("^<|^\\[")|not)
                      | select(.source | IN("prometheus","victoriametrics","thanos","cloud-monitoring")))' 2>/dev/null || echo '[]')"
  [ -n "$umetrics" ] || umetrics='[]'

  # A dropped entry is the dangerous direction: a dropped resource_intent re-flags
  # a resource the customer exempted, and a dropped unit_metrics silently reverts to
  # COST-UNIT-004 while the operator believes they declared a unit. Count them and
  # say so, rather than leaving "units=0" as the only evidence.
  # Count only entries the operator really attempted: a leading `<placeholder>` or
  # `[placeholder]` is the shipped template's own example, not a failed declaration,
  # and warning about it on every fresh scaffold would train people to ignore this.
  _ri_seen="$(printf '%s' "$_ri_raw" | jq -R -s 'split("\n") | map(select(length>0) | split("\t") | select((.[1] // "") | test("^<|^\\[") | not)) | length')" || return 1
  _um_seen="$(printf '%s' "$_um_raw" | jq -R -s 'split("\n") | map(select(length>0) | split("\t") | select([.[0] // "", .[1] // ""] | any(test("^<|^\\[")) | not)) | length')" || return 1
  _ri_kept="$(printf '%s' "$rintent"  | jq 'length')"
  _um_kept="$(printf '%s' "$umetrics" | jq 'length')"
  _ri_drop=$(( _ri_seen - _ri_kept )); [ "$_ri_drop" -ge 0 ] || _ri_drop=0
  _um_drop=$(( _um_seen - _um_kept )); [ "$_um_drop" -ge 0 ] || _um_drop=0
  if [ "$_ri_drop" -gt 0 ] || [ "$_um_drop" -gt 0 ]; then
    echo "[derived] WARNING: dropped ${_ri_drop} resource_intent and ${_um_drop} unit_metrics entr(ies) — a missing or unrecognized match/name key, an unfilled <placeholder>, an intent outside standby|dr|backup|pre-scaled|accepted-tradeoff, a source outside prometheus|victoriametrics|thanos|cloud-monitoring, or a YAML block scalar (query: > / |) which cannot be executed as a query. Those declarations are NOT in effect; fix them in ${SSOT_MD} and re-run." >&2
  fi

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
    }' > "$bc_json_tmp" || return 1
  jq -e 'type == "object"' "$bc_json_tmp" >/dev/null || return 1
  mv "$bc_json_tmp" "$SSOT_JSON" || return 1
  # printf '%s', never echo: `echo` interprets backslashes in some shells, so a
  # declaration whose free text contains one (a Windows path in a `why`, a regex
  # in a query) reaches jq as mangled JSON and this summary line dies with a
  # parse error on stderr while the written file is perfectly fine. Counting is
  # not worth a scary error message about data that is correct.
  echo "[derived] $SSOT_JSON (environment=$stage cost=$cost critical=$(printf '%s' "$crit" | jq 'length') envs=$(printf '%s' "$envmap" | jq 'length') slas=$(printf '%s' "$svcslas" | jq 'length') intents=$(printf '%s' "$rintent" | jq 'length') units=$(printf '%s' "$umetrics" | jq 'length'))"
)

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
