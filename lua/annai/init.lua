-- annai.nvim — 「やりたいこと」を日本語で聞くと、あなたの keymap から該当キーを
-- オンデバイス LLM が選んで教えてくれる案内役。外部送信なし・依存ゼロ。
--
-- 仕組み: 自分の keymap 一覧を文脈として渡し、その中から 1 つだけ選ばせる
--         （= 依存ゼロの軽量 RAG）。実在するキーしか答えられないので幻覚しにくい。
--
-- バックエンド: afm（Apple Foundation Models / オンデバイス）を優先し、
--               無ければ Ollama（localhost）にフォールバックする。
--
-- 履歴（任意・既定 OFF）: よく聞く操作を端末内に記録し、:Annai stats で
--                         「指がまだ覚えていないキー」を炙り出して定着を促す。

local M = {}

--------------------------------------------------------------------------------
-- 既定設定（setup(opts) で上書き可能）
--------------------------------------------------------------------------------
M.config = {
  -- 試すバックエンドの順番。先頭から「使える」ものが採用される。
  backends = { "afm", "ollama" },

  afm = {
    cmd = "afm", -- stdin→stdout の CLI（同梱の afm.swift をビルドした実行ファイル）
  },

  ollama = {
    url = "http://localhost:11434/api/generate",
    model = "qwen2.5:3b",
  },

  keymap = "<leader>?", -- 既定キー。false で無効化して自分で割り当ててもよい
  input_prompt = "やりたいこと: ",

  -- 履歴（よく聞く操作 = あなたの blind spot を炙り出す）。プライバシー優先で既定 OFF。
  history = {
    enabled = false, -- opt-in。true で記録開始
    path = nil, -- nil なら stdpath("data").."/annai/history.jsonl"（端末内のみ）
    max = 500, -- 保持する最大行数。超えたら古いものから破棄
  },
  stats_top = 5, -- :Annai stats で表示する上位件数

  -- LLM に渡す keymap を選ぶフィルタ。既定は「leader 始まり & desc 付き」。
  -- 英語/記号混じりだとオンデバイスモデルの言語判定が誤作動するため、
  -- 説明付きの自作キーだけに絞ると精度が安定する。
  keymap_filter = function(map)
    local leader = vim.g.mapleader or "\\"
    return map.desc ~= nil and map.desc ~= "" and map.lhs:sub(1, #leader) == leader
  end,

  -- leader の表示名。nil なら自動（space → "Space"）。
  leader_display = nil,

  -- プロンプト組み立て。入力・keymap 一覧・leader 表示名を受け取り文字列を返す。
  build_prompt = function(input, keymap_text, leader_label)
    return table.concat({
      "あなたは Neovim 操作ガイド。# キーマップ一覧 にある操作だけを根拠に答える。",
      "質問の意図に合う行が一覧にあれば、その 1 行だけを次の形式で答える:",
      leader_label .. " <キー> — <説明>",
      "合う操作が無ければ、推測で選ばず必ず「この設定には無い」とだけ答える。",
      "一覧に無いキーを創作してはいけない。前置き・補足・複数提示は禁止。",
      "",
      "# 例",
      "質問: ファイルを名前で開きたい",
      "回答: " .. leader_label .. " ff — ファイル名で検索",
      "質問: コンパイルしたい",
      "回答: この設定には無い",
      "",
      "# キーマップ一覧",
      keymap_text,
      "",
      "# 質問",
      input,
      "",
      "# 回答",
    }, "\n")
  end,

  window = {
    anchor = "SE", -- 右下に出す
    max_width = 56,
    max_height = 12,
    border = "rounded",
    title = " 案内 ",
  },
}

--------------------------------------------------------------------------------
-- フローティング窓（フォーカスを奪わない・操作で自動的に閉じる）
--------------------------------------------------------------------------------
local state = { win = nil }

local function close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
end

local function show(text)
  close()
  local w = M.config.window
  local lines = vim.split(text, "\n", { trimempty = false })
  local width = 24
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 2, w.max_width)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  state.win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    anchor = w.anchor,
    row = vim.o.lines - 2,
    col = vim.o.columns - 1,
    width = width,
    height = math.min(#lines, w.max_height),
    style = "minimal",
    border = w.border,
    focusable = false, -- フォーカスを奪わない
    title = w.title,
    title_pos = "center",
    noautocmd = true,
  })
  vim.wo[state.win].wrap = true
  -- カーソル移動 / 入力開始で自動的に閉じる（操作の邪魔をしない）
  vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter", "BufLeave" }, {
    once = true,
    callback = close,
  })
end

--------------------------------------------------------------------------------
-- keymap 収集
--------------------------------------------------------------------------------
local function leader_label()
  if M.config.leader_display then
    return M.config.leader_display
  end
  local leader = vim.g.mapleader or "\\"
  return leader == " " and "Space" or leader
end

