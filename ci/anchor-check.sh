#!/bin/sh
# Anchor check: every `skill-name#anchor-slug` cross-reference in
# skills/*/SKILL.md and skills/*/references/*.md must resolve to a real
# heading in the target skill's SKILL.md (GitHub-style anchor slugging).
# Read-only, no external dependencies beyond grep/sed/awk/find.
set -eu
DIR="${1:-.}"
SKILLS_DIR="$DIR/skills"

[ -d "$SKILLS_DIR" ] || { echo "no skills dir at $SKILLS_DIR"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# List of skill directory names, one per line.
find "$SKILLS_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort > "$TMP/skill-names"

# Build a '|'-joined alternation for the awk regex.
ALT=$(tr '\n' '|' < "$TMP/skill-names" | sed 's/|$//')
[ -n "$ALT" ] || { echo "ANCHOR-OK (no skills found)"; exit 0; }

# 1. Extract every candidate skill-name#anchor-slug reference as
#    "file:line:match", from SKILL.md and references/*.md files.
#    A match must not be immediately preceded by an identifier/path
#    character (alnum, _, -, ., /) so we don't match inside a longer
#    token or a relative file path like references/foo.md#bar, and must
#    not be immediately followed by an identifier character.
find "$SKILLS_DIR" \( -name SKILL.md -o -path '*/references/*.md' \) -print \
  | sort \
  | xargs awk -v alt="$ALT" '
    BEGIN { n = split(alt, names, "|") }
    {
      line = $0
      for (i = 1; i <= n; i++) {
        pat = names[i] "#[a-z0-9]+(-[a-z0-9]+)*"
        rest = line
        base = 0
        while (match(rest, pat)) {
          start = base + RSTART
          len = RLENGTH
          before = (start > 1) ? substr(line, start - 1, 1) : ""
          after = substr(line, start + len, 1)
          if (before !~ /[A-Za-z0-9_.\/-]/ && after !~ /[A-Za-z0-9_-]/) {
            print FILENAME ":" FNR ":" substr(line, start, len)
          }
          base = start + len - 1
          rest = substr(line, base + 1)
        }
      }
    }
  ' > "$TMP/refs" 2>/dev/null || true

if [ ! -s "$TMP/refs" ]; then
  echo "ANCHOR-OK (0 cross-references found)"
  exit 0
fi

# 2. GitHub-style heading -> anchor slug: lowercase, strip markdown
#    emphasis markers, drop anything not alnum/space/hyphen, spaces to
#    hyphens, collapse repeats, trim leading/trailing hyphens.
slugify() {
  tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[`*_]//g' \
    | sed -E 's/[^a-z0-9 -]//g' \
    | sed -E 's/[[:space:]]+/-/g' \
    | sed -E 's/-+/-/g' \
    | sed -E 's/^-//; s/-$//'
}

# Headings of a markdown file, skipping fenced code blocks (``` ... ```),
# already stripped of the leading '#'s.
headings_of() {
  awk '
    /^```/ { infence = !infence; next }
    !infence && /^#+[ \t]/ { sub(/^#+[ \t]+/, ""); print }
  ' "$1"
}

# Cache each skill's anchor set so we derive it once even if it is
# referenced many times.
anchors_for_skill() {
  skill="$1"
  cache="$TMP/anchors-$skill"
  if [ ! -f "$cache" ]; then
    skill_md="$SKILLS_DIR/$skill/SKILL.md"
    if [ -f "$skill_md" ]; then
      headings_of "$skill_md" | slugify > "$cache"
    else
      : > "$cache"
    fi
  fi
  cat "$cache"
}

FAIL=0
: > "$TMP/broken"

while IFS=: read -r file lineno match; do
  target_skill=$(printf '%s' "$match" | sed 's/#.*//')
  anchor=$(printf '%s' "$match" | sed 's/^[^#]*#//')

  if [ ! -d "$SKILLS_DIR/$target_skill" ]; then
    echo "$file:$lineno: broken reference '$match' -> skill '$target_skill' does not exist" >> "$TMP/broken"
    continue
  fi

  if [ ! -f "$SKILLS_DIR/$target_skill/SKILL.md" ]; then
    echo "$file:$lineno: broken reference '$match' -> $SKILLS_DIR/$target_skill/SKILL.md is missing" >> "$TMP/broken"
    continue
  fi

  if ! anchors_for_skill "$target_skill" | grep -qx -- "$anchor"; then
    echo "$file:$lineno: broken reference '$match' -> no heading in $target_skill/SKILL.md slugs to '$anchor'" >> "$TMP/broken"
  fi
done < "$TMP/refs"

if [ -s "$TMP/broken" ]; then
  echo "ANCHOR CHECK FAILED"
  cat "$TMP/broken"
  exit 1
fi

echo "ANCHOR-OK ($(wc -l < "$TMP/refs" | tr -d ' ') cross-references checked)"
