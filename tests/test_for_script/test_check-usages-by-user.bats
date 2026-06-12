#!/usr/bin/env bats

# nproc / ps / getent は PATH 先頭の stub で差し替え、決定的にテストする。
# stub fixture (cores=2):
#   uid 1000 (alice): cpu (50+50)/2 = 50.00, mem 30.00, top chrome
#   uid 4242 (unresolved): cpu 5.00, mem 5.00, top mystery-daemon
#   uid 0 (root): cpu 1.00, mem 40.00, top systemd
#   uid 998 (unresolved): cpu 0.00, mem 0.00, top polkitd (zero-CPU edge case)

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"

    TMPDIR_TEST="$(mktemp -d)"
    STUB_DIR="$TMPDIR_TEST/bin"
    mkdir -p "$STUB_DIR"

    cat > "$STUB_DIR/nproc" <<'EOF'
#!/bin/bash
echo 2
EOF

    cat > "$STUB_DIR/ps" <<'EOF'
#!/bin/bash
cat <<'PSOUT'
 1000  50.0  10.0 chrome
 1000  50.0  20.0 firefox
 4242  10.0   5.0 mystery-daemon
    0   2.0  40.0 systemd
  998   0.0   0.0 polkitd
PSOUT
EOF

    cat > "$STUB_DIR/getent" <<'EOF'
#!/bin/bash
case "$2" in
    0)    echo "root:x:0:0:root:/root:/bin/bash" ;;
    1000) echo "alice:x:1000:1000:Alice:/home/alice:/bin/bash" ;;
    *)    exit 2 ;;
esac
EOF

    chmod +x "$STUB_DIR/nproc" "$STUB_DIR/ps" "$STUB_DIR/getent"

    OLD_PATH=$PATH
    PATH="$STUB_DIR:$DIR/../../bin/linux:$PATH"
}

teardown() {
    PATH=$OLD_PATH
    rm -rf "$TMPDIR_TEST"
}

# ---------------------------------------------------------------------------
# help / version / option parsing
# ---------------------------------------------------------------------------

@test "help option -h prints docstring and exits 0" {
    run check-usages-by-user -h
    assert_success
    assert_output --partial 'Script: check-usages-by-user'
    assert_output --partial 'Usage:'
}

@test "help option --help prints docstring and exits 0" {
    run check-usages-by-user --help
    assert_success
    assert_output --partial 'Script: check-usages-by-user'
}

@test "version option -v prints package name and VERSION content" {
    run check-usages-by-user -v
    assert_success
    assert_output "regmonkey-shellutils $(cat "$DIR/../../VERSION")"
}

@test "version option --version prints package name and VERSION content" {
    run check-usages-by-user --version
    assert_success
    assert_output "regmonkey-shellutils $(cat "$DIR/../../VERSION")"
}

@test "unknown option fails with error message" {
    run check-usages-by-user -z
    assert_failure
    assert_output --partial 'Error: unknown option: -z'
    assert_output --partial 'Use --help'
}

@test "unexpected positional argument fails" {
    run check-usages-by-user foo
    assert_failure
    assert_output --partial 'Error: unexpected argument: foo'
}

@test "non-integer -n value fails" {
    run check-usages-by-user -n abc
    assert_failure
    assert_output --partial 'Error: -n requires a positive integer'
}

@test "zero -n value fails" {
    run check-usages-by-user -n 0
    assert_failure
    assert_output --partial 'Error: -n requires a positive integer'
}

@test "-n without argument fails" {
    run check-usages-by-user -n
    assert_failure
    assert_output --partial 'Error: option -n requires an argument'
}

# ---------------------------------------------------------------------------
# table output
# ---------------------------------------------------------------------------

@test "table output aggregates per-user CPU/MEM normalized by core count" {
    run check-usages-by-user
    assert_success
    assert_output --partial 'USER (UID)'
    # alice: cpu (50+50)/2, mem 10+20, top process = chrome
    assert_output --regexp 'alice \(1000\) +50\.00% +30\.00% +chrome'
    # root: cpu 2/2, mem 40
    assert_output --regexp 'root \(0\) +1\.00% +40\.00% +systemd'
}

@test "user with only zero-CPU processes still shows a top process" {
    run check-usages-by-user
    assert_success
    assert_output --regexp 'uid:998 \(998\) +0\.00% +0\.00% +polkitd'
}

@test "unresolved uid falls back to uid:<uid>" {
    run check-usages-by-user
    assert_success
    assert_output --regexp 'uid:4242 \(4242\) +5\.00% +5\.00% +mystery-daemon'
}

@test "default sort is CPU descending" {
    run check-usages-by-user
    assert_success
    # bats drops the leading blank line: line 0 = header, 1 = separator
    assert_line --index 2 --partial 'alice (1000)'
    assert_line --index 3 --partial 'uid:4242'
    assert_line --index 4 --partial 'root (0)'
}

@test "-m sorts by memory descending" {
    run check-usages-by-user -m
    assert_success
    assert_line --index 2 --partial 'root (0)'
    assert_line --index 3 --partial 'alice (1000)'
    assert_line --index 4 --partial 'uid:4242'
}

@test "-n 1 limits output to the top user" {
    run check-usages-by-user -n 1
    assert_success
    assert_output --partial 'alice (1000)'
    refute_output --partial 'root (0)'
    refute_output --partial 'uid:4242'
}

# ---------------------------------------------------------------------------
# JSON output
# ---------------------------------------------------------------------------

@test "-j outputs JSON entries with expected keys and values" {
    run check-usages-by-user -j
    assert_success
    assert_line --index 0 '['
    assert_line --index "$(( ${#lines[@]} - 1 ))" ']'
    assert_output --partial '"username": "alice"'
    assert_output --partial '"uid": 1000'
    assert_output --partial '"cpu_percent": 50.00'
    assert_output --partial '"mem_percent": 30.00'
    assert_output --partial '"top_process": "chrome"'
    assert_output --partial '"username": "uid:4242"'
}

@test "-mjn combined options output top-1 memory user as JSON" {
    run check-usages-by-user -mjn 1
    assert_success
    assert_output --partial '"username": "root"'
    refute_output --partial '"username": "alice"'
}
