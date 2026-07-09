local config = require("obelus.config")
local store = require("obelus.store")
local format = require("obelus.format")
local jobs = require("obelus.jobs")

-- Continuable batch conversations: send several related comments to ONE agent so
-- it reasons about them with shared context, then keep talking to that SAME agent
-- across rounds. The Batch record (in the store) holds ONE shared session id; each
-- later round --resumes it with a compact "diff" of what changed since last time.
--
-- This is distinct from a per-thread chat reply (an isolated 1:1 conversation about
-- a single comment): a batch keeps every thread in one mind.
local M = {}

local function bcfg()
  return config.options.transport.batch or {}
end

-- The most recent open batch (the continue target), or nil.
function M.open()
  return store.open_batch()
end

-- Like M.open, but scoped to ONE tag (nil = untagged) — the continue target for a
-- SPECIFIC tag's engagement (a tag meta thread's SUBMIT-ALL; see review.submit_all)
-- rather than whichever batch is globally most-recent.
---@param tag? string
function M.open_for_tag(tag)
  return store.open_batch_for_tag(tag)
end

-- Is this batch mid-dispatch? (any member's spinner is live) — used to serialize
-- continues so we never fork the shared session with overlapping resumes.
-- jobs.lua is the WS3 liveness owner (single source of truth, provenance-aware)
-- for every transport, not just cli — probe it directly instead of cli.is_running.
function M.busy(batch)
  for _, c in ipairs(store.batch_members(batch)) do
    if c.dispatching then
      if jobs.is_running(c.id) then
        return true
      end
      store.abort(c.id) -- stale flag, no live subprocess: clear it so we never wedge
    end
  end
  return false
end

-- Is tag T's shared session mid-dispatch ANYWHERE — the tag thread itself, or ANY
-- of its member threads (a plain reply on one, or another round)? Widens M.busy
-- (which only checks THIS batch's own current members) to the whole tag: a
-- unified tag session (see review.do_respond) can be resumed from three
-- different entry points — the tag thread, a member reply, or a batch round —
-- and all three must serialize against each other, not just against their own
-- kind, or a second dispatch would --resume a session a live subprocess hasn't
-- finished writing to yet.
---@param tag string
function M.tag_busy(tag)
  local tag_meta = store.get_meta(tag)
  if tag_meta and jobs.busy(tag_meta.id) then
    return true
  end
  for _, m in ipairs(store.tag_members(tag)) do
    if jobs.busy(m.id) then
      return true
    end
  end
  return false
end

-- Snapshot the members' state so the NEXT round can diff against it.
local function snapshot(members)
  local snap = {}
  for _, c in ipairs(members) do
    snap[c.id] = { status = c.status, nturns = #store.turns(c) }
  end
  return snap
end

-- The current working set for a round: open members + any new pending comments
-- not yet in the batch (so comments you add between rounds get folded in).
local function working_set(batch)
  local seen, out = {}, {}
  for _, c in ipairs(store.batch_members(batch)) do
    seen[c.id] = true
    if c.status ~= "resolved" then
      out[#out + 1] = c
    end
  end
  -- fold in newly-added pending threads; scope to the batch's tag when it has one
  local pend = batch.tag and store.pending_by_tag(batch.tag) or store.pending()
  for _, c in ipairs(pend) do
    if not seen[c.id] then
      out[#out + 1] = c
    end
  end
  return out
end

-- Classify the working set vs the batch's prior snapshot: what got resolved, what
-- is new, where the user replied, what's still open. This is the round delta.
local function classify(batch, working)
  local snap = batch.snapshot or {}
  local resolved, added, replied, open = {}, {}, {}, {}
  for id, s in pairs(snap) do
    local c = store.get(id)
    if c and c.status == "resolved" and s.status ~= "resolved" then
      resolved[#resolved + 1] = c
    end
  end
  for _, c in ipairs(working) do
    local s = snap[c.id]
    if not s then
      added[#added + 1] = c
    else
      local turns = store.turns(c)
      if #turns > (s.nturns or 0) and turns[#turns] and turns[#turns].author == "you" then
        replied[#replied + 1] = c
      end
      open[#open + 1] = c
    end
  end
  return { resolved = resolved, added = added, replied = replied, open = open }
end

local function label(c)
  local first = (vim.split(c.comment or "", "\n")[1] or ""):sub(1, 60)
  return string.format("%s  %s:%s — %s", c.id, format.relpath(c.file), format.range_label(c), first)
end

-- The per-round "diff" prompt. The resumed session already holds the full history,
-- so this conveys only the delta; the cli transport then appends the actions
-- protocol (schema + the open-member id list) via actions.instructions.
function M.round_prompt(batch, working, message)
  local d = classify(batch, working)
  local lines = {
    string.format(
      "This continues batch review #%d (round %d). You already hold these threads in",
      batch.seq or 0,
      (batch.round or 1) + 1
    ),
    "context from earlier rounds — here is what changed since the last round.",
    "",
  }
  if message and message ~= "" then
    lines[#lines + 1] = "Instruction for this round: " .. message
    lines[#lines + 1] = ""
  end
  local function section(title, items, as_reply)
    if #items == 0 then
      return
    end
    lines[#lines + 1] = title
    for _, c in ipairs(items) do
      if as_reply then
        local turns = store.turns(c)
        local last = (turns[#turns] and turns[#turns].text) or ""
        lines[#lines + 1] = "  - " .. c.id .. ' — "' .. ((vim.split(last, "\n")[1] or ""):sub(1, 120)) .. '"'
      else
        lines[#lines + 1] = "  - " .. label(c)
      end
    end
    lines[#lines + 1] = ""
  end
  section("RESOLVED (done — do not revisit):", d.resolved)
  section("NEW comments to address:", d.added)
  section("The user replied on these threads:", d.replied, true)
  section("Still open:", d.open)
  lines[#lines + 1] = "Address every still-open and new comment as before; write .ai/"
    .. require("obelus.actions").filename(batch.id)
    .. " for each."
  return table.concat(lines, "\n")
end

-- Round 1: create a Batch from these comments and dispatch it through the
-- session-capable transport (cli). For a TAGGED batch (opts.tag), this is a
-- unified tag-session send like any other (review.do_respond) — it resumes the
-- tag meta's OWN session (get-or-create; may already hold history from tag-thread
-- chats or earlier rounds) rather than starting fresh, prepends that tag's
-- membership delta (JOINED/LEFT — store.tag_membership_delta) ahead of the round
-- markdown, and defers session CAPTURE to the tag meta (never the batch record —
-- see cli.lua's owner_id branch). An UNTAGGED batch is untouched: its own
-- session_id captures the shared session as before. Returns the new Batch.
function M.create(comments, opts)
  opts = opts or {}
  local tag = opts.tag
  if tag and M.tag_busy(tag) then
    return vim.notify(
      "obelus: the #" .. tag .. " session is still working — wait for it to finish",
      vim.log.levels.WARN
    )
  end
  local ids = {}
  for _, c in ipairs(comments) do
    ids[#ids + 1] = c.id
  end
  local tag_meta = tag and store.tag_meta_thread(tag) or nil -- get-or-create the session owner
  local batch = store.add_batch({
    comment_ids = ids,
    round = 1,
    transport = bcfg().transport or "cli",
    model = opts.model,
    tag = tag, -- when present, membership stays scoped to this tag across rounds
    status = "open",
    snapshot = snapshot(comments),
  })
  for _, c in ipairs(comments) do
    store.set_comment_batch(c.id, batch.id) -- claim it; detach from any prior open batch
  end

  local prompt = format.to_markdown(comments)
  local resume
  local submit_opts = { comments = comments, model = opts.model, batch = batch }
  if tag then
    resume = tag_meta.session_id
    if bcfg().mode == "stateless" or bcfg().prompt == "full" then
      resume = nil
    end
    -- submit-all's round briefs a JOINING member's draft too (unlike a plain
    -- respond) — the round's own write-back is what settles a draft into a real
    -- turn, same policy as any other pending thread in this round
    local delta = store.tag_membership_delta(tag)
    local delta_block = format.tag_deltas(tag, delta, { include_drafts = true })
    if delta_block ~= "" then
      prompt = delta_block .. "\n\n" .. prompt
    end
    submit_opts.resume = resume
    submit_opts.session_owner_id = tag_meta.id
    local round_n, size_n = batch.round, #comments
    submit_opts.on_success = function()
      store.commit_tag_known_ids(tag)
      store.add_tag_crossref(tag, string.format("round %d sent — %d threads", round_n, size_n))
    end
  end
  submit_opts.prompt = prompt

  local ok = require("obelus.transport").submit(batch.transport, submit_opts)
  if ok == false then
    -- transport.submit already notified the error; undo the batch record so it
    -- doesn't linger as a dead continue target with nothing dispatched behind it
    store.remove_batch(batch.id)
    return nil
  end
  -- (membership commit + crossref moved to submit_opts.on_success — a spawned-
  -- but-failed run must not advance known_ids; see review.do_respond's note)
  vim.notify(
    string.format(
      "obelus: batch #%d%s submitted (%d threads) — <prefix>S to continue",
      batch.seq,
      batch.tag and (" #" .. batch.tag) or "",
      #comments
    ),
    vim.log.levels.INFO
  )
  return batch
end

-- Round N: resume `target` (default: the most recent open batch, M.open()) with the
-- round diff (or re-serialize the open set when the session is gone / prompt =
-- "full" / mode = "stateless"). `target` lets a caller resume a SPECIFIC batch —
-- e.g. review.submit_all's tag-scoped continue, which must resume THAT tag's own
-- batch rather than whichever is globally most-recent — instead of the default
-- "most recent open" pick <prefix>s/M.continue_batch always uses.
---@param message? string
---@param target? table
function M.continue(message, target)
  local batch = target or M.open()
  if not batch then
    return vim.notify("obelus: no open batch to continue — submit one first (<prefix>s)", vim.log.levels.WARN)
  end
  -- for a TAGGED batch, widen the check to the whole tag session (the tag thread
  -- itself, or a plain reply on any of its members, may be mid-dispatch too —
  -- see M.tag_busy)
  if M.busy(batch) or (batch.tag and M.tag_busy(batch.tag)) then
    return vim.notify("obelus: the batch agent is still working — wait for it to finish", vim.log.levels.WARN)
  end
  local working = working_set(batch)
  if #working == 0 then
    return vim.notify("obelus: batch #" .. (batch.seq or 0) .. " has no open threads to continue", vim.log.levels.INFO)
  end

  -- fold any newly-added pending comments into the batch membership. Stays HERE
  -- (pre-submit), not after: the payload/prompt need the full working set
  -- regardless of whether the dispatch itself succeeds, and set_comment_batch's
  -- detach-from-other-batches is safe to do unconditionally either way.
  local ids = vim.deepcopy(batch.comment_ids or {})
  local known = {}
  for _, id in ipairs(ids) do
    known[id] = true
  end
  for _, c in ipairs(working) do
    if not known[c.id] then
      ids[#ids + 1] = c.id
      store.set_comment_batch(c.id, batch.id) -- claim it; detach from any prior open batch
    end
  end

  -- resume only when we actually captured a session and aren't forced to re-serialize.
  -- A TAGGED batch defers to its tag meta's OWN session (unified tag session —
  -- get-or-create; it may already hold history from tag-thread chats or earlier
  -- rounds) instead of the batch's own session_id — see obelus.batch.create.
  local tag = batch.tag
  local tag_meta = tag and store.tag_meta_thread(tag) or nil
  -- NOT `tag and tag_meta.session_id or batch.session_id` — that's the classic
  -- Lua "and/or" trap: a tagged batch with no session CAPTURED yet (tag_meta.
  -- session_id nil/false) would silently fall through to batch.session_id, which
  -- a unified tag session must NEVER resume (see obelus.batch.create's doc comment)
  local resume
  if tag then
    resume = tag_meta.session_id
  else
    resume = batch.session_id
  end
  if bcfg().mode == "stateless" or bcfg().prompt == "full" then
    resume = nil
  end
  local prompt
  if resume then
    prompt = M.round_prompt(batch, working, message)
  else
    prompt = format.to_markdown(working)
    if message and message ~= "" then
      prompt = "Instruction for this round: " .. message .. "\n\n" .. prompt
    end
  end
  if tag then
    local delta = store.tag_membership_delta(tag)
    local delta_block = format.tag_deltas(tag, delta, { include_drafts = true })
    if delta_block ~= "" then
      prompt = delta_block .. "\n\n" .. prompt
    end
  end

  -- Persist MEMBERSHIP before the dispatch attempt: set_comment_batch already
  -- claimed the folded-in members away from other batches, so comment_ids must
  -- reflect that immediately — a failed dispatch previously left a new member
  -- claimed but unlisted (self-healing via the next fold-in, but a lie on disk).
  store.update_batch(batch.id, { comment_ids = ids })
  local submit_opts = {
    comments = working,
    prompt = prompt,
    model = batch.model,
    batch = batch,
    resume = resume,
  }
  if tag then
    submit_opts.session_owner_id = tag_meta.id
    -- the round being DISPATCHED: the bump commits only after submit succeeds
    local round_n, size_n = (batch.round or 1) + 1, #working
    submit_opts.on_success = function()
      store.commit_tag_known_ids(tag)
      store.add_tag_crossref(tag, string.format("round %d sent — %d threads", round_n, size_n))
    end
  end
  local ok = require("obelus.transport").submit(batch.transport or "cli", submit_opts)
  -- Commit the round bump + snapshot ONLY on submit success (transport.submit
  -- already notified any failure) — an exit-callback-timed snapshot would bake in
  -- agent-resolved statuses from a run that never happened. On failure we return
  -- WITHOUT bumping round/snapshot: the next successful round still diffs against
  -- the OLD (unchanged) snapshot and conveys the user's replies + everything
  -- resolved since — nothing this round would have reported is lost.
  if ok == false then
    return
  end

  store.update_batch(batch.id, {
    round = (batch.round or 1) + 1,
    snapshot = snapshot(working),
  })
  -- (membership commit + crossref moved to submit_opts.on_success — see above)

  vim.notify(
    string.format(
      "obelus: continuing batch #%d (round %d) — %d open%s",
      batch.seq or 0,
      batch.round or 2,
      #working,
      resume and "" or " [re-serialized: no live session]"
    ),
    vim.log.levels.INFO
  )
  return batch
end

return M
