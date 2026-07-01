#!/usr/bin/env bats

# mysshpass は sshpass + GPG 暗号化パスワードファイル、または対話プロンプトで
# SSH コマンドを実行するラッパー。
#
# 外部コマンド 'sshpass' / 'gpg' は PATH 先頭の stub で差し替える:
#   - sshpass stub は呼び出し引数を SSHPASS_ARGS_FILE に書き出すだけ。
#   - gpg stub は GPG_FIXTURE_FILE の内容をそのまま stdout に返す。
# 副作用は mktemp -d の sandbox に閉じ込め teardown で削除する。

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"

    TMPDIR_TEST="$(mktemp -d)"
    STUB_DIR="$TMPDIR_TEST/bin"
    mkdir -p "$STUB_DIR"

    export SSHPASS_ARGS_FILE="$TMPDIR_TEST/sshpass_args"

    # sshpass stub: 引数をファイルに書き出すだけ
    cat > "$STUB_DIR/sshpass" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$SSHPASS_ARGS_FILE"
EOF
    chmod +x "$STUB_DIR/sshpass"

    # パスワードファイルの fixture (プレーンテキスト; gpg stub がそのまま返す)
    export GPG_FIXTURE_FILE="$TMPDIR_TEST/sshpass.conf"
    cat > "$GPG_FIXTURE_FILE" <<'EOF'
machine 192.168.1.10 password secret123
machine jump-server  password jumppass
EOF

    # gpg stub: --decrypt を受け取ったら fixture をそのまま stdout に返す
    cat > "$STUB_DIR/gpg" <<EOF
#!/bin/bash
# '--quiet --decrypt <file>' に相当する呼び出しを模倣する
cat "$GPG_FIXTURE_FILE"
EOF
    chmod +x "$STUB_DIR/gpg"

    # SSHPASS_FILE を sandbox 内の GPG 暗号化ファイルとして設定 (存在チェック用)
    export SSHPASS_FILE="$TMPDIR_TEST/sshpass.conf.gpg"
    cp "$GPG_FIXTURE_FILE" "$SSHPASS_FILE"

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
    run mysshpass -h
    assert_success
    assert_output --partial 'Script: mysshpass'
    assert_output --partial 'Usage:'
}

@test "help option --help prints docstring and exits 0" {
    run mysshpass --help
    assert_success
    assert_output --partial 'Script: mysshpass'
    assert_output --partial 'Usage:'
}

@test "version option -v prints package name and VERSION content" {
    run mysshpass -v
    assert_success
    assert_output "regmonkey-shellutils $(cat "$DIR/../../VERSION")"
}

@test "version option --version prints package name and VERSION content" {
    run mysshpass --version
    assert_success
    assert_output "regmonkey-shellutils $(cat "$DIR/../../VERSION")"
}

@test "unknown option fails with error message and hint" {
    run mysshpass -z
    assert_failure
    assert_output --partial 'Error: unknown option: -z'
    assert_output --partial 'Use --help'
}

@test "--host without an argument fails" {
    run mysshpass --host
    assert_failure
    assert_output --partial 'Error: --host requires an argument'
    assert_output --partial 'Use --help'
}

# ---------------------------------------------------------------------------
# dependency checks
# ---------------------------------------------------------------------------

@test "fails when sshpass is not installed" {
    # sshpass と gpg は /usr/bin に実在するため PATH から除外できない。
    # bash の `command` はビルトインなので関数 override も効かない。
    # → STUB_DIR の sshpass/gpg stub の前段に、コマンド探索を横取りする
    #   「command」という名前の実行ファイルを置く。
    #   ただし bash ビルトインが優先されるため、この方法も機能しない。
    #
    # 現実的な解決策: sshpass の存在チェックを行う行を直接テストする
    # ラッパースクリプトを作成し、そのラッパー内で command builtin を
    # function として上書きした環境を bash -c で起動する。
    local wrapper="$TMPDIR_TEST/run_no_sshpass.sh"
    cat > "$wrapper" <<EOF
#!/bin/bash
command() {
    if [[ "\$1" == "-v" && "\$2" == "sshpass" ]]; then
        return 1
    fi
    builtin command "\$@"
}
export -f command
source "$DIR/../../bin/utils/mysshpass" "\$@"
EOF
    chmod +x "$wrapper"
    run bash "$wrapper" ssh user@host
    assert_failure
    assert_output --partial 'Error: sshpass is not installed'
}

@test "fails when gpg is not installed and --host is given" {
    local wrapper="$TMPDIR_TEST/run_no_gpg.sh"
    cat > "$wrapper" <<EOF
#!/bin/bash
command() {
    if [[ "\$1" == "-v" && "\$2" == "gpg" ]]; then
        return 1
    fi
    builtin command "\$@"
}
export -f command
source "$DIR/../../bin/utils/mysshpass" "\$@"
EOF
    chmod +x "$wrapper"
    run bash "$wrapper" --host 192.168.1.10 ssh user@192.168.1.10
    assert_failure
    assert_output --partial 'Error: gpg is not installed'
}

# ---------------------------------------------------------------------------
# SSHPASS_FILE validation (--host mode)
# ---------------------------------------------------------------------------

@test "fails when SSHPASS_FILE does not exist" {
    export SSHPASS_FILE="$TMPDIR_TEST/nonexistent.gpg"
    run mysshpass --host 192.168.1.10 ssh user@192.168.1.10
    assert_failure
    assert_output --partial 'Error: password file not found'
}

@test "fails when no entry for the given host" {
    run mysshpass --host unknown-host ssh user@unknown-host
    assert_failure
    assert_output --partial 'Error: no entry found for host: unknown-host'
}

# ---------------------------------------------------------------------------
# happy path: --host mode
# ---------------------------------------------------------------------------

@test "--host resolves password and invokes sshpass -e with remaining args" {
    run mysshpass --host 192.168.1.10 ssh user@192.168.1.10
    assert_success
    run cat "$SSHPASS_ARGS_FILE"
    assert_line '-e'
    assert_line 'ssh'
    assert_line 'user@192.168.1.10'
}

@test "--host resolves correct password for second entry" {
    run mysshpass --host jump-server ssh -p 2222 user@jump-server
    assert_success
    run cat "$SSHPASS_ARGS_FILE"
    assert_line '-e'
    assert_line 'ssh'
    assert_line 'user@jump-server'
}

@test "-- separator stops option parsing and passes rest to sshpass" {
    run mysshpass --host 192.168.1.10 -- ssh user@192.168.1.10
    assert_success
    run cat "$SSHPASS_ARGS_FILE"
    assert_line '-e'
    assert_line 'ssh'
    assert_line 'user@192.168.1.10'
}

# ---------------------------------------------------------------------------
# SSHPASS env var is set by sshpass -e mechanism (checked via stub env)
# ---------------------------------------------------------------------------

@test "SSHPASS env var is exported before calling sshpass in --host mode" {
    # sshpass stub を、SSHPASS を表示するものに差し替える
    cat > "$STUB_DIR/sshpass" <<EOF
#!/bin/bash
echo "SSHPASS=\${SSHPASS}"
EOF
    chmod +x "$STUB_DIR/sshpass"

    run mysshpass --host 192.168.1.10 ssh user@192.168.1.10
    assert_success
    assert_output 'SSHPASS=secret123'
}
