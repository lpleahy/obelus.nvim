-- panel: functional open/close of the chat surface + renderer selection.
T.describe("panel")

local function chat_buffer()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "obelus_reply" then
      local pw = vim.api.nvim_win_get_config(w).win
      pw = (type(pw) == "table") and (pw[false] or pw[1] or pw[true]) or pw
      if pw and vim.api.nvim_win_is_valid(pw) then
        return vim.api.nvim_win_get_buf(pw), w
      end
    end
  end
end

T.it("set_renderer writes the session override (config.ui), not config.options", function()
  T.fresh()
  local obelus = require("obelus")
  local config = require("obelus.config")
  obelus.set_renderer("builtin")
  T.eq(config.ui.renderer, "builtin")
  T.is_nil(config.options.render.renderer) -- config.options is untouched
  obelus.set_renderer("treesitter")
  T.eq(config.ui.renderer, "treesitter")
  T.is_nil(config.options.render.renderer)
  obelus.set_renderer("auto")
  T.eq(config.ui.renderer, "auto") -- an EXPLICIT auto override, distinct from nil ("never toggled")
  T.is_nil(config.options.render.renderer)
end)

T.it("set_renderer survives a re-run of setup() (e.g. a plugin manager reload)", function()
  local ctx = T.fresh()
  local obelus = require("obelus")
  local config = require("obelus.config")
  obelus.set_renderer("treesitter")
  T.eq(config.ui.renderer, "treesitter")
  -- re-setup rebuilds config.options from deepcopied defaults; the session override
  -- must NOT be reverted by it
  obelus.setup({ root = ctx.root, persist = { backend = "data", auto = false } })
  T.eq(config.ui.renderer, "treesitter")
end)

T.it("toggle_mode / toggle_band_style / toggle_resolved survive a re-run of setup()", function()
  local ctx = T.fresh()
  local obelus = require("obelus")
  local render = require("obelus.render")
  local config = require("obelus.config")

  T.eq(config.mode(), "inline")
  obelus.toggle_mode()
  T.eq(config.mode(), "sidebar")

  local style_before = render.band_style()
  render.toggle_band_style()
  local style_after = render.band_style()
  T.ok(style_after ~= style_before, "band style flipped")

  local resolved_before = render.resolved_shown()
  render.toggle_resolved()
  local resolved_after = render.resolved_shown()
  T.eq(resolved_after, not resolved_before)

  obelus.setup({ root = ctx.root, persist = { backend = "data", auto = false } })

  T.eq(config.mode(), "sidebar")
  T.eq(render.band_style(), style_after)
  T.eq(render.resolved_shown(), resolved_after)
end)

T.it("toggle_hints survives a re-run of setup()", function()
  local ctx = T.fresh()
  local obelus = require("obelus")
  local render = require("obelus.render")

  local hints_before = render.hints_shown()
  obelus.toggle_hints()
  local hints_after = render.hints_shown()
  T.eq(hints_after, not hints_before)

  obelus.setup({ root = ctx.root, persist = { backend = "data", auto = false } })

  T.eq(render.hints_shown(), hints_after)
end)

T.it("open_thread (builtin) opens the chat with a docked reply box", function()
  local ctx = T.fresh({ render = { renderer = "builtin" } })
  local file = ctx.root .. "/f.lua"
  vim.fn.writefile({ "local a = 1", "local b = 2", "return a + b" }, file)
  vim.cmd("edit " .. file)
  local fabs = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
  local c = ctx.store.add(T.comment({ file = fabs, range = { sl = 1, el = 1 } }))
  ctx.store.add_turn(c.id, "agent", "acknowledged, nothing to change")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local panel = require("obelus.panel")
  panel.open_thread(c.id, true) -- rooted popup
  vim.cmd("redraw")
  local chat_buf, input_win = chat_buffer()
  T.ok(input_win, "reply input window exists")
  T.ok(chat_buf, "chat buffer exists")
  local text = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
  T.contains(text, "acknowledged, nothing to change")
  panel.refresh() -- must not error on a settled thread
  panel.close()
end)

