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

T.it("typo'd engage resets to the default", function()
  local config = require("obelus.config")
  config.setup({ engage = "side" })
  T.eq(config.options.engage, "inline")
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

T.it("render.hints = false normalizes to { chat = false, compose = false }", function()
  local config = require("obelus.config")
  config.setup({ render = { hints = false } })
  T.eq(config.options.render.hints, { chat = false, compose = false })
end)

-- MIGRATION: render.thread (deprecated) merges into render.bands; the user's
-- thread values WIN over bands' own defaults.

T.it("render.thread shim: values land in render.bands", function()
  local config = require("obelus.config")
  config.setup({ render = { thread = { markdown = false, max_height = 12 } } })
  T.is_nil(config.options.render.thread)
  T.eq(config.options.render.bands.markdown, false)
  T.eq(config.options.render.bands.max_height, 12)
  -- untouched bands keys keep their own defaults
  T.eq(config.options.render.bands.style, "popup")
end)

T.it("scalar garbage where tables belong never crashes setup (render = true, transport = 0)", function()
  local ctx = T.fresh({ render = true, transport = 0 })
  local o = ctx.config.options
  T.eq(type(o.render), "table", "render restored to the default table")
  T.eq(type(o.transport), "table", "transport restored to the default table")
  T.eq(o.render.bands.enabled, true)
end)

T.it("render.thread shim: an EXPLICIT render.bands key beats a leftover thread key", function()
  local ctx = T.fresh({ render = { bands = { markdown = false }, thread = { markdown = true, max_height = 5 } } })
  local b = ctx.config.options.render.bands
  T.eq(b.markdown, false, "the current-API bands.markdown wins over the deprecated thread.markdown")
  T.eq(b.max_height, 5, "thread keys the user did NOT set in bands still migrate")
end)
