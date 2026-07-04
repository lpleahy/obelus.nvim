local config = require("obelus.config")
local store = require("obelus.store")
local render = require("obelus.render")
local capture = require("obelus.capture")
local view = require("obelus.view")
local review = require("obelus.review")

local M = {}

-- Public API ----------------------------------------------------------------

---Capture a review comment for the current line.
M.comment = capture.comment_normal
---Capture a review comment for the visual selection.
M.comment_visual = capture.comment_visual

---Toggle annotation display. `scope == "global"` toggles everywhere; else just this buffer.
---@param scope? "global"
function M.toggle(scope)
  render.toggle(scope)
end

---Open the review list.
---@param backend? "buffer"|"quickfix"|"split"
function M.list(backend)
  view.open(backend)
end

-- Resolve a comment by id, or fall back to the one under the cursor. Used only by
-- the UI entry points that stay here (open_chat, quick_reply) — everything else
-- moved to review.lua's own with_comment-wrapped guard.
local function lookup(id)
  if id then
    return store.get(id)
  end
  return render.at_cursor()
end

-- Chat/dispatch service layer (edit, delete, submit, tag(_mode), continue_batch,
-- batch_advance, dispatch, cancel, resolve, reopen, toggle_resolve, busy, respond,
-- chat_save, chat_send, clear) lives in review.lua; thin re-exports below.
M.edit = review.edit
M.delete = review.delete
M.submit = review.submit
M.tag = review.tag
M.tag_mode = review.tag_mode
M.continue_batch = review.continue_batch
M.batch_advance = review.batch_advance
M.dispatch = review.dispatch
M.cancel = review.cancel
M.resolve = review.resolve
M.reopen = review.reopen
M.toggle_resolve = review.toggle_resolve
M.busy = review.busy
M.respond = review.respond
M.chat_save = review.chat_save
M.chat_send = review.chat_send
M.clear = review.clear

