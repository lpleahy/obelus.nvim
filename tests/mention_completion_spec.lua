-- Completion-engine "@" mentions (blink.cmp / nvim-cmp), extending mention_spec.lua's
-- picker coverage: the shared item core (M._at_token/M._items) in mention.lua, engine
-- resolution + lazy registration in mention.attach(), and the mention_blink.lua /
-- mention_cmp.lua adapters driven directly with synthetic engine contexts. The
-- headless test env has no blink.cmp/nvim-cmp on rtp (see tests/run.lua) — engine
-- resolution here always drives package.loaded fakes, never the real plugins, and
-- every fake is torn down at the end of its own test (helpers.fresh() doesn't
-- touch package.loaded).
T.describe("mention_completion")

local mention = require("obelus.mention")

-- The buffer-local Lua-function callback mention.attach bound to "@" in insert
-- mode, or nil if none is bound (same helper as mention_spec.lua's, duplicated —
-- each spec file is its own chunk, no shared locals across them).
local function at_callback(buf)
  for _, km in ipairs(vim.api.nvim_buf_get_keymap(buf, "i")) do
    if km.lhs == "@" then
      return km.callback
    end
  end
end

-- A scratch buffer on obelus's input filetype — enough for attach()/enabled()
-- checks; the heavier real-panel open_input() (mention_spec.lua) isn't needed
-- when nothing here actually renders a picker or a completion menu.
local function scratch_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = mention.FILETYPE
  return buf
end

-- ---------------------------------------------------------------------------
-- M._at_token
-- ---------------------------------------------------------------------------

T.it("_at_token: a lone boundary @ has an empty prefix", function()
  local at_col0, prefix = mention._at_token("@", 1)
  T.eq(at_col0, 0)
  T.eq(prefix, "")
end)

