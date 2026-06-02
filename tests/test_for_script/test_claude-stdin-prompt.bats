#!/usr/bin/env bats

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"

    OLD_PATH=$PATH
    TMPDIR_TEST="$(mktemp -d)"

    # Stub `claude` so tests can assert how the wrapper invoked it.
    # The stub records its argv (one arg per line) into $CLAUDE_ARGV_FILE,
    # which the wrapper inherits via the environment.
    mkdir -p "$TMPDIR_TEST/bin"
    CLAUDE_ARGV_FILE="$TMPDIR_TEST/claude.argv"
    export CLAUDE_ARGV_FILE

    cat > "$TMPDIR_TEST/bin/claude" <<'STUB'
#!/bin/bash
: > "${CLAUDE_ARGV_FILE}"
for a in "$@"; do
    printf '%s\n' "$a" >> "${CLAUDE_ARGV_FILE}"
done
# Echo something benign so callers see a successful claude invocation.
printf 'CLAUDE_STUB_OK\n'
STUB
    chmod +x "$TMPDIR_TEST/bin/claude"

    # Stub dir FIRST, then the script dir, so `claude` resolves to our stub.
    PATH="$TMPDIR_TEST/bin:$DIR/../../bin/agent:$PATH"
}

teardown() {
    PATH=$OLD_PATH
    rm -rf "$TMPDIR_TEST"
}

@test "help option prints docstring and exits 0" {
    run claude-stdin-prompt -h
    assert_success
    assert_output --partial 'Script: claude-stdin-prompt'
    assert_output --partial 'Usage:'
}

@test "missing prompt fails with 'no prompt given'" {
    run bash -c 'echo "some stdin" | claude-stdin-prompt'
    assert_failure
    assert_output --partial 'no prompt given'
}

@test "claude not on PATH fails with informative error" {
    # Use only the bin/agent dir on PATH so the stub is not visible.
    # Keep /usr/bin and /bin so core utilities (bash, cat, basename...) work.
    run bash -c 'PATH="'"$DIR/../../bin/agent"':/usr/bin:/bin" claude-stdin-prompt -p "hi" <<< "stdin"'
    assert_failure
    assert_output --partial "'claude' CLI not found in PATH"
}

@test "-p TEXT: literal prompt and stdin are forwarded to claude" {
    run bash -c 'echo "STDIN_BODY" | claude-stdin-prompt -p "LITERAL_PROMPT"'
    assert_success
    # The wrapper echoes whatever claude's stub printed.
    assert_output --partial 'CLAUDE_STUB_OK'
    # Inspect what the stub received.
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"--print"* ]]
    [[ "$argv" == *"LITERAL_PROMPT"* ]]
    [[ "$argv" == *"STDIN_BODY"* ]]
}

@test "--prompt=TEXT (equals form) works the same as -p" {
    run bash -c 'echo "STDIN_X" | claude-stdin-prompt --prompt=EQ_PROMPT'
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"EQ_PROMPT"* ]]
    [[ "$argv" == *"STDIN_X"* ]]
}

@test "--prompt-file reads file content as the prompt" {
    pfile="$TMPDIR_TEST/prompt.txt"
    printf 'PROMPT_FROM_FILE_LINE_1\nPROMPT_FROM_FILE_LINE_2\n' > "$pfile"
    run bash -c 'echo "STDIN_PF" | claude-stdin-prompt --prompt-file "'"$pfile"'"'
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"PROMPT_FROM_FILE_LINE_1"* ]]
    [[ "$argv" == *"PROMPT_FROM_FILE_LINE_2"* ]]
    [[ "$argv" == *"STDIN_PF"* ]]
}

@test "--prompt-file with nonexistent file fails with 'file not found'" {
    run bash -c 'echo "x" | claude-stdin-prompt --prompt-file "'"$TMPDIR_TEST"'/does/not/exist.md"'
    assert_failure
    assert_output --partial 'file not found'
}

@test "--prompt specified twice fails" {
    run bash -c 'echo "x" | claude-stdin-prompt -p "first" --prompt "second"'
    assert_failure
    assert_output --partial 'prompt specified more than once'
}

@test "--context literal and --context-file both appear in combined prompt" {
    cfile="$TMPDIR_TEST/ctx.md"
    printf 'CONTEXT_FROM_FILE_BODY\n' > "$cfile"
    run bash -c 'echo "STDIN_CTX" | claude-stdin-prompt \
        --context "LITERAL_CONTEXT" \
        --context-file "'"$cfile"'" \
        -p "MY_PROMPT"'
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"LITERAL_CONTEXT"* ]]
    [[ "$argv" == *"CONTEXT_FROM_FILE_BODY"* ]]
    [[ "$argv" == *"MY_PROMPT"* ]]
    [[ "$argv" == *"STDIN_CTX"* ]]
    # Headers should appear too.
    [[ "$argv" == *"# Context"* ]]
    [[ "$argv" == *"# Instruction"* ]]
    [[ "$argv" == *"# stdin"* ]]
}

@test "--context-file with missing file fails" {
    run bash -c 'echo "x" | claude-stdin-prompt --context-file "'"$TMPDIR_TEST"'/no.md" -p "p"'
    assert_failure
    assert_output --partial 'file not found'
}

@test "default model: --model sonnet is injected when --model not supplied" {
    run bash -c 'echo "x" | claude-stdin-prompt -p "p"'
    assert_success
    # Look for the literal pair on two consecutive lines.
    run grep -nx -- '--model' "$CLAUDE_ARGV_FILE"
    assert_success
    run bash -c 'grep -A1 -x -- "--model" "'"$CLAUDE_ARGV_FILE"'" | tail -n1'
    assert_output 'sonnet'
}

@test "user-supplied --model opus is preserved (no sonnet injection)" {
    run bash -c 'echo "x" | claude-stdin-prompt --model opus -p "p"'
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"opus"* ]]
    # Sonnet must NOT have been injected.
    run grep -x -- 'sonnet' "$CLAUDE_ARGV_FILE"
    assert_failure
}

@test "unknown flags are forwarded to claude verbatim" {
    run bash -c 'echo "x" | claude-stdin-prompt --debug -p "p"'
    assert_success
    run grep -x -- '--debug' "$CLAUDE_ARGV_FILE"
    assert_success
}

@test "-- terminator: tokens after -- are forwarded verbatim" {
    run bash -c 'echo "x" | claude-stdin-prompt -p "p" -- --pass-through-flag VAL'
    assert_success
    run grep -x -- '--pass-through-flag' "$CLAUDE_ARGV_FILE"
    assert_success
    run grep -x -- 'VAL' "$CLAUDE_ARGV_FILE"
    assert_success
}

@test "bare positional becomes the prompt when no -p is given" {
    run bash -c 'echo "STDIN_POS" | claude-stdin-prompt "POSITIONAL_PROMPT"'
    assert_success
    argv="$(cat "$CLAUDE_ARGV_FILE")"
    [[ "$argv" == *"POSITIONAL_PROMPT"* ]]
    [[ "$argv" == *"STDIN_POS"* ]]
}