-- geometry: panel seating/scroll/reply-box invariants (M.geom()). This is the layer
-- where every historical visual bug lived — the reply box drifting from the reserved
-- rows, the view over-scrolling past the end, auto-follow fighting a manual scroll-up,
-- the input box growing out of step with its reserved rows. Assert on geom() fields
-- (structured, read-only introspection), not raw window/screen scans.
--
-- The BUILTIN renderer is forced everywhere (render.renderer = "builtin") so geometry
-- is exact — no markview conceal/async-settle wobble to account for.
T.describe("geometry")

-- gap semantics: the popup and sidebar dock the box with different zero-points
-- (popup = raw window-bottom row, sidebar = the reserved rows' screenpos), and
-- M.geom() normalizes them — gap == 0 means "seated" in BOTH modes. These specs
-- pinned that normalization when it was added; a docking change in either mode
-- shifts the number and fails here.

-- Opens a sidebar (or popup, with as_float=true) chat overflowing the window — enough
-- turns that the view must scroll, so "seated at the bottom" is a real assertion and
-- not a vacuous one. Waits for the post-open reveal (open_thread hides the input box
-- until the popup/sidebar height settles, see open_input/open_thread), then forces a
-- redraw so screenpos-derived geom() fields (expect_top/gap) read the settled layout.
local function seed_overflow(opts)
  opts = opts or {}
  local ctx = T.fresh({ render = { renderer = "builtin" } })
  local panel = require("obelus.panel")
  panel._timing.fill_throttle = 0 -- consecutive fills in one spec must not be throttled
  local c = ctx.store.add(T.comment())
  local pairs_n = opts.pairs or 15 -- 15 you + 15 agent = 30 turns, well past any window height
  for i = 1, pairs_n do
    ctx.store.add_turn(c.id, "you", "you turn " .. i)
    ctx.store.add_turn(c.id, "agent", "agent turn " .. i)
  end
  panel.open_thread(c.id, opts.as_float or false)
  T.wait_for(function()
    local g = panel.geom()
    return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
  end, 1000)
  vim.cmd("redraw")
  return ctx, panel, c
end

-- 1. SEAT ON OPEN -----------------------------------------------------------

T.it("seat on open: an overflowing thread lands seated at the very bottom", function()
  local _, panel = seed_overflow()
  local g = panel.geom()
  T.ok(g, "geom present")
  T.eq(g.mode, "chat")
  T.eq(g.botline, g.line_count, "seated: the last buffer line is the last visible line")
  T.eq(g.gap, 0, "reply box sits exactly on the reserved rows")
  T.eq(g.trailing_blank, g.box_rows, "trailing blank rows == the reserved box footprint")
  T.eq(g.follow, true)
end)

-- 2. SHORT THREAD -------------------------------------------------------------

T.it("short thread: box hugs the (tiny) content with no gap", function()
  local ctx = T.fresh({ render = { renderer = "builtin" } })
  local panel = require("obelus.panel")
  panel._timing.fill_throttle = 0
  -- a comment with its default single "you" turn and nothing else — the smallest
  -- real thread. That lone turn is also the trailing UNSENT draft (see
  -- store.pending_you_text / thread.build's hide_draft), so it loads into the reply
  -- box and is skipped from the rendered history: the chat body is just the split
  -- header + the reserved reply rows. Sidebar mode positions the box via its real
  -- screen row (not a fixed window-bottom offset — see input_wincfg's `want_screenpos`),
  -- so with content this short the box sits right after the header, not at the window
  -- floor; gap == 0 (geom() normalizes the two docking conventions) must still
  -- hold.
  local c = ctx.store.add(T.comment())
  panel.open_thread(c.id, false)
  T.wait_for(function()
    local g = panel.geom()
    return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
  end, 1000)
  vim.cmd("redraw")
  local g = panel.geom()
  T.ok(g, "geom present")
  T.eq(g.mode, "chat")
  T.eq(g.input_hidden, false, "input visible")
  T.ok(g.line_count <= 10, "line_count small: " .. tostring(g.line_count))
  T.eq(g.gap, 0, "reply box sits exactly on the reserved rows")
  T.eq(g.trailing_blank, g.box_rows)
  -- confirm *why* the body is that short: the draft really did load into the box
  local input_buf = vim.api.nvim_win_get_buf(g.input_win)
  local text = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")
  T.contains(text, "please review this")
end)

-- 3. OVER-SCROLL CLAMP --------------------------------------------------------

T.it("over-scroll clamp: scrolling the view past the end re-seats it", function()
  local _, panel = seed_overflow()
  local g0 = panel.geom()
  T.eq(g0.gap, 0, "starts seated")
  -- plain <C-e> (NOT M.scroll) can push the last line up off the window bottom,
  -- leaving the reserved reply rows floating over a void (see clamp_overscroll's
  -- comment) — 3 presses from an already-seated view reproduces exactly that.
  local ce = vim.api.nvim_replace_termcodes("<C-e>", true, false, true)
  pcall(vim.api.nvim_win_call, g0.win, function()
    vim.cmd("normal! 3" .. ce)
  end)
  vim.cmd("redraw")
  -- clamp_overscroll is registered on WinScrolled with NO `pattern` (any WinScrolled —
  -- including this synthetic one — runs it; see M.open's comment on why), so firing it
  -- directly is the deterministic trigger instead of relying on whether headless nvim
  -- raises WinScrolled off a scripted `:normal!` scroll.
  vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(g0.win) })
  vim.cmd("redraw")
  local g1 = panel.geom()
  T.eq(g1.gap, 0, "re-seated: gap closed")
  T.eq(g1.botline, g1.line_count, "re-seated: botline == line_count")
  T.eq(g1.follow, true)
end)

-- 4. SCROLL-UP STOPS FOLLOW ----------------------------------------------------

T.it("scroll-up stops follow without being yanked back; reseat() restores it", function()
  local _, panel = seed_overflow()
  local g0 = panel.geom()
  T.eq(g0.follow, true)
  local cy = vim.api.nvim_replace_termcodes("<C-y>", true, false, true)
  pcall(vim.api.nvim_win_call, g0.win, function()
    vim.cmd("normal! 5" .. cy)
  end)
  vim.cmd("redraw")
  local topline_after_scroll = (vim.fn.getwininfo(g0.win)[1] or {}).topline
  vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(g0.win) })
  vim.cmd("redraw")
  local g1 = panel.geom()
  T.eq(g1.follow, false, "scrolling up clears follow")
  T.ok(g1.botline < g1.line_count, "the last line is no longer pinned to the bottom")
  T.eq(g1.topline, topline_after_scroll, "neither handler scrolled the view back down")

  panel.reseat()
  vim.cmd("redraw")
  local g2 = panel.geom()
  T.eq(g2.follow, true)
  T.eq(g2.gap, 0)
  T.eq(g2.botline, g2.line_count, "reseat() lands back at the bottom")
end)

