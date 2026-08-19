#!/bin/sh
# tests/selftest-hermetic.sh — CI entry for the reusable self-test's hermetic layers.
#
# ci/run-tests.sh globs tests/*.sh and runs each under /bin/sh, so this exposes the
# self-test's regression fixtures (the validator adversarial cases + the
# cross-cutting libs) to CI. It runs ONLY the validators + capstone layers, never
# the mechanical layer — mechanical calls ci/run-tests.sh, which would recurse.
# Those two layers are fully hermetic (jq only; no creds, no docker, no network).
set -eu

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

sh "$DIR/selftest/run.sh" --layer validators >/dev/null 2>&1 \
  || { echo "SELFTEST-HERMETIC-FAIL: validators layer had a failing case (run: sh tests/selftest/run.sh --layer validators)"; exit 1; }
sh "$DIR/selftest/run.sh" --layer capstone >/dev/null 2>&1 \
  || { echo "SELFTEST-HERMETIC-FAIL: capstone layer had a failing case (run: sh tests/selftest/run.sh --layer capstone)"; exit 1; }

echo "SELFTEST-HERMETIC-OK (validator fixtures + cross-cutting libs)"
