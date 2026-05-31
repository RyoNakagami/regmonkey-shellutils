#!/usr/bin/env bats

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"

    OLD_PATH=$PATH
    PATH="$DIR/../../bin/edit:$PATH"

    TMPDIR_TEST="$(mktemp -d)"
}

teardown() {
    PATH=$OLD_PATH
    rm -rf "$TMPDIR_TEST"
}

@test "help option prints docstring and exits 0" {
    run punkt -h
    assert_success
    assert_output --partial 'Script: punkt'
    assert_output --partial 'Usage:'
}

@test "unknown option fails" {
    run punkt --no-such-flag
    assert_failure
    assert_output --partial 'Error: unknown option: --no-such-flag'
}

@test "nonexistent target fails" {
    run punkt "$TMPDIR_TEST/does-not-exist.txt"
    assert_failure
    assert_output --partial 'target does not exist'
}

@test "map without braces fails" {
    f="$TMPDIR_TEST/a.txt"
    printf 'x\n' > "$f"
    run punkt "$f" --map '、:，'
    assert_failure
    assert_output --partial 'must be wrapped in braces'
}

@test "map entry missing colon fails" {
    f="$TMPDIR_TEST/a.txt"
    printf 'x\n' > "$f"
    run punkt "$f" --map '{abc}'
    assert_failure
    assert_output --partial "missing ':'"
}

@test "default conversion replaces touten and kuten in place" {
    f="$TMPDIR_TEST/a.txt"
    printf 'これはテスト、です。次の行。\n' > "$f"
    run punkt "$f"
    assert_success
    assert_output --partial "changed: $f"
    run cat "$f"
    assert_output 'これはテスト，です．次の行．'
}

@test "preserves absence of trailing newline" {
    f="$TMPDIR_TEST/b.txt"
    printf 'end、here。' > "$f"   # no trailing newline
    run punkt "$f"
    assert_success
    # byte count must stay the same (， and ． are same width as 、 and 。 in UTF-8)
    [ "$(wc -c < "$f")" -eq "$(printf 'end，here．' | wc -c)" ]
    # and there is still no trailing newline
    run tail -c 1 "$f"
    refute_output $'\n'
}

@test "dry-run reports but does not modify the file" {
    f="$TMPDIR_TEST/a.txt"
    printf '残し、たい。\n' > "$f"
    before="$(cat "$f")"
    run punkt "$f" --dry-run
    assert_success
    assert_output --partial "would change: $f"
    [ "$(cat "$f")" = "$before" ]
}

@test "no change reports 'No files changed.'" {
    f="$TMPDIR_TEST/a.txt"
    printf 'plain ascii only\n' > "$f"
    run punkt "$f"
    assert_success
    assert_output --partial 'No files changed.'
}

@test "custom map applies arbitrary string replacements" {
    f="$TMPDIR_TEST/a.txt"
    printf 'foo and 、 done\n' > "$f"
    run punkt "$f" --map '{foo:bar, 、:，}'
    assert_success
    run cat "$f"
    assert_output 'bar and ， done'
}

@test "directory mode is non-recursive by default" {
    mkdir -p "$TMPDIR_TEST/sub"
    printf 'トップ、です。\n' > "$TMPDIR_TEST/top.txt"
    printf 'サブ、です。\n'   > "$TMPDIR_TEST/sub/deep.txt"
    run punkt "$TMPDIR_TEST"
    assert_success
    [ "$(cat "$TMPDIR_TEST/top.txt")" = 'トップ，です．' ]
    # subdirectory file untouched
    [ "$(cat "$TMPDIR_TEST/sub/deep.txt")" = 'サブ、です。' ]
}

@test "recursive flag converts files in subdirectories" {
    mkdir -p "$TMPDIR_TEST/sub"
    printf 'サブ、です。\n' > "$TMPDIR_TEST/sub/deep.txt"
    run punkt "$TMPDIR_TEST" -r
    assert_success
    [ "$(cat "$TMPDIR_TEST/sub/deep.txt")" = 'サブ，です．' ]
}

@test "hidden files are skipped" {
    printf '隠し、ファイル。\n' > "$TMPDIR_TEST/.hidden.txt"
    run punkt "$TMPDIR_TEST"
    assert_success
    [ "$(cat "$TMPDIR_TEST/.hidden.txt")" = '隠し、ファイル。' ]
}

@test "binary files (containing NUL) are skipped" {
    f="$TMPDIR_TEST/bin.dat"
    printf 'a\x00b、c。\n' > "$f"
    before="$(wc -c < "$f")"
    run punkt "$f"
    assert_success
    assert_output --partial 'No files changed.'
    [ "$(wc -c < "$f")" -eq "$before" ]
}
