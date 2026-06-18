#!/usr/bin/env bats

# grep-history は HISTORYFILE / -f で指定した履歴ファイルを grep し、
# zsh EXTENDED_HISTORY 形式 ": <ts>:<elapsed>;<command>" の各行を
# 'YYYY-MM-DD HH:MM:SS: <command>' に整形して表示する。
# 履歴ファイルは mktemp -d の sandbox に置き、HISTORYFILE で seam を上書きする。
#
# fixture の各行は 60 秒刻みのタイムスタンプを持つ:
#   1700000000 -> 2023-11-14 22:13:20 (UTC)  git
#   1700000060 -> 2023-11-14 22:14:20 (UTC)  docker
#   1700000120 -> 2023-11-14 22:15:20 (UTC)  grep
#   1700000180 -> 2023-11-14 22:16:20 (UTC)  echo
# テストは strftime のローカルタイムゾーン依存を避けるため TZ=UTC で実行する。

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"

    export TZ=UTC

    TMPDIR_TEST="$(mktemp -d)"
    HISTFILE_TEST="$TMPDIR_TEST/.zsh_history"
    cat > "$HISTFILE_TEST" <<'EOF'
: 1700000000:0;git commit -m "init"
: 1700000060:0;docker ps -a
: 1700000120:5;grep -rn "TODO" .
: 1700000180:0;echo hello; echo world
EOF

    export HISTORYFILE="$HISTFILE_TEST"

    OLD_PATH=$PATH
    PATH="$DIR/../../bin/utils:$PATH"
}

teardown() {
    PATH=$OLD_PATH
    rm -rf "$TMPDIR_TEST"
}

# ---------------------------------------------------------------------------
# help / version / option parsing
# ---------------------------------------------------------------------------

@test "help option -h prints docstring and exits 0" {
    run grep-history -h
    assert_success
    assert_output --partial 'Script: grep-history'
    assert_output --partial 'Usage:'
}

@test "help option --help prints docstring and exits 0" {
    run grep-history --help
    assert_success
    assert_output --partial 'Script: grep-history'
}

@test "version option -v prints package name and VERSION content" {
    run grep-history -v
    assert_success
    assert_output "regmonkey-shellutils $(cat "$DIR/../../VERSION")"
}

@test "version option --version prints package name and VERSION content" {
    run grep-history --version
    assert_success
    assert_output "regmonkey-shellutils $(cat "$DIR/../../VERSION")"
}

@test "unknown option fails with error message" {
    run grep-history -z
    assert_failure
    assert_output --partial 'Error: unknown option: -z'
    assert_output --partial 'Use --help'
}

@test "missing search word fails" {
    run grep-history
    assert_failure
    assert_output --partial 'Error: search word is missing'
}

@test "extra positional argument fails" {
    run grep-history foo bar
    assert_failure
    assert_output --partial 'Error: unexpected argument: bar'
}

@test "-f without an argument fails" {
    run grep-history -f
    assert_failure
    assert_output --partial 'Error: option -f requires an argument'
}

# ---------------------------------------------------------------------------
# search behaviour
# ---------------------------------------------------------------------------

@test "matches a single command and formats timestamp + command" {
    run grep-history docker
    assert_success
    assert_output "2023-11-14 22:14:20: docker ps -a"
}

@test "preserves semicolons inside the command body" {
    run grep-history hello
    assert_success
    assert_output "2023-11-14 22:16:20: echo hello; echo world"
}

@test "non-zero elapsed time does not leak into the command" {
    run grep-history TODO
    assert_success
    assert_output '2023-11-14 22:15:20: grep -rn "TODO" .'
}

@test "accepts a basic regular expression" {
    run grep-history 'git.*init'
    assert_success
    assert_output '2023-11-14 22:13:20: git commit -m "init"'
}

@test "no match produces empty output and exits 0" {
    run grep-history nonexistentpattern
    assert_success
    assert_output ''
}

# ---------------------------------------------------------------------------
# history file resolution
# ---------------------------------------------------------------------------

@test "-f overrides HISTORYFILE" {
    other="$TMPDIR_TEST/other_history"
    cat > "$other" <<'EOF'
: 1700000000:0;from other file
EOF
    run grep-history -f "$other" other
    assert_success
    assert_output '2023-11-14 22:13:20: from other file'
}

@test "missing HISTORYFILE and no -f fails" {
    unset HISTORYFILE
    run grep-history docker
    assert_failure
    assert_output --partial 'history file is not set'
}

@test "unreadable history file fails" {
    run grep-history -f "$TMPDIR_TEST/does-not-exist" docker
    assert_failure
    assert_output --partial 'cannot read history file'
}
