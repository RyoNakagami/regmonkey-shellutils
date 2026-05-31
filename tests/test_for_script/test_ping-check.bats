#!/usr/bin/env bats

# Note: these tests do NOT require an internet connection. 'ping' is stubbed
# in a sandbox bin/ directory placed ahead of the script dir on PATH, so the
# script's behavior is verified deterministically and offline. The ping stub
# simply echoes the arguments it received so assertions can inspect the
# IP version, packet count, and target that the script chose.

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"

    OLD_PATH=$PATH
    TMPDIR_TEST="$(mktemp -d)"

    # Sandbox bin for command stubs; placed before the real script dir.
    STUB_BIN="$TMPDIR_TEST/bin"
    mkdir -p "$STUB_BIN"
    PATH="$STUB_BIN:$DIR/../../bin/network:$PATH"

    # Default ping stub: echo the arguments so tests can assert on them.
    _stub ping <<'EOF'
#!/bin/bash
echo "ping-args: $*"
EOF
}

teardown() {
    PATH=$OLD_PATH
    rm -rf "$TMPDIR_TEST"
}

# Write an executable stub onto the sandbox PATH.
_stub() {
    local name="$1"
    cat >"$STUB_BIN/$name"
    chmod +x "$STUB_BIN/$name"
}

@test "help option prints docstring and exits 0" {
    run ping-check -h
    assert_success
    assert_output --partial 'Script: ping-check'
    assert_output --partial 'Usage:'
}

@test "--help also prints docstring and exits 0" {
    run ping-check --help
    assert_success
    assert_output --partial 'Script: ping-check'
}

@test "unknown option fails with error" {
    run ping-check --no-such-flag
    assert_failure
    assert_output --partial 'Error: unknown option: --no-such-flag'
}

@test "--count requires a numeric argument" {
    run ping-check -c abc
    assert_failure
    assert_output --partial 'Error: --count requires a numeric argument.'
}

@test "--count with no argument fails" {
    run ping-check --count
    assert_failure
    assert_output --partial 'Error: --count requires a numeric argument.'
}

@test "default uses IPv4 and 8.8.8.8 with 3 packets" {
    run ping-check
    assert_success
    assert_output --partial 'ping-args: -4 -c 3 8.8.8.8'
}

@test "-6 default target is Google IPv6 DNS" {
    run ping-check -6
    assert_success
    assert_output --partial 'ping-args: -6 -c 3 2001:4860:4860::8888'
}

@test "--v6 long flag behaves like -6" {
    run ping-check --v6
    assert_success
    assert_output --partial 'ping-args: -6 -c 3 2001:4860:4860::8888'
}

@test "custom target on IPv4" {
    run ping-check google.com
    assert_success
    assert_output --partial 'ping-args: -4 -c 3 google.com'
}

@test "-6 with custom target keeps the target" {
    run ping-check -6 google.com
    assert_success
    assert_output --partial 'ping-args: -6 -c 3 google.com'
}

@test "-c sets the packet count" {
    run ping-check -c 5
    assert_success
    assert_output --partial 'ping-args: -4 -c 5 8.8.8.8'
}

@test "-c and target combine" {
    run ping-check -c 5 yahoo.com
    assert_success
    assert_output --partial 'ping-args: -4 -c 5 yahoo.com'
}

@test "exit code propagates from ping (failure)" {
    _stub ping <<'EOF'
#!/bin/bash
echo "ping failed" >&2
exit 1
EOF
    run ping-check 192.0.2.1
    assert_failure
}
