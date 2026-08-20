#!/usr/bin/env bats

# codex は CODEX_BIN 経由の stub に差し替えて決定的にテストする。
# config は実ファイルのフィクスチャを CONFIG_FILE で渡し、yamlcli/jq は
# 本物を使う。これにより「codex=利用可否 / config=単価」の結合ロジックを
# そのまま検証できる。
#
# フィクスチャの意図:
#   - available-priced : codex にあり単価もある
#   - available-partial: codex にあるが一部の単価キーが無い
#   - available-nocost : codex にあるが config に無い（price が空）
#   - available-partial-unit : cost_type で単位を上書きするモデル
#   - hidden-model     : visibility=hide（-a 指定時のみ出る）
#   - priced-only      : config にあるが codex に無い（一覧に出ない）

setup() {
    load '../test_helper/bats-support/load'
    load '../test_helper/bats-assert/load'
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"
    REPO="$DIR/../.."

    OLD_PATH=$PATH
    TMPDIR_TEST="$(mktemp -d)"
    STUB_BIN="$TMPDIR_TEST/bin"
    mkdir -p "$STUB_BIN"

    # codex stub。'debug models --bundled' に固定 JSON を返し、渡された
    # 引数を argv ファイルへ記録する。
    CODEX_ARGV_FILE="$TMPDIR_TEST/codex.argv"
    export CODEX_ARGV_FILE
    cat > "$STUB_BIN/codex" <<'STUB'
#!/bin/bash
: > "${CODEX_ARGV_FILE}"
for a in "$@"; do
    printf '%s\n' "$a" >> "${CODEX_ARGV_FILE}"
done
cat <<'JSON'
{"models":[
  {"slug":"available-priced","display_name":"Available Priced","visibility":"list"},
  {"slug":"available-partial","display_name":"Available Partial","visibility":"list"},
  {"slug":"available-nocost","display_name":"Available NoCost","visibility":"list"},
  {"slug":"available-partial-unit","display_name":"Odd Unit","visibility":"list"},
  {"slug":"hidden-model","display_name":"Hidden Model","visibility":"hide"}
]}
JSON
STUB
    chmod +x "$STUB_BIN/codex"

    # 単価フィクスチャ。OpenAI 型の short/long ネスト構造。
    FIXTURE_CONFIG="$TMPDIR_TEST/agent_model_cost.yml"
    cat > "$FIXTURE_CONFIG" <<'YAML'
openai:
  unit: "USD / 1M tokens"
  source: "https://example.test/openai-pricing"
  retrieved: "2026-08-20"
  pricing_tier: "standard"
  models:
    available-priced:
      display: "Available Priced"
      short:
        input: 5.00
        cached_input: 0.075
        cache_write: 6.25
        output: 30.00
      long:
        input: 10.00
        output: 45.00
    available-partial:
      display: "Available Partial"
      short:
        input: 2.00
        output: 12.00
    available-partial-unit:
      display: "Odd Unit"
      cost_type: "USD / 1K images"
      short:
        input: 9.00
    priced-only:
      display: "Priced Only"
      short:
        input: 1.00
        output: 2.00
anthropic:
  source: "https://example.test/anthropic-pricing"
  retrieved: null
  pricing_tier: "standard"
  models: {}
YAML
    export CONFIG_FILE="$FIXTURE_CONFIG"

    PATH="$STUB_BIN:$REPO/bin/agent:$PATH"
}

teardown() {
    PATH=$OLD_PATH
    rm -rf "$TMPDIR_TEST"
}

# ---------------------------------------------------------------------------
# Help / version
# ---------------------------------------------------------------------------

@test "help (-h) prints docstring and exits 0" {
    run ls-agent-model -h
    assert_success
    assert_output --partial 'Script: ls-agent-model'
    assert_output --partial 'Options:'
}

@test "help (--help) prints docstring and exits 0" {
    run ls-agent-model --help
    assert_success
    assert_output --partial 'Script: ls-agent-model'
}

@test "version (-v) prints package version" {
    run ls-agent-model -v
    assert_success
    assert_output --partial 'regmonkey-shellutils'
}

# ---------------------------------------------------------------------------
# Default listing
# ---------------------------------------------------------------------------

@test "default lists visible slugs only, one per line" {
    run ls-agent-model
    assert_success
    assert_line --index 0 'available-priced'
    assert_line --index 1 'available-partial'
    assert_line --index 2 'available-nocost'
    refute_output --partial 'hidden-model'
}

