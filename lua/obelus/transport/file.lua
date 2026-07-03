local config = require("obelus.config")
local store = require("obelus.store")

-- Write the batch to a markdown file in the project (e.g. for an agent skill
-- or a file-mediated review loop to pick up).
return function(M)
  M.register("file", function(payload)
    local rel = (config.options.transport.file or {}).path or ".ai/review.md"
    local path = store.root() .. "/" .. rel
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile(vim.split(payload.markdown, "\n"), path)
    vim.notify("obelus: wrote " .. rel, vim.log.levels.INFO)
  end)
end