-- 5. INPUT AUTO-GROW ----------------------------------------------------------

T.it("input auto-grow: more lines grow the box and the reserved rows together", function()
  local _, panel = seed_overflow()
  local g0 = panel.geom()
  local input_buf = vim.api.nvim_win_get_buf(g0.input_win)
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "l1", "l2", "l3", "l4", "l5", "l6" })
  -- open_input's autocmd listens on TextChanged/TextChangedI; fire it directly rather
  -- than faking keystrokes (the buffer edit above is the actual trigger condition it
  -- checks — the typed line count changing).
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = input_buf })
  vim.cmd("redraw")
  T.wait_for(function()
    local g = panel.geom()
    return g ~= nil and g.input_height == 6
  end, 500)
  local g1 = panel.geom()
  T.eq(g1.input_height, 6, "grew to 6 rows (within the MIN 3 / MAX 10 caps)")
  T.eq(g1.trailing_blank, g1.box_rows, "reserved rows grew in step (box_rows == input_rows()+2)")
  T.eq(g1.gap, 0, "box still sits exactly on the reserved rows")
end)

-- 6. POPUP (rooted float) ------------------------------------------------------

T.it("popup: a rooted float, seated box, no gap", function()
  local ctx = T.fresh({ render = { renderer = "builtin" } })
  local panel = require("obelus.panel")
  panel._timing.fill_throttle = 0
  local file = ctx.root .. "/popup.lua"
  local lines = {}
  for i = 1, 20 do
    lines[i] = "-- line " .. i
  end
  vim.fn.writefile(lines, file)
  vim.cmd("edit " .. file)
  local fabs = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
  local c = ctx.store.add(T.comment({ file = fabs, range = { sl = 5, el = 5 } }))
  ctx.store.add_turn(c.id, "agent", "looks fine")
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  panel.open_thread(c.id, true) -- rooted popup
  T.wait_for(function()
    local g = panel.geom()
    return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
  end, 1000)
  vim.cmd("redraw")
  local g = panel.geom()
  T.ok(g, "geom present")
  T.eq(g.is_float, true)
  T.eq(g.gap, 0, "reply box sits exactly on the reserved rows")
  local wcfg = vim.api.nvim_win_get_config(g.win)
  T.eq(wcfg.relative, "win", "rooted (relative=win, hung off the source window) — not centred")
  T.ok(g.input_win ~= nil, "input window exists")
  T.eq(g.input_hidden, false, "input visible (not hidden)")
end)

