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
