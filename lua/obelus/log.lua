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

---@param entry table { label?: string, ok?: boolean, text?: string, when?: string,
---  code?: integer, cmd?: string[], stderr?: string }
---code/cmd/stderr are the failure post-mortem (exit code, exact argv, raw
---stderr) — rendered as their own sections so a broken config is diagnosable
---from :ObelusLogs alone.
function M.append(entry)
  local b = ensure_buf()
  local head = string.format(
    "## %s · %s · %s",
    entry.when or os.date("%H:%M:%S"),
    entry.label or "agent",
    entry.ok and "✓" or ("✗" .. (entry.code and (" exit " .. entry.code) or ""))
  )
  local lines = { head, "" }
  if entry.cmd then
    -- one line, whatever the argv contains: the PROMPT rides the argv and is
    -- multi-line + huge (nvim_buf_set_lines rejects items with newlines) —
    -- collapse whitespace and elide long elements; the full prompt is
    -- :ObelusPrompt's job, not the cmd line's
    local parts = {}
    for _, a in ipairs(entry.cmd) do
      a = tostring(a):gsub("%s+", " ")
      if #a > 120 then
        a = a:sub(1, 117) .. "…"
      end
      parts[#parts + 1] = a
    end
    lines[#lines + 1] = "cmd: `" .. table.concat(parts, " ") .. "`"
    lines[#lines + 1] = ""
  end
  if entry.stderr and entry.stderr ~= "" then
    lines[#lines + 1] = "### stderr"
    for _, l in ipairs(vim.split(entry.stderr, "\n")) do
      lines[#lines + 1] = l
    end
    lines[#lines + 1] = ""
  end
  for _, l in ipairs(vim.split(entry.text or "", "\n")) do
    lines[#lines + 1] = l
  end
  lines[#lines + 1] = ""
  -- the log must NEVER throw (a throw here would kill the exit callback that
  -- is trying to report a failure): scrub any stray \r/\n a caller slipped in
  for i, l in ipairs(lines) do
    lines[i] = l:gsub("[\r\n]", " ")
  end
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, 2, 2, false, lines) -- newest right under the header
  vim.bo[b].modifiable = false
end

---The log buffer's current lines (specs + programmatic checks).
---@return string[]
function M.lines()
  return vim.api.nvim_buf_get_lines(ensure_buf(), 0, -1, false)
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
