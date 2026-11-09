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

  vim.o.shortmess = vim.o.shortmess .. "I"
  vim.o.swapfile = false
  vim.o.termguicolors = true
  vim.o.background = "dark"
  vim.cmd.colorscheme("default")
  vim.o.background = "dark"
end

-- Let deferred work (vim.schedule / defer_fn(0) chains: panel fills, preview
-- placement, the first progress tick) run to completion. Iteration-counted, not
-- time-budgeted: each vim.wait turns the loop at least once.
function C.settle(n)
  for _ = 1, n or 8 do
    vim.wait(5)
  end
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

---@return table raw capture; the parent resolves attr ids and writes the file
function C.capture()
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

  return {
    rows = rows,
    cols = cols,
    text = text,
    attrs = attrs,
    body = out,
    groups = vim.tbl_keys(groups),
  }
end

-- the setup/keymap registration path: commands, keymaps, autocmds, highlights —
-- everything obelus.setup() registers globally, serialized order-independently
function C.registration()
  local out = {}
  local function push(s)
    out[#out + 1] = s
  end
  push("## user commands")
  local cmds = vim.api.nvim_get_commands({ builtin = false })
  local names = vim.tbl_keys(cmds)
  table.sort(names)
  for _, n in ipairs(names) do
    local c = cmds[n]
    push(
      string.format(
        "%s nargs=%s range=%s bang=%s complete=%s desc=%s",
        n,
        ser(c.nargs),
        ser(c.range),
        ser(c.bang),
        ser(c.complete),
        ser(c.definition)
      )
    )
  end
  push("## keymaps (global)")
  local maps = {}
  for _, mode in ipairs({ "n", "x", "s", "o", "i", "c", "t" }) do
    for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
      maps[#maps + 1] = string.format(
        "%s %s desc=%s silent=%s noremap=%s nowait=%s expr=%s rhs=%s",
        mode,
        m.lhs,
        ser(m.desc),
        ser(m.silent),
        ser(m.noremap),
        ser(m.nowait),
        ser(m.expr),
        ser(m.rhs or (m.callback and "<lua>") or "")
      )
    end
  end
  table.sort(maps)
  vim.list_extend(out, maps)
  push("## autocmds")
  local acs = {}
  for _, a in ipairs(vim.api.nvim_get_autocmds({})) do
    if a.group_name and a.group_name:lower():find("obelus", 1, true) then
      acs[#acs + 1] = string.format(
        "%s %s pattern=%s buffer=%s once=%s desc=%s cmd=%s",
        a.group_name,
        a.event,
        ser(a.pattern),
        ser(a.buffer and true or false),
        ser(a.once),
        ser(a.desc),
        ser(a.command ~= "" and a.command or "<lua>")
      )
    end
  end
  table.sort(acs)
  vim.list_extend(out, acs)
  push("## highlight groups (Obelus*)")
  local hls = {}
  for name in pairs(vim.api.nvim_get_hl(0, {})) do
    if type(name) == "string" and name:match("^Obelus") then
      hls[#hls + 1] = describe_hl(name)
    end
  end
  table.sort(hls)
  vim.list_extend(out, hls)
  push("## namespaces (obelus*)")
  local nss = {}
  for name in pairs(vim.api.nvim_get_namespaces()) do
    if name:match("^obelus") then
      nss[#nss + 1] = name
    end
  end
  table.sort(nss)
  vim.list_extend(out, nss)
  push("## notifications")
  for _, n in ipairs(C.notes or {}) do
    push(n)
  end
  return out
end

return C
