#!/usr/bin/env bats

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"

    OLD_PATH=$PATH
    PATH="$DIR/../../bin/measurement:$PATH"

    TMPDIR_TEST="$(mktemp -d)"

    # Stub 'sensors' with realistic output
    STUB_BIN="$TMPDIR_TEST/bin"
    mkdir -p "$STUB_BIN"
    cat > "$STUB_BIN/sensors" <<'EOF'
#!/bin/bash
cat <<'SENSORS_OUT'
amdgpu-pci-1800
Adapter: PCI adapter
edge:         +38.0°C

k10temp-pci-00c3
Adapter: PCI adapter
Tctl:         +46.4°C
Tccd1:        +43.4°C
Tccd2:        +38.5°C

nvme-pci-0500
Adapter: PCI adapter
Composite:    +29.9°C  (low  =  -0.1°C, high = +79.8°C)

nvme-pci-0200
Adapter: PCI adapter
Composite:    +40.9°C  (low  =  -0.1°C, high = +86.8°C)
SENSORS_OUT
EOF
    chmod +x "$STUB_BIN/sensors"
    PATH="$STUB_BIN:$PATH"
}

teardown() {
    PATH=$OLD_PATH
    rm -rf "$TMPDIR_TEST"
}

# ---------------------------------------------------------------------------
# Option parsing
# ---------------------------------------------------------------------------

@test "help option prints docstring and exits 0" {
    run sensor-logger -h
    assert_success
    assert_output --partial 'Script: sensor-logger'
    assert_output --partial 'Usage:'
}

@test "unknown option fails with error message" {
    run sensor-logger -x
    assert_failure
    assert_output --partial 'unknown option'
}

@test "unexpected positional argument fails" {
    run sensor-logger something
    assert_failure
    assert_output --partial 'unexpected argument'
}

@test "-i without value fails" {
    run sensor-logger -i
    assert_failure
    assert_output --partial '-i requires a value'
}

@test "-d without value fails" {
    run sensor-logger -d
    assert_failure
    assert_output --partial '-d requires a value'
}

@test "-i zero fails" {
    run sensor-logger -i 0 -d "$TMPDIR_TEST/logs"
    assert_failure
    assert_output --partial '-i must be a positive integer'
}

@test "-i non-integer fails" {
    run sensor-logger -i 1.5 -d "$TMPDIR_TEST/logs"
    assert_failure
    assert_output --partial '-i must be a positive integer'
}

@test "-i negative fails" {
    run sensor-logger -i -1 -d "$TMPDIR_TEST/logs"
    assert_failure
    assert_output --partial '-i must be a positive integer'
}

# ---------------------------------------------------------------------------
# Logging behaviour
# ---------------------------------------------------------------------------

@test "log directory is created when it does not exist" {
    local logdir="$TMPDIR_TEST/new/nested/dir"
    sensor-logger -d "$logdir" &
    local pid=$!
    sleep 1.5
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
    [[ -d "$logdir" ]]
}

@test "JSONL log file is created under the log directory" {
    local logdir="$TMPDIR_TEST/logs"
    sensor-logger -d "$logdir" &
    local pid=$!
    sleep 1.5
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
    local count
    count=$(find "$logdir" -name 'sensor-temperature_*.jsonl' -o \
                           -name 'sensor-temperature_*.jsonl.gz' | wc -l)
    [[ "$count" -ge 1 ]]
}

@test "each log line is valid JSON with expected keys" {
    local logdir="$TMPDIR_TEST/logs"
    sensor-logger -d "$logdir" &
    local pid=$!
    sleep 2.5
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true

    # Collect lines from either plain or compressed log
    local lines
    local jsonl
    jsonl=$(find "$logdir" -name 'sensor-temperature_*.jsonl' | head -1)
    local gz
    gz=$(find "$logdir" -name 'sensor-temperature_*.jsonl.gz' | head -1)

    if [[ -n "$jsonl" ]]; then
        lines=$(cat "$jsonl")
    elif [[ -n "$gz" ]]; then
        lines=$(gzip -dc "$gz")
    else
        fail "No log file found"
    fi

    # Every line must contain the required top-level keys
    while IFS= read -r line; do
        [[ "$line" == *'"datetime"'* ]]
        [[ "$line" == *'"cpu"'* ]]
        [[ "$line" == *'"gpu"'* ]]
        [[ "$line" == *'"nvme"'* ]]
    done <<< "$lines"
}

