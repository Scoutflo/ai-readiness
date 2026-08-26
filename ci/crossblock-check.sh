#!/bin/sh
# Cross-block-state check.
#
# A `bash` command block (in a SKILL.md / reference *.md fenced ```bash block) or a
# standalone *.sh script that runs under `set -u` / `set -eu` / `set -euo` must not
# reference an UPPER_SNAKE shell variable it never assigns within that same block, when
# that variable is assigned by SOME OTHER block in the same file. That pattern is a
# stateless-block violation: each block runs in a fresh shell, so the variable is unset
# and `set -u` aborts with "unbound variable" on a real run. This is the audit-aws /
# audit-lgtm `$TOTAL` class of bug that rubric review missed twice.
#
# Deliberately narrow to stay false-positive-free:
#   - only >=2-char ALL-CAPS/underscore names (real shell config vars), never lowercase
#     (which would be jq/awk internal variables inside quoted programs);
#   - excludes environment/runtime externals (below) and ${VAR:-...}-guarded uses;
#   - recognizes assignments via NAME=, export/local NAME=, `for NAME in`, and `read NAME`.
#
# Read-only. POSIX sh + POSIX awk only (no GNU \b — the macOS/BSD awk does not support it,
# and this gate must run on any contributor machine incl. Windows Git Bash).
set -eu
DIR="${1:-.}"
FAIL=0
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
: > "$TMP"

# Vars a stateless block may legitimately read without assigning (environment, plugin
# runtime, user-exported provider secrets, well-known shell specials).
EXTERNAL="HOME PWD USER SHELL PATH TMPDIR TMP CLAUDE_PLUGIN_ROOT SCOUTFLO_AUDIT_DIR SCOUTFLO_CONFIG SCOUTFLO_TARGET SCOUTFLO_SLACK_WEBHOOK PROM_TOKEN GRAFANA_TOKEN SENTRY_TOKEN DATADOG_API_KEY DATADOG_APP_KEY KIBANA_API_KEY PAGERDUTY_TOKEN ZENDUTY_TOKEN GROUNDCOVER_API_KEY DIGITALOCEAN_ACCESS_TOKEN DO_TOKEN JSM_API_TOKEN JSM_EMAIL JSM_CLOUD_ID VM_TOKEN LOKI_TOKEN TEMPO_TOKEN MIMIR_TOKEN GITHUB_TOKEN ANTHROPIC_API_KEY AWS_ROLE_ARN GOOGLE_APPLICATION_CREDENTIALS OUT_DIR CURL_MAX_TIME SLACK_WEBHOOK_URL IFS REPLY LINENO RANDOM SECONDS PIPESTATUS OPTARG OPTIND LANG LC_ALL TERM COLUMNS"

find "$DIR/skills" "$DIR/report-standard" \( -name '*.md' -o -name '*.sh' \) 2>/dev/null | sort | while IFS= read -r f; do
  # File-wide UPPER_SNAKE assignment names (any assignment form, anywhere in the file):
  # NAME=, `read ... NAME`, `for NAME in`. Used to require "assigned elsewhere" before flagging.
  FILEASG="$(
    { grep -oE '(^|[^A-Za-z0-9_])[A-Z][A-Z0-9_]+=' "$f" 2>/dev/null | grep -oE '[A-Z][A-Z0-9_]+'
      grep -oE 'read( +-[A-Za-z]+)*( +[A-Za-z_][A-Za-z0-9_]*)+' "$f" 2>/dev/null | grep -oE '[A-Z][A-Z0-9_]+'
      grep -oE 'for +[A-Z][A-Z0-9_]+ +in' "$f" 2>/dev/null | grep -oE '[A-Z][A-Z0-9_]+'
    } | sort -u | tr '\n' ' '
  )"

  awk -v ext="$EXTERNAL" -v fileasg="$FILEASG" -v fname="$f" '
    BEGIN{
      split(ext,E," "); for(i in E) extv[E[i]]=1
      split(fileasg,A," "); for(i in A) fasg[A[i]]=1
      md = (fname ~ /\.md$/)
    }
    function flush(   name){
      if(!inblock||!setu) return
      for(name in useraw){
        if(name in asg) continue
        if(name in extv) continue
        if(!(name in fasg)) continue
        printf "%s:%d: set-u block uses $%s but never assigns it (assigned elsewhere in file) -> unbound-variable crash in a fresh shell\n", fname, blockline, name
      }
    }
    md {
      if($0 ~ /^```bash[ \t]*$/){ inblock=1; blockline=NR; setu=0; delete asg; delete useraw; next }
      if($0 ~ /^```[ \t]*$/ && inblock){ flush(); inblock=0; next }
      if(!inblock) next
    }
    !md { if(NR==1){ inblock=1; blockline=1; setu=0 } }
    {
      if(!inblock) next
      if($0 ~ /set +-[a-z]*u/ || $0 ~ /nounset/ || $0 ~ /set +-eu/ || $0 ~ /set +-euo/) setu=1

      # --- assignments in this block ---
      s=$0
      while(match(s,/(^|[^A-Za-z0-9_])[A-Z][A-Z0-9_]+=/)){
        nm=substr(s,RSTART,RLENGTH); gsub(/[^A-Za-z0-9_]/,"",nm); sub(/=$/,"",nm); asg[nm]=1
        s=substr(s,RSTART+RLENGTH)
      }
      if(match($0,/for +[A-Z][A-Z0-9_]+ +in/)){
        nm=substr($0,RSTART,RLENGTH); sub(/^for +/,"",nm); sub(/ +in$/,"",nm); asg[nm]=1
      }
      # `read [-opts] VAR...` (incl. inside `while ... read ...; do`): every UPPER_SNAKE token
      # after "read" (skipping -flags) up to ; or "do" is assigned.
      r=$0
      while(match(r,/read( +-[A-Za-z]+)*( +[A-Za-z_][A-Za-z0-9_]*)+/)){
        seg=substr(r,RSTART,RLENGTH); sub(/^read/,"",seg)
        n=split(seg,rw," ")
        for(i=1;i<=n;i++){ if(rw[i] ~ /^-/) continue; if(rw[i] ~ /^[A-Z][A-Z0-9_]+$/) asg[rw[i]]=1 }
        r=substr(r,RSTART+RLENGTH)
      }

      # --- unguarded uses: bare $VAR, or ${VAR} / ${VAR}... without a :-+=? modifier ---
      # Skip comment lines: a `#`-comment references no live variable. Only consider the
      # code portion before an unquoted leading `#` (full-line comments are the common case;
      # a `#` mid-line after code is rare in these blocks and erring toward not-flagging a
      # commented use is safer than a false positive that trains people to ignore the gate).
      t=$0
      sub(/^[ \t]*#.*/,"",t)
      while(match(t,/\$\{?[A-Z][A-Z0-9_]+/)){
        raw=substr(t,RSTART,RLENGTH); nm=raw; gsub(/[^A-Za-z0-9_]/,"",nm)
        if(raw ~ /\{/){
          after=substr(t,RSTART+RLENGTH,1)
          if(after!=":" && after!="-" && after!="+" && after!="=" && after!="?") useraw[nm]=1
        } else {
          useraw[nm]=1
        }
        t=substr(t,RSTART+RLENGTH)
      }
    }
    END{ if(!md) flush() }
  ' "$f" >> "$TMP"
done

if [ -s "$TMP" ]; then
  echo "CROSS-BLOCK CHECK FAILED"
  cat "$TMP"
  FAIL=1
else
  echo "CROSSBLOCK-OK (no set-u block references an undeclared cross-block variable)"
fi
exit $FAIL
