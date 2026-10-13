#!/usr/bin/env bats

# filtergrep は PATH 配下で glob に一致するファイルのうち，指定行範囲内に
# PATTERN を含むもののファイル名を列挙する．
#
# fixture は mktemp -d の sandbox に作成し teardown で削除する．

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"

    OLD_PATH=$PATH
    PATH="$DIR/../../bin/fs:$PATH"

    TMPDIR_TEST="$(mktemp -d)"
    SRC="$TMPDIR_TEST/src"
    mkdir -p "$SRC/sub"

    printf 'needle\nline2\nline3\nline4\nline5\n' > "$SRC/head.txt"
    printf 'line1\nline2\nline3\nline4\nneedle\n' > "$SRC/tail.txt"
    printf 'line1\nline2\nneedle\nline4\nline5\n' > "$SRC/sub/mid.py"
    printf 'nothing\nhere\n' > "$SRC/none.txt"
}

teardown() {
    PATH=$OLD_PATH
    rm -rf "$TMPDIR_TEST"
}

@test "help option prints docstring and exits 0" {
    run filtergrep -h
    assert_success
    assert_output --partial 'Script: filtergrep'
    assert_output --partial 'Usage:'
}

@test "missing PATTERN and PATH fails" {
    run filtergrep
    assert_failure
    assert_output --partial 'PATTERN and PATH are required'
}

@test "missing PATH fails" {
    run filtergrep needle
    assert_failure
    assert_output --partial 'PATTERN and PATH are required'
}

@test "extra positional argument fails" {
    run filtergrep needle "$SRC" extra
    assert_failure
    assert_output --partial 'got extra: extra'
}

@test "nonexistent path fails" {
    run filtergrep needle "$TMPDIR_TEST/no-such-dir"
    assert_failure
    assert_output --partial 'path does not exist'
}

@test "non-integer --start fails" {
    run filtergrep needle "$SRC" --start abc
    assert_failure
    assert_output --partial '--start must be a positive integer'
}

@test "zero --end fails" {
    run filtergrep needle "$SRC" --end 0
    assert_failure
    assert_output --partial '--end must be a positive integer'
}

@test "--start greater than --end fails" {
    run filtergrep needle "$SRC" --start 5 --end 2
    assert_failure
    assert_output --partial 'must be <= --end'
}

@test "option without value fails" {
    run filtergrep needle "$SRC" --end
    assert_failure
    assert_output --partial '--end requires a value'
}

@test "unknown option fails" {
    run filtergrep needle "$SRC" --bogus
    assert_failure
    assert_output --partial 'unknown option: --bogus'
}

@test "without range lists every file containing the pattern" {
    run filtergrep needle "$SRC"
    assert_success
    assert_line "$SRC/head.txt"
    assert_line "$SRC/tail.txt"
    assert_line "$SRC/sub/mid.py"
    refute_line "$SRC/none.txt"
    assert_equal "${#lines[@]}" 3
}

@test "--end limits the search to the first lines" {
    run filtergrep needle "$SRC" --end 3
    assert_success
    assert_line "$SRC/head.txt"
    assert_line "$SRC/sub/mid.py"
    refute_line "$SRC/tail.txt"
}

@test "--start skips matches before the start line" {
    run filtergrep needle "$SRC" --start 2
    assert_success
    refute_line "$SRC/head.txt"
    assert_line "$SRC/sub/mid.py"
    assert_line "$SRC/tail.txt"
}

@test "--start and --end select an inclusive range" {
    run filtergrep needle "$SRC" --start 3 --end 3
    assert_success
    assert_output "$SRC/sub/mid.py"
}

@test "--include=<glob> restricts the searched files" {
    run filtergrep needle "$SRC" --include='*.py'
    assert_success
    assert_output "$SRC/sub/mid.py"
}

@test "--include <glob> form is accepted" {
    run filtergrep needle "$SRC" --include '*.txt' --end 1
    assert_success
    assert_output "$SRC/head.txt"
}

@test "options may precede the positional arguments" {
    run filtergrep --end 1 --include='*.txt' needle "$SRC"
    assert_success
    assert_output "$SRC/head.txt"
}

@test "a single file can be given as PATH" {
    run filtergrep needle "$SRC/tail.txt"
    assert_success
    assert_output "$SRC/tail.txt"
}

@test "pattern is an extended regular expression" {
    printf 'foo\n' > "$SRC/foo.re"
    printf 'bar\n' > "$SRC/bar.re"
    printf 'baz\n' > "$SRC/baz.re"
    run filtergrep '^(foo|ba+r)$' "$SRC" --include='*.re'
    assert_success
    assert_line "$SRC/foo.re"
    assert_line "$SRC/bar.re"
    refute_line "$SRC/baz.re"
}

@test "-F treats the pattern as a literal string" {
    printf 'a.b(c\n' > "$SRC/literal.fx"
    printf 'aXb(c\n' > "$SRC/other.fx"
    run filtergrep -F 'a.b(' "$SRC" --include='*.fx'
    assert_success
    assert_output "$SRC/literal.fx"
}

@test "-i ignores case for regex patterns" {
    printf 'NeEdLe here\n' > "$SRC/upper.ic"
    run filtergrep -i '^needle\s' "$SRC" --include='*.ic'
    assert_success
    assert_output "$SRC/upper.ic"
}

@test "-i ignores case for fixed strings" {
    printf 'A.B\n' > "$SRC/upper.ic"
    printf 'AxB\n' > "$SRC/other.ic"
    run filtergrep -F -i 'a.b' "$SRC" --include='*.ic'
    assert_success
    assert_output "$SRC/upper.ic"
}

@test "match is case sensitive by default" {
    printf 'NEEDLE\n' > "$SRC/upper.ic"
    run filtergrep needle "$SRC" --include='*.ic'
    assert_success
    assert_output ''
}

@test "pattern with slash, quotes and backslash is passed safely" {
    printf 'path/to "x" \\d\n' > "$SRC/special.sp"
    run filtergrep -F 'path/to "x" \d' "$SRC" --include='*.sp'
    assert_success
    assert_output "$SRC/special.sp"
}

@test "file names with spaces are handled" {
    printf 'needle\n' > "$SRC/with space.sp"
    run filtergrep needle "$SRC" --include='*.sp'
    assert_success
    assert_output "$SRC/with space.sp"
}

@test "-- allows a pattern starting with a dash" {
    printf 'set -euo pipefail\n' > "$SRC/dash.sp"
    run filtergrep --include='*.sp' -- '-euo' "$SRC"
    assert_success
    assert_output "$SRC/dash.sp"
}

@test "no match prints nothing and exits 0" {
    run filtergrep 'no-such-string' "$SRC"
    assert_success
    assert_output ''
}
