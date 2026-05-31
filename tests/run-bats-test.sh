#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Author: Ryo Nakagami
# Revised: 2026-05-31
# Script: run-bats-test.sh
# Description:
#   Runs every bats test file under tests/test_for_script/, printing a cyan
#   section header per file so results are grouped by script under test.
#
#   Uses the vendored bats submodule (tests/bats/bin/bats) resolved relative
#   to this script, so it works regardless of PATH or shell aliases and from
#   any working directory.
#
# Usage:
#   bash tests/run-bats-test.sh
#   ./tests/run-bats-test.sh            # if executable
# -----------------------------------------------------------------------------

set -uo pipefail

# Resolve repo paths relative to this script (not the caller's CWD).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
BATS="${SCRIPT_DIR}/bats/bin/bats"
TEST_DIR="${SCRIPT_DIR}/test_for_script"

if [[ ! -x "${BATS}" ]]; then
    echo "Error: bats not found at ${BATS}." >&2
    echo "Initialize submodules with: git submodule update --init" >&2
    exit 1
fi

# Run every file; keep going on failure so all sections are shown, then exit
# non-zero if any section failed.
failures=0
for f in "${TEST_DIR}"/test_*.bats; do
    printf '\n\033[1;36m=== %s ===\033[0m\n' "$(basename "$f" .bats)"
    "${BATS}" "$f" || failures=$((failures + 1))
done

if (( failures > 0 )); then
    printf '\n\033[1;31m%d test file(s) failed.\033[0m\n' "$failures" >&2
    exit 1
fi
