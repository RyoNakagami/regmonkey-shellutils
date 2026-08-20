#!/usr/bin/env bats

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"
    REPO="$DIR/../.."

    OLD_PATH=$PATH
    TMPDIR_TEST="$(mktemp -d)"

    # ask-command resolves sibling agents via $(dirname "${BASH_SOURCE[0]}"),
    # so stubs must live in the same directory as the script.  We build a sandbox:
    #   $TMPDIR_TEST/bin/agent/ask-command            (real script, symlinked)
    #   $TMPDIR_TEST/bin/agent/claude-stdin-prompt  (stub)
    #   $TMPDIR_TEST/bin/agent/codex-stdin-prompt   (stub)
    #   $TMPDIR_TEST/lib/docstring.sh               (real lib, symlinked)
    mkdir -p "$TMPDIR_TEST/bin/agent" "$TMPDIR_TEST/lib"
    ln -s "$REPO/bin/agent/ask-command" "$TMPDIR_TEST/bin/agent/ask-command"
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

    # Add sandbox bin/agent to PATH so `ask-command` is invocable by name.
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
    run ask-command -h
    assert_success
    assert_output --partial 'Script: ask-command'
    assert_output --partial 'Options:'
}

@test "help (--help) prints docstring and exits 0" {
    run ask-command --help
    assert_success
    assert_output --partial 'Script: ask-command'
}

# ---------------------------------------------------------------------------
# Validation failures
# ---------------------------------------------------------------------------

@test "no target command fails" {
    run ask-command
    assert_failure
    assert_output --partial '解説対象のコマンドが指定されていません'
}

@test "blank target command fails" {
    run ask-command "   "
    assert_failure
    assert_output --partial '解説対象のコマンドが空です'
}

@test "unknown option fails" {
    run ask-command --unknown-flag git
    assert_failure
    assert_output --partial 'unknown option'
}

@test "--model without argument fails" {
    run ask-command --model
    assert_failure
    assert_output --partial 'requires an argument'
}

@test "--example with non-integer fails" {
    run ask-command --example abc git
    assert_failure
    assert_output --partial '--example must be a positive integer'
}

@test "--example with zero fails" {
    run ask-command -n 0 git
    assert_failure
    assert_output --partial '--example must be a positive integer'
}

# ---------------------------------------------------------------------------
# Default backend (claude-stdin-prompt) and default model
# ---------------------------------------------------------------------------

@test "target command is piped to claude-stdin-prompt as stdin" {
    run ask-command git stash
    assert_success
    assert_output --partial 'CLAUDE_STUB_OK'
    # The stub cats stdin, so the target string must appear in the output.
    assert_output --partial 'git stash'
}

@test "default model is haiku for the claude backend" {
    run ask-command git stash
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"--model"* ]]
    [[ "$argv" == *"haiku"* ]]
}

@test "--model overrides the haiku default" {
    run ask-command --model opus4.8 rsync
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"opus4.8"* ]]
    [[ "$argv" != *"haiku"* ]]
}

@test "-m short form overrides the model" {
    run ask-command -m sonnet awk
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"sonnet"* ]]
}

@test "--model=VALUE form is accepted" {
    run ask-command --model=opus tar
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"opus"* ]]
}

# ---------------------------------------------------------------------------
# --codex backend
# ---------------------------------------------------------------------------

@test "--codex routes to codex-stdin-prompt" {
    run ask-command --codex docker
    assert_success
    assert_output --partial 'CODEX_STUB_OK'
}

@test "--codex defaults to gpt-5.6-luna" {
    run ask-command --codex docker
    assert_success
    argv="$(cat "$CODEX_ARGV_FILE")"
    [[ "$argv" == *"--model"* ]]
    [[ "$argv" == *"gpt-5.6-luna"* ]]
}

@test "--codex never inherits the claude haiku default" {
    run ask-command --codex docker
    assert_success
    argv="$(cat "$CODEX_ARGV_FILE")"
    [[ "$argv" != *"haiku"* ]]
}

@test "--codex with --model overrides the luna default" {
    run ask-command --codex --model gpt-5.5 jq
    assert_success
    argv="$(cat "$CODEX_ARGV_FILE")"
    [[ "$argv" == *"gpt-5.5"* ]]
    [[ "$argv" != *"gpt-5.6-luna"* ]]
}

@test "--codex resolves the 'luna' shorthand to gpt-5.6-luna" {
    run ask-command --codex --model luna jq
    assert_success
    argv="$(cat "$CODEX_ARGV_FILE")"
    [[ "$argv" == *"gpt-5.6-luna"* ]]
}

@test "--codex resolves the 'terra' shorthand to gpt-5.6-terra" {
    run ask-command --codex --model terra jq
    assert_success
    argv="$(cat "$CODEX_ARGV_FILE")"
    [[ "$argv" == *"gpt-5.6-terra"* ]]
}

@test "claude backend does not apply the codex model shorthand" {
    run ask-command --model luna jq
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    # 'luna' must pass through untouched on the claude backend.
    [[ "$argv" == *"luna"* ]]
    [[ "$argv" != *"gpt-5.6-luna"* ]]
}

# ---------------------------------------------------------------------------
# Prompt construction
# ---------------------------------------------------------------------------

@test "prompt contains the four required sections" {
    run ask-command git stash
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"## 動作"* ]]
    [[ "$argv" == *"## Syntax"* ]]
    [[ "$argv" == *"## Frequently Used Options"* ]]
    [[ "$argv" == *"## Examples"* ]]
}

@test "default example count is 3" {
    run ask-command git stash
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"3件"* ]]
}

@test "--example N embeds N into the prompt" {
    run ask-command --example 5 find
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"5件"* ]]
}

@test "-n N (short form) embeds N into the prompt" {
    run ask-command -n 7 find
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"7件"* ]]
}

@test "default output language is ja" {
    run ask-command git stash
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"出力言語は ja です"* ]]
}

@test "--lang overrides the output language" {
    run ask-command --lang en find
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"出力言語は en です"* ]]
}

@test "-l short form overrides the output language" {
    run ask-command -l en find
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"出力言語は en です"* ]]
}

# ---------------------------------------------------------------------------
# Positional handling
# ---------------------------------------------------------------------------

@test "multiple positional args are joined into one command string" {
    run ask-command docker compose up
    assert_success
    assert_output --partial 'docker compose up'
}

@test "quoted multi-word target is preserved" {
    run ask-command "git rebase -i"
    assert_success
    assert_output --partial 'git rebase -i'
}

@test "flags after the target command are treated as part of the target" {
    run ask-command git log --oneline
    assert_success
    assert_output --partial 'git log --oneline'
    # Must NOT be rejected as an unknown option.
    refute_output --partial 'unknown option'
}

@test "-- protects a target starting with a dash" {
    run ask-command -- --version
    assert_success
    assert_output --partial -- '--version'
}

@test "options are still parsed when they precede the target" {
    run ask-command --codex -n 2 git bisect
    assert_success
    assert_output --partial 'CODEX_STUB_OK'
    assert_output --partial 'git bisect'
    argv="$(cat "$CODEX_ARGV_FILE")"
    [[ "$argv" == *"2件"* ]]
}
