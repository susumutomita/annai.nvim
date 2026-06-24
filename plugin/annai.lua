-- :Annai コマンドを登録する。setup() を呼んでいなくても既定設定で動くようにする。
-- （setup() は keymap の割り当てと opts のマージを追加で行う）
--
--   :Annai                やりたいことを聞く
--   :Annai stats          よく聞く操作（まだ覚えていないキー）を表示
--   :Annai history clear  履歴を消去
if vim.g.loaded_annai then
  return
end
vim.g.loaded_annai = true

vim.api.nvim_create_user_command("Annai", function(o)
  require("annai").command(o.fargs)
end, {
  nargs = "*",
  desc = "やりたいことを on-device LLM に聞く（stats / history clear）",
  complete = function(arglead)
    local out = {}
    for _, s in ipairs({ "stats", "history" }) do
      if s:find(arglead, 1, true) == 1 then
        table.insert(out, s)
      end
    end
    return out
  end,
})
