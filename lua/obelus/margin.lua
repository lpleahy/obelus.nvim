-- Opt-in, window-owned margin preview. No store writes, prompt changes, or
-- replacement of render.at_cursor's first-match semantics live here.
local api = vim.api
local store = require("obelus.store")
local layout = require("obelus.margin_layout")
local M = {}
local sessions, unsafe = {}, {}
local pending, group
local settle_composer, open_composer -- defined below; M.close / M.action need them
local paint_ns = api.nvim_create_namespace("obelus_margin_cards")
local view_ns = api.nvim_create_namespace("obelus_margin_view")

-- Every margin group is a link to an obelus group or derived from thread.palette()
-- (theme-resolved, never an Obelus* group, so ordering against init.lua's
-- ColorScheme handler does not matter). No colour literals live here; all groups
-- are `default` so a user colorscheme may override them. nvim_set_hl's `default`
-- never replaces an existing definition, so a derived group is re-derived on a
-- theme change only while it still holds what we last wrote (a user override, or
-- a theme that defines the group itself, is left alone). `:hi clear` restores a
-- default link we wrote earlier, minus its `default` flag, so that state counts
-- as ours too; and the group is emptied with `:hi clear <name>` (an empty
-- nvim_set_hl leaves a once-linked group refusing every later default link).
-- Call this from a window without a winhighlight remap (the source): nvim_get_hl
-- resolves through the current window's winhighlight once that window has been
-- drawn.
local last_derived, default_link = {}, {}
local function written(name)
  local hl = api.nvim_get_hl(0, { name = name })
  hl.default = nil
  return hl
end
local function ours(name, current)
  return next(current) == nil
    or vim.deep_equal(current, last_derived[name])
    or (default_link[name] ~= nil and vim.deep_equal(current, { link = default_link[name] }))
end
local function derive(name, spec)
  if ours(name, written(name)) then
    if vim.fn.hlexists(name) == 1 then
      vim.cmd.highlight({ "clear", name })
    end
    spec.default = true
    api.nvim_set_hl(0, name, spec)
    last_derived[name] = written(name)
    if spec.link then
      default_link[name] = spec.link
    end
  end
end

local function highlights()
  local thread = require("obelus.thread")
  local p = thread.palette()
  local float_title = api.nvim_get_hl(0, { name = "FloatTitle", link = false })
  api.nvim_set_hl(0, "ObelusMarginBorder", { link = "ObelusBorder", default = true })
  -- the theme's title colour, fg only: FloatTitle carries a bg on opaque themes
  -- and an inherited bg would paint a band into the card's top border
  if float_title and float_title.fg then
    derive("ObelusMarginTitle", { fg = float_title.fg, bold = float_title.bold })
  else
    derive("ObelusMarginTitle", { link = "ObelusThreadHeaderN" })
  end
  api.nvim_set_hl(0, "ObelusMarginConnector", { link = "ObelusChrome", default = true })
  derive("ObelusMarginActive", { fg = p.mention, bold = true })
  derive("ObelusMarginSource", { bg = thread.blend(p.mention, p.bg, 0.22) })
end

