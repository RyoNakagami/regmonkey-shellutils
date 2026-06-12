#!/usr/bin/env bats

# free は PATH 先頭の stub で差し替え、決定的にテストする。
# stub fixture (BAR_LENGTH=40, total 1000):
#   used 500 -> 20#, buff 300 -> 12#, free 200 -> 8#, available 400 -> 16#
#   swap total 2000: used 500 -> 10#, free 1500 -> 30#
# stub は受け取った引数を $STUB_DIR/free_args に記録する。

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"

    TMPDIR_TEST="$(mktemp -d)"
    STUB_DIR="$TMPDIR_TEST/bin"
    mkdir -p "$STUB_DIR"

    cat > "$STUB_DIR/free" <<'EOF'
#!/bin/bash
echo "$@" >> "${0%/*}/free_args"
cat <<'OUT'
              total        used        free      shared  buff/cache   available
Mem:           1000         500         200          10         300         400
Swap:          2000         500        1500
OUT
EOF
    chmod +x "$STUB_DIR/free"

    OLD_PATH=$PATH
    PATH="$STUB_DIR:$DIR/../../bin/linux:$PATH"
}

teardown() {
    PATH=$OLD_PATH
    rm -rf "$TMPDIR_TEST"
}

hashes() { printf '%*s' "$1" '' | tr ' ' '#'; }
spaces() { printf '%*s' "$1" ''; }

# ---------------------------------------------------------------------------
# help / version / option parsing
# ---------------------------------------------------------------------------

@test "help option -h prints docstring and exits 0" {
    run check-memory -h
    assert_success
    assert_output --partial 'Script: check-memory'
    assert_output --partial 'Usage:'
}

@test "help option --help prints docstring and exits 0" {
    run check-memory --help
    assert_success
    assert_output --partial 'Script: check-memory'
}

@test "version option -v prints package name and VERSION content" {
    run check-memory -v
    assert_success
    assert_output "regmonkey-shellutils $(cat "$DIR/../../VERSION")"
}

@test "version option --version prints package name and VERSION content" {
    run check-memory --version
    assert_success
    assert_output "regmonkey-shellutils $(cat "$DIR/../../VERSION")"
}

@test "unknown option fails with error message" {
    run check-memory -z
    assert_failure
    assert_output --partial 'Error: unknown option: -z'
    assert_output --partial 'Use --help'
}

@test "unexpected positional argument fails" {
    run check-memory foo
    assert_failure
    assert_output --partial 'Error: unexpected argument: foo'
}

# ---------------------------------------------------------------------------
# bar graph output
# ---------------------------------------------------------------------------

@test "renders memory and swap bars proportional to usage" {
    run check-memory
    assert_success
    assert_line --index 0 "Memory Usage (MB): Total 1000"
    assert_line --index 1 "Used      [$(hashes 20)$(spaces 20)] 500"
    assert_line --index 2 "Buff/Cache[$(hashes 12)$(spaces 28)] 300"
    assert_line --index 3 "Free      [$(hashes 8)$(spaces 32)] 200"
    assert_line --index 4 "Available [$(hashes 16)$(spaces 24)] 400"
    assert_line --index 5 "Swap Usage (MB): Total 2000"
    assert_line --index 6 "Used [$(hashes 10)$(spaces 30)] 500"
    assert_line --index 7 "Free [$(hashes 30)$(spaces 10)] 1500"
}

@test "default unit is MB and free is invoked with -m" {
    run check-memory
    assert_success
    assert_output --partial 'Memory Usage (MB)'
    run cat "$STUB_DIR/free_args"
    assert_output '-m'
}

@test "-g switches unit label to GB and invokes free -g" {
    run check-memory -g
    assert_success
    assert_output --partial 'Memory Usage (GB)'
    run cat "$STUB_DIR/free_args"
    assert_output '-g'
}

@test "--bytes switches unit label to B and invokes free -b" {
    run check-memory --bytes
    assert_success
    assert_output --partial 'Memory Usage (B)'
    run cat "$STUB_DIR/free_args"
    assert_output '-b'
}

@test "host without swap renders empty bars instead of failing" {
    cat > "$STUB_DIR/free" <<'EOF'
#!/bin/bash
cat <<'OUT'
              total        used        free      shared  buff/cache   available
Mem:           1000         500         200          10         300         400
Swap:             0           0           0
OUT
EOF
    chmod +x "$STUB_DIR/free"

    run check-memory
    assert_success
    assert_line --index 5 "Swap Usage (MB): Total 0"
    assert_line --index 6 "Used [$(spaces 40)] 0"
    assert_line --index 7 "Free [$(spaces 40)] 0"
}

@test "zero value renders a bar with no hash marks" {
    cat > "$STUB_DIR/free" <<'EOF'
#!/bin/bash
cat <<'OUT'
              total        used        free      shared  buff/cache   available
Mem:           1000        1000           0          10           0           0
Swap:          2000           0        2000
OUT
EOF
    chmod +x "$STUB_DIR/free"

    run check-memory
    assert_success
    assert_line --index 1 "Used      [$(hashes 40)] 1000"
    assert_line --index 3 "Free      [$(spaces 40)] 0"
    assert_line --index 6 "Used [$(spaces 40)] 0"
}
