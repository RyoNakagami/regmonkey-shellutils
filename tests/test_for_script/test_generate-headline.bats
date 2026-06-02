#!/usr/bin/env bats

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"
    REPO="$DIR/../.."

    OLD_PATH=$PATH
    TMPDIR_TEST="$(mktemp -d)"

    # generate-headline resolves sibling agents via $(dirname "${BASH_SOURCE[0]}"),
    # so stubs must live in the same directory as the script.  We build a sandbox:
    #   $TMPDIR_TEST/bin/agent/generate-headline   (real script, symlinked)
    #   $TMPDIR_TEST/bin/agent/claude-stdin-prompt  (stub)
    #   $TMPDIR_TEST/bin/agent/codex-stdin-prompt   (stub)
    #   $TMPDIR_TEST/lib/docstring.sh               (real lib, symlinked)
    mkdir -p "$TMPDIR_TEST/bin/agent" "$TMPDIR_TEST/lib"
    ln -s "$REPO/bin/agent/generate-headline" "$TMPDIR_TEST/bin/agent/generate-headline"
    ln -s "$REPO/lib/docstring.sh"            "$TMPDIR_TEST/lib/docstring.sh"

    CLAUDE_ARGV_FILE="$TMPDIR_TEST/claude-stdin-prompt.argv"
    CODEX_ARGV_FILE="$TMPDIR_TEST/codex-stdin-prompt.argv"
    export CLAUDE_ARGV_FILE CODEX_ARGV_FILE

    cat > "$TMPDIR_TEST/bin/agent/claude-stdin-prompt" <<'STUB'
#!/bin/bash
: > "${CLAUDE_ARGV_FILE}"
for a in "$@"; do
    printf '%s\n' "$a" >> "${CLAUDE_ARGV_FILE}"
done
cat
printf 'CLAUDE_STUB_OK\n'
STUB
    chmod +x "$TMPDIR_TEST/bin/agent/claude-stdin-prompt"

    cat > "$TMPDIR_TEST/bin/agent/codex-stdin-prompt" <<'STUB'
#!/bin/bash
: > "${CODEX_ARGV_FILE}"
for a in "$@"; do
    printf '%s\n' "$a" >> "${CODEX_ARGV_FILE}"
done
cat
printf 'CODEX_STUB_OK\n'
STUB
    chmod +x "$TMPDIR_TEST/bin/agent/codex-stdin-prompt"

    # Add sandbox bin/agent to PATH so `generate-headline` is invocable by name.
    PATH="$TMPDIR_TEST/bin/agent:$PATH"
}

teardown() {
    PATH=$OLD_PATH
    rm -rf "$TMPDIR_TEST"
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

@test "help (-h) prints docstring and exits 0" {
    run generate-headline -h
    assert_success
    assert_output --partial 'Script: generate-headline'
    assert_output --partial 'Options:'
}

@test "help (--help) prints docstring and exits 0" {
    run generate-headline --help
    assert_success
    assert_output --partial 'Script: generate-headline'
}

# ---------------------------------------------------------------------------
# Validation failures
# ---------------------------------------------------------------------------

@test "empty positional arg fails with '入力が空'" {
    run generate-headline "   "
    assert_failure
    assert_output --partial '入力が空'
}

@test "unknown option fails" {
    run bash -c 'echo "text" | generate-headline --unknown-flag'
    assert_failure
    assert_output --partial 'unknown option'
}

@test "--candidate with non-integer fails" {
    run bash -c 'echo "text" | generate-headline --candidate abc'
    assert_failure
    assert_output --partial '--candidate must be a positive integer'
}

@test "--candidate with zero fails" {
    run bash -c 'echo "text" | generate-headline -n 0'
    assert_failure
    assert_output --partial '--candidate must be a positive integer'
}

@test "--model without argument fails" {
    run bash -c 'echo "text" | generate-headline --model'
    assert_failure
    assert_output --partial 'requires an argument'
}

# ---------------------------------------------------------------------------
# Default backend (claude-stdin-prompt)
# ---------------------------------------------------------------------------

@test "positional arg is piped to claude-stdin-prompt" {
    run generate-headline "テスト入力"
    assert_success
    assert_output --partial 'CLAUDE_STUB_OK'
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"-p"* ]]
}

@test "stdin is forwarded to claude-stdin-prompt" {
    run bash -c "CLAUDE_ARGV_FILE='$CLAUDE_ARGV_FILE' CODEX_ARGV_FILE='$CODEX_ARGV_FILE' PATH='$PATH' echo 'stdin テキスト' | generate-headline"
    assert_success
    assert_output --partial 'CLAUDE_STUB_OK'
}

@test "--model is forwarded to claude-stdin-prompt" {
    run bash -c "CLAUDE_ARGV_FILE='$CLAUDE_ARGV_FILE' CODEX_ARGV_FILE='$CODEX_ARGV_FILE' PATH='$PATH' echo 'text' | generate-headline --model opus"
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"opus"* ]]
}

@test "-m short form is forwarded to claude-stdin-prompt" {
    run bash -c "CLAUDE_ARGV_FILE='$CLAUDE_ARGV_FILE' CODEX_ARGV_FILE='$CODEX_ARGV_FILE' PATH='$PATH' echo 'text' | generate-headline -m haiku"
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"haiku"* ]]
}

# ---------------------------------------------------------------------------
# --codex backend (codex-stdin-prompt)
# ---------------------------------------------------------------------------

@test "--codex routes to codex-stdin-prompt" {
    run bash -c "CLAUDE_ARGV_FILE='$CLAUDE_ARGV_FILE' CODEX_ARGV_FILE='$CODEX_ARGV_FILE' PATH='$PATH' echo 'text' | generate-headline --codex"
    assert_success
    assert_output --partial 'CODEX_STUB_OK'
}

@test "--codex with --model forwards model to codex-stdin-prompt" {
    run bash -c "CLAUDE_ARGV_FILE='$CLAUDE_ARGV_FILE' CODEX_ARGV_FILE='$CODEX_ARGV_FILE' PATH='$PATH' echo 'text' | generate-headline --codex --model o4-mini"
    assert_success
    argv="$(cat "$CODEX_ARGV_FILE")"
    [[ "$argv" == *"o4-mini"* ]]
}

@test "--codex with positional arg routes to codex-stdin-prompt" {
    run generate-headline --codex "テスト"
    assert_success
    assert_output --partial 'CODEX_STUB_OK'
}

# ---------------------------------------------------------------------------
# --candidate option
# ---------------------------------------------------------------------------

@test "--candidate N embeds N into the prompt" {
    run bash -c "CLAUDE_ARGV_FILE='$CLAUDE_ARGV_FILE' CODEX_ARGV_FILE='$CODEX_ARGV_FILE' PATH='$PATH' echo 'text' | generate-headline --candidate 5"
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"5案ずつ"* ]]
}

@test "-n N (short form) embeds N into the prompt" {
    run bash -c "CLAUDE_ARGV_FILE='$CLAUDE_ARGV_FILE' CODEX_ARGV_FILE='$CODEX_ARGV_FILE' PATH='$PATH' echo 'text' | generate-headline -n 2"
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"2案ずつ"* ]]
}

@test "default candidate count is 3" {
    run bash -c "CLAUDE_ARGV_FILE='$CLAUDE_ARGV_FILE' CODEX_ARGV_FILE='$CODEX_ARGV_FILE' PATH='$PATH' echo 'text' | generate-headline"
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"3案ずつ"* ]]
}
