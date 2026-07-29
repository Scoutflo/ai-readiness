#!/bin/sh
# redaction.sh
# Global regex-based redaction for secrets in reports

set -eu

# Redaction patterns (in order of specificity)
REDACTION_PATTERNS='
s/AKIA[0-9A-Z]\{16\}/AKIA[REDACTED]/g;
s/sk_live_[A-Za-z0-9]\{24,\}/sk_live_[REDACTED]/g;
s/sk_test_[A-Za-z0-9]\{24,\}/sk_test_[REDACTED]/g;
s/Bearer [A-Za-z0-9._-]\{40,\}/Bearer [REDACTED]/g;
s/api_key_[A-Za-z0-9]\{32,\}/api_key_[REDACTED]/g;
s/ASIA[0-9A-Z]\{16\}/ASIA[REDACTED]/g;
s/wJalrXUtnFEMI[A-Za-z0-9/+]\{32,\}/wJalrXUtnFEMI[REDACTED]/g;
s/github_pat_[A-Za-z0-9]\{36,\}/github_pat_[REDACTED]/g
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

# --- Check if content has secrets (before redacting) ---
has_secrets() {
  content="$1"

  echo "$content" | grep -E 'AKIA[0-9A-Z]{16}|sk_live_[A-Za-z0-9]{24,}|Bearer [A-Za-z0-9._-]{40,}' > /dev/null 2>&1 || return 1

  return 0
}

# --- Count redactions ---
count_redactions() {
  content="$1"

  count=$(echo "$content" | grep -o '\[REDACTED\]' | wc -l)
  echo "$count"
}
