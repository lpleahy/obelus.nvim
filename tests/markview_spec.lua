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

-- portability audit helpers (strip_bg/@punctuation independence) --------------
-- Every hl_group/line_hl_group/sign_hl_group and virt_text/virt_lines chunk hl
-- markview's OWN extmarks reference in `buf` — the exact walk the Phase-1 audit
-- probe used, kept here so the pinning specs below exercise the SAME surface.
local function collect_markview_groups(buf)
  local groups = {}
  local function add(g)
    if g and g ~= "" then
      groups[g] = true
    end
  end
  for name, nsid in pairs(vim.api.nvim_get_namespaces()) do
    if name:lower():find("markview", 1, true) then
      local ok, marks = pcall(vim.api.nvim_buf_get_extmarks, buf, nsid, 0, -1, { details = true })
      if ok then
        for _, m in ipairs(marks) do
          local d = m[4] or {}
          add(d.hl_group)
          add(d.line_hl_group)
          add(d.sign_hl_group)
          if d.virt_text then
            for _, chunk in ipairs(d.virt_text) do
              add(chunk[2])
            end
          end
          if d.virt_lines then
            for _, line in ipairs(d.virt_lines) do
              for _, chunk in ipairs(line) do
                add(chunk[2])
              end
            end
          end
        end
      end
    end
  end
  return groups
end

-- parse a window's 'winhighlight' into a {hl-from -> hl-to} map
local function parse_winhl(win)
  local raw = vim.wo[win].winhighlight or ""
  local map = {}
  for pair in raw:gmatch("[^,]+") do
    local from, to = pair:match("^([^:]+):(.+)$")
    if from then
      map[from] = to
    end
  end
  return map
end

-- a group's EFFECTIVE fg/bg accounting for the window's winhighlight remap: a
-- group remapped by `winhl` resolves through its target; an unmapped group
-- resolves globally (link=false follows markview's own internal `{link=...}`
-- chains, e.g. MarkviewTableHeader -> @markup.heading -> ...).
local function effective_hl(winhl, name)
  local target = winhl[name]
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = target or name, link = false })
  if not ok or not hl then
    return nil, nil, target
  end
  return hl.fg, hl.bg, target
end

