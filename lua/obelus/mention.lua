-- @-file mentions in an obelus input buffer (the docked reply box, the quick-reply
-- composer): completion-engine sources (lua/obelus/mention_blink.lua,
-- lua/obelus/mention_cmp.lua) when blink.cmp/nvim-cmp are present and
-- input.mention.completion allows it — the engine's own menu then owns "@"; else
-- typing "@" at a word boundary opens a file picker scoped to the project root and
-- the pick lands as a project-relative path right after the "@" (fzf-lua backend if
-- installed, else vim.ui.select over a plain file list).

local M = {}

local attached = {} -- buf -> true; M.attach never double-binds a buffer
local scheduled = {} -- buf -> true while a trigger is queued (cleared when it runs)
local ns = vim.api.nvim_create_namespace("obelus_mention")

local DEFAULT_CAP = 4000
local LIST_TIMEOUT_MS = 2000
local SKIP_DIRS = { [".git"] = true, [".hg"] = true, [".svn"] = true, ["node_modules"] = true }
local ITEMS_TTL_MS = 10000 -- engines re-query per keystroke; don't re-run fd every keypress
-- path characters allowed in a token after "@" (word chars, dot, slash, backslash,
-- hyphen, underscore, and ALL non-ASCII bytes — %w is byte-wise ASCII-only, and
-- without \128-\255 a single é/CJK char in a filename would stop the backward
-- token scan dead at its continuation byte, permanently closing the menu for that
-- mention) — matched against relative file paths, so no spaces here (a space
-- always ends a token; see M._escape for how a picked space survives).
local PATH_CHAR = "[%w%._/\\%-\128-\255]"

-- "@" starts a word: line start, or preceded by whitespace/"(" . col0 is the
-- 0-based column "@" is about to land at (BEFORE insertion) — the char just
-- before it is at 1-based index col0 in `line`.
local function is_boundary(line, col0)
  if col0 <= 0 then
    return true
  end
  local prev = line:sub(col0, col0)
  return prev:match("%s") ~= nil or prev == "("
end

-- One file-listing command, cwd=root, bounded synchronous wait. nil on a missing
-- binary/error/timeout — caller falls through to the next lister.
local function run_lister(cmd, root, timeout_ms)
  if vim.fn.executable(cmd[1]) ~= 1 then
    return nil
  end
  local ok, proc = pcall(vim.system, cmd, { cwd = root, text = true })
  if not ok or not proc then
    return nil
  end
  local ok2, res = pcall(function()
    return proc:wait(timeout_ms)
  end)
  if not ok2 or not res or res.code ~= 0 or not res.stdout then
    pcall(function()
      proc:kill(9)
    end)
    return nil
  end
  return vim.split(res.stdout, "\n", { trimempty = true })
end

