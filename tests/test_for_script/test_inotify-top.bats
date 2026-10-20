#!/usr/bin/env bats

setup() {
  bats_require_minimum_version 1.5.0
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
  DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
  export PATH="${DIR}/../../bin/linux:${PATH}"
  TMPDIR_TEST="$(mktemp -d)"
  export INOTIFY_TOP_PROC_ROOT="${TMPDIR_TEST}/proc"
  mkdir -p "${INOTIFY_TOP_PROC_ROOT}"
}

teardown() {
  chmod -R u+rwX "${TMPDIR_TEST}"
  rm -rf "${TMPDIR_TEST}"
}

make_process() {
  local pid="$1" watches="$2" app="$3" i
  mkdir -p "${INOTIFY_TOP_PROC_ROOT}/${pid}/fdinfo"
  printf '%s\n' "${app}" > "${INOTIFY_TOP_PROC_ROOT}/${pid}/comm"
  printf '%s\0%s\0' "${app}" '--flag' > "${INOTIFY_TOP_PROC_ROOT}/${pid}/cmdline"
  {
    printf 'pos:\t0\nnot inotify\n'
    for ((i = 0; i < watches; i++)); do
      printf 'inotify wd:%x\n' "${i}"
    done
  } > "${INOTIFY_TOP_PROC_ROOT}/${pid}/fdinfo/3"
}

@test "help includes usage and sudo guidance" {
  for option in -h --help; do
    run --separate-stderr inotify-top "${option}"
    assert_success
    assert_output --partial 'Script: inotify-top'
    assert_output --partial 'Usage:'
    assert_output --partial 'sudo inotify-top'
    [ -z "${stderr}" ]
  done
}

@test "invalid arguments print usage only to stderr and exit 2" {
  for value in -1 abc 1.5 +2 ''; do
    run --separate-stderr inotify-top -n "${value}"
    assert_equal "${status}" 2
    assert_output ''
    [[ "${stderr}" == *'Usage:'* ]]
  done
  for argument in -n --unknown positional; do
    run --separate-stderr inotify-top "${argument}"
    assert_equal "${status}" 2
    assert_output ''
    [[ "${stderr}" == *'Usage:'* ]]
  done
}

@test "TSV sums descriptors, ignores other lines and zeros, and sorts ties by PID" {
  make_process 20 2 beta
  make_process 3 3 alpha
  make_process 8 0 ignored
  printf 'inotify wd:99\n' > "${INOTIFY_TOP_PROC_ROOT}/20/fdinfo/4"
  run --separate-stderr inotify-top
  assert_success
  assert_output $'PID\tWATCHES\tAPP\n3\t3\talpha\n20\t3\tbeta'
  [ -z "${stderr}" ]
}

@test "default limit is 20, explicit limits work, and zero or all shows every record" {
  for ((pid = 1; pid <= 25; pid++)); do
    make_process "${pid}" "${pid}" "app${pid}"
  done
  run --separate-stderr inotify-top
  assert_success
  assert_equal "${#lines[@]}" 21
  assert_line --index 1 $'25\t25\tapp25'
  assert_line --index 20 $'6\t6\tapp6'
  [ -z "${stderr}" ]
  run inotify-top -n 2
  assert_success
  assert_equal "${#lines[@]}" 3
  run inotify-top -n 0002
  assert_success
  assert_equal "${#lines[@]}" 3
  run inotify-top -n 0
  assert_success
  assert_equal "${#lines[@]}" 26
  run inotify-top -n 1 --all
  assert_success
  assert_equal "${#lines[@]}" 26
  run inotify-top --all -n 1
  assert_success
  assert_equal "${#lines[@]}" 2
}

@test "empty scans produce header or an empty JSON array without stderr" {
  run --separate-stderr inotify-top
  assert_success
  assert_output $'PID\tWATCHES\tAPP'
  [ -z "${stderr}" ]
  run --separate-stderr inotify-top --json --cmd
  assert_success
  assert_output '[]'
  [ -z "${stderr}" ]
}

@test "JSON escapes quotes backslashes and control characters, preserving Unicode" {
  make_process 7 2 $'名"\\\t\n\r\001\037\n'
  run --separate-stderr inotify-top --json
  assert_success
  assert_output '[{"pid": 7, "watches": 2, "app": "名\"\\\u0009\u000a\u000d\u0001\u001f\u000a"}]'
  [ -z "${stderr}" ]
}

