local config = require("obelus.config")
local store = require("obelus.store")
local render = require("obelus.render")
local jobs = require("obelus.jobs")

local M = {}

-- Resolve a comment by id, or fall back to the one under the cursor.
local function lookup(id)
  if id then
    return store.get(id)
  end
  return render.at_cursor()
end

-- Collapses the repeated "no comment here" guard shared by most actions below:
-- resolve by id (or cursor), warn and bail if there's nothing there, else call
-- fn with the resolved comment in place of id.
local function with_comment(fn)
  return function(id, ...)
    local c = lookup(id)
    if not c then
      return vim.notify("obelus: no comment here", vim.log.levels.WARN)
    end
    return fn(c, ...)
  end
end

---Edit the comment text at cursor (or `id`).
---@param id? string
M.edit = with_comment(function(c)
  require("obelus.capture").edit_comment(c)
end)

---Delete the comment at cursor (or `id`); kills any in-flight dispatch on it first.
---@param id? string
M.delete = with_comment(function(c)
  -- batch members share one process; killing it here is consistent with jobs.cancel's
  -- semantics (deleting one mid-dispatch member would otherwise strand the still-live
  -- subprocess with no comment left to report its result to). Say so — for a batch,
  -- the OTHER members' in-flight round dies with the shared process too.
  local killed = jobs.is_running(c.id) and jobs.cancel(c.id)
  store.remove(c.id)
  render.render_all()
  vim.notify(
    killed and "obelus: comment deleted — its in-flight dispatch (and any batch round sharing it) was cancelled"
      or "obelus: comment deleted",
    vim.log.levels.INFO
  )
end)

-- Batch submit: ALL pending comments go to ONE agent that shares their context and
-- addresses each (resolve / reply / needs_response). Uses the batch model when set.
--
-- With batch conversations enabled and no explicit transport, this creates a
-- continuable Batch (one shared session you keep talking to via M.continue_batch);
-- an explicit `name` (e.g. :ObelusSubmit file) still does a plain one-shot send.
---@param name? string a registered transport name; nil = the batch/default flow
---@param opts? table
function M.submit(name, opts)
  opts = opts or {}
  if opts.model == nil then
    local cli = config.options.transport.cli or {}
    local models = cli.models or {}
    opts.model = models.batch or models.send
  end
  local bc = config.options.transport.batch
  if not name and bc and bc.enabled then
    -- scope the batch to a tag when there's a tag context: the active sticky tag, or
    -- (failing that) the tag on the thread under the cursor; otherwise all pending.
    local comments, tag = opts.comments, opts.tag
    if not comments then
      if tag == nil then
        local at = render.at_cursor()
        tag = store.active_tag or (at and at.tag)
      end
      comments = tag and store.pending_by_tag(tag) or store.pending()
    end
    if #comments == 0 then
      local msg = tag and ("obelus: no pending threads tagged #" .. tag) or "obelus: no pending comments to submit"
      return vim.notify(msg, vim.log.levels.WARN)
    end
    return require("obelus.batch").create(comments, { model = opts.model, tag = tag })
  end
  require("obelus.transport").submit(name, opts)
end

-- Tagging: tag/untag the thread at cursor (or `id`); `name` ~= nil sets it directly
-- (empty string clears), nil prompts. Tags curate which threads form a batch.
---@param id? string
---@param name? string
M.tag = with_comment(function(c, name)
  local function apply(t)
    store.tag_comment(c.id, t)
    render.render_all()
    vim.notify(t and ("obelus: tagged #" .. t) or "obelus: tag cleared", vim.log.levels.INFO)
  end
  if name ~= nil then
    return apply(name ~= "" and name or nil)
  end
  vim.ui.input({ prompt = "Tag (empty clears): ", default = c.tag or store.active_tag or "" }, function(t)
    if t == nil then
      return -- cancelled: leave the tag as-is
    end
    apply(t ~= "" and t or nil)
  end)
end)

