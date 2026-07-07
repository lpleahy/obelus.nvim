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
  T.eq(config.options.input.mention, { picker = true, completion = "auto", send = "reference" })
end)

T.it("input.mention = false stays the bare boolean (disabled entirely)", function()
  local config = require("obelus.config")
  config.setup({ input = { mention = false } })
  T.eq(config.options.input.mention, false)
end)

T.it('input.mention = { completion = "cmp" } merges over the defaults: picker stays true', function()
  local config = require("obelus.config")
  config.setup({ input = { mention = { completion = "cmp" } } })
  T.eq(config.options.input.mention, { picker = true, completion = "cmp", send = "reference" })
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
  T.eq(config.options.input.mention, { picker = true, completion = "auto", send = "reference" })
end)

-- ---------------------------------------------------------------------------
-- keys.overrides / keys.chat (section C: full key overridability) — sparse maps
-- of name -> lhs string, or `false` to disable. Bad VALUES drop just that one
-- entry (warn once), unlike enum()/boolean() which reset the whole field; the
-- surrounding table itself follows the usual ensure_table scalar-garbage idiom.
-- ---------------------------------------------------------------------------

T.it("keys.overrides/keys.chat default to empty tables", function()
  local config = require("obelus.config")
  config.setup({})
  T.eq(config.options.keys.overrides, {})
  T.eq(config.options.keys.chat, {})
end)

T.it("keys.overrides/keys.chat accept string|false values", function()
  local config = require("obelus.config")
  config.setup({
    keys = { overrides = { s = "<leader>Zs", J = false }, chat = { wrap = false, send = "<C-CR>" } },
  })
  T.eq(config.options.keys.overrides.s, "<leader>Zs")
  T.eq(config.options.keys.overrides.J, false)
  T.eq(config.options.keys.chat.wrap, false)
  T.eq(config.options.keys.chat.send, "<C-CR>")
end)

T.it("keys.overrides/keys.chat: a garbage value warns once and drops only that entry", function()
  local config = require("obelus.config")
  config.setup({
    keys = { overrides = { s = 5 }, chat = { send = 5, save = "<C-x>" } },
  })
  T.is_nil(config.options.keys.overrides.s, "garbage override value dropped")
  T.is_nil(config.options.keys.chat.send, "garbage chat key value dropped")
  T.eq(config.options.keys.chat.save, "<C-x>", "sibling entry unaffected by the neighbor's garbage")
end)

-- keys.list (section D: the review list/chat panel's own bindings) follows the
-- exact same string|false idiom as keys.chat — same ensure_table/validate_key_map
-- calls, just a different sparse map.

T.it("keys.list defaults to an empty table; accepts string|false values", function()
  local config = require("obelus.config")
  config.setup({})
  T.eq(config.options.keys.list, {})
  config.setup({ keys = { list = { delete = "X", resolve = false } } })
  T.eq(config.options.keys.list.delete, "X")
  T.eq(config.options.keys.list.resolve, false)
end)

T.it("keys.list: a garbage value warns once and drops only that entry", function()
  local config = require("obelus.config")
  config.setup({ keys = { list = { delete = 5, reopen = "Y" } } })
  T.is_nil(config.options.keys.list.delete, "garbage list key value dropped")
  T.eq(config.options.keys.list.reopen, "Y", "sibling entry unaffected by the neighbor's garbage")
end)

T.it("keys = false stays the bare boolean (overrides/chat validation skipped, not crashed)", function()
  local config = require("obelus.config")
  config.setup({ keys = false })
  T.eq(config.options.keys, false)
end)

T.it("keys = 5 (garbage) resets to the default table, with overrides/chat defaults intact", function()
  local ctx = T.fresh({ keys = 5 })
  T.eq(type(ctx.config.options.keys), "table")
  T.eq(ctx.config.options.keys.overrides, {})
  T.eq(ctx.config.options.keys.chat, {})
end)

-- ---------------------------------------------------------------------------
-- keys.overrides (init.lua's keymaps()/whichkey()) — the ACTUAL mapping behavior.
-- keymaps()/whichkey() only run once for real per process (the `did_setup` latch
-- in init.lua), so a later config.setup() with different overrides wouldn't be
-- observable through the real session mappings. init._keymaps/_whichkey are test
-- seams that re-run the same registration logic directly against a throwaway `k`
-- table — each spec picks a prefix/lhs family it owns exclusively so it can't
-- collide with the real session's mappings (this only ADDS mappings; it never
-- unmaps a stale lhs from a previous call).
-- ---------------------------------------------------------------------------

T.it("keys.overrides: a full-lhs override maps there instead of prefix..suffix", function()
  local init = require("obelus.init")
  local prefix = "<leader>ZZQ"
  init._keymaps({ prefix = prefix, disabled = {}, overrides = { s = "<leader>ZZs" } })
  T.ok(vim.fn.maparg("<leader>ZZs", "n") ~= "", "the override lhs is mapped")
  T.eq(vim.fn.maparg(prefix .. "s", "n"), "", "the default prefix..suffix is NOT mapped for an overridden suffix")
  T.ok(vim.fn.maparg(prefix .. "l", "n") ~= "", "a non-overridden suffix still maps under the prefix")
end)

T.it("keys.overrides: false disables the row entirely (no mapping at the default lhs)", function()
  local init = require("obelus.init")
  local prefix = "<leader>ZZR"
  init._keymaps({ prefix = prefix, disabled = {}, overrides = { J = false } })
  T.eq(vim.fn.maparg(prefix .. "J", "n"), "", "disabled-via-override suffix: no mapping at the default lhs")
end)

T.it("keys.overrides: an unknown suffix warns once (typo'd or removed row)", function()
  local init = require("obelus.init")
  -- vim.notify_once dedupes by message text; a fresh, never-used-before suffix here
  -- guarantees this exact message hasn't fired in an earlier spec in this process.
  local seen = false
  local orig = vim.notify_once
  vim.notify_once = function(msg, ...)
    if msg:find("keys.overrides has no suffix 'ZzUnknownSuffix99'", 1, true) then
      seen = true
    end
    return orig(msg, ...)
  end
  local ok, err = pcall(function()
    init._keymaps({ prefix = "<leader>ZZU", disabled = {}, overrides = { ZzUnknownSuffix99 = "<leader>ZZUx" } })
  end)
  vim.notify_once = orig
  if not ok then
    error(err, 0)
  end
  T.ok(seen, "warned about the unknown override suffix")
end)

T.it("MAPSPEC: suffix 'A' (tag_thread) maps under the prefix by default", function()
  local init = require("obelus.init")
  local prefix = "<leader>ZZA"
  init._keymaps({ prefix = prefix, disabled = {}, overrides = {} })
  T.ok(vim.fn.maparg(prefix .. "A", "n") ~= "", "suffix A is mapped by default")
end)

T.it("MAPSPEC: suffix 'A' disables/overrides like any other row", function()
  local init = require("obelus.init")
  local prefix = "<leader>ZZAA"
  init._keymaps({ prefix = prefix, disabled = {}, overrides = { A = false } })
  T.eq(vim.fn.maparg(prefix .. "A", "n"), "", "disabled via override: no mapping at the default lhs")
end)
