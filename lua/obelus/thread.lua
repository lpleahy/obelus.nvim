local format = require("obelus.format")
local config = require("obelus.config")
local mention = require("obelus.mention")

-- the left accent bar glyph (tunable: render.bar, e.g. "▌"/"█" for thicker)
local function barchar()
  return (config.options.render or {}).bar or "▎"
end

-- Strip zero-width characters (U+200B/C/D, U+FEFF) the agent sometimes inserts to
-- escape nested ``` fences. They render literally as <200b> and break fence/markdown
-- parsing (prose gets treated as code → wrong colour). Applied at RENDER time so it
-- also cleans up replies already in the history, without touching the stored text.
local function sanitize(s)
  if not s or s == "" then
    return s
  end
  return (s:gsub("\226\128[\139\140\141]", ""):gsub("\239\187\191", ""))
end

-- Renders a comment as a full-width inline "band" (extmark virt_lines, so it
-- occupies real vertical space and pushes code down — no floating box). Style is
-- borrowed from the inline-diagnostic plugins: a left accent bar + a background
-- tint blended from the theme, with light inline-markdown styling of the body.
local M = {}

-- Serialize a comment's conversation as plain Markdown (for a real buffer rendered
-- by a markdown plugin like markview). Turns become sections separated by rules;
-- the rooted code snippet is a fenced block. No obelus chrome — the renderer owns it.
function M.to_markdown(comment)
  local store = require("obelus.store")
  local out = {}
  local function add(s)
    for _, l in ipairs(vim.split(s, "\n", { plain = true })) do
      out[#out + 1] = l
    end
  end
  for i, t in ipairs(store.turns(comment)) do
    if i > 1 then
      add("")
      add("---")
      add("")
    end
    local who = t.author == "agent" and "### agent ↩" or "### you"
    if i == 1 then
      who = who .. "  ·  `" .. format.range_label(comment) .. "`"
    end
    add(who)
    add("")
    if i == 1 and comment.selected_text and #comment.selected_text > 0 then
      add("```" .. (comment.ft or comment.filetype or ""))
      for _, l in ipairs(comment.selected_text) do
        add(l)
      end
      add("```")
      add("")
    end
    add(sanitize(t.text) or "")
  end
  return out
end

-- color helpers ------------------------------------------------------------

local function channels(c)
  return math.floor(c / 65536) % 256, math.floor(c / 256) % 256, c % 256
end

local function blend(fg, bg, alpha)
  local fr, fgc, fb = channels(fg)
  local br, bgc, bb = channels(bg)
  local r = math.floor(fr * alpha + br * (1 - alpha) + 0.5)
  local g = math.floor(fgc * alpha + bgc * (1 - alpha) + 0.5)
  local b = math.floor(fb * alpha + bb * (1 - alpha) + 0.5)
  return r * 65536 + g * 256 + b
end

local function color(name, attr)
  local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and h and h[attr] then
    return h[attr]
  end
end

