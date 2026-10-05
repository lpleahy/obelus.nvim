-- ask mode (|obelus-ask|): the treesitter context capture, the question framing,
-- the read-only/stream/model contract of an ask send (over the fake transport AND
-- the real cli transport with a stubbed spawn), scratch isolation from every
-- review-side selector, and the clear sweep.
T.describe("ask")

local ask = require("obelus.ask")

local LUA = {
  "local M = {}",
  "",
  "local function helper(a, b)",
  "  local sum = a + b",
  "  return sum * 2",
  "end",
  "",
  "function M.run(x)",
  "  if x == nil then",
  "    return helper(1, 2)",
  "  end",
  "  return helper(x, x)",
  "end",
  "",
  "M.VALUE = 42",
  "",
  "return M",
}

-- A real lua file under the temp root, opened in a window (the bundled lua
-- treesitter parser attaches by filetype).
local function open_lua(ctx, lines)
  local file = ctx.root .. "/f.lua"
  vim.fn.writefile(lines or LUA, file)
  vim.cmd("edit " .. file)
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].filetype = "lua"
  return buf, vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
end

local function fresh_fake(extra)
  local F = require("fake")
  -- a REAL-path root: nvim resolves buffer names (macOS /var -> /private/var),
  -- and format.relpath / the mention policy compare against store.root()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  root = (vim.uv or vim.loop).fs_realpath(root) or root
  local base = {
    root = root,
    transport = { dispatch = "fake", cli = { models = { send = "big", fast = "small", batch = "huge" } } },
    render = { renderer = "builtin" },
  }
  local ctx = T.fresh(extra and vim.tbl_deep_extend("force", base, extra) or base)
  ctx.root = root
  F.reset()
  F.install()
  require("obelus.panel")._timing.fill_throttle = 0
  require("obelus.progress")._timing.tick = 20
  return ctx, F
end

-- ---------------------------------------------------------------------------
-- context capture
-- ---------------------------------------------------------------------------

