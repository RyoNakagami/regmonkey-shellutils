#!/usr/bin/env bats

# yamlcli と jq は PATH 先頭の stub で差し替え、決定的にテストする。
# stub の挙動:
#   - yamlcli --to-json <file> : 受け取ったパスを無視し、固定 JSON を出力する。
#   - jq -r --arg p <name> ... : .<p>.x11_css4_colors の "key=value" を出力する。
# stub は CONFIG_FILE 経由で渡されたパスに依存しないため、実 config は不要。
# ANSI エスケープは assert 前に sed で除去する。

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"

    OLD_PATH=$PATH
    TMPDIR_TEST="$(mktemp -d)"

    STUB_BIN="$TMPDIR_TEST/bin"
    mkdir -p "$STUB_BIN"

    # 2パレットを持つ固定の JSON を返す yamlcli stub。
    cat > "$STUB_BIN/yamlcli" <<'EOF'
#!/bin/bash
cat <<'JSON'
{
  "default": {
    "x11_css4_colors": {
      "almond": "#EFDECD",
      "blue": "#0000FF",
      "crimson": "#DC143C"
    }
  },
  "regmonkey_colors": {
    "x11_css4_colors": {
      "azureblue": "#428CE6",
      "white": "#FFFFFF"
    }
  }
}
JSON
EOF
    chmod +x "$STUB_BIN/yamlcli"

    # 実 jq があれば本物にフォワードする。無い環境向けに固定の minimal jq を置く。
    REAL_JQ="$(command -v jq || true)"
    if [ -n "$REAL_JQ" ]; then
        cat > "$STUB_BIN/jq" <<EOF
#!/bin/bash
exec "$REAL_JQ" "\$@"
EOF
        chmod +x "$STUB_BIN/jq"
    fi

    # CONFIG_FILE はダミーで良い（yamlcli stub がパスを無視するため）。
    # ただし読み取り可能チェックを通すために実在ファイルにする。
    DUMMY_CONFIG="$TMPDIR_TEST/color_config.yml"
    : > "$DUMMY_CONFIG"
    export CONFIG_FILE="$DUMMY_CONFIG"

    PATH="$STUB_BIN:$DIR/../../bin/utils:$PATH"

    # yamlcli/jq を欠いた最小 PATH（"command not found" を再現するため）。
    MIN_BIN="$TMPDIR_TEST/minbin"
    mkdir -p "$MIN_BIN"
    local cmd src
    for cmd in bash dirname cat printf env sed sort tr cut grep; do
        src="$(command -v "$cmd" || true)"
        [ -n "$src" ] && ln -sf "$src" "$MIN_BIN/$cmd"
    done
}

teardown() {
    PATH=$OLD_PATH
    rm -rf "$TMPDIR_TEST"
}

# ANSI カラーエスケープを除去して plain text にする。
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# ---------------------------------------------------------------------------
# help / version / option parsing
# ---------------------------------------------------------------------------

@test "help option -h prints docstring and exits 0" {
    run show-colors -h
    assert_success
    assert_output --partial 'Script: show-colors'
    assert_output --partial 'Usage:'
}

@test "help option --help prints docstring and exits 0" {
    run show-colors --help
    assert_success
    assert_output --partial 'Script: show-colors'
}

@test "version option -v prints package name and VERSION content" {
    run show-colors -v
    assert_success
    assert_output --partial 'regmonkey-shellutils'
}

@test "unknown option exits 1 with error" {
    run show-colors -x
    assert_failure
    assert_output --partial 'Error: unknown option: -x'
}

@test "-p without an argument exits 1" {
    run show-colors -p
    assert_failure
    assert_output --partial 'requires an argument'
}

@test "unknown palette exits 1 with valid-palette hint" {
    run show-colors -p bogus
    assert_failure
    assert_output --partial 'Error: unknown palette: bogus'
    assert_output --partial 'Valid palettes: default, regmonkey'
}

