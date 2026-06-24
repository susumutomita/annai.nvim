# annai.nvim

> 「やりたいこと」を日本語で聞くと、**あなた自身の keymap** から該当するキーを
> オンデバイス LLM が選んで教えてくれる Neovim の案内役。
> 外部送信なし・API キー不要・追加プラグイン依存ゼロ。

*Ask your Neovim, in plain language, “how do I …?” — an **on-device** LLM answers
with a real keybinding picked from **your own keymaps**. No cloud, no API key,
no telemetry.*

「案内（あんない）」= guidance / reception desk.

<!-- デモ GIF を録ったら docs/demo.gif に置いてここで参照する -->
<!-- ![demo](docs/demo.gif) -->

## なぜ作ったか

キーマップは覚えられない。でも `which-key` のメニューを総当たりするのも面倒。
そこで **「やりたいことを言葉で言うと、設定済みのキーを 1 つ教えてくれる」** 入口を作りました。

- 渡すのは **あなたの keymap 一覧（説明文付き）＋ 質問** だけ。コードや開いているファイルは送りません。
- 一覧から **実在するキーを 1 つだけ選ばせる** プロンプト設計なので、存在しないショートカットを捏造しにくい（幻覚対策）。
- Apple のオンデバイス LLM（Foundation Models）を優先。無ければローカルの Ollama にフォールバック。**どちらも端末内で完結**します。

## 必要環境

バックエンドは上から順に「使えるもの」が選ばれます。**どちらか一方**あれば動きます。

| バックエンド | 必要なもの | 備考 |
| --- | --- | --- |
| `afm`（推奨・最速） | macOS 26+ / Apple Silicon / Apple Intelligence 有効 | 同梱の `afm/afm.swift` をビルド |
| `ollama`（フォールバック） | [Ollama](https://ollama.com) + 任意のモデル | 例: `ollama pull qwen2.5:3b` |

## インストール

### 1. （任意・推奨）afm をビルド

```sh
swiftc -O afm/afm.swift -o ~/.local/bin/afm
# 確認:  echo "ping と一言で返して" | afm
```

afm が無い場合は Ollama だけでも動きます（`ollama serve` を起動しておく）。

### 2. プラグインを追加（[lazy.nvim](https://github.com/folke/lazy.nvim)）

```lua
{
  "susumutomita/annai.nvim",
  event = "VeryLazy",
  opts = {
    -- すべて任意。既定のままでも動く。
    ollama = { model = "qwen2.5:3b" }, -- フォールバック時に使うモデル
    keymap = "<leader>?",              -- 起動キー（false で無効化）
  },
}
```

## 使い方

- `<leader>?`（または `:Annai`）を押す
- 「全文検索したい」「ファイラーと本文を行き来したい」などを **日本語で入力**
- 右下にフォーカスを奪わない小窓で答え（例: `Space fg — 全文検索`）が出る
- カーソルを動かす / 入力を始めると自動で閉じる

## 答えが違ったら：もう一度 `?` で詳しく

最初のバックエンド（既定は afm・最速）は、一覧に無い操作だと無理に 1 つ選ぶことがあります。**回答の小窓が出ている間にもう一度 `<leader>?` を押す**と、打ち直さずに同じ質問を次のバックエンド（より慎重な Ollama）へ回します。

- 1 回目: afm（速い）が即答。違っていそうなら…
- 2 回目（小窓が出たまま `?`）: 同じ質問を Ollama が答え直す（`置換` → `この設定には無い` など）
- 小窓は `— 違う？ もう一度 ? でじっくり聞く` とヒントを出すので、これも覚えなくて OK

打つキーは `?` だけ。新しいコマンドも引数も無し＝**速さ（afm 既定）と正確さ（必要なときだけ Ollama）の両取り**です。次のバックエンドが無いとき（afm だけ等）はヒントを出しません。

## 履歴とよく聞く操作（任意・既定 OFF）

annai は「答える」だけでなく、**あなたが繰り返し聞いている操作 = まだ指が覚えていないキー**を炙り出せます。最終目標は **annai 無しでも手が動くこと**。

`history.enabled = true` にすると、質問と回答を端末内の JSONL に記録します。

```vim
:Annai stats          " よく聞く操作の top5 を表示
:Annai history clear  " 履歴を消去
```

```
よく聞く操作 top3（指が覚えたら annai 卒業）:
 5回  Space fg — 全文検索
 3回  Space wl — 右の窓へ
 2回  Space e  — ファイルツリー開閉
```

### プライバシー

- **既定で無効（opt-in）**。`history.enabled = true` にした時だけ記録します。
- 記録先は **`stdpath("data")/annai/history.jsonl`（あなたの端末内のみ）**。外部には一切送りません。
- いつでも `:Annai history clear` で全消去できます。

## 設定

`setup(opts)`（lazy なら `opts`）で上書きできます。既定値は以下。

```lua
require("annai").setup({
  backends = { "afm", "ollama" }, -- 試す順番
  afm = { cmd = "afm" },
  ollama = {
    url = "http://localhost:11434/api/generate",
    model = "qwen2.5:3b",
  },
  keymap = "<leader>?",
  input_prompt = "やりたいこと: ",
  leader_display = nil, -- nil なら自動（space → "Space"）

  -- 履歴（よく聞く操作の炙り出し）。既定 OFF・端末内のみ。
  history = {
    enabled = false,
    path = nil, -- nil なら stdpath("data").."/annai/history.jsonl"
    max = 500,
  },
  stats_top = 5,
  more_hint = "— 違う？ もう一度 ? でじっくり聞く", -- エスカレーション導線のヒント

  -- LLM に渡す keymap を選ぶフィルタ（既定: leader 始まり & desc 付き）
  keymap_filter = function(map)
    local leader = vim.g.mapleader or "\\"
    return map.desc ~= nil and map.desc ~= "" and map.lhs:sub(1, #leader) == leader
  end,

  -- プロンプトの組み立て（英語圏向けに差し替え可）
  build_prompt = function(input, keymap_text, leader_label)
    -- ... 既定は日本語。lua/annai/init.lua を参照
  end,

  window = { anchor = "SE", max_width = 56, max_height = 12, border = "rounded", title = " 案内 " },
})
```

### 英語で使いたい場合

`keymap_filter` を「desc 付きの全マップ」に広げ、`build_prompt` を英語テンプレに差し替えるだけです。
モデルは Ollama の英語強めのもの（例: `llama3.2:3b`）を指定するとよいです。

## 仕組み

```
<leader>?  →  vim.ui.input で質問を受ける
           →  自分の keymap を走査（desc 付き & leader 始まり）
           →  「一覧 ＋ 質問」を 1 つのプロンプトに
           →  afm（あれば）/ Ollama に投げる
           →  返ってきた 1 行をフォーカスを奪わない小窓に表示
```

LLM は「一覧から 1 つ選ぶ」分類タスクしか任されていないため、3B 程度の小モデルでも十分・高速です。

## ライセンス

[MIT](./LICENSE)
