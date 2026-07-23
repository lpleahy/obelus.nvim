-- stream: stream-json line parsing + the stateful feed()/text() collector.
T.describe("stream")

local M = require("obelus.stream")

-- Encode an event table as one stream-json line (trailing newline, the framing
-- the collector expects).
local function line(ev)
  return vim.json.encode(ev) .. "\n"
end

local function delta(text)
  return {
    type = "stream_event",
    event = { type = "content_block_delta", delta = { type = "text_delta", text = text } },
  }
end

local function message(text)
  return { type = "assistant", message = { content = { { type = "text", text = text } } } }
end

local function result(text, session, is_error)
  return { type = "result", result = text, session_id = session, is_error = is_error }
end

-- parse_line ------------------------------------------------------------

T.it("parse_line: system event yields a session kind", function()
  local ev = M.parse_line(vim.json.encode({ type = "system", session_id = "sess-1" }))
  T.eq(ev, { kind = "session", session = "sess-1" })
end)

T.it("parse_line: content_block_delta text_delta yields a delta", function()
  local ev = M.parse_line(vim.json.encode(delta("Hel")))
  T.eq(ev, { kind = "delta", text = "Hel" })
end)

T.it("parse_line: assistant message with multiple text blocks joins them with a blank line", function()
  -- separate text blocks are separate pieces of prose (tool_use sat between
  -- them) — butting them together produced "…before reporting.I read through…"
  local raw = vim.json.encode({
    type = "assistant",
    message = { content = { { type = "text", text = "Hello" }, { type = "text", text = "world" } } },
  })
  local ev = M.parse_line(raw)
  T.eq(ev, { kind = "message", text = "Hello\n\nworld" })
end)

T.it("parse_line: result event carries session and is_error", function()
  local ev = M.parse_line(vim.json.encode(result("done", "sess-9", true)))
  T.eq(ev, { kind = "result", text = "done", session = "sess-9", is_error = true })
end)

T.it("parse_line: result event defaults is_error to false when absent", function()
  local ev = M.parse_line(vim.json.encode({ type = "result", result = "done", session_id = "sess-9" }))
  T.eq(ev.is_error, false)
end)

T.it("parse_line: garbage / empty / non-JSON lines yield nil", function()
  T.is_nil(M.parse_line(nil))
  T.is_nil(M.parse_line(""))
  T.is_nil(M.parse_line("not json at all"))
  T.is_nil(M.parse_line(vim.json.encode({ type = "unknown_shape" })))
end)

-- collector: feed chunking ----------------------------------------------