@test "default invokes codex with 'debug models --bundled'" {
    run ls-agent-model
    assert_success
    run cat "$CODEX_ARGV_FILE"
    assert_line --index 0 'debug'
    assert_line --index 1 'models'
    assert_line --index 2 '--bundled'
}

@test "config priced-only model is not listed (codex decides availability)" {
    run ls-agent-model
    assert_success
    refute_output --partial 'priced-only'
}

@test "-a includes hidden models" {
    run ls-agent-model -a
    assert_success
    assert_output --partial 'hidden-model'
}

@test "default output is plain slugs with no pricing metadata" {
    run ls-agent-model
    assert_success
    refute_output --partial 'pricing_tier'
    refute_output --partial 'https://'
}

# ---------------------------------------------------------------------------
# JSON output — prices
# ---------------------------------------------------------------------------

@test "--json lists the same visible slugs as the default output" {
    run bash -c 'ls-agent-model --json | jq -r ".models[].slug"'
    assert_success
    assert_line --index 0 'available-priced'
    assert_line --index 1 'available-partial'
    assert_line --index 2 'available-nocost'
    refute_output --partial 'hidden-model'
}

@test "--json excludes hidden models" {
    run bash -c 'ls-agent-model --json | jq ".models | length"'
    assert_success
    assert_output '4'
}

@test "-aj includes hidden models" {
    run bash -c 'ls-agent-model -aj | jq ".models | length"'
    assert_success
    assert_output '5'
}

@test "--json returns the config price structure verbatim" {
    # short/long のネストをそのまま返すこと（正規化しない）。
    run bash -c 'ls-agent-model --json | jq -c ".models[] | select(.slug == \"available-priced\") | .price | keys"'
    assert_success
    assert_output '["long","short"]'
}

@test "--json preserves a sub-cent price exactly" {
    run bash -c 'ls-agent-model --json | jq ".models[] | select(.slug == \"available-priced\") | .price.short.cached_input == 0.075"'
    assert_success
    assert_output 'true'
}

@test "--json omits price keys absent from config rather than nulling them" {
    # available-partial は cache_write と long を持たない。
    run bash -c 'ls-agent-model --json | jq -c ".models[] | select(.slug == \"available-partial\") | [(.price.short | has(\"cache_write\")), (.price | has(\"long\"))]"'
    assert_success
    assert_output '[false,false]'
}

@test "--json keeps a codex model that has no config entry, with empty price" {
    run bash -c 'ls-agent-model --json | jq ".models[] | select(.slug == \"available-nocost\") | .price | length"'
    assert_success
    assert_output '0'
}

@test "--json falls back to the codex display_name when config has no display" {
    run bash -c 'ls-agent-model --json | jq -r ".models[] | select(.slug == \"available-nocost\") | .display"'
    assert_success
    assert_output 'Available NoCost'
}

@test "--json prefers the config display name over the codex one" {
    run bash -c 'ls-agent-model --json | jq -r ".models[] | select(.slug == \"available-priced\") | .display"'
    assert_success
    assert_output 'Available Priced'
}

# ---------------------------------------------------------------------------
# JSON output — pricing provenance (tier / retrieved / source)
# ---------------------------------------------------------------------------

@test "--json reports the pricing tier verbatim from config" {
    run bash -c 'ls-agent-model --json | jq -r ".pricing_tier"'
    assert_success
    assert_output 'standard'
}

@test "--json reports a non-standard tier verbatim" {
    cat > "$TMPDIR_TEST/batch.yml" <<'YAML'
openai:
  pricing_tier: "batch"
  models:
    available-priced: {input: 1.0}
YAML
    CONFIG_FILE="$TMPDIR_TEST/batch.yml" run bash -c 'ls-agent-model --json | jq -r ".pricing_tier"'
    assert_success
    assert_output 'batch'
}

@test "--json reports the retrieval date" {
    run bash -c 'ls-agent-model --json | jq -r ".retrieved"'
    assert_success
    assert_output '2026-08-20'
}

@test "--json reports the source URL" {
    run bash -c 'ls-agent-model --json | jq -r ".source"'
    assert_success
    assert_output 'https://example.test/openai-pricing'
}

@test "--json reports null provenance when config omits it" {
    cat > "$TMPDIR_TEST/nometa.yml" <<'YAML'
openai:
  models:
    available-priced: {input: 1.0}
YAML
    CONFIG_FILE="$TMPDIR_TEST/nometa.yml" run bash -c 'ls-agent-model --json | jq -c "[.pricing_tier, .retrieved, .source]"'
    assert_success
    assert_output '[null,null,null]'
}

# ---------------------------------------------------------------------------
# Price unit (cost_type) — provider default with per-model override
# ---------------------------------------------------------------------------

