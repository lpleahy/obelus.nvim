local store = require("obelus.store")
local render = require("obelus.render")
local format = require("obelus.format")
local config = require("obelus.config")

local M = {}

local state = { buf = nil, line_map = {} }

-- Every real (non-meta) thread — the project thread never belongs in a per-file
-- listing: its "file" is the project root, a directory, not an annotation target.
-- Shared by M.quickfix and build() below.
local function real_comments()
  return vim.tbl_filter(function(c)
    return not c.meta
  end, store.all())
end

function M.quickfix()
  local items = {}
  for _, c in ipairs(real_comments()) do
    table.insert(items, {
      filename = c.file,
      lnum = c.range.sl,
      col = c.range.sc or 1,
      text = (c.status == "resolved" and "[✓] " or "") .. (vim.split(c.comment or "", "\n")[1] or ""),
    })
  end
  vim.fn.setqflist({}, " ", { title = "AI Review (" .. #items .. ")", items = items })
  vim.cmd("copen")
end

local function build()
  local lines, map = {}, {}
  local function push(text, id)
    table.insert(lines, text)
    if id then
      map[#lines] = id
    end
  end

  local all = real_comments()
  push("# AI Review — " .. #all .. " comment(s)")
  push("")
  push("Keys: <CR> jump · e edit · dd delete · S submit · r refresh · q close")
  push("")

  local by_file, order = {}, {}
  for _, c in ipairs(all) do
    if not by_file[c.file] then
      by_file[c.file] = {}
      table.insert(order, c.file)
    end
    table.insert(by_file[c.file], c)
  end

  for _, file in ipairs(order) do
    push("## " .. format.relpath(file))
    push("")
    for _, c in ipairs(by_file[file]) do
      push(string.format("- %s %s", format.range_label(c), c.status == "resolved" and "·✓" or ""), c.id)
      push("  ```", c.id)
      for _, l in ipairs((c.context and c.context.before) or {}) do
        push("    " .. l, c.id)
      end
      for _, l in ipairs(c.selected_text or {}) do
        push("  ▌ " .. l, c.id)
      end
      for _, l in ipairs((c.context and c.context.after) or {}) do
        push("    " .. l, c.id)
      end
      push("  ```", c.id)
      for _, l in ipairs(vim.split(c.comment or "", "\n")) do
        push("  💬 " .. l, c.id)
      end
      push("")
    end
  end
  return lines, map
end

local function fill(buf)
  local lines, map = build()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  state.line_map = map
end

function M.refresh()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    fill(state.buf)
  end
end

local function buffer(split)
  -- Sync any open source buffers so displayed line numbers are current.
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      render.sync_positions(b)
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  state.buf = buf
  fill(buf)

  if split then
    vim.cmd("botright vsplit")
    vim.api.nvim_win_set_buf(0, buf)
  else
    local width = math.min(100, math.floor(vim.o.columns * 0.8))
    local height = math.floor(vim.o.lines * 0.8)
    vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      row = math.floor((vim.o.lines - height) / 2),
      col = math.floor((vim.o.columns - width) / 2),
      width = width,
      height = height,
      style = "minimal",
      border = "rounded",
      title = " AI Review ",
      title_pos = "center",
    })
  end

  local function cid()
    return state.line_map[vim.api.nvim_win_get_cursor(0)[1]]
  end

  local kopts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "q", "<cmd>close<cr>", kopts)
  vim.keymap.set("n", "r", M.refresh, kopts)
  vim.keymap.set("n", "<CR>", function()
    local c = cid() and store.get(cid())
    if not c then
      return
    end
    vim.cmd("close")
    vim.cmd("edit " .. vim.fn.fnameescape(c.file))
    pcall(vim.api.nvim_win_set_cursor, 0, { c.range.sl, (c.range.sc or 1) - 1 })
  end, kopts)
  vim.keymap.set("n", "e", function()
    if cid() then
      require("obelus").edit(cid())
    end
  end, kopts)
  vim.keymap.set("n", "dd", function()
    if cid() then
      require("obelus").delete(cid())
      M.refresh()
    end
  end, kopts)
  vim.keymap.set("n", "S", function()
    require("obelus").submit()
    M.refresh()
  end, kopts)
end

function M.open(backend)
  backend = backend or config.options.view.default
  if backend == "quickfix" then
    M.quickfix()
  elseif backend == "split" then
    buffer(true)
  else
    buffer(false)
  end
end

return M
