#!/usr/bin/env bats

setup() {
  bats_require_minimum_version 1.5.0
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
  DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
  export PATH="${DIR}/../../bin/linux:${PATH}"
  TMPDIR_TEST="$(mktemp -d)"
  export GREP_INOTIFY_PROC_ROOT="${TMPDIR_TEST}/proc"
  ROOT="${TMPDIR_TEST}/root"
  mkdir -p "${GREP_INOTIFY_PROC_ROOT}/123/fdinfo" "${ROOT}" \
    "${TMPDIR_TEST}/scratch" "${TMPDIR_TEST}/mock-bin"
  : > "${GREP_INOTIFY_PROC_ROOT}/123/fdinfo/3"
}

teardown() {
  chmod -R u+rwX "${TMPDIR_TEST}"
  rm -rf "${TMPDIR_TEST}"
}

watch_path() {
  local inode
  inode="$(stat -c '%i' -- "$1")"
  printf 'inotify wd:1 ino:%x sdev:800 mask:fff\n' "${inode}" \
    >> "${GREP_INOTIFY_PROC_ROOT}/123/fdinfo/${2:-3}"
}

assert_summary() {
  assert_equal "${stderr}" \
    "Watched inodes: $1; found: $2; not found: $3 (outside root, another filesystem, or file watches)"
}

assert_no_temporary_files() {
  [ -z "$(find "${TMPDIR_TEST}/scratch" -mindepth 1 -print)" ]
}

@test "help explains full scan sudo and options" {
  for option in -h --help; do
    run --separate-stderr grep-inotify "${option}"
    assert_success
    assert_output --partial 'Script: grep-inotify'
    assert_output --partial 'Usage:'
    assert_output --partial 'large trees take time'
    assert_output --partial "sudo is required"
    [ -z "${stderr}" ]
  done
}

@test "missing nonnumeric and nonexistent PID exit 1" {
  run --separate-stderr grep-inotify
  assert_equal "${status}" 1
  assert_output ''
  assert_equal "${stderr}" 'Error: PID is required'
  run --separate-stderr grep-inotify abc
  assert_equal "${status}" 1
  assert_output ''
  assert_equal "${stderr}" 'Error: PID must be numeric: abc'
  run --separate-stderr grep-inotify 999
  assert_equal "${status}" 1
  assert_output ''
  assert_equal "${stderr}" 'Error: process does not exist: 999'
}

@test "invalid options values and extra PIDs exit 2 with usage on stderr" {
  for option in --bad -d --depth -n -r --root; do
    run --separate-stderr grep-inotify "${option}"
    assert_equal "${status}" 2
    assert_output ''
    [[ "${stderr}" == *'Usage:'* ]]
  done
  for value in -1 1.5 abc ''; do
    for option in -d --depth -n; do
      run --separate-stderr grep-inotify "${option}" "${value}" 123
      assert_equal "${status}" 2
      assert_output ''
      [[ "${stderr}" == *'Usage:'* ]]
    done
  done
  run --separate-stderr grep-inotify -d 0 123
  assert_equal "${status}" 2
  [[ "${stderr}" == *'positive integer'* ]]
  run --separate-stderr grep-inotify 123 456
  assert_equal "${status}" 2
  [[ "${stderr}" == *'Usage:'* ]]
}

@test "depth is relative to root with descending counts and ascending path ties" {
  mkdir -p "${ROOT}/b/one/x" "${ROOT}/a/one/x" "${ROOT}/a/two"
  watch_path "${ROOT}/b/one"
  watch_path "${ROOT}/b/one/x"
  watch_path "${ROOT}/a/one"
  watch_path "${ROOT}/a/one/x"
  watch_path "${ROOT}/a/two"
  run --separate-stderr grep-inotify -r "${ROOT}" --depth 2 123
  assert_success
  assert_output "$(printf 'COUNT\tPATH\n2\t%s/a/one\n2\t%s/b/one\n1\t%s/a/two' \
    "${ROOT}" "${ROOT}" "${ROOT}")"
  assert_summary 5 5 0
}

@test "default depth is three and shallow paths including root stay intact" {
  mkdir -p "${ROOT}/a/b/c/d"
  watch_path "${ROOT}"
  watch_path "${ROOT}/a"
  watch_path "${ROOT}/a/b/c"
  watch_path "${ROOT}/a/b/c/d"
  run --separate-stderr grep-inotify --root "${ROOT}/" 123
  assert_success
  assert_output "$(printf 'COUNT\tPATH\n2\t%s/a/b/c\n1\t%s\n1\t%s/a' \
    "${ROOT}" "${ROOT}" "${ROOT}")"
  assert_summary 4 4 0
}