@test "--json resolves cost_type from the provider unit by default" {
    run bash -c 'ls-agent-model --json | jq -r ".models[] | select(.slug == \"available-priced\") | .cost_type"'
    assert_success
    assert_output 'USD / 1M tokens'
}

@test "--json lets a model override the unit with its own cost_type" {
    run bash -c 'ls-agent-model --json | jq -r ".models[] | select(.slug == \"available-partial-unit\") | .cost_type"'
    assert_success
    assert_output 'USD / 1K images'
}

@test "--json keeps cost_type out of the price object" {
    # cost_type は単位のメタ情報であって単価ではないので price に混ぜない。
    run bash -c 'ls-agent-model --json | jq -c ".models[] | select(.slug == \"available-partial-unit\") | .price"'
    assert_success
    assert_output '{"short":{"input":9.0}}'
}

@test "--json reports a null cost_type when neither unit nor override is set" {
    cat > "$TMPDIR_TEST/nounit.yml" <<'YAML'
openai:
  models:
    available-priced:
      short: {input: 1.0}
YAML
    CONFIG_FILE="$TMPDIR_TEST/nounit.yml" run bash -c 'ls-agent-model --json | jq -r ".models[] | select(.slug == \"available-priced\") | .cost_type"'
    assert_success
    assert_output 'null'
}

# ---------------------------------------------------------------------------
# Provider-specific price shapes
#
# 価格構造は解釈せず config のまま返すため、プロバイダごとに形が違ってよい。
# ---------------------------------------------------------------------------

@test "--json passes through a flat Anthropic-shaped price structure" {
    cat > "$TMPDIR_TEST/flat.yml" <<'YAML'
openai:
  unit: "USD / 1M tokens"
  source: "https://example.test/flat"
  retrieved: "2026-01-02"
  pricing_tier: "standard"
  models:
    available-priced:
      input: 5.00
      output: 25.00
YAML
    CONFIG_FILE="$TMPDIR_TEST/flat.yml" run bash -c 'ls-agent-model --json | jq -c ".models[] | select(.slug == \"available-priced\") | .price"'
    assert_success
    assert_output '{"input":5.0,"output":25.0}'
}

# ---------------------------------------------------------------------------
# Real config
# ---------------------------------------------------------------------------

@test "real config records tier, retrieval date, and source for openai" {
    REAL_CONFIG="$REPO/bin/agent/config/agent_model_cost.yml"
    run bash -c "yamlcli --to-json '$REAL_CONFIG' | jq -r '.openai | [.pricing_tier, .retrieved, (.source|tostring)] | join(\"|\")'"
    assert_success
    assert_output --regexp '^standard\|[0-9]{4}-[0-9]{2}-[0-9]{2}\|https://'
}

@test "real config declares a default price unit for every provider" {
    REAL_CONFIG="$REPO/bin/agent/config/agent_model_cost.yml"
    run bash -c "yamlcli --to-json '$REAL_CONFIG' | jq -r 'to_entries[] | .value.unit'"
    assert_success
    assert_line --index 0 'USD / 1M tokens'
    assert_line --index 1 'USD / 1M tokens'
}

@test "real config resolves a cost_type onto every listed model" {
    run bash -c 'ls-agent-model --json | jq -r "[.models[] | select(.cost_type == null)] | length"'
    assert_success
    assert_output '0'
}

@test "real config declares an anthropic section for future --claude support" {
    REAL_CONFIG="$REPO/bin/agent/config/agent_model_cost.yml"
    run bash -c "yamlcli --to-json '$REAL_CONFIG' | jq -r '.anthropic | has(\"models\")'"
    assert_success
    assert_output 'true'
}

# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------

@test "--claude reports not implemented and fails" {
    run ls-agent-model --claude
    assert_failure
    assert_output --partial 'not implemented yet'
}

@test "--claude takes precedence over other options" {
    run ls-agent-model --claude --json
    assert_failure
    assert_output --partial 'not implemented yet'
}

@test "unknown option fails" {
    run ls-agent-model -Z
    assert_failure
    assert_output --partial 'unknown option'
}

@test "the removed -l option is rejected" {
    run ls-agent-model -l
    assert_failure
    assert_output --partial 'unknown option'
}

@test "unexpected positional argument fails" {
    run ls-agent-model foo
    assert_failure
    assert_output --partial 'unexpected argument'
}

@test "unreadable config file fails with a clear message" {
    CONFIG_FILE="$TMPDIR_TEST/does-not-exist.yml" run ls-agent-model --json
    assert_failure
    assert_output --partial 'cannot read config file'
}
