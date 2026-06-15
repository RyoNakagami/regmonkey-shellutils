#!/usr/bin/env bats

# Note: these tests do NOT require an internet connection. 'curl' and 'jq'
# are stubbed in a sandbox bin/ directory placed ahead of the script dir on
# PATH, so the script's behavior is verified deterministically and offline.

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

    # A minimal PATH that provides the coreutils the script/stubs need
    # (dirname, cat, bash, ...) but deliberately omits curl/jq, so we can
    # simulate "command not found" without breaking the rest of the script.
    MIN_BIN="$TMPDIR_TEST/minbin"
    mkdir -p "$MIN_BIN"
    for cmd in bash dirname cat printf env; do
        src="$(command -v "$cmd" || true)"
        [ -n "$src" ] && ln -sf "$src" "$MIN_BIN/$cmd"
    done
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
    run fetch-globalip -h
    assert_success
    assert_output --partial 'Script: fetch-globalip'
    assert_output --partial 'Usage:'
}

@test "--help also prints docstring and exits 0" {
    run fetch-globalip --help
    assert_success
    assert_output --partial 'Script: fetch-globalip'
}

@test "unknown option fails with error" {
    run fetch-globalip --no-such-flag
    assert_failure
    assert_output --partial 'Error: unknown option: --no-such-flag'
}

@test "legacy -v4 flag is no longer accepted" {
    run fetch-globalip -v4
    assert_failure
    assert_output --partial 'Error: unknown option: -v4'
}

@test "positional argument is rejected" {
    run fetch-globalip extra-arg
    assert_failure
    assert_output --partial "Error: no positional arguments are accepted (got 'extra-arg')."
}

@test "--timeout requires a numeric argument" {
    run fetch-globalip --timeout abc
    assert_failure
    assert_output --partial 'Error: --timeout requires a numeric argument.'
}

@test "missing curl fails" {
    # PATH has coreutils but no curl/jq.
    PATH="$MIN_BIN:$DIR/../../bin/network"
    run fetch-globalip
    assert_failure
    assert_output --partial "Error: 'curl' command not found in PATH."
}

@test "JSON mode (default) pipes the response through jq" {
    _stub curl <<'EOF'
#!/bin/bash
# Ignore args; emit a canned ifconfig.co payload.
echo '{"ip":"203.0.113.7","country":"Japan"}'
EOF
    _stub jq <<'EOF'
#!/bin/bash
# Minimal stub: prove the response is fed to jq on stdin, then mark it.
sed 's/^/[jq] /'
EOF
    run fetch-globalip
    assert_success
    assert_output --partial '[jq] {"ip":"203.0.113.7","country":"Japan"}'
}

@test "JSON mode without jq warns and prints the raw response" {
    _stub curl <<'EOF'
#!/bin/bash
echo '{"ip":"203.0.113.7"}'
EOF
    # No jq on PATH; coreutils + the curl stub only.
    cp "$STUB_BIN/curl" "$MIN_BIN/curl"
    PATH="$MIN_BIN:$DIR/../../bin/network"
    run fetch-globalip
    assert_success
    assert_output --partial "Warning: 'jq' is not installed"
    assert_output --partial '{"ip":"203.0.113.7"}'
}

@test "--v4 mode queries inet-ip.info and prints the plain IP" {
    _stub curl <<'EOF'
#!/bin/bash
# Confirm the IPv4-only endpoint is targeted, then emit a plain address.
case "$*" in
    *inet-ip.info*) echo '198.51.100.42' ;;
    *) echo "unexpected curl target: $*" >&2; exit 1 ;;
esac
EOF
    run fetch-globalip --v4
    assert_success
    assert_output --partial '198.51.100.42'
}

@test "curl failure surfaces an error and exits non-zero" {
    _stub curl <<'EOF'
#!/bin/bash
echo "curl: (28) Connection timed out" >&2
exit 28
EOF
    run fetch-globalip
    assert_failure
    assert_output --partial 'Error: failed to fetch global IP address.'
}
