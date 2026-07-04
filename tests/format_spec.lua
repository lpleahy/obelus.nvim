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