@test "duplicates across descriptors are removed and non-inotify lines ignored" {
  mkdir "${ROOT}/a"
  watch_path "${ROOT}/a"
  watch_path "${ROOT}/a" 4
  printf 'pos: 0 ino:ffffffff\nnot inotify ino:ff\ninotify wd:2 mask:0\n' \
    >> "${GREP_INOTIFY_PROC_ROOT}/123/fdinfo/3"
  run --separate-stderr grep-inotify -r "${ROOT}" --json 123
  assert_success
  assert_output "[{\"count\": 1, \"path\": \"${ROOT}/a\"}]"
  assert_summary 1 1 0
}

@test "summary includes unmatched file and outside-root watches before limiting" {
  mkdir -p "${ROOT}/a" "${ROOT}/b" "${TMPDIR_TEST}/outside"
  : > "${ROOT}/file"
  watch_path "${ROOT}/a"
  watch_path "${ROOT}/b"
  watch_path "${ROOT}/file"
  watch_path "${TMPDIR_TEST}/outside"
  ln -s "${TMPDIR_TEST}/outside" "${ROOT}/link"
  run --separate-stderr grep-inotify -r "${ROOT}" -n 1 123
  assert_success
  assert_output "$(printf 'COUNT\tPATH\n1\t%s/a' "${ROOT}")"
  assert_summary 4 2 2
}

@test "default top 20 explicit limit zero and all work" {
  for ((i = 1; i <= 25; i++)); do
    mkdir "${ROOT}/dir${i}"
    watch_path "${ROOT}/dir${i}"
  done
  run --separate-stderr grep-inotify -r "${ROOT}" 123
  assert_success
  assert_equal "${#lines[@]}" 21
  assert_summary 25 25 0
  run --separate-stderr grep-inotify -r "${ROOT}" -n 2 --json 123
  assert_success
  assert_output "[{\"count\": 1, \"path\": \"${ROOT}/dir1\"}, {\"count\": 1, \"path\": \"${ROOT}/dir10\"}]"
  assert_summary 25 25 0
  run --separate-stderr grep-inotify -r "${ROOT}" -n 0 123
  assert_success
  assert_equal "${#lines[@]}" 26
  run --separate-stderr grep-inotify -r "${ROOT}" -n 1 --all 123
  assert_success
  assert_equal "${#lines[@]}" 26
}

@test "default root uses HOME and leading zeros in numeric options work" {
  mkdir -p "${ROOT}/a/b"
  watch_path "${ROOT}/a/b"
  HOME="${ROOT}" run --separate-stderr grep-inotify -d 01 -n 0001 00123
  assert_success
  assert_output "$(printf 'COUNT\tPATH\n1\t%s/a' "${ROOT}")"
  assert_summary 1 1 0
}

@test "empty inode sets output empty JSON or TSV with a zero summary" {
  run --separate-stderr grep-inotify -r "${ROOT}" --json 123
  assert_success
  assert_output '[]'
  assert_summary 0 0 0
  run --separate-stderr grep-inotify -r "${ROOT}" 123
  assert_success
  assert_output $'COUNT\tPATH'
  assert_summary 0 0 0
}

@test "no matches produce an empty result with an unmatched summary" {
  mkdir "${TMPDIR_TEST}/outside"
  watch_path "${TMPDIR_TEST}/outside"
  run --separate-stderr grep-inotify -r "${ROOT}" --json 123
  assert_success
  assert_output '[]'
  assert_summary 1 0 1
}

@test "JSON and TSV preserve paths with quotes backslashes tabs and newlines" {
  special=$'名"\\\t\n\r\001'
  mkdir "${ROOT}/${special}"
  watch_path "${ROOT}/${special}"
  run --separate-stderr grep-inotify -r "${ROOT}" --json 123
  assert_success
  assert_output '[{"count": 1, "path": "'"${ROOT}"'/名\"\\\u0009\u000a\u000d\u0001"}]'
  assert_summary 1 1 0
  run --separate-stderr grep-inotify -r "${ROOT}" 123
  assert_success
  assert_output $'COUNT\tPATH\n1\t'"${ROOT}"$'/名"\\\\\\t\\n\\r\001'
  assert_summary 1 1 0
}

