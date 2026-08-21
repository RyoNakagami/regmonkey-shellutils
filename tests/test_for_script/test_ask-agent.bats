#!/usr/bin/env bats

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"
    REPO="$DIR/../.."

    OLD_PATH=$PATH
    TMPDIR_TEST="$(mktemp -d)"

    # ask-agent resolves sibling agents via $(dirname "${BASH_SOURCE[0]}"),
    # so stubs must live in the same directory as the script.  We build a sandbox:
    #   $TMPDIR_TEST/bin/agent/ask-agent             (real script, symlinked)
    #   $TMPDIR_TEST/bin/agent/claude-stdin-prompt   (stub)
    #   $TMPDIR_TEST/bin/agent/codex-stdin-prompt    (stub)
    #   $TMPDIR_TEST/lib/docstring.sh                (real lib, symlinked)
    mkdir -p "$TMPDIR_TEST/bin/agent" "$TMPDIR_TEST/lib"
    ln -s "$REPO/bin/agent/ask-agent" "$TMPDIR_TEST/bin/agent/ask-agent"
    ln -s "$REPO/lib/docstring.sh"    "$TMPDIR_TEST/lib/docstring.sh"

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

    # Add sandbox bin/agent to PATH so `ask-agent` is invocable by name.
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
    run ask-agent -h
    assert_success
    assert_output --partial 'Script: ask-agent'
    assert_output --partial 'Options:'
}

@test "help (--help) prints docstring and exits 0" {
    run ask-agent --help
    assert_success
    assert_output --partial 'Script: ask-agent'
}

# ---------------------------------------------------------------------------
# Validation failures
# ---------------------------------------------------------------------------

@test "no request fails" {
    run ask-agent
    assert_failure
    assert_output --partial '依頼文が指定されていません'
}

@test "blank request fails" {
    run ask-agent "   "
    assert_failure
    assert_output --partial '依頼文が空です'
}

@test "unknown option fails" {
    run ask-agent --unknown-flag hello
    assert_failure
    assert_output --partial 'unknown option'
}

@test "--model without argument fails" {
    run ask-agent --model
    assert_failure
    assert_output --partial 'requires an argument'
}

# ---------------------------------------------------------------------------
# Default backend (claude-stdin-prompt) and cheapest-model default
# ---------------------------------------------------------------------------

@test "request is piped to claude-stdin-prompt as stdin" {
    run ask-agent into japanese how are you?
    assert_success
    assert_output --partial 'CLAUDE_STUB_OK'
    # The stub cats stdin, so the request string must appear in the output.
    assert_output --partial 'into japanese how are you?'
}

@test "default model is haiku (cheapest) for the claude backend" {
    run ask-agent into japanese hello
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"--model"* ]]
    [[ "$argv" == *"haiku"* ]]
}

@test "--model overrides the haiku default" {
    run ask-agent --model opus4.8 into japanese hello
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"opus4.8"* ]]
    [[ "$argv" != *"haiku"* ]]
}

@test "-m short form overrides the model" {
    run ask-agent -m sonnet into japanese hello
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"sonnet"* ]]
}

@test "--model=VALUE form is accepted" {
    run ask-agent --model=opus into japanese hello
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"opus"* ]]
}

# ---------------------------------------------------------------------------
# --codex backend
# ---------------------------------------------------------------------------

@test "--codex routes to codex-stdin-prompt" {
    run ask-agent --codex into english 承知しました
    assert_success
    assert_output --partial 'CODEX_STUB_OK'
}

@test "--codex defaults to gpt-5.6-luna (cheapest)" {
    run ask-agent --codex into english 承知しました
    assert_success
    argv="$(cat "$CODEX_ARGV_FILE")"
    [[ "$argv" == *"--model"* ]]
    [[ "$argv" == *"gpt-5.6-luna"* ]]
}

@test "--codex never inherits the claude haiku default" {
    run ask-agent --codex into english hello
    assert_success
    argv="$(cat "$CODEX_ARGV_FILE")"
    [[ "$argv" != *"haiku"* ]]
}

@test "--codex with --model overrides the luna default" {
    run ask-agent --codex --model gpt-5.5 into english hello
    assert_success
    argv="$(cat "$CODEX_ARGV_FILE")"
    [[ "$argv" == *"gpt-5.5"* ]]
    [[ "$argv" != *"gpt-5.6-luna"* ]]
}

@test "--codex resolves the 'luna' shorthand to gpt-5.6-luna" {
    run ask-agent --codex --model luna into english hello
    assert_success
    argv="$(cat "$CODEX_ARGV_FILE")"
    [[ "$argv" == *"gpt-5.6-luna"* ]]
}

@test "--codex resolves the 'terra' shorthand to gpt-5.6-terra" {
    run ask-agent --codex --model terra into english hello
    assert_success
    argv="$(cat "$CODEX_ARGV_FILE")"
    [[ "$argv" == *"gpt-5.6-terra"* ]]
}

@test "claude backend does not apply the codex model shorthand" {
    run ask-agent --model luna into english hello
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    # 'luna' must pass through untouched on the claude backend.
    [[ "$argv" == *"luna"* ]]
    [[ "$argv" != *"gpt-5.6-luna"* ]]
}

# ---------------------------------------------------------------------------
# Prompt construction
# ---------------------------------------------------------------------------

@test "prompt instructs splitting instruction from target text" {
    run ask-agent into japanese hello
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"指示"* ]]
    [[ "$argv" == *"対象テキスト"* ]]
}

@test "default prompt forbids preamble and decoration" {
    run ask-agent into japanese hello
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"結果テキストのみ"* ]]
    [[ "$argv" == *"前置き"* ]]
}

@test "--verbose drops the concise-only constraint" {
    run ask-agent --verbose into japanese hello
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"補足説明"* ]]
    [[ "$argv" != *"結果テキストのみ"* ]]
}

@test "-v short form drops the concise-only constraint" {
    run ask-agent -v into japanese hello
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"補足説明"* ]]
}

@test "prompt does not hardcode an output language" {
    run ask-agent into japanese hello
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    # Output language is left to the request itself, not pinned by the wrapper.
    [[ "$argv" == *"対象テキストの言語を保つ"* ]]
}

# ---------------------------------------------------------------------------
# Positional handling
# ---------------------------------------------------------------------------

@test "multiple positional args are joined into one request string" {
    run ask-agent make it concise under 10 strings 今日は天気が良いですね
    assert_success
    assert_output --partial 'make it concise under 10 strings 今日は天気が良いですね'
}

@test "quoted multi-word request is preserved" {
    run ask-agent "into japanese how are you?"
    assert_success
    assert_output --partial 'into japanese how are you?'
}

@test "flags after the request are treated as part of the request" {
    run ask-agent explain git log --oneline
    assert_success
    assert_output --partial 'explain git log --oneline'
    # Must NOT be rejected as an unknown option.
    refute_output --partial 'unknown option'
}

@test "-- protects a request starting with a dash" {
    run ask-agent -- --force というオプションの意味を1行で
    assert_success
    assert_output --partial -- '--force というオプションの意味を1行で'
}

@test "options are still parsed when they precede the request" {
    run ask-agent --codex -m terra into english 承知しました
    assert_success
    assert_output --partial 'CODEX_STUB_OK'
    assert_output --partial 'into english 承知しました'
    argv="$(cat "$CODEX_ARGV_FILE")"
    [[ "$argv" == *"gpt-5.6-terra"* ]]
}

@test "a question with no target text is passed through as the request" {
    run ask-agent bash の set -e は何をする?
    assert_success
    assert_output --partial 'bash の set -e は何をする?'
}
