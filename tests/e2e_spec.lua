-- e2e: the full streaming lifecycle over the fake transport (tests/fake.lua) — send,
-- deltas, finish, cancel, and the busy guard. The first true end-to-end chat test:
-- exercises obelus.chat_send -> do_respond -> transport.submit -> the fake transport's
-- store.stream_* choreography -> progress's tick -> panel.refresh()/fill(), all driven
-- synchronously (no real subprocess, no sleeping past real timing).
T.describe("e2e")

-- Fresh obelus + a fresh fake transport registration, with the wall-clock knobs
-- shrunk so a T.wait_for actually observes the tick/fill propagation quickly.
-- `extra` (optional) merges over the base opts (e.g. { render = { narration = "keep" } }).
local function fresh_stream_ctx(extra)
  local F = require("fake")
  local base = { transport = { dispatch = "fake" }, render = { renderer = "builtin" } }
  local ctx = T.fresh(extra and vim.tbl_deep_extend("force", base, extra) or base)
  F.reset()
  F.install()
  require("obelus.panel")._timing.fill_throttle = 0
  require("obelus.progress")._timing.tick = 20
  return ctx, F
end

-- A comment rooted in a real file/buffer (the panel's popup roots off the source
-- window; the sidebar doesn't strictly need it, but this keeps both codepaths lit).
local function open_file_comment(ctx, text)
  local file = ctx.root .. "/f.lua"
  vim.fn.writefile({ "local a = 1", "local b = 2" }, file)
  vim.cmd("edit " .. file)
  local fabs = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
  local c =
    ctx.store.add(T.comment({ file = fabs, range = { sl = 1, el = 1 }, comment = text or "please review this" }))
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  return c
end

-- Open the thread's sidebar chat, wait for the docked reply box to reveal (open_thread
-- defers this one tick after the first fill), then send.
local function open_and_send(c, text)
  local panel = require("obelus.panel")
  panel.open_thread(c.id, false)
  T.ok(
    T.wait_for(function()
      local g = panel.geom()
      return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
    end),
    "reply box revealed"
  )
  require("obelus").chat_send(c.id, text, "send")
  return panel
end

-- ---------------------------------------------------------------------------
-- 1. send -> streaming state
-- ---------------------------------------------------------------------------

