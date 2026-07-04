-- config: defaults, deep-merge, and the string-root convenience.
T.describe("config")

T.it("defaults expose render/transport/persist/bands", function()
  local config = require("obelus.config")
  config.setup({})
  T.ok(config.options.render, "render")
  T.ok(config.options.transport, "transport")
  T.ok(config.options.persist, "persist")
  T.ok(config.options.render.bands, "render.bands")
end)

T.it("setup deep-merges: override one key, keep siblings", function()
  local config = require("obelus.config")
  config.setup({ render = { bar = "X" } })
  T.eq(config.options.render.bar, "X")
  T.ok(config.options.render.colors, "sibling render.colors preserved")
  T.ok(config.options.transport.cli, "sibling transport.cli preserved")
end)

T.it("string root is wrapped into a function", function()
  local config = require("obelus.config")
  config.setup({ root = "/tmp/obelus-root" })
  T.eq(type(config.options.root), "function")
  T.eq(config.options.root(), "/tmp/obelus-root")
end)

T.it("renderer defaults to nil (auto)", function()
  local config = require("obelus.config")
  config.setup({})
  T.is_nil(config.options.render.renderer)
end)

-- Enum validation: a bad value warns once and RESETS the field to the default
-- (rather than leaving the typo live, or erroring setup outright).

T.it("typo'd render.renderer resets to the default (nil/auto)", function()
  local config = require("obelus.config")
  config.setup({ render = { renderer = "markvew" } })
  T.is_nil(config.options.render.renderer)
end)

T.it("typo'd mode resets to the default", function()
  local config = require("obelus.config")
  config.setup({ mode = "side" })
  T.eq(config.options.mode, "inline")
end)

T.it("typo'd transport.batch.mode resets to the default", function()
  local config = require("obelus.config")
  config.setup({ transport = { batch = { mode = "sesion" } } })
  T.eq(config.options.transport.batch.mode, "session")
end)

-- FALSE-TABLE normalization: `render.bands = false` used to be silently re-enabled
-- by every `(cfg.bands or {}).enabled ~= false` call site (tbl_deep_extend REPLACES
-- the subtable with the bare boolean). Setup now normalizes it to the real all-off
-- shape before anything reads it.

T.it("render.bands = false normalizes to { enabled = false, ... } and bands.bands_on() agrees", function()
  local config = require("obelus.config")
  config.setup({ render = { bands = false } })
  T.eq(config.options.render.bands.enabled, false)
  -- the other bands keys keep their defaults (inert while disabled)
  T.eq(config.options.render.bands.style, "popup")
  local render = require("obelus.render")
  T.eq(render.bands_on(), false)
end)

T.it("render.hints = false stays the boolean false", function()
  local config = require("obelus.config")
  config.setup({ render = { hints = false } })
  T.eq(config.options.render.hints, false)
end)

T.it("render.hints = true stays the boolean true", function()
  local config = require("obelus.config")
  config.setup({ render = { hints = true } })
  T.eq(config.options.render.hints, true)
end)

-- MIGRATION: render.hints used to be a { chat, compose } table; a user-passed table
-- coerces to a single boolean (true if ANY sub-value was true) with a one-time warning.

T.it("render.hints = { chat = true, compose = false } (old shape) coerces to true", function()
  local config = require("obelus.config")
  config.setup({ render = { hints = { chat = true, compose = false } } })
  T.eq(config.options.render.hints, true)
end)

T.it("render.hints = { chat = false, compose = false } (old shape) coerces to false", function()
  local config = require("obelus.config")
  config.setup({ render = { hints = { chat = false, compose = false } } })
  T.eq(config.options.render.hints, false)
end)

T.it("scalar garbage where tables belong never crashes setup (render = true, transport = 0)", function()
  local ctx = T.fresh({ render = true, transport = 0 })
  local o = ctx.config.options
  T.eq(type(o.render), "table", "render restored to the default table")
  T.eq(type(o.transport), "table", "transport restored to the default table")
  T.eq(o.render.bands.enabled, true)
end)

