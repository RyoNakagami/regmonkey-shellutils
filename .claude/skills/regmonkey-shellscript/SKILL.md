---
name: regmonkey-shellscript
description: regmonkey-shellutils リポジトリに新しい shellscript を追加する skill．docstring 遵守 / lib 利用 / bats unit test 付き，Plan→Code の承諾フロー．
---

# regmonkey-shellscript

このリポジトリ（`regmonkey-shellutils`）の `script/` 配下に新しい shellscript を 1 本追加し，対応する bats ユニットテストまで揃えるための skill．

## When to use

ユーザーが以下のような依頼をしたとき，この skill を発動する:

- 「`script/` に新しい shellscript を追加して」
- 「`<name>` という script を作って」
- 「[script/pdftrim](script/pdftrim) みたいなのを作って」

逆に，既存 script の挙動修正・バグ修正のみの依頼ではこの skill を発動しない．

## Workflow: Plan → (Ask) → Code → Verify

> **重要**: Plan 提示後，必ず `AskUserQuestion` でユーザー承諾を得てから Code 段階に進む．承諾無しでファイルを書き出さない．

### Step 0: 環境確認（黙って実行）

- `git rev-parse --show-toplevel` でリポジトリ直下にいることを確認する．
- `lib/docstring.sh`，`test/test_for_script/`，`test/bats/bin/bats`，`test/test_helper/bats-{support,assert}/` が存在することを確認．
- 既存 script の流儀を 1〜2 本だけ参照する（例: [script/fast-du](script/fast-du), [script/generate-random-passwd](script/generate-random-passwd), [script/pdftrim](script/pdftrim)）．新しいファイルを乱読しない．

### Step 1: Plan を立てる

以下を埋めた "Plan" をユーザーに 1 メッセージで提示する．

| 項目 | 内容 |
| --- | --- |
| script パス | `script/<name>`（kebab-case，拡張子なし，既存と衝突しないこと） |
| 概要 (Description) | 1〜3 行 |
| Steps | docstring の Steps 節に書く番号付き手順 |
| Options | `-h` 以外に必要なフラグと意味 |
| 引数 | 位置引数の数と型 |
| Usage 例 | 想定する呼び出しサンプル 1〜3 行 |
| 外部依存コマンド | `gs` / `jq` / `curl` 等．`command -v` で存在確認するか |
| バリデーション項目 | 入力存在 / 出力衝突 / 引数型 / 範囲 など |
| Notes | エッジケース・前提条件 |
| ユニットテスト観点 | bats で検証する `@test` のタイトル列挙（最低 3 観点） |

最低限の `@test` 観点（これ未満なら Plan として不十分）:

1. `-h` で docstring が表示され `assert_success`
2. 入力不足 / 不正引数で `assert_failure` + メッセージ確認（複数項目）
3. ハッピーパス：期待ファイル生成または期待出力（外部副作用は fixture で sandbox 化）

### Step 2: ユーザー承諾を取る

`AskUserQuestion` で「この内容で実装して良いか」を問う．選択肢例:

- 「OK，このまま実装」
- 「項目を修正して再 Plan」
- 「キャンセル」

`OK` 以外なら Step 1 に戻る．承諾を得るまで Code に進まない．

### Step 3: Code（script 本体生成）

`bin/<category>/<name>` を以下のテンプレートで生成する．`Revised:` は本日の日付（system context の currentDate）を YYYY-MM-DD で入れる．

```bash
#!/bin/bash
# -----------------------------------------------------------------------------
# Author: Ryo Nakagami
# Revised: YYYY-MM-DD
# Script: <name>
# Description:
#   <1〜3 行の概要>
#
#   Steps:
#     1. <step1>
#     2. <step2>
#     ...
#
# Options:
#    -<flag> <arg>  <意味>
#    -h             Show this help message
#
# Usage:
#   ./<name> <args>
#
# Notes:
#   - <依存コマンド・前提条件>
#   - Sources '../lib/docstring.sh' for usage_helper.
# -----------------------------------------------------------------------------

set -euo pipefail

# ---- Load dependencies ----
source "$(dirname "${BASH_SOURCE[0]}")/../lib/docstring.sh"

# ---- Default values ----
# (variables initialized here)

# ---- Parse options ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h)
      usage_helper
      exit 0
      ;;
    -*)
      echo "Error: unknown option: $1" >&2
      usage_helper
      exit 1
      ;;
    *)
      # positional handling
      shift
      ;;
  esac
done

# ---- Validate ----
# (existence / type / range checks; print "Error: ..." to stderr and exit 1)

# ---- Run ----
# (実装本体)
```

**遵守ルール**:

