-- mention: the "@" file-picker bound to obelus input buffers (mention.lua). The
-- expr mapping always returns "@" (never eats the char) and, only at a word
-- boundary, schedules the picker; these specs drive that callback directly
-- (mention.attach binds a Lua-function keymap, retrievable via
-- nvim_buf_get_keymap) rather than simulating real insert-mode keystrokes, and
-- manually apply its "@" return value the same way Neovim's expr-mapping
-- insertion would — see feed_at() below.
T.describe("mention")

local mention = require("obelus.mention")
local real_pick = mention._pick -- restored once the stubbing tests below are done

-- Open a real thread chat + docked reply input (same pattern as e2e_spec's
-- open_and_send), returning the input's window + buffer.
local function open_input(ctx)
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

-- The buffer-local Lua-function callback mention.attach bound to "@" in insert
-- mode, or nil if none is bound.
local function at_callback(buf)
  for _, km in ipairs(vim.api.nvim_buf_get_keymap(buf, "i")) do
    if km.lhs == "@" then
      return km.callback
    end
  end
end

-- Drive the "@" mapping exactly as Neovim would for a real keystroke: call the
-- expr callback (its side effect, if any, is scheduled via vim.schedule — not
-- run yet), then apply its returned string at the cursor and advance past it,
-- same as expr-mapping insertion does for any other key.
local function feed_at(buf, win, row1, col0)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { row1, col0 })
  local cb = at_callback(buf)
  T.ok(cb, "the @ keymap is bound")
  local ret = cb()
  local row0 = row1 - 1
  vim.api.nvim_buf_set_text(buf, row0, col0, row0, col0, { ret })
  vim.api.nvim_win_set_cursor(win, { row1, col0 + #ret })
end

-- ---------------------------------------------------------------------------
-- 1. mid-word "@" never invokes the picker
-- ---------------------------------------------------------------------------

T.it("mid-word @ (e.g. foo@bar) does not invoke the picker; the literal @ lands", function()
  local ctx = T.fresh()
  local win, buf = open_input(ctx)
  local calls = 0
  mention._pick = function(_, _)
    calls = calls + 1
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "foo" })
  feed_at(buf, win, 1, 3) -- cursor right after "foo" — prev char "o", not a boundary

  T.wait_for(function()
    return calls > 0
  end, 60) -- give any (wrongly) scheduled trigger a chance to fire
  T.eq(calls, 0, "the picker must never fire for a mid-word @")
  T.eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], "foo@", "the literal @ was inserted")
end)

-- ---------------------------------------------------------------------------
-- 2. a boundary "@" triggers the picker; the pick lands right after it
-- ---------------------------------------------------------------------------

T.it("boundary @ triggers the picker; selecting a file inserts its path, cursor lands after it", function()
  local ctx = T.fresh()
  local win, buf = open_input(ctx)
  mention._pick = function(_, cb)
    cb("lua/obelus/panel.lua")
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  feed_at(buf, win, 1, 0) -- line start is always a boundary

  T.ok(
    T.wait_for(function()
      return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "@lua/obelus/panel.lua"
    end),
    "the picked path landed right after the @"
  )
  local cursor = vim.api.nvim_win_get_cursor(win)
  T.eq(cursor, { 1, #"@lua/obelus/panel.lua" }, "cursor sits right after the inserted path")
end)

-- ---------------------------------------------------------------------------
-- 3. a stale recorded position (the @ moved/vanished before the pick resolved)
--    aborts silently: no insertion, no error
-- ---------------------------------------------------------------------------

T.it("stale @ position (line mutated before the picker resolves) inserts nothing, errors nothing", function()
  local ctx = T.fresh()
  local win, buf = open_input(ctx)
  mention._pick = function(_, cb)
    -- simulate the user continuing to type / deleting the @ while the picker
    -- (in reality, an async UI) was still open
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "totally different text now" })
    cb("lua/obelus/panel.lua")
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  feed_at(buf, win, 1, 0)

  T.wait_for(function()
    return false
  end, 60) -- just pump the loop long enough for the schedule to fire
  T.eq(
    vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1],
    "totally different text now",
    "no path was spliced into the mutated line"
  )
end)

-- ---------------------------------------------------------------------------
-- 4. a path with spaces escapes as `\ `
-- ---------------------------------------------------------------------------

T.it("a picked path with spaces escapes as \\ ", function()
  local ctx = T.fresh()
  local win, buf = open_input(ctx)
  mention._pick = function(_, cb)
    cb("path with spaces/file.lua")
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  feed_at(buf, win, 1, 0)

  T.ok(
    T.wait_for(function()
      return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "@path\\ with\\ spaces/file.lua"
    end),
    "spaces in the picked path were escaped"
  )
end)

