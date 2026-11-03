#!/bin/sh
# Package-boundary gate: every tracked top-level entry must be classified in
# docs/ship-manifest.md as either runtime SHIP surface or dev-only STRIP-able,
# and every SHIP path must exist. This stops a new top-level directory from
# silently landing on either side of the ship boundary unreviewed. It is a
# CHECK, not a build step — it changes nothing about what ships today.
#
# Run from the repo root (run-tests.sh does this). POSIX sh.
set -eu

SELF="$(CDPATH= cd -- "$(dirname "$0")" && pwd)/$(basename "$0")"
ROOT="${1:-.}"
cd "$ROOT"

# Runtime surface a plugin consumer needs.
SHIP=".claude-plugin skills report-standard templates hooks LICENSE README.md CHANGELOG.md SECURITY.md"
# Dev-only paths safe to strip from a published artifact.
DEV=".claude .github .gitignore .gitleaksignore AGENTS.md CLAUDE.md GEMINI.md CONTRIBUTING.md ENGINEERING.md ci docs tests"

MANIFEST="docs/ship-manifest.md"
[ -f "$MANIFEST" ] || { echo "PACKAGE-BOUNDARY: $MANIFEST missing (the boundary must be declared)" >&2; exit 1; }

rc=0

# A development directory classification does not permit nested agent checkouts.
# Git links without a corresponding submodule definition break checkout cleanup;
# ordinary files from those local checkouts must not enter the package either.
check_agent_worktrees() (
  tracked=$(git -C "$1" ls-files --stage -- .claude/worktrees) || {
    echo 'PACKAGE-BOUNDARY: could not inspect the Git index' >&2; exit 1;
  }
  [ -z "$tracked" ] || {
    echo 'PACKAGE-BOUNDARY: tracked .claude/worktrees/ entries are local-only; remove them from the index without deleting local worktrees' >&2
    exit 1
  }
)

# 1. Every tracked top-level entry is classified in exactly one list.
if command -v git >/dev/null 2>&1 && [ -e .git ]; then
  check_agent_worktrees . || rc=1
  entries="$(git ls-files | sed 's#/.*##' | sort -u)"
else
  entries="$(ls -A | grep -v '^scoutflo-audits$' | sort -u)"
fi
for e in $entries; do
  case " $SHIP $DEV " in
    *" $e "*) : ;;
    *) echo "PACKAGE-BOUNDARY: top-level '$e' is not classified in docs/ship-manifest.md (add it to the SHIP runtime surface or the DEV-only list, then reflect it in $MANIFEST)" >&2; rc=1 ;;
  esac
done

# 2. Every declared SHIP path exists (a runtime surface can't name a missing dir).
for s in $SHIP; do
  [ -e "$s" ] || { echo "PACKAGE-BOUNDARY: declared SHIP path '$s' does not exist" >&2; rc=1; }
done

# 3. The manifest names both halves (keep the doc and the gate in lockstep).
grep -q 'Runtime surface (SHIP' "$MANIFEST" || { echo "PACKAGE-BOUNDARY: $MANIFEST lost its 'Runtime surface (SHIP' section" >&2; rc=1; }
grep -q 'Dev-only (STRIP' "$MANIFEST" || { echo "PACKAGE-BOUNDARY: $MANIFEST lost its 'Dev-only (STRIP' section" >&2; rc=1; }

# 4. Exercise the index boundary in a disposable repository, including when the
# main gate runs on a Git-free archive. No commit or working directory is removed.
if command -v git >/dev/null 2>&1 && [ "${SCOUTFLO_PACKAGE_BOUNDARY_FIXTURE:-0}" != 1 ]; then
  fixture=$(mktemp -d)
  trap 'rm -rf "$fixture"' EXIT HUP INT TERM
  mkdir -p "$fixture/home" "$fixture/repo/.claude/worktrees/example"
  # Use no inherited Git templates or configuration in this synthetic repository.
  (
    HOME="$fixture/home"; GIT_CONFIG_GLOBAL=/dev/null; GIT_CONFIG_NOSYSTEM=1
    export HOME GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
    git -C "$fixture/repo" init --quiet --template=
    for path in $SHIP; do mkdir -p "$fixture/repo/$path"; done
    mkdir -p "$fixture/repo/docs"
    cp "$MANIFEST" "$fixture/repo/$MANIFEST"
    printf 'keep local working files\n' > "$fixture/repo/.claude/worktrees/example/local.txt"
    check_agent_worktrees "$fixture/repo" || exit 1
    # Run the real entrypoint too. The flag disables only nested self-fixtures,
    # never the main index guard, so removing its invocation fails this test.
    SCOUTFLO_PACKAGE_BOUNDARY_FIXTURE=1 sh "$SELF" "$fixture/repo" > "$fixture/result" 2>&1 || {
      echo 'PACKAGE-BOUNDARY: clean integration fixture failed' >&2; exit 1;
    }
    # The referent need not be a checked-out commit: the tracked mode/path itself
    # is the boundary being tested, so use an inert object made in this fixture.
    object=$(git -C "$fixture/repo" hash-object -w --stdin </dev/null)
    git -C "$fixture/repo" update-index --add --cacheinfo 160000 "$object" .claude/worktrees/example
    if check_agent_worktrees "$fixture/repo" > "$fixture/result" 2>&1; then
      echo 'PACKAGE-BOUNDARY: regression fixture accepted a tracked agent Git link' >&2; exit 1
    fi
    grep -q 'tracked .claude/worktrees/' "$fixture/result" || exit 1
    if SCOUTFLO_PACKAGE_BOUNDARY_FIXTURE=1 sh "$SELF" "$fixture/repo" > "$fixture/result" 2>&1; then
      echo 'PACKAGE-BOUNDARY: entrypoint failed to reject a tracked agent Git link' >&2; exit 1
    fi
    grep -q 'tracked .claude/worktrees/' "$fixture/result" || exit 1
    git -C "$fixture/repo" update-index --force-remove -- .claude/worktrees/example
    check_agent_worktrees "$fixture/repo" || exit 1
    [ -f "$fixture/repo/.claude/worktrees/example/local.txt" ] || {
      echo 'PACKAGE-BOUNDARY: index cleanup removed local working files' >&2; exit 1;
    }
    # A forced add of ordinary local-worktree files must fail the same boundary.
    git -C "$fixture/repo" add -- .claude/worktrees/example/local.txt
    if check_agent_worktrees "$fixture/repo" > "$fixture/result" 2>&1; then
      echo 'PACKAGE-BOUNDARY: regression fixture accepted tracked local-worktree files' >&2; exit 1
    fi
    git -C "$fixture/repo" update-index --force-remove -- .claude/worktrees/example/local.txt
    git -C "$fixture/repo" update-index --add --cacheinfo 160000 "$object" .claude/worktrees
    if check_agent_worktrees "$fixture/repo" > "$fixture/result" 2>&1; then
      echo 'PACKAGE-BOUNDARY: regression fixture accepted the worktrees root as a Git link' >&2; exit 1
    fi
  ) || rc=1
fi

[ "$rc" = 0 ] && echo "PACKAGE-BOUNDARY-OK (every tracked top-level entry is classified; SHIP surface exists)"
exit "$rc"
