-- format: labels + the Markdown payload handed to an agent.
T.describe("format")

T.it("range_label renders line and char ranges", function()
  local F = require("obelus.format")
  T.eq(F.range_label({ range = { sl = 5, el = 5 } }), "L5-L5")
  T.eq(F.range_label({ range = { sl = 3, el = 7 } }), "L3-L7")
  T.eq(F.range_label({ range = { sl = 3, sc = 2, el = 3, ec = 9 } }), "L3:2-L3:9")
end)

T.it("relpath strips the project root", function()
  local ctx = T.fresh()
  local F = require("obelus.format")
  T.eq(F.relpath(ctx.root .. "/lua/x.lua"), "lua/x.lua")
  T.eq(F.relpath("/elsewhere/y.lua"), "/elsewhere/y.lua") -- outside root: unchanged
end)

T.it("to_markdown includes path, range, code, and the feedback", function()
  local ctx = T.fresh()
  local c = ctx.store.add(T.comment({
    file = ctx.root .. "/a.lua",
    range = { sl = 10, el = 12 },
    selected_text = { "for i = 1, n do", "  work()", "end" },
    comment = "guard against nil n",
  }))
  local md = require("obelus.format").to_markdown({ c })
  T.contains(md, "a.lua")
  T.contains(md, "L10-L12")
  T.contains(md, "work()")
  T.contains(md, "guard against nil n")
  T.contains(md, "```lua") -- language fence from the file extension
end)

T.it("to_markdown honours a custom title", function()
  local ctx = T.fresh()
  local c = ctx.store.add(T.comment())
  local md = require("obelus.format").to_markdown({ c }, { title = "# Round 2" })
  T.contains(md, "# Round 2")
end)

T.it("comment_md: the file lands as a real @mention (the send policy governs threads too)", function()
  local ctx = T.fresh()
  vim.fn.writefile({ "x" }, ctx.root .. "/f.lua")
  local c = T.comment({ file = ctx.root .. "/f.lua", comment = "fix this" })
  local md = require("obelus.format").comment_md(c, 1)
  T.contains(md, "1. @f.lua", "the heading references the file as @path")
end)

-- meta_context: the project thread's briefing ----------------------------------

T.it("meta_context: a pending thread appears FULL — comment AND an agent turn's text", function()
  local ctx = T.fresh()
  local F = require("obelus.format")
  local c = ctx.store.add(T.comment({ comment = "why is this here?" }))
  ctx.store.add_turn(c.id, "agent", "because of the legacy migration")
  local md = F.meta_context()
  T.contains(md, "why is this here?", "the original comment is present")
  T.contains(md, "because of the legacy migration", "an agent turn's text is present")
end)

T.it("meta_context: a resolved thread collapses to ONE @thread:<id> summary line", function()
  local ctx = T.fresh()
  local F = require("obelus.format")
  local c = ctx.store.add(T.comment({ comment = "fix the off-by-one\nsecond line ignored" }))
  ctx.store.add_turn(c.id, "agent", "done, fixed")
  ctx.store.resolve(c.id)
  local md = F.meta_context()
  T.contains(md, "Resolved (summaries", "the resolved section heading is present")
  T.contains(md, "@thread:" .. c.id, "the summary line references the thread by id")
  T.contains(md, "fix the off-by-one", "the first line of the comment is the summary")
  T.ok(not md:find("second line ignored", 1, true), "only the FIRST line summarizes — not the whole comment")
  T.ok(not md:find("done, fixed", 1, true), "a resolved thread's turns are NOT included in full")
end)

T.it("meta_context: the meta record itself is never included, pending or resolved", function()
  local ctx = T.fresh()
  local F = require("obelus.format")
  local meta = ctx.store.meta_thread()
  local md = F.meta_context()
  T.ok(not md:find(meta.id, 1, true), "the meta thread's own id never appears in its own briefing")
  T.contains(md, "no open threads", "with nothing else, the briefing says so")
end)

-- meta_context({ tag = ... }): the tag-scoped (tag meta thread) briefing ---------

T.it("meta_context({tag=...}): only that tag's threads appear — a different tag's is absent", function()
  local ctx = T.fresh()
  local F = require("obelus.format")
  local a = ctx.store.add(T.comment({ comment = "fix the auth check" }))
  ctx.store.tag_comment(a.id, "auth")
  local p = ctx.store.add(T.comment({ comment = "speed up the query" }))
  ctx.store.tag_comment(p.id, "perf")

  local md = F.meta_context({ tag = "auth" })
  T.contains(md, "fix the auth check", "the #auth thread is present")
  T.ok(not md:find("speed up the query", 1, true), "the #perf thread is absent from the #auth briefing")
  T.contains(md, "#auth thread", "the title names the scoped tag")
end)

