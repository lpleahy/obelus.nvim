-- Parser for Claude Code's `--output-format stream-json` lines. Each input line
-- is one JSON event; we map it to a small normalized event for the chat to grow.
local M = {}

---@param line string one JSON line from the stream
---@return table|nil { kind = "session"|"delta"|"message"|"result", text?, session?, is_error? }
function M.parse_line(line)
  if not line or line == "" then
    return nil
  end
  local ok, e = pcall(vim.json.decode, line)
  if not ok or type(e) ~= "table" then
    return nil
  end

  if e.type == "system" and e.session_id then
    return { kind = "session", session = e.session_id }
  end

  -- token-level deltas (with --include-partial-messages)
  if
    e.type == "stream_event"
    and e.event
    and e.event.type == "content_block_delta"
    and e.event.delta
    and e.event.delta.type == "text_delta"
  then
    return { kind = "delta", text = e.event.delta.text or "" }
  end

  -- a NEW text block opening: the boundary between two pieces of prose the agent
  -- wrote as separate messages/blocks (e.g. "let me check X" → tools run → the
  -- real answer). The collector turns this into a paragraph break — without it
  -- the two butt together mid-sentence ("…before reporting.I read through it").
  if
    e.type == "stream_event"
    and e.event
    and e.event.type == "content_block_start"
    and e.event.content_block
    and e.event.content_block.type == "text"
  then
    return { kind = "block_start" }
  end

  -- whole assistant text block (when partial messages are off). Multiple text
  -- blocks in one message (prose around tool_use) join with a blank line, same
  -- reason as block_start above.
  if e.type == "assistant" and e.message and type(e.message.content) == "table" then
    local parts = {}
    for _, b in ipairs(e.message.content) do
      if b.type == "text" and b.text and b.text ~= "" then
        parts[#parts + 1] = b.text
      end
    end
    if #parts > 0 then
      return { kind = "message", text = table.concat(parts, "\n\n") }
    end
    return nil
  end

  if e.type == "result" then
    return { kind = "result", text = e.result, session = e.session_id, is_error = e.is_error == true }
  end

  return nil
end

-- Stateful collector over a stream-json stdout: buffers partial lines, parses each
-- complete one, and accumulates the reply text with the precedence rules the chat
-- depends on — deltas win over the final result (a late short result must not
-- truncate the streamed reply), whole-message events only count when no deltas ever
-- arrived. One collector per subprocess; feed() runs in vim.system's stdout callback
-- (a fast context), so `on_update(text)` must do its own vim.schedule.
-- An unterminated final line (no trailing newline before exit) is dropped by design:
-- stream-json is line-terminated, so a remainder is a truncated JSON record that
-- can't parse — never real reply text.
function M.collector(on_update)
  local linebuf, acc, got_delta, session = "", "", false, nil
  local pending_sep = false -- a new text block opened; separate it from prior prose
  -- byte offset in `acc` where the CURRENT (latest) text block began, AFTER its
  -- lazy separator (see the block_start/message handling below) — 0 while there's
  -- only ever been one block. Feeds narration greying (thread.build) and the CHAT
  -- stream-finish narration collapse (M.collapse) below; untouched by anything
  -- else about the delta/result precedence rules.
  local final_start = 0
  local C = {}

  function C.feed(data)
    if not data then
      return
    end
    linebuf = linebuf .. data
    while true do
      local nl = linebuf:find("\n")
      if not nl then
        break
      end
      local line = linebuf:sub(1, nl - 1)
      linebuf = linebuf:sub(nl + 1)
      local ev = M.parse_line(line)
      if ev then
        if ev.kind == "session" then
          session = ev.session
        elseif ev.kind == "block_start" then
          -- LAZY separator: applied only when the new block actually produces a
          -- delta, so an empty text block can't leave a trailing blank paragraph
          pending_sep = acc ~= ""
        elseif ev.kind == "delta" then
          if pending_sep then
            pending_sep = false
            if not acc:match("\n%s*$") then
              acc = acc .. "\n\n"
            end
            final_start = #acc -- the new latest block starts HERE, after the separator
          end
          acc = acc .. (ev.text or "")
          got_delta = true
          if on_update then
            on_update(acc)
          end
        elseif ev.kind == "message" and not got_delta then
          -- distinct assistant MESSAGES (prose → tools → more prose) join with a
          -- blank line, never butted together mid-sentence
          if acc ~= "" and ev.text and ev.text ~= "" then
            acc = acc .. "\n\n" .. ev.text
          else
            acc = acc .. (ev.text or "")
          end
          final_start = #acc - #(ev.text or "") -- each message IS its own latest block
          if on_update then
            on_update(acc)
          end
        elseif ev.kind == "result" then
          -- only adopt the final result text if we never received streaming deltas;
          -- otherwise KEEP the accumulated deltas — the result can be a short final
          -- message (e.g. after a tool/file write) that would truncate the real reply
          if ev.text and ev.text ~= "" and not got_delta then
            acc = ev.text
            final_start = 0 -- acc was just wholesale replaced: back to "a single block"
          end
          session = ev.session or session
        end
      end
    end
  end

  function C.text()
    return acc
  end

  function C.session()
    return session
  end

  -- byte offset in C.text() where the latest text block begins (after any lazy
  -- separator); 0 when there's only ever been one block.
  function C.final_start()
    return final_start
  end

  return C
end

-- Collector for a PLAIN-TEXT streaming CLI (transport.cli.output = "text", e.g.
-- Google's `agy -p`): stdout chunks ARE the reply — no framing, no events. Same
-- interface as M.collector so transport/cli.lua treats the two uniformly:
--   session()     — always nil (a text stream carries no session id; capture it
--                   out-of-band via transport.cli.session's log-file extraction)
--   final_start() — always 0 (no block boundaries → M.collapse keeps everything,
--                   and thread.build's narration-greying sees one single block)
function M.text_collector(on_update)
  local acc = ""
  local C = {}

  function C.feed(data)
    if not data or data == "" then
      return
    end
    acc = acc .. data
    if on_update then
      on_update(acc)
    end
  end

  function C.text()
    return acc
  end

  function C.session()
    return nil
  end

  function C.final_start()
    return 0
  end

  return C
end

-- Collector for a GENERIC line-delimited-JSON stream (transport.cli.output =
-- "jsonl"): each stdout line is one JSON event, and `map(ev)` — the user's /
-- preset's transport.cli.events — normalizes it to any of
--   { delta = "text chunk", session = "id", final = "whole reply",
--     block = "a whole message/paragraph" }
-- (nil/{}: ignore the event). `block` is for CLIs that emit MESSAGE-granular
-- text (codex item.completed, opencode text parts): appended like a delta but
-- separated from prior text by a blank line. Same precedence rule as the
-- claude collector: a `final` only replaces the accumulation when no
-- deltas/blocks ever arrived, so a short trailing summary can't truncate the
-- streamed reply. Interface matches M.collector/M.text_collector; final_start
-- stays 0 (no narration bookkeeping).
function M.jsonl_collector(on_update, map)
  local linebuf, acc, got_delta, session = "", "", false, nil
  local C = {}

  function C.feed(data)
    if not data then
      return
    end
    linebuf = linebuf .. data
    while true do
      local nl = linebuf:find("\n")
      if not nl then
        break
      end
      local line = linebuf:sub(1, nl - 1)
      linebuf = linebuf:sub(nl + 1)
      local okd, e = pcall(vim.json.decode, line)
      if okd and type(e) == "table" then
        local okm, ev = pcall(map, e)
        if okm and type(ev) == "table" then
          if ev.session and ev.session ~= "" then
            session = ev.session
          end
          if ev.delta and ev.delta ~= "" then
            acc = acc .. ev.delta
            got_delta = true
            if on_update then
              on_update(acc)
            end
          end
          if ev.block and ev.block ~= "" then
            acc = (acc ~= "" and acc .. "\n\n" or "") .. ev.block
            got_delta = true
            if on_update then
              on_update(acc)
            end
          end
          if ev.final and ev.final ~= "" and not got_delta then
            acc = ev.final
            if on_update then
              on_update(acc)
            end
          end
        end
      end
    end
  end

  function C.text()
    return acc
  end

  function C.session()
    return session
  end

  function C.final_start()
    return 0
  end

  return C
end

---Compute the text a CHAT stream-finish should store, honoring render.narration:
---  "keep"     — always the full `acc`.
---  "collapse" (default, any other value) — ONLY the latest block's text (`acc`
---               from `final_start`, with one leading separator run of blank
---               lines stripped) — the interim narration and its \n\n
---               separators vanish together.
---Guard: nothing to collapse (`final_start` is 0/past the end of `acc`) or the
---sliced tail is empty/whitespace-only (stream ended right after a block_start,
---or narration_end lands past #acc) — never store an empty reply that had real
---narration; fall back to the full `acc`.
---@param acc string
---@param final_start integer
---@param mode? "collapse"|"keep"
function M.collapse(acc, final_start, mode)
  if mode == "keep" or not final_start or final_start <= 0 or final_start >= #acc then
    return acc
  end
  local tail = acc:sub(final_start + 1):match("^\n*(.*)$")
  if not tail or tail:match("^%s*$") then
    return acc -- guard: the "final block" was empty — keep the full narration
  end
  return tail
end

return M
