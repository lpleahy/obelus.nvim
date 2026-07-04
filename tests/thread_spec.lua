-- thread: the in-house (dependency-free) renderer used for bands, and as the
-- streaming/builtin body. thread.build returns STRUCTURED rows ({kind, agent,
-- bar_hl, bg_hl/rule_hl, chunks-with-role}); thread.to_virt_lines serializes them
-- into the old baked { {text, hl}, ... } chunk-list format render.lua's band
-- pipeline consumes.
T.describe("thread")

local function flatten(rows, width)
  local vl = require("obelus.thread").to_virt_lines(rows, width or 9999)
  local out = {}
  for _, row in ipairs(vl) do
    local s = ""
    for _, chunk in ipairs(row) do
      s = s .. (chunk[1] or "")
    end
    out[#out + 1] = s
  end
  return table.concat(out, "\n")
end

-- Exact per-row width bound, mirroring thread.lua's own arithmetic (build()'s
-- `inner = max(12, width - 3)` wrap cap, to_virt_lines' pad-to-`width`): a wrapped/
-- padded row can only exceed `width` if the bar gutter itself doesn't fit inside the
-- 3-cell margin `inner` reserves, so the bound is max(width, gutter + inner).
local function row_bound(width)
  local bar = (require("obelus.config").options.render or {}).bar or "▎"
  local gutter = vim.fn.strdisplaywidth(bar .. " ")
  local inner = math.max(12, width - 3)
  return math.max(width, gutter + inner)
end

T.it("build renders you/agent turns with headers and content", function()
  local ctx = T.fresh()
  local c = ctx.store.add(T.comment({ comment = "please fix this" }))
  ctx.store.add_turn(c.id, "agent", "done, see the diff")
  local rows = require("obelus.thread").build(ctx.store.get(c.id), 70, { markdown = true, rules = true })
  T.ok(#rows > 0, "rows produced")
  local text = flatten(rows, 70)
  T.contains(text, "you")
  T.contains(text, "agent")
  T.contains(text, "please fix this")
  T.contains(text, "done, see the diff")
end)

T.it("build strips zero-width chars and BOM but keeps other multibyte text", function()
  local ctx = T.fresh()
  local zwsp, zwnj, zwj, bom = "\226\128\139", "\226\128\140", "\226\128\141", "\239\187\191"
  local c = ctx.store.add(T.comment({ comment = "strip these" }))
  -- zero-width chars as the agent emits them (escaping nested ``` fences), plus
  -- en/em dashes that share the \226\128 lead bytes and must NOT be eaten
  ctx.store.add_turn(
    c.id,
    "agent",
    bom .. "fen" .. zwsp .. "ce" .. zwnj .. "d" .. zwj .. " a\226\128\147b \226\128\148 c"
  )
  local text = flatten(require("obelus.thread").build(ctx.store.get(c.id), 70, { markdown = true }))
  T.contains(text, "fenced a\226\128\147b \226\128\148 c")
  for _, bad in ipairs({ zwsp, zwnj, zwj, bom }) do
    T.ok(not text:find(bad, 1, true), "zero-width byte sequence survived render")
  end
end)

T.it("build wraps long body text to the given width", function()
  local ctx = T.fresh()
  local long = string.rep("word ", 60)
  local c = ctx.store.add(T.comment({ comment = long }))
  local rows = require("obelus.thread").build(ctx.store.get(c.id), 40, { markdown = true })
  local bound = row_bound(40)
  for _, row in ipairs(require("obelus.thread").to_virt_lines(rows, 40)) do
    local w = 0
    for _, chunk in ipairs(row) do
      w = w + vim.fn.strdisplaywidth(chunk[1] or "")
    end
    T.ok(w <= bound, "row within width bound (" .. bound .. "): " .. w)
  end
end)

T.it("build wraps CJK/emoji body text without exceeding the width bound", function()
  local ctx = T.fresh()
  -- wide (2-cell) glyphs, space-separated so wrap() still breaks at word bounds —
  -- exercises strdisplaywidth-based wrapping, not the raw byte/char length
  local long = string.rep("日本語テキスト🎉 ", 30)
  local c = ctx.store.add(T.comment({ comment = long }))
  local rows = require("obelus.thread").build(ctx.store.get(c.id), 40, { markdown = true })
  local bound = row_bound(40)
  for _, row in ipairs(require("obelus.thread").to_virt_lines(rows, 40)) do
    local w = 0
    for _, chunk in ipairs(row) do
      w = w + vim.fn.strdisplaywidth(chunk[1] or "")
    end
    T.ok(w <= bound, "row within width bound (" .. bound .. "): " .. w)
  end
end)

-- ---------------------------------------------------------------------------
-- to_virt_lines: the serializer's own shape guarantees
-- ---------------------------------------------------------------------------

T.it("to_virt_lines: every row's first chunk is the bar; a rule row's dashes fill width - 2", function()
  local ctx = T.fresh()
  local c = ctx.store.add(T.comment({ comment = "please fix this" }))
  ctx.store.add_turn(c.id, "agent", "done")
  local thread = require("obelus.thread")
  local width = 50
  local rows = thread.build(ctx.store.get(c.id), width, { markdown = true, rules = true })
  local vl = thread.to_virt_lines(rows, width)
  T.eq(#vl, #rows, "one virt_lines row per structured row")
  local bar = (require("obelus.config").options.render or {}).bar or "▎"
  local saw_rule = false
  for i, r in ipairs(rows) do
    T.eq(vl[i][1][1], bar .. " ", "row " .. i .. " starts with the bar chunk")
    T.eq(vl[i][1][2], r.bar_hl, "the bar chunk's hl matches the row's bar_hl")
    if r.kind == "rule" then
      saw_rule = true
      T.eq(vim.fn.strdisplaywidth(vl[i][2][1]), math.max(width - 2, 1), "rule dashes fill width - 2")
      T.eq(vl[i][2][2], r.rule_hl, "the dash chunk's hl matches the row's rule_hl")
    end
  end
  T.ok(saw_rule, "at least one rule row was produced (the leading turn-1 divider)")
end)

-- ---------------------------------------------------------------------------
-- structure: build's rows carry kind/agent and per-chunk roles
-- ---------------------------------------------------------------------------

T.it("build: structured rows carry kind/agent, and every chunk carries a known role", function()
  local ctx = T.fresh()
  local c = ctx.store.add(T.comment({ comment = "prose line\n```lua\nlocal x = 1\n```", tag = "bugfix" }))
  ctx.store.add_turn(c.id, "agent", "agent prose reply")
  local rows = require("obelus.thread").build(ctx.store.get(c.id), 60, { markdown = true, rules = true })

  local seen = { header = false, meta = false, body = false, code = false, tag = false }
  for _, r in ipairs(rows) do
    T.ok(r.kind == "rule" or r.kind == "content", "row.kind is rule or content")
    if r.kind == "rule" then
      T.ok(type(r.agent) == "boolean", "rule row has agent bool")
      T.ok(type(r.char) == "string", "rule row has a char")
      T.ok(type(r.bar_hl) == "string" and type(r.rule_hl) == "string", "rule row has bar_hl/rule_hl")
    else
      T.ok(type(r.agent) == "boolean", "content row has agent bool")
      T.ok(type(r.bar_hl) == "string" and type(r.bg_hl) == "string", "content row has bar_hl/bg_hl")
      for _, ch in ipairs(r.chunks) do
        T.ok(seen[ch.role] ~= nil, "chunk role is a known role, got " .. tostring(ch.role))
        seen[ch.role] = true
      end
    end
  end
  T.ok(seen.header, "a header-role chunk was seen (turn author name)")
  T.ok(seen.meta, "a meta-role chunk was seen (range label)")
  T.ok(seen.body, "a body-role chunk was seen (prose line)")
  T.ok(seen.code, "a code-role chunk was seen (fenced lua block)")
  T.ok(seen.tag, "a tag-role chunk was seen (#bugfix badge)")
end)

-- ---------------------------------------------------------------------------
-- purity: opts.live/opts.spinner drive the spinner — no progress/jobs dependency
-- ---------------------------------------------------------------------------

T.it("build is a pure formatter: opts.live/opts.spinner drive the spinner directly", function()
  local ctx = T.fresh()
  local c = ctx.store.add(T.comment({ comment = "please fix" }))
  ctx.store.add_turn(c.id, "agent", "") -- empty trailing agent turn: mid-stream, no delta yet

  local live_rows = require("obelus.thread").build(
    ctx.store.get(c.id),
    60,
    { markdown = true, rules = true, live = true, spinner = "X" }
  )
  T.contains(flatten(live_rows, 60), "X thinking…", "opts.spinner drives the glyph, not progress.frame()")

  local idle_rows =
    require("obelus.thread").build(ctx.store.get(c.id), 60, { markdown = true, rules = true, live = false })
  T.ok(not flatten(idle_rows, 60):find("thinking…", 1, true), "opts.live = false renders no spinner row")
end)

-- ---------------------------------------------------------------------------
-- ts_chunks memoization: a bounded content-keyed cache (thread_spec test seam)
-- ---------------------------------------------------------------------------

T.it("ts_chunks: rebuilding the same fenced code block reuses the memoized capture", function()
  local ctx = T.fresh()
  local c = ctx.store.add(T.comment({ comment = "```lua\nlocal x = 1\nreturn x + 1\n```" }))
  local thread = require("obelus.thread")
  local before = thread._ts_stats.hits
  thread.build(ctx.store.get(c.id), 60, { markdown = true, rules = true })
  thread.build(ctx.store.get(c.id), 60, { markdown = true, rules = true })
  T.ok(thread._ts_stats.hits > before, "the second build hit the ts_chunks cache")
end)

-- ---------------------------------------------------------------------------
-- PART 1 — pad_table_edges: external-mode (markdown=false) blank-line padding
-- around table blocks, so markview's virt-line borders don't land on real text.
-- ---------------------------------------------------------------------------

-- body-role row texts only (skips the turn header row and any rule rows), in the
-- order thread.build emitted them — used to inspect exactly which lines the
-- md==false pass-through (with pad_table_edges applied) produced.
local function body_texts(rows)
  local out = {}
  for _, r in ipairs(rows) do
    if r.kind == "content" and r.chunks[1] and r.chunks[1].role == "body" then
      local s = ""
      for _, ch in ipairs(r.chunks) do
        s = s .. (ch[1] or "")
      end
      out[#out + 1] = s
    end
  end
  return out
end

T.it("pad_table_edges: a table hugging text above/below gets a blank row on both sides", function()
  local ctx = T.fresh()
  local text = "above text\n| A | B |\n| --- | --- |\n| 1 | 2 |\nbelow text"
  local c = ctx.store.add(T.comment({ comment = text }))
  local rows = require("obelus.thread").build(ctx.store.get(c.id), 70, { markdown = false, rules = true })
  T.eq(
    body_texts(rows),
    { "above text", "", "| A | B |", "| --- | --- |", "| 1 | 2 |", "", "below text" },
    "blank rows inserted before and after the table block"
  )
end)

T.it("pad_table_edges: a table already surrounded by blanks is unchanged (idempotent)", function()
  local ctx = T.fresh()
  local text = "above text\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\nbelow text"
  local c = ctx.store.add(T.comment({ comment = text }))
  local rows = require("obelus.thread").build(ctx.store.get(c.id), 70, { markdown = false, rules = true })
  local want = vim.split(text, "\n", { plain = true })
  T.eq(body_texts(rows), want, "row count/content identical to the (already-padded) input")
end)

T.it("pad_table_edges: a piped 'table' inside a 4-backtick fence is not padded", function()
  local ctx = T.fresh()
  local text = "text\n````\n| a | b |\n| --- | --- |\n````\nmore"
  local c = ctx.store.add(T.comment({ comment = text }))
  local rows = require("obelus.thread").build(ctx.store.get(c.id), 70, { markdown = false, rules = true })
  local want = vim.split(text, "\n", { plain = true })
  T.eq(body_texts(rows), want, "fenced content passed through verbatim, no padding inserted")
end)

T.it("pad_table_edges: markdown=true path is untouched (no padding)", function()
  local ctx = T.fresh()
  local text = "above text\n| A | B |\n| --- | --- |\n| 1 | 2 |\nbelow text"
  local c = ctx.store.add(T.comment({ comment = text }))
  local rows = require("obelus.thread").build(ctx.store.get(c.id), 70, { markdown = true, rules = true })
  for _, s in ipairs(body_texts(rows)) do
    T.ok(s ~= "", "no blank body row was introduced in the markdown=true path: " .. vim.inspect(body_texts(rows)))
  end
end)

-- ---------------------------------------------------------------------------
-- PART 2 — builtin (markdown=true) renderer upgrades: tables, inline spans,
-- task/ordered lists, header levels, horizontal rules, hanging indent, and the
-- code-block language label.
-- ---------------------------------------------------------------------------

T.it("builtin table: columns align — │ lands at the same display column in every row", function()
  local ctx = T.fresh()
  local text = "| A | BBBBB |\n| --- | --- |\n| 1 | 2 |"
  local c = ctx.store.add(T.comment({ comment = text }))
  local rows = require("obelus.thread").build(ctx.store.get(c.id), 60, { markdown = true, rules = true })
  local bar_positions = {}
  for _, s in ipairs(body_texts(rows)) do
    local positions, i = {}, 1
    while true do
      local f = s:find("│", i, true)
      if not f then
        break
      end
      positions[#positions + 1] = f
      i = f + 1
    end
    if #positions > 0 then
      bar_positions[#bar_positions + 1] = positions
    end
  end
  T.ok(#bar_positions >= 2, "at least two data rows (header + body) carried │ separators")
  for i = 2, #bar_positions do
    T.eq(bar_positions[i], bar_positions[1], "│ positions in row " .. i .. " match row 1")
  end
end)

T.it("builtin table: all border/junction glyphs are present, no raw | remains", function()
  local ctx = T.fresh()
  local text = "| A | B |\n| --- | --- |\n| 1 | 2 |"
  local c = ctx.store.add(T.comment({ comment = text }))
  local rows = require("obelus.thread").build(ctx.store.get(c.id), 60, { markdown = true, rules = true })
  local texts = body_texts(rows)
  local flat = table.concat(texts, "\n")
  for _, ch in ipairs({ "╭", "┬", "╮", "├", "┼", "┤", "╰", "┴", "╯" }) do
    T.contains(flat, ch, "border/junction glyph present: " .. ch)
  end
  for _, s in ipairs(texts) do
    T.ok(not s:find("|", 1, true), "no raw ASCII pipe remains in: " .. s)
  end
end)

T.it("builtin table: right-alignment (---:) pads the LEFT of the cell", function()
  local ctx = T.fresh()
  local text = "| Name | Score |\n| --- | ---: |\n| Bob | 7 |"
  local c = ctx.store.add(T.comment({ comment = text }))
  local rows = require("obelus.thread").build(ctx.store.get(c.id), 60, { markdown = true, rules = true })
  local expect = string.rep(" ", vim.fn.strdisplaywidth("Score") - vim.fn.strdisplaywidth("7")) .. "7"
  local found = false
  for _, s in ipairs(body_texts(rows)) do
    if s:find("Bob", 1, true) then
      found = true
      T.contains(s, expect, "the right-aligned Score cell pads its left side before '7': " .. s)
    end
  end
  T.ok(found, "found the Bob data row")
end)

T.it("builtin table: an overflowing row is truncated with an ellipsis, never wrapped", function()
  local ctx = T.fresh()
  local width = 40
  local text = "| Col |\n| --- |\n| " .. string.rep("x", 200) .. " |"
  local c = ctx.store.add(T.comment({ comment = text }))
  local rows = require("obelus.thread").build(ctx.store.get(c.id), width, { markdown = true, rules = true })
  local texts = body_texts(rows)
  T.eq(#texts, 5, "exactly 5 table rows (border/header/divider/body/border) — never wrapped into extras")
  local saw_ellipsis = false
  for _, s in ipairs(texts) do
    if s:find("…", 1, true) then
      saw_ellipsis = true
    end
  end
  T.ok(saw_ellipsis, "the overflowing row was clipped with an ellipsis")
  local bound = row_bound(width)
  for _, row in ipairs(require("obelus.thread").to_virt_lines(rows, width)) do
    local w = 0
    for _, chunk in ipairs(row) do
      w = w + vim.fn.strdisplaywidth(chunk[1] or "")
    end
    T.ok(w <= bound, "row within width bound (" .. bound .. "): " .. w)
  end
end)

-- ---------------------------------------------------------------------------
-- table_block_rows column-fitting (layer 2 of the width-fit work): a too-wide
-- table shrinks its COLUMNS (widest-first, floor 3) instead of losing its right
-- wall to the whole-row clip_chunks fallback — every wall/border survives at the
-- fitted width, with individual over-wide cells ellipsized.
-- ---------------------------------------------------------------------------

T.it(
  "builtin table: a too-wide multi-column table shrinks columns — walls survive, an over-wide cell ellipsizes",
  function()
    local ctx = T.fresh()
    local width = 40
    local text = "| Name | Description | Notes |\n| --- | --- | --- |\n| Alice | " .. string.rep("z", 60) .. " | ok |"
    local c = ctx.store.add(T.comment({ comment = text }))
    local rows = require("obelus.thread").build(ctx.store.get(c.id), width, { markdown = true, rules = true })

    -- every emitted row (border, header, separator, body) stays within the bound
    local bound = row_bound(width)
    for _, row in ipairs(require("obelus.thread").to_virt_lines(rows, width)) do
      local w = 0
      for _, chunk in ipairs(row) do
        w = w + vim.fn.strdisplaywidth(chunk[1] or "")
      end
      T.ok(w <= bound, "row within width bound (" .. bound .. "): " .. w)
    end

    -- find the data rows (their chunks open with the "│ " chunk, unlike border rows
    -- which open with "╭"/"├"/"╰") and check the wall + ellipsis at the chunk level
    local last_data, saw_ellipsis = nil, false
    for _, r in ipairs(rows) do
      if r.kind == "content" and r.chunks[1] and r.chunks[1][1] == "│ " then
        last_data = r.chunks
      end
      if r.kind == "content" then
        for _, ch in ipairs(r.chunks) do
          if type(ch[1]) == "string" and ch[1]:sub(-3) == "…" then
            saw_ellipsis = true
          end
        end
      end
    end
    T.ok(last_data, "at least one data row was emitted")
    local last_chunk = last_data[#last_data]
    T.eq(last_chunk[1]:sub(-3), "│", "the last data row's final chunk still ends with the │ wall")
    T.ok(saw_ellipsis, "at least one cell was ellipsized (clip_chunks appended …)")
  end
)

T.it("builtin table: a narrow table that already fits never gets an ellipsis", function()
  local ctx = T.fresh()
  local text = "| A | B |\n| --- | --- |\n| 1 | 2 |"
  local c = ctx.store.add(T.comment({ comment = text }))
  local rows = require("obelus.thread").build(ctx.store.get(c.id), 60, { markdown = true, rules = true })
  T.ok(not flatten(rows, 60):find("…", 1, true), "a table that already fits is never ellipsized")
end)

T.it("builtin table: bold works inside a cell", function()
  local ctx = T.fresh()
  local text = "| A |\n| --- |\n| **x** |"
  local c = ctx.store.add(T.comment({ comment = text }))
  local rows = require("obelus.thread").build(ctx.store.get(c.id), 60, { markdown = true, rules = true })
  local saw = false
  for _, r in ipairs(rows) do
    if r.kind == "content" then
      for _, ch in ipairs(r.chunks) do
        if ch[1] == "x" and ch[2] == "ObelusThreadBold" then
          saw = true
        end
      end
    end
  end
  T.ok(saw, "the cell's **x** span rendered Bold with markers stripped")
end)

T.it("md_chunks inline spans: italic/strike/link + bold regression + literal lone-* guard", function()
  local ctx = T.fresh()
  local text = "*it* and **b** and ~~s~~ and [t](http://example.com/u) and 2 * 3 = 6"
  local c = ctx.store.add(T.comment({ comment = text }))
  local rows = require("obelus.thread").build(ctx.store.get(c.id), 90, { markdown = true, rules = true })
  local seen, flat = {}, ""
  for _, r in ipairs(rows) do
    if r.kind == "content" and r.chunks[1] and r.chunks[1].role == "body" then
      for _, ch in ipairs(r.chunks) do
        flat = flat .. (ch[1] or "")
        seen[#seen + 1] = { ch[1], ch[2] }
      end
    end
  end
  local function has(text_, hl_)
    for _, e in ipairs(seen) do
      if e[1] == text_ and e[2] == hl_ then
        return true
      end
    end
    return false
  end
  T.ok(has("it", "ObelusThreadItalic"), "italic span styled, asterisks stripped")
  T.ok(has("b", "ObelusThreadBold"), "**bold** regression still works")
  T.ok(has("s", "ObelusThreadStrike"), "strike span styled, tildes stripped")
  T.ok(has("t", "ObelusThreadLink"), "link text styled with the Link hl")
  T.ok(not flat:find("http://example.com/u", 1, true), "the URL is dropped from the rendered copy")
  T.contains(flat, "2 * 3 = 6", "a lone spaced * in prose is never read as an italic opener")
end)

T.it("task list glyphs: unchecked/checked render ☐/☑, checked text stays body_hl", function()
  local ctx = T.fresh()
  local text = "- [ ] todo\n- [x] done"
  local c = ctx.store.add(T.comment({ comment = text }))
  local rows = require("obelus.thread").build(ctx.store.get(c.id), 60, { markdown = true, rules = true })
  T.eq(body_texts(rows), { "☐ todo", "☑ done" })
  for _, r in ipairs(rows) do
    if r.kind == "content" and r.chunks[1] and r.chunks[1].role == "body" then
      for _, ch in ipairs(r.chunks) do
        T.ok(ch[2] ~= "ObelusThreadStrike", "a checked task's text is never struck through: " .. ch[1])
      end
    end
  end
end)

T.it("ordered list: the marker is its own meta_hl chunk, the rest via md_chunks", function()
  local ctx = T.fresh()
  local text = "1. first"
  local c = ctx.store.add(T.comment({ comment = text }))
  local rows = require("obelus.thread").build(ctx.store.get(c.id), 60, { markdown = true, rules = true })
  local marker_ok = false
  for _, r in ipairs(rows) do
    if r.kind == "content" and r.chunks[1] and r.chunks[1].role == "body" then
      if r.chunks[1][1] == "1. " and r.chunks[1][2] == "ObelusThreadMeta" then
        marker_ok = true
      end
    end
  end
  T.ok(marker_ok, "the '1. ' marker is a standalone ObelusThreadMeta chunk")
end)

T.it("header levels: # and ## use the accent Header hl, ### keeps Bold", function()
  local ctx = T.fresh()
  local text = "# one\n## two\n### three"
  local c = ctx.store.add(T.comment({ comment = text }))
  local rows = require("obelus.thread").build(ctx.store.get(c.id), 60, { markdown = true, rules = true })
  local hls = {}
  for _, r in ipairs(rows) do
    if r.kind == "content" and r.chunks[1] and r.chunks[1].role == "body" then
      hls[#hls + 1] = r.chunks[1][2]
    end
  end
  T.eq(hls, { "ObelusThreadHeader", "ObelusThreadHeader", "ObelusThreadBold" })
end)

T.it("horizontal rule: a lone --- row emits a single meta_hl ─ row", function()
  local ctx = T.fresh()
  local text = "above\n\n---\n\nbelow"
  local c = ctx.store.add(T.comment({ comment = text }))
  local rows = require("obelus.thread").build(ctx.store.get(c.id), 40, { markdown = true, rules = true })
  local found = false
  for _, r in ipairs(rows) do
    if r.kind == "content" and r.chunks[1] and r.chunks[1].role == "body" then
      local ch = r.chunks[1]
      -- byte-safe "all dashes" check: "─" is a 3-byte UTF-8 char, so a Lua pattern
      -- quantifier ("─+") would only repeat its LAST byte — gsub-away-then-empty
      -- sidesteps that multibyte pitfall entirely.
      if ch[2] == "ObelusThreadMeta" and ch[1] ~= "" and (ch[1]:gsub("─", "")) == "" then
        found = true
      end
    end
  end
  T.ok(found, "an hr row of ─ chars in ObelusThreadMeta was emitted")
end)

T.it("hanging indent: a wrapped bullet's continuations start with the lead spaces and fit the bound", function()
  local ctx = T.fresh()
  local text = "- " .. string.rep("word ", 30)
  local c = ctx.store.add(T.comment({ comment = text }))
  local width = 30
  local rows = require("obelus.thread").build(ctx.store.get(c.id), width, { markdown = true, rules = true })
  local texts = body_texts(rows)
  T.ok(#texts >= 2, "the bullet wrapped into multiple rows")
  T.contains(texts[1], "• ", "the first row carries the bullet")
  for i = 2, #texts do
    T.ok(
      texts[i]:match("^  %S"),
      "continuation row " .. i .. " starts with the 2-space hanging indent: " .. vim.inspect(texts[i])
    )
  end
  local bound = row_bound(width)
  for _, row in ipairs(require("obelus.thread").to_virt_lines(rows, width)) do
    local w = 0
    for _, chunk in ipairs(row) do
      w = w + vim.fn.strdisplaywidth(chunk[1] or "")
    end
    T.ok(w <= bound, "row within width bound (" .. bound .. "): " .. w)
  end
end)

T.it("code label: the language is right-aligned on the block's first row, absent when lang == ''", function()
  local ctx = T.fresh()
  local text = "```lua\nlocal x = 1\nreturn x\n```\n\n```\nbare fence, no lang\n```"
  local c = ctx.store.add(T.comment({ comment = text }))
  local rows = require("obelus.thread").build(ctx.store.get(c.id), 60, { markdown = true, rules = true })
  local code_rows = {}
  for _, r in ipairs(rows) do
    if r.kind == "content" and r.chunks[1] and r.chunks[1].role == "code" then
      code_rows[#code_rows + 1] = r
    end
  end
  T.eq(#code_rows, 3, "2 rows from the lua block + 1 row from the unlabelled block")
  local last = code_rows[1].chunks[#code_rows[1].chunks]
  T.eq(last[1], "lua", "the lua block's first row ends with the language label text")
  T.eq(last[2], "ObelusThreadCodeLabel", "...styled with the CodeLabel hl")
  for _, ch in ipairs(code_rows[2].chunks) do
    T.ok(ch[2] ~= "ObelusThreadCodeLabel", "no label on the lua block's second row")
  end
  for _, ch in ipairs(code_rows[3].chunks) do
    T.ok(ch[2] ~= "ObelusThreadCodeLabel", "no label when lang == '' (bare fence)")
  end
end)

T.it("table cells: a pipe inside a code span or escaped as \\| is CONTENT, not a delimiter", function()
  local ctx = T.fresh()
  local c = ctx.store.add(T.comment({ comment = "q" }))
  ctx.store.add_turn(c.id, "agent", "| A | B | C |\n| --- | --- | --- |\n| `a|b` | x\\|y | z |")
  local rows = require("obelus.thread").build(ctx.store.get(c.id), 60, { markdown = true })
  local text = flatten(rows, 60)
  T.contains(text, "a|b", "the code span kept its pipe")
  T.contains(text, "x|y", "the escaped pipe is a literal")
  T.contains(text, "z", "the trailing cell was not silently dropped")
  T.ok(not text:find("\\|", 1, true), "the escape backslash never renders")
end)

T.it("hanging indent: a deeply nested bullet in a narrow band stays within the width bound", function()
  local ctx = T.fresh()
  local width = 18 -- inner = max(12, 18-3) = 15; a 10-cell marker would squeeze past the floor
  local c = ctx.store.add(T.comment({ comment = "q" }))
  ctx.store.add_turn(c.id, "agent", "        - deeply nested bullet with enough words to wrap")
  local rows = require("obelus.thread").build(ctx.store.get(c.id), width, { markdown = true })
  local bound = row_bound(width)
  for _, row in ipairs(require("obelus.thread").to_virt_lines(rows, width)) do
    local w = 0
    for _, chunk in ipairs(row) do
      w = w + vim.fn.strdisplaywidth(chunk[1] or "")
    end
    T.ok(w <= bound, "row within width bound (" .. bound .. "): " .. w)
  end
end)

T.it("pad_table_edges: a table at the very START or END of a turn still gets its blank rows", function()
  -- the buffer row above a turn's first line is the "agent ↩" header — without a
  -- leading blank, markview draws the table's top border overlay ONTO the header
  local ctx = T.fresh()
  local c = ctx.store.add(T.comment({ comment = "q" }))
  ctx.store.add_turn(c.id, "agent", "| A | B |\n| --- | --- |\n| 1 | 2 |")
  local rows = require("obelus.thread").build(ctx.store.get(c.id), 70, { markdown = false, rules = false })
  local texts = {}
  for _, r in ipairs(rows) do
    if r.kind == "content" then
      local s = ""
      for _, ch in ipairs(r.chunks) do
        s = s .. (ch[1] or "")
      end
      texts[#texts + 1] = s
    end
  end
  -- turn body = blank, table x3, blank (headers/comment rows precede)
  T.eq(texts[#texts], "", "trailing blank row for the bottom border")
  T.eq(texts[#texts - 4], "", "leading blank row for the top border (header row stays untouched)")
  T.contains(texts[#texts - 3], "| A | B |")
end)

-- ---------------------------------------------------------------------------
-- PART 3 — fit_table_cells: markview-mode (markdown=false) source fitting. Runs
-- right after pad_table_edges, on the RENDERED copy only — never the stored text.
-- ---------------------------------------------------------------------------

T.it("fit_table_cells: a too-wide table's rows all fit the budget, separator alignment colons preserved", function()
  local ctx = T.fresh()
  local width = 40 -- inner = max(12, 40-3) = 37; budget = inner - 2 = 35
  local budget = math.max(12, width - 3) - 2
  local text = "| Name | Description | Notes |\n| :--- | ---: | :--: |\n| Alice | " .. string.rep("z", 60) .. " | ok |"
  local c = ctx.store.add(T.comment({ comment = text }))
  local rows = require("obelus.thread").build(ctx.store.get(c.id), width, { markdown = false, rules = true })
  local texts = body_texts(rows)

  local table_lines, sep_line = {}, nil
  for _, s in ipairs(texts) do
    if s:match("^%s*|.*|%s*$") then
      table_lines[#table_lines + 1] = s
      if s:match("^%s*|[%s:%-|]+|%s*$") then
        sep_line = s
      end
    end
  end
  T.ok(#table_lines >= 3, "the table's rows were emitted")
  for _, s in ipairs(table_lines) do
    T.ok(vim.fn.strdisplaywidth(s) <= budget, "table row within budget (" .. budget .. "): " .. s)
  end

  T.ok(sep_line, "the rebuilt separator row was found")
  local segs = {}
  for seg in sep_line:gmatch("[^|]+") do
    segs[#segs + 1] = seg:match("^%s*(.-)%s*$")
  end
  T.eq(#segs, 3, "3 separator segments")
  T.ok(segs[1]:match("^:%-+$"), "col 1 (:---) kept its LEADING colon only: " .. segs[1])
  T.ok(segs[2]:match("^%-+:$"), "col 2 (---:) kept its TRAILING colon only: " .. segs[2])
  T.ok(segs[3]:match("^:%-+:$"), "col 3 (:--:) kept BOTH colons: " .. segs[3])
end)

T.it("fit_table_cells: a narrow table (already within budget) is byte-identical (idempotent)", function()
  local ctx = T.fresh()
  local text = "above text\n| A | B |\n| --- | --- |\n| 1 | 2 |\nbelow text"
  local c = ctx.store.add(T.comment({ comment = text }))
  local rows = require("obelus.thread").build(ctx.store.get(c.id), 70, { markdown = false, rules = true })
  T.eq(
    body_texts(rows),
    { "above text", "", "| A | B |", "| --- | --- |", "| 1 | 2 |", "", "below text" },
    "a table that already fits the budget is passed through byte-identical, same as pad_table_edges alone"
  )
end)

T.it("fit_table_cells: a piped 'table' inside a fence is never rewritten, even at a budget too small for it", function()
  local ctx = T.fresh()
  local width = 30 -- a small budget: this would need fitting if it were a REAL table
  local text = "text\n````\n| " .. string.rep("y", 100) .. " | b |\n| --- | --- |\n````\nmore"
  local c = ctx.store.add(T.comment({ comment = text }))
  local rows = require("obelus.thread").build(ctx.store.get(c.id), width, { markdown = false, rules = true })
  T.eq(body_texts(rows), vim.split(text, "\n", { plain = true }), "fenced content passed through verbatim")
end)

-- ---------------------------------------------------------------------------
-- panel._fit_width: pure width-fit arithmetic (panel.lua's fit_rooted). Unit-tested
-- directly here since geometry_spec's integration-level popup-width spec can only
-- exercise the base<cap growth path (it must widen the editor to do even that — see
-- its comment); the cap-below-base clamp can't be reached through a real
-- open_thread() pass without contriving a pathologically narrow editor, so it's
-- covered here instead.
-- ---------------------------------------------------------------------------

T.it("panel._fit_width: grows to content, never below base, never past cap", function()
  local fit_width = require("obelus.panel")._fit_width
  T.eq(fit_width(100, 120, 116), 116, "content wider than base, within cap: grows to content")
  T.eq(fit_width(100, 80, 116), 100, "content narrower than base: never shrinks below base")
  T.eq(fit_width(100, 120, 90), 90, "cap below base: cap wins even though content is wider still")
end)

-- ---------------------------------------------------------------------------
-- thread.pref_width: SOURCE-derived preferred width (panel.fit_rooted's two-way
-- sizing) — hard_w (fenced code / table rows, can't rewrap without damage) vs
-- soft_w (everything else, wraps fine) — measured on the comment's RAW turn text
-- (store.turns), never rendered/wrapped lines.
-- ---------------------------------------------------------------------------

T.it("pref_width: a prose-only thread has hard_w == 0 and soft_w == the widest line", function()
  local pref_width = require("obelus.thread").pref_width
  local hard_w, soft_w = pref_width({
    turns = {
      { author = "you", text = "short line" },
      { author = "agent", text = "a longer prose reply line here" },
    },
  })
  T.eq(hard_w, 0, "no fences/tables: nothing is hard content")
  T.eq(soft_w, vim.fn.strdisplaywidth("a longer prose reply line here"), "soft_w is the widest prose line")
end)

T.it("pref_width: a 130-col fenced code line is hard content, wider than the surrounding prose", function()
  local pref_width = require("obelus.thread").pref_width
  local code = string.rep("x", 130)
  local hard_w, soft_w = pref_width({ turns = { { author = "agent", text = "prose\n```\n" .. code .. "\n```" } } })
  T.eq(hard_w, 130, "the fenced line's width is hard_w")
  T.ok(soft_w < hard_w, "the prose line stays in soft_w, narrower than the code line")
end)

T.it("pref_width: an empty (or nil) comment floors both widths at 0", function()
  local pref_width = require("obelus.thread").pref_width
  T.eq({ pref_width({ turns = {} }) }, { 0, 0 })
  T.eq({ pref_width({}) }, { 0, 0 })
  T.eq({ pref_width(nil) }, { 0, 0 })
end)

T.it("pref_width: a table row's width counts as hard, even outside a fenced block", function()
  local pref_width = require("obelus.thread").pref_width
  local row = "| " .. string.rep("z", 100) .. " | b |"
  local sep = "| --- | --- |"
  local hard_w, soft_w = pref_width({ turns = { { author = "agent", text = row .. "\n" .. sep } } })
  T.eq(hard_w, vim.fn.strdisplaywidth(row), "the table row's width is hard_w")
  T.eq(soft_w, 0, "no prose lines in this turn")
end)

T.it("fit_table_cells: CJK cells truncate by DISPLAY width, rows never exceed the budget", function()
  local ctx = T.fresh()
  local c = ctx.store.add(T.comment({ comment = "q" }))
  ctx.store.add_turn(
    c.id,
    "agent",
    "| 項目 | 説明 |\n| --- | --- |\n| 日本語テキストの長いセルの内容がここにあります | 短い |"
  )
  local width = 40 -- budget = inner - 2 = 35; the CJK cell is ~48 cells naturally
  local rows = require("obelus.thread").build(ctx.store.get(c.id), width, { markdown = false, rules = false })
  local budget = math.max(12, width - 3) - 2
  local saw_table = false
  for _, r in ipairs(rows) do
    if r.kind == "content" then
      local s = ""
      for _, ch in ipairs(r.chunks) do
        s = s .. (ch[1] or "")
      end
      if s:find("|", 1, true) then
        saw_table = true
        T.ok(
          vim.fn.strdisplaywidth(s) <= budget,
          "table row within budget (" .. budget .. "): " .. vim.fn.strdisplaywidth(s)
        )
      end
    end
  end
  T.ok(saw_table, "the table rows were emitted")
end)

T.it("builtin table: a CJK cell in a shrunk column keeps the row bound AND the closing wall", function()
  local ctx = T.fresh()
  local c = ctx.store.add(T.comment({ comment = "q" }))
  ctx.store.add_turn(
    c.id,
    "agent",
    "| A | B |\n| --- | --- |\n| 日本語テキストの長い説明がここに続きます | ok |"
  )
  local width = 24
  local rows = require("obelus.thread").build(ctx.store.get(c.id), width, { markdown = true })
  local bound = row_bound(width)
  local saw_wall = false
  for _, row in ipairs(require("obelus.thread").to_virt_lines(rows, width)) do
    local s, w = "", 0
    for _, chunk in ipairs(row) do
      s = s .. (chunk[1] or "")
      w = w + vim.fn.strdisplaywidth(chunk[1] or "")
    end
    T.ok(w <= bound, "row within bound (" .. bound .. "): " .. w .. " [" .. s .. "]")
    if s:find("│%s*$") then
      saw_wall = true -- data rows keep their closing wall despite the CJK clip
    end
  end
  T.ok(saw_wall, "at least one data row ends with its wall")
end)

T.it("fit_one_table: a bare pipe from an unescaped \\| is re-escaped; code-span pipes are not", function()
  local ctx = T.fresh()
  local filler = string.rep("z", 60)
  local c = ctx.store.add(T.comment({ comment = "q" }))
  ctx.store.add_turn(c.id, "agent", "| a\\|b | `c|d` | " .. filler .. " |\n| --- | --- | --- |\n| 1 | 2 | 3 |")
  local rows = require("obelus.thread").build(ctx.store.get(c.id), 40, { markdown = false, rules = false })
  local header_line
  for _, r in ipairs(rows) do
    if r.kind == "content" then
      local s = ""
      for _, ch in ipairs(r.chunks) do
        s = s .. (ch[1] or "")
      end
      if s:find("a", 1, true) and s:find("|", 1, true) then
        header_line = s
        break
      end
    end
  end
  T.ok(header_line ~= nil, "the rebuilt header row was emitted")
  T.contains(header_line, "a\\|b", "the bare pipe is re-escaped so markview reparses 3 columns")
  T.contains(header_line, "`c|d`", "the code-span pipe stays unescaped (GFM: literal inside backticks)")
end)
