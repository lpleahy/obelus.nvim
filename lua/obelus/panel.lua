local store = require("obelus.store")
local format = require("obelus.format")
local nav_util = require("obelus.nav")

-- Use markview to render the conversation *content* as Markdown? render.renderer
-- can force on/off; default auto = on iff markview is installed. When on, obelus
-- still draws the structure (bars/dividers/headers) but leaves the turn bodies raw
-- so markview renders them (tables, syntax-highlighted code, links, …).
-- Which markdown renderer drives the chat bodies: "markview" | "builtin" | "treesitter".
-- Resolves the `render.renderer` setting (with a markview-if-installed auto-default),
-- and downgrades "markview" to "builtin" when the plugin isn't available so a bad
-- config never leaves the chat unrendered.
local function render_mode()
  local config = require("obelus.config")
  local cfg = config.options.render or {}
  local has_mv = pcall(require, "markview.actions")

  -- config.ui.renderer (the :ObelusRenderer session override) resolves FIRST.
  -- nil = never toggled → fall through to options below. "auto" is an EXPLICIT
  -- auto (still overrides options.render.renderer, unlike nil).
  local ui = config.ui.renderer
  if ui == "auto" then
    return has_mv and "markview" or "builtin"
  elseif ui == "builtin" or ui == "treesitter" then
    return ui
  elseif ui == "markview" then
    return has_mv and "markview" or "builtin"
  end

  local m = cfg.renderer
  if m == "builtin" or m == "treesitter" then
    return m
  elseif m == "markview" then
    return has_mv and "markview" or "builtin"
  end
  -- nil == auto: markview if installed, else builtin
  return has_mv and "markview" or "builtin"
end

-- markview is the active renderer? (kept as a helper — most call sites only care about this)
local function markview_on()
  return render_mode() == "markview"
end

-- raise markview's max_buf_lines once (default 1000 only renders a cursor window,
-- which truncates long threads); a deep-extend keeps the user's other markview opts
local markview_configured = false
local function ensure_markview_config()
  if markview_configured then
    return
  end
  markview_configured = true
  pcall(function()
    require("markview").setup({ preview = { max_buf_lines = 100000 } })
  end)
end

-- markview render `_config` (tmp_setup) for obelus's OWN chat/preview renders: a copy of the
-- LIVE markview config (so the user's code-block/heading styling + our raised max_buf_lines are
-- all preserved) with ONE override — table virt_lines OFF. markview draws table borders as
-- virt_lines (virtual rows, not real buffer lines); line_hl_group only tints real lines, so
-- those border rows punch a hole in the per-turn bubble bg. With virt_lines off the borders
-- sit on real lines that DO get the tint. Scoped to obelus's renders via tmp_setup — the user's
-- other markdown buffers keep their boxed/virt-line tables untouched.
-- Cached on the inputs that change the built table: the IDENTITY of markview's live
-- spec.config (a table reference — markview's own setup() replaces it wholesale, so
-- comparing by reference is exactly "did the user's markview config change"), the
-- Normal-bg value, and the transparent flag. A vim.deepcopy() of markview's whole spec
-- is not cheap and this ran on every render pass (10Hz while streaming); rebuild (a
-- fresh deepcopy) only when one of those three differs, else return the SAME cached
-- table. Safe to return the same table across calls: markview's render() treats
-- `_config` as READ-ONLY input (it's threaded through spec.tmp_setup, which restores
-- the real config after each render — it never mutates the table it's given).
local mv_render_cfg_cache = {}
local function mv_render_cfg()
  local ok, spec = pcall(require, "markview.spec")
  local spec_cfg = (ok and type(spec.config) == "table") and spec.config or nil
  local normal_bg = (vim.api.nvim_get_hl(0, { name = "Normal", link = false }) or {}).bg
  local is_transparent = (require("obelus.config").options.render or {}).transparent == true
  local c = mv_render_cfg_cache
  if c.built and c.spec_cfg == spec_cfg and c.normal_bg == normal_bg and c.transparent == is_transparent then
    return c.built
  end
  local base = {}
  if spec_cfg then
    local ok2, copy = pcall(vim.deepcopy, spec_cfg)
    if ok2 and type(copy) == "table" then
      base = copy
    end
  end
  base.markdown = base.markdown or {}
  base.markdown.tables = base.markdown.tables or {}
  base.markdown.tables.use_virt_lines = false
  -- Transparent theme/mode: the code-block language label ("Lua") is a right-aligned virt_text
  -- that doesn't pick up the line's bubble tint, so with no bg it reads as a see-through hole.
  -- Point its hl at obelus's own Obelus_MarkviewCodeLabel (given the bubble bg in markview_harmonize)
  -- so it blends. Opaque themes keep markview's language-coloured label (label_hl stays nil).
  if normal_bg == nil or is_transparent then
    base.markdown.code_blocks = base.markdown.code_blocks or {}
    base.markdown.code_blocks.label_hl = "Obelus_MarkviewCodeLabel"
  end
  c.spec_cfg, c.normal_bg, c.transparent, c.built = spec_cfg, normal_bg, is_transparent, base
  return base
end

-- The one scoped, DETACHED markview render — with the window's `wrap` temporarily
-- OFF while it runs. markview hard-degrades table rendering in a wrapped window
-- (its own source says "BUG, wrap breaks table rendering"): no pipe conceal, raw
-- `| --- |` separator, fallback @punctuation hls instead of the table groups. The
-- render call is synchronous, so lying about wrap only for its duration gets the
-- full-quality marks; they display fine in the wrapped window as long as a table
-- row doesn't physically wrap (a wider-than-window table renders imperfectly
-- either way — that's the case markview's guard existed for). Restore is
-- unconditional so an error inside the render can't leave the chat unwrapped.
local function mv_render_scoped(buf, win)
  local ok_mv, mv = pcall(require, "markview.actions")
  if not ok_mv then
    return
  end
  local had_wrap
  if win and vim.api.nvim_win_is_valid(win) then
    had_wrap = vim.wo[win].wrap
    vim.wo[win].wrap = false
  end
  pcall(mv.render, buf, { enable = true, hybrid_mode = false }, mv_render_cfg())
  if had_wrap ~= nil and win and vim.api.nvim_win_is_valid(win) then
    vim.wo[win].wrap = had_wrap
  end
end

local function transparent()
  return (require("obelus.config").options.render or {}).transparent == true
end

-- keybind-hint visibility (off by default; see config.render.hints). Delegates to
-- render.lua's M.hints_shown(), which resolves the config.ui.hints session toggle
-- over options.render.hints — the single switch every hint footer reads.
local function hints()
  return require("obelus.render").hints_shown()
end

