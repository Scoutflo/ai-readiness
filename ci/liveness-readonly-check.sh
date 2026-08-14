#!/bin/sh
# liveness-readonly-check.sh — mechanically enforce that the shared live-evidence
# library can only ever make READ-ONLY calls.
#
# Why this exists: rca (and later audit-kubernetes) now make live kubectl calls
# through skills/live-evidence/lib. A live-call surface is exactly where a
# read-only guarantee erodes over time — a well-meaning edit adds a `kubectl
# rollout restart` to "just nudge it". This gate makes that impossible to ship:
# it proves every kubectl invocation in the lib routes through the guarded
# le_kubectl wrapper and uses only an allowlisted read verb, and that no
# mutating verb or secret-value read appears anywhere in the lib code. It is the
# same mechanical rigor as redaction-parity-check.sh — a promise in prose is not
# a guarantee; a CI gate is.
#
# Read-only. POSIX sh + grep/awk.
set -eu
DIR="${1:-.}"
LIBDIR="$DIR/skills/live-evidence/lib"
[ -d "$LIBDIR" ] || { echo "LIVENESS-READONLY: $LIBDIR not found"; exit 1; }

ALLOWED="get describe list logs top events version api-resources auth config"
# Mutating / dangerous kubectl verbs and subcommands that must never appear.
FORBIDDEN='apply|create|edit|patch|replace|delete|scale|rollout|exec|cp|port-forward|proxy|annotate|label|cordon|uncordon|drain|taint|debug|attach|run|set|apply'
FAIL=0
found_lib=0

for f in "$LIBDIR"/*.sh; do
  [ -f "$f" ] || continue
  found_lib=1
  # Only inspect code, never the documentation comments (which legitimately
  # enumerate the forbidden verbs to explain the policy).
  CODE="$(grep -vE '^[[:space:]]*#' "$f" || true)"
  # For invocation/verb detection, blank out double-quoted string contents so a
  # "kubectl" mentioned inside an echo message is not mistaken for a call.
  STRIPPED="$(printf '%s\n' "$CODE" | sed 's/"[^"]*"/""/g')"

  # 1. No mutating kubectl verb on any real command line (not across a pipe).
  if printf '%s\n' "$STRIPPED" | grep -Eq "kubectl[^|;&]*[[:space:]](${FORBIDDEN})([[:space:]]|\"|=|\$)"; then
    echo "LIVENESS-READONLY: $f contains a forbidden (mutating) kubectl verb:"
    printf '%s\n' "$STRIPPED" | grep -En "kubectl[^|;&]*[[:space:]](${FORBIDDEN})([[:space:]]|\"|=|\$)" || true
    FAIL=1
  fi

  # 2. Never read secret VALUES.
  if printf '%s\n' "$STRIPPED" | grep -Eq "get[[:space:]]+secret([[:space:]][^|]*)?-o[[:space:]]+(yaml|json)"; then
    echo "LIVENESS-READONLY: $f reads secret values (get secret -o yaml|json is forbidden)"
    FAIL=1
  fi

  # 3. Exactly ONE raw kubectl invocation (the le_kubectl wrapper); every other
  #    kubectl usage must route through le_kubectl. Exclude "le_kubectl" (word
  #    char before kubectl) and `command -v kubectl` (an existence check, not a
  #    call). Detection runs on STRIPPED so echo-message mentions don't count.
  RAW="$(printf '%s\n' "$STRIPPED" | grep -nE '(^|[^_[:alnum:]])kubectl[[:space:]]' | grep -vE 'le_kubectl|command[[:space:]]+-v[[:space:]]+kubectl' || true)"
  RAWN="$(printf '%s' "$RAW" | grep -c . || true)"
  if [ "${RAWN:-0}" -ne 1 ]; then
    echo "LIVENESS-READONLY: $f must call kubectl only through the le_kubectl wrapper (found ${RAWN:-0} raw invocation(s), expected exactly 1):"
    printf '%s\n' "$RAW"
    FAIL=1
  else
    printf '%s\n' "$RAW" | grep -q -- '--context' || { echo "LIVENESS-READONLY: $f — the kubectl wrapper must pin --context explicitly"; FAIL=1; }
    printf '%s\n' "$RAW" | grep -q -- '--request-timeout' || { echo "LIVENESS-READONLY: $f — the kubectl wrapper must bound calls with --request-timeout"; FAIL=1; }
  fi

  # 4. Every le_kubectl call site passes an allowlisted verb as its 2nd argument.
  BADVERBS="$(printf '%s\n' "$CODE" \
    | grep -oE 'le_kubectl[[:space:]]+"[^"]*"[[:space:]]+[a-z][a-z-]*' \
    | awk '{print $3}' \
    | while read -r v; do
        ok=0; for a in $ALLOWED; do [ "$v" = "$a" ] && ok=1; done
        [ "$ok" = "1" ] || echo "$v"
      done)"
  if [ -n "$BADVERBS" ]; then
    echo "LIVENESS-READONLY: $f has le_kubectl call(s) with a non-allowlisted verb: $(printf '%s' "$BADVERBS" | tr '\n' ' ')"
    FAIL=1
  fi
done

[ "$found_lib" -eq 1 ] || { echo "LIVENESS-READONLY: no *.sh found under $LIBDIR"; exit 1; }
[ "$FAIL" -eq 0 ] || { echo "LIVENESS-READONLY CHECK FAILED"; exit 1; }
echo "LIVENESS-READONLY-OK (live-evidence lib routes all kubectl through the guarded wrapper; read verbs only, no mutation, no secret-value reads)"
