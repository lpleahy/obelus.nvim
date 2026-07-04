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
local hl_ns = vim.api.nvim_create_namespace("obelus_mention_hl") -- live VALID-mention highlight, separate from `ns` (the picker's anchor marks) so clearing one never touches the other

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
-- before it is at 1-based index col0 in `line`. `edge_prev` overrides the
-- col0<=0 "always a boundary" default with a real check against that single
-- character — thread.lua's mention post-pass scans one md_chunks CHUNK at a
-- time, so col0==0 there means "start of this chunk", not "start of the line";
-- it passes the previous chunk's last byte (nil only at the true line start).
local function is_boundary(line, col0, edge_prev)
  if col0 <= 0 then
    if edge_prev == nil then
      return true
    end
    return edge_prev:match("%s") ~= nil or edge_prev == "("
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
local items_waiters = {} -- root -> { cb, ... } callbacks parked on the in-flight refresh

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
    local parked = items_waiters[root]
    items_waiters[root] = nil
    for _, cb in ipairs(parked or {}) do
      cb(items)
    end
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

-- Async variant for the completion adapters: `cb(items)` fires exactly once —
-- immediately when the cache can answer (fresh, OR stale-but-nonempty: snappy
-- menu now, the background refresh lands for the next keystroke), else parked on
-- the in-flight refresh. This is what makes the menu pop on the VERY FIRST "@"
-- of a session: the old sync path answered a cold cache with zero items, so
-- blink showed nothing until the next typed character re-queried.
function M._items_async(root, cb)
  local now = (vim.uv or vim.loop).now()
  local hit = items_cache[root]
  if hit and not hit.refreshing and (now - hit.at) < ITEMS_TTL_MS then
    return cb(hit.items)
  end
  if hit and #hit.items > 0 then
    refresh_items(root)
    return cb(hit.items)
  end
  local w = items_waiters[root]
  if w then
    w[#w + 1] = cb
  else
    items_waiters[root] = { cb }
  end
  refresh_items(root)
  -- a synchronous lister (spec stub) has already flushed the waiters by now
end

-- Warm the file-list cache for this project — called when an input buffer opens,
-- so the first "@" almost always answers instantly instead of waiting on fd.
function M.prewarm()
  local ok, root = pcall(function()
    return require("obelus.store").root()
  end)
  if ok and root then
    local hit = items_cache[root]
    if not (hit and (((vim.uv or vim.loop).now() - hit.at) < ITEMS_TTL_MS)) then
      refresh_items(root)
    end
  end
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

-- Validation cache: fs_stat is cheap but M._scan reruns on every TextChanged(I)
-- (per keystroke) and again per render fill — a short TTL avoids re-stat'ing the
-- same path dozens of times a second while still picking up a file that
-- appears/disappears within a few seconds. Keyed on (root, path) since the same
-- relative path can validate differently across projects/roots.
local STAT_TTL_MS = 5000
local stat_cache = {} -- "root\0path" -> { ok = bool, at = uv.now() }

local function stat_valid(root, path)
  local uv = vim.uv or vim.loop
  local key = root .. "\0" .. path
  local now = uv.now()
  local hit = stat_cache[key]
  if hit and (now - hit.at) < STAT_TTL_MS then
    return hit.ok
  end
  local ok = uv.fs_stat(root .. "/" .. path) ~= nil
  stat_cache[key] = { ok = ok, at = now }
  return ok
end

-- Test seam: drop every cached stat result so the next M._scan re-checks the
-- filesystem instead of serving a (possibly now-stale) cached verdict.
function M._scan_invalidate()
  stat_cache = {}
end

-- Every VALID @mention in `line`: an "@" at an is_boundary position, followed by a
-- run of PATH_CHAR bytes where a "\ " pair continues the token (unescaped to a
-- plain space in the returned path — the reverse of M._escape) — same grammar
-- M._at_token scans backward for while typing, but this scans forward over
-- FINISHED text and additionally requires the token to name a real file/dir
-- under the project root. `edge_prev` is forwarded to is_boundary — nil (the
-- default) for a real line; thread.lua's per-chunk post-pass passes the
-- preceding chunk's last byte when scanning a chunk that isn't the line's start.
-- Returns an array of { start_col0, end_col0_excl, path } (0-based, exclusive
-- end — a plain vim.api.nvim_buf_set_extmark/string.sub range), earliest first,
-- with no overlap (a token never contains another "@" — PATH_CHAR excludes it).
function M._scan(line, edge_prev)
  local root = require("obelus.store").root()
  local out = {}
  local pos = 1
  while true do
    local at1 = line:find("@", pos, true)
    if not at1 then
      break
    end
    pos = at1 + 1
    local col0 = at1 - 1
    if is_boundary(line, col0, edge_prev) then
      local j = at1 + 1
      local raw = {}
      while j <= #line do
        local ch = line:sub(j, j)
        -- the "\ " pair must be checked FIRST: "\" alone also matches PATH_CHAR,
        -- which would eat the backslash bare and then break on the space —
        -- cutting "dir\ with space" down to the never-validating "dir\"
        if ch == "\\" and line:sub(j + 1, j + 1) == " " then
          raw[#raw + 1] = " "
          j = j + 2
        elseif ch:match(PATH_CHAR) then
          raw[#raw + 1] = ch
          j = j + 1
        else
          break
        end
      end
      local path = table.concat(raw)
      if path ~= "" and stat_valid(root, path) then
        out[#out + 1] = { col0, j - 1, path }
      end
    end
  end
  return out
end

-- True if any line of `text` (a full message, possibly multi-line) has at least
-- one valid mention — used by transport/init.lua to decide whether an outgoing
-- prompt needs the "@paths are real files" note.
function M._has_mention(text)
  if not text or text == "" then
    return false
  end
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    if #M._scan(line) > 0 then
      return true
    end
  end
  return false
end

-- Every unique valid mentioned path across `text`, first-appearance order.
function M._mentioned_paths(text)
  local seen, out = {}, {}
  if not text or text == "" then
    return out
  end
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    for _, m in ipairs(M._scan(line)) do
      if not seen[m[3]] then
        seen[m[3]] = true
        out[#out + 1] = m[3]
      end
    end
  end
  return out
end

-- inline-mode caps: a mention is a deliberate ask, so the budget is generous, but
-- an @'d lockfile or generated blob must not blow the whole prompt
local INLINE_MAX_FILE = 32 * 1024 -- bytes per file (truncated at the last full line)
local INLINE_MAX_TOTAL = 128 * 1024 -- bytes across all inlined files (rest fall back to a reference)

local function fence_for(content)
  local run = 2
  for ticks in content:gmatch("`+") do
    run = math.max(run, #ticks)
  end
  return string.rep("`", math.max(3, run + 1))
end

-- One file's inline block: "@path:" + a fenced, possibly-truncated dump; nil body
-- for directories (browse) and binaries (NUL sniff) — those get a one-line note.
local function inline_block(root, path)
  local uv = vim.uv or vim.loop
  local st = uv.fs_stat(root .. "/" .. path)
  if st and st.type == "directory" then
    return "@" .. path .. ": (directory — browse it as needed)", 0
  end
  local f = io.open(root .. "/" .. path, "rb")
  if not f then
    return nil, 0
  end
  local content = f:read(INLINE_MAX_FILE + 1) or ""
  f:close()
  if content:find("\0", 1, true) then
    return "@" .. path .. ": (binary file — skipped)", 0
  end
  local truncated = #content > INLINE_MAX_FILE
  if truncated then
    content = content:sub(1, INLINE_MAX_FILE)
    content = content:match("^(.*)\n[^\n]*$") or content -- cut back to the last full line
  end
  local lang = path:match("%.([%w_]+)$") or ""
  local fence = fence_for(content)
  local head = "@" .. path .. (truncated and " (truncated):" or ":")
  return head .. "\n" .. fence .. lang .. "\n" .. content .. "\n" .. fence, #content
end

-- The prompt suffix implementing input.mention.send for an outgoing message:
--   "reference" (default) — one line telling the agent @paths are project-relative
--                           files to read (it runs with cwd = the project root)
--   "inline"              — [Mentioned files] + each unique mentioned file's
--                           contents, fenced; capped per-file and in total, with
--                           overflow falling back to the reference note
-- nil when the text has no valid mentions or mentions are disabled outright.
function M.prompt_suffix(text)
  local cfg = require("obelus.config").options.input.mention
  if cfg == false then
    return nil
  end
  local paths = M._mentioned_paths(text)
  if #paths == 0 then
    return nil
  end
  local note = '[Mentions] "@path" tokens are file paths relative to the project root — read them for context.'
  if cfg.send ~= "inline" then
    return "\n\n" .. note
  end
  local root = require("obelus.store").root()
  local blocks, spent, overflow = {}, 0, {}
  for _, path in ipairs(paths) do
    if spent >= INLINE_MAX_TOTAL then
      overflow[#overflow + 1] = "@" .. path
    else
      local block, bytes = inline_block(root, path)
      if block then
        blocks[#blocks + 1] = block
        spent = spent + bytes
      end
    end
  end
  if #blocks == 0 then
    return "\n\n" .. note
  end
  local out = "\n\n[Mentioned files] contents of @-mentioned project files:\n\n" .. table.concat(blocks, "\n\n")
  if #overflow > 0 then
    out = out .. "\n\n(not inlined, read as needed: " .. table.concat(overflow, ", ") .. ")"
  end
  return out
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

-- Re-highlight every VALID mention in `buf` (ObelusMention over each "@path"
-- span, row-wise). Clears + rebuilds the whole namespace on every call — input
-- buffers are a handful of lines, so a full rescan per TextChanged(I) is cheap
-- (M._scan's stat cache absorbs the repeat fs_stat calls across keystrokes).
local function rescan_mentions(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, line in ipairs(lines) do
    for _, m in ipairs(M._scan(line)) do
      pcall(vim.api.nvim_buf_set_extmark, buf, hl_ns, i - 1, m[1], {
        end_col = m[2],
        hl_group = "ObelusMention",
      })
    end
  end
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

  -- live VALID-mention highlight — independent of the engine/picker branch below
  -- (blink/cmp own completion, but nobody else styles finished "@path" text).
  -- No BufWipeout teardown needed: hl_ns extmarks die with the buffer.
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = function()
      rescan_mentions(buf)
    end,
  })
  rescan_mentions(buf) -- once immediately: a restored draft may already have mentions

  local engine = resolve_engine(mention)
  if engine then
    -- (no vim.b.completion override: blink only honors it when the user's global
    -- enabled() is ALSO true, and its default already admits our nofile buffers —
    -- a stricter user enabled() can't be overridden from here at all)
    M.prewarm() -- list the project NOW so the first "@" answers instantly
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