-- Set (or, with no arg, cycle) the chat markdown renderer. Applies live to an open
-- panel. Writes the session override config.ui.renderer (NOT config.options), so it
-- survives a re-run of setup() — panel.render_mode() resolves it first.
--   "markview" | "builtin" | "treesitter" | "auto" (auto = markview if installed, else builtin)
---@param mode? "markview"|"builtin"|"treesitter"|"auto"
function M.set_renderer(mode)
  local order = { "markview", "builtin", "treesitter" }
  if not mode then -- cycle from whatever is effectively active
    local cur = config.ui.renderer
    if cur == "auto" then
      cur = nil
    end
    if cur == nil then
      cur = config.options.render.renderer
    end
    if cur ~= "markview" and cur ~= "builtin" and cur ~= "treesitter" then
      cur = pcall(require, "markview.actions") and "markview" or "builtin"
    end
    local i = 1
    for idx, m in ipairs(order) do
      if m == cur then
        i = idx
        break
      end
    end
    mode = order[(i % #order) + 1]
  end
  if mode ~= "markview" and mode ~= "builtin" and mode ~= "treesitter" and mode ~= "auto" then
    return vim.notify("obelus: renderer must be markview | builtin | treesitter | auto", vim.log.levels.WARN)
  end
  config.ui.renderer = mode -- "auto" stored literally: an explicit auto override
  pcall(function()
    require("obelus.panel").refresh()
  end)
  pcall(function()
    require("obelus.render").render_all()
  end)
  vim.notify("obelus: renderer = " .. mode)
end

---Toggle the review threads sidebar/popup.
function M.panel()
  require("obelus.panel").toggle()
end

-- Open the sidebar: if the cursor is on a comment, open that thread's chat in the
-- sidebar; otherwise open the threads list (the navigator). So <prefix>o is one key
-- that always opens the sidebar, whether or not you're on a thread.
---@param id? string
function M.open_chat(id)
  local c = lookup(id)
  if not c then
    return require("obelus.panel").open() -- not on a thread → the list navigator
  end
  require("obelus.panel").open_thread(c.id, false)
end

---Set the engagement modality (session override, survives re-setup()) and repaint.
---@param mode "inline"|"sidebar"
function M.set_mode(mode)
  config.ui.mode = mode
  render.render_all()
  vim.notify("obelus: " .. mode .. " mode", vim.log.levels.INFO)
end

---Toggle between inline and sidebar engagement.
function M.toggle_mode()
  M.set_mode(config.mode() == "sidebar" and "inline" or "sidebar")
end

---Toggle the keybind hint footers (session override, survives re-setup()) and
---repaint every surface (bands, sidebar/popup, compose) so they appear/disappear live.
function M.toggle_hints()
  config.ui.hints = not render.hints_shown()
  pcall(function()
    require("obelus.panel").refresh()
  end)
  render.render_all()
  vim.notify("obelus: keybind hints " .. (config.ui.hints and "shown" or "hidden"), vim.log.levels.INFO)
end

---Reply to the comment under the cursor in whichever modality is active.
function M.reply_here()
  local panel = require("obelus.panel")
  local c = render.at_cursor()
  if config.mode() == "sidebar" then
    if not c then
      return M.open_chat() -- nothing under the cursor: just open the navigator
    end
    panel.open_thread(c.id, false)
  else
    -- inline: pop the thread into a floating chat (the file can't host an
    -- editable bubble, so the popup gives the same in-flow chat)
    if not c then
      return vim.notify("obelus: no comment under cursor", vim.log.levels.WARN)
    end
    panel.open_thread(c.id, true)
  end
  -- open_thread already lands in the input in insert; nothing more to do
end

-- Quick reply via the small inline float (same look as adding a comment), as an
-- alternative to the full thread popup. The agent's reply streams into the band.
---@param id? string
function M.quick_reply(id)
  local c = lookup(id)
  if not c then
    return vim.notify("obelus: no comment here", vim.log.levels.WARN)
  end
  render.arm_follow(c.id) -- seat the comment ~1/4 down so its band (history) is in view
  render.compose({
    title = "reply",
    anchor_above = true, -- sit above the comment so the band below stays visible (not
    -- stranded at the very bottom of the screen)
    on_submit = function(text, action)
      if action == "save" then
        M.chat_save(c.id, text)
      else
        M.chat_send(c.id, text, action == "send_fast" and "fast" or "send")
      end
    end,
  })
end

-- Setup ---------------------------------------------------------------------

local function commands()
  local cmd = vim.api.nvim_create_user_command
  cmd("ObelusComment", function(a)
    if a.range > 0 then
      M.comment_visual()
    else
      M.comment()
    end
  end, { range = true, desc = "obelus: add a review comment" })

  cmd("ObelusToggle", function(a)
    M.toggle(a.args ~= "" and a.args or nil)
  end, {
    nargs = "?",
    complete = function()
      return { "global" }
    end,
    desc = "obelus: toggle annotations",
  })

  cmd("ObelusList", function(a)
    M.list(a.args ~= "" and a.args or nil)
  end, {
    nargs = "?",
    complete = function()
      return { "buffer", "quickfix", "split" }
    end,
    desc = "obelus: open the review list",
  })

  cmd("ObelusEdit", function()
    M.edit()
  end, { desc = "obelus: edit comment at cursor" })

  cmd("ObelusDelete", function()
    M.delete()
  end, { desc = "obelus: delete comment at cursor" })

  cmd("ObelusSubmit", function(a)
    M.submit(a.args ~= "" and a.args or nil)
  end, {
    nargs = "?",
    complete = function()
      return require("obelus.transport").names()
    end,
    desc = "obelus: submit the review batch",
  })

  cmd("ObelusContinue", function(a)
    M.continue_batch(a.args ~= "" and a.args or nil)
  end, {
    nargs = "?",
    desc = "obelus: continue the open batch conversation (next round)",
  })

  cmd("ObelusRenderer", function(a)
    M.set_renderer(a.args ~= "" and a.args or nil)
  end, {
    nargs = "?",
    complete = function()
      return { "markview", "builtin", "treesitter", "auto" }
    end,
    desc = "obelus: set the chat markdown renderer (markview|builtin|treesitter|auto)",
  })

  cmd("ObelusTag", function(a)
    M.tag(nil, a.args ~= "" and a.args or nil)
  end, {
    nargs = "?",
    complete = function()
      return store.tags()
    end,
    desc = "obelus: tag/untag the thread at cursor (curates batch membership)",
  })

  cmd("ObelusTagMode", function(a)
    M.tag_mode(a.args ~= "" and a.args or nil)
  end, {
    nargs = "?",
    complete = function()
      return store.tags()
    end,
    desc = "obelus: toggle sticky tagging mode (new threads inherit the tag)",
  })

  cmd("ObelusDispatch", function()
    M.dispatch()
  end, { desc = "obelus: dispatch comment at cursor to a background agent" })

  cmd("ObelusCancel", function()
    M.cancel()
  end, { desc = "obelus: cancel the in-flight dispatch at cursor" })

  cmd("ObelusClear", function()
    M.clear()
  end, { desc = "obelus: clear all comments" })

  cmd("ObelusSave", function()
    store.save()
  end, { desc = "obelus: save reviews to disk" })

  cmd("ObelusLoad", function()
    store.load()
    render.render_all()
  end, { desc = "obelus: reload reviews from disk" })

  cmd("ObelusJobs", function()
    require("obelus.log").open()
  end, { desc = "obelus: open the background-job output log" })

  cmd("ObelusBands", function()
    render.toggle_band()
  end, { desc = "obelus: toggle inline comment bands in this buffer" })

  cmd("ObelusBandStyle", function()
    render.toggle_band_style()
  end, { desc = "obelus: toggle thread display style (inline band | hover popup)" })

  cmd("ObelusPanel", function()
    M.panel()
  end, { desc = "obelus: toggle the review threads sidebar" })

  cmd("ObelusResolve", function()
    M.resolve()
  end, { desc = "obelus: resolve comment at cursor" })

  cmd("ObelusReopen", function()
    M.reopen()
  end, { desc = "obelus: reopen comment at cursor" })

  cmd("ObelusRespond", function()
    M.respond()
  end, { desc = "obelus: respond to the thread at cursor" })

  cmd("ObelusQuickReply", function()
    M.quick_reply()
  end, { desc = "obelus: quick reply to the thread at cursor (inline float)" })

  cmd("ObelusChat", function()
    M.open_chat()
  end, { desc = "obelus: open the thread chat sidebar for the comment at cursor" })

  cmd("ObelusToggleResolved", function()
    render.toggle_resolved()
  end, { desc = "obelus: show/hide resolved comments" })

  cmd("ObelusMode", function(a)
    if a.args == "inline" or a.args == "sidebar" then
      M.set_mode(a.args)
    else
      M.toggle_mode()
    end
  end, {
    nargs = "?",
    complete = function()
      return { "inline", "sidebar" }
    end,
    desc = "obelus: toggle/set engagement mode (inline|sidebar)",
  })

  cmd("ObelusHints", function()
    M.toggle_hints()
  end, { desc = "obelus: toggle keybind hint footers" })

  cmd("ObelusPrompt", function()
    require("obelus.log").open_prompt()
  end, { desc = "obelus: show the last prompt sent to the agent (verbatim)" })

  cmd("ObelusRenderInfo", function()
    vim.print(require("obelus.panel").render_info())
  end, { desc = "obelus: dump the renderer decision inputs for the chat/preview" })
end

-- Declarative keymap spec: one row per default mapping (lhs = keys.prefix .. suffix).
-- rhs is a function, EXCEPT the x-mode comment map, which MUST stay the exact
-- ':<C-u>lua...' STRING rhs — the <C-u> clears the visual range so '<,'> marks are
-- set from the just-made selection before comment_visual reads them; a function rhs
-- loses that guarantee. Skip a row entirely via keys.disabled = { suffix, ... }.
local MAPSPEC = {
  { suffix = "c", modes = "n", rhs = M.comment, desc = "obelus: comment line" },
  {
    suffix = "c",
    modes = "x",
    rhs = ":<C-u>lua require('obelus').comment_visual()<CR>",
    desc = "obelus: comment selection",
    silent = true,
  },
  {
    suffix = "t",
    modes = "n",
    rhs = function()
      M.toggle()
    end,
    desc = "obelus: toggle (buffer)",
  },
  {
    suffix = "T",
    modes = "n",
    rhs = function()
      M.toggle("global")
    end,
    desc = "obelus: toggle (global)",
  },
  {
    suffix = "l",
    modes = "n",
    rhs = function()
      M.list()
    end,
    desc = "obelus: list",
  },
  {
    suffix = "q",
    modes = "n",
    rhs = function()
      M.list("quickfix")
    end,
    desc = "obelus: quickfix",
  },
  {
    suffix = "j",
    modes = "n",
    rhs = function()
      require("obelus.log").open()
    end,
    desc = "obelus: job output log",
  },
  {
    suffix = "b",
    modes = "n",
    rhs = function()
      render.toggle_band()
    end,
    desc = "obelus: toggle inline bands",
  },
  {
    suffix = "B",
    modes = "n",
    rhs = function()
      render.toggle_band_style()
    end,
    desc = "obelus: toggle band/popup style",
  },
  {
    suffix = "p",
    modes = "n",
    rhs = function()
      M.panel()
    end,
    desc = "obelus: toggle threads sidebar",
  },
  {
    suffix = "R",
    modes = "n",
    rhs = function()
      M.toggle_resolve()
    end,
    desc = "obelus: toggle resolved at cursor",
  },
  {
    suffix = "z",
    modes = "n",
    rhs = function()
      render.toggle_pin()
    end,
    desc = "obelus: pin/collapse band",
  },
  {
    suffix = "J",
    modes = "n",
    rhs = function()
      render.scroll(1)
    end,
    desc = "obelus: scroll thread down",
  },
  {
    suffix = "K",
    modes = "n",
    rhs = function()
      render.scroll(-1)
    end,
    desc = "obelus: scroll thread up",
  },
  {
    suffix = "m",
    modes = "n",
    rhs = function()
      M.toggle_mode()
    end,
    desc = "obelus: toggle inline/sidebar mode",
  },
  {
    suffix = "?",
    modes = "n",
    rhs = function()
      M.toggle_hints()
    end,
    desc = "obelus: toggle keybind hints",
  },
  {
    suffix = "o",
    modes = "n",
    rhs = function()
      M.open_chat()
    end,
    desc = "obelus: open full thread (scrollable)",
  },
  {
    suffix = "h",
    modes = "n",
    rhs = function()
      render.toggle_resolved()
    end,
    desc = "obelus: show/hide resolved",
  },
  {
    suffix = "r",
    modes = "n",
    rhs = function()
      M.reply_here()
    end,
    desc = "obelus: reply to thread at cursor",
  },
  {
    suffix = "f",
    modes = "n",
    rhs = function()
      M.quick_reply()
    end,
    desc = "obelus: quick reply (inline float)",
  },
  -- (edit-comment keymap removed: a thread's unsent message now opens editable in the reply box
  -- via <prefix>r/<prefix>o; :ObelusEdit still edits the raw comment text if you want it)
  {
    suffix = "d",
    modes = "n",
    rhs = function()
      M.delete()
    end,
    desc = "obelus: delete at cursor",
  },
  {
    suffix = "s",
    modes = "n",
    rhs = function()
      M.batch_advance()
    end,
    desc = "obelus: submit / continue batch (auto)",
  },
  {
    suffix = "S",
    modes = "n",
    rhs = function()
      M.submit()
    end,
    desc = "obelus: force a new batch (even if one is open)",
  },
  {
    suffix = "D",
    modes = "n",
    rhs = function()
      M.dispatch()
    end,
    desc = "obelus: dispatch one (background)",
  },
  {
    suffix = "g",
    modes = "n",
    rhs = function()
      M.tag()
    end,
    desc = "obelus: tag/untag thread (batch group)",
  },
  {
    suffix = "G",
    modes = "n",
    rhs = function()
      M.tag_mode()
    end,
    desc = "obelus: toggle sticky tagging mode",
  },
  {
    suffix = "C",
    modes = "n",
    rhs = function()
      M.cancel()
    end,
    desc = "obelus: cancel dispatch at cursor",
  },
  {
    suffix = "x",
    modes = "n",
    rhs = function()
      M.clear()
    end,
    desc = "obelus: clear all",
  },
}

-- Suffixes listed in keys.disabled, as a set. Shared by keymaps() (which skips the
-- map entirely) and whichkey() (which must skip registering that entry too, or
-- which-key would resurrect a mapping the user asked to disable).
local function disabled_suffixes(k)
  local disabled = {}
  for _, suffix in ipairs((k and k.disabled) or {}) do
    disabled[suffix] = true
  end
  return disabled
end

-- keys.overrides[suffix]: nil keeps the default `prefix .. suffix` lhs; `false`
-- disables the row (same effect as listing it in keys.disabled); a string is a FULL
-- replacement lhs (used verbatim — NOT appended to `prefix`). Shared by keymaps()
-- (the real mapping) and whichkey()'s `add` (which must follow the same lhs, or
-- skip the row when the override moved outside the <prefix> group — see there).
-- Returns the lhs to map, or nil if the row should be skipped entirely.
local function suffix_lhs(k, suffix, p)
  -- NOT the `cond and a or b` idiom: overrides[suffix] can legitimately BE `false`,
  -- which that idiom silently swallows back into the `or` branch.
  local ov = nil
  if type(k.overrides) == "table" then
    ov = k.overrides[suffix]
  end
  if ov == false then
    return nil
  elseif ov ~= nil then
    return ov
  end
  return p .. suffix
end

-- One-time warning for a keys.overrides suffix that doesn't match any MAPSPEC row
-- (a typo, or a suffix from a since-removed mapping) — silently ignored otherwise,
-- so surface it instead of leaving the override looking like it did nothing.
local function warn_unknown_overrides(k)
  if type(k.overrides) ~= "table" then
    return
  end
  local known = {}
  for _, spec in ipairs(MAPSPEC) do
    known[spec.suffix] = true
  end
  for suffix in pairs(k.overrides) do
    if not known[suffix] then
      vim.notify_once(
        "obelus: keys.overrides has no suffix '" .. tostring(suffix) .. "' — ignored",
        vim.log.levels.WARN
      )
    end
  end
end

-- `k` defaults to config.options.keys; a test seam (M._keymaps) can pass a throwaway
-- config directly, so a spec can verify override/disable behavior without disturbing
-- the real session's mappings (this only ADDS mappings — it never unmaps a stale lhs
-- from a prior call, so tests should use a prefix/lhs family they own exclusively).
local function keymaps(k)
  k = k or config.options.keys
  if not k then
    return
  end
  local p = k.prefix or "<leader>o"
  local map = vim.keymap.set
  local disabled = disabled_suffixes(k)
  warn_unknown_overrides(k)
  for _, spec in ipairs(MAPSPEC) do
    if not disabled[spec.suffix] then
      local lhs = suffix_lhs(k, spec.suffix, p)
      if lhs then
        map(spec.modes, lhs, spec.rhs, { desc = spec.desc, silent = spec.silent })
      end
    end
  end
  -- band_scroll: user-chosen lhs (not keys.prefix .. suffix), so it stays outside MAPSPEC
  local bs = k.band_scroll
  if bs then
    if bs.line_down then
      map("n", bs.line_down, function()
        render.scroll(1, 1)
      end, { desc = "obelus: thread down a line" })
    end
    if bs.line_up then
      map("n", bs.line_up, function()
        render.scroll(-1, 1)
      end, { desc = "obelus: thread up a line" })
    end
    if bs.down then
      map("n", bs.down, function()
        render.scroll(1)
      end, { desc = "obelus: thread down half-page" })
    end
    if bs.up then
      map("n", bs.up, function()
        render.scroll(-1)
      end, { desc = "obelus: thread up half-page" })
    end
  end
