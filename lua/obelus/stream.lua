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

  -- whole assistant text block (when partial messages are off)
  if e.type == "assistant" and e.message and type(e.message.content) == "table" then
    local parts = {}
    for _, b in ipairs(e.message.content) do
      if b.type == "text" and b.text then
        parts[#parts + 1] = b.text
      end
    end
    if #parts > 0 then
      return { kind = "message", text = table.concat(parts) }
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
        elseif ev.kind == "delta" then
          acc = acc .. (ev.text or "")
          got_delta = true
          if on_update then
            on_update(acc)
          end
        elseif ev.kind == "message" and not got_delta then
          acc = acc .. (ev.text or "")
          if on_update then
            on_update(acc)
          end
        elseif ev.kind == "result" then
          -- only adopt the final result text if we never received streaming deltas;
          -- otherwise KEEP the accumulated deltas — the result can be a short final
          -- message (e.g. after a tool/file write) that would truncate the real reply
          if ev.text and ev.text ~= "" and not got_delta then
            acc = ev.text
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

  return C
end

return M
