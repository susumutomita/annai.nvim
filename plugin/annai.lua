-- :Annai コマンドを登録する。setup() を呼んでいなくても既定設定で動くようにする。
-- （setup() は keymap の割り当てと opts のマージを追加で行う）
if vim.g.loaded_annai then
  return
end
vim.g.loaded_annai = true

vim.api.nvim_create_user_command("Annai", function()
  require("annai").ask()
end, { desc = "やりたいことを on-device LLM に聞く" })
