#!/usr/bin/env bats

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"

    OLD_PATH=$PATH
    PATH="$DIR/../../bin/markdown:$PATH"

    TMPDIR_TEST="$(mktemp -d)"
}

teardown() {
    PATH=$OLD_PATH
    if [[ -n "${TMPDIR_TEST:-}" && -d "$TMPDIR_TEST" ]]; then
        chmod -R u+rwX "$TMPDIR_TEST" 2>/dev/null || true
        rm -rf "$TMPDIR_TEST"
    fi
}

_need_gawk() {
    command -v gawk >/dev/null 2>&1 || skip "gawk not installed"
}

@test "help option prints docstring and exits 0" {
    _need_gawk
    run md-tree -h
    assert_success
    assert_output --partial 'Script: md-tree'
    assert_output --partial 'Usage:'
}

@test "--help long flag prints docstring and exits 0" {
    _need_gawk
    run md-tree --help
    assert_success
    assert_output --partial 'Script: md-tree'
}

@test "unknown option fails with error" {
    _need_gawk
    run md-tree --bogus
    assert_failure
    assert_output --partial 'unknown option'
}

@test "multiple file positionals fail" {
    _need_gawk
    f1="$TMPDIR_TEST/a.md"
    f2="$TMPDIR_TEST/b.md"
    : > "$f1"
    : > "$f2"
    run md-tree "$f1" "$f2"
    assert_failure
    assert_output --partial 'multiple files not supported'
}

@test "non-md/qmd extension is rejected" {
    _need_gawk
    f="$TMPDIR_TEST/notmd.txt"
    echo "# hi" > "$f"
    run md-tree "$f"
    assert_failure
    assert_output --partial 'Only .md or .qmd files are supported'
}

@test "missing file fails with File not found" {
    _need_gawk
    run md-tree "$TMPDIR_TEST/does_not_exist.md"
    assert_failure
    assert_output --partial 'File not found'
}

@test "unreadable file fails with File not readable" {
    _need_gawk
    [[ $(id -u) -eq 0 ]] && skip "running as root; chmod 000 is ineffective"
    f="$TMPDIR_TEST/unreadable.md"
    echo "# hi" > "$f"
    chmod 000 "$f"
    run md-tree "$f"
    assert_failure
    assert_output --partial 'File not readable'
    chmod 600 "$f" 2>/dev/null || true
}

@test "basic tree output: shape and labels" {
    _need_gawk
    f="$TMPDIR_TEST/simple.md"
    cat > "$f" <<'EOF'
# A
## B
## C
# D
EOF
    run md-tree "$f"
    assert_success
    # First line is the filename (root label)
    assert_line --index 0 "$f"
    # All headings appear
    assert_output --partial 'A'
    assert_output --partial 'B'
    assert_output --partial 'C'
    assert_output --partial 'D'
    # Tree glyphs are present
    assert_output --partial '├──'
    assert_output --partial '└──'
}

@test ".qmd extension is accepted" {
    _need_gawk
    f="$TMPDIR_TEST/doc.qmd"
    cat > "$f" <<'EOF'
# Quarto Title
## Section
EOF
    run md-tree "$f"
    assert_success
    assert_line --index 0 "$f"
    assert_output --partial 'Quarto Title'
    assert_output --partial 'Section'
}

@test "--json produces valid JSON with expected names" {
    _need_gawk
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    f="$TMPDIR_TEST/j.md"
    cat > "$f" <<'EOF'
# Top
## Sub1
## Sub2
EOF
    run md-tree --json "$f"
    assert_success
    # Valid JSON
    echo "$output" | jq . >/dev/null
    # top-level name equals the filename argument
    name="$(echo "$output" | jq -r '.name')"
    [ "$name" = "$f" ]
    # Headings appear in JSON
    assert_output --partial '"Top"'
    assert_output --partial '"Sub1"'
    assert_output --partial '"Sub2"'
}

@test "--yaml produces structural YAML output" {
    _need_gawk
    f="$TMPDIR_TEST/y.md"
    cat > "$f" <<'EOF'
# A
## B
EOF
    run md-tree --yaml "$f"
    assert_success
    assert_output --partial "name: \"$f\""
    assert_output --partial 'children:'
    assert_output --partial '- name: "A"'
    assert_output --partial '- name: "B"'
}

@test "YAML front matter is skipped" {
    _need_gawk
    f="$TMPDIR_TEST/fm.md"
    cat > "$f" <<'EOF'
---
foo: bar
title: Hello
---
# Real Heading
## Second
EOF
    run md-tree "$f"
    assert_success
    refute_output --partial 'foo: bar'
    refute_output --partial 'title: Hello'
    assert_output --partial 'Real Heading'
    assert_output --partial 'Second'
}

@test "fenced code blocks with backticks are skipped" {
    _need_gawk
    f="$TMPDIR_TEST/fence.md"
    cat > "$f" <<'EOF'
# Outside
```
# Inside
EOF
    # close fence + post-fence heading
    printf '```\n## After\n' >> "$f"

    run md-tree "$f"
    assert_success
    assert_output --partial 'Outside'
    assert_output --partial 'After'
    refute_output --partial 'Inside'
}

@test "tilde fenced code blocks are skipped" {
    _need_gawk
    f="$TMPDIR_TEST/tilde.md"
    cat > "$f" <<'EOF'
# Outer
~~~
# HiddenInTilde
~~~
## TildeAfter
EOF
    run md-tree "$f"
    assert_success
    assert_output --partial 'Outer'
    assert_output --partial 'TildeAfter'
    refute_output --partial 'HiddenInTilde'
}

@test "trailing # marks on headings are stripped" {
    _need_gawk
    f="$TMPDIR_TEST/trail.md"
    cat > "$f" <<'EOF'
# Heading ###
## Sub ##
EOF
    run md-tree "$f"
    assert_success
    # The bare title without trailing #'s appears
    assert_output --partial '── Heading'
    assert_output --partial '── Sub'
    # Trailing hash sequence is NOT present
    refute_output --partial 'Heading ###'
    refute_output --partial 'Sub ##'
}

@test "nested levels render with increasing indentation" {
    _need_gawk
    f="$TMPDIR_TEST/nest.md"
    cat > "$f" <<'EOF'
# A
## B
### C
EOF
    run md-tree "$f"
    assert_success
    # root = filename
    assert_line --index 0 "$f"
    # A is at top level, prefixed by tree glyph (└── since only one top-level)
    assert_line --index 1 '└── A'
    # B nested one level under A: 4 spaces of indent + glyph
    assert_line --index 2 '    └── B'
    # C nested two levels: 8 spaces indent + glyph
    assert_line --index 3 '        └── C'
}