#!/usr/bin/env bats

# multiclamscan はディレクトリ直下のファイルを ClamAV で並列スキャンし、
# 結果をタイムスタンプ付きログに保存する。
#
# 外部コマンド clamscan はスタブで差し替える。infected を模すスタブは
# clamscan 同様に 'FOUND' 行を出して exit 1 する。ログ出力先は
# MULTICLAMSCAN_LOG_DIR で mktemp sandbox に閉じ込め、teardown で削除する。

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"

    TMPDIR_TEST="$(mktemp -d)"
    STUB_DIR="$TMPDIR_TEST/bin"
    SCAN_DIR="$TMPDIR_TEST/scan"
    export MULTICLAMSCAN_LOG_DIR="$TMPDIR_TEST/logs"
    mkdir -p "$STUB_DIR" "$SCAN_DIR"

    # 既定の clamscan スタブ: clean。スキャン対象パスを 1 行出して exit 0。
    cat > "$STUB_DIR/clamscan" <<'EOF'
#!/bin/bash
target="${!#}"
echo "${target}: OK"
exit 0
EOF
    chmod +x "$STUB_DIR/clamscan"

    OLD_PATH=$PATH
    PATH="$STUB_DIR:$DIR/../../bin/linux:/usr/bin:/bin"
}

teardown() {
    PATH=$OLD_PATH
    rm -rf "$TMPDIR_TEST"
}

# clamscan スタブを infected 版に差し替えるヘルパ
_use_infected_stub() {
    cat > "$STUB_DIR/clamscan" <<'EOF'
#!/bin/bash
target="${!#}"
echo "${target}: Eicar-Test-Signature FOUND"
exit 1
EOF
    chmod +x "$STUB_DIR/clamscan"
}

# ---------------------------------------------------------------------------
# help / version
# ---------------------------------------------------------------------------

@test "help option -h prints docstring and exits 0" {
    run multiclamscan -h
    assert_success
    assert_output --partial 'Script: multiclamscan'
    assert_output --partial 'Usage:'
}

@test "version option -V prints package version and exits 0" {
    run multiclamscan -V
    assert_success
    assert_output --partial 'regmonkey-shellutils'
}

# ---------------------------------------------------------------------------
# validation failures
# ---------------------------------------------------------------------------

@test "missing -d fails with required message" {
    run multiclamscan
    assert_failure
    assert_output --partial '-d <directory> is required'
}

@test "non-existent directory fails" {
    run multiclamscan -d "$TMPDIR_TEST/nope"
    assert_failure
    assert_output --partial 'directory not found'
}

@test "non-numeric -p fails" {
    run multiclamscan -d "$SCAN_DIR" -p abc
    assert_failure
    assert_output --partial '-p must be a positive integer'
}

@test "zero -p fails" {
    run multiclamscan -d "$SCAN_DIR" -p 0
    assert_failure
    assert_output --partial '-p must be a positive integer'
}

@test "invalid -m fails" {
    run multiclamscan -d "$SCAN_DIR" -m 100X
    assert_failure
    assert_output --partial '-m must be a size'
}

@test "missing clamscan binary fails" {
    # clamscan がシステムに実在しても検出しないよう、必要な最小限のツール
    # だけを symlink した隔離 bin を作り、そこに clamscan を含めない。
    NOCLAM="$TMPDIR_TEST/noclam"
    mkdir -p "$NOCLAM"
    for t in bash find xargs realpath date grep mkdir ls dirname; do
        src="$(command -v "$t")"
        [[ -n "$src" ]] && ln -s "$src" "$NOCLAM/$t"
    done
    PATH="$NOCLAM:$DIR/../../bin/linux"
    run multiclamscan -d "$SCAN_DIR"
    assert_failure
    assert_output --partial 'clamscan not found'
}

# ---------------------------------------------------------------------------
# happy path
# ---------------------------------------------------------------------------

@test "clean directory succeeds, writes log, reports no infection" {
    printf 'hello\n' > "$SCAN_DIR/a.txt"
    printf 'world\n' > "$SCAN_DIR/b.txt"

    run multiclamscan -d "$SCAN_DIR"
    assert_success
    assert_output --partial 'Scan complete. Log saved to'
    assert_output --partial 'no infected files found'

    # ログファイルが 1 つ生成されている
    run bash -c "ls '$MULTICLAMSCAN_LOG_DIR'/multiclamscan_*.log"
    assert_success
}

@test "empty directory succeeds (xargs -r skips clamscan)" {
    run multiclamscan -d "$SCAN_DIR"
    assert_success
    assert_output --partial 'no infected files found'
}

# ---------------------------------------------------------------------------
# infected path: clamscan exits 1 but script still completes and reports it
# ---------------------------------------------------------------------------

@test "infected file: reports detection and exits 1 without aborting early" {
    _use_infected_stub
    printf 'x5o!\n' > "$SCAN_DIR/eicar.txt"

    run multiclamscan -d "$SCAN_DIR"
    assert_failure 1
    # 'set -e' に殺されず最後まで到達している証拠
    assert_output --partial 'Scan complete. Log saved to'
    assert_output --partial 'INFECTED files detected'

    # ログに FOUND 行が記録されている
    run bash -c "grep -q 'FOUND' '$MULTICLAMSCAN_LOG_DIR'/multiclamscan_*.log"
    assert_success
}
