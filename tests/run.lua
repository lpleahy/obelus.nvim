-- Headless test runner. Invoked by `make test`:
--   nvim --headless -u NONE -i NONE -c "luafile tests/run.lua"
-- Loads every *_spec.lua, tallies results, and sets the process exit code.
local src = debug.getinfo(1, "S").source:sub(2)
local testdir = vim.fn.fnamemodify(src, ":p:h")
local root = vim.fn.fnamemodify(testdir, ":h")
vim.opt.runtimepath:append(root)
package.path = testdir .. "/?.lua;" .. package.path

-- Optional extra runtimepath (markview.nvim, nvim-treesitter, render-markdown.nvim, …)
-- so the renderer-plugin specs can run:
--   OBELUS_TEST_RTP=/abs/markview.nvim:/abs/nvim-treesitter make test
-- With no OBELUS_TEST_RTP, fall back to the usual lazy.nvim install dirs when they
-- exist — a plain `make test` on a dev machine then still runs the renderer specs
-- (the most bug-prone integrations) instead of silently skipping them.
local extra = vim.env.OBELUS_TEST_RTP
if not extra or extra == "" then
  local lazy = vim.fn.stdpath("data") .. "/lazy"
  local found = {}
  for _, name in ipairs({ "markview.nvim", "nvim-treesitter", "render-markdown.nvim" }) do
    if vim.fn.isdirectory(lazy .. "/" .. name) == 1 then
      found[#found + 1] = lazy .. "/" .. name
    end
  end
  extra = table.concat(found, ":")
end
for _, p in ipairs(vim.split(extra, ":", { plain = true })) do
  if p ~= "" then
    vim.opt.runtimepath:append(p)
  end
end

local ok_h, T = pcall(require, "helpers")
if not ok_h then
  io.write("FATAL: could not load tests/helpers.lua: " .. tostring(T) .. "\n")
  vim.cmd("cquit 1")
  return
end
_G.T = T

for _, spec in ipairs({
  "config",
  "store",
  "actions",
  "format",
  "stream",
  "thread",
  "chat",
  "render",
  "geometry",
  "e2e",
  "tag_session",
  "modes",
  "panel",
  "mention",
  "mention_completion",
  "markview",
  "render_markdown",
}) do
  local ok, err = pcall(require, spec .. "_spec")
  if not ok then
    io.write("ERROR loading " .. spec .. "_spec: " .. tostring(err) .. "\n")
    T.failed = T.failed + 1
    T.failures[#T.failures + 1] = spec .. "_spec failed to load: " .. tostring(err)
  end
end

local pass = T.report()
vim.cmd(pass and "qall!" or "cquit 1")
