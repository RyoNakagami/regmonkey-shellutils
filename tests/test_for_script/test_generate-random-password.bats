#!/usr/bin/env bats

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"

    OLD_PATH=$PATH
    PATH="$DIR/../../bin/utils:$PATH"
}

teardown() {
    PATH=$OLD_PATH
}

# length helper: prints number of characters on the single output line
_len_of() {
    printf '%s' "$1" | wc -c | tr -d ' '
}

@test "help option prints docstring and exits 0" {
    run generate-random-password -h
    assert_success
    assert_output --partial 'Script: generate-random-passwd'
    assert_output --partial 'Usage:'
}

@test "no argument uses default length of 16 (base64)" {
    run generate-random-password
    assert_success
    [ "$(_len_of "$output")" = "16" ]
}

@test "default output is base64 alphabet only" {
    run generate-random-password
    assert_success
    assert_output --regexp '^[A-Za-z0-9+/=]+$'
}

@test "explicit length produces exactly that many base64 chars" {
    run generate-random-password 32
    assert_success
    [ "$(_len_of "$output")" = "32" ]
}

@test "numeric flag produces digits only" {
    run generate-random-password -n 20
    assert_success
    [ "$(_len_of "$output")" = "20" ]
    assert_output --regexp '^[0-9]+$'
}

@test "numeric flag after length is also accepted" {
    run generate-random-password 20 -n
    assert_success
    [ "$(_len_of "$output")" = "20" ]
    assert_output --regexp '^[0-9]+$'
}

@test "numeric flag with no length uses default length of 16" {
    run generate-random-password -n
    assert_success
    [ "$(_len_of "$output")" = "16" ]
    assert_output --regexp '^[0-9]+$'
}

@test "zero length is rejected" {
    run generate-random-password 0
    assert_failure
    assert_output --partial 'positive integer'
}

@test "non-integer length is rejected" {
    run generate-random-password abc
    assert_failure
    assert_output --partial 'Unexpected argument'
}

@test "length of 77 or more is rejected" {
    run generate-random-password 77
    assert_failure
    assert_output --partial 'less than 77'
}

@test "unknown option fails" {
    run generate-random-password -x 16
    assert_failure
    assert_output --partial 'Usage:'
}
