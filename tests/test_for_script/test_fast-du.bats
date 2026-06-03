#!/usr/bin/env bats

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"

    OLD_PATH=$PATH
    PATH="$DIR/../../bin/fs:$PATH"

    TMPDIR_TEST="$(mktemp -d)"
}

teardown() {
    PATH=$OLD_PATH
    rm -rf "$TMPDIR_TEST"
}

@test "help option prints docstring and exits 0" {
    run fast-du -h
    assert_success
    assert_output --partial 'Script: fast-du'
    assert_output --partial 'Usage:'
}

@test "missing TARGET_DIR argument fails" {
    run fast-du
    assert_failure
    assert_output --partial 'TARGET_DIR is required'
}

@test "nonexistent directory fails" {
    run fast-du "$TMPDIR_TEST/no-such-dir"
    assert_failure
    assert_output --partial 'not a directory'
}

@test "unknown option fails" {
    run fast-du -x "$TMPDIR_TEST"
    assert_failure
    assert_output --partial 'unknown option'
}

@test "non-integer parallel value fails" {
    run fast-du -P abc "$TMPDIR_TEST"
    assert_failure
    assert_output --partial '-P must be a positive integer'
}

@test "zero parallel value fails" {
    run fast-du -P 0 "$TMPDIR_TEST"
    assert_failure
    assert_output --partial '-P must be a positive integer'
}

@test "trailing -P without value fails" {
    run fast-du "$TMPDIR_TEST" -P
    assert_failure
    assert_output --partial '-P requires a value'
}

@test "too many positional arguments fails" {
    run fast-du "$TMPDIR_TEST" "$TMPDIR_TEST"
    assert_failure
    assert_output --partial 'too many arguments'
}

@test "happy path: lists each item with a size column" {
    mkdir -p "$TMPDIR_TEST/target/beta"
    printf 'hello world\n' > "$TMPDIR_TEST/target/alpha.txt"
    printf 'nested\n' > "$TMPDIR_TEST/target/beta/inner.txt"

    run fast-du "$TMPDIR_TEST/target"
    assert_success
    assert_output --partial 'alpha.txt'
    assert_output --partial 'beta'
    assert_output --regexp '^[0-9]+(\.[0-9]+)?[KMGT]?[[:blank:]]'
}

@test "happy path: explicit -P parallelism works" {
    mkdir -p "$TMPDIR_TEST/target"
    printf 'data\n' > "$TMPDIR_TEST/target/file.txt"

    run fast-du -P 4 "$TMPDIR_TEST/target"
    assert_success
    assert_output --partial 'file.txt'
}

@test "empty directory succeeds with no output" {
    mkdir -p "$TMPDIR_TEST/empty"

    run fast-du "$TMPDIR_TEST/empty"
    assert_success
    assert_output ''
}