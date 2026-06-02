#!/usr/bin/env bats

# Note: these tests do NOT require ffmpeg. A fake 'ffmpeg' is stubbed in a
# sandbox bin/ directory placed ahead of the script dir on PATH, so the
# script's behavior is verified deterministically and without transcoding.
# The default ffmpeg stub echoes the arguments it received (so assertions can
# inspect the encoding flags the script chose) and creates the output file
# (the last argument) so the "Wrote: ..." path can be exercised.

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"
    SCRIPT_DIR="$DIR/../../bin/utils"

    OLD_PATH=$PATH
    TMPDIR_TEST="$(mktemp -d)"

    # Sandbox bin for command stubs; placed before the real script dir so the
    # fake ffmpeg shadows any real ffmpeg on the system.
    STUB_BIN="$TMPDIR_TEST/bin"
    mkdir -p "$STUB_BIN"
    PATH="$STUB_BIN:$SCRIPT_DIR:$PATH"

    # A scratch dir for input/output files so the cwd stays clean.
    WORK="$TMPDIR_TEST/work"
    mkdir -p "$WORK"
    INPUT="$WORK/input.mov"
    : > "$INPUT"

    # Default ffmpeg stub: echo the arguments and create the output file
    # (the final argument) so the script reaches its success message.
    _stub ffmpeg <<'EOF'
#!/bin/bash
echo "ffmpeg-args: $*"
# The last positional argument is the output path; create it.
for last; do :; done
: > "$last"
EOF
}

teardown() {
    PATH=$OLD_PATH
    rm -rf "$TMPDIR_TEST"
}

# Write an executable stub onto the sandbox PATH.
_stub() {
    local name="$1"
    cat >"$STUB_BIN/$name"
    chmod +x "$STUB_BIN/$name"
}

# Build a minimal PATH that contains the coreutils the script needs but NOT
# ffmpeg, so the "ffmpeg missing" branch can be exercised even when a real
# ffmpeg is installed in /usr/bin.
_path_without_ffmpeg() {
    local tools="$TMPDIR_TEST/tools"
    mkdir -p "$tools"
    local t
    for t in bash dirname basename awk sed cat env mktemp rm chmod mkdir; do
        local p
        p="$(command -v "$t" 2>/dev/null)" || continue
        ln -sf "$p" "$tools/$t"
    done
    PATH="$tools:$SCRIPT_DIR"
}

# --- help / argument parsing ----------------------------------------------

@test "help option prints docstring and exits 0" {
    run convert_to_uploadable_mp4 -h
    assert_success
    assert_output --partial 'Script: convert_to_uploadable_mp4'
    assert_output --partial 'Usage:'
}

@test "unknown option fails with error" {
    run convert_to_uploadable_mp4 --no-such-flag
    assert_failure
    assert_output --partial 'Error: unknown option: --no-such-flag'
}

@test "more than one input file fails" {
    run convert_to_uploadable_mp4 "$INPUT" "$WORK/extra.mov"
    assert_failure
    assert_output --partial 'only one input file is accepted'
}

# --- dependency / input validation ----------------------------------------

@test "ffmpeg missing on PATH fails" {
    _path_without_ffmpeg
    # Sanity: ffmpeg must not be reachable from this PATH.
    ! command -v ffmpeg >/dev/null 2>&1
    run convert_to_uploadable_mp4 "$INPUT"
    assert_failure
    assert_output --partial "'ffmpeg' is not installed or not on PATH."
}

@test "missing input path is required" {
    run convert_to_uploadable_mp4
    assert_failure
    assert_output --partial 'input video path is required.'
}

@test "nonexistent input file fails" {
    run convert_to_uploadable_mp4 "$WORK/does_not_exist.mov"
    assert_failure
    assert_output --partial 'input file does not exist:'
}

# --- CRF validation --------------------------------------------------------

@test "non-numeric CRF is rejected" {
    run convert_to_uploadable_mp4 -c abc "$INPUT"
    assert_failure
    assert_output --partial '-c (CRF) must be an integer in 0-51'
}

@test "CRF above 51 is rejected" {
    run convert_to_uploadable_mp4 -c 52 "$INPUT"
    assert_failure
    assert_output --partial '-c (CRF) must be an integer in 0-51'
}

# --- scale validation ------------------------------------------------------

@test "non-positive scale is rejected" {
    run convert_to_uploadable_mp4 -s 0 "$INPUT"
    assert_failure
    assert_output --partial '-s (max long side) must be a positive integer'
}

@test "non-numeric scale is rejected" {
    run convert_to_uploadable_mp4 -s abc "$INPUT"
    assert_failure
    assert_output --partial '-s (max long side) must be a positive integer'
}

# --- output collision ------------------------------------------------------

@test "existing output without -y fails" {
    local out="$WORK/out.mp4"
    : > "$out"
    run convert_to_uploadable_mp4 -o "$out" "$INPUT"
    assert_failure
    assert_output --partial 'output file already exists:'
    assert_output --partial '(use -y to overwrite)'
}

@test "existing output with -y overwrites" {
    local out="$WORK/out.mp4"
    : > "$out"
    run convert_to_uploadable_mp4 -y -o "$out" "$INPUT"
    assert_success
    assert_output --partial 'ffmpeg-args:'
    assert_output --partial "Wrote: $out"
}

# --- happy paths -----------------------------------------------------------

@test "default output name is derived from input stem" {
    cd "$WORK"
    run convert_to_uploadable_mp4 input.mov
    assert_success
    assert_output --partial 'Wrote: input_uploadable.mp4'
}

@test "default encoding flags are compatibility-first" {
    run convert_to_uploadable_mp4 -o "$WORK/out.mp4" "$INPUT"
    assert_success
    assert_output --partial '-c:v libx264'
    assert_output --partial '-pix_fmt yuv420p'
    assert_output --partial '-c:a aac'
    assert_output --partial '-movflags +faststart'
    # No -s, so even-dimension guard filter is used and -y is NOT forced.
    assert_output --partial 'scale=trunc(iw/2)*2:trunc(ih/2)*2'
    assert_output --partial 'ffmpeg-args: -n '
}

@test "custom CRF is passed to ffmpeg" {
    run convert_to_uploadable_mp4 -c 20 -o "$WORK/out.mp4" "$INPUT"
    assert_success
    assert_output --partial '-crf 20'
}

@test "scale option builds a downscale filter and reports max side" {
    run convert_to_uploadable_mp4 -s 1080 -o "$WORK/out.mp4" "$INPUT"
    assert_success
    assert_output --partial 'min(iw,1080)'
    assert_output --partial 'max side 1080px'
}

@test "force flag passes -y to ffmpeg" {
    run convert_to_uploadable_mp4 -y -o "$WORK/out.mp4" "$INPUT"
    assert_success
    assert_output --partial 'ffmpeg-args: -y '
}

@test "exit code propagates from ffmpeg failure" {
    _stub ffmpeg <<'EOF'
#!/bin/bash
echo "ffmpeg failed" >&2
exit 1
EOF
    run convert_to_uploadable_mp4 -o "$WORK/out.mp4" "$INPUT"
    assert_failure
}