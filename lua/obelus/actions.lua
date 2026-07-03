local store = require("obelus.store")
local format = require("obelus.format")

-- The agent write-back protocol. We tell the dispatched agent to record, in a
-- per-job `.ai/review-actions-<key>.json`, what it did with each comment (beyond
-- editing files); after the run we read + apply that file so the agent can
-- resolve, ask, note, or re-anchor its own threads. Keyed per dispatch (not one
-- shared file) so two concurrent dispatches can never clobber each other's write.
local M = {}

function M.filename(key)
  return "review-actions-" .. key .. ".json"
end

function M.path(key)
  return store.root() .. "/.ai/" .. M.filename(key)
end

---Instructions appended to the dispatch prompt: the schema + the comment ids.
---`key` names the exact per-job file the agent must write.
function M.instructions(comments, key)
  local n = #(comments or {})
  local filename = M.filename(key)
  local lines = {
    "---",
    "## Review protocol — REQUIRED, be diligent",
    "",
    ("You have ALL %d open review comments together, on purpose: they may be related, so"):format(n),
    "consider them as a set and address them coherently using the shared context.",
    "",
    "You MUST account for EVERY comment below — leave NONE unhandled. After your edits,",
    "WRITE a JSON file at `.ai/" .. filename .. "` in the project root: an array with one",
    "entry PER comment id listed below (all of them, no omissions). Each entry:",
    "",
    '  { "comment_id": "<id>",',
    '    "action": "resolve" | "needs_response" | "reply" | "move",',
    '    "message": "<text — for needs_response / reply>",',
    '    "line": <number>  // for move: the new line the comment refers to',
    "  }",
    "",
    "- resolve: you completed the requested change. PREFER this — actually do the work.",
    '- needs_response: you genuinely need input to proceed; ask a specific question in "message".',
    '- reply: leave a note (e.g. why no change was needed) without resolving; put it in "message".',
    '- move: you relocated the code; give the new "line".',
    "",
    "Do not stop until every comment has an entry. Write ONLY valid JSON. The comments:",
  }
  for _, c in ipairs(comments or {}) do
    local first = (vim.split(c.comment or "", "\n")[1] or ""):sub(1, 80)
    lines[#lines + 1] = string.format("- %s  %s:%s  — %s", c.id, format.relpath(c.file), format.range_label(c), first)
  end
  return table.concat(lines, "\n")
end

local VALID_ACTIONS = { resolve = true, reopen = true, needs_response = true, reply = true, move = true }

-- message is optional, but when present it must be a string — a non-string
-- message (e.g. an agent that emits a number/table) skips the WHOLE entry rather
-- than getting silently tostring'd into the thread.
local function valid_message(a)
  return a.message == nil or type(a.message) == "string"
end

---Read, apply, and consume the keyed actions file for `key` — falling back to the
---LEGACY un-suffixed `.ai/review-actions.json` when the keyed file is absent (a
---batch session resumed from an old round still remembers the old path). Returns
---the count of valid entries applied.
---@param key string
---@param allowed table<string, true>? comment ids this dispatch may touch; entries
---  for ids outside it are skipped (an agent can't poison unrelated threads). nil
---  means unrestricted.
function M.apply(key, allowed)
  local path = M.path(key)
  if vim.fn.filereadable(path) == 0 then
    path = store.root() .. "/.ai/review-actions.json" -- legacy fallback
    if vim.fn.filereadable(path) == 0 then
      return 0
    end
  end
  local filename = vim.fn.fnamemodify(path, ":t")
  local ok, list = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  vim.fn.delete(path) -- consume it regardless
  if not ok or type(list) ~= "table" then
    vim.notify("obelus: agent wrote invalid " .. filename .. " — ignored", vim.log.levels.ERROR)
    return 0
  end

  local n = 0
  for _, a in ipairs(list) do
    if
      type(a) == "table"
      and type(a.comment_id) == "string"
      and VALID_ACTIONS[a.action]
      and valid_message(a)
      and (not allowed or allowed[a.comment_id])
    then
      local c = store.get(a.comment_id)
      if c then
        local applied = true
        if a.action == "resolve" then
          store.resolve(c.id)
        elseif a.action == "reopen" then
          store.reopen(c.id)
        elseif a.action == "needs_response" then
          if a.message and a.message ~= "" then
            store.add_turn(c.id, "agent", a.message)
          end
          store.update(c.id, { status = "needs_response" })
        elseif a.action == "reply" then
          if a.message and a.message ~= "" then
            store.add_turn(c.id, "agent", a.message)
          end
        elseif a.action == "move" then
          local sl = a.line or (type(a.range) == "table" and a.range[1])
          local el = (type(a.range) == "table" and a.range[2]) or sl
          if type(sl) == "number" and type(el) == "number" then
            c.range.sl = sl
            c.range.el = el
            c.extmark_id = nil -- re-anchor on next render
            store.update(c.id, {})
          else
            applied = false -- bad/missing line: skip the move entirely, never clamp
          end
        end
        if applied then
          n = n + 1
        end
      end
    end
  end
  return n
end

-- Delete stale per-job actions files (crashed/abandoned runs) so `.ai/` doesn't
-- accumulate forever. NEVER delete a file younger than 24h — a concurrent nvim
-- instance in the same project may be mid-dispatch with its own keyed file.
function M.sweep()
  local dir = store.root() .. "/.ai"
  local cutoff = os.time() - 24 * 60 * 60
  local stale = vim.fn.glob(dir .. "/review-actions-*.json", false, true)
  -- the legacy un-suffixed file too (the glob's literal dash excludes it): apply()'s
  -- legacy fallback would otherwise treat an arbitrarily old leftover as a fresh
  -- write-back forever — sweeping it bounds that bridge to 24h, while a genuinely
  -- fresh legacy write (a session resumed from an old round) is younger and survives
  stale[#stale + 1] = dir .. "/review-actions.json"
  for _, path in ipairs(stale) do
    local ft = vim.fn.getftime(path)
    if ft >= 0 and ft < cutoff then
      vim.fn.delete(path)
    end
  end
end

return M
