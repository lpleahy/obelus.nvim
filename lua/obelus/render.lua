local config = require("obelus.config")
local store = require("obelus.store")
local nav = require("obelus.nav")
-- jobs.lua is dependency-light (only top-requires store; review.lua is lazy inside
-- it) so a top-level require here doesn't create a load cycle. progress.lua DOES
-- lazily require render.lua (is_expanded/file_buf_map/refresh_dynamic/render_buffer,
-- all inside function bodies) — so progress is required inline at its two call
-- sites below instead of at module scope, to keep that lazy relationship one-way.
local jobs = require("obelus.jobs")

local M = {}

local ns = vim.api.nvim_create_namespace("obelus")
local ns_band = vim.api.nvim_create_namespace("obelus_band")
M.enabled = true
local buf_disabled = {} -- bufnr -> true means hidden in this buffer
local band_override = {} -- bufnr -> bool: per-buffer override of the band default
local pinned = {} -- comment id -> true: keep its band expanded regardless of cursor
local band_scroll = {} -- comment id -> band scroll offset (rows from top); nil = stick to bottom
local band_extent = {} -- comment id -> { inner, maxoff } from the last capped render (for clamping)
local cover_id = {} -- bufnr -> id of the comment currently under the cursor

local function display_enabled(bufnr)
  if not M.enabled then
    return false
  end
  if buf_disabled[bufnr] then
    return false
  end
  return config.options.render.enabled
end

-- Are inline bands on for this buffer? Per-buffer override wins; else config default.
local function bands_enabled(bufnr)
  if config.mode() ~= "inline" then
    return false -- sidebar mode: chat lives in the sidebar, not inline bands
  end
  if band_override[bufnr] ~= nil then
    return band_override[bufnr]
  end
  return (config.options.render.bands or {}).enabled ~= false
end

-- public state getters (for which-key live toggle labels)
function M.bands_on(bufnr)
  return bands_enabled(bufnr or vim.api.nvim_get_current_buf())
end

-- Are annotations actually displayed in this buffer right now? Read-only mirror of
-- display_enabled's semantics (M.enabled global AND not buffer-disabled AND config
-- render.enabled) — exposed for which-key's live toggle icon on <prefix>t.
function M.annotations_on(bufnr)
  return display_enabled(bufnr or vim.api.nvim_get_current_buf())
end

-- Thread display style: "inline" virt_lines band, or a rooted "popup" hover preview.
-- config.ui.band_style (session toggle) wins; else the config default. The literal
-- fallback aligns to config.defaults.render.bands.style ("popup") — post-validation
-- the key always exists, so this is a dead fallback kept in sync on principle.
local function band_style()
  if config.ui.band_style ~= nil then
    return config.ui.band_style
  end
  return (config.options.render.bands or {}).style or "popup"
end
function M.band_style()
  return band_style()
end

-- Forget the covered comment for a buffer so the next CursorMoved re-evaluates
-- (used when the hover preview is dismissed on window-leave so it re-opens on return).
function M.reset_cover(bufnr)
  cover_id[bufnr or vim.api.nvim_get_current_buf()] = nil
end

function M.resolved_shown()
  if config.ui.show_resolved ~= nil then
    return config.ui.show_resolved
  end
  return config.options.render.annotations.show_resolved == true
end

function M.toggle_resolved()
  config.ui.show_resolved = not M.resolved_shown()
  M.render_all()
  vim.notify("obelus: resolved comments " .. (config.ui.show_resolved and "shown" or "hidden"), vim.log.levels.INFO)
end