T.it("panel list: the project thread is pinned as the FIRST row; <CR> on it opens its chat", function()
  local ctx = T.fresh()
  require("obelus.panel")._timing.fill_throttle = 0 -- a fresh open right after a prior
  -- test's fill() must not get coalesce-skipped by the shared module-level timestamp
  -- a real per-file thread too, so the pinned row is verifiably ABOVE it, not just
  -- the only row in an otherwise-empty list
  ctx.store.add(T.comment({ file = ctx.root .. "/f.lua", comment = "a real thread" }))
  local meta = ctx.store.meta_thread()
  local panel = require("obelus.panel")
  panel.open()
  vim.cmd("redraw")
  local g = panel.geom()
  T.eq(g.mode, "list")
  local lines = vim.api.nvim_buf_get_lines(g.buf, 0, -1, false)
  local meta_row
  for i, l in ipairs(lines) do
    if l:find("project thread", 1, true) then
      meta_row = i
      break
    end
  end
  T.ok(meta_row, "a 'project thread' row exists in the list")
  local file_row
  for i, l in ipairs(lines) do
    if l:find("a real thread", 1, true) then
      file_row = i
      break
    end
  end
  T.ok(file_row, "the real thread's row exists too")
  T.ok(meta_row < file_row, "the project thread row comes BEFORE any per-file thread row")

  vim.api.nvim_win_set_cursor(g.win, { meta_row, 0 })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  vim.cmd("redraw")
  local g2 = panel.geom()
  T.eq(g2.mode, "chat", "<CR> on the pinned row opened chat mode")
  T.eq(g2.thread, meta.id, "the chat opened IS the project thread")
  panel.close()
end)

-- tag meta threads ------------------------------------------------------------

T.it("panel list: no active tag -> no pinned '#<tag> thread' row", function()
  local ctx = T.fresh()
  ctx.store.set_active_tag(nil) -- store.active_tag isn't reset by T.fresh (only a real store.load() clears it)
  require("obelus.panel")._timing.fill_throttle = 0
  ctx.store.meta_thread()
  ctx.store.add(T.comment({ file = ctx.root .. "/f.lua", comment = "a real thread" }))
  local panel = require("obelus.panel")
  panel.open()
  vim.cmd("redraw")
  local g = panel.geom()
  local text = table.concat(vim.api.nvim_buf_get_lines(g.buf, 0, -1, false), "\n")
  T.contains(text, "project thread", "the global row is still there")
  T.ok(not text:find("◆  #", 1, true), "no tag row when no tag is engaged (no active tag, no open tagged batch)")
  panel.close()
end)