function M.setup_highlights()
  local cc = (require("obelus.config").options.render or {}).colors or {}
  -- All blended from the live theme, with robust fallbacks (transparent themes,
  -- missing DiagnosticOk, etc.) and overridable via config.render.colors.
  local bg = color("Normal", "bg") or color("NormalFloat", "bg") or color("CursorLine", "bg") or 0x1e1e2e
  local fg = color("Normal", "fg") or 0xcdd6f4
  local accent = color(cc.you or "DiagnosticInfo", "fg") or color("Function", "fg") or 0x89b4fa
  local agentc = color(cc.agent or "DiagnosticOk", "fg")
    or color("DiagnosticHint", "fg")
    or color("String", "fg")
    or 0xa6e3a1
  local meta = color(cc.meta or "Comment", "fg") or 0x6c7086
  -- a distinct "chrome" accent for floats borders + the input box — neither the you
  -- nor the agent colour, so they read as the frame around the conversation. Sourced
  -- from a theme variable (Tokyo Night's purple keyword colour by default) so it
  -- adapts to any theme; override with render.colors.accent.
  local brand = color(cc.accent or "@keyword", "fg")
    or color("Keyword", "fg")
    or color("Statement", "fg")
    or color("Special", "fg")
    or 0xbb9af7
  -- @mention accent: deliberately NOT brand/you/agent — every obelus surface a
  -- mention can appear on is tinted with one of those (input box = brand, your
  -- turns = you, agent turns = agent), so any of them would blend in somewhere.
  -- The theme's warn orange collides with none of them; override with
  -- render.colors.mention.
  local mentionc = color(cc.mention or "DiagnosticWarn", "fg")
    or color("WarningMsg", "fg")
    or color("Number", "fg")
    or 0xe0af68
  -- Identity lives on the BAR + DIVIDER LINES (full colour); the bubble bg is a
  -- whisper-soft tint so blocks of colour don't encroach on each other. In
  -- `transparent` mode the bg is dropped entirely (NONE) — the code/editor shows
  -- through everywhere (floats AND in-buffer band/sidebar) and text stays crisp.
  local transparent = (require("obelus.config").options.render or {}).transparent == true
  local tint = cc.tint or 0.08
  -- NB: `cond and nil or x` is always x in Lua, so compute bgs with a real branch
  local band, reply, codeb, rcodeb
  if not transparent then
    band = blend(accent, bg, tint)
    reply = blend(agentc, bg, tint)
    codeb = blend(accent, bg, tint + 0.05)
    rcodeb = blend(agentc, bg, tint + 0.05)
  end
  local set = function(name, opts)
    vim.api.nvim_set_hl(0, name, opts)
  end
  set("ObelusThreadBar", { fg = accent, bg = band })
  set("ObelusThreadBg", { bg = band })
  set("ObelusThreadHeader", { fg = accent, bg = band, bold = true })
  set("ObelusThreadText", { fg = fg, bg = band })
  set("ObelusThreadBold", { fg = fg, bg = band, bold = true })
  set("ObelusReplyBold", { fg = fg, bg = reply, bold = true })
  set("ObelusThreadMeta", { fg = meta, bg = band })
  set("ObelusThreadRule", { fg = accent, bg = band }) -- divider carries the colour
  set("ObelusThreadCode", { fg = accent, bg = codeb })
  set("ObelusReplyBar", { fg = agentc, bg = reply })
  set("ObelusReplyBg", { bg = reply })
  set("ObelusReplyHeader", { fg = agentc, bg = reply, bold = true })
  set("ObelusReplyText", { fg = fg, bg = reply })
  set("ObelusReplyMeta", { fg = meta, bg = reply })
  set("ObelusReplyCode", { fg = agentc, bg = rcodeb })
  set("ObelusReplyRule", { fg = agentc, bg = reply }) -- divider carries the colour
  -- inline span groups (builtin renderer only — md_chunks' S table): *italic* keeps
  -- the body fg on the bubble bg; ~~strike~~ and [links] are fg-only (no bg to gate
  -- in transparent mode); the code-block language label shares the code box bg so it
  -- reads as part of the code row, not a floating tag.
  set("ObelusThreadItalic", { fg = fg, bg = band, italic = true })
  set("ObelusReplyItalic", { fg = fg, bg = reply, italic = true })
  set("ObelusThreadStrike", { fg = meta, strikethrough = true })
  set("ObelusReplyStrike", { fg = meta, strikethrough = true })
  set("ObelusThreadLink", { fg = brand, underline = true })
  set("ObelusReplyLink", { fg = brand, underline = true })
  -- valid @mention spans (thread.lua's md_chunks post-pass): brand fg (same accent
  -- as links/tags) on the turn's own bubble bg — bg follows band/reply exactly like
  -- Bold above, so it drops to NONE in transparent mode too.
  set("ObelusThreadMention", { fg = mentionc, bg = band, bold = true })
  set("ObelusReplyMention", { fg = mentionc, bg = reply, bold = true })
  set("ObelusThreadCodeLabel", { fg = meta, bg = codeb })
  set("ObelusReplyCodeLabel", { fg = meta, bg = rcodeb })
  -- neutral-bg dividers for the sidebar (drawn as virt_lines, so the tint can't
  -- bleed past the line into the neighbouring bubble)
  local rs = cc.rule or 0.75
  set("ObelusThreadRuleN", { fg = blend(accent, bg, rs) })
  set("ObelusReplyRuleN", { fg = blend(agentc, bg, rs) })
  -- bar tick for divider rows: the bright bar colour with NO bg, so the left bar
  -- reads as one continuous line without painting a tinted square over the rule
  set("ObelusThreadBarN", { fg = accent })
  set("ObelusReplyBarN", { fg = agentc })
  -- fg-only headers (no bg), used in markview mode so markview owns the backgrounds
  set("ObelusThreadHeaderN", { fg = accent, bold = true })
  set("ObelusReplyHeaderN", { fg = agentc, bold = true })
  -- chrome (scroll hints / help lines): a neutral colour distinct from you/agent,
  -- no background box, so it doesn't read as a turn
  set("ObelusChrome", { fg = meta })
  -- the chrome accent (float borders): the distinct brand colour, no box
  set("ObelusBorder", { fg = brand })
  -- tag badge: the distinct brand colour sitting ON the you-bubble tint (bg = band,
  -- NOT the agent tint), so a thread's #tag reads cleanly in the header with no box
  set("ObelusThreadTag", { fg = brand, bg = band })
  -- the reply/compose INPUT box: tinted with the DISTINCT brand colour (not you/agent)
  -- + a brand border/bar, so the place you type is unmistakable from the history
  local inbg = not transparent and blend(brand, bg, math.min(tint * 2.4, 0.26)) or nil
  set("ObelusInput", { fg = fg, bg = inbg })
  set("ObelusInputBorder", { fg = brand, bg = inbg, bold = true })
  set("ObelusInputBar", { fg = brand, bg = inbg }) -- the input's left statuscolumn bar
  set("ObelusInputHeader", { fg = brand, bg = inbg, bold = true }) -- the "reply"/"you" title
  -- live VALID @mention highlight in an input buffer (mention.lua's rescan_mentions):
  -- mention accent fg only, no bg — the input box's own bg (inbg above) shows
  -- through, and its chrome is BRAND-tinted, which is exactly why the mention
  -- accent is a different colour (see mentionc above)
  set("ObelusMention", { fg = mentionc, bold = true })
  -- optional Visual-selection override for the chat windows (render.colors.selection).
  -- Remapped onto the chat window via chat_winhl so it doesn't touch Visual elsewhere.
  if cc.selection ~= nil then
    local sbg = type(cc.selection) == "number" and cc.selection or color(cc.selection, "bg")
    set("ObelusVisual", { bg = sbg })
  end
end

-- markview harmonization ---------------------------------------------------
-- markview computes every code/heading/inline background from the editor's Normal
-- bg, so on obelus's tinted float those boxes clash. We define Obelus_Markview*
-- twins whose BG is blended from obelus's float tint (keeping markview's tuned FG),
-- then remap the bg-bearing Markview* groups to them PER-WINDOW via 'winhighlight'
-- (verified to retarget extmark hl_groups — including @-prefixed treesitter capture
-- names like @punctuation.special.markdown; winhighlight's {hl-from} is just a
-- highlight-group NAME, nvim never special-cases the string shape) — so only
-- obelus's float/sidebar is affected and global markview rendering elsewhere (the
-- user's own markdown buffers, with their own personal markview config) is
-- untouched. This ALSO makes obelus independent of two global repairs some users'
-- dotfiles apply for a bare `markview.setup({})` install: (1) stripping bg from
-- Markview{Code,CodeInfo,InlineCode,Heading0-6,Icon0-6} on transparent setups —
-- every one of those groups is already remapped to a twin below whose bg is nil in
-- transparent mode, so obelus never needed that global strip; (2) pinning
-- @punctuation.special.markdown's fg — markview falls back to that exact group for
-- a table's border glyphs when the window is wrapped at render time, and some
-- colorschemes never define it (or its `@markup.raw`/`@markup.link.label...`
-- cousins used by inline-code/hyperlink fg), leaving those groups with NEITHER fg
-- nor bg (invisible). obelus's own render is never actually wrapped while markview
-- draws (mv_render_scoped forces wrap off for the whole synchronous render call, so
-- @punctuation.special.markdown's degraded path is structurally unreachable here),
-- but it — and the other themes-can-leave-this-undefined groups below — get a twin
-- with a themed fallback fg anyway, both as defense-in-depth and because the SAME
-- undefined-@-group failure mode is real for MarkviewInlineCode/MarkviewHyperlink
-- (their fg sources have no internal fallback in markview itself).

-- (re)define the Obelus_Markview* twins from the live obelus tint + markview FGs.
function M.markview_harmonize()
  -- blend the code/inline/box backgrounds from the NEUTRAL editor bg (not the you-tint
  -- bubble bg) with a SMALL lift, so a box sits subtly on EITHER the you or the agent
  -- bubble without a visible edge or a clashing hue (the bubbles alternate colour but
  -- the per-window markview remap can only be one colour).
  -- In a TRANSPARENT theme/terminal an explicit bg becomes an opaque rectangle (e.g. Ghostty's
  -- background-opacity-cells), so a blended code/inline/icon bg reads as a black box over the
  -- see-through buffer. When the editor bg is transparent (Normal bg unset, or obelus transparent
  -- mode) leave these backgrounds UNSET — the per-turn bubble tint (line_hl) shows through the
  -- code/inline/icon spans instead of a box. Opaque themes keep the subtle recessed boxes.
  local nbg = color("Normal", "bg")
  local transparent = (require("obelus.config").options.render or {}).transparent == true or nbg == nil
  local base = nbg or color("NormalFloat", "bg") or 0x1e1e2e
  local r, g, b = channels(base)
  -- RECESS code: darken on dark themes (toward black), lighten on light themes — so a
  -- code box reads as "set into" the bubble (like most editors render fenced code),
  -- not a lighter patch. Blended from the neutral bg so it sits on either bubble.
  local sink = (r + g + b) < 384 and 0x000000 or 0xffffff
  local code_bg = not transparent and blend(sink, base, 0.22) or nil
  local inline_bg = not transparent and blend(sink, base, 0.16) or nil
  local box_bg = not transparent and blend(sink, base, 0.08) or nil
  local function set(name, opts)
    vim.api.nvim_set_hl(0, name, opts)
  end
  -- meta/border fallback fg chain shared by every twin below whose markview source
  -- can end up genuinely undefined on some theme (no @markup.*/@punctuation.* capture
  -- set): the group's own live fg if the theme DOES define it, else a neutral but
  -- always-visible colour. Only ever shows through characters with no more specific
  -- (e.g. per-token injected-language) highlighting on top of it — never overrides
  -- real syntax colour, just prevents "no fg and no bg at all".
  local meta_fallback = color("Comment", "fg") or 0x6c7086
  -- BG-ONLY, deliberately: this is markview's whole code-block REGION highlight.
  -- Giving it ANY fallback fg paints EVERY token in every fence that colour —
  -- the treesitter injection colours underneath never show through (a shipped
  -- regression: "all my code blocks are grey"). Token fgs come from the markdown
  -- TS highlighter; this group only supplies the recessed box. `fg` passes
  -- through ONLY if markview's own group defines one (it normally doesn't).
  set("Obelus_MarkviewCode", { bg = code_bg, fg = color("MarkviewCode", "fg") })
  set("Obelus_MarkviewCodeInfo", { bg = code_bg, fg = color("Comment", "fg") })
  set("Obelus_MarkviewCodeFg", { fg = code_bg }) -- the code box border; fg must equal code bg (nil = none)
  -- the code-block language LABEL (transparent mode uses this via code_blocks.label_hl). Give it the
  -- AGENT bubble bg (code blocks live in agent turns) so the right-aligned label blends with the
  -- bubble instead of a see-through hole; opaque mode isn't routed here (keeps the coloured label).
  set("Obelus_MarkviewCodeLabel", {
    bg = color("ObelusReplyBg", "bg") or code_bg,
    fg = color("MarkviewCodeInfo", "fg") or color("Comment", "fg"),
  })
  -- inline `code`: DEFAULT to no background so it inherits the per-turn bubble tint (a fixed
  -- recessed box reads as a dark hole that doesn't match the alternating bubble bg). A knob
  -- restores a box: render.colors.inline_code = true (recessed) | <0xRRGGBB> | <hl group name>.
  local ic = ((require("obelus.config").options.render or {}).colors or {}).inline_code
  -- markview's OWN MarkviewInlineCode fg is sourced from `@markup.raw` with NO
  -- internal fallback (unlike its palette-driven groups, which always have a
  -- hardcoded hex fallback baked into markview itself) — a theme that never sets
  -- `@markup.raw` leaves inline code with no fg at all; fall back to String (most
  -- themes colour inline code like a literal) then the shared meta chain.
  local icfg = color("MarkviewInlineCode", "fg") or color("@markup.raw", "fg") or color("String", "fg") or meta_fallback
  local ibg
  if ic == true then
    ibg = inline_bg
  elseif type(ic) == "number" then
    ibg = ic
  elseif type(ic) == "string" then
    ibg = color(ic, "bg")
  end
  set("Obelus_MarkviewInlineCode", { bg = ibg, fg = icfg })
  for i = 0, 6 do
    set("Obelus_MarkviewIcon" .. i, { bg = code_bg, fg = color("MarkviewPalette" .. i .. "Fg", "fg") })
  end
  for i = 1, 6 do
    set("Obelus_MarkviewHeading" .. i, { bg = box_bg, fg = color("MarkviewPalette" .. i .. "Fg", "fg") })
  end
  for i = 0, 7 do
    set("Obelus_MarkviewPalette" .. i, { bg = box_bg, fg = color("MarkviewPalette" .. i .. "Fg", "fg") })
    set("Obelus_MarkviewPalette" .. i .. "Bg", { bg = box_bg })
  end
  -- a plain `>` blockquote border: mute it (Comment colour) so it doesn't read as a
  -- second clashing vertical bar inside the bubble next to the turn's accent bar
  set("Obelus_MarkviewBlockQuoteDefault", { fg = color("Comment", "fg") or 0x6c7086 })
  -- the horizontal-rule gap glyph: markview's OWN default hr config hardcodes
  -- "MarkviewIcon3Fg" for it, but markview never actually DEFINES that group (it's
  -- absent from markview's own highlights.lua) — every `---` is invisible-by-default
  -- on a vanilla install, no colorscheme quirk required. Fall back through the same
  -- palette index (Icon3/Palette3 groups ARE always defined — see the Icon0-6 loop
  -- above) so the glyph stays in the same colour family as the rest of the palette.
  set("Obelus_MarkviewIcon3Fg", {
    fg = color("MarkviewIcon3Fg", "fg") or color("MarkviewPalette3Fg", "fg") or meta_fallback,
  })
  -- markdown links/images/footnotes: markview's OWN MarkviewHyperlink fg is sourced
  -- from `@markup.link.label.markdown_inline` with no internal fallback (same class
  -- of gap as inline code above) — fall back to the standard `Underlined` group
  -- (virtually every colorscheme sets it; it's the semantically-right family for a
  -- link) before the shared meta chain.
  set("Obelus_MarkviewHyperlink", {
    fg = color("MarkviewHyperlink", "fg") or color("@markup.link.label.markdown_inline", "fg") or color(
      "Underlined",
      "fg"
    ) or meta_fallback,
  })
  -- @punctuation.special.markdown: markview's OWN degraded-table-border fallback hl
  -- (used when a table renders in a WRAPPED window — see markview_winhl's remap
  -- comment). obelus's scoped render always forces wrap off for the render call, so
  -- this path is structurally unreachable today; twinned anyway as defense-in-depth
  -- (a future render call site that doesn't wrap-bracket, or a markview internal
  -- change, would otherwise silently regress to an undefined/invisible border) and
  -- because it's the exact failure mode this whole hardening pass targets.
  set("Obelus_MarkviewPunctuationSpecial", {
    fg = color("@punctuation.special.markdown", "fg") or color("@punctuation.special", "fg") or color(
      "Delimiter",
      "fg"
    ) or meta_fallback,
  })
end

-- per-window winhighlight remap string retargeting markview's bg-bearing groups
-- to their Obelus_* twins (apply to the obelus chat float/sidebar window only).
function M.markview_winhl()
  local p = {
    "MarkviewCode:Obelus_MarkviewCode",
    "MarkviewCodeInfo:Obelus_MarkviewCodeInfo",
    "MarkviewCodeFg:Obelus_MarkviewCodeFg",
    "MarkviewInlineCode:Obelus_MarkviewInlineCode",
    "MarkviewBlockQuoteDefault:Obelus_MarkviewBlockQuoteDefault",
    "MarkviewIcon3Fg:Obelus_MarkviewIcon3Fg", -- hr gap glyph (never defined by markview itself)
    "MarkviewHyperlink:Obelus_MarkviewHyperlink", -- links/images/footnotes
    -- markview's degraded (wrapped-window) table-border fallback hl — an ordinary
    -- highlight group despite the @-prefixed treesitter-capture-style name; 'winhighlight'
    -- remaps it exactly like any other {hl-from} (verified empirically: an extmark
    -- referencing this exact group name resolves through the window's winhighlight
    -- the same way a plain "MarkviewCode"-style name does — same before/after
    -- attribute-id delta, same scoping to the one window).
    "@punctuation.special.markdown:Obelus_MarkviewPunctuationSpecial",
  }
  for i = 0, 6 do
    p[#p + 1] = ("MarkviewIcon%d:Obelus_MarkviewIcon%d"):format(i, i)
  end
  for i = 1, 6 do
    p[#p + 1] = ("MarkviewHeading%d:Obelus_MarkviewHeading%d"):format(i, i)
  end
  for i = 0, 7 do
    p[#p + 1] = ("MarkviewPalette%d:Obelus_MarkviewPalette%d"):format(i, i)
    p[#p + 1] = ("MarkviewPalette%dBg:Obelus_MarkviewPalette%dBg"):format(i, i)
  end
  return table.concat(p, ",")
end

-- text helpers -------------------------------------------------------------

-- Incremental width tracking (was O(len²): re-measure the whole accumulated line
-- with vim.fn.strdisplaywidth on every word). `curw` is the running display width
-- of `cur`; each word's width is measured once and added/compared directly. A
-- single word wider than `width` still goes out alone on its own row (cur == ""
-- always accepts the candidate, same as before).
local function wrap(text, width)
  local out = {}
  for _, para in ipairs(vim.split(text or "", "\n", { plain = true })) do
    if para == "" then
      out[#out + 1] = ""
    else
      local cur, curw = "", 0
      for word in para:gmatch("%S+") do
        local ww = vim.fn.strdisplaywidth(word)
        if cur == "" then
          cur, curw = word, ww
        elseif curw + 1 + ww > width then
          out[#out + 1] = cur
          cur, curw = word, ww
        else
          cur = cur .. " " .. word
          curw = curw + 1 + ww
        end
      end
      if cur ~= "" then
        out[#out + 1] = cur
      end
    end
  end
  return out
end

-- light inline markdown: `code`, **bold**, *italic*, ~~strike~~, and [text](url)
-- links — markers stripped, styled spans returned as { text, hl } chunks. One
-- earliest-match scan per position: every span pattern is probed (in a fixed
-- order — code, bold, italic, strike, link) and the SMALLEST start position wins;
-- a tie goes to whichever was probed earlier in that order, which is what makes
-- **bold** win over the *italic* pattern spuriously matching one character in (the
-- italic scan alone would read "**bold**" as "*bold*" starting at its second `*`).
-- *italic* additionally requires a non-space, non-`*` character touching each
-- delimiter — this is what keeps a spaced-out "2 * 3 = 6" from ever opening a span.
-- Links render as TEXT ONLY, styled with S.link — the URL is dropped from the
-- RENDERED copy (same as markview's conceal); the stored turn text keeps it.
-- S = { code, bold, italic, strike, link } highlight group names; `base` is the
-- surrounding text's hl (unstyled runs, and any style's fallback if unset in S).
local function md_chunks(line, base, S)
  S = S or {}
  local out, pos, n = {}, 1, #line
  while pos <= n do
    local best -- { s, e, hl, text }
    local function consider(s, e, hl, text)
      if s and (not best or s < best.s) then
        best = { s = s, e = e, hl = hl, text = text }
      end
    end
    local cs, ce = line:find("`[^`]+`", pos) -- `code`
    consider(cs, ce, S.code or base, cs and line:sub(cs + 1, ce - 1))
    local bs, be = line:find("%*%*[^*]+%*%*", pos) -- **bold**
    consider(bs, be, S.bold or base, bs and line:sub(bs + 2, be - 2))
    local is1, ie1 = line:find("%*[^%s*]%*", pos) -- *x* (1-char content)
    local is2, ie2 = line:find("%*[^%s*][^*]-[^%s*]%*", pos) -- *xy...z* (2+-char content)
    local is, ie = is1, ie1
    if is2 and (not is or is2 < is) then
      is, ie = is2, ie2
    end
    consider(is, ie, S.italic or base, is and line:sub(is + 1, ie - 1))
    local ss, se = line:find("~~[^~]+~~", pos) -- ~~strike~~
    consider(ss, se, S.strike or base, ss and line:sub(ss + 2, se - 2))
    local lks, lke, ltext = line:find("%[([^%]]+)%]%([^%)]+%)", pos) -- [text](url)
    consider(lks, lke, S.link or base, ltext)

    if not best then
      out[#out + 1] = { line:sub(pos), base }
      break
    end
    if best.s > pos then
      out[#out + 1] = { line:sub(pos, best.s - 1), base }
    end
    out[#out + 1] = { best.text, best.hl }
    pos = best.e + 1
  end
  if #out == 0 then
    out = { { line, base } }
  end
  return out
end

-- POST-PASS over one md_chunks() call's output: re-styles valid @mention slices
-- (S.mention) inside chunks whose hl is exactly `base` — i.e. plain unstyled text
-- only; a chunk already carrying S.code/bold/italic/strike/link is left alone byte
-- for byte, so a mention inside `code spans` or **bold** stays styled as that, never
-- re-tagged as a mention. Splits a matching chunk into up to 3 pieces (before /
-- mention / after) but never changes the concatenated text — every input byte is
-- re-emitted in exactly one output chunk, which is what keeps clip_chunks/wrap's
-- width math (computed on the ORIGINAL md_chunks output elsewhere) still valid
-- here: this only ever SPLITS a chunk, never trims or pads it.
-- `prev_char` is the last byte of whatever text preceded THIS chunk list in the
-- source line (nil when this is genuinely the line's own start) — needed because
-- is_boundary for a mention at column 0 of chunk N must see the last character of
-- chunk N-1, not fall back to "line start" just because it's chunk-relative column 0.
local function style_mentions(chunks, base, S)
  if not S.mention then
    return chunks
  end
  local out, prev_char = {}, nil
  for _, ch in ipairs(chunks) do
    local text, hl = ch[1], ch[2]
    if hl ~= base or not text:find("@", 1, true) then
      out[#out + 1] = ch
    else
      local pos = 1
      for _, m in ipairs(mention._scan(text, prev_char)) do
        local s, e = m[1] + 1, m[2] -- 1-based inclusive slice of `text`
        if s > pos then
          out[#out + 1] = { text:sub(pos, s - 1), hl }
        end
        out[#out + 1] = { text:sub(s, e), S.mention }
        pos = e + 1
      end
      if pos <= #text then
        out[#out + 1] = { text:sub(pos), hl }
      end
    end
    if #text > 0 then
      prev_char = text:sub(-1)
    end
  end
  return out
end

-- Bakes a content row's bar + chunks + right-pad into the old flat virt_lines chunk
-- list (the format render.lua's band pipeline consumes). Internal to the M.to_virt_lines
-- serializer only — thread.build itself returns STRUCTURED rows (see below); nothing
-- else bakes a bar/pad chunk into a row's content anymore.
local function row(bar_hl, content, bg_hl, width)
  local barstr = barchar() .. " "
  local r = { { barstr, bar_hl } }
  local used = vim.fn.strdisplaywidth(barstr)
  for _, c in ipairs(content) do
    -- a FRESH { text, hl } pair, not the structured chunk itself: a chunk table
    -- carries a named `role` key alongside its [1]/[2] array slots, and nvim's
    -- lua->api conversion for virt_lines rejects a table that mixes integer and
    -- string keys ("Cannot convert given Lua table" — it can no longer tell the
    -- table is a list). role is a build()/panel._rows_to_chat concern only; the
    -- virt_lines API never sees it.
    r[#r + 1] = { c[1], c[2] }
    used = used + vim.fn.strdisplaywidth(c[1])
  end
  if used < width then
    r[#r + 1] = { string.rep(" ", width - used), bg_hl }
  end
  return r
end

-- STRUCTURED row constructors — thread.build's actual output shape. No bar chunk,
-- no right-padding chunk: those are baked in by the serializers (M.to_virt_lines for
-- the read-only band; panel._rows_to_chat for the real-text chat buffer). `chunks`
-- entries keep chunk[1]=text, chunk[2]=hl positional (so downstream indexing stays
-- natural) plus a named `role` field ("header"|"meta"|"body"|"code"|"tag") that
-- drives external-renderer (markview/treesitter) body-dropping in _rows_to_chat.
local function content_row(rows, agent, bar_hl, bg_hl, chunks)
  rows[#rows + 1] = { kind = "content", agent = agent, bar_hl = bar_hl, bg_hl = bg_hl, chunks = chunks }
end

local function rule_row(rows, agent, char, bar_hl, rule_hl)
  rows[#rows + 1] = { kind = "rule", agent = agent, char = char, bar_hl = bar_hl, rule_hl = rule_hl }
end

-- Tag every chunk in `chunks` with `role` (mutates in place) and returns it, so
-- call sites can inline it: content_row(rows, agent, bar, bg, mark_role(chunks, "body")).
local function mark_role(chunks, role)
  for _, ch in ipairs(chunks) do
    ch.role = role
  end
  return chunks
end

-- Treesitter-highlight a fenced code block for the inline band (virt_lines can't run
-- a real highlighter, so we tokenize the block ourselves). Returns a per-line list of
-- {text, hl} chunks where hl = { code_hl, "@capture" } — the code_hl keeps the code-box
-- bg under the token's theme colour. Returns nil (→ caller falls back to monotone) for
-- any language without a parser/query, or on any error. Everything is pcall-guarded.
local function ts_chunks_uncached(code_lines, lang, code_hl)
  local has_ts = vim.treesitter and vim.treesitter.get_string_parser and vim.treesitter.query
  if not has_ts then
    return nil
  end
  local norm = (vim.treesitter.language.get_lang and vim.treesitter.language.get_lang(lang)) or lang
  local src = table.concat(code_lines, "\n")
  local okp, parser = pcall(vim.treesitter.get_string_parser, src, norm)
  if not okp or not parser then
    return nil
  end
  local okq, query = pcall(vim.treesitter.query.get, norm, "highlights")
  if not okq or not query then
    return nil
  end
  local cols = {} -- [0-based row] -> { [0-based byte col] = "@capture" } (last wins)
  local ok = pcall(function()
    local trees = parser:parse()
    local root = trees and trees[1] and trees[1]:root()
    if not root then
      return
    end
    for id, node in query:iter_captures(root, src, 0, -1) do
      local name = query.captures[id]
      if name and name:sub(1, 1) ~= "_" then
        local sr, sc, er, ec = node:range()
        for r = sr, math.min(er, #code_lines - 1) do
          local line = code_lines[r + 1] or ""
          local from = (r == sr) and sc or 0
          local to = (r == er) and ec or #line
          cols[r] = cols[r] or {}
          for c = from, to - 1 do
            cols[r][c] = "@" .. name
          end
        end
      end
    end
  end)
  if not ok then
    return nil
  end
  local out = {}
  for i, line in ipairs(code_lines) do
    local r, chunks, c, n = i - 1, {}, 0, #line
    while c < n do
      local hl = cols[r] and cols[r][c]
      local j = c + 1
      while j < n and (cols[r] and cols[r][j]) == hl do
        j = j + 1
      end
      chunks[#chunks + 1] = { line:sub(c + 1, j), hl and { code_hl, hl } or code_hl }
      c = j
    end
    out[i] = #chunks > 0 and chunks or { { "", code_hl } }
  end
  return out
end

-- Bounded content-keyed memoization: a streaming code block grows by one key per
-- delta (its text changes every frame), so this is a cache with a hard cap, not an
-- unbounded map. code_hl is PART of the key — the you/agent bubble tint is baked
-- into the cached chunks' hl, so the same code text quoted in both a you-turn and
-- an agent-turn must not share an entry (it would paint the other bubble's tint).
-- NEVER cache a nil result — a missing parser/transient failure must retry every
-- call, not wedge into a permanent miss. clip_chunks (below) never MUTATES a chunk
-- table it's handed — on the "fits" branch it copies the chunk REFERENCE into a new
-- output array, only allocating a fresh table for the truncated boundary chunk — so
-- a cached chunk table can be safely shared across many rows/builds. M._ts_stats is
-- a test seam (thread_spec asserts hits > 0 on a second build of the same code text).
local ts_cache = {}
local ts_cache_n = 0
M._ts_stats = { hits = 0, misses = 0 }

local function ts_chunks(code_lines, lang, code_hl)
  if not lang or lang == "" or #code_lines == 0 then
    return nil
  end
  local key = lang .. "\0" .. tostring(code_hl) .. "\0" .. table.concat(code_lines, "\n")
  local cached = ts_cache[key]
  if cached ~= nil then
    M._ts_stats.hits = M._ts_stats.hits + 1
    return cached
  end
  M._ts_stats.misses = M._ts_stats.misses + 1
  local out = ts_chunks_uncached(code_lines, lang, code_hl)
  if out ~= nil then
    if ts_cache_n >= 64 then
      ts_cache = {} -- reset BEFORE storing, don't evict piecemeal: keeps memory flat
      ts_cache_n = 0 -- under streaming, and the entry that crossed the cap survives
    end
    ts_cache[key] = out
    ts_cache_n = ts_cache_n + 1
  end
  return out
end

-- Truncate a chunk list to a display width (the inline band doesn't wrap code).
-- Never mutates its input chunk tables (see ts_chunks' cache-sharing note above).
-- The boundary cut is by DISPLAY cells, not characters: strcharpart counts chars,
-- and `room` chars of CJK/emoji can be ~2×`room` cells — an over-wide clip here
-- used to blow past maxw and (via the table renderer's second whole-row clip)
-- could even eat the row's closing wall.
local function clip_chunks(chunks, maxw)
  local out, used = {}, 0
  for _, ch in ipairs(chunks) do
    local w = vim.fn.strdisplaywidth(ch[1])
    if used + w <= maxw then
      out[#out + 1] = ch
      used = used + w
    else
      local room = maxw - used - 1
      local cut = ""
      if room > 0 then
        cut = vim.fn.strcharpart(ch[1], 0, room) -- chars ≥ cells: start high, shave down
        while cut ~= "" and vim.fn.strdisplaywidth(cut) > room do
          cut = vim.fn.strcharpart(cut, 0, vim.fn.strchars(cut) - 1)
        end
      end
      out[#out + 1] = { cut .. "…", ch[2] }
      break
    end
  end
  return out
end

-- Builds ONE turn's header chunk list (the row right after the divider): the
-- author name/status on turn 1, the range label + optional #tag on turn 1, and the
-- trailing "· draft" marker on an unsent turn. Pure extraction from the old build()
-- loop — identical strings/hls/ordering, just named and given a `role` per chunk.
local function turn_header(comment, t, i, is_last, status, agent)
  local header
  if agent then
    header = { { "agent ↩", "ObelusReplyHeader", role = "header" } }
  else
    header = { { t.author or "you", "ObelusThreadHeader", role = "header" } }
    if i == 1 then
      if status == "resolved" then
        header[#header + 1] = { "  ✓", "ObelusReplyHeader", role = "header" }
      elseif status == "needs_response" then
        header[#header + 1] = { "  ⚑ needs response", "ObelusReplyHeader", role = "header" }
      end
      header[#header + 1] = { "  " .. format.range_label(comment), "ObelusThreadMeta", role = "meta" }
      if comment.tag and comment.tag ~= "" then
        header[#header + 1] = { "  #" .. comment.tag, "ObelusThreadTag", role = "tag" }
      end
    end
    -- the trailing "you" turn is the UNSENT draft (a new comment, or a reply you're writing):
    -- mark it "· draft" until it's dispatched, so it reads as editable rather than sent
    if is_last and not comment.dispatching then
      header[#header + 1] = { "  · draft", "ObelusThreadMeta", role = "meta" }
    end
  end
  return header
end

-- table detection -----------------------------------------------------------
-- Shared shape between pad_table_edges (external-mode blank-line padding, below)
-- and the builtin table-box detector in body_rows' md path: a row of `| cell |
-- cell |`, and a GFM alignment separator of only `-`, `:`, `|`, and spaces.
local function is_table_row(l)
  return l:match("^%s*|.*|%s*$") ~= nil
end
local function is_table_sep(l)
  return l:match("^%s*|[%s:%-|]+|%s*$") ~= nil
end

-- Preferred content width for a comment's whole conversation — the SOURCE-derived
-- sizing panel.fit_rooted/preview_base_width grow-or-shrink the popup to (see those
-- for the recipe). Measured at the SOURCE (the turns' raw stored text), never the
-- rendered chat buffer: rendered lines are already wrapped to the CURRENT window
-- width, so measuring THEM oscillates (shrink -> rebuild narrower -> lines rewrap ->
-- shrink again). Source text is width-independent: STABLE across refits.
--
-- Same fence/table walk as pad_table_edges/body_rows above (duplicated, not shared —
-- those two build OUTPUT rows; this only measures, so it skips their line-splicing).
-- Returns two widths:
--   hard_w — max display width over lines INSIDE a fenced code block or a table row
--            (is_table_row/is_table_sep): content that cannot rewrap without visual
--            damage (broken columns, mis-highlighted code), so it may push the popup
--            past the comfort base, up to the editor cap.
--   soft_w — max display width over every other (prose) line: prose wraps fine, so
--            the caller caps it at the comfort base instead of letting it grow the
--            popup (an unbroken long word/URL still wraps — just not at a word
--            boundary — so it's deliberately NOT hard content).
function M.pref_width(comment)
  local store = require("obelus.store")
  local hard_w, soft_w = 0, 0
  if not comment then
    return hard_w, soft_w
  end
  for _, t in ipairs(store.turns(comment)) do
    local lines = vim.split(t.text or "", "\n", { plain = true })
    local fence = nil -- backtick count of the OPEN fence (nil = not in a code block)
    local li, ln = 1, #lines
    while li <= ln do
      local raw = lines[li]
      local bt = raw:match("^%s*(`+)")
      if bt and #bt >= 3 and not fence then
        fence = #bt -- OPEN fence
        hard_w = math.max(hard_w, vim.fn.strdisplaywidth(raw))
        li = li + 1
      elseif fence and bt and #bt >= fence and raw:match("^%s*`+%s*$") then
        fence = nil -- CLOSE fence (bare backticks, at least as long as the open)
        hard_w = math.max(hard_w, vim.fn.strdisplaywidth(raw))
        li = li + 1
      elseif fence then
        hard_w = math.max(hard_w, vim.fn.strdisplaywidth(raw)) -- inside the block
        li = li + 1
      elseif is_table_row(raw) and li < ln and is_table_sep(lines[li + 1]) then
        hard_w = math.max(hard_w, vim.fn.strdisplaywidth(raw), vim.fn.strdisplaywidth(lines[li + 1]))
        li = li + 2
        while li <= ln and is_table_row(lines[li]) do
          hard_w = math.max(hard_w, vim.fn.strdisplaywidth(lines[li]))
          li = li + 1
        end
      else
        soft_w = math.max(soft_w, vim.fn.strdisplaywidth(raw))
        li = li + 1
      end
    end
  end
  return hard_w, soft_w
end

-- With the scoped markview render (tables.use_virt_lines=false), markview draws a
-- table's top/bottom border on the REAL blank lines around it — a table hugging
-- text silently loses those borders. obelus owns the markdown it hands to the
-- external renderer, so normalize the RENDERED copy here (never the stored text):
-- insert a blank line before/after any table block that doesn't already have one.
-- Fence-aware (mirrors body_rows' own `+` open/close rules) so a `|`-table inside a
-- fenced code sample is left untouched. REVERT: delete this function and its one
-- call site to restore raw pass-through.
local function pad_table_edges(lines)
  local out = {}
  local fence = nil -- backtick count of the OPEN fence (nil = not in a code block)
  local i, n = 1, #lines
  while i <= n do
    local raw = lines[i]
    local bt = raw:match("^%s*(`+)")
    if bt and #bt >= 3 and not fence then
      fence = #bt -- OPEN fence
      out[#out + 1] = raw
      i = i + 1
    elseif fence and bt and #bt >= fence and raw:match("^%s*`+%s*$") then
      fence = nil -- CLOSE fence (bare backticks, at least as long as the open)
      out[#out + 1] = raw
      i = i + 1
    elseif fence then
      out[#out + 1] = raw -- inside the block: never a table
      i = i + 1
    elseif is_table_row(raw) and i < n and is_table_sep(lines[i + 1]) then
      -- pad BEFORE when the preceding line is non-blank — INCLUDING when the table
      -- is the turn's very first line (#out == 0): the buffer row above it is then
      -- the turn's "agent ↩" header row, and markview would draw the table's top
      -- border overlay ONTO the header, shoving it to the right of the box
      if #out == 0 or out[#out] ~= "" then
        out[#out + 1] = ""
      end
      out[#out + 1] = raw
      out[#out + 1] = lines[i + 1]
      i = i + 2
      while i <= n and is_table_row(lines[i]) do
        out[#out + 1] = lines[i]
        i = i + 1
      end
      -- pad AFTER symmetrically — a table as the turn's LAST line would otherwise
      -- get its bottom border drawn on the next turn's header (or divider) row
      if i > n or lines[i] ~= "" then
        out[#out + 1] = ""
      end
    else
      out[#out + 1] = raw
      i = i + 1
    end
  end
  return out
end

-- builtin table box + list helpers ------------------------------------------

-- Wraps a list/task/ordered line's remainder to (inner - leadw) once a marker has
-- claimed `leadw` display cells, so a wrapped continuation lines up under the
-- first line's TEXT instead of rejoining at column 0. `marker` prefixes the FIRST
-- piece only; every later piece gets `leadw` plain spaces instead.
-- A marker so wide it would squeeze the hang-wrap below the same 12-cell floor
-- `inner` itself uses (a deeply nested bullet in a sliver-narrow band) falls back
-- to the plain collapse-and-wrap — bounded output beats preserved indentation
-- there; the marker glyph itself still survives (wrap keeps non-space tokens).
local function wrap_hanging(marker, remainder, inner, leadw)
  if leadw <= 0 or leadw > math.max(inner - 12, 0) then
    return wrap(marker .. remainder, inner)
  end
  local pieces = wrap(remainder, inner - leadw)
  if #pieces == 0 then
    pieces = { "" }
  end
  local out = { marker .. pieces[1] }
  for i = 2, #pieces do
    out[#out + 1] = string.rep(" ", leadw) .. pieces[i]
  end
  return out
end

-- A line of only -/*/_ (3+, optional surrounding space): a Markdown horizontal
-- rule. Checked only outside fences/tables (see body_rows' dispatch order).
local function is_hr(l)
  return l:match("^%s*%-%-%-+%s*$") ~= nil or l:match("^%s*%*%*%*+%s*$") ~= nil or l:match("^%s*___+%s*$") ~= nil
end

-- Splits one GFM table row into trimmed cells. NOT a naive split on `|`: a pipe
-- inside a backtick code span (`` `a|b` ``) is cell CONTENT per GFM, and `\|` is
-- the GFM escape for a literal pipe — a raw split would cut the code span in half
-- and silently drop trailing cells (real content loss in a review tool). An
-- unbalanced backtick degrades to "the rest of the row is one cell", which still
-- loses no text. Drops the leading/trailing EMPTY field the outer pipes produce
-- (a malformed row missing an outer pipe on one side degrades gracefully).
local function table_cells(l)
  local parts, cur = {}, {}
  local in_code = false
  local i, n = 1, #l
  while i <= n do
    local ch = l:sub(i, i)
    if ch == "\\" and l:sub(i + 1, i + 1) == "|" then
      cur[#cur + 1] = "|" -- GFM escaped pipe: literal cell content
      i = i + 2
    elseif ch == "`" then
      in_code = not in_code
      cur[#cur + 1] = ch
      i = i + 1
    elseif ch == "|" and not in_code then
      parts[#parts + 1] = table.concat(cur)
      cur = {}
      i = i + 1
    else
      cur[#cur + 1] = ch
      i = i + 1
    end
  end
  parts[#parts + 1] = table.concat(cur)
  if parts[1] and parts[1]:match("^%s*$") then
    table.remove(parts, 1)
  end
  if parts[#parts] and parts[#parts]:match("^%s*$") then
    table.remove(parts, #parts)
  end
  for i2, p in ipairs(parts) do
    parts[i2] = p:match("^%s*(.-)%s*$")
  end
  return parts
end

-- Parses a detected table block (header row, GFM separator row, then body rows —
-- see the two-line lookahead in body_rows) into header/body cells + per-column
-- alignment from the separator's colons (:--- left, ---: right, :--: center; no
-- colons defaults left).
local function parse_table(block)
  local header = table_cells(block[1])
  local aligns = {}
  for i, seg in ipairs(table_cells(block[2])) do
    local l, r = seg:match("^(:?)%-*(:?)$")
    if l == ":" and r == ":" then
      aligns[i] = "center"
    elseif r == ":" then
      aligns[i] = "right"
    else
      aligns[i] = "left"
    end
  end
  local body = {}
  for i = 3, #block do
    body[#body + 1] = table_cells(block[i])
  end
  return header, aligns, body
end

-- Widest-first column shrink, shared by table_block_rows (styled/rendered cell
-- widths, builtin renderer) and fit_one_table below (raw markdown cell widths,
-- markview-mode source fitting). Repeatedly takes one cell off the CURRENT widest
-- column until `chrome + sum(widths)` fits `target`, or every column has hit the
-- 3-cell floor — whichever comes first (a still-too-wide result is a real, expected
-- outcome: table_block_rows falls back to its whole-row clip_chunks safety net;
-- fit_table_cells just ships the best-effort fit — see its own note). Mutates
-- `widths` in place; returns the final total for callers that want it.
local function shrink_col_widths(widths, ncol, chrome, target)
  local FLOOR = 3
  local total = chrome
  for _, w in ipairs(widths) do
    total = total + w
  end
  while total > target do
    local wi, wv = 1, widths[1]
    for i = 2, ncol do
      if widths[i] > wv then
        wi, wv = i, widths[i]
      end
    end
    if wv <= FLOOR then
      break -- every column is at (or under) the floor — stop; caller's own fallback applies
    end
    widths[wi] = wv - 1
    total = total - 1
  end
  return total
end

-- Shrinks + rebuilds ONE over-wide table BLOCK's raw markdown lines to fit `budget`
-- display cells per row, preserving each column's separator alignment colons.
-- Column widths are the RAW cell text's display width (unlike table_block_rows,
-- there's no styled/markers-stripped measurement available here — this runs on
-- markdown text markview hasn't parsed yet). Truncation is plain TEXT truncation
-- (vim.fn.strcharpart), not clip_chunks: a cut markdown span (an unclosed `` ` `` or
-- `**`) can leave a stray marker dangling in that one cell — acceptable, since
-- markview reparses this text fresh on every render (a stray marker degrades just
-- that cell's styling, it doesn't corrupt the table or leak into neighbours).
-- markview's RENDERED table row is wider than the raw text, in two ways measured
-- empirically: (1) ~1 structural cell per column plus the corner overhang
-- (plain-text tables: min no-wrap margin = ncol + 1 across ncol 2..6), and
-- (2) markview RECOUPS concealed marker cells as alignment padding — a row whose
-- cells hide `backticks` renders narrower, so markview pads it (and its
-- neighbours) up to per-column maxima that can exceed even the WIDEST raw row
-- (measured 75 rendered vs 67 max-raw on a 3-column marker-heavy table). The fit
-- must budget for the RENDERED width or the fitted table still wraps; biased
-- generous because an over-shrunk table is cosmetic while an under-shrunk one
-- wraps and breaks the whole box.
local function mv_table_margin(ncol)
  return 2 * ncol + 4 -- ncol+1 structural + ~2 conceal-recoup cells per column + slack
end

local function fit_one_table(block, budget)
  local header, _, body = parse_table(block)
  local ncol = #header
  local widths = {}
  for i = 1, ncol do
    local w = vim.fn.strdisplaywidth(header[i] or "")
    for _, r in ipairs(body) do
      w = math.max(w, vim.fn.strdisplaywidth(r[i] or ""))
    end
    widths[i] = w
  end
  local chrome = 3 * ncol + 1 -- "| " + " | " + " |" — same chrome shape as table_block_rows
  shrink_col_widths(widths, ncol, chrome, budget - mv_table_margin(ncol))

  -- Truncate-only, NO padding: markview aligns columns itself, measuring cells by
  -- their MARKER-STRIPPED width (it conceals `code` backticks, ** markers, …).
  -- Padding by RAW width here skewed that math — rows containing concealed markers
  -- rendered narrower than plain rows, so their side walls drifted out of line
  -- (the broken vertical bars in mixed prose/code tables). Unpadded cells are also
  -- strictly narrower raw text, so the no-wrap budget still holds.
  local function fit_cell(text, w)
    if vim.fn.strdisplaywidth(text) <= w then
      return text
    end
    -- truncate by DISPLAY width, not chars: strcharpart counts characters, and a
    -- CJK/emoji cell cut to w-1 CHARS can still be ~2(w-1) CELLS wide — the row
    -- would physically wrap, which is the exact markview breakage this exists to
    -- prevent. Shave chars until the display width fits.
    local cut = vim.fn.strcharpart(text, 0, math.max(w - 1, 0))
    while cut ~= "" and vim.fn.strdisplaywidth(cut) > math.max(w - 1, 0) do
      cut = vim.fn.strcharpart(cut, 0, vim.fn.strchars(cut) - 1)
    end
    -- a cut that landed INSIDE a `code` span leaves an odd backtick — the unclosed
    -- span shows its raw backtick and skews markview's per-cell measurement. Close
    -- it (one extra raw cell, covered by mv_table_margin's slack).
    local _, ticks = cut:gsub("`", "")
    if ticks % 2 == 1 then
      cut = cut .. "`"
    end
    return cut .. "…"
  end

  -- table_cells UNESCAPED any `\|` to a literal pipe when parsing; re-emitting that
  -- bare pipe would split the rebuilt row into extra columns on markview's reparse.
  -- Re-escape pipes OUTSIDE code spans (a `|` inside backticks is literal per GFM
  -- and escaping it there would render the backslash).
  local function escape_bare_pipes(text)
    local out, in_code = {}, false
    for i = 1, #text do -- byte-wise is fine: ` and | are ASCII
      local ch = text:sub(i, i)
      if ch == "`" then
        in_code = not in_code
      end
      if ch == "|" and not in_code then
        out[#out + 1] = "\\|"
      else
        out[#out + 1] = ch
      end
    end
    return table.concat(out)
  end

  local function build_row(cells)
    local parts = {}
    for i = 1, ncol do
      parts[#parts + 1] = escape_bare_pipes(fit_cell(cells[i] or "", widths[i]))
    end
    return "| " .. table.concat(parts, " | ") .. " |"
  end

  -- rebuild the separator preserving each column's OWN alignment colons (":---",
  -- "---:", ":--:") at the new width — read straight off the raw separator segments
  -- rather than parse_table's aligns (which collapses ":---" and plain "---" to the
  -- same "left", losing exactly the distinction this has to preserve).
  local function build_sep()
    local segs = table_cells(block[2])
    local parts = {}
    for i = 1, ncol do
      local seg = segs[i] or ""
      local l = seg:match("^:") ~= nil
      local r = seg:match(":$") ~= nil
      local dashes = math.max(widths[i] - (l and 1 or 0) - (r and 1 or 0), 1)
      parts[#parts + 1] = (l and ":" or "") .. string.rep("-", dashes) .. (r and ":" or "")
    end
    return "| " .. table.concat(parts, " | ") .. " |"
  end

  local out = { build_row(header), build_sep() }
  for _, r in ipairs(body) do
    out[#out + 1] = build_row(r)
  end
  return out
end

-- markview-mode ONLY (md == false, called from body_rows right after
-- pad_table_edges): fixes a table row that would otherwise physically WRAP when
-- displayed. markview's wrap-bracketed render (panel.lua's mv_render_scoped) only
-- lies about `wrap` for the DURATION of its own synchronous render call — the real
-- window still has wrap=true afterward, and an over-wide row wraps at that point,
-- which breaks markview's table box (its own source: wrap breaks table rendering).
-- obelus already owns the RENDERED markdown copy handed to markview (same precedent
-- as pad_table_edges above), so pre-shrink any table block whose rows exceed
-- `budget` on OUR copy before markview ever sees it: same widest-first shrink as
-- table_block_rows (the builtin renderer), applied to raw text instead of styled
-- chunks. Fence-aware, same open/close rules as pad_table_edges — duplicated here
-- rather than factored out, so pad_table_edges' already-pinned behaviour can't be
-- disturbed by a shared-helper change; see that function's fence walk for the
-- identical shape. REVERT: delete this function (+ fit_one_table/shrink_col_widths
-- above, if unused elsewhere) and its one call site in body_rows.
--
-- Idempotence is load-bearing, not just tidy: this runs on EVERY fill of EVERY
-- markview turn (not once), so a narrow table (every row already <= budget) MUST
-- come back byte-identical — any rewrite of an already-fitting table would show up
-- as visible per-frame churn even though nothing changed.
local function fit_table_cells(lines, budget)
  local out = {}
  local fence = nil -- backtick count of the OPEN fence (nil = not in a code block)
  local i, n = 1, #lines
  while i <= n do
    local raw = lines[i]
    local bt = raw:match("^%s*(`+)")
    if bt and #bt >= 3 and not fence then
      fence = #bt
      out[#out + 1] = raw
      i = i + 1
    elseif fence and bt and #bt >= fence and raw:match("^%s*`+%s*$") then
      fence = nil
      out[#out + 1] = raw
      i = i + 1
    elseif fence then
      out[#out + 1] = raw
      i = i + 1
    elseif is_table_row(raw) and i < n and is_table_sep(lines[i + 1]) then
      local block = { raw, lines[i + 1] }
      i = i + 2
      while i <= n and is_table_row(lines[i]) do
        block[#block + 1] = lines[i]
        i = i + 1
      end
      -- the fits-check must use the same ncol-aware threshold fit_one_table fits
      -- to: markview's RENDERED row is ~ncol+1 cells wider than the raw text, so a
      -- raw row at exactly `budget` would still wrap once rendered
      local threshold = budget - mv_table_margin(#table_cells(block[1]))
      local fits = true
      for _, l in ipairs(block) do
        if vim.fn.strdisplaywidth(l) > threshold then
          fits = false
          break
        end
      end
      if fits then
        for _, l in ipairs(block) do
          out[#out + 1] = l
        end
      else
        for _, l in ipairs(fit_one_table(block, budget)) do
          out[#out + 1] = l
        end
      end
    else
      out[#out + 1] = raw
      i = i + 1
    end
  end
  return out
end

-- One table cell: inline spans styled via md_chunks (code/bold/... work inside a
-- cell), padded to the column width with PLAIN spaces around the styled chunks,
-- per the separator row's alignment for this column. `width` can be SMALLER than
-- the cell's natural width — table_block_rows' widest-first shrink fits the whole
-- table to the available width by narrowing columns below what some cells need —
-- so an over-wide cell is ellipsized (clip_chunks, same as a truncated code line)
-- rather than left to blow out the column.
local function pad_cell(text, width, align, base_hl, S)
  local styled = md_chunks(text, base_hl, S)
  local w = 0
  for _, c in ipairs(styled) do
    w = w + vim.fn.strdisplaywidth(c[1])
  end
  if w > width then
    styled = clip_chunks(styled, width)
    w = 0
    for _, c in ipairs(styled) do
      w = w + vim.fn.strdisplaywidth(c[1])
    end
  end
  local room = math.max(width - w, 0)
  local padl, padr = 0, room
  if align == "right" then
    padl, padr = room, 0
  elseif align == "center" then
    padl = math.floor(room / 2)
    padr = room - padl
  end
  local out = {}
  if padl > 0 then
    out[#out + 1] = { string.rep(" ", padl), base_hl }
  end
  for _, c in ipairs(styled) do
    out[#out + 1] = c
  end
  if padr > 0 then
    out[#out + 1] = { string.rep(" ", padr), base_hl }
  end
  return out
end

-- Builtin (md=true) table renderer: turns a detected block into an aligned box.
-- Border/junction rows are OUR OWN chunks in meta_hl, so the bubble tint is
-- guaranteed underneath them whether the theme is opaque or transparent. Header
-- cells render in the turn's Bold hl, body cells in body_hl. Never wraps a row —
-- an overflowing row is clipped exactly like a code line (clip_chunks:
-- strcharpart + "…").
local function table_block_rows(rows_out, block, agent, bar, bg, meta_hl, body_hl, bold_hl, S, inner)
  local header, aligns, body = parse_table(block)
  local ncol = #header
  -- width measures the RENDERED (markers-stripped) cell text — the same measurement
  -- pad_cell pads against below — so a `**bold**` cell doesn't inflate its column by
  -- the four marker characters that never actually show up on screen.
  local function cell_w(text, base_hl)
    local w = 0
    for _, c in ipairs(md_chunks(text, base_hl, S)) do
      w = w + vim.fn.strdisplaywidth(c[1])
    end
    return w
  end
  local widths = {}
  for i = 1, ncol do
    local w = cell_w(header[i] or "", bold_hl)
    for _, r in ipairs(body) do
      w = math.max(w, cell_w(r[i] or "", body_hl))
    end
    widths[i] = w
  end

  -- Shrink columns to fit `inner` BEFORE laying out any row, so every emitted row
  -- (border/header/separator/body) shares the same fitted widths and the box's
  -- walls line up. Chrome = the "│ " lead + " │ " between columns + " │" trail
  -- data_row builds below: 2 + 3*(ncol-1) + 2 == 3*ncol + 1.
  local chrome = 3 * ncol + 1
  shrink_col_widths(widths, ncol, chrome, inner)
  -- Still too wide (every column already at the 3-cell floor): the final whole-row
  -- clip_chunks in emit() below is the last-resort safety net, same as before this
  -- change — a table box can still lose its right wall in that extreme case.

  local function border(l, mid, r)
    local parts = {}
    for i = 1, ncol do
      parts[#parts + 1] = string.rep("─", widths[i] + 2)
    end
    return { { l .. table.concat(parts, mid) .. r, meta_hl } }
  end

  local function data_row(cells, base_hl)
    local out = { { "│ ", meta_hl } }
    for i = 1, ncol do
      for _, ch in ipairs(pad_cell(cells[i] or "", widths[i], aligns[i], base_hl, S)) do
        out[#out + 1] = ch
      end
      out[#out + 1] = { i < ncol and " │ " or " │", meta_hl }
    end
    return out
  end

  local function emit(chunks)
    content_row(rows_out, agent, bar, bg, mark_role(clip_chunks(chunks, inner), "body"))
  end

  emit(border("╭", "┬", "╮"))
  emit(data_row(header, bold_hl))
  emit(border("├", "┼", "┤"))
  for _, r in ipairs(body) do
    emit(data_row(r, body_hl))
  end
  emit(border("╰", "┴", "╯"))
end

-- Appends ONE turn's body rows: either the in-box "thinking…" spinner (streaming
-- agent reply with no delta yet) or the fence/markdown/code walker that splits the
-- turn text into body/code content rows. Pure extraction from the old build() loop
-- — identical parsing/wrapping/highlighting, just appending structured rows instead
-- of baked chunk-lists. `live`/`spinner` come from opts (thread.build no longer
-- requires jobs/progress — see M.build).
local function body_rows(rows, t, agent, bar, bg, code, body_hl, meta_hl, md, inner, live, spinner)
  if agent and (t.text == nil or t.text == "") and live then
    -- streaming agent reply not yet started: spinner in the box
    content_row(rows, agent, bar, bg, { { spinner .. " thinking…", meta_hl, role = "meta" } })
    return
  end
  local bold = agent and "ObelusReplyBold" or "ObelusThreadBold"
  -- level 1/2 headers get the turn's accent-coloured Header hl; level 3+ stays Bold
  local header_hl = agent and "ObelusReplyHeader" or "ObelusThreadHeader"
  local italic = agent and "ObelusReplyItalic" or "ObelusThreadItalic"
  local strike = agent and "ObelusReplyStrike" or "ObelusThreadStrike"
  local link = agent and "ObelusReplyLink" or "ObelusThreadLink"
  local code_label_hl = agent and "ObelusReplyCodeLabel" or "ObelusThreadCodeLabel"
  local mention_hl = agent and "ObelusReplyMention" or "ObelusThreadMention"
  local S = { code = code, bold = bold, italic = italic, strike = strike, link = link, mention = mention_hl }
  local fence = nil -- backtick count of the OPEN fence (nil = not in a code block)
  local code_lang, code_buf = "", {} -- buffered block + its language, for treesitter
  local function flush_code()
    local hl = ts_chunks(code_buf, code_lang, code) -- per-line chunks, or nil
    for ci, cl in ipairs(code_buf) do
      local chunks = hl and hl[ci]
      if chunks then
        chunks = clip_chunks(chunks, inner)
      else
        local l = cl -- monotone fallback: verbatim, code-styled, truncated
        if vim.fn.strdisplaywidth(l) > inner then
          l = vim.fn.strcharpart(l, 0, inner - 1) .. "…"
        end
        chunks = { { l, code } }
      end
      -- language label: right-aligned on the block's FIRST row only, room permitting
      if ci == 1 and code_lang ~= "" then
        local used = 0
        for _, ch in ipairs(chunks) do
          used = used + vim.fn.strdisplaywidth(ch[1])
        end
        if used + #code_lang + 2 <= inner then
          chunks[#chunks + 1] = { string.rep(" ", inner - used - vim.fn.strdisplaywidth(code_lang) - 1), code }
          chunks[#chunks + 1] = { code_lang, code_label_hl }
        end
      end
      content_row(rows, agent, bar, code, mark_role(chunks, "code")) -- code bg fills the whole row
    end
    code_buf = {}
  end
  local lines = vim.split(sanitize(t.text) or "", "\n", { plain = true })
  if not md then
    -- external renderer (markview/treesitter): pad table blank-lines on OUR copy
    -- only — see pad_table_edges above. REVERT: delete this call to restore
    -- raw pass-through.
    lines = pad_table_edges(lines)
    -- then fit any over-wide table's COLUMNS to the render width — see
    -- fit_table_cells above. The per-block ncol-aware markview margin
    -- (mv_table_margin) is subtracted inside; pass the plain available width.
    lines = fit_table_cells(lines, inner)
  end
  local li, ln = 1, #lines
  while li <= ln do
    local raw = lines[li]
    local bt = md and raw:match("^%s*(`+)")
    if bt and #bt >= 3 and not fence then
      -- OPEN fence: remember its length so only a >= -length bare fence closes it
      -- (a 4-backtick block can contain literal ``` fences without closing early)
      fence = #bt
      code_lang = raw:match("^%s*`+%s*([%w_%-%+%.]+)") or ""
      li = li + 1
    elseif fence and bt and #bt >= fence and raw:match("^%s*`+%s*$") then
      flush_code() -- CLOSE fence (bare backticks, at least as long as the open)
      fence = nil
      li = li + 1
    elseif fence then
      code_buf[#code_buf + 1] = raw -- inside the block (incl. shorter literal fences)
      li = li + 1
    elseif md and is_table_row(raw) and li < ln and is_table_sep(lines[li + 1]) then
      -- Same two-line (header + separator) lookahead as pad_table_edges: a header
      -- row that has streamed in WITHOUT its separator yet (li == ln, nothing to
      -- look ahead at) simply fails this check and falls through to the plain-line
      -- branch below — it renders as a raw line for this frame, and the very next
      -- delta re-runs this check and "upgrades" it to a box once the separator
      -- lands. No separate streaming state needed.
      local block = { raw, lines[li + 1] }
      li = li + 2
      while li <= ln and is_table_row(lines[li]) do
        block[#block + 1] = lines[li]
        li = li + 1
      end
      table_block_rows(rows, block, agent, bar, bg, meta_hl, body_hl, bold, S, inner)
    elseif md and is_hr(raw) then
      content_row(rows, agent, bar, bg, mark_role({ { string.rep("─", inner), meta_hl } }, "body"))
      li = li + 1
    else
      -- per source line: lift # headers (level-aware hl), > quotes, task/ordered/
      -- bullet markers to their glyphs. leadw/marker_text/lead_chunk (list lines
      -- only) drive the hanging-indent wrap below.
      local lhl, line, leadw, lead_chunk, marker_text, remainder = body_hl, raw, 0, nil, nil, nil
      local hashes = md and raw:match("^(#+)%s+")
      if hashes then
        line, lhl = raw:gsub("^#+%s+", ""), (#hashes <= 2 and header_hl or bold)
      elseif md and raw:match("^%s*>%s?") then
        line, lhl = (raw:gsub("^%s*>%s?", "│ ")), meta_hl
      elseif md then
        local tindent, tmark = raw:match("^(%s*)[-*]%s+%[([ xX])%]%s+")
        local oindent, omark = raw:match("^(%s*)(%d+[%.%)])%s+")
        local bindent = raw:match("^(%s*)[-*]%s+")
        if tindent then
          -- task list: "- [ ] x" / "- [x] x" -> glyph + text, both body_hl (no
          -- strikethrough on a checked item — keep it readable)
          marker_text = tindent .. ((tmark == " ") and "☐" or "☑") .. " "
          remainder = raw:gsub("^%s*[-*]%s+%[[ xX]%]%s+", "")
          leadw = vim.fn.strdisplaywidth(marker_text)
        elseif oindent then
          -- ordered list: the marker ("1.") is its OWN meta_hl chunk; the rest
          -- goes through md_chunks like everything else
          lead_chunk = { oindent .. omark .. " ", meta_hl }
          leadw = vim.fn.strdisplaywidth(oindent .. omark .. " ")
          marker_text, remainder = "", raw:gsub("^%s*%d+[%.%)]%s+", "")
        elseif bindent then
          -- bullet: stays inline text (mirrors the pre-existing "-/* " -> "• ")
          marker_text = bindent .. "• "
          remainder = raw:gsub("^(%s*)[-*]%s+", "")
          leadw = vim.fn.strdisplaywidth(marker_text)
        end
      end
      -- when markview owns rendering (md=false) keep the raw line whole so it
      -- can wrap/parse it itself; in-house mode hard-wraps to the band width,
      -- with a hanging indent for list continuations (marker_text ~= nil)
      local pieces
      if md and marker_text ~= nil then
        pieces = wrap_hanging(marker_text, remainder, inner, leadw)
      else
        pieces = md and wrap(line, inner) or { line }
      end
      for pi, l in ipairs(pieces) do
        local chunks = md and md_chunks(l, lhl, S) or { { l, lhl } }
        -- builtin renderer only (md == true); markview owns styling in the other
        -- mode and can't be told about @ separately. Guard on "@" present before
        -- ever calling into style_mentions/M._scan — most lines have none.
        if md and l:find("@", 1, true) then
          chunks = style_mentions(chunks, lhl, S)
        end
        if lead_chunk and pi == 1 then
          local merged = { lead_chunk }
          for _, ch in ipairs(chunks) do
            merged[#merged + 1] = ch
          end
          chunks = merged
        end
        content_row(rows, agent, bar, bg, mark_role(chunks, "body"))
      end
      li = li + 1
    end
  end
  if fence then
    flush_code() -- a fenced block left open at the end of the turn
  end
end

---Build a comment's conversation as STRUCTURED rows (rule rows + content rows with
---per-chunk roles). Two thin serializers turn these into the old baked formats:
---M.to_virt_lines (the read-only inline/rooted band) and panel._rows_to_chat (the
---real-text chat buffer). Pure formatter — no transport/progress/jobs requires:
---opts.live (a job actually backs this dispatch) and opts.spinner (the current
---glyph) come from the caller (jobs.live(c) / progress.frame()).
---@param comment table
---@param width integer full text width of the window
---@param opts? table { markdown?: boolean, rules?: boolean, with_code?: boolean, hide_draft?: boolean, live?: boolean, spinner?: string }
function M.build(comment, width, opts)
  opts = opts or {}
  local store = require("obelus.store")
  local md = opts.markdown ~= false
  local rules = opts.rules ~= false
  local inner = math.max(12, width - 3)
  local status = comment.status or "open"
  local turns = store.turns(comment)
  local rows = {}
  local live = opts.live == true
  local spinner = opts.spinner or "⠋"

  -- one block per conversation turn (you / agent), oldest first
  for i, t in ipairs(turns) do
    -- when the reply box is open (hide_draft), the trailing draft lives IN the box, so don't
    -- render it in the history too; a read-only view (band / hover preview) still shows "· draft"
    if opts.hide_draft and i == #turns and t.author == "you" and not comment.dispatching then
      goto continue
    end
    local agent = t.author == "agent"
    local bar = agent and "ObelusReplyBar" or "ObelusThreadBar"
    local ruleN = agent and "ObelusReplyRuleN" or "ObelusThreadRuleN"
    local bg = agent and "ObelusReplyBg" or "ObelusThreadBg"
    local code = agent and "ObelusReplyCode" or "ObelusThreadCode"
    local body_hl = agent and "ObelusReplyText" or "ObelusThreadText"
    local meta_hl = agent and "ObelusReplyMeta" or "ObelusThreadMeta"

    -- divider before each turn: bar tick in the bright turn colour but NO bg (barN)
    -- so the bar stays one continuous line without a tinted square crossing the
    -- rule; the dashes are neutral so the bubble tint stops at the rule
    local barN = agent and "ObelusReplyBarN" or "ObelusThreadBarN"
    if rules then
      rule_row(rows, agent, i == 1 and "─" or "┄", barN, ruleN)
    end

    content_row(rows, agent, bar, bg, turn_header(comment, t, i, i == #turns, status, agent))

    -- the commented code snippet on the original comment (so a multi-line /
    -- partial selection is visible without the file, e.g. in the sidebar)
    if i == 1 and opts.with_code and comment.selected_text and #comment.selected_text > 0 then
      for _, l in ipairs(comment.selected_text) do
        local s = "▏ " .. l
        if vim.fn.strdisplaywidth(s) > inner then
          s = vim.fn.strcharpart(s, 0, inner - 1) .. "…" -- code: truncate, don't wrap
        end
        content_row(rows, agent, bar, bg, { { s, meta_hl, role = "meta" } })
      end
    end

    body_rows(rows, t, agent, bar, bg, code, body_hl, meta_hl, md, inner, live, spinner)
    ::continue::
  end

  -- standalone "thinking" spinner only when no agent turn has started yet (one-shot
  -- dispatch); streaming replies render their own in-box spinner on the empty agent
  -- turn, so we must NOT also show this once deltas make that turn non-empty
  local tail = turns[#turns]
  local spinning = live and not (tail and tail.author == "agent")
  if spinning then
    if rules then
      rule_row(rows, true, "┄", "ObelusReplyRuleN", "ObelusReplyRuleN")
    end
    content_row(
      rows,
      true,
      "ObelusReplyBar",
      "ObelusReplyBg",
      { { "agent ↩", "ObelusReplyHeader", role = "header" } }
    )
    content_row(
      rows,
      true,
      "ObelusReplyBar",
      "ObelusReplyBg",
      { { spinner .. " thinking…", "ObelusReplyMeta", role = "meta" } }
    )
  end

  if rules then
    local la = spinning or (tail and tail.author == "agent")
    rule_row(
      rows,
      la,
      "─",
      la and "ObelusReplyRuleN" or "ObelusThreadRuleN",
      la and "ObelusReplyRuleN" or "ObelusThreadRuleN"
    )
  end

  return rows
end

---Serialize thread.build's structured rows into the read-only band's baked
---virt_lines format (a flat { {text, hl}, ... } chunk list per row): the bar chunk
---first, then content, then a trailing pad chunk so the bubble bg fills the row.
---Byte-for-byte identical to the pre-refactor M.build output — render.lua's
---cap_rows/reply_anchor pagination math and the markview_spec-era behaviour both
---depend on this exact shape.
---@param rows table structured rows from M.build
---@param width integer full text width of the window (must match M.build's width)
function M.to_virt_lines(rows, width)
  local out = {}
  for _, r in ipairs(rows) do
    if r.kind == "rule" then
      -- "<bar> " (matching content rows) then dashes, so the rule aligns with the
      -- text column instead of starting one cell to its left
      out[#out + 1] = {
        { barchar() .. " ", r.bar_hl },
        { string.rep(r.char, math.max(width - 2, 1)), r.rule_hl },
      }
    else
      out[#out + 1] = row(r.bar_hl, r.chunks, r.bg_hl, width)
    end
  end
  return out
end

return M