-- Effective keybind-hint visibility: config.ui.hints (the :ObelusHints / <prefix>?
-- session toggle; nil = never toggled) overrides options.render.hints. One switch for
-- every hint footer (the sidebar/popup keybind line, the docked reply box's footer,
-- the compose footer, the inline band's paginated tips) — see config.lua's comment.
function M.hints_shown()
  if config.ui.hints ~= nil then
    return config.ui.hints
  end
  return config.options.render.hints == true
end

---Place (or update) the extmark for a single comment in `bufnr`.
function M.place(bufnr, c)
  -- the project (meta) thread's "file" is the project root, a DIRECTORY — it has
  -- no line to annotate. store.by_file(file) already never matches it in the
  -- normal render_buffer/render_bands passes (a directory path never equals a
  -- real buffer's abspath), but guard here too in case something calls M.place
  -- directly with it.
  if c.meta then
    return
  end
  if not display_enabled(bufnr) then
    return
  end
  local r = config.options.render
  local a = r.annotations or {}
  local total = vim.api.nvim_buf_line_count(bufnr)
  local line0 = c.range.sl - 1
  if line0 < 0 or line0 >= total then
    return
  end
  -- resolved + hidden: just a subtle gutter checkmark (toggle with <leader>oh)
  if c.status == "resolved" and not M.resolved_shown() then
    local sok, sid = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line0, 0, {
      id = c.extmark_id,
      sign_text = a.resolved_sign or "✓",
      sign_hl_group = "ObelusReplyHeader",
    })
    if sok then
      c.extmark_id = sid
    end
    return
  end
  local last0 = math.min((c.range.el or c.range.sl) - 1, total - 1)
  local charwise = c.kind == "char" and c.range.sc and c.range.ec

  local opts = { id = c.extmark_id }
  if a.signs then
    opts.sign_text = a.sign
    opts.sign_hl_group = a.sign_hl
  end
  -- eol preview only in inline mode with bands off; in sidebar mode the chat
  -- lives in the sidebar, so don't ghost the file
  if a.preview and config.mode() == "inline" and not bands_enabled(bufnr) then
    local first = vim.split(c.comment or "", "\n")[1] or ""
    opts.virt_text = { { (a.preview_prefix or "  ▌ ") .. first, a.preview_hl } }
    opts.virt_text_pos = "eol"
  end
  -- mark the WHOLE commented region: a precise char span for charwise, a line
  -- band for linewise (so multi-line / partial selections show all the lines)
  if charwise then
    opts.end_row = last0
    opts.end_col = math.max(c.range.ec, 1)
    opts.hl_group = "ObelusRangeText"
  else
    opts.line_hl_group = "ObelusThreadBg"
  end

  local col = math.max((c.range.sc or 1) - 1, 0)
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line0, col, opts)
  if ok then
    c.extmark_id = id
  end

  -- gutter sign (+ line band when linewise) on every other line of the range
  for l = line0 + 1, last0 do
    local lopts = {}
    if not charwise then
      lopts.line_hl_group = "ObelusThreadBg"
    end
    if a.signs then
      lopts.sign_text = a.sign
      lopts.sign_hl_group = a.sign_hl
    end
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, l, 0, lopts)
  end
end

function M.render_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if not display_enabled(bufnr) then
    return
  end
  local file = nav.abspath(vim.api.nvim_buf_get_name(bufnr))
  if not file then
    return
  end
  for _, c in ipairs(store.by_file(file)) do
    c.extmark_id = nil
    M.place(bufnr, c)
  end
end

function M.render_all()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      M.render_buffer(b)
      M.render_bands(b)
    end
  end
  pcall(function()
    local panel = require("obelus.panel")
    panel.refresh()
    panel.refresh_preview()
  end)
end

function M.toggle(scope)
  if scope == "global" then
    M.enabled = not M.enabled
    M.render_all()
    vim.notify("obelus: annotations " .. (M.enabled and "on" or "off") .. " (global)", vim.log.levels.INFO)
  else
    local bufnr = vim.api.nvim_get_current_buf()
    buf_disabled[bufnr] = not buf_disabled[bufnr]
    M.render_buffer(bufnr)
    vim.notify("obelus: annotations " .. (buf_disabled[bufnr] and "off" or "on") .. " (buffer)", vim.log.levels.INFO)
  end
end

