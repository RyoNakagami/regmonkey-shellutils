#!/usr/bin/env bats

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"

    OLD_PATH=$PATH
    TMPDIR_TEST="$(mktemp -d)"

    # Stub `codex` so tests can assert how the wrapper invoked it.
    # Records argv (one arg per line) into $CODEX_ARGV_FILE.
    # Non-verbose mode: wrapper calls `codex ... -o "$TMPFILE" "$COMBINED" >/dev/null 2>&1`
    # then `cat "$TMPFILE"` — so the stub must detect `-o <file>` and write
    # the final positional (combined prompt) into that file so the wrapper's
    # subsequent `cat "$TMPFILE"` produces observable output.
    # --custom-verbose mode: wrapper `exec codex ... "$COMBINED"` — no `-o`;
    # stub then prints the combined prompt to stdout.
    mkdir -p "$TMPDIR_TEST/bin"
    CODEX_ARGV_FILE="$TMPDIR_TEST/codex.argv"
    export CODEX_ARGV_FILE

    cat > "$TMPDIR_TEST/bin/codex" <<'STUB'
#!/usr/bin/env bash
: > "${CODEX_ARGV_FILE}"
for a in "$@"; do
    printf '%s\n' "$a" >> "${CODEX_ARGV_FILE}"
done

out_file=""
prev=""
last=""
for a in "$@"; do
    if [[ "$prev" == "-o" ]]; then
        out_file="$a"
    fi
    prev="$a"
    last="$a"
done

if [[ -n "$out_file" ]]; then
    printf '%s' "$last" > "$out_file"
else
    printf '%s' "$last"
fi
STUB
    chmod +x "$TMPDIR_TEST/bin/codex"

    # Stub dir FIRST, then the script dir, so `codex` resolves to our stub.
    PATH="$TMPDIR_TEST/bin:$DIR/../../bin/agent:$PATH"
}

teardown() {
    PATH=$OLD_PATH
    rm -rf "$TMPDIR_TEST"
}

@test "help option prints docstring and exits 0" {
    run codex-stdin-prompt -h
    assert_success
    assert_output --partial 'Script: codex-stdin-prompt'
    assert_output --partial 'Usage:'
}

@test "--help long form prints docstring and exits 0" {
    run codex-stdin-prompt --help
    assert_success
    assert_output --partial 'Script: codex-stdin-prompt'
}

@test "missing prompt fails with 'no prompt given'" {
    run bash -c 'echo "some stdin" | codex-stdin-prompt'
    assert_failure
    assert_output --partial 'no prompt given'
}

@test "codex not on PATH fails with informative error and install hint" {
    run bash -c 'PATH="'"$DIR/../../bin/agent"':/usr/bin:/bin" codex-stdin-prompt -p "hi" <<< "stdin"'
    assert_failure
    assert_output --partial "'codex' CLI not found in PATH"
    assert_output --partial 'npm install -g @openai/codex'
}

@test "-p TEXT: literal prompt + stdin reach codex; argv has 'exec' and bypass flag" {
    run bash -c 'echo "STDIN_BODY" | codex-stdin-prompt -p "LITERAL_PROMPT"'
    assert_success
    assert_output --partial 'LITERAL_PROMPT'
    assert_output --partial 'STDIN_BODY'

    argv="$(cat "$CODEX_ARGV_FILE")"
    [[ "$argv" == *"exec"* ]]
    [[ "$argv" == *"--dangerously-bypass-approvals-and-sandbox"* ]]
    [[ "$argv" == *"-o"* ]]
}

@test "--prompt=TEXT (equals form) works" {
    run bash -c 'echo "STDIN_EQ" | codex-stdin-prompt --prompt=EQ_PROMPT'
    assert_success
    assert_output --partial 'EQ_PROMPT'
    assert_output --partial 'STDIN_EQ'
}

@test "-p value pointing to existing file uses file contents as the prompt" {
    pfile="$TMPDIR_TEST/prompt.md"
    printf 'PROMPT_FROM_FILE_BODY' > "$pfile"
    run bash -c 'echo "STDIN_PF" | codex-stdin-prompt -p "'"$pfile"'"'
    assert_success
    assert_output --partial 'PROMPT_FROM_FILE_BODY'
    assert_output --partial 'STDIN_PF'
    refute_output --partial "$pfile"
}

@test "-p value that is not a file is used as a literal string" {
    run bash -c 'echo "x" | codex-stdin-prompt -p "JUST_A_LITERAL_STRING"'
    assert_success
    assert_output --partial 'JUST_A_LITERAL_STRING'
}

@test "--context-file LITERAL adds literal context block with headers before prompt" {
    run bash -c 'echo "sd" | codex-stdin-prompt --context-file "CTX_LITERAL_AAA" -p "P_BODY"'
    assert_success
    assert_output --partial 'CTX_LITERAL_AAA'
    assert_output --partial '# Context'
    assert_output --partial '# Instruction'
    assert_output --partial '# stdin'
    assert_output --partial 'P_BODY'
}

@test "--context-file PATH adds the file's contents (not the path string)" {
    cfile="$TMPDIR_TEST/ctx.md"
    printf 'CTX_FROM_FILE_BBB' > "$cfile"
    run bash -c 'echo "sd" | codex-stdin-prompt --context-file "'"$cfile"'" -p "P"'
    assert_success
    assert_output --partial 'CTX_FROM_FILE_BBB'
    refute_output --partial "$cfile"
}

@test "multiple --context-file calls stack in order" {
    run bash -c 'echo "sd" | codex-stdin-prompt --context-file "FIRST_CTX" --context-file "SECOND_CTX" -p "P"'
    assert_success
    assert_output --partial 'FIRST_CTX'
    assert_output --partial 'SECOND_CTX'
    first_pos=$(printf '%s' "$output" | grep -b -o 'FIRST_CTX' | head -1 | cut -d: -f1)
    second_pos=$(printf '%s' "$output" | grep -b -o 'SECOND_CTX' | head -1 | cut -d: -f1)
    [ -n "$first_pos" ]
    [ -n "$second_pos" ]
    [ "$first_pos" -lt "$second_pos" ]
}

@test "unknown flags are forwarded to codex (e.g. --model o4-mini)" {
    run bash -c 'echo "x" | codex-stdin-prompt --model o4-mini -p "P"'
    assert_success
    run grep -x -- '--model' "$CODEX_ARGV_FILE"
    assert_success
    run grep -x -- 'o4-mini' "$CODEX_ARGV_FILE"
    assert_success
}

@test "-- terminator: tokens after -- are forwarded verbatim to codex" {
    run bash -c 'echo "x" | codex-stdin-prompt -p "P" -- --some-codex-flag VAL'
    assert_success
    run grep -x -- '--some-codex-flag' "$CODEX_ARGV_FILE"
    assert_success
    run grep -x -- 'VAL' "$CODEX_ARGV_FILE"
    assert_success
}

@test "--custom-verbose: codex is exec'd with 'exec' + bypass; no -o injection" {
    run bash -c 'echo "VS_STDIN" | codex-stdin-prompt --custom-verbose -p "VS_PROMPT"'
    assert_success
    assert_output --partial 'VS_PROMPT'
    assert_output --partial 'VS_STDIN'

    argv="$(cat "$CODEX_ARGV_FILE")"
    [[ "$argv" == *"exec"* ]]
    [[ "$argv" == *"--dangerously-bypass-approvals-and-sandbox"* ]]
    run grep -x -- '-o' "$CODEX_ARGV_FILE"
    assert_failure
}