local function collect_keymaps()
  local leader = vim.g.mapleader or "\\"
  local label = leader_label()
  local out = {}
  for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
    if M.config.keymap_filter(map) then
      table.insert(out, label .. " " .. map.lhs:sub(#leader + 1) .. " = " .. map.desc)
    end
  end
  return table.concat(out, "\n")
end

--------------------------------------------------------------------------------
-- バックエンド
--------------------------------------------------------------------------------
local backends = {}

backends.afm = {
  available = function()
    return vim.fn.executable(M.config.afm.cmd) == 1
  end,
  run = function(prompt, on_done)
    vim.system({ M.config.afm.cmd }, { stdin = prompt, text = true }, function(res)
      vim.schedule(function()
        local out = vim.trim(res.stdout or "")
        if res.code == 0 and out ~= "" then
          on_done(out)
        else
          local msg = vim.trim(res.stderr or "")
          on_done(nil, msg ~= "" and msg or "afm: 応答なし")
        end
      end)
    end)
  end,
}

backends.ollama = {
  available = function()
    return vim.fn.executable("curl") == 1
  end,
  run = function(prompt, on_done)
    local o = M.config.ollama
    local body = vim.json.encode({ model = o.model, prompt = prompt, stream = false })
    vim.system({ "curl", "-s", o.url, "-d", body }, { text = true }, function(res)
      vim.schedule(function()
        if res.code ~= 0 then
          on_done(nil, "Ollama に接続できません（ollama serve を起動してください）。")
          return
        end
        local ok, decoded = pcall(vim.json.decode, res.stdout)
        if not ok or type(decoded) ~= "table" then
          on_done(nil, "応答の解析に失敗しました。")
          return
        end
        if decoded.error then
          on_done(nil, "モデル未取得: ollama pull " .. o.model)
          return
        end
        on_done(vim.trim(decoded.response or ""))
      end)
    end)
  end,
}

local function pick_backend()
  for _, name in ipairs(M.config.backends) do
    local b = backends[name]
    if b and b.available() then
      return b
    end
  end
  return nil
end

--------------------------------------------------------------------------------
-- 履歴（端末内 JSONL に追記。よく聞く操作 = まだ指が覚えていないキーを炙り出す）
--------------------------------------------------------------------------------
local function history_path()
  return M.config.history.path or (vim.fn.stdpath("data") .. "/annai/history.jsonl")
end

local function read_history()
  local path = history_path()
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local entries = {}
  for _, line in ipairs(vim.fn.readfile(path)) do
    if line ~= "" then
      local ok, e = pcall(vim.json.decode, line)
      if ok and type(e) == "table" then
        table.insert(entries, e)
      end
    end
  end
  return entries
end

-- 1 回の回答を記録する。history.enabled が false なら何もしない（プライバシー優先）。
local function record(question, answer)
  if not M.config.history.enabled then
    return
  end
  local path = history_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ vim.json.encode({ q = question, a = answer, t = os.time() }) }, path, "a")
  local max = M.config.history.max
  if max and max > 0 then
    local lines = vim.fn.readfile(path)
    if #lines > max then
      vim.fn.writefile(vim.list_slice(lines, #lines - max + 1, #lines), path)
    end
  end
end

-- 回答ごとの出現回数を数え、多い順に上位 n 件を返す（純粋関数・テスト対象）。
local function top_answers(entries, n)
  local count, order = {}, {}
  for _, e in ipairs(entries) do
    local a = e.a
    if a and a ~= "" then
      if not count[a] then
        count[a] = 0
        table.insert(order, a)
      end
      count[a] = count[a] + 1
    end
  end
  table.sort(order, function(x, y)
    if count[x] ~= count[y] then
      return count[x] > count[y]
    end
    return x < y -- 同数は文字列順で安定させる
  end)
  local out = {}
  for i = 1, math.min(n, #order) do
    table.insert(out, { answer = order[i], count = count[order[i]] })
  end
  return out
end

--------------------------------------------------------------------------------
-- 公開 API
--------------------------------------------------------------------------------
function M.ask()
  vim.ui.input({ prompt = M.config.input_prompt }, function(input)
    if not input or input == "" then
      return
    end
    local backend = pick_backend()
    if not backend then
      show("利用可能なバックエンドがありません。\nafm をビルドするか Ollama を起動してください。")
      return
    end
    show("考え中...")
    local prompt = M.config.build_prompt(input, collect_keymaps(), leader_label())
    backend.run(prompt, function(answer, err)
      if answer then
        record(input, answer)
      end
      show(answer or ("エラー: " .. (err or "不明")))
    end)
  end)
end

-- よく聞く操作（= まだ覚えていないキー）を表示する。
function M.stats()
  if not M.config.history.enabled then
    show("履歴は無効です。\nsetup で history.enabled=true にすると、\nよく聞く操作を記録して表示します。")
    return
  end
  local top = top_answers(read_history(), M.config.stats_top)
  if #top == 0 then
    show("まだ履歴がありません。\n:Annai で何度か聞くと、ここに『よく聞く操作』が出ます。")
    return
  end
  local lines = { "よく聞く操作 top" .. #top .. "（指が覚えたら annai 卒業）:" }
  for _, item in ipairs(top) do
    table.insert(lines, string.format(" %d回  %s", item.count, item.answer))
  end
  show(table.concat(lines, "\n"))
end

function M.history_clear()
  local path = history_path()
  if vim.fn.filereadable(path) == 1 then
    vim.fn.delete(path)
  end
  show("履歴を消去しました。")
end

-- :Annai のサブコマンド振り分け
function M.command(args)
  local sub = args and args[1]
  if not sub then
    return M.ask()
  end
  if sub == "stats" then
    return M.stats()
  end
  if sub == "history" and args[2] == "clear" then
    return M.history_clear()
  end
  show("使い方:\n :Annai                やりたいことを聞く\n :Annai stats          よく聞く操作\n :Annai history clear  履歴を消去")
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  -- リスト/関数は index マージを避けて丸ごと差し替える
  if opts then
    if opts.backends then
      M.config.backends = opts.backends
    end
    if opts.keymap_filter then
      M.config.keymap_filter = opts.keymap_filter
    end
    if opts.build_prompt then
      M.config.build_prompt = opts.build_prompt
    end
  end
  if M.config.keymap then
    vim.keymap.set("n", M.config.keymap, M.ask, { desc = "やりたいことを LLM に聞く" })
  end
end

-- テスト用に内部関数を公開する（_ 始まりは内部 API の目印）
M._read_history = read_history
M._top_answers = top_answers
M._record = record
M._history_path = history_path

return M
