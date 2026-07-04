-- e2e: the full streaming lifecycle over the fake transport (tests/fake.lua) — send,
-- deltas, finish, cancel, and the busy guard. The first true end-to-end chat test:
-- exercises obelus.chat_send -> do_respond -> transport.submit -> the fake transport's
-- store.stream_* choreography -> progress's tick -> panel.refresh()/fill(), all driven
-- synchronously (no real subprocess, no sleeping past real timing).
T.describe("e2e")

-- Fresh obelus + a fresh fake transport registration, with the wall-clock knobs
-- shrunk so a T.wait_for actually observes the tick/fill propagation quickly.
local function fresh_stream_ctx()
  local F = require("fake")
  local ctx = T.fresh({ transport = { dispatch = "fake" }, render = { renderer = "builtin" } })
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
