-- Load the batch into the quickfix list. Pairs with sidekick.nvim's native
-- `{quickfix}` prompt variable: `:Sidekick cli send msg="{quickfix}"`.
return function(M)
  M.register("quickfix", function(payload)
    require("obelus.view").quickfix()
    vim.notify(
      "obelus: loaded " .. #payload.comments .. ' into quickfix — :Sidekick cli send msg="{quickfix}"',
      vim.log.levels.INFO
    )
  end)
end
