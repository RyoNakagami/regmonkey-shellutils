#!/usr/bin/env bats

# detect-linebreak はファイルの行末コード（LF / CR / CRLF）を解析する。
# -c (default) で統計を表示し、-l/-r/-w で該当行をフィルタ表示する。
#
# fixture はバイナリ safe な printf で sandbox 内に作成する:
#   line1: LF   ("line1\n")
#   line2: CRLF ("line2\r\n")
#   line3: LF   ("line3\n")
#   line4: CR   ("line4\r")
# → LF:2  CRLF:1  CR:1  Total:4

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"

    OLD_PATH=$PATH
    PATH="$DIR/../../bin/edit:$PATH"

    TMPDIR_TEST="$(mktemp -d)"

    # Mixed line-ending fixture (binary-safe)
    FIXTURE="$TMPDIR_TEST/mixed.txt"
    printf 'line1\nline2\r\nline3\nline4\r' > "$FIXTURE"

    # LF-only fixture
    LF_ONLY="$TMPDIR_TEST/lf_only.txt"
    printf 'aaa\nbbb\nccc\n' > "$LF_ONLY"
}

teardown() {
    PATH=$OLD_PATH
    rm -rf "$TMPDIR_TEST"
}

# ---------------------------------------------------------------------------
# help / version / option parsing
# ---------------------------------------------------------------------------

@test "help option -h prints docstring and exits 0" {
    run detect-linebreak -h
    assert_success
    assert_output --partial 'Script: detect-linebreak'
    assert_output --partial 'Usage:'
}

@test "help option --help prints docstring and exits 0" {
    run detect-linebreak --help
    assert_success
    assert_output --partial 'Script: detect-linebreak'
}

@test "version option -v prints package name and version" {
    run detect-linebreak -v
    assert_success
    assert_output "regmonkey-shellutils $(cat "$DIR/../../VERSION")"
}

@test "version option --version prints package name and version" {
    run detect-linebreak --version
    assert_success
    assert_output "regmonkey-shellutils $(cat "$DIR/../../VERSION")"
}

@test "unknown option fails with error message" {
    run detect-linebreak -z "$FIXTURE"
    assert_failure
    assert_output --partial 'Error: unknown option: -z'
    assert_output --partial 'Use --help'
}

@test "no file argument fails with error message" {
    run detect-linebreak
    assert_failure
    assert_output --partial 'Error: no input file specified.'
    assert_output --partial 'Use --help'
}

@test "extra positional argument fails" {
    run detect-linebreak "$FIXTURE" extra
    assert_failure
    assert_output --partial 'Error: unexpected argument: extra'
}

@test "file not found fails with error message" {
    run detect-linebreak "$TMPDIR_TEST/no_such_file.txt"
    assert_failure
    assert_output --partial 'Error: file not found:'
}

# ---------------------------------------------------------------------------
# CHECK mode (-c / default)
# ---------------------------------------------------------------------------

@test "default mode shows line-ending statistics" {
    run detect-linebreak "$FIXTURE"
    assert_success
    assert_output --partial 'Line break usage:'
    assert_output --partial 'Total lines: 4'
}

@test "-c flag shows line-ending statistics" {
    run detect-linebreak -c "$FIXTURE"
    assert_success
    assert_output --partial 'Line break usage:'
    assert_output --partial 'Total lines: 4'
}

@test "CHECK mode counts CRLF correctly" {
    run detect-linebreak -c "$FIXTURE"
    assert_success
    assert_output --partial 'CRLF:     1 lines (25.00%)'
}

@test "CHECK mode counts CR correctly" {
    run detect-linebreak -c "$FIXTURE"
    assert_success
    assert_output --partial 'CR:       1 lines (25.00%)'
}

@test "CHECK mode counts LF correctly" {
    run detect-linebreak -c "$FIXTURE"
    assert_success
    assert_output --partial 'LF:       2 lines (50.00%)'
}

# ---------------------------------------------------------------------------
# filter modes (-l / -r / -w)
# ---------------------------------------------------------------------------

@test "-w shows only CRLF lines with line numbers" {
    run detect-linebreak -w "$FIXTURE"
    assert_success
    assert_output --partial 'CRLF'
    refute_output --partial 'CR  '
    refute_output --partial 'LF  '
}

@test "-w output contains the correct CRLF line" {
    run detect-linebreak -w "$FIXTURE"
    assert_success
    assert_output --partial 'Line 2'
    assert_output --partial 'line2'
}

@test "-l shows only LF lines with line numbers" {
    run detect-linebreak -l "$FIXTURE"
    assert_success
    assert_output --partial 'LF'
    assert_output --partial 'Line 1'
    assert_output --partial 'line1'
    assert_output --partial 'Line 3'
    assert_output --partial 'line3'
}

@test "-r shows only CR lines with line numbers" {
    run detect-linebreak -r "$FIXTURE"
    assert_success
    assert_output --partial 'CR'
    assert_output --partial 'Line 4'
    assert_output --partial 'line4'
}

@test "-w on LF-only file produces empty output and exits 0" {
    run detect-linebreak -w "$LF_ONLY"
    assert_success
    assert_output ''
}

@test "-r on LF-only file produces empty output and exits 0" {
    run detect-linebreak -r "$LF_ONLY"
    assert_success
    assert_output ''
}
