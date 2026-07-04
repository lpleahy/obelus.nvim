-- store: comment CRUD, conversation turns, editable drafts, batches, tags.
T.describe("store")

T.it("add assigns id/status; get retrieves; all counts", function()
  local S = T.fresh().store
  local c = S.add(T.comment({ comment = "hi" }))
  T.ok(c.id, "id assigned")
  T.eq(c.status, "open")
  T.eq(S.get(c.id).comment, "hi")
  T.eq(#S.all(), 1)
end)

T.it("update + remove", function()
  local S = T.fresh().store
  local c = S.add(T.comment())
  S.update(c.id, { status = "resolved" })
  T.eq(S.get(c.id).status, "resolved")
  S.remove(c.id)
  T.is_nil(S.get(c.id))
  T.eq(#S.all(), 0)
end)

T.it("turns synthesize from the comment field", function()
  local S = T.fresh().store
  local c = S.add(T.comment({ comment = "first" }))
  local t = S.turns(c)
  T.eq(#t, 1)
  T.eq(t[1].author, "you")
  T.eq(t[1].text, "first")
end)

T.it("add_turn appends and tracks last_result", function()
  local S = T.fresh().store
  local c = S.add(T.comment({ comment = "q" }))
  S.add_turn(c.id, "agent", "answer")
  local t = S.turns(S.get(c.id))
  T.eq(#t, 2)
  T.eq(t[2].author, "agent")
  T.eq(S.get(c.id).last_result, "answer")
end)

T.it("pending = unresolved threads whose last turn is yours", function()
  local S = T.fresh().store
  local c = S.add(T.comment({ comment = "q" })) -- last turn = you -> pending
  T.eq(#S.pending(), 1)
  S.add_turn(c.id, "agent", "a") -- last turn = agent -> not pending
  T.eq(#S.pending(), 0)
  S.add_turn(c.id, "you", "follow up") -- last turn = you -> pending again
  T.eq(#S.pending(), 1)
  S.resolve(c.id) -- resolved -> not pending
  T.eq(#S.pending(), 0)
end)

T.it("resolve / reopen toggle status", function()
  local S = T.fresh().store
  local c = S.add(T.comment())
  S.resolve(c.id)
  T.eq(S.get(c.id).status, "resolved")
  S.reopen(c.id)
  T.eq(S.get(c.id).status, "open")
end)

T.it("set_pending_you creates, updates in place, and clears a reply draft", function()
  local S = T.fresh().store
  local c = S.add(T.comment({ comment = "q" }))
  S.add_turn(c.id, "agent", "a") -- last turn agent
  S.set_pending_you(c.id, "draft reply") -- adds a you turn
  T.eq(S.pending_you_text(S.get(c.id)), "draft reply")
  S.set_pending_you(c.id, "edited") -- updates in place (no dup)
  T.eq(S.pending_you_text(S.get(c.id)), "edited")
  T.eq(#S.turns(S.get(c.id)), 3) -- q / a / edited (no duplicate)
  S.set_pending_you(c.id, "") -- clearing a reply draft removes it
  T.is_nil(S.pending_you_text(S.get(c.id)))
  T.eq(#S.turns(S.get(c.id)), 2)
end)

T.it("set_pending_you on the comment turn keeps it and syncs c.comment", function()
  local S = T.fresh().store
  local c = S.add(T.comment({ comment = "orig" })) -- single you turn = the comment
  S.set_pending_you(c.id, "edited comment")
  T.eq(S.get(c.id).comment, "edited comment")
  T.eq(S.pending_you_text(S.get(c.id)), "edited comment")
  S.set_pending_you(c.id, "") -- n == 1: kept, not removed
  T.eq(#S.turns(S.get(c.id)), 1)
end)

T.it("clear_dispatching clears the busy flag without popping turns", function()
  local S = T.fresh().store
  local c = S.add(T.comment({ comment = "q" }))
  S.stream_start(c.id) -- sets dispatching = true, appends the trailing agent turn
  T.eq(S.get(c.id).dispatching, true)
  S.clear_dispatching(c.id)
  T.is_nil(S.get(c.id).dispatching)
  T.eq(#S.turns(S.get(c.id)), 2) -- unlike abort, the (now-filled) turn stays
end)

T.it("save() strips the runtime dispatching flag from disk", function()
  local S = T.fresh().store
  local c = S.add(T.comment({ comment = "q" }))
  S.update(c.id, { dispatching = true })
  S.save()
  local lines = vim.fn.readfile(S.store_path())
  T.eq(#lines, 1)
  T.ok(not lines[1]:find("dispatching", 1, true), "dispatching leaked into the saved jsonl")
end)

T.it("save() strips the runtime _stream_turn handle from disk (else it duplicates the turn)", function()
  local S = T.fresh().store
  local c = S.add(T.comment({ comment = "q" }))
  S.stream_start(c.id) -- sets c._stream_turn to a table reference INTO c.turns
  S.save()
  local lines = vim.fn.readfile(S.store_path())
  T.eq(#lines, 1)
  T.ok(not lines[1]:find("_stream_turn", 1, true), "_stream_turn leaked into the saved jsonl")
end)

T.it("draft-save mid-stream targets the streamed turn BY HANDLE, not the tail (no corruption)", function()
  local S = T.fresh().store
  local c = S.add(T.comment({ comment = "q" })) -- turns: [you:"q"]
  S.stream_start(c.id) -- turns: [you:"q", agent:""] — c._stream_turn == turns[2]
  S.set_pending_you(c.id, "my draft") -- turns: [you:"q", agent:"", you:"my draft"]
  S.stream_update(c.id, "agent text") -- must land on the handle's turn, NOT the new tail

  local turns = S.turns(S.get(c.id))
  T.eq(#turns, 3)
  T.eq(turns[2].author, "agent")
  T.eq(turns[2].text, "agent text", "the delta landed on the streamed (2nd-to-last) turn")
  T.eq(turns[3].author, "you")
  T.eq(turns[3].text, "my draft", "the draft tail is untouched by the streamed delta")

  S.stream_finish(c.id, "final agent text", "sess-1", true)
  local turns2 = S.turns(S.get(c.id))
  T.eq(#turns2, 3, "stream_finish also targets the handle — the draft isn't eaten")
  T.eq(turns2[2].author, "agent")
  T.eq(turns2[2].text, "final agent text")
  T.eq(turns2[3].author, "you")
  T.eq(turns2[3].text, "my draft", "the draft survives the finish too")
  T.is_nil(S.get(c.id).dispatching)
end)

T.it("save_soon debounces a burst of mutations into one trailing-edge write", function()
  local ctx = T.fresh({ persist = { auto = true } })
  local S = ctx.store
  S._timing.save_debounce = 20

  local c = S.add(T.comment({ comment = "q" })) -- queues a debounced save
  S.update(c.id, { status = "resolved" }) -- a second mutation restarts the debounce window

  -- Nothing has yielded to the event loop yet, so the debounced timer can't have
  -- fired — this is the whole point of debouncing instead of writing synchronously.
  T.eq(vim.fn.filereadable(S.store_path()), 0, "no synchronous write from save_soon")

  T.ok(
    T.wait_for(function()
      return vim.fn.filereadable(S.store_path()) == 1
    end, 500),
    "the debounced save eventually flushed"
  )
  local lines = vim.fn.readfile(S.store_path())
  T.eq(#lines, 1, "both mutations coalesced into ONE write")
  T.ok(lines[1]:find('"resolved"', 1, true) ~= nil, "the trailing-edge write captured the LATEST mutation")

  S._timing.save_debounce = 150 -- restore the module default for any later spec
end)

T.it("a project switch flushes the pending debounced save to the OLD root first", function()
  local ctx = T.fresh({ persist = { auto = true } })
  local S = ctx.store
  S._timing.save_debounce = 10000 -- effectively never fires on its own in this spec
  local old_path = S.store_path()

  S.add(T.comment({ comment = "belongs to project A" })) -- queues a debounced save for root A
  T.eq(vim.fn.filereadable(old_path), 0, "nothing written yet (still debouncing)")

  -- move the project root (what DirChanged does) — maybe_reload must flush the
  -- pending write to the OLD path BEFORE store_path() repoints at the new root
  local new_root = vim.fn.tempname()
  vim.fn.mkdir(new_root, "p")
  require("obelus.config").options.root = function()
    return new_root
  end
  T.eq(S.maybe_reload(), true, "root changed -> reloaded")

  T.eq(vim.fn.filereadable(old_path), 1, "project A's pending mutation landed in A's file")
  T.ok(table.concat(vim.fn.readfile(old_path), "\n"):find("belongs to project A", 1, true) ~= nil)
  T.eq(#S.all(), 0, "the new (empty) project's store loaded")
  S._timing.save_debounce = 150
end)

T.it("batches: open_batch returns the most-recent open; members resolve ids", function()
  local S = T.fresh().store
  local c1 = S.add(T.comment())
  local c2 = S.add(T.comment())
  local b1 = S.add_batch({ status = "open", comment_ids = { c1.id } })
  local b2 = S.add_batch({ status = "open", comment_ids = { c1.id, c2.id } })
  T.eq(S.open_batch().id, b2.id) -- newest open wins
  T.eq(#S.batch_members(b2), 2)
  S.update_batch(b2.id, { status = "done" })
  T.eq(S.open_batch().id, b1.id) -- falls back to the earlier open one
  S.update_batch(b1.id, { status = "done" })
  T.is_nil(S.open_batch())
end)

T.it("set_comment_batch owns membership via batch.comment_ids only — no c.batch_id back-ref", function()
  local S = T.fresh().store
  local c = S.add(T.comment())
  local b = S.add_batch({ status = "open", comment_ids = { c.id } })
  S.set_comment_batch(c.id, b.id)
  T.is_nil(S.get(c.id).batch_id, "set_comment_batch must not write a back-ref onto the comment")
end)

T.it("load() strips a legacy batch_id field from an old jsonl line (migration)", function()
  local ctx = T.fresh()
  local S = ctx.store
  local path = S.store_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({
    vim.json.encode({
      id = "1-1",
      file = "/tmp/obelus-test/x.lua",
      range = { sl = 1, el = 1 },
      kind = "line",
      comment = "legacy",
      status = "open",
      batch_id = "b-old-1", -- pre-refactor back-ref; load() must strip it
    }),
  }, path)
  S.load()
  T.is_nil(S.get("1-1").batch_id, "load() migrates away a stale batch_id field")
end)

-- the project (meta) thread ---------------------------------------------------

T.it("meta_thread: get-or-create is idempotent — one record, same id every call", function()
  local S = T.fresh().store
  local a = S.meta_thread()
  T.ok(a.meta, "meta = true")
  T.eq(a.file, S.root(), "file is the project root")
  local b = S.meta_thread()
  T.eq(b.id, a.id, "a second call returns the SAME record")
  local metas = vim.tbl_filter(function(c)
    return c.meta
  end, S.all())
  T.eq(#metas, 1, "exactly one meta record exists, even after two get-or-create calls")
end)

T.it("meta_thread: excluded from pending, even when its 'status' would otherwise qualify", function()
  local S = T.fresh().store
  local meta = S.meta_thread()
  T.eq(meta.status, "open", "a freshly created meta record looks pending by status alone")
  local pending_ids = {}
  for _, c in ipairs(S.pending()) do
    pending_ids[c.id] = true
  end
  T.is_nil(pending_ids[meta.id], "the meta record never shows up in store.pending()")
end)

T.it("meta_thread: persists to disk and reloads with meta = true, same id", function()
  local ctx = T.fresh({ persist = { auto = true } })
  local S = ctx.store
  local meta = S.meta_thread()
  S.save()
  S.load()
  local reloaded = S.get(meta.id)
  T.ok(reloaded, "the meta record survives a reload under its original id")
  T.eq(reloaded.meta, true)
  -- and get-or-create after a reload still finds it — no duplicate created
  local again = S.meta_thread()
  T.eq(again.id, meta.id)
  local metas = vim.tbl_filter(function(c)
    return c.meta
  end, S.all())
  T.eq(#metas, 1)
end)

T.it("tags: tag_comment, tags(), pending_by_tag, sticky active_tag", function()
  local S = T.fresh().store
  local c = S.add(T.comment({ comment = "q" }))
  S.tag_comment(c.id, "auth")
  T.eq(S.get(c.id).tag, "auth")
  T.eq(S.tags(), { "auth" })
  T.eq(#S.pending_by_tag("auth"), 1)
  T.eq(#S.pending_by_tag("other"), 0)
  S.tag_comment(c.id, "") -- clearing unsets the tag
  T.is_nil(S.get(c.id).tag)
  -- sticky tagging mode: new comments inherit the active tag
  S.set_active_tag("grp")
  local c2 = S.add(T.comment({ comment = "q2" }))
  T.eq(c2.tag, "grp")
  S.set_active_tag(nil)
end)

T.it("get_meta never creates; the sidebar pin only shows an EXISTING project thread", function()
  local ctx = T.fresh()
  T.is_nil(ctx.store.get_meta(), "no meta record until deliberately created")
  local panel = require("obelus.panel")
  panel.open(false)
  T.ok(
    T.wait_for(function()
      return panel.geom() ~= nil
    end),
    "list opened"
  )
  T.is_nil(ctx.store.get_meta(), "opening the sidebar did not plant a meta record")
  panel.close()
  local meta = ctx.store.meta_thread()
  T.ok(meta and meta.meta, "explicit creation works")
end)

T.it("load() heals duplicate meta records — keeps the one with the most conversation", function()
  local ctx = T.fresh({ persist = { auto = true } })
  local keep = ctx.store.meta_thread()
  ctx.store.add_turn(keep.id, "you", "the real conversation")
  ctx.store.save()
  -- plant a rival meta record straight into the jsonl, as a concurrent instance would
  local path = ctx.store.store_path()
  local lines = vim.fn.readfile(path)
  lines[#lines + 1] = vim.json.encode({
    meta = true,
    id = "9999999999-1",
    file = ctx.store.root(),
    range = { sl = 1, el = 1 },
    kind = "line",
    selected_text = {},
    comment = "project thread",
    status = "open",
  })
  vim.fn.writefile(lines, path)
  ctx.store.load()
  local metas = 0
  for _, c in ipairs(ctx.store.all()) do
    if c.meta then
      metas = metas + 1
    end
  end
  T.eq(metas, 1, "exactly one meta record after load")
  T.eq(ctx.store.get_meta().id, keep.id, "the one with the conversation won")
end)