-- Pane window highlight: the obelus split's chrome treatment (mirrors
-- panel.lua's chat_winhl) — dim NonText/EndOfBuffer filler, and in transparent
-- mode the thread text group as the base so the editor shows through. Never a
-- hardcoded bg.
local function pane_winhl()
  local parts = { "NonText:ObelusChrome", "EndOfBuffer:ObelusChrome" }
  if (require("obelus.config").options.render or {}).transparent == true then
    parts[#parts + 1] = "Normal:ObelusThreadText"
  end
  return table.concat(parts, ",")
end

local function find(win)
  win = win or api.nvim_get_current_win()
  if sessions[win] then
    return sessions[win]
  end
  for _, s in pairs(sessions) do
    if s.win == win then
      return s
    end
  end
end

local function valid(s)
  return api.nvim_win_is_valid(s.source)
    and api.nvim_win_is_valid(s.win)
    and api.nvim_buf_is_valid(s.buf)
    and api.nvim_buf_is_valid(s.pane)
    and api.nvim_win_get_buf(s.source) == s.buf
    and api.nvim_win_get_buf(s.win) == s.pane
    and require("obelus.nav").abspath(api.nvim_buf_get_name(s.buf)) == s.file
end

local function clear_matches(s)
  for _, id in ipairs(s.matches or {}) do
    pcall(vim.fn.matchdelete, id, s.source)
  end
  s.matches = {}
end

function M.close(win)
  local s = find(win)
  if not s then
    return
  end
  sessions[s.source] = nil -- detach before WinClosed/BufWipeout callbacks
  s.closing = true
  pcall(settle_composer, s) -- the open reply is kept as a draft (SPEC A3 rule 6)
  clear_matches(s)
  if api.nvim_buf_is_valid(s.buf) then
    if api.nvim_buf_get_changedtick(s.buf) ~= s.tick or vim.bo[s.buf].modified then
      unsafe[s.buf] = true
    end
    api.nvim_buf_clear_namespace(s.buf, s.ns, 0, -1)
  else
    unsafe[s.buf] = nil
  end
  if api.nvim_win_is_valid(s.win) then
    pcall(api.nvim_win_close, s.win, true)
  end
  if api.nvim_buf_is_valid(s.pane) then
    pcall(api.nvim_buf_delete, s.pane, { force = true })
  end
  if not next(sessions) and group then
    api.nvim_del_augroup_by_id(group)
    api.nvim_set_decoration_provider(view_ns, {})
    group = nil
  end
end

-- Margin-only live marks. Never sync these into the persisted range, nor change
-- selected_text. After any source edit the preview is display-only: the baseline
-- sender's disk/range contract is not repaired by these private marks.
local function anchor(s, c)
  local mark = s.anchors[c.id]
  local cached = s.anchor_records[c.id]
  -- Reloads replace records; range/kind replacements also invalidate this cache.
  -- Private mark motion alone never changes the persisted range or selected_text.
  local replaced = cached and (cached.record ~= c or cached.kind ~= c.kind or not vim.deep_equal(cached.range, c.range))
  if replaced then
    api.nvim_buf_del_extmark(s.buf, s.ns, mark)
    s.anchors[c.id], s.anchor_records[c.id], mark = nil, nil, nil
  end
  if not mark then
    local total = api.nvim_buf_line_count(s.buf)
    local sl, el = c.range.sl, c.range.el or c.range.sl
    local col = math.max(0, (c.range.sc or 1) - 1)
    -- Prefer an existing live top mark, just as render.comment_row does.
    if c.extmark_id and not replaced then
      local pos = api.nvim_buf_get_extmark_by_id(s.buf, api.nvim_create_namespace("obelus"), c.extmark_id, {})
      if #pos > 0 then
        sl, el, col = pos[1] + 1, pos[1] + 1 + el - sl, pos[2]
      end
    end
    if sl < 1 or sl > total or el < sl then
      return
    end
    el = math.min(el, total)
    local first = api.nvim_buf_get_lines(s.buf, sl - 1, sl, false)[1] or ""
    local last = api.nvim_buf_get_lines(s.buf, el - 1, el, false)[1] or ""
    col = c.kind == "char" and math.min(col, #first) or 0
    local ec = c.kind == "char" and math.min(c.range.ec or #last, #last) or #last
    mark = api.nvim_buf_set_extmark(s.buf, s.ns, sl - 1, col, {
      end_row = el - 1,
      end_col = math.max(sl == el and col or 0, ec),
      right_gravity = true,
      end_right_gravity = true,
    })
    s.anchors[c.id] = mark
    s.anchor_records[c.id] = { record = c, kind = c.kind, range = vim.deepcopy(c.range) }
  end
  local pos = api.nvim_buf_get_extmark_by_id(s.buf, s.ns, mark, { details = true })
  if #pos == 0 then
    return
  end
  return { sl = pos[1] + 1, sc = pos[2], el = (pos[3].end_row or pos[1]) + 1, ec = pos[3].end_col or pos[2] }
end

-- The active card stays listed while resolved cards are hidden: `x` keeps the card
-- just resolved in view (shown as resolved) so `o` / `dd` act on it; selecting
-- another card drops it.
local function comments(s)
  local out, seen, visible = {}, {}, {}
  for _, c in ipairs(store.by_file(s.file)) do
    seen[c.id] = true
    if c.status ~= "resolved" or c.id == s.active or require("obelus.render").resolved_shown() then
      local a = anchor(s, c)
      if a then
        visible[c.id] = true
        out[#out + 1] = { c = c, a = a }
      end
    end
  end
  for id, mark in pairs(s.anchors) do
    if not seen[id] then
      api.nvim_buf_del_extmark(s.buf, s.ns, mark)
      s.anchors[id], s.anchor_records[id], s.offset[id] = nil, nil, nil
    end
  end
  -- Hidden/deleted cards cannot retain an invisible batch selection.
  for id in pairs(s.checked) do
    if not visible[id] then
      s.checked[id] = nil
    end
  end
  table.sort(out, function(a, b)
    if a.a.sl ~= b.a.sl then
      return a.a.sl < b.a.sl
    end
    if a.a.sc ~= b.a.sc then
      return a.a.sc < b.a.sc
    end
    return a.c.id < b.c.id
  end)
  return out
end

-- Ports attach to source LINES (the charwise accent still marks the exact range).
-- text_height, unlike screenpos, also works with smoothscroll skipcol and with
-- horizontally scrolled text. Include real wraps, closed folds and virtual rows.
-- nvim_win_call forwards only the callback's FIRST return value, so the side of an
-- off-screen anchor travels in a table.
local function screen_row(s, a, top, height)
  local r = api.nvim_win_call(s.source, function()
    local view = vim.fn.winsaveview()
    if a.el < view.topline then
      return { side = "above" }
    end
    if a.sl > vim.fn.line("w$") then
      return { side = "below" }
    end
    local line = math.max(a.sl, view.topline)
    local fold = vim.fn.foldclosed(line)
    if fold ~= -1 then
      line = math.max(fold, view.topline)
    end
    local rows = 0
    if line > view.topline then
      rows = api.nvim_win_text_height(s.source, {
        start_row = view.topline - 1,
        start_vcol = view.skipcol,
        end_row = line - 2,
      }).all + (api.nvim_win_text_height(s.source, { start_row = line - 1, end_row = line - 1 }).fill or 0)
    end
    local info = vim.fn.getwininfo(s.source)[1]
    local row = rows + (view.topfill or 0) + info.winrow + info.winbar - top
    if row < 1 then
      return { side = "above" }
    end
    if row > height then
      return { side = "below" }
    end
    return { row = row }
  end)
  return r.row, r.side
end

-- A redraw-only geometry gate catches folds and third-party virtual-row changes
-- that need not emit CursorMoved/WinScrolled. It schedules, never paints inside
-- a decoration callback, and ignores our pane/highlight writes (no redraw loop).
local function signature(s)
  local info = vim.fn.getwininfo(s.win)[1]
  local parts = api.nvim_win_call(s.source, function()
    local v = vim.fn.winsaveview()
    local source = vim.fn.getwininfo(s.source)[1]
    return {
      v.topline,
      v.skipcol,
      v.leftcol,
      v.topfill,
      source.width,
      source.height,
      source.winrow,
      source.wincol,
      source.winbar,
      info.width,
      info.height,
      info.winrow,
      info.wincol,
      info.winbar,
      api.nvim_buf_get_changedtick(s.buf),
    }
  end)
  for _, item in ipairs(s.order or {}) do
    local row, side = screen_row(s, item.a, info.winrow + info.winbar - 1, info.height)
    parts[#parts + 1] = row or side
  end
  return table.concat(parts, ":")
end

local function source_highlight(s, a, kind)
  clear_matches(s)
  if not a then
    return
  end
  local first, last =
    api.nvim_win_call(s.source, function()
      return { vim.fn.line("w0"), vim.fn.line("w$") }
    end), nil
  first, last = first[1], first[2]
  local positions = {}
  for line = math.max(a.sl, first), math.min(a.el, last) do
    if kind == "char" then
      local text = api.nvim_buf_get_lines(s.buf, line - 1, line, false)[1] or ""
      local col = line == a.sl and a.sc or 0
      local finish = line == a.el and a.ec or #text
      if finish > col then
        positions[#positions + 1] = { line, col + 1, finish - col }
      end
    else
      positions[#positions + 1] = { line }
    end
    if #positions == 8 then
      s.matches[#s.matches + 1] = vim.fn.matchaddpos("ObelusMarginSource", positions, 30, -1, { window = s.source })
      positions = {}
    end
  end
  if #positions > 0 then
    s.matches[#s.matches + 1] = vim.fn.matchaddpos("ObelusMarginSource", positions, 30, -1, { window = s.source })
  end
end

-- Tabs/newlines are normalized by clip. strwidth measures those serialized cells
-- without inheriting the focused source's wrap/linebreak/breakindent padding.
local function cells(text)
  return vim.fn.strwidth(text)
end

local function clip(text, width)
  local out, used = {}, 0
  for _, ch in ipairs(vim.fn.split(text:gsub("\t", "  "):gsub("[\r\n]", " "), "\\zs")) do
    local w = cells(ch)
    if used + w > width then
      break
    end
    out[#out + 1], used = ch, used + w
  end
  return table.concat(out)
end

-- The inline reply box (SPEC A3): 3 text rows plus its own top/bottom border rows,
-- reserved inside the card below its last thread row while composing.
local COMPOSER_ROWS = 5
local COMPOSER_HEIGHT = 3
-- connector lane columns; the card box starts at column LANES + 2 (0-based)
local LANES = 4

-- Reply-draft predicate (critic.md G2): the trailing you-turn is a DRAFT only when
-- the thread has more than one turn and is not dispatching. A fresh 1-turn
-- comment's only turn IS the comment — never a draft, never prefilled or hidden.
local function reply_draft(c)
  local turns = store.turns(c)
  local tail = turns[#turns]
  return #turns > 1 and tail ~= nil and tail.author == "you" and not c.dispatching
end

-- One card = a rounded text box exactly `width` cells wide (SPEC A2): the title in
-- the top border, the thread rows (bar included) inside, the scroll hint in the
-- bottom border. While the inline composer is open on this card the bottom border
-- is omitted and COMPOSER_ROWS blank rows are reserved for the float, whose own
-- bottom border closes the box.
local function card(s, c, width, height)
  local thread = require("obelus.thread")
  local inner = width - 2
  local composing = s.composing ~= nil and s.composing.id == c.id
  local built = thread.build(c, inner, {
    live = require("obelus.jobs").live(c),
    spinner = require("obelus.progress").frame(),
    hide_draft = (composing and s.composing.has_saved_draft) or nil,
  })
  local rows = thread.to_virt_lines(built, inner)
  local chrome = composing and 1 + COMPOSER_ROWS or 2
  local room = height - 2 - chrome -- two rows stay free for the above/below indicators
  local maxbody = math.max(1, math.min(s.expanded[c.id] and room or 7, room))
  local offset = math.min(s.offset[c.id] or math.max(0, #rows - maxbody), math.max(0, #rows - maxbody))
  local active = c.id == s.active
  local border = active and "ObelusMarginActive" or "ObelusMarginBorder"
  local title_hl = active and "ObelusMarginActive" or "ObelusMarginTitle"
  local title = clip(
    (s.checked[c.id] and "[x] " or "[ ] ")
      .. "#"
      .. c.id:match("[^-]+$")
      .. " L"
      .. c.range.sl
      .. " · "
      .. (c.status or "open")
      .. (c.ask and " · ask" or ""),
    width - 4
  )
  local result = {
    {
      { "╭ ", border },
      { title, title_hl },
      { " " .. string.rep("─", width - 4 - cells(title)) .. "╮", border },
    },
  }
  local last = math.min(#rows, offset + maxbody)
  for i = offset + 1, last do
    local line, remaining = { { "│", border } }, inner
    for _, chunk in ipairs(rows[i]) do
      local text = clip(chunk[1], remaining)
      if #text > 0 then
        line[#line + 1] = { text, chunk[2] }
        remaining = remaining - cells(text)
      end
    end
    if remaining > 0 then
      line[#line + 1] = { string.rep(" ", remaining), built[i].bg_hl }
    end
    line[#line + 1] = { "│", border }
    result[#result + 1] = line
  end
  if composing then
    result.composer_at = #result + 1 -- card-relative index of the float's first row
    for _ = 1, COMPOSER_ROWS do
      result[#result + 1] = { { string.rep(" ", width) } }
    end
  else
    local hint = #rows > maxbody and ((offset + 1) .. "–" .. last .. "/" .. #rows .. " J/K") or ""
    if hint == "" then
      result[#result + 1] = { { "╰" .. string.rep("─", width - 2) .. "╯", border } }
    elseif cells(hint) + 3 <= width then
      result[#result + 1] = {
        { "╰" .. string.rep("─", width - 3 - cells(hint)) .. " ", border },
        { hint, "ObelusThreadMeta" },
        { "╯", border },
      }
    else
      hint = clip(hint, width - 2)
      result[#result + 1] = {
        { "╰", border },
        { hint .. string.rep(" ", width - 2 - cells(hint)), "ObelusThreadMeta" },
        { "╯", border },
      }
    end
  end
  s.extent[c.id] = math.max(0, #rows - maxbody)
  return result
end

-- Apply what the composer holds to the thread (SPEC A3 rule 5): non-empty text is
-- kept as the trailing you-turn (the "· draft"); empty text deletes that draft only
-- when the composer opened ON a reply draft. A fresh comment's own text is never
-- overwritten or blanked: store.set_pending_you (behind chat_save) edits the
-- trailing you-turn in place, and on a 1-turn thread that turn IS the comment, so
-- the reply is appended as its own turn first. `keep_status` (the composer was
-- settled from outside: resolved, margin closed, card left the pane) stores the
-- text without chat_save's reopen, so a resolve on the composing card sticks.
-- Returns "gone" when the comment no longer exists, "kept" when text was stored,
-- "cleared" when an empty composer deleted the draft it opened on, else nil.
local function apply_draft(id, text, had_draft, keep_status)
  local c = store.get(id)
  if not c then
    return "gone"
  end
  if text ~= "" then
    local turns = store.turns(c)
    if #turns == 1 and turns[1].author == "you" then
      store.add_turn(id, "you", text)
    end
    if keep_status then
      store.set_pending_you(id, text)
      require("obelus.render").render_all()
    else
      require("obelus").chat_save(id, text)
    end
    return "kept"
  elseif had_draft and reply_draft(c) then
    require("obelus").chat_save(id, "")
    return "cleared"
  end
end

local function composer_text(cm)
  return vim.trim(table.concat(api.nvim_buf_get_lines(cm.buf, 0, -1, false), "\n"))
end

-- Stop Insert, Replace and Virtual Replace, including Ctrl-o's temporary Normal
-- mode, before leaving the composer for an unmodifiable pane.
local function leave_insert()
  vim.cmd("stopinsert")
end

-- Close the inline composer from outside render.compose's own keymaps (card left
-- the pane, margin closed, composer moved to another card), keeping the typed text
-- as a draft. The float's buffer is wiped with it, so the text is read first.
function settle_composer(s, notice)
  local cm = s.composing
  if not cm then
    return
  end
  s.composing, s.seat = nil, true
  M.refresh()
  if not (cm.win and api.nvim_win_is_valid(cm.win)) then
    return
  end
  local text = composer_text(cm)
  if api.nvim_get_current_win() == cm.win then
    leave_insert()
    local source = api.nvim_win_is_valid(s.source) and s.source
    local pane = not s.closing and api.nvim_win_is_valid(s.win) and s.win
    local back = pane or source
    if back then
      api.nvim_set_current_win(back)
    end
  end
  pcall(api.nvim_win_close, cm.win, true)
  local result = apply_draft(cm.id, text, cm.has_saved_draft, true)
  if notice and result == "gone" and text ~= "" then
    -- A reload can remove the record without review.delete's own notification.
    vim.notify("obelus margin: comment no longer exists; reply discarded", vim.log.levels.WARN)
  elseif notice and result ~= "gone" then
    -- An empty composer kept nothing: say only what happened to the card.
    vim.notify(result == "kept" and notice or (notice:gsub("; reply kept as draft$", "")), vim.log.levels.INFO)
  end
end

-- Persist the composer text without closing anything: QuitPre runs with the pane
-- or the composer current, and closing the current window there aborts :qa.
local function keep_draft(s)
  local cm = s.composing
  if cm and cm.buf and api.nvim_buf_is_valid(cm.buf) then
    local result = apply_draft(cm.id, composer_text(cm), cm.has_saved_draft, true)
    if result == "kept" then
      -- A failed :qa leaves this editor open on the draft we just persisted.
      cm.has_saved_draft = reply_draft(store.get(cm.id))
    end
    return result
  end
end

-- The session whose composer float is `win`, if any (event hygiene: the margin's
-- own autocmds must ignore the composer window — typing there never repaints).
local function composer_of(win)
  for _, s in pairs(sessions) do
    if s.composing and s.composing.win == win then
      return s
    end
  end
end

local function paint(s)
  if not valid(s) then
    return M.close(s.source)
  end
  if api.nvim_win_get_tabpage(s.source) ~= api.nvim_get_current_tabpage() then
    return
  end
  local tick = api.nvim_buf_get_changedtick(s.buf)
  if tick ~= s.tick or vim.bo[s.buf].modified then
    unsafe[s.buf] = true
  end
  s.tick = tick
  s.paints = (s.paints or 0) + 1
  -- a composer closed behind our back (render.compose's finish(), :close) has
  -- already wiped its buffer: forget it before the cards are measured
  if s.composing and s.composing.win and not api.nvim_win_is_valid(s.composing.win) then
    s.composing = nil
  end
  local info = vim.fn.getwininfo(s.win)[1]
  local width, height = info.width, info.height
  local top = info.winrow + info.winbar - 1
  local all = comments(s)
  s.order = all
  -- a comment created on the source cursor while the margin is open (<leader>oc)
  -- becomes the active card; every store id for the file counts as seen, so
  -- toggling resolved visibility never looks like a new card
  local known, fresh = s.known, nil
  if known then
    local row = api.nvim_win_get_cursor(s.source)[1]
    for _, item in ipairs(all) do
      if not known[item.c.id] and not fresh and row >= item.a.sl and row <= item.a.el then
        fresh = item
      end
    end
  end
  known = known or {}
  for _, c in ipairs(store.by_file(s.file)) do
    known[c.id] = true
  end
  s.known = known
  if fresh then
    s.active, s.seat, s.source_cursor = fresh.c.id, true, nil
  end
  local active
  for _, item in ipairs(all) do
    if item.c.id == s.active then
      active = item
    end
  end
  if not active then
    -- the active card is gone (deleted, or its range left the buffer): move to its
    -- nearest neighbour by source line (previous, else next), not the first card
    local pick = all[1]
    if s.active_sl then
      for _, item in ipairs(all) do
        if item.a.sl <= s.active_sl then
          pick = item
        else
          break
        end
      end
    end
    active = pick
    s.active = pick and pick.c.id
    s.seat = s.seat or pick ~= nil
  end
  s.active_sl = active and active.a.sl
  local items, bodies = {}, {}
  local lanes = LANES
  local cardwidth = width - lanes - 2
  s.extent = {}
  if width >= 28 and height >= 8 then
    for i, item in ipairs(all) do
      local row, side = screen_row(s, item.a, top, height)
      local body = card(s, item.c, cardwidth, height)
      bodies[item.c.id] = body
      items[#items + 1] = { id = item.c.id, order = i, row = row, side = side, h = #body }
      if item.c.id == s.active then
        active = item
      end
    end
  end
  local placement = layout.place(items, { rows = height, active = s.active })
  local lane, _, shared = layout.lanes(items, placement, lanes)
  local grid = layout.draw(items, placement, lane, { rows = height, lane_max = lanes, active = s.active })
  local lines, marks, row_ids = {}, {}, {}
  for row = 1, height do
    lines[row], marks[row] = grid[row].text, grid[row].spans
  end
  for id, placed in pairs(placement.cards) do
    for i, chunks in ipairs(bodies[id]) do
      local row = placed.top + i - 1
      local remaining = cardwidth
      for _, chunk in ipairs(chunks) do
        local text = clip(chunk[1], remaining)
        local off = #lines[row]
        lines[row] = lines[row] .. text
        local hl = chunk[2]
        if hl and #text > 0 then
          marks[row][#marks[row] + 1] = { off, off + #text, hl }
        end
        remaining = remaining - cells(text)
      end
      row_ids[row] = id
    end
  end
  -- inline composer: follow the card (its top moves with the source view); a card
  -- that is no longer placed takes its draft with it (SPEC A3 rule 6)
  local cm = s.composing
  if cm then
    local placed = placement.cards[cm.id]
    local at = placed and bodies[cm.id].composer_at
    if at and placed.top + #bodies[cm.id] - 1 > placement.hi then
      at = nil -- the reserved rows would run into the bottom indicator row
    end
    cm.row = at and (placed.top + at - 2) or nil -- 0-based pane row of the float's top border
    local rec = store.get(cm.id)
    if cm.win and rec and rec.status == "resolved" and cm.status ~= "resolved" then
      -- resolved from outside the margin since the composer opened (sidebar, source
      -- <leader>oR, agent write-back): the card stays in view as the active card, but
      -- the reply is kept as a draft rather than reopening the thread later
      settle_composer(s, "obelus margin: card resolved; reply kept as draft")
    elseif cm.win then
      if cm.row then
        local border = cm.id == s.active and "ObelusMarginActive" or "ObelusMarginBorder"
        pcall(api.nvim_win_set_config, cm.win, {
          relative = "win",
          win = s.win,
          row = cm.row,
          col = lanes + 2,
          width = cardwidth - 2,
          height = COMPOSER_HEIGHT,
          title = { { " reply ", border } },
          title_pos = "left",
        })
        vim.wo[cm.win].winhighlight = "Normal:ObelusInput,NormalFloat:ObelusInput,SignColumn:ObelusInput,FloatBorder:"
          .. border
          .. ",FloatTitle:"
          .. border
          .. ",EndOfBuffer:ObelusInput"
      else
        settle_composer(s, "obelus margin: card left the pane; reply kept as draft")
      end
    end
  end
  local function indicator(row, n, label)
    if row then
      lines[row] = grid[row].text .. clip("… " .. n .. " " .. label .. " · [c / ]c", cardwidth)
    end
  end
  indicator(placement.top_indicator, #placement.above, "above/packed")
  indicator(placement.bottom_indicator, #placement.below, "below/packed")
  if #all == 0 then
    lines[1] = clip("No comments. Annotate in the source first.", width)
  end
  if width < 28 or height < 8 then
    lines[1] = clip("Margin needs 28 columns / 8 rows", width)
  end
  s.placement, s.items, s.row_ids = placement, items, row_ids
  local changed = not vim.deep_equal(lines, api.nvim_buf_get_lines(s.pane, 0, -1, false))
  if changed then
    vim.bo[s.pane].modifiable = true
    api.nvim_buf_set_lines(s.pane, 0, -1, false, lines)
    vim.bo[s.pane].modifiable = false
  end
  if changed or not vim.deep_equal(marks, s.paint_marks) then
    api.nvim_buf_clear_namespace(s.pane, paint_ns, 0, -1)
    for row, spans in ipairs(marks) do
      for _, span in ipairs(spans) do
        if span[2] > span[1] and span[2] <= #lines[row] then
          api.nvim_buf_set_extmark(s.pane, paint_ns, row - 1, span[1], { end_col = span[2], hl_group = span[3] })
        end
      end
    end
    s.paint_marks = marks
  end
  local p = placement.cards[s.active]
  if s.seat and p then
    api.nvim_win_set_cursor(s.win, { p.top, #grid[p.top].text })
  end
  s.seat = nil
  api.nvim_win_call(s.win, function()
    local view = vim.fn.winsaveview()
    view.topline, view.leftcol, view.skipcol = 1, 0, 0
    vim.fn.winrestview(view)
  end)
  s.pane_row = api.nvim_win_get_cursor(s.win)[1]
  vim.wo[s.win].statusline = " margin preview · ? help"
    .. (unsafe[s.buf] and " · EDITED: sends blocked" or "")
    .. (shared and " · shared lanes" or "")
  source_highlight(s, active and active.a, active and active.c.kind)
  s.signature = signature(s)
end

function M.refresh()
  if pending or not next(sessions) then
    return
  end
  pending = true
  vim.schedule(function()
    pending = false
    local copy = vim.tbl_values(sessions)
    for _, s in ipairs(copy) do
      local ok, err = pcall(paint, s)
      if not ok then
        M.close(s.source)
        vim.notify("obelus margin closed: " .. tostring(err), vim.log.levels.ERROR)
      end
    end
  end)
end

local function choose_cursor()
  local s = find()
  if not s or s.jumping or not valid(s) then
    return
  end
  local win = api.nvim_get_current_win()
  if win == s.win then
    local row = api.nvim_win_get_cursor(win)[1]
    if row ~= s.pane_row and s.row_ids[row] and s.row_ids[row] ~= s.active then
      s.active, s.seat = s.row_ids[row], true
    end
    s.pane_row = row
  else
    local cursor = api.nvim_win_get_cursor(win)
    local key = cursor[1] .. ":" .. cursor[2]
    if key == s.source_cursor then
      return
    end
    s.source_cursor = key
    local candidates = {}
    for _, item in ipairs(comments(s)) do
      local a = item.a
      if
        cursor[1] >= a.sl
        and cursor[1] <= a.el
        and (
          item.c.kind ~= "char" or ((cursor[1] > a.sl or cursor[2] >= a.sc) and (cursor[1] < a.el or cursor[2] < a.ec))
        )
      then
        candidates[#candidates + 1] = item.c.id
      end
    end
    -- Stable overlap selection in THIS pane only. The global renderer is untouched.
    if #candidates > 0 and not vim.tbl_contains(candidates, s.active) then
      s.active, s.seat = candidates[1], true
    end
  end
end

local function setup_events()
  if group then
    return
  end
  group = api.nvim_create_augroup("obelus_margin_preview", { clear = true })
  api.nvim_set_decoration_provider(view_ns, {
    on_win = function(_, win)
      local s = sessions[win]
      if s and valid(s) then
        local ok, current = pcall(signature, s)
        if ok and current ~= s.signature then
          s.signature = current
          M.refresh()
        end
      end
      return false
    end,
  })
  api.nvim_create_autocmd("QuitPre", {
    group = group,
    callback = function()
      local cur = api.nvim_get_current_win()
      local s = sessions[cur]
      if s then
        return M.close(s.source) -- :q on the last source must not strand its pane
      end
      s = find(cur) or composer_of(cur)
      if s then
        leave_insert()
        keep_draft(s) -- :q / :qa from the pane or the composer: the reply survives as a draft
      end
    end,
  })
  api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      -- :qa / :wqa from anywhere: the open reply is kept as a draft (SPEC A3 rule 6)
      for _, s in pairs(sessions) do
        pcall(settle_composer, s)
      end
    end,
  })
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinEnter" }, {
    group = group,
    callback = function()
      if composer_of(api.nvim_get_current_win()) then
        return -- typing/moving inside the inline composer never repaints the cards
      end
      choose_cursor()
      M.refresh()
    end,
  })
  api.nvim_create_autocmd({
    "WinScrolled",
    "WinResized",
    "VimResized",
    "BufWinEnter",
    "BufWinLeave",
    "BufFilePost",
    "WinClosed",
    "BufWipeout",
    "TabEnter",
  }, {
    group = group,
    callback = function(args)
      if args.event == "WinScrolled" and composer_of(tonumber(args.match)) then
        return -- the composer's own wrap scrolling is not a card-geometry change
      end
      local s
      if args.event == "WinClosed" then
        s = composer_of(tonumber(args.match))
      elseif args.event == "BufWipeout" then
        for _, candidate in pairs(sessions) do
          if candidate.composing and candidate.composing.buf == args.buf then
            s = candidate
            break
          end
        end
      end
      if s then
        -- :close / :only / :tabclose (unlike :q) skip QuitPre. Save synchronously,
        -- before the float's wipe-on-close buffer disappears.
        local cm = s.composing
        local cur = api.nvim_get_current_win()
        if cur == cm.win or cur == s.win then
          leave_insert()
        end
        local kept = keep_draft(s) == "kept"
        s.composing, s.seat = nil, true
        if kept and not s.closing then
          vim.schedule(function()
            -- render.compose's keys close the float BEFORE on_submit/on_cancel;
            -- those callbacks own the outcome, so external closes alone notify.
            if not cm.finished then
              vim.notify("obelus margin: composer closed; reply kept as draft", vim.log.levels.INFO)
            end
          end)
        end
      end
      M.refresh()
    end,
  })
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
    group = group,
    callback = function(args)
      -- Our scratch writes (and unrelated buffers) must not schedule themselves.
      for _, s in pairs(sessions) do
        if args.buf == s.buf then
          M.refresh()
          return
        end
      end
    end,
  })
  api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = {
      "wrap",
      "linebreak",
      "foldenable",
      "foldmethod",
      "foldlevel",
      "conceallevel",
      "number",
      "relativenumber",
      "winbar",
    },
    callback = M.refresh,
  })
  api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      -- scheduled so it always runs after thread.setup_highlights (init.lua's
      -- ColorScheme handler) has redefined the obelus groups we link to
      vim.schedule(function()
        local _, s = next(sessions)
        if not s then
          return
        end
        -- read the theme from the source window: the composer float's winhighlight
        -- remaps FloatTitle/Normal and would answer the probe with our own groups
        if api.nvim_win_is_valid(s.source) then
          api.nvim_win_call(s.source, highlights)
        else
          highlights()
        end
        M.refresh()
      end)
    end,
  })
end

local function safe(s)
  if api.nvim_buf_get_changedtick(s.buf) ~= s.tick or vim.bo[s.buf].modified then
    unsafe[s.buf] = true
  end
  if unsafe[s.buf] then
    vim.notify(
      "obelus margin preview: source edited; margin sends/reply entry are blocked for this buffer. Private marks track display only. Reopen a clean file after verifying saved review ranges; existing obelus commands are unchanged.",
      vim.log.levels.WARN
    )
    return false
  end
  return true
end

function M.select(id, win)
  local s = find(win)
  if not s then
    return
  end
  for _, item in ipairs(comments(s)) do
    if item.c.id == id then
      s.active, s.seat = id, true
      M.refresh()
      return true
    end
  end
end

function M.jump(win)
  local s = find(win)
  if not s or not s.active then
    return
  end
  local c = store.get(s.active)
  local a = c and anchor(s, c)
  if not a then
    return
  end
  -- Deleted EOF marks may sit one row past the buffer. Clamp navigation only;
  -- the edited-source send guard and persisted range remain unchanged.
  local line = math.min(a.sl, api.nvim_buf_line_count(s.buf))
  local text = api.nvim_buf_get_lines(s.buf, line - 1, line, false)[1] or ""
  s.jumping = true -- WinEnter must not select the OLD source cursor's comment.
  local ok, err = pcall(function()
    api.nvim_set_current_win(s.source)
    api.nvim_win_set_cursor(s.source, { line, math.min(a.sc, #text) })
    vim.cmd("normal! zvzz")
    local cursor = api.nvim_win_get_cursor(s.source)
    s.source_cursor = cursor[1] .. ":" .. cursor[2]
  end)
  s.jumping = nil
  if not ok then
    vim.notify("obelus margin: cannot jump to source: " .. tostring(err), vim.log.levels.WARN)
  end
  M.refresh()
end

function M.next(dir, win)
  local s = find(win)
  if not s then
    return
  end
  local list, index = comments(s), 1
  if #list == 0 then
    return
  end
  for i, item in ipairs(list) do
    if item.c.id == s.active then
      index = i
    end
  end
  index = (index - 1 + dir) % #list + 1
  s.active, s.seat = list[index].c.id, true
  local was = api.nvim_get_current_win()
  M.jump(s.source)
  if was == s.win then
    api.nvim_set_current_win(s.win)
  end
  M.refresh()
end

-- The inline reply (SPEC A3): seat the source on the card's range, reserve the
-- composer rows inside the card, then open render.compose's float there with the
-- card's own border so its bottom border closes the box. Focus flows pane ->
-- composer; render.compose hands it back to the pane when the float closes.
function open_composer(s, c)
  local review = require("obelus.review")
  if review.busy(c.id) then
    vim.notify("obelus margin: the agent is still replying — wait for it to finish", vim.log.levels.WARN)
    return false
  end
  -- The store has one draft per thread, even when several windows show it.
  for _, other in pairs(sessions) do
    local cm = other.composing
    if cm and cm.id == c.id and cm.win and api.nvim_win_is_valid(cm.win) then
      api.nvim_set_current_win(cm.win)
      return true
    end
  end
  settle_composer(s) -- another card's composer: keep its text as that card's draft
  local was = api.nvim_get_current_win()
  M.jump(s.source) -- scroll the source to the card's range (scoped jump guard)
  -- seat the range a quarter of the way down the window, exactly where
  -- render.arm_follow will keep it when the reply streams in, so the card does
  -- not move between <CR> and the agent's first chunk
  pcall(api.nvim_win_call, s.source, function()
    local sl0 = (c.range.sl or 1) - 1
    local view = vim.fn.winsaveview()
    view.topline = math.max(sl0 - math.floor(api.nvim_win_get_height(s.source) * 0.25), 0) + 1
    vim.fn.winrestview(view)
  end)
  if api.nvim_win_is_valid(s.win) then
    api.nvim_set_current_win(s.win)
  end
  local had_draft = reply_draft(c)
  local cm = { id = c.id, has_saved_draft = had_draft, status = c.status }
  s.composing, s.seat = cm, true
  local ok, err = pcall(paint, s) -- reserve the rows now so the float can be seated on the placed card
  if not ok then
    s.composing = nil
    if api.nvim_win_is_valid(was) then
      api.nvim_set_current_win(was)
    end
    M.close(s.source)
    vim.notify("obelus margin closed: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  if not (s.composing and s.composing.row) then
    s.composing = nil
    M.refresh()
    if api.nvim_win_is_valid(was) then
      api.nvim_set_current_win(was)
    end
    vim.notify("margin: pane too short for inline reply", vim.log.levels.WARN)
    return false
  end
  local config = require("obelus.config")
  local border = c.id == s.active and "ObelusMarginActive" or "ObelusMarginBorder"
  local id = c.id
  local function done()
    cm.finished = true
    if s.composing == cm then
      s.composing = nil
    end
    s.seat = true
    leave_insert() -- the pane we return to is nomodifiable
    M.refresh()
  end
  local fwin = require("obelus.render").compose({
    title = "reply",
    height = COMPOSER_HEIGHT,
    anchor = { win = s.win, row = s.composing.row, col = LANES + 2, width = api.nvim_win_get_width(s.win) - LANES - 4 },
    border = { "├", "─", "┤", "│", "╯", "─", "╰", "│" },
    title_hl = border,
    zindex = config.z.INPUT or config.z.OVERLAY,
    default = had_draft and store.pending_you_text(c) or nil,
    on_submit = function(text, action)
      apply_draft(id, text, cm.has_saved_draft) -- the draft persists even if the send is refused
      if action ~= "save" then
        local cur = store.get(id)
        if api.nvim_buf_is_valid(s.buf) and not safe(s) then
          return done() -- the source was edited while the composer was open: draft only
        end
        if cur and review.busy(id) then
          vim.notify("obelus margin: the agent is still replying — reply kept as draft", vim.log.levels.WARN)
        else
          -- the composer's <M-CR> means "fast" here as everywhere else
          require("obelus").chat_send(id, text, action == "send_fast" and "fast" or "send")
        end
      end
      done()
    end,
    on_cancel = function(text)
      apply_draft(id, text, cm.has_saved_draft)
      done()
    end,
  })
  s.composing.win, s.composing.buf = fwin, api.nvim_win_get_buf(fwin)
  vim.wo[fwin].winhighlight = "Normal:ObelusInput,NormalFloat:ObelusInput,SignColumn:ObelusInput,FloatBorder:"
    .. border
    .. ",FloatTitle:"
    .. border
    .. ",EndOfBuffer:ObelusInput"
  M.refresh()
  return true
end

function M.action(name, win)
  local s = find(win)
  if s and not valid(s) then
    return M.close(s.source)
  end
  local c = s and s.active and store.get(s.active)
  if not c then
    return
  end
  if name == "check" then
    s.checked[c.id] = not s.checked[c.id] or nil
    return M.refresh()
  end
  if name == "expand" then
    s.expanded[c.id] = not s.expanded[c.id]
    return M.refresh()
  end
  if name == "reply" or name == "thread" or name == "dispatch" or name == "batch" then
    if not safe(s) then
      return false
    end
  end
  if name == "reply" then
    return open_composer(s, c)
  end
  if s.composing and s.composing.id == c.id and name ~= "batch" and name ~= "dispatch" then
    -- a status change on the composing card: keep the text as its draft first, so
    -- the resolve/delete wins and the thread popup opens on a single editor
    settle_composer(s)
  end
  if name == "thread" then
    -- The full thread window (the pre-margin reply path), rooted in the SOURCE.
    M.jump(s.source)
    require("obelus.panel").open_thread(c.id, true)
    local cursor = api.nvim_win_get_cursor(s.source)
    s.source_cursor = cursor[1] .. ":" .. cursor[2]
  elseif name == "toggle_resolved" then
    require("obelus.review")[c.status == "resolved" and "reopen" or "resolve"](c.id)
  elseif name == "batch" then
    local list = comments(s) -- prune hidden checks before deciding the fallback
    local selected, checked = {}, next(s.checked) ~= nil
    for _, item in ipairs(list) do
      if (checked and s.checked[item.c.id]) or (not checked and item.c.id == s.active) then
        if item.c.ask or item.c.scratch or item.c.status == "resolved" or require("obelus.review").busy(item.c.id) then
          vim.notify("obelus margin: uncheck ask/resolved/busy threads before batching", vim.log.levels.WARN)
          return false
        end
        selected[#selected + 1] = item.c
      end
    end
    if #selected > 0 then
      require("obelus.review").submit(nil, { comments = selected })
    end
  elseif name == "dispatch" or name == "resolve" or name == "reopen" or name == "delete" or name == "cancel" then
    require("obelus.review")[name](c.id)
  end
  M.refresh()
end

function M.focus(win)
  local s = find(win)
  if s then
    if composer_of(api.nvim_get_current_win()) then
      leave_insert()
    end
    api.nvim_set_current_win(s.win)
    s.seat = true
    M.refresh()
  end
end

-- True while a margin is open for this source window: the margin IS the preview
-- there, so render.on_cursor skips the hover float (SPEC A4; critic.md G1).
function M.suppresses_preview(win)
  local s = win and sessions[win]
  return s ~= nil and valid(s)
end

local function maps(s)
  local config = require("obelus.config")
  local function map(key, fn, desc, opts)
    if not key then
      return -- keys.list[name] = false disables the verb here as well
    end
    vim.keymap.set(
      "n",
      key,
      fn,
      vim.tbl_extend(
        "force",
        { buffer = s.pane, silent = true, nowait = true, desc = "obelus margin: " .. desc },
        opts or {}
      )
    )
  end
  local function act(name)
    return function()
      M.action(name, s.source)
    end
  end
  -- single keys: the keys.list names that exist resolve through config.list_key, so
  -- a user rebind/disable applies to the pane too; <CR> stays reply here
  map("<CR>", act("reply"), "reply")
  map(config.list_key("reply", "r"), act("reply"), "reply")
  map(config.list_key("dispatch", "D"), act("dispatch"), "dispatch")
  map(config.list_key("resolve", "x"), act("resolve"), "resolve")
  map(config.list_key("reopen", "o"), act("reopen"), "reopen")
  map(config.list_key("delete", "dd"), act("delete"), "delete")
  map(config.list_key("cancel", "C"), act("cancel"), "cancel")
  map("s", act("batch"), "batch")
  map("<Space>", act("check"), "check", { nowait = false }) -- plain <Space> may be the leader
  map(config.list_key("expand", "<Tab>"), act("expand"), "expand")
  map(config.list_key("jump", "gd"), function()
    M.jump(s.source)
  end, "source")
  map(config.list_key("close", "q"), function()
    M.close(s.source)
  end, "close")
  map(config.list_key("refresh", "R"), M.refresh, "refresh")
  map("]c", function()
    M.next(1, s.source)
  end, "next comment")
  map("[c", function()
    M.next(-1, s.source)
  end, "previous comment")
  local function scroll(dir)
    return function()
      if s.active then
        local max = s.extent[s.active] or 0
        s.offset[s.active] = math.max(0, math.min(max, (s.offset[s.active] or max) + dir * 3))
        M.refresh()
      end
    end
  end
  map("J", scroll(1), "scroll card")
  map("K", scroll(-1), "scroll card")
  -- pane-local <leader>o… aliases (SPEC A5): the same handlers as the single keys
  map("<leader>od", act("dispatch"), "dispatch selected")
  map("<leader>os", act("batch"), "batch checked")
  map("<leader>or", act("reply"), "reply")
  map("<leader>ox", act("delete"), "delete selected")
  map("<leader>oR", act("toggle_resolved"), "resolve/reopen")
  map("<leader>oC", act("cancel"), "cancel")
  map("<leader>oh", function()
    require("obelus.render").toggle_resolved()
  end, "toggle resolved")
  map("<leader>oo", act("thread"), "open full thread")
  map("<leader>oJ", scroll(1), "scroll card")
  map("<leader>oK", scroll(-1), "scroll card")
  for key, command in pairs({
    ["<C-e>"] = "\5",
    ["<C-y>"] = "\25",
    ["<C-d>"] = "\4",
    ["<C-u>"] = "\21",
    ["<ScrollWheelDown>"] = "3\5",
    ["<ScrollWheelUp>"] = "3\25",
  }) do
    map(key, function()
      api.nvim_win_call(s.source, function()
        vim.cmd.normal({ args = { command }, bang = true })
      end)
      M.refresh()
    end, "scroll source and cards")
  end
  map("?", function()
    local text = "Margin preview: j/k onto a card or click selects · [c/]c previous/next · gd source · Ctrl-w h/l switch panes\n"
      .. "Enter/r reply inside the card (insert mode; Esc Esc keeps the draft, Esc Enter sends, C-s saves, M-CR fast send)\n"
      .. "Closing the inline reply returns to normal mode, also from Replace/Virtual Replace.\n"
      .. "D send selected · Space check · s batch checked (else selected) · x resolve · o reopen · dd delete · C cancel\n"
      .. "Tab expand · J/K card scroll · Ctrl-d/u/e/y or wheel scroll source · R refresh · q close · :ObelusMargin [on|off]\n"
      .. "Aliases: <leader>od send · os batch · or reply · ox delete · oR resolve/reopen · oC cancel\n"
      .. "oh show/hide resolved · oo full thread (q returns to source) · oJ/oK card scroll\n"
      .. "Delete a draft: r, clear the text (Esc then ggdG), Esc. Saving a draft marks the thread open again. Accent = the active card; its source range is tinted.\n"
      .. "FAKE transport only when launched via preview.sh. Cursor/click activation; no passive hover."
    -- Neovim hard-wraps notifications, even inside shortcut tokens. Wrap this
    -- margin-only help at spaces first, leaving the last screen cell free.
    local lines, width = {}, math.max(1, vim.o.columns - 1)
    for paragraph in text:gmatch("[^\n]+") do
      local line = ""
      for word in paragraph:gmatch("%S+") do
        if line ~= "" and cells(line .. " " .. word) > width then
          lines[#lines + 1], line = line, ""
        end
        line = line == "" and word or (line .. " " .. word)
      end
      lines[#lines + 1] = line
    end
    vim.notify(table.concat(lines, "\n"))
  end, "help")
end

function M.open()
  local existing = find() or composer_of(api.nvim_get_current_win())
  if existing then
    return M.focus(existing.source)
  end
  local source, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  local file = require("obelus.nav").abspath(api.nvim_buf_get_name(buf))
  if not file or vim.bo[buf].buftype ~= "" or api.nvim_win_get_config(source).relative ~= "" then
    return vim.notify("obelus margin: open a named file in a normal window first", vim.log.levels.WARN)
  end
  if api.nvim_win_get_width(source) < 64 then
    return vim.notify("obelus margin: source window needs at least 64 columns", vim.log.levels.WARN)
  end
  highlights()
  require("obelus.panel").hide_preview() -- the margin takes over as this window's preview (SPEC A4)
  local width = math.min(62, math.max(28, math.floor(api.nvim_win_get_width(source) * 0.43)))
  vim.cmd("rightbelow " .. width .. "vnew")
  local win, pane = api.nvim_get_current_win(), api.nvim_get_current_buf()
  vim.bo[pane].buftype, vim.bo[pane].bufhidden, vim.bo[pane].swapfile = "nofile", "wipe", false
  vim.bo[pane].filetype, vim.bo[pane].modifiable = "obelus_margin", false
  vim.bo[pane].undolevels = -1 -- streaming repaints must not accumulate scratch undo history
  for key, value in pairs({
    wrap = false,
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldcolumn = "0",
    foldenable = false,
    cursorline = false,
    list = false,
    spell = false,
    winfixwidth = true,
    scrolloff = 0,
    sidescrolloff = 0,
    winbar = "",
    winhighlight = pane_winhl(),
  }) do
    vim.wo[win][key] = value
  end
  local s = {
    source = source,
    buf = buf,
    win = win,
    pane = pane,
    file = file,
    ns = api.nvim_create_namespace("obelus_margin_anchor_" .. source),
    anchors = {},
    anchor_records = {},
    checked = {},
    offset = {},
    expanded = {},
    extent = {},
    row_ids = {},
    tick = api.nvim_buf_get_changedtick(buf),
    matches = {},
    seat = true,
  }
  sessions[source] = s
  setup_events()
  maps(s)
  api.nvim_set_current_win(source)
  choose_cursor()
  M.refresh()
  return win
end

function M.toggle(on)
  local s = find() or composer_of(api.nvim_get_current_win())
  if on == false or (on == nil and s) then
    return M.close(s and s.source)
  end
  return M.open()
end

-- Introspection for focused integration tests; not persisted or part of the store.
function M._state(win)
  return find(win)
end
return M