- `set -euo pipefail` を必ず付ける．
- `lib/docstring.sh` を必ず source する．`-h` は `usage_helper` を呼ぶだけにする（再実装しない）．
- 既存 lib に同等のヘルパがあれば再利用する．汎用化できる新ヘルパが出てきたら `lib/` に追加して両方から source する（script 内に閉じ込めない）．
- エラーは `stderr` に `Error: <理由>` の形で出す．終了コードは非ゼロ．
- バリデーション順序: 依存コマンド存在 → 入力存在/読取可能 → 引数型/範囲 → 出力衝突（`-y`/`--force` で許可）．
- docstring の `Description / Options / Usage / Notes` を欠かない．
- 余計なコメントは書かない（理由が非自明な箇所のみ）．

生成後に `chmod +x script/<name>` を実行する．

### Step 4: Code（bats テスト生成）

`test/test_for_script/test_<name>.bats` を以下の骨格で生成する．

```bash
#!/usr/bin/env bats

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
  DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"

  OLD_PATH=$PATH
  PATH="$DIR/../../script:$PATH"

  # fixture が必要なら mktemp で sandbox を作る
  TMPDIR_TEST="$(mktemp -d)"
}

teardown() {
  PATH=$OLD_PATH
  rm -rf "$TMPDIR_TEST"
}

@test "help option prints docstring and exits 0" {
  run <name> -h
  assert_success
  assert_output --partial 'Script: <name>'
  assert_output --partial 'Usage:'
}

# バリデーション失敗系を 1 つ以上
@test "<failure case>" {
  run <name> <bad args>
  assert_failure
  assert_output --partial '<期待メッセージの一部>'
}

# ハッピーパス
@test "<happy path>" {
  run <name> <good args>
  assert_success
  # 期待出力 / 期待ファイル / 副作用を検証
}
```

**遵守ルール**:

- ファイル名は `test_<script名>.bats`．`<script名>` は script ファイル名そのまま（拡張子なし）．
- `setup` で `PATH` に `script/` を足し，`teardown` で復元．
- 外部副作用（ファイル生成，ネットワーク等）は `mktemp -d` の sandbox に閉じ込める．テスト後 `rm -rf` する．
- 外部 API を叩く場合は，参考先 [test/test_for_script/test_fetch-globalip.bats](test/test_for_script/test_fetch-globalip.bats) のようにヘッダコメントで「要インターネット接続」を明記．
- バイナリ系（PDF, 画像）の検証は，生成ツール自身（例: `gs`）で fixture を作ってから検証するのが軽い．

### Step 5: Verify（テスト実行）

```bash
./test/bats/bin/bats test/test_for_script/test_<name>.bats
```

- 全 PASS を確認するまで完了報告しない．
- 失敗した場合，原因（script 側 / test 側）を切り分けて修正し再実行する．テストを甘くして PASS させない（assertion を削る / `--partial` を空文字にする等は禁止）．

### Step 6: 報告

最終出力は短く:

- 作成ファイル（markdown link 形式で `[script/<name>](script/<name>)` と `[test/test_for_script/test_<name>.bats](test/test_for_script/test_<name>.bats)`）
- bats 結果サマリ（`N tests, N passed`）

## Rules（全体の制約）

1. **Plan → Ask → Code** の順序を絶対に崩さない．Plan の前にファイル書き出しを始めない．
2. **docstring フォーマット**: `Author / Revised / Script / Description / Steps / Options / Usage / Notes` を欠かない．`Revised` は当日日付．
3. **lib を使う**: `lib/docstring.sh` を必ず source する．汎用化可能な処理は新ヘルパを `lib/` に追加してそこから取り込む．
4. **bats 必須**: テスト無しの完了は許容しない．最低 3 観点（help / failure / happy path）．
5. **既存ファイル上書き禁止**: `script/<name>` または `test/test_for_script/test_<name>.bats` が既に存在する場合，ユーザーに別名 or 上書き許可を確認する．
6. **依存コマンド**: `gs` / `jq` のような外部ツール依存がある場合，script 内で `command -v` チェックし，テスト側でも未インストール環境を想定するか前提を明記する．
7. **テストを甘くしない**: PASS させるために assertion を緩めない．失敗したら実装を直す．
8. **既存スタイルを優先**: 命名・コメント・オプション解析のスタイルは既存 script（[script/fast-du](script/fast-du), [script/generate-random-passwd](script/generate-random-passwd), [script/pdftrim](script/pdftrim)）を参考にする．

## References（参考にする既存ファイル）

- 共通 helper: [lib/docstring.sh](lib/docstring.sh)
- script 例: [script/fast-du](script/fast-du), [script/generate-random-passwd](script/generate-random-passwd), [script/pdftrim](script/pdftrim)
- bats 例: [test/test_for_script/test_pdftrim.bats](test/test_for_script/test_pdftrim.bats), [test/test_for_script/test_fetch-globalip.bats](test/test_for_script/test_fetch-globalip.bats), [test/test_for_script/test_bazaar-zen.bats](test/test_for_script/test_bazaar-zen.bats)
- bats runner: `./test/bats/bin/bats`
- bats helpers: `test/test_helper/bats-support/`, `test/test_helper/bats-assert/`
