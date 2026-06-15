#!/usr/bin/env bats

# zgrep / dpkg-query は PATH 先頭の stub で差し替え、決定的にテストする。
# 入力ファイルは REBOOT_PKGS_FILE、dpkg ログの glob は DPKG_LOG_GLOB で
# sandbox 内に向ける。stub は DPKG_LOG_GLOB の中身を grep して動く。

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"

    TMPDIR_TEST="$(mktemp -d)"
    STUB_DIR="$TMPDIR_TEST/bin"
    mkdir -p "$STUB_DIR"

    # zgrep stub: $DPKG_LOG_GLOB が指す単一ファイルを grep する。
    cat > "$STUB_DIR/zgrep" <<'EOF'
#!/bin/bash
# 末尾引数 = glob (テストでは単一ファイル)、その手前が pattern。
file="${@: -1}"
pattern="${@: -2:1}"
[[ -f "$file" ]] || exit 1
grep -h -E "$pattern" "$file" 2>/dev/null
EOF
    chmod +x "$STUB_DIR/zgrep"

    # dpkg-query stub: 既知パッケージのみバージョンを返す。
    cat > "$STUB_DIR/dpkg-query" <<'EOF'
#!/bin/bash
for a in "$@"; do last="$a"; done
case "$last" in
    libssl3) echo "3.0.2-installed" ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$STUB_DIR/dpkg-query"

    export REBOOT_PKGS_FILE="$TMPDIR_TEST/reboot-required.pkgs"
    export DPKG_LOG_GLOB="$TMPDIR_TEST/dpkg.log"
    : > "$DPKG_LOG_GLOB"

    OLD_PATH=$PATH
    PATH="$STUB_DIR:$DIR/../../bin/linux:$PATH"
}

teardown() {
    PATH=$OLD_PATH
    unset REBOOT_PKGS_FILE DPKG_LOG_GLOB
    rm -rf "$TMPDIR_TEST"
}

# ---------------------------------------------------------------------------
# help / version / option parsing
# ---------------------------------------------------------------------------

@test "help option -h prints docstring and exits 0" {
    run check-reboot-required -h
    assert_success
    assert_output --partial 'Script: check-reboot-required'
    assert_output --partial 'Usage:'
}

@test "help option --help prints docstring and exits 0" {
    run check-reboot-required --help
    assert_success
    assert_output --partial 'Script: check-reboot-required'
}

@test "version option -v prints package name and VERSION content" {
    run check-reboot-required -v
    assert_success
    assert_output "regmonkey-shellutils $(cat "$DIR/../../VERSION")"
}

@test "version option --version prints package name and VERSION content" {
    run check-reboot-required --version
    assert_success
    assert_output "regmonkey-shellutils $(cat "$DIR/../../VERSION")"
}

@test "unknown option fails with error message" {
    run check-reboot-required -z
    assert_failure
    assert_output --partial 'Error: unknown option: -z'
    assert_output --partial 'Use --help'
}

@test "unexpected positional argument fails" {
    run check-reboot-required foo
    assert_failure
    assert_output --partial 'Error: unexpected argument: foo'
}

# ---------------------------------------------------------------------------
# data path
# ---------------------------------------------------------------------------

@test "no reboot-required file reports no reboot required" {
    rm -f "$REBOOT_PKGS_FILE"
    run check-reboot-required
    assert_success
    assert_output "no reboot required"
}

@test "upgrade entry yields before/after versions and timestamp" {
    echo "linux-image-generic" > "$REBOOT_PKGS_FILE"
    cat > "$DPKG_LOG_GLOB" <<'EOF'
2026-06-10 09:00:00 upgrade linux-image-generic:amd64 5.15.0-100 5.15.0-101
2026-06-14 18:30:00 upgrade linux-image-generic:amd64 5.15.0-101 5.15.0-102
EOF
    run check-reboot-required
    assert_success
    assert_line --index 0 --partial 'PACKAGE'
    assert_output --partial 'linux-image-generic'
    assert_output --partial '5.15.0-101'
    assert_output --partial '5.15.0-102'
    assert_output --partial '2026-06-14 18:30:00'
    # 古い方の after は採用されない
    refute_output --partial '5.15.0-100'
}

@test "install entry reports (none) as before version" {
    echo "newpkg" > "$REBOOT_PKGS_FILE"
    cat > "$DPKG_LOG_GLOB" <<'EOF'
2026-06-12 07:15:00 install newpkg:amd64 <none> 1.0.0
EOF
    run check-reboot-required
    assert_success
    assert_output --partial 'newpkg'
    assert_output --partial '(none)'
    assert_output --partial '1.0.0'
    assert_output --partial '2026-06-12 07:15:00'
}

@test "package without log entry falls back to dpkg-query version" {
    echo "libssl3" > "$REBOOT_PKGS_FILE"
    : > "$DPKG_LOG_GLOB"
    run check-reboot-required
    assert_success
    assert_output --partial 'libssl3'
    assert_output --partial '3.0.2-installed'
    assert_output --partial 'N/A'
}

@test "duplicate packages are collapsed to a single row" {
    printf 'libssl3\nlibssl3\n' > "$REBOOT_PKGS_FILE"
    : > "$DPKG_LOG_GLOB"
    run check-reboot-required
    assert_success
    count="$(grep -c 'libssl3' <<< "$output")"
    assert_equal "$count" 1
}
