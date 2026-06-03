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

@test "help option prints docstring and exits 0" {
    run isoweek -h
    assert_success
    assert_output --partial 'Script: isoweek'
    assert_output --partial 'Usage:'
}

@test "missing datetime argument fails" {
    run isoweek
    assert_failure
    assert_output --partial 'DATETIME argument is required'
}

@test "unknown option fails" {
    run isoweek -x 2025-01-03
    assert_failure
    assert_output --partial 'unknown option'
}

@test "invalid datetime format fails" {
    run isoweek not-a-date
    assert_failure
    assert_output --partial 'Invalid datetime format'
}

@test "too many arguments fails" {
    run isoweek 2025-01-03 2025-01-04
    assert_failure
    assert_output --partial 'too many arguments'
}

@test "happy path: 2025-01-03 is ISO week 01" {
    run isoweek 2025-01-03
    assert_success
    assert_output '01'
}

@test "utc flag converts across timezone boundary" {
    # 2024-12-30T05:00:00+09:00 is Mon Dec 30 in Tokyo (week 01 of 2025)
    # but Sun Dec 29 20:00 in UTC (week 52 of 2024).
    TZ=Asia/Tokyo run isoweek 2024-12-30T05:00:00+09:00
    assert_success
    assert_output '01'

    TZ=Asia/Tokyo run isoweek -u 2024-12-30T05:00:00+09:00
    assert_success
    assert_output '52'
}

@test "option placed after positional argument is accepted" {
    TZ=Asia/Tokyo run isoweek 2024-12-30T05:00:00+09:00 -u
    assert_success
    assert_output '52'
}