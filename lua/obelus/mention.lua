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
-- always ends a token; see M._escape for how a picked space survives). ":" is
-- also allowed — needed for "@thread:<id>" tokens (see M._scan); harmless for a
-- real file path (colons are rare/invalid in one anyway), and the boundary rule
-- (is_boundary) still guards an email like foo@bar.com from ever triggering.
local PATH_CHAR = "[%w%._/\\%-:\128-\255]"

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

-- Native clipboard-image paste (keys.chat.paste_image, default <C-y>) --------
-- Grabs whatever IMAGE is on the system clipboard into a dest .png under
-- <root>/.ai/img and inserts an "@"-mention for it at the cursor — reference mode
-- (input.mention.send) then tells the agent to Read the file itself; inline mode
-- skips it outright (inline_block's NUL sniff treats any PNG as a binary file), so
-- an @'d screenshot can never blow up an inline-mode prompt either way.

local PASTE_WAIT_MS = 1500 -- an explicit one-off user action, not a hot path

local function file_nonempty(path)
  local st = (vim.uv or vim.loop).fs_stat(path)
  return st ~= nil and st.size > 0
end

-- Runs `cmd` (its own dest arg is baked in by the caller), bounded synchronous
-- wait — same wait/kill shape as run_lister above. Success = `dest` exists and is
-- non-empty afterward: the one check that covers every backend below, whether it
-- writes dest directly (pngpaste, osascript) or we pipe stdout to it ourselves.
local function run_and_check(cmd, dest, timeout_ms)
  if vim.fn.executable(cmd[1]) ~= 1 then
    return false
  end
  local ok, proc = pcall(vim.system, cmd, { text = true })
  if not ok or not proc then
    return false
  end
  local ok2, res = pcall(function()
    return proc:wait(timeout_ms)
  end)
  if not ok2 or not res then
    pcall(function()
      proc:kill(9)
    end)
    return false
  end
  return file_nonempty(dest)
end

-- Linux backends (wl-paste / xclip) write the PNG to STDOUT, not a dest arg —
-- capture it and write `dest` ourselves. `text = false`: this is binary data, not
-- something to decode/normalize as text.
local function run_stdout_to_file(cmd, dest, timeout_ms)
  if vim.fn.executable(cmd[1]) ~= 1 then
    return false
  end
  local ok, proc = pcall(vim.system, cmd, { text = false })
  if not ok or not proc then
    return false
  end
  local ok2, res = pcall(function()
    return proc:wait(timeout_ms)
  end)
  if not ok2 or not res or not res.stdout or res.stdout == "" then
    pcall(function()
      proc:kill(9)
    end)
    return false
  end
  local f = io.open(dest, "wb")
  if not f then
    return false
  end
  f:write(res.stdout)
  f:close()
  return file_nonempty(dest)
end

local function osascript_quote(s)
  return (s:gsub("\\", "\\\\"):gsub('"', '\\"'))
end

-- macOS fallback (no pngpaste installed): read the clipboard as «class PNGf» and
-- write it straight to `dest` via AppleScript's own file I/O, closing access in
-- either the success or the error path (never leaves the file handle open).
-- Verified for real on a dev machine — see the paste-narration report for the
-- exact command run and its result.
local function grab_osascript(dest, timeout_ms)
  if vim.fn.executable("osascript") ~= 1 then
    return false
  end
  local q = osascript_quote(dest)
  local script = table.concat({
    "try",
    "set pngData to the clipboard as «class PNGf»",
    'set outFile to open for access (POSIX file "' .. q .. '") with write permission',
    "set eof outFile to 0",
    "write pngData to outFile",
    "close access outFile",
    "on error errMsg",
    "try",
    'close access (POSIX file "' .. q .. '")',
    "end try",
    "error errMsg",
    "end try",
  }, "\n")
  local ok, proc = pcall(vim.system, { "osascript", "-e", script }, { text = true })
  if not ok or not proc then
    return false
  end
  pcall(function()
    proc:wait(timeout_ms)
  end)
  return file_nonempty(dest)
end

-- Clipboard IMAGE -> `dest` (parent dir must already exist). Backend chain, each
-- executable-gated: pngpaste, then the macOS osascript fallback, then Linux
-- wl-paste/xclip. Test seam — specs stub this wholesale for a deterministic paste.
function M._grab_clipboard_image(dest)
  return run_and_check({ "pngpaste", dest }, dest, PASTE_WAIT_MS)
    or grab_osascript(dest, PASTE_WAIT_MS)
    or run_stdout_to_file({ "wl-paste", "-t", "image/png" }, dest, PASTE_WAIT_MS)
    or run_stdout_to_file({ "xclip", "-selection", "clipboard", "-t", "image/png", "-o" }, dest, PASTE_WAIT_MS)
end

local img_seq = 0 -- disambiguates two pastes landing in the same wall-clock second

-- keys.chat.paste_image's handler (panel.lua's docked reply box + render.lua's
-- composer both bind this the same way, n+i). Grabs the clipboard image into
-- <root>/.ai/img/<timestamp>-<seq>.png and inserts "@<relpath> " at the cursor —
-- mention._scan will find the just-written file and highlight/validate it like any
-- other @mention. Works from Normal or Insert mode: records the mode BEFORE the
-- (synchronous, bounded) clipboard grab, inserts at the recorded cursor, and only
-- resumes insert if it started there.
function M.paste_image(opts)
  opts = opts or {}
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local was_insert = vim.fn.mode():match("^[iR]") ~= nil
  local pos = vim.api.nvim_win_get_cursor(win)
  local row0, col0 = pos[1] - 1, pos[2]

  local root = require("obelus.store").root()
  local dir = root .. "/.ai/img"
  local made = vim.fn.mkdir(dir, "p")
  if made ~= 1 and vim.fn.isdirectory(dir) ~= 1 then
    vim.notify("obelus: cannot create " .. dir .. " (permissions?)", vim.log.levels.ERROR)
    return
  end
  local stamp = os.date("%Y%m%d-%H%M%S")
  local dest, relpath
  local uv = vim.uv or vim.loop
  for _ = 1, 1000 do -- disambiguate same-second pastes; bounded so a stuck dir can't loop forever
    img_seq = img_seq + 1
    local name = stamp .. "-" .. img_seq .. ".png"
    local candidate = dir .. "/" .. name
    if uv.fs_stat(candidate) == nil then
      dest, relpath = candidate, name -- SHORT display: _scan resolves bare names via .ai/img
      break
    end
  end

  if not dest or not M._grab_clipboard_image(dest) then
    pcall(os.remove, dest) -- a failed backend may have left a zero-byte stub
    if not opts.silent then
      vim.notify("obelus: no image on the clipboard", vim.log.levels.INFO)
    end
    return false
  end
  if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_win_is_valid(win)) then
    return -- the input surface closed during the (bounded, synchronous) grab
  end

  local line = vim.api.nvim_buf_get_lines(buf, row0, row0 + 1, false)[1] or ""
  -- Insert mode: col0 IS the insertion gap. Normal mode: the cursor sits ON a
  -- character — insert AFTER it (mirrors normal-mode `p`), not before. AFTER THE
  -- CHARACTER, not after its first byte: col0+1 on a multibyte char (é/CJK/emoji)
  -- splices the mention MID-CHARACTER, corrupting the line's UTF-8.
  local insert_col
  if was_insert then
    insert_col = col0
  elseif #line == 0 then
    insert_col = 0
  else
    local ci = vim.fn.charidx(line, math.min(col0, #line - 1))
    local bi = ci >= 0 and vim.fn.byteidx(line, ci + 1) or -1
    insert_col = (bi >= 0) and bi or #line
  end
  local text = "@" .. M._escape(relpath) .. " "
  -- boundary guard: an @ glued to a word ("see@x.png") is a MID-WORD token the
  -- validator rightly rejects (renders white, not orange) — prefix a space when
  -- the char before the insertion point isn't already a boundary
  if insert_col > 0 then
    local prev = line:sub(insert_col, insert_col)
    if prev ~= "" and not prev:match("%s") and prev ~= "(" then
      text = " " .. text
    end
  end
  vim.api.nvim_buf_set_text(buf, row0, insert_col, row0, insert_col, { text })
  local new_col = insert_col + #text
  if was_insert then
    vim.api.nvim_win_set_cursor(win, { row0 + 1, new_col })
    vim.cmd("startinsert")
  else
    vim.api.nvim_win_set_cursor(win, { row0 + 1, math.max(new_col - 1, 0) })
  end
  return true
end

-- Outgoing-prompt rewrite: the input DISPLAYS short image mentions ("@x.png");
-- the AGENT needs the real path. Expand every valid short image mention in the
-- outgoing markdown to "@.ai/img/<name>" — applied once at the transport choke
-- point, before the mention send policy runs (which then sees the full path,
-- so reference notes and inline expansion both resolve).
function M.expand_image_mentions(text)
  if not text or text == "" or not text:find("@", 1, true) then
    return text
  end
  local lines = vim.split(text, "\n", { plain = true })
  local changed = false
  for i, line in ipairs(lines) do
    local ms = M._scan(line)
    for k = #ms, 1, -1 do -- right-to-left so earlier spans stay valid
      local m = ms[k]
      local span = line:sub(m[1] + 1, m[2])
      if not m[3]:find("/", 1, true) then
        -- plain root-level file: nothing to expand
      elseif span == "@" .. M._escape(m[3]:match("([^/]+)$") or "") and m[3]:sub(1, 8) == ".ai/img/" then
        line = line:sub(1, m[1]) .. "@" .. M._escape(m[3]) .. line:sub(m[2] + 1)
        changed = true
      end
    end
    if changed then
      lines[i] = line
    end
  end
  return changed and table.concat(lines, "\n") or text
end

-- keys.chat.paste_image (default <C-v>): the TUI paste gesture. IMAGE on the
-- clipboard -> save + @mention (paste_image above); otherwise fall back to a
-- normal TEXT paste of the + register, so <C-v> is simply "paste" in obelus
-- inputs — like other agent TUIs (a terminal can't deliver Cmd+V for images at
-- all: the terminal owns that key and only ever forwards TEXT via bracketed
-- paste, which nvim already handles natively — that path doesn't come through
-- here and keeps working).
function M.smart_paste()
  if M.paste_image({ silent = true }) then
    return
  end
  local text = vim.fn.getreg("+")
  if text and text ~= "" then
    vim.api.nvim_paste(text, true, -1)
  else
    vim.notify("obelus: clipboard is empty", vim.log.levels.INFO)
  end
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

-- One completion item per EXISTING thread — "@thread:<id>" mentions (M._scan
-- validates them, M.prompt_suffix expands a mentioned one to its full context).
-- label is what lands after "@" (thread:<id>, same shape a file path's label is —
-- both adapters splice `item.label` straight into textEdit.newText); filterText is
-- the rich fuzzy target (file/range/comment text, so you can find a thread by what
-- it's ABOUT, not just its opaque id); kind = 23 (LSP CompletionItemKind.Event) so
-- an engine's icon distinguishes it from a File (17) item. Computed fresh on every
-- call (no cache, unlike the file listing) — thread state (new/replied/resolved/
-- deleted) changes far more often than ITEMS_TTL_MS would tolerate, and this is
-- pure in-memory iteration, no I/O. The meta (project) thread itself is excluded:
-- mentioning it does nothing (M.prompt_suffix skips it), so it has no business
-- cluttering the picker. `root` must be the ACTIVE store's project (store.root())
-- — every real caller (M.prewarm, the picker, both completion adapters) always
-- passes exactly that, so this only ever excludes threads when it's asked about a
-- DIFFERENT project's file listing (a spec probing an arbitrary root, or a stale
-- cache entry left over from a project that's since been switched away from).
local function thread_items(root)
  local store = require("obelus.store")
  if root ~= store.root() then
    return {}
  end
  local format = require("obelus.format")
  local out = {}
  for _, c in ipairs(store.all()) do
    if not c.meta then
      local first = (vim.split(c.comment or "", "\n")[1] or ""):sub(1, 40)
      out[#out + 1] = {
        label = "thread:" .. c.id,
        kind = 23,
        filterText = string.format("%s %s %s thread:%s", format.relpath(c.file), format.range_label(c), first, c.id),
      }
    end
  end
  return out
end

-- file items (as cached/listed) + a fresh thread item per existing thread, as a
-- NEW list — never mutates `files` in place, since that table is the shared cache.
local function combine_items(files, root)
  local out = {}
  for i, f in ipairs(files) do
    out[i] = f
  end
  for _, t in ipairs(thread_items(root)) do
    out[#out + 1] = t
  end
  return out
end

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
      cb(combine_items(items, root))
    end
  end)
end

function M._items(root)
  local now = (vim.uv or vim.loop).now()
  local hit = items_cache[root]
  if hit and not hit.refreshing and (now - hit.at) < ITEMS_TTL_MS then
    return combine_items(hit.items, root)
  end
  refresh_items(root)
  -- re-read: a synchronous lister stub (specs) — or a genuinely instant refresh —
  -- may have already landed; real async serves the stale/empty snapshot instead
  local hit2 = items_cache[root]
  return combine_items(hit2 and hit2.items or {}, root)
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
    return cb(combine_items(hit.items, root))
  end
  if hit and #hit.items > 0 then
    refresh_items(root)
    return cb(combine_items(hit.items, root))
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
      local first_colon -- raw byte pos + unescaped length when the first ":" was eaten
      while j <= #line do
        local ch = line:sub(j, j)
        -- the "\ " pair must be checked FIRST: "\" alone also matches PATH_CHAR,
        -- which would eat the backslash bare and then break on the space —
        -- cutting "dir\ with space" down to the never-validating "dir\"
        if ch == "\\" and line:sub(j + 1, j + 1) == " " then
          raw[#raw + 1] = " "
          j = j + 2
        elseif ch:match(PATH_CHAR) then
          if ch == ":" and not first_colon then
            first_colon = { at = j, len = #raw } -- token state BEFORE this colon
          end
          raw[#raw + 1] = ch
          j = j + 1
        else
          break
        end
      end
      local path = table.concat(raw)
      -- "thread:<id>" is a SEPARATE mention grammar (see M._items/M.prompt_suffix):
      -- valid iff a comment with that exact id exists — bypasses the fs_stat check
      -- entirely (a thread id never names a real file). The whole "thread:<id>"
      -- token is the returned path, same as a file path is.
      local tid = path:match("^thread:(.+)$")
      local valid = tid and (require("obelus.store").get(tid) ~= nil) or (path ~= "" and stat_valid(root, path))
      -- SHORT image mentions: pasted images display as just "@<name>.png" — a
      -- slash-less token that exists under .ai/img resolves to its full path
      -- (highlighting + the send-time rewrite/expansion all see the real file).
      if not valid and path ~= "" and not tid and not path:find("/", 1, true) then
        if stat_valid(root, ".ai/img/" .. path) then
          out[#out + 1] = { col0, j - 1, ".ai/img/" .. path }
          valid = nil -- handled; skip the plain branch below
          path = ""
        end
      end
      if path ~= "" and valid then
        out[#out + 1] = { col0, j - 1, path }
      elseif first_colon and first_colon.len > 0 and not tid then
        -- ":" joined PATH_CHAR for thread tokens, which swallowed line-suffixed
        -- references like "@lua/foo.lua:12" whole and invalidated them (the file
        -- exists, "lua/foo.lua:12" doesn't). Fall back to the token UP TO the
        -- first colon — the common grep/LSP "path:line" paste keeps its mention.
        local base = table.concat(raw, "", 1, first_colon.len)
        if stat_valid(root, base) then
          out[#out + 1] = { col0, first_colon.at - 1, base }
        end
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
  content = content:gsub("\n$", "") -- files end with \n; avoid a blank line before the fence
  return head .. "\n" .. fence .. lang .. "\n" .. content .. "\n" .. fence, #content
end

-- "@thread:<id>" mentions ALWAYS expand to that thread's full serialization
-- (format.thread_full: comment_md + every conversation turn) — regardless of
-- input.mention.send, which governs FILE mentions only. This is how a resolved
-- thread's one-line summary in format.meta_context() gets pulled back in full,
-- from ANY chat, not just the project thread's. The meta (project) record itself
-- is never expandable this way (nothing to pull about itself) — skipped silently.
-- nil when none of `ids` names a real, non-meta thread.
local function thread_mentions_block(ids, expand_opts)
  local store = require("obelus.store")
  local format = require("obelus.format")
  local blocks = {}
  for _, id in ipairs(ids) do
    local c = store.get(id)
    if c and not c.meta then
      -- expand_opts.include_drafts: the SENDING context's draft policy — a tag
      -- meta's plain RESPOND promises member drafts stay unsent AND unseen; an
      -- explicit @thread pull-back must not smuggle the draft in through the
      -- side door (it still gets the "(has an unsent draft, not shown)" note)
      blocks[#blocks + 1] = format.thread_full(c, expand_opts)
    end
  end
  if #blocks == 0 then
    return nil
  end
  return "\n\n[Mentioned threads] full context for @thread:<id> mentions:\n\n" .. table.concat(blocks, "\n\n")
end

-- The prompt suffix implementing input.mention.send for an outgoing message:
--   "reference" (default) — one line telling the agent @paths are project-relative
--                           files to read (it runs with cwd = the project root)
--   "inline"              — [Mentioned files] + each unique mentioned file's
--                           contents, fenced; capped per-file and in total, with
--                           overflow falling back to the reference note
-- PLUS, independently of that knob: a "[Mentioned threads]" block for every
-- "@thread:<id>" mention (see thread_mentions_block above).
-- nil when the text has no valid mentions at all, or mentions are disabled outright.
function M.prompt_suffix(text, opts)
  local cfg = require("obelus.config").options.input.mention
  if cfg == false then
    return nil
  end
  local paths = M._mentioned_paths(text)
  if #paths == 0 then
    return nil
  end
  local file_paths, thread_ids = {}, {}
  for _, p in ipairs(paths) do
    local tid = p:match("^thread:(.+)$")
    if tid then
      thread_ids[#thread_ids + 1] = tid
    else
      file_paths[#file_paths + 1] = p
    end
  end
  local out = thread_mentions_block(thread_ids, opts and { include_drafts = opts.include_drafts }) or ""

  if #file_paths == 0 then
    return out ~= "" and out or nil
  end
  local note = '[Mentions] "@path" tokens are file paths relative to the project root — read them for context.'
  if cfg.send ~= "inline" then
    return out .. "\n\n" .. note
  end
  local root = require("obelus.store").root()
  local blocks, spent, overflow = {}, 0, {}
  for _, path in ipairs(file_paths) do
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
    return out .. "\n\n" .. note
  end
  local inlined = "\n\n[Mentioned files] contents of @-mentioned project files:\n\n" .. table.concat(blocks, "\n\n")
  if #overflow > 0 then
    inlined = inlined .. "\n\n(not inlined, read as needed: " .. table.concat(overflow, ", ") .. ")"
  end
  return out .. inlined
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
-- Cmd+V support (macOS terminals): the terminal can only forward TEXT — but
-- screenshot tools (CleanShot/Clop) put the image's FILE PATH on the clipboard
-- as text, so a Cmd+V paste lands an absolute "/…/Shot.png" string here.
-- Convert it: import the file into .ai/img (copy, dedup by name) and replace
-- the pasted path with a short "@<name>" mention. Runs from the same
-- TextChanged(I) hook as the highlight rescan; idempotent (once replaced, no
-- absolute path remains). Existence-gated, so half-typed paths never convert.
local IMAGE_EXT = { png = true, jpg = true, jpeg = true, gif = true, webp = true }

local function convert_pasted_image_paths(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, line in ipairs(lines) do
    if line:find("[~/]") and line:find("%.%w") then
      -- some tools paste a file:// URL: strip the scheme + percent-decode so
      -- the plain-path detector below sees a real filesystem path
      if line:find("file://", 1, true) then
        line = line:gsub("file://([^%s]+)", function(enc)
          return (enc:gsub("%%(%x%x)", function(h)
            return string.char(tonumber(h, 16))
          end))
        end)
        pcall(vim.api.nvim_buf_set_lines, buf, i - 1, i, false, { line })
      end
      local changed = false
      local search_from = 1
      while true do
        -- anchor on an image EXTENSION, then try candidate path starts
        -- longest-first ("/" or "~" positions before it) with an existence
        -- check — paths contain interior dots ("nvim.lpleahy/…") and spaces
        -- (CleanShot names), so start-anchored patterns misparse them
        local es, ee, ext = line:find("%.(%w+)", search_from)
        if not es then
          break
        end
        search_from = ee + 1
        if IMAGE_EXT[ext:lower()] then
          for st = 1, es - 1 do
            local ch = line:sub(st, st)
            if (ch == "/" or ch == "~") and (st == 1 or line:sub(st - 1, st - 1) ~= "") then
              local cand = line:sub(st, ee)
              local abs = vim.fn.fnamemodify(cand, ":p")
              if vim.fn.filereadable(abs) == 1 then
                local root = require("obelus.store").root()
                local dir = root .. "/.ai/img"
                vim.fn.mkdir(dir, "p")
                -- sanitize: CleanShot-style names carry spaces and "@2x" — an
                -- "@" inside a mention token CUTS it (PATH_CHAR excludes @) and
                -- spaces need escaping; normalize both away on import
                local base = vim.fn.fnamemodify(abs, ":t"):gsub("[%s@]+", "-"):gsub("%-+", "-")
                local dest, name = dir .. "/" .. base, base
                local uv = vim.uv or vim.loop
                local n = 1
                while uv.fs_stat(dest) ~= nil and n < 100 do
                  n = n + 1
                  name = vim.fn.fnamemodify(base, ":r") .. "-" .. n .. "." .. ext
                  dest = dir .. "/" .. name
                end
                if uv.fs_copyfile(abs, dest) then
                  local mtext = "@" .. M._escape(name)
                  line = line:sub(1, st - 1) .. mtext .. line:sub(ee + 1)
                  pcall(vim.api.nvim_buf_set_lines, buf, i - 1, i, false, { line })
                  local win = vim.api.nvim_get_current_win()
                  if vim.api.nvim_win_get_buf(win) == buf then
                    local pos = vim.api.nvim_win_get_cursor(win)
                    if pos[1] == i and pos[2] >= ee then
                      pcall(vim.api.nvim_win_set_cursor, win, { i, pos[2] - (ee - st + 1) + #mtext })
                    end
                  end
                  search_from = st + #mtext
                  changed = true
                end
                break -- longest candidate that exists wins; stop trying shorter
              end
            end
          end
        end
      end
      if changed then
        lines[i] = line
      end
    end
  end
end

local function rescan_mentions(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  convert_pasted_image_paths(buf)
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
