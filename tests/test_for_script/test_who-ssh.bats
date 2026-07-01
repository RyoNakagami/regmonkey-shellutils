#!/usr/bin/env bats

# who-ssh は SSH プロセス一覧と（オプションで）リスニングポートを表示する。
# stdout が tty の場合は $PAGER / less -R でページングされ、
# 非 tty（bats 実行時）では直接 stdout に出力される。
# ANSI カラーは非 tty 時または NO_COLOR セット時に自動無効化される。
#
# 外部コマンド ps / ss は STUB_DIR に置いたスタブで差し替える。
# 副作用は mktemp -d の sandbox に閉じ込め teardown で削除する。

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"

    TMPDIR_TEST="$(mktemp -d)"
    STUB_DIR="$TMPDIR_TEST/bin"
    mkdir -p "$STUB_DIR"

    # ps stub: 'ps -eo user,pid,command' と 'ps aux' の両形式を返す
    cat > "$STUB_DIR/ps" <<'EOF'
#!/bin/bash
if [[ "$1" == "aux" ]]; then
    printf '%-15s %-8s %-6s %-6s %-50s\n' \
        "USER" "PID" "%CPU" "%MEM" "COMMAND"
    printf '%-15s %-8s %-6s %-6s %-50s\n' \
        "alice" "1001" "0.1" "0.2" "sshd: alice [priv]"
    printf '%-15s %-8s %-6s %-6s %-50s\n' \
        "bob" "1002" "0.0" "0.1" "sshd: bob@pts/0"
else
    # ps -eo user,pid,command
    echo "USER       PID COMMAND"
    echo "alice     1001 sshd: alice [priv]"
    echo "bob       1002 sshd: bob@pts/0"
fi
EOF
    chmod +x "$STUB_DIR/ps"

    # ss stub: '-tlnp' で sshd のリスニング行を返す
    cat > "$STUB_DIR/ss" <<'EOF'
#!/bin/bash
echo "State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process"
echo "LISTEN 0      128    0.0.0.0:22           0.0.0.0:*       users:((\"sshd\",pid=888,fd=3))"
EOF
    chmod +x "$STUB_DIR/ss"

    # bats は非 tty で実行されるためページャは起動しない。
    # 念のため less stub も置いて、誤起動したら失敗できるようにする。
    cat > "$STUB_DIR/less" <<'EOF'
#!/bin/bash
echo "PAGER_INVOKED" >&2
exit 1
EOF
    chmod +x "$STUB_DIR/less"

    export NO_COLOR=1  # カラーエスケープをテスト出力に混入させない

    OLD_PATH=$PATH
    PATH="$STUB_DIR:$DIR/../../bin/linux:/usr/bin:/bin"
}

teardown() {
    PATH=$OLD_PATH
    rm -rf "$TMPDIR_TEST"
}

# ---------------------------------------------------------------------------
# help / version / option parsing
# ---------------------------------------------------------------------------

@test "help option -h prints docstring and exits 0" {
    run who-ssh -h
    assert_success
    assert_output --partial 'Script: who-ssh'
    assert_output --partial 'Usage:'
}

@test "help option --help prints docstring and exits 0" {
    run who-ssh --help
    assert_success
    assert_output --partial 'Script: who-ssh'
    assert_output --partial 'Usage:'
}

@test "version option -v prints package name and VERSION content" {
    run who-ssh -v
    assert_success
    assert_output "regmonkey-shellutils $(cat "$DIR/../../VERSION")"
}

@test "version option --version prints package name and VERSION content" {
    run who-ssh --version
    assert_success
    assert_output "regmonkey-shellutils $(cat "$DIR/../../VERSION")"
}

@test "unknown option fails with error message and hint" {
    run who-ssh --no-such-flag
    assert_failure
    assert_output --partial 'Error: unknown option: --no-such-flag'
    assert_output --partial 'Use --help'
}

@test "unexpected positional argument fails" {
    run who-ssh extraarg
    assert_failure
    assert_output --partial 'Error: unexpected argument: extraarg'
    assert_output --partial 'Use --help'
}

@test "-u without an argument fails" {
    run who-ssh -u
    assert_failure
    assert_output --partial 'Error: -u requires an argument'
    assert_output --partial 'Use --help'
}

# ---------------------------------------------------------------------------
# happy path: default output
# ---------------------------------------------------------------------------

@test "default output contains USER and PID column headers" {
    run who-ssh
    assert_success
    assert_output --partial 'USER'
    assert_output --partial 'PID'
}

@test "default output lists ssh processes from stub" {
    run who-ssh
    assert_success
    assert_output --partial 'alice'
    assert_output --partial 'bob'
    assert_output --partial '1001'
    assert_output --partial '1002'
}

@test "default output does not contain port section without -p" {
    run who-ssh
    assert_success
    refute_output --partial 'Listening SSH ports'
}

# ---------------------------------------------------------------------------
# -u USER filter
# ---------------------------------------------------------------------------

@test "-u alice shows alice and suppresses bob" {
    run who-ssh -u alice
    assert_success
    assert_output --partial 'alice'
    refute_output --partial 'bob'
}

@test "-u bob shows bob and suppresses alice" {
    run who-ssh -u bob
    assert_success
    assert_output --partial 'bob'
    refute_output --partial 'alice'
}

# ---------------------------------------------------------------------------
# -d detail mode
# ---------------------------------------------------------------------------

@test "-d shows CPU and MEM column headers" {
    run who-ssh -d
    assert_success
    assert_output --partial '%CPU'
    assert_output --partial '%MEM'
}

@test "-d shows process entries with detail columns" {
    run who-ssh -d
    assert_success
    assert_output --partial 'alice'
    assert_output --partial '0.1'
}

# ---------------------------------------------------------------------------
# -p port mode
# ---------------------------------------------------------------------------

@test "-p shows listening SSH port section header" {
    run who-ssh -p
    assert_success
    assert_output --partial 'Listening SSH ports'
}

@test "-p shows ss stub output containing sshd" {
    run who-ssh -p
    assert_success
    assert_output --partial 'sshd'
    assert_output --partial ':22'
}

# ---------------------------------------------------------------------------
# pager: must NOT be invoked when stdout is not a tty (bats context)
# ---------------------------------------------------------------------------

@test "pager is not invoked when stdout is not a tty" {
    run who-ssh
    assert_success
    # less stub が呼ばれると stderr に PAGER_INVOKED が出て exit 1 になる
    refute_output --partial 'PAGER_INVOKED'
}

# ---------------------------------------------------------------------------
# no SSH processes found
# ---------------------------------------------------------------------------

@test "shows 'No SSH processes found' when ps returns nothing" {
    cat > "$STUB_DIR/ps" <<'EOF'
#!/bin/bash
echo "USER       PID COMMAND"
EOF
    chmod +x "$STUB_DIR/ps"
    run who-ssh
    assert_success
    assert_output --partial 'No SSH processes found'
}

# ---------------------------------------------------------------------------
# -p: no listening ports
# ---------------------------------------------------------------------------

@test "shows 'No SSH ports listening' when ss returns nothing" {
    cat > "$STUB_DIR/ss" <<'EOF'
#!/bin/bash
echo "State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process"
EOF
    chmod +x "$STUB_DIR/ss"
    run who-ssh -p
    assert_success
    assert_output --partial 'No SSH ports listening'
}
