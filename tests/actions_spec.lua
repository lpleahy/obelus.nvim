-- actions: the agent write-back protocol — per-job keyed `.ai/review-actions-<key>.json`
-- files (kills the concurrent-dispatch race a single shared file had), type-validated
-- entries, and the batch round/snapshot commit-on-submit-success invariant.
T.describe("actions")

local function write_json(path, value)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ vim.json.encode(value) }, path)
end

T.it("instructions(comments, key) names the exact keyed actions file", function()
  local S = T.fresh().store
  local actions = require("obelus.actions")
  local c = S.add(T.comment({ comment = "q" }))
  local text = actions.instructions({ c }, "b-1-1")
  T.contains(text, ".ai/review-actions-b-1-1.json")
end)

T.it("apply(key, allowed): applies resolve/reply/needs_response/move, returns the count, consumes the file", function()
  local ctx = T.fresh()
  local S = ctx.store
  local actions = require("obelus.actions")
  local c_resolve = S.add(T.comment({ comment = "fix this" }))
  local c_reply = S.add(T.comment({ comment = "why?" }))
  local c_ask = S.add(T.comment({ comment = "which one?" }))
  local c_move = S.add(T.comment({ comment = "moved", range = { sl = 3, el = 3 } }))
  S.update(c_move.id, { extmark_id = 42 })

  local key = "onejob"
  write_json(actions.path(key), {
    { comment_id = c_resolve.id, action = "resolve" },
    { comment_id = c_reply.id, action = "reply", message = "no change needed" },
    { comment_id = c_ask.id, action = "needs_response", message = "clarify?" },
    { comment_id = c_move.id, action = "move", line = 42 },
  })

  local allowed = { [c_resolve.id] = true, [c_reply.id] = true, [c_ask.id] = true, [c_move.id] = true }
  local n = actions.apply(key, allowed)

  T.eq(n, 4)
  T.eq(S.get(c_resolve.id).status, "resolved")
  T.ok(S.turns(S.get(c_reply.id))[2].text == "no change needed", "reply appended an agent turn")
  T.eq(S.get(c_ask.id).status, "needs_response")
  T.ok(S.turns(S.get(c_ask.id))[2].text == "clarify?", "needs_response appended an agent turn")
  T.eq(S.get(c_move.id).range, { sl = 42, el = 42 })
  T.is_nil(S.get(c_move.id).extmark_id, "move clears the stale extmark so it re-anchors")
  T.eq(vim.fn.filereadable(actions.path(key)), 0, "the keyed file is consumed")
end)

T.it("concurrency: apply(key1) consumes ONLY key1's file; key2's stays untouched and applies separately", function()
  local ctx = T.fresh()
  local S = ctx.store
  local actions = require("obelus.actions")
  local c1 = S.add(T.comment({ comment = "one" }))
  local c2 = S.add(T.comment({ comment = "two" }))
  write_json(actions.path("job1"), { { comment_id = c1.id, action = "resolve" } })
  write_json(actions.path("job2"), { { comment_id = c2.id, action = "resolve" } })

  local n1 = actions.apply("job1", { [c1.id] = true })
  T.eq(n1, 1)
  T.eq(S.get(c1.id).status, "resolved")
  T.eq(S.get(c2.id).status, "open", "job2's target untouched by job1's apply")
  T.eq(vim.fn.filereadable(actions.path("job1")), 0, "job1's file consumed")
  T.eq(vim.fn.filereadable(actions.path("job2")), 1, "job2's file still there")

  local n2 = actions.apply("job2", { [c2.id] = true })
  T.eq(n2, 1)
  T.eq(S.get(c2.id).status, "resolved")
  T.eq(vim.fn.filereadable(actions.path("job2")), 0, "job2's file consumed by its own apply")
end)

T.it("scoping: an entry outside allowed_ids is ignored; reopen works for an allowed id", function()
  local ctx = T.fresh()
  local S = ctx.store
  local actions = require("obelus.actions")
  local c_in = S.add(T.comment({ comment = "in scope" }))
  local c_out = S.add(T.comment({ comment = "out of scope" }))
  S.resolve(c_in.id)

  local key = "scoped"
  write_json(actions.path(key), {
    { comment_id = c_in.id, action = "reopen" },
    { comment_id = c_out.id, action = "resolve" }, -- not in `allowed` -> ignored
  })

  local n = actions.apply(key, { [c_in.id] = true })
  T.eq(n, 1, "only the allowed entry counts")
  T.eq(S.get(c_in.id).status, "open", "reopen applied to the allowed id")
  T.eq(S.get(c_out.id).status, "open", "the out-of-scope entry left the comment's state unchanged")
end)

