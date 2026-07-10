-- render-markdown.nvim integration — SKIPPED unless the plugin is on the runtimepath.
-- Run these with:  OBELUS_TEST_RTP=/path/to/render-markdown.nvim make test
-- (a lazy.nvim install under stdpath("data")/lazy is picked up automatically — see run.lua)
T.describe("render-markdown")

local has_rm = pcall(require, "render-markdown")

-- all of render-markdown's extmarks live in this one namespace (its core/ui.lua)
local function rm_marks(buf, details)
  local ns = vim.api.nvim_get_namespaces()["render-markdown.nvim"]
  if not ns then
    return details and {} or 0
  end
  local ok, ms = pcall(vim.api.nvim_buf_get_extmarks, buf, ns, 0, -1, { details = details == true })
  if not ok then
    return details and {} or 0
  end
  return details and ms or #ms
end

-- an extmark in obelus's own panel namespace carrying `hl`? (decorate() lands each
-- kept _rows_to_chat seg as a plain hl_group extmark there — see panel.decorate)
local function panel_seg(buf, hl)
  local ns = vim.api.nvim_get_namespaces()["obelus_panel"]
  if not ns then
    return false
  end
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if (m[4] or {}).hl_group == hl then
      return true
    end
  end
  return false
end

T.it("set_renderer validates and cycles through all four renderers", function()
  local ctx = T.fresh()
  ctx.obelus.set_renderer("treesitter")
  ctx.obelus.set_renderer() -- cycle: markview → builtin → treesitter → render-markdown → …
  T.eq(ctx.config.ui.renderer, "render-markdown", "treesitter cycles to render-markdown")
  ctx.obelus.set_renderer()
  T.eq(ctx.config.ui.renderer, "markview", "render-markdown wraps back to markview")
  ctx.obelus.set_renderer("render-markdown") -- the explicit form validates too
  T.eq(ctx.config.ui.renderer, "render-markdown", "explicit render-markdown accepted")
  ctx.obelus.set_renderer("bogus")
  T.eq(ctx.config.ui.renderer, "render-markdown", "an invalid name is rejected, override unchanged")
end)

T.it("_rows_to_chat external mode: the #tag seg is KEPT for render-markdown, dropped otherwise", function()
  -- render-markdown has no obsidian-style tag handler (probed: zero marks on a
  -- "#tag" line), so obelus's own ObelusThreadTag chip must survive the external
  -- body-seg drop there — unlike markview, which renders the tag itself and wins
  -- the highlight tie (that drop is pinned in chat_spec).
  local ctx = T.fresh()
  local c = ctx.store.add(T.comment({ comment = "please review", tag = "bugfix" }))
  ctx.store.add_turn(c.id, "agent", "reply body text")
  local rows = require("obelus.thread").build(ctx.store.get(c.id), 70, { markdown = false, rules = true })
  local panel = require("obelus.panel")
  local function has_tag(entries)
    for _, e in ipairs(entries) do
      for _, seg in ipairs(e.deco.segs or {}) do
        if type(seg[3]) == "string" and seg[3]:find("Tag", 1, true) then
          return true
        end
      end
    end
    return false
  end
  T.ok(
    has_tag(panel._rows_to_chat(rows, { external = true, renderer = "render-markdown" })),
    "render-markdown external mode keeps the #tag seg"
  )
  T.ok(
    not has_tag(panel._rows_to_chat(rows, { external = true, renderer = "markview" })),
    "markview external mode still drops it"
  )
  T.ok(
    not has_tag(panel._rows_to_chat(rows, { external = true })),
    "renderer-less external callers keep the historical drop"
  )
end)

T.it_when(has_rm, "render_mode resolves render-markdown; auto never picks it", function()
  local ctx = T.fresh({ render = { renderer = "render-markdown" } })
  local panel = require("obelus.panel")
  T.eq(panel.render_info().render_mode, "render-markdown", "config renderer resolves")
  ctx.obelus.set_renderer("auto")
  T.ok(panel.render_info().render_mode ~= "render-markdown", "auto stays markview-first / builtin")
  ctx.obelus.set_renderer("render-markdown")
  T.eq(panel.render_info().render_mode, "render-markdown", "session override resolves")
end)

