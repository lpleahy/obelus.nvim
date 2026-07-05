local config = require("obelus.config")

local M = {}

---@type table[]
M.comments = {}

---@type table[] Batch conversation records (one shared agent session each).
M.batches = {}

-- Sticky tagging: while set, every NEW thread inherits this tag, so you can make a
-- run of related comments and batch them together. nil = tagging mode off.
M.active_tag = nil

local seq = 0
local bseq = 0
local root_cache = nil
local loaded_root = nil

local function opts()
  return config.options
end

function M.root()
  if root_cache == nil then
    root_cache = opts().root()
  end
  return root_cache
end

function M.reset_root()
  root_cache = nil
end

local function data_path(root)
  local dir = vim.fn.stdpath("data") .. "/obelus"
  vim.fn.mkdir(dir, "p")
  return dir .. "/" .. vim.fn.sha256(root) .. ".jsonl"
end

function M.store_path()
  local root = M.root()
  if opts().persist.backend == "jsonl" then
    return root .. "/" .. opts().persist.path
  end
  return data_path(root)
end

function M.next_id()
  seq = seq + 1
  return string.format("%d-%d", os.time(), seq)
end

---@param comment table
function M.add(comment)
  comment.id = comment.id or M.next_id()
  comment.created_at = comment.created_at or os.time()
  comment.status = comment.status or "open" -- "open" | "needs_response" | "resolved"
  if comment.tag == nil and M.active_tag then
    comment.tag = M.active_tag -- sticky tagging mode: new threads inherit the active tag
  end
  table.insert(M.comments, comment)
  if opts().persist.auto then
    M.save_soon()
  end
  return comment
end

function M.get(id)
  for _, c in ipairs(M.comments) do
    if c.id == id then
      return c
    end
  end
end

