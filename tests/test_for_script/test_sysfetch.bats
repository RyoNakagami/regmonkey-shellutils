#!/usr/bin/env bats

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"
    SCRIPT="$DIR/../../bin/linux/sysfetch"

    OLD_PATH=$PATH
    TMPDIR_TEST="$(mktemp -d)"

    # stub directory placed first in PATH so backend commands are intercepted.
    # /usr/bin & /bin stay on PATH so awk/sed/printf/jq/mktemp still resolve.
    STUB_DIR="$TMPDIR_TEST/stub"
    mkdir -p "$STUB_DIR"
    PATH="$STUB_DIR:$DIR/../../bin/linux:/usr/bin:/bin"
}

teardown() {
    PATH=$OLD_PATH
    rm -rf "$TMPDIR_TEST"
}

# ---------------------------------------------------------------------------
# Helper: install fake backend commands with deterministic output.
#   $1 (optional) = nvidia-smi CSV line; empty/omitted simulates "no GPU".
# ---------------------------------------------------------------------------
_install_stubs() {
    local gpu_csv="${1-}"

    cat > "$STUB_DIR/hostnamectl" <<'EOF'
#!/bin/bash
cat <<'OUT'
 Static hostname: testhost
 Operating System: TestOS 1.0
    Architecture: x86-64
OUT
EOF

    cat > "$STUB_DIR/uname" <<'EOF'
#!/bin/bash
case "$1" in
    -r) echo "6.14.0-test" ;;
    -v) echo "#1 SMP PREEMPT_DYNAMIC Mon Jun 2 10:00:00 UTC 2026" ;;
    *)  echo "uname-stub" ;;
esac
EOF

    cat > "$STUB_DIR/uptime" <<'EOF'
#!/bin/bash
echo "up 1 hour, 2 minutes"
EOF

    cat > "$STUB_DIR/top" <<'EOF'
#!/bin/bash
echo "%Cpu(s):  5.5 us,  1.5 sy,  0.0 ni, 93.0 id"
EOF

    cat > "$STUB_DIR/free" <<'EOF'
#!/bin/bash
if [[ "$1" == "-b" ]]; then
    cat <<'OUT'
               total        used        free
Mem:     16000000000  4000000000  12000000000
Swap:             0           0           0
OUT
else
    cat <<'OUT'
               total        used        free
Mem:            60Gi        16Gi        44Gi
Swap:            0B          0B          0B
OUT
fi
EOF

    cat > "$STUB_DIR/df" <<'EOF'
#!/bin/bash
cat <<'OUT'
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda1       916G  403G  467G  47% /
/dev/sda2       511M  6.2M  505M   2% /boot/efi
OUT
EOF

    cat > "$STUB_DIR/nvidia-smi" <<EOF
#!/bin/bash
printf '%s' "${gpu_csv}"
[[ -n "${gpu_csv}" ]] && echo
exit 0
EOF

    chmod +x "$STUB_DIR"/*
}

# ---------------------------------------------------------------------------
# help / option parsing
# ---------------------------------------------------------------------------

@test "help option -h prints docstring and exits 0" {
    run sysfetch -h
    assert_success
    assert_output --partial 'Script: sysfetch'
    assert_output --partial 'Usage:'
}

@test "help option --help prints docstring and exits 0" {
    run sysfetch --help
    assert_success
    assert_output --partial 'Script: sysfetch'
}

@test "unknown option fails with error message" {
    run sysfetch --no-such-flag
    assert_failure
    assert_output --partial 'Error: unknown option: --no-such-flag'
    assert_output --partial 'Use --help'
}

# ---------------------------------------------------------------------------
# pure helpers (sourced directly; source-guard prevents main from running)
# ---------------------------------------------------------------------------

@test "_calc_percent computes percentage with one decimal" {
    run bash -c 'source "'"$SCRIPT"'"; _calc_percent 512 1024'
    assert_success
    assert_output "50.0"
}

@test "_calc_percent returns 0.0 when total is zero" {
    run bash -c 'source "'"$SCRIPT"'"; _calc_percent 100 0'
    assert_success
    assert_output "0.0"
}

@test "_extract_build_date extracts UTC date from uname -v string" {
    run bash -c 'source "'"$SCRIPT"'"; _extract_build_date "#1 SMP PREEMPT_DYNAMIC Mon Jun 2 10:00:00 UTC 2026"'
    assert_success
    assert_output "Mon Jun 2 10:00:00 UTC"
}

@test "_extract_build_date returns dash when no date present" {
    run bash -c 'source "'"$SCRIPT"'"; _extract_build_date "no date here"'
    assert_success
    assert_output --regexp '^-$'
}

@test "_gpu_display formats name and usage when GPU present" {
    run bash -c 'source "'"$SCRIPT"'"; _gpu_display "NVIDIA RTX" "42"'
    assert_success
    assert_output "NVIDIA RTX (42%)"
}

@test "_gpu_display shows Not available when name is empty" {
    run bash -c 'source "'"$SCRIPT"'"; _gpu_display "" ""'
    assert_success
    assert_output "Not available"
}

# ---------------------------------------------------------------------------
# table output with stubbed backends
# ---------------------------------------------------------------------------

@test "table output shows expected labels and stubbed values" {
    _install_stubs "NVIDIA Test GPU, 33"
    run sysfetch
    assert_success
    assert_output --partial "Static hostname: testhost"
    assert_output --partial "OS: TestOS 1.0"
    assert_output --partial "Architecture: x86-64"
    assert_output --partial "Kernel: 6.14.0-test"
    assert_output --partial "Build Date: Mon Jun 2 10:00:00 UTC"
    assert_output --partial "Uptime: 1 hour, 2 minutes"
    assert_output --partial "CPU Usage: 7%"
    assert_output --partial "GPU: NVIDIA Test GPU (33%)"
    assert_output --partial "Memory Usage: 16Gi/60Gi (25.0%)"
    assert_output --partial "Disk Usage: 403G/916G (47% used) [/]"
    assert_output --partial "6.2M/511M (2% used) [/boot/efi]"
}

@test "table output shows GPU Not available when nvidia-smi returns nothing" {
    _install_stubs ""
    run sysfetch
    assert_success
    assert_output --partial "GPU: Not available"
}

# ---------------------------------------------------------------------------
# JSON output with stubbed backends (validated with jq)
# ---------------------------------------------------------------------------

@test "json output is valid JSON" {
    _install_stubs "NVIDIA Test GPU, 33"
    run bash -c 'sysfetch --json | jq -e . >/dev/null'
    assert_success
}

@test "json output carries expected scalar fields" {
    _install_stubs "NVIDIA Test GPU, 33"

    run bash -c 'sysfetch --json | jq -r .hostname'
    assert_output "testhost"

    run bash -c 'sysfetch --json | jq -r .os'
    assert_output "TestOS 1.0"

    run bash -c 'sysfetch --json | jq -r .memory.usage_percent'
    assert_output "25.0"

    run bash -c 'sysfetch --json | jq -r .gpu.name'
    assert_output "NVIDIA Test GPU"

    run bash -c 'sysfetch --json | jq -r ".disks | length"'
    assert_output "2"
}

@test "json output uses null gpu when nvidia-smi returns nothing" {
    _install_stubs ""
    run bash -c 'sysfetch --json | jq -r ".gpu.name"'
    assert_success
    assert_output "null"
}

@test "json output -j flag works same as --json" {
    _install_stubs "NVIDIA Test GPU, 33"
    run bash -c 'sysfetch -j | jq -e . >/dev/null'
    assert_success
}
