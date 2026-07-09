-- Unified tag conversations (feat/tag-sessions): a tag = ONE agent conversation,
-- owned by the tag meta record (tag_meta.session_id is canonical). Every send
-- concerning tag T — the tag thread's own messages, a single-thread reply on a
-- TAGGED member, and a batch round (obelus.batch) — resumes THAT session; a
-- captured session lands back on the tag meta, never a member's own c.session_id.
-- See review.lua's do_respond, obelus.batch, store.lua's tag_membership_delta /
-- commit_tag_known_ids / add_tag_crossref, format.lua's tag_deltas.
T.describe("tag_session")

local function fresh_ctx(extra)
  local F = require("fake")
  local base = { transport = { dispatch = "fake", batch = { transport = "fake" } } }
  local ctx = T.fresh(extra and vim.tbl_deep_extend("force", base, extra) or base)
  F.reset()
  F.install()
  return ctx, F
end

-- ---------------------------------------------------------------------------
-- founding: the tag thread's first send briefs every current member ONCE
-- ---------------------------------------------------------------------------

T.it("tag-thread founding send: JOIN-briefs every currently-tagged member, once", function()
  local ctx, F = fresh_ctx()
  local a = ctx.store.add(T.comment({ comment = "fix the auth check" }))
  ctx.store.tag_comment(a.id, "auth")
  local b = ctx.store.add(T.comment({ comment = "check token expiry" }))
  ctx.store.tag_comment(b.id, "auth")

  local tagmeta = ctx.store.tag_meta_thread("auth")
  require("obelus").chat_send(tagmeta.id, "what's up with #auth?", "send")

  T.ok(F.payload, "dispatched")
  T.contains(F.payload.markdown, "JOINED the #auth conversation:")
  T.contains(F.payload.markdown, "fix the auth check")
  T.contains(F.payload.markdown, "check token expiry")
  T.contains(F.payload.markdown, "what's up with #auth?", "the user's text follows the briefing")
  F.finish(true, "sess-1")

  local known = ctx.store.get_meta("auth").known_ids
  T.eq(#known, 2, "known_ids now covers both founding members")
end)

T.it("tag-thread SECOND send: no join blocks at all (known_ids already covers everyone)", function()
  local ctx, F = fresh_ctx()
  local a = ctx.store.add(T.comment({ comment = "fix the auth check" }))
  ctx.store.tag_comment(a.id, "auth")
  local tagmeta = ctx.store.tag_meta_thread("auth")

  require("obelus").chat_send(tagmeta.id, "first", "send")
  F.finish(true, "sess-1")

  require("obelus").chat_send(tagmeta.id, "second — any update?", "send")
  T.ok(not F.payload.markdown:find("JOINED", 1, true), "nothing new joined since the founding send")
  T.eq(F.payload.markdown, "second — any update?", "just the plain follow-up text (plus no delta, no preamble)")
  T.eq(F.payload.opts.resume, "sess-1", "resumes the founded session")
  F.finish(true, "sess-1")
end)

-- ---------------------------------------------------------------------------
-- member replies: scoping, write-back scope, resume, model, session ownership
-- ---------------------------------------------------------------------------

T.it("member reply: scoping preamble present, resume == tag session, model == models.batch", function()
  local ctx, F = fresh_ctx({ transport = { cli = { models = { send = "light", batch = "heavy" } } } })
  local m = ctx.store.add(T.comment({ comment = "fix the auth check" }))
  ctx.store.tag_comment(m.id, "auth")

  require("obelus").chat_send(m.id, "please also check refresh tokens", "send")

  T.ok(F.payload, "dispatched")
  T.contains(F.payload.markdown, "This message concerns ONLY the thread below")
  T.contains(F.payload.markdown, "#auth")
  T.contains(F.payload.markdown, "please also check refresh tokens")
  T.eq(F.payload.opts.model, "heavy", "tag-session sends default to models.batch")
  local tagmeta = ctx.store.get_meta("auth")
  T.ok(tagmeta, "the tag meta was get-or-created")
  T.eq(F.payload.opts.resume, tagmeta.session_id, "resumes the tag session (nil on this founding send)")
  T.eq(F.payload.opts.session_owner_id, tagmeta.id, "captured session is owned by the tag meta")
  F.finish(true, "sess-member-1")
end)

T.it(
  "member reply: write-back scope is ENFORCED to {X} only — actions_comments never includes tag siblings",
  function()
    local ctx, F = fresh_ctx()
    local m = ctx.store.add(T.comment({ comment = "member one" }))
    ctx.store.tag_comment(m.id, "auth")
    local sibling = ctx.store.add(T.comment({ comment = "member two" }))
    ctx.store.tag_comment(sibling.id, "auth")

    require("obelus").chat_send(m.id, "just about you", "send")
    T.eq(#F.payload.opts.actions_comments, 1)
    T.eq(F.payload.opts.actions_comments[1].id, m.id, "ONLY the replied-to thread is in the write-back scope")
    F.finish(true, "sess-1")
  end
)

T.it("member reply: a captured session lands on the TAG META, never on the member's own c.session_id", function()
  local ctx, F = fresh_ctx()
  local m = ctx.store.add(T.comment({ comment = "fix it" }))
  ctx.store.tag_comment(m.id, "auth")

  require("obelus").chat_send(m.id, "go", "send")
  F.finish(true, "sess-captured")

  T.eq(ctx.store.get_meta("auth").session_id, "sess-captured", "the tag meta captured the session")
  T.is_nil(ctx.store.get(m.id).session_id, "the member's OWN session_id field is never touched")
end)

T.it(
  "member reply on a thread that just joined: its identity comes via the JOIN block, not a separate resend",
  function()
    local ctx, F = fresh_ctx()
    local m = ctx.store.add(T.comment({ comment = "fresh auth thread" }))
    ctx.store.tag_comment(m.id, "auth")
    -- an agent turn already in place: otherwise the reply below (its first-ever
    -- send) would update the still-unsent COMMENT text in place (store.
    -- set_pending_you's n==1 case) instead of adding a new turn — unrelated to
    -- this test, which is about the join block, not draft/comment semantics.
    ctx.store.add_turn(m.id, "agent", "looked into it already")

    require("obelus").chat_send(m.id, "look at this", "send")
    T.contains(F.payload.markdown, "JOINED the #auth conversation:", "this member's own first send is also its join")
    T.contains(F.payload.markdown, "fresh auth thread")
    T.contains(
      F.payload.markdown,
      "looked into it already",
      "the join block carries the FULL thread, not just the comment"
    )
    F.finish(true, "sess-1")

    -- a SECOND reply on the SAME already-known member: no join block this time —
    -- the model already has its identity from the first send.
    require("obelus").chat_send(m.id, "any update?", "send")
    T.ok(not F.payload.markdown:find("JOINED", 1, true), "already known — not re-briefed")
    T.contains(
      F.payload.markdown,
      "This message concerns ONLY the thread below",
      "the scoping preamble still shows every time"
    )
    F.finish(true, "sess-1")
  end
)

T.it("member reply: cross-reference line appended to the tag meta's transcript, agent-authored", function()
  local ctx, F = fresh_ctx()
  local m =
    ctx.store.add(T.comment({ file = "/tmp/obelus-test/sample.lua", range = { sl = 1, el = 1 }, comment = "x" }))
  ctx.store.tag_comment(m.id, "auth")

  require("obelus").chat_send(m.id, "fix the token refresh path please", "send")
  F.finish(true, "sess-1")

  local tagmeta = ctx.store.get_meta("auth")
  local turns = ctx.store.turns(tagmeta)
  local tail = turns[#turns]
  T.eq(tail.author, "agent", "the cross-ref is agent-authored")
  T.contains(tail.text, "↳ re")
  T.contains(tail.text, "sample.lua")
  T.contains(tail.text, "fix the token refresh path please", "the first line of the user's message is quoted")
end)

T.it("member reply: the cross-ref does NOT flip the tag thread into a pending/awaiting-reply state", function()
  local ctx, F = fresh_ctx()
  local m = ctx.store.add(T.comment({ comment = "x" }))
  ctx.store.tag_comment(m.id, "auth")
  require("obelus").chat_send(m.id, "go", "send")
  F.finish(true, "sess-1")

  local tagmeta = ctx.store.get_meta("auth")
  T.is_nil(ctx.store.pending_you_text(tagmeta), "no draft appears on the tag thread from the cross-ref")
  local pending_ids = {}
  for _, c in ipairs(ctx.store.pending()) do
    pending_ids[c.id] = true
  end
  T.is_nil(pending_ids[tagmeta.id], "the tag thread never enters store.pending() because of a cross-ref")
end)

-- ---------------------------------------------------------------------------
-- untag -> fork, retag a -> b
-- ---------------------------------------------------------------------------

T.it(
  "untag forks: the member's session clears, and the next respond founds FRESH via thread_full (not comment_md)",
  function()
    local ctx, F = fresh_ctx()
    local m = ctx.store.add(T.comment({ comment = "fix it" }))
    ctx.store.tag_comment(m.id, "auth")
    require("obelus").chat_send(m.id, "go", "send")
    F.finish(true, "sess-1")
    ctx.store.add_turn(m.id, "agent", "on it")

    ctx.store.tag_comment(m.id, nil) -- untag: fork
    T.is_nil(ctx.store.get(m.id).session_id, "untagging cleared the stale session_id")

    require("obelus").chat_send(m.id, "still there?", "send")
    T.is_nil(F.payload.opts.resume, "a genuinely fresh session — nothing to resume")
    T.contains(F.payload.markdown, "on it", "thread_full (own turns only) founds the fresh prompt, not comment_md")
    T.contains(F.payload.markdown, "still there?")
    T.ok(
      not F.payload.markdown:find("This message concerns ONLY", 1, true),
      "no longer tag-session framing — plain thread"
    )
    F.finish(true, "sess-forked")
  end
)

T.it("retag a -> b: a's NEXT tag-session send reports the leave; b's founding send reports the join", function()
  local ctx, F = fresh_ctx()
  local m = ctx.store.add(T.comment({ file = ctx.root .. "/sample.lua", range = { sl = 1, el = 1 }, comment = "x" }))
  ctx.store.tag_comment(m.id, "auth")
  require("obelus").chat_send(m.id, "go", "send") -- founds #auth, m joins
  F.finish(true, "sess-auth-1")

  ctx.store.tag_comment(m.id, "perf") -- retag auth -> perf

  -- b (perf)'s founding send: m is a join
  require("obelus").chat_send(m.id, "look at perf now", "send")
  T.contains(F.payload.markdown, "JOINED the #perf conversation:")
  F.finish(true, "sess-perf-1")

  -- a (auth)'s next send: m shows as a LEFT line (still exists, just elsewhere now)
  local other = ctx.store.add(T.comment({ comment = "another auth thing" }))
  ctx.store.tag_comment(other.id, "auth")
  local authmeta = ctx.store.tag_meta_thread("auth")
  require("obelus").chat_send(authmeta.id, "status?", "send")
  T.contains(F.payload.markdown, "LEFT the conversation (do not act on it): sample.lua L1-L1")
  F.finish(true, "sess-auth-2")
end)

-- ---------------------------------------------------------------------------
-- batch rounds: resume the tag session, no double-briefing, round cross-refs,
-- interstitial respond doesn't bump batch.round
-- ---------------------------------------------------------------------------

T.it(
  "batch round 1: resumes an ALREADY-established tag session (from an earlier tag-thread chat) instead of forking",
  function()
    local ctx, F = fresh_ctx()
    local c = ctx.store.add(T.comment({ comment = "fix the auth check" }))
    ctx.store.tag_comment(c.id, "auth")
    local tagmeta = ctx.store.tag_meta_thread("auth")
    require("obelus").chat_send(tagmeta.id, "hi", "send")
    F.finish(true, "sess-established")

    local created = require("obelus.batch").create({ c }, { tag = "auth" })
    T.ok(created, "batch created")
    T.eq(F.oneshots[1].opts.resume, "sess-established", "round 1 resumed the ALREADY-established tag session")
    T.eq(F.oneshots[1].opts.session_owner_id, tagmeta.id)
  end
)

T.it(
  "batch round: no double-briefing — a member already joined via a prior send is NOT re-joined by the round",
  function()
    local ctx, F = fresh_ctx()
    local c = ctx.store.add(T.comment({ comment = "fix the auth check" }))
    ctx.store.tag_comment(c.id, "auth")
    local tagmeta = ctx.store.tag_meta_thread("auth")
    require("obelus").chat_send(tagmeta.id, "hi", "send") -- c joins here
    F.finish(true, "sess-1")

    require("obelus.batch").create({ c }, { tag = "auth" })
    T.ok(
      not F.oneshots[1].markdown:find("JOINED", 1, true),
      "c was already briefed — no repeat join in the round prompt"
    )
  end
)

T.it("batch round + cross-ref: a round dispatch appends 'round N sent — K threads' to the tag meta", function()
  local ctx, F = fresh_ctx()
  local c1 = ctx.store.add(T.comment({ comment = "one" }))
  ctx.store.tag_comment(c1.id, "auth")
  local c2 = ctx.store.add(T.comment({ comment = "two" }))
  ctx.store.tag_comment(c2.id, "auth")

  local batch = require("obelus.batch")
  local created = batch.create({ c1, c2 }, { tag = "auth" })
  T.ok(created, "round 1 dispatched")
  local tagmeta = ctx.store.get_meta("auth")
  -- cross-refs (and known_ids) commit on RUN SUCCESS, not dispatch start — a
  -- spawned-but-failed run must not advance the membership baseline
  local turns = ctx.store.turns(tagmeta)
  T.ok(not (turns[#turns].text or ""):find("round 1 sent", 1, true), "no cross-ref before the run finishes")
  F.finish_batch("sess-r1")
  turns = ctx.store.turns(tagmeta)
  T.eq(turns[#turns].author, "agent")
  T.contains(turns[#turns].text, "round 1 sent — 2 threads")

  batch.continue("do more", created)
  F.finish_batch("sess-r1")
  turns = ctx.store.turns(tagmeta)
  T.eq(turns[#turns].author, "agent")
  T.contains(turns[#turns].text, "round 2 sent")
end)

T.it("interstitial respond (a plain member reply) does NOT bump the tag's open batch.round", function()
  local ctx, F = fresh_ctx()
  local c1 = ctx.store.add(T.comment({ comment = "one" }))
  ctx.store.tag_comment(c1.id, "auth")
  local c2 = ctx.store.add(T.comment({ comment = "two" }))
  ctx.store.tag_comment(c2.id, "auth")

  local batch = require("obelus.batch")
  local created = batch.create({ c1, c2 }, { tag = "auth" })
  T.ok(created, "round 1 dispatched")
  F.finish_batch("sess-r1")
  local round_before = ctx.store.get_batch(created.id).round

  require("obelus").chat_send(c1.id, "just a quick side note", "send") -- plain member reply, not submit-all
  F.finish(true, "sess-r1")

  T.eq(ctx.store.get_batch(created.id).round, round_before, "an interstitial reply never touches batch.round")
end)

-- ---------------------------------------------------------------------------
-- models: untagged threads keep models.send; a fast send still honours models.fast
-- ---------------------------------------------------------------------------

T.it("model defaults: an ordinary (never-tagged) thread's send still uses models.send, not models.batch", function()
  local ctx, F = fresh_ctx({ transport = { cli = { models = { send = "light", batch = "heavy" } } } })
  local c = ctx.store.add(T.comment({ comment = "plain thread" }))
  require("obelus").chat_send(c.id, "hello", "send")
  T.eq(F.payload.opts.model, "light", "untagged threads are untouched — still models.send")
  F.finish(true, "sess-1")
end)

T.it(
  "model defaults: a FAST send on a tagged member honours models.fast, overriding the tag-session batch default",
  function()
    local ctx, F = fresh_ctx({ transport = { cli = { models = { send = "light", fast = "quick", batch = "heavy" } } } })
    local m = ctx.store.add(T.comment({ comment = "x" }))
    ctx.store.tag_comment(m.id, "auth")
    require("obelus").chat_send(m.id, "hello", "fast")
    T.eq(F.payload.opts.model, "quick", "an explicit fast send still wins")
    F.finish(true, "sess-1")
  end
)

-- ---------------------------------------------------------------------------
-- cross-entry-point busy guard: the shared session serializes across ALL of
-- its entry points (tag thread, member reply, batch round), not just within
-- each kind — avoids --resuming a session a live subprocess hasn't finished
-- writing to yet (obelus.batch.tag_busy).
-- ---------------------------------------------------------------------------

T.it("busy guard: a reply on a SIBLING tagged thread is rejected while another member is mid-dispatch", function()
  local ctx, F = fresh_ctx()
  local a = ctx.store.add(T.comment({ comment = "a" }))
  ctx.store.tag_comment(a.id, "auth")
  local b = ctx.store.add(T.comment({ comment = "b" }))
  ctx.store.tag_comment(b.id, "auth")

  require("obelus").chat_send(a.id, "go", "send") -- a is now mid-dispatch (no F.finish yet)
  T.eq(ctx.store.get(a.id).dispatching, true)
  local before = F.payload

  require("obelus").chat_send(b.id, "go too", "send")
  T.eq(F.payload, before, "no second dispatch happened — b's send was rejected")
  T.is_nil(ctx.store.get(b.id).dispatching, "b was never actually dispatched")

  F.finish(true, "sess-1") -- clean up a's in-flight dispatch
end)

T.it("busy guard: a batch round for a tag is rejected while the tag thread itself is mid-dispatch", function()
  local ctx, F = fresh_ctx()
  local c = ctx.store.add(T.comment({ comment = "x" }))
  ctx.store.tag_comment(c.id, "auth")
  local tagmeta = ctx.store.tag_meta_thread("auth")

  require("obelus").chat_send(tagmeta.id, "hello", "send") -- the tag thread is now mid-dispatch

  local created = require("obelus.batch").create({ c }, { tag = "auth" })
  T.is_nil(created, "the round was rejected — the tag session is busy")
  T.eq(#F.oneshots, 0, "no batch dispatch was even attempted")

  F.finish(true, "sess-1")
end)

T.it("a spawned-but-FAILED run does NOT advance known_ids — the retry re-briefs (no context hole)", function()
  local ctx, F = fresh_ctx()
  local c1 = ctx.store.add(T.comment({ comment = "one" }))
  ctx.store.tag_comment(c1.id, "auth")
  local tm = ctx.store.tag_meta_thread("auth")
  require("obelus").chat_send(tm.id, "founding message", "send")
  T.contains(F.payload.markdown, "JOINED", "founding send carried the join briefing")
  F.finish(false) -- the RUN failed after a successful spawn
  T.eq(#(ctx.store.get_meta("auth").known_ids or {}), 0, "failed run did not commit membership")
  -- retry: the agent never heard the briefing, so it must be re-sent
  F.payload = nil
  require("obelus").chat_send(tm.id, "retry", "send")
  T.contains(F.payload.markdown, "JOINED", "the retry re-briefs — no silent context hole")
  F.finish(true)
  T.eq(#(ctx.store.get_meta("auth").known_ids or {}), 1, "successful run commits membership")
end)

T.it("case-D founding prompt carries the user's message exactly ONCE (no draft duplication)", function()
  local ctx, F = fresh_ctx()
  local c = ctx.store.add(T.comment({ comment = "seed comment" }))
  ctx.store.add_turn(c.id, "agent", "an old reply") -- multi-turn so thread_full serializes turns
  require("obelus").chat_send(c.id, "UNIQUE-MESSAGE-TOKEN please", "send")
  local _, count = F.payload.markdown:gsub("UNIQUE%-MESSAGE%-TOKEN", "")
  T.eq(count, 1, "the message appears once, not as a mislabeled draft plus the live text")
  T.ok(not F.payload.markdown:find("draft, unsent", 1, true), "no phantom draft labeling")
end)

T.it("deleting the tag meta MID-RUN: the captured session is dropped with a notice, never a crash", function()
  -- real cli transport, vim.system stubbed (stream_spec's idiom): the run's exit
  -- callback fires AFTER the tag meta record was deleted — cli.lua's owner guard
  -- must notify instead of indexing a dead record
  local ctx = T.fresh({ transport = { dispatch = "cli", cli = { cmd = { "claude", "-p" } } } })
  local c = ctx.store.add(T.comment({ comment = "member thread" }))
  ctx.store.tag_comment(c.id, "auth")
  local tagmeta = ctx.store.tag_meta_thread("auth")

  local real_system, fed_stdout, on_exit = vim.system, nil, nil
  vim.system = function(_, opts, exit_cb)
    fed_stdout, on_exit = opts.stdout, exit_cb
    return {
      kill = function() end,
      wait = function()
        return { code = 0, stdout = "" }
      end,
      pid = 1,
    }
  end
  require("obelus").chat_send(c.id, "reply on the member", "send")
  T.ok(fed_stdout and on_exit, "spawned with stdout + exit handlers")
  fed_stdout(nil, vim.json.encode({ type = "system", session_id = "sess-doomed" }) .. "\n")
  fed_stdout(nil, vim.json.encode({
    type = "stream_event",
    event = { type = "content_block_delta", delta = { type = "text_delta", text = "done." } },
  }) .. "\n")

  ctx.store.remove(tagmeta.id) -- the owner dies while the run is still going

  local real_notify, notices = vim.notify, {}
  vim.notify = function(msg, ...)
    notices[#notices + 1] = tostring(msg)
    return real_notify(msg, ...)
  end
  local ok, err = pcall(on_exit, { code = 0, stdout = "", stderr = "" })
  vim.wait(100)
  vim.system, vim.notify = real_system, real_notify

  T.ok(ok, "the exit callback did not error: " .. tostring(err))
  local seen = false
  for _, msg in ipairs(notices) do
    if msg:find("deleted mid-run", 1, true) then
      seen = true
    end
  end
  T.ok(seen, "the user is told the session was not saved")
  T.is_nil(ctx.store.get(c.id).session_id, "the orphaned session never lands on the member thread")
end)