---Read live extmark positions back into the store (keeps line numbers correct
---after the user edits a file above existing comments).
function M.sync_positions(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local file = nav.abspath(vim.api.nvim_buf_get_name(bufnr))
  if not file then
    return
  end
  for _, c in ipairs(store.by_file(file)) do
    if c.extmark_id then
      local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, c.extmark_id, {})
      if pos and pos[1] then
        local delta = (pos[1] + 1) - c.range.sl
        if delta ~= 0 then
          c.range.sl = c.range.sl + delta
          c.range.el = c.range.el + delta
        end
      end
    end
  end
end

-- A comment's *live* top row (follows the extmark, so it survives edits/drift).
local function comment_row(bufnr, c)
  if c.extmark_id then
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, c.extmark_id, {})
    if pos and pos[1] then
      return pos[1]
    end
  end
  return c.range.sl - 1
end

---Comment whose live range covers the cursor line in the current buffer.
function M.at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local file = nav.abspath(vim.api.nvim_buf_get_name(bufnr))
  if not file then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  for _, c in ipairs(store.by_file(file)) do
    local row = comment_row(bufnr, c) + 1
    if line >= row and line <= row + ((c.range.el or c.range.sl) - c.range.sl) then
      return c
    end
  end
end

local function text_width(win)
  local total = vim.api.nvim_win_get_width(win)
  local gutter = (vim.fn.getwininfo(win)[1] or {}).textoff or 0
  return math.max(20, total - gutter)
end

-- file -> bufnr over every loaded buffer, built ONCE by a caller that needs is_expanded
-- for many comments in one pass (progress.lua's 10 Hz tick) instead of paying the
-- fnamemodify scan per comment. Callers must rebuild it each pass — it is not cached
-- here, so a buffer opened/closed mid-tick can never read stale.
function M.file_buf_map()
  local map = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local f = nav.abspath(vim.api.nvim_buf_get_name(b))
      if f and not map[f] then
        map[f] = b
      end
    end
  end
  return map
end

local function covering(bufnr, win, c)
  local line = vim.api.nvim_win_get_cursor(win)[1]
  local top = comment_row(bufnr, c)
  return line >= top + 1 and line <= top + 1 + ((c.range.el or c.range.sl) - c.range.sl)
end

-- Is this comment's box currently open? (file band expanded, or the sidebar
-- chat showing it). Used to put the spinner in the box, not a separate float.
-- bufmap: optional pre-built M.file_buf_map() result (a caller looping over many
-- comments in one pass builds it once and reuses it here instead of a per-call scan).
function M.is_expanded(c, bufmap)
  local pok, panel = pcall(require, "obelus.panel")
  if pok and panel.showing and panel.showing(c.id) then
    return true -- the modal sidebar/popup chat shows this thread
  end
  if pok and panel.preview_showing and panel.preview_showing(c.id) then
    return true -- the rooted hover preview shows this thread
  end
  -- when a map was provided, trust it for misses too — it covers every loaded buffer,
  -- so falling back to the scan would pay the per-comment cost exactly for the
  -- not-currently-open files the map already answered "no" for
  local b = bufmap and bufmap[c.file] or (not bufmap and nav.buf_for_file(c.file)) or nil
  if not b or not bands_enabled(b) then
    return false
  end
  if band_style() == "popup" then
    return false -- popup style has no inline band; the preview (above) is the surface
  end
  local w = nav.win_for_buf(b)
  if not w then
    return false
  end
  if pinned[c.id] then
    return true
  end
  local mode = (config.options.render.bands or {}).mode or "focus"
  return mode == "all" or covering(b, w, c)
end

-- Re-render only the dynamic surfaces (bands + sidebar) — used by the progress
-- timer to animate spinners and stream growing turns without re-placing signs.
function M.refresh_dynamic()
  -- only buffers actually DISPLAYED in a window can show a band — re-placing virt_lines on
  -- every loaded-but-hidden buffer 10x/sec is wasted work that helps starve the main loop.
  local visible = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    visible[vim.api.nvim_win_get_buf(w)] = true
  end
  for b in pairs(visible) do
    if vim.api.nvim_buf_is_loaded(b) then
      M.render_bands(b)
    end
  end
  pcall(function()
    local panel = require("obelus.panel")
    panel.refresh()
    panel.refresh_preview() -- stream into the hover preview too
  end)