T.it("collector: a line split across feed() calls reassembles, delta seen once", function()
  local seen = {}
  local c = M.collector(function(t)
    seen[#seen + 1] = t
  end)
  local raw = line(delta("Hello"))
  local mid = math.floor(#raw / 2)
  c.feed(raw:sub(1, mid))
  T.eq(c.text(), "") -- no newline yet, nothing parsed
  c.feed(raw:sub(mid + 1))
  T.eq(c.text(), "Hello")
  T.eq(seen, { "Hello" }) -- exactly one on_update, not one per feed() call
end)

T.it("collector: several lines in one feed() chunk all parse", function()
  local c = M.collector()
  c.feed(line(delta("A")) .. line(delta("B")) .. line(delta("C")))
  T.eq(c.text(), "ABC")
end)

-- collector: delta-over-result precedence --------------------------------

T.it("collector: deltas accumulate; a later result does not replace them", function()
  local c = M.collector()
  c.feed(line(delta("stream")))
  c.feed(line(delta("ed reply")))
  c.feed(line(result("short final", "sess-x", false)))
  T.eq(c.text(), "streamed reply") -- deltas win, result text discarded
  T.eq(c.session(), "sess-x") -- but session from the result IS adopted
end)

-- collector: message-only fallback ---------------------------------------

T.it("collector: with no deltas, assistant messages accumulate as separate paragraphs", function()
  local c = M.collector()
  c.feed(line(message("hi")))
  c.feed(line(message("there")))
  T.eq(c.text(), "hi\n\nthere")
end)

T.it("collector: a new text block between delta runs becomes a paragraph break", function()
  local block_start =
    { type = "stream_event", event = { type = "content_block_start", content_block = { type = "text" } } }
  local c = M.collector()
  c.feed(line(block_start)) -- the FIRST block: no leading separator
  c.feed(line(delta("Let me check one thing before reporting.")))
  c.feed(line(block_start)) -- tools ran; the agent starts a new message
  c.feed(line(delta("I read through it.")))
  T.eq(c.text(), "Let me check one thing before reporting.\n\nI read through it.")
end)

T.it("collector: an empty text block leaves no trailing separator (lazy)", function()
  local block_start =
    { type = "stream_event", event = { type = "content_block_start", content_block = { type = "text" } } }
  local c = M.collector()
  c.feed(line(delta("done.")))
  c.feed(line(block_start)) -- opens but never produces a delta
  T.eq(c.text(), "done.", "no dangling blank paragraph")
end)

T.it("collector: a result DOES replace acc when no deltas ever arrived", function()
  local c = M.collector()
  c.feed(line(message("hi ")))
  c.feed(line(result("final replaces", "sess-y", false)))
  T.eq(c.text(), "final replaces")
  T.eq(c.session(), "sess-y")
end)

-- collector: unterminated final line -------------------------------------

T.it("collector: a trailing chunk with no newline is dropped", function()
  local c = M.collector()
  c.feed(line(delta("first")))
  T.eq(c.text(), "first")
  c.feed(vim.json.encode(delta("second"))) -- no trailing newline: process end mid-line
  T.eq(c.text(), "first") -- unchanged: unterminated remainder never parses
end)

-- collector: on_update sequencing -----------------------------------------

T.it("collector: on_update fires once per accumulating event with text-so-far", function()
  local seen = {}
  local c = M.collector(function(t)
    seen[#seen + 1] = t
  end)
  c.feed(line({ type = "system", session_id = "s1" })) -- no on_update: not accumulating
  c.feed(line(delta("A")))
  c.feed(line(delta("B")))
  c.feed(line(result("ignored", "s1", false))) -- no on_update: result never calls it
  T.eq(seen, { "A", "AB" })
end)

-- collector: nil feed --------------------------------------------------

T.it("collector: feed(nil) (process end) is a no-op", function()
  local c = M.collector()
  c.feed(line(delta("A")))
  T.eq(c.text(), "A")
  c.feed(nil)
  T.eq(c.text(), "A")
  T.is_nil(c.session())
end)

-- collector: final_start() (narration boundary tracking) --------------------

local block_start =
  { type = "stream_event", event = { type = "content_block_start", content_block = { type = "text" } } }

T.it("final_start: a single block stays 0", function()
  local c = M.collector()
  c.feed(line(delta("hello ")))
  c.feed(line(delta("world")))
  T.eq(c.text(), "hello world")
  T.eq(c.final_start(), 0, "no second block ever opened")
end)

T.it("final_start: two blocks — text from final_start()+1 is exactly the second block", function()
  local c = M.collector()
  c.feed(line(block_start)) -- first block: no leading separator
  c.feed(line(delta("Let me check one thing.")))
  c.feed(line(block_start)) -- tools ran; a genuinely new block opens
  c.feed(line(delta("The fix is simple.")))
  local acc = c.text()
  T.eq(acc, "Let me check one thing.\n\nThe fix is simple.")
  T.eq(acc:sub(c.final_start() + 1), "The fix is simple.", "final_start lands right after the lazy separator")
end)

T.it("final_start: an empty second block (lazy sep never applied) leaves it unchanged", function()
  local c = M.collector()
  c.feed(line(delta("done.")))
  local before = c.final_start()
  c.feed(line(block_start)) -- opens but never produces a delta
  T.eq(c.text(), "done.", "no dangling blank paragraph")
  T.eq(c.final_start(), before, "an empty block never becomes 'the latest' — nothing was ever appended for it")
end)

T.it("final_start: three blocks — always tracks the LATEST one", function()
  local c = M.collector()
  c.feed(line(block_start))
  c.feed(line(delta("first")))
  c.feed(line(block_start))
  c.feed(line(delta("second")))
  c.feed(line(block_start))
  c.feed(line(delta("third")))
  T.eq(c.text():sub(c.final_start() + 1), "third")
end)

T.it("final_start: a result replacing acc (no deltas ever arrived) resets it to 0", function()
  local c = M.collector()
  c.feed(line(block_start))
  c.feed(line(message("hi")))
  c.feed(line(result("final replaces", "sess-z", false)))
  T.eq(c.text(), "final replaces")
  T.eq(c.final_start(), 0)
end)

-- M.collapse: the CHAT stream-finish narration collapse -----------------------

T.it("collapse: mode 'keep' always returns the full acc", function()
  T.eq(M.collapse("A\n\nB", 3, "keep"), "A\n\nB")
end)

T.it("collapse: final_start 0 (single block) returns the full acc", function()
  T.eq(M.collapse("just one block", 0, nil), "just one block")
end)

T.it("collapse: slices from final_start, stripping a leading separator run", function()
  local acc = "Let me check.\n\nThe fix is simple."
  local fs = #"Let me check.\n\n" -- final_start as stream.lua would report it
  T.eq(M.collapse(acc, fs, nil), "The fix is simple.")
end)

T.it("collapse: strips leading blank lines even if final_start landed a byte early", function()
  -- defensive: even if final_start pointed at the START of the separator run
  -- instead of after it, the result must never carry leading blank lines
  local acc = "narration\n\nreal answer"
  local fs = #"narration"
  T.eq(M.collapse(acc, fs, nil), "real answer")
end)

T.it("collapse: guard — an empty final block falls back to the full acc", function()
  local acc = "Let me check.\n\n"
  local fs = #acc
  T.eq(M.collapse(acc, fs, nil), acc, "final_start >= #acc: nothing to collapse to")
end)

T.it("collapse: guard — a whitespace-only final block falls back to the full acc", function()
  local acc = "Let me check.\n\n   "
  local fs = #"Let me check.\n\n"
  T.eq(M.collapse(acc, fs, nil), acc, "never store an empty reply that had real narration")
end)

T.it("cli run_stream: the collector callback can call back into the collector (scoping regression)", function()
  -- `local col = stream.collector(function() … col.final_start() … end)` captured
  -- the GLOBAL col (nil): the closure compiles before the local enters scope.
  -- Drive the REAL cli transport with a stubbed vim.system that feeds stdout.
  local ctx = T.fresh({ transport = { dispatch = "cli", cli = { cmd = { "claude", "-p" } } } })
  local real_system = vim.system
  local fed_stdout
  vim.system = function(cmd, opts, on_exit)
    fed_stdout = opts.stdout
    return {
      kill = function() end,
      wait = function()
        return { code = 0, stdout = "" }
      end,
      pid = 1,
    }
  end
  local c = ctx.store.add(T.comment({ comment = "seed" }))
  require("obelus").chat_send(c.id, "hello", "send")
  T.ok(fed_stdout, "spawned with a stdout handler")
  local line = vim.json.encode({
    type = "stream_event",
    event = { type = "content_block_delta", delta = { type = "text_delta", text = "streamed!" } },
  }) .. "\n"
  local ok, err = pcall(fed_stdout, nil, line)
  vim.wait(100)
  vim.system = real_system
  T.ok(ok, "the delta callback did not error: " .. tostring(err))
  local turns = ctx.store.turns(ctx.store.get(c.id))
  local found = false
  for _, t in ipairs(turns) do
    if (t.text or ""):find("streamed!", 1, true) then
      found = true
    end
  end
  T.ok(found, "the streamed delta reached the store")
  ctx.store.abort(c.id)
end)

-- ── text_collector: the plain-text counterpart (transport.cli.output = "text") ──

T.it("text_collector: chunks accumulate verbatim and fire on_update", function()
  local updates = {}
  local C = M.text_collector(function(t)
    updates[#updates + 1] = t
  end)
  C.feed("Hello")
  C.feed(", world")
  C.feed(nil) -- ignored, never fires
  C.feed("") -- ignored, never fires
  T.eq(C.text(), "Hello, world")
  T.eq(updates, { "Hello", "Hello, world" })
  T.is_nil(C.session(), "a text stream carries no session id")
  T.eq(C.final_start(), 0, "no block boundaries in a text stream")
end)

T.it("text_collector: collapse keeps everything (final_start 0 guard)", function()
  local C = M.text_collector(nil)
  C.feed("narration…\n\nthe answer")
  T.eq(M.collapse(C.text(), C.final_start(), "collapse"), "narration…\n\nthe answer")
end)

T.it("cli run_stream (output=text): raw chunks reach the store; session comes from the log file", function()
  -- Drive the REAL cli transport with a stubbed vim.system playing an agy-shaped
  -- CLI: plain text on stdout, the conversation id only in the --log-file.
  local ctx = T.fresh({
    transport = {
      dispatch = "cli",
      cli = {
        cmd = { "fake-agy", "--sandbox" },
        prompt_flag = "-p",
        output = "text",
        flags = { resume = "--conversation", stream = {} },
        session = { flag = "--log-file", pattern = "Print mode: conversation=([%x%-]+)" },
      },
    },
  })
  local real_system = vim.system
  local seen_cmd, fed_stdout, exit_cb
  vim.system = function(cmd, opts, on_exit)
    seen_cmd, fed_stdout, exit_cb = cmd, opts.stdout, on_exit
    return { kill = function() end, pid = 1 }
  end
  local c = ctx.store.add(T.comment({ comment = "seed" }))
  require("obelus").chat_send(c.id, "hello", "send")
  vim.system = real_system
  T.ok(fed_stdout ~= nil and exit_cb ~= nil, "spawned with stdout + exit handlers")
  local logfile
  for i, a in ipairs(seen_cmd) do
    if a == "--log-file" then
      logfile = seen_cmd[i + 1]
    end
  end
  T.ok(logfile, "argv carries --log-file for session capture")
  fed_stdout(nil, "Hello ")
  fed_stdout(nil, "from agy")
  local fd = assert(io.open(logfile, "w"))
  fd:write("I0722 printmode.go:216] Print mode: conversation=cafe0000-0000-0000-0000-000000000042, sending message\n")
  fd:close()
  exit_cb({ code = 0, stderr = "" })
  T.wait_for(function()
    return (ctx.store.get(c.id) or {}).session_id ~= nil
  end)
  local cm = ctx.store.get(c.id)
  T.eq(cm.session_id, "cafe0000-0000-0000-0000-000000000042", "session id extracted from the log")
  local turns = ctx.store.turns(cm)
  local found = false
  for _, t in ipairs(turns) do
    if (t.text or ""):find("Hello from agy", 1, true) then
      found = true
    end
  end
  T.ok(found, "the raw text chunks reached the store as the reply")
end)

-- ── jsonl_collector: the generic line-JSON collector (output = "jsonl") ─────

local function jl_map(e)
  if e.t == "d" then
    return { delta = e.v }
  elseif e.t == "done" then
    return { final = e.v, session = e.sid }
  elseif e.t == "sid" then
    return { session = e.v }
  end
end

T.it("jsonl_collector: deltas accumulate; a final never truncates streamed deltas", function()
  local updates = {}
  local C = M.jsonl_collector(function(t)
    updates[#updates + 1] = t
  end, jl_map)
  C.feed('{"t":"sid","v":"s-1"}\n{"t":"d","v":"Hel"}\n')
  C.feed('{"t":"d","v":"lo"}\n{"t":"done","v":"short","sid":"s-2"}\n')
  T.eq(C.text(), "Hello", "final must not replace streamed deltas")
  T.eq(C.session(), "s-2", "later session wins")
  T.eq(updates, { "Hel", "Hello" })
end)

T.it("jsonl_collector: with no deltas the final IS the reply; junk lines are skipped", function()
  local C = M.jsonl_collector(nil, jl_map)
  C.feed("not json at all\n")
  C.feed('{"t":"done","v":"the whole reply","sid":"s-9"}\n')
  T.eq(C.text(), "the whole reply")
  T.eq(C.session(), "s-9")
  T.eq(C.final_start(), 0)
end)

T.it("jsonl_collector: a throwing map only drops that event", function()
  local C = M.jsonl_collector(nil, function(e)
    if e.boom then
      error("mapper bug")
    end
    return { delta = e.v }
  end)
  C.feed('{"boom":true}\n{"v":"ok"}\n')
  T.eq(C.text(), "ok")
end)
