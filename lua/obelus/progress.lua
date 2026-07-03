local config = require("obelus.config")
local nav = require("obelus.nav")

-- Background-job tracking + an out-of-the-way spinner. Display modes:
--   "auto"       inline spinner on EACH worked thread's line when its buffer is open,
--                else a corner float (default)
--   "inline"     same as auto
--   "corner"     always a top-right float counting running jobs
--   "statusline" nothing floating; use require("obelus.progress").statusline()
--   "off"        no UI
local M = {}

-- Spinner tick interval (ms), read when the timer starts — specs shrink it instead
-- of waiting out real frames.
M._timing = { tick = 100 }

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local ns = vim.api.nvim_create_namespace("obelus_progress")

local jobs = {} -- id -> job
local seq = 0
local frame = 1
local timer = nil
local corner_win = nil
local corner_buf = nil

local function display()
  return (config.options.progress and config.options.progress.display) or "auto"
end

local function count_running()
  local n = 0
  for _, j in pairs(jobs) do
    if j.status == "running" then
      n = n + 1
    end
  end
  return n
end

-- ONE inline target per comment that has an open buffer, so EVERY dispatched thread
-- (e.g. all members of a batch) gets a spinner on its line — not only the first.
local function build_inlines(comments)
  local out = {}
  for _, c in ipairs(comments or {}) do
    local b = nav.buf_for_file(c.file)
    if b then
      out[#out + 1] = { id = c.id, comment = c, bufnr = b }
    end
  end
  return out
end

local function set_inline(t, label, glyph, hl)
  if not (t and vim.api.nvim_buf_is_valid(t.bufnr)) then
    return
  end
  -- read the comment's CURRENT row each frame (not a value cached at job start) so the
  -- spinner tracks edits that shift the range mid-job instead of stranding on the old line
  local line0 = math.min(t.comment.range.sl - 1, vim.api.nvim_buf_line_count(t.bufnr) - 1)
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, t.bufnr, ns, math.max(line0, 0), 0, {
    id = t.extmark_id,
    virt_text = { { " " .. glyph .. " " .. label, hl or "DiagnosticInfo" } },
    virt_text_pos = "right_align",
    priority = 250,
  })
  if ok then
    t.extmark_id = id
  end
end

local function clear_inline(t)
  if t and t.extmark_id and vim.api.nvim_buf_is_valid(t.bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, t.bufnr, ns, t.extmark_id)
    t.extmark_id = nil
  end
end

