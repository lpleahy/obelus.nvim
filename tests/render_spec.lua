-- render: inline annotation extmarks (signs, line/char highlight, resolved/toggle
-- state, position drift) + collapsible inline "band" virt_lines threads (cap,
-- pagination, scrolling) and their supporting lookups (file_buf_map/is_expanded).
T.describe("render")

local render = require("obelus.render")
local ns = vim.api.nvim_create_namespace("obelus")
local ns_band = vim.api.nvim_create_namespace("obelus_band")

-- A real file in a real window (extmarks/virt_lines need both). The comment's
-- `file` must match what render.lua's internal abspath() will compute from the
-- buffer's own name — fnamemodify(path, ":p") on tempname() itself can disagree
-- (e.g. macOS resolves /var -> /private/var on :edit but ":p" alone doesn't), so
-- derive `file` from the buffer's name post-edit rather than the pre-edit string.
local function open_file(lines)
  local path = vim.fn.tempname() .. ".lua"
  vim.fn.writefile(lines, path)
  vim.cmd.edit(path)
  local buf = vim.api.nvim_get_current_buf()
  local file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":p")
  return buf, file
end

local function sample_lines()
  local out = {}
  for i = 1, 20 do
    out[i] = "line " .. i .. " = " .. i
  end
  return out
end

