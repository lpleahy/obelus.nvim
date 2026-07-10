-- Persistent job-output log. Headless dispatch has no TUI to read, so every
-- agent run's full output lands here (newest on top) — open with :ObelusJobs.
local M = {}

local buf = nil

local function ensure_buf()
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "hide"
  pcall(vim.api.nvim_buf_set_name, buf, "obelus://jobs")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# obelus jobs", "" })
  vim.bo[buf].modifiable = false
  return buf
end

---@param entry table { label?: string, ok?: boolean, text?: string, when?: string }
function M.append(entry)
  local b = ensure_buf()
  local lines = {
    string.format(
      "## %s · %s · %s",
      entry.when or os.date("%H:%M:%S"),
      entry.label or "agent",
      entry.ok and "✓" or "✗"
    ),
    "",
  }
  for _, l in ipairs(vim.split(entry.text or "", "\n")) do
    lines[#lines + 1] = l
  end
  lines[#lines + 1] = ""
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, 2, 2, false, lines) -- newest right under the header
  vim.bo[b].modifiable = false
end

-- The last FINAL prompt the cli transport handed to the agent process (chat
-- reply or batch), exactly as sent — [Mentions]/[Mentioned files]/[Formatting]
-- suffixes included. Session-scoped; :ObelusPrompt shows it.
local last_prompt = nil

function M.set_prompt(p)
  last_prompt = p
end

function M.prompt()
  return last_prompt
end

function M.open_prompt()
  if not last_prompt then
    vim.notify("obelus: no prompt sent yet this session", vim.log.levels.INFO)
    return
  end
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "markdown"
  vim.bo[b].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, vim.split(last_prompt, "\n", { plain = true }))
  vim.bo[b].modifiable = false
  local width = math.min(100, math.floor(vim.o.columns * 0.8))
  local height = math.floor(vim.o.lines * 0.8)
  vim.api.nvim_open_win(b, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " last prompt sent ",
    title_pos = "center",
    zindex = require("obelus.config").z.OVERLAY, -- above the chat stack (incl. its input)
  })
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = b, silent = true })
end

function M.open()
  local b = ensure_buf()
  local width = math.min(100, math.floor(vim.o.columns * 0.8))
  local height = math.floor(vim.o.lines * 0.8)
  vim.api.nvim_open_win(b, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " obelus jobs ",
    title_pos = "center",
    zindex = require("obelus.config").z.OVERLAY, -- above the chat stack (incl. its input)
  })
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = b, nowait = true, silent = true })
end

return M