-- CLEAN BREAK: removed keys are ignored (new defaults land instead) and warned about
-- once — no migration, unlike the false-table/hints shims above.

T.it("removed keys are ignored: engage, render.signs, transport.cli.model", function()
  local config = require("obelus.config")
  config.setup({
    engage = "sidebar",
    render = { signs = false },
    transport = { cli = { model = "gpt-x" } },
  })
  T.eq(config.options.mode, "inline", "engage is ignored; mode keeps its default")
  T.eq(config.options.render.annotations.signs, true, "render.signs is ignored; annotations.signs keeps its default")
  T.is_nil(config.options.transport.cli.models.send, "transport.cli.model is ignored")
end)

T.it("removed keys are ignored: render.thread, render.markview, cli.fast_model/batch_model", function()
  local config = require("obelus.config")
  config.setup({
    render = { thread = { markdown = false, max_height = 12 }, markview = false },
    transport = { cli = { fast_model = "a", batch_model = "b" } },
  })
  T.is_nil(config.options.render.thread, "render.thread is dropped, not migrated")
  T.eq(config.options.render.bands.markdown, true, "render.bands is untouched by the ignored render.thread")
  T.eq(config.options.render.bands.max_height, 0.6, "render.bands.max_height keeps its default")
  T.is_nil(config.options.render.markview, "render.markview is dropped")
  T.is_nil(config.options.transport.cli.models.fast, "transport.cli.fast_model is ignored")
  T.is_nil(config.options.transport.cli.models.batch, "transport.cli.batch_model is ignored")
end)

T.it("render.annotations carries the new defaults (signs/sign/preview/etc.)", function()
  local config = require("obelus.config")
  config.setup({})
  local a = config.options.render.annotations
  T.eq(a.signs, true)
  T.eq(a.sign, "▌")
  T.eq(a.sign_hl, "DiagnosticInfo")
  T.eq(a.preview, true)
  T.eq(a.preview_hl, "Comment")
  T.eq(a.preview_prefix, "  ▌ ")
  T.eq(a.resolved_sign, "✓")
  T.eq(a.show_resolved, false)
end)

T.it("transport.cli.models subtable merges: one key overridden, siblings default to nil", function()
  local config = require("obelus.config")
  config.setup({ transport = { cli = { models = { fast = "haiku" } } } })
  local models = config.options.transport.cli.models
  T.eq(models.fast, "haiku")
  T.is_nil(models.send)
  T.is_nil(models.batch)
end)

-- input.mention: false | true | { picker?, completion? } — true/table sugar
-- normalizes into the expanded table; false is left alone (mention.attach()
-- short-circuits on the bare boolean, so it never becomes a table).

T.it("input.mention = true normalizes to the default table (picker + auto completion)", function()
  local config = require("obelus.config")
  config.setup({})
  T.eq(config.options.input.mention, { picker = true, completion = "auto" })
end)

T.it("input.mention = false stays the bare boolean (disabled entirely)", function()
  local config = require("obelus.config")
  config.setup({ input = { mention = false } })
  T.eq(config.options.input.mention, false)
end)

T.it('input.mention = { completion = "cmp" } merges over the defaults: picker stays true', function()
  local config = require("obelus.config")
  config.setup({ input = { mention = { completion = "cmp" } } })
  T.eq(config.options.input.mention, { picker = true, completion = "cmp" })
end)

T.it('input.mention.completion typo resets to "auto"; .picker typo resets to true', function()
  local config = require("obelus.config")
  config.setup({ input = { mention = { completion = "codeium", picker = "yes" } } })
  T.eq(config.options.input.mention.completion, "auto")
  T.eq(config.options.input.mention.picker, true)
end)

T.it("input.mention = 3 (garbage) resets to the default table", function()
  local config = require("obelus.config")
  config.setup({ input = { mention = 3 } })
  T.eq(config.options.input.mention, { picker = true, completion = "auto" })
end)