local function extmarks(buf, namespace)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })) do
    out[#out + 1] = { id = m[1], row = m[2], col = m[3], d = m[4] }
  end
  return out
end

local function marks_at(buf, namespace, row0)
  return vim.tbl_filter(function(m)
    return m.row == row0
  end, extmarks(buf, namespace))
end

local function flatten(row)
  local s = ""
  for _, chunk in ipairs(row) do
    s = s .. (chunk[1] or "")
  end
  return s
end

-- 1. PLACE LINEWISE ----------------------------------------------------------

T.it("place linewise: sign + ObelusThreadBg on every row of the range", function()
  T.fresh()
  local buf, file = open_file(sample_lines())
  require("obelus.store").add(T.comment({ file = file, range = { sl = 3, el = 5 }, kind = "line" }))
  render.render_buffer(buf)
  for _, row0 in ipairs({ 2, 3, 4 }) do
    local m = marks_at(buf, ns, row0)[1]
    T.ok(m, "extmark on row " .. row0)
    T.ok(m.d.sign_text and m.d.sign_text:find("▌", 1, true), "sign_text on row " .. row0)
    T.eq(m.d.line_hl_group, "ObelusThreadBg")
  end
end)

-- 2. PLACE CHARWISE -----------------------------------------------------------

T.it("place charwise: precise char span with end_col + ObelusRangeText", function()
  T.fresh()
  local buf, file = open_file(sample_lines())
  require("obelus.store").add(T.comment({ file = file, kind = "char", range = { sl = 2, el = 2, sc = 3, ec = 7 } }))
  render.render_buffer(buf)
  local m = marks_at(buf, ns, 1)[1]
  T.ok(m, "extmark on row 1")
  T.eq(m.col, 2)
  T.eq(m.d.end_row, 1)
  T.eq(m.d.end_col, 7)
  T.eq(m.d.hl_group, "ObelusRangeText")
end)

-- 2.5 THE PROJECT (META) THREAD NEVER GETS AN IN-FILE BAND ---------------------

T.it("place: never places anything for the meta record, even called directly", function()
  local ctx = T.fresh()
  local buf, _ = open_file(sample_lines())
  local meta = ctx.store.meta_thread()
  render.place(buf, meta)
  T.eq(#extmarks(buf, ns), 0, "no extmark landed for the meta record")
end)

-- 3. RESOLVED HIDDEN -----------------------------------------------------------

T.it("resolved comments show only a checkmark sign until toggle_resolved shows them", function()
  local ctx = T.fresh()
  local buf, file = open_file(sample_lines())
  ctx.store.add(T.comment({ file = file, range = { sl = 3, el = 3 }, status = "resolved" }))
  render.render_buffer(buf)

  local rows = extmarks(buf, ns)
  T.eq(#rows, 1, "only the gutter checkmark, no line band")
  T.ok(rows[1].d.sign_text and rows[1].d.sign_text:find("✓", 1, true))
  T.is_nil(rows[1].d.line_hl_group)

  render.toggle_resolved() -- shown: full annotation (line band) returns
  local shown = false
  for _, m in ipairs(extmarks(buf, ns)) do
    if m.d.line_hl_group == "ObelusThreadBg" then
      shown = true
    end
  end
  T.ok(shown, "ObelusThreadBg present once resolved comments are shown")

  render.toggle_resolved() -- toggles back to hidden (default)
  local hidden_again = extmarks(buf, ns)
  T.eq(#hidden_again, 1)
  T.ok(hidden_again[1].d.sign_text and hidden_again[1].d.sign_text:find("✓", 1, true))
end)

-- 4. TOGGLE ---------------------------------------------------------------------

T.it("toggle hides/restores extmarks: per-buffer, then global", function()
  local ctx = T.fresh()
  local buf, file = open_file(sample_lines())
  ctx.store.add(T.comment({ file = file, range = { sl = 2, el = 2 } }))
  render.render_buffer(buf)
  T.ok(#extmarks(buf, ns) > 0, "extmarks present before toggle")

  render.toggle() -- buffer scope
  T.eq(#extmarks(buf, ns), 0)
  render.toggle()
  T.ok(#extmarks(buf, ns) > 0, "restored after second buffer toggle")

  render.toggle("global")
  T.eq(#extmarks(buf, ns), 0)
  render.toggle("global") -- net zero: leaves M.enabled as it was for later specs
  T.ok(#extmarks(buf, ns) > 0, "restored after second global toggle")
end)

-- 5. SYNC_POSITIONS ---------------------------------------------------------------

T.it("sync_positions re-reads a drifted extmark row back into the store", function()
  local ctx = T.fresh()
  local buf, file = open_file(sample_lines())
  local c = ctx.store.add(T.comment({ file = file, range = { sl = 5, el = 5 } }))
  render.render_buffer(buf)
  T.ok(c.extmark_id, "extmark placed")

  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "x = 1", "y = 2", "z = 3" })
  render.sync_positions(buf)
  T.eq(c.range.sl, 8)
  T.eq(c.range.el, 8) -- shifted by the same delta as sl
end)

-- 6. AT_CURSOR ------------------------------------------------------------------

T.it("at_cursor covers the live range and follows it after drift", function()
  local ctx = T.fresh()
  local buf, file = open_file(sample_lines())
  local c = ctx.store.add(T.comment({ file = file, range = { sl = 5, el = 5 } }))
  render.render_buffer(buf)

  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  T.eq((render.at_cursor() or {}).id, c.id)

  vim.api.nvim_win_set_cursor(0, { 10, 0 })
  T.is_nil(render.at_cursor())

  -- push the comment down 3 lines and resync; at_cursor must track the NEW position
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "x = 1", "y = 2", "z = 3" })
  render.sync_positions(buf)
  T.eq(c.range.sl, 8)
  vim.api.nvim_win_set_cursor(0, { 8, 0 })
  T.eq((render.at_cursor() or {}).id, c.id)
  vim.api.nvim_win_set_cursor(0, { 5, 0 }) -- the OLD position no longer covers it
  T.is_nil(render.at_cursor())
end)

-- 7. BANDS INLINE -----------------------------------------------------------------

T.it("inline band: virt_lines render only while the cursor covers the comment", function()
  local ctx = T.fresh({ render = { bands = { style = "inline" } } })
  local buf, file = open_file(sample_lines())
  local c = ctx.store.add(T.comment({ file = file, range = { sl = 3, el = 3 }, comment = "please review" }))
  ctx.store.add_turn(c.id, "agent", "looks fine")
  render.render_buffer(buf)

  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  render.render_bands(buf)
  local bm = extmarks(buf, ns_band)
  T.eq(#bm, 1, "one band extmark while the cursor covers the comment")
  local vl = bm[1].d.virt_lines
  T.ok(vl and #vl > 0, "virt_lines present")
  T.eq(#vl[1], 1, "separator row is a single chunk")
  T.eq(vl[1][1][1], "", "separator row's chunk text is empty")

  vim.api.nvim_win_set_cursor(0, { 15, 0 }) -- off the comment: focus mode covers nothing
  render.render_bands(buf)
  T.eq(#extmarks(buf, ns_band), 0, "no band extmark once the cursor leaves the comment")
end)

-- 8. CAP + PAGINATION ---------------------------------------------------------------

T.it("long threads paginate: capped virt_lines with ⋯ indicators; scroll_band moves and clamps", function()
  local ctx = T.fresh({ render = { bands = { style = "inline" } } })
  local buf, file = open_file(sample_lines())
  local c = ctx.store.add(T.comment({ file = file, range = { sl = 3, el = 3 }, comment = "kick off the thread" }))
  for i = 1, 40 do
    ctx.store.add_turn(c.id, "agent", "reply " .. i)
  end
  render.render_buffer(buf)
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  render.render_bands(buf)

  -- mirror render.lua's private band_cap()/cap_rows() math exactly, from the live
  -- window height + config, instead of hard-coding a row count that only holds in
  -- one particular terminal size.
  local win = vim.api.nvim_get_current_win()
  local h = vim.api.nvim_win_get_height(win)
  local mh = ctx.config.options.render.bands.max_height
  local cap
  if not mh or mh <= 0 then
    cap = math.max(8, math.floor(h * 0.6))
  elseif mh < 1 then
    cap = math.max(4, math.floor(h * mh))
  else
    cap = math.floor(mh)
  end

  local function band_virt_lines()
    local bm = extmarks(buf, ns_band)
    T.eq(#bm, 1)
    return bm[1].d.virt_lines
  end

  local vl = band_virt_lines()
  -- cap rows (2 ⋯ indicators + (cap - 2) content rows) + 1 blank separator prepended
  -- by render_bands (outside the cap, per cap_rows' own accounting)
  T.eq(#vl, cap + 1)
  T.contains(flatten(vl[2]), "⋯", "first content row (after the separator) is the top indicator")
  T.contains(flatten(vl[#vl]), "⋯", "last row is the bottom indicator")

  local above_before = tonumber(flatten(vl[2]):match("(%d+) above"))
  T.ok(above_before and above_before > 0, "stuck to the bottom: rows hidden above > 0")

  render.scroll_band(-1) -- dir<0 = up, toward earlier turns
  local above_after = tonumber(flatten(band_virt_lines()[2]):match("(%d+) above"))
  T.ok(above_after and above_after < above_before, "scrolling up drops the 'N above' count")

  for _ = 1, 40 do -- far more than enough steps to walk the offset down to 0
    render.scroll_band(-1)
  end
  T.contains(flatten(band_virt_lines()[2]), "top of thread", "offset clamps at 0")
end)

-- 9. POPUP STYLE ------------------------------------------------------------------

T.it("popup style (the default) renders no inline band extmarks", function()
  local ctx = T.fresh() -- default render.bands.style == "popup"
  local buf, file = open_file(sample_lines())
  local c = ctx.store.add(T.comment({ file = file, range = { sl = 3, el = 3 } }))
  ctx.store.add_turn(c.id, "agent", "ack")
  render.render_buffer(buf)
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  render.render_bands(buf)
  T.eq(#extmarks(buf, ns_band), 0)
end)

-- 10. FILE_BUF_MAP ------------------------------------------------------------------

T.it("file_buf_map resolves the edited file's bufnr; is_expanded agrees with/without it", function()
  local ctx = T.fresh()
  local buf, file = open_file(sample_lines())
  local c = ctx.store.add(T.comment({ file = file, range = { sl = 3, el = 3 } }))

  local map = render.file_buf_map()
  T.eq(map[file], buf)

  T.eq(render.is_expanded(c), false) -- no panel open
  T.eq(render.is_expanded(c, map), render.is_expanded(c))
end)