local function render_corner(n)
  if n == 0 then
    if corner_win and vim.api.nvim_win_is_valid(corner_win) then
      pcall(vim.api.nvim_win_close, corner_win, true)
    end
    corner_win, corner_buf = nil, nil
    return
  end
  local text = " " .. FRAMES[frame] .. " obelus: " .. n .. (n == 1 and " job " or " jobs ")
  if not (corner_buf and vim.api.nvim_buf_is_valid(corner_buf)) then
    corner_buf = vim.api.nvim_create_buf(false, true)
  end
  vim.api.nvim_buf_set_lines(corner_buf, 0, -1, false, { text })
  local cfg = {
    relative = "editor",
    anchor = "NE",
    row = 1,
    col = vim.o.columns - 1,
    width = vim.fn.strdisplaywidth(text),
    height = 1,
    style = "minimal",
    border = "rounded",
    focusable = false,
    noautocmd = true,
    zindex = 200,
  }
  if corner_win and vim.api.nvim_win_is_valid(corner_win) then
    vim.api.nvim_win_set_config(corner_win, cfg)
  else
    corner_win = vim.api.nvim_open_win(corner_buf, false, cfg)
    vim.wo[corner_win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"
  end
end

local function is_expanded(c, bufmap)
  local ok, e = pcall(function()
    return require("obelus.render").is_expanded(c, bufmap)
  end)
  return (ok and e) or false
end

local function render()
  local mode = display()
  local corner = 0
  -- built ONCE per tick and discarded after — is_expanded would otherwise re-scan every
  -- loaded buffer with fnamemodify per comment, per frame (O(comments × buffers) at 10 Hz)
  local mok, bufmap = pcall(function()
    return require("obelus.render").file_buf_map()
  end)
  bufmap = mok and bufmap or nil
  for _, job in pairs(jobs) do
    if job.status == "running" then
      -- re-evaluate EACH FRAME, per comment, which surface shows the worked thread (it
      -- can change as the cursor moves or styles toggle): if a view shows the thread its
      -- band carries the spinner (clear any inline); otherwise spin inline on its line.
      local visible = false
      for _, t in ipairs(job.inlines or {}) do
        if is_expanded(t.comment, bufmap) then
          clear_inline(t)
        elseif mode == "auto" or mode == "inline" then
          set_inline(t, job.label, FRAMES[frame], "DiagnosticInfo")
          visible = true
        end
      end
      if not visible then
        for _, c in ipairs(job.comments or {}) do
          if is_expanded(c, bufmap) then
            visible = true
            break
          end
        end
      end
      if not visible and mode ~= "off" and mode ~= "statusline" then
        corner = corner + 1 -- nothing on screen shows this job → count it in the corner
      end
    end
  end
  if mode ~= "statusline" and mode ~= "off" then
    render_corner(corner)
  end
  pcall(vim.cmd, "redrawstatus")
  -- animate in-box spinners + stream growing turns into bands/panel
  pcall(function()
    require("obelus.render").refresh_dynamic()
  end)
  if count_running() == 0 then
    M._stop()
  end
end

function M._stop()
  if timer then
    timer:stop()
    pcall(function()
      timer:close()
    end)
    timer = nil
  end
end

-- Drop ALL tracked jobs and their UI (test seam): a spec that dies between start()
-- and finish() would otherwise leave its job "running" forever, inflating the
-- count for every later spec in the same process.
function M._reset()
  for _, job in pairs(jobs) do
    for _, t in ipairs(job.inlines or {}) do
      clear_inline(t)
    end
  end
  jobs = {}
  render_corner(0)
  M._stop()
end

local function ensure_timer()
  if timer then
    return
  end
  timer = (vim.uv or vim.loop).new_timer()
  timer:start(
    0,
    M._timing.tick,
    vim.schedule_wrap(function()
      frame = (frame % #FRAMES) + 1
      render()
    end)
  )
end

---Start tracking a background job. Returns a handle to pass to finish().
---@param opts table { label?: string, comments?: table[] }
function M.start(opts)
  seq = seq + 1
  local job = { id = seq, label = opts.label or "agent", comments = opts.comments or {}, status = "running" }
  -- always prepare inline targets; render() decides each frame, per comment, whether a
  -- view is showing the thread (spinner lives there) or we fall back to inline/corner
  local mode = display()
  if mode == "auto" or mode == "inline" then
    job.inlines = build_inlines(job.comments)
  else
    job.inlines = {}
  end
  jobs[job.id] = job
  ensure_timer()
  render()
  return job
end

---Mark a job finished. Shows a brief ✓/✗ inline on each worked line before clearing.
function M.finish(job, ok, result)
  if not job then
    return
  end
  job.status = ok and "ok" or "error"
  job.result = result
  for _, t in ipairs(job.inlines or {}) do
    set_inline(t, job.label, ok and "✓" or "✗", ok and "DiagnosticOk" or "DiagnosticError")
    local handle = t
    vim.defer_fn(function()
      clear_inline(handle)
      pcall(require("obelus.render").render_buffer, handle.bufnr)
    end, 2000)
  end
  jobs[job.id] = nil
  render()
  -- per-tick fill no longer forces a markview redraw (that was the flicker), so do the single
  -- precise bottom-seat now the stream is done (no-op if the user scrolled up — seat_finish
  -- respects follow)
  pcall(function()
    require("obelus.panel").seat_finish()
  end)
end

-- Drop any job for a comment id (cancel / stuck cleanup); stop the timer if idle.
function M.cancel(id)
  for jid, job in pairs(jobs) do
    for _, c in ipairs(job.comments or {}) do
      if c.id == id then
        for _, t in ipairs(job.inlines or {}) do
          clear_inline(t)
        end
        jobs[jid] = nil
        break
      end
    end
  end
  if not next(jobs) then
    M._stop()
  end
  render()
end

---Current spinner glyph (so other surfaces can animate in sync).
function M.frame()
  return FRAMES[frame]
end

---Statusline component (for lualine etc.): "⠙ 2" while jobs run, "" when idle.
function M.statusline()
  local n = count_running()
  if n == 0 then
    return ""
  end
  return FRAMES[frame] .. " " .. n
end

return M
