-- markview integration — SKIPPED unless markview.nvim (and its treesitter dep) are on the
-- runtimepath. Run these with:  OBELUS_TEST_RTP=/path/to/markview.nvim:/path/to/nvim-treesitter make test
T.describe("markview")

local has_mv = pcall(require, "markview")

local function chat_buffer()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "obelus_reply" then
      local pw = vim.api.nvim_win_get_config(w).win
      pw = (type(pw) == "table") and (pw[false] or pw[1] or pw[true]) or pw
      if pw and vim.api.nvim_win_is_valid(pw) then
        return vim.api.nvim_win_get_buf(pw)
      end
    end
  end
end

local function markview_decos(buf)
  local n = 0
  for name, ns in pairs(vim.api.nvim_get_namespaces()) do
    if name:lower():find("markview", 1, true) then
      local ok, ms = pcall(vim.api.nvim_buf_get_extmarks, buf, ns, 0, -1, {})
      if ok then
        n = n + #ms
      end
    end
  end
  return n
end

T.it_when(has_mv, "markview mode renders DETACHED but with decorations", function()
  local mv = require("markview")
  pcall(mv.setup, { preview = { filetypes = { "markdown" } } })
  local mvstate = require("markview.state")
  local ctx = T.fresh({ render = { renderer = "markview" } })
  local file = ctx.root .. "/f.lua"
  vim.fn.writefile({ "local a = 1" }, file)
  vim.cmd("edit " .. file)
  local fabs = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
  local c = ctx.store.add(T.comment({ file = fabs, range = { sl = 1, el = 1 } }))
  ctx.store.add_turn(c.id, "agent", "## Heading\n\n`inline` and a table:\n\n| A | B |\n| --- | --- |\n| 1 | 2 |")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local panel = require("obelus.panel")
  panel.open_thread(c.id, true)
  for _ = 1, 5 do
    vim.cmd("redraw")
    vim.wait(30)
  end
  local buf = chat_buffer()
  T.ok(buf, "chat buffer exists")
  -- obelus drives markview manually: it must NOT be attached (else its auto-render would
  -- fight the scoped config), yet its decorations must be present.
  T.eq(mvstate.buf_attached(buf), false, "markview should be detached")
  T.ok(markview_decos(buf) > 0, "markview rendered decorations")
  -- G / cursor churn must not change the decoration count (no auto-render leak)
  local before = markview_decos(buf)
  vim.api.nvim_win_call(vim.fn.win_findbuf(buf)[1] or 0, function()
    pcall(vim.cmd, "normal! gg")
    pcall(vim.cmd, "normal! G")
  end)
  vim.cmd("redraw")
  T.eq(markview_decos(buf), before, "decorations stable across cursor movement")
  panel.close()
end)

T.it_when(has_mv, "tables render FULL (concealed pipes) in the wrapped chat, conceallevel survives", function()
  local ctx = T.fresh({ render = { renderer = "markview" } })
  local panel = require("obelus.panel")
  panel._timing.fill_throttle = 0
  local c = ctx.store.add(T.comment({ comment = "table please" }))
  ctx.store.add_turn(c.id, "agent", "| Day | Weather |\n| --- | --- |\n| Mon | Sunny |")
  panel.open_thread(c.id, false)
  T.ok(
    T.wait_for(function()
      local g = panel.geom()
      return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
    end, 2000),
    "chat opened"
  )
  vim.cmd("redraw")
  local g = panel.geom()
  -- markview's detach used to restore conceallevel to 0 AFTER apply_winopts set 2,
  -- and coalesced fills never re-asserted it — conceal marks then showed raw text
  T.eq(vim.wo[g.win].conceallevel, 2, "conceallevel survives markview's detach-time option restore")
  T.eq(vim.wo[g.win].wrap, true, "the wrap-bracket around the render restored wrap")
  -- markview degrades table interiors in wrapped windows (no pipe conceal marks);
  -- the wrap-bracketed render must produce the FULL marks: at least one conceal
  -- mark ON a table row (a pipe replaced by a border glyph)
  T.ok(
    T.wait_for(function()
      for name, ns in pairs(vim.api.nvim_get_namespaces()) do
        if name:find("markview", 1, true) then
          for _, m in ipairs(vim.api.nvim_buf_get_extmarks(g.buf, ns, 0, -1, { details = true })) do
            if (m[4] or {}).conceal ~= nil then
              return true
            end
          end
        end
      end
      return false
    end, 2000),
    "table interior conceal marks exist (full markview table rendering)"
  )
  panel.close()
end)

