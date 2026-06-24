-- annai.nvim — 「やりたいこと」を日本語で聞くと、あなたの keymap から該当キーを
-- オンデバイス LLM が選んで教えてくれる案内役。外部送信なし・依存ゼロ。
--
-- 仕組み: 自分の keymap 一覧を文脈として渡し、その中から 1 つだけ選ばせる
--         （= 依存ゼロの軽量 RAG）。実在するキーしか答えられないので幻覚しにくい。
--
-- バックエンド: afm（Apple Foundation Models / オンデバイス）を優先し、
--               無ければ Ollama（localhost）にフォールバックする。

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
  command = "Annai", -- ユーザコマンド名（plugin/annai.lua が登録）
  input_prompt = "やりたいこと: ",

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
      "あなたは Neovim 操作ガイド。下の一覧から質問に最も合う操作を 1 つだけ選ぶ。",
      "各行の説明文と質問を照合して選ぶこと。回答は必ず次の形式のみ:",
      leader_label .. " <キー> — <その操作の説明>",
      "一覧に該当が無ければ「この設定には無い」とだけ答える。前置き・補足は禁止。",
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
      show(answer or ("エラー: " .. (err or "不明")))
    end)
  end)
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

return M
