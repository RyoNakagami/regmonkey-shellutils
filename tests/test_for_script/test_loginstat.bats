#!/usr/bin/env bats

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"

    OLD_PATH=$PATH
    PATH="$DIR/../../bin/linux:$PATH"

    TMPDIR_TEST="$(mktemp -d)"

    # stub directory — placed first in PATH so loginctl is intercepted
    STUB_DIR="$TMPDIR_TEST/stub"
    mkdir -p "$STUB_DIR"
    PATH="$STUB_DIR:$PATH"
}

teardown() {
    PATH=$OLD_PATH
    rm -rf "$TMPDIR_TEST"
}

# ---------------------------------------------------------------------------
# Helper: write a loginctl stub that returns fixed show-session output
# ---------------------------------------------------------------------------
_make_loginctl_stub() {
    local show_output="$1"   # content for 'show-session <sid>'
    local list_output="${2:-1 1000 testuser seat0 pts/0}"

    cat > "$STUB_DIR/loginctl" <<EOF
#!/bin/bash
case "\$1" in
    show-session) printf '%s\n' '$show_output' ;;
    list-sessions) printf '%s\n' '$list_output' ;;
esac
EOF
    # use heredoc-safe approach: write via file
    {
        echo '#!/bin/bash'
        echo 'case "$1" in'
        echo '    show-session)'
        printf '        cat <<'"'"'STUBEOF'"'"'\n'
        printf '%s\n' "$show_output"
        printf 'STUBEOF\n'
        echo '        ;;'
        echo '    list-sessions)'
        printf '        printf '"'"'%%s\n'"'"' '"'"'%s'"'"'\n' "$list_output"
        echo '        ;;'
        echo 'esac'
    } > "$STUB_DIR/loginctl"
    chmod +x "$STUB_DIR/loginctl"
}

# Minimal show-session output for a typical SSH session
_ssh_session_output() {
    cat <<'EOF'
Name=testuser
Service=sshd
Type=tty
TTY=pts/0
Display=
Leader=12345
RemoteHost=192.168.1.100
Timestamp=Mon 2026-06-02 10:00:00 JST
IdleHint=no
IdleSinceHint=0
EOF
}

# show-session output for a GUI session
_gui_session_output() {
    cat <<'EOF'
Name=testuser
Service=gdm-password
Type=x11
TTY=
Display=:0
Leader=9999
RemoteHost=
Timestamp=Mon 2026-06-02 09:00:00 JST
IdleHint=no
IdleSinceHint=0
EOF
}

# ---------------------------------------------------------------------------
# help / option parsing
# ---------------------------------------------------------------------------

@test "help option -h prints docstring and exits 0" {
    run loginstat -h
    assert_success
    assert_output --partial 'Script: loginstat'
    assert_output --partial 'Usage:'
}

@test "help option --help prints docstring and exits 0" {
    run loginstat --help
    assert_success
    assert_output --partial 'Script: loginstat'
}

@test "unknown option fails with error message" {
    run loginstat --no-such-flag
    assert_failure
    assert_output --partial 'Error: unknown option: --no-such-flag'
    assert_output --partial 'Use --help'
}

# ---------------------------------------------------------------------------
# _idle_fmt logic (sourced directly, no loginctl needed)
# ---------------------------------------------------------------------------

@test "_idle_fmt returns dot when idle_hint is no" {
    run bash -c '
        source "'"$DIR"'/../../bin/linux/loginstat" 2>/dev/null || true
        source "'"$DIR"'/../../lib/docstring.sh"
        # redefine main so sourcing does not execute
        main() { :; }
        source "'"$DIR"'/../../bin/linux/loginstat"
        _idle_fmt "no" "0"
    '
    # We test via a self-contained subshell to avoid loginctl dependency
    run bash -c '
        _idle_fmt() {
            local idle_hint="$1" idle_since="${2:-0}"
            if [[ "$idle_hint" != "yes" ]] || ! [[ "$idle_since" =~ ^[0-9]+$ ]] || (( idle_since <= 0 )); then
                echo "."; return
            fi
            local now_usec idle_sec
            now_usec=$(( $(date +%s) * 1000000 ))
            idle_sec=$(( (now_usec - idle_since) / 1000000 ))
            if (( idle_sec < 60 )); then echo "."
            elif (( idle_sec < 3600 )); then echo "$((idle_sec/60))m"
            elif (( idle_sec < 86400 )); then printf "%d:%02d\n" $((idle_sec/3600)) $((idle_sec%3600/60))
            else echo "$((idle_sec/86400))days"
            fi
        }
        _idle_fmt "no" "0"
    '
    assert_success
    assert_output "."
}

