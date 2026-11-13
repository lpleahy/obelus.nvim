-- Runs INSIDE each child `nvim --embed` (loaded by tests/ui/run.lua via
-- nvim_exec_lua + dofile). Two jobs:
--   boot(opts)  — pin everything that could make a render vary between runs or
--                 machines (clock, colorscheme/background, notify, option defaults)
--                 and put obelus + the test fixtures on the path.
--   capture()   — read back what the user sees: the composed screen grid (text +
--                 per-cell attr ids, resolved to colours by the parent from the
--                 UI's hl_attr_define table), every window's geometry/options,
--                 every extmark in every displayed buffer, and the resolved
--                 attributes of every highlight group those reference.
-- Nothing here touches lua/obelus: the clock stub and the vim.notify recorder are
-- process-global test doubles installed before obelus loads.
-- containment first (tests/xdg_guard.lua): this child inherits the run's env
dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/xdg_guard.lua")("tests/ui/child.lua")

local C = {}

-- 2026-01-01T00:00:00Z. Obelus stamps ids/turns with os.time(); none of it is
-- rendered today, but a fixed clock keeps any future "N min ago" byte-stable too.
C.EPOCH = 1767225600

local scrubs = {} -- { from, to } literal replacements applied to every string we emit

local function scrub(s)
  if type(s) ~= "string" then
    return s
  end
  for _, p in ipairs(scrubs) do
    s = s:gsub(vim.pesc(p[1]), (p[2]:gsub("%%", "%%%%")))
  end
  return s
end

function C.boot(opts)
  local real_time, real_date = os.time, os.date
  os.time = function(t)
    if t then
      return real_time(t)
    end
    return C.EPOCH
  end
  os.date = function(fmt, t)
    return real_date(fmt, t or C.EPOCH)
  end

  -- the repo root (obelus itself) + tests/ (helpers.lua, fake.lua) + tests/ui/
  vim.opt.runtimepath:append(opts.repo)
  package.path = table.concat({
    opts.repo .. "/tests/?.lua",
    opts.repo .. "/tests/ui/?.lua",
    package.path,
  }, ";")

  -- longest first so a root nested in TMPDIR is replaced whole
  local roots = { opts.root, vim.uv.fs_realpath(opts.root) or opts.root }
  for _, r in ipairs(roots) do
    scrubs[#scrubs + 1] = { r, "<ROOT>" }
  end
  if opts.tmp then
    scrubs[#scrubs + 1] = { vim.uv.fs_realpath(opts.tmp) or opts.tmp, "<TMP>" }
    scrubs[#scrubs + 1] = { opts.tmp, "<TMP>" }
  end
  table.sort(scrubs, function(a, b)
    return #a[1] > #b[1]
  end)

  -- notifications are recorded (and serialized), never drawn: a long one would
  -- otherwise raise a hit-enter prompt that blocks the RPC request
  C.notes = {}
  vim.notify = function(msg, level)
    C.notes[#C.notes + 1] = string.format("[%s] %s", tostring(level or "-"), scrub(tostring(msg)))
  end

  -- source paths of Lua callbacks are serialized relative to these
  scrubs[#scrubs + 1] = { opts.repo, "<REPO>" }
  scrubs[#scrubs + 1] = { vim.env.VIMRUNTIME, "<VIMRUNTIME>" }
  table.sort(scrubs, function(a, b)
    return #a[1] > #b[1]
  end)

  C.install_virtual_clock()

  -- user-command callbacks are not exposed by nvim_get_commands(): record them at
  -- creation (a process-global test double, like vim.notify above) so a command
  -- whose callback is swapped under an unchanged description still diffs
  C.cmd_cb = {}
  local create_cmd = vim.api.nvim_create_user_command
  vim.api.nvim_create_user_command = function(name, cmd, o)
    C.cmd_cb[name] = cmd
    return create_cmd(name, cmd, o)
  end

  vim.o.shortmess = vim.o.shortmess .. "I"
  vim.o.swapfile = false
  vim.o.termguicolors = true
  vim.o.background = "dark"
  vim.cmd.colorscheme("default")
  vim.o.background = "dark"

  -- the full editor state BEFORE obelus loads (Neovim's own defaults included), so
  -- the registration snapshot can diff what loading + setup() added, changed or
  -- removed — taken last, after the harness's own settings above
  C.pre = C.registry_state()
end

-- ── virtual clock ───────────────────────────────────────────────────────────
-- Every timer and every vim.schedule callback in the child runs on a VIRTUAL
-- clock that only the harness advances, so no amount of host load or parent delay
-- can change what is on screen at capture time:
--   * vim.uv.new_timer() (and so vim.defer_fn, which builds on it) returns a fake
--     timer that never fires by itself;
--   * vim.schedule() (and so vim.schedule_wrap) appends to a FIFO queue;
--   * vim.uv.now() returns the virtual time (0 unless advanced).
-- C.settle() drains the queue and fires due timers (earliest due first, ties in
-- start order) until nothing is runnable at the current virtual time. A timer due
-- later — e.g. progress.finish's 2000 ms ✓ clear, or the spinner's next tick —
-- stays pending until C.advance(ms) moves the clock; captures never advance it.
-- These are process-global test doubles installed before obelus loads; lua/ is
-- untouched.
local V = { now = 0, seq = 0, timers = {}, queue = {} }
C.V = V

local Timer = {}
Timer.__index = Timer
function Timer:start(timeout, rep, cb)
  V.seq = V.seq + 1
  self.due, self.rep, self.cb, self.order, self.active = V.now + (timeout or 0), rep or 0, cb, V.seq, true
  V.timers[self] = true
  return 0
end
function Timer:stop()
  self.active = false
  V.timers[self] = nil
  return 0
end
function Timer:close(cb)
  self:stop()
  self.closing = true
  if cb then
    cb()
  end
end
function Timer:again()
  if (self.rep or 0) > 0 then
    self:start(self.rep, self.rep, self.cb)
  end
  return 0
end
function Timer:is_active()
  return self.active == true
end
function Timer:is_closing()
  return self.closing == true
end
function Timer:set_repeat(r)
  self.rep = r
end
function Timer:get_repeat()
  return self.rep or 0
end
function Timer:get_due_in()
  return math.max(0, (self.due or V.now) - V.now)
end

function C.install_virtual_clock()
  vim.uv.new_timer = function()
    return setmetatable({}, Timer)
  end
  vim.uv.now = function()
    return V.now
  end
  vim.schedule = function(fn)
    V.queue[#V.queue + 1] = fn
  end
end

local function next_due(limit)
  local best
  for t in pairs(V.timers) do
    if t.due <= limit and (not best or t.due < best.due or (t.due == best.due and t.order < best.order)) then
      best = t
    end
  end
  return best
end

local function fire(t)
  if (t.rep or 0) > 0 then
    V.seq = V.seq + 1
    t.due, t.order = t.due + t.rep, V.seq
  else
    t:stop()
  end
  t.cb()
end

-- Run everything runnable at the current virtual time, to quiescence. Errors in a
-- callback propagate (Neovim would have shown them as an error message).
function C.settle()
  for _ = 1, 100000 do
    if #V.queue > 0 then
      local q = V.queue
      V.queue = {}
      for _, fn in ipairs(q) do
        fn()
      end
    else
      local t = next_due(V.now)
      if not t then
        return true
      end
      fire(t)
    end
  end
  error("settle: deferred work never quiesced (a callback keeps rescheduling itself)")
end

-- Move the virtual clock forward `ms`, firing timers in due order (settling at
-- each step). Not used by today's scenarios; there for stepping spinner frames.
function C.advance(ms)
  local target = V.now + ms
  C.settle()
  while true do
    local t = next_due(target)
    if not t then
      break
    end
    V.now = math.max(V.now, t.due)
    fire(t)
    C.settle()
  end
  V.now = target
  C.settle()
end

-- deterministic, sorted-key serialization of any Lua value on one line
local function ser(v)
  local t = type(v)
  if v == vim.NIL or v == nil then
    return "nil"
  elseif t == "string" then
    return string.format("%q", scrub(v)):gsub("\\\n", "\\n")
  elseif t == "number" then
    if v == math.floor(v) then
      return string.format("%d", v)
    end
    return string.format("%.6g", v)
  elseif t == "boolean" then
    return tostring(v)
  elseif t == "table" then
    if vim.islist(v) and (#v > 0 or getmetatable(v) == nil) then
      local parts = {}
      for _, x in ipairs(v) do
        parts[#parts + 1] = ser(x)
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = vim.tbl_keys(v)
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    local parts = {}
    for _, k in ipairs(keys) do
      parts[#parts + 1] = tostring(k) .. "=" .. ser(v[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "<" .. t .. ">"
end
C.ser = ser

local HL_KEYS = { "fg", "bg", "sp", "bold", "italic", "underline", "undercurl", "underdouble", "underdotted" }
vim.list_extend(HL_KEYS, { "underdashed", "strikethrough", "reverse", "standout", "nocombine", "blend", "default" })

local function hex(n)
  return string.format("#%06x", n)
end

-- "Group: fg=#.. bg=#.. bold [-> Link]" — resolved (link=false) attributes plus the
-- direct link target, so both a colour change and a re-link show up
local function describe_hl(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false, create = false })
  if not ok then
    return name .. ": <error>"
  end
  local parts = {}
  for _, k in ipairs(HL_KEYS) do
    local v = hl[k]
    if v ~= nil then
      if k == "fg" or k == "bg" or k == "sp" then
        parts[#parts + 1] = k .. "=" .. hex(v)
      elseif v == true then
        parts[#parts + 1] = k
      else
        parts[#parts + 1] = k .. "=" .. tostring(v)
      end
    end
  end
  local lok, raw = pcall(vim.api.nvim_get_hl, 0, { name = name, create = false })
  local link = lok and raw and raw.link and (" -> " .. raw.link) or ""
  if next(hl) == nil and link == "" then
    return name .. ": <cleared>"
  end
  return name .. ": " .. table.concat(parts, " ") .. link
end
C.describe_hl = describe_hl

local function add_group(set, g)
  if type(g) == "string" and g ~= "" then
    set[g] = true
  elseif type(g) == "table" then -- a list of groups (stacked hl in a chunk)
    for _, x in ipairs(g) do
      add_group(set, x)
    end
  end
end

local function chunks_groups(set, chunks)
  for _, ch in ipairs(chunks or {}) do
    if type(ch) == "table" then
      add_group(set, ch[2])
    end
  end
end

local WIN_OPTS = {
  "winhighlight",
  "winblend",
  "wrap",
  "linebreak",
  "conceallevel",
  "concealcursor",
  "signcolumn",
  "number",
  "relativenumber",
  "numberwidth",
  "foldcolumn",
  "statuscolumn",
  "cursorline",
  "list",
  "spell",
  "smoothscroll",
  "fillchars",
  "scrolloff",
  "sidescrolloff",
}
local BUF_OPTS = { "filetype", "buftype", "modifiable", "bufhidden" }

local function buf_label(b)
  local name = vim.api.nvim_buf_get_name(b)
  if name == "" then
    return "[scratch]"
  end
  return scrub(vim.fn.fnamemodify(name, ":."))
end

-- every window, in a refactor-stable order: splits by screen position, then floats
-- by zindex / position (window HANDLES are not part of the snapshot)
local function ordered_wins()
  local wins = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local cfg = vim.api.nvim_win_get_config(w)
    local pos = vim.fn.win_screenpos(w)
    wins[#wins + 1] = {
      win = w,
      float = cfg.relative ~= nil and cfg.relative ~= "",
      z = cfg.zindex or 0,
      row = pos[1],
      col = pos[2],
      cfg = cfg,
    }
  end
  table.sort(wins, function(a, b)
    if a.float ~= b.float then
      return not a.float
    end
    if a.z ~= b.z then
      return a.z < b.z
    end
    if a.row ~= b.row then
      return a.row < b.row
    end
    if a.col ~= b.col then
      return a.col < b.col
    end
    return a.win < b.win
  end)
  return wins
end

local function ns_names()
  local m = {}
  for name, id in pairs(vim.api.nvim_get_namespaces()) do
    m[id] = name
  end
  return m
end

-- extmark details minus volatile/handle fields, namespace by NAME
local function extmark_line(nsmap, m)
  local d = vim.deepcopy(m[4] or {})
  local nsname = nsmap[d.ns_id] or ("ns#" .. tostring(d.ns_id))
  d.ns_id = nil
  return nsname, string.format("%d:%d %s", m[2], m[3], ser(d))
end

local diff_entries -- defined with the registration helpers below

---@return table raw capture; the parent resolves attr ids and writes the file
function C.capture()
  C.settle()
  vim.cmd("redraw!")
  local rows, cols = vim.o.lines, vim.o.columns
  local text, attrs = {}, {}
  for r = 1, rows do
    local t, a = {}, {}
    for c = 1, cols do
      t[#t + 1] = vim.fn.screenstring(r, c)
      a[#a + 1] = vim.fn.screenattr(r, c)
    end
    text[r] = scrub(table.concat(t))
    attrs[r] = a
  end

  local out = {}
  local function push(s)
    out[#out + 1] = s
  end
  local groups = {}

  local wins = ordered_wins()
  local label = {}
  for i, w in ipairs(wins) do
    label[w.win] = "W" .. i
  end
  local cur = vim.api.nvim_get_current_win()
  push("## cursor")
  push(
    string.format(
      "win=%s mode=%s pos=%s screen=%d,%d",
      label[cur] or "?",
      vim.api.nvim_get_mode().mode,
      ser(vim.api.nvim_win_get_cursor(cur)),
      vim.fn.screenrow(),
      vim.fn.screencol()
    )
  )

  push("## windows")
  local bufs, buf_order = {}, {}
  for _, w in ipairs(wins) do
    local b = vim.api.nvim_win_get_buf(w.win)
    if not bufs[b] then
      bufs[b] = "B" .. (#buf_order + 1)
      buf_order[#buf_order + 1] = b
    end
    local info = vim.fn.getwininfo(w.win)[1] or {}
    push(
      string.format(
        "%s %s buf=%s(%s) screenpos=%d,%d size=%dx%d topline=%d textoff=%d",
        label[w.win],
        w.float and "float" or "split",
        bufs[b],
        buf_label(b),
        w.row,
        w.col,
        vim.api.nvim_win_get_width(w.win),
        vim.api.nvim_win_get_height(w.win),
        info.topline or -1,
        info.textoff or -1
      )
    )
    if w.float then
      local c = w.cfg
      local keep = {}
      for _, k in ipairs({ "relative", "anchor", "row", "col", "zindex", "border", "style", "focusable" }) do
        keep[k] = c[k]
      end
      for _, k in ipairs({ "title", "title_pos", "footer", "footer_pos", "hide", "mouse", "fixed" }) do
        keep[k] = c[k]
      end
      if c.relative == "win" then
        keep.win = label[c.win] or "?"
      end
      chunks_groups(groups, type(c.title) == "table" and c.title or nil)
      chunks_groups(groups, type(c.footer) == "table" and c.footer or nil)
      push("  cfg " .. ser(keep))
    end
    local o = {}
    for _, k in ipairs(WIN_OPTS) do
      o[k] = vim.wo[w.win][k]
    end
    push("  wo " .. ser(o))
    for pair in (vim.wo[w.win].winhighlight or ""):gmatch("[^,]+") do
      local from, to = pair:match("^([^:]+):(.+)$")
      add_group(groups, from)
      add_group(groups, to)
    end
  end

  push("## buffers")
  local nsmap = ns_names()
  for _, b in ipairs(buf_order) do
    local bo = {}
    for _, k in ipairs(BUF_OPTS) do
      bo[k] = vim.bo[b][k]
    end
    push(string.format("%s %s lines=%d %s", bufs[b], buf_label(b), vim.api.nvim_buf_line_count(b), ser(bo)))
  end

  push("## extmarks")
  for _, b in ipairs(buf_order) do
    local marks = vim.api.nvim_buf_get_extmarks(b, -1, 0, -1, { details = true })
    local by_ns = {}
    for _, m in ipairs(marks) do
      local d = m[4] or {}
      for _, k in ipairs({ "hl_group", "line_hl_group", "sign_hl_group", "number_hl_group", "cursorline_hl_group" }) do
        add_group(groups, d[k])
      end
      chunks_groups(groups, d.virt_text)
      for _, vl in ipairs(d.virt_lines or {}) do
        chunks_groups(groups, vl)
      end
      local nsname, line = extmark_line(nsmap, m)
      by_ns[nsname] = by_ns[nsname] or {}
      table.insert(by_ns[nsname], line)
    end
    local names = vim.tbl_keys(by_ns)
    table.sort(names)
    for _, n in ipairs(names) do
      push(string.format("%s ns=%s (%d)", bufs[b], n, #by_ns[n]))
      for _, l in ipairs(by_ns[n]) do -- already in (row, col, id) order from the API
        push("  " .. l)
      end
    end
  end

  push("## notifications")
  for _, n in ipairs(C.notes or {}) do
    push(n)
  end

  -- first-use registrations: everything the scenario's actions (opening a chat, a
  -- composer, a stream…) added, changed or removed in the global registry since
  -- setup() — baselined, so a lazily installed or overwritten mapping/command/
  -- autocmd/highlight fails like any visual change
  if C.post_setup then
    local now = C.registry_state()
    for _, sec in ipairs({
      { "cmds", "user commands" },
      { "maps", "keymaps" },
      { "aus", "autocmds" },
      { "hls", "highlight groups" },
      { "ns", "namespaces" },
    }) do
      local d = diff_entries(C.post_setup[sec[1]], now[sec[1]])
      push(string.format("## registry changes since setup: %s (%d)", sec[2], #d))
      vim.list_extend(out, d)
    end
  end

  return {
    rows = rows,
    cols = cols,
    text = text,
    attrs = attrs,
    body = out,
    groups = vim.tbl_keys(groups),
  }
end

-- ── setup / registration state ──────────────────────────────────────────────
-- Everything that loading obelus + setup() can register or overwrite: user
-- commands, keymaps (global AND buffer-local, every mode, Neovim's defaults
-- included), autocmds (every group AND ungrouped), highlight groups, namespaces.
-- Each entry is { key, sig, fn }: `sig` is the stable serialization (no handles,
-- ids or line numbers; a Lua callback is named by its source FILE), `fn` the live
-- callback, compared by identity in-process so swapping one Lua callback for
-- another with an identical description still reads as "changed".
local MAP_MODES = { "n", "v", "x", "s", "o", "i", "c", "t", "l" }

-- A callback's BEHAVIOUR identity, stable across processes and independent of
-- where in its file it sits: a hash of its SOURCE TEXT (the lines from
-- linedefined to lastlinedefined) plus, recursively, of every function it closes
-- over. Swapping `M.toggle_hints()` for `M.toggle_mode()` in a callback changes
-- its text and so its hash; moving the function down the file does not.
-- (Not string.dump: LuaJIT's seeded string hashing makes template-table
-- constants dump in a different order in every process.)
local src_lines = {}
local function fn_hash(f, depth)
  local info = debug.getinfo(f, "S")
  local path = info.source and info.source:match("^@(.+)$")
  if not path or info.linedefined <= 0 then
    return "C"
  end
  if src_lines[path] == nil then
    src_lines[path] = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or false
  end
  local lines = src_lines[path]
  if not lines then
    return "nosrc"
  end
  local parts = { table.concat(vim.list_slice(lines, info.linedefined, info.lastlinedefined), "\n") }
  if depth > 0 then
    local i = 1
    while true do
      local name, v = debug.getupvalue(f, i)
      if not name then
        break
      end
      if type(v) == "function" then
        parts[#parts + 1] = name .. "=" .. fn_hash(v, depth - 1)
      end
      i = i + 1
    end
  end
  return vim.fn.sha256(table.concat(parts, "\0")):sub(1, 12)
end

local function fn_src(f)
  if type(f) ~= "function" then
    return tostring(f)
  end
  local info = debug.getinfo(f, "S")
  return "<lua " .. scrub((info.source or "?"):gsub("^@", "")) .. "#" .. fn_hash(f, 3) .. ">"
end

local function map_sig(m)
  return string.format(
    "desc=%s silent=%s noremap=%s nowait=%s expr=%s script=%s rhs=%s",
    ser(m.desc),
    ser(m.silent),
    ser(m.noremap),
    ser(m.nowait),
    ser(m.expr),
    ser(m.script),
    m.callback and fn_src(m.callback) or ser(m.rhs or "")
  )
end

function C.registry_state()
  local st = { cmds = {}, maps = {}, aus = {}, hls = {}, ns = {} }
  for name, c in pairs(vim.api.nvim_get_commands({ builtin = false })) do
    st.cmds[#st.cmds + 1] = {
      key = name,
      sig = string.format(
        "nargs=%s range=%s count=%s bang=%s bar=%s complete=%s def=%s",
        ser(c.nargs),
        ser(c.range),
        ser(c.count),
        ser(c.bang),
        ser(c.bar),
        ser(c.complete and (type(c.complete) == "string" and c.complete or "<fn>") or nil),
        ser(c.definition)
      ) .. (C.cmd_cb[name] and (" run=" .. fn_src(C.cmd_cb[name])) or ""),
      fn = C.cmd_cb[name],
    }
  end
  for _, mode in ipairs(MAP_MODES) do
    for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
      st.maps[#st.maps + 1] = { key = "global " .. mode .. " " .. m.lhs, sig = map_sig(m), fn = m.callback }
    end
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) then
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, mode)) do
          st.maps[#st.maps + 1] = {
            key = "buf(" .. buf_label(b) .. ") " .. mode .. " " .. m.lhs,
            sig = map_sig(m),
            fn = m.callback,
          }
        end
      end
    end
  end
  for _, a in ipairs(vim.api.nvim_get_autocmds({})) do
    -- buffer-local patterns ("<buffer=5>") and window-id patterns (WinClosed
    -- "1003") carry allocation numbers: normalize them away
    local pat = a.pattern
    if a.buffer and a.buffer > 0 then
      pat = "<buffer>"
    elseif type(pat) == "string" and pat:match("^%d+$") and a.event:match("^Win") then
      -- keep WHICH window it targets (by role: its buffer and kind), not the id
      local w = tonumber(pat)
      if vim.api.nvim_win_is_valid(w) then
        local float = (vim.api.nvim_win_get_config(w).relative or "") ~= ""
        pat = "<win " .. buf_label(vim.api.nvim_win_get_buf(w)) .. (float and " float" or " split") .. ">"
      else
        pat = "<win closed>"
      end
    end
    local key = string.format(
      "%s %s pattern=%s buffer=%s",
      a.group_name or "<ungrouped>",
      a.event,
      ser(pat),
      a.buffer and a.buffer > 0 and buf_label(a.buffer) or "-"
    )
    st.aus[#st.aus + 1] = {
      key = key,
      sig = string.format(
        "once=%s desc=%s run=%s",
        ser(a.once),
        ser(a.desc),
        (a.command and a.command ~= "") and ser(a.command) or fn_src(a.callback)
      ),
      fn = a.callback,
    }
  end
  -- highlight DEFINITIONS as set (attributes + link), not resolutions: a
  -- link=false lookup is coloured by the current window's 'winhighlight', which
  -- is a capture-context artefact, not a registry change
  for name, def in pairs(vim.api.nvim_get_hl(0, {})) do
    if type(name) == "string" then
      local d = vim.deepcopy(def)
      for _, k in ipairs({ "fg", "bg", "sp" }) do
        if type(d[k]) == "number" then
          d[k] = hex(d[k])
        end
      end
      st.hls[#st.hls + 1] = { key = name, sig = ser(d) }
    end
  end
  for name in pairs(vim.api.nvim_get_namespaces()) do
    st.ns[#st.ns + 1] = { key = name, sig = "" }
  end
  for _, list in pairs(st) do
    table.sort(list, function(a, b)
      if a.key ~= b.key then
        return a.key < b.key
      end
      return a.sig < b.sig
    end)
  end
  return st
end

-- multiset diff of two entry lists: an entry is unchanged when an unused `pre`
-- entry has the same key, sig AND callback identity; "changed" when only the key
-- matches; else added. Leftover pre entries were removed.
diff_entries = function(pre, post)
  local used, out = {}, {}
  local function take(pred)
    for i, e in ipairs(pre) do
      if not used[i] and pred(e) then
        used[i] = true
        return e
      end
    end
  end
  for _, e in ipairs(post) do
    local same = take(function(p)
      return p.key == e.key and p.sig == e.sig and rawequal(p.fn, e.fn)
    end)
    if not same then
      local was = take(function(p)
        return p.key == e.key
      end)
      if was then
        local why = was.sig ~= e.sig and "" or "  (same description, different callback)"
        out[#out + 1] = "~ " .. e.key .. "\n    was: " .. was.sig .. "\n    now: " .. e.sig .. why
      else
        out[#out + 1] = "+ " .. e.key .. "  " .. e.sig
      end
    end
  end
  for i, p in ipairs(pre) do
    if not used[i] then
      out[#out + 1] = "- " .. p.key .. "  " .. p.sig
    end
  end
  return out
end

-- the setup/keymap registration path: a diff of the full editor state before
-- obelus loaded vs after setup() (+ opening a file), then the complete
-- after-state of commands, keymaps and autocmds (Neovim defaults included, so an
-- overwritten default shows twice: in the diff and in the full table)
function C.registration()
  C.settle()
  local post = C.registry_state()
  local out = {}
  local function push(s)
    out[#out + 1] = s
  end
  for _, sec in ipairs({
    { "cmds", "user commands" },
    { "maps", "keymaps" },
    { "aus", "autocmds" },
    { "hls", "highlight groups" },
    { "ns", "namespaces" },
  }) do
    local d = diff_entries(C.pre[sec[1]], post[sec[1]])
    push(string.format("## diff vs before obelus loaded: %s (%d)", sec[2], #d))
    vim.list_extend(out, d)
  end
  for _, sec in ipairs({ { "cmds", "user commands" }, { "maps", "keymaps" }, { "aus", "autocmds" } }) do
    push(string.format("## full after setup: %s (%d)", sec[2], #post[sec[1]]))
    for _, e in ipairs(post[sec[1]]) do
      push(e.key .. "  " .. e.sig)
    end
  end
  push("## notifications")
  for _, n in ipairs(C.notes or {}) do
    push(n)
  end
  return out
end

return C