@test "sensor values are parsed correctly from stub output" {
    local logdir="$TMPDIR_TEST/logs"
    sensor-logger -d "$logdir" &
    local pid=$!
    sleep 1.5
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true

    local jsonl
    jsonl=$(find "$logdir" -name 'sensor-temperature_*.jsonl' | head -1)
    gz=$(find "$logdir" -name 'sensor-temperature_*.jsonl.gz' | head -1)
    local line
    if [[ -n "$jsonl" ]]; then
        line=$(head -1 "$jsonl")
    else
        line=$(gzip -dc "$gz" | head -1)
    fi

    [[ "$line" == *'"tctl":+46.4'* ]]
    [[ "$line" == *'"tccd1":+43.4'* ]]
    [[ "$line" == *'"tccd2":+38.5'* ]]
    [[ "$line" == *'"edge":+38.0'* ]]
    [[ "$line" == *'"nvme0":+29.9'* ]]
    [[ "$line" == *'"nvme1":+40.9'* ]]
}

@test "missing sensor field is recorded as null" {
    # Stub with no GPU edge line
    cat > "$STUB_BIN/sensors" <<'EOF'
#!/bin/bash
cat <<'SENSORS_OUT'
k10temp-pci-00c3
Adapter: PCI adapter
Tctl:         +46.4°C
Tccd1:        +43.4°C
Tccd2:        +38.5°C
SENSORS_OUT
EOF
    chmod +x "$STUB_BIN/sensors"

    local logdir="$TMPDIR_TEST/logs"
    sensor-logger -d "$logdir" &
    local pid=$!
    sleep 1.5
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true

    local jsonl gz line
    jsonl=$(find "$logdir" -name 'sensor-temperature_*.jsonl' | head -1)
    gz=$(find "$logdir" -name 'sensor-temperature_*.jsonl.gz' | head -1)
    if [[ -n "$jsonl" ]]; then
        line=$(head -1 "$jsonl")
    else
        line=$(gzip -dc "$gz" | head -1)
    fi

    [[ "$line" == *'"edge":null'* ]]
    [[ "$line" == *'"nvme0":null'* ]]
    [[ "$line" == *'"nvme1":null'* ]]
}

@test "on SIGTERM log file is compressed" {
    local logdir="$TMPDIR_TEST/logs"
    sensor-logger -d "$logdir" &
    local pid=$!
    sleep 1.5
    kill -TERM "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
    local gz_count
    gz_count=$(find "$logdir" -name 'sensor-temperature_*.jsonl.gz' | wc -l)
    [[ "$gz_count" -ge 1 ]]
}

@test "existing old jsonl files are compressed on startup" {
    local logdir="$TMPDIR_TEST/logs"
    mkdir -p "$logdir"
    # Plant a fake old log file
    printf '{"datetime":"2026-01-01T00:00:00","cpu":{},"gpu":{},"nvme":{}}\n' \
        > "$logdir/sensor-temperature_20260101_000000.jsonl"

    sensor-logger -d "$logdir" &
    local pid=$!
    sleep 1.5
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true

    # The old file must now be gzip-compressed
    [[ -f "$logdir/sensor-temperature_20260101_000000.jsonl.gz" ]]
    [[ ! -f "$logdir/sensor-temperature_20260101_000000.jsonl" ]]
}

@test "custom interval -i 2 produces fewer lines than interval 1 in same wall time" {
    local logdir1="$TMPDIR_TEST/logs1"
    local logdir2="$TMPDIR_TEST/logs2"

    sensor-logger -i 1 -d "$logdir1" &
    local pid1=$!
    sensor-logger -i 2 -d "$logdir2" &
    local pid2=$!

    sleep 3.5
    kill "$pid1" "$pid2" 2>/dev/null
    wait "$pid1" "$pid2" 2>/dev/null || true

    local count1 count2 jsonl gz
    jsonl=$(find "$logdir1" -name 'sensor-temperature_*.jsonl' | head -1)
    gz=$(find "$logdir1" -name 'sensor-temperature_*.jsonl.gz' | head -1)
    if [[ -n "$jsonl" ]]; then count1=$(wc -l < "$jsonl")
    else count1=$(gzip -dc "$gz" | wc -l); fi

    jsonl=$(find "$logdir2" -name 'sensor-temperature_*.jsonl' | head -1)
    gz=$(find "$logdir2" -name 'sensor-temperature_*.jsonl.gz' | head -1)
    if [[ -n "$jsonl" ]]; then count2=$(wc -l < "$jsonl")
    else count2=$(gzip -dc "$gz" | wc -l); fi

    [[ "$count1" -gt "$count2" ]]
}