end

-- Diff-view highlights, linked to builtin Diff groups so they look right in any
-- colorscheme (and stay user-overridable via `default = true`).
local function highlights()
  local links = {
    ObelusRangeText = "DiffText", -- precise char span
    ObelusSign = "DiffText", -- gutter marker
  }
  for group, target in pairs(links) do
    vim.api.nvim_set_hl(0, group, { link = target, default = true })
  end
  require("obelus.thread").setup_highlights()
  pcall(function() -- harmonize markview's bg groups with obelus's tint (no-op if absent)
    require("obelus.thread").markview_harmonize()
  end)
end

local function autocmds()
  local grp = vim.api.nvim_create_augroup("obelus", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = grp, callback = highlights })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
    group = grp,
    callback = function(a)
      render.render_buffer(a.buf)
      render.render_bands(a.buf)
      -- entering a buffer doesn't imply a CursorMoved: opening a file with the
      -- cursor landing straight on a commented line (jumps, session restore)
      -- must show its band/hover without a wiggle
      if a.buf == vim.api.nvim_get_current_buf() then
        pcall(render.on_cursor)
      end
    end,
  })
  -- on cursor move AND on (re)entering a window, refresh the band/hover preview for
  -- the comment under the cursor (WinEnter makes the popup re-appear when you return)
  vim.api.nvim_create_autocmd({ "CursorMoved", "WinEnter" }, {
    group = grp,
    callback = function()
      render.on_cursor()
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = grp,
    callback = function(a)
      render.sync_positions(a.buf)
      render.render_bands(a.buf)
      if config.options.persist.auto then
        store.save()
      end
    end,
  })
  vim.api.nvim_create_autocmd("DirChanged", {
    group = grp,
    callback = function()
      if store.maybe_reload() then
        render.render_all()
      end
    end,
  })