mention._pick = real_pick -- done stubbing; the remaining specs don't drive the picker

-- ---------------------------------------------------------------------------
-- 5. config.input.mention = false: attach is a no-op
-- ---------------------------------------------------------------------------

T.it("input.mention = false: attach never binds the @ keymap", function()
  local ctx = T.fresh({ input = { mention = false } })
  local _, buf = open_input(ctx)
  T.is_nil(at_callback(buf), "no buffer-local i-mode @ keymap exists")
end)

-- ---------------------------------------------------------------------------
-- 6. the fallback file-lister, unit-tested against this repo (the worktree)
-- ---------------------------------------------------------------------------

local function worktree_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  local testdir = vim.fn.fnamemodify(src, ":p:h")
  return vim.fn.fnamemodify(testdir, ":h")
end

T.it("_list_files: relative paths from the real worktree, includes mention.lua, respects the cap", function()
  local root = worktree_root()
  local files = mention._list_files(root)
  T.ok(#files > 0, "the worktree has files")
  local found = false
  for _, f in ipairs(files) do
    T.ok(not f:match("^/"), "every path is relative: " .. f)
    if f == "lua/obelus/mention.lua" then
      found = true
    end
  end
  T.ok(found, "lua/obelus/mention.lua is in the list")

  local capped, truncated = mention._list_files(root, 3)
  T.ok(#capped <= 3, "the cap is respected")
  T.ok(truncated, "a cap smaller than the tree reports truncated")
end)

-- ---------------------------------------------------------------------------
-- 7. hardening: same-batch dedup, extmark anchoring, abort-path resume
-- ---------------------------------------------------------------------------

T.it("two boundary @s in one batch open ONE picker, anchored on the first @", function()
  local ctx = T.fresh()
  local win, buf = open_input(ctx)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" }) -- blank the pre-seeded draft
  local calls, captured = 0, nil
  mention._pick = function(_, cb)
    calls = calls + 1
    captured = cb
  end
  -- two boundary "@"s driven back-to-back with NO event-loop turn between them —
  -- the second must be deduped by the scheduled[] flag, not stack a second picker
  feed_at(buf, win, 1, 0)
  vim.api.nvim_buf_set_text(buf, 0, 1, 0, 1, { " " }) -- "@ " so the next @ is at a boundary
  feed_at(buf, win, 1, 2)
  T.ok(
    T.wait_for(function()
      return calls > 0
    end),
    "the scheduled trigger ran"
  )
  vim.wait(50)
  T.eq(calls, 1, "exactly one picker opened for the batch")
  captured("lua/x.lua")
  T.eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], "@lua/x.lua @", "the pick landed after the FIRST @ only")
  mention._pick = real_pick
end)

T.it("the anchor extmark tracks the @ through edits made while the picker is open", function()
  local ctx = T.fresh()
  local win, buf = open_input(ctx)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" }) -- blank the pre-seeded draft
  local captured
  mention._pick = function(_, cb)
    captured = cb
  end
  feed_at(buf, win, 1, 0)
  T.ok(
    T.wait_for(function()
      return captured ~= nil
    end),
    "picker opened"
  )
  -- shift the @ right by prepending text at line start (as if edited mid-pick)
  vim.api.nvim_buf_set_text(buf, 0, 0, 0, 0, { "xx " })
  captured("lua/obelus/panel.lua")
  T.eq(
    vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1],
    "xx @lua/obelus/panel.lua",
    "the pick followed the @ to its shifted position"
  )
  mention._pick = real_pick
end)

T.it("a stale pick (the @ was deleted) aborts the insert but still refocuses + resumes insert", function()
  local ctx = T.fresh()
  local win, buf = open_input(ctx)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" }) -- blank the pre-seeded draft
  local captured
  mention._pick = function(_, cb)
    captured = cb
  end
  feed_at(buf, win, 1, 0)
  T.ok(
    T.wait_for(function()
      return captured ~= nil
    end),
    "picker opened"
  )
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" }) -- the @ is gone
  -- drift focus + mode away, like a real picker UI would
  vim.cmd("stopinsert")
  local g = require("obelus.panel").geom()
  vim.api.nvim_set_current_win(g.win)
  captured("lua/x.lua")
  T.eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], "", "no insertion on a stale pick")
  -- the regression this pins: resume() must run on the ABORT path too, not just
  -- explicit cancel — before the fix the user was left focused on whatever window
  -- the picker UI had current, in Normal mode. Focus is assertable headless; the
  -- startinsert half isn't (it only engages on real input processing, which a
  -- headless run never does — verified interactively).
  T.eq(vim.api.nvim_get_current_win(), win, "focus returned to the reply box")
  vim.cmd("stopinsert")
  mention._pick = real_pick
