#!/usr/bin/env bats

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"

    OLD_PATH=$PATH
    PATH="$DIR/../../bin/fs:$PATH"

    TMPDIR_TEST="$(mktemp -d)"

    # Populate a sandbox with files of known modification times.
    touch -d "10 days ago" "$TMPDIR_TEST/old.log"
    touch -d "2 days ago"  "$TMPDIR_TEST/mid.log"
    touch -d "1 hour ago"  "$TMPDIR_TEST/new.log"
    touch -d "1 hour ago"  "$TMPDIR_TEST/note.txt"
}

teardown() {
    PATH=$OLD_PATH
    rm -rf "$TMPDIR_TEST"
}

# -----------------------------------------------------------------------------
# help / version
# -----------------------------------------------------------------------------

@test "help option prints docstring and exits 0" {
    run fd-recent-file -h
    assert_success
    assert_output --partial 'Script: fd-recent-file'
    assert_output --partial 'Usage:'
}

@test "--help long option prints docstring and exits 0" {
    run fd-recent-file --help
    assert_success
    assert_output --partial 'Script: fd-recent-file'
}

@test "version option prints package version and exits 0" {
    run fd-recent-file -v
    assert_success
    assert_output --partial 'regmonkey-shellutils'
}

@test "--version long option prints package version and exits 0" {
    run fd-recent-file --version
    assert_success
    assert_output --partial 'regmonkey-shellutils'
}

# -----------------------------------------------------------------------------
# argument validation
# -----------------------------------------------------------------------------

@test "missing required -s and -p fails" {
    run fd-recent-file
    assert_failure
    assert_output --partial 'are required'
}

@test "missing -p fails" {
    run fd-recent-file -s '\.log$'
    assert_failure
    assert_output --partial 'are required'
}

@test "missing -s fails" {
    run fd-recent-file -p "$TMPDIR_TEST"
    assert_failure
    assert_output --partial 'are required'
}

@test "nonexistent search path fails" {
    run fd-recent-file -s '\.log$' -p "$TMPDIR_TEST/no-such-dir"
    assert_failure
    assert_output --partial 'not a directory'
}

@test "non-integer depth fails" {
    run fd-recent-file -s '\.log$' -p "$TMPDIR_TEST" -d abc
    assert_failure
    assert_output --partial '-d must be a positive integer'
}

@test "zero depth fails" {
    run fd-recent-file -s '\.log$' -p "$TMPDIR_TEST" -d 0
    assert_failure
    assert_output --partial '-d must be a positive integer'
}

@test "unknown option fails" {
    run fd-recent-file -Z
    assert_failure
    assert_output --partial 'unknown option'
}

@test "option requiring an argument without one fails" {
    run fd-recent-file -s
    assert_failure
    assert_output --partial 'requires an argument'
}

@test "unexpected positional argument fails" {
    run fd-recent-file -s '\.log$' -p "$TMPDIR_TEST" extra
    assert_failure
    assert_output --partial 'unexpected argument'
}

@test "unparseable -a value fails" {
    run fd-recent-file -s '\.log$' -p "$TMPDIR_TEST" -a 'not a date'
    assert_failure
    assert_output --partial "could not parse -a value"
}

@test "unparseable -b value fails" {
    run fd-recent-file -s '\.log$' -p "$TMPDIR_TEST" -a '' -b 'not a date'
    assert_failure
    assert_output --partial "could not parse -b value"
}

@test "empty time window (a >= b) fails" {
    run fd-recent-file -s '\.log$' -p "$TMPDIR_TEST" -a 2025-02-01 -b 2025-01-01
    assert_failure
    assert_output --partial 'empty window'
}

# -----------------------------------------------------------------------------
# happy paths: time-window filtering
# -----------------------------------------------------------------------------

@test "last 7 days (-a 7d) includes recent files, excludes old" {
    run fd-recent-file -s '\.log$' -p "$TMPDIR_TEST" -a 7d
    assert_success
    assert_output --partial 'mid.log'
    assert_output --partial 'new.log'
    refute_output --partial 'old.log'
}

@test "older-than window (-a '' -b 7d) includes only old files" {
    run fd-recent-file -s '\.log$' -p "$TMPDIR_TEST" -a '' -b 7d
    assert_success
    assert_output --partial 'old.log'
    refute_output --partial 'mid.log'
    refute_output --partial 'new.log'
}

@test "bounded window (-a 3d -b 1d) keeps only mid file" {
    run fd-recent-file -s '\.log$' -p "$TMPDIR_TEST" -a 3d -b 1d
    assert_success
    assert_output --partial 'mid.log'
    refute_output --partial 'old.log'
    refute_output --partial 'new.log'
}

@test "regex pattern restricts by extension" {
    run fd-recent-file -s '\.txt$' -p "$TMPDIR_TEST" -a 7d
    assert_success
    assert_output --partial 'note.txt'
    refute_output --partial '.log'
}

@test "deprecated -t alias behaves like -a" {
    run fd-recent-file -s '\.log$' -p "$TMPDIR_TEST" -t 7d
    assert_success
    assert_output --partial 'new.log'
    refute_output --partial 'old.log'
}

@test "no lower bound and no upper bound (-a '') lists all matches" {
    run fd-recent-file -s '\.log$' -p "$TMPDIR_TEST" -a ''
    assert_success
    assert_output --partial 'old.log'
    assert_output --partial 'mid.log'
    assert_output --partial 'new.log'
}

@test "output includes an ISO 8601 timestamp column" {
    run fd-recent-file -s '\.log$' -p "$TMPDIR_TEST" -a 7d
    assert_success
    assert_output --regexp '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}'
}

@test "no matching files produces empty output and succeeds" {
    run fd-recent-file -s '\.nomatch$' -p "$TMPDIR_TEST" -a 7d
    assert_success
    assert_output ''
}

# -----------------------------------------------------------------------------
# dependency handling / fd binary resolution
# -----------------------------------------------------------------------------

@test "FD_BIN override is honoured" {
    # A fake fd that emits one NUL-terminated path from the sandbox.
    local fakebin="$TMPDIR_TEST/fakefd.sh"
    cat > "$fakebin" <<EOF
#!/bin/bash
printf '%s\\0' "$TMPDIR_TEST/new.log"
EOF
    chmod +x "$fakebin"

    FD_BIN="$fakebin" run fd-recent-file -s '\.log$' -p "$TMPDIR_TEST" -a 7d
    assert_success
    assert_output --partial 'new.log'
}

@test "missing fd binary fails with a clear error" {
    FD_BIN="definitely-not-a-real-binary-xyz" run fd-recent-file -s '\.log$' -p "$TMPDIR_TEST" -a 7d
    assert_failure
    assert_output --partial 'fd binary not found'
}
