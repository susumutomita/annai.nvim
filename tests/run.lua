-- annai.nvim 履歴・統計ロジックのテスト（UI を開かない純粋ロジックだけ検証）。
-- 実行: nvim --headless -l tests/run.lua   （リポジトリ root から）

vim.opt.runtimepath:prepend(vim.fn.getcwd())
local annai = require("annai")

local function assert_eq(got, want, msg)
  if got ~= want then
    error(string.format("FAIL %s: got=%s want=%s", msg, vim.inspect(got), vim.inspect(want)))
  end
end

local tmp = vim.fn.tempname() .. "/history.jsonl"
annai.setup({ history = { enabled = true, path = tmp, max = 100 }, keymap = false })

-- 記録する（同じ回答を 2 回 + 別の回答 1 回）
annai._record("ぜんぶ検索したい", "Space fg — 全文検索")
annai._record("全文を探す", "Space fg — 全文検索")
annai._record("右の窓へ行きたい", "Space wl — 右の窓へ")

local entries = annai._read_history()
assert_eq(#entries, 3, "history line count")

local top = annai._top_answers(entries, 5)
assert_eq(top[1].answer, "Space fg — 全文検索", "top1 answer")
assert_eq(top[1].count, 2, "top1 count")
assert_eq(top[2].answer, "Space wl — 右の窓へ", "top2 answer")
assert_eq(top[2].count, 1, "top2 count")

-- history.enabled=false のときは記録しない（プライバシー）
annai.setup({ history = { enabled = false, path = tmp } })
annai._record("記録されないはず", "Space ff — ファイル名で検索")
annai.setup({ history = { enabled = true, path = tmp } })
assert_eq(#annai._read_history(), 3, "disabled record is a no-op")

-- 消去（show は UI なので pcall で包む。delete は show より前に走る）
pcall(annai.history_clear)
assert_eq(vim.fn.filereadable(tmp), 0, "history file removed")
assert_eq(#annai._read_history(), 0, "history empty after clear")

-- 空履歴のとき top は空配列
assert_eq(#annai._top_answers({}, 5), 0, "empty history => empty top")

-- エスカレーション: replace_last は直前の行を上書き（同じ質問の最終回答だけ残す＝二重カウント防止）
local tmp2 = vim.fn.tempname() .. "/history.jsonl"
annai.setup({ history = { enabled = true, path = tmp2 }, keymap = false })
annai._record("置換したい", "Space e — ファイルツリー開閉") -- afm の誤答
annai._record("置換したい", "この設定には無い", true) -- Ollama で聞き直して上書き
local esc = annai._read_history()
assert_eq(#esc, 1, "escalation replaces the last record")
assert_eq(esc[1].a, "この設定には無い", "final answer is kept after escalation")

-- pick_backend は from_idx 以降の最初の利用可能を返す（escalation の停止条件）
annai.setup({ backends = { "ollama" }, keymap = false }) -- curl は CI にもある = ollama 利用可
local b1, i1 = annai._pick_backend(1)
assert(b1 ~= nil and i1 == 1, "ollama available at index 1")
assert(annai._pick_backend(2) == nil, "no backend beyond the last (escalation stops)")

print("OK: annai history/stats/escalation tests passed")