T.it(
  "panel list: an active (sticky) tag pins '#<tag> thread' under the global row; <CR> opens it (get-or-create)",
  function()
    local ctx = T.fresh()
    require("obelus.panel")._timing.fill_throttle = 0
    ctx.store.meta_thread()
    ctx.store.set_active_tag("auth")
    T.is_nil(ctx.store.get_meta("auth"), "the tag meta record doesn't exist yet — only engagement (active_tag) does")

    local panel = require("obelus.panel")
    panel.open()
    vim.cmd("redraw")
    local g = panel.geom()
    local lines = vim.api.nvim_buf_get_lines(g.buf, 0, -1, false)
    local meta_row, tag_row
    for i, l in ipairs(lines) do
      if not meta_row and l:find("project thread", 1, true) then
        meta_row = i
      end
      if l:find("#auth thread", 1, true) then
        tag_row = i
      end
    end
    T.ok(meta_row, "the global row is present")
    T.ok(tag_row, "the #auth row is present")
    T.ok(tag_row > meta_row, "the tag row sits UNDER the global row")

    vim.api.nvim_win_set_cursor(g.win, { tag_row, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    vim.cmd("redraw")
    local g2 = panel.geom()
    T.eq(g2.mode, "chat", "<CR> on the tag row opened chat mode")
    local created = ctx.store.get_meta("auth")
    T.ok(created, "the tag meta record was get-or-created by <CR>")
    T.eq(g2.thread, created.id, "the chat opened IS the newly created #auth thread")
    panel.close()
    ctx.store.set_active_tag(nil) -- don't leak sticky tagging mode into the next spec (process-wide singleton)
  end
)

T.it("tag_thread(): no active tag notifies; a sticky tag opens/creates and toggles closed on a second call", function()
  local ctx = T.fresh()
  ctx.store.set_active_tag(nil) -- guard against a leaked active_tag from a prior spec (see above)
  local obelus = require("obelus")
  local panel = require("obelus.panel")

  local msg
  local orig = vim.notify
  vim.notify = function(m, ...)
    msg = m
    return orig(m, ...)
  end
  obelus.tag_thread()
  vim.notify = orig
  T.contains(msg or "", "no active tag", "no tag context at all -> a clear notice")

  ctx.store.set_active_tag("auth")
  obelus.tag_thread()
  vim.cmd("redraw")
  local created = ctx.store.get_meta("auth")
  T.ok(created, "get-or-created the sticky tag's meta thread")
  T.ok(panel.showing(created.id), "opened it")

  obelus.tag_thread() -- press it again while it's already open
  T.ok(not panel.showing(created.id), "a second call while showing TOGGLES it closed")
  ctx.store.set_active_tag(nil) -- don't leak sticky tagging mode into the next spec (process-wide singleton)
end)

T.it("the explorer lists EVERY existing tag meta-conversation, not just the engaged tag's", function()
  local ctx = T.fresh()
  require("obelus.panel")._timing.fill_throttle = 0 -- fresh open right after a prior test's fill
  ctx.store.set_active_tag(nil)
  -- two past tag conversations, neither engaged
  local a = ctx.store.tag_meta_thread("auth")
  ctx.store.add_turn(a.id, "agent", "old auth discussion")
  ctx.store.tag_meta_thread("perf")
  local panel = require("obelus.panel")
  panel.open(false)
  T.ok(
    T.wait_for(function()
      return panel.geom() ~= nil
    end),
    "list opened"
  )
  local g = panel.geom()
  local text
  T.ok(
    T.wait_for(function()
      text = table.concat(vim.api.nvim_buf_get_lines(g.buf, 0, -1, false), "\n")
      return text:find("#auth thread", 1, true) ~= nil
    end, 2000),
    "list filled"
  )
  T.contains(text, "#auth thread", "past tag conversation findable")
  T.contains(text, "#perf thread", "the other one too")
  T.contains(text, "1 turns", "conversation size hinted")
  panel.close()
end)

T.it("back() from a sidebar chat parks the LIST on that thread's row; fresh opens park at the top", function()
  local ctx = T.fresh()
  require("obelus.panel")._timing.fill_throttle = 0
  ctx.store.set_active_tag(nil)
  -- enough threads that a bottom-seated scroll would hide the top of the list
  local ids = {}
  for i = 1, 12 do
    local c = ctx.store.add(T.comment({ file = ctx.root .. "/f" .. i .. ".lua", comment = "thread " .. i }))
    ctx.store.add_turn(c.id, "agent", ("reply line\n"):rep(6))
    ids[i] = c.id
  end
  local panel = require("obelus.panel")
  panel.open_thread(ids[7], false) -- sidebar chat (seats to the bottom)
  T.ok(
    T.wait_for(function()
      local g = panel.geom()
      return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
    end),
    "chat opened"
  )
  panel.back()
  local g = panel.geom()
  T.eq(g.mode, "list", "back in the list")
  local row = vim.api.nvim_win_get_cursor(g.win)[1]
  local line = vim.api.nvim_buf_get_lines(g.buf, row - 1, row, false)[1] or ""
  T.contains(line, "thread 7", "cursor parked on the thread we just left")
  panel.close()

  panel.open(false) -- fresh open, no prior chat
  T.ok(
    T.wait_for(function()
      return panel.geom() ~= nil
    end),
    "list opened"
  )
  local g2 = panel.geom()
  local info = vim.fn.getwininfo(g2.win)[1] or {}
  T.eq(info.topline, 1, "a fresh list starts at the top, not scrolled past its content")
  panel.close()
end)

-- keys.list: LIST-mode buffer-local bindings on the shared panel buffer -------

local function n_cb(buf, lhs)
  for _, km in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if km.lhs == lhs then
      return km.callback
    end
  end
end

T.it("keys.list.delete = 'X': X is bound on the panel buffer, dd is not", function()
  local ctx = T.fresh({ keys = { list = { delete = "X" } } })
  require("obelus.panel")._timing.fill_throttle = 0
  ctx.store.add(T.comment({ file = ctx.root .. "/f.lua", comment = "q" }))
  local panel = require("obelus.panel")
  panel.open()
  T.ok(
    T.wait_for(function()
      return panel.geom() ~= nil
    end),
    "list opened"
  )
  local g = panel.geom()
  T.ok(n_cb(g.buf, "X"), "the rebound lhs is bound")
  T.is_nil(n_cb(g.buf, "dd"), "the old default is no longer bound")
  panel.close()
end)

T.it("keys.list.resolve = false disables the binding entirely", function()
  local ctx = T.fresh({ keys = { list = { resolve = false } } })
  require("obelus.panel")._timing.fill_throttle = 0
  ctx.store.add(T.comment({ file = ctx.root .. "/f.lua", comment = "q" }))
  local panel = require("obelus.panel")
  panel.open()
  T.ok(
    T.wait_for(function()
      return panel.geom() ~= nil
    end),
    "list opened"
  )
  local g = panel.geom()
  T.is_nil(n_cb(g.buf, "x"), "x is not bound when keys.list.resolve = false")
  panel.close()
end)

T.it("keys.list: a dual-mode binding (jump) rebinds ONCE and still works in chat mode too", function()
  local ctx = T.fresh({ keys = { list = { jump = "J" } } })
  require("obelus.panel")._timing.fill_throttle = 0
  local file = ctx.root .. "/f.lua"
  vim.fn.writefile({ "local a = 1" }, file)
  local c = ctx.store.add(T.comment({ file = file, range = { sl = 1, el = 1 } }))
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
  T.ok(n_cb(g.buf, "J"), "the rebound lhs is bound in chat mode too — jump acts in both modes")
  T.is_nil(n_cb(g.buf, "gd"), "the old default is gone in chat mode too (one binding, one name)")
  panel.close()
end)

T.it("meta rows carry their own accent group, distinct from the grey chrome", function()
  local ctx = T.fresh()
  require("obelus.panel")._timing.fill_throttle = 0
  ctx.store.set_active_tag(nil)
  ctx.store.meta_thread()
  local panel = require("obelus.panel")
  panel.open(false)
  T.ok(
    T.wait_for(function()
      return panel.geom() ~= nil
    end),
    "list opened"
  )
  local g = panel.geom()
  local found
  T.ok(
    T.wait_for(function()
      for _, m in
        ipairs(
          vim.api.nvim_buf_get_extmarks(g.buf, vim.api.nvim_create_namespace("obelus_panel"), 0, -1, { details = true })
        )
      do
        if (m[4] or {}).hl_group == "ObelusMetaThread" then
          found = true
        end
      end
      return found
    end, 2000),
    "the project-thread row uses ObelusMetaThread, not ObelusChrome"
  )
  local hl = vim.api.nvim_get_hl(0, { name = "ObelusMetaThread", link = false })
  T.ok(hl.bold and hl.fg, "brand accent + bold defined")
  panel.close()
end)
