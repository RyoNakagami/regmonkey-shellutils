#!/usr/bin/env bats

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"

    OLD_PATH=$PATH
    PATH="$DIR/../../bin/linux:$PATH"

    TMPDIR_TEST="$(mktemp -d)"

    # fixture passwd file: system users (UID < 1000), human users
    # (1000 <= UID < 65534), and nobody (65534, excluded from "human").
    FIXTURE="$TMPDIR_TEST/passwd"
    cat > "$FIXTURE" <<'EOF'
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
alice:x:1000:1000:Alice:/home/alice:/bin/bash
bob:x:1001:1001:Bob:/home/bob:/bin/zsh
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
EOF
    export PASSWD_FILE="$FIXTURE"
}

teardown() {
    PATH=$OLD_PATH
    rm -rf "$TMPDIR_TEST"
}

# ---------------------------------------------------------------------------
# help / option parsing
# ---------------------------------------------------------------------------

@test "help option -h prints docstring and exits 0" {
    run passwd-ls -h
    assert_success
    assert_output --partial 'Script: passwd-ls'
    assert_output --partial 'Usage:'
}

@test "help option --help prints docstring and exits 0" {
    run passwd-ls --help
    assert_success
    assert_output --partial 'Script: passwd-ls'
}

@test "unknown option fails with error message" {
    run passwd-ls -z
    assert_failure
    assert_output --partial 'Unknown option: -z'
    assert_output --partial 'Use --help'
}

@test "unexpected positional argument fails" {
    run passwd-ls foo
    assert_failure
    assert_output --partial 'Unexpected argument: foo'
}

@test "unreadable passwd file fails with error" {
    export PASSWD_FILE="$TMPDIR_TEST/does-not-exist"
    run passwd-ls
    assert_failure
    assert_output --partial 'Error: cannot read passwd file'
}

# ---------------------------------------------------------------------------
# filtering: human (default) / system / all
# ---------------------------------------------------------------------------

@test "default table shows only human users (UID >= 1000, < 65534)" {
    run passwd-ls
    assert_success
    assert_output --partial 'USERNAME'
    assert_output --partial 'alice'
    assert_output --partial 'bob'
    refute_output --partial 'root'
    refute_output --partial 'daemon'
    refute_output --partial 'nobody'
}

@test "-u behaves the same as the default human filter" {
    run passwd-ls -u
    assert_success
    assert_output --partial 'alice'
    refute_output --partial 'root'
}

@test "-s shows only system users (UID < 1000)" {
    run passwd-ls -s
    assert_success
    assert_output --partial 'root'
    assert_output --partial 'daemon'
    refute_output --partial 'alice'
    refute_output --partial 'bob'
}

@test "-a shows all users including system and nobody" {
    run passwd-ls -a
    assert_success
    assert_output --partial 'root'
    assert_output --partial 'alice'
    assert_output --partial 'nobody'
}

# ---------------------------------------------------------------------------
# JSON output
# ---------------------------------------------------------------------------

@test "-j emits a JSON array with username and numeric uid" {
    run passwd-ls -j
    assert_success
    assert_output --partial '['
    assert_output --partial ']'
    assert_output --partial '"username": "alice"'
    assert_output --partial '"uid": 1000'
}

@test "combined -sj behaves like -s --json" {
    run passwd-ls -sj
    assert_success
    assert_output --partial '"username": "root"'
    refute_output --partial '"username": "alice"'
}

@test "JSON output is parseable by a JSON reader" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available to validate JSON"
    fi
    run passwd-ls -aj
    assert_success
    echo "$output" | python3 -c 'import json,sys; json.load(sys.stdin)'
}