T.it("chat_send: dispatching starts, empty agent turn queued, fake transport got the payload, message shown", function()
  local ctx, F = fresh_stream_ctx()
  local c = open_file_comment(ctx)
  local panel = open_and_send(c, "hello agent")

  T.eq(ctx.store.get(c.id).dispatching, true, "dispatching flag set synchronously")
  local turns = ctx.store.turns(ctx.store.get(c.id))
  local tail = turns[#turns]
  T.eq(tail.author, "agent", "the trailing turn is the (empty) agent placeholder")
  T.eq(tail.text, "", "stream_start left it empty — no deltas yet")

  T.ok(F.payload ~= nil, "fake transport received the dispatch")
  T.eq(F.payload.comments[1].id, c.id)
  T.eq(F.payload.opts.stream, true, "streamed, not one-shot")

  local g = panel.geom()
  T.ok(
    T.wait_for(function()
      local lines = vim.api.nvim_buf_get_lines(g.buf, 0, -1, false)
      return table.concat(lines, "\n"):find("hello agent", 1, true) ~= nil
    end),
    "the chat shows the message you just sent"
  )
end)

-- ---------------------------------------------------------------------------
-- 2. deltas grow the chat
-- ---------------------------------------------------------------------------

T.it("deltas: streamed chunks grow the chat while seated at the bottom", function()
  local ctx, F = fresh_stream_ctx()
  local c = open_file_comment(ctx)
  local panel = open_and_send(c, "hello agent")

  F.delta("The fix ")
  F.delta("is simple.")

  local g
  T.ok(
    T.wait_for(function()
      g = panel.geom()
      if not g then
        return false
      end
      local lines = vim.api.nvim_buf_get_lines(g.buf, 0, -1, false)
      return table.concat(lines, "\n"):find("The fix is simple.", 1, true) ~= nil
    end, 2000),
    "the progress tick + fill propagated the streamed text into the chat buffer"
  )

  g = panel.geom()
  T.eq(g.follow, true, "still following (seated) while streaming")
  T.eq(g.botline, g.line_count, "the bottom line is in view while streaming")
end)

-- ---------------------------------------------------------------------------
-- 3. finish -> settled
-- ---------------------------------------------------------------------------

T.it("finish: stream settles — dispatching clears, session recorded, seated at the bottom", function()
  local ctx, F = fresh_stream_ctx()
  local c = open_file_comment(ctx)
  local panel = open_and_send(c, "hello agent")

  F.delta("The fix ")
  F.delta("is simple.")
  T.ok(
    T.wait_for(function()
      local g = panel.geom()
      if not g then
        return false
      end
      local lines = vim.api.nvim_buf_get_lines(g.buf, 0, -1, false)
      return table.concat(lines, "\n"):find("The fix is simple.", 1, true) ~= nil
    end, 2000),
    "delta landed before finishing"
  )

  F.finish(true, "sess-123")

  T.is_nil(ctx.store.get(c.id).dispatching, "dispatching cleared")
  T.eq(ctx.store.get(c.id).session_id, "sess-123")
  T.eq(require("obelus").busy(c.id), false)
  local turns = ctx.store.turns(ctx.store.get(c.id))
  local tail = turns[#turns]
  T.eq(tail.author, "agent")
  T.eq(tail.text, "The fix is simple.", "the full streamed text is finalized on the turn")

  -- gap == 0 means seated in both docking modes (geom() normalizes the popup vs
  -- sidebar zero-points — see geometry_spec's note)
  T.ok(
    T.wait_for(function()
      local g = panel.geom()
      return g ~= nil and g.gap == 0
    end, 2000),
    "seated at the bottom (gap == 0) after finish"
  )

  local g = panel.geom()
  local buftext = table.concat(vim.api.nvim_buf_get_lines(g.buf, 0, -1, false), "\n")
  T.contains(buftext, "The fix is simple.", "the reply text survives the plain -> external renderer swap")
end)

-- ---------------------------------------------------------------------------
-- 4. cancel path
-- ---------------------------------------------------------------------------

T.it("cancel: kills the job (jobs.cancel), dispatching clears, and the empty placeholder turn is dropped", function()
  local ctx, F = fresh_stream_ctx()
  local c2 = ctx.store.add(T.comment({ comment = "please look at this" }))

  require("obelus").chat_send(c2.id, "go", "send")
  T.eq(ctx.store.get(c2.id).dispatching, true)
  local mid_turns = ctx.store.turns(ctx.store.get(c2.id))
  T.eq(mid_turns[#mid_turns].author, "agent", "an empty agent placeholder is queued while dispatching")

  require("obelus").cancel(c2.id)

  T.eq(F.cancelled, true, "review.cancel routed through jobs.cancel to the fake's cancel closure")
  T.is_nil(ctx.store.get(c2.id).dispatching, "dispatching cleared")
  local turns = ctx.store.turns(ctx.store.get(c2.id))
  local tail = turns[#turns]
  T.eq(tail.author, "you", "the empty agent placeholder was dropped — tail is your message again")
  T.eq(tail.text, "go")
  T.eq(require("obelus").busy(c2.id), false)
end)

-- ---------------------------------------------------------------------------
-- 4b. delete mid-stream cancels the job
-- ---------------------------------------------------------------------------

T.it("delete mid-stream cancels the job", function()
  local ctx, F = fresh_stream_ctx()
  local c = ctx.store.add(T.comment({ comment = "please look at this" }))
  local jobs = require("obelus.jobs")

  require("obelus").chat_send(c.id, "go", "send")
  T.eq(ctx.store.get(c.id).dispatching, true)
  T.ok(jobs.is_running(c.id), "a job is registered while streaming")

  require("obelus").delete(c.id)

  T.eq(F.cancelled, true, "delete killed the live job before removing the comment")
  T.is_nil(ctx.store.get(c.id), "the comment is gone")
  T.eq(jobs.is_running(c.id), false, "no job remains registered for the deleted id")
end)

-- ---------------------------------------------------------------------------
-- 5. busy guard
-- ---------------------------------------------------------------------------

-- jobs.lua gives busy() provenance: it trusts ANY registered job (not just a cli
-- subprocess), so the fake transport's registered job (tests/fake.lua's F.install)
-- is now seen as live too. do_respond's "the agent is still replying" guard holds
-- for non-cli transports — a concurrent send during streaming is REJECTED, not
-- silently let through by a self-heal.
T.it("busy guard: a concurrent send during streaming is rejected (not let through by self-heal)", function()
  local ctx, F = fresh_stream_ctx()
  -- F itself only remembers the LAST streamed payload (no counter), so count
  -- dispatches ourselves by wrapping the just-registered "fake" transport handler.
  local registry = require("obelus.transport")
  local inner = registry.transports.fake
  local dispatch_count = 0
  registry.transports.fake = function(payload)
    dispatch_count = dispatch_count + 1
    inner(payload)
  end

  local c = ctx.store.add(T.comment({ comment = "please look" }))

  require("obelus").chat_send(c.id, "first", "send")
  T.eq(dispatch_count, 1, "the first send dispatched")
  T.eq(ctx.store.get(c.id).dispatching, true)

  -- Immediately send again, WITHOUT finish/cancel — this is the busy-guard scenario.
  require("obelus").chat_send(c.id, "second", "send")

  T.eq(dispatch_count, 1, "busy() rejected the second send — no second dispatch")
  T.eq(ctx.store.get(c.id).dispatching, true, "still mid the FIRST dispatch, untouched by the rejected second one")
  local turns = ctx.store.turns(ctx.store.get(c.id))
  T.eq(#turns, 2, "unchanged: comment turn + the first dispatch's empty agent placeholder")
  T.eq(turns[1].author, "you")
  T.eq(
    turns[1].text,
    "first",
    "the second send's text ('second') was never saved — busy() rejects before set_pending_you"
  )
  T.eq(turns[2].author, "agent")
  T.eq(turns[2].text, "", "still the first dispatch's untouched placeholder")
end)

-- ---------------------------------------------------------------------------
-- 6. cli spawn failure rolls back (real cli transport, missing binary)
-- ---------------------------------------------------------------------------

-- vim.system raises synchronously when the executable can't be spawned (verified
-- against Neovim's vim._core.system: `spawn()` calls `error(...)` directly, not via
-- the exit callback) — cli.lua's `pcall(vim.system, ...)` catches that and rolls the
-- thread back. The chain do_respond -> transport.submit -> the cli handler is each
-- pcall'd in turn, so no error escapes to this call site; no pcall needed here.
T.it("spawn failure rolls back: dispatching clears, placeholder popped, comment survives", function()
  local ctx = T.fresh({ transport = { dispatch = "cli", cli = { cmd = { "obelus-no-such-binary-xyz" } } } })
  local jobs = require("obelus.jobs")
  local c = ctx.store.add(T.comment({ comment = "please look at this" }))

  require("obelus").chat_send(c.id, "hello", "send")

  T.is_nil(ctx.store.get(c.id).dispatching, "dispatching rolled back")
  T.eq(require("obelus").busy(c.id), false)
  T.eq(jobs.is_running(c.id), false, "the job registration was cleared on spawn failure")
  local turns = ctx.store.turns(ctx.store.get(c.id))
  T.eq(turns[#turns].author, "you", "the empty agent placeholder was rolled back — tail is your message again")
  T.eq(turns[#turns].text, "hello")
  T.ok(ctx.store.get(c.id) ~= nil, "the comment still exists")
end)

-- ---------------------------------------------------------------------------
-- 7. the hover preview's stream-finish repaint is forced (trailing edge)
-- ---------------------------------------------------------------------------

-- fill_preview is throttled/coalesced now, and the finish path's refresh calls are
-- unforced — so a delta→finish landing inside one throttle window used to leave the
-- finalized text permanently unpainted (the progress timer stops with the job, so
-- nothing re-ticks). seat_finish's forced preview repaint is the guarantee.
T.it("preview: the stream's final text lands without interaction (forced finish repaint)", function()
  local F = require("fake")
  local ctx = T.fresh({
    transport = { dispatch = "fake" },
    render = { renderer = "builtin", bands = { style = "popup" } },
  })
  F.reset()
  F.install()
  local panel = require("obelus.panel")
  -- DEFAULT fill_throttle (160ms) on purpose: the regression needs delta→finish to
  -- land inside one throttle window; a shrunken throttle would mask it
  require("obelus.progress")._timing.tick = 20

  local file = ctx.root .. "/p.lua"
  vim.fn.writefile({ "local a = 1" }, file)
  vim.cmd("edit " .. file)
  local fabs = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
  local c = ctx.store.add(T.comment({ file = fabs, range = { sl = 1, el = 1 } }))
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  panel.preview(c.id)
  T.ok(panel.preview_geom() ~= nil, "the hover preview is showing")

  require("obelus").chat_send(c.id, "go", "send")
  F.delta("almost ")
  F.finish(true, "sess-p") -- immediately: same throttle window as the delta's repaint
  -- amend nothing further — the final text must land with NO cursor move / no ticks
  T.ok(
    T.wait_for(function()
      local g = panel.preview_geom()
      if not (g and g.buf and vim.api.nvim_buf_is_valid(g.buf)) then
        return false
      end
      return table.concat(vim.api.nvim_buf_get_lines(g.buf, 0, -1, false), "\n"):find("almost", 1, true) ~= nil
    end, 1000),
    "the finalized reply text painted into the preview without any interaction"
  )
end)

-- ---------------------------------------------------------------------------
-- 8. the project (meta) thread: briefing + write-back fan-out + resumed sends
-- ---------------------------------------------------------------------------

T.it(
  "meta send: first chat_send briefs the project + the user text; actions_comments fans out to real ids only",
  function()
    local ctx, F = fresh_stream_ctx()
    local pending = ctx.store.add(T.comment({ comment = "please review this pending thing" }))
    local resolved = ctx.store.add(T.comment({ comment = "already fixed" }))
    ctx.store.resolve(resolved.id)
    local meta = ctx.store.meta_thread()

    require("obelus").chat_send(meta.id, "what's the state of the review?", "send")

    T.ok(F.payload, "the meta thread dispatched through the fake transport")
    T.contains(F.payload.markdown, "please review this pending thing", "the pending thread's text is in the briefing")
    T.contains(F.payload.markdown, "@thread:" .. resolved.id, "the resolved thread appears as a summary line")
    T.contains(F.payload.markdown, "what's the state of the review?", "the user's own text follows the briefing")

    local ids = {}
    for _, cm in ipairs(F.payload.opts.actions_comments) do
      ids[cm.id] = true
    end
    T.ok(ids[pending.id], "the pending thread's id is in the fan-out list")
    T.ok(ids[resolved.id], "the resolved thread's id is in the fan-out list too")
    T.is_nil(ids[meta.id], "the meta thread's OWN id is never in the fan-out list")

    F.finish(true, "sess-meta-1")
  end
)

T.it("meta send: a resumed send (session_id set) sends only the new text", function()
  local ctx, F = fresh_stream_ctx()
  ctx.store.add(T.comment({ comment = "some other thread" }))
  local meta = ctx.store.meta_thread()
  meta.session_id = "sess-meta-already" -- as a completed dispatch would have recorded

  require("obelus").chat_send(meta.id, "follow-up question", "send")

  T.ok(F.payload, "dispatched")
  T.eq(F.payload.opts.resume, "sess-meta-already")
  T.eq(F.payload.markdown, "follow-up question", "no re-briefing on a resumed send")
  F.finish(true, "sess-meta-already")
end)

-- cli transport (real, vim.system stubbed — same idiom as mention_completion_spec's
-- ":ObelusPrompt" test): the ACTUAL Review protocol block cli.lua injects, gated on
-- opts.actions_comments regardless of transport.chat_actions (default false).
T.it(
  "meta send: cli actions gating — actions_comments present forces the Review protocol, listing real ids only",
  function()
    local ctx = T.fresh({ transport = { dispatch = "cli", cli = { cmd = { "claude", "-p" } } } })
    local c1 = ctx.store.add(T.comment({ comment = "one" }))
    local c2 = ctx.store.add(T.comment({ comment = "two" }))
    local meta = ctx.store.meta_thread()

    local real_system = vim.system
    local captured
    vim.system = function(cmd, _opts)
      captured = cmd
      return {
        kill = function() end,
        wait = function()
          return { code = 0, stdout = "" }
        end,
        pid = 1,
      }
    end
    require("obelus").chat_send(meta.id, "status please", "send")
    vim.system = real_system

    T.ok(captured, "the cli transport spawned")
    local prompt = require("obelus.log").prompt()
    T.contains(
      prompt,
      "Review protocol",
      "the write-back protocol block is present (chat_actions is false by default — actions_comments overrides it)"
    )
    T.contains(prompt, c1.id, "the first real thread's id is listed")
    T.contains(prompt, c2.id, "the second real thread's id is listed")
    T.ok(
      not prompt:find("- " .. meta.id .. "  ", 1, true),
      "the meta thread's OWN id is not among the LISTED comments (only real ids are)"
    )
  end
)

-- ---------------------------------------------------------------------------
-- 8b. tag meta threads: scoped briefing, own session, SUBMIT-ALL's batch round
-- ---------------------------------------------------------------------------

T.it(
  "tag meta send (plain RESPOND): briefs ONLY that tag's threads, drafts excluded; actions_comments scoped to the tag",
  function()
    local ctx, F = fresh_stream_ctx()
    local auth_pending = ctx.store.add(T.comment({ comment = "fix the auth check" }))
    ctx.store.tag_comment(auth_pending.id, "auth")
    local auth_draft = ctx.store.add(T.comment({ comment = "check the token expiry" }))
    ctx.store.tag_comment(auth_draft.id, "auth")
    ctx.store.add_turn(auth_draft.id, "agent", "looks fine to me")
    ctx.store.set_pending_you(auth_draft.id, "actually, double check the refresh path")
    local perf = ctx.store.add(T.comment({ comment = "speed up the query" }))
    ctx.store.tag_comment(perf.id, "perf")
    local untagged = ctx.store.add(T.comment({ comment = "totally unrelated thread" }))

    local tagmeta = ctx.store.tag_meta_thread("auth")
    require("obelus").chat_send(tagmeta.id, "what's the state of #auth?", "send")

    T.ok(F.payload, "the tag meta dispatched through the fake transport")
    T.contains(F.payload.markdown, "fix the auth check", "the #auth pending thread is in the briefing")
    T.contains(F.payload.markdown, "looks fine to me", "the #auth thread's sent agent turn is shown in full")
    T.ok(
      not F.payload.markdown:find("actually, double check the refresh path", 1, true),
      "a member's unsent draft TEXT is never in the briefing (plain RESPOND excludes drafts)"
    )
    T.contains(F.payload.markdown, "has an unsent draft, not shown", "the skipped draft is noted instead")
    T.ok(not F.payload.markdown:find("speed up the query", 1, true), "a DIFFERENT tag's thread is absent")
    T.ok(not F.payload.markdown:find("totally unrelated thread", 1, true), "an untagged thread is absent")
    T.contains(F.payload.markdown, "what's the state of #auth?", "the user's own text follows the briefing")

    local ids = {}
    for _, cm in ipairs(F.payload.opts.actions_comments) do
      ids[cm.id] = true
    end
    T.ok(ids[auth_pending.id], "the #auth pending thread is in the fan-out list")
    T.ok(ids[auth_draft.id], "the #auth draft-holding thread is in the fan-out list too")
    T.is_nil(ids[perf.id], "a DIFFERENT tag's thread is never in the fan-out list")
    T.is_nil(ids[untagged.id], "an untagged thread is never in the fan-out list")
    T.is_nil(ids[tagmeta.id], "the tag meta's OWN id is never in the fan-out list")

    F.finish(true, "sess-tag-auth-1")
  end
)

-- SUPERSEDES the old "rides its OWN session — independent of the batch's" MVP
-- test: unified tag conversations (feat/tag-sessions) make the tag meta's session
-- the ONE canonical session for its whole tag — the batch now resumes THIS same
-- session (see obelus.batch.create's doc comment) rather than keeping an
-- independent one. The global meta stays independent (untouched design point).
T.it(
  "tag meta send: founds/rides the UNIFIED tag session — the tag's batch resumes the SAME session, independent of the global meta",
  function()
    local ctx, F = fresh_stream_ctx({ transport = { batch = { transport = "fake" } } })
    local c = ctx.store.add(T.comment({ comment = "some auth thing" }))
    ctx.store.tag_comment(c.id, "auth")
    local global = ctx.store.meta_thread()
    global.session_id = "sess-global"

    local tagmeta = ctx.store.tag_meta_thread("auth")
    T.is_nil(tagmeta.session_id, "a fresh tag meta has no session yet")

    require("obelus").chat_send(tagmeta.id, "hello", "send")
    T.is_nil(F.payload.opts.resume, "first send: nothing to resume yet")
    T.eq(F.payload.opts.session_owner_id, tagmeta.id, "a captured session is owned by the tag meta")
    F.finish(true, "sess-tag-auth")

    T.eq(ctx.store.get(tagmeta.id).session_id, "sess-tag-auth", "the tag meta recorded the session")
    T.eq(ctx.store.get_meta().session_id, "sess-global", "the global meta's session is untouched — independent")

    require("obelus").chat_send(tagmeta.id, "follow-up", "send")
    T.eq(F.payload.opts.resume, "sess-tag-auth", "the SECOND send resumes the SAME (unified) tag session")
    F.finish(true, "sess-tag-auth")

    -- a batch created for this tag afterward resumes THIS session — unified, not
    -- independent — and never captures one of its own on the batch record.
    local created = require("obelus.batch").create({ c }, { tag = "auth" })
    T.ok(created, "batch created")
    T.eq(F.oneshots[1].opts.resume, "sess-tag-auth", "round 1 resumes the tag meta's already-established session")
    T.is_nil(created.session_id, "the batch record itself never gets its own session_id — it defers to the tag meta")
  end
)

T.it("tag meta SUBMIT-ALL: continues the tag's own open batch, folding in a member's draft + the typed note", function()
  local ctx = T.fresh({ transport = { dispatch = "fake", batch = { transport = "fake" } } })
  local F = require("fake")
  F.reset()
  F.install()

  local c1 = ctx.store.add(T.comment({ comment = "fix the auth check" }))
  ctx.store.tag_comment(c1.id, "auth")
  local c2 = ctx.store.add(T.comment({ comment = "check the token expiry" }))
  ctx.store.tag_comment(c2.id, "auth")

  local batch = require("obelus.batch")
  local created = batch.create({ c1 }, { tag = "auth" })
  T.ok(created, "the tag's batch was created (one-shot, non-stream dispatch — see F.oneshots)")
  -- unified tag session: a TAGGED batch defers session CAPTURE to its tag meta,
  -- never the batch record (obelus.batch.create's session_owner_id) — simulate
  -- that capture (F.finish_batch mirrors cli.lua's run_oneshot owner-id branch)
  -- so the round below takes the normal resumed-session "diff" path
  -- (round_prompt, which labels members by id) instead of a full re-serialization
  -- (no ids to grep for).
  T.eq(
    created.session_id,
    nil,
    "the batch record itself never captures a session for a TAGGED batch — it defers to the tag meta"
  )
  F.finish_batch("sess-tag-auth-1")
  T.eq(ctx.store.tag_meta_thread("auth").session_id, "sess-tag-auth-1", "the captured session landed on the tag meta")

  -- c2 is NOT yet a batch member and carries a saved-but-unsent draft reply —
  -- SUBMIT-ALL must fold it in as a new member of the round, same as any other
  -- pending thread (store.pending()/pending_by_tag already treat a trailing
  -- "you" turn as pending regardless of whether it was ever formally "sent").
  ctx.store.set_pending_you(c2.id, "wait, also check the refresh token")

  local tagmeta = ctx.store.tag_meta_thread("auth")
  require("obelus").submit_all(tagmeta.id, "please prioritize the token issue")

  T.eq(#F.oneshots, 2, "the create dispatch, then SUBMIT-ALL's continue round dispatch")
  local payload = F.oneshots[#F.oneshots]
  T.contains(payload.markdown, "please prioritize the token issue", "the typed note became the round instruction")
  T.contains(payload.markdown, c2.id, "the newly-folded draft-holding member's id is in the round diff")

  local reloaded = ctx.store.get_batch(created.id)
  T.eq(reloaded.round, 2, "the batch advanced to round 2 via the EXISTING batch machinery")
  local member_ids = {}
  for _, id in ipairs(reloaded.comment_ids) do
    member_ids[id] = true
  end
  T.ok(member_ids[c1.id] and member_ids[c2.id], "both threads (incl. the draft-holder) are now batch members")

  T.eq(
    ctx.store.pending_you_text(ctx.store.get(c2.id)),
    "wait, also check the refresh token",
    "SUBMIT-ALL doesn't itself rewrite the draft text — the round's own agent write-back reply is what "
      .. "settles it into a real turn, same as any other reply"
  )
end)

T.it("submit_all: in the GLOBAL meta or an ordinary thread, falls back to a plain send", function()
  local ctx, F = fresh_stream_ctx()
  local global = ctx.store.meta_thread()
  require("obelus").submit_all(global.id, "hello")
  T.ok(F.payload, "dispatched")
  T.eq(F.payload.opts.stream, true, "went through the normal streaming chat_send path, not a batch round")
  F.finish(true, "sess-g")

  local c = ctx.store.add(T.comment({ comment = "ordinary thread" }))
  require("obelus").submit_all(c.id, "hi")
  T.eq(F.payload.comments[1].id, c.id, "an ordinary thread also just gets a plain send")
  F.finish(true, "sess-c")
end)

-- ---------------------------------------------------------------------------
-- 9. streaming narration: grey while streaming, collapsed at finish
-- ---------------------------------------------------------------------------

local function tail_turn(ctx, c)
  local turns = ctx.store.turns(ctx.store.get(c.id))
  return turns[#turns]
end

T.it("narration: a two-block stream's mid-stream turn holds both blocks + a live narration_end", function()
  local ctx, F = fresh_stream_ctx()
  local c = open_file_comment(ctx)
  open_and_send(c, "hello agent")

  F.block_start() -- the very first block: no leading separator
  F.delta("Let me check the file first.")
  F.block_start() -- tools ran; the agent starts a genuinely new block
  F.delta("The fix is simple.")

  local t = tail_turn(ctx, c)
  T.eq(t.text, "Let me check the file first.\n\nThe fix is simple.", "both blocks are visible mid-stream")
  T.ok(t.narration_end and t.narration_end > 0, "narration_end tracks the latest block's start")
  T.eq(t.text:sub(t.narration_end + 1), "The fix is simple.", "narration_end lands right at the final block")
end)

T.it("narration: finish collapses to the final block only (default render.narration = 'collapse')", function()
  local ctx, F = fresh_stream_ctx()
  local c = open_file_comment(ctx)
  open_and_send(c, "hello agent")

  F.block_start()
  F.delta("Let me check the file first.")
  F.block_start()
  F.delta("The fix is simple.")
  F.finish(true, "sess-narr-1")

  local t = tail_turn(ctx, c)
  T.eq(t.text, "The fix is simple.", "only the final block survives — the interim narration is gone")
  T.ok(not t.text:match("^\n"), "no leading blank line left behind")
  T.is_nil(t.narration_end, "narration_end is stripped once the turn settles")
end)

T.it('narration: render.narration = "keep" preserves the full narration on finish', function()
  local ctx, F = fresh_stream_ctx({ render = { narration = "keep" } })
  local c = open_file_comment(ctx)
  open_and_send(c, "hello agent")

  F.block_start()
  F.delta("Let me check the file first.")
  F.block_start()
  F.delta("The fix is simple.")
  F.finish(true, "sess-narr-2")

  local t = tail_turn(ctx, c)
  T.eq(t.text, "Let me check the file first.\n\nThe fix is simple.", "keep mode stores the whole accumulated reply")
  T.is_nil(t.narration_end, "narration_end is still stripped — it's runtime-only regardless of the mode")
end)

T.it("narration: guard — a stream that ends right after a block_start keeps the full acc", function()
  local ctx, F = fresh_stream_ctx()
  local c = open_file_comment(ctx)
  open_and_send(c, "hello agent")

  F.delta("Let me check the file first.")
  F.block_start() -- opens but nothing ever follows it — an "empty final block"
  F.finish(true, "sess-narr-3")

  local t = tail_turn(ctx, c)
  T.eq(t.text, "Let me check the file first.", "never store an empty reply — the guard kept the only real text")
end)

T.it("tag-meta RESPOND: an explicit @thread pull-back still hides the member's draft", function()
  local F = require("fake")
  local ctx = T.fresh({ transport = { dispatch = "fake" } })
  F.install()
  local m = ctx.store.add(T.comment({ comment = "member thread" }))
  ctx.store.tag_comment(m.id, "auth")
  ctx.store.add_turn(m.id, "agent", "earlier agent reply")
  ctx.store.set_pending_you(m.id, "SECRET DRAFT do not send")
  local tm = ctx.store.tag_meta_thread("auth")
  require("obelus").chat_send(tm.id, "context on @thread:" .. m.id .. " please", "send")
  T.ok(F.payload, "dispatched")
  T.contains(F.payload.markdown, "[Mentioned threads]", "the pull-back expanded")
  T.ok(not F.payload.markdown:find("SECRET DRAFT", 1, true), "the draft did NOT leak through the mention")
  T.contains(F.payload.markdown, "unsent draft, not shown", "the skip note travels with the expansion")
end)

T.it("batch.continue persists folded-in membership even when the dispatch fails", function()
  local F = require("fake")
  local ctx = T.fresh({ transport = { dispatch = "fake", batch = { enabled = true, transport = "fake" } } })
  F.install()
  local c1 = ctx.store.add(T.comment({ comment = "one" }))
  ctx.store.tag_comment(c1.id, "auth")
  require("obelus.batch").create({ ctx.store.get(c1.id) }, { tag = "auth" })
  local b = require("obelus.batch").open_for_tag("auth")
  T.ok(b, "batch open")
  local c2 = ctx.store.add(T.comment({ comment = "two" }))
  ctx.store.tag_comment(c2.id, "auth")
  -- make the NEXT dispatch fail
  require("obelus.transport").register("fake", function()
    error("boom")
  end)
  require("obelus.batch").continue("round note", b)
  local ids = {}
  for _, id in ipairs(require("obelus.batch").open_for_tag("auth").comment_ids or {}) do
    ids[id] = true
  end
  T.ok(ids[c2.id], "the new member's id is in comment_ids despite the failed round")
end)
