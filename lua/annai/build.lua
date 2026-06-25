-- afm（Apple Foundation Models CLI）を端末上でビルドする。
-- lazy.nvim の build フィールドから呼ぶ:
--   build = function() require("annai.build").afm() end
--
-- macOS + swiftc がある時だけビルドし、それ以外（Linux/Windows、CLT 無し）は
-- 黙ってスキップする。こうすることで、afm が無い環境でも install が失敗せず、
-- Ollama バックエンドだけで動く。

local M = {}

-- このプラグインのルート（…/lua/annai/build.lua から 3 つ上）を返す。
-- lazy が build をどの cwd で実行しても afm.swift を確実に解決できるようにする。
local function plugin_root()
  local this = debug.getinfo(1, "S").source:sub(2) -- 先頭の @ を除く
  return vim.fn.fnamemodify(this, ":h:h:h")
end

-- afm をビルドする。成功で true、スキップ/失敗で false。
-- opts.out で出力先を変更可（既定 ~/.local/bin/afm）。
function M.afm(opts)
  opts = opts or {}
  local out = opts.out or vim.fn.expand("~/.local/bin/afm")

  if vim.fn.has("mac") ~= 1 then
    vim.notify("[annai] afm は macOS 専用のためスキップ（Ollama で動作します）", vim.log.levels.INFO)
    return false
  end
  if vim.fn.executable("swiftc") ~= 1 then
    vim.notify(
      "[annai] swiftc が見つからないため afm をスキップ（xcode-select --install / Ollama で動作します）",
      vim.log.levels.WARN
    )
    return false
  end

  local src = plugin_root() .. "/afm/afm.swift"
  if vim.fn.filereadable(src) ~= 1 then
    vim.notify("[annai] afm.swift が見つかりません: " .. src, vim.log.levels.ERROR)
    return false
  end

  vim.fn.mkdir(vim.fn.fnamemodify(out, ":h"), "p")
  local result = vim.fn.system({ "swiftc", "-O", src, "-o", out })
  if vim.v.shell_error ~= 0 then
    vim.notify("[annai] afm のビルドに失敗しました:\n" .. result, vim.log.levels.ERROR)
    return false
  end

  vim.notify("[annai] afm をビルドしました: " .. out .. "（~/.local/bin を PATH に通してください）", vim.log.levels.INFO)
  return true
end

-- テスト用に内部関数を公開する
M._plugin_root = plugin_root

return M