-- The project thread: ONE persisted meta record (`meta = true`) holding the
-- project-level conversation (see obelus.project() / review.do_respond's `c.meta`
-- branch) — a chat about the review as a WHOLE, not one file/range. `file` is the
-- project root (a directory, never a real annotation target) so it naturally never
-- matches store.by_file/render.place's per-buffer lookups; get-or-create is
-- idempotent (first call creates + persists it, every later call — this session or
-- a reloaded one — returns the SAME record). Built by hand rather than through
-- M.add: the meta thread is deliberately never tagged (M.add's sticky-tag
-- inheritance is for real, batchable threads) and never batched/pending (see
-- M.pending's `c.meta` guard below).
-- The existing meta record, or nil — NEVER creates. Surfaces that merely DISPLAY
-- the project thread (the sidebar's pinned row) use this: creating on every list
-- render meant two nvim instances on one project each planted their own meta
-- record just by opening the sidebar (last save then clobbered the other).
-- Creation is reserved for the deliberate action: obelus.project() / <prefix>a.
function M.get_meta()
  for _, c in ipairs(M.comments) do
    if c.meta then
      return c
    end
  end
end

function M.meta_thread()
  local existing = M.get_meta()
  if existing then
    return existing
  end
  local rec = {
    meta = true,
    file = M.root(),
    range = { sl = 1, el = 1 },
    kind = "line",
    selected_text = {},
    comment = "project thread",
    id = M.next_id(),
    created_at = os.time(),
    status = "open",
  }
  table.insert(M.comments, rec)
  if opts().persist.auto then
    M.save_soon()
  end
  return rec
end

function M.update(id, fields)
  local c = M.get(id)
  if c then
    for k, v in pairs(fields) do
      c[k] = v
    end
    if opts().persist.auto then
      M.save_soon()
    end
  end
  return c
end

function M.remove(id)
  for i, c in ipairs(M.comments) do
    if c.id == id then
      table.remove(M.comments, i)
      M.detach_from_batches(id)
      if opts().persist.auto then
        M.save_soon()
      end
      return c
    end
  end
end

-- Drop a deleted comment id from any batch it belonged to; if that empties an
-- open batch, close it so it can't linger as a (dead) continue target.
function M.detach_from_batches(comment_id)
  for _, b in ipairs(M.batches) do
    if b.comment_ids then
      for j = #b.comment_ids, 1, -1 do
        if b.comment_ids[j] == comment_id then
          table.remove(b.comment_ids, j)
        end
      end
      if #b.comment_ids == 0 and b.status == "open" then
        b.status = "done"
      end
    end
  end
end

-- Make a comment belong to exactly ONE batch: drop it from every OTHER batch's
-- members (closing any it empties). Prevents a retagged comment from living in
-- two open batches and getting its state clobbered twice. Membership is owned
-- SOLELY by batch.comment_ids — no back-ref written onto the comment (the caller
-- adds comment_id to the target batch's comment_ids itself); a c.batch_id field
-- used to be written here but nothing ever read it, and it went stale/dangling
-- across deletes.
function M.set_comment_batch(comment_id, batch_id)
  for _, b in ipairs(M.batches) do
    if b.id ~= batch_id and b.comment_ids then
      for j = #b.comment_ids, 1, -1 do
        if b.comment_ids[j] == comment_id then
          table.remove(b.comment_ids, j)
        end
      end
      if #b.comment_ids == 0 and b.status == "open" then
        b.status = "done"
      end
    end
  end
  if opts().persist.auto then
    M.save_soon()
  end
end

function M.clear()
  M.comments = {}
  M.batches = {}
  if opts().persist.auto then
    M.save_soon()
  end
end

function M.all()
  return M.comments
end

-- Batch records -------------------------------------------------------------
-- A Batch holds ONE shared agent session for a set of related comments, so we
-- can keep talking to the same agent across rounds (see obelus.batch).

function M.next_batch_id()
  bseq = bseq + 1
  return string.format("b-%d-%d", os.time(), bseq), bseq
end

---@param b table
function M.add_batch(b)
  local id, n = M.next_batch_id()
  b.id = b.id or id
  b.seq = b.seq or n -- human number ("#1") shown in the UI
  b.created_at = b.created_at or os.time()
  b.status = b.status or "open" -- "open" | "done"
  b.round = b.round or 1
  table.insert(M.batches, b)
  if opts().persist.auto then
    M.save_soon()
  end
  return b
end

function M.get_batch(id)
  for _, b in ipairs(M.batches) do
    if b.id == id then
      return b
    end
  end
end

function M.update_batch(id, fields)
  local b = M.get_batch(id)
  if b then
    for k, v in pairs(fields) do
      b[k] = v
    end
    if opts().persist.auto then
      M.save_soon()
    end
  end
  return b
end

function M.remove_batch(id)
  for i, b in ipairs(M.batches) do
    if b.id == id then
      table.remove(M.batches, i)
      if opts().persist.auto then
        M.save_soon()
      end
      return b
    end
  end
end

function M.batches_all()
  return M.batches
end

-- The most recent still-open batch (the continue target), or nil.
function M.open_batch()
  local found
  for _, b in ipairs(M.batches) do
    if b.status == "open" and (not found or (b.seq or 0) > (found.seq or 0)) then
      found = b
    end
  end
  return found
end

-- A batch's member comments (in id order), skipping any since-deleted.
function M.batch_members(b)
  local out = {}
  for _, id in ipairs(b and b.comment_ids or {}) do
    local c = M.get(id)
    if c then
      out[#out + 1] = c
    end
  end
  return out
end

-- The batch/submit set: unresolved threads whose latest turn is yours (i.e.
-- awaiting the agent) and that aren't already mid-dispatch. Covers new comments
-- and saved (drafted) replies alike.
function M.pending()
  return vim.tbl_filter(function(c)
    if c.meta or c.status == "resolved" or c.dispatching then
      return false
    end
    local t = M.turns(c)
    return #t == 0 or t[#t].author == "you"
  end, M.comments)
end

-- A comment's conversation as a list of turns; synthesized from legacy
-- comment/last_result fields if `turns` was never materialized.
function M.turns(c)
  if c.turns and #c.turns > 0 then
    return c.turns
  end
  local t = {}
  if c.comment and c.comment ~= "" then
    t[#t + 1] = { author = "you", text = c.comment }
  end
  if c.last_result and c.last_result ~= "" then
    t[#t + 1] = { author = "agent", text = c.last_result }
  end
  return t
end

function M.add_turn(id, author, text)
  local c = M.get(id)
  if not c then
    return
  end
  if not (c.turns and #c.turns > 0) then
    c.turns = M.turns(c)
  end
  table.insert(c.turns, { author = author, text = text, at = os.time() })
  if author == "agent" then
    c.last_result = text
  end
  if opts().persist.auto then
    M.save_soon()
  end
  return c
end

-- The unsent "you" message = the trailing turn when it's yours (a new comment never sent, or a
-- reply you're drafting). It's what shows as "· draft" and what opens editable in the input box.
function M.pending_you_text(c)
  local t = M.turns(c)
  local tail = t[#t]
  if tail and tail.author == "you" then
    return tail.text
  end
  return nil
end

-- Save the editable draft: UPDATE the trailing "you" turn in place (so editing never duplicates
-- it); create one if the last turn is the agent; and clearing a reply draft ("") removes it. The
-- first turn IS the comment, so we keep it (and sync the legacy comment field) instead of deleting.
function M.set_pending_you(id, text)
  local c = M.get(id)
  if not c then
    return
  end
  if not (c.turns and #c.turns > 0) then
    c.turns = M.turns(c)
  end
  local n = #c.turns
  local tail = c.turns[n]
  if tail and tail.author == "you" then
    if text == "" and n > 1 then
      table.remove(c.turns) -- clearing a reply draft drops it; the comment (n == 1) is kept
    else
      tail.text = text
      if n == 1 then
        c.comment = text -- the first turn is the comment; keep format/list in sync
      end
    end
  elseif text ~= "" then
    table.insert(c.turns, { author = "you", text = text, at = os.time() })
  end
  if opts().persist.auto then
    M.save_soon()
  end
  return c
end

function M.resolve(id)
  return M.update(id, { status = "resolved" })
end

function M.reopen(id)
  return M.update(id, { status = "open" })
end

-- Is `turn` (a table reference) still present in c.turns? A draft saved mid-stream
-- inserts a "you" turn after the streamed one, and abort/discard may already have
-- removed it — so "the tail" can no longer be trusted; only an exact table-identity
-- match counts as "the stream's turn is still there".
local function turn_present(c, turn)
  if not (turn and c.turns) then
    return false
  end
  for _, t in ipairs(c.turns) do
    if t == turn then
      return true
    end
  end
  return false
end

-- Remove `turn` from c.turns by identity (not position). Returns true if found.
local function remove_turn(c, turn)
  for i, t in ipairs(c.turns or {}) do
    if t == turn then
      table.remove(c.turns, i)
      return true
    end
  end
  return false
end

-- Streaming agent reply: append an empty agent turn, then grow it as chunks
-- arrive, then finalize. `dispatching` marks the thread busy (out of the batch).
function M.stream_start(id)
  local c = M.get(id)
  if not c then
    return
  end
  if not (c.turns and #c.turns > 0) then
    c.turns = M.turns(c)
  end
  table.insert(c.turns, { author = "agent", text = "", at = os.time() })
  -- runtime handle (underscore prefix) to the EXACT turn table just inserted, so
  -- later writes target it by identity instead of blindly hitting "the tail" — a
  -- draft saved mid-stream pushes a "you" turn after this one, which would
  -- otherwise land agent deltas in the draft and corrupt the conversation.
  c._stream_turn = c.turns[#c.turns]
  c.dispatching = true
  return c
end

-- `narration_end` (optional) is the collector's C.final_start() — the byte offset
-- where the latest text block begins; stored RUNTIME-ONLY on the turn (thread.build
-- reads it to grey narration lines while streaming). Batch callers that never pass
-- it just clear the field each call, which is harmless — narration greying and the
-- CHAT-only collapse-on-finish (cli.lua) both key off this same field.
function M.stream_update(id, text, narration_end)
  local c = M.get(id)
  if not c then
    return
  end
  if c._stream_turn then
    if turn_present(c, c._stream_turn) then
      c._stream_turn.text = text
      c._stream_turn.narration_end = narration_end
    end
    -- handle exists but its turn is gone (a draft-save moved it off the tail, or
    -- abort already popped it): drop the update silently — never write to
    -- whatever's now at the tail, that could be the "you" draft.
    return
  end
  -- no handle at all (a caller from before stream_start ever ran): fall back to
  -- the old tail-write, but ONLY when the tail is actually an agent turn.
  if c.turns and #c.turns > 0 and c.turns[#c.turns].author == "agent" then
    c.turns[#c.turns].text = text
    c.turns[#c.turns].narration_end = narration_end
  end
end

-- Drop a transient streamed turn used only as a LIVE batch-progress preview: pop
-- the handle's turn (by identity) so per-comment outcomes can come solely from the
-- actions file. The caller clears `dispatching` for the whole batch and re-renders,
-- so this only touches the placeholder turn.
function M.stream_discard(id)
  local c = M.get(id)
  if not c then
    return
  end
  if c._stream_turn then
    remove_turn(c, c._stream_turn)
    c._stream_turn = nil
    return
  end
  -- no handle: fall back to the old blind tail-if-agent behavior
  if c.turns and #c.turns > 0 and c.turns[#c.turns].author == "agent" then
    table.remove(c.turns)
  end
end

-- Force-end a dispatch (cancel / stuck): drop the busy flag and finalize any
-- trailing empty agent placeholder so the thread isn't stuck "thinking…".
function M.abort(id)
  local c = M.get(id)
  if not c then
    return
  end
  c.dispatching = nil
  if c._stream_turn then
    -- pop the HANDLE's turn (by identity), only if it's still an empty placeholder —
    -- keep partial streamed text. A draft-save may have moved the handle's turn off
    -- the tail, so don't touch "the tail" blindly.
    if turn_present(c, c._stream_turn) and (c._stream_turn.text == nil or c._stream_turn.text == "") then
      remove_turn(c, c._stream_turn)
    end
    -- kept partial text must not keep the narration marker: `live` in thread.build
    -- is per-COMMENT, so a LATER stream on this thread would re-grey this finished
    -- (aborted) turn's narration span — stream_finish clears it, abort must too
    c._stream_turn.narration_end = nil
    c._stream_turn = nil
  elseif c.turns and #c.turns > 0 then
    local tail = c.turns[#c.turns]
    -- drop a not-yet-answered agent placeholder so the thread reads as if nothing
    -- was sent (your last turn stays; you can re-send). Keep partial streamed text.
    if tail.author == "agent" and (tail.text == nil or tail.text == "") then
      table.remove(c.turns)
    end
  end
  if opts().persist.auto then
    M.save_soon()
  end
end

function M.stream_finish(id, text, session, ok)
  local c = M.get(id)
  if not c then
    return
  end
  local turn
  if c._stream_turn then
    if turn_present(c, c._stream_turn) then
      c._stream_turn.text = text
      turn = c._stream_turn
    end
    -- else: aborted mid-flight (a draft-save/abort already dropped this turn) — do
    -- NOT resurrect it, just fall through to the bookkeeping below.
  elseif c.turns and #c.turns > 0 and c.turns[#c.turns].author == "agent" then
    c.turns[#c.turns].text = text -- legacy caller, no handle: old tail-write fallback
    turn = c.turns[#c.turns]
  else
    c.turns = c.turns or {}
    table.insert(c.turns, { author = "agent", text = text, at = os.time() })
    turn = c.turns[#c.turns]
  end
  if turn then
    turn.narration_end = nil -- runtime-only; this turn is no longer "in flight"
  end
  c._stream_turn = nil
  c.last_result = text
  c.dispatching = nil
  if session then
    c.session_id = session
  end
  if not ok then
    c.status = "open"
  end
  if opts().persist.auto then
    M.save_soon()
  end
  return c
end

-- Clear the runtime busy flag once a dispatch settles (success or cancel), without
-- touching turns: unlike M.abort, this must NOT pop a trailing turn — on the success
-- path a real reply/turn was already written and abort's placeholder-pop would eat it.
-- `store.update(id, { dispatching = nil })` is a no-op (a table constructor never adds
-- a key whose value is nil), so callers need a direct field write instead.
function M.clear_dispatching(id)
  local c = M.get(id)
  if not c then
    return
  end
  c.dispatching = nil
  if opts().persist.auto then
    M.save_soon()
  end
  return c
end

function M.by_file(file)
  return vim.tbl_filter(function(c)
    return c.file == file
  end, M.comments)
end

-- Tags ----------------------------------------------------------------------
-- A tag curates which related threads form a batch (vs "all pending").

-- Enable/disable sticky tagging mode (nil/"" turns it off).
function M.set_active_tag(tag)
  M.active_tag = (tag and tag ~= "") and tag or nil
  return M.active_tag
end

-- Set or clear (nil/"") a single thread's tag. Direct field write so clearing
-- works (M.update can't unset a key — nil values vanish from the fields table).
function M.tag_comment(id, tag)
  local c = M.get(id)
  if not c then
    return
  end
  if c.meta then
    return -- the project thread is never batch-curated; a tag on it would be a phantom
  end
  c.tag = (tag and tag ~= "") and tag or nil
  if opts().persist.auto then
    M.save_soon()
  end
  return c
end

-- Pending threads carrying a given tag (the batch set for that tag).
function M.pending_by_tag(tag)
  return vim.tbl_filter(function(c)
    return c.tag == tag
  end, M.pending())
end

-- Distinct tags currently in use, in first-seen order.
function M.tags()
  local seen, out = {}, {}
  for _, c in ipairs(M.comments) do
    if c.tag and not seen[c.tag] then
      seen[c.tag] = true
      out[#out + 1] = c.tag
    end
  end
  return out
end

-- Batches persist in a sibling jsonl file next to the comments store.
function M.batches_path()
  return (M.store_path():gsub("%.jsonl$", "")) .. ".batches.jsonl"
end

function M.save_batches()
  local path = M.batches_path()
  local lines = {}
  for _, b in ipairs(M.batches) do
    table.insert(lines, vim.json.encode(b))
  end
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local ok, err = pcall(vim.fn.writefile, lines, path)
  if not ok then
    vim.notify("obelus: failed to save batches: " .. tostring(err), vim.log.levels.ERROR)
  end
end

-- Debounced saves -------------------------------------------------------------
-- Every mutator above writes the WHOLE jsonl synchronously via M.save(); during a
-- burst of small mutations (e.g. every streamed delta flipping through set_pending_you
-- / stream_update-adjacent bookkeeping) that's ~2N writes per dispatch for state that's
-- mostly runtime anyway. M.save_soon() coalesces a burst into one trailing-edge write.
M._timing = { save_debounce = 150 }

local save_timer = nil

-- Stop/close any pending debounced timer (idempotent).
local function stop_save_timer()
  if save_timer then
    local t = save_timer
    save_timer = nil
    pcall(function()
      t:stop()
      t:close()
    end)
  end
end

-- Flush on exit so a quick `:wq` right after a mutation never loses it to an
-- unfired debounce timer. Registered once (module-level guard) the first time a
-- debounced save is actually queued — auto=false users never touch this at all.
local flush_installed = false
local function ensure_flush_on_exit()
  if flush_installed then
    return
  end
  flush_installed = true
  local grp = vim.api.nvim_create_augroup("obelus_store", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = grp,
    callback = function()
      if save_timer then
        M.save() -- stops the timer itself (see below) and writes synchronously
      end
    end,
  })
end

-- Write NOW if a debounced save is pending. Callers that are about to swap the
-- store's identity (a project reload, a root change) MUST flush first — the pending
-- write belongs to the OLD root, and firing it after the swap would write the new
-- project's state while silently dropping the old project's last mutation.
function M.flush()
  if save_timer then
    M.save() -- stops the timer itself and writes synchronously
  end
end

-- Debounced M.save(): trailing-edge, coalesces a burst of mutations into one write.
-- Callers already gate on persist.auto; double-gated here too so this is safe to call
-- directly in the future without re-deriving that check.
function M.save_soon()
  if not opts().persist.auto then
    return
  end
  -- mid-shutdown there is no event loop left to debounce into (and VimLeavePre runs
  -- with v:exiting ALREADY set, so a handler registered/queued during it can be
  -- missed) — write synchronously instead of risking a never-fired timer
  if vim.v.exiting ~= vim.NIL then
    return M.save()
  end
  ensure_flush_on_exit()
  stop_save_timer()
  local uv = vim.uv or vim.loop
  save_timer = uv.new_timer()
  save_timer:start(
    M._timing.save_debounce,
    0,
    vim.schedule_wrap(function()
      save_timer = nil
      -- nvim went into teardown while the timer was pending: the VimLeavePre flush
      -- already wrote synchronously, don't double-write into a dying loop
      if vim.v.exiting == vim.NIL then
        M.save()
      end
    end)
  )
end

function M.save()
  stop_save_timer() -- an explicit/manual save supersedes any queued debounced one
  local path = M.store_path()
  local lines = {}
  for _, c in ipairs(M.comments) do
    local copy = vim.deepcopy(c)
    copy.extmark_id = nil -- runtime-only fields
    copy.bufnr = nil
    copy.dispatching = nil
    copy._stream_turn = nil -- a table ref into copy.turns — serializing it would
    -- duplicate the in-flight turn into the jsonl as a second top-level field
    for _, t in ipairs(copy.turns or {}) do
      t.narration_end = nil -- runtime-only (stream.lua's collector offset); never persisted
    end
    table.insert(lines, vim.json.encode(copy))
  end
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local ok, err = pcall(vim.fn.writefile, lines, path)
  if not ok then
    vim.notify("obelus: failed to save reviews: " .. tostring(err), vim.log.levels.ERROR)
  end
  M.save_batches()
end

function M.load_batches()
  M.batches = {}
  bseq = 0
  local path = M.batches_path()
  if vim.fn.filereadable(path) == 1 then
    for _, line in ipairs(vim.fn.readfile(path)) do
      if line ~= "" then
        local ok, rec = pcall(vim.json.decode, line)
        if ok and type(rec) == "table" then
          table.insert(M.batches, rec)
          if type(rec.seq) == "number" and rec.seq > bseq then
            bseq = rec.seq -- keep new batch numbers above any reloaded one
          end
        end
      end
    end
  end
end

function M.load()
  M.flush() -- a pending debounced save must land before its state is replaced
  M.comments = {}
  seq = 0
  M.active_tag = nil -- tagging mode is per-session/project; don't leak it across a reload
  local path = M.store_path()
  if vim.fn.filereadable(path) == 1 then
    for _, line in ipairs(vim.fn.readfile(path)) do
      if line ~= "" then
        local ok, rec = pcall(vim.json.decode, line)
        if ok and type(rec) == "table" then
          rec.dispatching = nil -- runtime-only; never resume a load as "in flight"
          rec.extmark_id = nil
          rec._stream_turn = nil -- migration: strip if an older build ever leaked one
          rec.batch_id = nil -- migration: membership is owned solely by batch.comment_ids now
          for _, t in ipairs(rec.turns or {}) do
            t.narration_end = nil -- migration: runtime-only, strip if one ever leaked to disk
          end
          -- HEAL duplicate meta records (planted by concurrent instances before the
          -- pin-no-create fix, or by a lost race between two saves): keep whichever
          -- has the most conversation (turns, then a session), drop the rest.
          if rec.meta then
            local existing = M.get_meta()
            if existing then
              local function weight(r)
                return #(r.turns or {}) * 2 + (r.session_id and 1 or 0)
              end
              if weight(rec) > weight(existing) then
                for i, cc in ipairs(M.comments) do
                  if cc == existing then
                    table.remove(M.comments, i)
                    break
                  end
                end
                table.insert(M.comments, rec)
              end
              rec = nil
            end
          end
          if rec then
            table.insert(M.comments, rec)
          end
        end
      end
    end
  end
  -- keep the id counter above any reloaded id so a new comment created in the same
  -- second can't collide with one just loaded (mirrors bseq in load_batches)
  for _, rec in ipairs(M.comments) do
    local n = tonumber(tostring(rec.id):match("-(%d+)$"))
    if n and n > seq then
      seq = n
    end
  end
  M.load_batches()
  loaded_root = M.root()
end

-- Reset the cached root and reload if the project changed (DirChanged).
function M.maybe_reload()
  -- flush BEFORE the root moves: a pending debounced save belongs to the OLD
  -- project's path, and load()'s own flush would run after store_path() repointed
  M.flush()
  M.reset_root()
  if M.root() ~= loaded_root then
    M.load()
    return true
  end
  return false
end

return M
