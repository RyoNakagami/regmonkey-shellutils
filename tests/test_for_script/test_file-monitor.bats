#!/usr/bin/env bats

# file-monitor monitors a target file for line count and size changes,
# appending CSV rows to a log file at regular intervals.
#
# Tests use a short -t 2 -n 1 run so the loop fires at least once.

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"

    OLD_PATH=$PATH
    PATH="$DIR/../../bin/measurement:$PATH"

    TMPDIR_TEST="$(mktemp -d)"
    TARGET="$TMPDIR_TEST/target.txt"
    LOG="$TMPDIR_TEST/out.csv"

    printf 'line1\nline2\nline3\n' > "$TARGET"
}

teardown() {
    PATH=$OLD_PATH
    rm -rf "$TMPDIR_TEST"
}

# ---------------------------------------------------------------------------
# help / option parsing
# ---------------------------------------------------------------------------

@test "help option -h prints docstring and exits 0" {
    run file-monitor -h
    assert_success
    assert_output --partial 'Script: file-monitor'
    assert_output --partial 'Usage:'
}

@test "unknown option fails with Error message" {
    run file-monitor -z
    assert_failure
    assert_output --partial 'Error: unknown option: -z'
}

@test "option missing argument fails with Error message" {
    run file-monitor -f
    assert_failure
    assert_output --partial 'Error: option -f requires an argument'
}

# ---------------------------------------------------------------------------
# validation failures
# ---------------------------------------------------------------------------

@test "missing -f fails with Error message" {
    run file-monitor -o "$LOG"
    assert_failure
    assert_output --partial 'Error: -f TARGET_FILE is required.'
}

@test "missing -o fails with Error message" {
    run file-monitor -f "$TARGET"
    assert_failure
    assert_output --partial 'Error: -o LOG_FILE is required.'
}

@test "non-existent target file fails with Error message" {
    run file-monitor -f "$TMPDIR_TEST/no_such.txt" -o "$LOG" -t 1
    assert_failure
    assert_output --partial 'Error: TARGET_FILE does not exist:'
}

@test "invalid -b unit fails with Error message" {
    run file-monitor -f "$TARGET" -o "$LOG" -b TB -t 1
    assert_failure
    assert_output --partial 'Error: -b UNIT must be one of B, KB, MB, GB'
}

@test "non-integer -n fails with Error message" {
    run file-monitor -f "$TARGET" -o "$LOG" -n abc -t 1
    assert_failure
    assert_output --partial 'Error: -n INTERVAL must be a positive integer'
}

@test "zero -n fails with Error message" {
    run file-monitor -f "$TARGET" -o "$LOG" -n 0 -t 1
    assert_failure
    assert_output --partial 'Error: -n INTERVAL must be a positive integer'
}

@test "non-integer -t fails with Error message" {
    run file-monitor -f "$TARGET" -o "$LOG" -t abc
    assert_failure
    assert_output --partial 'Error: -t DURATION must be a positive integer'
}

# ---------------------------------------------------------------------------
# happy path
# ---------------------------------------------------------------------------

@test "basic run creates log with CSV header and data rows (bytes)" {
    run file-monitor -f "$TARGET" -o "$LOG" -n 1 -t 2
    assert_success
    # Header line
    assert [ -f "$LOG" ]
    run head -1 "$LOG"
    assert_output 'timestamp,lines,size_B'
    # At least one data row written
    local rows
    rows=$(wc -l < "$LOG")
    assert [ "$rows" -ge 2 ]
}

@test "data rows contain correct line count" {
    run file-monitor -f "$TARGET" -o "$LOG" -n 1 -t 2
    assert_success
    # Second line should have 3 lines (3 newlines in fixture)
    run awk -F, 'NR==2{print $2}' "$LOG"
    assert_output '3'
}

@test "-b KB produces KB header and decimal size value" {
    run file-monitor -f "$TARGET" -o "$LOG" -n 1 -t 2 -b KB
    assert_success
    run head -1 "$LOG"
    assert_output 'timestamp,lines,size_KB'
    # Size column in data row should be decimal (contains a dot)
    run awk -F, 'NR==2{print $3}' "$LOG"
    assert_output --partial '.'
}

@test "-b MB produces MB header" {
    run file-monitor -f "$TARGET" -o "$LOG" -n 1 -t 2 -b MB
    assert_success
    run head -1 "$LOG"
    assert_output 'timestamp,lines,size_MB'
}

@test "-b GB produces GB header" {
    run file-monitor -f "$TARGET" -o "$LOG" -n 1 -t 2 -b GB
    assert_success
    run head -1 "$LOG"
    assert_output 'timestamp,lines,size_GB'
}

@test "existing non-empty log file is not overwritten (no duplicate header)" {
    # Pre-populate log with a header
    echo 'timestamp,lines,size_B' > "$LOG"
    echo '2026-07-01 00:00:00,0,0' >> "$LOG"
    run file-monitor -f "$TARGET" -o "$LOG" -n 1 -t 2
    assert_success
    # Header must appear exactly once
    local count
    count=$(grep -c 'timestamp,lines' "$LOG")
    assert [ "$count" -eq 1 ]
}
