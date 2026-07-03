local config = require("obelus.config")

-- Interactive handoff: deliver the batch to a running CLI agent via sidekick.nvim.
return function(M)
  M.register("sidekick", function(payload)
    local ok, cli = pcall(require, "sidekick.cli")
    if not ok then
      return vim.notify("obelus: sidekick.nvim not available", vim.log.levels.ERROR)
    end
    local s = config.options.transport.sidekick or {}
    cli.send({ msg = payload.markdown, name = s.name })
    if s.focus and cli.focus then
      pcall(cli.focus, { name = s.name })
    end
    vim.notify("obelus: sent " .. #payload.comments .. " comment(s) to " .. (s.name or "agent"), vim.log.levels.INFO)
  end)
end
