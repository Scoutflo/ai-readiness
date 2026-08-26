#!/bin/sh
# toolkit-targets.sh — the ONE shared enumerator for multiple targets under a single
# integration block in toolkit.yaml. Every consumer (doctor, every audit, connect) calls
# this instead of inlining its own parser, so the labeled-list schema is parsed one way.
#
# Schema (backward-compatible):
#   Single-block (today, unchanged) — a mapping under the integration key:
#       clickstack:
#         hyperdx_url: https://h:8080
#         hyperdx_api_key_env: HDX_API_KEY
#     => 1 target, label defaults to the integration name ("clickstack").
#   Multi-target (new) — a YAML LIST of mappings, each = the same mapping + a `label:`:
#       clickstack:
#         - label: hdx-eu
#           hyperdx_url: https://eu:8080
#           hyperdx_api_key_env: HDX_EU_KEY
#         - label: hdx-us
#           hyperdx_url: https://us:8080
#           hyperdx_api_key_env: HDX_US_KEY
#     => N targets, one per list item; `label` is required, unique, slug-safe.
#
# Usage:
#   toolkit-targets.sh <config-file> <block> count            -> integer N (0 if absent)
#   toolkit-targets.sh <config-file> <block> label <i>        -> the target's label (0-based i)
#   toolkit-targets.sh <config-file> <block> get   <i> <key>  -> a scalar value in target i
#   toolkit-targets.sh <config-file> <block> labels           -> all labels, one per line
#   toolkit-targets.sh <config-file> <block> kind             -> "seq" (a list = multi-target),
#                                                                 "map" (single-block), or "absent"
#     Consumers use `kind` for the output-path rule: single-block ("map") writes the FLAT
#     <integration>/<date>/ path (zero migration); a list ("seq") writes <integration>/<label>/<date>/.
#
# For a single-block mapping, `get 0 <key>` returns exactly what the old two-level read did,
# and `label 0` returns the block name — so existing single-block configs behave identically.
#
# yq (mikefarah v4) is used as a fast path when available and usable; otherwise a POSIX
# awk parser handles the same layout — so multi-target does NOT require yq. Read-only.
set -eu

CFG="${1:?usage: toolkit-targets.sh <config> <block> <count|label|get|labels> ...}"
BLOCK="${2:?missing <block>}"
OP="${3:?missing op: count|label|get|labels}"
[ -f "$CFG" ] || { echo ""; exit 0; }

HAVE_YQ=0
if command -v yq >/dev/null 2>&1 && yq -r '. | keys | length' "$CFG" >/dev/null 2>&1; then
  # Confirm mikefarah-style tag support; fall back to awk if this yq is a different flavor.
  if yq -r '.["'"$BLOCK"'"] | tag' "$CFG" >/dev/null 2>&1; then HAVE_YQ=1; fi
fi

# --- yq fast path (mikefarah v4) ---------------------------------------------
yq_kind() { yq -r '.["'"$BLOCK"'"] | tag' "$CFG" 2>/dev/null || echo '!!null'; }
yq_count() {
  k=$(yq_kind)
  case "$k" in
    '!!seq') yq -r '.["'"$BLOCK"'"] | length' "$CFG" 2>/dev/null || echo 0 ;;
    '!!map') echo 1 ;;
    *)       echo 0 ;;
  esac
}
yq_label() {
  k=$(yq_kind)
  if [ "$k" = '!!seq' ]; then yq -r '.["'"$BLOCK"'"]['"$1"'].label // ""' "$CFG" 2>/dev/null
  else echo "$BLOCK"; fi
}
yq_get() {
  k=$(yq_kind)
  if [ "$k" = '!!seq' ]; then yq -r '.["'"$BLOCK"'"]['"$1"'].["'"$2"'"] // ""' "$CFG" 2>/dev/null
  else yq -r '.["'"$BLOCK"'"].["'"$2"'"] // ""' "$CFG" 2>/dev/null; fi
}

