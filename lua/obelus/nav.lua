-- Shared file/window navigation helpers: absolute-path normalization, buffer/window
-- lookup by file, and the jump-to-source-line logic shared by panel's list and
-- chat views. Pure leaf module — no requires on config/store/render/panel, so
-- anything can require it downward without creating a cycle.
local M = {}

function M.abspath(name)
  return name ~= "" and vim.fn.fnamemodify(name, ":p") or nil
end

function M.buf_for_file(file)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and M.abspath(vim.api.nvim_buf_get_name(b)) == file then
      return b
    end
  end
end

-- The window currently showing this buffer (so bands track the file even when
-- focus is in a reply float or another window — important for live streaming).
function M.win_for_buf(bufnr)
  local cur = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(cur) == bufnr then
    return cur
  end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == bufnr then
      return w
    end
  end
end

-- Jump to a comment's source line: pick a window other than opts.avoid (falling
-- back to wincmd p), edit the file, then position the cursor at the comment's
-- range — clamped to the buffer's current line count.
-- opts.avoid: window handle to skip when picking a target window.
-- opts.warn_orphan: when the comment's start line is beyond the buffer's end,
--   notify that it's orphaned before clamping (jump_to instead clamps silently).
function M.goto_source(c, opts)
  opts = opts or {}
  local target
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if w ~= opts.avoid then
      target = w
      break
    end
  end
  if target then
    vim.api.nvim_set_current_win(target)
  else
    vim.cmd("wincmd p")
  end
  vim.cmd("edit " .. vim.fn.fnameescape(c.file))
  local total = vim.api.nvim_buf_line_count(0)
  local row = c.range.sl
  if opts.warn_orphan and row > total then
    vim.notify("obelus: that line is gone (orphaned) — jumping to nearest", vim.log.levels.WARN)
    row = total
  end
  pcall(vim.api.nvim_win_set_cursor, 0, { math.max(math.min(row, total), 1), (c.range.sc or 1) - 1 })
end

return M
