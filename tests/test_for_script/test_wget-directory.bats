#!/usr/bin/env bats

# wget-directory は wget を使ってウェブサイトのディレクトリを再帰ダウンロードする。
# 実際のネットワーク通信は行わず、PATH 先頭に置いた wget スタブが
# 受け取った引数を stdout にそのまま出力することで、
# 引数組み立て（深さ / include(-A) / exclude(-R) / URL 位置）を検証する。

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"

    TMPDIR_TEST="$(mktemp -d)"

    # wget stub: prints its arguments, one per line, prefixed for matching.
    cat > "$TMPDIR_TEST/wget" <<'EOF'
#!/bin/bash
for a in "$@"; do
    printf 'ARG:%s\n' "$a"
done
EOF
    chmod +x "$TMPDIR_TEST/wget"

    OLD_PATH=$PATH
    # stub dir first so 'wget' resolves to it, then the script dir.
    PATH="$TMPDIR_TEST:$DIR/../../bin/utils:$PATH"
}

teardown() {
    PATH=$OLD_PATH
    rm -rf "$TMPDIR_TEST"
}

# ---------------------------------------------------------------------------
# help / version / option parsing
# ---------------------------------------------------------------------------

@test "help option -h prints docstring and exits 0" {
    run wget-directory -h
    assert_success
    assert_output --partial 'Script: wget-directory'
    assert_output --partial 'Usage:'
}

@test "help option --help prints docstring and exits 0" {
    run wget-directory --help
    assert_success
    assert_output --partial 'Script: wget-directory'
}

@test "version option -v prints package name and version" {
    run wget-directory -v
    assert_success
    assert_output "regmonkey-shellutils $(cat "$DIR/../../VERSION")"
}

@test "version option --version prints package name and version" {
    run wget-directory --version
    assert_success
    assert_output "regmonkey-shellutils $(cat "$DIR/../../VERSION")"
}

@test "unknown option fails with error message" {
    run wget-directory -z
    assert_failure
    assert_output --partial 'Error: unknown option: -z'
    assert_output --partial 'Use --help'
}

@test "option requiring argument fails when missing" {
    run wget-directory -d
    assert_failure
    assert_output --partial 'Error: option -d requires an argument.'
}

@test "no target URL fails with error message" {
    run wget-directory
    assert_failure
    assert_output --partial 'Error: no target URL specified'
    assert_output --partial 'Use --help'
}

@test "extra positional argument fails" {
    run wget-directory https://example.com/ extra
    assert_failure
    assert_output --partial 'Error: unexpected argument: extra'
}

@test "non-integer depth fails" {
    run wget-directory -l abc https://example.com/
    assert_failure
    assert_output --partial 'Error: -l depth must be a positive integer: abc'
}

@test "zero depth fails" {
    run wget-directory -l 0 https://example.com/
    assert_failure
    assert_output --partial 'Error: -l depth must be a positive integer: 0'
}

# ---------------------------------------------------------------------------
# argument construction (via wget stub)
# ---------------------------------------------------------------------------

@test "default invocation passes base flags and default depth 5" {
    run wget-directory https://example.com/
    assert_success
    assert_output --partial 'ARG:-e'
    assert_output --partial 'ARG:robots=off'
    assert_output --partial 'ARG:--recursive'
    assert_output --partial 'ARG:--no-parent'
    assert_output --partial 'ARG:-l'
    assert_output --partial 'ARG:5'
    assert_output --partial 'ARG:https://example.com/'
}

@test "positional URL and -d URL are equivalent" {
    run wget-directory -d https://example.com/
    assert_success
    assert_output --partial 'ARG:https://example.com/'
}

@test "-l overrides the recursion depth" {
    run wget-directory -l 30 https://example.com/
    assert_success
    assert_output --partial 'ARG:-l'
    assert_output --partial 'ARG:30'
    refute_output --partial 'ARG:5'
}

@test "-i adds an accept list (-A)" {
    run wget-directory -i pdf https://example.com/
    assert_success
    assert_output --partial 'ARG:-A'
    assert_output --partial 'ARG:pdf'
    refute_output --partial 'ARG:-R'
}

@test "-e adds a reject list (-R)" {
    run wget-directory -e 'zip,tar.gz' https://example.com/
    assert_success
    assert_output --partial 'ARG:-R'
    assert_output --partial 'ARG:zip,tar.gz'
    refute_output --partial 'ARG:-A'
}

@test "comma-separated include is passed as a single argument" {
    run wget-directory -i 'pdf,ps,djvu' https://example.com/
    assert_success
    assert_output --partial 'ARG:pdf,ps,djvu'
}

@test "include and exclude can be combined" {
    run wget-directory -i pdf -e tmp https://example.com/
    assert_success
    assert_output --partial 'ARG:-A'
    assert_output --partial 'ARG:pdf'
    assert_output --partial 'ARG:-R'
    assert_output --partial 'ARG:tmp'
}

@test "URL is the last argument passed to wget" {
    run wget-directory -i pdf https://example.com/dir/
    assert_success
    last_line="$(printf '%s\n' "$output" | tail -n 1)"
    assert_equal "$last_line" 'ARG:https://example.com/dir/'
}