end

-- Band height cap: max_height as an absolute line count (>=1), a fraction of the
-- window (0<frac<1), or nil/0 → 60% of the window.
local function band_cap(win)
  local mh = (config.options.render.bands or {}).max_height
  local h = vim.api.nvim_win_get_height(win)
  if not mh or mh <= 0 then
    return math.max(8, math.floor(h * 0.6))
  elseif mh < 1 then
    return math.max(4, math.floor(h * mh))
  end
  return math.floor(mh)
end

-- Cap a band's height (you can't scroll virtual lines) and make it *paginated*: a
-- fixed window into the thread with ⋯ indicators top/bottom; <prefix>J/<prefix>K
-- scroll it (M.scroll_band). Default sticks to the bottom (latest turns).
local function cap_rows(rows, win, id)
  local cap = band_cap(win)
  if #rows <= cap then
    if id then
      band_extent[id], band_scroll[id] = nil, nil
    end
    return rows
  end
  local inner = math.max(cap - 2, 1) -- reserve 2 rows for the ⋯ indicators
  local maxoff = #rows - inner
  local off = id and band_scroll[id] or nil
  if off == nil then
    off = maxoff -- stick to the latest
  end
  off = math.max(0, math.min(off, maxoff))
  if id then
    band_extent[id] = { inner = inner, maxoff = maxoff }
  end
  local pfx = (config.options.keys and config.options.keys.prefix) or "<leader>o"
  -- chrome: neutral colour, NO background box, so the hints don't read like a turn
  local function ind(text)
    return { { text, "ObelusChrome" } }
  end
  -- the keybind tips are opt-in (config.render.hints); off by default we show
  -- just a minimal "⋯ N above/below" count so you still know the band is paginated
  local hints_on = M.hints_shown()
  local function tip(label, keys)
    return ind(hints_on and (label .. " · " .. keys .. " ") or (label .. " "))
  end
  local out = {}
  out[#out + 1] = off > 0 and tip(" ⋯ " .. off .. " above", pfx .. "K up · " .. pfx .. "J down")
    or tip(" ⋯ top of thread", pfx .. "J down · " .. pfx .. "o full")
  for i = off + 1, off + inner do
    out[#out + 1] = rows[i]
  end
  local below = #rows - (off + inner)
  out[#out + 1] = below > 0 and tip(" ⋯ " .. below .. " below", pfx .. "J down · " .. pfx .. "o full")
    or tip(" ⋯ latest", pfx .. "K up · " .. pfx .. "o full")
  return out
end

---Render expanded comment bands (virt_lines): the comment under the cursor (in
---"focus" mode) plus any pinned ones; or every comment (in "all" mode).
function M.render_bands(bufnr)
  if not bufnr or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns_band, 0, -1)
  if not (bands_enabled(bufnr) and display_enabled(bufnr)) then
    return
  end
  if band_style() == "popup" then
    return -- popup style: the thread shows in panel.preview, never as virt_lines
  end
  local win = nav.win_for_buf(bufnr)
  if not win then
    return
  end
  local file = nav.abspath(vim.api.nvim_buf_get_name(bufnr))
  if not file then
    return
  end
  local mode = (config.options.render.bands or {}).mode or "focus"
  local cfg = config.options.render.bands or {}
  local width = text_width(win)
  if cfg.max_width then
    width = math.min(width, cfg.max_width)
  end
  local line = vim.api.nvim_win_get_cursor(win)[1]
  local total = vim.api.nvim_buf_line_count(bufnr)
  local thread = require("obelus.thread")
  for _, c in ipairs(store.by_file(file)) do
    local top = comment_row(bufnr, c)
    local span = (c.range.el or c.range.sl) - c.range.sl
    local is_cov = line >= top + 1 and line <= top + 1 + span
    local hidden = c.status == "resolved" and not M.resolved_shown()
    if not hidden then
      local pok, panel = pcall(require, "obelus.panel")
      if pok and panel.showing and panel.showing(c.id) then
        hidden = true -- the popup / sidebar chat is already showing this thread
      end
    end
    if not hidden and (pinned[c.id] or mode == "all" or (mode == "focus" and is_cov)) then
      -- serialize BEFORE cap_rows: cap_rows' own "⋯ N above/below" indicator rows
      -- are baked { {text, hl} } chunk lists (fed straight into virt_lines), so the
      -- array it slices/mixes them into must already be in that same baked shape —
      -- feeding it thread.build's structured rows directly would splice two
      -- incompatible row shapes into one virt_lines list.
      local rows = cap_rows(
        thread.to_virt_lines(
          thread.build(c, width, {
            markdown = cfg.markdown,
            rules = cfg.rules,
            live = jobs.live(c),
            spinner = require("obelus.progress").frame(),
          }),
          width
        ),
        win,
        c.id
      )
      -- subtle separator so adjacent threads don't butt together: one blank, un-tinted
      -- virt_line ABOVE the band. Added AFTER cap_rows, so it never counts toward the
      -- height cap or gets paginated, and it sits OUTSIDE the thread (no gap is added
      -- INSIDE a thread — turns stay rule-separated). Opt out: render.bands.separator=false
      if (config.options.render.bands or {}).separator ~= false then
        table.insert(rows, 1, { { "", "Normal" } })
      end
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_band, math.max(math.min(top + span, total - 1), 0), 0, {
        virt_lines = rows,
        virt_lines_above = false,
      })
    end
  end
end

-- Position a reply input where the new turn will land: below the comment's
-- selected lines AND below its inline band. Moves the cursor to the comment's
-- last line and returns the row offset for a cursor-relative float.
function M.reply_anchor(bufnr, c)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local win = nav.win_for_buf(bufnr) or vim.api.nvim_get_current_win()
  local total = vim.api.nvim_buf_line_count(bufnr)
  local el = math.max(math.min(c.range.el or c.range.sl, total), 1)
  pcall(vim.api.nvim_win_set_cursor, win, { el, 0 })
  local offset = 1
  if band_style() == "inline" and bands_enabled(bufnr) and display_enabled(bufnr) then
    local cfg = config.options.render.bands or {}
    local width = text_width(win)
    if cfg.max_width then
      width = math.min(width, cfg.max_width)
    end
    -- serialize BEFORE cap_rows (same reason as render_bands above): the offset must
    -- count the actual visual rows cap_rows would paginate/hand to virt_lines.
    local thread = require("obelus.thread")
    local rows = cap_rows(
      thread.to_virt_lines(
        thread.build(c, width, {
          markdown = cfg.markdown,
          rules = cfg.rules,
          live = jobs.live(c),
          spinner = require("obelus.progress").frame(),
        }),
        width
      ),
      win,
      c.id
    )
    -- +1 for the blank separator render_bands prepends above each band (keep in sync)
    local sep = ((config.options.render.bands or {}).separator ~= false) and 1 or 0
    offset = #rows + 1 + sep -- clear the band so the input sits just past the thread
  end
  return offset
end

---Scroll the capped inline band under the cursor. dir<0 = up (earlier turns),
---dir>0 = down (toward the latest); `lines` = rows to move (nil = half a page).
---Silent no-op when off a band / the thread already fits (so motion keys bound to
---this fall through harmlessly).
-- Scroll dispatcher for M-u/M-d (+ <prefix>J/K): route to the focused popup/sidebar
-- chat if one has focus, else scroll the inline band under the cursor. So the same
-- keys scroll the conversation in every mode.
function M.scroll(dir, lines)
  local ok, panel = pcall(require, "obelus.panel")
  if ok and panel.scroll and panel.scroll(dir, lines) then
    return
  end
  M.scroll_band(dir, lines)
end

function M.scroll_band(dir, lines)
  local c = M.at_cursor()
  if not c then
    return
  end
  local ext = band_extent[c.id]
  if not ext then
    return -- thread fits in the band; nothing to scroll
  end
  local cur = band_scroll[c.id]
  if cur == nil then
    cur = ext.maxoff
  end
  local step = (lines or math.max(1, math.floor(ext.inner / 2))) * (dir < 0 and -1 or 1)
  band_scroll[c.id] = math.max(0, math.min(cur + step, ext.maxoff))
  M.render_bands(vim.api.nvim_get_current_buf())
end

-- Re-arm the inline band's auto-scroll on send: stick it to the bottom (latest turn)
-- and scroll the file so the band is in view. Scrolling the band up (M.scroll_band)
-- sets a fixed offset, which turns following off until the next send re-arms it.
function M.arm_follow(id)
  band_scroll[id] = nil -- nil = stick to the latest
  local c = require("obelus.store").get(id)
  if not c then
    return
  end
  local b = nav.buf_for_file(c.file)
  local w = b and nav.win_for_buf(b)
  if w and vim.api.nvim_win_is_valid(w) then
    local sl0 = (c.range.sl or 1) - 1
    local wh = vim.api.nvim_win_get_height(w)
    local top = math.max(sl0 - math.floor(wh * 0.25), 0)
    pcall(vim.api.nvim_win_call, w, function()
      local v = vim.fn.winsaveview()
      v.topline = top + 1 -- seat the comment ~1/4 down so the band below it is visible
      vim.fn.winrestview(v)
    end)
  end
end

---Toggle inline bands on/off for a buffer (overrides the config default).
function M.toggle_band(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  band_override[bufnr] = not bands_enabled(bufnr)
  M.render_buffer(bufnr)
  M.render_bands(bufnr)
  vim.notify("obelus: inline bands " .. (bands_enabled(bufnr) and "on" or "off") .. " (buffer)", vim.log.levels.INFO)
end

---Toggle the thread display style for all buffers: inline band <-> hover popup.
---A session override (config.ui.band_style), not a mutation of config.options —
---survives a re-run of setup().
function M.toggle_band_style()
  local style = (band_style() == "popup") and "inline" or "popup"
  config.ui.band_style = style
  for k in pairs(cover_id) do
    cover_id[k] = nil -- force a fresh evaluation at the cursor in the new style
  end
  pcall(function()
    require("obelus.panel").hide_preview()
  end)
  M.render_all() -- clears virt_lines bands (popup) or repaints them (inline)
  M.on_cursor() -- show the band/preview for the current cursor immediately
  vim.notify("obelus: thread style → " .. style, vim.log.levels.INFO)
end

---Pin/unpin the comment under the cursor so its band stays expanded (fold-like).
function M.toggle_pin(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local c = M.at_cursor()
  if not c then
    return vim.notify("obelus: no comment under cursor", vim.log.levels.WARN)
  end
  pinned[c.id] = (not pinned[c.id]) or nil
  M.render_bands(bufnr)
  vim.notify("obelus: comment " .. (pinned[c.id] and "pinned open" or "collapsed"), vim.log.levels.INFO)
end

---CursorMoved / WinEnter hook: re-render the band (inline) or open/move/close the
---hover preview (popup) for the comment under the cursor. Runs on WinEnter too, so
---switching windows reconciles the preview (no separate WinLeave hook needed).
function M.on_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local pok, panel = pcall(require, "obelus.panel")
  -- the user is BROWSING the maximized hover (it holds the real cursor): every
  -- CursorMoved/WinEnter in there would otherwise read as "cursor left the
  -- covered comment" and hide the very window they're reading
  if pok and panel.preview_focused and panel.preview_focused() then
    return
  end
  -- Cheap guard: this runs on EVERY CursorMoved in EVERY buffer, and the scan below is
  -- O(comments) with a per-comment extmark lookup (comment_row). With no comments
  -- anywhere `cover` can only ever end up nil (store.by_file(file) would find nothing
  -- either) — skip straight to that outcome's reconcile instead of paying for the
  -- scan to prove it. Still has to RUN that reconcile, not just return bare: popup
  -- style must still hide a lingering preview, and inline focus-mode must still clear
  -- a lingering band (e.g. the last comment in the project was just deleted) — same
  -- hide/clear semantics as the cover==nil path below, just without the scan.
  if #store.all() == 0 then
    if band_style() == "popup" then
      cover_id[bufnr] = nil
      if pok then
        panel.hide_preview()
      end
    elseif
      bands_enabled(bufnr)
      and ((config.options.render.bands or {}).mode or "focus") == "focus"
      and cover_id[bufnr] ~= nil
    then
      cover_id[bufnr] = nil
      M.render_bands(bufnr)
    end
    return
  end
  -- the comment (if any, non-hidden) whose range covers the cursor in this buffer
  local cover
  if bands_enabled(bufnr) then
    local file = nav.abspath(vim.api.nvim_buf_get_name(bufnr))
    if file then
      local win = vim.api.nvim_get_current_win()
      local line = vim.api.nvim_win_get_cursor(win)[1]
      for _, c in ipairs(store.by_file(file)) do
        local top = comment_row(bufnr, c)
        if line >= top + 1 and line <= top + 1 + ((c.range.el or c.range.sl) - c.range.sl) then
          if not (c.status == "resolved" and not M.resolved_shown()) then
            cover = c.id
            break
          end
        end
      end
    end
  end

  if band_style() == "popup" then
    -- reconcile the single hover preview: show it for the covered comment, hide it
    -- otherwise (off a comment, in a non-file window, or bands disabled here)
    if cover and pok then
      if cover ~= cover_id[bufnr] or not panel.preview_showing(cover) then
        cover_id[bufnr] = cover
        panel.preview(cover)
      end
    else
      cover_id[bufnr] = nil
      if pok then
        panel.hide_preview()
      end
    end
    return
  end

  -- inline style: re-render the band only when the covered comment changes (focus mode)
  if not bands_enabled(bufnr) then
    return
  end
  if ((config.options.render.bands or {}).mode or "focus") ~= "focus" then
    return
  end
  if cover ~= cover_id[bufnr] then
    cover_id[bufnr] = cover
    M.render_bands(bufnr)
  end
end

-- Buffer-local chat-surface keybind, driven by keys.chat[name] (config.chat_key —
-- shared with panel.lua's docked reply box, section C): `false` skips the binding
-- entirely, unset keeps `default` (today's hardcoded key).
local function bind_chat(o, modes, name, default, fn)
  local lhs = config.chat_key(name, default)
  if lhs then
    vim.keymap.set(modes, lhs, fn, o)
  end
end

---Band-styled input float near the cursor — the one composer for new comments
---and replies alike. opts: { title, row, height, default, on_submit(text, action), on_cancel }.
function M.compose(opts)
  opts = opts or {}
  local prev = vim.api.nvim_get_current_win()
  local ibuf = vim.api.nvim_create_buf(false, true)
  vim.bo[ibuf].bufhidden = "wipe"
  vim.bo[ibuf].filetype = "obelus_reply" -- so cursor-animation plugins can exclude it
  require("obelus.mention").attach(ibuf) -- "@" opens a project file picker (see mention.lua)
  if opts.default and opts.default ~= "" then
    vim.api.nvim_buf_set_lines(ibuf, 0, -1, false, vim.split(opts.default, "\n"))
  end
  -- a small "you"-bubble input float: anchored at the cursor by default (new
  -- comment / quick reply), or over a parent window's bottom edge (popup reply).
  local wcfg
  if opts.parent_win and vim.api.nvim_win_is_valid(opts.parent_win) then
    wcfg = {
      relative = "win",
      win = opts.parent_win,
      anchor = "SW",
      row = vim.api.nvim_win_get_height(opts.parent_win),
      col = 0,
      width = math.max(vim.api.nvim_win_get_width(opts.parent_win), 20),
      height = opts.height or 3,
    }
  else
    -- anchor_above: float rises ABOVE the cursor line so it doesn't cover the inline
    -- band (the history) that renders below the comment — you can read it while typing
    wcfg = {
      relative = "cursor",
      anchor = opts.anchor_above and "SW" or "NW",
      row = opts.anchor_above and 0 or (opts.row or 1),
      col = 0,
      width = math.min(text_width(vim.api.nvim_get_current_win()), 72),
      height = opts.height or 3,
    }
  end
  wcfg.style = "minimal"
  wcfg.border = "rounded"
  wcfg.title = { { " ▎ " .. (opts.title or "you") .. " ", "ObelusInputHeader" } }
  wcfg.title_pos = "left"
  if M.hints_shown() then
    wcfg.footer = { { " ⏎ send · <C-s> save · <Esc> cancel ", "ObelusThreadMeta" } }
    wcfg.footer_pos = "right"
  end
  local fwin = vim.api.nvim_open_win(ibuf, true, wcfg)
  vim.wo[fwin].cursorline = false
  vim.wo[fwin].wrap = true
  -- the rounded border IS the box; a 1-col empty sign column just gives the text a
  -- little left padding inside it (no inner "▎" bar that would double up the line)
  vim.wo[fwin].signcolumn = "yes:1"
  vim.wo[fwin].foldcolumn = "0"
  vim.wo[fwin].winhighlight =
    "Normal:ObelusInput,NormalFloat:ObelusInput,SignColumn:ObelusInput,FloatBorder:ObelusInputBorder,FloatTitle:ObelusThreadHeader,EndOfBuffer:ObelusInput"
  vim.wo[fwin].winblend = config.options.render.winblend or 0
  vim.cmd("startinsert")
  local done = false
  local function finish(action)
    if done then
      return
    end
    done = true
    local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(ibuf, 0, -1, false), "\n"))
    if vim.api.nvim_win_is_valid(fwin) then
      vim.api.nvim_win_close(fwin, true)
    end
    if vim.api.nvim_win_is_valid(prev) then
      vim.api.nvim_set_current_win(prev)
    end
    if action == "cancel" or text == "" then
      if opts.on_cancel then
        opts.on_cancel(text) -- pass the text so a caller can still save it (e.g. escape saves a comment)
      end
      return
    end
    if opts.on_submit then
      opts.on_submit(text, action)
    end
  end
  local o = { buffer = ibuf, nowait = true, silent = true }
  -- Chat-surface keybinds (section C; keys.chat — shared table with the docked reply
  -- box, see panel.lua's open_input), defaults = today's hardcoded keys.
  bind_chat(o, "n", "send", "<CR>", function() -- Enter sends, like the persistent reply box
    finish("send")
  end)
  bind_chat(o, { "n", "i" }, "send_fast", "<M-CR>", function() -- Alt+Enter: send with the fast model
    finish("send_fast")
  end)
  bind_chat(o, { "n", "i" }, "save", "<C-s>", function()
    finish("save")
  end)
  bind_chat(o, { "n", "i" }, "paste_image", "<C-v>", function()
    require("obelus.mention").smart_paste() -- image -> @mention; else plain text paste
  end)
  bind_chat(o, "n", "close_esc", "<Esc>", function()
    finish("cancel")
  end)
  bind_chat(o, "n", "close", "q", function()
    finish("cancel")
  end)
  -- cycle (normal mode) hops to the history window so you can yank earlier output;
  -- Tab there hops back here (wired by the caller that owns the history window).
  if opts.parent_win and vim.api.nvim_win_is_valid(opts.parent_win) then
    bind_chat(o, "n", "cycle", "<Tab>", function()
      if vim.api.nvim_win_is_valid(opts.parent_win) then
        vim.api.nvim_set_current_win(opts.parent_win)
      end
    end)
  end
  return fwin
end

---Reply to the comment under the cursor (native in-file chat: the band shows the
---history, this composer is the input).
function M.reply_inline()
  local c = M.at_cursor()
  if not c then
    return vim.notify("obelus: no comment under cursor", vim.log.levels.WARN)
  end
  local id = c.id
  M.compose({
    anchor_above = true, -- the band (history) is below the comment; keep it visible
    on_submit = function(text, action)
      if action == "save" then
        require("obelus").chat_save(id, text)
      else
        require("obelus").chat_send(id, text, action == "send_fast" and "fast" or "send")
      end
    end,
  })
end

return M