-- Sticky tagging mode: while on, new threads inherit the tag. `name` ~= nil sets it
-- (empty clears), nil toggles (prompting for a tag when turning it on).
---@param name? string
function M.tag_mode(name)
  local function set(t)
    store.set_active_tag(t)
    render.render_all()
    local on = store.active_tag
    vim.notify(
      on and ("obelus: tagging mode ON — new threads tagged #" .. on) or "obelus: tagging mode off",
      vim.log.levels.INFO
    )
  end
  if name ~= nil then
    return set(name ~= "" and name or nil)
  end
  if store.active_tag then
    return set(nil) -- toggle off
  end
  vim.ui.input({ prompt = "Tagging mode — tag for new threads: " }, function(t)
    if t == nil or t == "" then
      return
    end
    set(t)
  end)
end

-- Continue the open batch conversation (round N): resume the shared session with a
-- compact diff of what changed. `text` is an optional instruction for this round.
---@param text? string
function M.continue_batch(text)
  require("obelus.batch").continue(text and text ~= "" and text or nil)
end

-- One key for the whole batch loop: if a continuable batch is open (and idle), advance it
-- to the NEXT round; otherwise submit the pending comments as a NEW batch. So <prefix>s
-- "just works" round after round without the user tracking which round they're on. New
-- comments added between rounds are folded into the continue automatically (batch working
-- set). <prefix>S stays as the explicit "start a fresh batch" escape hatch.
---@param text? string
function M.batch_advance(text)
  local batch = require("obelus.batch")
  local open = batch.open()
  if open and not batch.busy(open) then
    M.continue_batch(text)
  else
    M.submit()
  end
end

