#!/usr/bin/env bats

# sshcode は SSH ホスト上のディレクトリを VS Code Remote-SSH のワークスペース
# として開くために 'code --folder-uri "vscode-remote://ssh-remote+<host><dir>"'
# を起動する。-r/--relative の場合は 'ssh -G <host>' からリモート user を
# 解決して '/home/<user>/<relative>/' を組み立てる。
#
# 外部コマンド 'code' と 'ssh' は PATH 先頭の stub で差し替える:
#   - code stub は呼び出し引数を $CODE_ARGS_FILE に書き出すだけ。
#   - ssh stub は 'ssh -G' に対して固定の 'user testuser' を返す。
# 副作用は mktemp -d の sandbox に閉じ込め teardown で削除する。

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"

    TMPDIR_TEST="$(mktemp -d)"
    STUB_DIR="$TMPDIR_TEST/bin"
    mkdir -p "$STUB_DIR"

    export CODE_ARGS_FILE="$TMPDIR_TEST/code_args"

    cat > "$STUB_DIR/code" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$CODE_ARGS_FILE"
EOF
    chmod +x "$STUB_DIR/code"

    cat > "$STUB_DIR/ssh" <<'EOF'
#!/bin/bash
# 'ssh -G <host>' をエミュレートして固定の設定を返す。
if [[ "$1" == "-G" ]]; then
    echo "host ${2}"
    echo "user testuser"
    exit 0
fi
exit 0
EOF
    chmod +x "$STUB_DIR/ssh"

    OLD_PATH=$PATH
    PATH="$STUB_DIR:$DIR/../../bin/utils:$PATH"
}

teardown() {
    PATH=$OLD_PATH
    rm -rf "$TMPDIR_TEST"
}

# ---------------------------------------------------------------------------
# help / version / option parsing
# ---------------------------------------------------------------------------

@test "help option -h prints docstring and exits 0" {
    run sshcode -h
    assert_success
    assert_output --partial 'Script: sshcode'
    assert_output --partial 'Usage:'
}

@test "help option --help prints docstring and exits 0" {
    run sshcode --help
    assert_success
    assert_output --partial 'Script: sshcode'
}

@test "version option -v prints package name and VERSION content" {
    run sshcode -v
    assert_success
    assert_output "regmonkey-shellutils $(cat "$DIR/../../VERSION")"
}

@test "version option --version prints package name and VERSION content" {
    run sshcode --version
    assert_success
    assert_output "regmonkey-shellutils $(cat "$DIR/../../VERSION")"
}

@test "unknown option fails with error message" {
    run sshcode -z
    assert_failure
    assert_output --partial 'Error: unknown option: -z'
    assert_output --partial 'Use --help'
}

@test "-s without an argument fails" {
    run sshcode -s
    assert_failure
    assert_output --partial 'Error: option -s requires an argument'
}

# ---------------------------------------------------------------------------
# argument validation
# ---------------------------------------------------------------------------

@test "missing host fails" {
    run sshcode -a /srv/www
    assert_failure
    assert_output --partial 'SSH host is required'
}

@test "missing target directory fails" {
    run sshcode -s myhost
    assert_failure
    assert_output --partial 'a target directory is required'
}

@test "relative and absolute are mutually exclusive" {
    run sshcode -s myhost -r foo -a /bar
    assert_failure
    assert_output --partial 'mutually exclusive'
}

@test "unexpected positional argument fails" {
    run sshcode -s myhost -a /srv extra
    assert_failure
    assert_output --partial 'Error: unexpected argument: extra'
}

# ---------------------------------------------------------------------------
# folder-uri construction
# ---------------------------------------------------------------------------

@test "absolute path is passed through verbatim" {
    run sshcode -s myhost -a /srv/www
    assert_success
    run cat "$CODE_ARGS_FILE"
    assert_line '--folder-uri'
    assert_line 'vscode-remote://ssh-remote+myhost/srv/www'
}

@test "relative path resolves remote user via ssh -G" {
    run sshcode -s myhost -r projects/foo
    assert_success
    run cat "$CODE_ARGS_FILE"
    assert_line 'vscode-remote://ssh-remote+myhost/home/testuser/projects/foo/'
}

@test "long options behave like short options" {
    run sshcode --ssh myhost --absolute /opt/app
    assert_success
    run cat "$CODE_ARGS_FILE"
    assert_line 'vscode-remote://ssh-remote+myhost/opt/app'
}

@test "options are order-independent (target before host)" {
    run sshcode -r projects/foo -s myhost
    assert_success
    run cat "$CODE_ARGS_FILE"
    assert_line 'vscode-remote://ssh-remote+myhost/home/testuser/projects/foo/'
}

# ---------------------------------------------------------------------------
# remote user resolution failure
# ---------------------------------------------------------------------------

@test "fails when remote user cannot be resolved" {
    # ssh stub を 'user' 行を返さないものに差し替える。
    cat > "$STUB_DIR/ssh" <<'EOF'
#!/bin/bash
echo "host placeholder"
exit 0
EOF
    chmod +x "$STUB_DIR/ssh"
    run sshcode -s myhost -r projects/foo
    assert_failure
    assert_output --partial 'could not resolve remote user'
}
