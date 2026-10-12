#!/bin/sh
# test-crossblock-gate.sh — falsifiable fixtures for ci/crossblock-check.sh.
# The shipped repo passes. A set-u block reading a variable another block assigns is
# rejected, and so is an inline write command ("Rollback: `kubectl ... delete ...`") that
# reads block variables: in a fresh shell those are unset and the command falls back to the
# current context/namespace/profile/project. A self-contained fenced rollback block, a
# read-only inline command, a placeholder-only inline command and an inline command that
# reads only a user-exported secret all pass.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$ROOT/ci/crossblock-check.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

# 1) the shipped repo passes
sh "$GATE" "$ROOT" >/dev/null 2>&1 || fail "gate rejects the shipped repo"

# 2) fenced-block class: a set-u block reads a variable only another block assigns
mkdir -p "$WORK/fenced/skills/setup-x"
cat > "$WORK/fenced/skills/setup-x/SKILL.md" <<'EOF'
# x
```bash
set -eu
TOTAL="3"
```
```bash
set -eu
echo "$TOTAL"
```
EOF
sh "$GATE" "$WORK/fenced" >/dev/null 2>&1 && fail "gate accepted a set-u block reading another block's variable"

# 3) inline class: a write command in prose that reads block variables is rejected (kubectl, aws, curl DELETE)
for cmd in \
  'kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" delete pdb alertmanager' \
  'aws logs delete-subscription-filter --log-group-name "$LOG_GROUP" --filter-name sink' \
  'curl -X DELETE "${API}/projects/${ORG}/uptime/${CHECK_ID}/"'; do
  rm -rf "$WORK/inline"; mkdir -p "$WORK/inline/skills/setup-x"
  printf '# x\n```bash\nset -eu\nKUBE_CONTEXT="ctx"\n```\n\nRollback: `%s`.\n' "$cmd" > "$WORK/inline/skills/setup-x/SKILL.md"
  out="$(sh "$GATE" "$WORK/inline" 2>&1)" && fail "gate accepted an inline write command: $cmd"
  printf '%s' "$out" | grep -q 'inline write command reads' || fail "rejection did not name the inline write class: $cmd"
done

# 4) the same rollback as a self-contained fenced block passes
mkdir -p "$WORK/selfcontained/skills/setup-x"
cat > "$WORK/selfcontained/skills/setup-x/SKILL.md" <<'EOF'
# x
Rollback, in its own fresh shell:
```bash
set -eu
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
MON_NS="monitoring"                # kubernetes.monitoring_namespace
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" delete pdb alertmanager
```
EOF
sh "$GATE" "$WORK/selfcontained" >/dev/null 2>&1 || fail "gate rejected a self-contained fenced rollback block"

# 5) read-only, placeholder-only and exported-secret-only inline commands pass
mkdir -p "$WORK/benign/skills/audit-x"
cat > "$WORK/benign/skills/audit-x/SKILL.md" <<'EOF'
# x
Read the labels first (`kubectl get pods -n "$MON_NS" --show-labels`).
Rollback: `kubectl delete pdb <name>` after choosing the PDB.
Remove a test check with `curl -X DELETE -H "Authorization: Bearer ${SENTRY_TOKEN}" https://sentry.example.com/api/0/x/`.
EOF
sh "$GATE" "$WORK/benign" >/dev/null 2>&1 || fail "gate rejected a read-only, placeholder-only or exported-secret-only inline command"

# 6) setup skills: an undo step written as a one-line note is rejected even with only placeholders,
#    in prose and as a comment inside a command block
rm -rf "$WORK/note"; mkdir -p "$WORK/note/skills/setup-x"
printf '# x\nRollback = `kubectl delete pdb <app>-pdb -n <ns>`.\n' > "$WORK/note/skills/setup-x/SKILL.md"
out="$(sh "$GATE" "$WORK/note" 2>&1)" && fail "gate accepted a one-line undo note in a setup skill"
printf '%s' "$out" | grep -q 'undo step written as a one-line note' || fail "rejection did not name the one-line undo class"
rm -rf "$WORK/comment"; mkdir -p "$WORK/comment/skills/setup-x"
printf '# x\n```bash\nset -eu\n# ANNOUNCE this manifest; rollback = kubectl delete networkpolicy <name> -n <ns>\necho ok\n```\n' > "$WORK/comment/skills/setup-x/SKILL.md"
out="$(sh "$GATE" "$WORK/comment" 2>&1)" && fail "gate accepted an undo step hidden in a comment"
printf '%s' "$out" | grep -q 'undo step hidden in a comment' || fail "rejection did not name the comment undo class"

# 7) a setup skill that points at its rollback block, or warns against a command, passes
mkdir -p "$WORK/pointer/skills/setup-x"
cat > "$WORK/pointer/skills/setup-x/SKILL.md" <<'EOF'
# x
Rollback: run the rollback block below. Never `kubectl apply` the raw backup.
Rollback is the policy rollback block in the section above, `NEW_POLICY` set to the printed name.
EOF
sh "$GATE" "$WORK/pointer" >/dev/null 2>&1 || fail "gate rejected a pointer to a rollback block or a warning"

echo "CROSSBLOCK-GATE-OK (fenced and inline cross-block classes and one-line setup undo notes rejected; self-contained, pointer and benign forms pass)"