end)

-- ---------------------------------------------------------------------------
-- 8. paste_image: native clipboard-image paste (keys.chat.paste_image, <C-v> — smart: image else text)
-- ---------------------------------------------------------------------------

local real_grab = mention._grab_clipboard_image

-- The buffer-local callback bound to `lhs` in `mode` — same nvim_buf_get_keymap
-- lookup idiom as at_callback/chat_spec's n_callback, generalized over mode.
local function keymap_cb(buf, mode, lhs)
  for _, km in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if km.lhs == lhs then
      return km.callback
    end
  end
end

T.it("paste_image: a successful grab inserts a valid, highlightable @mention at the cursor", function()
  local ctx = T.fresh()
  local win, buf = open_input(ctx)
  mention._grab_clipboard_image = function(dest)
    vim.fn.writefile({ "fake png bytes" }, dest)
    return true
  end

  vim.api.nvim_set_current_win(win) -- paste_image reads the CURRENT win/buf, not a closure over these
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "see " })
  -- :startinsert (real, so nvim_win_set_cursor below can rest AT col 4 — one past
  -- the last char, exactly like a real insert-mode cursor) — but headless nvim
  -- never actually flips vim.fn.mode()'s return value without real input
  -- processing (same limitation the stale-pick test above notes), so stub that
  -- separately for paste_image's own was_insert check.
  vim.cmd("startinsert")
  vim.api.nvim_win_set_cursor(win, { 1, 4 })
  local real_mode = vim.fn.mode
  vim.fn.mode = function()
    return "i"
  end
  local cb = keymap_cb(buf, "i", "<C-V>")
  T.ok(cb, "paste_image is bound in insert mode")
  cb()
  vim.fn.mode = real_mode

  local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
  T.ok(line:match("^see @%.ai/img/%d+%-%d+%-%d+%.png $") ~= nil, "an @mention for the pasted image landed: " .. line)
  local path = line:match("@(%S+)")
  T.ok(vim.fn.filereadable(ctx.root .. "/" .. path) == 1, "the pasted image file actually exists under the project")
  mention._scan_invalidate()
  T.ok(#mention._scan(line) > 0, "the inserted mention validates (mention._scan finds it)")
  T.eq(vim.api.nvim_win_get_cursor(win), { 1, #line }, "cursor lands right after the inserted mention")

  mention._grab_clipboard_image = real_grab
end)

T.it("paste_image: from Normal mode, inserts after the cursor and does NOT resume insert", function()
  local ctx = T.fresh()
  local win, buf = open_input(ctx)
  mention._grab_clipboard_image = function(dest)
    vim.fn.writefile({ "fake png bytes" }, dest)
    return true
  end

  vim.api.nvim_set_current_win(win)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x" })
  vim.cmd("stopinsert")
  vim.api.nvim_win_set_cursor(win, { 1, 0 }) -- Normal mode, cursor ON "x"
  local cb = keymap_cb(buf, "n", "<C-V>")
  T.ok(cb, "paste_image is bound in normal mode")
  cb()

  local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
  T.ok(line:match("^x@%.ai/img/%d+%-%d+%-%d+%.png $") ~= nil, "inserted right AFTER the cursor char: " .. line)
  T.eq(vim.fn.mode(), "n", "stayed in Normal mode (no startinsert from a Normal-mode paste)")

  mention._grab_clipboard_image = real_grab
end)

T.it("paste_image: a failed grab notifies and inserts nothing", function()
  local ctx = T.fresh()
  local win, buf = open_input(ctx)
  mention._grab_clipboard_image = function(_dest)
    return false
  end
  local notified
  local real_notify = vim.notify
  vim.notify = function(msg, level)
    notified = { msg = msg, level = level }
  end

  vim.api.nvim_set_current_win(win)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  vim.cmd("startinsert")
  vim.fn.setreg("+", "") -- empty clipboard: the smart fallback has no text either
  local cb = keymap_cb(buf, "i", "<C-V>")
  cb()

  vim.notify = real_notify
  T.ok(notified, "a notification fired")
  T.contains(notified.msg, "clipboard is empty")
  T.eq(notified.level, vim.log.levels.INFO)
  T.eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], "", "nothing was inserted on failure")
  -- and the DIRECT (non-smart) call still reports the image-specific message
  notified = nil
  vim.notify = function(msg, level)
    notified = { msg = msg, level = level }
  end
  mention.paste_image()
  vim.notify = real_notify
  T.ok(notified and notified.msg:find("no image on the clipboard", 1, true), "direct call keeps its message")

  mention._grab_clipboard_image = real_grab
  local _ = ctx
end)