T.it("meta_context({tag=...}): an untagged thread is absent too (tag scope, not just 'not this other tag')", function()
  local ctx = T.fresh()
  local F = require("obelus.format")
  local a = ctx.store.add(T.comment({ comment = "tagged one" }))
  ctx.store.tag_comment(a.id, "auth")
  ctx.store.add(T.comment({ comment = "never tagged at all" }))

  local md = F.meta_context({ tag = "auth" })
  T.contains(md, "tagged one")
  T.ok(not md:find("never tagged at all", 1, true), "an untagged thread doesn't leak into a tag-scoped briefing")
end)

T.it("meta_context({tag=..., include_drafts=false}): a trailing unsent draft reply is skipped + noted", function()
  local ctx = T.fresh()
  local F = require("obelus.format")
  local c = ctx.store.add(T.comment({ comment = "why is this here?" }))
  ctx.store.tag_comment(c.id, "auth")
  ctx.store.add_turn(c.id, "agent", "because of the legacy migration")
  ctx.store.set_pending_you(c.id, "an unsent follow-up draft")

  local md = F.meta_context({ tag = "auth", include_drafts = false })
  T.contains(md, "because of the legacy migration", "the sent agent turn is still shown in full")
  T.ok(not md:find("an unsent follow-up draft", 1, true), "the draft's TEXT never appears")
  T.contains(md, "(has an unsent draft, not shown)", "a one-line note marks the skipped draft")
end)

T.it("meta_context (include_drafts=true, default): the draft is shown, LABELED as an unsent draft", function()
  local ctx = T.fresh()
  local F = require("obelus.format")
  local c = ctx.store.add(T.comment({ comment = "why is this here?" }))
  ctx.store.add_turn(c.id, "agent", "because of the legacy migration")
  ctx.store.set_pending_you(c.id, "an unsent follow-up draft")

  local md = F.meta_context() -- the GLOBAL thread's briefing: today's behavior + the new label
  T.contains(md, "an unsent follow-up draft", "the draft's text is still included (unchanged behavior)")
  T.contains(md, "You (draft, unsent):", "but now explicitly labeled as an unsent draft")
end)

T.it("thread_full: a brand-new (never-sent) comment is never treated as a draft to skip/label", function()
  local ctx = T.fresh()
  local F = require("obelus.format")
  local c = ctx.store.add(T.comment({ comment = "first thought" }))
  local out = F.thread_full(c, { include_drafts = false })
  T.contains(out, "first thought", "the initial comment shows via comment_md regardless of include_drafts")
  T.ok(not out:find("not shown", 1, true), "no 'skipped draft' note for the very first turn")
end)

-- tag_deltas: unified tag session JOINED/LEFT prompt block ----------------------

T.it("tag_deltas: a join renders the member's FULL identity under a JOINED heading", function()
  local ctx = T.fresh()
  local F = require("obelus.format")
  local c = ctx.store.add(T.comment({ comment = "fix the auth check" }))
  ctx.store.tag_comment(c.id, "auth")
  local out = F.tag_deltas("auth", { joins = { c }, leaves = {} })
  T.contains(out, "JOINED the #auth conversation:")
  T.contains(out, "fix the auth check", "the join carries the member's full comment_md")
end)

T.it("tag_deltas: a join's include_drafts=false skips a trailing unsent draft, same as thread_full", function()
  local ctx = T.fresh()
  local F = require("obelus.format")
  local c = ctx.store.add(T.comment({ comment = "fix the auth check" }))
  ctx.store.tag_comment(c.id, "auth")
  ctx.store.add_turn(c.id, "agent", "looked into it")
  ctx.store.set_pending_you(c.id, "SECRET unsent draft")

  local excluded = F.tag_deltas("auth", { joins = { c }, leaves = {} }, { include_drafts = false })
  T.ok(not excluded:find("SECRET unsent draft", 1, true), "respond-mode joins never leak a draft")
  T.contains(excluded, "not shown")

  local included = F.tag_deltas("auth", { joins = { c }, leaves = {} }, { include_drafts = true })
  T.contains(included, "SECRET unsent draft", "submit-all's joins DO include a draft")
end)

T.it("tag_deltas: a leave for a still-existing (untagged) member names its file/range", function()
  local ctx = T.fresh()
  local F = require("obelus.format")
  local c = ctx.store.add(T.comment({ file = ctx.root .. "/f.lua", range = { sl = 3, el = 3 } }))
  local out = F.tag_deltas("auth", { joins = {}, leaves = { { id = c.id, c = c } } })
  T.contains(out, "LEFT the conversation (do not act on it): f.lua L3-L3")
end)

T.it("tag_deltas: a leave for a DELETED member (c = nil) falls back to its bare id", function()
  local F = require("obelus.format")
  local out = F.tag_deltas("auth", { joins = {}, leaves = { { id = "1234-1", c = nil } } })
  T.contains(out, "LEFT the conversation (do not act on it): 1234-1 (deleted)")
end)

T.it("tag_deltas: nothing to report renders as an empty string (nothing prepended to the prompt)", function()
  local F = require("obelus.format")
  T.eq(F.tag_deltas("auth", { joins = {}, leaves = {} }), "")
end)