T.it_when(has_rm, "render-markdown decorates the chat buffer (scoped render, conceallevel 3, winhl twins)", function()
  local ctx = T.fresh({ render = { renderer = "render-markdown" } })
  local panel = require("obelus.panel")
  panel._timing.fill_throttle = 0
  local c = ctx.store.add(T.comment({ comment = "rich please" }))
  ctx.store.add_turn(
    c.id,
    "agent",
    "## Heading\n\nSome `inline` code and:\n\n```lua\nlocal x = 1\n```\n\n| A | B |\n| --- | --- |\n| 1 | 2 |"
  )
  panel.open_thread(c.id, false)
  T.ok(
    T.wait_for(function()
      local g = panel.geom()
      return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
    end, 2000),
    "chat opened"
  )
  local g = panel.geom()
  T.ok(
    T.wait_for(function()
      return rm_marks(g.buf) > 0
    end, 2000),
    "render-markdown placed extmarks on the chat buffer"
  )
  -- conceal evidence: the plugin conceals code-fence delimiters/info (conceal = "")
  local concealed = false
  for _, m in ipairs(rm_marks(g.buf, true)) do
    if (m[4] or {}).conceal ~= nil or (m[4] or {}).conceal_lines ~= nil then
      concealed = true
      break
    end
  end
  T.ok(concealed, "conceal marks exist — the buffer actually renders, not just attaches")
  T.eq(vim.wo[g.win].conceallevel, 3, "conceallevel 3 (render-markdown's own rendered value) asserted")
  T.contains(
    vim.wo[g.win].winhighlight,
    "RenderMarkdownCode:Obelus_RenderMdCode",
    "the per-window twin remap is applied"
  )
  panel.close()
end)

T.it_when(has_rm, "switching to builtin evicts render-markdown's decorations", function()
  local ctx = T.fresh({ render = { renderer = "render-markdown" } })
  local panel = require("obelus.panel")
  panel._timing.fill_throttle = 0
  local c = ctx.store.add(T.comment({ comment = "code please" }))
  ctx.store.add_turn(c.id, "agent", "```lua\nlocal x = 1\n```")
  panel.open_thread(c.id, false)
  T.ok(
    T.wait_for(function()
      local g = panel.geom()
      return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
    end, 2000),
    "chat opened"
  )
  local g = panel.geom()
  T.ok(
    T.wait_for(function()
      return rm_marks(g.buf) > 0
    end, 2000),
    "rendered in render-markdown mode first"
  )
  ctx.obelus.set_renderer("builtin") -- refreshes the open panel live
  T.ok(
    T.wait_for(function()
      return rm_marks(g.buf) == 0
    end, 2000),
    "builtin mode cleared every render-markdown mark"
  )
  T.eq(vim.wo[g.win].conceallevel, 0, "conceallevel back to the raw-text modes' 0")
  panel.close()
end)

T.it_when(has_rm, "the #tag chip renders as an obelus seg in render-markdown mode", function()
  local ctx = T.fresh({ render = { renderer = "render-markdown" } })
  local panel = require("obelus.panel")
  panel._timing.fill_throttle = 0
  local c = ctx.store.add(T.comment({ comment = "tagged", tag = "bugfix" }))
  ctx.store.add_turn(c.id, "agent", "reply body")
  panel.open_thread(c.id, false)
  T.ok(
    T.wait_for(function()
      local g = panel.geom()
      return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
    end, 2000),
    "chat opened"
  )
  local g = panel.geom()
  local text = table.concat(vim.api.nvim_buf_get_lines(g.buf, 0, -1, false), "\n")
  T.contains(text, "#bugfix", "the raw #tag text is in the chat")
  T.ok(panel_seg(g.buf, "ObelusThreadTag"), "the ObelusThreadTag seg decorates it (kept, unlike markview mode)")
  panel.close()
end)