T.it("paste_image: keys.chat.paste_image = false disables the binding entirely", function()
  local ctx = T.fresh({ keys = { chat = { paste_image = false } } })
  local _win, buf = open_input(ctx)
  T.is_nil(keymap_cb(buf, "i", "<C-V>"), "no <C-v> paste keymap bound in the docked reply box")
end)

T.it("paste_image: two pastes get two distinct files and two @mentions (seq disambiguation)", function()
  local ctx = T.fresh()
  local win, buf = open_input(ctx)
  local n = 0
  mention._grab_clipboard_image = function(dest)
    n = n + 1
    vim.fn.writefile({ "fake png bytes " .. n }, dest)
    return true
  end

  vim.api.nvim_set_current_win(win)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  vim.cmd("startinsert")
  local cb = keymap_cb(buf, "i", "<C-V>")
  cb()
  cb() -- a second paste right after — must not collide with the first's filename

  local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
  local paths = {}
  for p in line:gmatch("@(%S+)") do
    paths[#paths + 1] = p
  end
  T.eq(#paths, 2, "two @mentions landed: " .. line)
  T.ok(paths[1] ~= paths[2], "the two pasted files have distinct names")
  for _, p in ipairs(paths) do
    T.ok(vim.fn.filereadable(ctx.root .. "/" .. p) == 1, "file exists: " .. p)
  end

  mention._grab_clipboard_image = real_grab
end)

T.it("paste_image: also bound and working from the quick-reply composer float", function()
  local ctx = T.fresh()
  mention._grab_clipboard_image = function(dest)
    vim.fn.writefile({ "fake png bytes" }, dest)
    return true
  end
  local fwin = require("obelus.render").compose({ on_cancel = function() end })
  T.ok(fwin and vim.api.nvim_win_is_valid(fwin), "the composer float opened")
  local buf = vim.api.nvim_win_get_buf(fwin)
  local cb = keymap_cb(buf, "i", "<C-V>")
  T.ok(cb, "paste_image is bound on the composer float too")
  cb()

  local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
  T.ok(
    line:match("^@%.ai/img/%d+%-%d+%-%d+%.png $") ~= nil,
    "the mention landed in the composer buffer: " .. tostring(line)
  )
  T.ok(vim.api.nvim_win_is_valid(fwin), "the composer float stays open — paste doesn't submit/close it")

  pcall(vim.api.nvim_win_close, fwin, true)
  mention._grab_clipboard_image = real_grab
  local _ = ctx
end)

T.it("paste_image in Normal mode on a multibyte char inserts AFTER the character, valid UTF-8", function()
  local ctx = T.fresh()
  local win, buf = open_input(ctx)
  local real_grab = mention._grab_clipboard_image
  mention._grab_clipboard_image = function(dest)
    vim.fn.writefile({ "png" }, dest)
    return true
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "café" })
  vim.api.nvim_set_current_win(win)
  vim.cmd("stopinsert")
  vim.api.nvim_win_set_cursor(win, { 1, 3 }) -- ON the é (its first byte)
  mention.paste_image()
  local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
  T.ok(line:find("^café@", 1, false) ~= nil or line:sub(1, 5) == "café", "the é survived intact: " .. line)
  T.ok(vim.fn.strdisplaywidth(line) > 0 and not line:find("\239\191\189", 1, true), "no replacement chars")
  T.contains(line, "café@", "mention landed after the whole character")
  mention._grab_clipboard_image = real_grab
end)

T.it("smart_paste: no image on the clipboard falls back to pasting the + register text", function()
  local ctx = T.fresh()
  local win, buf = open_input(ctx)
  local real_grab = mention._grab_clipboard_image
  mention._grab_clipboard_image = function()
    return false -- no image
  end
  vim.fn.setreg("+", "plain clipboard text")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  vim.api.nvim_set_current_win(win)
  vim.cmd("stopinsert")
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  mention.smart_paste()
  T.contains(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], "plain clipboard text", "text pasted like normal")
  mention._grab_clipboard_image = real_grab
end)
