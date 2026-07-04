-- @-file mentions: typing "@" at a word boundary in an obelus input buffer (the
-- docked reply box, the quick-reply composer) opens a file picker scoped to the
-- project root; the pick lands as a project-relative path right after the "@".
-- fzf-lua backend if installed, else vim.ui.select over a plain file list.

local M = {}

local attached = {} -- buf -> true; M.attach never double-binds a buffer
local scheduled = {} -- buf -> true while a trigger is queued (cleared when it runs)
local ns = vim.api.nvim_create_namespace("obelus_mention")

local DEFAULT_CAP = 4000
local LIST_TIMEOUT_MS = 2000
local SKIP_DIRS = { [".git"] = true, [".hg"] = true, [".svn"] = true, ["node_modules"] = true }

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
  local escaped = relpath:gsub(" ", "\\ ")
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
  if (config.options.input or {}).mention == false then
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