-- SUBMIT-ALL (keys.chat.send_all, default <M-s>, in a TAG meta thread's input):
-- unlike plain RESPOND (do_respond above, which deliberately excludes member
-- drafts from the briefing), this ENGAGES the batch — every pending thread
-- carrying the tag, INCLUDING one sitting on a saved-but-unsent draft reply
-- (store.pending()/pending_by_tag already treat a trailing "you" turn as a real
-- reply regardless of whether it was ever formally "sent" — see store.lua's
-- pending_you_text; the round's write-back reply is what actually turns it into
-- a settled, no-longer-draft turn, same as any other reply) — via the SAME batch
-- machinery <prefix>s/<prefix>S use: continue the tag's own open batch if it's
-- idle, else start a new one, carrying `text` as this round's instruction. The
-- note is only conveyed on a CONTINUE — batch.create has no per-round instruction
-- slot, the same limitation <prefix>s's own optional text already has on a fresh
-- submit. In the GLOBAL meta or an ordinary thread — neither has a "tag" or
-- "member drafts" concept — this falls back to a plain send.
---@param id string
---@param text string
function M.submit_all(id, text)
  local c = store.get(id)
  if not (c and c.meta_tag) then
    return M.chat_send(id, text, "send") -- not a tag meta: plain send (see doc comment above)
  end
  if not (text and text ~= "") then
    return
  end
  local tag = c.meta_tag
  local batch = require("obelus.batch")
  local open = batch.open_for_tag(tag)
  if open then
    if batch.busy(open) then
      return vim.notify("obelus: the batch agent is still working — wait for it to finish", vim.log.levels.WARN)
    end
    return batch.continue(text, open)
  end
  local comments = store.pending_by_tag(tag)
  if #comments == 0 then
    return vim.notify("obelus: no pending threads tagged #" .. tag .. " to submit", vim.log.levels.WARN)
  end
  local cli = config.options.transport.cli or {}
  local models = cli.models or {}
  batch.create(comments, { model = models.batch or models.send, tag = tag })
end

-- Per-comment modality: fire the comment at cursor (or `id`) off to a
-- background agent immediately, with a spinner. Doesn't touch the batch.
---@param id? string
M.dispatch = with_comment(function(c)
  if M.busy(c.id) then
    return vim.notify("obelus: already dispatching this one", vim.log.levels.WARN)
  end
  require("obelus.transport").submit(config.options.transport.dispatch or "cli", { comments = { c } })
end)

-- Cancel an in-flight dispatch (kills the subprocess; the thread is left as it was).
---@param id? string
M.cancel = with_comment(function(c)
  if not c.dispatching then
    return vim.notify("obelus: nothing to cancel here", vim.log.levels.INFO)
  end
  pcall(function()
    jobs.cancel(c.id) -- kill the job (best effort; the owning transport decides how)
  end)
  store.abort(c.id) -- ALWAYS un-stick the thread, even if the process is wedged/already gone
  require("obelus.progress").cancel(c.id) -- clear the (possibly frozen) spinner job
  render.render_all()
  vim.notify("obelus: dispatch cancelled", vim.log.levels.INFO)
end)

---Resolve the comment at cursor (or `id`).
---@param id? string
M.resolve = with_comment(function(c)
  store.resolve(c.id)
  render.render_all()
end)

---Reopen the comment at cursor (or `id`).
---@param id? string
M.reopen = with_comment(function(c)
  store.reopen(c.id)
  render.render_all()
end)

-- Toggle a comment's resolved state: resolved → reopened, anything else → resolved.
---@param id? string
M.toggle_resolve = with_comment(function(c)
  if c.status == "resolved" then
    store.reopen(c.id)
    vim.notify("obelus: reopened", vim.log.levels.INFO)
  else
    store.resolve(c.id)
    vim.notify("obelus: resolved", vim.log.levels.INFO)
  end
  render.render_all()
end)

-- Is a thread genuinely mid-dispatch? Clears a STALE `dispatching` flag (set but
-- with no registered job — e.g. left over from a crash, reload, or lost callback)
-- so it can never block replies forever. Owned by jobs.lua (provenance-aware: a
-- non-cli transport's live job is trusted, not insta-healed away).
---@param id string
---@return boolean
M.busy = jobs.busy

-- The project thread's own framing, prepended (after the briefing) on its FIRST
-- send — distinct from actions.instructions' JSON write-back SCHEMA, which the
-- transport appends separately (see the `actions_comments` fan-out below): this is
-- just what tells the agent it's talking about the whole project, not one thread.
local META_PREAMBLE = "You are the project-level reviewer for this codebase: you may read any file to answer."
  .. " Your streamed reply here IS the project-level conversation. To act on an INDIVIDUAL review thread below"
  .. " (reply to it, resolve it, or ask it a question) you MUST use the write-back protocol — keyed by that"
  .. " thread's comment id — rather than just describing the change in prose."

-- A TAG meta's own framing (parallel to META_PREAMBLE, scoped to one tag): plain
-- RESPOND here is a discussion ABOUT the tag's threads that deliberately does NOT
-- send/commit any member's unsent draft (format.meta_context's include_drafts =
-- false already keeps drafts out of the briefing itself; this just says so) — that
-- is what keys.chat.send_all (SUBMIT-ALL, see M.submit_all below) is for instead.
local TAG_META_PREAMBLE = 'You are the batch-level reviewer for the tag "#%s": you may read any file to answer.'
  .. " Your streamed reply here IS the tag-level conversation — replying here does NOT send or commit any"
  .. " member thread's unsent draft. To act on an INDIVIDUAL review thread below (reply to it, resolve it, or"
  .. " ask it a question) you MUST use the write-back protocol — keyed by that thread's comment id — rather"
  .. " than just describing the change in prose."

-- A reply on a TAGGED member thread X routes over its tag's shared session (see
-- tag_session_prompt below) — the session holds the WHOLE tag's context (every
-- JOINED/LEFT thread it's seen), but this one message is scoped to X alone. Says
-- so; the write-back scope (actions_comments = { X }, see do_respond) enforces it.
local SCOPING_PREAMBLE = "This message concerns ONLY the thread below — you have the broader #%s context, but"
  .. " reply to and act on THIS thread alone."