-- Last-resort lister (no fd/rg/git on PATH): a capped scan skipping noise dirs.
local function walk_fs(root, cap)
  local uv = vim.uv or vim.loop
  local out, queue = {}, { "" }
  while #queue > 0 and #out < cap do
    local rel = table.remove(queue, 1)
    local fd = uv.fs_scandir(rel == "" and root or (root .. "/" .. rel))
    if fd then
      while #out < cap do
        local name, typ = uv.fs_scandir_next(fd)
        if not name then
          break
        end
        local rel2 = rel == "" and name or (rel .. "/" .. name)
        if typ == "directory" then
          -- bound the frontier too: `out` is capped, but a file-sparse tree could
          -- otherwise balloon the queue with dirs long before out ever fills
          if not SKIP_DIRS[name] and #queue < cap then
            queue[#queue + 1] = rel2
          end
        elseif typ == "file" then
          out[#out + 1] = rel2
        end
      end
    end
  end
  return out
end

-- Project file list relative to `root`, capped at `cap` (default 4000): fd, then
-- `rg --files`, then `git ls-files` (first one installed and answering in time),
-- else the capped walk above. Test seam — unit-tested directly against this repo.
-- Returns files, truncated (true when the cap actually cut the list).
function M._list_files(root, cap)
  cap = cap or DEFAULT_CAP
  local files = run_lister({ "fd", "--type", "f" }, root, LIST_TIMEOUT_MS)
    or run_lister({ "rg", "--files" }, root, LIST_TIMEOUT_MS)
    or run_lister({ "git", "ls-files" }, root, LIST_TIMEOUT_MS)
    or walk_fs(root, cap)
  local truncated = #files > cap
  if truncated then
    local capped = {}
    for i = 1, cap do
      capped[i] = files[i]
    end
    files = capped
  end
  return files, truncated
end

-- Escape spaces as `\ ` so a picked/completed path reads as one token when it
-- lands in the input buffer. Shared by the picker's insert_and_resume and the
-- blink/cmp adapters' textEdit.newText — label/filterText stay UNescaped (see
-- M._items) since those are for display/filtering, not insertion.
function M._escape(path)
  return (path:gsub(" ", "\\ "))
end

-- Async file listing for the completion path: fd → rg → git tried in sequence,
-- each via vim.system with an on_exit callback (NO :wait — this runs inside the
-- completion engine's per-keystroke request, where a synchronous multi-second
-- lister would freeze the whole editor); the capped walk runs last, scheduled
-- (it's local-fs bounded). `cb(files)` fires on the main loop exactly once.
-- Test seam — specs stub this wholesale for synchronous determinism.
function M._list_files_async(root, cb)
  local cmds = { { "fd", "--type", "f" }, { "rg", "--files" }, { "git", "ls-files" } }
  local function finish(files)
    if #files > DEFAULT_CAP then
      local capped = {}
      for i = 1, DEFAULT_CAP do
        capped[i] = files[i]
      end
      files = capped
    end
    cb(files)
  end
  local function try(i)
    local cmd = cmds[i]
    if not cmd then
      vim.schedule(function()
        finish(walk_fs(root, DEFAULT_CAP))
      end)
      return
    end
    if vim.fn.executable(cmd[1]) ~= 1 then
      return try(i + 1)
    end
    local ok = pcall(vim.system, cmd, { cwd = root, text = true, timeout = LIST_TIMEOUT_MS }, function(res)
      vim.schedule(function()
        if res.code == 0 and res.stdout then
          finish(vim.split(res.stdout, "\n", { trimempty = true }))
        else
          try(i + 1)
        end
      end)
    end)
    if not ok then
      try(i + 1)
    end
  end
  try(1)
end

-- LSP-shaped CompletionItem array for every project file under `root`, relative
-- paths as labels — the shared core both mention_blink.lua and mention_cmp.lua
-- build their per-request textEdit from (ranges depend on the request's cursor/@
-- position, so they're NOT baked in here). Cached per root with a ~10s TTL and
-- refreshed in the BACKGROUND: a cold or expired call serves what it has (stale
-- items, or none on the very first "@") and kicks off the async listing — both
-- adapters set is_incomplete, so the engine re-queries on the next keystroke and
-- picks up the fresh list. Never blocks the keystroke. Test seam: M._invalidate()
-- drops the cache.
local items_cache = {} -- root -> { items = CompletionItem[], at = uv.now(), refreshing = bool }

local function refresh_items(root)
  local hit = items_cache[root]
  if hit and hit.refreshing then
    return
  end
  items_cache[root] = { items = hit and hit.items or {}, at = hit and hit.at or 0, refreshing = true }
  M._list_files_async(root, function(files)
    local items = {}
    for i, f in ipairs(files) do
      items[i] = {
        label = f,
        kind = 17, -- LSP CompletionItemKind.File
        filterText = f,
      }
    end
    items_cache[root] = { items = items, at = (vim.uv or vim.loop).now(), refreshing = false }
  end)
end

function M._items(root)
  local now = (vim.uv or vim.loop).now()
  local hit = items_cache[root]
  if hit and not hit.refreshing and (now - hit.at) < ITEMS_TTL_MS then
    return hit.items
  end
  refresh_items(root)
  -- re-read: a synchronous lister stub (specs) — or a genuinely instant refresh —
  -- may have already landed; real async serves the stale/empty snapshot instead
  local hit2 = items_cache[root]
  return hit2 and hit2.items or {}
end

-- Test seam: force the next M._items call to re-list instead of serving the cache.
function M._invalidate()
  items_cache = {}
end

-- Scan back from `cursor_col0` (0-based, cursor's current column) for an "@" that
-- starts a word (is_boundary at the "@"'s own position) with only path characters
-- between it and the cursor. Returns `at_col0, prefix` (0-based column of "@", the
-- text typed after it so far) or nil when no such "@" is in scope — either there
-- isn't one, it's mid-word (foo@bar), or the token already ended (a space, or any
-- other non-path char, sits between the "@" and the cursor). Shared by the picker's
-- own trigger (implicitly, via is_boundary) and both completion-engine adapters,
-- which call this directly once per keystroke.
function M._at_token(line, cursor_col0)
  local i = cursor_col0 -- 1-based scan pointer: line:sub(i, i) is the char just left of it
  while i > 0 and line:sub(i, i):match(PATH_CHAR) do
    i = i - 1
  end
  if i <= 0 or line:sub(i, i) ~= "@" then
    return nil
  end
  local at_col0 = i - 1
  if not is_boundary(line, at_col0) then
    return nil
  end
  return at_col0, line:sub(i + 1, cursor_col0)
end

-- Fallback backend: vim.ui.select over M._list_files. `callback(relpath|nil)` —
-- nil on Esc/cancel.
local function pick_fallback(root, callback)
  local files, truncated = M._list_files(root)
  table.sort(files)
  local prompt = truncated and string.format("@ files (first %d)> ", DEFAULT_CAP) or "@ files> "
  vim.ui.select(files, { prompt = prompt }, function(choice)
    callback(choice)
  end)
end

-- fzf-lua backend: a `files` picker rooted at `root`, default styling (no winopts
-- beyond the prompt — the user's own fzf-lua config governs looks). entry_to_file
-- strips icons/ANSI and resolves the cwd-joined path; format.relpath turns that
-- back into the project-relative text we insert. `callback(relpath|nil)` on
-- select; Escape just closes fzf-lua (no action runs, so no callback either).
local function pick_fzf(fzf, root, callback)
  local ok_path, path_mod = pcall(require, "fzf-lua.path")
  fzf.files({
    cwd = root,
    prompt = "@ files> ",
    actions = {
      ["default"] = function(selected, opts)
        local entry = selected and selected[1]
        local file = (entry and ok_path) and path_mod.entry_to_file(entry, opts) or nil
        callback(file and file.path and require("obelus.format").relpath(file.path) or nil)
      end,
    },
  })
end

-- Backend resolution: fzf-lua if installed, else the built-in fallback. Test
-- seam — specs overwrite M._pick wholesale for a synchronous, deterministic
-- callback.
function M._pick(root, callback)
  local ok, fzf = pcall(require, "fzf-lua")
  if ok then
    return pick_fzf(fzf, root, callback)
  end
  return pick_fallback(root, callback)
end

-- Refocus the input window (if it's still around) and resume insert mode.
-- `cursor` ({row1, col0}) repositions the cursor first — omitted on cancel/stale
-- abort, which leave the cursor wherever it already was.
local function resume(win, cursor)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  vim.api.nvim_set_current_win(win)
  -- startinsert BEFORE the cursor set: in Normal mode nvim_win_set_cursor clamps
  -- the column to line-length-1 (no resting past the last char), which would
  -- land one short of "right after the inserted text" when it ends the line.
  vim.cmd("startinsert")
  if cursor then
    pcall(vim.api.nvim_win_set_cursor, win, cursor)
  end
end

-- Insert `relpath` right after the "@" the extmark anchors — the mark TRACKS the
-- "@" through any edits made while the picker was open (typing before it, lines
-- added above), so this can't splice at a stale offset or onto a DIFFERENT "@"
-- that merely landed at the same coordinates. If the anchored spot no longer
-- holds "@" (deleted), abort the insert but still refocus + resume insert — the
-- user picked a file and must not be stranded in another window in Normal mode.
-- Spaces in the path escape as `\ ` so it reads as one token.
local function insert_and_resume(buf, win, mark, relpath)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark, {})
  pcall(vim.api.nvim_buf_del_extmark, buf, ns, mark)
  if not relpath or relpath == "" then
    return resume(win) -- explicit cancel
  end
  local row0, col0 = pos[1], pos[2]
  if not row0 or row0 >= vim.api.nvim_buf_line_count(buf) then
    return resume(win)
  end
  local line = vim.api.nvim_buf_get_lines(buf, row0, row0 + 1, false)[1] or ""
  if line:sub(col0 + 1, col0 + 1) ~= "@" then
    return resume(win) -- the anchored "@" was deleted
  end
  local escaped = M._escape(relpath)
  vim.api.nvim_buf_set_text(buf, row0, col0 + 1, row0, col0 + 1, { escaped })
  resume(win, { row0 + 1, col0 + 1 + #escaped })
end

-- Scheduled right after a boundary "@" lands in the buffer. Runs AFTER the input
-- batch flushed: re-validates the recorded spot actually holds "@" (a same-batch
-- snapshot can be stale) and drops an extmark on it so the callback finds THIS
-- "@" wherever it drifts. `scheduled[buf]` is cleared here — set in the expr
-- callback — so 2+ boundary "@"s delivered in ONE batch (macro playback,
-- feedkeys-driven text) open ONE picker, not a stack whose callbacks would all
-- splice at the first "@".
local function trigger(buf, win, row0, col0)
  scheduled[buf] = nil
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local line = vim.api.nvim_buf_get_lines(buf, row0, row0 + 1, false)[1] or ""
  if line:sub(col0 + 1, col0 + 1) ~= "@" then
    return
  end
  -- default (right) gravity: text inserted AT or before the mark pushes it along,
  -- so it keeps pointing at this "@" char however the line shifts under the picker
  local mark = vim.api.nvim_buf_set_extmark(buf, ns, row0, col0, {})
  local root = require("obelus.store").root()
  M._pick(root, function(relpath)
    insert_and_resume(buf, win, mark, relpath)
  end)
end

-- The filetype obelus sets on every input buffer (panel.lua's docked reply box,
-- render.lua's compose float) — the ONE filetype both completion-engine sources
-- are scoped to.
M.FILETYPE = "obelus_reply"

-- Lazy, once-ever registration per engine (module-level: surviving across every
-- buffer's attach(), not per-buffer) — add_source_provider on the real blink.cmp
-- ASSERTS if the id already exists, so registering twice would error, not no-op.
local registered = { blink = false, cmp = false }

-- Test seam: specs that drive fake package.loaded["blink.cmp"]/["cmp"] modules
-- call this first so registration runs again against their fake.
function M._reset_engine()
  registered.blink = false
  registered.cmp = false
end

-- Register the obelus source with blink.cmp (once) and scope it to our filetype.
-- Returns true once blink.cmp is present and (already, or now) registered; false
-- if blink.cmp isn't installed. A registration failure (a stale "obelus" provider
-- left over from a prior, unreloaded setup — see the assert above) warns once and
-- reports false, same as "not installed" — either way the caller falls back to
-- the picker keymap.
local function register_blink()
  if registered.blink then
    return true
  end
  local ok, blink = pcall(require, "blink.cmp")
  if not ok then
    return false
  end
  -- a PRIOR registration can outlive this module (blink's registry lives in its
  -- own config; an obelus-only Lua reload resets `registered` but not blink) —
  -- add_source_provider asserts on a duplicate id, which would read as "failed"
  -- and bind the picker ALONGSIDE the still-active source. Already-there = done.
  local ok_cfg, blink_cfg = pcall(require, "blink.cmp.config")
  if ok_cfg and blink_cfg.sources and blink_cfg.sources.providers and blink_cfg.sources.providers.obelus then
    registered.blink = true
    return true
  end
  local ok2 = pcall(function()
    blink.add_source_provider("obelus", { name = "obelus", module = "obelus.mention_blink" })
    blink.add_filetype_source(M.FILETYPE, "obelus")
  end)
  if not ok2 then
    vim.notify_once(
      "obelus: failed to register the blink.cmp mention source — falling back to the @ picker",
      vim.log.levels.WARN
    )
    return false
  end
  registered.blink = true
  return true
end

-- Same shape as register_blink(), for nvim-cmp: cmp.register_source is itself
-- idempotent (last registration wins, no assert), but `registered.cmp` still
-- guards it — no reason to rebuild the source object and re-run setup.filetype
-- on every attach().
local function register_cmp()
  if registered.cmp then
    return true
  end
  local ok, cmp = pcall(require, "cmp")
  if not ok then
    return false
  end
  local ok2 = pcall(function()
    cmp.register_source("obelus", require("obelus.mention_cmp").new())
    cmp.setup.filetype(M.FILETYPE, { sources = { { name = "obelus" } } })
  end)
  if not ok2 then
    vim.notify_once(
      "obelus: failed to register the nvim-cmp mention source — falling back to the @ picker",
      vim.log.levels.WARN
    )
    return false
  end
  registered.cmp = true
  return true
end

-- Which completion engine (if any) serves "@" for this session, registering it
-- lazily the first time it resolves. `mention` is config.options.input.mention
-- ALREADY normalized to a table (config.lua turns true/false/table into that
-- shape — see normalize_mention there; this is never called with mention == false,
-- attach() short-circuits on that first). completion == false -> nil (no engine,
-- ever). "blink"/"cmp" force that engine, warning once + falling back to nil (so
-- the picker binds) when the plugin genuinely isn't present. "auto" tries blink
-- then cmp and is nil, SILENTLY, when neither is installed — that's the expected
-- everyday case (e.g. this repo's own headless test env), not a misconfiguration.
local function resolve_engine(mention)
  local completion = mention.completion
  if completion == false then
    return nil
  end
  if (completion == "blink" or completion == "auto") and register_blink() then
    return "blink"
  end
  if completion == "blink" then
    vim.notify_once(
      'obelus: input.mention.completion = "blink" but blink.cmp isn\'t installed — falling back to the @ picker',
      vim.log.levels.WARN
    )
    return nil
  end
  if (completion == "cmp" or completion == "auto") and register_cmp() then
    return "cmp"
  end
  if completion == "cmp" then
    vim.notify_once(
      'obelus: input.mention.completion = "cmp" but nvim-cmp isn\'t installed — falling back to the @ picker',
      vim.log.levels.WARN
    )
    return nil
  end
  return nil
end

-- Bind the insert-mode "@" mapping to `buf` (idempotent — never double-attaches).
-- No-op when config.input.mention is false. An <expr> mapping: "@" is ALWAYS
-- returned (so it's inserted like any normal char, mid-word "@"s included — the
-- mapping never eats it); the picker itself is scheduled after, only at a word
-- boundary, so it never fires for an email/`foo@bar`.
function M.attach(buf)
  if attached[buf] then
    return
  end
  local config = require("obelus.config")
  local mention = config.options.input.mention
  if mention == false then
    return
  end
  attached[buf] = true
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      attached[buf] = nil
      scheduled[buf] = nil
    end,
  })

  local engine = resolve_engine(mention)
  if engine then
    -- (no vim.b.completion override: blink only honors it when the user's global
    -- enabled() is ALSO true, and its default already admits our nofile buffers —
    -- a stricter user enabled() can't be overridden from here at all)
    return -- the engine's menu owns "@" — binding the picker too would be chaos
  end
  if mention.picker == false then
    return
  end

  vim.keymap.set("i", "@", function()
    local win = vim.api.nvim_get_current_win()
    local pos = vim.api.nvim_win_get_cursor(win)
    local row0, col0 = pos[1] - 1, pos[2]
    if is_boundary(vim.api.nvim_get_current_line(), col0) and not scheduled[buf] then
      scheduled[buf] = true
      vim.schedule(function()
        trigger(buf, win, row0, col0)
      end)
    end
    return "@"
  end, { buffer = buf, expr = true, silent = true })
end

return M