end

-- which-key's own builtin icon rule (lua/which-key/icons.lua) assigns any entry
-- whose desc matches the pattern "toggle" the nf-fa toggle-switch glyph (U+F204,
-- "toggle_off") in "yellow" — with no notion of live state (it's the same glyph
-- whether the thing is actually on or off). obelus used to override that with a
-- plain filled/empty circle pair so ON/OFF stayed visible; the ask here is to keep
-- the default which-key *aesthetic* for both states: ON reuses that exact glyph +
-- color so it reads identically to an unregistered default "toggle" entry, and OFF
-- swaps in the matching outline glyph from the same nf-md toggle-switch family
-- (which-key itself has no OFF-specific glyph to defer to), in grey.
local function sw(on)
  return on and { icon = "󰔡", color = "yellow" } or { icon = "󰨙", color = "grey" }
end

local function whichkey(k)
  local ok, wk = pcall(require, "which-key")
  if not ok then
    return
  end
  k = k or config.options.keys
  if not k then -- keys = false: no mappings at all, so nothing for which-key to own
    return
  end
  local p = k.prefix or "<leader>o"
  local disabled = disabled_suffixes(k)

  -- which-key has no native toggle-state; it calls function desc/icon live though.
  -- Registering WITH the rhs makes which-key own these so it uses our state icon.
  local specs = { { p, group = "obelus" } }
  local function add(suffix, rhs, desc, icon)
    if disabled[suffix] then
      return
    end
    local lhs = suffix_lhs(k, suffix, p)
    if not lhs then -- keys.overrides[suffix] == false
      return
    end
    -- an override that moved OUTSIDE keys.prefix is still a real mapping (keymaps()
    -- set it), but it no longer belongs to this which-key <prefix> GROUP — drop it
    -- from `specs` rather than registering a stray entry under the wrong group.
    if lhs:sub(1, #p) ~= p then
      return
    end
    specs[#specs + 1] = { lhs, rhs, desc = desc, icon = icon }
  end

  add(
    "b",
    function()
      render.toggle_band()
    end,
    "toggle inline bands",
    function()
      return sw(render.bands_on())
    end
  )

  add("B", function()
    render.toggle_band_style()
  end, function()
    return "style: " .. render.band_style()
  end, function()
    return sw(render.band_style() == "popup")
  end)

  add(
    "T",
    function()
      M.toggle("global")
    end,
    "toggle annotations (global)",
    function()
      return sw(render.enabled)
    end
  )

  add(
    "t",
    function()
      M.toggle()
    end,
    "toggle annotations (buffer)",
    function()
      return sw(render.annotations_on())
    end
  )

  add(
    "h",
    function()
      render.toggle_resolved()
    end,
    "show/hide resolved",
    function()
      return sw(render.resolved_shown())
    end
  )

  add("m", function()
    M.toggle_mode()
  end, function()
    return "mode: " .. config.mode()
  end, function()
    return sw(config.mode() ~= "sidebar")
  end)

  add(
    "?",
    function()
      M.toggle_hints()
    end,
    "toggle keybind hints",
    function()
      return sw(render.hints_shown())
    end
  )

  add("G", function()
    M.tag_mode()
  end, function()
    return store.active_tag and ("tagging #" .. store.active_tag) or "toggle sticky tagging mode"
  end, function()
    return sw(store.active_tag ~= nil)
  end)

  add(
    "R",
    function()
      M.toggle_resolve()
    end,
    "toggle resolved at cursor",
    function()
      local cok, c = pcall(render.at_cursor)
      return sw(cok and c ~= nil and c.status == "resolved")
    end
  )

  pcall(wk.add, specs)
end

local did_setup = false

---Configure obelus. Idempotent: registers commands/keymaps/autocmds on the first
---call only; every call (re)builds config.options and repaints.
---@param opts? table
function M.setup(opts)
  config.setup(opts)
  if (config.options.transport.batch or {}).object then
    vim.notify_once(
      "obelus: transport.batch.object is not implemented yet (reserved for the batch meta-thread)",
      vim.log.levels.WARN
    )
  end
  if config.options.persist.auto then
    store.load()
  end
  if not did_setup then
    highlights()
    commands()
    keymaps()
    autocmds()
    whichkey()
    pcall(function()
      require("obelus.actions").sweep() -- delete stale per-job actions files from crashed runs
    end)
    did_setup = true
  end
  render.render_all()
  -- the plugin loads AFTER the session's first cursor placement (VeryLazy) — no
  -- CursorMoved/WinEnter will fire until the user moves, so a cursor already
  -- sitting on a commented line would show no band/hover until wiggled off+on.
  -- One deferred evaluation covers the startup position.
  vim.schedule(function()
    pcall(render.on_cursor)
  end)
  return M
end

-- Test seams (config_spec/init spec): keymaps()/whichkey() only ever run ONCE for
-- real, on the first M.setup() call (the `did_setup` latch above) — a later
-- setup() with a different keys.overrides/keys.chat wouldn't otherwise be
-- observable. Exposed so a spec can re-run the registration logic directly against
-- a throwaway `k` table, same idea as panel.lua's `_fit_width`.
M._keymaps = keymaps
M._whichkey = whichkey
M._MAPSPEC = MAPSPEC

return M
