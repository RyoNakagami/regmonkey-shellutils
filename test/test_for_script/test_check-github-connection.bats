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
    run check-github-connection -h
    assert_success
    assert_output --partial 'Script: check-github-connection'
    assert_output --partial 'Usage:'
}

@test "unknown option fails with error" {
    run check-github-connection --no-such-flag
    assert_failure
    assert_output --partial 'Error: unknown option: --no-such-flag'
}

@test "positional argument is rejected" {
    run check-github-connection extra-arg
    assert_failure
    assert_output --partial "Error: no positional arguments are accepted (got 'extra-arg')."
}

@test "missing curl fails" {
    # PATH has coreutils but no curl/jq.
    PATH="$MIN_BIN:$DIR/../../bin/network"
    run check-github-connection
    assert_failure
    assert_output --partial "Error: 'curl' command not found in PATH."
}

@test "status mode fails when jq is missing" {
    _stub curl <<'EOF'
#!/bin/bash
echo '{"status":{"indicator":"none","description":"All Systems Operational"}}'
EOF
    # curl is available (stub on MIN_BIN), but jq is not.
    cp "$STUB_BIN/curl" "$MIN_BIN/curl"
    PATH="$MIN_BIN:$DIR/../../bin/network"
    run check-github-connection
    assert_failure
    assert_output --partial "Error: 'jq' command not found in PATH (required for status mode)."
}

@test "status mode (default) prints jq output" {
    _stub curl <<'EOF'
#!/bin/bash
# Ignore args; emit a canned status.json payload.
echo '{"status":{"indicator":"none","description":"All Systems Operational"}}'
EOF
    _stub jq <<'EOF'
#!/bin/bash
# Minimal stub: prove the .status filter is applied to stdin.
[ "$1" = ".status" ] || { echo "unexpected jq filter: $*" >&2; exit 1; }
cat
EOF
    run check-github-connection
    assert_success
    assert_output --partial 'All Systems Operational'
}

@test "--time mode prints timing breakdown" {
    # Stub curl to echo its '-w' write-out template with values filled in,
    # mimicking curl's variable substitution for the fields we care about.
    _stub curl <<'EOF'
#!/bin/bash
fmt=""
while [ $# -gt 0 ]; do
    case "$1" in
        -w) fmt="$2"; shift 2 ;;
        *) shift ;;
    esac
done
out="$fmt"
out="${out//%\{time_namelookup\}/0.001}"
out="${out//%\{time_connect\}/0.010}"
out="${out//%\{time_appconnect\}/0.050}"
out="${out//%\{time_starttransfer\}/0.100}"
out="${out//%\{time_total\}/0.120}"
out="${out//%\{http_code\}/200}"
printf '%s' "$out"
EOF
    run check-github-connection --time
    assert_success
    assert_output --partial 'dns:'
    assert_output --partial 'tcp:'
    assert_output --partial 'tls:'
    assert_output --partial 'ttfb:'
    assert_output --partial 'total:'
    assert_output --partial 'http_code:  200'
}
