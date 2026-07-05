-- chat: the panel's rows -> chat structural transform (M._rows_to_chat) — the exact
-- boundary where thread.build's chunk rows become real buffer text + decorations.
-- This is where the divider-corruption regression lived (rule glyphs leaking into
-- selectable buffer text instead of staying virt_line chrome), so these specs pin
-- that invariant hard, plus the external-renderer seg-dropping and the transparent-
-- theme / renderer-resolution behaviours around it.
T.describe("chat")

-- ---------------------------------------------------------------------------
-- 1. rows -> chat structure
-- ---------------------------------------------------------------------------

T.it("_rows_to_chat: clean text, no bare rule glyphs, bg/bar pinned, agent turn carries the divider", function()
  local ctx = T.fresh()
  local c = ctx.store.add(T.comment({ comment = "please review this" }))
  ctx.store.add_turn(c.id, "agent", "sure, fixed it")
  ctx.store.set_pending_you(c.id, "thanks, one more thing") -- trailing "you" draft turn

  local rows = require("obelus.thread").build(ctx.store.get(c.id), 70, { markdown = true, rules = true })
  local out = require("obelus.panel")._rows_to_chat(rows, {})
  T.ok(#out > 0, "rows produced")

  local reply_entry_idx
  for i, e in ipairs(out) do
    T.ok(type(e.text) == "string", "entry text is a string")
    T.is_nil(e.text:match("%s+$"), "entry text has no trailing whitespace: " .. vim.inspect(e.text))
    -- the divider-corruption regression: rule glyphs must NEVER land in selectable
    -- buffer text — they only ever ride along as deco.rule (a virt_line)
    T.ok(not e.text:find("─", 1, true), "entry text never carries the rule glyph ─")
    T.ok(not e.text:find("┄", 1, true), "entry text never carries the rule glyph ┄")
    T.ok(e.deco and (e.deco.bg == "ObelusThreadBg" or e.deco.bg == "ObelusReplyBg"), "deco.bg is a known bubble bg")
    T.ok(type(e.deco.bar) == "string" and e.deco.bar ~= "", "deco.bar is a bar highlight group")
    -- pin the you/agent bar<->bg pairing: thread.build marks agent turns with a bar
    -- hl containing "Reply" (ObelusReplyBar*); "you" turns use ObelusThreadBar*
    if e.deco.bar:find("Reply", 1, true) then
      T.eq(e.deco.bg, "ObelusReplyBg", "a Reply-bar row must carry the reply bubble bg")
      reply_entry_idx = reply_entry_idx or i
    else
      T.eq(e.deco.bg, "ObelusThreadBg", "a Thread-bar row must carry the you bubble bg")
    end
  end

  T.ok(reply_entry_idx, "an agent (reply) entry exists")
  -- the inter-turn divider rides the FOLLOWING content row — i.e. the row that
  -- STARTS the agent turn (its header row) carries deco.rule, not a standalone entry
  local first_reply = out[reply_entry_idx]
  T.ok(first_reply.deco.rule ~= nil, "the entry starting the agent turn carries the divider")
  T.eq(first_reply.deco.rule.reply, true, "the divider before an agent turn is marked reply = true")
end)

-- ---------------------------------------------------------------------------
-- 2. external mode (markview/treesitter): body segs dropped, header/meta segs kept
-- ---------------------------------------------------------------------------

local function seg_hls(entry)
  local hls = {}
  for _, seg in ipairs(entry.deco.segs) do
    hls[#hls + 1] = seg[3]
  end
  return hls
end

local function is_headerish(hls)
  for _, hl in ipairs(hls) do
    if type(hl) == "string" and (hl:find("Header", 1, true) or hl:find("Meta", 1, true)) then
      return true
    end
  end
  return false
end

T.it("_rows_to_chat external mode: the #tag seg is absent externally but present internally", function()
  local ctx = T.fresh()
  local c = ctx.store.add(T.comment({ comment = "please review", tag = "bugfix" }))
  ctx.store.add_turn(c.id, "agent", "reply body text")

  local rows_raw = require("obelus.thread").build(ctx.store.get(c.id), 70, { markdown = false, rules = true })
  local panel = require("obelus.panel")
  local internal = panel._rows_to_chat(rows_raw, { external = false })
  local external = panel._rows_to_chat(rows_raw, { external = true })

  local function is_tagish(hls)
    for _, hl in ipairs(hls) do
      if type(hl) == "string" and hl:find("Tag", 1, true) then
        return true
      end
    end
    return false
  end

  local internal_has_tag, external_has_tag = false, false
  for _, e in ipairs(internal) do
    if is_tagish(seg_hls(e)) then
      internal_has_tag = true
    end
  end
  for _, e in ipairs(external) do
    if is_tagish(seg_hls(e)) then
      external_has_tag = true
    end
  end
  T.ok(internal_has_tag, "internal mode keeps the #tag seg")
  T.ok(not external_has_tag, "external mode drops the #tag seg — markview mode must keep dropping it")
end)

T.it("_rows_to_chat external mode: body segs empty (markview paints them), header/meta segs kept", function()
  local ctx = T.fresh()
  local c = ctx.store.add(T.comment({ comment = "line one\nline two" }))
  ctx.store.add_turn(c.id, "agent", "reply body text")

  local rows_raw = require("obelus.thread").build(ctx.store.get(c.id), 70, { markdown = false, rules = true })
  local panel = require("obelus.panel")
  local internal = panel._rows_to_chat(rows_raw, { external = false })
  local external = panel._rows_to_chat(rows_raw, { external = true })

  T.eq(#internal, #external, "same number of content rows either way")
  local saw_body, saw_header = false, false
  for i, ientry in ipairs(internal) do
    local eentry = external[i]
    T.eq(eentry.text, ientry.text, "text is identical regardless of external mode")
    if is_headerish(seg_hls(ientry)) then
      saw_header = true
      T.ok(#eentry.deco.segs > 0, "header/meta row keeps its segs in external mode")
    else
      saw_body = true
      T.eq(#eentry.deco.segs, 0, "body row segs are EMPTY in external mode (markview paints the body)")
      T.ok(#ientry.deco.segs > 0, "the same body row keeps its segs when external = false")
    end
  end
  T.ok(saw_body and saw_header, "both body and header/meta rows were exercised")
end)

-- ---------------------------------------------------------------------------
-- 3. a trailing divider (pending_rule with no content row after it) is dropped
-- ---------------------------------------------------------------------------

T.it("_rows_to_chat: a trailing divider with no following content row lands no entry", function()
  T.fresh()
  -- hand-crafted, mimicking thread.build's STRUCTURED row shape exactly: a content
  -- (header) row, then a rule row as the very LAST row (as if a stream ended right
  -- at a turn boundary, or the trailing footer rule ran off the end)
  local rows = {
    {
      kind = "content",
      agent = false,
      bar_hl = "ObelusThreadBar",
      bg_hl = "ObelusThreadBg",
      chunks = { { "you", "ObelusThreadHeader", role = "header" } },
    },
    { kind = "rule", agent = false, char = "─", bar_hl = "ObelusThreadBarN", rule_hl = "ObelusThreadRuleN" },
  }
  local out = require("obelus.panel")._rows_to_chat(rows, {})
  T.eq(#out, 1, "the trailing divider produced no entry of its own")
  T.eq(out[1].text, "you")
  T.is_nil(out[1].deco.rule, "no divider was pending before this row")
end)

-- ---------------------------------------------------------------------------
-- 4. transparent invariant: band/reply/code/input bgs unset in transparent mode,
--    set in opaque mode. setup_highlights runs inside T.fresh (obelus.setup).
-- ---------------------------------------------------------------------------

-- the band/reply/code bgs gated on the `transparent` branch in thread.setup_highlights
local BG_GROUPS = {
  "ObelusThreadBar",
  "ObelusThreadBg",
  "ObelusThreadHeader",
  "ObelusThreadText",
  "ObelusThreadBold",
  "ObelusReplyBold",
  "ObelusThreadMeta",
  "ObelusThreadRule",
  "ObelusThreadCode",
  "ObelusReplyBar",
  "ObelusReplyBg",
  "ObelusReplyHeader",
  "ObelusReplyText",
  "ObelusReplyMeta",
  "ObelusReplyCode",
  "ObelusReplyRule",
  -- the reply/compose input box: also gated on `transparent` (its own `inbg` local)
  "ObelusInput",
  "ObelusInputBorder",
  "ObelusInputBar",
  "ObelusInputHeader",
  -- builtin-renderer inline span groups that carry a bg (Italic sits on the bubble
  -- tint; CodeLabel sits on the code box bg) — Strike/Link are fg-only (underline/
  -- strikethrough, no bg key at all), so they're deliberately NOT in this list.
  "ObelusThreadItalic",
  "ObelusReplyItalic",
  "ObelusThreadCodeLabel",
  "ObelusReplyCodeLabel",
}

-- obelus.setup() only calls thread.setup_highlights() once EVER per process (guarded
-- by a private `did_setup` latch in init.lua — see M.setup) — later T.fresh() calls
-- re-run config.setup() (so config.options.render.transparent DOES flip live) but
-- skip re-deriving the highlight groups from it. So exercising a `render.transparent`
-- flip has to call thread.setup_highlights() directly, same as the ColorScheme
-- autocmd would, to force the groups to reflect the config that was just set.
T.it("transparent mode: band/reply/code/input bgs are unset (NONE)", function()
  T.fresh({ render = { transparent = true } })
  require("obelus.thread").setup_highlights()
  for _, g in ipairs(BG_GROUPS) do
    local hl = vim.api.nvim_get_hl(0, { name = g, link = false })
    T.is_nil(hl.bg, g .. " should have no bg in transparent mode")
  end
end)

T.it("opaque mode: the same groups DO carry a bg", function()
  -- set Normal's bg FIRST, and restore it before this spec ends (even on failure) so
  -- a leftover Normal bg can never leak into a later spec via pcall-safe cleanup
  vim.api.nvim_set_hl(0, "Normal", { bg = 0x1e1e2e })
  local ok, err = pcall(function()
    T.fresh({}) -- no `transparent` — the opaque branch of setup_highlights
    require("obelus.thread").setup_highlights()
    for _, g in ipairs(BG_GROUPS) do
      local hl = vim.api.nvim_get_hl(0, { name = g, link = false })
      T.ok(hl.bg ~= nil, g .. " should carry a bg in opaque mode")
    end
  end)
  vim.api.nvim_set_hl(0, "Normal", {})
  if not ok then
    error(err, 0)
  end
end)

-- ---------------------------------------------------------------------------
-- 5. render mode resolution: builtin/treesitter both draw with no conceal;
--    treesitter additionally attaches a real highlighter to the chat buffer.
--    (markview mode is covered by markview_spec.)
-- ---------------------------------------------------------------------------

local function open_builtin_thread(renderer)
  local ctx = T.fresh({ render = { renderer = renderer } })
  require("obelus.panel")._timing.fill_throttle = 0
  local file = ctx.root .. "/f.lua"
  vim.fn.writefile({ "local a = 1", "local b = 2", "return a + b" }, file)
  vim.cmd("edit " .. file)
  local fabs = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
  local c = ctx.store.add(T.comment({ file = fabs, range = { sl = 1, el = 1 } }))
  ctx.store.add_turn(c.id, "agent", "## heading\n\nsome `code` and prose")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local panel = require("obelus.panel")
  panel.open_thread(c.id, false)
  vim.cmd("redraw")
  return panel.geom()
end

T.it("renderer = builtin: chat renders in-house, no conceal", function()
  local g = open_builtin_thread("builtin")
  T.ok(g and g.win, "chat is open")
  T.eq(vim.wo[g.win].conceallevel, 0)
end)

T.it("renderer = treesitter: no conceal, but treesitter IS started on the buffer", function()
  local g = open_builtin_thread("treesitter")
  T.ok(g and g.win, "chat is open")
  T.eq(vim.wo[g.win].conceallevel, 0)
  T.ok(vim.treesitter.highlighter.active[g.buf] ~= nil, "treesitter highlighter attached to the chat buffer")
end)

-- ---------------------------------------------------------------------------
-- 6. the builtin (md=true) table box renderer's rows survive _rows_to_chat like
--    any other body content — real text + segs, never mistaken for a divider.
-- ---------------------------------------------------------------------------

T.it("_rows_to_chat: a builtin table's rows land as ordinary body segs, not a pending rule", function()
  local ctx = T.fresh()
  local text = "| A | B |\n| --- | --- |\n| 1 | 2 |"
  local c = ctx.store.add(T.comment({ comment = text }))
  local rows = require("obelus.thread").build(ctx.store.get(c.id), 60, { markdown = true, rules = true })
  local out = require("obelus.panel")._rows_to_chat(rows, {})
  local border_entry
  for _, e in ipairs(out) do
    if e.text:find("╭", 1, true) then
      border_entry = e
    end
  end
  T.ok(border_entry, "the table's top border row made it into the chat rows as real text")
  T.ok(#border_entry.deco.segs > 0, "the border row carries a real seg (body content), not an empty entry")
  T.is_nil(border_entry.deco.rule, "the border row itself isn't also carrying a pending divider")
end)

T.it("chat winhighlight dims NonText — smoothscroll's <<< marker renders as chrome, not stray text", function()
  local ctx = T.fresh()
  local c = ctx.store.add(T.comment({ comment = "q" }))
  ctx.store.add_turn(c.id, "agent", "hello")
  local panel = require("obelus.panel")
  panel.open_thread(c.id, false)
  T.ok(
    T.wait_for(function()
      local g = panel.geom()
      return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
    end),
    "chat opened"
  )
  local g = panel.geom()
  T.contains(vim.wo[g.win].winhighlight, "NonText:ObelusChrome")
  panel.close()
end)

T.it("a stale dispatching flag (stream died, no job) self-heals when the chat opens", function()
  local ctx = T.fresh()
  local c = ctx.store.add(T.comment({ comment = "q" }))
  ctx.store.add_turn(c.id, "agent", "an old reply")
  c.dispatching = true -- as left behind by a stream that never finalized
  local panel = require("obelus.panel")
  panel.open_thread(c.id, false)
  T.ok(
    T.wait_for(function()
      local g = panel.geom()
      return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
    end),
    "chat opened"
  )
  T.ok(
    T.wait_for(function()
      return ctx.store.get(c.id).dispatching == nil
    end, 1000),
    "the stale flag was cleared by the render pass — renderer/spinner no longer stuck"
  )
  panel.close()
end)

-- ---------------------------------------------------------------------------
-- 7. wrap toggle (section B; keys.chat.wrap, default "W") — nvim can't h-scroll a
--    wrapped window, so the chat window's own buffer-local "W" (see panel.lua's
--    maps()) flips vim.wo[win].wrap and pins it in state.wrap_override so the
--    NEXT fill (apply_winopts) doesn't stomp it back to the mode=="chat" default.
-- ---------------------------------------------------------------------------

-- The buffer-local normal-mode callback bound to `lhs` (mention_spec's at_callback
-- idiom — retrieved via nvim_buf_get_keymap rather than simulating a keystroke).
local function n_callback(buf, lhs)
  for _, km in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if km.lhs == lhs then
      return km.callback
    end
  end
end

local function open_wrap_thread(opts)
  local ctx = T.fresh(opts)
  require("obelus.panel")._timing.fill_throttle = 0
  local c = ctx.store.add(T.comment({ comment = "q" }))
  ctx.store.add_turn(c.id, "agent", "hello")
  local panel = require("obelus.panel")
  panel.open_thread(c.id, false)
  T.ok(
    T.wait_for(function()
      local g = panel.geom()
      return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
    end),
    "chat opened"
  )
  return ctx, panel, c
end

T.it("wrap toggle: W flips vim.wo[win].wrap and survives a forced refresh", function()
  local ctx, panel, c = open_wrap_thread()
  local g = panel.geom()
  T.eq(vim.wo[g.win].wrap, true, "wrap starts on (the chat-mode default)")

  local cb = n_callback(g.buf, "W")
  T.ok(cb, "the W keymap is bound on the chat buffer")
  cb()
  T.eq(vim.wo[g.win].wrap, false, "wrap toggled off")

  -- a real (non-coalesced) fill pass must not stomp the override back to the
  -- mode=="chat" default — change the content so fill()'s signature check can't
  -- just skip the pass (see fill()'s `sig`/`force` comment).
  ctx.store.add_turn(c.id, "agent", "one more thing")
  panel.refresh()
  T.eq(vim.wo[g.win].wrap, false, "wrap survives a forced refresh/fill")

  cb() -- toggle back on
  T.eq(vim.wo[g.win].wrap, true, "toggles back on")
  panel.close()
end)

T.it("wrap toggle: closing the chat clears the override for the next open", function()
  local _, panel, c = open_wrap_thread()
  local g = panel.geom()
  local cb = n_callback(g.buf, "W")
  cb()
  T.eq(vim.wo[g.win].wrap, false, "wrap toggled off")
  panel.close()

  panel.open_thread(c.id, false)
  T.ok(
    T.wait_for(function()
      local g2 = panel.geom()
      return g2 ~= nil and g2.input_win ~= nil and not g2.input_pending_reveal
    end),
    "reopened"
  )
  local g2 = panel.geom()
  T.eq(vim.wo[g2.win].wrap, true, "reopening starts from the plain default, not the cleared toggle")
  panel.close()
end)

T.it("wrap toggle: keys.chat.wrap = false disables the binding entirely", function()
  local _, panel = open_wrap_thread({ keys = { chat = { wrap = false } } })
  local g = panel.geom()
  T.is_nil(n_callback(g.buf, "W"), "no W keymap bound when keys.chat.wrap = false")
  panel.close()
end)

T.it("wrap toggle: keys.chat.wrap = a custom lhs rebinds it", function()
  local _, panel = open_wrap_thread({ keys = { chat = { wrap = "Z" } } })
  local g = panel.geom()
  T.is_nil(n_callback(g.buf, "W"), "the default W is no longer bound")
  T.ok(n_callback(g.buf, "Z"), "the custom lhs is bound instead")
  panel.close()
end)

-- ---------------------------------------------------------------------------
-- 8. keys.chat overridability (section C) — the docked reply box's own bindings
-- ---------------------------------------------------------------------------

T.it("keys.chat.close = 'x': the reply box gets x, not q", function()
  local ctx = T.fresh({ keys = { chat = { close = "x" } } })
  local c = ctx.store.add(T.comment({ comment = "q" }))
  local panel = require("obelus.panel")
  panel.open_thread(c.id, false)
  T.ok(
    T.wait_for(function()
      local g = panel.geom()
      return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
    end),
    "chat opened"
  )
  local ibuf = vim.api.nvim_win_get_buf(panel.geom().input_win)
  T.ok(n_callback(ibuf, "x"), "x is bound on the reply box")
  T.is_nil(n_callback(ibuf, "q"), "q is no longer bound")
  panel.close()
end)

T.it("selection: ObelusVisual derives a contrast boost by default; explicit override wins", function()
  vim.api.nvim_set_hl(0, "Normal", { bg = 0x1e1e2e, fg = 0xcdd6f4 })
  vim.api.nvim_set_hl(0, "Visual", { bg = 0x283457 })
  T.fresh()
  require("obelus.thread").setup_highlights()
  local hl = vim.api.nvim_get_hl(0, { name = "ObelusVisual", link = false })
  T.ok(hl.bg ~= nil, "ObelusVisual defined without any config")
  T.ok(hl.bg ~= 0x283457, "boosted away from the raw theme Visual")
  -- dark theme: the boost lifts LIGHTER (opposite of the code-box recess)
  local function lum(c)
    return math.floor(c / 65536) % 256 + math.floor(c / 256) % 256 + c % 256
  end
  T.ok(lum(hl.bg) > lum(0x283457), "lighter than the theme Visual on a dark bg")

  T.fresh({ render = { colors = { selection = 0x3d59a1 } } })
  require("obelus.thread").setup_highlights()
  local hl2 = vim.api.nvim_get_hl(0, { name = "ObelusVisual", link = false })
  T.eq(hl2.bg, 0x3d59a1, "the explicit override is used verbatim")
end)

T.it("chat windows always remap Visual to ObelusVisual", function()
  local ctx = T.fresh()
  local c = ctx.store.add(T.comment({ comment = "q" }))
  ctx.store.add_turn(c.id, "agent", "hello")
  local panel = require("obelus.panel")
  panel.open_thread(c.id, false)
  T.ok(
    T.wait_for(function()
      local g = panel.geom()
      return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
    end),
    "chat opened"
  )
  T.contains(vim.wo[panel.geom().win].winhighlight, "Visual:ObelusVisual")
  panel.close()
end)

T.it("a bg-less colorscheme does NOT strip the code boxes when transparent = false", function()
  -- the old auto-detect (`Normal bg unset => transparent`) silently removed the
  -- recessed code-block backgrounds for bg-less themes even with transparent=false
  vim.api.nvim_set_hl(0, "Normal", { fg = 0xcdd6f4 }) -- no bg, like a transparent theme
  T.fresh({ render = { transparent = false } })
  require("obelus.thread").markview_harmonize()
  local hl = vim.api.nvim_get_hl(0, { name = "Obelus_MarkviewCode", link = false })
  T.ok(hl.bg ~= nil, "the code box keeps its recessed bg (blend base falls back)")
  -- and the ONE switch still works: transparent = true drops it
  T.fresh({ render = { transparent = true } })
  require("obelus.thread").markview_harmonize()
  local hl2 = vim.api.nvim_get_hl(0, { name = "Obelus_MarkviewCode", link = false })
  T.is_nil(hl2.bg, "transparent = true is the only thing that strips it")
  vim.api.nvim_set_hl(0, "Normal", { bg = 0x1e1e2e, fg = 0xcdd6f4 })
end)