T.it("context: the enclosing function via treesitter, named, as the default", function()
  local ctx = fresh_fake()
  local buf = open_lua(ctx)
  local c = ask.context(buf, 4, 4) -- `local sum = a + b` inside helper()
  T.eq(c.kind, "function")
  T.eq({ c.sl, c.el }, { 3, 6 }, "the whole `local function helper … end`")
  T.eq(c.name, "helper")
  T.eq(c.lines[1], "local function helper(a, b)")
  T.eq(c.lines[#c.lines], "end")
  T.eq(c.trimmed, false)

  local m = ask.context(buf, 10, 10) -- `return helper(1, 2)` — nested in an if inside M.run
  T.eq({ m.sl, m.el, m.name }, { 8, 13, "M.run" }, "climbs past the if and the CALL to the enclosing function")
end)

T.it("context: no enclosing function -> the `lines` window; a range across functions too", function()
  local ctx = fresh_fake({ ask = { lines = 2 } })
  local buf = open_lua(ctx)
  local top = ask.context(buf, 15, 15) -- `M.VALUE = 42`, top level
  T.eq(top.kind, "lines")
  T.eq({ top.sl, top.el }, { 13, 17 }, "2 each side, clamped to the buffer")
  local span = ask.context(buf, 5, 9) -- helper's body through M.run's if — only the root spans both
  T.eq(span.kind, "lines")
  T.eq({ span.sl, span.el }, { 3, 11 })
end)

T.it("context: an integer `context` is a lines window; max_lines trims around the asked lines", function()
  local ctx = fresh_fake({ ask = { context = 1 } })
  local buf = open_lua(ctx)
  local one = ask.context(buf, 4, 4)
  T.eq({ one.kind, one.sl, one.el }, { "lines", 3, 5 })

  ctx = fresh_fake({ ask = { max_lines = 3 } })
  buf = open_lua(ctx)
  local t = ask.context(buf, 12, 12) -- `return helper(x, x)` in M.run (6 lines) capped to 3
  T.eq(t.kind, "function")
  T.eq(t.trimmed, true)
  T.eq(t.el - t.sl + 1, 3)
  T.ok(t.sl <= 12 and t.el >= 12, "the asked line stays inside the trimmed window")
  T.eq(#t.lines, 3)
end)

T.it("context: a C signature line climbs past function_declarator to the whole function_definition", function()
  local ctx = fresh_fake()
  local file = ctx.root .. "/m.c"
  vim.fn.writefile({ "static int add(int a, int b)", "{", "  int s = a + b;", "  return s;", "}", "", "int x;" }, file)
  vim.cmd("edit " .. file)
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].filetype = "c"
  if not pcall(vim.treesitter.get_parser, buf, "c") then
    return -- no c parser in this runtime: nothing to assert
  end
  local sig = ask.context(buf, 1, 1) -- the declarator line itself
  T.eq({ sig.kind, sig.sl, sig.el }, { "function", 1, 5 }, "the declarator is not the scope; its definition is")
  local body = ask.context(buf, 3, 3)
  T.eq({ body.kind, body.sl, body.el }, { "function", 1, 5 })
end)

T.it("context: no parser for the filetype -> lines fallback, never an error", function()
  local ctx = fresh_fake({ ask = { lines = 1 } })
  local file = ctx.root .. "/notes.zzqq"
  vim.fn.writefile({ "one", "two", "three" }, file)
  vim.cmd("edit " .. file)
  local buf = vim.api.nvim_get_current_buf()
  local c = ask.context(buf, 2, 2)
  T.eq({ c.kind, c.sl, c.el }, { "lines", 1, 3 })
end)

-- ---------------------------------------------------------------------------
-- prompt framing
-- ---------------------------------------------------------------------------

T.it("prompt: question framing, the @path mention header, context + asked fences, no review wording", function()
  local ctx = fresh_fake()
  local buf, fabs = open_lua(ctx)
  local c = ctx.store.add(T.comment({
    file = fabs,
    range = { sl = 4, el = 4 },
    selected_text = { "  local sum = a + b" },
    comment = "why multiply later?",
    ask = true,
    scratch = true,
  }))
  c.ask_context = ask.context(buf, 4, 4)
  local p = ask.prompt(c)
  T.contains(p, "# Question about code")
  T.contains(p, "do not modify any file")
  T.contains(p, "### @f.lua `L4-L4`", "the file is a real mention token, same shape as comment_md")
  T.contains(p, "Enclosing `helper` (`L3-L6`):")
  T.contains(p, "```lua\nlocal function helper(a, b)")
  T.contains(p, "Asked lines (`L4-L4`):\n```lua\n  local sum = a + b\n```")
  T.contains(p, "**Question:** why multiply later?")
  T.ok(not p:find("Code review feedback", 1, true), "never the review preamble")
  T.ok(not p:find("**Feedback:**", 1, true), "never the Feedback: line")
end)

T.it("prompt: a snippet containing ``` gets a longer fence; context equal to the asked range is omitted", function()
  local ctx = fresh_fake()
  local _, fabs = open_lua(ctx)
  local c = ctx.store.add(T.comment({
    file = fabs,
    range = { sl = 1, el = 1 },
    selected_text = { "x = '```'" },
    comment = "q",
    ask = true,
  }))
  c.ask_context = { kind = "lines", sl = 1, el = 1, lines = { "x = '```'" }, trimmed = false }
  local p = ask.prompt(c)
  T.contains(p, "````lua\nx = '```'\n````")
  T.ok(not p:find("Surrounding lines", 1, true), "no context block when it adds nothing")
end)

-- ---------------------------------------------------------------------------
-- the send contract (fake transport)
-- ---------------------------------------------------------------------------

T.it(
  "ask(question): creates an ask+scratch thread with context and sends it streamed, read-only, on the ask model",
  function()
    local ctx, F = fresh_fake()
    local buf, fabs = open_lua(ctx)
    vim.api.nvim_win_set_cursor(0, { 4, 2 })
    require("obelus").ask("what is sum?")

    local all = ctx.store.all()
    T.eq(#all, 1, "one thread created")
    local c = all[1]
    T.eq(c.file, fabs)
    T.eq({ c.range.sl, c.range.el, c.kind }, { 4, 4, "line" })
    T.eq(c.comment, "what is sum?")
    T.eq(c.ask, true)
    T.eq(c.scratch, true, "ask.scratch default")
    T.eq(c.ask_context.name, "helper", "the enclosing function was captured on the record")
    T.is_nil(c.tag)

    T.ok(F.payload ~= nil, "dispatched at once — no second key")
    T.eq(F.payload.comments[1].id, c.id)
    T.eq(F.payload.opts.stream, true)
    T.eq(F.payload.opts.read_only, true)
    T.eq(F.payload.opts.model, "small", "ask.model = fast -> models.fast")
    T.is_nil(F.payload.opts.resume)
    T.is_nil(F.payload.opts.actions_comments)
    T.contains(F.payload.markdown, "# Question about code")
    T.contains(F.payload.markdown, "**Question:** what is sum?")
    local _, n = F.payload.markdown:gsub("what is sum%?", "")
    T.eq(n, 1, "the question appears exactly once (no Feedback-line duplicate)")
    T.contains(F.payload.markdown, "[Mentions]", "the @path header still trips the mention policy")

    F.delta("`sum` is a + b.")
    F.finish(true, "sess-ask-1")
    local turns = ctx.store.turns(ctx.store.get(c.id))
    T.eq(#turns, 2)
    T.eq(turns[2].text, "`sum` is a + b.")
    T.eq(ctx.store.get(c.id).session_id, "sess-ask-1")
    T.eq(buf, vim.api.nvim_get_current_buf())
  end
)

T.it("follow-up on an ask thread resumes the session and stays read-only on the ask model", function()
  local ctx, F = fresh_fake()
  local _, fabs = open_lua(ctx)
  local c = ctx.store.add(T.comment({
    file = fabs,
    range = { sl = 4, el = 4 },
    comment = "q1",
    ask = true,
    scratch = true,
    session_id = "sess-1",
    turns = {
      { author = "you", text = "q1" },
      { author = "agent", text = "a1" },
    },
  }))
  require("obelus").chat_send(c.id, "and why doubled?", "send")
  T.eq(F.payload.opts.resume, "sess-1")
  T.eq(F.payload.opts.read_only, true)
  T.eq(F.payload.opts.model, "small", "a plain send on an ask thread still uses the ask model")
  T.eq(F.payload.markdown:sub(1, #"and why doubled?"), "and why doubled?", "resumed: just the text")
  T.ok(not F.payload.markdown:find("# Question about code", 1, true), "no re-founding while the session lives")
  F.finish(true, "sess-1")

  -- send FAST on an ask thread honours the explicit fast request, distinguishable
  -- from the ask model only when ask.model names a different slot
  ctx.config.options.ask.model = "batch"
  require("obelus").chat_send(c.id, "longer?", "send")
  T.eq(F.payload.opts.model, "huge", "ask.model = batch")
  F.finish(true, "sess-1")
  require("obelus").chat_send(c.id, "shorter?", "fast")
  T.eq(F.payload.opts.model, "small", "fast wins over ask.model")
  T.eq(F.payload.opts.read_only, true)
  F.finish(true, "sess-1")
end)

T.it("ask.model = 'batch' / a literal id / 'send' resolve through the models slots", function()
  local cfg = require("obelus.config")
  T.fresh({ ask = { model = "batch" }, transport = { cli = { models = { send = "big", batch = "huge" } } } })
  T.eq(cfg.ask_model(), "huge")
  T.fresh({ ask = { model = "fast" }, transport = { cli = { models = { send = "big" } } } })
  T.eq(cfg.ask_model(), "big", "fast falls back to send")
  T.fresh({ ask = { model = "claude-haiku-4-5" } })
  T.eq(cfg.ask_model(), "claude-haiku-4-5", "a literal id passes through")
  T.fresh({ ask = { model = "send" }, transport = { cli = { models = { send = "big" } } } })
  T.eq(cfg.ask_model(), "big")
end)

T.it("a lost session re-founds with the ask prompt (never the review framing)", function()
  local ctx, F = fresh_fake()
  local buf, fabs = open_lua(ctx)
  local c = ctx.store.add(T.comment({
    file = fabs,
    range = { sl = 4, el = 4 },
    selected_text = { "  local sum = a + b" },
    comment = "q1",
    ask = true,
    scratch = true,
    turns = {
      { author = "you", text = "q1" },
      { author = "agent", text = "a1" },
    },
  }))
  c.ask_context = ask.context(buf, 4, 4)
  require("obelus").chat_send(c.id, "again?", "send")
  T.is_nil(F.payload.opts.resume)
  local md = F.payload.markdown
  T.contains(md, "# Question about code")
  T.contains(md, "Enclosing `helper`")
  T.contains(md, "**Question:** q1", "the ORIGINAL question founds the thread")
  T.contains(md, "Conversation so far")
  local label = require("obelus.config").agent_label()
  T.contains(md, "**" .. label .. ":** a1", "the earlier answer is carried over, labelled with the CLI's name")
  T.contains(md, "**Follow-up:** again?", "the new text is the follow-up")
  T.ok(md:find("%*%*Question:%*%* q1.*:%*%* a1.*%*%*Follow%-up:%*%* again%?"), "in conversation order")
  local _, n = md:gsub("again%?", "")
  T.eq(n, 1, "the new text appears once")
  T.ok(not md:find("Code review feedback", 1, true))
  F.finish(true, "sess-2")
end)

T.it("<prefix>d (dispatch) on an ask thread takes the ask path; an answered one with no draft is a no-op", function()
  local ctx, F = fresh_fake()
  local _, fabs = open_lua(ctx)
  local c = ctx.store.add(T.comment({ file = fabs, range = { sl = 4, el = 4 }, comment = "draft q", ask = true }))
  require("obelus").dispatch(c.id)
  T.ok(F.payload ~= nil)
  T.eq(F.payload.opts.read_only, true)
  T.eq(F.payload.opts.stream, true, "never the one-shot/actions path")
  F.finish(true, "s")
  F.reset()
  F.install()
  require("obelus").dispatch(c.id) -- answered, nothing waiting
  T.is_nil(F.payload, "nothing re-sent: the original question isn't asked twice")
end)

T.it("cancel-with-text keeps the question as a draft and does NOT send; <prefix>d sends it later", function()
  local ctx, F = fresh_fake()
  local buf, fabs = open_lua(ctx)
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  -- drive the composer like the user would: type, then <Esc> (cancel keeps text)
  require("obelus").ask()
  local fwin = vim.api.nvim_get_current_win()
  T.ok(vim.api.nvim_win_get_config(fwin).relative ~= "", "the ask composer opened")
  vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(fwin), 0, -1, false, { "saved for later" })
  vim.cmd("stopinsert")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
  local c = ctx.store.all()[1]
  T.ok(c ~= nil, "cancel-with-text still created the thread")
  T.eq(c.ask, true)
  T.eq(c.comment, "saved for later")
  T.eq(c.file, fabs)
  T.is_nil(F.payload, "not sent on cancel")
  T.eq(vim.api.nvim_get_current_buf(), buf)
  require("obelus").dispatch(c.id)
  T.ok(F.payload ~= nil and F.payload.opts.read_only == true, "sent later through the ask path")
  F.finish(true, "s")
end)

T.it("<C-s> (save) in the ask composer keeps a draft and does NOT send; <CR> sends", function()
  local ctx, F = fresh_fake()
  local _, fabs = open_lua(ctx)
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  require("obelus").ask()
  local fwin = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(fwin), 0, -1, false, { "later" })
  vim.cmd("stopinsert")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-s>", true, false, true), "x", false)
  local c = ctx.store.all()[1]
  T.ok(c and c.ask, "saved as an ask thread")
  T.eq(c.comment, "later")
  T.eq(c.file, fabs)
  T.is_nil(F.payload, "save ≠ send")

  require("obelus").ask()
  fwin = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(fwin), 0, -1, false, { "now" })
  vim.cmd("stopinsert")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  T.eq(#ctx.store.all(), 2)
  T.ok(F.payload ~= nil and F.payload.opts.read_only == true, "<CR> sent through the ask path")
  T.contains(F.payload.markdown, "**Question:** now")
  F.finish(true, "s")
end)

T.it(
  "ask.scratch = false: still never pending, never batched, read-only on every send; taggable + survives the sweep",
  function()
    -- the batch flow uses transport.batch.transport (default "cli"): point it at the
    -- fake so the submit below is captured rather than spawning a CLI
    local ctx, F = fresh_fake({ ask = { scratch = false }, transport = { batch = { transport = "fake" } } })
    local _, fabs = open_lua(ctx)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    require("obelus").ask("q")
    local c = ctx.store.all()[1]
    T.eq(c.ask, true)
    T.is_nil(c.scratch)
    T.eq(F.payload.opts.read_only, true, "still read-only: ask is a question either way")
    F.finish(true, "s")

    -- a drafted follow-up on it, plus a cancelled-with-text fresh ask: neither is pending
    ctx.store.set_pending_you(c.id, "a saved follow-up")
    local draft =
      ctx.store.add(T.comment({ file = fabs, range = { sl = 5, el = 5 }, comment = "unsent q", ask = true }))
    local review = ctx.store.add(T.comment({ file = fabs, range = { sl = 8, el = 8 }, comment = "review me" }))
    T.eq(
      vim.tbl_map(function(x)
        return x.id
      end, ctx.store.pending()),
      { review.id },
      "ask threads are never pending, scratch or not"
    )
    F.reset()
    F.install()
    require("obelus").dispatch_all()
    T.eq(F.payload.comments[1].id, review.id, "dispatch-all only saw the review thread")
    F.finish_batch("s")
    F.reset()
    F.install()
    require("obelus").submit()
    T.eq(#F.payload.comments, 1)
    T.eq(F.payload.comments[1].id, review.id, "a batch submit only saw the review thread")
    F.finish_batch("s2")

    -- the ask's own draft still goes out the ask way
    F.reset()
    F.install()
    require("obelus").dispatch(draft.id)
    T.eq(F.payload.opts.read_only, true)
    T.contains(F.payload.markdown, "# Question about code")
    F.finish(true, "s3")

    -- not scratch: taggable, in the briefing, and NOT swept by ask_clear
    T.ok(ctx.store.tag_comment(c.id, "auth"))
    T.eq(ctx.store.get(c.id).tag, "auth")
    T.contains(require("obelus.format").meta_context(), "a saved follow-up")
    T.eq(require("obelus").ask_clear(), 0)
    T.ok(ctx.store.get(c.id) ~= nil)
  end
)

T.it("<M-CR> (send fast) in the ask composer uses the fast slot even when ask.model is another slot", function()
  local ctx, F = fresh_fake({ ask = { model = "batch" } })
  open_lua(ctx)
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  require("obelus").ask()
  local fwin = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(fwin), 0, -1, false, { "quick one" })
  vim.cmd("stopinsert")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<M-CR>", true, false, true), "x", false)
  T.ok(F.payload ~= nil, "sent")
  T.eq(F.payload.opts.model, "small", "fast slot")
  T.eq(F.payload.opts.read_only, true)
  F.finish(true, "s")
end)

T.it("<prefix>g on a scratch ask thread warns instead of claiming it was tagged", function()
  local ctx, F = fresh_fake()
  local _, fabs = open_lua(ctx)
  local a =
    ctx.store.add(T.comment({ file = fabs, range = { sl = 4, el = 4 }, comment = "q", ask = true, scratch = true }))
  local seen
  local real_notify = vim.notify
  vim.notify = function(msg)
    seen = msg
  end
  local ok, err = pcall(require("obelus").tag, a.id, "auth")
  vim.notify = real_notify
  if not ok then
    error(err, 0)
  end
  T.ok(seen and seen:find("can't be tagged", 1, true), "refusal surfaced: " .. tostring(seen))
  T.is_nil(ctx.store.get(a.id).tag)
end)

-- ---------------------------------------------------------------------------
-- scratch isolation + the sweep
-- ---------------------------------------------------------------------------

T.it("scratch threads never reach pending(), tags, the project briefing, or write-back fan-outs", function()
  local ctx, F = fresh_fake()
  local _, fabs = open_lua(ctx)
  ctx.store.set_active_tag("auth") -- sticky tagging ON
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  require("obelus").ask("q")
  local a = ctx.store.all()[1]
  ctx.store.set_active_tag(nil) -- BEFORE any assertion: a failure must not leak the tag into later specs
  T.is_nil(a.tag, "sticky tag NOT inherited by a scratch thread")
  F.finish(true, "s")

  -- a scratch thread with a waiting draft is still not pending
  ctx.store.set_pending_you(a.id, "follow-up draft")
  local review = ctx.store.add(T.comment({ file = fabs, range = { sl = 8, el = 8 }, comment = "real review" }))
  local pending_ids = vim.tbl_map(function(c)
    return c.id
  end, ctx.store.pending())
  T.eq(pending_ids, { review.id }, "only the review thread is pending")

  T.is_nil(ctx.store.tag_comment(a.id, "auth"), "tagging a scratch thread is refused")
  T.is_nil(ctx.store.get(a.id).tag)
  T.eq(#ctx.store.tag_members("auth"), 0)

  local brief = require("obelus.format").meta_context()
  T.ok(not brief:find("follow-up draft", 1, true) and not brief:find(a.id, 1, true), "absent from the briefing")
  T.contains(brief, "real review")

  -- the project thread's write-back fan-out skips scratch
  F.reset()
  F.install()
  local meta = ctx.store.meta_thread()
  require("obelus").chat_send(meta.id, "status?", "send")
  local ids = vim.tbl_map(function(c)
    return c.id
  end, F.payload.opts.actions_comments or {})
  T.eq(ids, { review.id })
  F.finish(true, "s-meta")
end)

T.it("dispatch_all and a batch submit leave scratch threads alone", function()
  local ctx, F = fresh_fake()
  local _, fabs = open_lua(ctx)
  ctx.store.add(T.comment({ file = fabs, range = { sl = 4, el = 4 }, comment = "q", ask = true, scratch = true }))
  local r = ctx.store.add(T.comment({ file = fabs, range = { sl = 8, el = 8 }, comment = "review me" }))
  require("obelus").dispatch_all()
  T.eq(#F.payload.comments, 1)
  T.eq(F.payload.comments[1].id, r.id)
  T.is_nil(F.payload.opts.stream, "a review dispatch is the one-shot path, untouched")
  F.finish_batch("s")
end)

T.it("ask_clear removes every scratch thread (cancelling live ones) and nothing else", function()
  local ctx, F = fresh_fake()
  local _, fabs = open_lua(ctx)
  local s1 =
    ctx.store.add(T.comment({ file = fabs, range = { sl = 4, el = 4 }, comment = "q1", ask = true, scratch = true }))
  ctx.store.add(T.comment({ file = fabs, range = { sl = 5, el = 5 }, comment = "q2", ask = true, scratch = true }))
  local keep = ctx.store.add(T.comment({ file = fabs, range = { sl = 8, el = 8 }, comment = "keep" }))
  local meta = ctx.store.meta_thread()
  require("obelus").chat_send(s1.id, "live?", "send") -- s1 is mid-stream
  T.ok(require("obelus").busy(s1.id))
  local n = require("obelus").ask_clear()
  T.eq(n, 2)
  T.ok(F.cancelled, "the live ask job was cancelled")
  local ids = vim.tbl_map(function(c)
    return c.id
  end, ctx.store.all())
  table.sort(ids)
  local want = { keep.id, meta.id }
  table.sort(want)
  T.eq(ids, want)
  T.eq(require("obelus").ask_clear(), 0, "idempotent")
end)

T.it("scratch/ask/ask_context survive a save/load round trip", function()
  local ctx = fresh_fake()
  local _, fabs = open_lua(ctx)
  local c = ctx.store.add(T.comment({
    file = fabs,
    range = { sl = 4, el = 4 },
    comment = "q",
    ask = true,
    scratch = true,
    ask_context = { kind = "function", sl = 3, el = 6, name = "helper", lines = { "a", "b" }, trimmed = false },
  }))
  ctx.store.save()
  ctx.store.clear()
  ctx.store.load()
  local back = ctx.store.get(c.id)
  T.eq(back.ask, true)
  T.eq(back.scratch, true)
  T.eq(back.ask_context.name, "helper")
  T.eq(#ctx.store.scratch(), 1)
end)

-- ---------------------------------------------------------------------------
-- the read-only guarantee on the REAL cli transport (stubbed spawn)
-- ---------------------------------------------------------------------------

T.it(
  "real cli transport: an ask spawn runs plan mode, sandbox read-only and no write-back protocol — even with edits ON and chat_actions = true",
  function()
    local seen_mode
    local ctx = T.fresh({
      transport = {
        dispatch = "cli",
        chat_actions = true,
        cli = {
          cmd = { "claude", "-p", "--permission-mode", "acceptEdits" },
          models = { send = "big", fast = "small" },
          permissions = {
            enabled = true,
            level = "unrestricted", -- the most permissive global level…
            wrapper = function(cmd, wctx)
              seen_mode = wctx.mode
              return cmd
            end,
          },
        },
      },
    })
    local cfgmod = require("obelus.config")
    local real_system = vim.system
    local captured
    vim.system = function(cmd)
      captured = cmd
      return {
        kill = function() end,
        wait = function()
          return { code = 0, stdout = "" }
        end,
        pid = 1,
      }
    end
    local ok, err = pcall(function()
      T.ok(cfgmod.edits_enabled(), "edits are ON globally")
      local _, fabs = open_lua(ctx)
      vim.api.nvim_win_set_cursor(0, { 4, 0 })
      require("obelus").ask("what?")
      local function flag(cmd, name)
        for i, v in ipairs(cmd) do
          if v == name then
            return cmd[i + 1]
          end
        end
      end
      T.eq(flag(captured, "--permission-mode"), "plan", "…yet THIS spawn is plan mode")
      T.eq(flag(captured, "--model"), "small")
      T.eq(seen_mode, "read-only", "…and the sandbox wrapped it read-only despite `unrestricted`")
      local prompt = require("obelus.log").prompt()
      T.ok(not prompt:find("review%-actions"), "no write-back protocol in the prompt")
      T.contains(prompt, "# Question about code")
      T.contains(prompt, "[Formatting]", "the streaming path's formatting suffix rides along")

      -- a plain review reply in the same session is untouched by any of that
      seen_mode = nil
      local r = ctx.store.add(T.comment({ file = fabs, range = { sl = 8, el = 8 }, comment = "review" }))
      require("obelus").chat_send(r.id, "please", "send")
      T.eq(flag(captured, "--permission-mode"), "acceptEdits")
      T.is_nil(seen_mode, "unrestricted: no wrap for ordinary spawns")
      T.ok(
        require("obelus.log").prompt():find("review%-actions"),
        "chat_actions = true still applies to review threads"
      )
      for _, c in ipairs(ctx.store.all()) do
        ctx.store.abort(c.id)
      end
    end)
    vim.system = real_system
    cfgmod.ui.perms = nil
    if not ok then
      error(err, 0)
    end
  end
)

-- ---------------------------------------------------------------------------
-- keys, commands, config
-- ---------------------------------------------------------------------------

T.it("keys: i asks (n + x), I clears; :ObelusAsk / :ObelusAskClear exist", function()
  T.fresh({})
  local init = require("obelus.init")
  local prefix = "<leader>ZZi"
  init._keymaps({ prefix = prefix, disabled = {}, overrides = {} })
  local function desc(suffix, mode)
    local m = vim.fn.maparg(prefix .. suffix, mode, false, true)
    return m and m.desc or ""
  end
  T.ok(desc("i", "n"):find("ask about this line", 1, true))
  T.ok(desc("i", "x"):find("ask about the selection", 1, true))
  T.ok(vim.fn.maparg(prefix .. "i", "x"):find("ask_visual", 1, true), "x-mode rhs is the :<C-u>lua string")
  T.ok(desc("I", "n"):find("clear every ask thread", 1, true))
  T.ok(vim.fn.exists(":ObelusAsk") == 2)
  T.ok(vim.fn.exists(":ObelusAskClear") == 2)
end)

T.it(":ObelusAsk <question> sends without a composer; a range asks about the selection", function()
  local ctx, F = fresh_fake()
  open_lua(ctx)
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  vim.cmd("ObelusAsk what does this do")
  local c = ctx.store.all()[1]
  T.eq(c.comment, "what does this do")
  T.eq({ c.range.sl, c.range.el }, { 4, 4 })
  T.eq(F.payload.opts.read_only, true)
  F.finish(true, "s")
  F.reset()
  F.install()
  vim.cmd("8,12ObelusAsk explain the branch")
  local v = ctx.store.all()[2]
  T.eq({ v.range.sl, v.range.el, v.kind }, { 8, 12, "line" })
  T.eq(v.comment, "explain the branch")
  T.eq(v.ask_context.name, "M.run")
  F.finish(true, "s2")
end)

T.it("config: bad ask knobs reset (typed -> nil -> default via ask_opt); scratch is a boolean", function()
  local cfg = require("obelus.config")
  cfg.setup({ ask = { model = 7, context = "sometimes", lines = -1, max_lines = 2.5, scratch = "yes" } })
  T.is_nil(cfg.options.ask.model)
  T.eq(cfg.ask_opt("model"), "fast")
  T.eq(cfg.ask_opt("context"), "function")
  T.eq(cfg.ask_opt("lines"), 20)
  T.eq(cfg.ask_opt("max_lines"), 120)
  T.eq(cfg.ask_opt("scratch"), true)
  cfg.setup({ ask = { model = "opus", context = 7, lines = 3, max_lines = 50, scratch = false } })
  T.eq(cfg.ask_opt("model"), "opus")
  T.eq(cfg.ask_opt("context"), 7)
  T.eq(cfg.ask_opt("lines"), 3)
  T.eq(cfg.ask_opt("max_lines"), 50)
  T.eq(cfg.ask_opt("scratch"), false)
  cfg.setup({ ask = 0 })
  T.eq(cfg.ask_opt("model"), "fast", "a non-table ask resets wholesale")
end)

T.it("render: an ask thread gets the ? sign and the ?ask chip; a review thread keeps ▌", function()
  local ctx = fresh_fake({ render = { bands = { style = "inline" } } })
  local buf, fabs = open_lua(ctx)
  local a = ctx.store.add(T.comment({ file = fabs, range = { sl = 4, el = 4 }, comment = "q", ask = true }))
  local r = ctx.store.add(T.comment({ file = fabs, range = { sl = 8, el = 8 }, comment = "review" }))
  local render = require("obelus.render")
  render.render_buffer(buf)
  local ns = vim.api.nvim_create_namespace("obelus")
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  local signs = {}
  for _, m in ipairs(marks) do
    if m[4].sign_text then
      signs[m[2] + 1] = vim.trim(m[4].sign_text)
    end
  end
  T.eq(signs[4], "?")
  T.eq(signs[8], "▌")
  local thread = require("obelus.thread")
  local function header_text(c)
    local rows = thread.build(c, 80, {})
    for _, row in ipairs(rows) do
      local s = ""
      for _, chunk in ipairs(row.chunks or row) do
        if type(chunk) == "table" and type(chunk[1]) == "string" then
          s = s .. chunk[1]
        end
      end
      if s:find("L4%-L4") or s:find("L8%-L8") then
        return s
      end
    end
    return ""
  end
  T.ok(header_text(a):find("?ask", 1, true), "ask chip on the ask thread's header")
  T.ok(not header_text(r):find("?ask", 1, true), "no chip on a review thread")

  -- sidebar list: an ask thread that ALSO carries a tag shows both badges
  local tagged =
    ctx.store.add(T.comment({ file = fabs, range = { sl = 10, el = 10 }, comment = "tq", ask = true, tag = "auth" }))
  local panel = require("obelus.panel")
  panel._timing.fill_throttle = 0
  panel.open()
  vim.cmd("redraw")
  local lines = vim.api.nvim_buf_get_lines(panel.geom().buf, 0, -1, false)
  local row
  for _, l in ipairs(lines) do
    if l:find("tq", 1, true) then
      row = l
    end
  end
  T.ok(row and row:find("?ask", 1, true) and row:find("#auth", 1, true), "both badges: " .. tostring(row))
  ctx.store.remove(tagged.id)
end)
