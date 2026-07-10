-- The three dispatch modalities + the global edits toggle + per-tag models.
--   <prefix>s : ONE shared batch agent            (batch_spec territory, covered elsewhere)
--   <prefix>D : dispatch ONE thread, own agent    (review.dispatch)
--   <prefix>P : dispatch ALL in parallel, one agent EACH (review.dispatch_all — new)
-- Plus: transport.cli.models.tags (per-tag model override) and config.edits_enabled()
-- (:ObelusEdits — read-only `plan` permission mode for new cli spawns).
T.describe("modes")

local function fresh_ctx(extra)
  local F = require("fake")
  local base = { transport = { dispatch = "fake", batch = { transport = "fake" } } }
  local ctx = T.fresh(extra and vim.tbl_deep_extend("force", base, extra) or base)
  F.reset()
  F.install()
  return ctx, F
end

-- ---------------------------------------------------------------------------
-- dispatch_all: the parallel modality
-- ---------------------------------------------------------------------------

T.it("dispatch_all: every pending thread gets its OWN dispatch — resolved/meta threads don't", function()
  local ctx, F = fresh_ctx()
  local a = ctx.store.add(T.comment({ comment = "one" }))
  local b = ctx.store.add(T.comment({ comment = "two" }))
  local c = ctx.store.add(T.comment({ comment = "three" }))
  ctx.store.resolve(c.id)
  ctx.store.meta_thread() -- the project meta record is never dispatchable

  require("obelus").dispatch_all()

  T.eq(#F.oneshots, 2, "one dispatch per PENDING thread")
  local seen = {}
  for _, payload in ipairs(F.oneshots) do
    T.eq(#payload.comments, 1, "each dispatch carries exactly one thread")
    seen[payload.comments[1].id] = true
  end
  T.ok(seen[a.id] and seen[b.id], "both pending threads went out")
  T.is_nil(seen[c.id], "the resolved thread stayed put")
end)

T.it("dispatch_all: scopes to the sticky tag like a batch submit; '' (bang) ignores tag context", function()
  local ctx, F = fresh_ctx()
  local a = ctx.store.add(T.comment({ comment = "auth one" }))
  ctx.store.tag_comment(a.id, "auth")
  local b = ctx.store.add(T.comment({ comment = "untagged" }))

  ctx.store.set_active_tag("auth")
  require("obelus").dispatch_all()
  local first = #F.oneshots
  require("obelus").dispatch_all("") -- the bang form: ALL pending, tag context ignored
  local second = #F.oneshots
  ctx.store.set_active_tag(nil) -- clean up BEFORE asserting: sticky tags leak into later specs
  T.eq(first, 1, "sticky tag scopes the parallel dispatch")
  T.eq(F.oneshots[1].comments[1].id, a.id)
  -- a is mid-dispatch now, so the bang form picks up only the untagged leftover
  T.eq(second, 2, "'' dispatched the remaining pending set regardless of the sticky tag")
  T.eq(F.oneshots[2].comments[1].id, b.id)
end)

T.it("dispatch_all: a thread already mid-dispatch is skipped, not double-fired", function()
  local ctx, F = fresh_ctx()
  local a = ctx.store.add(T.comment({ comment = "busy one" }))
  ctx.store.add(T.comment({ comment = "free one" }))
  require("obelus").dispatch(a.id) -- first dispatch claims it (jobs/dispatching)
  local before = #F.oneshots
  require("obelus").dispatch_all()
  T.eq(#F.oneshots, before + 1, "only the free thread dispatched — no double-fire on the busy one")
end)

-- ---------------------------------------------------------------------------
-- per-tag model override (transport.cli.models.tags)
-- ---------------------------------------------------------------------------

T.it("models.tags: the tag thread's send, a member reply, and the tag batch all use the override", function()
  local ctx, F = fresh_ctx({
    transport = { cli = { models = { send = "sonnet", batch = "opus", tags = { auth = "special-model" } } } },
  })
  local a = ctx.store.add(T.comment({ comment = "member" }))
  ctx.store.tag_comment(a.id, "auth")

  -- case A: the tag thread's own message
  local tm = ctx.store.tag_meta_thread("auth")
  require("obelus").chat_send(tm.id, "hello tag", "send")
  T.eq(F.payload.opts.model, "special-model", "tag thread send uses the tag's model")
  F.finish(true, "sess-a")

  -- case B: a reply on the tagged member
  require("obelus").chat_send(a.id, "member reply", "send")
  T.eq(F.payload.opts.model, "special-model", "member reply rides the same tag model")
  F.finish(true, "sess-a")

  -- the tag batch round
  local batch = require("obelus.batch")
  batch.create({ a }, { model = nil, tag = "auth" })
  local payload = F.oneshots[#F.oneshots]
  T.ok(payload, "batch dispatched")
end)

T.it("models.tags: an unlisted tag falls back to models.batch; untagged batch unaffected", function()
  local ctx, F = fresh_ctx({
    transport = { cli = { models = { send = "sonnet", batch = "opus", tags = { auth = "special-model" } } } },
  })
  local p = ctx.store.add(T.comment({ comment = "perf thread" }))
  ctx.store.tag_comment(p.id, "perf")
  local tm = ctx.store.tag_meta_thread("perf")
  require("obelus").chat_send(tm.id, "hello", "send")
  T.eq(F.payload.opts.model, "opus", "unlisted tag → models.batch")
  F.finish(true)

  local plain = ctx.store.add(T.comment({ comment = "plain thread" }))
  require("obelus").chat_send(plain.id, "hi", "send")
  T.eq(F.payload.opts.model, "sonnet", "a never-tagged thread keeps models.send")
end)

T.it("models.tags: review.submit resolves the model AFTER the tag (batch.create gets the override)", function()
  local ctx, F = fresh_ctx({
    transport = { cli = { models = { send = "sonnet", batch = "opus", tags = { auth = "special-model" } } } },
  })
  local a = ctx.store.add(T.comment({ comment = "auth pending" }))
  ctx.store.tag_comment(a.id, "auth")
  ctx.store.set_active_tag("auth")
  require("obelus").submit()
  ctx.store.set_active_tag(nil)
  local payload = F.oneshots[#F.oneshots]
  T.ok(payload and payload.opts and payload.opts.batch, "a tag batch was created")
  T.eq(payload.opts.model, "special-model", "the batch went out on the tag's model")
end)

-- ---------------------------------------------------------------------------
-- the global edits toggle (:ObelusEdits) — real cli transport, stubbed spawn
-- ---------------------------------------------------------------------------

T.it("edits toggle: OFF swaps new cli spawns to --permission-mode plan; ON restores the configured cmd", function()
  local ctx = T.fresh({
    transport = { dispatch = "cli", cli = { cmd = { "claude", "-p", "--permission-mode", "acceptEdits" } } },
  })
  local cfgmod = require("obelus.config")
  local real_system = vim.system
  local captured
  vim.system = function(cmd)
    captured = cmd
    return {
      kill = function() end,
      wait = function()
        return { code = 0, stdout = "" }
      end,
      pid = 1,
    }
  end
  local ok, err = pcall(function()
    local function perm_mode(cmd)
      for i, v in ipairs(cmd) do
        if v == "--permission-mode" then
          return cmd[i + 1]
        end
      end
      return nil
    end

    local c1 = ctx.store.add(T.comment({ comment = "first" }))
    require("obelus").chat_send(c1.id, "with edits", "send")
    T.eq(perm_mode(captured), "acceptEdits", "default: the configured permission mode is untouched")
    ctx.store.abort(c1.id)

    require("obelus").toggle_edits(false)
    T.ok(not cfgmod.edits_enabled(), "toggle reports OFF")
    local c2 = ctx.store.add(T.comment({ comment = "second" }))
    require("obelus").chat_send(c2.id, "read only", "send")
    T.eq(perm_mode(captured), "plan", "edits OFF: the spawn runs claude's read-only plan mode")
    local _, n = table.concat(captured, " "):gsub("%-%-permission%-mode", "")
    T.eq(n, 1, "the configured flag was REPLACED, not doubled")
    ctx.store.abort(c2.id)

    require("obelus").toggle_edits() -- no-arg toggles back on
    T.ok(cfgmod.edits_enabled(), "toggle reports ON again")
    local c3 = ctx.store.add(T.comment({ comment = "third" }))
    require("obelus").chat_send(c3.id, "edits again", "send")
    T.eq(perm_mode(captured), "acceptEdits", "the user's exact configured mode came back")
    ctx.store.abort(c3.id)
  end)
  vim.system = real_system
  cfgmod.ui.edits = nil -- session-scoped: never leak the toggle into other specs
  if not ok then
    error(err, 0)
  end
end)

T.it(":ObelusEdits off twice STAYS off (the and/or-swallows-false command-arg trap)", function()
  T.fresh({})
  local cfgmod = require("obelus.config")
  vim.cmd("ObelusEdits off")
  T.ok(not cfgmod.edits_enabled(), "off turns it off")
  vim.cmd("ObelusEdits off")
  T.ok(not cfgmod.edits_enabled(), "off AGAIN keeps it off — never silently re-enables")
  vim.cmd("ObelusEdits on")
  T.ok(cfgmod.edits_enabled(), "on turns it on")
  vim.cmd("ObelusEdits")
  T.ok(not cfgmod.edits_enabled(), "bare command toggles")
  cfgmod.ui.edits = nil
end)

T.it("fast send on a TAGGED thread never falls through to the heavy tag model", function()
  -- with only models.tags configured (fast/send nil), <M-CR> must stay on the
  -- account default (model nil), not silently pick the expensive tag override
  local ctx, F = fresh_ctx({
    transport = { cli = { models = { tags = { auth = "opus-heavy" } } } },
  })
  local a = ctx.store.add(T.comment({ comment = "member" }))
  ctx.store.tag_comment(a.id, "auth")
  require("obelus").chat_send(a.id, "quick question", "fast")
  T.is_nil(F.payload.opts.model, "fast stays on the account default, not the tag model")
  F.finish(true)
  local tm = ctx.store.get_meta("auth")
  require("obelus").chat_send(tm.id, "quick tag question", "fast")
  T.is_nil(F.payload.opts.model, "fast on the tag thread itself: same")
end)

T.it("models.tags scalar typo: guarded to a table with a warning, never a crash", function()
  local ctx, F = fresh_ctx({
    transport = { cli = { models = { batch = "opus", tags = true } } },
  })
  local a = ctx.store.add(T.comment({ comment = "member" }))
  ctx.store.tag_comment(a.id, "auth")
  local ok = pcall(function()
    require("obelus").chat_send(a.id, "does not crash", "send")
  end)
  T.ok(ok, "a scalar where the tags table belongs degrades gracefully")
  T.eq(F.payload.opts.model, "opus", "…falling back to models.batch")
end)

T.it("edits OFF: the cli prompt drops the actions write-back demand (plan mode can't honor it)", function()
  local ctx = T.fresh({
    transport = { dispatch = "cli", cli = { cmd = { "claude", "-p", "--permission-mode", "acceptEdits" } } },
  })
  local cfgmod = require("obelus.config")
  local real_system = vim.system
  vim.system = function()
    return {
      kill = function() end,
      wait = function()
        return { code = 0, stdout = "" }
      end,
      pid = 1,
    }
  end
  local ok, err = pcall(function()
    local c1 = ctx.store.add(T.comment({ comment = "first" }))
    require("obelus").dispatch(c1.id)
    T.contains(require("obelus.log").prompt(), "review-actions", "edits ON: the write-back protocol is demanded")
    ctx.store.abort(c1.id)

    require("obelus").toggle_edits(false)
    local c2 = ctx.store.add(T.comment({ comment = "second" }))
    require("obelus").dispatch(c2.id)
    T.ok(
      not require("obelus.log").prompt():find("review-actions", 1, true),
      "edits OFF: no actions-file demand — the read-only agent replies in text instead"
    )
    ctx.store.abort(c2.id)
  end)
  vim.system = real_system
  cfgmod.ui.edits = nil
  if not ok then
    error(err, 0)
  end
end)

T.it("dispatch_all: a failed spawn is not counted as dispatched (honest notify)", function()
  local ctx = T.fresh({ transport = { dispatch = "fake" } })
  require("obelus.transport").register("fake", function()
    error("boom") -- every spawn fails
  end)
  ctx.store.add(T.comment({ comment = "one" }))
  ctx.store.add(T.comment({ comment = "two" }))
  local notices = {}
  local real_notify = vim.notify
  vim.notify = function(msg, lvl)
    notices[#notices + 1] = { msg = tostring(msg), lvl = lvl }
  end
  require("obelus").dispatch_all()
  vim.notify = real_notify
  for _, n in ipairs(notices) do
    T.ok(not n.msg:find("dispatched %d+ thread"), "no false success claim: " .. n.msg)
  end
end)