-- Two-way width-fit (panel.lua's fit_rooted -> base_width_for -> thread.pref_width):
-- a short exchange gets a SNUG box (floored at MIN_W=50), not the old 100-120
-- comfort base; a fenced code block's hard content can still push past that base,
-- up to math.max(40, vim.o.columns - 4).
--
-- This can't be observed at the headless DEFAULT 80 columns: popup_width()'s 100-col
-- floor already exceeds that cap (max(40, 80-4) = 76 < 100), so a hard-content popup
-- would land on `cap` regardless of how wide the code line actually is, and the spec
-- would be vacuous for the growth half. Widen the editor for the duration of this one
-- spec (restored after) so popup_width() (120 @ 150 cols) sits BELOW the cap (146) —
-- the one condition where a real open_thread() pass can show actual content-driven
-- growth, not just the cap. (The pure arithmetic is unit-tested directly: thread_spec's
-- "panel._fit_width" spec and thread_spec's "pref_width" specs.)
T.it("popup width: snug for a short reply, wide for a fenced code line (capped to the editor)", function()
  local old_columns = vim.o.columns
  local ok, err = pcall(function()
    vim.o.columns = 150
    -- the same clamp fit_rooted computes; rooted_wincfg's OWN width clamp
    -- (math.max(40, source win width - 4)) coincides with it here because the
    -- source window spans the whole (unsplit) editor.
    local cap = math.max(40, vim.o.columns - 4)

    local ctx = T.fresh({ render = { renderer = "builtin" } })
    local panel = require("obelus.panel")
    panel._timing.fill_throttle = 0
    local file = ctx.root .. "/wide.lua"
    local lines = {}
    for i = 1, 10 do
      lines[i] = "-- line " .. i
    end
    vim.fn.writefile(lines, file)
    vim.cmd("edit " .. file)
    local fabs = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")

    -- WIDE: an agent turn with a FENCED code block containing one 200-char line —
    -- hard content (can't rewrap without breaking the block), so it's allowed to
    -- push the popup past the comfort base, up to the editor cap.
    local wide = ctx.store.add(T.comment({ file = fabs, range = { sl = 1, el = 1 } }))
    ctx.store.add_turn(wide.id, "agent", "```\n" .. string.rep("x", 200) .. "\n```")
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    panel.open_thread(wide.id, true)
    T.ok(
      T.wait_for(function()
        local g = panel.geom()
        return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
      end, 1000),
      "wide popup opened"
    )
    vim.cmd("redraw")
    local wide_width = vim.api.nvim_win_get_config(panel.geom().win).width
    panel.close()

    -- NARROW: a short single-turn draft thread (prose only) — the smallest real popup.
    local narrow = ctx.store.add(T.comment({ file = fabs, range = { sl = 2, el = 2 }, comment = "short" }))
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    panel.open_thread(narrow.id, true)
    T.ok(
      T.wait_for(function()
        local g = panel.geom()
        return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
      end, 1000),
      "narrow popup opened"
    )
    vim.cmd("redraw")
    local narrow_width = vim.api.nvim_win_get_config(panel.geom().win).width
    panel.close()

    T.eq(wide_width, cap, "the fenced-code popup grew to exactly the editor cap: " .. tostring(wide_width))
    T.ok(narrow_width < 100, "the narrow (prose-only) popup is snug, below the old 100-col comfort floor")
    T.ok(narrow_width >= 50, "the narrow popup never shrinks below MIN_W (50): " .. tostring(narrow_width))
    T.ok(narrow_width < wide_width, "the narrow popup did NOT also grow to the cap: " .. tostring(narrow_width))
  end)
  vim.o.columns = old_columns
  if not ok then
    error(err, 0)
  end
end)

-- 7. CLOSE CLEANS UP ------------------------------------------------------------

T.it("close cleans up: geom() nils out and no floating windows remain", function()
  local _, panel = seed_overflow({ as_float = true, pairs = 3 })
  T.ok(panel.geom(), "sanity: the popup is open before close")
  panel.close()
  T.is_nil(panel.geom(), "geom() nils out after close")
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local ok, cfg = pcall(vim.api.nvim_win_get_config, w)
    T.ok(not (ok and cfg.relative and cfg.relative ~= ""), "no floating windows remain")
  end
end)

-- 8. HOVER PREVIEW (popup band style) --------------------------------------------
-- fill_preview gained fill()'s coalesce/throttle + a buf-handle-aware content
-- signature (see WS6 / panel.lua's fill_preview doc comment). These specs pin the
-- two invariants that refactor could regress: a hidden-then-reshown preview must
-- never render blank (bufhidden=wipe swaps in a NEW buffer handle on every reopen —
-- the sig must not survive across that), and the coalesce must actually skip real
-- buffer writes on unchanged content while still picking up a real change.
T.describe("preview")

local function seed_preview(name)
  local ctx = T.fresh({ render = { renderer = "builtin", bands = { style = "popup" } } })
  local panel = require("obelus.panel")
  local render = require("obelus.render")
  panel._timing.fill_throttle = 0
  local file = ctx.root .. "/" .. name .. ".lua"
  vim.fn.writefile({ "local a = 1" }, file)
  vim.cmd("edit " .. file)
  local fabs = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
  local c = ctx.store.add(T.comment({ file = fabs, range = { sl = 1, el = 1 } }))
  ctx.store.add_turn(c.id, "agent", "looks fine")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  return ctx, panel, render, c
end

T.it("hide then re-show is not blank (the buf handle is part of the coalesce sig)", function()
  local _, panel, render, c = seed_preview("preview_reshow")

  render.on_cursor()
  T.ok(panel.preview_showing(c.id), "preview open for the covered comment")
  local pg1 = panel.preview_geom()
  T.ok(pg1 and pg1.buf, "preview geom present")
  T.contains(table.concat(vim.api.nvim_buf_get_lines(pg1.buf, 0, -1, false), "\n"), "looks fine")

  panel.hide_preview()
  panel.preview(c.id)
  T.ok(panel.preview_showing(c.id), "preview reopened")
  local pg2 = panel.preview_geom()
  T.ok(pg2 and pg2.buf, "preview geom present after reopen")
  T.ok(pg2.buf ~= pg1.buf, "bufhidden=wipe gave the reopened preview a NEW buffer handle")
  T.contains(
    table.concat(vim.api.nvim_buf_get_lines(pg2.buf, 0, -1, false), "\n"),
    "looks fine",
    "reopened preview is not blank"
  )
end)

T.it("coalesce: unchanged content does not rewrite the buffer; a real change does", function()
  local ctx, panel, render, c = seed_preview("preview_coalesce")

  render.on_cursor()
  T.ok(panel.preview_showing(c.id), "preview open")

  local buf = panel.preview_geom().buf
  local n = 0
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      n = n + 1
    end,
  })

  panel.refresh_preview()
  local n1 = n
  panel.refresh_preview() -- unchanged content: the coalesce must skip the buffer write
  T.eq(n, n1, "second unchanged pass did not rewrite the buffer")

  ctx.store.add_turn(c.id, "you", "one more thing")
  panel.refresh_preview()
  T.ok(n > n1, "a real content change rewrites the buffer")
end)

-- ---------------------------------------------------------------------------
-- sticky popup anchoring (render.popup_anchor)
-- ---------------------------------------------------------------------------

-- Open a rooted popup on a comment placed near the TOP of a tall file (room is
-- below -> side "below"), then scroll the code window so the selection sits near
-- the BOTTOM (room flips to above). Sticky must hold "below"; auto must flip.
local function open_rooted_near_top(ctx)
  require("obelus.panel")._timing.fill_throttle = 0 -- the flip nudge must actually fill
  local file = ctx.root .. "/g.lua"
  local lines = {}
  for i = 1, 200 do
    lines[i] = "local l" .. i .. " = " .. i
  end
  vim.fn.writefile(lines, file)
  vim.cmd("edit " .. file)
  local fabs = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
  -- mid-file line: BOTH sides have scroll headroom, so zt/zb genuinely flip
  -- which side of the viewport the selection sits on
  local c = ctx.store.add(T.comment({ file = fabs, range = { sl = 100, el = 100 } }))
  vim.api.nvim_win_set_cursor(0, { 100, 0 })
  vim.cmd("normal! zt") -- selection at the viewport top: max room below
  local cwin = vim.api.nvim_get_current_win()
  require("obelus.panel").open_thread(c.id, true) -- rooted popup
  T.ok(
    T.wait_for(function()
      local g = require("obelus.panel").geom()
      return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
    end),
    "popup opened"
  )
  return c, cwin
end

local function popup_anchor_now()
  local g = require("obelus.panel").geom()
  return vim.api.nvim_win_get_config(g.win).anchor
end

local function flip_room_and_refill(ctx, c, cwin)
  -- scroll the CODE window so the selection is near the viewport bottom: the
  -- room comparison now favours "above"
  vim.api.nvim_win_call(cwin, function()
    vim.api.nvim_win_set_cursor(cwin, { 100, 0 })
    vim.cmd("normal! zb")
  end)
  -- fills are signature-coalesced: identical content skips fit_rooted entirely.
  -- Nudge the content like a real reply would, so the re-fit actually runs.
  ctx.store.add_turn(c.id, "you", "another message that changes the fill signature")
  require("obelus.panel").refresh()
  vim.cmd("redraw")
end

T.it("preview_matches_chat = true: the side is held when the roomier side flips (no teleport)", function()
  local ctx = T.fresh({ render = { preview_matches_chat = true } })
  local c, cwin = open_rooted_near_top(ctx)
  T.eq(popup_anchor_now(), "NW", "opened hanging below (room was below)")
  flip_room_and_refill(ctx, c, cwin)
  vim.wait(100)
  T.eq(popup_anchor_now(), "NW", "held: still below — no teleport")
  require("obelus.panel").close()
end)

T.it("default (knob off): the side re-evaluates and flips to the roomier side (original behavior)", function()
  local ctx = T.fresh()
  local c, cwin = open_rooted_near_top(ctx)
  T.eq(popup_anchor_now(), "NW", "opened hanging below")
  flip_room_and_refill(ctx, c, cwin)
  T.ok(
    T.wait_for(function()
      return popup_anchor_now() == "SW"
    end, 2000),
    "auto: flipped above (roomier side)"
  )
  require("obelus.panel").close()
end)

T.it("preview_matches_chat: hover decides the side; the modal reuses it (no flip on reply)", function()
  local ctx = T.fresh({ render = { preview_matches_chat = true } })
  require("obelus.panel")._timing.fill_throttle = 0
  require("obelus.panel")._timing.preview_settle = 0
  local file = ctx.root .. "/h.lua"
  local lines = {}
  for i = 1, 200 do
    lines[i] = "local h" .. i .. " = " .. i
  end
  vim.fn.writefile(lines, file)
  vim.cmd("edit " .. file)
  local fabs = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
  local c = ctx.store.add(T.comment({ file = fabs, range = { sl = 100, el = 100 } }))
  ctx.store.add_turn(c.id, "agent", "hello there")
  vim.api.nvim_win_set_cursor(0, { 100, 0 })
  vim.cmd("normal! zt") -- room below -> hover decides "below"
  local cwin = vim.api.nvim_get_current_win()
  local panel = require("obelus.panel")
  panel.preview(c.id)
  vim.wait(200)
  panel.hide_preview()
  -- flip the room BEFORE the modal ever opens: auto would choose "above" now
  vim.api.nvim_win_call(cwin, function()
    vim.api.nvim_win_set_cursor(cwin, { 100, 0 })
    vim.cmd("normal! zb")
  end)
  panel.open_thread(c.id, true)
  T.ok(
    T.wait_for(function()
      local g = panel.geom()
      return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
    end),
    "modal opened"
  )
  local g = panel.geom()
  T.eq(vim.api.nvim_win_get_config(g.win).anchor, "NW", "the modal reused the side the HOVER decided")
  panel.close()
end)

T.it("preview_matches_chat: a short reply hover is snug too (MIN_W floor, like the chat popup)", function()
  local saved = vim.o.columns
  vim.o.columns = 150
  local ctx = T.fresh({ render = { preview_matches_chat = true } })
  require("obelus.panel")._timing.fill_throttle = 0
  require("obelus.panel")._timing.preview_settle = 0
  local file = ctx.root .. "/h2.lua"
  vim.fn.writefile({ "local a = 1" }, file)
  vim.cmd("edit " .. file)
  local fabs = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
  local c = ctx.store.add(T.comment({ file = fabs, range = { sl = 1, el = 1 } }))
  ctx.store.add_turn(c.id, "agent", "short")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local panel = require("obelus.panel")
  panel.preview(c.id)
  vim.wait(300)
  local pw
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      pw = vim.api.nvim_win_get_width(w)
    end
  end
  panel.hide_preview()
  vim.o.columns = saved
  -- source-derived recipe (base_width_for -> thread.pref_width): a short exchange
  -- floors at MIN_W (50), same as the modal chat popup would for the same content —
  -- NOT the old fixed 100-120 comfort base regardless of content length.
  T.eq(pw, 50, "hover floors at MIN_W like the chat popup would for the same short content")
end)

T.it("preview_matches_chat: hard content (a fenced code line) grows the hover past the base, capped", function()
  local saved = vim.o.columns
  vim.o.columns = 150
  local ctx = T.fresh({ render = { preview_matches_chat = true } })
  require("obelus.panel")._timing.fill_throttle = 0
  require("obelus.panel")._timing.preview_settle = 0
  local file = ctx.root .. "/h2b.lua"
  vim.fn.writefile({ "local a = 1" }, file)
  vim.cmd("edit " .. file)
  local fabs = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
  local c = ctx.store.add(T.comment({ file = fabs, range = { sl = 1, el = 1 } }))
  -- a fenced code line pushes hard_w past the comfort base, same as the chat popup
  ctx.store.add_turn(c.id, "agent", "```\n" .. string.rep("x", 200) .. "\n```")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local panel = require("obelus.panel")
  panel.preview(c.id)
  vim.wait(300)
  local pw
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      pw = vim.api.nvim_win_get_width(w)
    end
  end
  panel.hide_preview()
  vim.o.columns = saved
  -- same cap the chat popup would grow to: math.max(40, 150 - 4) = 146
  T.eq(pw, 146, "hover grows past the comfort base for hard content, same as the chat popup")
end)

T.it("default (knob off): the hover keeps its own narrower auto width", function()
  local saved = vim.o.columns
  vim.o.columns = 150
  local ctx = T.fresh()
  require("obelus.panel")._timing.fill_throttle = 0
  require("obelus.panel")._timing.preview_settle = 0
  local file = ctx.root .. "/h3.lua"
  vim.fn.writefile({ "local a = 1" }, file)
  vim.cmd("edit " .. file)
  local fabs = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
  local c = ctx.store.add(T.comment({ file = fabs, range = { sl = 1, el = 1 } }))
  ctx.store.add_turn(c.id, "agent", "short")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local panel = require("obelus.panel")
  panel.preview(c.id)
  vim.wait(300)
  local pw
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      pw = vim.api.nvim_win_get_width(w)
    end
  end
  panel.hide_preview()
  vim.o.columns = saved
  T.eq(pw, 105, "the original 0.7-fraction preview width")
end)

T.it("keys.chat.maximize: the popup toggles to near-full-editor and back to the fitted root", function()
  local ctx = T.fresh()
  require("obelus.panel")._timing.fill_throttle = 0
  local file = ctx.root .. "/m.lua"
  vim.fn.writefile({ "local a = 1" }, file)
  vim.cmd("edit " .. file)
  local fabs = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
  local c = ctx.store.add(T.comment({ file = fabs, range = { sl = 1, el = 1 } }))
  ctx.store.add_turn(c.id, "agent", "hello")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local panel = require("obelus.panel")
  panel.open_thread(c.id, true)
  T.ok(
    T.wait_for(function()
      local g = panel.geom()
      return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
    end),
    "popup opened"
  )
  local g = panel.geom()
  T.eq(vim.api.nvim_win_get_config(g.win).relative, "win", "rooted before maximize")
  panel.toggle_maximize()
  T.ok(
    T.wait_for(function()
      return vim.api.nvim_win_get_config(g.win).relative == "editor"
    end),
    "maximized to an editor overlay"
  )
  T.eq(vim.api.nvim_win_get_width(g.win), math.max(40, vim.o.columns - 4), "near-full width")
  panel.toggle_maximize()
  T.ok(
    T.wait_for(function()
      return vim.api.nvim_win_get_config(g.win).relative == "win"
    end),
    "back to the fitted rooted geometry"
  )
  panel.close()
end)