@test "JSON honors ordering and limit and separates records correctly" {
  make_process 20 2 beta
  make_process 3 2 alpha
  make_process 7 1 gamma
  run --separate-stderr inotify-top --json -n 2
  assert_success
  assert_output '[{"pid": 3, "watches": 2, "app": "alpha"}, {"pid": 20, "watches": 2, "app": "beta"}]'
  [ -z "${stderr}" ]
}

@test "cmd replaces NUL with spaces in both formats and handles empty cmdline" {
  make_process 7 1 worker
  run --separate-stderr inotify-top --cmd
  assert_success
  assert_output $'PID\tWATCHES\tAPP\tCMD\n7\t1\tworker\tworker --flag '
  [ -z "${stderr}" ]
  run --separate-stderr inotify-top --cmd --json
  assert_success
  assert_output '[{"pid": 7, "watches": 1, "app": "worker", "cmd": "worker --flag "}]'
  [ -z "${stderr}" ]
  : > "${INOTIFY_TOP_PROC_ROOT}/7/cmdline"
  run inotify-top --cmd --json
  assert_success
  assert_output '[{"pid": 7, "watches": 1, "app": "worker", "cmd": ""}]'
}

@test "cmd truncates at 200 characters and escapes JSON control characters" {
  make_process 7 1 worker
  printf '%0205d\0' 0 > "${INOTIFY_TOP_PROC_ROOT}/7/cmdline"
  printf -v expected '%0200d' 0
  run --separate-stderr inotify-top --cmd --json
  assert_success
  assert_output "[{\"pid\": 7, \"watches\": 1, \"app\": \"worker\", \"cmd\": \"${expected}\"}]"
  [ -z "${stderr}" ]
  printf 'a"\\\t\n\0' > "${INOTIFY_TOP_PROC_ROOT}/7/cmdline"
  run inotify-top --cmd --json
  assert_success
  assert_output '[{"pid": 7, "watches": 1, "app": "worker", "cmd": "a\"\\\u0009\u000a "}]'
}

@test "TSV escapes embedded delimiters so one process remains one record" {
  make_process 7 1 $'a\tb\nc\\d\r'
  run --separate-stderr inotify-top
  assert_success
  assert_output $'PID\tWATCHES\tAPP\n7\t1\ta\\tb\\nc\\\\d\\r'
  [ -z "${stderr}" ]
}

@test "missing proc files are skipped silently" {
  make_process 1 3 missing
  make_process 2 2 missingcmd
  make_process 3 1 good
  rm "${INOTIFY_TOP_PROC_ROOT}/1/comm" "${INOTIFY_TOP_PROC_ROOT}/2/cmdline"
  ln -s "${TMPDIR_TEST}/vanished" "${INOTIFY_TOP_PROC_ROOT}/3/fdinfo/4"
  run --separate-stderr inotify-top --cmd
  assert_success
  assert_output $'PID\tWATCHES\tAPP\tCMD\n3\t1\tgood\tgood --flag '
  [ -z "${stderr}" ]
}

@test "unreadable processes and descriptors are skipped silently" {
  if [[ "${EUID}" == 0 ]]; then
    skip 'permission checks require an unprivileged user'
  fi
  make_process 1 3 hidden
  make_process 2 2 hidden
  make_process 3 1 good
  make_process 4 4 hidden
  chmod 000 "${INOTIFY_TOP_PROC_ROOT}/1/fdinfo" \
    "${INOTIFY_TOP_PROC_ROOT}/2/comm" "${INOTIFY_TOP_PROC_ROOT}/4/fdinfo/3"
  run --separate-stderr inotify-top
  assert_success
  assert_output $'PID\tWATCHES\tAPP\n3\t1\tgood'
  [ -z "${stderr}" ]
}

@test "missing proc root reports an actionable error" {
  export INOTIFY_TOP_PROC_ROOT="${TMPDIR_TEST}/missing"
  run --separate-stderr inotify-top
  assert_failure
  assert_output ''
  [[ "${stderr}" == 'Error: cannot read proc directory:'* ]]
}