-- Unified tag session: build a tag-session send's prompt = the membership delta
-- (JOINED/LEFT blocks — store.tag_membership_delta) since the tag meta's last
-- committed baseline, THEN (only on `founding` — this session's very first-ever
-- send) `opts.preamble`, THEN `body`. The join blocks in the delta ARE the
-- founding briefing now — this REPLACES the old one-shot format.meta_context()
-- call for tag metas; don't call both (see review.do_respond's two tag-session
-- branches below, neither of which calls meta_context).
-- `opts.include_drafts` governs the JOIN blocks' own thread_full call — respond
-- modes (both branches below) pass false; obelus.batch's submit-all rounds pass
-- true, matching format.meta_context's existing respond-vs-submit-all split.
---@param tag string
---@param founding boolean
---@param body string
---@param opts? { include_drafts?: boolean, preamble?: string }
local function tag_session_prompt(tag, founding, body, opts)
  opts = opts or {}
  local parts = {}
  local delta = store.tag_membership_delta(tag)
  local delta_block = require("obelus.format").tag_deltas(tag, delta, { include_drafts = opts.include_drafts })
  if delta_block ~= "" then
    parts[#parts + 1] = delta_block
  end
  if founding and opts.preamble then
    parts[#parts + 1] = opts.preamble
  end
  parts[#parts + 1] = body
  return table.concat(parts, "\n\n")
end

-- Add a follow-up user turn and continue the agent conversation (--resume).
-- mode: "send" (default → cli.models.send) | "fast" (→ cli.models.fast, falling back to send)
local function do_respond(c, text, mode)
  -- the tag this send concerns, if any (mutually exclusive: a meta record only
  -- ever carries meta_tag, a real thread only ever carries tag) — used by the
  -- busy guard below AND by the tag-session branches further down.
  local tag = c.meta_tag or (not c.meta and c.tag or nil)
  -- a tag's shared session can be resumed from THREE entry points (the tag
  -- thread, a member reply, or a batch round) — serialize against ALL of them,
  -- not just this thread's own dispatching flag (obelus.batch.tag_busy).
  if M.busy(c.id) or (tag and require("obelus.batch").tag_busy(tag)) then
    return vim.notify("obelus: the agent is still replying — wait for it to finish", vim.log.levels.WARN)
  end
  store.set_pending_you(c.id, text) -- update the draft turn in place (no duplicate), then dispatch
  store.reopen(c.id)
  render.arm_follow(c.id) -- inline band: stick to the bottom + scroll the file into view
  render.render_all()
  require("obelus.panel").on_send(c.id) -- modal popup/sidebar: re-arm its auto-scroll
  local cli = config.options.transport.cli or {}
  local models = cli.models or {}
  local format = require("obelus.format")

  -- Unified tag session: EVERY send concerning tag T — the tag thread's own
  -- message (c.meta_tag ~= nil, case A below) or a reply on a TAGGED member
  -- thread (c.tag ~= nil, case B) — resumes the ONE shared session owned by the
  -- tag meta record (tag_meta.session_id is canonical; see doc/obelus.txt's "Tag
  -- threads"). `tag_ctx` (nil for the untouched global-meta/plain-thread cases)
  -- carries what the post-dispatch bookkeeping below needs: which tag, and the
  -- member-reply cross-reference line (case B only — case A's OWN message IS the
  -- tag-level conversation, nothing to cross-reference).
  local model, prompt, submit_opts, tag_ctx

  if c.meta_tag then
    -- case A: the tag thread's OWN message. `c` IS the tag meta record, so
    -- `c.session_id` doubles as the tag session's id — no separate lookup.
    model = (mode == "fast") and (models.fast or models.send) or (models.batch or models.send)
    prompt = tag_session_prompt(tag, c.session_id == nil, text, {
      include_drafts = false, -- plain RESPOND never leaks a member's unsent draft (see SUBMIT-ALL below)
      preamble = string.format(TAG_META_PREAMBLE, tag),
    })
    submit_opts = {
      comments = { c },
      resume = c.session_id,
      prompt = prompt,
      stream = true,
      model = model,
      session_owner_id = c.id,
      -- the mention policy must see ONLY the user's text: the delta's join blocks
      -- carry real "@path" mentions on purpose and must NOT be re-scanned (see
      -- transport/init.lua's choke point)
      mention_text = text,
      mention_include_drafts = false, -- same promise as plain RESPOND: no leaking a draft via @thread pull-back
    }
    -- fan-out: the write-back protocol covers every member of THIS tag (not just
    -- the meta record itself — cli.lua's run_stream would otherwise scope
    -- `allowed` to just the meta id).
    submit_opts.actions_comments = vim.tbl_filter(function(x)
      return not x.meta and x.tag == tag
    end, store.all())
    tag_ctx = { tag = tag }
  elseif tag then
    -- case B: a reply on a TAGGED member thread X — routes over X's tag's shared
    -- session (get-or-create the meta record), scoped to X alone. The write-back
    -- scope below (actions_comments = { c }) ENFORCES that scoping, not just states it.
    local tag_meta = store.tag_meta_thread(tag)
    model = (mode == "fast") and (models.fast or models.send) or (models.batch or models.send)
    local body = string.format(SCOPING_PREAMBLE, tag) .. "\n\n" .. text
    prompt = tag_session_prompt(tag, tag_meta.session_id == nil, body, { include_drafts = false })
    submit_opts = {
      comments = { c },
      resume = tag_meta.session_id,
      prompt = prompt,
      stream = true,
      model = model,
      session_owner_id = tag_meta.id, -- captured session lands on the TAG META, never on c
      actions_comments = { c },
      mention_text = text,
      mention_include_drafts = false,
    }
    local first = (vim.split(text, "\n")[1] or ""):sub(1, 120)
    tag_ctx = {
      tag = tag,
      -- cross-reference: note this reply in the tag meta's own transcript, so
      -- reading #<tag> alone still shows every member send that happened
      crossref = string.format("↳ re %s %s: %s", format.relpath(c.file), format.range_label(c), first),
    }
  elseif c.meta then
    -- case C: the GLOBAL project thread — untouched.
    model = (mode == "fast") and (models.fast or models.send) or models.send
    prompt = text
    if not c.session_id then
      prompt = format.meta_context() .. "\n\n" .. META_PREAMBLE .. "\n\n" .. text
    end
    submit_opts = {
      comments = { c },
      resume = c.session_id,
      prompt = prompt,
      stream = true,
      model = model,
      mention_text = text,
    }
    -- fan-out: the write-back protocol must cover every REAL thread (not just the
    -- meta record itself) — this is how the project chat can reply/resolve/
    -- needs_response on any thread in the project, not only the one it's
    -- nominally "about".
    submit_opts.actions_comments = vim.tbl_filter(function(x)
      return not x.meta
    end, store.all())
  else
    -- case D: an ordinary thread — untouched for one that was NEVER tagged (see
    -- below). No session to resume = the agent has never seen this comment;
    -- prepend the thread's own serialization so it isn't sent with zero file/
    -- selection context (also carries the @path so the mention send policy
    -- applies to it). format.thread_full, not the older comment_md: for a
    -- genuinely brand-new comment (its only turn IS c.comment) the two produce
    -- IDENTICAL output — but a thread UNTAGGED/RETAGGED just now (store.
    -- tag_comment clears c.session_id, forcing this same "no session" founding
    -- path) may already hold turns from its tagged life, and those belong in the
    -- fresh session too (own turns only — no tag-chat commentary; see
    -- store.tag_comment's doc comment).
    model = (mode == "fast") and (models.fast or models.send) or models.send
    prompt = text
    if not c.session_id then
      -- include_drafts="omit": set_pending_you already wrote `text` onto the
      -- turns as the trailing draft — serializing it AND appending it sent the
      -- user's message twice ("You (draft, unsent): X … X")
      prompt = format.thread_full(c, { include_drafts = "omit" }) .. "\n" .. text
    end
    submit_opts = {
      comments = { c },
      resume = c.session_id,
      prompt = prompt,
      stream = true,
      model = model,
    }
  end

  -- transport.submit pcalls the backend and RETURNS FALSE on failure (unknown
  -- transport name, backend threw) — and this pcall is belt-and-braces for anything
  -- thrown before that catch. Either way the send never started: unstick the panel's
  -- streaming bridge (on_send above armed it) or the chat stays in plain-text
  -- streaming mode with a spinner nothing will ever clear.
  if tag_ctx then
    -- membership commits ride the RUN-success hook, not dispatch start: a
    -- spawned-but-failed run advancing known_ids would make the retry skip the
    -- join briefings the agent never received (a silent, permanent context hole)
    submit_opts.on_success = function()
      store.commit_tag_known_ids(tag_ctx.tag)
      if tag_ctx.crossref then
        store.add_tag_crossref(tag_ctx.tag, tag_ctx.crossref)
      end
    end
  end
  local ok, ret = pcall(require("obelus.transport").submit, config.options.transport.dispatch or "cli", submit_opts)
  if not ok or ret == false then
    store.abort(c.id)
    pcall(function()
      require("obelus.panel").seat_finish(c.id) -- clear the panel's streaming bridge + reseat
    end)
    render.render_all()
    if not ok then
      vim.notify("obelus: send failed: " .. tostring(ret), vim.log.levels.ERROR)
    end -- ret == false: transport.submit already notified the specific error
  end
end

---Respond to a thread: `text` sends immediately, else prompts for it.
---@param id? string
---@param text? string
M.respond = with_comment(function(c, text)
  if text and text ~= "" then
    do_respond(c, text)
  else
    require("obelus.capture").prompt({ title = " respond to thread " }, function(t)
      if t then
        do_respond(c, t)
      end
    end)
  end
end)

-- Save the editable draft (the trailing "you" turn) so closing / <C-s> keeps what you typed as
-- "· draft"; it reopens in the box next time and joins the next batch. Empty text clears it.
---@param id string
---@param text string
function M.chat_save(id, text)
  store.set_pending_you(id, text)
  if text and text ~= "" then
    store.reopen(id)
  end
  render.render_all()
end

-- Send a reply now (dispatch + stream the agent's response into the thread).
-- mode: "send" (default) | "fast" (use the configured fast model).
---@param id string
---@param text string
---@param mode? "send"|"fast"
function M.chat_send(id, text, mode)
  local c = lookup(id)
  if c and text and text ~= "" then
    do_respond(c, text, mode)
  end
end

---Clear all comments, killing any live jobs first.
function M.clear()
  jobs.cancel_all() -- kill any live jobs before wiping the comments out from under them
  store.clear()
  render.render_all()
  vim.notify("obelus: cleared all comments", vim.log.levels.INFO)
end

-- Completion hook for transports: repaint every surface after a job mutates
-- threads. Owns the repaint so transports never reach into the UI layer.
function M.refresh()
  require("obelus.render").render_all()
  -- the panel surfaces too — an OPEN hover preview otherwise keeps showing the
  -- batch's transient progress turn (the model's raw working narration) after
  -- the writeback replaced it, until some unrelated event forces a fill
  pcall(function()
    local panel = require("obelus.panel")
    panel.refresh()
    panel.refresh_preview(true)
  end)
end

return M
