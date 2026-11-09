-- UI snapshot scenarios. Each runs in a FRESH child nvim (tests/ui/run.lua), at
-- every size, from the same synthetic fixture: no agents, no network, no user
-- config. The fake transport (tests/fake.lua) drives streaming exactly like
-- transport/cli.lua does, synchronously.
--
-- A scenario only arranges state; capture happens afterwards in child.lua. Keep
-- every scenario deterministic: no wall-clock waits. Timers and vim.schedule run
-- on the child's VIRTUAL clock (child.lua): C.settle() runs everything runnable
-- now, to quiescence; C.advance(ms) moves the clock. Host load cannot change it.
local C = _G.__ui

local S = { list = {} }

local function scenario(name, fn, opts)
  opts = opts or {}
  S.list[#S.list + 1] = { name = name, fn = fn, kind = opts.kind, sizes = opts.sizes, hidden = opts.hidden }
end

-- the source file every scenario annotates (plain buffer: no filetype/syntax, so
-- the screen shows obelus's decorations, not a syntax theme)
local SOURCE = {
  "-- sample.lua: a small module the fixtures annotate",
  "local M = {}",
  "",
  "local function clamp(x, lo, hi)",
  "  if x < lo then",
  "    return lo",
  "  end",
  "  return math.min(x, hi)",
  "end",
  "",
  "function M.scale(values, factor)",
  "  local out = {}",
  "  for i, v in ipairs(values) do",
  "    out[i] = clamp(v * factor, 0, 100)",
  "  end",
  "  return out",
  "end",
  "",
  "function M.sum(values)",
  "  local total = 0",
  "  for _, v in ipairs(values) do",
  "    total = total + v",
  "  end",
  "  return total",
  "end",
  "",
  "return M",
}

local LONG_AGENT = table.concat({
  "Good catch. `clamp` is applied **after** the multiply, so a negative `factor` silently",
  "maps every value to `0` instead of raising. Two options:",
  "",
  "1. Validate `factor` up front and `error()` on a negative value.",
  "2. Clamp the *input* first, then scale — this keeps the contract but changes rounding.",
  "",
  "```lua",
  "function M.scale(values, factor)",
  '  assert(factor >= 0, "factor must be non-negative")',
  "  local out = {}",
  "  for i, v in ipairs(values) do",
  "    out[i] = clamp(v * factor, 0, 100)",
  "  end",
  "  return out",
  "end",
  "```",
  "",
  "| option | breaks callers | cost |",
  "| --- | --- | --- |",
  "| validate | yes, on bad input | O(1) |",
  "| clamp first | no | O(n) |",
  "",
  "> I'd go with option 1: it fails loudly, which matches `M.sum`'s behaviour.",
}, "\n")

-- Fresh obelus over the fixed project root (the child's cwd), builtin renderer,
-- fake transport installed, and every wall-clock knob pinned:
--   panel fill throttle / preview settle -> 0 (run on the next loop turn)
--   progress tick -> effectively never repeats: the timer's FIRST tick fires
--   immediately (frame 1 -> 2) and the next would be ~11 days later, so every
--   spinner glyph on screen is frame 2 ("⠙") — frozen, not sampled.
local function fresh(opts)
  local H = require("helpers")
  _G.T = H
  local root = vim.fn.getcwd()
  local base = {
    root = root,
    render = { renderer = "builtin" },
    transport = { dispatch = "fake" },
  }
  local ctx = H.fresh(vim.tbl_deep_extend("force", base, opts or {}))
  local F = require("fake")
  F.reset()
  F.install()
  require("obelus.panel")._timing.fill_throttle = 0
  require("obelus.panel")._timing.preview_settle = 0
  require("obelus.progress")._timing.tick = 1e9
  ctx.F = F
  vim.fn.writefile(SOURCE, root .. "/sample.lua")
  vim.cmd("edit sample.lua")
  ctx.buf = vim.api.nvim_get_current_buf()
  ctx.file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
  -- the registry as setup() + opening the file left it; captures diff against it
  -- to pin first-use registrations (see child.lua's capture)
  C.settle()
  C.post_setup = C.registry_state()
  return ctx
end

local function add(ctx, over)
  local sl, el = over.sl or 11, over.el or over.sl or 11
  over.sl, over.el = nil, nil
  local sel = {}
  for l = sl, el do
    sel[#sel + 1] = SOURCE[l]
  end
  return ctx.store.add(vim.tbl_deep_extend("force", {
    file = ctx.file,
    range = { sl = sl, el = el },
    kind = "line",
    selected_text = sel,
    comment = "negative factors are clamped to 0 silently — intended?",
  }, over))
end

local function cursor(row, col)
  vim.api.nvim_win_set_cursor(0, { row, col or 0 })
  require("obelus.render").on_cursor()
end

-- the chat's docked reply box is revealed by deferred work: settle, then REQUIRE
-- it (a chat that never finished opening must fail the scenario, not be captured)
local function wait_chat(panel)
  C.settle()
  local g = panel.geom()
  assert(g ~= nil and g.input_win ~= nil and not g.input_pending_reveal, "chat did not finish opening")
end

-- ── inline annotations (bands disabled: signs + line tint + eol preview) ──────
scenario("annotations_linewise_charwise", function()
  local ctx = fresh({ render = { bands = { enabled = false } } })
  add(ctx, { sl = 11, el = 13 })
  add(ctx, {
    sl = 20,
    el = 20,
    kind = "char",
    range = { sl = 20, el = 20, sc = 9, ec = 13 },
    selected_text = { "total" },
    comment = "name this `sum`?\nsecond line of the note",
  })
  add(ctx, { sl = 4, ask = true, comment = "why not math.max(lo, math.min(x, hi))?" })
  require("obelus.render").render_all()
  cursor(1)
  C.settle()
end)

-- a settled conversation: you -> agent -> you -> agent (markdown-heavy last turn)
local function conversation(ctx, over)
  local c = add(ctx, over or {})
  ctx.store.add_turn(c.id, "agent", "It is intended for inputs, but `factor` itself is never checked.")
  ctx.store.add_turn(c.id, "you", "so what happens with factor = -2? see @sample.lua")
  ctx.store.add_turn(c.id, "agent", LONG_AGENT)
  return c
end

-- a short settled thread: one exchange
local function short_thread(ctx, over)
  local c = add(ctx, over or {})
  ctx.store.add_turn(c.id, "agent", "Yes — **intended**. Inputs are percentages; see `clamp`.")
  return c
end

-- ── resolved / hidden states ──────────────────────────────────────────────────
scenario("resolved_hidden", function()
  local ctx = fresh({ render = { bands = { style = "inline" } } })
  local c = short_thread(ctx, { sl = 11 })
  ctx.store.resolve(c.id)
  add(ctx, { sl = 19, comment = "open thread next to a resolved one" })
  require("obelus.render").render_all()
  cursor(11) -- on the resolved comment: hidden => no band, only the ✓ sign
  C.settle()
end)

scenario("resolved_shown_band", function()
  local ctx = fresh({ render = { bands = { style = "inline" } } })
  local c = short_thread(ctx, { sl = 11 })
  ctx.store.resolve(c.id)
  require("obelus.render").toggle_resolved()
  cursor(11)
  C.settle()
end)

-- ── inline bands (style = "inline": virt_lines) ───────────────────────────────
scenario("band_inline_short", function()
  local ctx = fresh({ render = { bands = { style = "inline" } } })
  short_thread(ctx, { sl = 4, el = 9, tag = "math", comment = "clamp could be a one-liner" })
  add(ctx, { sl = 13, status = "needs_response", comment = "needs a reply" })
  require("obelus.render").render_all()
  cursor(5)
  C.settle()
end)

scenario("band_inline_long", function()
  local ctx = fresh({ render = { bands = { style = "inline" } } })
  conversation(ctx, { sl = 2 })
  require("obelus.render").render_all()
  cursor(2)
  C.settle()
end)

scenario("band_inline_long_hints", function()
  local ctx = fresh({ render = { bands = { style = "inline" }, hints = true } })
  conversation(ctx, { sl = 2 })
  require("obelus.render").render_all()
  cursor(2)
  C.settle()
end)

scenario("band_inline_ask_draft", function()
  local ctx = fresh({ render = { bands = { style = "inline", mode = "all" } } })
  add(ctx, { sl = 4, ask = true, comment = "why not math.max(lo, math.min(x, hi))?" })
  local c = short_thread(ctx, { sl = 7, el = 8 })
  ctx.store.add_turn(c.id, "you", "draft reply mentioning @sample.lua and @missing.lua")
  require("obelus.render").render_all()
  cursor(1)
  C.settle()
end)

-- ── popup band style (the default): the rooted hover preview ──────────────────
scenario("band_popup_preview", function()
  local ctx = fresh()
  conversation(ctx, { sl = 11, el = 13 })
  require("obelus.render").render_all()
  cursor(12)
  C.settle()
end)

-- ── thread chat view ──────────────────────────────────────────────────────────
scenario("chat_popup", function()
  local ctx = fresh()
  local c = conversation(ctx, { sl = 11, el = 13 })
  require("obelus.render").render_all()
  cursor(11)
  local panel = require("obelus.panel")
  panel.open_thread(c.id, true)
  wait_chat(panel)
  C.settle()
end)

scenario("chat_popup_hints", function()
  local ctx = fresh({ render = { hints = true } })
  local c = short_thread(ctx, { sl = 11 })
  require("obelus.render").render_all()
  cursor(11)
  local panel = require("obelus.panel")
  panel.open_thread(c.id, true)
  wait_chat(panel)
  C.settle()
end)

scenario("chat_sidebar", function()
  local ctx = fresh({ mode = "sidebar" })
  local c = conversation(ctx, { sl = 11, el = 13 })
  require("obelus.render").render_all()
  cursor(11)
  local panel = require("obelus.panel")
  panel.open_thread(c.id, false)
  wait_chat(panel)
  C.settle()
end)

-- ── threads sidebar panel (one representative list) ───────────────────────────
scenario("panel_list", function()
  local ctx = fresh({ mode = "sidebar" })
  short_thread(ctx, { sl = 4, tag = "math" })
  conversation(ctx, { sl = 11, el = 13 })
  local r = short_thread(ctx, { sl = 19 })
  ctx.store.resolve(r.id)
  add(ctx, { sl = 24, ask = true, comment = "is total ever nil?" })
  require("obelus.render").render_all()
  cursor(1)
  require("obelus.panel").open()
  C.settle()
end)

-- ── progress / spinner (frames frozen: see fresh()) ───────────────────────────
-- streaming into an inline band: eol spinner + the live (grey) agent turn
scenario("stream_inline_band", function()
  local ctx = fresh({ render = { bands = { style = "inline" } } })
  local c = short_thread(ctx, { sl = 11 })
  require("obelus.render").render_all()
  cursor(11)
  require("obelus").chat_send(c.id, "and for factor = -2?", "send")
  ctx.F.delta("Let me check `clamp`… ")
  ctx.F.block_start()
  ctx.F.delta("With `factor = -2` every value maps to **0**.")
  C.settle() -- the first (and only) progress tick renders frame 2 everywhere
end)

-- streaming with no text yet: the in-band "thinking" spinner
scenario("stream_inline_band_waiting", function()
  local ctx = fresh({ render = { bands = { style = "inline" } } })
  local c = short_thread(ctx, { sl = 11 })
  require("obelus.render").render_all()
  cursor(11)
  require("obelus").chat_send(c.id, "and for factor = -2?", "send")
  C.settle()
end)

-- streaming into the popup chat (in-box spinner, live turn)
scenario("stream_chat_popup", function()
  local ctx = fresh()
  local c = short_thread(ctx, { sl = 11 })
  require("obelus.render").render_all()
  cursor(11)
  local panel = require("obelus.panel")
  panel.open_thread(c.id, true)
  wait_chat(panel)
  require("obelus").chat_send(c.id, "and for factor = -2?", "send")
  ctx.F.delta("With `factor = -2` every value maps to **0**.")
  C.settle()
end)

-- a job for a thread whose file has no open buffer: the corner float
scenario("progress_corner", function()
  local ctx = fresh({ progress = { display = "corner" } })
  local c = short_thread(ctx, { sl = 11 })
  require("obelus.render").render_all()
  cursor(1)
  require("obelus").chat_send(c.id, "and for factor = -2?", "send")
  C.settle()
end)

-- finish: the brief ✓ on the worked line. Its 2000 ms clear is a virtual-clock
-- timer, so it is still pending at capture however long the host takes.
scenario("progress_finish_ok", function()
  local ctx = fresh({ render = { bands = { style = "inline" } } })
  local c = short_thread(ctx, { sl = 11 })
  require("obelus.render").render_all()
  cursor(11)
  require("obelus").chat_send(c.id, "and for factor = -2?", "send")
  ctx.F.delta("Every value maps to **0**.")
  C.settle()
  ctx.F.finish(true, "sess-1")
end)

-- …and 2000 virtual ms later the ✓ has cleared (the band stays, the eol mark goes)
scenario("progress_finish_cleared", function()
  local ctx = fresh({ render = { bands = { style = "inline" } } })
  local c = short_thread(ctx, { sl = 11 })
  require("obelus.render").render_all()
  cursor(11)
  require("obelus").chat_send(c.id, "and for factor = -2?", "send")
  ctx.F.delta("Every value maps to **0**.")
  C.settle()
  ctx.F.finish(true, "sess-1")
  C.advance(2000)
end)

-- ── composers ─────────────────────────────────────────────────────────────────
-- the quick-reply float (title "reply", footer hints on), with an @mention typed
scenario("compose_quick_reply_hints", function()
  local ctx = fresh({ render = { bands = { style = "inline" }, hints = true } })
  local c = short_thread(ctx, { sl = 11 })
  require("obelus.render").render_all()
  cursor(11)
  require("obelus").quick_reply(c.id)
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "look at @sample.lua and @nope.lua please" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  C.settle()
end)

-- the new-comment composer (hints off), via the user-facing entry point
scenario("compose_comment", function()
  fresh()
  cursor(14)
  require("obelus").comment() -- the real entry point: capture.comment_normal
  C.settle()
end)

-- ── obelus.api: an extension backend's non-file buffer, and the approve prompt ──
local GUIDE = {
  "# Recursion",
  "",
  "A recursive function calls itself on a smaller input.",
  "Every recursion needs a base case that stops it.",
  "",
  "Example: factorial(n) = n * factorial(n - 1)",
}

-- an in-memory backend owning "memo://" buffers, seeded with `threads`; shows
-- "memo://guide/recursion" in the current window. ctx.sends collects each turn's
-- emit callback so a scenario can stream into it.
local function memo_guide(ctx, threads)
  ctx.sends = {}
  require("obelus.api").register_backend({
    name = "memo",
    schemes = { "memo" },
    match = function(b)
      return vim.api.nvim_buf_get_name(b):match("^memo://") ~= nil
    end,
    store = {
      list = function()
        return vim.deepcopy(threads)
      end,
      create = function(_, new)
        return { id = "new", range = new.range, turns = { { author = "you", text = new.text } } }
      end,
      update = function() end,
      delete = function() end,
      resolve = function() end,
    },
    transport = {
      send = function(_, emit)
        ctx.sends[#ctx.sends + 1] = emit
      end,
    },
  })
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(buf, "memo://guide/recursion")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, GUIDE)
  vim.api.nvim_set_current_buf(buf)
  return buf
end

local MEMO_THREAD = {
  id = 1,
  range = { sl = 4, el = 4 },
  turns = {
    { author = "you", text = "what counts as a base case here?" },
    { author = "agent", text = "The input where the answer is **known** without recursing: `factorial(0) = 1`." },
  },
}

-- a backend thread rendered as an inline band on the backend's buffer
scenario("api_backend_band", function()
  local ctx = fresh({ render = { bands = { style = "inline" } } })
  memo_guide(ctx, { MEMO_THREAD })
  cursor(4)
  C.settle()
end)

-- the popup thread view of a backend thread, with a reply streaming in through
-- the backend's transport (spinner labelled with the backend's name)
scenario("api_backend_thread_stream", function()
  local ctx = fresh()
  memo_guide(ctx, { MEMO_THREAD })
  cursor(4)
  local panel = require("obelus.panel")
  panel.open_thread("api:memo:1", true)
  wait_chat(panel)
  require("obelus").chat_send("api:memo:1", "and for fibonacci?", "send")
  ctx.sends[1]({ type = "start" })
  ctx.sends[1]({ type = "delta", text = "Two base cases: `fib(0) = 0` and `fib(1) = 1`." })
  C.settle()
end)

-- the approve prompt as it first appears: unfocused, Deny selected
scenario("api_approve_prompt", function()
  fresh()
  require("obelus.api").approve({
    summary = "Write 3 flashcards to the deck 'recursion'",
    details = "base case · recursive case · stack depth",
    on_result = function() end,
  })
  C.settle()
end)

-- the review's blocked-loop case, with a real UI: focus, queue `a` (typeahead and
-- pending input), block the loop past the unarmed window, let it arm, then run
-- what is left of the typeahead. The prompt must still be open, focused and
-- undecided (a decision would show as a notification and close the float).
scenario("api_approve_queued_typeahead", function()
  fresh()
  require("obelus.api").approve({
    summary = "Write 3 flashcards to the deck 'recursion'",
    on_result = function(v)
      vim.notify("approval result: " .. tostring(v))
    end,
  })
  C.settle()
  assert(require("obelus.api").approve_focus(), "focus failed")
  vim.api.nvim_feedkeys("a", "t", false)
  vim.api.nvim_input("a")
  vim.uv.sleep(750)
  C.advance(700) -- the unarmed window's timer: drain, then a scheduled drain + arm
  C.settle()
  assert(require("obelus.approve")._active().armed, "prompt did not arm")
  vim.api.nvim_feedkeys("", "x", false)
  C.settle()
end)

-- Enter typed (processed normally) while the focused prompt is still UNARMED
-- denies at once, like Esc/q/<C-c> (Luodda parity): the float is gone and the
-- decision shows as a notification
scenario("api_approve_enter_unarmed", function()
  fresh()
  require("obelus.api").approve({
    summary = "Write 3 flashcards to the deck 'recursion'",
    on_result = function(v)
      vim.notify("approval result: " .. tostring(v))
    end,
  })
  C.settle()
  assert(require("obelus.api").approve_focus(), "focus failed")
  assert(not require("obelus.approve")._active().armed, "should still be unarmed")
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  C.settle()
end)

-- ── setup / keymap registration path ──────────────────────────────────────────
scenario("registration", function()
  fresh()
end, { kind = "registration", sizes = { { 80, 24 } } })

-- ── harness self-tests (hidden: run only when OBELUS_UI_ONLY names them exactly;
-- see tests/ui/selftest.sh). Never part of the baseline suite.
scenario("_selftest_hang", function()
  -- an unresponsive child: the parent's guard (or the supervisor) must stop it.
  -- OBELUS_UI_HANG_MAX_MS bounds the loop so a self-test that FAILS to stop it
  -- (e.g. under a teardown mutation) cannot leave it running for ever.
  local max = tonumber(vim.env.OBELUS_UI_HANG_MAX_MS or "")
  local deadline = max and vim.uv.hrtime() + max * 1e6
  while not deadline or vim.uv.hrtime() < deadline do
  end
  os.exit(0)
end, { hidden = true, sizes = { { 80, 24 } } })

scenario("_selftest_error", function()
  error("deliberate scenario failure")
end, { hidden = true, sizes = { { 80, 24 } } })

function S.run(name)
  for _, sc in ipairs(S.list) do
    if sc.name == name then
      sc.fn()
      return true
    end
  end
  error("unknown scenario " .. name)
end

return S
