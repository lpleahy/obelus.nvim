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