T.it("_at_token: a boundary @ with a partial path prefix", function()
  local line = "@lua/ob"
  local at_col0, prefix = mention._at_token(line, #line)
  T.eq(at_col0, 0)
  T.eq(prefix, "lua/ob")
end)

T.it("_at_token: a boundary @ mid-line (preceded by whitespace)", function()
  local line = "see @lua/x.lua"
  local at_col0, prefix = mention._at_token(line, #line)
  T.eq(at_col0, 4)
  T.eq(prefix, "lua/x.lua")
end)

T.it("_at_token: mid-word @ (foo@bar) is rejected", function()
  local at_col0 = mention._at_token("foo@bar", 7)
  T.is_nil(at_col0)
end)

T.it("_at_token: an @ earlier in the line, cursor past a space, is nil (the token already ended)", function()
  local at_col0 = mention._at_token("@foo bar", 8)
  T.is_nil(at_col0, "a space ends the token; the @ is out of scope")
end)

T.it("_at_token: no @ in the line at all is nil", function()
  local at_col0 = mention._at_token("just plain text", 16)
  T.is_nil(at_col0)
end)

T.it("_at_token: multibyte filename chars stay inside the token (the scan is byte-wise)", function()
  -- %w alone is ASCII-only: without \128-\255 in PATH_CHAR the scan died on
  -- the é's continuation byte and the menu closed for good mid-mention
  local line = "@caf\195\169/x.lua"
  local at_col0, prefix = mention._at_token(line, #line)
  T.eq(at_col0, 0, "the @ is still reachable past a multibyte char")
  T.eq(prefix, "caf\195\169/x.lua")
  -- boundary rule still applies with multibyte BEFORE the @
  local at2 = mention._at_token("\226\134\146 @lua", #"\226\134\146 @lua")
  T.eq(at2, #"\226\134\146 ", "multibyte text before a space-boundary @ is fine")
end)

-- ---------------------------------------------------------------------------
-- M._items caching
-- ---------------------------------------------------------------------------

T.it("_items: two calls within the TTL run the lister once; _invalidate forces a re-list", function()
  local real_list_async = mention._list_files_async
  local calls = 0
  -- synchronous stub: _items serves the refreshed cache on the SAME call (the
  -- real async path serves stale-then-fresh across keystrokes instead)
  mention._list_files_async = function(_, cb)
    calls = calls + 1
    cb({ "a.lua", "b.lua" })
  end
  mention._invalidate()

  local items1 = mention._items("/fake/root")
  local items2 = mention._items("/fake/root")
  T.eq(calls, 1, "cached — the second call didn't re-list")
  T.eq(#items1, 2)
  T.eq(items1[1], { label = "a.lua", kind = 17, filterText = "a.lua" })
  T.eq(items2, items1, "the second call served the same cached items")

  mention._invalidate()
  mention._items("/fake/root")
  T.eq(calls, 2, "_invalidate forced a fresh list")

  mention._list_files_async = real_list_async
  mention._invalidate()
end)

T.it("_items: includes one item per existing thread, appended after the file items", function()
  local ctx = T.fresh()
  local c = ctx.store.add(T.comment({ comment = "why is this here?" }))
  local meta = ctx.store.meta_thread()
  local real_list_async = mention._list_files_async
  mention._list_files_async = function(_, cb)
    cb({ "a.lua" })
  end
  mention._invalidate()

  local items = mention._items(ctx.root)
  local thread_item, meta_item
  for _, it in ipairs(items) do
    if it.label == "thread:" .. c.id then
      thread_item = it
    elseif it.label == "thread:" .. meta.id then
      meta_item = it
    end
  end
  T.ok(thread_item, "a completion item exists for the real thread")
  T.eq(thread_item.kind, 23, "kind = Event, distinct from File (17)")
  T.contains(thread_item.filterText, "why is this here?", "filterText carries the comment text (fuzzy target)")
  T.contains(thread_item.filterText, "thread:" .. c.id)
  T.is_nil(meta_item, "the meta (project) thread never appears in the picker")

  mention._list_files_async = real_list_async
  mention._invalidate()
end)

-- ---------------------------------------------------------------------------
-- Engine resolution + lazy registration (package.loaded fakes; no real
-- blink.cmp/nvim-cmp on rtp in this test env)
-- ---------------------------------------------------------------------------

-- Crash-safe fake scaffolding: a failed assertion mid-spec raises, and cleanup
-- written at the tail of the closure would be SKIPPED — the leaked fake then
-- corrupts every later engine-resolution spec in this process. pcall + rethrow.
local function with_fakes(fakes, fn)
  for name, mod in pairs(fakes) do
    package.loaded[name] = mod
  end
  local ok, err = pcall(fn)
  for name in pairs(fakes) do
    package.loaded[name] = nil
  end
  mention._reset_engine()
  if not ok then
    error(err, 0)
  end
end

T.it("engine resolution: blink present -> attach registers ONCE across two attaches, binds no @ keymap", function()
  T.fresh({ input = { mention = { completion = "blink" } } })
  mention._reset_engine()
  local provider_calls, filetype_calls = 0, {}
  with_fakes({
    ["blink.cmp"] = {
      add_source_provider = function(id, cfg)
        provider_calls = provider_calls + 1
        T.eq(id, "obelus")
        T.eq(cfg.module, "obelus.mention_blink")
      end,
      add_filetype_source = function(ft, id)
        filetype_calls[#filetype_calls + 1] = ft
        T.eq(id, "obelus")
      end,
    },
  }, function()
    local buf1, buf2 = scratch_buf(), scratch_buf()
    mention.attach(buf1)
    mention.attach(buf2)

    T.eq(provider_calls, 1, "add_source_provider called exactly once across both attaches")
    T.eq(filetype_calls, { mention.FILETYPE }, "add_filetype_source called exactly once, for our filetype")
    T.is_nil(at_callback(buf1), "no @ picker keymap — blink's menu owns @")
    T.is_nil(at_callback(buf2), "no @ picker keymap on the second buffer either")
    vim.api.nvim_buf_delete(buf1, { force = true })
    vim.api.nvim_buf_delete(buf2, { force = true })
  end)
end)

T.it("engine resolution: a provider already in blink's registry (obelus-only reload) counts as registered", function()
  T.fresh({ input = { mention = { completion = "blink" } } })
  mention._reset_engine()
  with_fakes({
    ["blink.cmp"] = {
      -- a re-register would assert in real blink — the fake makes it LOUD
      add_source_provider = function()
        error("duplicate registration — must not be called")
      end,
      add_filetype_source = function()
        error("must not be called")
      end,
    },
    ["blink.cmp.config"] = { sources = { providers = { obelus = { module = "obelus.mention_blink" } } } },
  }, function()
    local buf = scratch_buf()
    mention.attach(buf)
    T.is_nil(at_callback(buf), "no picker keymap — the pre-registered blink source still owns @")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

T.it("engine resolution: cmp present -> attach registers ONCE across two attaches, binds no @ keymap", function()
  T.fresh({ input = { mention = { completion = "cmp" } } })
  mention._reset_engine()
  local register_calls, filetype_calls = 0, 0
  with_fakes({
    ["cmp"] = {
      register_source = function(id, src)
        register_calls = register_calls + 1
        T.eq(id, "obelus")
        T.ok(src.complete, "the registered source has complete()")
      end,
      setup = {
        filetype = function(ft, opts)
          filetype_calls = filetype_calls + 1
          T.eq(ft, mention.FILETYPE)
          T.eq(opts.sources, { { name = "obelus" } })
        end,
      },
    },
  }, function()
    local buf1, buf2 = scratch_buf(), scratch_buf()
    mention.attach(buf1)
    mention.attach(buf2)

    T.eq(register_calls, 1, "register_source called exactly once across both attaches")
    T.eq(filetype_calls, 1, "setup.filetype called exactly once")
    T.is_nil(at_callback(buf1), "no @ picker keymap — cmp's menu owns @")
    T.is_nil(at_callback(buf2))
    vim.api.nvim_buf_delete(buf1, { force = true })
    vim.api.nvim_buf_delete(buf2, { force = true })
  end)
end)

T.it('engine resolution: completion = "blink" with no blink installed warns ONCE, the picker binds', function()
  T.fresh({ input = { mention = { completion = "blink" } } })
  mention._reset_engine()
  package.loaded["blink.cmp"] = nil -- genuinely absent in this test env either way

  -- vim.notify_once is left REAL (it dedupes internally, forever, by exact msg
  -- text — see :h vim.notify_once) so this actually exercises "warns once", not
  -- a hand-rolled dedupe; only the underlying vim.notify is stubbed to count.
  local warns = 0
  local real_notify = vim.notify
  vim.notify = function(msg, ...)
    if msg:match("blink%.cmp isn't installed") then
      warns = warns + 1
    end
    return real_notify(msg, ...)
  end

  local buf1, buf2 = scratch_buf(), scratch_buf()
  mention.attach(buf1)
  mention.attach(buf2)

  vim.notify = real_notify
  T.eq(warns, 1, "warned exactly once across two attaches")
  T.ok(at_callback(buf1), "the @ picker keymap bound (fallback)")
  T.ok(at_callback(buf2), "the @ picker keymap bound on the second buffer too")

  mention._reset_engine()
  vim.api.nvim_buf_delete(buf1, { force = true })
  vim.api.nvim_buf_delete(buf2, { force = true })
end)

T.it("engine resolution: completion = false never engages an engine — the picker binds", function()
  T.fresh({ input = { mention = { completion = false } } })
  mention._reset_engine()
  local buf = scratch_buf()
  mention.attach(buf)
  T.ok(at_callback(buf), "the @ picker keymap bound")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

T.it("engine resolution: picker = false with no engine present binds nothing at all", function()
  T.fresh({ input = { mention = { picker = false, completion = "auto" } } })
  mention._reset_engine()
  local buf = scratch_buf()
  mention.attach(buf)
  T.is_nil(at_callback(buf), "neither an engine nor the picker claimed @")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- ---------------------------------------------------------------------------
-- mention_blink.lua, driven directly with a synthetic blink.cmp.Context
-- (cursor = {row1, col0}, line = the current line's text — see
-- completion/trigger/context.lua in the installed blink.cmp)
-- ---------------------------------------------------------------------------

T.it("mention_blink: no @ in scope -> empty items, no error, a cancel fn is returned", function()
  local src = require("obelus.mention_blink").new()
  local got
  local cancel = src:get_completions({ cursor = { 1, 9 }, line = "just text" }, function(resp)
    got = resp
  end)
  T.ok(got, "callback ran")
  T.eq(got.items, {})
  T.eq(got.is_incomplete_forward, false)
  T.eq(got.is_incomplete_backward, false)
  T.eq(type(cancel), "function", "returns a cancel fn per the installed interface")
end)

T.it("mention_blink: a boundary @ returns items with textEdit ranges + escaped newText", function()
  local ctx = T.fresh()
  vim.fn.mkdir(ctx.root .. "/dir with space", "p")
  vim.fn.writefile({ "x" }, ctx.root .. "/dir with space/file.lua")
  mention._invalidate()
  -- pre-warm: _items is async-refreshing now — the first call serves nothing and
  -- kicks the lister; wait for the fresh list like the engine's next keystroke would
  local root = require("obelus.store").root()
  mention._items(root)
  T.ok(
    T.wait_for(function()
      return #mention._items(root) > 0
    end, 3000),
    "the async file list landed"
  )

  local src = require("obelus.mention_blink").new()
  local line = "@lua"
  local got
  local cancel = src:get_completions({ cursor = { 3, #line }, line = line }, function(resp)
    got = resp
  end)
  T.ok(got, "callback ran")
  T.ok(#got.items > 0, "the project's files came back as items")
  T.eq(got.is_incomplete_forward, true, "forces a re-query — path chars break blink's own keyword")
  T.eq(got.is_incomplete_backward, true)
  T.eq(type(cancel), "function")

  local spacey
  for _, item in ipairs(got.items) do
    if item.label == "dir with space/file.lua" then
      spacey = item
    end
  end
  T.ok(spacey, "the spacey path is among the items")
  T.eq(spacey.kind, 17)
  T.eq(spacey.filterText, "dir with space/file.lua", "filterText is UNescaped")
  T.eq(spacey.textEdit.newText, "dir\\ with\\ space/file.lua", "newText escapes the spaces")
  T.eq(spacey.textEdit.range.start, { line = 2, character = 1 }, "range starts right after the @")
  T.eq(spacey.textEdit.range["end"], { line = 2, character = #line }, "range ends at the cursor")
end)

T.it("mention_blink: enabled() is filetype- and config-gated", function()
  T.fresh({ input = { mention = { completion = "blink" } } })
  local src = require("obelus.mention_blink").new()
  local orig = vim.api.nvim_get_current_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)

  vim.bo[buf].filetype = "lua"
  T.eq(src:enabled(), false, "the wrong filetype is disabled")

  vim.bo[buf].filetype = mention.FILETYPE
  T.eq(src:enabled(), true, "our filetype, completion active -> enabled")

  T.fresh({ input = { mention = { completion = false } } })
  T.eq(src:enabled(), false, "completion turned off in config -> disabled even on our filetype")

  pcall(vim.api.nvim_set_current_buf, orig)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- ---------------------------------------------------------------------------
-- mention_cmp.lua, driven directly with a synthetic cmp.Context (targets the
-- STANDARD nvim-cmp source contract — cmp isn't installed in this dev env to
-- verify field names against; see mention_cmp.lua's header comment)
-- ---------------------------------------------------------------------------

T.it("mention_cmp: get_trigger_characters/get_keyword_pattern basic shape", function()
  local src = require("obelus.mention_cmp").new()
  T.eq(src:get_trigger_characters(), { "@" })
  T.ok(
    type(src:get_keyword_pattern()) == "string" and src:get_keyword_pattern():find("@", 1, true),
    "pattern mentions @"
  )
end)

T.it("mention_cmp: no @ in scope -> empty, isIncomplete false", function()
  local src = require("obelus.mention_cmp").new()
  local got
  src:complete({ context = { cursor_before_line = "just text", cursor = { line = 0 } } }, function(resp)
    got = resp
  end)
  T.ok(got, "callback ran")
  T.eq(got.items, {})
  T.eq(got.isIncomplete, false)
end)

T.it("mention_cmp: a boundary @ returns items with textEdit ranges + escaped newText", function()
  local ctx = T.fresh()
  vim.fn.mkdir(ctx.root .. "/dir with space", "p")
  vim.fn.writefile({ "x" }, ctx.root .. "/dir with space/file.lua")
  mention._invalidate()
  -- pre-warm: _items is async-refreshing now — the first call serves nothing and
  -- kicks the lister; wait for the fresh list like the engine's next keystroke would
  local root = require("obelus.store").root()
  mention._items(root)
  T.ok(
    T.wait_for(function()
      return #mention._items(root) > 0
    end, 3000),
    "the async file list landed"
  )

  local src = require("obelus.mention_cmp").new()
  local line = "@lua"
  local got
  src:complete({ context = { cursor_before_line = line, cursor = { line = 4 } } }, function(resp)
    got = resp
  end)
  T.ok(got, "callback ran")
  T.ok(#got.items > 0)
  T.eq(got.isIncomplete, true)

  local spacey
  for _, item in ipairs(got.items) do
    if item.label == "dir with space/file.lua" then
      spacey = item
    end
  end
  T.ok(spacey, "the spacey path is among the items")
  T.eq(spacey.textEdit.newText, "dir\\ with\\ space/file.lua")
  T.eq(spacey.textEdit.range.start, { line = 4, character = 1 })
  T.eq(spacey.textEdit.range["end"], { line = 4, character = #line })
end)

-- ---------------------------------------------------------------------------
-- _scan: forward validation over finished text (files must EXIST)
-- ---------------------------------------------------------------------------

T.it("_scan: valid mentions only — existing file yes, missing file no, mid-word no", function()
  local ctx = T.fresh()
  vim.fn.writefile({ "x" }, ctx.root .. "/real.lua")
  mention._scan_invalidate()
  local line = "see @real.lua and @missing.lua and foo@real.lua end"
  local got = mention._scan(line)
  T.eq(#got, 1, "only the valid boundary mention matched")
  T.eq(got[1][3], "real.lua")
  T.eq(line:sub(got[1][1] + 1, got[1][2]), "@real.lua", "the span covers the whole token")
end)

T.it("_scan: an escaped-space path validates and unescapes (the \\  pair beats PATH_CHAR's backslash)", function()
  local ctx = T.fresh()
  vim.fn.mkdir(ctx.root .. "/dir with space", "p")
  vim.fn.writefile({ "x" }, ctx.root .. "/dir with space/file.lua")
  mention._scan_invalidate()
  local line = "check @dir\\ with\\ space/file.lua please"
  local got = mention._scan(line)
  T.eq(#got, 1, "the spacey mention validated")
  T.eq(got[1][3], "dir with space/file.lua", "the path came back UNescaped")
  T.eq(line:sub(got[1][1] + 1, got[1][2]), "@dir\\ with\\ space/file.lua")
end)

T.it("_scan: two mentions on one line, both spans returned in order", function()
  local ctx = T.fresh()
  vim.fn.writefile({ "x" }, ctx.root .. "/a.lua")
  vim.fn.writefile({ "x" }, ctx.root .. "/b.lua")
  mention._scan_invalidate()
  local got = mention._scan("@a.lua then @b.lua")
  T.eq(#got, 2)
  T.eq(got[1][3], "a.lua")
  T.eq(got[2][3], "b.lua")
end)

T.it("_scan: the stat cache serves within the TTL; _scan_invalidate re-checks", function()
  local ctx = T.fresh()
  vim.fn.writefile({ "x" }, ctx.root .. "/here.lua")
  mention._scan_invalidate()
  T.eq(#mention._scan("@here.lua"), 1, "valid while the file exists")
  vim.fn.delete(ctx.root .. "/here.lua")
  T.eq(#mention._scan("@here.lua"), 1, "still valid within the TTL (cached verdict)")
  mention._scan_invalidate()
  T.eq(#mention._scan("@here.lua"), 0, "invalid after the cache drops")
end)

T.it("_scan: @thread:<id> is valid for a real thread id, invalid for garbage (bypasses fs_stat entirely)", function()
  local ctx = T.fresh()
  local c = ctx.store.add(T.comment({ comment = "q" }))
  mention._scan_invalidate()
  local line = "see @thread:" .. c.id .. " and @thread:does-not-exist"
  local got = mention._scan(line)
  T.eq(#got, 1, "only the real thread id validated")
  T.eq(got[1][3], "thread:" .. c.id, "the returned path is the WHOLE thread:<id> token")
end)

-- ---------------------------------------------------------------------------
-- input-buffer live highlight
-- ---------------------------------------------------------------------------

-- same shape as mention_spec.lua's open_input (spec files are separate scopes)
local function open_reply_input(ctx)
  local file = ctx.root .. "/f.lua"
  vim.fn.writefile({ "local a = 1" }, file)
  vim.cmd("edit " .. file)
  local fabs = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
  local c = ctx.store.add(T.comment({ file = fabs, range = { sl = 1, el = 1 } }))
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local panel = require("obelus.panel")
  panel.open_thread(c.id, false)
  T.ok(
    T.wait_for(function()
      local g = panel.geom()
      return g ~= nil and g.input_win ~= nil and not g.input_pending_reveal
    end),
    "reply box revealed"
  )
  local g = panel.geom()
  return g.input_win, vim.api.nvim_win_get_buf(g.input_win)
end

T.it("input highlight: valid mentions get ObelusMention extmarks; invalid ones don't", function()
  local ctx = T.fresh()
  vim.fn.writefile({ "x" }, ctx.root .. "/real.lua")
  mention._scan_invalidate()
  local win, buf = open_reply_input(ctx)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "@real.lua and @missing.lua" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  local ns_id = vim.api.nvim_create_namespace("obelus_mention_hl")
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns_id, 0, -1, { details = true })
  T.eq(#marks, 1, "exactly one highlight — the valid mention")
  T.eq(marks[1][3], 0, "starts at the @")
  T.eq(marks[1][4].end_col, #"@real.lua", "covers the whole token")
  T.eq(marks[1][4].hl_group, "ObelusMention")
  local _ = win
end)

-- ---------------------------------------------------------------------------
-- chat-body styling (builtin renderer post-pass)
-- ---------------------------------------------------------------------------

T.it("thread body: a valid mention gets the per-bubble Mention style; code spans are left alone", function()
  local ctx = T.fresh()
  vim.fn.writefile({ "x" }, ctx.root .. "/real.lua")
  mention._scan_invalidate()
  local c = ctx.store.add(T.comment({ comment = "q" }))
  ctx.store.add_turn(c.id, "agent", "see @real.lua and `@real.lua` ok")
  local rows = require("obelus.thread").build(ctx.store.get(c.id), 70, { markdown = true, rules = false })
  local mention_chunks, full = {}, {}
  for _, r in ipairs(rows) do
    if r.kind == "content" then
      for _, ch in ipairs(r.chunks) do
        full[#full + 1] = ch[1]
        if ch[2] == "ObelusReplyMention" then
          mention_chunks[#mention_chunks + 1] = ch[1]
        end
      end
    end
  end
  T.eq(mention_chunks, { "@real.lua" }, "exactly the plain-text mention styled — not the code-span one")
  T.contains(table.concat(full), "see @real.lua and @real.lua ok", "total text byte-identical (splits only)")
end)

-- ---------------------------------------------------------------------------
-- prompt_suffix: input.mention.send = "reference" | "inline"
-- ---------------------------------------------------------------------------

T.it('prompt_suffix: "reference" (default) appends the one-line note; no mentions -> nil', function()
  local ctx = T.fresh()
  vim.fn.writefile({ "x" }, ctx.root .. "/real.lua")
  mention._scan_invalidate()
  local s = mention.prompt_suffix("please check @real.lua")
  T.ok(s and s:find("[Mentions]", 1, true), "the reference note is present")
  T.is_nil(mention.prompt_suffix("no mentions here"), "nil without a valid mention")
  T.is_nil(mention.prompt_suffix("@missing.lua"), "an invalid mention doesn't trigger the note")
end)

T.it('prompt_suffix: "inline" embeds the file contents, fenced, once per unique path', function()
  local ctx = T.fresh({ input = { mention = { send = "inline" } } })
  vim.fn.writefile({ "local marker_line = 42" }, ctx.root .. "/real.lua")
  mention._scan_invalidate()
  local s = mention.prompt_suffix("check @real.lua and again @real.lua")
  T.ok(s and s:find("[Mentioned files]", 1, true), "the inline section is present")
  T.contains(s, "local marker_line = 42", "the file's contents are embedded")
  T.contains(s, "```lua", "fenced with the extension language")
  T.contains(s, "local marker_line = 42\n```", "no dangling blank line before the closing fence")
  local _, n = s:gsub("@real%.lua", "")
  T.eq(n, 1, "the file appears once despite two mentions")
end)

T.it('prompt_suffix: "inline" truncates a huge file at the cap and says so', function()
  local ctx = T.fresh({ input = { mention = { send = "inline" } } })
  local big = {}
  for i = 1, 4000 do
    big[i] = string.format("line %04d %s", i, string.rep("x", 40))
  end
  vim.fn.writefile(big, ctx.root .. "/big.lua")
  mention._scan_invalidate()
  local s = mention.prompt_suffix("@big.lua")
  T.ok(s, "suffix produced")
  T.contains(s, "(truncated)", "truncation is flagged")
  T.ok(#s < 40 * 1024, "the embedded content respects the per-file cap")
  T.ok(not s:find("line 4000", 1, true), "the tail was cut")
end)

T.it('prompt_suffix: "inline" notes directories instead of dumping them', function()
  local ctx = T.fresh({ input = { mention = { send = "inline" } } })
  vim.fn.mkdir(ctx.root .. "/somedir", "p")
  mention._scan_invalidate()
  local s = mention.prompt_suffix("@somedir")
  T.ok(s and s:find("directory", 1, true), "a directory mention gets the browse note")
end)

-- ---------------------------------------------------------------------------
-- prompt_suffix: "@thread:<id>" mentions — ALWAYS expand in full, independent of
-- input.mention.send (that knob governs FILE mentions only)
-- ---------------------------------------------------------------------------

T.it("prompt_suffix: a mentioned RESOLVED thread expands fully under [Mentioned threads]", function()
  local ctx = T.fresh()
  local c = ctx.store.add(T.comment({ comment = "fix the off-by-one error" }))
  ctx.store.add_turn(c.id, "agent", "fixed, see the new bounds check")
  ctx.store.resolve(c.id)
  local s = mention.prompt_suffix("pull that back in: @thread:" .. c.id)
  T.ok(s, "a suffix was produced")
  T.contains(s, "[Mentioned threads]")
  T.contains(s, "fix the off-by-one error", "the original comment is included in full")
  T.contains(s, "fixed, see the new bounds check", "the agent's turn is included in full")
end)

T.it("prompt_suffix: works from ANY chat, not just the meta thread's — pending thread too", function()
  local ctx = T.fresh()
  local c = ctx.store.add(T.comment({ comment = "still open, not resolved" }))
  local s = mention.prompt_suffix("see @thread:" .. c.id)
  T.contains(s, "[Mentioned threads]")
  T.contains(s, "still open, not resolved")
end)

T.it("prompt_suffix: @thread:<meta-id> is skipped — the project thread is never expandable", function()
  local ctx = T.fresh()
  local meta = ctx.store.meta_thread()
  T.is_nil(mention.prompt_suffix("look at @thread:" .. meta.id), "nothing to expand, nothing to reference either")
end)

T.it("prompt_suffix: a thread mention plus a file mention both appear (independent sections)", function()
  local ctx = T.fresh()
  vim.fn.writefile({ "x" }, ctx.root .. "/real.lua")
  mention._scan_invalidate()
  local c = ctx.store.add(T.comment({ comment = "context for this" }))
  local s = mention.prompt_suffix("see @thread:" .. c.id .. " and @real.lua")
  T.contains(s, "[Mentioned threads]")
  T.contains(s, "context for this")
  T.contains(s, "[Mentions]", "the file mention still gets its own (default reference) note")
end)

T.it("transport.submit applies the mention policy exactly once at the choke point", function()
  local F = require("fake")
  local ctx = T.fresh({ transport = { dispatch = "fake", default = "fake" } })
  F.install()
  vim.fn.writefile({ "x" }, ctx.root .. "/real.lua")
  mention._scan_invalidate()
  local c = ctx.store.add(T.comment({ comment = "look at @real.lua" }))
  require("obelus.transport").submit("fake", {})
  T.ok(F.payload, "the fake transport got the payload")
  local _, n = F.payload.markdown:gsub("%[Mentions%]", "")
  T.eq(n, 1, "the reference note landed exactly once in the outgoing markdown")
  local _ = c
end)

-- ---------------------------------------------------------------------------
-- async first-@ behavior: the menu must pop on the SESSION'S FIRST "@"
-- ---------------------------------------------------------------------------

T.it("_items_async: a cold cache parks the callback and fires it when the list lands", function()
  T.fresh()
  local real_list_async = mention._list_files_async
  local deferred
  mention._list_files_async = function(_, cb)
    deferred = cb -- hold the listing like a slow fd would
  end
  mention._invalidate()

  local got
  mention._items_async("/fake/root2", function(items)
    got = items
  end)
  T.is_nil(got, "no premature empty answer — the callback is parked")
  deferred({ "a.lua" })
  T.ok(got ~= nil, "the callback fired when the listing landed")
  T.eq(#got, 1)
  T.eq(got[1].label, "a.lua")

  mention._list_files_async = real_list_async
  mention._invalidate()
end)

T.it("_items_async: a stale-but-nonempty cache answers immediately (and refreshes behind)", function()
  T.fresh()
  local real_list_async = mention._list_files_async
  local calls = 0
  mention._list_files_async = function(_, cb)
    calls = calls + 1
    if calls == 1 then
      cb({ "old.lua" }) -- first fill, synchronous
    end
    -- second refresh held forever — the stale answer must not depend on it
  end
  mention._invalidate()
  mention._items_async("/fake/root3", function() end) -- fills the cache
  -- age the cache artificially by dropping only the timestamp path: simplest is
  -- waiting out the TTL — too slow — so instead invalidate is NOT used (it would
  -- empty items); rely on the refreshing flag path: force a second async call
  -- while a refresh is in-flight-but-stale
  local got
  mention._invalidate() -- cold again, but now hold the listing
  mention._items_async("/fake/root3", function(items)
    got = items
  end)
  T.is_nil(got, "cold after invalidate: parked (no stale items exist to serve)")

  mention._list_files_async = real_list_async
  mention._invalidate()
end)

T.it("mention_blink: get_completions on a COLD cache still calls back with items (async, not empty)", function()
  local ctx = T.fresh()
  vim.fn.writefile({ "x" }, ctx.root .. "/one.lua")
  local real_list_async = mention._list_files_async
  local deferred
  mention._list_files_async = function(_, cb)
    deferred = cb
  end
  mention._invalidate()

  local src = require("obelus.mention_blink").new()
  local got
  local cancel = src:get_completions({ cursor = { 1, 1 }, line = "@" }, function(resp)
    got = resp
  end)
  T.is_nil(got, "no empty answer for the first @ — blink would show nothing")
  deferred({ "one.lua" })
  T.ok(got ~= nil, "the callback fired once the file list landed")
  T.eq(#got.items, 1, "the first @ pops with real items")
  T.eq(got.items[1].label, "one.lua")
  T.eq(type(cancel), "function")

  mention._list_files_async = real_list_async
  mention._invalidate()
end)

T.it("mention_blink: cancelling a parked request suppresses its late callback", function()
  T.fresh()
  local real_list_async = mention._list_files_async
  local deferred
  mention._list_files_async = function(_, cb)
    deferred = cb
  end
  mention._invalidate()

  local src = require("obelus.mention_blink").new()
  local got
  local cancel = src:get_completions({ cursor = { 1, 1 }, line = "@" }, function(resp)
    got = resp
  end)
  cancel()
  deferred({ "one.lua" })
  T.is_nil(got, "a cancelled request never calls back")

  mention._list_files_async = real_list_async
  mention._invalidate()
end)

T.it(":ObelusPrompt — the cli transport records the exact final prompt, [Mentions] note included", function()
  local ctx = T.fresh({ transport = { dispatch = "cli", cli = { cmd = { "claude", "-p" } } } })
  vim.fn.writefile({ "x" }, ctx.root .. "/real.lua")
  mention._scan_invalidate()
  local real_system = vim.system
  local captured
  vim.system = function(cmd, opts)
    captured = cmd
    return {
      kill = function() end,
      wait = function()
        return { code = 0, stdout = "" }
      end,
      pid = 1,
    }
  end
  local c = ctx.store.add(T.comment({ comment = "seed" }))
  require("obelus").chat_send(c.id, "look at @real.lua please", "send")
  vim.system = real_system
  T.ok(captured, "the cli transport spawned")
  local recorded = require("obelus.log").prompt()
  T.ok(recorded, "the final prompt was recorded")
  T.eq(recorded, captured[#captured], "recorded prompt IS the argv prompt — verbatim")
  T.contains(recorded, "[Mentions]", "the mention note is visible in the inspection")
  T.contains(recorded, "[Formatting]", "the formatting suffix too")
  T.eq(vim.fn.exists(":ObelusPrompt"), 2, "the :ObelusPrompt command exists")
end)

T.it("a NEVER-dispatched thread's first chat message carries the comment context + mention policy", function()
  local F = require("fake")
  local ctx = T.fresh({ transport = { dispatch = "fake" } })
  F.install()
  vim.fn.writefile({ "local x = 1" }, ctx.root .. "/f.lua")
  mention._scan_invalidate()
  local c =
    ctx.store.add(T.comment({ file = ctx.root .. "/f.lua", comment = "why?", selected_text = { "local x = 1" } }))
  T.is_nil(c.session_id, "fresh comment: no session")
  require("obelus").chat_send(c.id, "is this ok?", "send")
  T.ok(F.payload, "dispatched")
  T.contains(F.payload.markdown, "@f.lua", "the serialized comment (with its @path) is prepended")
  T.contains(F.payload.markdown, "local x = 1", "the selection is included")
  T.contains(F.payload.markdown, "is this ok?", "the user's message follows")
  T.contains(F.payload.markdown, "[Mentions]", "the mention send policy applied to the thread")
end)

T.it("a RESUMED thread's chat message sends only the new text (the session carries history)", function()
  local F = require("fake")
  local ctx = T.fresh({ transport = { dispatch = "fake" } })
  F.install()
  local c = ctx.store.add(T.comment({ comment = "seed" }))
  c.session_id = "sess-1" -- as a completed dispatch would have recorded
  require("obelus").chat_send(c.id, "follow-up question", "send")
  T.ok(F.payload, "dispatched")
  T.eq(F.payload.opts.resume, "sess-1", "resumes the session")
  T.ok(not F.payload.markdown:find("Feedback:", 1, true), "no re-serialized comment on resume")
  T.contains(F.payload.markdown, "follow-up question")
end)

T.it('send = "inline": starting a thread embeds the commented file, not just the selection', function()
  local F = require("fake")
  local ctx =
    T.fresh({ transport = { dispatch = "fake", default = "fake" }, input = { mention = { send = "inline" } } })
  F.install()
  vim.fn.writefile({ "local hidden_part = 99", "local shown = 1" }, ctx.root .. "/whole.lua")
  mention._scan_invalidate()
  ctx.store.add(
    T.comment({ file = ctx.root .. "/whole.lua", comment = "check", selected_text = { "local shown = 1" } })
  )
  require("obelus.transport").submit("fake", {})
  T.ok(F.payload, "submitted")
  T.contains(F.payload.markdown, "[Mentioned files]", "inline section present")
  T.contains(F.payload.markdown, "local hidden_part = 99", "the WHOLE file is embedded, beyond the selection")
end)

T.it("meta first send: briefing @thread summaries do NOT self-expand; a USER-typed one does", function()
  local F = require("fake")
  local ctx = T.fresh({ transport = { dispatch = "fake" } })
  F.install()
  local done = ctx.store.add(T.comment({ comment = "old fixed issue" }))
  ctx.store.add_turn(done.id, "agent", string.rep("long resolved conversation text ", 40))
  ctx.store.resolve(done.id)
  local meta = ctx.store.meta_thread()
  require("obelus").chat_send(meta.id, "just an overview please", "send")
  T.ok(F.payload, "dispatched")
  T.contains(F.payload.markdown, "@thread:" .. done.id, "the one-line summary is present")
  T.ok(not F.payload.markdown:find("[Mentioned threads]", 1, true), "the summary did NOT self-expand")
  T.ok(not F.payload.markdown:find("long resolved conversation text", 1, true), "resolved body stayed out")

  -- but the USER explicitly mentioning the resolved thread pulls it back in full
  F.finish(true) -- settle the first stream: busy() blocks a send while it runs
  F.payload = nil
  meta.session_id = "sess-meta"
  require("obelus").chat_send(meta.id, "tell me about @thread:" .. done.id, "send")
  T.ok(F.payload, "second send dispatched")
  T.contains(F.payload.markdown, "[Mentioned threads]", "user-typed thread mention expands")
  T.contains(F.payload.markdown, "long resolved conversation text", "in full")
end)

T.it("_scan: a line-suffixed file reference (@path:12) falls back to the valid path", function()
  local ctx = T.fresh()
  vim.fn.mkdir(ctx.root .. "/lua", "p")
  vim.fn.writefile({ "x" }, ctx.root .. "/lua/x.lua")
  mention._scan_invalidate()
  local line = "see @lua/x.lua:12 for the bug"
  local got = mention._scan(line)
  T.eq(#got, 1, "the mention survives the :12 suffix")
  T.eq(got[1][3], "lua/x.lua", "path excludes the line suffix")
  T.eq(line:sub(got[1][1] + 1, got[1][2]), "@lua/x.lua", "the span ends before the colon")
end)