@test "unexpected positional argument exits 1" {
    run show-colors foo
    assert_failure
    assert_output --partial 'Error: unexpected argument: foo'
}

# ---------------------------------------------------------------------------
# rendering
# ---------------------------------------------------------------------------

@test "default palette renders header and all default colors" {
    run show-colors
    assert_success
    output="$(printf '%s\n' "$output" | strip_ansi)"
    assert_line --index 0 --partial 'Color Name'
    assert_line --index 0 --partial 'Hex'
    # default パレットの3色がすべて出力される。
    assert_output --partial 'almond'
    assert_output --partial 'blue'
    assert_output --partial 'crimson'
    assert_output --partial '#EFDECD'
}

@test "default palette does not include regmonkey-only colors" {
    run show-colors
    assert_success
    output="$(printf '%s\n' "$output" | strip_ansi)"
    refute_output --partial 'azureblue'
}

@test "-p regmonkey renders the regmonkey palette" {
    run show-colors -p regmonkey
    assert_success
    output="$(printf '%s\n' "$output" | strip_ansi)"
    assert_output --partial 'azureblue'
    assert_output --partial '#428CE6'
    assert_output --partial 'white'
    refute_output --partial 'almond'
}

@test "--palette long option works the same as -p" {
    run show-colors --palette regmonkey
    assert_success
    output="$(printf '%s\n' "$output" | strip_ansi)"
    assert_output --partial 'azureblue'
}

@test "names are colored with truecolor ANSI escapes" {
    run show-colors
    assert_success
    # almond #EFDECD -> 239;222;205
    assert_output --partial $'\033[38;2;239;222;205m'
}

@test "colors are sorted by name" {
    run show-colors
    assert_success
    output="$(printf '%s\n' "$output" | strip_ansi)"
    # almond < blue < crimson; mid=2 なので左列に almond,blue・右列に crimson。
    # 行頭の名前だけ拾って順序を確認する。
    local names
    names="$(printf '%s\n' "$output" | grep -oE '\| [a-z]+ ' | tr -d '| ' | head -3)"
    assert_equal "$names" "$(printf 'almond\ncrimson\nblue')"
}

# ---------------------------------------------------------------------------
# JSON export
# ---------------------------------------------------------------------------

@test "--json exports the default palette as valid JSON" {
    run show-colors --json
    assert_success
    # 着色エスケープを含まない（テーブルではなく JSON）。
    refute_output --partial $'\033['
    # jq でパースでき、期待する key=value を持つ。
    echo "$output" | jq -e '.almond == "#EFDECD"'
    echo "$output" | jq -e '.crimson == "#DC143C"'
}

@test "-j is the short form of --json" {
    run show-colors -j
    assert_success
    echo "$output" | jq -e '.blue == "#0000FF"'
}

@test "--json honors the selected palette" {
    run show-colors -p regmonkey --json
    assert_success
    echo "$output" | jq -e '.azureblue == "#428CE6"'
    echo "$output" | jq -e 'has("almond") | not'
}

@test "--json output has keys sorted" {
    run show-colors --json
    assert_success
    local keys sorted
    keys="$(echo "$output" | jq -r 'keys_unsorted[]')"
    sorted="$(printf '%s\n' "$keys" | sort)"
    assert_equal "$keys" "$sorted"
}

# ---------------------------------------------------------------------------
# dependency / config errors
# ---------------------------------------------------------------------------

@test "missing config file exits 1" {
    export CONFIG_FILE="$TMPDIR_TEST/does-not-exist.yml"
    run show-colors
    assert_failure
    assert_output --partial 'cannot read config file'
}

@test "missing yamlcli dependency exits 1" {
    # yamlcli/jq を持たない最小 PATH にスクリプト本体だけを足す。
    PATH="$MIN_BIN:$DIR/../../bin/utils"
    run show-colors
    assert_failure
    assert_output --partial 'required command not found: yamlcli'
}
