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

# stat helper that returns octal permission like "0755" / "0644"
_mode_of() {
    stat -c '%a' "$1"
}

@test "help option prints docstring and exits 0" {
    run ptouch -h
    assert_success
    assert_output --partial 'Script: ptouch'
    assert_output --partial 'Usage:'
}

@test "missing path argument fails with error" {
    run ptouch
    assert_failure
    assert_output --partial 'Error: <path> argument is required.'
}

@test "unknown option fails" {
    run ptouch --no-such-flag "$TMPDIR_TEST/a"
    assert_failure
    assert_output --partial 'Error: unknown option: --no-such-flag'
}

@test "invalid permission mode fails" {
    run ptouch -m 9abc "$TMPDIR_TEST/a"
    assert_failure
    assert_output --partial 'Error: invalid permission mode'
}

@test "more than one positional path fails" {
    run ptouch "$TMPDIR_TEST/a" "$TMPDIR_TEST/b"
    assert_failure
    assert_output --partial 'only one <path> argument'
}

@test "creates file with parents at default 755" {
    target="$TMPDIR_TEST/a/b/c/file.sh"
    run ptouch "$target"
    assert_success
    [ -f "$target" ]
    [ ! -s "$target" ]
    [ "$(_mode_of "$target")" = "755" ]
}

@test "creates file with custom mode via -m" {
    target="$TMPDIR_TEST/conf/app.conf"
    run ptouch -m 644 "$target"
    assert_success
    [ -f "$target" ]
    [ "$(_mode_of "$target")" = "644" ]
}

@test "creates file with custom mode via --permission=" {
    target="$TMPDIR_TEST/secret/key"
    run ptouch --permission=600 "$target"
    assert_success
    [ -f "$target" ]
    [ "$(_mode_of "$target")" = "600" ]
}

@test "refuses to overwrite existing file without --force" {
    target="$TMPDIR_TEST/existing"
    echo "original" > "$target"
    run ptouch "$target"
    assert_failure
    assert_output --partial 'already exists'
    # untouched
    run cat "$target"
    assert_output 'original'
}

@test "overwrites existing file with --force and applies mode" {
    target="$TMPDIR_TEST/existing"
    echo "original" > "$target"
    chmod 644 "$target"
    run ptouch -f -m 600 "$target"
    assert_success
    [ -f "$target" ]
    [ ! -s "$target" ]
    [ "$(_mode_of "$target")" = "600" ]
}

@test "refuses when path is an existing directory" {
    target="$TMPDIR_TEST/somedir"
    mkdir -p "$target"
    run ptouch "$target"
    assert_failure
    assert_output --partial 'existing directory'
}