T.it("move: a bad or missing line is SKIPPED entirely — never clamped, range untouched", function()
  local ctx = T.fresh()
  local S = ctx.store
  local actions = require("obelus.actions")
  local c_bad = S.add(T.comment({ comment = "a", range = { sl = 5, el = 5 } }))
  local c_missing = S.add(T.comment({ comment = "b", range = { sl = 9, el = 9 } }))

  local key = "badmove"
  write_json(actions.path(key), {
    { comment_id = c_bad.id, action = "move", line = "not-a-number" },
    { comment_id = c_missing.id, action = "move" }, -- no line, no range
  })

  local allowed = { [c_bad.id] = true, [c_missing.id] = true }
  local n = actions.apply(key, allowed)

  T.eq(n, 0, "neither invalid move counts toward the applied total")
  T.eq(S.get(c_bad.id).range, { sl = 5, el = 5 }, "non-numeric line: range untouched")
  T.eq(S.get(c_missing.id).range, { sl = 9, el = 9 }, "missing line: range untouched, NOT clamped to 1")
end)

T.it("reply: a non-string message skips the entry (never tostring'd into a turn)", function()
  local ctx = T.fresh()
  local S = ctx.store
  local actions = require("obelus.actions")
  local c = S.add(T.comment({ comment = "q" }))
  local before = #S.turns(S.get(c.id))

  local key = "badmsg"
  write_json(actions.path(key), {
    { comment_id = c.id, action = "reply", message = 12345 },
  })

  local n = actions.apply(key, { [c.id] = true })
  T.eq(n, 0, "the entry doesn't count")
  T.eq(#S.turns(S.get(c.id)), before, "no turn added from a non-string message")
end)

T.it("garbage (non-JSON) file: apply returns 0 and still consumes the file", function()
  local ctx = T.fresh()
  local actions = require("obelus.actions")
  local key = "garbage"
  vim.fn.mkdir(vim.fn.fnamemodify(actions.path(key), ":h"), "p")
  vim.fn.writefile({ "not valid json {{{" }, actions.path(key))

  local n = actions.apply(key, {})
  T.eq(n, 0)
  T.eq(vim.fn.filereadable(actions.path(key)), 0, "the garbage file is consumed regardless")
end)

T.it("legacy fallback: the un-suffixed review-actions.json is consumed when the keyed file is absent", function()
  local ctx = T.fresh()
  local S = ctx.store
  local actions = require("obelus.actions")
  local c = S.add(T.comment({ comment = "q" }))
  local legacy = ctx.root .. "/.ai/review-actions.json"
  write_json(legacy, { { comment_id = c.id, action = "resolve" } })

  local n = actions.apply("some-key-with-no-file", { [c.id] = true })
  T.eq(n, 1)
  T.eq(S.get(c.id).status, "resolved")
  T.eq(vim.fn.filereadable(legacy), 0, "the legacy file is consumed")
end)

-- batch.continue: round/snapshot commit ONLY on transport.submit success -----

T.it("batch.continue: a failing transport.submit leaves batch.round and .snapshot UNCHANGED", function()
  local ctx = T.fresh()
  local S = ctx.store
  local batch = require("obelus.batch")
  local c = S.add(T.comment({ comment = "q" }))
  local b = S.add_batch({
    comment_ids = { c.id },
    round = 1,
    transport = "cli",
    status = "open",
    snapshot = {},
  })
  S.set_comment_batch(c.id, b.id)
  S.update_batch(b.id, { transport = "no-such-transport-registered" })

  local result = batch.continue()
  T.is_nil(result, "continue reports nothing back on a failed submit")
  local reloaded = S.get_batch(b.id)
  T.eq(reloaded.round, 1, "round is NOT bumped after a failed transport.submit")
  T.eq(reloaded.snapshot, {}, "snapshot is NOT overwritten after a failed transport.submit")
end)

T.it("sweep deletes stale keyed AND legacy files (>24h) but keeps fresh ones", function()
  local ctx = T.fresh()
  local A = require("obelus.actions")
  local dir = ctx.root .. "/.ai"
  vim.fn.mkdir(dir, "p")
  local stale_keyed = dir .. "/review-actions-old.json"
  local stale_legacy = dir .. "/review-actions.json"
  local fresh_keyed = dir .. "/review-actions-live.json"
  for _, p in ipairs({ stale_keyed, stale_legacy, fresh_keyed }) do
    vim.fn.writefile({ "[]" }, p)
  end
  -- age the stale pair past the 24h cutoff (touch -t is portable enough for macOS/Linux CI)
  local two_days_ago = os.date("%Y%m%d%H%M", os.time() - 2 * 24 * 60 * 60)
  vim.fn.system({ "touch", "-t", two_days_ago, stale_keyed })
  vim.fn.system({ "touch", "-t", two_days_ago, stale_legacy })

  A.sweep()

  T.eq(vim.fn.filereadable(stale_keyed), 0, "stale keyed file swept")
  T.eq(vim.fn.filereadable(stale_legacy), 0, "stale legacy file swept (bounds the fallback bridge)")
  T.eq(vim.fn.filereadable(fresh_keyed), 1, "a fresh keyed file (possibly a concurrent instance's) survives")
end)