T.it_when(has_rm, "code-span-heavy over-wide table doesn't wrap RENDERED (markview margin over-covers)", function()
  -- The markview-tuned measure_table margin serves this renderer too — measured:
  -- render-markdown's borders/delimiter are OVERLAY virt_text (zero wrap capacity)
  -- and its inline alignment pads only lift rows to the widest row's raw width, so
  -- the margin's border + span-pad + slack terms are pure headroom here. Same
  -- shape/width as markview_spec's span-heavy spec; assert the RENDERED height.
  local ctx = T.fresh({ render = { renderer = "render-markdown" } })
  local panel = require("obelus.panel")
  panel._timing.fill_throttle = 0
  local saved_columns = vim.o.columns
  vim.o.columns = 190
  local c = ctx.store.add(T.comment({ comment = "verdict table" }))
  ctx.store.add_turn(
    c.id,
    "agent",
    table.concat({
      "| Comment | Verdict | Why | Recommended fix |",
      "| --- | --- | --- | --- |",
      '| 1783642229-7 "testing this" | REAL bug | `strip_bg()` drops `hl.bg` for themes that set `#ff9e64` and writes the rest through anyway | read `hl.bg` directly and keep `#ff9e64` as the fallback |',
      '| 1783642230-1 "test" | not a bug | when trees conceal the backticks markview pads `inline` code both sides | keep `strip_bg()` but skip pad cells |',
    }, "\n")
  )
  panel.open_thread(c.id, true) -- the full-width float, like markview_spec's twin
  local opened = T.wait_for(function()
    local g = panel.geom()
    return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
  end, 2000)
  if not opened then
    vim.o.columns = saved_columns
  end
  T.ok(opened, "chat opened")
  local g = panel.geom()
  T.wait_for(function()
    return rm_marks(g.buf) > 0
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
  T.ok(all_single, "every span-heavy rendered row occupies exactly one screen row" .. (bad and (": " .. bad) or ""))
end)

T.it_when(has_rm, "harmonized twins: transparent mode strips every bg; opaque mode carries them", function()
  local thread = require("obelus.thread")
  -- transparent: the one-switch contract — every Obelus_RenderMd* bg must be nil
  vim.api.nvim_set_hl(0, "Normal", {})
  local ok, err = pcall(function()
    T.fresh({ render = { renderer = "render-markdown", transparent = true } })
    thread.render_md_harmonize()
    for _, name in ipairs({
      "Obelus_RenderMdCode",
      "Obelus_RenderMdCodeInline",
      "Obelus_RenderMdH1",
      "Obelus_RenderMdH1Bg",
    }) do
      local hl = vim.api.nvim_get_hl(0, { name = name, link = false }) or {}
      T.is_nil(hl.bg, name .. " must not carry a bg in transparent mode")
    end
    -- fg-only groups still resolve to something visible
    local head = vim.api.nvim_get_hl(0, { name = "Obelus_RenderMdTableHead", link = false }) or {}
    T.ok(head.fg ~= nil, "table border twin keeps a defined fg")
  end)
  vim.api.nvim_set_hl(0, "Normal", {})
  if not ok then
    error(err, 0)
  end
  -- opaque: same derivation as markview's twins — code bg = agent bubble bg by default
  vim.api.nvim_set_hl(0, "Normal", { bg = 0x1e1e2e })
  ok, err = pcall(function()
    T.fresh({ render = { renderer = "render-markdown" } })
    thread.render_md_harmonize()
    local code = (vim.api.nvim_get_hl(0, { name = "Obelus_RenderMdCode", link = false }) or {}).bg
    local h1 = (vim.api.nvim_get_hl(0, { name = "Obelus_RenderMdH1", link = false }) or {}).bg
    local reply = (vim.api.nvim_get_hl(0, { name = "ObelusReplyBg", link = false }) or {}).bg
    T.ok(code ~= nil, "Obelus_RenderMdCode carries a bg in opaque mode")
    T.ok(h1 ~= nil, "Obelus_RenderMdH1 carries a bg in opaque mode")
    T.eq(code, reply, "seamless default: code bg IS the agent bubble bg (markview parity)")
  end)
  vim.api.nvim_set_hl(0, "Normal", {})
  if not ok then
    error(err, 0)
  end
end)

-- ---------------------------------------------------------------------------
-- View-scoped rendering + lifecycle regressions (adversarial-review pins).
-- ---------------------------------------------------------------------------

local has_mv = pcall(require, "markview")

T.it_when(has_rm, "long chat: the SEATED view is rendered; scrolling re-renders the exposed view", function()
  -- render-markdown parses only the window's visible range: without the
  -- post-seat render + the WinScrolled re-render, a long chat opened seated at
  -- the bottom kept every mark in the PRE-seat rows near the top — the view the
  -- user actually saw was raw text at conceallevel 3, and scrolling never
  -- rendered history (obelus deliberately doesn't rely on the plugin's manager).
  local ctx = T.fresh({ render = { renderer = "render-markdown" } })
  local panel = require("obelus.panel")
  panel._timing.fill_throttle = 0
  local c = ctx.store.add(T.comment({ comment = "long thread" }))
  local body = {}
  for i = 1, 40 do
    body[#body + 1] = ("### Section %d\n\ntext with `inline%d` code:\n\n```lua\nlocal v%d = %d\n```"):format(i, i, i, i)
  end
  ctx.store.add_turn(c.id, "agent", table.concat(body, "\n\n"))
  panel.open_thread(c.id, false)
  T.ok(
    T.wait_for(function()
      local g = panel.geom()
      return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
    end, 3000),
    "chat opened"
  )
  local g = panel.geom()
  T.ok(
    T.wait_for(function()
      return rm_marks(g.buf) > 0
    end, 2000),
    "rendered at all"
  )
  local function view_range()
    local topline, botline = 0, 0
    vim.api.nvim_win_call(g.win, function()
      topline = vim.fn.line("w0")
      botline = vim.fn.line("w$")
    end)
    return topline, botline
  end
  local function marks_between(lo0, hi0)
    local n = 0
    for _, m in ipairs(rm_marks(g.buf, true)) do
      if m[2] >= lo0 and m[2] <= hi0 then
        n = n + 1
      end
    end
    return n
  end
  local total = vim.api.nvim_buf_line_count(g.buf)
  T.ok(total > 100, "the thread is long enough that the seat jumped past the first view")
  local topline, botline = view_range()
  T.ok(botline > total - 30, "the view actually seated near the bottom")
  T.ok(
    marks_between(topline - 1, botline - 1) > 0,
    ("the SEATED view (%d..%d of %d) carries render-markdown marks"):format(topline, botline, total)
  )
  -- scroll to the middle: the WinScrolled hook must re-render the exposed rows
  vim.api.nvim_win_call(g.win, function()
    vim.api.nvim_win_set_cursor(g.win, { math.floor(total / 2), 0 })
    vim.cmd("normal! zz")
  end)
  vim.api.nvim_exec_autocmds("WinScrolled", {})
  local mid_lo, mid_hi = math.floor(total / 2) - 15, math.floor(total / 2) + 15
  T.ok(
    T.wait_for(function()
      return marks_between(mid_lo, mid_hi) > 0
    end, 2000),
    "after scrolling, the middle band re-rendered"
  )
  panel.close()
end)

T.it_when(has_rm, "back-to-list evicts render-markdown decorations and conceallevel", function()
  -- M.back() flips state.mode to list on the SAME buffer/window: without the
  -- list-mode eviction in fill(), the chat's overlay '█'/icon strips painted
  -- over list rows (overlay virt_text ignores conceallevel 0) and the plugin's
  -- per-buffer cache stayed enabled=true — its manager (when attached) then
  -- re-rendered the LIST and wrote conceallevel 3 back on the next CursorMoved.
  local ctx = T.fresh({ render = { renderer = "render-markdown" } })
  local panel = require("obelus.panel")
  panel._timing.fill_throttle = 0
  local c = ctx.store.add(T.comment({ comment = "leak check" }))
  ctx.store.add_turn(c.id, "agent", "## Head\n\n```lua\nlocal x = 1\n```")
  panel.open_thread(c.id, false)
  T.ok(
    T.wait_for(function()
      local g = panel.geom()
      return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
    end, 3000),
    "chat opened"
  )
  local g = panel.geom()
  local win, buf = g.win, g.buf
  T.ok(
    T.wait_for(function()
      return rm_marks(buf) > 0
    end, 2000),
    "rendered in chat mode first"
  )
  panel.back()
  T.ok(
    T.wait_for(function()
      return rm_marks(buf) == 0
    end, 2000),
    "the list carries zero render-markdown marks"
  )
  T.eq(vim.wo[win].conceallevel, 0, "the list window's conceallevel is back to 0")
  -- and the per-buffer cache is left disabled, so a manager event can't re-render
  local st = require("render-markdown.state")
  if st.cache and st.cache[buf] ~= nil then
    T.eq(st.cache[buf].enabled, false, "the plugin's per-buffer config is left disabled")
  end
  panel.close()
end)

T.it_when(has_rm and has_mv, "live renderer switch reapplies the winhighlight twin remap", function()
  -- chat_winhl embeds ONE renderer's twin map at window creation; the reconcile
  -- must rebuild it on a live :ObelusRenderer switch or the new renderer's marks
  -- resolve through the GLOBAL groups (DiffText heading strips in the bubbles).
  local ctx = T.fresh({ render = { renderer = "markview" } })
  local panel = require("obelus.panel")
  panel._timing.fill_throttle = 0
  local c = ctx.store.add(T.comment({ comment = "switcher" }))
  ctx.store.add_turn(c.id, "agent", "## Head\n\n```lua\nlocal x = 1\n```")
  panel.open_thread(c.id, false)
  T.ok(
    T.wait_for(function()
      local g = panel.geom()
      return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
    end, 3000),
    "chat opened"
  )
  local g = panel.geom()
  T.contains(vim.wo[g.win].winhighlight, "MarkviewCode:Obelus_MarkviewCode", "markview remap at open")
  ctx.obelus.set_renderer("render-markdown")
  T.ok(
    T.wait_for(function()
      return (vim.wo[g.win].winhighlight or ""):find("RenderMarkdownCode:Obelus_RenderMdCode", 1, true) ~= nil
    end, 2000),
    "switching to render-markdown swapped the remap in the LIVE window"
  )
  T.ok(
    T.wait_for(function()
      return rm_marks(g.buf) > 0
    end, 2000),
    "…and its marks are on"
  )
  ctx.obelus.set_renderer("markview")
  T.ok(
    T.wait_for(function()
      return (vim.wo[g.win].winhighlight or ""):find("MarkviewCode:Obelus_MarkviewCode", 1, true) ~= nil
    end, 2000),
    "switching back restored the markview remap"
  )
  T.ok(
    T.wait_for(function()
      return rm_marks(g.buf) == 0
    end, 2000),
    "…and render-markdown's marks are gone"
  )
  panel.close()
end)