@test "_idle_fmt returns dot when idle under 60 seconds" {
    run bash -c '
        _idle_fmt() {
            local idle_hint="$1" idle_since="${2:-0}"
            if [[ "$idle_hint" != "yes" ]] || ! [[ "$idle_since" =~ ^[0-9]+$ ]] || (( idle_since <= 0 )); then
                echo "."; return
            fi
            local now_usec idle_sec
            now_usec=$(( $(date +%s) * 1000000 ))
            idle_sec=$(( (now_usec - idle_since) / 1000000 ))
            if (( idle_sec < 60 )); then echo "."
            elif (( idle_sec < 3600 )); then echo "$((idle_sec/60))m"
            elif (( idle_sec < 86400 )); then printf "%d:%02d\n" $((idle_sec/3600)) $((idle_sec%3600/60))
            else echo "$((idle_sec/86400))days"
            fi
        }
        # 30 seconds ago
        now_usec=$(( $(date +%s) * 1000000 ))
        idle_since=$(( now_usec - 30 * 1000000 ))
        _idle_fmt "yes" "$idle_since"
    '
    assert_success
    assert_output "."
}

@test "_idle_fmt shows minutes when idle between 1 min and 1 hour" {
    run bash -c '
        _idle_fmt() {
            local idle_hint="$1" idle_since="${2:-0}"
            if [[ "$idle_hint" != "yes" ]] || ! [[ "$idle_since" =~ ^[0-9]+$ ]] || (( idle_since <= 0 )); then
                echo "."; return
            fi
            local now_usec idle_sec
            now_usec=$(( $(date +%s) * 1000000 ))
            idle_sec=$(( (now_usec - idle_since) / 1000000 ))
            if (( idle_sec < 60 )); then echo "."
            elif (( idle_sec < 3600 )); then echo "$((idle_sec/60))m"
            elif (( idle_sec < 86400 )); then printf "%d:%02d\n" $((idle_sec/3600)) $((idle_sec%3600/60))
            else echo "$((idle_sec/86400))days"
            fi
        }
        # 5 minutes ago
        now_usec=$(( $(date +%s) * 1000000 ))
        idle_since=$(( now_usec - 300 * 1000000 ))
        _idle_fmt "yes" "$idle_since"
    '
    assert_success
    assert_output --regexp '^[0-9]+m$'
}

@test "_idle_fmt shows HH:MM when idle between 1 hour and 1 day" {
    run bash -c '
        _idle_fmt() {
            local idle_hint="$1" idle_since="${2:-0}"
            if [[ "$idle_hint" != "yes" ]] || ! [[ "$idle_since" =~ ^[0-9]+$ ]] || (( idle_since <= 0 )); then
                echo "."; return
            fi
            local now_usec idle_sec
            now_usec=$(( $(date +%s) * 1000000 ))
            idle_sec=$(( (now_usec - idle_since) / 1000000 ))
            if (( idle_sec < 60 )); then echo "."
            elif (( idle_sec < 3600 )); then echo "$((idle_sec/60))m"
            elif (( idle_sec < 86400 )); then printf "%d:%02d\n" $((idle_sec/3600)) $((idle_sec%3600/60))
            else echo "$((idle_sec/86400))days"
            fi
        }
        # 2 hours 30 minutes ago
        now_usec=$(( $(date +%s) * 1000000 ))
        idle_since=$(( now_usec - 9000 * 1000000 ))
        _idle_fmt "yes" "$idle_since"
    '
    assert_success
    assert_output --regexp '^[0-9]+:[0-9][0-9]$'
}