# --- awk fallback (no yq) -----------------------------------------------------
# Emits, for the block, one record per target as: <i>\t<key>\t<value>, plus a
# synthetic key "__label__". Callers filter. Handles: a top-level "<block>:" line,
# then either indented "key: value" (single map => target 0, label __block__) or a
# list of "- " items (each item => a target; keys are the item's indented "key: value"
# lines and the leading "- key: value"). Stops at the next top-level (column-0) key.
awk_dump() {
  awk -v blk="$BLOCK" '
    function strip(v){ sub(/[[:space:]]#.*$/,"",v); sub(/^[[:space:]]+/,"",v); sub(/[[:space:]]+$/,"",v);
                       sub(/^"/,"",v); sub(/"$/,"",v); sub(/^'\''/,"",v); sub(/'\''$/,"",v); return v }
    BEGIN{ inblk=0; isseq=0; idx=-1 }
    # top-level key line (column 0, not a comment)
    /^[A-Za-z_][A-Za-z0-9_]*:/ {
      if ($0 ~ "^" blk ":[[:space:]]*$" || $0 ~ "^" blk ":") { inblk=1; next }
      else if (inblk) { inblk=0 }
    }
    inblk {
      line=$0
      if (line ~ /^[[:space:]]*#/ || line ~ /^[[:space:]]*$/) next
      # a list item begins with (indent)"- "
      if (line ~ /^[[:space:]]*-[[:space:]]/) {
        isseq=1; idx++
        rest=line; sub(/^[[:space:]]*-[[:space:]]*/,"",rest)
        if (rest ~ /^[A-Za-z0-9_]+:/) {   # "- key: value" on the dash line
          key=rest; sub(/:.*/,"",key); val=rest; sub(/^[A-Za-z0-9_]+:[[:space:]]*/,"",val)
          printf "%d\t%s\t%s\n", idx, key, strip(val)
        }
        next
      }
      # an indented "key: value" line
      if (line ~ /^[[:space:]]+[A-Za-z0-9_]+:/) {
        key=line; sub(/^[[:space:]]+/,"",key); sub(/:.*/,"",key)
        val=line; sub(/^[[:space:]]+[A-Za-z0-9_]+:[[:space:]]*/,"",val)
        if (!isseq) { idx=0 }   # single-block mapping => target 0
        printf "%d\t%s\t%s\n", idx, key, strip(val)
      }
    }
  ' "$CFG"
}
awk_count() {
  d=$(awk_dump)
  [ -n "$d" ] || { echo 0; return; }
  # highest index + 1
  printf '%s\n' "$d" | awk -F'\t' 'BEGIN{m=-1} {if($1>m)m=$1} END{print m+1}'
}
awk_label() {
  i="$1"; d=$(awk_dump)
  # is it a list? (any record whose target has a label, or >1 target)
  n=$(printf '%s\n' "$d" | awk -F'\t' 'BEGIN{m=-1}{if($1>m)m=$1}END{print m+1}')
  lbl=$(printf '%s\n' "$d" | awk -F'\t' -v i="$i" '$1==i && $2=="label"{print $3; exit}')
  if [ -n "$lbl" ]; then echo "$lbl"; elif [ "$n" = "1" ]; then echo "$BLOCK"; else echo ""; fi
}
awk_get() {
  i="$1"; key="$2"
  awk_dump | awk -F'\t' -v i="$i" -v k="$key" '$1==i && $2==k{print $3; exit}'
}
awk_kind() {
  awk -v blk="$BLOCK" '
    BEGIN{ inblk=0; seenitem=0; seenkey=0 }
    /^[A-Za-z_][A-Za-z0-9_]*:/ { if ($0 ~ "^" blk ":") { inblk=1; next } else if (inblk) inblk=0 }
    inblk {
      if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next
      if ($0 ~ /^[[:space:]]*-[[:space:]]/) { seenitem=1 }
      else if ($0 ~ /^[[:space:]]+[A-Za-z0-9_]+:/) { seenkey=1 }
    }
    END{ if (seenitem) print "seq"; else if (seenkey) print "map"; else print "absent" }
  ' "$CFG"
}
yq_kind_norm() {
  case "$(yq_kind)" in ('!!seq') echo seq ;; ('!!map') echo map ;; (*) echo absent ;; esac
}

case "$OP" in
  count)   if [ "$HAVE_YQ" = 1 ]; then yq_count; else awk_count; fi ;;
  label)   [ $# -ge 4 ] || { echo ""; exit 0; }
           if [ "$HAVE_YQ" = 1 ]; then yq_label "$4"; else awk_label "$4"; fi ;;
  get)     [ $# -ge 5 ] || { echo ""; exit 0; }
           if [ "$HAVE_YQ" = 1 ]; then yq_get "$4" "$5"; else awk_get "$4" "$5"; fi ;;
  kind)    if [ "$HAVE_YQ" = 1 ]; then yq_kind_norm; else awk_kind; fi ;;
  labels)  n=$(if [ "$HAVE_YQ" = 1 ]; then yq_count; else awk_count; fi)
           i=0; while [ "$i" -lt "$n" ]; do
             if [ "$HAVE_YQ" = 1 ]; then yq_label "$i"; else awk_label "$i"; fi
             i=$((i+1)); done ;;
  *) echo "toolkit-targets.sh: unknown op '$OP'" >&2; exit 2 ;;
esac