@test "64-bit inode conversion is exact and find uses xdev and directory filtering" {
  printf 'inotify ino:ffffffffffffffff\ninotify ino:20000000000001\ninotify ino:FFFFFFFFFFFFFFFF\n' \
    > "${GREP_INOTIFY_PROC_ROOT}/123/fdinfo/3"
  cat > "${TMPDIR_TEST}/mock-bin/find" <<'SH'
#!/bin/bash
[[ "$2" == -xdev && "$3" == -type && "$4" == d ]] || exit 99
printf '18446744073709551615\0%s/a\0' "$1"
printf '9007199254740993\0%s/b\0' "$1"
printf '9007199254740992\0%s/not-watched\0' "$1"
SH
  chmod +x "${TMPDIR_TEST}/mock-bin/find"
  PATH="${TMPDIR_TEST}/mock-bin:${PATH}" run --separate-stderr \
    grep-inotify -r "${ROOT}" --all 123
  assert_success
  assert_output "$(printf 'COUNT\tPATH\n1\t%s/a\n1\t%s/b' "${ROOT}" "${ROOT}")"
  assert_summary 2 2 0
}

@test "missing fdinfo and invalid search root exit 1" {
  run --separate-stderr grep-inotify -r "${TMPDIR_TEST}/missing" 123
  assert_equal "${status}" 1
  assert_output ''
  [[ "${stderr}" == *'cannot read search root'* ]]
  rm "${GREP_INOTIFY_PROC_ROOT}/123/fdinfo/3"
  rmdir "${GREP_INOTIFY_PROC_ROOT}/123/fdinfo"
  run --separate-stderr grep-inotify -r "${ROOT}" 123
  assert_equal "${status}" 1
  assert_output ''
  [[ "${stderr}" == *'cannot read fdinfo'* ]]
}

@test "unreadable fdinfo directory or file exits 1" {
  if [[ "${EUID}" == 0 ]]; then skip 'requires an unprivileged user'; fi
  chmod 000 "${GREP_INOTIFY_PROC_ROOT}/123/fdinfo"
  run --separate-stderr grep-inotify -r "${ROOT}" 123
  assert_equal "${status}" 1
  assert_output ''
  [[ "${stderr}" == *'cannot read fdinfo'* ]]
  chmod 700 "${GREP_INOTIFY_PROC_ROOT}/123/fdinfo"
  chmod 000 "${GREP_INOTIFY_PROC_ROOT}/123/fdinfo/3"
  TMPDIR="${TMPDIR_TEST}/scratch" run --separate-stderr grep-inotify -r "${ROOT}" 123
  assert_equal "${status}" 1
  assert_output ''
  [[ "${stderr}" == *'cannot read fdinfo'* ]]
  assert_no_temporary_files
}

@test "temporary files are removed after success" {
  mkdir "${ROOT}/a"
  watch_path "${ROOT}/a"
  TMPDIR="${TMPDIR_TEST}/scratch" run --separate-stderr grep-inotify -r "${ROOT}" 123
  assert_success
  assert_summary 1 1 0
  assert_no_temporary_files
}

@test "failed directory scan exits 1 and cleans temporary files without partial output" {
  watch_path "${ROOT}"
  cat > "${TMPDIR_TEST}/mock-bin/find" <<'SH'
#!/bin/bash
printf 'find: permission denied\n' >&2
exit 1
SH
  chmod +x "${TMPDIR_TEST}/mock-bin/find"
  TMPDIR="${TMPDIR_TEST}/scratch" PATH="${TMPDIR_TEST}/mock-bin:${PATH}" \
    run --separate-stderr grep-inotify -r "${ROOT}" 123
  assert_equal "${status}" 1
  assert_output ''
  [[ "${stderr}" == *'directory scan incomplete'* ]]
  assert_no_temporary_files
}

@test "filesystem root groups paths without doubled slashes" {
  printf 'inotify ino:1\ninotify ino:2\ninotify ino:3\n' \
    > "${GREP_INOTIFY_PROC_ROOT}/123/fdinfo/3"
  cat > "${TMPDIR_TEST}/mock-bin/find" <<'SH'
#!/bin/bash
printf '%s\0%s\0' 1 / 2 /home/user/project 3 /home/user/project/src
SH
  chmod +x "${TMPDIR_TEST}/mock-bin/find"
  PATH="${TMPDIR_TEST}/mock-bin:${PATH}" run --separate-stderr \
    grep-inotify -r / -d 2 123
  assert_success
  assert_output $'COUNT\tPATH\n2\t/home/user\n1\t/'
  assert_summary 3 3 0
}

@test "TERM cleans temporary files and exits with signal status" {
  watch_path "${ROOT}"
  cat > "${TMPDIR_TEST}/mock-bin/find" <<'SH'
#!/bin/bash
kill -TERM "${PPID}"
SH
  chmod +x "${TMPDIR_TEST}/mock-bin/find"
  TMPDIR="${TMPDIR_TEST}/scratch" PATH="${TMPDIR_TEST}/mock-bin:${PATH}" \
    run --separate-stderr grep-inotify -r "${ROOT}" 123
  assert_equal "${status}" 143
  assert_output ''
  assert_no_temporary_files
}