-- rich markdown covering every element the portability audit cares about:
-- headings, fenced+inline code, a FITTING table, an UNFITTABLE one (5 cols in a
-- narrow window — exercises markview's degraded/wrapped table path), a
-- blockquote, a bullet list, bold/italic, and a horizontal rule (whose gap glyph
-- is the always-undefined MarkviewIcon3Fg — see thread.lua's markview_harmonize).
local RICH_MD = table.concat({
  "# H1 Heading",
  "## H2 Heading",
  "### H3 Heading",
  "",
  "Some **bold** and *italic* text.",
  "",
  "```lua",
  "local function foo()",
  "  return 1",
  "end",
  "```",
  "",
  "Inline `code span` here.",
  "",
  "| A | B |",
  "| --- | --- |",
  "| 1 | 2 |",
  "",
  "| One | Two | Three | Four | Five |",
  "| --- | --- | --- | --- | --- |",
  "| aaaaaaaaaa | bbbbbbbbbb | cccccccccc | dddddddddd | eeeeeeeeee |",
  "",
  "> A blockquote line.",
  "",
  "- bullet one",
  "- bullet two",
  "",
  "---",
}, "\n")

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

-- ---------------------------------------------------------------------------
-- Portability: vanilla markview (plain setup({}), no personal user config) must
-- render obelus chats correctly WITHOUT help from the two global repairs some
-- users' dotfiles apply — stripping bg from Markview* groups on a transparent
-- setup, and pinning @punctuation.special.markdown's fg. obelus must carry
-- equivalent guarantees itself, scoped to its own windows.
-- ---------------------------------------------------------------------------

T.it_when(
  has_mv,
  "PORTABILITY: transparent Normal — no markview-referenced group leaks a bg outside an Obelus_ twin",
  function()
    vim.api.nvim_set_hl(0, "Normal", {}) -- bg NONE (transparent terminal), same as chat_spec's pattern
    local ok, err = pcall(function()
      local ctx = T.fresh({ render = { renderer = "markview", transparent = true } })
      local panel = require("obelus.panel")
      panel._timing.fill_throttle = 0
      local c = ctx.store.add(T.comment({ comment = "rich" }))
      ctx.store.add_turn(c.id, "agent", RICH_MD)
      panel.open_thread(c.id, false) -- sidebar: default width is narrow enough the 5-col table can't fit
      T.ok(
        T.wait_for(function()
          local g = panel.geom()
          return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
        end, 2000),
        "chat opened"
      )
      for _ = 1, 5 do
        vim.cmd("redraw")
        vim.wait(30)
      end
      local g = panel.geom()
      local winhl = parse_winhl(g.win)
      local groups = collect_markview_groups(g.buf)
      local checked = 0
      for name in pairs(groups) do
        local fg, bg, target = effective_hl(winhl, name)
        local via_twin = (target and target:match("^Obelus_")) or name:match("^Obelus_")
        if not via_twin then
          T.ok(
            bg == nil,
            string.format("%s (-> %s) leaks a bg in transparent mode: %s", name, tostring(target), tostring(bg))
          )
        end
        checked = checked + 1
      end
      T.ok(checked > 0, "markview actually decorated the chat buffer (nothing to check otherwise)")
      panel.close()
    end)
    vim.api.nvim_set_hl(0, "Normal", {})
    if not ok then
      error(err, 0)
    end
  end
)

T.it_when(
  has_mv,
  "PORTABILITY: @punctuation.special.markdown resolves to a defined fg through the chat winhl even when the global group is cleared",
  function()
    local ctx = T.fresh({ render = { renderer = "markview" } })
    local panel = require("obelus.panel")
    panel._timing.fill_throttle = 0
    local c = ctx.store.add(T.comment({ comment = "table" }))
    ctx.store.add_turn(c.id, "agent", RICH_MD)
    panel.open_thread(c.id, false)
    T.ok(
      T.wait_for(function()
        local g = panel.geom()
        return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
      end, 2000),
      "chat opened"
    )
    vim.cmd("hi clear @punctuation.special.markdown") -- simulate a theme that never defines it
    require("obelus.thread").markview_harmonize() -- re-derive the twin from the now-cleared group,
    -- same as the ColorScheme autocmd / next render would
    local g = panel.geom()
    local winhl = parse_winhl(g.win)
    local target = winhl["@punctuation.special.markdown"]
    T.ok(target ~= nil, "the chat window's winhighlight remaps @punctuation.special.markdown")
    local hl = vim.api.nvim_get_hl(0, { name = target, link = false })
    T.ok(hl and hl.fg ~= nil, "the twin (" .. tostring(target) .. ") still resolves to a defined fg")
    panel.close()
  end
)

T.it_when(has_mv, "PORTABILITY: opaque state — the twins still carry obelus's computed bgs", function()
  vim.api.nvim_set_hl(0, "Normal", { bg = 0x1e1e2e })
  local ok, err = pcall(function()
    local ctx = T.fresh({ render = { renderer = "markview" } }) -- no `transparent` — the opaque branch
    local panel = require("obelus.panel")
    panel._timing.fill_throttle = 0
    local c = ctx.store.add(T.comment({ comment = "code" }))
    ctx.store.add_turn(c.id, "agent", RICH_MD)
    panel.open_thread(c.id, false)
    T.ok(
      T.wait_for(function()
        local g = panel.geom()
        return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
      end, 2000),
      "chat opened"
    )
    for _ = 1, 5 do
      vim.cmd("redraw")
      vim.wait(30)
    end
    local codebg = (vim.api.nvim_get_hl(0, { name = "Obelus_MarkviewCode", link = false }) or {}).bg
    local h1bg = (vim.api.nvim_get_hl(0, { name = "Obelus_MarkviewHeading1", link = false }) or {}).bg
    T.ok(codebg ~= nil, "Obelus_MarkviewCode carries a bg in opaque mode")
    T.ok(h1bg ~= nil, "Obelus_MarkviewHeading1 carries a bg in opaque mode")
    panel.close()
  end)
  vim.api.nvim_set_hl(0, "Normal", {})
  if not ok then
    error(err, 0)
  end
end)