-- append markview's per-window highlight remap to a base winhighlight (markview's
-- code/heading/table boxes then use obelus-tinted twins inside this window only).
-- A neutral base (no Normal remap) lets the per-turn tinted bubbles stand out like
-- the inline band; transparent mode keeps the NONE base so the editor shows through.
local function chat_winhl(base)
  base = base or ""
  local parts = {}
  if base ~= "" then
    parts[#parts + 1] = base
  end
  -- 'smoothscroll' draws a NonText "<<<" over the top line whenever the seated-
  -- at-bottom view starts mid-wrapped-line (i.e. almost always once history is
  -- taller than the window). Keep the affordance but in the dim chrome colour —
  -- theme-bright NonText reads as stray text glued to the first message.
  parts[#parts + 1] = "NonText:ObelusChrome"
  if markview_on() then
    parts[#parts + 1] = require("obelus.thread").markview_winhl()
  end
  -- per-window Visual remap: ObelusVisual is the contrast-boosted (or user-set)
  -- selection colour — ALWAYS mapped now; the theme's Visual blends into the
  -- tinted bubbles/code boxes (see thread.setup_highlights' derivation)
  parts[#parts + 1] = "Visual:ObelusVisual"
  return table.concat(parts, ",")
end

-- Rooted float config: hang off the anchored selection (root.sl0..root.el0) in
-- root.win, keeping the WHOLE selection visible by hanging BELOW the last line or
-- ABOVE the first line — whichever side has more viewport room. Shared by the modal
-- popup and the non-modal hover preview. Returns a wcfg for nvim_open_win /
-- nvim_win_set_config.
-- `force_side` ("below"|"above", optional) pins the side regardless of the room
-- comparison — the modal popup's STICKY anchoring (render.popup_anchor): the side
-- is chosen once per thread and held, so a reply growing the box can't teleport
-- it across the selection mid-conversation. Returns wcfg AND the side used.
local function rooted_wincfg(root, base_w, base_h, title, min_h, force_side)
  min_h = min_h or 6
  local info = vim.fn.getwininfo(root.win)[1] or {}
  local wh = info.height or vim.api.nvim_win_get_height(root.win)
  local topline0 = (info.topline or 1) - 1 -- first visible buffer line (0-based)
  local sl0 = root.sl0 or root.line0 or 0
  local el0 = root.el0 or root.line0 or sl0
  local above = sl0 - topline0 -- viewport rows above the FIRST selected line
  local below = wh - (el0 - topline0) - 1 -- viewport rows below the LAST selected line
  local width = math.min(base_w, math.max(40, vim.api.nvim_win_get_width(root.win) - 4))
  local wcfg = {
    relative = "win",
    win = root.win,
    width = width,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "left",
  }
  local side = force_side
  if side ~= "below" and side ~= "above" then
    side = (below >= above) and "below" or "above"
  end
  -- leave a 2-row gap to the window edge so the float (and its docked input) never
  -- sit flush against the very bottom/top — easier to read and to tell apart
  if side == "below" then -- hang under the LAST selected line
    wcfg.bufpos = { el0, 0 }
    wcfg.anchor, wcfg.row, wcfg.col = "NW", 1, 0
    wcfg.height = math.max(min_h, math.min(base_h, below - 3))
  else -- rise from one row clear of the FIRST selected line
    wcfg.bufpos = { sl0, 0 }
    wcfg.anchor, wcfg.row, wcfg.col = "SW", -1, 0
    wcfg.height = math.max(min_h, math.min(base_h, above - 3))
  end
  return wcfg, side
end

-- The review sidebar. Two modes in one right-hand split:
--   list  — every thread across files, status + previewable; <CR> opens a thread
--   chat  — one thread as real, selectable, band-styled text + a reply input pane
-- Styling matches the inline bands (ObelusThread*/ObelusReply* groups).
local M = {}

-- shared geometry/title/winopts helpers -------------------------------------------
-- Dedup across the modal popup (fit_rooted/M.open), the hover preview (M.preview/
-- size_preview), and fit_rooted's own coalesce — verified seams where the three
-- surfaces compute the exact same numbers. Zero behavior change: each caller passes
-- the same inputs it always did.

local FALLBACK_WIDTH = 74 -- window width fallback when no live win is available yet

-- Rooted-float width. render.popup_width, when set, is the ONE base for BOTH the
-- modal chat popup and the hover preview (they otherwise use different auto
-- fractions, so hovering then replying reads as a width jump):
--   >= 1  — fixed column count
--   0..1  — fraction of the editor width
--   nil   — auto (the original per-surface behavior): clamp(columns*frac, 100, 120)
--           with frac 0.8 for the chat popup, 0.7 for the hover preview.
-- Content can still GROW the chat popup past the base (fit_width) so a wide
-- table/line isn't clipped — the knob sets where the box STARTS, not a hard cap.
local function popup_width(frac)
  return math.max(100, math.min(120, math.floor(vim.o.columns * (frac or 0.8))))
end

-- Pure width-fit arithmetic (a spec seam — M._fit_width below): grow `base` up to
-- `content_w` (never shrink below it), capped at `cap` so a very wide line still
-- can't blow the float past the editor.
local function fit_width(base, content_w, cap)
  return math.min(math.max(base, content_w), cap)
end
M._fit_width = fit_width -- test seam (geometry_spec/thread_spec unit-test the pure arithmetic)

-- Two-way content sizing (fit_rooted + preview_base_width, when render.preview_matches_chat):
-- a SOURCE-derived preferred width (thread.pref_width — see its comment for why source,
-- not the rendered buffer). Grows a short exchange down to a snug floor instead of every
-- popup defaulting to the 100-120 comfort base, while code/tables can still push wider.
--   G       — gutter+padding: the bar (2, statuscolumn) + breathing room (2).
--   pref    — hard content (fences/tables) floors the width even past the comfort base;
--             soft content (prose) is capped AT the comfort base (popup_width()) — it
--             wraps fine, so it never NEEDS more room, however long a line runs.
--   base_w  — pref, floored at MIN_W (a one-line reply still gets a readable box) and
--             capped at the editor (never wider than the screen).
local MIN_W = 50
local function base_width_for(comment)
  local G = 4
  local cap = math.max(40, vim.o.columns - 4) -- never wider than the editor
  local hard_w, soft_w = require("obelus.thread").pref_width(comment)
  local pref = math.max(hard_w + G, math.min(soft_w + G, popup_width()))
  return math.max(MIN_W, math.min(pref, cap))
end

-- Shared rooted-float title: file + range label, or the generic fallback when
-- there's no live comment (centred fallback / a stale or deleted thread id). The
-- project (meta) thread has no file/range worth showing (its "file" is the
-- project root) — a fixed title instead.
local function float_title(c)
  if c and c.meta then
    return " ◆ project thread "
  end
  return c and (" ◆ " .. format.relpath(c.file) .. "  " .. format.range_label(c) .. " ") or " ◆ obelus review "
end

-- The zb seat sequence shared by fill's jump block, clamp_overscroll's re-seat, and
-- the hover preview's seat (fill_preview + size_preview): pin the buffer's last line
-- to the window's bottom in one wrap-aware step (why zb, not winrestview+set_cursor:
-- see fill's original comment — the pair overshot then corrected, which jittered the
-- view while streaming). Must run via nvim_win_call: `normal! zb` operates on the
-- CURRENT window. The divergent details across call sites are deliberate — passed as
-- opts, NOT normalized here:
--   opts.redraw      — force a synchronous redraw before zb (fill only: markview
--                       computes its conceal/virt_lines SCREEN geometry on the NEXT
--                       redraw, so a bare zb after a hard+markview+non-streaming pass
--                       would seat against stale, too-short geometry)
--   opts.content_row — after zb, additionally park the cursor on this row (fill/
--                      clamp_overscroll: the last OUTPUT line, above the reserved
--                      input rows — so re-seating doesn't strand the cursor inside
--                      the input box's footprint). The preview's seat is bare
--                      (no redraw, no content_row) — it's unfocused, so there's no
--                      cursor to park usefully, and its geometry is already final.
local function seat_bottom(win, buf, opts)
  opts = opts or {}
  local last = vim.api.nvim_buf_line_count(buf)
  -- the markview-geometry redraw runs BEFORE entering win_call: a redraw inside
  -- paints one frame with the terminal cursor temporarily parked in the chat
  -- window (win_call switches current window) — the orange "ghost cursor"
  -- glimmer users see mid-stream. Out here it paints with the REAL cursor, and
  -- it still computes markview's conceal geometry for the seat (redraw is
  -- global — it repaints the chat window regardless of which window is current).
  if opts.redraw then
    pcall(vim.cmd, "redraw")
  end
  pcall(vim.api.nvim_win_call, win, function()
    vim.wo.scrolloff = 0 -- so zb seats the last line at the very bottom (under the box)
    pcall(vim.api.nvim_win_set_cursor, win, { last, 0 })
    vim.cmd("normal! zb")
    if opts.content_row then
      pcall(vim.api.nvim_win_set_cursor, win, { opts.content_row, 0 })
    end
  end)
end

-- Consolidated imperative vim.wo option sets shared by the chat window (fill(), both
-- list AND chat mode) and the hover preview (fill_preview(), which is always
-- "chat"-shaped: read-only history, no list branch). `mode` is state.mode
-- ("list"|"chat"); the preview call site always passes "chat" and streaming=false —
-- the preview's conceal was never gated on stream state (unlike the chat modal, it
-- doesn't detach markview while streaming; see fill_preview's unconditional
-- mv.render), so passing streaming=false there reproduces its original behaviour
-- exactly: conceallevel tracks markview_on() alone.
-- `wrap_override` (chat call site only — declared below `state`, so it's passed in
-- rather than read here) pins wrap regardless of `mode`: the session wrap toggle
-- (keys.chat.wrap, see M.toggle_wrap). nil (the preview's call, always) keeps the
-- plain mode=="chat" default — the preview is unfocusable, so it never has a toggle
-- to honor.
local function apply_winopts(win, buf, mode, streaming, wrap_override)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  local rmode = render_mode()
  vim.wo[win].signcolumn = "no" -- the bar lives in the statuscolumn now
  local want_wrap = mode == "chat"
  if wrap_override ~= nil then
    want_wrap = wrap_override
  end
  vim.wo[win].wrap = want_wrap
  -- the statuscolumn draws the accent bar on EVERY screen line (incl. wraps), a fixed
  -- 2-cell gutter — so wrapped body lines align past the bar without showbreak tricks
  vim.wo[win].statuscolumn = mode == "chat" and ("%!v:lua.require'obelus.panel'.statuscol(" .. buf .. ")") or ""
  vim.wo[win].breakindent = false
  vim.wo[win].showbreak = ""
  vim.wo[win].cursorline = mode == "list" -- no cursorline bleed through bubbles
  -- conceal is markview-only; treesitter/builtin show raw/styled real text (no
  -- conceal). markview is detached while streaming (body is plain in-house), so no
  -- conceal then either.
  vim.wo[win].conceallevel = (mode == "chat" and rmode == "markview" and not streaming) and 2 or 0
  vim.wo[win].concealcursor = "nvic"
  -- a split inherits the user's gutter; clear number/fold so the bar sits flush (the
  -- statuscolumn set above owns the left gutter now)
  vim.wo[win].numberwidth = 1
  pcall(function()
    vim.wo[win].foldcolumn = "0"
  end)
end

-- Wall-clock knobs (ms), read at call time — specs shrink these instead of sleeping
-- past them. fill_throttle caps soft (streaming-tick) chat rebuilds; preview_settle is
-- the one-shot re-fit delay after markview's async render (see fill_preview).
M._timing = { fill_throttle = 160, preview_settle = 180 }

local ns = vim.api.nvim_create_namespace("obelus_panel")
local ns_conn = vim.api.nvim_create_namespace("obelus_panel_conn") -- rooted-popup connector
local ns_pconn = vim.api.nvim_create_namespace("obelus_preview_conn") -- hover-preview connector
local ICON = { open = "○", needs_response = "⚑", resolved = "✓" }
-- fg-only (no background box) so the list reads as clean text, not tinted blocks
local ICON_HL = { open = "ObelusThreadBarN", needs_response = "ObelusInputBorder", resolved = "ObelusReplyBarN" }
local ORDER = { needs_response = 1, open = 2, resolved = 3 }

local state = {
  _anchor_sides = {}, -- thread id -> "below"|"above" (sticky side, shared by preview + modal)
  win = nil,
  buf = nil,
  mode = "list", -- "list" | "chat"
  thread = nil, -- comment id in chat mode
  line_map = {}, -- list mode: buffer line -> comment id
  expanded = {}, -- list mode: comment id -> previewing turns
  scroll_once = false, -- one-shot: next fill jumps to the bottom, then never forces
  follow = true, -- sticky auto-scroll: armed on send, cleared when the user scrolls up
  input_win = nil, -- persistent reply input float docked at the chat's bottom
  input_buf = nil,
  -- "popup" band style: a non-modal, non-focusable hover preview of the thread,
  -- separate from the modal chat above so the two never clobber each other
  preview_win = nil,
  preview_buf = nil,
  preview_thread = nil,
  preview_root = nil,
  -- session wrap toggle (keys.chat.wrap, default "W") for the CHAT window only —
  -- nil = no override (apply_winopts' usual mode=="chat" default); true/false pins
  -- wrap regardless of mode/streaming until cleared (M.close / a new open_thread).
  wrap_override = nil,
}

-- Three DIFFERENT "are we following the bottom" predicates live in this file — by
-- design, not oversight (unifying them on botline regresses cursor-parked-in-
-- history-stops-autoscroll, verified in the A/B pass):
--   (a) reply_following()          — botline-based: "is the reply area in the
--                                     VIEWPORT" (drives the input box dim/hide, and
--                                     the merged WinScrolled handler in M.open)
--   (b) the CursorMoved autocmd's cursor-row check (in M.open) — "did the USER move
--                                     the CURSOR above the reply area" (stops
--                                     auto-follow on manual nav; a botline check here
--                                     would also fire on cursor moves that don't
--                                     change the viewport, e.g. scrolling elsewhere)
--   (c) M.scroll's botline re-arm  — botline-based too, but only runs after an
--                                     EXPLICIT M.scroll call (the band's <M-u>/
--                                     <M-d>), so follow re-arms the instant a manual
--                                     scroll reaches the bottom again
local function status_of(c)
  return c.status or "open"
end

-- list mode ----------------------------------------------------------------

-- Every real (non-meta) thread — the project thread is pinned separately (its own
-- row, above every per-file section) and never belongs to a file grouping or the
-- open/needs/resolved counts (see build_list below).
local function real_comments()
  return vim.tbl_filter(function(c)
    return not c.meta
  end, store.all())
end

local function build_list()
  local lines, map, decos = {}, {}, {}
  local function push(text, id, deco)
    lines[#lines + 1] = text
    if id then
      map[#lines] = id
    end
    if deco then
      decos[#lines] = deco
    end
  end

  local all = real_comments()
  local counts = { open = 0, needs_response = 0, resolved = 0 }
  for _, c in ipairs(all) do
    counts[status_of(c)] = (counts[status_of(c)] or 0) + 1
  end
  -- the winbar already says "◆ obelus review"; here just the counts + keys, dim
  local hdr =
    string.format("  %d open  ·  %d needs  ·  %d resolved", counts.open, counts.needs_response, counts.resolved)
  if store.active_tag then
    hdr = hdr .. "  ·  tagging #" .. store.active_tag
  end
  push(hdr, nil, { segs = { { 0, #hdr, "ObelusChrome" } } })
  if hints() then
    local keys = "  <CR> open · gd jump · D send · x resolve · dd delete · q close"
    push(keys, nil, { segs = { { 0, #keys, "ObelusChrome" } } })
  end
  push("")

  -- the project thread: pinned FIRST, above every per-file section — but only
  -- when it EXISTS (get_meta, no create): auto-creating on every list render
  -- planted duplicate meta records across concurrent nvim instances just for
  -- opening the sidebar. <prefix>a / :ObelusProject creates it deliberately.
  -- <CR> on the row opens the chat like any other thread (see `nav` below,
  -- which special-cases it: no source line to jump to).
  do
    local meta = store.get_meta()
    if meta then
      local text = "  ◆  project thread"
      push(text, meta.id, { segs = { { 0, #text, "ObelusChrome" } } })
      push("")
    end
  end

  -- only this project's files (a comment whose file lives outside the project root —
  -- e.g. a scratch /tmp file — shouldn't clutter the list)
  local root = store.root()
  local function in_project(f)
    return type(f) == "string" and (f == root or f:sub(1, #root + 1) == root .. "/")
  end
  local show_res = require("obelus.render").resolved_shown()
  local by_file, order = {}, {}
  for _, c in ipairs(all) do
    if (show_res or status_of(c) ~= "resolved") and in_project(c.file) then
      if not by_file[c.file] then
        by_file[c.file] = {}
        order[#order + 1] = c.file
      end
      table.insert(by_file[c.file], c)
    end
  end

  for _, file in ipairs(order) do
    local list = by_file[file]
    table.sort(list, function(a, b)
      local sa, sb = ORDER[status_of(a)] or 2, ORDER[status_of(b)] or 2
      if sa ~= sb then
        return sa < sb
      end
      return a.range.sl < b.range.sl
    end)
    -- file section header
    local fh = " " .. format.relpath(file)
    push(fh, nil, { segs = { { 0, #fh, "ObelusThreadHeaderN" } } })
    for _, c in ipairs(list) do
      local s = status_of(c)
      local icon = ICON[s] or "○"
      local rl = format.range_label(c)
      local first = vim.split(c.comment or "", "\n")[1] or ""
      local pre = "   "
      local badge = (c.tag and c.tag ~= "") and ("  #" .. c.tag) or ""
      local rlf = string.format("%-10s", rl) -- padded label; highlight its full width, not just #rl
      local text = pre .. icon .. "  " .. rlf .. " " .. first .. badge
      local i1 = #pre + #icon
      local r0 = i1 + 2
      local segs = { { #pre, i1, ICON_HL[s] }, { r0, r0 + #rlf, "ObelusChrome" } }
      if badge ~= "" then
        segs[#segs + 1] = { #text - #badge, #text, "ObelusBorder" } -- fg-only brand: no box
      end
      push(text, c.id, { segs = segs })
      if state.expanded[c.id] then
        for _, t in ipairs(store.turns(c)) do
          local tag = t.author == "agent" and "↩ agent" or "· you"
          for j, l in ipairs(vim.split(t.text or "", "\n")) do
            local line = string.format("        %s %s", j == 1 and tag or string.rep(" ", #tag), l)
            push(
              line,
              c.id,
              { segs = { { 8, 8 + #tag, t.author == "agent" and "ObelusReplyBarN" or "ObelusThreadBarN" } } }
            )
          end
        end
      end
    end
    push("")
  end
  return lines, map, decos
end

-- chat mode ----------------------------------------------------------------

-- The reply box auto-grows with what you type: a comfortable few rows to start, up to
-- a cap (past which the box stays put and you scroll inside it in normal mode).
local MIN_INPUT_ROWS = 3
local MAX_INPUT_ROWS = 10
local function input_rows()
  local n = MIN_INPUT_ROWS
  if state.input_buf and vim.api.nvim_buf_is_valid(state.input_buf) then
    n = vim.api.nvim_buf_line_count(state.input_buf)
  end
  return math.max(MIN_INPUT_ROWS, math.min(n, MAX_INPUT_ROWS))
end
-- screen rows the bordered box occupies (content + rounded border top/bottom) = the
-- count of blank reply rows reserved under it in the chat buffer
local function box_rows()
  return input_rows() + 2
end

-- thread.build returns STRUCTURED rows (kind/agent/bar_hl/bg_hl, chunks with a
-- per-chunk `role`). This turns them into real (selectable) buffer text + decos:
-- a rule row never touches the text — it carries forward as `pending_rule`, landing
-- as deco.rule on the NEXT content row (dropped if trailing — same as the read-only
-- band's cap_rows behaviour). Pure (no panel state); exported for specs — the
-- divider-classification bugs used to live in exactly this split, back when it had
-- to sniff hl-group NAME substrings to tell a divider from content.
-- opts.external: an external renderer (markview/treesitter) colours the body, so
-- keep only "header"/"meta" role chunks and drop "body"/"code"/"tag" (the #tag
-- badge stays dropped in markview mode, exactly as before).
-- Returns a list of { text = <buffer line>, deco = <decorate() entry> } in order.
function M._rows_to_chat(rows, opts)
  local mv = (opts or {}).external == true
  local out = {}
  local pending_rule = nil
  for _, row in ipairs(rows) do
    if row.kind == "rule" then
      pending_rule = { char = row.char, reply = row.agent }
    else -- a content row: real text from its chunks (no bar/pad chunk to skip)
      local text, segs = "", {}
      for _, ch in ipairs(row.chunks) do
        local s = #text
        text = text .. (ch[1] or "")
        -- Both modes draw the SAME chrome — tinted bubble bg, bright bar, you/agent
        -- header + range meta — so the sidebar/popup look like the inline band.
        -- markview mode only drops the BODY/code/tag segs so markview colours the body.
        if not mv or ch.role == "header" or ch.role == "meta" then
          segs[#segs + 1] = { s, #text, ch[2] }
        end
      end
      text = text:gsub("%s+$", "")
      out[#out + 1] = {
        text = text,
        deco = {
          bg = row.agent and "ObelusReplyBg" or "ObelusThreadBg", -- per-turn tinted bubble (both modes)
          bar = row.bar_hl, -- bright bar with the bubble bg (both modes)
          segs = segs,
          rule = pending_rule,
        },
      }
      pending_rule = nil
    end
  end
  return out
end

local function build_chat(id, opts)
  opts = opts or {}
  id = id or state.thread
  local c = store.get(id)
  if not c then
    if id == state.thread then
      state.mode = "list"
      return build_list()
    end
    return {}, {}, {}
  end
  local is_float = opts.is_float
  if is_float == nil then
    is_float = state.is_float
  end
  local read_only = opts.read_only == true -- the hover preview: no keybind/reply rows
  local lines, map, decos = {}, {}, {}
  local function push(text, deco)
    lines[#lines + 1] = text
    map[#lines] = c.id
    if deco then
      decos[#lines] = deco
    end
  end

  -- the float shows file+range in its border title; only the split needs the header line
  if not is_float then
    if c.meta then
      push(string.format(" ◆ project thread  [%s]", status_of(c)))
    else
      push(string.format(" ◆ %s  %s  [%s]", format.relpath(c.file), format.range_label(c), status_of(c)))
    end
  end
  if not read_only and hints() then
    local back = is_float and "q close" or "<BS> back"
    local resolve = status_of(c) == "resolved" and "o reopen" or "x resolve"
    push(" " .. back .. " · r reply · " .. resolve .. " · <CR> jump")
    push("")
  end

  -- Render the conversation through the SAME builder as the inline band, as real
  -- selectable text, so the sidebar and the inline view look identical.
  local width = opts.width
    or (state.win and vim.api.nvim_win_is_valid(state.win) and vim.api.nvim_win_get_width(state.win))
    or FALLBACK_WIDTH
  -- markview mode: leave bodies as raw Markdown (markdown=false) so markview renders
  -- them; obelus still bakes in the bar + dividers. Otherwise use the in-house styling.
  -- WHILE STREAMING, though, markview is detached (its per-delta auto-render is what made
  -- code/tables flash + mis-place table borders below the box) — so render the in-house
  -- styled markdown instead, which is stable-height and gets the bubble bg. On finish we
  -- swap to raw + re-attach markview (see fill()'s markview lifecycle block).
  -- via jobs.busy, NOT the raw flag: a stream that died without finalizing leaves
  -- dispatching==true forever, which kept these bodies on the in-house renderer
  -- (and the spinner alive) until the next send. busy() self-heals that flag.
  local streaming = require("obelus.jobs").busy(c.id) or (id == state.thread and state.streaming == true)
  -- `ext` = an EXTERNAL renderer (markview or treesitter) colours the body, so leave it raw
  -- Markdown and drop obelus's own body segments. markview mode falls back to the in-house
  -- styling WHILE streaming (markview is detached then); treesitter is stable so it stays raw
  -- throughout; builtin always uses the in-house styling.
  local mode = render_mode()
  local ext = (mode == "treesitter") or (mode == "markview" and not streaming)
  local rows = require("obelus.thread").build(c, width - 1, {
    markdown = not ext,
    rules = true,
    -- the commented code snippet is useful in the SIDEBAR (the file isn't visible there),
    -- but a rooted popup / hover preview is drawn right over those same lines in the file,
    -- so showing them again reads as redundant "ghost" text — skip it for floats.
    with_code = not is_float,
    -- the modal chat has the reply box open, so its trailing draft is being edited THERE —
    -- hide it from the history to avoid duplication. The read-only hover preview keeps it.
    hide_draft = not read_only,
    -- thread.build is a pure formatter now: it takes liveness/spinner from the caller
    -- instead of requiring jobs/progress itself.
    live = require("obelus.jobs").live(c),
    spinner = require("obelus.progress").frame(),
  })
  for _, e in ipairs(M._rows_to_chat(rows, { external = ext })) do
    push(e.text, e.deco)
  end

  -- the reply area: a full-width divider + a gap row that stay VISIBLE above the
  -- docked input box (which floats over the last 5 blank rows) — so the input is
  -- clearly separated from the history and you can read the last output above it.
  if not read_only then
    -- the box footprint: box_rows() blank spacer lines the input box floats over. The divider
    -- above them is a VIRT_LINE on the first blank (via the `rule` deco, same as inter-turn
    -- dividers) — NOT a real "┄┄┄" line. A real line of box-drawing dashes gets parsed by
    -- markview as Markdown (a list-item lazy continuation, etc.) and indented/concealed, which
    -- visibly disrupts the divider whenever the last turn ends in a list/block.
    for k = 1, box_rows() do
      push("", k == 1 and { rule = { char = "┄", reply = false } } or {})
    end
  end
  return lines, map, decos
end

-- rendering ----------------------------------------------------------------

-- buf -> { [line1based] = bar_hl }. Drives the statuscolumn bar so each bubble gets a
-- CONTINUOUS left accent bar on every screen line — including soft-wrapped markview
-- paragraphs, which an inline-virt_text bar could only mark on their first line.
local bar_maps = {}

-- 'statuscolumn' callback: draw the turn's accent bar for v:lnum on every screen line
-- (v:virtnum>0 = wrapped continuation → still bar it; v:virtnum<0 = an extmark virtual
-- line, e.g. a divider, which draws its own bar → skip). A fixed 2-cell gutter keeps
-- the text column aligned whether or not the line has a bar.
-- `buf` is embedded in the statuscolumn string per window (see fill/fill_preview) so
-- the lookup never depends on which buffer is FOCUSED — the bars must stay drawn while
-- the input float has focus and the chat window merely redraws underneath it.
function M.statuscol(buf)
  local map = bar_maps[buf]
  if not map or (vim.v.virtnum or 0) < 0 then
    return "  "
  end
  local hl = map[vim.v.lnum]
  if not hl then
    return "  "
  end
  local bar = (require("obelus.config").options.render or {}).bar or "▎"
  return "%#" .. hl .. "#" .. bar .. " %*"
end

local function decorate(decos, buf, win)
  buf = buf or state.buf
  win = win or state.win
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  bar_maps[buf] = {} -- rebuilt below; the statuscolumn reads it for the left bar
  local width = (win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win)) or FALLBACK_WIDTH
  local barw = vim.fn.strdisplaywidth(((require("obelus.config").options.render or {}).bar or "▎") .. " ")
  for line, d in pairs(decos) do
    -- divider above this line: a virt line of dashes only — NO bar tick here. virt
    -- lines render in the text area (right of the statuscolumn), so a bar here would
    -- sit 2 cells right of the real per-line statuscolumn bar and read as a stray
    -- misaligned line. The dashes start at the text column, aligned with the bubbles.
    if d.rule then
      local rh = d.rule.reply and "ObelusReplyRuleN" or "ObelusThreadRuleN"
      local dashes = string.rep(d.rule.char, math.max(width - barw - 2, 1))
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, line - 1, 0, {
        virt_lines = { { { dashes, rh } } },
        virt_lines_above = true,
      })
    end
    -- bubble background: line_hl fills wrapped rows + to the window edge
    if d.bg then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, line - 1, 0, { line_hl_group = d.bg })
    end
    -- the left accent bar is drawn by the statuscolumn (M.statuscol) on EVERY screen
    -- line incl. wrapped continuations; here we just record this line's bar colour
    if d.bar then
      bar_maps[buf][line] = d.bar
    end
    if d.segs then -- per-chunk fg/header/code segments over the real text
      for _, seg in ipairs(d.segs) do
        if seg[3] then
          pcall(vim.api.nvim_buf_set_extmark, buf, ns, line - 1, seg[1], { end_col = seg[2], hl_group = seg[3] })
        end
      end
    elseif d.icon then -- list: status icon
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, line - 1, 2, { end_col = 5, hl_group = d.icon })
    end
  end
end

-- Are we seated at the bottom of the chat (the reply area is in view)? Follow
-- predicate (a) — see the three-predicates comment above state{}.
local function reply_following()
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    return true
  end
  local ok, wi = pcall(function()
    return vim.fn.getwininfo(state.win)[1]
  end)
  if not ok or not wi then
    return true
  end
  return (wi.botline or 0) >= vim.api.nvim_buf_line_count(state.buf)
end

local function reply_dock()
  return (require("obelus.config").options.render or {}).reply_dock or "pinned"
end

-- The docked reply box's window config (style is open-only, so it's added at open).
-- Factored so the box can be repositioned after the float re-fits / the view scrolls.
local function input_wincfg()
  local pw = vim.api.nvim_win_get_width(state.win)
  local wh = vim.api.nvim_win_get_height(state.win)
  local br = box_rows()
  local total = math.max(vim.api.nvim_buf_line_count(state.buf), br + 1)
  local dock = reply_dock()
  local following = reply_following()
  -- Where the box docks:
  --  · POPUP (float, pinned): the window bottom (wh - br). fit_rooted sizes the float to the
  --    content + reserved rows, so those rows sit at the bottom — deterministic, no screenpos,
  --    so it can't slide while the wrapped height settles (the reveal poll holds it hidden
  --    until then anyway).
  --  · SIDEBAR (split, pinned): the split is a FIXED size, so short content sits at the top and
  --    the reserved rows fall right AFTER it (not at the window bottom). Use their REAL screen
  --    row (clamped to the bottom) so the divider stays directly above the box, no gap.
  --  · SERIAL: track the reserved rows' real screen row so the box rides down with the output.
  local srow = math.max(0, wh - br)
  local want_screenpos = dock == "serial" or not state.is_float
  if want_screenpos then
    pcall(function()
      local sp = vim.fn.screenpos(state.win, total - br + 1, 1) -- 1-based first reply-box row
      local wi = vim.fn.getwininfo(state.win)[1]
      if sp and (sp.row or 0) > 0 and wi then
        -- screenpos is the absolute screen row; a relative=win float's ROW is measured from
        -- the window's TEXT area (below the winbar), so subtract winrow AND the winbar.
        local s = sp.row - wi.winrow - (wi.winbar or 0)
        -- serial rides past the bottom; pinned (sidebar) clamps so it never drops below it
        srow = (dock == "serial") and math.max(0, s) or math.max(0, math.min(s, wh - br))
      end
    end)
  end
  local barglyph = (require("obelus.config").options.render or {}).bar or "▎"
  -- SEATED (following): the accent bar IS the box's left edge — it reads as docked to the
  -- conversation. FLOATING (pinned + scrolled up): drop the bar and close the box into a
  -- thin rounded outline, so it reads as a self-contained bubble floating over the history
  -- you're scrolling. (serial dock hides instead, handled by reposition_input.)
  local floating = dock == "pinned" and not following
  local left, tl, bl
  if floating then
    left, tl, bl = { "│", "ObelusInputBorder" }, { "╭", "ObelusInputBorder" }, { "╰", "ObelusInputBorder" }
  else
    left = { barglyph, "ObelusInputBar" }
    tl, bl = left, left -- the bar runs the full height of the left edge (corners included)
  end
  local cfg = {
    relative = "win",
    win = state.win,
    anchor = "NW",
    row = srow,
    col = 0, -- a relative=win bordered float renders its LEFT BORDER *at* this win-col
    -- (not one cell left), so col 0 puts the bar flush under the statuscolumn turn bars
    -- (verified by reading real screen cells). Do NOT derive from textoff/gutter width.
    width = math.max(pw - 2, 16), -- as wide as a bordered box can be (the 1-col inset is its right border)
    height = input_rows(),
    -- The brand bar IS the box's left border (not a separate statuscolumn bar over the
    -- chat buffer) — so the bar and the box are one float and can NEVER drift apart.
    -- Thin rounded border on the other three sides marks it out as the input.
    border = {
      tl, -- topleft
      { "─", "ObelusInputBorder" }, -- top
      { "╮", "ObelusInputBorder" }, -- topright
      { "│", "ObelusInputBorder" }, -- right
      { "╯", "ObelusInputBorder" }, -- botright
      { "─", "ObelusInputBorder" }, -- bot
      bl, -- botleft
      left, -- left
    },
    title = { { " reply ", "ObelusInputHeader" } },
    title_pos = "left",
    zindex = 60, -- above the chat float so it never renders behind it
  }
  if hints() then -- footer + footer_pos must be set together (or neither)
    cfg.footer = { { " ⏎ send · <C-s> save · <Tab> history · q close ", "ObelusThreadMeta" } }
    cfg.footer_pos = "right"
  end
  return cfg
end

local function reposition_input()
  if not (state.input_win and vim.api.nvim_win_is_valid(state.input_win)) then
    return
  end
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    return
  end
  local cfg = input_wincfg()
  -- serial dock: the box scrolls off with the output, so hide it once the reply area
  -- leaves the view (nvim 0.10+ `hide`); pinned dock always stays shown. Also stay hidden
  -- while a fresh box awaits its post-settle reveal (open_input → open_thread).
  local hide = (reply_dock() == "serial" and not reply_following()) or state.input_pending_reveal == true
  -- coalesce: a redundant set_config repaints the box AND emits a spurious WinScrolled (which
  -- re-enters this path) → the jitter. Only touch the box when its geometry/appearance changed.
  local barglyph = ((cfg.border and cfg.border[1]) or {})[1] or ""
  local barhl = ((cfg.border and cfg.border[1]) or {})[2] or ""
  local sig = table.concat({ cfg.row, cfg.col, cfg.width, cfg.height, barglyph, barhl, hide and 1 or 0 }, ":")
  if sig == state._inputsig then
    return
  end
  state._inputsig = sig
  pcall(vim.api.nvim_win_set_config, state.input_win, cfg)
  pcall(vim.api.nvim_win_set_config, state.input_win, { hide = hide })
end

-- Re-fit the rooted modal float to its LIVE content, capped by the room on its
-- chosen side (rooted_wincfg) so it never covers the anchored selection, and by the
-- size caps. Called after every fill (open, stream, resize) so a reused or streamed
-- popup is always content-sized — fixing the float growing on cancel+resend, where
-- the old one-shot shrink ran only on first open and the reuse path never re-fit.
-- `force` is the pass kind (hard OR _forcefill — see fill()'s `force` local): a
-- hard/forced pass may SHRINK the float; a soft (streaming-tick) pass only grows.
-- Must be the FULL `force`, not bare `hard` — the stream-finish pass sets
-- state._forcefill (not scroll_once/hard) so the plain->markview swap always paints
-- even when the user scrolled up; if this only shrank on `hard`, stream-finish would
-- stop shrinking the float (that exact regression is called out in the refactor plan).
local function fit_rooted(force)
  -- SIDEBAR is deliberately excluded: it's a split with winfixwidth=true (see M.open),
  -- so resizing it to fit content would shove the code window it sits beside around
  -- on every fill — only the FLOAT (rooted or centred) grows to fit content below.
  if not (state.is_float and state.win and vim.api.nvim_win_is_valid(state.win)) then
    return
  end
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    return
  end
  local c = store.get(state.thread)
  local title = float_title(c)
  -- Two-way content sizing (base_width_for -> thread.pref_width): measured at the
  -- SOURCE (the comment's stored turn text), not the rendered buffer — see
  -- base_width_for's comment for the recipe and thread.pref_width's for why source,
  -- not rendered lines. O(turns' lines) — but this only runs once per EXECUTED fill
  -- (fit_rooted is called from fill() AFTER its own coalesce/throttle gate has already
  -- let the pass through — see fill()'s `force`/`sig` checks above), not per keystroke.
  local base_w = base_width_for(c)
  if state.maximized then
    -- keys.chat.maximize: near-full-editor overlay; the coalesce below still
    -- guards reconfig churn, and toggling back re-fits (toggle cleared _rootfit)
    local W = math.max(40, vim.o.columns - 4)
    local H = math.max(6, vim.o.lines - vim.o.cmdheight - 6)
    local wcfg_max = {
      relative = "editor",
      row = 1,
      col = math.max(0, math.floor((vim.o.columns - W) / 2)),
      width = W,
      height = H,
      style = "minimal",
      border = "rounded",
      title = title,
      title_pos = "center",
    }
    local last = state._rootfit
    if not last or last.relative ~= "editor" or last.width ~= wcfg_max.width or last.height ~= wcfg_max.height then
      state._rootfit = wcfg_max
      pcall(vim.api.nvim_win_set_config, state.win, wcfg_max)
    end
    return
  end
  -- fit the CONTENT. The window wraps (wrap=true), so its real height is the WRAPPED
  -- screen-row count, not the buffer line count — buffer lines undersize a popup whose
  -- long agent lines wrap (cutting content off). Take the larger of the two; the rooted
  -- cap / the centred cap below clamps it so a huge reply still caps-then-scrolls.
  local base_h = vim.api.nvim_buf_line_count(state.buf)
  local okth, th = pcall(vim.api.nvim_win_text_height, state.win, {})
  if okth and th and th.all then
    base_h = math.max(base_h, th.all)
  end
  local wcfg
  if state.root and vim.api.nvim_win_is_valid(state.root.win) then
    -- STICKY side (default): decided the FIRST time this thread is placed — by
    -- the hover preview (when render.preview_matches_chat) or the modal, whichever
    -- came first — then held for the session (per-thread map), so hover -> reply ->
    -- reopen never flips the box across the selection. render.popup_anchor = "auto"
    -- restores the every-pass room-comparison (may flip to the roomier side).
    local sticky = (require("obelus.config").options.render or {}).preview_matches_chat == true
    local side
    wcfg, side =
      rooted_wincfg(state.root, base_w, base_h, title, nil, sticky and state._anchor_sides[state.thread] or nil)
    if sticky and state.thread then
      state._anchor_sides[state.thread] = side
    end
  else
    -- no rooted anchor (centred fallback — e.g. opened off the source buffer, or a
    -- symlinked project path): still content-size and GROW with streaming, capped to
    -- ~80% of the editor (then scroll). Never a fixed tall block with a gap above input.
    local width = math.min(base_w, math.max(40, vim.o.columns - 4))
    local cap = math.max(6, math.floor(vim.o.lines * 0.8))
    local height = math.max(6, math.min(base_h, cap))
    wcfg = {
      relative = "editor",
      row = math.max(0, math.floor((vim.o.lines - height) / 2)),
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      width = width,
      height = height,
      title = title,
      title_pos = "center",
    }
  end
  -- coalesce + de-jitter: nvim_win_text_height is the WRAPPED row count, which wobbles by a
  -- row or two as markview conceals / the stream re-wraps. Only re-config when position/anchor
  -- changed, the height/width GROWS, or a hard pass wants the exact final fit; a soft
  -- (streaming) pass never shrinks EITHER dimension. Width must NOT count as "moved":
  -- a width-growth pass (a long line streaming in) would then bypass the height clamp,
  -- and the earlier paragraphs re-wrapping into fewer rows at the new width shows up
  -- as a visible mid-stream height SHRINK — the exact jitter this block exists to kill.
  local last = state._rootfit
  local moved = not last
    or last.relative ~= wcfg.relative
    or last.win ~= wcfg.win
    or last.anchor ~= wcfg.anchor
    or last.row ~= wcfg.row
    or last.col ~= wcfg.col
    or (last.bufpos and last.bufpos[1]) ~= (wcfg.bufpos and wcfg.bufpos[1])
  if last and not (moved or force) then
    wcfg.height = math.max(wcfg.height, last.height) -- soft: never shrink (kills the wobble)
    wcfg.width = math.max(wcfg.width, last.width)
  end
  local grew = not last or wcfg.height > last.height or wcfg.width > last.width
  if moved or grew or (force and (wcfg.height ~= last.height or wcfg.width ~= last.width)) then
    state._rootfit = wcfg
    pcall(vim.api.nvim_win_set_config, state.win, wcfg)
  end
  -- (the input box is repositioned in fill, AFTER the scroll, for popup AND sidebar)
end

-- Bring the active markdown decorator into line with the config mode for state.buf, computed
-- fresh each pass (no transition-diffing) so a live switch or a stream edge can't leave a stale
-- decorator running. At most one paints the bodies:
--   markview   — DETACHED, rendered manually with the scoped config. markview must NOT be
--                attached: its own auto-render fires on cursor/scroll (e.g. G) using the user's
--                GLOBAL config, which re-adds table virt_lines (undoing use_virt_lines=false) and
--                reflows/clears decorations. Detached, our scoped render STICKS. A markdown ts
--                highlighter runs alongside for code-block syntax injections.
--   treesitter — plain treesitter markdown highlighting on the raw body (real lines, no conceal).
--   builtin    — obelus's own in-house styling; neither decorator.
-- While streaming, ALL modes show the plain in-house markdown (stable, no flash), so markview and
-- the ts highlighter are both off until the stream settles.
local function reconcile_renderer(mode, streaming, force)
  local mvok, mv = pcall(require, "markview.actions")
  -- markview stays detached no matter what (it's only ever attached transiently at buffer create)
  if mvok and state._mv_attached then
    pcall(mv.detach, state.buf)
    state._mv_attached = false
  end
  local want_mv = mode == "markview" and mvok and not streaming
  local want_ts = mode == "treesitter" or want_mv -- markview needs ts for code-block injections
  if mvok then
    if want_mv then
      require("obelus.thread").markview_harmonize() -- fresh twins from the live palette
      ensure_markview_config()
      mv_render_scoped(state.buf, state.win) -- wrap-bracketed: full table marks
    else
      pcall(mv.clear, state.buf) -- builtin/treesitter/streaming: no markview decorations
    end
  end
  if want_ts then
    if not state._ts_on then
      pcall(vim.treesitter.start, state.buf, "markdown")
      state._ts_on = true
    end
    -- full synchronous parse incl. injections, every executed pass: nvim 0.12's
    -- ASYNC injection parsing only progresses with redraw activity, so an idle
    -- chat sat with grey code fences until the user typed (each keystroke's
    -- redraws inched the parse along). Incremental — cheap when nothing changed.
    pcall(function()
      vim.treesitter.get_parser(state.buf, "markdown"):parse(true)
    end)
  elseif state._ts_on then
    pcall(vim.treesitter.stop, state.buf)
    state._ts_on = false
  end
end

local function fill()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    return
  end
  -- scroll: a one-shot jump on open, PLUS sticky follow — armed on send, it keeps the
  -- bottom (your message + the streaming reply) in view; the user stops it by scrolling
  -- up (the CursorMoved handler clears state.follow), and the next send re-arms it.
  local hard = state.scroll_once == true -- open/send/finish: do the precise (redraw) seat
  -- `force` bypasses the coalesce/throttle AND lets fit_rooted shrink, WITHOUT seating the
  -- view to the bottom (which `jump` does). The stream-finish pass sets it so the plain→
  -- markview swap always paints — even when the user scrolled up (not following) so we must
  -- NOT scroll them back down.
  local force = hard or state._forcefill == true
  state._forcefill = false
  local jump = hard or (state.mode == "chat" and state.follow == true)
  state.scroll_once = false
  -- streaming = a reply is in flight for the shown thread (c.dispatching), OR one was just
  -- sent and dispatch hasn't set the flag yet (state.streaming, set in on_send). While it's
  -- true we keep markview OFF and render obelus's in-house markdown (stable height, no flash).
  local streaming = false
  if state.mode == "chat" and state.thread then
    local sc = require("obelus.store").get(state.thread)
    -- jobs.busy, not the raw dispatching flag — see build_chat's note (self-heals
    -- a stale flag so markview isn't stuck off for this thread all session)
    streaming = (sc ~= nil and require("obelus.jobs").busy(sc.id)) or state.streaming == true
  end
  local mode = render_mode()
  -- throttle the heavy rebuild during streaming: the 100ms progress timer would otherwise
  -- rebuild + re-render markview ~10x/sec, saturating the main loop so SCROLL INPUT is
  -- starved (you couldn't scroll up while a reply streamed). Cap soft rebuilds at ~6/sec by
  -- bailing BEFORE build_chat/build_list pay for the rebuild; a hard seat (open/send/finish)
  -- always passes, and the next tick renders the latest, so the final text still lands.
  -- state._lastfill/_fillsig are left stale on a throttled tick so the pending change is
  -- picked up next time (only set below once a pass actually proceeds).
  local now = (vim.uv or vim.loop).now()
  if not force and state._lastfill and (now - state._lastfill) < M._timing.fill_throttle then
    return
  end
  local lines, map, decos
  if state.mode == "chat" then
    lines, map, decos = build_chat()
  else
    lines, map, decos = build_list()
  end
  -- coalesce: skip the markview reconcile/decorate/seat pass below when nothing VISIBLE
  -- changed since the last fill (a 100ms progress tick with no new delta) — build_chat/
  -- build_list above still ran (the signature needs the built lines), but this skips the
  -- expensive part: decorate + reconcile_renderer + the scroll/seat. A hard seat or width
  -- change forces a pass.
  local sig = state.mode
    .. "|"
    .. mode -- a live renderer switch (same raw lines) must still force the reconcile below
    .. "|"
    .. ((state.win and vim.api.nvim_win_is_valid(state.win) and vim.api.nvim_win_get_width(state.win)) or 0)
    .. "|"
    .. #lines
    .. "|"
    .. table.concat(lines, "\n")
  if not force and sig == state._fillsig then
    return
  end
  state._lastfill = now
  state._fillsig = sig
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  state.line_map = map
  decorate(decos)
  if state.mode == "chat" then
    reconcile_renderer(mode, streaming, force)
  end
  -- winopts AFTER the renderer reconcile: markview's detach (fired once, on the
  -- first chat pass) restores the window options it saved at attach time —
  -- clobbering conceallevel back to 0, and later coalesced fills would never
  -- re-assert it, leaving markview's conceal marks (table pipes, fences) showing
  -- as raw text. Setting the options last makes every executed pass authoritative.
  apply_winopts(state.win, state.buf, state.mode, streaming, state.wrap_override)
  fit_rooted(force) -- re-fit the rooted float (+ reposition the reply box) BEFORE scrolling
  if jump and state.win and vim.api.nvim_win_is_valid(state.win) then
    -- pin the LAST line to the window bottom in ONE wrap-aware step (zb) — the old
    -- winrestview+set_cursor pair overshot then corrected, which is what made the view
    -- jitter up/down while streaming. zb also re-pins when the cursor is already at the
    -- end (so a reused/list-scrolled window isn't left stranded). markview-off pre-wraps,
    -- so geometry's already final — skip the redraw then.
    seat_bottom(state.win, state.buf, {
      redraw = hard and state.mode == "chat" and markview_on() and not streaming,
      -- rest the cursor on the last OUTPUT line (just above the divider), not inside the
      -- reserved input rows — so re-seating lands you at the end of the chat, and you don't
      -- have to scroll the cursor back up out of the input box to read the latest reply.
      content_row = state.mode == "chat" and math.max(#lines - box_rows(), 1) or nil,
    })
  end
  -- keep the chat flush-left — a stray horizontal scroll shows "<<<" precedes-listchars
  -- at the start of a line (seen in the popup); wrap is on, so leftcol should be 0
  if state.mode == "chat" and state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_call, state.win, function()
      local v = vim.fn.winsaveview()
      if (v.leftcol or 0) ~= 0 then
        v.leftcol = 0
        vim.fn.winrestview(v)
      end
    end)
  end
  -- reposition the input box AFTER the scroll settles (its screen row tracks the reply
  -- line) — for both the popup and the sidebar, which fit_rooted skips
  reposition_input()
end

function M.refresh()
  fill()
end

-- Structured, READ-ONLY introspection of the live chat + reply-box geometry — the
-- numbers the seating/over-scroll behaviours are defined by. Specs assert on this
-- instead of reverse-engineering windows.
-- :ObelusRenderInfo — every input to the "which renderer painted this?" decision,
-- for the chat AND the hover preview, so a live "why is this body in-house styled?"
-- has answers without guesswork. Returns a table (also vim.print-ed by the command).
function M.render_info()
  local config = require("obelus.config")
  local jobs = require("obelus.jobs")
  local function mvmarks(buf)
    local n = 0
    if buf and vim.api.nvim_buf_is_valid(buf) then
      for name, nsid in pairs(vim.api.nvim_get_namespaces()) do
        if name:find("markview", 1, true) then
          n = n + #vim.api.nvim_buf_get_extmarks(buf, nsid, 0, -1, {})
        end
      end
    end
    return n
  end
  -- treesitter facts for the first fenced code line in `buf`: is the highlighter
  -- attached, did the injected-language parse actually complete (captures exist),
  -- and what would the screen paint there (the winhl-effective hl of the top
  -- capture)? Distinguishes "parse never finished" from "parsed but painted grey".
  local function ts_facts(buf)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
      return nil
    end
    local out = { highlighter_active = vim.treesitter.highlighter.active[buf] ~= nil }
    local ok_p, parser = pcall(vim.treesitter.get_parser, buf, "markdown")
    out.parser = ok_p and parser ~= nil
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local in_fence = false
    for i, l in ipairs(lines) do
      if l:match("^%s*```%w") then
        in_fence = true
      elseif in_fence and l:match("%S") then
        out.fence_line = i - 1
        local caps = {}
        local ok_c, cs = pcall(vim.treesitter.get_captures_at_pos, buf, i - 1, math.max(#(l:match("^%s*") or ""), 1))
        if ok_c then
          for _, cap in ipairs(cs) do
            caps[#caps + 1] = cap.capture .. "(" .. cap.lang .. ")"
          end
        end
        out.fence_captures = caps
        break
      end
    end
    return out
  end
  local function surface(label, thread_id, win, buf)
    local c = thread_id and require("obelus.store").get(thread_id)
    return {
      surface = label,
      thread = thread_id,
      dispatching_flag = c and c.dispatching or false,
      jobs_busy = (c and jobs.busy(c.id)) or false,
      state_streaming = state.streaming or false,
      markview_marks = mvmarks(buf),
      conceallevel = (win and vim.api.nvim_win_is_valid(win)) and vim.wo[win].conceallevel or nil,
      winhl = (win and vim.api.nvim_win_is_valid(win)) and vim.wo[win].winhighlight:sub(1, 120) or nil,
      ts = ts_facts(buf),
    }
  end
  return {
    nvim = tostring(vim.version()),
    render_mode = render_mode(),
    markview_loaded = (pcall(require, "markview.actions")),
    ui_renderer_override = config.ui.renderer,
    options_renderer = (config.options.render or {}).renderer,
    chat = state.thread and surface("chat", state.thread, state.win, state.buf) or nil,
    preview = state.preview_thread and surface("preview", state.preview_thread, state.preview_win, state.preview_buf)
      or nil,
  }
end

-- nil when no panel window is open. `gap` = box_top - expect_top: 0 means the reply
-- box sits exactly on the reserved rows (seated); nil when it can't be measured.
function M.geom()
  local function num(x)
    if type(x) == "table" then
      return x[false] or x[1] or x[true] -- nvim<0.10 win_get_config row/col compat
    end
    return x
  end
  local chat = state.win
  if not (chat and vim.api.nvim_win_is_valid(chat)) then
    return nil
  end
  local g = {
    mode = state.mode,
    thread = state.thread,
    win = chat,
    buf = state.buf,
    is_float = state.is_float == true,
    follow = state.follow == true,
    streaming = state.streaming == true,
    input_pending_reveal = state.input_pending_reveal == true,
    chat_height = vim.api.nvim_win_get_height(chat),
    chat_row = tonumber(num(vim.api.nvim_win_get_config(chat).row)),
    box_rows = box_rows(),
    preview_win = (state.preview_win and vim.api.nvim_win_is_valid(state.preview_win)) and state.preview_win or nil,
    preview_buf = state.preview_buf,
    preview_thread = state.preview_thread,
  }
  local cbuf = state.buf
  if cbuf and vim.api.nvim_buf_is_valid(cbuf) then
    local total = vim.api.nvim_buf_line_count(cbuf)
    g.line_count = total
    local trailing = 0
    for i = total, 1, -1 do
      if (vim.api.nvim_buf_get_lines(cbuf, i - 1, i, false)[1] or "") == "" then
        trailing = trailing + 1
      else
        break
      end
    end
    g.trailing_blank = trailing
    local okth, th = pcall(vim.api.nvim_win_text_height, chat, {})
    g.text_height = (okth and th and th.all) or nil
    -- where the first reserved reply row actually renders (window-relative, 0-based)
    pcall(function()
      local sp = vim.fn.screenpos(chat, total - trailing + 1, 1)
      local wi = vim.fn.getwininfo(chat)[1]
      if sp and (sp.row or 0) > 0 and wi then
        g.expect_top = sp.row - wi.winrow - (wi.winbar or 0)
      end
      if wi then
        g.topline, g.botline, g.winrow = wi.topline, wi.botline, wi.winrow
      end
    end)
  end
  local input = state.input_win
  if input and vim.api.nvim_win_is_valid(input) then
    local icfg = vim.api.nvim_win_get_config(input)
    g.input_win = input
    g.input_row = tonumber(num(icfg.row))
    g.input_height = vim.api.nvim_win_get_height(input)
    g.input_hidden = icfg.hide == true
    if g.input_row then
      -- The two docks measure differently (verified empirically by the geometry
      -- specs): the POPUP box is anchored at the raw window bottom (wh - box_rows),
      -- one row above where the first reserved line renders, so its row + 1 is what
      -- lines up with expect_top when seated; the SIDEBAR box is anchored via the
      -- same screenpos expect_top reads, so its row lines up directly. Normalize so
      -- gap == 0 means "seated" in BOTH modes.
      g.box_top = g.input_row + (state.is_float and 1 or 0)
      if g.expect_top then
        g.gap = g.box_top - g.expect_top
      end
    end
  end
  return g
end

-- Sending a reply re-arms the auto-scroll for this thread's chat (if open), so the
-- bottom (your message + the streaming reply) is brought into view no matter where
-- the user had scrolled — until they scroll up again.
function M.on_send(id)
  if M.showing(id) then
    -- mark streaming NOW, before store.stream_start sets c.dispatching (dispatch is async):
    -- this fill then sizes the popup to the PLAIN content (markview detaches) instead of the
    -- markview-inflated height, which is what left the transient gap above the reply box.
    state.streaming = true
    state.follow = true
    state.scroll_once = true
    fill()
  end
end

-- Called once when a stream FINISHES (from progress.finish). The per-tick fill no longer
-- forces a markview redraw, so the bottom can be a row short while streaming with markview on;
-- this does the single precise redraw-seat at the end — but only if the user is still following
-- (scrolled up to read history = leave their view alone).
function M.seat_finish(id)
  -- Clear the bridge flag unconditionally (even if the chat isn't the focused mode right now)
  -- so it can't go stale; c.dispatching stays authoritative for any still-live stream.
  state.streaming = false -- stream done: build_chat swaps to raw md, fill re-attaches markview
  if (id == nil or M.showing(id)) and state.mode == "chat" then
    -- seat to the bottom only if the user is still following; but ALWAYS force the fill so the
    -- plain→markview swap paints even when they scrolled up (don't yank their view down).
    if state.follow == true then
      state.scroll_once = true
    end
    state._forcefill = true
    fill()
  end
  -- The hover preview needs the same trailing-edge guarantee: its per-tick repaints
  -- are throttled/coalesced, the finish-path refresh calls are unforced, and the
  -- progress timer has just stopped — so a delta→finish inside one throttle window
  -- would leave the finalized text (and the plain→markview swap) permanently
  -- unpainted until the next cursor move. Force the one repaint here.
  if
    state.preview_win
    and vim.api.nvim_win_is_valid(state.preview_win)
    and (id == nil or state.preview_thread == id)
  then
    M.refresh_preview(true)
  end
end

-- Force the chat back to its seated bottom (latest output flush above the reply box). A
-- reliable recovery from an over-scroll — re-arms follow and does fill's precise zb seat — so
-- you never have to close+reopen to fix the view. Bound to zz/G in the chat window.
function M.reseat()
  if state.mode == "chat" and state.win and vim.api.nvim_win_is_valid(state.win) then
    state.follow = true
    state.scroll_once = true
    fill()
  end
end

-- Wrap toggle for the CHAT window (keys.chat.wrap, default "W"; section B — nvim
-- can't h-scroll a WRAPPED window). Flips vim.wo[win].wrap immediately and pins the
-- choice in state.wrap_override so apply_winopts' next pass (every fill(), incl. a
-- streaming tick) doesn't stomp it back to the mode=="chat" default. The override is
-- session-scoped: cleared on M.close() and on the next open_thread() (a fresh
-- thread starts from the plain default, not a stale wrap state from the last one).
-- With wrap off, native zl/zh/$/0 pan horizontally (nvim has no other way to scroll a
-- wrapped window sideways).
-- Full-screen toggle for the chat FLOAT (keys.chat.maximize, default "Z"): blow
-- the popup up to (nearly) the whole editor for reading, toggle back to the
-- fitted rooted/centred geometry. Sidebar mode: no-op with a note (it's a split;
-- resize it with normal window commands).
function M.toggle_maximize()
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    return
  end
  if not state.is_float then
    return vim.notify("obelus: maximize is for the popup — the sidebar is a normal split", vim.log.levels.INFO)
  end
  state.maximized = not state.maximized or nil
  state._rootfit, state._fillsig = nil, nil -- force the next fill to re-fit + re-seat
  M.refresh()
  pcall(vim.cmd, "redraw")
end

function M.toggle_wrap()
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    return
  end
  local want = not vim.wo[state.win].wrap
  state.wrap_override = want
  vim.wo[state.win].wrap = want
  vim.notify(want and "obelus: wrap on" or "obelus: wrap off — zl/zh to pan")
end

-- Scroll the focused popup/sidebar chat (the docked input counts as focused too).
-- Returns true if it handled the scroll, so the inline band scroll can fall through.
-- Scrolling up stops the auto-scroll follow; reaching the bottom re-arms it.
function M.scroll(dir, lines)
  local keystr = lines and ((dir < 0 and "<C-y>" or "<C-e>"):rep(lines)) or (dir < 0 and "<C-u>" or "<C-d>")
  -- no modal chat: scroll the non-focusable hover preview if it's showing (M-u/M-d on
  -- the source line should scroll the popup preview, like the inline band)
  if not (state.win and vim.api.nvim_win_is_valid(state.win) and state.mode == "chat") then
    if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) and state.preview_thread then
      pcall(vim.api.nvim_win_call, state.preview_win, function()
        vim.cmd("normal! " .. vim.api.nvim_replace_termcodes(keystr, true, false, true))
      end)
      return true
    end
    return false
  end
  local cw = vim.api.nvim_get_current_win()
  if cw ~= state.win and cw ~= state.input_win then
    return false -- the chat isn't focused; let the inline band handle M-u/M-d
  end
  -- scroll the VIEW (not just the cursor — moving the cursor within the visible area
  -- doesn't move the viewport). Run the scroll in the chat window's own context so it
  -- works even when the docked input has focus.
  local last = vim.api.nvim_buf_line_count(state.buf)
  local botline = last
  pcall(vim.api.nvim_win_call, state.win, function()
    vim.cmd("normal! " .. vim.api.nvim_replace_termcodes(keystr, true, false, true))
    botline = vim.fn.line("w$")
  end)
  -- follow predicate (c) — see the three-predicates comment above state{}
  state.follow = botline >= last - 1 -- scrolling up stops follow; reaching the bottom re-arms
  reposition_input() -- the box is anchored to the reply rows; keep it on them as we scroll
  return true
end

-- Prevent OVER-SCROLLING the chat past its end. Plain <C-d>/mouse-wheel (Vim builtin, NOT
-- M.scroll) can push the last line up off the window bottom, leaving the reserved reply rows
-- floating over a void — the box stays pinned at the bottom, so a big gap opens (confirmed by
-- measuring the live geometry — see M.geom(): last output at row 10, box at row 23, GAP=13). On
-- ANY scroll of the chat window, if we're scrolled down and the last line sits above the bottom
-- with empty rows beneath it, pin it back to the bottom (fill's zb seat). Guarded so the
-- re-seat's own scroll can't recurse.
local _overscroll_guard = false
local function clamp_overscroll()
  if _overscroll_guard then
    return
  end
  if not (state.win and vim.api.nvim_win_is_valid(state.win) and state.mode == "chat") then
    return
  end
  local win, buf = state.win, state.buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local info = vim.fn.getwininfo(win)[1]
  if not info then
    return
  end
  if (info.topline or 1) <= 1 then
    return -- showing from the top → not scrolled down, nothing to over-scroll
  end
  local last = vim.api.nvim_buf_line_count(buf)
  if (info.botline or 0) < last then
    return -- last line not visible → a genuine mid-history scroll, leave it
  end
  local sp = vim.fn.screenpos(win, last, 1)
  if not (sp and (sp.row or 0) > 0) then
    return
  end
  local win_bottom = (info.winrow or 0) + (info.height or 0) - 1
  if sp.row >= win_bottom - 1 then
    return -- already seated (allow a 1-row markview wobble)
  end
  _overscroll_guard = true
  seat_bottom(win, buf, { content_row = math.max(last - box_rows(), 1) })
  _overscroll_guard = false
  state.follow = true
  reposition_input()
end

-- Is the sidebar currently showing this thread's chat? (so its spinner lives here)
function M.showing(id)
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win) and state.mode == "chat" and state.thread == id
end

-- reply input: a persistent float docked at the chat's bottom edge ------------

local function input_submit(action)
  if not (state.input_buf and vim.api.nvim_buf_is_valid(state.input_buf)) then
    return
  end
  local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false), "\n"))
  if text == "" then
    return
  end
  if require("obelus").busy(state.thread) then
    return vim.notify("obelus: the agent is still replying — wait for it to finish", vim.log.levels.WARN)
  end
  local id = state.thread
  vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { "" }) -- clear, keep the box open
  state.scroll_once = true
  if action == "save" then
    require("obelus").chat_save(id, text)
  elseif action == "send_fast" then
    require("obelus").chat_send(id, text, "fast")
  else
    require("obelus").chat_send(id, text, "send")
  end
end

-- nvim keeps a per-window cursor, so toggling focus returns you where you left off.
-- `insert` only when summoned ('r' / first open), not when Tab-ing back to it.
function M.focus_input(insert)
  if state.input_win and vim.api.nvim_win_is_valid(state.input_win) then
    vim.api.nvim_set_current_win(state.input_win)
    if insert then
      vim.cmd("startinsert")
    end
  end
end

function M.focus_history()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.cmd, "stopinsert")
    vim.api.nvim_set_current_win(state.win)
    -- if the cursor is parked in the trailing zone, land it on the last line of actual
    -- output (the trailing reply area = divider + box_rows() reserved box rows)
    local total = vim.api.nvim_buf_line_count(state.buf)
    local last_content = math.max(total - box_rows(), 1)
    if (vim.api.nvim_win_get_cursor(state.win)[1] or 1) > last_content then
      pcall(vim.api.nvim_win_set_cursor, state.win, { last_content, 0 })
    end
  end
end

-- Buffer-local chat-surface keybind, driven by keys.chat[name] (config.chat_key —
-- section C): `false` skips the binding entirely (the key is unset in `o`), unset
-- keeps `default` (today's hardcoded key).
local function bind_chat(o, modes, name, default, fn)
  local lhs = require("obelus.config").chat_key(name, default)
  if lhs then
    vim.keymap.set(modes, lhs, fn, o)
  end
end

local function open_input()
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    return
  end
  if state.input_win and vim.api.nvim_win_is_valid(state.input_win) then
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "obelus_reply" -- so cursor-animation plugins can exclude it
  state.input_buf = buf
  require("obelus.mention").attach(buf) -- "@" opens a project file picker (see mention.lua)
  -- load the trailing UNSENT "you" message (a new comment, or a reply you're drafting) into the
  -- box so you edit it in place; it shows in the thread as "· draft" until sent
  local st = require("obelus.store")
  local pend = state.thread and st.pending_you_text(st.get(state.thread))
  if pend and pend ~= "" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(pend, "\n"))
  end
  state.input_win = vim.api.nvim_open_win(buf, false, vim.tbl_extend("force", input_wincfg(), { style = "minimal" }))
  -- open HIDDEN: the chat popup grows to its final height ASYNC (esp. with markview), and
  -- nvim_win_get_height reports the configured height before the window actually renders it,
  -- so a box placed now hangs below the still-short popup then jumps up as it catches up.
  -- open_thread reveals it after the height settles → it appears once, bottom-anchored.
  state.input_pending_reveal = true
  pcall(vim.api.nvim_win_set_config, state.input_win, { hide = true })
  vim.wo[state.input_win].cursorline = false
  vim.wo[state.input_win].wrap = true
  vim.wo[state.input_win].signcolumn = "no" -- the left bar is inline virt_text now
  vim.wo[state.input_win].foldcolumn = "0"
  -- the input float is opened while the chat window is current, so it INHERITS the chat's
  -- conceallevel=2 / concealcursor="nvic" (style="minimal" doesn't reset conceal). The "i"
  -- in concealcursor conceals the caret's line in insert → the insert cursor goes invisible.
  -- The input is plain text, so turn conceal off here.
  vim.wo[state.input_win].conceallevel = 0
  vim.wo[state.input_win].concealcursor = ""
  -- a higher-contrast you-tinted box with a bright accent border, so the input where
  -- you type clearly stands out from the chat history behind/around it
  vim.wo[state.input_win].winhighlight =
    "Normal:ObelusInput,NormalFloat:ObelusInput,FloatBorder:ObelusInputBorder,FloatTitle:ObelusInputHeader,EndOfBuffer:ObelusInput"
  vim.wo[state.input_win].winblend = require("obelus.config").options.render.winblend or 0
  local o = { buffer = buf, nowait = true, silent = true }
  -- Chat-surface keybinds (section C; keys.chat — see bind_chat above), defaults =
  -- today's hardcoded keys:
  --   to_code    <C-h> — jumps STRAIGHT to the code (skip the chat output that sits
  --                      between the input float and the code — the float isn't in
  --                      the wincmd-h direction order)
  --   send       <CR>
  --   send_fast  <M-CR> — send with the configured FAST model
  --   save       <C-s>
  --   cycle      <Tab>   — from insert too, so "type, then Tab" hops to the history
  --                        and leaves the box (and its text) in place instead of
  --                        falling through to a global/cmp <Tab>
  --   cycle_back <S-Tab>
  --   close_esc  <Esc>   — hops to the history (Esc-Esc, from `maps()`'s own <Esc>,
  --                        closes the whole popup)
  --   close      q       — closes the whole panel
  bind_chat(o, { "n", "i" }, "to_code", "<C-h>", function()
    pcall(vim.cmd, "stopinsert")
    if state.is_float then
      if state.root and vim.api.nvim_win_is_valid(state.root.win) then
        pcall(vim.api.nvim_set_current_win, state.root.win) -- popup: the source under it
      end
    elseif state.win and vim.api.nvim_win_is_valid(state.win) then
      pcall(vim.api.nvim_set_current_win, state.win) -- sidebar: hop to the chat, then left
      pcall(vim.cmd, "wincmd h")
    end
  end)
  bind_chat(o, "n", "send", "<CR>", function()
    input_submit("send")
  end)
  bind_chat(o, { "n", "i" }, "send_fast", "<M-CR>", function()
    input_submit("send_fast")
  end)
  bind_chat(o, { "n", "i" }, "save", "<C-s>", function()
    input_submit("save")
  end)
  bind_chat(o, { "n", "i" }, "cycle", "<Tab>", function()
    M.focus_history()
  end)
  bind_chat(o, { "n", "i" }, "cycle_back", "<S-Tab>", function()
    M.focus_history()
  end)
  bind_chat(o, "n", "close_esc", "<Esc>", function()
    M.focus_history()
  end)
  bind_chat(o, "n", "maximize", "Z", function()
    M.toggle_maximize() -- same toggle as the chat window's — reachable while typing
  end)
  bind_chat(o, "n", "close", "q", function()
    M.close()
  end)
  -- scroll the history WITHOUT leaving the input (works in insert too, so you can read
  -- back while composing). M.scroll routes to the focused chat (the input counts).
  local bs = (require("obelus.config").options.keys or {}).band_scroll
  if type(bs) == "table" then
    if bs.up then
      vim.keymap.set({ "n", "i" }, bs.up, function()
        require("obelus.render").scroll(-1)
      end, o)
    end
    if bs.down then
      vim.keymap.set({ "n", "i" }, bs.down, function()
        require("obelus.render").scroll(1)
      end, o)
    end
  end
  -- auto-grow: when the typed line count changes, re-fill so the reserved reply rows
  -- and the box height grow/shrink together (a fresh box is 1 row, not a tall block)
  state.input_rows = input_rows()
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = function()
      if not (state.input_buf and vim.api.nvim_buf_is_valid(state.input_buf)) then
        return
      end
      local n = input_rows()
      if n ~= state.input_rows then
        state.input_rows = n
        fill() -- re-reserves box_rows() blanks; reposition_input resizes + moves the box
      end
    end,
  })
end

local function close_input()
  if state.input_win and vim.api.nvim_win_is_valid(state.input_win) then
    -- persist whatever is in the box as the editable draft (the trailing "you" turn), so closing
    -- never loses it — it reopens in the box and shows as "· draft". Empty clears the draft.
    if state.input_buf and vim.api.nvim_buf_is_valid(state.input_buf) and state.thread then
      local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false), "\n"))
      pcall(require("obelus").chat_save, state.thread, text)
    end
    pcall(vim.api.nvim_win_close, state.input_win, true)
  end
  state.input_win, state.input_buf = nil, nil
end

-- actions ------------------------------------------------------------------

local function cid()
  return state.line_map[vim.api.nvim_win_get_cursor(state.win)[1]]
end

function M.open_thread(id, as_float)
  M.hide_preview() -- the modal chat replaces any non-modal hover preview cleanly
  state.thread = id
  -- root a float popup at the comment's location in the source window (so it hangs
  -- off the rooted line like the inline band, just floating). Falls back to centred.
  state.root = nil
  if as_float then
    local cwin = vim.api.nvim_get_current_win()
    local cbuf = vim.api.nvim_win_get_buf(cwin)
    local c = store.get(id)
    if c and nav_util.abspath(vim.api.nvim_buf_get_name(cbuf)) == c.file then
      state.root = {
        win = cwin,
        buf = cbuf,
        sl0 = c.range.sl - 1, -- first selected line (0-based)
        el0 = (c.range.el or c.range.sl) - 1, -- last selected line (0-based)
      }
      -- scroll the source so the selection sits ~1/4 from the top, giving the popup
      -- room below it (avoids the float running off-screen for a mid/low comment).
      -- Only for the modal popup — the hover preview must not jump the code on move.
      pcall(function()
        local wh = vim.api.nvim_win_get_height(cwin)
        local top = math.max(state.root.sl0 - math.floor(wh * 0.25), 0)
        vim.api.nvim_win_call(cwin, function()
          vim.fn.winrestview({ topline = top + 1, lnum = state.root.el0 + 1, col = 0, leftcol = 0 })
        end)
      end)
    end
  end
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    M.open(as_float)
  end
  state.mode = "chat"
  state.thread = id
  state.scroll_once = true -- one jump to the bottom on open
  state.follow = true -- start following the latest until the user scrolls up
  state._fillsig, state._inputsig, state._rootfit, state._lastfill = nil, nil, nil, nil -- fresh thread
  state.wrap_override = nil -- a fresh thread starts from the plain wrap default, not a stale toggle
  -- (the sticky anchor side is a per-thread MAP now — a re-open reuses the side
  -- this thread was first placed on; a different thread decides its own)
  state.maximized = nil -- the full-screen toggle is per-open, not per-thread
  -- Create the docked reply box BEFORE the chat fill. fill() seats the chat (scroll to
  -- bottom) and then repositions the reply box against that SETTLED layout — but only if the
  -- box already exists. Opening it AFTER render_all left the first open positioned by
  -- open_input's standalone input_wincfg against an unseated layout, so it landed wrong until
  -- a later event re-seated it (a reuse worked because the box already existed → fill placed
  -- it). Opening first routes the first open through the same proven fill→reposition path.
  open_input() -- the fixed reply box docked at the bottom
  -- render_all fills the popup (scrolls once + seats the reply box) AND hides this thread's
  -- inline band in the file now that the popup is showing it. The commented line keeps its
  -- normal gutter sign — no extra rooted band/highlight here.
  pcall(function()
    require("obelus.render").render_all()
  end)
  -- Reveal + focus the box on the next tick (after render_all's first fill applies). With the
  -- deterministic window-bottom anchor the box is correct as soon as it's seated, so no settle
  -- poll/delay is needed — any later markview reflow just grows the popup, and the WinResized→
  -- fill / WinScrolled autocmds re-seat and keep the box on the bottom. Normal mode (press i to
  -- type) so the deferred insert caret is flushed by your first key.
  vim.schedule(function()
    if not (state.input_win and vim.api.nvim_win_is_valid(state.input_win)) then
      return
    end
    state.input_pending_reveal = false
    reposition_input()
    M.focus_input(false)
  end)
end

function M.back()
  close_input() -- the reply box belongs to the chat, not the list
  state.mode = "list"
  state.thread = nil
  vim.api.nvim_set_current_win(state.win)
  fill()
end

-- Jump to the file buffer holding a thread (inline mode: the list is a navigator).
-- The project (meta) thread has no source location — its "file" is the project
-- root, a directory — so there's nothing to `:edit`; no-op with a notice instead.
function M.jump_to(id)
  local c = store.get(id)
  if not c then
    return
  end
  if c.meta then
    return vim.notify("obelus: the project thread has no source location", vim.log.levels.INFO)
  end
  nav_util.goto_source(c, { avoid = state.win })
end

-- The project thread has no source location to root a floating popup at (see
-- open_thread) or jump to — it always opens as a normal thread chat, regardless of
-- the active engagement modality (which only decides "popup vs sidebar" for
-- threads that actually HAVE a file/range to root against).
local function nav(id)
  local c = store.get(id)
  if c and c.meta then
    return M.open_thread(id)
  end
  if require("obelus.config").mode() == "inline" then
    M.jump_to(id)
  else
    M.open_thread(id)
  end
end

function M.jump()
  local c = store.get(state.thread or cid())
  if not c then
    return
  end
  if c.meta then
    return vim.notify("obelus: the project thread has no source location", vim.log.levels.INFO)
  end
  local float = state.is_float
  nav_util.goto_source(c, { avoid = state.win, warn_orphan = true })
  if float then
    M.close() -- popup you've jumped out of: close it (a float is hard to refocus)
  end
end

function M.reply()
  if state.mode == "chat" then
    M.focus_input(false) -- 'r' summons the input in normal mode (press i to type)
  end
end

local function act(fn)
  return function()
    local id = cid()
    if id then
      fn(id)
    end
  end
end

local function maps()
  local o = { buffer = state.buf, nowait = true, silent = true }
  local set = function(lhs, fn)
    vim.keymap.set("n", lhs, fn, o)
  end
  -- <C-l> from the chat output hops into the docked reply box (a float, so it isn't
  -- reachable via wincmd l) — so "code -> <C-l> -> output -> <C-l> -> input" works
  set("<C-l>", function()
    if state.mode == "chat" and state.input_win and vim.api.nvim_win_is_valid(state.input_win) then
      M.focus_input(false)
    end
  end)
  set("<CR>", function()
    if state.mode == "list" then
      local id = cid()
      if id then
        nav(id)
      end
    else
      M.jump()
    end
  end)
  set("gd", function() -- jump to the source line without leaving the panel open/closed state
    local id = state.mode == "chat" and state.thread or cid()
    if id then
      M.jump_to(id)
    end
  end)
  -- re-seat the chat to the bottom (recover from an over-scroll without reopening). In list
  -- mode fall through to the normal zz/G so navigation isn't hijacked.
  set("zz", function()
    if state.mode == "chat" then
      M.reseat()
    else
      pcall(vim.cmd, "normal! zz")
    end
  end)
  set("G", function()
    if state.mode == "chat" then
      M.reseat()
    else
      pcall(vim.cmd, "normal! G")
    end
  end)
  set("C", function() -- cancel the in-flight dispatch
    local id = state.mode == "chat" and state.thread or cid()
    if id then
      require("obelus").cancel(id)
    end
  end)
  set("q", function()
    if state.mode == "chat" and not state.is_float then
      M.back() -- split: back to the list
    else
      M.close() -- float popup (or list): close
    end
  end)
  set("<BS>", function()
    if state.mode == "chat" then
      if state.is_float then
        M.close()
      else
        M.back()
      end
    end
  end)
  -- Esc in the history closes the whole popup (output + docked input together) so it
  -- can't orphan the input box; from the input, Esc hops here first (so Esc-Esc closes)
  set("<Esc>", function()
    if state.is_float then
      M.close()
    elseif state.mode == "chat" then
      M.back()
    end
  end)
  set("<Tab>", function()
    if state.mode == "list" then
      local id = cid()
      if id then
        state.expanded[id] = not state.expanded[id]
        fill()
      end
    elseif state.mode == "chat" then
      M.focus_input(false) -- hop to the reply input, but don't assume insert
    end
  end)
  set("<S-Tab>", function()
    if state.mode == "chat" then
      M.focus_input(false)
    end
  end)
  set("r", function()
    if state.mode == "chat" then
      M.reply()
    else
      local id = cid()
      if id then
        nav(id)
      end
    end
  end)
  set("R", M.refresh)
  set(
    "x",
    act(function(id)
      require("obelus").resolve(id)
    end)
  )
  set(
    "o",
    act(function(id)
      require("obelus").reopen(id)
    end)
  )
  set(
    "D",
    act(function(id)
      require("obelus").dispatch(id)
    end)
  )
  set(
    "dd",
    act(function(id)
      require("obelus").delete(id)
    end)
  )
  -- chat-window wrap toggle (section B; keys.chat.wrap, default "W") — no-op in list
  -- mode (nothing to h-scroll there). `false` disables it, like every other keys.chat
  -- entry.
  local wrap_lhs = require("obelus.config").chat_key("wrap", "W")
  if wrap_lhs then
    set(wrap_lhs, function()
      if state.mode == "chat" then
        M.toggle_wrap()
      end
    end)
  end
  -- full-screen toggle (keys.chat.maximize, default "Z" — shadows ZZ/ZQ inside
  -- the chat only; rebind or disable via keys.chat)
  local max_lhs = require("obelus.config").chat_key("maximize", "Z")
  if max_lhs then
    set(max_lhs, function()
      if state.mode == "chat" then
        M.toggle_maximize()
      end
    end)
  end
end

function M.open(as_float)
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    fill()
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile" -- scratch: never prompt to save
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown" -- set BEFORE attach (and never change it: markview
  state.buf = buf -- auto-detaches nofile buffers on a buftype/filetype OptionSet)
  state._mv_attached = false
  state._ts_on = false
  -- ft=markdown can trigger nvim-treesitter's own FileType highlight; cancel it so exactly one
  -- renderer owns the buffer (reconcile_renderer re-enables treesitter for that mode).
  pcall(vim.treesitter.stop, buf)
  -- attach markview directly (its auto-attach skips nofile buffers; attach() doesn't),
  -- with hybrid OFF for THIS buffer only so the cursor line never reverts to raw md
  if markview_on() then
    ensure_markview_config()
    pcall(function()
      require("markview.actions").attach(buf, { enable = true, hybrid_mode = false })
    end)
    -- reconcile_renderer's own detach-on-first-fill reads this flag, then leaves it false
    -- (markview stays detached for the buffer's whole lifetime after that)
    state._mv_attached = true
  end
  state.streaming = false
  state.mode = "list"
  state.is_float = as_float == true
  if as_float then
    local width = popup_width()
    local height = math.floor(vim.o.lines * 0.8)
    local wcfg = {
      relative = "editor",
      row = math.floor((vim.o.lines - height) / 2),
      col = math.floor((vim.o.columns - width) / 2),
      width = width,
      height = height,
      style = "minimal",
      border = "rounded",
      title = " ◆ obelus review ",
      title_pos = "center",
    }
    -- rooted: hang the popup off the comment's line in the source window, choosing
    -- the side (below/above) with more room — like the inline band, but floating
    local root = state.root
    if root and vim.api.nvim_win_is_valid(root.win) then
      wcfg = rooted_wincfg(root, width, height, float_title(store.get(state.thread)))
    end
    state.win = vim.api.nvim_open_win(buf, true, wcfg)
    -- NEUTRAL base (theme NormalFloat) so the per-turn tinted bubbles stand out like
    -- the inline band; only transparent mode maps Normal→NONE for the editor to show
    local fbase = transparent() and "Normal:ObelusThreadText,NormalFloat:ObelusThreadText," or ""
    vim.wo[state.win].winhighlight = chat_winhl(fbase .. "FloatBorder:ObelusBorder,EndOfBuffer:NormalFloat")
    vim.wo[state.win].winblend = require("obelus.config").options.render.winblend or 0
  else
    vim.cmd("botright vsplit")
    state.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(state.win, buf)
    vim.api.nvim_win_set_width(state.win, math.min(76, math.floor(vim.o.columns * 0.42)))
    vim.wo[state.win].winfixwidth = true
    vim.wo[state.win].winbar = " ◆ obelus review "
    -- neutral split base so the tinted bubbles stand out (markview boxes harmonized)
    vim.wo[state.win].winhighlight = chat_winhl(transparent() and "Normal:ObelusThreadText" or "")
  end
  vim.wo[state.win].number = false
  vim.wo[state.win].relativenumber = false
  fill() -- fill() now re-fits a rooted float to its live content (see fit_rooted)
  maps()
  local grp = vim.api.nvim_create_augroup("obelus_panel", { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = grp,
    pattern = tostring(state.win),
    once = true,
    callback = function()
      close_input() -- the input float is part of the chat's lifecycle (no orphan on :q)
      if state.root and state.root.buf and vim.api.nvim_buf_is_valid(state.root.buf) then
        vim.api.nvim_buf_clear_namespace(state.root.buf, ns_conn, 0, -1) -- drop the connector
      end
      local buf = state.buf -- capture before it's nilled below: bar_maps is keyed by bufnr
      state.win, state.buf, state.is_float, state.root = nil, nil, nil, nil
      if buf then
        bar_maps[buf] = nil -- the buffer is gone (bufhidden=wipe); drop its statuscolumn bar map
      end
    end,
  })
  -- re-wrap on resize (line_hl keeps colors correct regardless, this re-flows text)
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = grp,
    callback = function()
      if state.win and vim.api.nvim_win_is_valid(state.win) then
        fill()
      end
    end,
  })
  -- follow on/off: reading the history (cursor above the latest) stops the auto-scroll;
  -- returning to the bottom re-arms it. The auto-scroll itself lands at the bottom, so
  -- it only ever sets follow=true — only the user moving up turns it off.
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = grp,
    buffer = state.buf,
    callback = function()
      if not (state.win and vim.api.nvim_win_is_valid(state.win) and state.mode == "chat") then
        return
      end
      local cur = vim.api.nvim_win_get_cursor(state.win)[1]
      local last = vim.api.nvim_buf_line_count(state.buf)
      -- follow predicate (b) — see the three-predicates comment above state{}
      state.follow = cur >= last - box_rows() -- the trailing reply area (divider + box rows)
    end,
  })
  -- Merged into ONE pattern-less WinScrolled handler (was two adjacent autocmds on the
  -- same event): clamp_overscroll FIRST, then the follow update + reposition_input —
  -- preserving both the original definition order (clamp_overscroll may re-seat the
  -- view, which the follow read below then observes) and each half's own guard. No
  -- `pattern`: WinScrolled's pattern only matches the FIRST window in the aggregated
  -- event, and the input float/popup resizing is often first, so a chat-window pattern
  -- would miss the real over-scrolls this exists to catch.
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = grp,
    callback = function()
      clamp_overscroll() -- over-scroll clamp: registered here (not module scope) so a
      -- plugin reload doesn't stack a second copy
      if state.win and vim.api.nvim_win_is_valid(state.win) and state.mode == "chat" then
        -- scrolling up (even via the input box's scroll keys, which don't move the chat
        -- cursor) stops the auto-follow, so you can read history WHILE a reply streams;
        -- returning to the bottom re-arms it (follow predicate (a)). Then update the
        -- box (dim/hide).
        state.follow = reply_following()
        reposition_input()
      end
    end,
  })
end

function M.close()
  close_input()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win, state.buf, state.is_float = nil, nil, nil
  state.maximized = nil
  state.wrap_override = nil -- clear the session wrap toggle with the window it applied to
  -- the thread's inline band returns now the popup is gone
  pcall(function()
    require("obelus.render").render_all()
  end)
end

-- Toggle the threads sidebar (the list navigator) open/closed. Works from anywhere —
-- no comment under the cursor needed. If a thread chat/popup is showing, this closes
-- it too (a single key to dismiss any panel window).
function M.toggle()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    M.close()
  else
    M.open() -- the split list navigator
  end
end

-- popup band style: a non-modal, non-focusable hover preview --------------------
-- In render.bands.style = "popup", render.on_cursor opens/moves/closes this preview
-- as the covered comment changes (instead of drawing a virt_lines band). It shows
-- the thread read-only (no input) without stealing focus; <leader>or upgrades it to
-- the modal chat+input (open_thread, which calls hide_preview first).

function M.preview_showing(id)
  return state.preview_win ~= nil and vim.api.nvim_win_is_valid(state.preview_win) and state.preview_thread == id
end

-- Structured, READ-ONLY introspection of the hover preview ALONE — separate from
-- M.geom() because the preview can be showing with NO modal chat open at all (that's
-- the whole point of the popup band style; M.geom() is chat-window-gated). nil when
-- no preview is showing.
function M.preview_geom()
  if not (state.preview_win and vim.api.nvim_win_is_valid(state.preview_win)) then
    return nil
  end
  return { win = state.preview_win, buf = state.preview_buf, thread = state.preview_thread }
end

-- Stop/close the pending re-fit defer (idempotent). Cancel-and-RESCHEDULE, never
-- skip-if-pending: a skipped re-fit would leave the stale-height bottom gap the defer
-- exists to close. Also called from hide_preview so closing the preview can't leave a
-- timer outliving it (harmless either way — size_preview no-ops on an invalid win/
-- stale thread id below — but there's no reason to let it fire late).
local function stop_preview_settle_timer()
  if state._preview_settle_timer then
    local t = state._preview_settle_timer
    state._preview_settle_timer = nil
    pcall(function()
      t:stop()
      t:close()
    end)
  end
end

-- Maximized-preview wcfg: the same near-full overlay as the chat's maximize,
-- but focusable=false stays (the hover is read-only; <A-d>/<A-u> scroll it).
local function preview_max_wcfg(title)
  local W = math.max(40, vim.o.columns - 4)
  local H = math.max(6, vim.o.lines - vim.o.cmdheight - 6)
  return {
    relative = "editor",
    row = 1,
    col = math.max(0, math.floor((vim.o.columns - W) / 2)),
    width = W,
    height = H,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
    focusable = false,
    zindex = 40,
  }
end

-- keys.chat.maximize while HOVERING: the preview is unfocusable and the cursor
-- sits in the CODE window, so the toggle binds buffer-locally on the SOURCE
-- buffer only while its preview is showing — unbound the moment the hover hides
-- (ZZ/ZQ shadowed only during a hover, nowhere else).
local function unbind_preview_maximize()
  local m = state.preview_max_map
  state.preview_max_map = nil
  if m and vim.api.nvim_buf_is_valid(m.buf) then
    pcall(vim.keymap.del, "n", m.lhs, { buffer = m.buf })
  end
end

local function bind_preview_maximize(srcbuf)
  local lhs = require("obelus.config").chat_key("maximize", "Z")
  if not lhs then
    return
  end
  if state.preview_max_map and state.preview_max_map.buf == srcbuf then
    return -- already bound for this buffer
  end
  unbind_preview_maximize()
  vim.keymap.set("n", lhs, function()
    M.toggle_preview_maximize()
  end, { buffer = srcbuf, silent = true, nowait = true })
  state.preview_max_map = { buf = srcbuf, lhs = lhs }
end

-- Is the user BROWSING the maximized preview (it holds the real cursor)?
-- render.on_cursor consults this: cursor/win events inside the preview must not
-- trip the hover's own hide-on-leave lifecycle.
function M.preview_focused()
  return state.preview_maximized ~= nil
    and state.preview_win ~= nil
    and vim.api.nvim_win_is_valid(state.preview_win)
    and vim.api.nvim_get_current_win() == state.preview_win
end

function M.toggle_preview_maximize()
  if not (state.preview_win and vim.api.nvim_win_is_valid(state.preview_win)) then
    return
  end
  state.preview_maximized = not state.preview_maximized or nil
  if state.preview_maximized then
    -- FOCUSED read-only browse mode: the overlay takes the real cursor, so all
    -- native motions (j/k/h/l, search, visual select, y) just work. Z/q/<Esc>
    -- inside it (or leaving the window any other way) restores the rooted hover.
    local title = float_title(store.get(state.preview_thread))
    local wcfg = preview_max_wcfg(title)
    wcfg.focusable = true
    state.preview_return_win = vim.api.nvim_get_current_win()
    pcall(vim.api.nvim_win_set_config, state.preview_win, wcfg)
    pcall(vim.api.nvim_set_current_win, state.preview_win)
    local pbuf = state.preview_buf
    if pbuf and vim.api.nvim_buf_is_valid(pbuf) then
      local lhs = require("obelus.config").chat_key("maximize", "Z")
      for _, key in ipairs({ lhs, "q", "<Esc>" }) do
        if key then
          vim.keymap.set("n", key, function()
            M.toggle_preview_maximize()
          end, { buffer = pbuf, silent = true, nowait = true })
        end
      end
      -- leaving the overlay by ANY route (wincmd, mouse) restores the hover too;
      -- scheduled so the restore's own window ops never run inside the autocmd
      vim.api.nvim_create_autocmd("WinLeave", {
        buffer = pbuf,
        once = true,
        callback = function()
          vim.schedule(function()
            if state.preview_maximized then
              state.preview_maximized = nil
              M.refresh_preview(true)
            end
          end)
        end,
      })
    end
    pcall(vim.cmd, "redraw")
  else
    local ret = state.preview_return_win
    state.preview_return_win = nil
    if ret and vim.api.nvim_win_is_valid(ret) then
      pcall(vim.api.nvim_set_current_win, ret) -- fires the WinLeave above; the guard sees maximized=nil
    end
    M.refresh_preview(true) -- re-fit back to the rooted, unfocusable geometry
  end
end

function M.hide_preview()
  stop_preview_settle_timer()
  unbind_preview_maximize()
  state.preview_maximized = nil
  if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then
    pcall(vim.api.nvim_win_close, state.preview_win, true)
  end
  if state.preview_root and state.preview_root.buf and vim.api.nvim_buf_is_valid(state.preview_root.buf) then
    pcall(vim.api.nvim_buf_clear_namespace, state.preview_root.buf, ns_pconn, 0, -1)
  end
  if state.preview_buf then
    bar_maps[state.preview_buf] = nil -- preview_buf has bufhidden=wipe, so it dies with its window
  end
  state.preview_win, state.preview_thread, state.preview_root = nil, nil, nil
end

-- fill_preview gets fill()'s defenses: a content signature to coalesce away
-- unchanged rebuilds, and a time-throttle before paying for one — it used to pay for
-- a FULL rebuild (buffer write + decorate + markview render + a deferred re-fit) on
-- every ~10Hz refresh_preview tick unconditionally. `force` bypasses BOTH (mirrors
-- fill()'s hard/force pass): M.preview() passes true on every (re)open — a fast
-- hide+reopen, or moving straight from one covered comment to another (on_cursor
-- calls M.preview() directly, no hide in between — see render.lua's on_cursor), must
-- never be dropped by a stale throttle window or a coalesce against the PREVIOUS
-- comment's content. M.refresh_preview() (the stream-tick path) passes nothing, so
-- it's fully throttled/coalesced.
-- Opt-in geometry parity (render.preview_matches_chat): the hover preview uses
-- the CHAT popup's width recipe (same base + same grow-to-content) and shares the
-- per-thread sticky anchor side, so <prefix>or turns a hover into the chat without
-- the box changing width or jumping across the selection (the input rows appear
-- below; with the side held "below" the content itself doesn't move). Off (the
-- default): the preview keeps its own narrower base and per-hover side.
local function preview_matching()
  return (require("obelus.config").options.render or {}).preview_matches_chat == true
end

-- SAME recipe as the chat popup (base_width_for -> thread.pref_width), measured on
-- the previewed comment's SOURCE text — never the preview buffer (that's the
-- rendered/wrapped copy; measuring it oscillates, see thread.pref_width). This is
-- what makes hover == chat: replying to a hovered thread never resizes the box.
local function preview_base_width()
  if preview_matching() and state.preview_thread then
    return base_width_for(store.get(state.preview_thread))
  end
  return popup_width(0.7)
end

local function preview_side()
  if preview_matching() and state.preview_thread then
    return state._anchor_sides[state.preview_thread]
  end
  return nil
end

local function remember_preview_side(side)
  if preview_matching() and state.preview_thread then
    state._anchor_sides[state.preview_thread] = side
  end
end

local function fill_preview(force)
  if not (state.preview_buf and vim.api.nvim_buf_is_valid(state.preview_buf)) then
    return
  end
  local now = (vim.uv or vim.loop).now()
  if not force and state._plastfill and (now - state._plastfill) < M._timing.fill_throttle then
    return -- leave _pfillsig stale: the next tick (or a forced call) picks up the pending change
  end
  local win = state.preview_win
  local width = (win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win)) or FALLBACK_WIDTH
  local mode = render_mode()
  local lines, _, decos = build_chat(state.preview_thread, { is_float = true, read_only = true, width = width })
  -- The preview_buf HANDLE is part of the signature, not just its content: preview_buf
  -- has bufhidden=wipe, so hide->reopen creates a NEW buffer number. Without the
  -- handle in the sig, byte-identical content would coalesce against the OLD (now
  -- wiped) buffer's last-written signature, and the freshly (re)created buffer would
  -- never get its first write — a reopened preview would render blank.
  local sig = table.concat(lines, "\n")
    .. "|"
    .. width
    .. "|"
    .. mode
    .. "|"
    .. tostring(state.preview_thread)
    .. "|"
    .. tostring(state.preview_buf)
  if not force and sig == state._pfillsig then
    return
  end
  state._plastfill = now
  state._pfillsig = sig
  vim.bo[state.preview_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.preview_buf, 0, -1, false, lines)
  vim.bo[state.preview_buf].modifiable = false
  decorate(decos, state.preview_buf, win)
  if win and vim.api.nvim_win_is_valid(win) and not M.preview_focused() then
    -- unfocused: always follow the latest. Bare seat (no redraw, no content_row) —
    -- size_preview below re-seats moments later anyway whenever preview_root is set.
    -- While the user BROWSES the maximized preview, their cursor position is theirs.
    seat_bottom(win, state.preview_buf, {})
  end
  local pmode = render_mode()
  if pmode == "markview" or pmode == "treesitter" then
    -- the markdown TS highlighter supplies the CODE-BLOCK token colours (language
    -- injections) — markview only draws the box/label around them. The chat path
    -- starts it in reconcile_renderer; without this the preview's fences render
    -- as an all-grey box while the modal shows them coloured.
    if state._pts_buf ~= state.preview_buf then
      pcall(vim.treesitter.start, state.preview_buf, "markdown")
      state._pts_buf = state.preview_buf -- once per buffer (bufhidden=wipe recreates)
    end
    -- FORCE a full synchronous parse, injections included: nvim 0.12 parses
    -- injections ASYNCHRONOUSLY, progressing on redraw activity — an idle,
    -- unfocused float gets none, so big threads sat with grey (unparsed) code
    -- fences forever while the same buffer coloured fine once something drove
    -- redraws (e.g. typing). Incremental, so cheap on unchanged content.
    pcall(function()
      vim.treesitter.get_parser(state.preview_buf, "markdown"):parse(true)
    end)
  end
  if markview_on() then
    -- per-actual-pass, NOT cached/once: this races markview's own ColorScheme
    -- lifecycle (a live theme change must re-derive the twins on the very next
    -- render). The coalesce above is what shields this from every 10Hz tick.
    require("obelus.thread").markview_harmonize()
    pcall(function()
      local mv = require("markview.actions")
      -- drive the preview DETACHED too (like the modal): otherwise markview's auto-render reverts
      -- the scoped config (table virt_lines come back). detach clears, then we render scoped.
      pcall(mv.detach, state.preview_buf)
      mv_render_scoped(state.preview_buf, win) -- wrap-bracketed: full table marks
    end)
  end
  -- winopts AFTER the markview block: the detach above restores markview's saved
  -- window options (clobbering conceallevel to 0), so setting ours last keeps the
  -- conceal marks displayable — same ordering fix as fill()'s.
  apply_winopts(win, state.preview_buf, "chat", false)
  -- size SNUG to content and GROW with streaming, like the modal's fit_rooted —
  -- EXCEPT the preview must still SHRINK for shorter threads (its sizing here is
  -- text_height-only; no grow-only/never-shrink clamp like fit_rooted's soft pass).
  -- The two fit strategies are opposite ON PURPOSE — do NOT unify them. The real
  -- height is the WRAPPED screen-row count (incl. virt_line dividers), not the buffer
  -- line count. Take the larger; cap at ~80% of the editor (rooted_wincfg then clamps
  -- to the room beside the anchor) so a long reply caps-then-scrolls instead of a
  -- fixed gap under a short draft. min_h = 1 so a 1-line comment is snug (no 6-row
  -- floor — the preview has no input).
  local function size_preview()
    local w = state.preview_win
    if not (w and vim.api.nvim_win_is_valid(w) and state.preview_root) then
      return
    end
    if not (state.preview_buf and vim.api.nvim_buf_is_valid(state.preview_buf)) then
      return
    end
    -- DISPLAYED height: nvim_win_text_height accounts for BOTH wrapping AND markview conceal,
    -- unlike buffer line_count which OVER-counts concealed ``` fence lines (that over-count is
    -- what sized the box too tall, so it opened scrolled part-way with a bottom gap). Fall back
    -- to line_count only if the measurement fails. Cap ~80% of the editor → long threads scroll.
    local okth, th = pcall(vim.api.nvim_win_text_height, w, {})
    local base_h = (okth and th and th.all) or vim.api.nvim_buf_line_count(state.preview_buf)
    base_h = math.max(1, math.min(base_h, math.max(3, math.floor(vim.o.lines * 0.8))))
    local title = float_title(store.get(state.preview_thread))
    if state.preview_maximized then
      local mcfg = preview_max_wcfg(title)
      mcfg.focusable = true -- keep the browse mode's focusability across re-fits
      pcall(vim.api.nvim_win_set_config, w, mcfg)
      if not M.preview_focused() then
        seat_bottom(w, state.preview_buf, {})
      end
      return
    end
    local wcfg, pside = rooted_wincfg(state.preview_root, preview_base_width(), base_h, title, 1, preview_side())
    remember_preview_side(pside)
    wcfg.focusable = false
    wcfg.zindex = 40
    pcall(vim.api.nvim_win_set_config, w, wcfg)
    -- Seat the LATEST content at the bottom (like the chat) so the box fills from the bottom with
    -- older turns above if it overflows — instead of opening scrolled part-way with empty below.
    seat_bottom(w, state.preview_buf, {})
  end
  if win and vim.api.nvim_win_is_valid(win) and state.preview_root then
    size_preview()
    -- markview places its virt_lines ASYNC (debounced ~150ms), and the preview is
    -- focusable=false, so — unlike the modal — it never gets a cursor/scroll event to
    -- re-fit itself after markview settles. That stale first measurement is what
    -- leaves a bottom gap (or a clip). Re-fit ONCE after markview settles so the
    -- window snaps to the true height.
    --
    -- CANCEL-AND-RESCHEDULE (never skip-if-pending): keep the timer handle in state
    -- and stop/close any prior pass's still-pending timer before scheduling this
    -- pass's. This defer CANNOT be deleted — the preview is focusable=false, so no
    -- cursor/scroll event ever reaches it to trigger a re-fit once markview's async
    -- render settles; skipping a scheduled re-fit here would leave that stale-height
    -- gap. REVERT: delete this whole block to restore the single-measurement
    -- behaviour (pre-coalesce, this ran unconditionally every fill_preview pass).
    stop_preview_settle_timer()
    local pid = state.preview_thread
    state._preview_settle_timer = vim.defer_fn(function()
      state._preview_settle_timer = nil
      if state.preview_thread == pid then
        size_preview()
      end
    end, M._timing.preview_settle)
  end
  return lines
end

function M.preview(id)
  local c = store.get(id)
  if not c then
    return M.hide_preview()
  end
  -- the modal chat/popup already owns this thread (or is mid-open: state.mode is
  -- transiently "list" inside M.open) — don't also pop a preview for it
  if M.showing(id) or (state.win and vim.api.nvim_win_is_valid(state.win) and state.thread == id) then
    return M.hide_preview()
  end
  local cwin = vim.api.nvim_get_current_win()
  local cbuf = vim.api.nvim_win_get_buf(cwin)
  if nav_util.abspath(vim.api.nvim_buf_get_name(cbuf)) ~= c.file then
    return M.hide_preview()
  end
  state.preview_thread = id
  state.preview_root = {
    win = cwin,
    buf = cbuf,
    sl0 = c.range.sl - 1, -- first selected line (0-based)
    el0 = (c.range.el or c.range.sl) - 1, -- last selected line (0-based)
  }
  if not (state.preview_buf and vim.api.nvim_buf_is_valid(state.preview_buf)) then
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "markdown" -- before attach; never changed (markview nofile detach)
    if markview_on() then
      ensure_markview_config()
      pcall(function()
        require("markview.actions").attach(buf, { enable = true, hybrid_mode = false })
      end)
    end
    state.preview_buf = buf
  end
  local lines = build_chat(id, { is_float = true, read_only = true, width = FALLBACK_WIDTH })
  local W = preview_base_width()
  local H = math.min(math.max(#lines, 3), math.max(6, math.floor(vim.o.lines * 0.8)))
  local wcfg, oside = rooted_wincfg(state.preview_root, W, H, float_title(c), 1, preview_side())
  remember_preview_side(oside)
  wcfg.focusable = false -- read-only preview: window-nav skips it, cursor stays in code
  wcfg.zindex = 40 -- below the modal input (60); above normal content
  bind_preview_maximize(cbuf)
  if state.preview_maximized then
    wcfg = preview_max_wcfg(float_title(c))
  end
  if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then
    pcall(vim.api.nvim_win_set_config, state.preview_win, wcfg)
  else
    -- noautocmd: opening this float must not fire WinLeave/WinResized/WinEnter (which
    -- would race with our own on_cursor lifecycle and flicker the preview closed)
    wcfg.noautocmd = true
    state.preview_win = vim.api.nvim_open_win(state.preview_buf, false, wcfg)
    wcfg.noautocmd = nil
    local pbase = transparent() and "Normal:ObelusThreadText,NormalFloat:ObelusThreadText," or ""
    vim.wo[state.preview_win].winhighlight = chat_winhl(pbase .. "FloatBorder:ObelusBorder,EndOfBuffer:NormalFloat")
    vim.wo[state.preview_win].winblend = require("obelus.config").options.render.winblend or 0
    vim.wo[state.preview_win].number = false
    vim.wo[state.preview_win].relativenumber = false
    vim.wo[state.preview_win].signcolumn = "no"
    vim.wo[state.preview_win].foldcolumn = "0"
  end
  fill_preview(true) -- forced: a fresh (re)open must never be dropped by a stale throttle/sig
  -- (no extra rooted marker — the commented line keeps its normal inline gutter sign)
  -- (open/close on hover is driven by render.on_cursor)
end

-- force: bypass the throttle/coalesce (seat_finish's trailing-edge repaint — the
-- stream's final text must land even when the last soft repaint was moments ago).
function M.refresh_preview(force)
  if not (state.preview_win and vim.api.nvim_win_is_valid(state.preview_win)) then
    return
  end
  local c = store.get(state.preview_thread)
  if not c or (c.status == "resolved" and not require("obelus.render").resolved_shown()) then
    return M.hide_preview()
  end
  fill_preview(force) -- throttled/coalesced unless forced — see fill_preview's doc comment
end

return M