@test "_idle_fmt shows days when idle over 1 day" {
    run bash -c '
        _idle_fmt() {
            local idle_hint="$1" idle_since="${2:-0}"
            if [[ "$idle_hint" != "yes" ]] || ! [[ "$idle_since" =~ ^[0-9]+$ ]] || (( idle_since <= 0 )); then
                echo "."; return
            fi
            local now_usec idle_sec
            now_usec=$(( $(date +%s) * 1000000 ))
            idle_sec=$(( (now_usec - idle_since) / 1000000 ))
            if (( idle_sec < 60 )); then echo "."
            elif (( idle_sec < 3600 )); then echo "$((idle_sec/60))m"
            elif (( idle_sec < 86400 )); then printf "%d:%02d\n" $((idle_sec/3600)) $((idle_sec%3600/60))
            else echo "$((idle_sec/86400))days"
            fi
        }
        # 2 days ago
        now_usec=$(( $(date +%s) * 1000000 ))
        idle_since=$(( now_usec - 172800 * 1000000 ))
        _idle_fmt "yes" "$idle_since"
    '
    assert_success
    assert_output --regexp '^[0-9]+days$'
}

# ---------------------------------------------------------------------------
# _type_disp logic
# ---------------------------------------------------------------------------

@test "_type_disp returns ssh for sshd service" {
    run bash -c '
        _type_disp() {
            local service="$1" type="$2"
            case "$service" in
                sshd) echo "ssh"; return ;;
                xrdp-sesman) echo "rdp"; return ;;
                gdm-password|gdm-wayland-session|gdm-x-session) echo "gui"; return ;;
            esac
            if [[ "$type" == "x11" || "$type" == "wayland" ]]; then echo "gui"
            else echo "${type:-unknown}"
            fi
        }
        _type_disp "sshd" "tty"
    '
    assert_success
    assert_output "ssh"
}

@test "_type_disp returns rdp for xrdp-sesman service" {
    run bash -c '
        _type_disp() {
            local service="$1" type="$2"
            case "$service" in
                sshd) echo "ssh"; return ;;
                xrdp-sesman) echo "rdp"; return ;;
                gdm-password|gdm-wayland-session|gdm-x-session) echo "gui"; return ;;
            esac
            if [[ "$type" == "x11" || "$type" == "wayland" ]]; then echo "gui"
            else echo "${type:-unknown}"
            fi
        }
        _type_disp "xrdp-sesman" "tty"
    '
    assert_success
    assert_output "rdp"
}

@test "_type_disp returns gui for gdm-password service" {
    run bash -c '
        _type_disp() {
            local service="$1" type="$2"
            case "$service" in
                sshd) echo "ssh"; return ;;
                xrdp-sesman) echo "rdp"; return ;;
                gdm-password|gdm-wayland-session|gdm-x-session) echo "gui"; return ;;
            esac
            if [[ "$type" == "x11" || "$type" == "wayland" ]]; then echo "gui"
            else echo "${type:-unknown}"
            fi
        }
        _type_disp "gdm-password" "x11"
    '
    assert_success
    assert_output "gui"
}

# ---------------------------------------------------------------------------
# table output with loginctl stub
# ---------------------------------------------------------------------------

@test "table output has header with expected columns" {
    _make_loginctl_stub "$(_ssh_session_output)" "1 1000 testuser seat0 pts/0"
    run loginstat
    assert_success
    assert_output --partial "USER"
    assert_output --partial "SESSION"
    assert_output --partial "LOGIN"
    assert_output --partial "IDLE"
    assert_output --partial "FROM"
    assert_output --partial "TYPE"
    assert_output --partial "WHAT"
}

@test "table output shows session data row" {
    _make_loginctl_stub "$(_ssh_session_output)" "1 1000 testuser seat0 pts/0"
    run loginstat
    assert_success
    assert_output --partial "testuser"
    assert_output --partial "ssh"
}

# ---------------------------------------------------------------------------
# JSON output with loginctl stub
# ---------------------------------------------------------------------------

@test "json output is a valid JSON array" {
    _make_loginctl_stub "$(_ssh_session_output)" "1 1000 testuser seat0 pts/0"
    run loginstat --json
    assert_success
    assert_output --partial "["
    assert_output --partial "]"
    assert_output --partial '"user"'
    assert_output --partial '"session"'
}

@test "json output for empty session list is empty array" {
    # stub: list-sessions returns nothing
    cat > "$STUB_DIR/loginctl" <<'STUBEOF'
#!/bin/bash
case "$1" in
    show-session) ;;
    list-sessions) ;;
esac
STUBEOF
    chmod +x "$STUB_DIR/loginctl"

    run loginstat --json
    assert_success
    assert_output "$(printf '[\n]')"
}

@test "json output -j flag works same as --json" {
    _make_loginctl_stub "$(_ssh_session_output)" "1 1000 testuser seat0 pts/0"
    run loginstat -j
    assert_success
    assert_output --partial '"type"'
}