T.it_when(has_mv, "an over-wide table's rows are pre-fit so they never physically wrap (fit_table_cells)", function()
  local ctx = T.fresh({ render = { renderer = "markview" } })
  local panel = require("obelus.panel")
  panel._timing.fill_throttle = 0
  local c = ctx.store.add(T.comment({ comment = "table please" }))
  ctx.store.add_turn(
    c.id,
    "agent",
    "| Name | Description | Notes |\n| --- | --- | --- |\n| Alice | " .. string.rep("z", 80) .. " | ok |"
  )
  panel.open_thread(c.id, false) -- sidebar: a narrow split, so an unfit table would wrap for sure
  T.ok(
    T.wait_for(function()
      local g = panel.geom()
      return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
    end, 2000),
    "chat opened"
  )
  vim.cmd("redraw")
  local g = panel.geom()
  local win_width = vim.api.nvim_win_get_width(g.win)

  -- (a) no physical wrap ON THE TABLE: every REAL buffer line that's part of the
  -- table (raw `| ... |` markdown — markview draws OVER it via conceal/virt_text
  -- rather than rewriting the buffer) fits inside the window's actual width. Scoped
  -- to table rows, not every line in the buffer: obelus's own " ◆ file  range
  -- [status]" split header is plain text that's ALLOWED to wrap normally (only a
  -- table's box-drawing breaks when markview wraps it — see fit_table_cells'
  -- doc comment) and isn't part of what this layer fits.
  local saw_table_row = false
  for _, l in ipairs(vim.api.nvim_buf_get_lines(g.buf, 0, -1, false)) do
    if l:match("^%s*|.*|%s*$") then
      saw_table_row = true
      T.ok(vim.fn.strdisplaywidth(l) <= win_width, "table row within window width (" .. win_width .. "): " .. l)
    end
  end
  T.ok(saw_table_row, "the table's rows were actually found in the buffer")

  -- (b) the full table render survived the pre-fit: markview conceal marks exist
  -- (same probe as the "renders FULL" spec above) — proof this didn't just dodge
  -- wrap by degrading the table into raw, unconcealed text
  T.ok(
    T.wait_for(function()
      for name, ns in pairs(vim.api.nvim_get_namespaces()) do
        if name:find("markview", 1, true) then
          for _, m in ipairs(vim.api.nvim_buf_get_extmarks(g.buf, ns, 0, -1, { details = true })) do
            if (m[4] or {}).conceal ~= nil then
              return true
            end
          end
        end
      end
      return false
    end, 2000),
    "table interior conceal marks exist despite the pre-fit"
  )
  panel.close()
end)

T.it_when(has_mv, "a 5-column over-wide table doesn't wrap RENDERED (ncol-aware markview margin)", function()
  -- markview's rendered row is ~ncol+1 cells wider than the raw text (its own
  -- inter-column padding + corner overhang) — a flat margin fit 3 columns but
  -- every >=4-column table still physically wrapped once rendered. Assert on the
  -- RENDERED height (text_height == 1 per row), not the raw width.
  local ctx = T.fresh({ render = { renderer = "markview" } })
  local panel = require("obelus.panel")
  panel._timing.fill_throttle = 0
  -- a 5-column table needs ~37 text cells even at the 3-cell column floor; the
  -- default headless 80-col editor gives the sidebar only ~33, where the fit is
  -- LEGITIMATELY impossible (best-effort floor — the table wraps like any other
  -- unfittable content). Widen the editor so the fit is feasible and the assertion
  -- exercises the ncol margin math, not the floor.
  local saved_columns = vim.o.columns
  vim.o.columns = 140
  local c = ctx.store.add(T.comment({ comment = "wide table" }))
  ctx.store.add_turn(
    c.id,
    "agent",
    "| one | two | three | four | five |\n| --- | --- | --- | --- | --- |\n| "
      .. string.rep("a", 30)
      .. " | bb | cc | dd | "
      .. string.rep("e", 30)
      .. " |"
  )
  panel.open_thread(c.id, false)
  local opened = T.wait_for(function()
    local g = panel.geom()
    return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
  end, 2000)
  if not opened then
    vim.o.columns = saved_columns
  end
  T.ok(opened, "chat opened")
  -- wait for markview's async marks so text_height measures the RENDERED rows
  local g = panel.geom()
  T.wait_for(function()
    for name, ns in pairs(vim.api.nvim_get_namespaces()) do
      if name:find("markview", 1, true) and #vim.api.nvim_buf_get_extmarks(g.buf, ns, 0, -1, {}) > 0 then
        return true
      end
    end
    return false
  end, 2000)
  vim.cmd("redraw")
  local lines = vim.api.nvim_buf_get_lines(g.buf, 0, -1, false)
  local saw = false
  local all_single = true
  local bad
  for i, l in ipairs(lines) do
    if l:match("^%s*|.*|%s*$") then
      saw = true
      local ok, th = pcall(vim.api.nvim_win_text_height, g.win, { start_row = i - 1, end_row = i - 1 })
      if not (ok and th and th.all == 1) then
        all_single = false
        bad = l
      end
    end
  end
  vim.o.columns = saved_columns
  T.ok(saw, "the table's rows were found")
  T.ok(all_single, "every rendered table row occupies exactly one screen row" .. (bad and (": " .. bad) or ""))
end)
