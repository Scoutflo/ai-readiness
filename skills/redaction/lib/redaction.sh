#!/bin/sh
# redaction.sh
# Global regex-based redaction for secrets in reports

set -eu

# Redaction patterns (in order of specificity)
REDACTION_PATTERNS='
s/\([Xx]-[Vv][Oo]-[Aa][Pp][Ii]-[Ii][Dd]["'"'"'\\]*[[:space:]]*[:=][[:space:]]*["'"'"'\\]*\)[^[:space:]<>"'"'"'`,;\\][^<>"'"'"'`,;\\]*/\1[REDACTED]/g;
s/\([Xx]-[Vv][Oo]-[Aa][Pp][Ii]-[Kk][Ee][Yy]["'"'"'\\]*[[:space:]]*[:=][[:space:]]*["'"'"'\\]*\)[^[:space:]<>"'"'"'`,;\\][^<>"'"'"'`,;\\]*/\1[REDACTED]/g;
s/\([Rr][Oo][Uu][Tt][Ii][Nn][Gg][_-]\{0,1\}[Kk][Ee][Yy]["'"'"'\\]*[[:space:]]*[:=][[:space:]]*["'"'"'\\]*\)[^[:space:]<>"'"'"'`,;\\][^<>"'"'"'`,;\\]*/\1[REDACTED]/g;
s@\([Hh][Tt][Tt][Pp][Ss]\{0,1\}:\\*/\\*/[Aa][Ll][Ee][Rr][Tt]\.[Vv][Ii][Cc][Tt][Oo][Rr][Oo][Pp][Ss]\.[Cc][Oo][Mm]\\*/integrations\\*/[^/\\[:space:]<>"'"'"']\{1,\}\\*/[0-9]\{8\}\\*/alert\\*/\)[^/\\?#[:space:]<>"'"'"'`)]\{1,\}\\*/[^/\\?#[:space:]<>"'"'"'`)]\{1,\}@\1[REDACTED]@g;
s@\([Hh][Tt][Tt][Pp][Ss]\{0,1\}:\\*/\\*/[Aa][Ll][Ee][Rr][Tt]\.[Vv][Ii][Cc][Tt][Oo][Rr][Oo][Pp][Ss]\.[Cc][Oo][Mm]\\*/integrations\\*/[^/\\[:space:]<>"'"'"']\{1,\}\\*/[0-9]\{8\}\\*/alert\\*/\)[^/\\?#[:space:]<>"'"'"'`)]\{1,\}@\1[REDACTED]@g;
s/AKIA[0-9A-Z]\{16\}/AKIA[REDACTED]/g;
s/NRAK-[A-Za-z0-9]\{20,\}/NRAK-[REDACTED]/g;
s/sk_live_[A-Za-z0-9]\{24,\}/sk_live_[REDACTED]/g;
s/sk_test_[A-Za-z0-9]\{24,\}/sk_test_[REDACTED]/g;
s/Bearer [A-Za-z0-9._-]\{40,\}/Bearer [REDACTED]/g;
s/api_key_[A-Za-z0-9]\{32,\}/api_key_[REDACTED]/g;
s/ASIA[0-9A-Z]\{16\}/ASIA[REDACTED]/g;
s/wJalrXUtnFEMI[A-Za-z0-9/+]\{32,\}/wJalrXUtnFEMI[REDACTED]/g;
s/github_pat_[A-Za-z0-9_]\{36,\}/github_pat_[REDACTED]/g;
s/ghp_[A-Za-z0-9]\{36,\}/ghp_[REDACTED]/g;
s/\([?&][Tt][Oo][Kk][Ee][Nn]=\)[^&#[:space:]<>"'"'"'`]\{1,\}/\1[REDACTED]/g;
s/\([?&][Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]=\)[^&#[:space:]<>"'"'"'`]\{1,\}/\1[REDACTED]/g
'

# --- Redact content from stdin ---
redact_content() {
  sed "$REDACTION_PATTERNS"
}

# --- Redact file in-place ---
redact_file() {
  file="$1"

  [ -f "$file" ] || { echo "redaction: file not found: $file" >&2; return 1; }

  # Create temp file with redacted content
  temp_file="${file}.redacted"
  sed "$REDACTION_PATTERNS" "$file" > "$temp_file"

  # Move back
  mv "$temp_file" "$file"
}

# --- Explicit file detection: 0=match, 1=clean, 2=unreadable/not a file ---
has_secrets_file() {
  [ -f "${1:-}" ] && [ -r "$1" ] || return 2
  _sf_redact_original="$(cat < "$1" 2>/dev/null)" || return 2
  _sf_redact_filtered="$(printf '%s' "$_sf_redact_original" | redact_content)" || return 2
  [ "$_sf_redact_original" != "$_sf_redact_filtered" ]
}

# --- Literal content, retaining existing-file compatibility for old callers ---
# File callers use has_secrets_file so a missing path cannot be read as content.
# Use the masking rules themselves so detection cannot omit a supported family.
has_secrets() {
  if [ -f "$1" ]; then
    has_secrets_file "$1"
    return $?
  fi
  _sf_redact_original="$1"
  _sf_redact_filtered="$(printf '%s' "$_sf_redact_original" | redact_content)" || return 2
  [ "$_sf_redact_original" != "$_sf_redact_filtered" ]
}

# --- Count redactions ---
count_redactions() {
  content="$1"

  count=$(echo "$content" | grep -o '\[REDACTED\]' | wc -l)
  echo "$count"
}
